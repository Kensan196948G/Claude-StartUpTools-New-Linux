#!/usr/bin/env bash
# ============================================================
# postgres.sh — Local PostgreSQL 運用ライブラリ (ClaudeOS v10)
#
# 方針: Local PostgreSQL (systemd postgresql@<ver>-main, Unix socket) を正本 DB とし、
#       Neon 等の managed DB に依存しない。全関数は純粋関数寄りで bats から
#       PATH スタブ (pg_dump / pg_restore / psql / pg_isready / pg_lsclusters) で密閉可能。
#
# 主な関数:
#   pg__bin_dir                         → サーバ版に合う client bin dir (PG_BIN 優先)
#   pg__cmd <tool>                      → 実行パス
#   pg__health [db]                     → pg_isready (0/1)
#   pg__disk [path]                     → "used_pct<TAB>avail" を出力
#   pg__db_exists <db> / pg__role_exists <role>
#   pg__init_project <name> [--role r] [--db d] [--password-file f]
#   pg__backup <db> <dir> [--retention-days N] [--prefix p]
#   pg__verify_backup <file>            → sha256 + pg_restore --list
#   pg__prune_backups <dir> <prefix> <days>
#   pg__backup_freshness <dir> <prefix> <max_age_hours>
#   pg__restore_drill <db> <backup_file> [--recovery-db n] [--keep]
#   pg__migration_risk <path>           → 破壊的 SQL 検出 (HUMAN_APPROVAL)
#   pg__status_json <db> <dir> [prefix] → Mission Control 用 JSON
#
# 環境変数:
#   PG_BIN            client bin dir を強制 (systemd unit は必ず指定する)
#   PGHOST            既定 /var/run/postgresql (socket)
#   CCSU_PG_STATE_DIR ドリル結果等の記録先 (既定 $CCSU_HOME/pg)
#   CCSU_PG_BACKUP_ROOT 既定バックアップ root (既定 /var/backups/claudeos)
#
# 安全規約:
#   - パスワード / DATABASE_URL の値を stdout・ログへ出さない
#   - restore drill の対象 DB 名は必ず *_recovery (本番 DB へ復元しない)
#   - DROP / TRUNCATE / 大量 DELETE は pg__migration_risk で HUMAN_APPROVAL 扱い
# ============================================================

[[ -n "${_CCSU_POSTGRES_LOADED:-}" ]] && return 0
_CCSU_POSTGRES_LOADED=1

: "${PGHOST:=/var/run/postgresql}"
export PGHOST
: "${CCSU_PG_BACKUP_ROOT:=/var/backups/claudeos}"

_pg__state_dir() { printf '%s' "${CCSU_PG_STATE_DIR:-${CCSU_HOME:-$HOME/.claudeos}/pg}"; }
_pg__log() { if declare -F log_info >/dev/null 2>&1; then log_info "$@"; else printf '[pg] %s\n' "$*"; fi; }
_pg__warn() { if declare -F log_warn >/dev/null 2>&1; then log_warn "$@"; else printf '[pg][WARN] %s\n' "$*" >&2; fi; }
_pg__err() { if declare -F log_error >/dev/null 2>&1; then log_error "$@"; else printf '[pg][ERR] %s\n' "$*" >&2; fi; }

# pg__server_version — pg_lsclusters の online クラスタ主版 (例: 16)。不明なら空。
pg__server_version() {
  command -v pg_lsclusters >/dev/null 2>&1 || return 1
  pg_lsclusters 2>/dev/null | awk 'NR>1 && $4=="online" {print $1; exit}'
}

# pg__bin_dir — PG_BIN > /usr/lib/postgresql/<server-ver>/bin > pg_config --bindir > PATH
pg__bin_dir() {
  if [[ -n "${PG_BIN:-}" ]]; then printf '%s' "$PG_BIN"; return 0; fi
  local v; v="$(pg__server_version 2>/dev/null || true)"
  if [[ -n "$v" && -x "/usr/lib/postgresql/$v/bin/pg_dump" ]]; then printf '/usr/lib/postgresql/%s/bin' "$v"; return 0; fi
  if command -v pg_config >/dev/null 2>&1; then pg_config --bindir 2>/dev/null && return 0; fi
  printf ''
}

