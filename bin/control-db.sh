#!/usr/bin/env bash
# ============================================================
# control-db.sh — claudeos_control Control Plane 運用 CLI (ClaudeOS v11)
#
# 使い方:
#   control-db.sh health [db]
#   control-db.sh init [--db d] [--role-prefix p] [--grant-to role] [--dry-run]
#   control-db.sh migrate [--db d] [--dir path] [--dry-run] [--allow-destructive v1,v2]
#   control-db.sh migration-status [--db d] [--dir path] [--json]
#   control-db.sh status
#   control-db.sh grants [db]
#
# 既定 db: $CTL_DB (= claudeos_control)。既定 migrations dir: db/control/migrations。
# ロールは claudeos_control_{migrator,app,ro,audit} (NOLOGIN グループロール)。
# パスワード・接続文字列は一切扱わない (docs/architecture/ControlPlaneデータ基盤仕様.md)。
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
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    health)            ctl__health "${1:-}" ;;
    init)               ctl__init "$@" ;;
    migrate)            ctl__migrate "$@" ;;
    migration-status)    ctl__migration_status "$@" ;;
    status)              ctl__status_json ;;
    grants)              ctl__grant_matrix "${1:-}" ;;
    -h|--help|"") sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' ;;
    *) die "不明なコマンド: $cmd" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
