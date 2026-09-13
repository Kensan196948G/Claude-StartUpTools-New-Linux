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
#   ctl__reconcile [--db d] [--reason r] [--dry-run] → 放棄された run を stale へ遷移
#   ctl__approval_request ... → Human Approval Gate の申請を作成 (承認待ち)
#   ctl__approval_decide  ... → Y/N を記録し、閾値到達で approved/rejected へ遷移
#   ctl__approval_check   ... → 実行可能な承認か判定 (改変検出・期限・承認数を確認)
#   ctl__eval_define / ctl__eval_record → 評価定義の登録 / 結果の記録
#   ctl__usage_record     ... → モデル利用量 (token/cost) の記録
#   ctl__project_register ... → project の冪等登録
#   ctl__run_start / ctl__run_heartbeat / ctl__run_finish → run のライフサイクル
#   ctl__agent_register   ... → agent の冪等登録
#   ctl__agent_assign / ctl__agent_release → 排他 path_scope 付き割当
#   ctl__handoff_offer / ctl__handoff_accept → Agent 間引き継ぎ
#   ctl__dashboard_json   ... → Mission Control 用の集計 JSON (常に rc=0)
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

# _ctl__sqlq <value> — SQL 文字列リテラルへ埋め込む前のエスケープ (単一引用符を二重化)。
#   数値・列挙値は CHECK 制約側で検証させ、ここでは全て文字列として安全側で扱う。
_ctl__sqlq() { printf '%s' "${1//\'/\'\'}"; }

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

# ctl__reconcile [--db d] [--reason r] [--dry-run]
#   control.v_stale_runs (lease 失効または heartbeat 途絶) に該当する run を
#   status='stale' へ遷移させる。すでに終端状態 (succeeded/failed/...) の
#   run は対象外なので、放棄されていない run を誤って上書きすることはない。
#   戻り値: 0=成功 (対象0件も含む), 2=引数エラー, 3=DB 接続不可, 1=更新失敗
ctl__reconcile() {
  local db="$CTL_DB" reason="lease_expired_reconciler" dry_run=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --db) db="$2"; shift 2 ;;
      --reason) reason="$2"; shift 2 ;;
      --dry-run) dry_run=1; shift ;;
      *) _ctl__err "ctl__reconcile: 不明な引数 $1"; return 2 ;;
    esac
  done
  pg__health "$db" >/dev/null 2>&1 || { _ctl__err "$db に接続できません"; return 3; }

  local psql; psql="$(pg__cmd psql)"
  if (( dry_run )); then
    local ids
    ids="$("$psql" -h "$PGHOST" -d "$db" -Atqc \
      "select run_id from control.v_stale_runs" 2>/dev/null || true)"
    local n; n="$(printf '%s\n' "$ids" | sed '/^$/d' | wc -l | tr -d ' ')"
    _ctl__log "[dry-run] reconcile 対象: ${n} 件 (db=$db)"
    return 0
  fi

  local reason_escaped="${reason//\'/\'\'}"
  local out
  out="$("$psql" -h "$PGHOST" -d "$db" -v ON_ERROR_STOP=1 -Atqc "
    UPDATE control.runs
       SET status = 'stale',
           reconciled_at = now(),
           reconcile_reason = '${reason_escaped}'
     WHERE run_id IN (SELECT run_id FROM control.v_stale_runs)
       AND status IN ('leased','running')
    RETURNING run_id;
  " 2>&1)"
  if [[ $? -ne 0 ]]; then
    _ctl__err "reconcile 更新に失敗しました: ${out:0:300}"
    return 1
  fi
  local n; n="$(printf '%s\n' "$out" | sed '/^$/d' | wc -l | tr -d ' ')"
  _ctl__log "reconcile 完了: ${n} 件を stale へ遷移 (db=$db, reason=$reason)"
}

# ------------------------------------------------------------
# Human Approval Gate (control.approvals / control.approval_decisions)
# ------------------------------------------------------------

