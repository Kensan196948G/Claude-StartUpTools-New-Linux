#!/usr/bin/env bash
# ============================================================
# control-db.sh — claudeos_control Control Plane 運用ライブラリ (ClaudeOS v11)
#
# 方針: PostgreSQLデータ運用仕様.md の規約 (Unix socket peer 認証、psql CLI 経由、
#       秘密ゼロ) をそのまま踏襲する。lib/postgres.sh の pg__cmd / pg__health /
#       pg__db_exists / pg__role_exists / pg__migration_risk を再利用し、
#       claudeos_control 固有のロール・migration runner だけをここに実装する。
#
# ロールモデル: claudeos_control_{migrator,app,ro,audit} は全て NOLOGIN の
#   グループロール。パスワード・接続文字列は一切生成しない。peer 認証で
#   接続した OS ユーザー相当ロールへ GRANT し、実行時は SET ROLE で権限を
#   落とす (docs/architecture/ControlPlaneデータ基盤仕様.md §4)。
#
# 主な関数:
#   ctl__health [db]                         → 接続 + control スキーマ存在確認
#   ctl__init [--db d] [--role-prefix p] [--grant-to role] [--dry-run]
#   ctl__migrate [--db d] [--dir path] [--dry-run] [--allow-destructive v1,v2]
#   ctl__migration_status [--db d] [--dir path] [--json]
#   ctl__status_json                         → Mission Control 用 (常に rc=0)
#   ctl__grant_matrix [db]                   → 権限一覧 (TSV, 監査用 read-only)
#
# migration runner の規約:
#   - ファイル名は NNNN_name.sql (4 桁通し番号)。違反は rc=2。
#   - control.schema_migrations の checksum と現在のファイルの sha256 が
#     食い違えば checksum drift として rc=4 で全件拒否 (1 件も適用しない)。
#   - 未適用ファイルより番号の大きい版が既に適用済みの場合は順序違反として
#     rc=4 (gap 検出)。
#   - 適用前に pg__migration_risk で破壊的操作を検査する。検出時は
#     --allow-destructive <version[,version...]> で明示許可した版のみ通す。
#   - 各 migration ファイル自身が BEGIN/COMMIT と schema_migrations への
#     INSERT を含む (db/control/migrations/*.sql 参照)。runner は
#     追加のトランザクション制御をしない。
#
# 安全規約:
#   - パスワード / 接続文字列を扱わない (そもそも存在しない設計)
#   - migrator ロールが未作成の場合は SET ROLE をスキップし、現在の
#     接続ロールのまま適用する (bootstrap: DB 作成直後の初回 migrate 用)
# ============================================================

[[ -n "${_CCSU_CONTROLDB_LOADED:-}" ]] && return 0
_CCSU_CONTROLDB_LOADED=1

: "${PGHOST:=/var/run/postgresql}"
export PGHOST
: "${CTL_DB:=claudeos_control}"
: "${CTL_ROLE_PREFIX:=claudeos_control}"

_ctl__mig_dir()   { printf '%s' "${CCSU_CONTROL_MIG_DIR:-${CCSU_ROOT:-.}/db/control/migrations}"; }
_ctl__state_dir() { printf '%s' "${CCSU_CONTROL_STATE_DIR:-${CCSU_HOME:-$HOME/.claudeos}/control-plane}"; }
_ctl__log()  { if declare -F log_info  >/dev/null 2>&1; then log_info  "$@"; else printf '[ctl] %s\n' "$*"; fi; }
_ctl__warn() { if declare -F log_warn  >/dev/null 2>&1; then log_warn  "$@"; else printf '[ctl][WARN] %s\n' "$*" >&2; fi; }
_ctl__err()  { if declare -F log_error >/dev/null 2>&1; then log_error "$@"; else printf '[ctl][ERR] %s\n' "$*" >&2; fi; }

# _ctl__ident <name> — DB/role 識別子の妥当性 (小文字英数と _ のみ、先頭英字)
_ctl__ident() { [[ "$1" =~ ^[a-z][a-z0-9_]{0,62}$ ]]; }

# _ctl__json_array — 標準入力の JSON オブジェクト (1 行 1 個) を配列へ束ねる。jq が無ければ手組み。
_ctl__json_array() {
  if command -v jq >/dev/null 2>&1; then
    jq -s -c '.' 2>/dev/null && return 0
  fi
  local first=1 line out='['
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    if (( first )); then out+="$line"; first=0; else out+=",$line"; fi
  done
  out+=']'
  printf '%s\n' "$out"
}

