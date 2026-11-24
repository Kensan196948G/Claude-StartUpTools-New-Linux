#!/usr/bin/env bats
# ============================================================
# control-db-0006.bats — migration 0006_ship_native.sql の静的検査 (DB 不要)
#
# 検証観点:
#   - 命名規約 (NNNN_name.sql) と migration 台帳への INSERT / BEGIN・COMMIT / checksum 既定値
#   - pg__migration_risk が additive と判定する (破壊的 SQL を含まない)
#   - 既存テーブルへ ALTER TABLE をかけない (追加のみ)
#   - 追記専用表にはトリガが付き、app ロールへ UPDATE を付与しない
#   - nonce の UNIQUE (DB 側リプレイ防止) と SHA ドメインの存在
#   - 手動ロールバックは migrations/ の外にあり ctl__migrate の列挙対象にならない
#   - ロールバックは 0006 で作った物だけを対象にし、バックアップ手順を明記している
# ============================================================

bats_require_minimum_version 1.5.0
load '../helpers/common-setup'

setup() {
  _bats_common_setup
  MIG="$REPO_ROOT/db/control/migrations/0006_ship_native.sql"
  DOWN="$REPO_ROOT/db/control/rollback/0006_ship_native.down.sql"
}
teardown() { _bats_common_teardown; }

@test "0006: 命名規約・トランザクション・台帳 INSERT が既存 migration と同じ形" {
  [ -f "$MIG" ]
  [[ "$(basename "$MIG")" =~ ^[0-9]{4}_[a-z0-9_]+\.sql$ ]]
  grep -q '^\\if :{?checksum}' "$MIG"
  grep -q "^\\\\set checksum 'unverified'" "$MIG"
  grep -q '^BEGIN;$' "$MIG"
  grep -q '^COMMIT;$' "$MIG"
  grep -q "VALUES ('0006', '0006_ship_native.sql', :'checksum')" "$MIG"
}

@test "0006: pg__migration_risk は additive と判定する" {
  # shellcheck disable=SC1091
  source "$REPO_ROOT/lib/postgres.sh"
  run pg__migration_risk "$MIG"
  [ "$status" -eq 0 ]
  [[ "$output" == *"none (additive"* ]]
}

@test "0006: ALTER TABLE / CREATE EXTENSION を使わない" {
  run grep -inE '\balter[[:space:]]+table\b|\bcreate[[:space:]]+extension\b' "$MIG"
  [ "$status" -eq 1 ]
}

@test "0006: 追記専用表には append-only トリガがあり app へ UPDATE を付与しない" {
  local t
  for t in ship_state_transitions quality_evaluations test_results gate_evaluations \
           ship_review_attestations human_approvals approval_revocations \
           approval_consumptions merge_events remediation_events recovery_events; do
    grep -q "ensure_append_only_trigger('control', '$t')" "$MIG" || { echo "missing trigger: $t"; return 1; }
  done
  # 追記専用表の GRANT ブロックは SELECT, INSERT のみで UPDATE を revoke している
  grep -q "PERFORM control.grant_if_role('claudeos_control_app', 'SELECT, INSERT'," "$MIG"
  grep -q "PERFORM control.revoke_if_role('claudeos_control_app', 'UPDATE'," "$MIG"
}

@test "0006: nonce の UNIQUE と 40 桁 SHA ドメインがある" {
  grep -q 'CONSTRAINT uq_human_approvals_nonce UNIQUE (nonce)' "$MIG"
  grep -q 'CONSTRAINT uq_approval_consumptions_nonce    UNIQUE (nonce)' "$MIG"
  grep -q 'CONSTRAINT uq_quality_evaluations_eval UNIQUE (eval_id)' "$MIG"
  grep -q "CHECK (VALUE ~ '^\[0-9a-f\]{40}\$')" "$MIG"
}

@test "0006: 秘密を保持する列名を作らない (hmac / private_key / passphrase / token / password)" {
  run grep -inE '^[[:space:]]+(hmac|private_?key|passphrase|token|password|secret)[[:space:]]+[a-z]' "$MIG"
  [ "$status" -eq 1 ]
}

@test "rollback: migrations/ の外にあり ctl__migrate の列挙対象にならない" {
  [ -f "$DOWN" ]
  run find "$REPO_ROOT/db/control/migrations" -maxdepth 1 -name '*down*'
  [ -z "$output" ]
  grep -q '自動実行しない' "$DOWN"
  grep -q 'pg_dump' "$DOWN"
  grep -q "DELETE FROM control.schema_migrations WHERE version = '0006';" "$DOWN"
}

@test "rollback: 0001〜0005 の表を DROP しない" {
  local t
  for t in projects tasks runs run_steps approvals approval_decisions audit_events \
           model_usage eval_results policy_changes schema_migrations; do
    run grep -nE "DROP TABLE IF EXISTS control\.${t};" "$DOWN"
    [ "$status" -eq 1 ] || { echo "rollback drops existing table: $t"; return 1; }
  done
}

@test "rollback: 0006 で CREATE した表はすべて DROP 対象に含まれる" {
  local t
  while IFS= read -r t; do
    grep -q "DROP TABLE IF EXISTS control.${t};" "$DOWN" || { echo "not dropped: $t"; return 1; }
  done < <(grep -oE 'CREATE TABLE IF NOT EXISTS control\.[a-z_]+' "$MIG" | sed 's/.*control\.//')
}