# ctl__approval_request --category c --subject-kind k --subject-ref r
#   --object-sha256 h --requested-by u [--db d] [--required-approvals 1|2]
#   [--required-role role] [--ttl-hours N] [--head-sha sha] [--project-id id]
#   [--run-id id] [--question text]
#   承認申請を pending として作成し、approval_id を stdout へ出す。
#   risk_category / subject_kind / required_approver_role の値検証は
#   DB 側の CHECK / FK 制約に委ねる (二重定義を避けるため)。
ctl__approval_request() {
  local db="$CTL_DB" category="" subject_kind="" subject_ref="" object_sha256=""
  local requested_by="" required_approvals=1 required_role="owner" ttl_hours=""
  local head_sha="" project_id="" run_id="" question="マージ判定：Y / N"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --db) db="$2"; shift 2 ;;
      --category) category="$2"; shift 2 ;;
      --subject-kind) subject_kind="$2"; shift 2 ;;
      --subject-ref) subject_ref="$2"; shift 2 ;;
      --object-sha256) object_sha256="$2"; shift 2 ;;
      --requested-by) requested_by="$2"; shift 2 ;;
      --required-approvals) required_approvals="$2"; shift 2 ;;
      --required-role) required_role="$2"; shift 2 ;;
      --ttl-hours) ttl_hours="$2"; shift 2 ;;
      --head-sha) head_sha="$2"; shift 2 ;;
      --project-id) project_id="$2"; shift 2 ;;
      --run-id) run_id="$2"; shift 2 ;;
      --question) question="$2"; shift 2 ;;
      *) _ctl__err "ctl__approval_request: 不明な引数 $1"; return 2 ;;
    esac
  done
  if [[ -z "$category" || -z "$subject_kind" || -z "$subject_ref" || -z "$object_sha256" || -z "$requested_by" ]]; then
    _ctl__err "ctl__approval_request: --category/--subject-kind/--subject-ref/--object-sha256/--requested-by は必須です"
    return 2
  fi
  [[ "$object_sha256" =~ ^[0-9a-f]{64}$ ]] || { _ctl__err "--object-sha256 は sha256 hex (64桁) が必要です"; return 2; }
  pg__health "$db" >/dev/null 2>&1 || { _ctl__err "$db に接続できません"; return 3; }

  # VALUES 句では同じ行の他列 (requested_at) を参照できないため now() を直接使う
  # (requested_at の既定値も now() であり、実質的に同一時刻になる)。
  local ttl_clause="now() + coalesce((select default_ttl from control.risk_categories where category = '$(_ctl__sqlq "$category")'), interval '24 hours')"
  [[ -n "$ttl_hours" ]] && ttl_clause="now() + interval '${ttl_hours} hours'"

  # NULL 許容の値は先に SQL 断片 (リテラルまたは NULL) へ組み立ててから埋め込む。
  # 二重引用符のネストで printf のフォーマット文字列が壊れるのを避けるため。
  local project_id_sql="NULL" run_id_sql="NULL" head_sha_sql="NULL"
  [[ -n "$project_id" ]] && project_id_sql="'$(_ctl__sqlq "$project_id")'"
  [[ -n "$run_id" ]] && run_id_sql="'$(_ctl__sqlq "$run_id")'"
  [[ -n "$head_sha" ]] && head_sha_sql="'$(_ctl__sqlq "$head_sha")'"

  local psql; psql="$(pg__cmd psql)"
  local out
  out="$("$psql" -h "$PGHOST" -d "$db" -v ON_ERROR_STOP=1 -Atqc "
    INSERT INTO control.approvals
      (project_id, run_id, risk_category, required_approver_role, required_approvals,
       subject_kind, subject_ref, approved_object_sha256, head_sha, requested_by,
       expires_at, question_text)
    VALUES (
      $project_id_sql,
      $run_id_sql,
      '$(_ctl__sqlq "$category")', '$(_ctl__sqlq "$required_role")', $required_approvals,
      '$(_ctl__sqlq "$subject_kind")', '$(_ctl__sqlq "$subject_ref")', '$(_ctl__sqlq "$object_sha256")',
      $head_sha_sql,
      '$(_ctl__sqlq "$requested_by")',
      (select $ttl_clause),
      '$(_ctl__sqlq "$question")'
    )
    RETURNING approval_id;
  " 2>&1)"
  if [[ $? -ne 0 ]]; then
    _ctl__err "承認申請の作成に失敗しました: ${out:0:400}"
    return 1
  fi
  _ctl__log "承認申請を作成しました: approval_id=$out (db=$db, category=$category)" >&2
  printf '%s\n' "$out"
}

# ctl__approval_decide --approval-id id --approver a --approver-role role
#   --decision Y|N --object-sha256 h [--db d] [--note text]
#   Y/N を記録する。N は即座に rejected。Y は required_approvals に達した
#   時点で approved へ遷移する (二名承認は 2 人目の Y で初めて approved)。
#   申請者自身の承認・役割不一致・対象ハッシュ不一致の決定は集計対象外。
ctl__approval_decide() {
  local db="$CTL_DB" approval_id="" approver="" approver_role="" decision="" object_sha256="" note=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --db) db="$2"; shift 2 ;;
      --approval-id) approval_id="$2"; shift 2 ;;
      --approver) approver="$2"; shift 2 ;;
      --approver-role) approver_role="$2"; shift 2 ;;
      --decision) decision="$2"; shift 2 ;;
      --object-sha256) object_sha256="$2"; shift 2 ;;
      --note) note="$2"; shift 2 ;;
      *) _ctl__err "ctl__approval_decide: 不明な引数 $1"; return 2 ;;
    esac
  done
  if [[ -z "$approval_id" || -z "$approver" || -z "$approver_role" || -z "$decision" || -z "$object_sha256" ]]; then
    _ctl__err "ctl__approval_decide: --approval-id/--approver/--approver-role/--decision/--object-sha256 は必須です"
    return 2
  fi
  [[ "$decision" == "Y" || "$decision" == "N" ]] || { _ctl__err "--decision は Y か N です"; return 2; }
  [[ "$object_sha256" =~ ^[0-9a-f]{64}$ ]] || { _ctl__err "--object-sha256 は sha256 hex (64桁) が必要です"; return 2; }
  pg__health "$db" >/dev/null 2>&1 || { _ctl__err "$db に接続できません"; return 3; }

  local note_sql="NULL"
  [[ -n "$note" ]] && note_sql="'$(_ctl__sqlq "$note")'"

  local psql; psql="$(pg__cmd psql)"
  local out
  out="$("$psql" -h "$PGHOST" -d "$db" -v ON_ERROR_STOP=1 -Atqc "
    BEGIN;
    INSERT INTO control.approval_decisions
      (approval_id, approver, approver_role, decision, decided_object_sha256, note)
    VALUES (
      '$(_ctl__sqlq "$approval_id")', '$(_ctl__sqlq "$approver")', '$(_ctl__sqlq "$approver_role")',
      '$(_ctl__sqlq "$decision")', '$(_ctl__sqlq "$object_sha256")',
      $note_sql
    );

    UPDATE control.approvals
       SET status = 'rejected', decided_at = now()
     WHERE approval_id = '$(_ctl__sqlq "$approval_id")'
       AND status = 'pending'
       AND EXISTS (
         SELECT 1 FROM control.approval_decisions
          WHERE approval_id = '$(_ctl__sqlq "$approval_id")' AND decision = 'N'
       );

    UPDATE control.approvals a
       SET status = 'approved', decided_at = now()
     WHERE a.approval_id = '$(_ctl__sqlq "$approval_id")'
       AND a.status = 'pending'
       AND (
         SELECT count(*) FROM control.approval_decisions d
          WHERE d.approval_id = a.approval_id
            AND d.decision = 'Y'
            AND d.approver <> a.requested_by
            AND d.approver_role = a.required_approver_role
            AND d.decided_object_sha256 = a.approved_object_sha256
       ) >= a.required_approvals;

    SELECT status FROM control.approvals WHERE approval_id = '$(_ctl__sqlq "$approval_id")';
    COMMIT;
  " 2>&1)"
  if [[ $? -ne 0 ]]; then
    _ctl__err "承認決定の記録に失敗しました: ${out:0:400}"
    return 1
  fi
  local status; status="$(printf '%s\n' "$out" | tail -1)"
  _ctl__log "決定を記録しました: approval_id=$approval_id decision=$decision → status=$status" >&2
  printf '%s\n' "$status"
}

