#!/usr/bin/env bash
# ============================================================
# adversarial-probe.sh — Agent 実行基盤の攻撃耐性テスト
#
# 使い方:
#   adversarial-probe.sh run [--case ID] [--class C] [--json] [--out FILE] [--list]
#       corpus (tests/adversarial/corpus.json) の各ケースを実行し、expect と照合する。
#       1 件でも FAIL があれば rc=1 (CI で回せる)。
#   adversarial-probe.sh list           # ケース一覧
#
# 対象: policy-engine (認可) / improver-gate (自己改善昇格) / run-ledger (台帳) /
#       self-heal (自動適用) — Prompt Injection, 権限昇格, トークン偽造, スコープ脱出,
#       秘密漏えい, ポリシー弱体化の 6 クラス。
#
# 安全: 実行はすべてサンドボックス (既定 $CLAUDEOS_HOME/state/adversarial) 内で行い、
#       本番の監査ログ・鍵・run 台帳には触れない。payload は引数として渡すだけで
#       eval / 実行しない。
#
# 終了コード: 0 全 PASS / 1 FAIL あり / 2 実行エラー
# ============================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
# shellcheck source=lib/json.sh
source "$SCRIPT_DIR/../lib/json.sh"

require_cmd jq
require_cmd openssl

CORPUS="${CCSU_ADVERSARIAL_CORPUS:-$CCSU_ROOT/tests/adversarial/corpus.json}"
ADV_WORK="${CCSU_ADV_WORKDIR:-$CCSU_HOME/state/adversarial}"

adv__iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

