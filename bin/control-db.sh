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
#   control-db.sh approval-request --category c --subject-kind k --subject-ref r
#     --object-sha256 h --requested-by u [--required-approvals 1|2] [--required-role role] [--ttl-hours N]
#   control-db.sh approval-decide --approval-id id --approver a --approver-role role --decision Y|N --object-sha256 h
#   control-db.sh approval-check --approval-id id [--observed-sha256 h]
#   control-db.sh eval-define --key k --kind golden|regression|security|outcome|performance|smoke --title t [--required]
#   control-db.sh eval-record --key k --verdict PASS|FAIL|BLOCKED|NOT_RUN
#   control-db.sh usage-record --model-id id [--input-tokens n] [--output-tokens n] [--cost-micro-usd n]
#   control-db.sh project-register --key k [--display-name n] [--repo-path p] [--remote-slug o/r]
#   control-db.sh run-start --project-key k [--run-kind k] [--lease-owner o]
#   control-db.sh run-heartbeat --run-id id
#   control-db.sh run-finish --run-id id --status succeeded|failed|cancelled|blocked
#   control-db.sh agent-register --name n [--kind k] [--execution-plane p] [--verifier]
#   control-db.sh agent-assign --project-key k --run-id id --agent-name n [--path-scope p]
#   control-db.sh agent-release --assignment-id id
#   control-db.sh handoff-offer --run-id id --to-agent-name n --summary s
#   control-db.sh handoff-accept --handoff-id id
#   control-db.sh dashboard [db]
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
    approval-request)    ctl__approval_request "$@" ;;
    approval-decide)     ctl__approval_decide "$@" ;;
    approval-check)      ctl__approval_check "$@" ;;
    eval-define)         ctl__eval_define "$@" ;;
    eval-record)         ctl__eval_record "$@" ;;
    usage-record)        ctl__usage_record "$@" ;;
    project-register)    ctl__project_register "$@" ;;
    run-start)           ctl__run_start "$@" ;;
    run-heartbeat)       ctl__run_heartbeat "$@" ;;
    run-finish)          ctl__run_finish "$@" ;;
    agent-register)      ctl__agent_register "$@" ;;
    agent-assign)        ctl__agent_assign "$@" ;;
    agent-release)       ctl__agent_release "$@" ;;
    handoff-offer)       ctl__handoff_offer "$@" ;;
    handoff-accept)      ctl__handoff_accept "$@" ;;
    dashboard)           ctl__dashboard_json "${1:-}" ;;
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
