#!/usr/bin/env bash
# ============================================================
# pg-ops.sh — Local PostgreSQL 運用 CLI (ClaudeOS v10)
#
# 使い方:
#   pg-ops.sh health [db]                          pg_isready + ディスク
#   pg-ops.sh init <project> [--role r] [--db d] [--password-file f]
#   pg-ops.sh backup <db> [dir] [--retention-days N]
#   pg-ops.sh verify <backup-file>
#   pg-ops.sh restore-drill <db> [backup-file] [--keep]
#   pg-ops.sh freshness <db> [dir] [max-hours]
#   pg-ops.sh migration-risk <path>
#   pg-ops.sh status <db> [dir] [--json]
#   pg-ops.sh units <project> <db> [--install]     systemd backup/drill unit を生成 (--install で sudo 配置+timer 有効化)
#
# 既定 dir: $CCSU_PG_BACKUP_ROOT/<db> (= /var/backups/claudeos/<db>)。値 (パスワード / URL) は出力しない。
# ============================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
# shellcheck source=lib/postgres.sh
source "$SCRIPT_DIR/../lib/postgres.sh"

pgops__dir() { printf '%s' "${2:-$CCSU_PG_BACKUP_ROOT/$1}"; }

pgops__render_units() {
  local project="$1" db="$2" install="${3:-0}"
  local tdir="$CCSU_ROOT/Claude/templates/linux" out="${CCSU_PG_UNITS_DIR:-$CCSU_HOME/units}"
  local pgbin; pgbin="$(pg__bin_dir)"; [[ -n "$pgbin" ]] || pgbin="/usr/lib/postgresql/16/bin"
  mkdir -p "$out"
  local f name
  for f in pg-backup.service pg-backup.timer pg-restore-drill.service pg-restore-drill.timer; do
    [[ -f "$tdir/$f.tmpl" ]] || { log_error "テンプレートがありません: $tdir/$f.tmpl"; return 1; }
    name="claudeos-${project}-${f}"
    sed -e "s|@PROJECT@|$project|g" -e "s|@DB@|$db|g" -e "s|@USER@|$USER|g" -e "s|@CCSU_ROOT@|$CCSU_ROOT|g" \
        -e "s|@PG_BIN@|$pgbin|g" -e "s|@BACKUP_DIR@|$CCSU_PG_BACKUP_ROOT/$db|g" -e "s|@HOME@|$HOME|g" \
        "$tdir/$f.tmpl" > "$out/$name"
    printf '%s\n' "$out/$name"
  done
  if (( install )); then
    require_cmd sudo
    log_info "systemd unit を /etc/systemd/system へ配置します (sudo)"
    sudo mkdir -p "$CCSU_PG_BACKUP_ROOT/$db" && sudo chown "$USER:$USER" "$CCSU_PG_BACKUP_ROOT/$db" && sudo chmod 700 "$CCSU_PG_BACKUP_ROOT/$db"
    for f in pg-backup.service pg-backup.timer pg-restore-drill.service pg-restore-drill.timer; do
      sudo cp "$out/claudeos-${project}-${f}" "/etc/systemd/system/claudeos-${project}-${f}"
    done
    sudo systemctl daemon-reload
    sudo systemctl enable --now "claudeos-${project}-pg-backup.timer" "claudeos-${project}-pg-restore-drill.timer"
    log_ok "timer 有効化: claudeos-${project}-pg-backup.timer / claudeos-${project}-pg-restore-drill.timer"
  else
    log_info "生成のみ (--install で配置)。内容を確認してから導入してください。"
  fi
}

main() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    health)
      local db="${1:-postgres}"
      if pg__health "$db"; then log_ok "PostgreSQL accepting connections (db=$db, host=$PGHOST, bin=$(pg__bin_dir))"; else log_error "PostgreSQL に接続できません (db=$db)"; return 1; fi
      local pct avail; IFS=$'\t' read -r pct avail < <(pg__disk)
      printf '  disk: used=%s%% avail=%s\n' "$pct" "$avail"
      if [[ -n "$pct" ]] && (( pct >= 90 )); then log_warn "ディスク使用率 ${pct}% (>=90%)"; return 1; fi
      ;;
    init)        [[ -n "${1:-}" ]] || die "init <project> が必要です"; pg__init_project "$@" ;;
    backup)      local db="${1:-}"; [[ -n "$db" ]] || die "backup <db> が必要です"; local dir; dir="$(pgops__dir "$db" "${2:-}")"; shift; [[ $# -gt 0 && "${1:-}" != --* ]] && shift
                 local f; f="$(pg__backup "$db" "$dir" "$@")" && log_ok "backup: $f" ;;
    verify)      [[ -n "${1:-}" ]] || die "verify <file> が必要です"; pg__verify_backup "$1" && log_ok "verify PASS" ;;
    restore-drill) local db="${1:-}"; [[ -n "$db" ]] || die "restore-drill <db> が必要です"; shift
                 local file="${1:-}"; if [[ -n "$file" && "$file" != --* ]]; then shift; else file="$(pgops__dir "$db")/latest.dump"; fi
                 pg__restore_drill "$db" "$file" "$@" ;;
    freshness)   local db="${1:-}"; [[ -n "$db" ]] || die "freshness <db> が必要です"; pg__backup_freshness "$(pgops__dir "$db" "${2:-}")" "$db" "${3:-26}" ;;
    migration-risk) [[ -n "${1:-}" ]] || die "migration-risk <path> が必要です"; pg__migration_risk "$1" ;;
    status)      local db="${1:-}"; [[ -n "$db" ]] || die "status <db> が必要です"; local dir; dir="$(pgops__dir "$db" "${2:-}")"
                 if [[ "${2:-}" == "--json" || "${3:-}" == "--json" ]]; then [[ "${2:-}" == "--json" ]] && dir="$(pgops__dir "$db")"; pg__status_json "$db" "$dir"; else pg__status_json "$db" "$dir" | jq . 2>/dev/null || pg__status_json "$db" "$dir"; fi ;;
    units)       [[ -n "${1:-}" && -n "${2:-}" ]] || die "units <project> <db> [--install] が必要です"; local inst=0; [[ "${3:-}" == "--install" ]] && inst=1; pgops__render_units "$1" "$2" "$inst" ;;
    -h|--help|"") sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' ;;
    *) die "不明なコマンド: $cmd" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
