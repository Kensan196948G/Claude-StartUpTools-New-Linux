#!/usr/bin/env bats
# ============================================================
# control-db.bats — lib/control-db.sh のユニットテスト (psql を PATH スタブで密閉)
#
# 検証観点:
#   - init: dry-run は何も実行しない / 冪等 (既存 role/db は変更しない)
#   - migrate: 命名規約違反 / checksum drift / 順序違反(gap) はいずれも rc=4 (drift/gap) か rc=2 (命名)
#   - migrate: 破壊的操作は既定で拒否、--allow-destructive で明示許可した版のみ通す
#   - migrate: DB 接続不可は rc=3、dry-run は列挙のみで psql -f を呼ばない
#   - migrate: 正常適用は pending の各ファイルへ psql -f を順に呼ぶ
#   - status_json: DB 停止時でも rc=0 で妥当な JSON を返す
#   - 秘密情報 (接続文字列・パスワード) がいかなる出力にも出ない
# ============================================================

load '../helpers/common-setup'

_write_psql_stub() {
  # 呼び出し引数と、-f で渡されたファイルの適用ログを $PSQL_LOG へ記録する。
  # EXISTING_ROLES (空白区切り) / EXISTING_DB / APPLIED_MIGRATIONS ("v:sum" を ; 区切り)
  # / FORCE_FAIL_ON (含まれるとその -f 呼び出しを失敗させる部分文字列) で状態を模擬する。
  # 単純な部分文字列一致だけで判定し、正規表現・sed 抽出は使わない (引用符ネスト事故を避けるため)。
  local body
  body="$(cat <<'STUBEOF'
args="$*"
printf '%s\n' "$args" >> "$PSQL_LOG"
file=""; prev=""
for a in "$@"; do
  if [ "$prev" = "-f" ]; then file="$a"; fi
  prev="$a"
done
if [ -n "$file" ]; then
  printf 'APPLY:%s\n' "$file" >> "$PSQL_LOG"
  if [ -n "${FORCE_FAIL_ON:-}" ] && printf '%s' "$file" | grep -q "$FORCE_FAIL_ON"; then
    echo "stub: forced failure for $file" >&2
    exit 1
  fi
  exit 0
fi
case "$args" in
  *"select 1 from pg_roles"*)
    for r in $EXISTING_ROLES; do
      case "$args" in *"rolname='$r'"*) echo 1; exit 0 ;; esac
    done
    exit 0 ;;
  *"select 1 from pg_database"*)
    if [ -n "${EXISTING_DB:-}" ]; then
      case "$args" in *"datname='$EXISTING_DB'"*) echo 1 ;; esac
    fi
    exit 0 ;;
  *"select version, checksum, applied_at from control.schema_migrations"*)
    printf '%s\n' "${APPLIED_MIGRATIONS:-}" | tr ';' '\n' | sed '/^$/d' | sed 's/:/\t/' | sed 's/$/\t2026-09-13T00:00:00Z/'
    exit 0 ;;
  *"select version, checksum from control.schema_migrations"*)
    printf '%s\n' "${APPLIED_MIGRATIONS:-}" | tr ';' '\n' | sed '/^$/d' | sed 's/:/\t/'
    exit 0 ;;
  *"select count(*) from control.schema_migrations"*)
    printf '%s\n' "${APPLIED_MIGRATIONS:-}" | tr ';' '\n' | sed '/^$/d' | wc -l | tr -d ' '
    exit 0 ;;
  *"filename from control.schema_migrations"*)
    printf '%s\n' "${LAST_MIGRATION:-}"
    exit 0 ;;
  *"select 1 from information_schema.schemata"*)
    [ "${SCHEMA_EXISTS:-0}" = "1" ] && echo 1
    exit 0 ;;
  *"select run_id from control.v_stale_runs"*)
    printf '%s\n' "${STALE_RUN_IDS:-}" | tr ';' '\n' | sed '/^$/d'
    exit 0 ;;
  *"UPDATE control.runs"*)
    if [ "${FORCE_RECONCILE_FAIL:-0}" = "1" ]; then
      echo "stub: forced reconcile failure" >&2
      exit 1
    fi
    printf '%s\n' "${STALE_RUN_IDS:-}" | tr ';' '\n' | sed '/^$/d'
    exit 0 ;;
  *"INSERT INTO control.approvals"*)
    if [ "${FORCE_APPROVAL_FAIL:-0}" = "1" ]; then
      echo "stub: forced approval failure" >&2
      exit 1
    fi
    printf '%s\n' "${APPROVAL_ID_STUB:-approval-stub-id}"
    exit 0 ;;
  *"INSERT INTO control.approval_decisions"*)
    if [ "${FORCE_DECIDE_FAIL:-0}" = "1" ]; then
      echo "stub: forced decide failure" >&2
      exit 1
    fi
    printf '%s\n' "${DECIDE_STATUS_STUB:-pending}"
    exit 0 ;;
  *"'passport_version'"*)
    printf '%s\n' "${PASSPORT_EXPORT_BODY_STUB:-}"
    exit 0 ;;
  *"'runs_total'"*)
    if [ "${FORCE_DASHBOARD_FAIL:-0}" = "1" ]; then
      exit 0
    fi
    # 注意: ${VAR:-{}} は bash が最初の '}' で展開を閉じてしまい末尾に余分な
    # '}' が残るため使わない (`${DASHBOARD_STATS_STUB:-{}}"` を検証中に発見)。
    stats_val="${DASHBOARD_STATS_STUB:-}"
    [ -z "$stats_val" ] && stats_val="{}"
    printf '%s\n' "$stats_val"
    exit 0 ;;
  *"jsonb_build_object"*)
    printf '%s\n' "${APPROVAL_CHECK_JSON_STUB:-}"
    exit 0 ;;
  *"v_actionable_approvals"*)
    [ -n "${APPROVAL_ACTIONABLE_STUB:-}" ] && echo 1
    exit 0 ;;
  *"INSERT INTO control.eval_definitions"*)
    if [ "${FORCE_EVAL_DEFINE_FAIL:-0}" = "1" ]; then
      echo "stub: forced eval-define failure" >&2
      exit 1
    fi
    exit 0 ;;
  *"INSERT INTO control.eval_results"*)
    if [ "${FORCE_EVAL_FAIL:-0}" = "1" ]; then
      echo "stub: forced eval-record failure" >&2
      exit 1
    fi
    printf '%s\n' "${EVAL_RESULT_ID_STUB:-}"
    exit 0 ;;
  *"INSERT INTO control.model_usage"*)
    if [ "${FORCE_USAGE_FAIL:-0}" = "1" ]; then
      echo "stub: forced usage failure" >&2
      exit 1
    fi
    exit 0 ;;
  *"INSERT INTO control.projects"*)
    if [ "${FORCE_PROJECT_FAIL:-0}" = "1" ]; then
      echo "stub: forced project failure" >&2
      exit 1
    fi
    printf '%s\n' "${PROJECT_ID_STUB:-project-stub-id}"
    exit 0 ;;
  *"INSERT INTO control.runs"*)
    if [ "${FORCE_RUN_START_FAIL:-0}" = "1" ]; then
      echo "stub: forced run-start failure" >&2
      exit 1
    fi
    printf '%s\n' "${RUN_ID_STUB:-run-stub-id}"
    exit 0 ;;
  *"SET heartbeat_at = now()"*)
    if [ "${FORCE_HEARTBEAT_FAIL:-0}" = "1" ]; then
      echo "stub: forced heartbeat failure" >&2
      exit 1
    fi
    exit 0 ;;
  *"SET status = "*"ended_at = now()"*)
    if [ "${FORCE_RUN_FINISH_FAIL:-0}" = "1" ]; then
      echo "stub: forced run-finish failure" >&2
      exit 1
    fi
    exit 0 ;;
  *"INSERT INTO control.agents"*)
    if [ "${FORCE_AGENT_REGISTER_FAIL:-0}" = "1" ]; then
      echo "stub: forced agent-register failure" >&2
      exit 1
    fi
    printf '%s\n' "${AGENT_ID_STUB:-agent-stub-id}"
    exit 0 ;;
  *"select project_id from control.projects where project_key="*)
    printf '%s\n' "${PROJECT_LOOKUP_STUB:-project-stub-id}"
    exit 0 ;;
  *"select agent_id from control.agents where agent_name="*)
    val="${AGENT_LOOKUP_STUB:-agent-stub-id}"
    [ "$val" = "__NONE__" ] && val=""
    printf '%s\n' "$val"
    exit 0 ;;
  *"select task_id from control.tasks where"*)
    printf '%s\n' "${TASK_LOOKUP_STUB:-}"
    exit 0 ;;
  *"INSERT INTO control.agent_assignments"*)
    if [ "${FORCE_ASSIGN_CONFLICT:-0}" = "1" ]; then
      echo "ERROR:  duplicate key value violates unique constraint \"uq_agent_assignments_active_scope\"" >&2
      exit 1
    fi
    if [ "${FORCE_ASSIGN_FAIL:-0}" = "1" ]; then
      echo "stub: forced assign failure" >&2
      exit 1
    fi
    printf '%s\n' "${ASSIGNMENT_ID_STUB:-assignment-stub-id}"
    exit 0 ;;
  *"UPDATE control.agent_assignments"*)
    if [ "${FORCE_RELEASE_FAIL:-0}" = "1" ]; then
      echo "stub: forced release failure" >&2
      exit 1
    fi
    exit 0 ;;
  *"INSERT INTO control.handoffs"*)
    if [ "${FORCE_HANDOFF_OFFER_FAIL:-0}" = "1" ]; then
      echo "stub: forced handoff-offer failure" >&2
      exit 1
    fi
    printf '%s\n' "${HANDOFF_ID_STUB:-handoff-stub-id}"
    exit 0 ;;
  *"UPDATE control.handoffs"*)
    if [ "${FORCE_HANDOFF_ACCEPT_FAIL:-0}" = "1" ]; then
      echo "stub: forced handoff-accept failure" >&2
      exit 1
    fi
    exit 0 ;;
  *)
    exit 0 ;;