# ctl__approval_check --approval-id id [--db d] [--observed-sha256 h]
#   実行可能な承認かを判定する (期限内・承認済み・改変検出なし・承認数充足)。
#   --observed-sha256 を渡すと実行直前の対象再ハッシュを記録し、承認時と
#   食い違えば tamper_detected が true になり実行不可となる。
#   実行可能なら rc=0 で JSON を出力、そうでなければ rc=1。
ctl__approval_check() {
  local db="$CTL_DB" approval_id="" observed_sha256=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --db) db="$2"; shift 2 ;;
      --approval-id) approval_id="$2"; shift 2 ;;
      --observed-sha256) observed_sha256="$2"; shift 2 ;;
      *) _ctl__err "ctl__approval_check: 不明な引数 $1"; return 2 ;;
    esac
  done
  [[ -n "$approval_id" ]] || { _ctl__err "ctl__approval_check: --approval-id は必須です"; return 2; }
  pg__health "$db" >/dev/null 2>&1 || { _ctl__err "$db に接続できません"; return 3; }

  local psql; psql="$(pg__cmd psql)"
  if [[ -n "$observed_sha256" ]]; then
    [[ "$observed_sha256" =~ ^[0-9a-f]{64}$ ]] || { _ctl__err "--observed-sha256 は sha256 hex (64桁) が必要です"; return 2; }
    "$psql" -h "$PGHOST" -d "$db" -v ON_ERROR_STOP=1 -qc "
      UPDATE control.approvals
         SET observed_object_sha256 = '$(_ctl__sqlq "$observed_sha256")', observed_at = now()
       WHERE approval_id = '$(_ctl__sqlq "$approval_id")';
    " >/dev/null 2>&1
  fi

  # jsonb_build_object で PostgreSQL 自身に JSON を組み立てさせる (文字列連結による
  # エスケープ漏れを避ける)。actionable は v_actionable_approvals への EXISTS で判定する。
  local detail
  detail="$("$psql" -h "$PGHOST" -d "$db" -Atqc "
    SELECT jsonb_build_object(
        'approval_id', a.approval_id,
        'status', a.status,
        'expires_at', a.expires_at,
        'tamper_detected', a.tamper_detected,
        'actionable', EXISTS (SELECT 1 FROM control.v_actionable_approvals va WHERE va.approval_id = a.approval_id)
      )::text
      FROM control.approvals a WHERE a.approval_id = '$(_ctl__sqlq "$approval_id")';
  " 2>/dev/null || true)"

  if [[ -z "$detail" ]]; then
    printf '{"approval_id":"%s","actionable":false,"error":"not_found"}\n' "$(_ctl__sqlq "$approval_id")"
    return 1
  fi
  printf '%s\n' "$detail"

  local actionable
  actionable="$("$psql" -h "$PGHOST" -d "$db" -Atqc "
    SELECT 1 FROM control.v_actionable_approvals WHERE approval_id = '$(_ctl__sqlq "$approval_id")';
  " 2>/dev/null || true)"
  [[ -n "$actionable" ]]
}

# ------------------------------------------------------------
# Evals (control.eval_definitions / control.eval_results)
# ------------------------------------------------------------

# ctl__eval_define --key k --kind golden|regression|security|outcome|performance|smoke
#   --title t [--db d] [--required]
#   評価定義を冪等に登録する (既存なら変更しない)。
ctl__eval_define() {
  local db="$CTL_DB" key="" kind="" title="" required=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --db) db="$2"; shift 2 ;;
      --key) key="$2"; shift 2 ;;
      --kind) kind="$2"; shift 2 ;;
      --title) title="$2"; shift 2 ;;
      --required) required=1; shift ;;
      *) _ctl__err "ctl__eval_define: 不明な引数 $1"; return 2 ;;
    esac
  done
  [[ -n "$key" && -n "$kind" && -n "$title" ]] || { _ctl__err "ctl__eval_define: --key/--kind/--title は必須です"; return 2; }
  pg__health "$db" >/dev/null 2>&1 || { _ctl__err "$db に接続できません"; return 3; }

  local psql; psql="$(pg__cmd psql)"
  "$psql" -h "$PGHOST" -d "$db" -v ON_ERROR_STOP=1 -qc "
    INSERT INTO control.eval_definitions (eval_key, eval_kind, title, is_required)
    VALUES ('$(_ctl__sqlq "$key")', '$(_ctl__sqlq "$kind")', '$(_ctl__sqlq "$title")', $( (( required )) && echo true || echo false ))
    ON CONFLICT (eval_key) DO NOTHING;
  " || { _ctl__err "eval 定義の登録に失敗しました: $key"; return 1; }
  _ctl__log "eval 定義を登録しました (冪等): $key"
}

