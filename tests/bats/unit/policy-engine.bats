#!/usr/bin/env bats
# ============================================================
# policy-engine.bats — lib/policy-engine.sh + bin/policy-check.sh のテスト
# Agent Identity / Policy Engine (deny-by-default / 承認トークン / 監査証跡) を固定する。
# ============================================================

load '../helpers/common-setup'

setup() {
  _bats_common_setup
  export CLAUDEOS_HOME="$TEST_TEMP/claudeos"
  mkdir -p "$CLAUDEOS_HOME"
  # 本番 config を複製し、鍵と監査ログを一時領域へ向ける (実 ~/.claudeos を触らない)
  POLICY="$TEST_TEMP/agent-policy.json"
  jq --arg k "$TEST_TEMP/policy/identity.key" --arg a "$TEST_TEMP/logs/policy-audit.jsonl" \
     '.identity_key_file = $k | .audit_file = $a' "$REPO_ROOT/config/agent-policy.json" > "$POLICY"
  export CLAUDEOS_AGENT_POLICY="$POLICY"
  export AUDIT="$TEST_TEMP/logs/policy-audit.jsonl"
  export KEY="$TEST_TEMP/policy/identity.key"
  SCRIPT="$REPO_ROOT/bin/policy-check.sh"
}

teardown() { _bats_common_teardown; }

@test "policy: 既定は deny で、allow に載っている操作だけが通る" {
  run bash "$SCRIPT" check developer edit:src
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.decision')" = "allow" ]
  [ "$(printf '%s' "$output" | jq -r '.reasons[0]')" = "allow_listed" ]
  # allow に無い操作は deny
  run bash "$SCRIPT" check developer deploy:prod
  [ "$status" -eq 1 ]
  [ "$(printf '%s' "$output" | jq -r '.decision')" = "deny" ]
}

@test "policy: 未知の agent / 未分類の action は deny (fail-closed)" {
  run bash "$SCRIPT" check rogue read:file
  [ "$status" -eq 1 ]
  [ "$(printf '%s' "$output" | jq -r '.reasons[0]')" = "unknown_agent" ]
  run bash "$SCRIPT" check developer frobnicate:now
  [ "$status" -eq 1 ]
  [ "$(printf '%s' "$output" | jq -r '.reasons[0]')" = "unclassified_action" ]
}

@test "policy: hard_deny は承認トークンでも解除できない" {
  token="$(bash "$SCRIPT" issue cto --ttl 60)"
  run bash "$SCRIPT" check cto secret:print --token "$token"
  [ "$status" -eq 1 ]
  [ "$(printf '%s' "$output" | jq -r '.decision')" = "deny" ]
  [[ "$(printf '%s' "$output" | jq -r '.reasons[0]')" == hard_deny* ]]
  run bash "$SCRIPT" check cto main:push --token "$token"
  [ "$status" -eq 1 ]
}

@test "policy: 承認必須の操作は rc=3、承認者トークンで allow へ昇格する" {
  run bash "$SCRIPT" check developer pr:merge
  [ "$status" -eq 3 ]
  [ "$(printf '%s' "$output" | jq -r '.decision')" = "approval_required" ]
  token="$(bash "$SCRIPT" issue cto --ttl 60)"
  run bash "$SCRIPT" check developer pr:merge --token "$token"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.decision')" = "allow" ]
  [ "$(printf '%s' "$output" | jq -r '.approver')" = "cto" ]
}

@test "policy: 承認者以外が発行したトークンでは昇格しない" {
  token="$(bash "$SCRIPT" issue developer --ttl 60)"
  run bash "$SCRIPT" check developer pr:merge --token "$token"
  [ "$status" -eq 3 ]
  [ "$(printf '%s' "$output" | jq -r '.decision')" = "approval_required" ]
  [ "$(printf '%s' "$output" | jq -r '.reasons[0]')" = "approval_token_from_non_approver" ]
}

@test "policy: 改ざんされたトークンは invalid" {
  token="$(bash "$SCRIPT" issue cto --ttl 60)"
  tampered="${token%?}X"
  run bash "$SCRIPT" verify "$tampered"
  [ "$status" -ne 0 ]
  [ "$(printf '%s' "$output" | jq -r '.valid')" = "false" ]
  [ "$(printf '%s' "$output" | jq -r '.reasons[0]')" = "signature_mismatch" ]
  run bash "$SCRIPT" check developer pr:merge --token "$tampered"
  [ "$status" -eq 3 ]
  [ "$(printf '%s' "$output" | jq -r '.reasons[0]')" = "approval_token_invalid" ]
  # payload だけ差し替えても署名が合わない
  forged="$(printf '%s' '{"schema":"claudeos.agent-identity/v1","agent":"cto","issued":1,"expires":9999999999,"nonce":"x"}' | openssl base64 -A | tr '+/' '-_' | tr -d '=')"
  run bash "$SCRIPT" verify "$forged.${token##*.}"
  [ "$(printf '%s' "$output" | jq -r '.valid')" = "false" ]
}

@test "policy: 期限切れトークンは invalid" {
  token="$(bash "$SCRIPT" issue cto --ttl 0)"
  run bash "$SCRIPT" verify "$token"
  [ "$status" -ne 0 ]
  [ "$(printf '%s' "$output" | jq -r '.reasons[0]')" = "expired" ]
}

@test "policy: 判定は監査ログ (JSONL) に残る" {
  bash "$SCRIPT" check developer edit:src >/dev/null
  bash "$SCRIPT" check developer deploy:prod >/dev/null || true
  [ -f "$AUDIT" ]
  [ "$(jq -s 'length >= 2' "$AUDIT")" = "true" ]
  [ "$(jq -s '[.[] | select(.event=="decision" and .decision=="deny")] | length' "$AUDIT")" -ge 1 ]
  # JSONL として全行妥当
  ! jq -e 'select(. == null)' "$AUDIT" >/dev/null 2>&1
  while IFS= read -r line; do
    printf '%s' "$line" | jq -e . >/dev/null
  done < "$AUDIT"
}

@test "policy: 署名鍵は 0600 で作られ、内容が監査ログへ漏れない" {
  bash "$SCRIPT" issue cto --ttl 60 >/dev/null
  [ -f "$KEY" ]
  [ "$(stat -c %a "$KEY")" = "600" ]
  ! grep -qF "$(cat "$KEY")" "$AUDIT"
  # token 自体も監査ログに残さない
  token="$(bash "$SCRIPT" issue cto --ttl 60)"
  ! grep -qF "$token" "$AUDIT"
}

@test "policy: agents / explain / matrix が機能する" {
  run bash "$SCRIPT" agents
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | grep -c .)" -eq 11 ]
  run bash "$SCRIPT" explain developer edit:src
  [ "$status" -eq 0 ]
  [[ "$output" == *"allow"* ]]
  run bash "$SCRIPT" explain developer pr:merge
  [ "$status" -eq 3 ]
  run bash "$SCRIPT" matrix --json
  [ "$(printf '%s' "$output" | jq 'length')" -eq 198 ]
  [ "$(printf '%s' "$output" | jq '[.[] | select(.decision=="approval_required")] | length')" -ge 1 ]
}

@test "policy: run-ledger の run_id が判定に紐づく" {
  id="$(CLAUDEOS_RUNS_DIR="$TEST_TEMP/runs" bash "$REPO_ROOT/bin/run-ledger.sh" start --project Demo --task T)"
  run env CCSU_RUNS_DIR="$TEST_TEMP/runs" CLAUDEOS_RUN_ID="$id" bash "$SCRIPT" check developer edit:src
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.run_id')" = "$id" ]
}
