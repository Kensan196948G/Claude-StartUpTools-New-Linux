#!/usr/bin/env bats
# ============================================================
# computer-use.bats — GUI 観測・操作の統制をテストする
# 「承認が無ければ画面を撮らない」「allowlist の動詞だけ」「1 ステップずつ」「headless では実行しない」
# を固定する。GUI 自体が無いホストでは、拒否経路までを検証する (理由付きで rc=3)。
# ============================================================

load '../helpers/common-setup'

setup() {
  _bats_common_setup
  export CLAUDEOS_HOME="$TEST_TEMP/claudeos"
  mkdir -p "$CLAUDEOS_HOME"
  POLICY="$TEST_TEMP/agent-policy.json"
  jq --arg k "$TEST_TEMP/policy/identity.key" --arg a "$TEST_TEMP/logs/policy-audit.jsonl" \
     '.identity_key_file = $k | .audit_file = $a' "$REPO_ROOT/config/agent-policy.json" > "$POLICY"
  export CLAUDEOS_AGENT_POLICY="$POLICY"
  export CCSU_COMPUTER_USE_LOG="$TEST_TEMP/logs/computer-use.jsonl"
  unset DISPLAY WAYLAND_DISPLAY || true
  SCRIPT="$REPO_ROOT/libexec/computer-use.sh"
  POLICY_CLI="$REPO_ROOT/bin/policy-check.sh"

  cat > "$TEST_TEMP/plan.json" <<'JSON'
{ "schema": "claudeos.computer-use-plan/v1",
  "steps": [ { "verb": "wait", "seconds": 1 },
             { "verb": "click", "x": 10, "y": 20, "note": "OK ボタン" },
             { "verb": "type", "text": "hello" } ] }
JSON
  TOKEN="$(bash "$POLICY_CLI" issue cto --ttl 60)"
}

teardown() { _bats_common_teardown; }

@test "computer-use: probe は GUI の有無と利用可能ツールを報告する" {
  run bash "$SCRIPT" probe
  [ "$status" -eq 1 ]
  [ "$(printf '%s' "$output" | jq -r '.gui_available')" = "false" ]
  [[ "$(printf '%s' "$output" | jq -r '.note')" == headless* ]]
}

@test "computer-use: 承認が無ければ画面を取得しない (ポリシー先・撮影後ではない)" {
  run bash "$SCRIPT" observe --out "$TEST_TEMP/shot.png"
  [ "$status" -eq 3 ]
  [ ! -f "$TEST_TEMP/shot.png" ]
  [ ! -f "$CCSU_COMPUTER_USE_LOG" ]
}

@test "computer-use: 承認があっても headless では取得しない (rc=3)" {
  run bash "$SCRIPT" observe --out "$TEST_TEMP/shot.png" --token "$TOKEN"
  [ "$status" -eq 3 ]
  [ ! -f "$TEST_TEMP/shot.png" ]
  [[ "$output" == *headless* ]]
}

@test "computer-use: プラン検証は allowlist 外の動詞を拒否する (rc=4)" {
  jq '.steps[0].verb = "shell"' "$TEST_TEMP/plan.json" > "$TEST_TEMP/bad.json"
  run bash "$SCRIPT" plan --file "$TEST_TEMP/bad.json"
  [ "$status" -eq 4 ]
  [[ "$output" == *allowlist* ]]
}

@test "computer-use: プラン検証は必須フィールドの欠落を拒否する (rc=4)" {
  jq 'del(.steps[1].y)' "$TEST_TEMP/plan.json" > "$TEST_TEMP/noy.json"
  run bash "$SCRIPT" plan --file "$TEST_TEMP/noy.json"
  [ "$status" -eq 4 ]
  [[ "$output" == *y* ]]
  jq '.schema = "something-else"' "$TEST_TEMP/plan.json" > "$TEST_TEMP/noschema.json"
  run bash "$SCRIPT" plan --file "$TEST_TEMP/noschema.json"
  [ "$status" -eq 4 ]
  run bash "$SCRIPT" plan --file "$TEST_TEMP/plan.json"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.step_count')" -eq 3 ]
}

@test "computer-use: act は承認が無ければ実行しない (rc=3)" {
  run bash "$SCRIPT" act --plan "$TEST_TEMP/plan.json" --step 1
  [ "$status" -eq 3 ]
  [ ! -f "$CCSU_COMPUTER_USE_LOG" ]
}

@test "computer-use: act は承認があっても headless では実行しない (rc=3)" {
  run bash "$SCRIPT" act --plan "$TEST_TEMP/plan.json" --step 1 --token "$TOKEN"
  [ "$status" -eq 3 ]
  [[ "$output" == *headless* ]]
}

@test "computer-use: 範囲外のステップ指定は拒否する (rc=2)" {
  run bash "$SCRIPT" act --plan "$TEST_TEMP/plan.json" --step 9 --token "$TOKEN"
  [ "$status" -eq 2 ]
  [[ "$output" == *範囲外* ]]
}

@test "computer-use: DISPLAY があれば dry-run で計画を返し、confirm 無しでは発火しない" {
  run env DISPLAY=:99 bash "$SCRIPT" act --plan "$TEST_TEMP/plan.json" --step 1 --token "$TOKEN"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.dry_run')" = "true" ]
  [ "$(printf '%s' "$output" | jq -r '.executed // false')" = "false" ]
  [ "$(printf '%s' "$output" | jq -r '.verb')" = "click" ]
  [ "$(printf '%s' "$output" | jq -r '.detail.note')" = "OK ボタン" ]
}

@test "computer-use: confirm しても入力ツールが無ければ実行しない (rc=3)" {
  run env DISPLAY=:99 bash "$SCRIPT" act --plan "$TEST_TEMP/plan.json" --step 1 --token "$TOKEN" --confirm
  [ "$status" -eq 3 ]
  [[ "$output" == *xdotool* ]]
}

@test "computer-use: 実行ログは dry-run と確定実行を区別して残す" {
  env DISPLAY=:99 bash "$SCRIPT" act --plan "$TEST_TEMP/plan.json" --step 0 --token "$TOKEN" >/dev/null
  [ -f "$CCSU_COMPUTER_USE_LOG" ]
  [ "$(jq -r '.event' "$CCSU_COMPUTER_USE_LOG")" = "act_dry_run" ]
  [ "$(jq -r '.verb' "$CCSU_COMPUTER_USE_LOG")" = "wait" ]
}