# pg__cmd <tool> — bin dir 付きパス (bin dir 不明なら PATH 上の名前)
pg__cmd() {
  local dir; dir="$(pg__bin_dir)"
  if [[ -n "$dir" && -x "$dir/$1" ]]; then printf '%s/%s' "$dir" "$1"; else printf '%s' "$1"; fi
}

# pg__health [db] — pg_isready。0=accepting / 1=否
pg__health() {
  local db="${1:-postgres}"
  "$(pg__cmd pg_isready)" -h "$PGHOST" -d "$db" -q 2>/dev/null
}

# pg__disk [path] — "used_pct<TAB>avail_human" (df -P 準拠)
pg__disk() {
  local p="${1:-/var/lib/postgresql}"
  [[ -e "$p" ]] || p="/"
  df -Pk "$p" 2>/dev/null | awk 'NR==2 { pct=$5; sub(/%/,"",pct); avail=$4; printf "%s\t%.1fG\n", pct, avail/1024/1024 }'
}

pg__db_exists()   { [[ "$("$(pg__cmd psql)" -h "$PGHOST" -d postgres -Atqc "select 1 from pg_database where datname='${1//\'/\'\'}'" 2>/dev/null)" == "1" ]]; }
pg__role_exists() { [[ "$("$(pg__cmd psql)" -h "$PGHOST" -d postgres -Atqc "select 1 from pg_roles where rolname='${1//\'/\'\'}'" 2>/dev/null)" == "1" ]]; }

# _pg__ident <name> — DB/role 識別子の妥当性 (小文字英数と _ のみ、先頭英字)
_pg__ident() { [[ "$1" =~ ^[a-z][a-z0-9_]{0,62}$ ]]; }

# pg__init_project <name> [--role r] [--db d] [--password-file f]
#   専用 role (LOGIN, NOSUPERUSER, NOCREATEDB) と専用 DB (owner=role) を作成し、public への
#   CREATE を revoke する (least privilege)。password-file (0600) があれば ALTER ROLE PASSWORD。
#   既存 role/db は変更しない (冪等)。DATABASE_URL は値を出さず、形式だけ案内する。
pg__init_project() {
  local name="$1"; shift
  local role="" db="" pwfile=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --role) role="$2"; shift 2 ;;
      --db) db="$2"; shift 2 ;;
      --password-file) pwfile="$2"; shift 2 ;;
      *) _pg__err "pg__init_project: 不明な引数 $1"; return 2 ;;
    esac
  done
  local base; base="$(printf '%s' "$name" | tr 'A-Z-' 'a-z_' | tr -c 'a-z0-9_\n' '_')"
  role="${role:-${base}_app}"; db="${db:-$base}"
  _pg__ident "$role" && _pg__ident "$db" || { _pg__err "識別子が不正です: role=$role db=$db"; return 2; }
  local psql; psql="$(pg__cmd psql)"
  if pg__role_exists "$role"; then _pg__log "role 既存: $role (変更なし)"; else
    "$psql" -h "$PGHOST" -d postgres -v ON_ERROR_STOP=1 -qc "CREATE ROLE \"$role\" LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT" || return 1
    _pg__log "role 作成: $role"
  fi
  if [[ -n "$pwfile" ]]; then
    [[ -f "$pwfile" ]] || { _pg__err "password-file がありません: $pwfile"; return 2; }
    local perm; perm="$(stat -c '%a' "$pwfile" 2>/dev/null || echo 600)"
    [[ "$perm" == "600" || "$perm" == "400" ]] || _pg__warn "password-file の権限が $perm です (0600 推奨)"
    "$psql" -h "$PGHOST" -d postgres -v ON_ERROR_STOP=1 -q -v pw="$(head -1 "$pwfile")" -c "ALTER ROLE \"$role\" PASSWORD :'pw'" || return 1
    _pg__log "role パスワード設定: $role (値は表示しません)"
  fi
  if pg__db_exists "$db"; then _pg__log "database 既存: $db (変更なし)"; else
    "$psql" -h "$PGHOST" -d postgres -v ON_ERROR_STOP=1 -qc "CREATE DATABASE \"$db\" OWNER \"$role\" ENCODING 'UTF8' TEMPLATE template0" || return 1
    "$psql" -h "$PGHOST" -d "$db" -v ON_ERROR_STOP=1 -qc "REVOKE CREATE ON SCHEMA public FROM PUBLIC; REVOKE ALL ON DATABASE \"$db\" FROM PUBLIC" || return 1
    _pg__log "database 作成: $db (owner=$role, public CREATE revoke 済)"
  fi
  printf 'DATABASE_URL 形式: postgresql://%s:<password>@localhost/%s?host=%s (値は .env / systemd EnvironmentFile (0600) に置き Git へ入れない)\n' "$role" "$db" "$PGHOST"
}

