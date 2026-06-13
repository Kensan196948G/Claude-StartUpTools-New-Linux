#!/usr/bin/env bats
# ============================================================
# heartbeat-watchdog.bats — Heartbeat Watchdog のユニットテスト
#
# 対象: Claude/templates/claudeos/scripts/hooks/heartbeat-watchdog.js
#       (沈黙 type3: SIGKILL / OOM Kill / 再起動によるプロセス消滅を検知する外部監視)
#
# 戦略: cwd を $TEST_TEMP にして heartbeat.json の有無・内容を制御し、
#       watchdog の判定ロジックと fail-soft 挙動を観測する。
#       webhook 到達テスト (受け入れ③) は HTTPS_WEBHOOK_URL を
#       到達不能ローカルポート (127.0.0.1:1) に向け、接続失敗を観測する (ヘルメチック)。
# ============================================================

load '../helpers/common-setup'

setup() {
  _bats_common_setup
  WATCHDOG="$REPO_ROOT/Claude/templates/claudeos/scripts/hooks/heartbeat-watchdog.js"
}
teardown() { _bats_common_teardown; }

# ---------- fail-soft: どんな状態でも運用をブロックしない ----------

@test "heartbeat.json 不在でも exit 0 (未起動 skip)" {
  run bash -c "cd '$TEST_TEMP' && node '$WATCHDOG' 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"not found"* ]]
}

@test "heartbeat.json が壊れた JSON でも exit 0 (fail-soft)" {
  run bash -c "cd '$TEST_TEMP' && printf '%s' 'not-json' > heartbeat.json && node '$WATCHDOG' 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"parse error"* ]]
}

@test "last_beat フィールドが無くても exit 0 (fail-soft)" {
  run bash -c "cd '$TEST_TEMP' && printf '%s' '{}' > heartbeat.json && node '$WATCHDOG' 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"missing last_beat"* ]]
}

@test "last_beat が不正値でも exit 0 (fail-soft)" {
  run bash -c "cd '$TEST_TEMP' && printf '%s' '{\"last_beat\":\"not-a-date\"}' > heartbeat.json && node '$WATCHDOG' 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"invalid last_beat"* ]]
}

# ---------- 新鮮なハートビート: 通知しない ----------

@test "新鮮なハートビートは fresh と表示し通知しない" {
  run bash -c "cd '$TEST_TEMP' && node -e \"require('fs').writeFileSync('heartbeat.json', JSON.stringify({last_beat: new Date().toISOString()}))\" && HEARTBEAT_STALE_SEC=300 node '$WATCHDOG' 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"fresh"* ]]
  [[ "$output" != *"STALE"* ]]
}

# ---------- 失活ハートビート: 通知経路へ到達 ----------

@test "失活ハートビートは STALE と判定する" {
  run bash -c "cd '$TEST_TEMP' && printf '%s' '{\"last_beat\":\"2000-01-01T00:00:00.000Z\",\"session_id\":\"test-session\"}' > heartbeat.json && HEARTBEAT_STALE_SEC=1 node '$WATCHDOG' 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"STALE"* ]]
}

@test "失活 + webhook 有効: 送信経路へ到達 (ヘルメチック受け入れ)" {
  run bash -c "cd '$TEST_TEMP' && printf '%s' '{\"last_beat\":\"2000-01-01T00:00:00.000Z\",\"session_id\":\"test-session\"}' > heartbeat.json && printf '%s' '{\"webhook\":{\"enabled\":true,\"events\":{\"api_failure\":true}}}' > state.json && HEARTBEAT_STALE_SEC=1 HTTPS_WEBHOOK_URL='https://127.0.0.1:1/x' node '$WATCHDOG' 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"STALE"* ]]
  [[ "$output" == *"ECONNREFUSED"* || "$output" == *"送信エラー"* ]]
}

@test "失活 + webhook 無効: 送信経路に到達しない (二重ゲート)" {
  run bash -c "cd '$TEST_TEMP' && printf '%s' '{\"last_beat\":\"2000-01-01T00:00:00.000Z\"}' > heartbeat.json && printf '%s' '{\"webhook\":{\"enabled\":false}}' > state.json && HEARTBEAT_STALE_SEC=1 HTTPS_WEBHOOK_URL='https://127.0.0.1:1/x' node '$WATCHDOG' 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" != *"ECONNREFUSED"* ]]
  [[ "$output" != *"送信エラー"* ]]
}

@test "失活 + api_failure イベント無効: 送信経路に到達しない (二重ゲート)" {
  run bash -c "cd '$TEST_TEMP' && printf '%s' '{\"last_beat\":\"2000-01-01T00:00:00.000Z\"}' > heartbeat.json && printf '%s' '{\"webhook\":{\"enabled\":true,\"events\":{\"session_end\":true}}}' > state.json && HEARTBEAT_STALE_SEC=1 HTTPS_WEBHOOK_URL='https://127.0.0.1:1/x' node '$WATCHDOG' 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" != *"ECONNREFUSED"* ]]
  [[ "$output" != *"送信エラー"* ]]
}