esac
STUBEOF
)"
  make_stub_bin psql "$body"
}

setup() {
  _bats_common_setup
  export CCSU_HOME="$TEST_TEMP/home"
  export PGHOST="$TEST_TEMP/sock"
  export PG_BIN="$STUB_BIN"
  export CTL_DB="ctltest"
  export CTL_ROLE_PREFIX="ctl"
  export CCSU_CONTROL_MIG_DIR="$TEST_TEMP/migrations"
  export CCSU_CONTROL_STATE_DIR="$TEST_TEMP/control-plane"
  export PSQL_LOG="$TEST_TEMP/psql.log"
  export EXISTING_ROLES="" EXISTING_DB="" APPLIED_MIGRATIONS="" LAST_MIGRATION="" SCHEMA_EXISTS="0" FORCE_FAIL_ON=""
  export STALE_RUN_IDS="" FORCE_RECONCILE_FAIL="0"
  export PROJECT_ID_STUB="" PROJECT_LOOKUP_STUB="" FORCE_PROJECT_FAIL="0"
  export RUN_ID_STUB="" FORCE_RUN_START_FAIL="0" FORCE_HEARTBEAT_FAIL="0" FORCE_RUN_FINISH_FAIL="0"
  export AGENT_ID_STUB="" AGENT_LOOKUP_STUB="" FORCE_AGENT_REGISTER_FAIL="0"
  export TASK_LOOKUP_STUB="" ASSIGNMENT_ID_STUB="" FORCE_ASSIGN_FAIL="0" FORCE_ASSIGN_CONFLICT="0" FORCE_RELEASE_FAIL="0"
  export HANDOFF_ID_STUB="" FORCE_HANDOFF_OFFER_FAIL="0" FORCE_HANDOFF_ACCEPT_FAIL="0"
  export DASHBOARD_STATS_STUB="" FORCE_DASHBOARD_FAIL="0"
  export PASSPORT_EXPORT_BODY_STUB=""
  mkdir -p "$CCSU_CONTROL_MIG_DIR"
  : > "$PSQL_LOG"
  make_stub_bin pg_lsclusters 'printf "Ver Cluster Port Status Owner Data\n16  main 5432 online postgres /x\n"'
  make_stub_bin pg_isready 'exit 0'
  _write_psql_stub
  source "$REPO_ROOT/lib/common.sh"
  source "$REPO_ROOT/lib/postgres.sh"
  source "$REPO_ROOT/lib/control-db.sh"
}
teardown() { _bats_common_teardown; }