# ctl__health [db] — 接続可否 + control スキーマの存在を確認する
ctl__health() {
  local db="${1:-$CTL_DB}"
  pg__health "$db" || { _ctl__err "$db に接続できません"; return 1; }
  local exists
  exists="$("$(pg__cmd psql)" -h "$PGHOST" -d "$db" -Atqc \
    "select 1 from information_schema.schemata where schema_name='control'" 2>/dev/null || true)"
  if [[ "$exists" == "1" ]]; then
    _ctl__log "control スキーマ確認済み (db=$db)"
  else
    _ctl__warn "control スキーマが未作成です (db=$db)。ctl__migrate を実行してください"
  fi
}

# ctl__init [--db d] [--role-prefix p] [--grant-to role] [--dry-run]
#   4 つの NOLOGIN グループロールと専用 DB を作成する (冪等)。パスワードは
#   一切扱わない。作成したロールは --grant-to (既定: 現在の OS ユーザー相当
#   ロール) へ GRANT し、SET ROLE で権限を落とせるようにする。
ctl__init() {
  local db="$CTL_DB" role_prefix="$CTL_ROLE_PREFIX" dry_run=0
  local grant_to="${SUDO_USER:-$(id -un 2>/dev/null || printf '%s' "${USER:-postgres}")}"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --db) db="$2"; shift 2 ;;
      --role-prefix) role_prefix="$2"; shift 2 ;;
      --grant-to) grant_to="$2"; shift 2 ;;
      --dry-run) dry_run=1; shift ;;
      *) _ctl__err "ctl__init: 不明な引数 $1"; return 2 ;;
    esac
  done
  _ctl__ident "$db" && _ctl__ident "$role_prefix" && _ctl__ident "$grant_to" \
    || { _ctl__err "識別子が不正です: db=$db role_prefix=$role_prefix grant_to=$grant_to"; return 2; }

  local psql; psql="$(pg__cmd psql)"
  local migrator="${role_prefix}_migrator" app="${role_prefix}_app" ro="${role_prefix}_ro" audit="${role_prefix}_audit"
  local role
  for role in "$migrator" "$app" "$ro" "$audit"; do
    if pg__role_exists "$role"; then
      _ctl__log "role 既存: $role (変更なし)"
    elif (( dry_run )); then
      _ctl__log "[dry-run] role 作成予定: $role (NOLOGIN)"
    else
      "$psql" -h "$PGHOST" -d postgres -v ON_ERROR_STOP=1 -qc \
        "CREATE ROLE \"$role\" NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT" || return 1
      _ctl__log "role 作成: $role (NOLOGIN、パスワードなし)"
    fi
  done

  if (( dry_run )); then
    _ctl__log "[dry-run] GRANT $migrator,$app,$ro,$audit TO $grant_to"
  else
    "$psql" -h "$PGHOST" -d postgres -v ON_ERROR_STOP=1 -qc \
      "GRANT \"$migrator\", \"$app\", \"$ro\", \"$audit\" TO \"$grant_to\"" || return 1
    _ctl__log "role 付与: $migrator/$app/$ro/$audit → $grant_to"
  fi

  if pg__db_exists "$db"; then
    _ctl__log "database 既存: $db (変更なし)"
  elif (( dry_run )); then
    _ctl__log "[dry-run] database 作成予定: $db (owner=$migrator)"
  else
    "$psql" -h "$PGHOST" -d postgres -v ON_ERROR_STOP=1 -qc \
      "CREATE DATABASE \"$db\" OWNER \"$migrator\" ENCODING 'UTF8' TEMPLATE template0" || return 1
    "$psql" -h "$PGHOST" -d "$db" -v ON_ERROR_STOP=1 -qc \
      "REVOKE CREATE ON SCHEMA public FROM PUBLIC; REVOKE ALL ON DATABASE \"$db\" FROM PUBLIC" || return 1
    _ctl__log "database 作成: $db (owner=$migrator, public CREATE revoke 済)"
  fi
  _ctl__log "秘密情報は生成していません (NOLOGIN グループロール + peer 認証 + SET ROLE)"
}