# pg__backup <db> <dir> [--retention-days N] [--prefix p]
#   pg_dump -Fc → <dir>/<prefix>-<UTC ts>.dump + .sha256、latest.dump symlink、pg_restore --list で妥当性確認、retention prune。
#   成功時はファイルパスを stdout に出力。
pg__backup() {
  local db="$1" dir="$2"; shift 2
  local retention=14 prefix="$db"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --retention-days) retention="$2"; shift 2 ;;
      --prefix) prefix="$2"; shift 2 ;;
      *) _pg__err "pg__backup: 不明な引数 $1"; return 2 ;;
    esac
  done
  [[ -n "$db" && -n "$dir" ]] || { _pg__err "pg__backup: db と dir は必須"; return 2; }
  mkdir -p "$dir" || return 1
  local old_umask; old_umask="$(umask)"; umask 077
  local ts file; ts="$(date -u +%Y%m%dT%H%M%SZ)"; file="$dir/${prefix}-${ts}.dump"
  if ! "$(pg__cmd pg_dump)" -h "$PGHOST" -Fc --no-owner --no-privileges -f "$file" "$db" 2>"$file.err"; then
    umask "$old_umask"; _pg__err "pg_dump 失敗: $(head -c 300 "$file.err" 2>/dev/null)"; rm -f "$file"; return 1
  fi
  rm -f "$file.err"
  ( cd "$dir" && sha256sum "$(basename "$file")" > "$(basename "$file").sha256" ) || { umask "$old_umask"; return 1; }
  umask "$old_umask"
  if ! pg__verify_backup "$file" >/dev/null; then _pg__err "作成したバックアップの検証に失敗: $file"; return 1; fi
  ln -sfn "$(basename "$file")" "$dir/latest.dump"
  ln -sfn "$(basename "$file").sha256" "$dir/latest.dump.sha256"
  pg__prune_backups "$dir" "$prefix" "$retention" >/dev/null
  printf '%s\n' "$file"
}

# pg__verify_backup <file> — sha256 一致 + pg_restore --list 成功で 0。「存在するだけ」は成功扱いにしない。
pg__verify_backup() {
  local file="$1"
  [[ -s "$file" ]] || { _pg__err "バックアップが存在しないか空です: $file"; return 1; }
  if [[ -f "$file.sha256" ]]; then
    ( cd "$(dirname "$file")" && sha256sum -c --quiet "$(basename "$file").sha256" ) >/dev/null 2>&1 || { _pg__err "sha256 不一致: $file"; return 1; }
  else
    _pg__warn "sha256 ファイルがありません: $file.sha256"
  fi
  local n; n="$("$(pg__cmd pg_restore)" --list "$file" 2>/dev/null | grep -cvE '^;|^$' || true)"
  [[ "${n:-0}" -gt 0 ]] || { _pg__err "pg_restore --list が空 / 失敗: $file"; return 1; }
  printf 'verified: %s (toc entries=%s)\n' "$file" "$n"
}

# pg__prune_backups <dir> <prefix> <days> — retention 超過分を削除 (削除数を出力)
pg__prune_backups() {
  local dir="$1" prefix="$2" days="$3"
  [[ "$days" =~ ^[0-9]+$ ]] || { _pg__err "retention days が不正: $days"; return 2; }
  [[ -d "$dir" ]] || { printf '0\n'; return 0; }
  local n=0 f
  while IFS= read -r f; do
    rm -f "$f" "$f.sha256"; n=$((n + 1))
  done < <(find "$dir" -maxdepth 1 -type f -name "${prefix}-*.dump" -mtime "+${days}" 2>/dev/null)
  printf '%s\n' "$n"
}

