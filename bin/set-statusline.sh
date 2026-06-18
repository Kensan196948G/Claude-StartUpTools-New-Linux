#!/usr/bin/env bash
# ============================================================
# set-statusline.sh — Statusline 設定 (メニュー項12)
# 移植元: scripts/main/Set-Statusline.ps1 + StatuslineManager.psm1
#   ~/.claude/settings.json の statusLine.command を設定
#   重要: statusline は 1 行出力・emoji 非使用 (Agent Teams TUI と競合回避)
# ============================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
# shellcheck source=lib/json.sh
source "$SCRIPT_DIR/../lib/json.sh"

SETTINGS="${CCSU_CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"

main() {
  local dry_run=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) dry_run=1; shift ;;
      *) log_error "不明な引数: $1"; exit 1 ;;
    esac
  done
  log_info "Statusline 設定 (settings.json)"
  local sl_cmd="${CCSU_STATUSLINE_CMD:-node $CCSU_ROOT/scripts/dashboards/statusline.js}"

  if (( dry_run )); then
    if [[ -f "$SETTINGS" ]]; then
      json_valid "$SETTINGS" || { log_error "settings.json が不正な JSON です: $SETTINGS"; exit 1; }
    fi
    log_info "dry-run: statusLine.command を設定予定: $sl_cmd"
    log_info "dry-run: 書き込みは行いません: $SETTINGS"
    return 0
  fi

  mkdir -p "$(dirname "$SETTINGS")"
  [[ -f "$SETTINGS" ]] || echo '{}' > "$SETTINGS"
  json_valid "$SETTINGS" || { log_error "settings.json が不正な JSON です: $SETTINGS"; exit 1; }

  json_set "$SETTINGS" '.statusLine = {type: "command", command: $c}' --arg c "$sl_cmd"
  log_ok "statusLine 設定: $sl_cmd"
  log_info "1 行出力・emoji 非使用を厳守 (Agent Teams TUI との文字化け回避)"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
