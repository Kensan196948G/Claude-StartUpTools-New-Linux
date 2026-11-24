-- ============================================================
-- claudeos_control / 手動ロールバック 0006_ship_native.down.sql
--
-- *** 自動実行しない *** (ctl__migrate はこのディレクトリを読まない。
-- db/control/migrations/ の外に置いているのはそのため)。
-- 実行は Human Approval Gate (risk_category = 'destructive_data') の対象。
--
-- 対象: migration 0006 が作った物だけ。0001〜0005 の物・既存行には触れない。
--   * 0006 で作った表 / ビュー / 関数 / ドメイン / 索引 (idx_projects_remote_slug_lower)
--   * control.schema_migrations の version = '0006' の行
--   * 射影が control.projects / control.audit_events に書いた行は「残す」。
--     audit_events は追記専用 (トリガで行の除去不可) であり、projects は他機能も
--     参照しうるため。必要なら別途 Approval PR で扱う。
--
-- 手順 (必ず順に):
--   1) バックアップ (復元可能であることを先に確認する)
--        export PGHOST=/var/run/postgresql PG_BIN=/usr/lib/postgresql/16/bin
--        bash bin/pg-ops.sh backup claudeos_control           # pg_dump -Fc + sha256 + pg_restore --list 検証
--        bash bin/pg-ops.sh verify <出力された .dump>
--      (pg-ops が使えない場合: "$PG_BIN/pg_dump" -Fc -f /var/backups/claudeos/claudeos_control-pre-0006-down.dump claudeos_control)
--   2) 射影ワーカー (scripts/ship/project-to-db.js --apply) を停止する
--   3) 適用 (migrator 権限で):
--        "$PG_BIN/psql" -X -v ON_ERROR_STOP=1 -d claudeos_control \
--          -c 'SET ROLE claudeos_control_migrator' -f db/control/rollback/0006_ship_native.down.sql
--   4) 確認: SELECT version FROM control.schema_migrations ORDER BY 1;  → 0001..0005 のみ
--   5) 0006 を再適用する場合は ctl__migrate をそのまま実行すればよい (版 0006 は未適用扱いになる)
--
-- 注意: 実行すると Ship Native の射影データ (承認・品質評価・監査射影以外) は失われる。
--       正本はファイルストア ($CLAUDEOS_HOME/ship) なので、再適用後に射影を流し直せば復元できる。
-- ============================================================

BEGIN;

-- ビュー
DROP VIEW IF EXISTS control.v_ship_pr_latest;

-- 表 (参照される側を後に)
DROP TABLE IF EXISTS control.ship_session_usage;
DROP TABLE IF EXISTS control.recovery_events;
DROP TABLE IF EXISTS control.remediation_events;
DROP TABLE IF EXISTS control.review_findings;
DROP TABLE IF EXISTS control.merge_events;
DROP TABLE IF EXISTS control.approval_consumptions;
DROP TABLE IF EXISTS control.approval_revocations;
DROP TABLE IF EXISTS control.human_approvals;
DROP TABLE IF EXISTS control.ship_review_attestations;
DROP TABLE IF EXISTS control.gate_evaluations;
DROP TABLE IF EXISTS control.test_results;
DROP TABLE IF EXISTS control.quality_evaluations;
DROP TABLE IF EXISTS control.ship_state_transitions;
DROP TABLE IF EXISTS control.ship_sessions;
DROP TABLE IF EXISTS control.pull_requests;
DROP TABLE IF EXISTS control.policy_versions;
DROP TABLE IF EXISTS control.ship_run_states;

-- 既存 control.projects に足した索引のみ除去 (表本体は残す)
DROP INDEX IF EXISTS control.idx_projects_remote_slug_lower;

-- 関数
DROP FUNCTION IF EXISTS control.ship_pull_request_id(text, integer);
DROP FUNCTION IF EXISTS control.ship_project_id(text);
DROP FUNCTION IF EXISTS control.ensure_append_only_trigger(text, text);
DROP FUNCTION IF EXISTS control.ship_block_mutation();
DROP FUNCTION IF EXISTS control.jsonb_free_of_credentials(jsonb);

-- ドメイン (表を除去した後でないと依存で失敗する)
DROP DOMAIN IF EXISTS control.ship_record_id;
DROP DOMAIN IF EXISTS control.ship_repo;
DROP DOMAIN IF EXISTS control.git_sha40;

-- 台帳から 0006 を外す (version 一致の 1 行のみ)
DELETE FROM control.schema_migrations WHERE version = '0006';

COMMIT;