_mig() { printf '%s\n' "$2" > "$CCSU_CONTROL_MIG_DIR/$1"; }

# ---- init --------------------------------------------------
@test "ctl__init --dry-run: CREATE / GRANT を一切実行しない" {
  run ctl__init --grant-to tester --dry-run
  [ "$status" -eq 0 ]
  ! grep -qi "CREATE ROLE" "$PSQL_LOG"
  ! grep -qi "GRANT" "$PSQL_LOG"
  ! grep -qi "CREATE DATABASE" "$PSQL_LOG"
}
@test "ctl__init: role/db が既存なら CREATE を発行せず冪等" {
  export EXISTING_ROLES="ctl_migrator ctl_app ctl_ro ctl_audit" EXISTING_DB="ctltest"
  run ctl__init --grant-to tester
  [ "$status" -eq 0 ]
  ! grep -qi "CREATE ROLE" "$PSQL_LOG"
  ! grep -qi "CREATE DATABASE" "$PSQL_LOG"
}
@test "ctl__init: role/db 未存在なら作成し GRANT する" {
  run ctl__init --grant-to tester
  [ "$status" -eq 0 ]
  grep -q "CREATE ROLE \"ctl_migrator\"" "$PSQL_LOG"
  grep -q 'GRANT "ctl_migrator", "ctl_app", "ctl_ro", "ctl_audit" TO "tester"' "$PSQL_LOG"
  grep -q "CREATE DATABASE \"ctltest\"" "$PSQL_LOG"
}
@test "ctl__init: 不正な識別子は rc=2" {
  run ctl__init --db "Bad-Name!"
  [ "$status" -eq 2 ]
}

# ---- migrate: 命名規約 -------------------------------------
@test "ctl__migrate: 命名規約違反ファイルは rc=2" {
  _mig "not-a-migration.sql" "select 1;"
  run ctl__migrate
  [ "$status" -eq 2 ]
  [[ "$output" == *"命名規約違反"* ]]
}

# ---- migrate: drift / gap ----------------------------------
@test "ctl__migrate: checksum drift は rc=4 で 1 件も適用しない" {
  _mig "0001_a.sql" "select 1;"
  export APPLIED_MIGRATIONS="0001:deadbeef"
  run ctl__migrate
  [ "$status" -eq 4 ]
  [[ "$output" == *"checksum drift"* ]]
  ! grep -q "APPLY:" "$PSQL_LOG"
}
@test "ctl__migrate: 順序違反(gap) は rc=4" {
  _mig "0001_a.sql" "select 1;"
  _mig "0002_b.sql" "select 1;"
  _mig "0003_c.sql" "select 1;"
  local sum1 sum3
  sum1="$(sha256sum "$CCSU_CONTROL_MIG_DIR/0001_a.sql" | cut -d' ' -f1)"
  sum3="$(sha256sum "$CCSU_CONTROL_MIG_DIR/0003_c.sql" | cut -d' ' -f1)"
  export APPLIED_MIGRATIONS="0001:${sum1};0003:${sum3}"
  run ctl__migrate
  [ "$status" -eq 4 ]
  [[ "$output" == *"順序違反"* ]]
}

