#!/usr/bin/env bats
# ============================================================
# improver-gate.bats — Self-Improvement 昇格ゲートのテスト
# 「証拠 / 回帰 eval / 改善者以外の承認」が揃わない限り昇格しないことを固定する。
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
  export CCSU_RUNS_DIR="$TEST_TEMP/runs"
  export CCSU_IMPROVER_STATE_DIR="$TEST_TEMP/improver-state"
  export CCSU_IMPROVER_LOG="$TEST_TEMP/logs/improver-gate.jsonl"
  mkdir -p "$CCSU_RUNS_DIR" "$CCSU_IMPROVER_STATE_DIR"
  SCRIPT="$REPO_ROOT/bin/improver-gate.sh"
  LEDGER="$REPO_ROOT/bin/run-ledger.sh"
  POLICY_CLI="$REPO_ROOT/bin/policy-check.sh"

  SIG="$(bash "$LEDGER" signature "flake: test failed at 2026-09-25T09:00:00Z exit code 137 in /tmp/a/b.log")"
  printf 'introduce retry guard for flaky integration test\n' > "$TEST_TEMP/proposal.md"
  printf '{"status":"pass","cmd":"npm test","exit_code":0}\n' > "$TEST_TEMP/eval-pass.json"
  printf '{"status":"fail","cmd":"npm test","exit_code":1}\n' > "$TEST_TEMP/eval-fail.json"
}

teardown() { _bats_common_teardown; }

_fail_run() {  # 同一 signature の失敗を 1 件記録する
  id="$(bash "$LEDGER" start --project Demo --task T)"
  bash "$LEDGER" finish "$id" --status failed --note "flake: test failed at 2026-09-25T09:00:00Z exit code 137 in /tmp/a/b.log" >/dev/null
}

@test "improver-gate: 証拠 1 件では昇格できない (1 回の失敗で永久ルールを作らない)" {
  _fail_run
  run bash "$SCRIPT" evaluate "$SIG"
  [ "$status" -eq 1 ]
  [ "$(printf '%s' "$output" | jq -r '.evidence_count')" -eq 1 ]
  [ "$(printf '%s' "$output" | jq -r '.eligible')" = "false" ]
  [[ "$(printf '%s' "$output" | jq -r '.reasons[0]')" == insufficient_evidence* ]]
}

@test "improver-gate: 同一 signature が 2 回で証拠十分になる" {
  _fail_run
  _fail_run
  run bash "$SCRIPT" evaluate "$SIG"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.evidence_count')" -eq 2 ]
  [ "$(printf '%s' "$output" | jq -r '.eligible')" = "true" ]
  run bash "$SCRIPT" evidence
  [ "$(printf '%s' "$output" | jq -r --arg s "$SIG" '.[] | select(.signature==$s) | .count')" -eq 2 ]
}

@test "improver-gate: 証拠 + eval pass + 承認トークンで昇格する" {
  _fail_run; _fail_run
  token="$(bash "$POLICY_CLI" issue cto --ttl 60)"
  run bash "$SCRIPT" promote "$SIG" --proposal "$TEST_TEMP/proposal.md" --eval-result-file "$TEST_TEMP/eval-pass.json" --token "$token"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.status')" = "promoted" ]
  [ "$(printf '%s' "$output" | jq -r '.approved_by')" = "cto" ]
  [ "$(printf '%s' "$output" | jq -r '.regression_eval')" = "pass" ]
  [ -f "$CCSU_IMPROVER_STATE_DIR/$SIG.json" ]
  # main 反映は Approval PR 経由であることが記録に残る
  [ "$(jq -r '.obligations | length' "$CCSU_IMPROVER_STATE_DIR/$SIG.json")" -ge 1 ]
  [[ "$(jq -r '.obligations[0]' "$CCSU_IMPROVER_STATE_DIR/$SIG.json")" == *Approval\ PR* ]]
  run bash "$SCRIPT" status
  [[ "$output" == *"$SIG"* ]]
}

@test "improver-gate: 承認トークンが無ければ拒否し、記録を書かない" {
  _fail_run; _fail_run
  run bash "$SCRIPT" promote "$SIG" --proposal "$TEST_TEMP/proposal.md" --eval-result-file "$TEST_TEMP/eval-pass.json"
  [ "$status" -eq 1 ]
  [ "$(printf '%s' "$output" | jq -r '.decision')" = "rejected" ]
  [ "$(printf '%s' "$output" | jq -r '.written')" = "false" ]
  [ "$(printf '%s' "$output" | jq -r '.reasons | map(select(startswith("approver_token_missing"))) | length')" -eq 1 ]
  [ ! -f "$CCSU_IMPROVER_STATE_DIR/$SIG.json" ]
}

