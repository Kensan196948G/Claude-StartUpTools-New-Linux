#!/usr/bin/env bats
# ============================================================
# stop-failure-gate.bats — StopFailure 通知フックのユニットテスト
#
# 対象: Claude/templates/claudeos/scripts/hooks/stop-failure-gate.js
#       (無人 cron が API エラーで沈黙停止する死角を埋める通知専用フック)
#
# 戦略: フックを子プロセスとして起動し、stdin に擬似 StopFailure ペイロードを
#       与えて「親フックの stderr ログ」と「exit code」を観測する。
#       cwd を state.json 不在の $TEST_TEMP にすることで、detached spawn される
#       webhook-notifier.js は notify() 冒頭で早期 return し、ネットワークに
#       一切触れない (ヘルメチック)。
# ============================================================

load '../helpers/common-setup'

setup() {
  _bats_common_setup
  HOOK="$REPO_ROOT/Claude/templates/claudeos/scripts/hooks/stop-failure-gate.js"
  SETTINGS="$REPO_ROOT/Claude/templates/claude/settings.json"
}
teardown() { _bats_common_teardown; }

# ---------- fail-soft: どんな入力でも運用をブロックしない ----------

@test "空 stdin でも exit 0 (fail-soft)" {
  run bash -c "cd '$TEST_TEMP' && printf '' | node '$HOOK'"
  [ "$status" -eq 0 ]
}

@test "非 JSON stdin でも exit 0 (fail-soft)" {
  run bash -c "cd '$TEST_TEMP' && printf '%s' 'not json at all' | node '$HOOK'"
  [ "$status" -eq 0 ]
}

@test "空 JSON {} でも exit 0 かつ reason=unknown" {
  run bash -c "cd '$TEST_TEMP' && printf '%s' '{}' | node '$HOOK'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"reason=unknown"* ]]
}

# ---------- reason 抽出: 公式 error フィールド (文字列) ----------

@test "公式 error フィールドから billing_error を抽出" {
  run bash -c "cd '$TEST_TEMP' && printf '%s' '{\"error\":\"billing_error\"}' | node '$HOOK'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"reason=billing_error"* ]]
}

@test "公式 error フィールドから rate_limit を抽出" {
  run bash -c "cd '$TEST_TEMP' && printf '%s' '{\"error\":\"rate_limit\"}' | node '$HOOK'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"reason=rate_limit"* ]]
}

# ---------- reason 抽出: 後方互換 (旧候補フィールド / オブジェクト形) ----------

@test "旧 reason フィールドにフォールバック" {
  run bash -c "cd '$TEST_TEMP' && printf '%s' '{\"reason\":\"overloaded\"}' | node '$HOOK'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"reason=overloaded"* ]]
}

@test "オブジェクト形 error.type にフォールバック" {
  run bash -c "cd '$TEST_TEMP' && printf '%s' '{\"error\":{\"type\":\"server_error\"}}' | node '$HOOK'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"reason=server_error"* ]]
}

# ---------- settings.json 配線 (受け入れ条件) ----------

@test "settings.json: StopFailure が stop-failure-gate.js に配線 (受け入れ①)" {
  run node -e "const s=require('$SETTINGS');const sf=s.hooks.StopFailure;if(!Array.isArray(sf))process.exit(1);process.exit(/stop-failure-gate\.js/.test(sf[0].hooks[0].command)?0:2);"
  [ "$status" -eq 0 ]
}

@test "settings.json: StopFailure matcher が重大エラー種別を捕捉 (受け入れ②)" {
  run node -e "const s=require('$SETTINGS');const m=s.hooks.StopFailure[0].matcher;const crit=['billing_error','rate_limit','overloaded','authentication_failed','server_error'];process.exit((m==='*'||crit.every(t=>m.includes(t)))?0:1);"
  [ "$status" -eq 0 ]
}

@test "settings.json: 既存 Stop は session-end.js のまま (受け入れ④ 回帰防止)" {
  run node -e "const s=require('$SETTINGS');process.exit(/session-end\.js/.test(s.hooks.Stop[0].hooks[0].command)?0:1);"
  [ "$status" -eq 0 ]
}

# ---------- E2E: webhook-notifier 二重ゲート通過 (受け入れ③) ----------
# stop-failure-gate.js が detached spawn する webhook-notifier.js を直接駆動し、
# api_failure イベントが webhook.enabled / events.api_failure の二重ゲートを通過して
# 「送信経路」(HTTPS POST) まで到達することを実証する。実ネットワークには出さず、
# 到達不能なローカルポート (127.0.0.1:1) を狙って接続失敗を観測する (ヘルメチック)。

@test "webhook-notifier: api_failure 有効時に送信経路へ到達 (受け入れ③)" {
  run bash -c "cd '$TEST_TEMP' && printf '%s' '{\"webhook\":{\"enabled\":true,\"events\":{\"api_failure\":true}}}' > state.json && HTTPS_WEBHOOK_URL='https://127.0.0.1:1/x' node '$REPO_ROOT/Claude/templates/claudeos/scripts/hooks/webhook-notifier.js' api_failure '{\"reason\":\"billing_error\"}' 2>&1"
  [ "$status" -eq 0 ]
  # 二重ゲートを通過 → HTTPS POST を試行 → 接続失敗ログ ("送信エラー") が出る
  [[ "$output" == *"ECONNREFUSED"* || "$output" == *"送信エラー"* ]]
}

@test "webhook-notifier: api_failure 無効時はゲートで停止し送信しない (二重ゲート)" {
  run bash -c "cd '$TEST_TEMP' && printf '%s' '{\"webhook\":{\"enabled\":true,\"events\":{\"session_end\":true}}}' > state.json && HTTPS_WEBHOOK_URL='https://127.0.0.1:1/x' node '$REPO_ROOT/Claude/templates/claudeos/scripts/hooks/webhook-notifier.js' api_failure '{\"reason\":\"billing_error\"}' 2>&1"
  [ "$status" -eq 0 ]
  # events.api_failure が無いのでゲートで早期 return → 送信経路に一切到達しない
  [[ "$output" != *"ECONNREFUSED"* ]]
  [[ "$output" != *"送信エラー"* ]]
}