# ctl__eval_record --key k --verdict PASS|FAIL|BLOCKED|NOT_RUN [--db d]
#   [--score n] [--head-sha sha] [--run-id id] [--message m]
ctl__eval_record() {
  local db="$CTL_DB" key="" verdict="" score="" head_sha="" run_id="" message=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --db) db="$2"; shift 2 ;;
      --key) key="$2"; shift 2 ;;
      --verdict) verdict="$2"; shift 2 ;;
      --score) score="$2"; shift 2 ;;
      --head-sha) head_sha="$2"; shift 2 ;;
      --run-id) run_id="$2"; shift 2 ;;
      --message) message="$2"; shift 2 ;;
      *) _ctl__err "ctl__eval_record: 不明な引数 $1"; return 2 ;;
    esac
  done
  [[ -n "$key" && -n "$verdict" ]] || { _ctl__err "ctl__eval_record: --key/--verdict は必須です"; return 2; }
  pg__health "$db" >/dev/null 2>&1 || { _ctl__err "$db に接続できません"; return 3; }

  local run_id_sql="NULL" score_sql="NULL" head_sha_sql="NULL" message_sql="NULL"
  [[ -n "$run_id" ]] && run_id_sql="'$(_ctl__sqlq "$run_id")'"
  [[ -n "$score" ]] && score_sql="$score"
  [[ -n "$head_sha" ]] && head_sha_sql="'$(_ctl__sqlq "$head_sha")'"
  [[ -n "$message" ]] && message_sql="'$(_ctl__sqlq "$message")'"

  local psql; psql="$(pg__cmd psql)"
  local out
  out="$("$psql" -h "$PGHOST" -d "$db" -v ON_ERROR_STOP=1 -Atqc "
    INSERT INTO control.eval_results (eval_id, run_id, verdict, score, head_sha, message)
    SELECT eval_id, $run_id_sql, '$(_ctl__sqlq "$verdict")', $score_sql, $head_sha_sql, $message_sql
      FROM control.eval_definitions WHERE eval_key = '$(_ctl__sqlq "$key")'
    RETURNING result_id;
  " 2>&1)"
  if [[ $? -ne 0 ]]; then
    _ctl__err "eval 結果の記録に失敗しました: ${out:0:300}"
    return 1
  fi
  if [[ -z "$out" ]]; then
    _ctl__err "eval 定義が見つかりません (先に ctl__eval_define で登録してください): $key"
    return 1
  fi
  _ctl__log "eval 結果を記録しました: key=$key verdict=$verdict result_id=$out" >&2
  printf '%s\n' "$out"
}

# ------------------------------------------------------------
# Model usage (control.model_usage)
# ------------------------------------------------------------

# ctl__usage_record --model-id id [--db d] [--run-id id] [--request-kind k]
#   [--input-tokens n] [--output-tokens n] [--cache-read-tokens n]
#   [--cache-creation-tokens n] [--cost-micro-usd n]
ctl__usage_record() {
  local db="$CTL_DB" model_id="" run_id="" request_kind="message"
  local input_tokens=0 output_tokens=0 cache_read_tokens=0 cache_creation_tokens=0 cost_micro_usd=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --db) db="$2"; shift 2 ;;
      --model-id) model_id="$2"; shift 2 ;;
      --run-id) run_id="$2"; shift 2 ;;
      --request-kind) request_kind="$2"; shift 2 ;;
      --input-tokens) input_tokens="$2"; shift 2 ;;
      --output-tokens) output_tokens="$2"; shift 2 ;;
      --cache-read-tokens) cache_read_tokens="$2"; shift 2 ;;
      --cache-creation-tokens) cache_creation_tokens="$2"; shift 2 ;;
      --cost-micro-usd) cost_micro_usd="$2"; shift 2 ;;
      *) _ctl__err "ctl__usage_record: 不明な引数 $1"; return 2 ;;
    esac
  done
  [[ -n "$model_id" ]] || { _ctl__err "ctl__usage_record: --model-id は必須です"; return 2; }
  pg__health "$db" >/dev/null 2>&1 || { _ctl__err "$db に接続できません"; return 3; }

  local run_id_sql="NULL"
  [[ -n "$run_id" ]] && run_id_sql="'$(_ctl__sqlq "$run_id")'"

  local psql; psql="$(pg__cmd psql)"
  "$psql" -h "$PGHOST" -d "$db" -v ON_ERROR_STOP=1 -qc "
    INSERT INTO control.model_usage
      (run_id, model_id, request_kind, input_tokens, output_tokens,
       cache_read_tokens, cache_creation_tokens, cost_micro_usd)
    VALUES (
      $run_id_sql,
      '$(_ctl__sqlq "$model_id")', '$(_ctl__sqlq "$request_kind")',
      $input_tokens, $output_tokens, $cache_read_tokens, $cache_creation_tokens, $cost_micro_usd
    );
  " || { _ctl__err "利用量の記録に失敗しました"; return 1; }
  _ctl__log "利用量を記録しました: model=$model_id input=$input_tokens output=$output_tokens cost_micro_usd=$cost_micro_usd"
}

# ------------------------------------------------------------
# Projects / Runs ライフサイクル
# ------------------------------------------------------------