@test "improver-gate: 回帰 eval が fail / 未指定なら拒否する" {
  _fail_run; _fail_run
  token="$(bash "$POLICY_CLI" issue cto --ttl 60)"
  run bash "$SCRIPT" promote "$SIG" --proposal "$TEST_TEMP/proposal.md" --eval-result-file "$TEST_TEMP/eval-fail.json" --token "$token"
  [ "$status" -eq 1 ]
  [ "$(printf '%s' "$output" | jq -r '.decision')" = "rejected" ]
  [[ "$(printf '%s' "$output" | jq -r '.reasons[]')" == *regression_eval_not_pass* ]]
  run bash "$SCRIPT" promote "$SIG" --proposal "$TEST_TEMP/proposal.md" --token "$token"
  [ "$status" -eq 1 ]
  [[ "$(printf '%s' "$output" | jq -r '.reasons[]')" == *regression_eval_missing* ]]
  [ ! -f "$CCSU_IMPROVER_STATE_DIR/$SIG.json" ]
}

@test "improver-gate: 改善者自身のトークンでは承認にならない (Generator/Verifier 分離)" {
  _fail_run; _fail_run
  token="$(bash "$POLICY_CLI" issue improver --ttl 60)"
  run bash "$SCRIPT" promote "$SIG" --proposal "$TEST_TEMP/proposal.md" --eval-result-file "$TEST_TEMP/eval-pass.json" --token "$token"
  [ "$status" -eq 1 ]
  [[ "$(printf '%s' "$output" | jq -r '.reasons[]')" == *approval_rejected* ]]
  [ ! -f "$CCSU_IMPROVER_STATE_DIR/$SIG.json" ]
}

@test "improver-gate: 証拠不足なら eval と承認が揃っていても昇格しない" {
  _fail_run
  token="$(bash "$POLICY_CLI" issue cto --ttl 60)"
  run bash "$SCRIPT" promote "$SIG" --proposal "$TEST_TEMP/proposal.md" --eval-result-file "$TEST_TEMP/eval-pass.json" --token "$token"
  [ "$status" -eq 1 ]
  [[ "$(printf '%s' "$output" | jq -r '.reasons[]')" == *insufficient_evidence* ]]
  [ ! -f "$CCSU_IMPROVER_STATE_DIR/$SIG.json" ]
}

@test "improver-gate: --dry-run は判定だけして書き込まない" {
  _fail_run; _fail_run
  token="$(bash "$POLICY_CLI" issue cto --ttl 60)"
  run bash "$SCRIPT" promote "$SIG" --proposal "$TEST_TEMP/proposal.md" --eval-result-file "$TEST_TEMP/eval-pass.json" --token "$token" --dry-run
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.decision')" = "accepted" ]
  [ "$(printf '%s' "$output" | jq -r '.dry_run')" = "true" ]
  [ "$(printf '%s' "$output" | jq -r '.written')" = "false" ]
  [ ! -f "$CCSU_IMPROVER_STATE_DIR/$SIG.json" ]
}

@test "improver-gate: --proposal が無ければ rc=2 (提案なしの昇格を許さない)" {
  run bash "$SCRIPT" promote "$SIG" --eval-result-file "$TEST_TEMP/eval-pass.json"
  [ "$status" -eq 2 ]
  [ ! -f "$CCSU_IMPROVER_STATE_DIR/$SIG.json" ]
}

@test "improver-gate: すべての試行が監査ログに残る" {
  _fail_run
  bash "$SCRIPT" promote "$SIG" --proposal "$TEST_TEMP/proposal.md" >/dev/null 2>&1 || true
  [ -f "$CCSU_IMPROVER_LOG" ]
  [ "$(jq -s '[.[] | select(.event=="promotion_attempt")] | length' "$CCSU_IMPROVER_LOG")" -ge 1 ]
  [ "$(jq -s '[.[] | select(.decision=="rejected")] | length' "$CCSU_IMPROVER_LOG")" -ge 1 ]
}