# ---- migrate: 破壊的操作 ------------------------------------
@test "ctl__migrate: 破壊的 SQL は既定で拒否 (rc=1)、適用されない" {
  _mig "0001_a.sql" "DROP TABLE legacy;"
  run ctl__migrate
  [ "$status" -eq 1 ]
  ! grep -q "APPLY:" "$PSQL_LOG"
}
@test "ctl__migrate: --allow-destructive で明示許可した版のみ適用される" {
  _mig "0001_a.sql" "DROP TABLE legacy;"
  run ctl__migrate --allow-destructive 0001
  [ "$status" -eq 0 ]
  grep -q "APPLY:$CCSU_CONTROL_MIG_DIR/0001_a.sql" "$PSQL_LOG"
}

# ---- migrate: 接続不可 / dry-run / 正常適用 ------------------
@test "ctl__migrate: DB 接続不可は rc=3" {
  make_stub_bin pg_isready 'exit 1'
  _mig "0001_a.sql" "select 1;"
  run ctl__migrate
  [ "$status" -eq 3 ]
}
@test "ctl__migrate --dry-run: 列挙のみで psql -f を呼ばない" {
  _mig "0001_a.sql" "select 1;"
  _mig "0002_b.sql" "select 1;"
  run ctl__migrate --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"0001_a.sql"* && "$output" == *"0002_b.sql"* ]]
  ! grep -q "APPLY:" "$PSQL_LOG"
}
@test "ctl__migrate: 正常適用は pending の各ファイルへ psql -f を順に呼ぶ" {
  _mig "0001_a.sql" "select 1;"
  _mig "0002_b.sql" "select 1;"
  run ctl__migrate
  [ "$status" -eq 0 ]
  grep -q "APPLY:$CCSU_CONTROL_MIG_DIR/0001_a.sql" "$PSQL_LOG"
  grep -q "APPLY:$CCSU_CONTROL_MIG_DIR/0002_b.sql" "$PSQL_LOG"
  [ "$(grep -n 'APPLY:' "$PSQL_LOG" | head -1 | cut -d: -f1)" -lt "$(grep -n 'APPLY:' "$PSQL_LOG" | tail -1 | cut -d: -f1)" ]
}
@test "ctl__migrate: 適用済み分は再適用しない (冪等)" {
  _mig "0001_a.sql" "select 1;"
  local sum1; sum1="$(sha256sum "$CCSU_CONTROL_MIG_DIR/0001_a.sql" | cut -d' ' -f1)"
  export APPLIED_MIGRATIONS="0001:${sum1}"
  run ctl__migrate
  [ "$status" -eq 0 ]
  ! grep -q "APPLY:" "$PSQL_LOG"
  [[ "$output" == *"適用対象なし"* ]]
}

# ---- status_json --------------------------------------------
@test "ctl__status_json: 正常時に妥当な JSON を返す" {
  export APPLIED_MIGRATIONS="0001:abc"
  run ctl__status_json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.db == "ctltest" and .health == true and .migrations_applied == 1'
}
@test "ctl__status_json: DB 停止時でも rc=0 で妥当な JSON を返す" {
  make_stub_bin pg_isready 'exit 1'
  make_stub_bin psql 'exit 1'
  run ctl__status_json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.health == false and .migrations_applied == 0'
}

# ---- 秘密情報の非出力 -----------------------------------------
@test "秘密情報 (パスワード・接続文字列) がいかなる出力にも含まれない" {
  export EXISTING_ROLES="" EXISTING_DB=""
  run ctl__init --grant-to tester
  [[ "$output" != *"password"* ]]
  [[ "$output" != *"postgresql://"* ]]
  ! grep -qi "password" "$PSQL_LOG"
  ! grep -qi "postgresql://" "$PSQL_LOG"
}

@test "control-db.sh: 引数不足は non-zero" {
  run bash "$REPO_ROOT/bin/control-db.sh" migrate --db
  [ "$status" -ne 0 ]
}

# ---- reconcile -------------------------------------------------
@test "ctl__reconcile: 対象なしは 0 件で成功 (UPDATE 自体は WHERE 一致 0 件で安全に空振りする)" {
  run ctl__reconcile
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 件"* ]]
}
@test "ctl__reconcile: 対象がある場合は stale へ遷移し件数を報告する" {
  export STALE_RUN_IDS="11111111-1111-1111-1111-111111111111;22222222-2222-2222-2222-222222222222"
  run ctl__reconcile
  [ "$status" -eq 0 ]
  [[ "$output" == *"2 件"* ]]
  grep -q "UPDATE control.runs" "$PSQL_LOG"
  grep -q "lease_expired_reconciler" "$PSQL_LOG"
}
@test "ctl__reconcile --dry-run: UPDATE を発行せず件数だけ報告する" {
  export STALE_RUN_IDS="11111111-1111-1111-1111-111111111111"
  run ctl__reconcile --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"[dry-run]"* && "$output" == *"1 件"* ]]
  ! grep -q "UPDATE control.runs" "$PSQL_LOG"
}
@test "ctl__reconcile: --reason を SQL へ反映する" {
  export STALE_RUN_IDS="11111111-1111-1111-1111-111111111111"
  run ctl__reconcile --reason "manual test reason"
  [ "$status" -eq 0 ]
  grep -q "manual test reason" "$PSQL_LOG"
}
@test "ctl__reconcile: DB 接続不可は rc=3" {
  make_stub_bin pg_isready 'exit 1'
  run ctl__reconcile
  [ "$status" -eq 3 ]
}
@test "ctl__reconcile: UPDATE 失敗時は rc=1" {
  export STALE_RUN_IDS="11111111-1111-1111-1111-111111111111" FORCE_RECONCILE_FAIL="1"
  run ctl__reconcile
  [ "$status" -eq 1 ]
}

