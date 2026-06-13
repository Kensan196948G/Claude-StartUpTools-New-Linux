#!/usr/bin/env bats
# ============================================================
# notification-gate.bats — Notification 通知フックのユニットテスト
#
# 対象: Claude/templates/claudeos/scripts/hooks/notification-gate.js
#       (無人 cron が入力待ちで沈黙停止する死角を埋める通知専用フック)
#
# 戦略: フックを子プロセスとして起動し、stdin に擬似 Notification ペイロードを
#       与えて「親フックの stderr ログ」と「exit code」を観測する。
#       cwd を state.json 不在の $TEST_TEMP にすることで、detached spawn される
#       webhook-notifier.js は notify() 冒頭で早期 return し、ネットワークに
#       一切触れない (ヘルメチック)。
# ============================================================

load '../helpers/common-setup'

setup() {
  _bats_common_setup
  HOOK="$REPO_ROOT/Claude/templates/claudeos/scripts/hooks/notification-gate.js"
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

@test "空 JSON {} でも exit 0 かつ notification_type=unknown" {
  run bash -c "cd '$TEST_TEMP' && printf '%s' '{}' | node '$HOOK' 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"notification_type=unknown"* ]]
}

# ---------- notification_type 抽出: 公式フィールド ----------

@test "公式 notification_type から idle_prompt を抽出" {
  run bash -c "cd '$TEST_TEMP' && printf '%s' '{\"notification_type\":\"idle_prompt\"}' | node '$HOOK' 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"notification_type=idle_prompt"* ]]
}

@test "公式 notification_type から permission_prompt を抽出" {
  run bash -c "cd '$TEST_TEMP' && printf '%s' '{\"notification_type\":\"permission_prompt\"}' | node '$HOOK' 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"notification_type=permission_prompt"* ]]
}

# ---------- notification_type 抽出: フォールバック ----------

@test "notificationType camelCase フォールバック" {
  run bash -c "cd '$TEST_TEMP' && printf '%s' '{\"notificationType\":\"auth_success\"}' | node '$HOOK' 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"notification_type=auth_success"* ]]
}

@test "type フィールドにフォールバック" {
  run bash -c "cd '$TEST_TEMP' && printf '%s' '{\"type\":\"elicitation_request\"}' | node '$HOOK' 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"notification_type=elicitation_request"* ]]
}

# ---------- settings.json 配線 (受け入れ条件) ----------

@test "settings.json: Notification が notification-gate.js に配線 (受け入れ①)" {
  run node -e "const s=require('$SETTINGS');const n=s.hooks.Notification;if(!Array.isArray(n))process.exit(1);process.exit(/notification-gate\.js/.test(n[0].hooks[0].command)?0:2);"
  [ "$status" -eq 0 ]
}

@test "settings.json: Notification が idle_prompt と permission_prompt の両方を配線 (受け入れ②)" {
  run node -e "const s=require('$SETTINGS');const n=s.hooks.Notification;if(!Array.isArray(n))process.exit(1);const matchers=n.map(e=>e.matcher);process.exit((matchers.includes('idle_prompt')&&matchers.includes('permission_prompt'))?0:1);"
  [ "$status" -eq 0 ]
}

@test "settings.json: 既存 Stop は session-end.js のまま (回帰防止)" {
  run node -e "const s=require('$SETTINGS');process.exit(/session-end\.js/.test(s.hooks.Stop[0].hooks[0].command)?0:1);"
  [ "$status" -eq 0 ]
}

# ---------- E2E: webhook-notifier 二重ゲート通過 (受け入れ③) ----------
# notification-gate.js が detached spawn する webhook-notifier.js を直接駆動し、
# input_waiting イベントが webhook.enabled / events.input_waiting の二重ゲートを通過して
# 「送信経路」(HTTPS POST) まで到達することを実証する。実ネットワークには出さず、
# 到達不能なローカルポート (127.0.0.1:1) を狙って接続失敗を観測する (ヘルメチック)。

@test "webhook-notifier: input_waiting 有効時に送信経路へ到達 (受け入れ③)" {
  run bash -c "cd '$TEST_TEMP' && printf '%s' '{\"webhook\":{\"enabled\":true,\"events\":{\"input_waiting\":true}}}' > state.json && HTTPS_WEBHOOK_URL='https://127.0.0.1:1/x' node '$REPO_ROOT/Claude/templates/claudeos/scripts/hooks/webhook-notifier.js' input_waiting '{\"notification_type\":\"idle_prompt\"}' 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ECONNREFUSED"* || "$output" == *"送信エラー"* ]]
}

@test "webhook-notifier: input_waiting 無効時はゲートで停止し送信しない (二重ゲート)" {
  run bash -c "cd '$TEST_TEMP' && printf '%s' '{\"webhook\":{\"enabled\":true,\"events\":{\"session_end\":true}}}' > state.json && HTTPS_WEBHOOK_URL='https://127.0.0.1:1/x' node '$REPO_ROOT/Claude/templates/claudeos/scripts/hooks/webhook-notifier.js' input_waiting '{\"notification_type\":\"idle_prompt\"}' 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" != *"ECONNREFUSED"* ]]
  [[ "$output" != *"送信エラー"* ]]
}