# ctl__project_register --key k [--db d] [--display-name n] [--repo-path p]
#   [--remote-slug owner/repo] [--default-branch b]
#   project_key で冪等登録 (既存なら display_name 等のみ更新)。project_id を返す。
ctl__project_register() {
  local db="$CTL_DB" key="" display_name="" repo_path="" remote_slug="" default_branch="main"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --db) db="$2"; shift 2 ;;
      --key) key="$2"; shift 2 ;;
      --display-name) display_name="$2"; shift 2 ;;
      --repo-path) repo_path="$2"; shift 2 ;;
      --remote-slug) remote_slug="$2"; shift 2 ;;
      --default-branch) default_branch="$2"; shift 2 ;;
      *) _ctl__err "ctl__project_register: 不明な引数 $1"; return 2 ;;
    esac
  done
  [[ -n "$key" ]] || { _ctl__err "ctl__project_register: --key は必須です"; return 2; }
  pg__health "$db" >/dev/null 2>&1 || { _ctl__err "$db に接続できません"; return 3; }

  local repo_path_sql="NULL" remote_slug_sql="NULL"
  [[ -n "$repo_path" ]] && repo_path_sql="'$(_ctl__sqlq "$repo_path")'"
  [[ -n "$remote_slug" ]] && remote_slug_sql="'$(_ctl__sqlq "$remote_slug")'"

  local psql; psql="$(pg__cmd psql)"
  local out
  out="$("$psql" -h "$PGHOST" -d "$db" -v ON_ERROR_STOP=1 -Atqc "
    INSERT INTO control.projects (project_key, display_name, repo_path, remote_slug, default_branch)
    VALUES ('$(_ctl__sqlq "$key")', '$(_ctl__sqlq "$display_name")', $repo_path_sql, $remote_slug_sql, '$(_ctl__sqlq "$default_branch")')
    ON CONFLICT (project_key) DO UPDATE
      SET display_name = excluded.display_name, repo_path = excluded.repo_path,
          remote_slug = excluded.remote_slug, default_branch = excluded.default_branch,
          updated_at = now()
    RETURNING project_id;
  " 2>&1)"
  if [[ $? -ne 0 ]]; then
    _ctl__err "project 登録に失敗しました: ${out:0:300}"
    return 1
  fi
  _ctl__log "project 登録: key=$key project_id=$out" >&2
  printf '%s\n' "$out"
}

# ctl__run_start --project-key k [--db d] [--task-key tk] [--run-kind interactive|cron|
#   supervisor|headless|team|worktree|manual] [--goal-type g] [--session-ref s]
#   [--git-head-sha sha] [--lease-owner o] [--lease-ttl-min N]
#   project を (無ければ最小構成で) 冪等登録してから run を作成する。run_id を返す。
ctl__run_start() {
  local db="$CTL_DB" project_key="" task_key="" run_kind="interactive" goal_type=""
  local session_ref="" git_head_sha="" lease_owner="" lease_ttl_min=5
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --db) db="$2"; shift 2 ;;
      --project-key) project_key="$2"; shift 2 ;;
      --task-key) task_key="$2"; shift 2 ;;
      --run-kind) run_kind="$2"; shift 2 ;;
      --goal-type) goal_type="$2"; shift 2 ;;
      --session-ref) session_ref="$2"; shift 2 ;;
      --git-head-sha) git_head_sha="$2"; shift 2 ;;
      --lease-owner) lease_owner="$2"; shift 2 ;;
      --lease-ttl-min) lease_ttl_min="$2"; shift 2 ;;
      *) _ctl__err "ctl__run_start: 不明な引数 $1"; return 2 ;;
    esac
  done
  [[ -n "$project_key" ]] || { _ctl__err "ctl__run_start: --project-key は必須です"; return 2; }
  pg__health "$db" >/dev/null 2>&1 || { _ctl__err "$db に接続できません"; return 3; }

  local project_id
  project_id="$(ctl__project_register --db "$db" --key "$project_key" 2>/dev/null)"
  [[ -n "$project_id" ]] || { _ctl__err "project の解決に失敗しました: $project_key"; return 1; }

  local goal_type_sql="NULL" session_ref_sql="NULL" git_head_sha_sql="NULL" lease_owner_sql="NULL"
  local lease_token_sql="NULL" lease_expires_sql="NULL"
  [[ -n "$goal_type" ]] && goal_type_sql="'$(_ctl__sqlq "$goal_type")'"
  [[ -n "$session_ref" ]] && session_ref_sql="'$(_ctl__sqlq "$session_ref")'"
  [[ -n "$git_head_sha" ]] && git_head_sha_sql="'$(_ctl__sqlq "$git_head_sha")'"
  if [[ -n "$lease_owner" ]]; then
    lease_owner_sql="'$(_ctl__sqlq "$lease_owner")'"
    lease_token_sql="gen_random_uuid()"
    lease_expires_sql="now() + interval '${lease_ttl_min} minutes'"
  fi

  local task_id_sql="NULL"
  if [[ -n "$task_key" ]]; then
    local psql0; psql0="$(pg__cmd psql)"
    local tid; tid="$("$psql0" -h "$PGHOST" -d "$db" -Atqc "select task_id from control.tasks where project_id='$(_ctl__sqlq "$project_id")' and task_key='$(_ctl__sqlq "$task_key")'" 2>/dev/null || true)"
    [[ -n "$tid" ]] && task_id_sql="'$(_ctl__sqlq "$tid")'"
  fi

  local psql; psql="$(pg__cmd psql)"
  local out
  out="$("$psql" -h "$PGHOST" -d "$db" -v ON_ERROR_STOP=1 -Atqc "
    INSERT INTO control.runs
      (project_id, task_id, run_kind, goal_type, status, lease_owner, lease_token,
       lease_expires_at, heartbeat_at, started_at, session_ref, git_head_sha)
    VALUES (
      '$(_ctl__sqlq "$project_id")', $task_id_sql, '$(_ctl__sqlq "$run_kind")', $goal_type_sql,
      $( [[ -n "$lease_owner" ]] && echo "'running'" || echo "'queued'" ),
      $lease_owner_sql, $lease_token_sql, $lease_expires_sql,
      $( [[ -n "$lease_owner" ]] && echo "now()" || echo "NULL" ),
      $( [[ -n "$lease_owner" ]] && echo "now()" || echo "NULL" ),
      $session_ref_sql, $git_head_sha_sql
    )
    RETURNING run_id;
  " 2>&1)"
  if [[ $? -ne 0 ]]; then
    _ctl__err "run 開始に失敗しました: ${out:0:300}"
    return 1
  fi
  _ctl__log "run 開始: run_id=$out (project=$project_key, kind=$run_kind)" >&2
  printf '%s\n' "$out"
}