# ---- approval_request ---------------------------------------
@test "ctl__approval_request: 必須引数不足は rc=2" {
  run ctl__approval_request --category deployment
  [ "$status" -eq 2 ]
}
@test "ctl__approval_request: object-sha256 が64桁hexでなければ rc=2" {
  run ctl__approval_request --category deployment --subject-kind pull_request \
    --subject-ref "o/r#1" --object-sha256 "not-a-hash" --requested-by "u"
  [ "$status" -eq 2 ]
}
@test "ctl__approval_request: DB 接続不可は rc=3" {
  make_stub_bin pg_isready 'exit 1'
  run ctl__approval_request --category deployment --subject-kind pull_request \
    --subject-ref "o/r#1" --object-sha256 "$(printf x | sha256sum | cut -d' ' -f1)" --requested-by "u"
  [ "$status" -eq 3 ]
}
@test "ctl__approval_request: 正常系は approval_id を返し SQL に値が反映される" {
  export APPROVAL_ID_STUB="aaaa1111-0000-0000-0000-000000000000"
  local sha; sha="$(printf x | sha256sum | cut -d' ' -f1)"
  run ctl__approval_request --category deployment --subject-kind pull_request \
    --subject-ref "o/r#42" --object-sha256 "$sha" --requested-by "kensan"
  [ "$status" -eq 0 ]
  [[ "$output" == *"aaaa1111-0000-0000-0000-000000000000"* ]]
  grep -q "o/r#42" "$PSQL_LOG"
  grep -q "'kensan'" "$PSQL_LOG"
}
@test "ctl__approval_request: 秘密情報を含まない" {
  local sha; sha="$(printf x | sha256sum | cut -d' ' -f1)"
  run ctl__approval_request --category deployment --subject-kind pull_request \
    --subject-ref "o/r#1" --object-sha256 "$sha" --requested-by "u"
  [[ "$output" != *"password"* && "$output" != *"postgresql://"* ]]
}

# ---- approval_decide ------------------------------------------
@test "ctl__approval_decide: decision が Y/N 以外は rc=2" {
  run ctl__approval_decide --approval-id x --approver a --approver-role owner --decision MAYBE --object-sha256 "$(printf x | sha256sum | cut -d' ' -f1)"
  [ "$status" -eq 2 ]
}
@test "ctl__approval_decide: DB 接続不可は rc=3" {
  make_stub_bin pg_isready 'exit 1'
  run ctl__approval_decide --approval-id x --approver a --approver-role owner --decision Y --object-sha256 "$(printf x | sha256sum | cut -d' ' -f1)"
  [ "$status" -eq 3 ]
}
@test "ctl__approval_decide: 正常系は遷移後の status を返す" {
  export DECIDE_STATUS_STUB="approved"
  run ctl__approval_decide --approval-id x --approver a --approver-role owner --decision Y --object-sha256 "$(printf x | sha256sum | cut -d' ' -f1)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"approved"* ]]
}
@test "ctl__approval_decide: 記録失敗は rc=1" {
  export FORCE_DECIDE_FAIL="1"
  run ctl__approval_decide --approval-id x --approver a --approver-role owner --decision Y --object-sha256 "$(printf x | sha256sum | cut -d' ' -f1)"
  [ "$status" -eq 1 ]
}

# ---- approval_check ---------------------------------------------
@test "ctl__approval_check: 存在しない approval は rc=1 で not_found を返す" {
  export APPROVAL_CHECK_JSON_STUB=""
  run ctl__approval_check --approval-id nope
  [ "$status" -eq 1 ]
  [[ "$output" == *"not_found"* ]]
}
@test "ctl__approval_check: actionable なら rc=0" {
  export APPROVAL_CHECK_JSON_STUB='{"approval_id":"x","status":"approved","actionable":true}'
  export APPROVAL_ACTIONABLE_STUB="1"
  run ctl__approval_check --approval-id x
  [ "$status" -eq 0 ]
}
@test "ctl__approval_check: DB 接続不可は rc=3" {
  make_stub_bin pg_isready 'exit 1'
  run ctl__approval_check --approval-id x
  [ "$status" -eq 3 ]
}

