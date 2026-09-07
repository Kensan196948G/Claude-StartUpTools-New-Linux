#!/usr/bin/env bash
# ============================================================
# diag-postgres.sh — Local PostgreSQL 運用診断 (メニュー項18 / ClaudeOS v10)
#
# 表示: サーバ版 / client bin / 接続性 / ディスク / バックアップ root 配下の各 DB について
#       最新バックアップ鮮度と restore drill 結果 (~/.claudeos/pg/drill-<db>.json)。
#   --json   Mission Control 向け JSON 配列
# 秘密 (パスワード / DATABASE_URL) は一切表示しない。
# ============================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
# shellcheck source=lib/postgres.sh
source "$SCRIPT_DIR/../lib/postgres.sh"

diagpg__dbs() {
  # バックアップ root 配下のディレクトリ名 = DB 名
  [[ -d "$CCSU_PG_BACKUP_ROOT" ]] || return 0
  find "$CCSU_PG_BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort
}

main() {
  local json=0; [[ "${1:-}" == "--json" ]] && json=1
  if (( json )); then
    local first=1 db
    printf '['
    while IFS= read -r db; do
      [[ -n "$db" ]] || continue
      (( first )) || printf ','
      first=0
      pg__status_json "$db" "$CCSU_PG_BACKUP_ROOT/$db" | tr -d '\n'
    done < <(diagpg__dbs)
    printf ']\n'
    return 0
  fi
  log_info "Local PostgreSQL 運用診断 (ClaudeOS v10)"
  local ver bindir; ver="$(pg__server_version 2>/dev/null || printf 'unknown')"; bindir="$(pg__bin_dir)"
  printf '\n  server     : PostgreSQL %s (socket %s)\n  client bin : %s\n' "$ver" "$PGHOST" "${bindir:-PATH}"
  if pg__health; then printf '  health     : %sOK%s\n' "$C_GREEN" "$C_RESET"; else printf '  health     : %sNG (pg_isready failed)%s\n' "$C_RED" "$C_RESET"; fi
  local pct avail; IFS=$'\t' read -r pct avail < <(pg__disk)
  printf '  disk       : used=%s%% avail=%s\n' "${pct:-?}" "${avail:-?}"
  printf '  backup root: %s\n\n' "$CCSU_PG_BACKUP_ROOT"
  local db n=0 s
  while IFS= read -r db; do
    [[ -n "$db" ]] || continue
    n=$((n + 1))
    s="$(pg__status_json "$db" "$CCSU_PG_BACKUP_ROOT/$db")"
    printf '  🐘 %s\n' "$db"
    printf '     health=%s size=%s backup_fresh=%s age=%sh drill=%s\n' \
      "$(jq -r .health <<<"$s")" "$(jq -r '.size // "-"' <<<"$s")" "$(jq -r .backup_fresh <<<"$s")" \
      "$(jq -r '.backup_age_hours // "-"' <<<"$s")" "$(jq -r '.last_drill.result // "never"' <<<"$s")"
  done < <(diagpg__dbs)
  (( n > 0 )) || printf '  (登録 DB なし。bin/pg-ops.sh init <project> → backup <db> で開始)\n'
  printf '\n  操作: bin/pg-ops.sh health|init|backup|verify|restore-drill|freshness|migration-risk|status|units\n\n'
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
