#!/usr/bin/env bash
# ============================================================
# diag-control-plane.sh — Control Plane (claudeos_control) 運用診断 (ClaudeOS v11)
#
# 表示: 接続性 / run 状況 (実行中・stale・24h succeeded・24h failed) /
#       承認待ち件数 / 直近24hの eval FAIL・BLOCKED件数 / 24hのモデルコスト /
#       登録 agent 数。
#   --json   Mission Control 向け JSON (scripts/dashboards/serve-dashboard.js が読む)
# 秘密 (パスワード / 接続文字列) は一切表示しない (そもそも存在しない設計)。
# ============================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
# shellcheck source=lib/postgres.sh
source "$SCRIPT_DIR/../lib/postgres.sh"
# shellcheck source=lib/control-db.sh
source "$SCRIPT_DIR/../lib/control-db.sh"

main() {
  local json=0; [[ "${1:-}" == "--json" ]] && json=1
  local s; s="$(ctl__dashboard_json)"

  if (( json )); then
    printf '%s\n' "$s"
    return 0
  fi

  log_info "Control Plane 運用診断 (ClaudeOS v11, db=$CTL_DB)"
  if [[ "$(jq -r .health <<<"$s" 2>/dev/null)" == "true" ]]; then
    printf '\n  health  : %sOK%s\n' "$C_GREEN" "$C_RESET"
  else
    printf '\n  health  : %sNG (claudeos_control に接続できません)%s\n' "$C_RED" "$C_RESET"
  fi
  printf '  runs    : total=%s running=%s stale_pending_reconcile=%s succeeded_24h=%s failed_24h=%s\n' \
    "$(jq -r '.stats.runs_total // "-"' <<<"$s")" \
    "$(jq -r '.stats.runs_running // "-"' <<<"$s")" \
    "$(jq -r '.stats.runs_stale_pending_reconcile // "-"' <<<"$s")" \
    "$(jq -r '.stats.runs_succeeded_24h // "-"' <<<"$s")" \
    "$(jq -r '.stats.runs_failed_24h // "-"' <<<"$s")"
  printf '  承認    : pending=%s actionable=%s\n' \
    "$(jq -r '.stats.approvals_pending // "-"' <<<"$s")" \
    "$(jq -r '.stats.approvals_actionable // "-"' <<<"$s")"
  printf '  evals   : fail_or_blocked(24h)=%s\n' "$(jq -r '.stats.eval_results_24h_fail // "-"' <<<"$s")"
  local micro; micro="$(jq -r '.stats.cost_micro_usd_24h // 0' <<<"$s")"
  printf '  cost    : 24h=$%s\n' "$(awk -v m="$micro" 'BEGIN{printf "%.4f", m/1000000}' 2>/dev/null || printf '%s micro-USD' "$micro")"
  printf '  agents  : registered=%s\n\n' "$(jq -r '.stats.agents_registered // "-"' <<<"$s")"
  printf '  操作: bin/control-db.sh reconcile|approval-check|dashboard\n\n'
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
