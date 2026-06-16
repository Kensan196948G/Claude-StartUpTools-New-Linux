#!/usr/bin/env bash
# ============================================================
# deploy-launcher.sh — cron-launcher 配備エントリ (恒久ドリフト対策)
#
# cron が実走するのは ~/.claudeos/cron-launcher.sh (配備済み実行体) であり
# リポジトリ内テンプレートではない。PR を merge しても再配備しない限り runtime
# は古いまま (headless 既定化等が反映されない)。本エントリは
# Claude/templates/linux/ の正本を ~/.claudeos へ冪等・非破壊・ローカル限定で
# 同期する (ロジックは lib/deploy-launcher.sh)。
#
# 使い方:
#   bash bin/deploy-launcher.sh            # 差分があれば backup→配備
#   bash bin/deploy-launcher.sh --dry-run  # 配備対象の表示のみ (書き込まない)
#   bash bin/deploy-launcher.sh --help
# ============================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
# shellcheck source=lib/deploy-launcher.sh
source "$SCRIPT_DIR/../lib/deploy-launcher.sh"

_usage() {
  printf '%s\n' \
    "deploy-launcher.sh — テンプレート → ~/.claudeos 配備 (恒久ドリフト対策)" \
    "" \
    "USAGE:" \
    "  bash bin/deploy-launcher.sh [--dry-run] [--help]" \
    "" \
    "OPTIONS:" \
    "  --dry-run   配備対象を表示するだけで書き込まない" \
    "  --help, -h  このヘルプを表示" \
    "" \
    "配備対象: cron-launcher.sh / report-and-mail.py (templates/linux 内)" \
    "配備先  : \$CLAUDEOS_HOME (既定 ~/.claudeos)"
}

main() {
  local dry_run=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) dry_run="--dry-run"; shift ;;
      --help|-h) _usage; exit 0 ;;
      *) log_error "不明な引数: $1"; _usage >&2; exit 1 ;;
    esac
  done

  log_info "🚚 cron-launcher 配備 (テンプレート → $CCSU_HOME)"
  deploy_launcher__apply $dry_run
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
