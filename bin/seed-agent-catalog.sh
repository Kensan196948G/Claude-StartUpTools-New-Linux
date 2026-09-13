#!/usr/bin/env bash
# ============================================================
# seed-agent-catalog.sh — config/agent-catalog.json を control.agents へ登録する (ClaudeOS v11)
#
# 使い方: bin/seed-agent-catalog.sh [--db d] [--catalog path]
# 冪等 (ctl__agent_register の ON CONFLICT DO UPDATE)。jq が必要。
# ============================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
# shellcheck source=lib/postgres.sh
source "$SCRIPT_DIR/../lib/postgres.sh"
# shellcheck source=lib/control-db.sh
source "$SCRIPT_DIR/../lib/control-db.sh"

require_cmd jq

db="$CTL_DB"
catalog="$CCSU_ROOT/config/agent-catalog.json"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --db) db="$2"; shift 2 ;;
    --catalog) catalog="$2"; shift 2 ;;
    *) die "不明な引数: $1" ;;
  esac
done
[[ -f "$catalog" ]] || die "カタログがありません: $catalog"

# 名前 → agent_kind のヒューリスティックなマッピング (CHECK 制約の語彙に合わせる)。
# 未知の名前は generalist にフォールバックする。
declare -A KIND_MAP=(
  [cto]=cto [manager]=manager [code-reviewer]=reviewer [security-reviewer]=security_reviewer
  [ci-manager]=ci_manager [outcome-grader]=grader [e2e-runner]=e2e [audit-agent]=auditor
  [qa]=qa [architect]=planner [tdd-guide]=generalist [doc-updater]=generalist
  [api-designer]=planner [build-error-resolver]=implementer [database-reviewer]=reviewer
  [performance-reviewer]=reviewer [release-manager]=manager
)
# Generator/Verifier 分離 (AGENT_ORCHESTRATION.md §5) の独立 QA / 監査役に相当する名前。
declare -A VERIFIER_SET=(
  [code-reviewer]=1 [security-reviewer]=1 [outcome-grader]=1 [e2e-runner]=1
  [audit-agent]=1 [qa]=1 [database-reviewer]=1 [performance-reviewer]=1
)

n=0
while IFS= read -r name; do
  [[ -n "$name" ]] || continue
  kind="${KIND_MAP[$name]:-generalist}"
  verifier_flag=()
  [[ -n "${VERIFIER_SET[$name]:-}" ]] && verifier_flag=(--verifier)
  ctl__agent_register --db "$db" --name "$name" --kind "$kind" --execution-plane subagent \
    --instruction-ref "config/agent-catalog.json#${name}" "${verifier_flag[@]}" >/dev/null
  n=$((n + 1))
done < <(jq -r '(.first_class[].name), (.catalog[].name)' "$catalog")

log_ok "agent catalog seed 完了: ${n} 件登録 (db=$db)"