# ctl__run_heartbeat --run-id id [--db d] [--lease-ttl-min N]
ctl__run_heartbeat() {
  local db="$CTL_DB" run_id="" lease_ttl_min=5
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --db) db="$2"; shift 2 ;;
      --run-id) run_id="$2"; shift 2 ;;
      --lease-ttl-min) lease_ttl_min="$2"; shift 2 ;;
      *) _ctl__err "ctl__run_heartbeat: 不明な引数 $1"; return 2 ;;
    esac
  done
  [[ -n "$run_id" ]] || { _ctl__err "ctl__run_heartbeat: --run-id は必須です"; return 2; }
  pg__health "$db" >/dev/null 2>&1 || { _ctl__err "$db に接続できません"; return 3; }

  local psql; psql="$(pg__cmd psql)"
  "$psql" -h "$PGHOST" -d "$db" -v ON_ERROR_STOP=1 -qc "
    UPDATE control.runs
       SET heartbeat_at = now(), heartbeat_seq = heartbeat_seq + 1,
           lease_expires_at = now() + interval '${lease_ttl_min} minutes'
     WHERE run_id = '$(_ctl__sqlq "$run_id")'
       AND status IN ('leased','running');
  " || { _ctl__err "heartbeat 更新に失敗しました"; return 1; }
}

# ctl__run_finish --run-id id --status succeeded|failed|cancelled|blocked [--db d]
#   [--exit-code n] [--summary s]
ctl__run_finish() {
  local db="$CTL_DB" run_id="" status="" exit_code="" summary=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --db) db="$2"; shift 2 ;;
      --run-id) run_id="$2"; shift 2 ;;
      --status) status="$2"; shift 2 ;;
      --exit-code) exit_code="$2"; shift 2 ;;
      --summary) summary="$2"; shift 2 ;;
      *) _ctl__err "ctl__run_finish: 不明な引数 $1"; return 2 ;;
    esac
  done
  [[ -n "$run_id" && -n "$status" ]] || { _ctl__err "ctl__run_finish: --run-id/--status は必須です"; return 2; }
  pg__health "$db" >/dev/null 2>&1 || { _ctl__err "$db に接続できません"; return 3; }

  local exit_code_sql="NULL" summary_sql="NULL"
  [[ -n "$exit_code" ]] && exit_code_sql="$exit_code"
  [[ -n "$summary" ]] && summary_sql="'$(_ctl__sqlq "$summary")'"

  local psql; psql="$(pg__cmd psql)"
  "$psql" -h "$PGHOST" -d "$db" -v ON_ERROR_STOP=1 -qc "
    UPDATE control.runs
       SET status = '$(_ctl__sqlq "$status")', ended_at = now(),
           exit_code = $exit_code_sql, summary = $summary_sql
     WHERE run_id = '$(_ctl__sqlq "$run_id")';
  " || { _ctl__err "run 終了の記録に失敗しました"; return 1; }
  _ctl__log "run 終了: run_id=$run_id status=$status"
}

# ------------------------------------------------------------
# Agent Registry / Assignment / Handoff
# ------------------------------------------------------------

# ctl__agent_register --name n [--db d] [--kind k] [--execution-plane p]
#   [--model-id m] [--instruction-ref r] [--verifier]
#   agent_name で冪等登録 (既存なら属性を更新)。agent_id を返す。
ctl__agent_register() {
  local db="$CTL_DB" name="" kind="generalist" plane="subagent" model_id="" instruction_ref="" verifier=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --db) db="$2"; shift 2 ;;
      --name) name="$2"; shift 2 ;;
      --kind) kind="$2"; shift 2 ;;
      --execution-plane) plane="$2"; shift 2 ;;
      --model-id) model_id="$2"; shift 2 ;;
      --instruction-ref) instruction_ref="$2"; shift 2 ;;
      --verifier) verifier=1; shift ;;
      *) _ctl__err "ctl__agent_register: 不明な引数 $1"; return 2 ;;
    esac
  done
  [[ -n "$name" ]] || { _ctl__err "ctl__agent_register: --name は必須です"; return 2; }
  pg__health "$db" >/dev/null 2>&1 || { _ctl__err "$db に接続できません"; return 3; }

  local model_id_sql="NULL" instruction_ref_sql="NULL"
  [[ -n "$model_id" ]] && model_id_sql="'$(_ctl__sqlq "$model_id")'"
  [[ -n "$instruction_ref" ]] && instruction_ref_sql="'$(_ctl__sqlq "$instruction_ref")'"

  local psql; psql="$(pg__cmd psql)"
  local out
  out="$("$psql" -h "$PGHOST" -d "$db" -v ON_ERROR_STOP=1 -Atqc "
    INSERT INTO control.agents (agent_name, agent_kind, execution_plane, model_id, instruction_ref, is_verifier)
    VALUES ('$(_ctl__sqlq "$name")', '$(_ctl__sqlq "$kind")', '$(_ctl__sqlq "$plane")', $model_id_sql, $instruction_ref_sql, $( (( verifier )) && echo true || echo false ))
    ON CONFLICT (agent_name) DO UPDATE
      SET agent_kind = excluded.agent_kind, execution_plane = excluded.execution_plane,
          model_id = excluded.model_id, instruction_ref = excluded.instruction_ref,
          is_verifier = excluded.is_verifier, updated_at = now()
    RETURNING agent_id;
  " 2>&1)"
  if [[ $? -ne 0 ]]; then
    _ctl__err "agent 登録に失敗しました: ${out:0:300}"
    return 1
  fi
  _ctl__log "agent 登録: name=$name agent_id=$out" >&2
  printf '%s\n' "$out"
}