# ---- eval_define / eval_record --------------------------------
@test "ctl__eval_define: 必須引数不足は rc=2" {
  run ctl__eval_define --key k
  [ "$status" -eq 2 ]
}
@test "ctl__eval_define: 正常系は ON CONFLICT DO NOTHING で冪等登録する" {
  run ctl__eval_define --key pr5-demo --kind smoke --title "デモ"
  [ "$status" -eq 0 ]
  grep -q "ON CONFLICT (eval_key) DO NOTHING" "$PSQL_LOG"
}
@test "ctl__eval_record: 必須引数不足は rc=2" {
  run ctl__eval_record --key k
  [ "$status" -eq 2 ]
}
@test "ctl__eval_record: 対応する eval 定義が無ければ rc=1" {
  export EVAL_RESULT_ID_STUB=""
  run ctl__eval_record --key nope --verdict PASS
  [ "$status" -eq 1 ]
  [[ "$output" == *"見つかりません"* ]]
}
@test "ctl__eval_record: 正常系は result_id を返す" {
  export EVAL_RESULT_ID_STUB="rrrr2222-0000-0000-0000-000000000000"
  run ctl__eval_record --key pr5-demo --verdict PASS --score 0.9
  [ "$status" -eq 0 ]
  [[ "$output" == *"rrrr2222"* ]]
}
@test "ctl__eval_record: DB 接続不可は rc=3" {
  make_stub_bin pg_isready 'exit 1'
  run ctl__eval_record --key k --verdict PASS
  [ "$status" -eq 3 ]
}

# ---- usage_record ------------------------------------------------
@test "ctl__usage_record: model-id 必須、無ければ rc=2" {
  run ctl__usage_record --input-tokens 10
  [ "$status" -eq 2 ]
}
@test "ctl__usage_record: 正常系は INSERT を発行する" {
  run ctl__usage_record --model-id "claude-sonnet-5" --input-tokens 100 --output-tokens 20 --cost-micro-usd 50
  [ "$status" -eq 0 ]
  grep -q "claude-sonnet-5" "$PSQL_LOG"
}
@test "ctl__usage_record: DB 接続不可は rc=3" {
  make_stub_bin pg_isready 'exit 1'
  run ctl__usage_record --model-id "m"
  [ "$status" -eq 3 ]
}
@test "ctl__usage_record: 記録失敗は rc=1" {
  export FORCE_USAGE_FAIL="1"
  run ctl__usage_record --model-id "m"
  [ "$status" -eq 1 ]
}

# ---- project_register / run lifecycle ---------------------------
@test "ctl__project_register: --key 必須" {
  run ctl__project_register --display-name x
  [ "$status" -eq 2 ]
}
@test "ctl__project_register: 正常系は project_id を返す" {
  export PROJECT_ID_STUB="pppp0000-0000-0000-0000-000000000000"
  run ctl__project_register --key "demo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"pppp0000"* ]]
  grep -q "ON CONFLICT (project_key) DO UPDATE" "$PSQL_LOG"
}
@test "ctl__run_start: --project-key 必須" {
  run ctl__run_start --run-kind interactive
  [ "$status" -eq 2 ]
}
@test "ctl__run_start: DB 接続不可は rc=3" {
  make_stub_bin pg_isready 'exit 1'
  run ctl__run_start --project-key demo
  [ "$status" -eq 3 ]
}
@test "ctl__run_start: 正常系は run_id を返し queued 状態で作る (lease-owner 省略時)" {
  export PROJECT_ID_STUB="p1" RUN_ID_STUB="rrrr0000-0000-0000-0000-000000000000"
  run ctl__run_start --project-key demo
  [ "$status" -eq 0 ]
  [[ "$output" == *"rrrr0000"* ]]
  grep -q "'queued'" "$PSQL_LOG"
}
@test "ctl__run_start: --lease-owner 指定時は running 状態で作る" {
  export PROJECT_ID_STUB="p1" RUN_ID_STUB="r1"
  run ctl__run_start --project-key demo --lease-owner "host/pid1"
  [ "$status" -eq 0 ]
  grep -q "'running'" "$PSQL_LOG"
  grep -q "host/pid1" "$PSQL_LOG"
}
@test "ctl__run_heartbeat: --run-id 必須" {
  run ctl__run_heartbeat
  [ "$status" -eq 2 ]
}
@test "ctl__run_heartbeat: DB 接続不可は rc=3" {
  make_stub_bin pg_isready 'exit 1'
  run ctl__run_heartbeat --run-id r1
  [ "$status" -eq 3 ]
}
@test "ctl__run_heartbeat: 正常系は rc=0" {
  run ctl__run_heartbeat --run-id r1
  [ "$status" -eq 0 ]
}
@test "ctl__run_finish: --run-id/--status 必須" {
  run ctl__run_finish --run-id r1
  [ "$status" -eq 2 ]
}
@test "ctl__run_finish: 正常系は SQL に status を反映する" {
  run ctl__run_finish --run-id r1 --status succeeded --exit-code 0
  [ "$status" -eq 0 ]
  grep -q "'succeeded'" "$PSQL_LOG"
}

