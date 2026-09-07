#!/usr/bin/env bats
# ============================================================
# postgres.bats — lib/postgres.sh のユニットテスト (PATH スタブで密閉)
#
# 検証観点:
#   - bin dir 解決 (PG_BIN > pg_lsclusters 版 > PATH)
#   - backup: dump + sha256 + latest symlink + retention prune、失敗時の後始末
#   - verify: 「存在するだけ」は失敗 (sha256 不一致 / pg_restore --list 空)
#   - freshness: 期限超過は FAIL
#   - restore drill: *_recovery 以外を拒否 / 同名拒否
#   - migration-risk: 破壊的 SQL 検出 (WHERE 付き DELETE は除外)
#   - status json / diag-postgres --json
# ============================================================

load '../helpers/common-setup'

setup() {
  _bats_common_setup
  export CCSU_HOME="$TEST_TEMP/home"
  export CCSU_PG_STATE_DIR="$TEST_TEMP/state"
  export CCSU_PG_BACKUP_ROOT="$TEST_TEMP/backups"
  export PGHOST="$TEST_TEMP/sock"
  export PG_BIN="$STUB_BIN"   # 実 /usr/lib/postgresql/<ver>/bin を使わず PATH スタブへ固定
  # 偽 pg クライアント群
  make_stub_bin pg_lsclusters 'printf "Ver Cluster Port Status Owner Data\n16  main 5432 online postgres /x\n"'
  make_stub_bin pg_isready 'exit 0'
  make_stub_bin pg_dump 'out=""; while [ $# -gt 0 ]; do case "$1" in -f) out="$2"; shift 2;; *) shift;; esac; done; printf "PGDMP-fake-archive\n" > "$out"'
  make_stub_bin pg_restore 'case "$1" in --list) f="$2"; grep -q PGDMP "$f" && printf ";\n; Archive\n1; 0 0 TABLE public items\n2; 0 0 TABLE public tags\n" ;; *) exit 0;; esac'
  make_stub_bin psql 'echo 1'
  source "$REPO_ROOT/lib/common.sh"
  source "$REPO_ROOT/lib/postgres.sh"
}
teardown() { _bats_common_teardown; }

# ---- bin dir ---------------------------------------------
@test "pg__bin_dir: PG_BIN が最優先" { PG_BIN=/opt/pg/bin run pg__bin_dir; [ "$output" = "/opt/pg/bin" ]; }
@test "pg__bin_dir: PG_BIN 未指定なら pg_lsclusters の版に対応する bin dir か pg_config/PATH" { unset PG_BIN; run pg__bin_dir; [ "$status" -eq 0 ]; }
@test "pg__server_version: pg_lsclusters の online 版を返す" { run pg__server_version; [ "$output" = "16" ]; }
@test "pg__cmd: bin dir が無い場合は PATH 名を返す" { PG_BIN="$TEST_TEMP/nope" run pg__cmd pg_dump; [ "$output" = "pg_dump" ]; }

# ---- backup ----------------------------------------------
@test "pg__backup: dump + sha256 + latest symlink を作成しパスを出力" {
  run pg__backup mydb "$TEST_TEMP/bk"
  [ "$status" -eq 0 ]
  [[ "$output" == "$TEST_TEMP/bk/mydb-"*".dump" ]]
  [ -f "$output.sha256" ]
  [ "$(readlink "$TEST_TEMP/bk/latest.dump")" = "$(basename "$output")" ]
  [ "$(stat -c %a "$output")" = "600" ]
}
@test "pg__backup: pg_dump 失敗時はファイルを残さず非0" {
  make_stub_bin pg_dump 'echo "connection refused" >&2; exit 1'
  run pg__backup mydb "$TEST_TEMP/bk"
  [ "$status" -ne 0 ]
  [ -z "$(find "$TEST_TEMP/bk" -name '*.dump' 2>/dev/null)" ]
}
@test "pg__backup: retention 超過分を prune する" {
  mkdir -p "$TEST_TEMP/bk"; touch -d '30 days ago' "$TEST_TEMP/bk/mydb-20260101T000000Z.dump"
  run pg__backup mydb "$TEST_TEMP/bk" --retention-days 14
  [ "$status" -eq 0 ]
  [ ! -f "$TEST_TEMP/bk/mydb-20260101T000000Z.dump" ]
}

