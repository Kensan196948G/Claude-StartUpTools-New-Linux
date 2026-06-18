#!/usr/bin/env bash
# ============================================================
# maintenance-mode.sh — 保守モードへ移行 (メニュー項M)
# 移植元: scripts/main/Start-MaintenanceMode.ps1
#   state.maintenance.phase_mode=maintenance / project.phase_mode=maintenance / released_at
# ============================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
# shellcheck source=lib/json.sh
source "$SCRIPT_DIR/../lib/json.sh"

STATE="${CCSU_STATE_FILE:-$CCSU_ROOT/state.json}"

main() {
  local yes=0 dry_run=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --yes) yes=1; shift ;;
      --dry-run) dry_run=1; shift ;;
      *) log_error "不明な引数: $1"; exit 1 ;;
    esac
  done

  if (( yes == 0 && dry_run == 0 )); then
    local c; read -rp "  保守モードへ移行します。デプロイ完了を確認済みですか？ (y/N): " c
    [[ "${c^^}" == "Y" ]] || { log_info "キャンセルしました"; return 0; }
  fi

  local now; now="$(date -Iseconds)"
  if (( dry_run )); then
    log_info "dry-run: phase_mode=maintenance / released_at=$now を設定予定"
    log_info "dry-run: 書き込みは行いません: $STATE"
    return 0
  fi
  json_set "$STATE" \
    '.maintenance.phase_mode = "maintenance" | .project.phase_mode = "maintenance" | .maintenance.released_at = $t' \
    --arg t "$now"
  log_ok "保守モードへ移行: phase_mode=maintenance / released_at=$now"
  log_info "以降は maintenance-loop (Monitor→Triage→Fix→Verify→Deploy) で運用されます"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