# ---- agent_register / agent_assign / agent_release ---------------
@test "ctl__agent_register: --name 必須" {
  run ctl__agent_register --kind reviewer
  [ "$status" -eq 2 ]
}
@test "ctl__agent_register: 正常系は agent_id を返す" {
  export AGENT_ID_STUB="aaaa0000-0000-0000-0000-000000000000"
  run ctl__agent_register --name "code-reviewer" --kind reviewer --verifier
  [ "$status" -eq 0 ]
  [[ "$output" == *"aaaa0000"* ]]
  grep -q "'code-reviewer'" "$PSQL_LOG"
  grep -q ", true)" "$PSQL_LOG"
}
@test "ctl__agent_assign: 必須引数不足は rc=2" {
  run ctl__agent_assign --project-key demo
  [ "$status" -eq 2 ]
}
@test "ctl__agent_assign: DB 接続不可は rc=3" {
  make_stub_bin pg_isready 'exit 1'
  run ctl__agent_assign --project-key demo --run-id r1 --agent-name code-reviewer
  [ "$status" -eq 3 ]
}
@test "ctl__agent_assign: 正常系は assignment_id を返す" {
  export PROJECT_LOOKUP_STUB="p1" AGENT_LOOKUP_STUB="a1" ASSIGNMENT_ID_STUB="asgn0000-0000-0000-0000-000000000000"
  run ctl__agent_assign --project-key demo --run-id r1 --agent-name code-reviewer --path-scope "lib/x.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"asgn0000"* ]]
}
@test "ctl__agent_assign: path_scope 競合検知は rc=5" {
  export PROJECT_LOOKUP_STUB="p1" AGENT_LOOKUP_STUB="a1" FORCE_ASSIGN_CONFLICT="1"
  run ctl__agent_assign --project-key demo --run-id r1 --agent-name code-reviewer --path-scope "lib/x.sh"
  [ "$status" -eq 5 ]
  [[ "$output" == *"衝突"* ]]
}
@test "ctl__agent_release: --assignment-id 必須" {
  run ctl__agent_release
  [ "$status" -eq 2 ]
}
@test "ctl__agent_release: 正常系は rc=0" {
  run ctl__agent_release --assignment-id asgn1 --reason done
  [ "$status" -eq 0 ]
  grep -q "'done'" "$PSQL_LOG"
}

# ---- handoff_offer / handoff_accept -------------------------------
@test "ctl__handoff_offer: 必須引数不足は rc=2" {
  run ctl__handoff_offer --run-id r1
  [ "$status" -eq 2 ]
}
@test "ctl__handoff_offer: to-agent が見つからなければ rc=1" {
  export AGENT_LOOKUP_STUB="__NONE__"
  run ctl__handoff_offer --run-id r1 --to-agent-name nope --summary "レビュー依頼"
  [ "$status" -eq 1 ]
}
@test "ctl__handoff_offer: 正常系は handoff_id を返す" {
  export AGENT_LOOKUP_STUB="a1" HANDOFF_ID_STUB="hoff0000-0000-0000-0000-000000000000"
  run ctl__handoff_offer --run-id r1 --to-agent-name reviewer --summary "レビュー依頼"
  [ "$status" -eq 0 ]
  [[ "$output" == *"hoff0000"* ]]
}
@test "ctl__handoff_accept: --handoff-id 必須" {
  run ctl__handoff_accept
  [ "$status" -eq 2 ]
}
@test "ctl__handoff_accept: 正常系は rc=0" {
  run ctl__handoff_accept --handoff-id h1
  [ "$status" -eq 0 ]
  grep -q "'accepted'" "$PSQL_LOG"
}

# ---- dashboard_json (Mission Control 向け) ------------------------
@test "ctl__dashboard_json: 正常系は health=true と stats を返す" {
  export DASHBOARD_STATS_STUB='{"runs_total":3,"agents_registered":18}'
  run ctl__dashboard_json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.health == true and .stats.runs_total == 3'
}
@test "ctl__dashboard_json: クエリが空を返した場合 (DB/スキーマ不備) は health=false で rc=0" {
  export FORCE_DASHBOARD_FAIL="1"
  run ctl__dashboard_json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.health == false and .stats == null'
}
@test "diag-control-plane.sh --json: 妥当な JSON を返す" {
  export DASHBOARD_STATS_STUB='{"runs_total":0}'
  run bash "$REPO_ROOT/libexec/diag-control-plane.sh" --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.db == "ctltest"'
}

# ---- passport_export -----------------------------------------------
@test "ctl__passport_export: --run-id 必須" {
  run ctl__passport_export
  [ "$status" -eq 2 ]
}
@test "ctl__passport_export: DB 接続不可は rc=3" {
  make_stub_bin pg_isready 'exit 1'
  run ctl__passport_export --run-id r1
  [ "$status" -eq 3 ]
}
@test "ctl__passport_export: run が見つからなければ rc=1" {
  export PASSPORT_EXPORT_BODY_STUB=""
  run ctl__passport_export --run-id nope
  [ "$status" -eq 1 ]
}
@test "ctl__passport_export: 正常系は content_sha256 付きの妥当な JSON を返す" {
  export PASSPORT_EXPORT_BODY_STUB='{"passport_version":"1.0","issued_at":"2026-01-01T00:00:00Z","issuer":{"runtime":"claude-code","run_id":"r1"},"project":{"project_key":"demo","remote_slug":null,"default_branch":"main"},"task":null,"run":{"run_kind":"interactive","status":"succeeded","git_head_sha":null,"summary":"x"},"handoff":{"summary":"x","artifacts":[]}}'
  run ctl__passport_export --run-id r1
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'has("content_sha256") and (.content_sha256 | test("^[0-9a-f]{64}$"))'
}

# ---- passport_import -------------------------------------------------
_make_valid_passport() {
  local file="$1" body="$2"
  local canon hash
  canon="$(jq -S -c '.' <<<"$body")"
  hash="$(printf '%s' "$canon" | sha256sum | cut -d' ' -f1)"
  jq -c --arg h "$hash" '. + {content_sha256: $h}' <<<"$body" > "$file"
}