# pg__backup_freshness <dir> <prefix> <max_age_hours> — 最新バックアップが期限内で検証可なら 0
pg__backup_freshness() {
  local dir="$1" prefix="$2" max_h="${3:-26}"
  local latest; latest="$(find "$dir" -maxdepth 1 -type f -name "${prefix}-*.dump" -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2-)"
  [[ -n "$latest" ]] || { _pg__err "バックアップがありません: $dir/${prefix}-*.dump"; return 1; }
  local age_h; age_h=$(( ( $(date +%s) - $(stat -c %Y "$latest") ) / 3600 ))
  if (( age_h > max_h )); then _pg__err "バックアップが古い: ${age_h}h > ${max_h}h ($latest)"; return 1; fi
  pg__verify_backup "$latest" >/dev/null || return 1
  printf 'fresh: %s (age=%sh)\n' "$latest" "$age_h"
}

# pg__restore_drill <db> <backup_file> [--recovery-db name] [--keep]
#   *_recovery DB へ実際に pg_restore し、テーブル数と各テーブル行数を元 DB と比較する。
#   結果を $state/drill-<db>.json へ記録。PASS で 0。復元先は既定で削除 (--keep で保持)。
pg__restore_drill() {
  local db="$1" file="$2"; shift 2
  local rdb="${db}_recovery" keep=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --recovery-db) rdb="$2"; shift 2 ;;
      --keep) keep=1; shift ;;
      *) _pg__err "pg__restore_drill: 不明な引数 $1"; return 2 ;;
    esac
  done
  [[ "$rdb" == *_recovery ]] || { _pg__err "復元先 DB 名は *_recovery に限定します: $rdb"; return 2; }
  [[ "$rdb" != "$db" ]] || { _pg__err "復元先と元 DB が同一です"; return 2; }
  pg__verify_backup "$file" >/dev/null || return 1
  local psql pgr; psql="$(pg__cmd psql)"; pgr="$(pg__cmd pg_restore)"
  local started; started="$(date -Iseconds)"
  "$psql" -h "$PGHOST" -d postgres -v ON_ERROR_STOP=1 -qc "DROP DATABASE IF EXISTS \"$rdb\"" || return 1
  "$psql" -h "$PGHOST" -d postgres -v ON_ERROR_STOP=1 -qc "CREATE DATABASE \"$rdb\" TEMPLATE template0" || return 1
  local rc=0 result="PASS" detail=""
  mkdir -p "$(_pg__state_dir)"
  local errf; errf="$(_pg__state_dir)/drill-${db}.err"
  if ! "$pgr" -h "$PGHOST" --no-owner --no-privileges --exit-on-error -d "$rdb" "$file" >/dev/null 2>"$errf"; then
    result="FAIL"; detail="pg_restore failed: $(head -c 200 "$errf" | tr '\n' ' ')"; rc=1
  fi
  local q_tables="select count(*) from information_schema.tables where table_schema not in ('pg_catalog','information_schema')"
  local src_t rec_t
  if [[ "$result" == "PASS" ]]; then
    src_t="$("$psql" -h "$PGHOST" -d "$db" -Atqc "$q_tables" 2>/dev/null || echo '?')"
    rec_t="$("$psql" -h "$PGHOST" -d "$rdb" -Atqc "$q_tables" 2>/dev/null || echo '?')"
    if [[ "$src_t" != "$rec_t" ]]; then result="FAIL"; detail="table count mismatch src=$src_t rec=$rec_t"; rc=1; fi
  fi
  local mismatch=0
  if [[ "$result" == "PASS" ]]; then
    local t sc rc2
    while IFS= read -r t; do
      [[ -n "$t" ]] || continue
      sc="$("$psql" -h "$PGHOST" -d "$db" -Atqc "select count(*) from $t" 2>/dev/null || echo '?')"
      rc2="$("$psql" -h "$PGHOST" -d "$rdb" -Atqc "select count(*) from $t" 2>/dev/null || echo '?')"
      [[ "$sc" == "$rc2" ]] || { mismatch=$((mismatch + 1)); detail+="$t src=$sc rec=$rc2; "; }
    done < <("$psql" -h "$PGHOST" -d "$db" -Atqc "select quote_ident(table_schema)||'.'||quote_ident(table_name) from information_schema.tables where table_schema not in ('pg_catalog','information_schema') and table_type='BASE TABLE'" 2>/dev/null)
    (( mismatch == 0 )) || { result="FAIL"; rc=1; }
  fi
  if (( ! keep )); then
    "$psql" -h "$PGHOST" -d postgres -qc "DROP DATABASE IF EXISTS \"$rdb\"" >/dev/null 2>&1 || _pg__warn "復元先 DB の削除に失敗: $rdb"
  fi
  mkdir -p "$(_pg__state_dir)"
  printf '{"db":"%s","recovery_db":"%s","backup":"%s","result":"%s","tables_src":"%s","tables_recovery":"%s","row_mismatch":%s,"detail":"%s","started_at":"%s","finished_at":"%s"}\n' \
    "$db" "$rdb" "$file" "$result" "${src_t:-}" "${rec_t:-}" "$mismatch" "${detail//\"/\'}" "$started" "$(date -Iseconds)" > "$(_pg__state_dir)/drill-${db}.json"
  printf 'restore drill %s: db=%s recovery=%s tables=%s/%s row_mismatch=%s%s\n' "$result" "$db" "$rdb" "${src_t:-?}" "${rec_t:-?}" "$mismatch" "${detail:+ ($detail)}"
  return "$rc"
}

