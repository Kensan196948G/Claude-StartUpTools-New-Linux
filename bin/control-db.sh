#!/usr/bin/env bash
# ============================================================
# control-db.sh — claudeos_control Control Plane 運用 CLI (ClaudeOS v11)
#
# 使い方:
#   control-db.sh health [db]
#   control-db.sh init [--db d] [--role-prefix p] [--grant-to role] [--dry-run]
#   control-db.sh migrate [--db d] [--dir path] [--dry-run] [--allow-destructive v1,v2]
#   control-db.sh migration-status [--db d] [--dir path] [--json]
#   control-db.sh reconcile [--db d] [--reason r] [--dry-run]
#   control-db.sh status
#   control-db.sh grants [db]
#   control-db.sh units <project> <db> [--install]   systemd projection/reconcile unit を生成
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

ctlops__render_units() {
  local project="$1" db="$2" install="${3:-0}"
  local tdir="$CCSU_ROOT/Claude/templates/linux" out="${CCSU_CONTROL_UNITS_DIR:-$CCSU_HOME/units}"
  local pgbin; pgbin="$(pg__bin_dir)"; [[ -n "$pgbin" ]] || pgbin="/usr/lib/postgresql/16/bin"
  mkdir -p "$out"
  local f name
  for f in control-projection.service control-projection.timer control-reconcile.service control-reconcile.timer; do
    [[ -f "$tdir/$f.tmpl" ]] || { log_error "テンプレートがありません: $tdir/$f.tmpl"; return 1; }
    name="claudeos-${project}-${f}"
    sed -e "s|@PROJECT@|$project|g" -e "s|@DB@|$db|g" -e "s|@USER@|$USER|g" -e "s|@CCSU_ROOT@|$CCSU_ROOT|g" \
        -e "s|@PG_BIN@|$pgbin|g" -e "s|@HOME@|$HOME|g" \
        "$tdir/$f.tmpl" > "$out/$name"
    printf '%s\n' "$out/$name"
  done
  if (( install )); then
    require_cmd sudo
    log_info "systemd unit を /etc/systemd/system へ配置します (sudo)"
    for f in control-projection.service control-projection.timer control-reconcile.service control-reconcile.timer; do
      sudo cp "$out/claudeos-${project}-${f}" "/etc/systemd/system/claudeos-${project}-${f}"
    done
    sudo systemctl daemon-reload
    sudo systemctl enable --now "claudeos-${project}-control-projection.timer" "claudeos-${project}-control-reconcile.timer"
    log_ok "timer 有効化: claudeos-${project}-control-projection.timer / claudeos-${project}-control-reconcile.timer"
  else
    log_info "生成のみ (--install で配置)。内容を確認してから導入してください。"
  fi
}

main() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    health)            ctl__health "${1:-}" ;;
    init)               ctl__init "$@" ;;
    migrate)            ctl__migrate "$@" ;;
    migration-status)    ctl__migration_status "$@" ;;
    reconcile)           ctl__reconcile "$@" ;;
    status)              ctl__status_json ;;
    grants)              ctl__grant_matrix "${1:-}" ;;
    units)               [[ -n "${1:-}" && -n "${2:-}" ]] || die "units <project> <db> [--install] が必要です"
                         local inst=0; [[ "${3:-}" == "--install" ]] && inst=1
                         ctlops__render_units "$1" "$2" "$inst" ;;
    -h|--help|"") sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' ;;
    *) die "不明なコマンド: $cmd" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