# ---- verify ----------------------------------------------
@test "pg__verify_backup: 存在しない / 空ファイルは失敗" {
  run pg__verify_backup "$TEST_TEMP/none.dump"; [ "$status" -ne 0 ]
  : > "$TEST_TEMP/empty.dump"; run pg__verify_backup "$TEST_TEMP/empty.dump"; [ "$status" -ne 0 ]
}
@test "pg__verify_backup: sha256 不一致は失敗" {
  f="$(pg__backup mydb "$TEST_TEMP/bk")"
  printf 'tampered' >> "$f"
  run pg__verify_backup "$f"; [ "$status" -ne 0 ]
}
@test "pg__verify_backup: pg_restore --list が空なら失敗 (存在するだけでは成功にしない)" {
  f="$(pg__backup mydb "$TEST_TEMP/bk")"
  make_stub_bin pg_restore 'exit 0'
  run pg__verify_backup "$f"; [ "$status" -ne 0 ]
}

# ---- freshness -------------------------------------------
@test "pg__backup_freshness: 期限内は fresh、超過は FAIL" {
  pg__backup mydb "$TEST_TEMP/bk" >/dev/null
  run pg__backup_freshness "$TEST_TEMP/bk" mydb 26; [ "$status" -eq 0 ]; [[ "$output" == fresh:* ]]
  touch -d '3 days ago' "$TEST_TEMP/bk"/mydb-*.dump
  run pg__backup_freshness "$TEST_TEMP/bk" mydb 26; [ "$status" -ne 0 ]
}
@test "pg__backup_freshness: バックアップ無しは失敗" { run pg__backup_freshness "$TEST_TEMP/nobk" mydb; [ "$status" -ne 0 ]; }

# ---- restore drill safety --------------------------------
@test "pg__restore_drill: 復元先が *_recovery でなければ拒否 (rc=2)" {
  f="$(pg__backup mydb "$TEST_TEMP/bk")"
  run pg__restore_drill mydb "$f" --recovery-db mydb_prod; [ "$status" -eq 2 ]
}
@test "pg__restore_drill: 元 DB と同名は拒否" {
  f="$(pg__backup mydb_recovery "$TEST_TEMP/bk")"
  run pg__restore_drill mydb_recovery "$f" --recovery-db mydb_recovery; [ "$status" -eq 2 ]
}
@test "pg__restore_drill: psql スタブで PASS し結果 JSON を記録" {
  f="$(pg__backup mydb "$TEST_TEMP/bk")"
  make_stub_bin psql 'case "$*" in *quote_ident*) printf "public.items\n";; *count*) echo 1;; *) echo 0;; esac'
  run pg__restore_drill mydb "$f"
  [ "$status" -eq 0 ]
  [[ "$output" == *"restore drill PASS"* ]]
  jq -e '.result == "PASS" and .recovery_db == "mydb_recovery"' "$CCSU_PG_STATE_DIR/drill-mydb.json"
}

# ---- migration risk --------------------------------------
@test "pg__migration_risk: additive のみは 0" {
  mkdir -p "$TEST_TEMP/mig"; printf 'alter table t add column c text;\ncreate index i on t(c);\ndelete from t where id = 1;\n' > "$TEST_TEMP/mig/a.sql"
  run pg__migration_risk "$TEST_TEMP/mig"; [ "$status" -eq 0 ]
}
@test "pg__migration_risk: DROP / TRUNCATE / 条件なし DELETE は HUMAN_APPROVAL (rc=1)" {
  mkdir -p "$TEST_TEMP/mig"; printf 'DROP TABLE t;\n' > "$TEST_TEMP/mig/b.sql"
  run pg__migration_risk "$TEST_TEMP/mig"; [ "$status" -eq 1 ]; [[ "$output" == *HUMAN_APPROVAL* ]]
  printf 'truncate t;\n' > "$TEST_TEMP/mig/b.sql"; run pg__migration_risk "$TEST_TEMP/mig"; [ "$status" -eq 1 ]
  printf 'delete from t;\n' > "$TEST_TEMP/mig/b.sql"; run pg__migration_risk "$TEST_TEMP/mig"; [ "$status" -eq 1 ]
}

# ---- status / diag ---------------------------------------
@test "pg__status_json: 妥当な JSON で health と backup_fresh を返す" {
  pg__backup mydb "$TEST_TEMP/bk" >/dev/null
  run pg__status_json mydb "$TEST_TEMP/bk"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.db == "mydb" and .health == true and .backup_fresh == true'
}
@test "diag-postgres.sh --json: backup root 配下の DB を配列で返す" {
  pg__backup mydb "$CCSU_PG_BACKUP_ROOT/mydb" >/dev/null
  run bash "$REPO_ROOT/libexec/diag-postgres.sh" --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'length == 1 and .[0].db == "mydb"'
}
@test "pg-ops.sh: 引数不足は非0" { run bash "$REPO_ROOT/bin/pg-ops.sh" backup; [ "$status" -ne 0 ]; }