# ctl__agent_assign --project-key k --run-id id --agent-name n [--db d]
#   [--task-key tk] [--role implementer|reviewer|verifier|planner|observer]
#   [--path-scope p] [--worktree-path wp] [--branch bn]
#   同一 project の同一 path_scope が既に (released_at IS NULL で) 割当済みなら
#   rc=5 で衝突を報告する (同一ファイルへの並列書込み禁止の機械的担保)。
ctl__agent_assign() {
  local db="$CTL_DB" project_key="" run_id="" agent_name="" task_key="" role="implementer"
  local path_scope="" worktree_path="" branch=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --db) db="$2"; shift 2 ;;
      --project-key) project_key="$2"; shift 2 ;;
      --run-id) run_id="$2"; shift 2 ;;
      --agent-name) agent_name="$2"; shift 2 ;;
      --task-key) task_key="$2"; shift 2 ;;
      --role) role="$2"; shift 2 ;;
      --path-scope) path_scope="$2"; shift 2 ;;
      --worktree-path) worktree_path="$2"; shift 2 ;;
      --branch) branch="$2"; shift 2 ;;
      *) _ctl__err "ctl__agent_assign: 不明な引数 $1"; return 2 ;;
    esac
  done
  if [[ -z "$project_key" || -z "$run_id" || -z "$agent_name" ]]; then
    _ctl__err "ctl__agent_assign: --project-key/--run-id/--agent-name は必須です"
    return 2
  fi
  pg__health "$db" >/dev/null 2>&1 || { _ctl__err "$db に接続できません"; return 3; }

  local psql; psql="$(pg__cmd psql)"
  local project_id
  project_id="$("$psql" -h "$PGHOST" -d "$db" -Atqc "select project_id from control.projects where project_key='$(_ctl__sqlq "$project_key")'" 2>/dev/null || true)"
  [[ -n "$project_id" ]] || { _ctl__err "project が見つかりません: $project_key"; return 1; }
  local agent_id
  agent_id="$("$psql" -h "$PGHOST" -d "$db" -Atqc "select agent_id from control.agents where agent_name='$(_ctl__sqlq "$agent_name")'" 2>/dev/null || true)"
  [[ -n "$agent_id" ]] || { _ctl__err "agent が見つかりません (先に ctl__agent_register): $agent_name"; return 1; }

  local task_id_sql="NULL"
  if [[ -n "$task_key" ]]; then
    local tid; tid="$("$psql" -h "$PGHOST" -d "$db" -Atqc "select task_id from control.tasks where project_id='$(_ctl__sqlq "$project_id")' and task_key='$(_ctl__sqlq "$task_key")'" 2>/dev/null || true)"
    [[ -n "$tid" ]] && task_id_sql="'$(_ctl__sqlq "$tid")'"
  fi
  local path_scope_sql="NULL" worktree_path_sql="NULL" branch_sql="NULL"
  [[ -n "$path_scope" ]] && path_scope_sql="'$(_ctl__sqlq "$path_scope")'"
  [[ -n "$worktree_path" ]] && worktree_path_sql="'$(_ctl__sqlq "$worktree_path")'"
  [[ -n "$branch" ]] && branch_sql="'$(_ctl__sqlq "$branch")'"

  local out
  out="$("$psql" -h "$PGHOST" -d "$db" -v ON_ERROR_STOP=1 -Atqc "
    INSERT INTO control.agent_assignments
      (project_id, run_id, agent_id, task_id, assigned_role, path_scope, worktree_path, branch_name)
    VALUES (
      '$(_ctl__sqlq "$project_id")', '$(_ctl__sqlq "$run_id")', '$(_ctl__sqlq "$agent_id")',
      $task_id_sql, '$(_ctl__sqlq "$role")', $path_scope_sql, $worktree_path_sql, $branch_sql
    )
    RETURNING assignment_id;
  " 2>&1)"
  if [[ $? -ne 0 ]]; then
    if [[ "$out" == *"uq_agent_assignments_active_scope"* ]]; then
      _ctl__err "衝突: path_scope '$path_scope' は project '$project_key' で既に割当済みです (同一ファイルへの並列割当は禁止)"
      return 5
    fi
    _ctl__err "agent 割当に失敗しました: ${out:0:300}"
    return 1
  fi
  _ctl__log "agent 割当: agent=$agent_name role=$role path_scope=${path_scope:-<なし>} assignment_id=$out" >&2
  printf '%s\n' "$out"
}

# ctl__agent_release --assignment-id id [--db d] [--reason r]
ctl__agent_release() {
  local db="$CTL_DB" assignment_id="" reason=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --db) db="$2"; shift 2 ;;
      --assignment-id) assignment_id="$2"; shift 2 ;;
      --reason) reason="$2"; shift 2 ;;
      *) _ctl__err "ctl__agent_release: 不明な引数 $1"; return 2 ;;
    esac
  done
  [[ -n "$assignment_id" ]] || { _ctl__err "ctl__agent_release: --assignment-id は必須です"; return 2; }
  pg__health "$db" >/dev/null 2>&1 || { _ctl__err "$db に接続できません"; return 3; }

  local reason_sql="NULL"
  [[ -n "$reason" ]] && reason_sql="'$(_ctl__sqlq "$reason")'"

  local psql; psql="$(pg__cmd psql)"
  "$psql" -h "$PGHOST" -d "$db" -v ON_ERROR_STOP=1 -qc "
    UPDATE control.agent_assignments
       SET released_at = now(), release_reason = $reason_sql
     WHERE assignment_id = '$(_ctl__sqlq "$assignment_id")' AND released_at IS NULL;
  " || { _ctl__err "割当解放に失敗しました"; return 1; }
}