# pg__migration_risk <path> — SQL ファイル/ディレクトリから破壊的操作を検出。検出時は一覧を出し 1 (HUMAN_APPROVAL)。
pg__migration_risk() {
  local target="$1"
  [[ -e "$target" ]] || { _pg__err "対象がありません: $target"; return 2; }
  local hits
  hits="$(grep -rniE --include='*.sql' -e '\bdrop[[:space:]]+(table|column|schema|database|index)\b' -e '\btruncate\b' -e '\bdelete[[:space:]]+from\b[^;]*;' -e '\balter[[:space:]]+table\b.*\b(drop|type)\b' "$target" 2>/dev/null | grep -viE 'delete[[:space:]]+from[^;]*\bwhere\b' || true)"
  if [[ -z "$hits" ]]; then printf 'migration-risk: none (additive / backward-compatible)\n'; return 0; fi
  printf 'migration-risk: HUMAN_APPROVAL required — destructive statements detected:\n%s\n' "$hits"
  return 1
}

# pg__status_json <db> <backup_dir> [prefix] — Mission Control 用
pg__status_json() {
  local db="$1" dir="$2" prefix="${3:-$1}"
  local health=false size="" latest="" age_h="" fresh=false drill="{}" used_pct="" avail=""
  pg__health "$db" && health=true
  size="$("$(pg__cmd psql)" -h "$PGHOST" -d postgres -Atqc "select pg_size_pretty(pg_database_size('${db//\'/\'\'}'))" 2>/dev/null || true)"
  latest="$(find "$dir" -maxdepth 1 -type f -name "${prefix}-*.dump" -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2-)"
  if [[ -n "$latest" ]]; then age_h=$(( ( $(date +%s) - $(stat -c %Y "$latest") ) / 3600 )); pg__backup_freshness "$dir" "$prefix" 26 >/dev/null 2>&1 && fresh=true; fi
  [[ -f "$(_pg__state_dir)/drill-${db}.json" ]] && drill="$(cat "$(_pg__state_dir)/drill-${db}.json")"
  IFS=$'\t' read -r used_pct avail < <(pg__disk 2>/dev/null || printf '\t')
  printf '{"db":"%s","health":%s,"size":"%s","latest_backup":"%s","backup_age_hours":"%s","backup_fresh":%s,"disk_used_pct":"%s","disk_avail":"%s","last_drill":%s}\n' \
    "$db" "$health" "$size" "$latest" "$age_h" "$fresh" "$used_pct" "$avail" "$drill"
}