@test "ctl__passport_import: --file 必須" {
  run ctl__passport_import
  [ "$status" -eq 2 ]
}
@test "ctl__passport_import: 存在しないファイルは rc=2" {
  run ctl__passport_import --file "$TEST_TEMP/nope.json"
  [ "$status" -eq 2 ]
}
@test "ctl__passport_import: 必須キー欠落は rc=2" {
  echo '{"passport_version":"1.0"}' > "$TEST_TEMP/bad.json"
  run ctl__passport_import --file "$TEST_TEMP/bad.json"
  [ "$status" -eq 2 ]
}
@test "ctl__passport_import: content_sha256 不一致 (改ざん) は rc=1" {
  _make_valid_passport "$TEST_TEMP/p.json" '{"passport_version":"1.0","issued_at":"t","issuer":{"runtime":"codex","run_id":"r1"},"project":{"project_key":"demo"},"run":{"run_kind":"headless","status":"succeeded"}}'
  jq '.run.status = "tampered"' "$TEST_TEMP/p.json" > "$TEST_TEMP/p2.json"
  run ctl__passport_import --file "$TEST_TEMP/p2.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"一致しません"* ]]
}
@test "ctl__passport_import: DB 接続不可は rc=3" {
  _make_valid_passport "$TEST_TEMP/p.json" '{"passport_version":"1.0","issued_at":"t","issuer":{"runtime":"codex","run_id":"r1"},"project":{"project_key":"demo"},"run":{"run_kind":"headless","status":"succeeded"}}'
  make_stub_bin pg_isready 'exit 1'
  run ctl__passport_import --file "$TEST_TEMP/p.json"
  [ "$status" -eq 3 ]
}
@test "ctl__passport_import: 正常系は run_id を返す" {
  export PROJECT_ID_STUB="pppp" RUN_ID_STUB="rrrr9999-0000-0000-0000-000000000000"
  _make_valid_passport "$TEST_TEMP/p.json" '{"passport_version":"1.0","issued_at":"t","issuer":{"runtime":"codex","run_id":"r1"},"project":{"project_key":"demo"},"run":{"run_kind":"headless","status":"succeeded","git_head_sha":"abc","summary":"done"}}'
  run ctl__passport_import --file "$TEST_TEMP/p.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"rrrr9999"* ]]
  grep -q "'headless'" "$PSQL_LOG"
}
@test "ctl__passport_import: 未知の run_kind は manual へ丸められる" {
  export PROJECT_ID_STUB="pppp" RUN_ID_STUB="rrrr0000-0000-0000-0000-000000000000"
  _make_valid_passport "$TEST_TEMP/p.json" '{"passport_version":"1.0","issued_at":"t","issuer":{"runtime":"codex","run_id":"r1"},"project":{"project_key":"demo"},"run":{"run_kind":"codex-native","status":"succeeded"}}'
  run ctl__passport_import --file "$TEST_TEMP/p.json"
  [ "$status" -eq 0 ]
  grep -q "'manual'" "$PSQL_LOG"
  ! grep -q "'codex-native'" "$PSQL_LOG"
}
@test "task-passport.schema.json は妥当な JSON Schema (JSON として parse できる)" {
  run jq -e '.["$schema"] and .required and .properties' "$REPO_ROOT/docs/architecture/task-passport.schema.json"
  [ "$status" -eq 0 ]
}

# ---- units (systemd unit 生成、A2A Gateway 含む) --------------------
@test "control-db.sh units: 引数不足は non-zero" {
  run bash "$REPO_ROOT/bin/control-db.sh" units onlyproject
  [ "$status" -ne 0 ]
}
@test "control-db.sh units: --with-a2a-gateway 無しでは a2a-gateway.service を生成しない" {
  export CCSU_CONTROL_UNITS_DIR="$TEST_TEMP/units1"
  run bash "$REPO_ROOT/bin/control-db.sh" units demoproj ctltest
  [ "$status" -eq 0 ]
  [ -f "$CCSU_CONTROL_UNITS_DIR/claudeos-demoproj-control-projection.service" ]
  [ ! -f "$CCSU_CONTROL_UNITS_DIR/claudeos-demoproj-control-a2a-gateway.service" ]
}
@test "control-db.sh units --with-a2a-gateway: 127.0.0.1 限定の service を生成する" {
  export CCSU_CONTROL_UNITS_DIR="$TEST_TEMP/units2"
  run bash "$REPO_ROOT/bin/control-db.sh" units demoproj ctltest --with-a2a-gateway
  [ "$status" -eq 0 ]
  [ -f "$CCSU_CONTROL_UNITS_DIR/claudeos-demoproj-control-a2a-gateway.service" ]
  grep -q "IPAddressAllow=localhost" "$CCSU_CONTROL_UNITS_DIR/claudeos-demoproj-control-a2a-gateway.service"
  grep -q "IPAddressDeny=any" "$CCSU_CONTROL_UNITS_DIR/claudeos-demoproj-control-a2a-gateway.service"
  # "0.0.0.0 では listen しない" という説明コメント以外に、実際の bind 指定
  # (Environment 等) として 0.0.0.0 が出てこないことを確認する。
  ! grep -E '^[^#]*0\.0\.0\.0' "$CCSU_CONTROL_UNITS_DIR/claudeos-demoproj-control-a2a-gateway.service"
}
