#!/usr/bin/env bats
# ============================================================
# self-heal.bats — ログ→原因分類→修復提案 (propose-only) のテスト
# 自動適用しないこと (allowlist 空 + 承認必須) を固定する。
# ============================================================

load '../helpers/common-setup'

setup() {
  _bats_common_setup
  export CLAUDEOS_HOME="$TEST_TEMP/claudeos"
  mkdir -p "$CLAUDEOS_HOME/logs" "$CLAUDEOS_HOME/state"
  POLICY="$TEST_TEMP/agent-policy.json"
  jq --arg k "$TEST_TEMP/policy/identity.key" --arg a "$TEST_TEMP/logs/policy-audit.jsonl" \
     '.identity_key_file = $k | .audit_file = $a' "$REPO_ROOT/config/agent-policy.json" > "$POLICY"
  export CLAUDEOS_AGENT_POLICY="$POLICY"
  export CCSU_RUNS_DIR="$CLAUDEOS_HOME/runs"
  export CCSU_SELF_HEAL_STATE="$TEST_TEMP/self-heal-state"
  export CCSU_SELF_HEAL_REPORTS="$TEST_TEMP/self-heal-reports"
  SCRIPT="$REPO_ROOT/bin/self-heal.sh"
  POLICY_CLI="$REPO_ROOT/bin/policy-check.sh"
  LEDGER="$REPO_ROOT/bin/run-ledger.sh"

  LOG="$TEST_TEMP/app.log"
  cat > "$LOG" <<'LOG'
2026-09-25T09:00:00Z INFO starting up
2026-09-25T09:00:01Z ERROR connect failed to postgres at port 5432
2026-09-25T09:05:11Z ERROR connect failed to postgres at port 5433
2026-09-25T09:10:00Z ❌ [ERR ] systemd unit claudeos-demo.service not found
LOG
  printf 'INFO everything is fine\n' > "$TEST_TEMP/clean.log"
}

teardown() { _bats_common_teardown; }

@test "self-heal: エラーログを signature 単位で集計し rc=1 を返す" {
  run bash "$SCRIPT" scan --file "$LOG" --json
  [ "$status" -eq 1 ]
  [ "$(printf '%s' "$output" | jq -r '.issue_count')" -eq 2 ]
  # port 番号が違っても同一 signature (ポーリング可能な形に正規化される)
  [ "$(printf '%s' "$output" | jq -r '.issues[0].count')" -eq 2 ]
  [ "$(printf '%s' "$output" | jq -r '.issues[0].samples | length')" -eq 2 ]
  [[ "$(printf '%s' "$output" | jq -r '.issues[0].candidate_owner')" == "ops" ]]
  [[ "$(printf '%s' "$output" | jq -r '.issues[1].candidate_owner')" == "ops" ]]
}

@test "self-heal: 問題が無ければ rc=0 / issue_count=0" {
  run bash "$SCRIPT" scan --file "$TEST_TEMP/clean.log" --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.issue_count')" -eq 0 ]
}

@test "self-heal: --file 指定時は既定ディレクトリを巻き込まない" {
  run bash "$SCRIPT" scan --file "$TEST_TEMP/clean.log" --json
  [ "$(printf '%s' "$output" | jq -r '.inputs | length')" -eq 1 ]
  [ "$(printf '%s' "$output" | jq -r '.inputs[0]')" = "$TEST_TEMP/clean.log" ]
}

@test "self-heal: run-ledger の失敗記録が signature 集計へ合流する" {
  id="$(bash "$LEDGER" start --project Demo --task T)"
  bash "$LEDGER" finish "$id" --status blocked --note "cloudflare tunnel handshake timeout after 30 s" >/dev/null
  run bash "$SCRIPT" scan --file "$TEST_TEMP/clean.log" --json
  [ "$status" -eq 1 ]
  [ "$(printf '%s' "$output" | jq -r '.issue_count')" -eq 1 ]
  [[ "$(printf '%s' "$output" | jq -r '.issues[0].sources[0]')" == *failures.jsonl ]]
}

@test "self-heal: run は診断と提案を state へ書き、適用は人間に委ねる" {
  run bash "$SCRIPT" run --file "$LOG"
  [ "$status" -eq 1 ]
  [ -f "$CCSU_SELF_HEAL_STATE/latest.json" ]
  [ "$(jq -r '.remediation.mode' "$CCSU_SELF_HEAL_STATE/latest.json")" = "propose-only" ]
  [ "$(jq -r '.remediation.allowlist | length' "$CCSU_SELF_HEAL_STATE/latest.json")" -eq 0 ]
  ls "$CCSU_SELF_HEAL_STATE"/proposal-*.json >/dev/null 2>&1
  proposal="$(ls "$CCSU_SELF_HEAL_STATE"/proposal-*.json | head -1)"
  [ "$(jq -r '.apply' "$proposal")" = "human-approval-required" ]
  run bash "$SCRIPT" status
  [[ "$output" == *"issue_count=2"* ]]
}

@test "self-heal: --out は再現可能なレポートを残す (schema 付き)" {
  out="$TEST_TEMP/report.json"
  bash "$SCRIPT" scan --file "$LOG" --out "$out" >/dev/null 2>&1 || true
  [ -f "$out" ]
  [ "$(jq -r '.schema' "$out")" = "claudeos.self-heal-report/v1" ]
  [ "$(jq -r '.issue_count' "$out")" -eq 2 ]
}

@test "self-heal: allowlist が空なら apply は必ず拒否する (本番コードを自動で書き換えない)" {
  printf '{"kind":"restart-supervisor"}\n' > "$TEST_TEMP/prop.json"
  run bash "$SCRIPT" apply --proposal "$TEST_TEMP/prop.json"
  [ "$status" -eq 3 ]
  [[ "$output" == *allowlist* ]]
}

@test "self-heal: allowlist と承認トークンが揃った場合のみ適用へ進む" {
  printf '{"kind":"restart-supervisor"}\n' > "$TEST_TEMP/prop.json"
  token="$(bash "$POLICY_CLI" issue cto --ttl 60)"
  # allowlist 未設定の種別は拒否
  run env CCSU_SELF_HEAL_ALLOWLIST="rotate-log" bash "$SCRIPT" apply --proposal "$TEST_TEMP/prop.json" --token "$token"
  [ "$status" -eq 3 ]
  # allowlist 一致 + 承認あり
  run env CCSU_SELF_HEAL_ALLOWLIST="restart-supervisor,rotate-log" bash "$SCRIPT" apply --proposal "$TEST_TEMP/prop.json" --token "$token"
  [ "$status" -eq 0 ]
  [[ "$output" == *allowlist* ]]
  # 承認トークンが無ければ拒否
  run env CCSU_SELF_HEAL_ALLOWLIST="restart-supervisor" bash "$SCRIPT" apply --proposal "$TEST_TEMP/prop.json"
  [ "$status" -eq 3 ]
}