usage() { sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

# adv__sandbox — サンドボックスを作り、子プロセス用 env を ADV_ENV に用意する
adv__sandbox() {
  mkdir -p "$ADV_WORK/policy" "$ADV_WORK/logs" "$ADV_WORK/runs" "$ADV_WORK/state/improver" "$ADV_WORK/state/self-heal"
  chmod 700 "$ADV_WORK/policy" 2>/dev/null || true
  jq --arg k "$ADV_WORK/policy/identity.key" --arg a "$ADV_WORK/logs/policy-audit.jsonl" \
     '.identity_key_file = $k | .audit_file = $a' "$CCSU_ROOT/config/agent-policy.json" > "$ADV_WORK/policy.json"
  ADV_ENV=(
    "CLAUDEOS_AGENT_POLICY=$ADV_WORK/policy.json"
    "CLAUDEOS_HOME=$ADV_WORK"
    "CCSU_HOME=$ADV_WORK"
    "CCSU_RUNS_DIR=$ADV_WORK/runs"
    "CCSU_IMPROVER_STATE_DIR=$ADV_WORK/state/improver"
    "CCSU_IMPROVER_LOG=$ADV_WORK/logs/improver-gate.jsonl"
    "CCSU_SELF_HEAL_STATE=$ADV_WORK/state/self-heal"
    "CCSU_SELF_HEAL_REPORTS=$ADV_WORK/reports/self-heal"
  )
  ADV_AUDIT="$ADV_WORK/logs/policy-audit.jsonl"
}

adv_policy()   { env "${ADV_ENV[@]}" bash "$CCSU_ROOT/bin/policy-check.sh" "$@"; }
adv_ledger()   { env "${ADV_ENV[@]}" bash "$CCSU_ROOT/bin/run-ledger.sh" "$@"; }
adv_gate()     { env "${ADV_ENV[@]}" bash "$CCSU_ROOT/bin/improver-gate.sh" "$@"; }
adv_heal()     { env "${ADV_ENV[@]}" bash "$CCSU_ROOT/bin/self-heal.sh" "$@"; }

# --- ケース実行 ---------------------------------------------------------
# 各 checker は "<PASS|FAIL>\t<actual-json>" を stdout へ返す。

chk_policy_decision() {
  local actor="$1" action="$2" exp_dec="$3" exp_rc="$4"
  local out rc=0
  out="$(adv_policy check "$actor" "$action" 2>/dev/null)" || rc=$?
  local dec; dec="$(printf '%s' "$out" | jq -r '.decision // "none"')"
  if [[ "$dec" == "$exp_dec" && "$rc" -eq "$exp_rc" ]]; then
    printf 'PASS\t%s' "$(jq -cn --arg d "$dec" --argjson rc "$rc" '{decision:$d, rc:$rc}')"
  else
    printf 'FAIL\t%s' "$(jq -cn --arg d "$dec" --argjson rc "$rc" --arg ed "$exp_dec" --argjson erc "$exp_rc" \
      '{decision:$d, rc:$rc, expected_decision:$ed, expected_rc:$erc}')"
  fi
}

chk_token_tamper() {
  local actor="$1"
  local tok; tok="$(adv_policy issue "$actor" --ttl 60 2>/dev/null)"
  local tampered="${tok%?}X"
  local out; out="$(adv_policy verify "$tampered" 2>/dev/null || true)"
  local valid; valid="$(printf '%s' "$out" | jq -r 'if has("valid") then (.valid|tostring) else "unknown" end')"
  local why; why="$(printf '%s' "$out" | jq -r '.reasons[0] // ""')"
  if [[ "$valid" == "false" ]]; then
    printf 'PASS\t%s' "$(jq -cn --arg v "$valid" --arg w "$why" '{valid:$v, reason:$w}')"
  else
    printf 'FAIL\t%s' "$(jq -cn --arg v "$valid" '{valid:$v, expected_valid:"false"}')"
  fi
}

chk_token_self_issue() {
  local actor="$1" action="$2"
  local tok; tok="$(adv_policy issue "$actor" --ttl 60 2>/dev/null)"
  local out; out="$(adv_policy check "$actor" "$action" --token "$tok" 2>/dev/null || true)"
  local dec why
  dec="$(printf '%s' "$out" | jq -r '.decision // "none"')"
  why="$(printf '%s' "$out" | jq -r '.reasons[0] // ""')"
  if [[ "$dec" == "approval_required" ]]; then
    printf 'PASS\t%s' "$(jq -cn --arg d "$dec" --arg w "$why" '{decision:$d, reason:$w}')"
  else
    printf 'FAIL\t%s' "$(jq -cn --arg d "$dec" --arg w "$why" '{decision:$d, reason:$w, expected_decision:"approval_required"}')"
  fi
}

chk_token_expiry() {
  local actor="$1"
  local tok; tok="$(adv_policy issue "$actor" --ttl 0 2>/dev/null)"
  local out; out="$(adv_policy verify "$tok" 2>/dev/null || true)"
  local why; why="$(printf '%s' "$out" | jq -r '.reasons[0] // ""')"
  if [[ "$why" == "expired" ]]; then
    printf 'PASS\t%s' "$(jq -cn --arg w "$why" '{reason:$w}')"
  else
    printf 'FAIL\t%s' "$(jq -cn --arg w "$why" '{reason:$w, expected_reason:"expired"}')"
  fi
}

chk_promote_injection() {
  local payload="$1"
  local prop="$ADV_WORK/proposal-injection.txt"
  printf '%s\n' "$payload" > "$prop"
  local sig="sig-0000000000000000"
  local out rc=0
  out="$(adv_gate promote "$sig" --proposal "$prop" 2>/dev/null)" || rc=$?
  local dec written
  dec="$(printf '%s' "$out" | jq -r '.decision // "none"')"
  written="$(printf '%s' "$out" | jq -r 'if has("written") then (.written|tostring) else "missing" end')"
  local state_file="$ADV_WORK/state/improver/$sig.json"
  if [[ "$dec" == "rejected" && "$written" == "false" && ! -f "$state_file" ]]; then
    printf 'PASS\t%s' "$(jq -cn --arg d "$dec" --argjson w false --argjson rc "$rc" '{decision:$d, written:$w, rc:$rc}')"
  else
    printf 'FAIL\t%s' "$(jq -cn --arg d "$dec" --arg w "$written" --argjson rc "$rc" --argjson file "$( [[ -f "$state_file" ]] && printf true || printf false )" \
      '{decision:$d, written:$w, rc:$rc, state_file_created:$file, expected_decision:"rejected"}')"
  fi
}

chk_signature_injection() {
  local payload="$1"
  local out rc=0
  out="$(adv_gate evaluate "$payload" --min-evidence 2 2>/dev/null)" || rc=$?
  local elig count
  elig="$(printf '%s' "$out" | jq -r 'if has("eligible") then (.eligible|tostring) else "unknown" end')"
  count="$(printf '%s' "$out" | jq -r 'if has("evidence_count") then (.evidence_count|tostring) else "unknown" end')"
  if [[ "$elig" == "false" && "$rc" -ne 0 ]]; then
    printf 'PASS\t%s' "$(jq -cn --arg e "$elig" --argjson c "$count" '{eligible:$e, evidence_count:$c}')"
  else
    printf 'FAIL\t%s' "$(jq -cn --arg e "$elig" --argjson c "$count" --argjson rc "$rc" '{eligible:$e, evidence_count:$c, rc:$rc, expected_eligible:false}')"
  fi
}

chk_run_id_traversal() {
  local payload="$1"
  local rc=0
  adv_ledger get "$payload" >/dev/null 2>&1 || rc=$?
  if (( rc != 0 )); then
    printf 'PASS\t%s' "$(jq -cn --argjson rc "$rc" '{rc:$rc}')"
  else
    printf 'FAIL\t%s' "$(jq -cn --argjson rc "$rc" '{rc:$rc, expected:"nonzero"}')"
  fi
}

chk_self_heal_apply() {
  local prop="$ADV_WORK/proposal-apply.json"
  printf '{"kind":"restart-supervisor"}\n' > "$prop"
  local rc=0
  adv_heal apply --proposal "$prop" >/dev/null 2>&1 || rc=$?
  if (( rc == 3 )); then
    printf 'PASS\t%s' "$(jq -cn --argjson rc "$rc" '{rc:$rc}')"
  else
    printf 'FAIL\t%s' "$(jq -cn --argjson rc "$rc" '{rc:$rc, expected_rc:3}')"
  fi
}

chk_audit_has_no_key() {
  local key="$ADV_WORK/policy/identity.key"
  local leaks=0
  if [[ -f "$key" ]]; then
    if [[ -f "$ADV_AUDIT" ]] && grep -qF "$(cat "$key")" "$ADV_AUDIT"; then leaks=1; fi
  fi
  local tok; tok="$(adv_policy issue cto --ttl 60 2>/dev/null)"
  if [[ -n "$tok" && -f "$ADV_AUDIT" ]] && grep -qF "$tok" "$ADV_AUDIT"; then leaks=1; fi
  if (( leaks == 0 )); then
    printf 'PASS\t%s' "$(jq -cn '{leaks:0}')"
  else
    printf 'FAIL\t%s' "$(jq -cn '{leaks:1, expected:"0"}')"
  fi
}

chk_decision_has_no_secret() {
  local actor="$1" action="$2"
  local out; out="$(adv_policy check "$actor" "$action" 2>/dev/null || true)"
  local bad; bad="$(printf '%s' "$out" | jq -r '[keys[] | select(test("secret|password|token_value"))] | length')"
  if [[ "$bad" == "0" ]]; then
    printf 'PASS\t%s' "$(jq -cn '{secret_like_keys:0}')"
  else
    printf 'FAIL\t%s' "$(jq -cn --argjson b "$bad" '{secret_like_keys:$b}')"
  fi
}

chk_matrix_no_allow_for_harddeny() {
  local hard; hard="$(jq -c '.hard_deny' "$CCSU_ROOT/config/agent-policy.json")"
  local out; out="$(adv_policy matrix --json 2>/dev/null || printf '[]')"
  local rows; rows="$(printf '%s' "$out" | jq 'length')"
  local count
  count="$(printf '%s' "$out" | jq --argjson hard "$hard" '[.[] | select(.decision=="allow" and (.action as $a | $hard | index($a) != null))] | length')"
  if [[ "$count" == "0" ]]; then
    printf 'PASS\t%s' "$(jq -cn --argjson rows "$rows" '{allow_on_hard_deny:0, rows:$rows}')"
  else
    printf 'FAIL\t%s' "$(jq -cn --argjson c "$count" --argjson rows "$rows" '{allow_on_hard_deny:$c, rows:$rows, expected:0}')"
  fi
}

chk_policy_schema_present() {
  local ok; ok="$(jq -r '.schema // ""' "$CCSU_ROOT/config/agent-policy.json")"
  if [[ "$ok" == "claudeos.agent-policy/v1" ]]; then
    printf 'PASS\t%s' "$(jq -cn --arg s "$ok" '{schema:$s}')"
  else
    printf 'FAIL\t%s' "$(jq -cn --arg s "$ok" '{schema:$s, expected:"claudeos.agent-policy/v1"}')"
  fi
}

# adv__dispatch <case-json> — kind ごとの checker を呼ぶ
adv__dispatch() {
  local c="$1"
  local kind; kind="$(printf '%s' "$c" | jq -r '.kind')"
  local actor action payload exp_dec exp_rc
  actor="$(printf '%s' "$c" | jq -r '.actor // ""')"
  action="$(printf '%s' "$c" | jq -r '.action // ""')"
  payload="$(printf '%s' "$c" | jq -r '.payload // ""')"
  exp_dec="$(printf '%s' "$c" | jq -r '.expect.decision // ""')"
  exp_rc="$(printf '%s' "$c" | jq -r '.expect.rc // -1')"

  case "$kind" in
    policy_decision)          chk_policy_decision "$actor" "$action" "$exp_dec" "$exp_rc" ;;
    token_tamper)             chk_token_tamper "$actor" ;;
    token_self_issue)         chk_token_self_issue "$actor" "$action" ;;
    token_expiry)             chk_token_expiry "$actor" ;;
    promote_injection)        chk_promote_injection "$payload" ;;
    signature_injection)      chk_signature_injection "$payload" ;;
    run_id_traversal)         chk_run_id_traversal "$payload" ;;
    self_heal_apply_no_approval) chk_self_heal_apply ;;
    audit_has_no_key)         chk_audit_has_no_key ;;
    decision_has_no_secret)   chk_decision_has_no_secret "$actor" "$action" ;;
    matrix_no_allow_for_harddeny) chk_matrix_no_allow_for_harddeny ;;
    policy_schema_present)    chk_policy_schema_present ;;
    *) printf 'FAIL\t%s' "$(jq -cn --arg k "$kind" '{error:"unknown_kind", kind:$k}')" ;;
  esac
}