# ctl__migrate [--db d] [--dir path] [--dry-run] [--allow-destructive v1,v2]
#   戻り値: 0=適用成功/対象なし, 1=適用失敗または破壊的操作を拒否,
#           2=引数/命名規約エラー, 3=DB 接続不可, 4=checksum drift または順序違反
ctl__migrate() {
  local db="$CTL_DB" role_prefix="$CTL_ROLE_PREFIX" dir; dir="$(_ctl__mig_dir)"
  local dry_run=0 allow_destructive=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --db) db="$2"; shift 2 ;;
      --dir) dir="$2"; shift 2 ;;
      --role-prefix) role_prefix="$2"; shift 2 ;;
      --dry-run) dry_run=1; shift ;;
      --allow-destructive) allow_destructive="$2"; shift 2 ;;
      *) _ctl__err "ctl__migrate: 不明な引数 $1"; return 2 ;;
    esac
  done
  [[ -d "$dir" ]] || { _ctl__err "migration ディレクトリがありません: $dir"; return 2; }
  pg__health "$db" >/dev/null 2>&1 || { _ctl__err "$db に接続できません"; return 3; }

  local psql; psql="$(pg__cmd psql)"
  local migrator="${role_prefix}_migrator"
  local -a set_role_args=()
  if pg__role_exists "$migrator" 2>/dev/null; then
    set_role_args=(-c "SET ROLE \"$migrator\"")
  else
    _ctl__warn "role $migrator が未作成です。現在の接続ロールのまま適用します (bootstrap)"
  fi

  # 1) ファイル列挙 + 命名規約検査 (NNNN_name.sql)
  local -a files=()
  local f
  while IFS= read -r f; do files+=("$f"); done < <(find "$dir" -maxdepth 1 -type f -name '*.sql' 2>/dev/null | sort)
  (( ${#files[@]} > 0 )) || { _ctl__err "migration ファイルがありません: $dir"; return 2; }

  local -A file_version=() file_checksum=()
  local base
  for f in "${files[@]}"; do
    base="$(basename "$f")"
    if [[ ! "$base" =~ ^([0-9]{4})_[a-z0-9_]+\.sql$ ]]; then
      _ctl__err "命名規約違反: $base (NNNN_name.sql の形式が必要です)"
      return 2
    fi
    file_version["$base"]="${BASH_REMATCH[1]}"
    file_checksum["$base"]="$(sha256sum "$f" | cut -d' ' -f1)"
  done

  # 2) 適用済み一覧取得 (control.schema_migrations 未作成でも空扱い)
  local -A applied_checksum=()
  local ver sum
  while IFS=$'\t' read -r ver sum; do
    [[ -n "$ver" ]] && applied_checksum["$ver"]="$sum"
  done < <("$psql" -h "$PGHOST" -d "$db" -A -t -q -F $'\t' -c \
    "select version, checksum from control.schema_migrations order by version" 2>/dev/null || true)

  # 3) checksum drift + 順序違反 (gap) 検出。1 件でも検出したら全件拒否。
  local -a pending=()
  local seen_pending=0 drift=0
  for f in "${files[@]}"; do
    base="$(basename "$f")"; ver="${file_version[$base]}"
    if [[ -n "${applied_checksum[$ver]:-}" ]]; then
      if [[ "${applied_checksum[$ver]}" != "${file_checksum[$base]}" ]]; then
        _ctl__err "checksum drift 検出: version=$ver file=$base (適用済みチェックサムと不一致)"
        drift=1
      fi
      if (( seen_pending )); then
        _ctl__err "順序違反: version=$ver ($base) はより若い未適用 migration がある状態で既に適用済みです"
        return 4
      fi
    else
      seen_pending=1
      pending+=("$f")
    fi
  done
  (( drift )) && return 4

  if (( ${#pending[@]} == 0 )); then
    _ctl__log "適用対象なし (全て適用済み, db=$db)"
    return 0
  fi

  # 4) 破壊的操作の検査 (未適用ファイルのみ)
  local -a allow_versions=()
  [[ -n "$allow_destructive" ]] && IFS=',' read -ra allow_versions <<< "$allow_destructive"
  for f in "${pending[@]}"; do
    base="$(basename "$f")"; ver="${file_version[$base]}"
    local risk_out risk_rc=0
    risk_out="$(pg__migration_risk "$f")" || risk_rc=$?
    if (( risk_rc != 0 )); then
      local allowed=0 a
      for a in "${allow_versions[@]}"; do [[ "$a" == "$ver" ]] && allowed=1; done
      if (( ! allowed )); then
        _ctl__err "$risk_out"
        _ctl__err "破壊的操作を検出したため適用を拒否します: $base (--allow-destructive $ver で明示許可が必要)"
        return 1
      fi
      _ctl__warn "破壊的操作を --allow-destructive で許可し適用します: $base"
    fi
  done

  if (( dry_run )); then
    _ctl__log "[dry-run] 適用予定: ${#pending[@]} 件 (db=$db)"
    for f in "${pending[@]}"; do printf '  pending: %s\n' "$(basename "$f")"; done
    return 0
  fi

  # 5) 適用 (各ファイル自身が BEGIN/COMMIT と schema_migrations への INSERT を含む)
  for f in "${pending[@]}"; do
    base="$(basename "$f")"; sum="${file_checksum[$base]}"
    _ctl__log "適用中: $base (checksum=${sum:0:12}...)"
    if ! "$psql" -h "$PGHOST" -d "$db" -v ON_ERROR_STOP=1 -v checksum="$sum" "${set_role_args[@]}" -f "$f"; then
      _ctl__err "適用失敗: $base"
      return 1
    fi
    _ctl__log "適用完了: $base"
  done
}

# ctl__migration_status [--db d] [--dir path] [--json]
ctl__migration_status() {
  local db="$CTL_DB" dir; dir="$(_ctl__mig_dir)"
  local json=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --db) db="$2"; shift 2 ;;
      --dir) dir="$2"; shift 2 ;;
      --json) json=1; shift ;;
      *) _ctl__err "ctl__migration_status: 不明な引数 $1"; return 2 ;;
    esac
  done
  local psql; psql="$(pg__cmd psql)"
  local -A applied_checksum=() applied_at=()
  local ver sum at
  while IFS=$'\t' read -r ver sum at; do
    [[ -n "$ver" ]] && { applied_checksum["$ver"]="$sum"; applied_at["$ver"]="$at"; }
  done < <("$psql" -h "$PGHOST" -d "$db" -A -t -q -F $'\t' -c \
    "select version, checksum, applied_at from control.schema_migrations order by version" 2>/dev/null || true)

  local -a files=()
  local f
  while IFS= read -r f; do files+=("$f"); done < <(find "$dir" -maxdepth 1 -type f -name '*.sql' 2>/dev/null | sort)

  local rows="" base ver2 sum2 status2 drift2
  for f in "${files[@]}"; do
    base="$(basename "$f")"
    [[ "$base" =~ ^([0-9]{4})_ ]] || continue
    ver2="${BASH_REMATCH[1]}"
    sum2="$(sha256sum "$f" | cut -d' ' -f1)"
    status2="pending"; drift2=false
    if [[ -n "${applied_checksum[$ver2]:-}" ]]; then
      if [[ "${applied_checksum[$ver2]}" == "$sum2" ]]; then status2="applied"; else status2="drift"; drift2=true; fi
    fi
    rows+="$(printf '{"version":"%s","filename":"%s","status":"%s","drift":%s,"applied_at":"%s"}\n' \
      "$ver2" "$base" "$status2" "$drift2" "${applied_at[$ver2]:-}")"$'\n'
  done
  if (( json )); then
    printf '%s' "$rows" | _ctl__json_array
  else
    printf '%s' "$rows"
  fi
}

# ctl__status_json — Mission Control 用。DB 障害でも常に妥当な JSON を rc=0 で返す。
ctl__status_json() {
  local db="$CTL_DB"
  local health=false role_migrator_exists=false migrations_applied=0 migrations_pending=0 last_migration=""
  pg__health "$db" >/dev/null 2>&1 && health=true
  pg__role_exists "${CTL_ROLE_PREFIX}_migrator" 2>/dev/null && role_migrator_exists=true
  local psql; psql="$(pg__cmd psql)"
  migrations_applied="$("$psql" -h "$PGHOST" -d "$db" -Atqc "select count(*) from control.schema_migrations" 2>/dev/null || true)"
  [[ "$migrations_applied" =~ ^[0-9]+$ ]] || migrations_applied=0
  last_migration="$("$psql" -h "$PGHOST" -d "$db" -Atqc \
    "select version||' '||filename from control.schema_migrations order by version desc limit 1" 2>/dev/null || true)"
  local total_files=0
  total_files="$(find "$(_ctl__mig_dir)" -maxdepth 1 -type f -name '*.sql' 2>/dev/null | wc -l | tr -d ' ')"
  [[ "$total_files" =~ ^[0-9]+$ ]] || total_files=0
  migrations_pending=$(( total_files > migrations_applied ? total_files - migrations_applied : 0 ))
  printf '{"db":"%s","health":%s,"role_migrator_exists":%s,"migrations_applied":%s,"migrations_pending":%s,"last_migration":"%s"}\n' \
    "$db" "$health" "$role_migrator_exists" "$migrations_applied" "$migrations_pending" "${last_migration//\"/}"
  return 0
}

# ctl__grant_matrix [db] — control スキーマの権限一覧 (grantee<TAB>table<TAB>privileges)
ctl__grant_matrix() {
  local db="${1:-$CTL_DB}"
  "$(pg__cmd psql)" -h "$PGHOST" -d "$db" -A -t -q -F $'\t' -c \
    "select grantee, table_name, string_agg(privilege_type, ',' order by privilege_type) from information_schema.table_privileges where table_schema='control' group by grantee, table_name order by grantee, table_name" \
    2>/dev/null
}