# ctl__handoff_offer --run-id id --to-agent-name n --summary s [--db d]
#   [--from-agent-name n2] [--kind work|review|verification|escalation|information]
#   [--ttl-hours N]
ctl__handoff_offer() {
  local db="$CTL_DB" run_id="" to_agent_name="" from_agent_name="" summary="" kind="work" ttl_hours=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --db) db="$2"; shift 2 ;;
      --run-id) run_id="$2"; shift 2 ;;
      --to-agent-name) to_agent_name="$2"; shift 2 ;;
      --from-agent-name) from_agent_name="$2"; shift 2 ;;
      --summary) summary="$2"; shift 2 ;;
      --kind) kind="$2"; shift 2 ;;
      --ttl-hours) ttl_hours="$2"; shift 2 ;;
      *) _ctl__err "ctl__handoff_offer: 不明な引数 $1"; return 2 ;;
    esac
  done
  if [[ -z "$run_id" || -z "$to_agent_name" || -z "$summary" ]]; then
    _ctl__err "ctl__handoff_offer: --run-id/--to-agent-name/--summary は必須です"
    return 2
  fi
  pg__health "$db" >/dev/null 2>&1 || { _ctl__err "$db に接続できません"; return 3; }

  local psql; psql="$(pg__cmd psql)"
  local to_agent_id
  to_agent_id="$("$psql" -h "$PGHOST" -d "$db" -Atqc "select agent_id from control.agents where agent_name='$(_ctl__sqlq "$to_agent_name")'" 2>/dev/null || true)"
  [[ -n "$to_agent_id" ]] || { _ctl__err "agent が見つかりません: $to_agent_name"; return 1; }
  local from_agent_id_sql="NULL"
  if [[ -n "$from_agent_name" ]]; then
    local fid; fid="$("$psql" -h "$PGHOST" -d "$db" -Atqc "select agent_id from control.agents where agent_name='$(_ctl__sqlq "$from_agent_name")'" 2>/dev/null || true)"
    [[ -n "$fid" ]] && from_agent_id_sql="'$(_ctl__sqlq "$fid")'"
  fi
  local expires_sql="NULL"
  [[ -n "$ttl_hours" ]] && expires_sql="now() + interval '${ttl_hours} hours'"

  local out
  out="$("$psql" -h "$PGHOST" -d "$db" -v ON_ERROR_STOP=1 -Atqc "
    INSERT INTO control.handoffs (run_id, from_agent_id, to_agent_id, handoff_kind, summary, expires_at)
    VALUES ('$(_ctl__sqlq "$run_id")', $from_agent_id_sql, '$(_ctl__sqlq "$to_agent_id")', '$(_ctl__sqlq "$kind")', '$(_ctl__sqlq "$summary")', $expires_sql)
    RETURNING handoff_id;
  " 2>&1)"
  if [[ $? -ne 0 ]]; then
    _ctl__err "handoff 作成に失敗しました: ${out:0:300}"
    return 1
  fi
  _ctl__log "handoff 提示: to=$to_agent_name handoff_id=$out" >&2
  printf '%s\n' "$out"
}

# ctl__handoff_accept --handoff-id id [--db d]
ctl__handoff_accept() {
  local db="$CTL_DB" handoff_id=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --db) db="$2"; shift 2 ;;
      --handoff-id) handoff_id="$2"; shift 2 ;;
      *) _ctl__err "ctl__handoff_accept: 不明な引数 $1"; return 2 ;;
    esac
  done
  [[ -n "$handoff_id" ]] || { _ctl__err "ctl__handoff_accept: --handoff-id は必須です"; return 2; }
  pg__health "$db" >/dev/null 2>&1 || { _ctl__err "$db に接続できません"; return 3; }

  local psql; psql="$(pg__cmd psql)"
  "$psql" -h "$PGHOST" -d "$db" -v ON_ERROR_STOP=1 -qc "
    UPDATE control.handoffs
       SET state = 'accepted', accepted_at = now()
     WHERE handoff_id = '$(_ctl__sqlq "$handoff_id")' AND state = 'offered';
  " || { _ctl__err "handoff 受諾に失敗しました"; return 1; }
}

# ------------------------------------------------------------
# Mission Control 向け集計
# ------------------------------------------------------------

# ctl__dashboard_json [db] — run 状況・承認待ち・直近 eval・コスト・agent 登録数を
#   1 回のクエリで集計する。DB 障害時も常に妥当な JSON を rc=0 で返す
#   (ctl__status_json と同じ fail-soft 規約)。
ctl__dashboard_json() {
  local db="${1:-$CTL_DB}"

  local psql; psql="$(pg__cmd psql)"
  local stats
  stats="$("$psql" -h "$PGHOST" -d "$db" -Atqc "
    SELECT jsonb_build_object(
      'runs_total', (SELECT count(*) FROM control.runs),
      'runs_running', (SELECT count(*) FROM control.runs WHERE status IN ('leased','running')),
      'runs_stale_pending_reconcile', (SELECT count(*) FROM control.v_stale_runs),
      'runs_succeeded_24h', (SELECT count(*) FROM control.runs WHERE status='succeeded' AND ended_at > now() - interval '24 hours'),
      'runs_failed_24h', (SELECT count(*) FROM control.runs WHERE status='failed' AND ended_at > now() - interval '24 hours'),
      'approvals_pending', (SELECT count(*) FROM control.approvals WHERE status='pending'),
      'approvals_actionable', (SELECT count(*) FROM control.v_actionable_approvals),
      'eval_results_24h_fail', (SELECT count(*) FROM control.eval_results WHERE verdict IN ('FAIL','BLOCKED') AND occurred_at > now() - interval '24 hours'),
      'cost_micro_usd_24h', (SELECT coalesce(sum(cost_micro_usd),0) FROM control.model_usage WHERE occurred_at > now() - interval '24 hours'),
      'agents_registered', (SELECT count(*) FROM control.agents WHERE is_active)
    )::text;
  " 2>/dev/null || true)"

  # health は pg_isready の単純な疎通確認ではなく、control スキーマへ実際に
  # クエリが通ったか (stats が空でないか) で判定する。pg_isready は DB の
  # 存在有無に関わらず「サーバが応答している」ことしか示さないため。
  local health=false
  [[ -n "$stats" ]] && health=true

  printf '{"db":"%s","health":%s,"stats":%s}\n' "$db" "$health" "${stats:-null}"
  return 0
}