main() {
  local cmd="${1:-run}"; shift || true
  local filter_case="" filter_class="" as_json=0 out_file=""
  while (( $# )); do
    case "$1" in
      --case)  filter_case="${2:-}";  shift 2 ;;
      --class) filter_class="${2:-}"; shift 2 ;;
      --json)  as_json=1; shift ;;
      --out)   out_file="${2:-}"; shift 2 ;;
      *) shift ;;
    esac
  done

  [[ -f "$CORPUS" ]] || { log_error "コーパスがありません: $CORPUS"; return 2; }
  if [[ "$cmd" == "list" ]]; then
    jq -r '.cases[] | "\(.id)\t\(.class)\t\(.kind)"' "$CORPUS"
    return 0
  fi

  adv__sandbox

  local results='[]' total=0 passed=0 failed=0
  local ids; ids="$(jq -r '.cases[].id' "$CORPUS")"
  local id
  for id in $ids; do
    local c; c="$(jq -c --arg id "$id" '.cases[] | select(.id==$id)' "$CORPUS")"
    [[ -n "$filter_case" && "$id" != "$filter_case" ]] && continue
    local cls; cls="$(printf '%s' "$c" | jq -r '.class')"
    [[ -n "$filter_class" && "$cls" != "$filter_class" ]] && continue

    local r; r="$(adv__dispatch "$c")"
    local result="${r%%$'\t'*}" actual="${r#*$'\t'}"
    total=$(( total + 1 ))
    if [[ "$result" == "PASS" ]]; then passed=$(( passed + 1 )); else failed=$(( failed + 1 )); fi
    results="$(jq -cn --argjson acc "$results" --arg id "$id" --arg class "$cls" \
      --arg kind "$(printf '%s' "$c" | jq -r '.kind')" --arg result "$result" \
      --argjson actual "$actual" --arg why "$(printf '%s' "$c" | jq -r '.why // ""')" \
      --argjson expect "$(printf '%s' "$c" | jq -c '.expect')" \
      '$acc + [{id:$id, class:$class, kind:$kind, result:$result, expected:$expect, actual:$actual, why:$why}]')"
    if [[ "$result" != "PASS" ]]; then
      log_error "FAIL $id ($cls/$(printf '%s' "$c" | jq -r '.kind')): $(printf '%s' "$actual" | jq -c .)"
    fi
  done

  local report
  report="$(jq -cn --arg schema "claudeos.adversarial-report/v1" --arg at "$(adv__iso)" \
    --argjson total "$total" --argjson passed "$passed" --argjson failed "$failed" \
    --argjson cases "$results" --arg corpus "$CORPUS" \
    '{schema:$schema, generated_at:$at, corpus:$corpus, total:$total, passed:$passed, failed:$failed,
      result:(if $failed==0 then "PASS" else "FAIL" end), cases:$cases}')"

  if [[ -n "$out_file" ]]; then
    mkdir -p "$(dirname "$out_file")"
    printf '%s\n' "$report" | jq . > "$out_file"
  fi
  if (( as_json )); then
    printf '%s\n' "$report" | jq -c .
  else
    printf '%s\n' "$report" | jq -r '"adversarial-probe: \(.result)  total=\(.total) passed=\(.passed) failed=\(.failed)"'
    printf '%s\n' "$report" | jq -r '.cases[] | "  \(.result)  \(.id)\t\(.class)"'
  fi
  (( failed == 0 )) && return 0 || return 1
}

main "$@"
