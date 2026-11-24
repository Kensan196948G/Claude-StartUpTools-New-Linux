-- ============================================================
-- claudeos_control / migration 0006_ship_native.sql
--
-- 目的: ClaudeOS v5.0 "Ship Native" の射影先。PR 単位の Ship セッション
--       (状態機械)、Local Quality Engine の証跡 (品質評価 / テスト結果)、
--       AI Quality Gate の判定 (リスク R0..R4 を列で保持)、署名済み
--       Human Approval / 取り消し / nonce 使用記録、マージ観測、
--       レビュー指摘 / 修正 / 復旧イベント、ポリシー版。
-- 前提: 0001〜0005 が適用済みであること。
--
-- 正本と射影の関係 (重要):
--   Ship Native の正本はファイルストア (scripts/ship/lib/store.js、
--   $CLAUDEOS_HOME/ship/**) である。本 migration のテーブルは
--   scripts/ship/project-to-db.js が冪等に書き込む「検索・監査用の射影」
--   であり、マージ可否の判定には使わない (判定は署名検証済みファイルで行う)。
--
-- 既存テーブルの再利用 (詳細: docs/architecture/SHIP_DATA_MODEL.md):
--   control.projects      リポジトリ (owner/repo) 単位の project。remote_slug で突合
--   control.audit_events  audit.jsonl の各行 (action = 'ship.<event>')。追記専用のまま
--   control.runs          ship_sessions.control_run_id で任意に紐付け (状態語彙が
--                         run_statuses と合わないため run 本体は別テーブル)
--   control.model_usage   利用量の数量は既存表を使い、ship_session_usage で紐付け
--   control.approvals は再利用しない: nonce / 署名 / key_id / base_sha / R0..R4 を
--   型付き列 + UNIQUE で持てず、かつ status 遷移で UPDATE される可変表であり、
--   署名済み承認の追記専用性と両立しないため。
--
-- 設計規約 (0001 と同じ):
--   追加のみ。既存列の変更・既存行の破壊をしない。拡張機能を要求しない。
--   秘密情報を保存しない (署名は公開検証値なので text で保持してよい。
--   HMAC 鍵・秘密鍵・passphrase の列は作らない)。
--   SHA は全て 40 桁小文字 hex (control.git_sha40 ドメイン)。
--   追記専用テーブルは BEFORE UPDATE OR DELETE トリガで全ロールに対して
--   行の書き換えを拒否し、さらに claudeos_control_app へ UPDATE を付与しない。
--
-- 手動ロールバック: db/control/rollback/0006_ship_native.down.sql (自動実行しない)
-- ============================================================

\if :{?checksum}
\else
\set checksum 'unverified'
\endif

BEGIN;

-- ------------------------------------------------------------
-- ドメイン
-- ------------------------------------------------------------
DO $do$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
     WHERE n.nspname = 'control' AND t.typname = 'git_sha40'
  ) THEN
    CREATE DOMAIN control.git_sha40 AS text
      CONSTRAINT git_sha40_format CHECK (VALUE ~ '^[0-9a-f]{40}$');
    COMMENT ON DOMAIN control.git_sha40 IS
      'git commit SHA (40 桁小文字 hex)。短縮 SHA は受け付けない。';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
     WHERE n.nspname = 'control' AND t.typname = 'ship_repo'
  ) THEN
    -- store.js の REPO_RE と同一 + '..' を禁止
    CREATE DOMAIN control.ship_repo AS text
      CONSTRAINT ship_repo_format CHECK (
        VALUE ~ '^[A-Za-z0-9_.-]{1,100}/[A-Za-z0-9_.-]{1,100}$'
        AND position('..' in VALUE) = 0
      );
    COMMENT ON DOMAIN control.ship_repo IS 'GitHub の owner/repo のみ。URL・token を含めない。';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
     WHERE n.nspname = 'control' AND t.typname = 'ship_record_id'
  ) THEN
    -- store.js の ID_RE と同一 (run_id / eval_id / approval_id / nonce 等)
    CREATE DOMAIN control.ship_record_id AS text
      CONSTRAINT ship_record_id_format CHECK (VALUE ~ '^[A-Za-z0-9_-]{6,80}$');
  END IF;
END
$do$;

-- ------------------------------------------------------------
-- 共通ヘルパ
-- ------------------------------------------------------------

-- jsonb_free_of_credentials — jsonb 列の秘密混入ガード (0001/0003 の CHECK と同じ規則)
CREATE OR REPLACE FUNCTION control.jsonb_free_of_credentials(p jsonb)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog
AS $fn$
  SELECT p IS NULL OR (
    p::text !~* '(-----BEGIN [A-Z ]*PRIVATE KEY-----|sk-ant-|github_pat_|ghp_[A-Za-z0-9]{10}|AKIA[0-9A-Z]{16})'
    AND p::text !~* '(postgres(ql)?|mysql|mongodb(\+srv)?|redis)://[^"[:space:]]*:[^"[:space:]]*@'
  );
$fn$;

-- ship_block_mutation — 追記専用テーブルの行の書き換えを全ロールで拒否する
CREATE OR REPLACE FUNCTION control.ship_block_mutation()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog
AS $fn$
BEGIN
  RAISE EXCEPTION
    'control.% は追記専用です (操作 % は許可されません)', TG_TABLE_NAME, TG_OP
    USING ERRCODE = '0A000',
          HINT = '訂正は新しい行 (取り消し・再評価) を追記して表現してください。';
END
$fn$;

-- ensure_append_only_trigger — CREATE TRIGGER の冪等化 (ensure_touch_trigger と同型)
CREATE OR REPLACE FUNCTION control.ensure_append_only_trigger(
  p_schema text, p_table text
) RETURNS void
LANGUAGE plpgsql
SET search_path = pg_catalog
AS $fn$
DECLARE
  v_trg text := 'trg_append_only_' || p_table;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger tg
      JOIN pg_class c     ON c.oid = tg.tgrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = p_schema AND c.relname = p_table AND tg.tgname = v_trg
  ) THEN
    EXECUTE format(
      'CREATE TRIGGER %I BEFORE UPDATE OR DELETE ON %I.%I FOR EACH ROW EXECUTE FUNCTION control.ship_block_mutation()',
      v_trg, p_schema, p_table);
  END IF;
END
$fn$;

-- 既存 control.projects を remote_slug (大文字小文字無視) で引くための索引。
-- 既存テーブルへの索引追加のみ (列・制約は変更しない)。
CREATE INDEX IF NOT EXISTS idx_projects_remote_slug_lower
  ON control.projects (lower(remote_slug)) WHERE remote_slug IS NOT NULL;

-- ------------------------------------------------------------
-- 語彙: Ship run の状態 (scripts/ship/lib/state-machine.js STATES と一致)
--   CHECK ではなく lookup + FK (0001 の方針: 語彙追加を INSERT だけで完結させる)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS control.ship_run_states (
  state       text PRIMARY KEY CHECK (state ~ '^[A-Z][A-Z_]{1,40}$'),
  is_terminal boolean     NOT NULL DEFAULT false,
  sort_order  smallint    NOT NULL DEFAULT 0,
  description text        NOT NULL DEFAULT '',
  created_at  timestamptz NOT NULL DEFAULT now()
);
INSERT INTO control.ship_run_states (state, is_terminal, sort_order, description) VALUES
  ('IDLE',                    false,  10, '未開始'),
  ('DISCOVERY',               false,  20, '現状調査'),
  ('PLANNING',                false,  30, '計画'),
  ('IMPLEMENTING',            false,  40, '実装'),
  ('LOCAL_TESTING',           false,  50, 'Local Quality Engine 実行'),
  ('LOCAL_REMEDIATION',       false,  60, 'ローカル失敗の修正'),
  ('PR_CREATING',             false,  70, 'PR 作成'),
  ('SHIP_STARTING',           false,  80, '/ship 開始待ち (人が対話セッションで入力)'),
  ('SHIP_REVIEWING',          false,  90, '/ship レビュー中'),
  ('SHIP_REMEDIATING',        false, 100, 'レビュー指摘の修正'),
  ('SHIP_REVALIDATING',       false, 110, '再検証 (head 変更・承認失効を含む)'),
  ('QUALITY_EVALUATING',      false, 120, 'AI Quality Gate 判定中'),
  ('QUALITY_FAILED',          false, 130, 'AI Quality Gate 不合格'),
  ('HUMAN_APPROVAL_REQUIRED', false, 140, '署名付き人間承認待ち'),
  ('HUMAN_APPROVED',          false, 150, '承認検証済み'),
  ('MERGE_QUEUED',            false, 160, 'auto-merge 登録済み'),
  ('MERGING',                 false, 170, 'マージ実行中'),
  ('MERGED',                  false, 180, 'GitHub 再取得で merged を確認'),
  ('COMPLETED',               true,  190, '完了'),
  ('BLOCKED',                 false, 200, '人間判断待ち (再開可能)'),
  ('FAILED',                  true,  210, '失敗'),
  ('STOPPED',                 true,  220, '利用者が停止')
ON CONFLICT (state) DO NOTHING;

-- ------------------------------------------------------------
-- control.policy_versions — config/ship-policy.json の policyVersion
--   射影は各レコードが参照する版を ON CONFLICT DO NOTHING で登録する。
--   content_sha256 は --policy-file を渡したときだけ埋まる (既存値は上書きしない)。
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS control.policy_versions (
  policy_version text PRIMARY KEY
                 CHECK (policy_version ~ '^[0-9A-Za-z][0-9A-Za-z._+-]{0,63}$'),
  policy_schema  text CHECK (policy_schema IS NULL
                             OR policy_schema ~ '^[a-z0-9][a-z0-9._/-]{0,95}$'),
  content_sha256 text CHECK (content_sha256 IS NULL
                             OR content_sha256 ~ '^[0-9a-f]{64}$'),
  source_ref     control.safe_text,
  first_seen_at  timestamptz NOT NULL DEFAULT now(),
  created_at     timestamptz NOT NULL DEFAULT now()
);

-- ------------------------------------------------------------
-- control.pull_requests — PR の同一性のみ (head は評価ごとに各表が持つ)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS control.pull_requests (
  pull_request_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id      uuid NOT NULL
                  REFERENCES control.projects (project_id) ON DELETE RESTRICT,
  repo            control.ship_repo NOT NULL,
  pr_number       integer NOT NULL CHECK (pr_number BETWEEN 1 AND 10000000),
  first_seen_at   timestamptz NOT NULL DEFAULT now(),
  created_at      timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_pull_requests_repo_number UNIQUE (repo, pr_number)
);
CREATE INDEX IF NOT EXISTS idx_pull_requests_project
  ON control.pull_requests (project_id, pr_number DESC);

-- 射影 SQL を読みやすくする参照関数 (見つからなければ NULL → NOT NULL 違反で失敗させる)
CREATE OR REPLACE FUNCTION control.ship_project_id(p_repo text)
RETURNS uuid
LANGUAGE sql
STABLE
SET search_path = pg_catalog
AS $fn$
  SELECT p.project_id
    FROM control.projects p
   WHERE lower(p.remote_slug) = lower(p_repo)
   ORDER BY p.created_at, p.project_id
   LIMIT 1;
$fn$;

CREATE OR REPLACE FUNCTION control.ship_pull_request_id(p_repo text, p_pr integer)
RETURNS uuid
LANGUAGE sql
STABLE
SET search_path = pg_catalog
AS $fn$
  SELECT pr.pull_request_id
    FROM control.pull_requests pr
   WHERE pr.repo::text = p_repo AND pr.pr_number = p_pr;
$fn$;

-- ------------------------------------------------------------
-- control.ship_sessions — Ship Native run (runs/<run_id>.json) の最新スナップショット
--   可変 (射影は source_updated_at が新しい時だけ上書きする)。
--   状態遷移の履歴は ship_state_transitions (追記専用) に持つ。
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS control.ship_sessions (
  ship_session_id   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  ship_run_id       control.ship_record_id NOT NULL,
  project_id        uuid NOT NULL
                    REFERENCES control.projects (project_id) ON DELETE RESTRICT,
  pull_request_id   uuid REFERENCES control.pull_requests (pull_request_id)
                    ON DELETE RESTRICT,
  -- 既存 control.runs との任意の紐付け (supervisor 等が run を発行した場合)
  control_run_id    uuid REFERENCES control.runs (run_id) ON DELETE SET NULL,
  repo              control.ship_repo NOT NULL,
  -- ローカル絶対パスのみ
  project_dir       control.safe_text,
  mode              text NOT NULL
                    CHECK (mode IN ('SH1','SH2','SH3','SH4','SH5','QC','HG')),
  state             text NOT NULL REFERENCES control.ship_run_states (state),
  head_sha          control.git_sha40,
  base_sha          control.git_sha40,
  branch            text CHECK (branch IS NULL
                                OR (length(branch) BETWEEN 1 AND 255
                                    AND branch !~ '[[:space:][:cntrl:]]')),
  ship_capability   text CHECK (ship_capability IS NULL
                                OR ship_capability ~ '^[A-Za-z0-9_.-]{1,64}$'),
  ship_status       text CHECK (ship_status IS NULL
                                OR ship_status ~ '^[A-Za-z0-9_.-]{1,64}$'),
  retries           integer NOT NULL DEFAULT 0 CHECK (retries >= 0),
  source_created_at timestamptz NOT NULL,
  source_updated_at timestamptz NOT NULL,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_ship_sessions_run UNIQUE (ship_run_id),
  CONSTRAINT ck_ship_sessions_time
    CHECK (source_updated_at >= source_created_at)
);
SELECT control.ensure_touch_trigger('control', 'ship_sessions');

CREATE INDEX IF NOT EXISTS idx_ship_sessions_project_recent
  ON control.ship_sessions (project_id, source_updated_at DESC);
CREATE INDEX IF NOT EXISTS idx_ship_sessions_pr
  ON control.ship_sessions (pull_request_id) WHERE pull_request_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_ship_sessions_state
  ON control.ship_sessions (state, source_updated_at DESC);

-- ------------------------------------------------------------
-- control.ship_state_transitions — run.history[] (追記専用)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS control.ship_state_transitions (
  transition_id    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  ship_session_id  uuid NOT NULL
                   REFERENCES control.ship_sessions (ship_session_id) ON DELETE RESTRICT,
  seq              integer NOT NULL CHECK (seq >= 0),
  from_state       text NOT NULL REFERENCES control.ship_run_states (state),
  to_state         text NOT NULL REFERENCES control.ship_run_states (state),
  transitioned_at  timestamptz NOT NULL,
  evidence         jsonb NOT NULL DEFAULT '{}'::jsonb
                   CHECK (jsonb_typeof(evidence) = 'object'
                          AND control.jsonb_free_of_credentials(evidence)),
  created_at       timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_ship_state_transitions_seq UNIQUE (ship_session_id, seq)
);
SELECT control.ensure_append_only_trigger('control', 'ship_state_transitions');

CREATE INDEX IF NOT EXISTS idx_ship_state_transitions_to
  ON control.ship_state_transitions (to_state, transitioned_at DESC);

-- ------------------------------------------------------------
-- control.quality_evaluations — Local Quality Engine の 1 回の実行
--   (= local test run。証跡 quality/<slug>/<sha>/<eval_id>.json に対応、追記専用)
--   HMAC 値・HMAC 鍵は保存しない。evidence_hash (内容 sha256) のみ。
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS control.quality_evaluations (
  quality_evaluation_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  eval_id          control.ship_record_id NOT NULL,
  project_id       uuid NOT NULL
                   REFERENCES control.projects (project_id) ON DELETE RESTRICT,
  pull_request_id  uuid REFERENCES control.pull_requests (pull_request_id)
                   ON DELETE RESTRICT,
  repo             control.ship_repo NOT NULL,
  head_sha         control.git_sha40 NOT NULL,
  base_sha         control.git_sha40,
  profile          text CHECK (profile IS NULL
                               OR profile ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'),
  policy_version   text REFERENCES control.policy_versions (policy_version),
  isolation        control.safe_text,
  runner_host      control.safe_text,
  verdict          text NOT NULL CHECK (verdict IN ('PASS','FAIL','UNKNOWN')),
  reasons          jsonb NOT NULL DEFAULT '[]'::jsonb
                   CHECK (jsonb_typeof(reasons) = 'array'
                          AND control.jsonb_free_of_credentials(reasons)),
  evidence_hash    text NOT NULL CHECK (evidence_hash ~ '^[0-9a-f]{64}$'),
  started_at       timestamptz NOT NULL,
  finished_at      timestamptz,
  created_at       timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_quality_evaluations_eval UNIQUE (eval_id),
  CONSTRAINT ck_quality_evaluations_time
    CHECK (finished_at IS NULL OR finished_at >= started_at),
  -- PASS は完了した実行にしか付かない
  CONSTRAINT ck_quality_evaluations_pass_finished
    CHECK (verdict <> 'PASS' OR finished_at IS NOT NULL)
);
SELECT control.ensure_append_only_trigger('control', 'quality_evaluations');

CREATE INDEX IF NOT EXISTS idx_quality_evaluations_subject
  ON control.quality_evaluations (repo, head_sha, finished_at DESC);
CREATE INDEX IF NOT EXISTS idx_quality_evaluations_pr
  ON control.quality_evaluations (pull_request_id, finished_at DESC)
  WHERE pull_request_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_quality_evaluations_not_pass
  ON control.quality_evaluations (finished_at DESC) WHERE verdict <> 'PASS';

-- ------------------------------------------------------------
-- control.test_results — quality_evaluations.checks[] (追記専用)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS control.test_results (
  test_result_id   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  quality_evaluation_id uuid NOT NULL
                   REFERENCES control.quality_evaluations (quality_evaluation_id)
                   ON DELETE RESTRICT,
  check_seq        smallint NOT NULL CHECK (check_seq >= 0),
  check_id         text NOT NULL
                   CHECK (check_id ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'),
  category         text CHECK (category IS NULL
                               OR category ~ '^[a-z0-9][a-z0-9+_.-]{0,63}$'),
  command          control.safe_text,
  status           text NOT NULL CHECK (status IN ('PASS','FAIL','ERROR','NOT_RUN')),
  exit_code        integer,
  passed_count     integer CHECK (passed_count  IS NULL OR passed_count  >= 0),
  failed_count     integer CHECK (failed_count  IS NULL OR failed_count  >= 0),
  skipped_count    integer CHECK (skipped_count IS NULL OR skipped_count >= 0),
  duration_ms      integer NOT NULL DEFAULT 0 CHECK (duration_ms >= 0),
  reason           control.safe_text,
  -- ship home 相対のログ所在 (本文は保存しない)
  log_ref          control.safe_text,
  created_at       timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_test_results_seq UNIQUE (quality_evaluation_id, check_seq),
  -- quality.js と同じ規則: PASS は exit 0 かつ失敗件数 0
  CONSTRAINT ck_test_results_pass
    CHECK (status <> 'PASS' OR (exit_code = 0 AND coalesce(failed_count, 0) = 0))
);
SELECT control.ensure_append_only_trigger('control', 'test_results');

CREATE INDEX IF NOT EXISTS idx_test_results_failing
  ON control.test_results (check_id, created_at DESC)
  WHERE status IN ('FAIL','ERROR');

-- ------------------------------------------------------------
-- control.gate_evaluations — AI Quality Gate の判定 (gates/<slug>/pr-N/<head>.json)
--   リスク分類 (R0..R4) は独立テーブルにせず列で持つ (判定と同時に確定するため)。
--   追記専用: 同一 head の再評価は evaluated_at の異なる新しい行になる。
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS control.gate_evaluations (
  gate_evaluation_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id       uuid NOT NULL
                   REFERENCES control.projects (project_id) ON DELETE RESTRICT,
  pull_request_id  uuid NOT NULL
                   REFERENCES control.pull_requests (pull_request_id) ON DELETE RESTRICT,
  repo             control.ship_repo NOT NULL,
  head_sha         control.git_sha40 NOT NULL,
  base_sha         control.git_sha40 NOT NULL,
  verdict          text NOT NULL
                   CHECK (verdict IN ('PASS','CONDITIONAL','FAIL','UNKNOWN','BLOCKED')),
  risk_level       text NOT NULL CHECK (risk_level IN ('R0','R1','R2','R3','R4')),
  risk_detail      jsonb NOT NULL DEFAULT '[]'::jsonb
                   CHECK (jsonb_typeof(risk_detail) = 'array'
                          AND control.jsonb_free_of_credentials(risk_detail)),
  reasons          jsonb NOT NULL DEFAULT '[]'::jsonb
                   CHECK (jsonb_typeof(reasons) = 'array'
                          AND control.jsonb_free_of_credentials(reasons)),
  checks           jsonb NOT NULL DEFAULT '[]'::jsonb
                   CHECK (jsonb_typeof(checks) = 'array'
                          AND control.jsonb_free_of_credentials(checks)),
  -- quality_evaluations.eval_id への弱参照 (証跡ファイルが欠けても判定記録は残す)
  quality_eval_id  control.ship_record_id,
  ship_source      control.safe_text,
  policy_version   text REFERENCES control.policy_versions (policy_version),
  gate_hash        text CHECK (gate_hash IS NULL OR gate_hash ~ '^[0-9a-f]{64}$'),
  evaluated_at     timestamptz NOT NULL,
  created_at       timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_gate_evaluations_subject
    UNIQUE (pull_request_id, head_sha, evaluated_at)
);
SELECT control.ensure_append_only_trigger('control', 'gate_evaluations');

CREATE INDEX IF NOT EXISTS idx_gate_evaluations_pr_recent
  ON control.gate_evaluations (pull_request_id, evaluated_at DESC);
CREATE INDEX IF NOT EXISTS idx_gate_evaluations_verdict
  ON control.gate_evaluations (verdict, evaluated_at DESC);
CREATE INDEX IF NOT EXISTS idx_gate_evaluations_risk
  ON control.gate_evaluations (risk_level, evaluated_at DESC);

-- ------------------------------------------------------------
-- control.ship_review_attestations — /ship 結果の人間署名付き証跡
--   (ship-evidence/<slug>/pr-N/*.json、追記専用、nonce は一意)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS control.ship_review_attestations (
  ship_review_attestation_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  attestation_id   control.ship_record_id NOT NULL,
  pull_request_id  uuid NOT NULL
                   REFERENCES control.pull_requests (pull_request_id) ON DELETE RESTRICT,
  repo             control.ship_repo NOT NULL,
  head_sha         control.git_sha40 NOT NULL,
  reviewed         boolean NOT NULL,
  review_effort    text CHECK (review_effort IS NULL
                               OR review_effort ~ '^[a-z0-9_-]{1,32}$'),
  important_open   integer NOT NULL CHECK (important_open >= 0),
  watch_status     text NOT NULL
                   CHECK (watch_status IN ('checks-pass-comments-answered','stopped',
                                           'not-started','running')),
  notes            control.safe_text,
  approver         control.safe_text NOT NULL,
  key_id           text NOT NULL CHECK (key_id ~ '^sha256:[0-9a-f]{64}$'),
  issued_at        timestamptz NOT NULL,
  nonce            control.ship_record_id NOT NULL,
  signature        text NOT NULL
                   -- base64 (PostgreSQL の正規表現は繰返し上限 255 のため長さは length で制約)
                   CHECK (signature ~ '^[A-Za-z0-9+/]+={0,2}$'
                          AND length(signature) BETWEEN 16 AND 2048),
  created_at       timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_ship_review_attestations_id    UNIQUE (attestation_id),
  CONSTRAINT uq_ship_review_attestations_nonce UNIQUE (nonce)
);
SELECT control.ensure_append_only_trigger('control', 'ship_review_attestations');

CREATE INDEX IF NOT EXISTS idx_ship_review_attestations_pr
  ON control.ship_review_attestations (pull_request_id, head_sha, issued_at DESC);

-- ------------------------------------------------------------
-- control.human_approvals — 署名済み Human Gate 承認 (追記専用)
--   approvals/<slug>/pr-N/<approval_id>.json に対応。
--   nonce の UNIQUE が DB 側のリプレイ防止 (同一 nonce の承認は 2 行目を拒否)。
--   署名は公開検証値 (Ed25519 等の base64)。秘密鍵・passphrase は保存しない。
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS control.human_approvals (
  human_approval_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  approval_id      control.ship_record_id NOT NULL,
  project_id       uuid NOT NULL
                   REFERENCES control.projects (project_id) ON DELETE RESTRICT,
  pull_request_id  uuid NOT NULL
                   REFERENCES control.pull_requests (pull_request_id) ON DELETE RESTRICT,
  repo             control.ship_repo NOT NULL,
  head_sha         control.git_sha40 NOT NULL,
  base_sha         control.git_sha40 NOT NULL,
  decision         text NOT NULL
                   CHECK (decision IN ('approve','approve-conditional','reject')),
  gate_verdict     text NOT NULL
                   CHECK (gate_verdict IN ('PASS','CONDITIONAL','FAIL','UNKNOWN','BLOCKED')),
  gate_hash        text CHECK (gate_hash IS NULL OR gate_hash ~ '^[0-9a-f]{64}$'),
  quality_eval_id  control.ship_record_id,
  quality_evidence_hash text CHECK (quality_evidence_hash IS NULL
                                    OR quality_evidence_hash ~ '^[0-9a-f]{64}$'),
  risk_level       text NOT NULL CHECK (risk_level IN ('R0','R1','R2','R3','R4')),
  approver         control.safe_text NOT NULL,
  key_id           text NOT NULL CHECK (key_id ~ '^sha256:[0-9a-f]{64}$'),
  issued_at        timestamptz NOT NULL,
  expires_at       timestamptz NOT NULL,
  nonce            control.ship_record_id NOT NULL,
  policy_version   text REFERENCES control.policy_versions (policy_version),
  signature        text NOT NULL
                   -- base64 (PostgreSQL の正規表現は繰返し上限 255 のため長さは length で制約)
                   CHECK (signature ~ '^[A-Za-z0-9+/]+={0,2}$'
                          AND length(signature) BETWEEN 16 AND 2048),
  created_at       timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_human_approvals_id    UNIQUE (approval_id),
  CONSTRAINT uq_human_approvals_nonce UNIQUE (nonce),
  -- approval_consumptions の複合 FK 先 (使用記録の nonce が承認の nonce と一致すること)
  CONSTRAINT uq_human_approvals_id_nonce UNIQUE (approval_id, nonce),
  CONSTRAINT ck_human_approvals_expiry CHECK (expires_at > issued_at),
  -- human-gate.issueApproval と同じ規則: 通常承認は gate PASS にしか出さない
  CONSTRAINT ck_human_approvals_approve_needs_pass
    CHECK (decision <> 'approve' OR gate_verdict = 'PASS')
);
SELECT control.ensure_append_only_trigger('control', 'human_approvals');

CREATE INDEX IF NOT EXISTS idx_human_approvals_subject
  ON control.human_approvals (pull_request_id, head_sha, base_sha);
CREATE INDEX IF NOT EXISTS idx_human_approvals_expiry
  ON control.human_approvals (expires_at DESC);

-- ------------------------------------------------------------
-- control.approval_revocations — 承認取り消し (revocations/<approval_id>.json、追記専用)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS control.approval_revocations (
  revocation_id    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  approval_id      control.ship_record_id NOT NULL
                   REFERENCES control.human_approvals (approval_id) ON DELETE RESTRICT,
  reason           control.safe_text NOT NULL DEFAULT '',
  actor            control.safe_text NOT NULL,
  revoked_at       timestamptz NOT NULL,
  created_at       timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_approval_revocations_approval UNIQUE (approval_id)
);
SELECT control.ensure_append_only_trigger('control', 'approval_revocations');

-- ------------------------------------------------------------
-- control.approval_consumptions — nonce の使用記録 (consumed/<nonce>、追記専用)
--   approval_id / nonce それぞれ UNIQUE: 1 承認は 1 回しか使えない。
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS control.approval_consumptions (
  consumption_id   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  approval_id      control.ship_record_id NOT NULL,
  nonce            control.ship_record_id NOT NULL,
  consumed_at      timestamptz NOT NULL,
  created_at       timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_approval_consumptions_approval UNIQUE (approval_id),
  CONSTRAINT uq_approval_consumptions_nonce    UNIQUE (nonce),
  CONSTRAINT fk_approval_consumptions_approval
    FOREIGN KEY (approval_id, nonce)
    REFERENCES control.human_approvals (approval_id, nonce) ON DELETE RESTRICT
);
SELECT control.ensure_append_only_trigger('control', 'approval_consumptions');

-- ------------------------------------------------------------
-- control.merge_events — マージ観測 (merges/<slug>/pr-N.json の各観測、追記専用)
--   confirmed = true は GitHub API 再取得で merged を確認したものだけ。
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS control.merge_events (
  merge_event_id   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id       uuid NOT NULL
                   REFERENCES control.projects (project_id) ON DELETE RESTRICT,
  pull_request_id  uuid NOT NULL
                   REFERENCES control.pull_requests (pull_request_id) ON DELETE RESTRICT,
  repo             control.ship_repo NOT NULL,
  state            text NOT NULL
                   CHECK (state IN ('MERGED','MERGED_UNEXPECTED_HEAD','MERGE_QUEUED',
                                    'OPEN','CLOSED','UNKNOWN')),
  confirmed        boolean NOT NULL DEFAULT false,
  merge_commit_sha control.git_sha40,
  head_sha         control.git_sha40,
  expected_head_sha control.git_sha40,
  reason           control.safe_text,
  observed_at      timestamptz NOT NULL,
  created_at       timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_merge_events_observation UNIQUE (pull_request_id, observed_at, state),
  -- confirmed は merge commit SHA を伴う MERGED 系だけ。逆向き (MERGED なら必ず
  -- confirmed) は課さない: GitHub が state=MERGED でも mergeCommit を返さない場合、
  -- merge.confirm() は confirmed=false のまま記録するため (= 未確認の観測として残す)。
  CONSTRAINT ck_merge_events_confirmed
    CHECK (NOT confirmed
           OR (merge_commit_sha IS NOT NULL
               AND state IN ('MERGED','MERGED_UNEXPECTED_HEAD')))
);
SELECT control.ensure_append_only_trigger('control', 'merge_events');

CREATE INDEX IF NOT EXISTS idx_merge_events_pr_recent
  ON control.merge_events (pull_request_id, observed_at DESC);

-- ------------------------------------------------------------
-- control.review_findings — /ship・AI Gate・人間・CI のレビュー指摘
--   v5.0 の store にはまだ指摘単位のレコードが無い (書き手は将来追加)。
--   状態 (open → addressed 等) が変わるため可変。fingerprint で重複を排除。
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS control.review_findings (
  finding_id       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  pull_request_id  uuid NOT NULL
                   REFERENCES control.pull_requests (pull_request_id) ON DELETE RESTRICT,
  head_sha         control.git_sha40,
  source           text NOT NULL
                   CHECK (source IN ('ship','ai_gate','human','ci','other')),
  external_ref     control.safe_text,
  -- 正規化した指摘内容の sha256
  fingerprint      text NOT NULL CHECK (fingerprint ~ '^[0-9a-f]{64}$'),
  severity         text NOT NULL DEFAULT 'medium'
                   CHECK (severity IN ('info','low','medium','high','critical')),
  is_important     boolean NOT NULL DEFAULT false,
  category         text CHECK (category IS NULL OR category ~ '^[a-z0-9][a-z0-9._-]{0,63}$'),
  file_path        control.safe_text,
  line_number      integer CHECK (line_number IS NULL OR line_number >= 1),
  title            control.safe_text NOT NULL,
  status           text NOT NULL DEFAULT 'open'
                   CHECK (status IN ('open','addressed','dismissed','wont_fix','stale')),
  resolved_at      timestamptz,
  detail           jsonb NOT NULL DEFAULT '{}'::jsonb
                   CHECK (control.jsonb_free_of_credentials(detail)),
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_review_findings_fingerprint UNIQUE (pull_request_id, fingerprint),
  CONSTRAINT ck_review_findings_resolved
    CHECK ((status = 'open') = (resolved_at IS NULL))
);
SELECT control.ensure_touch_trigger('control', 'review_findings');

CREATE INDEX IF NOT EXISTS idx_review_findings_open
  ON control.review_findings (pull_request_id, severity)
  WHERE status = 'open';

-- ------------------------------------------------------------
-- control.remediation_events — 修正ラウンド (追記専用、書き手は将来追加)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS control.remediation_events (
  remediation_event_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  ship_session_id  uuid REFERENCES control.ship_sessions (ship_session_id)
                   ON DELETE RESTRICT,
  pull_request_id  uuid REFERENCES control.pull_requests (pull_request_id)
                   ON DELETE RESTRICT,
  finding_id       uuid REFERENCES control.review_findings (finding_id)
                   ON DELETE RESTRICT,
  round            smallint NOT NULL CHECK (round >= 1),
  trigger_kind     text NOT NULL
                   CHECK (trigger_kind IN ('local_test','quality_gate','review_finding',
                                           'ci','human_request')),
  outcome          text NOT NULL
                   CHECK (outcome IN ('started','succeeded','failed','abandoned')),
  from_head_sha    control.git_sha40,
  to_head_sha      control.git_sha40,
  summary          control.safe_text,
  detail           jsonb NOT NULL DEFAULT '{}'::jsonb
                   CHECK (control.jsonb_free_of_credentials(detail)),
  occurred_at      timestamptz NOT NULL DEFAULT now(),
  idempotency_key  text NOT NULL DEFAULT gen_random_uuid()::text,
  created_at       timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_remediation_events_idem UNIQUE (idempotency_key),
  CONSTRAINT ck_remediation_events_subject
    CHECK (ship_session_id IS NOT NULL OR pull_request_id IS NOT NULL)
);
SELECT control.ensure_append_only_trigger('control', 'remediation_events');

CREATE INDEX IF NOT EXISTS idx_remediation_events_session
  ON control.remediation_events (ship_session_id, occurred_at DESC)
  WHERE ship_session_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_remediation_events_pr
  ON control.remediation_events (pull_request_id, occurred_at DESC)
  WHERE pull_request_id IS NOT NULL;

-- ------------------------------------------------------------
-- control.recovery_events — 復旧 (stale lock 回収 / head 変更による承認失効 /
--   gate 外マージ検出 / BLOCKED からの再開 等。追記専用、書き手は将来追加)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS control.recovery_events (
  recovery_event_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  ship_session_id  uuid REFERENCES control.ship_sessions (ship_session_id)
                   ON DELETE RESTRICT,
  project_id       uuid REFERENCES control.projects (project_id) ON DELETE RESTRICT,
  recovery_kind    text NOT NULL
                   CHECK (recovery_kind IN ('stale_lock','head_changed','merged_outside_gate',
                                            'resume_from_blocked','retry_backoff',
                                            'circuit_breaker','reconcile','other')),
  from_state       text REFERENCES control.ship_run_states (state),
  to_state         text REFERENCES control.ship_run_states (state),
  outcome          text NOT NULL DEFAULT 'success'
                   CHECK (outcome IN ('success','failure','skipped')),
  detail           jsonb NOT NULL DEFAULT '{}'::jsonb
                   CHECK (control.jsonb_free_of_credentials(detail)),
  occurred_at      timestamptz NOT NULL DEFAULT now(),
  idempotency_key  text NOT NULL DEFAULT gen_random_uuid()::text,
  created_at       timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_recovery_events_idem UNIQUE (idempotency_key)
);
SELECT control.ensure_append_only_trigger('control', 'recovery_events');

CREATE INDEX IF NOT EXISTS idx_recovery_events_time
  ON control.recovery_events (recovery_kind, occurred_at DESC);

-- ------------------------------------------------------------
-- control.ship_session_usage — 既存 control.model_usage と Ship セッションの紐付け
--   (数量・金額は model_usage が正。重複集計を避けるため 1 usage は 1 セッションのみ)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS control.ship_session_usage (
  usage_id         uuid PRIMARY KEY
                   REFERENCES control.model_usage (usage_id) ON DELETE CASCADE,
  ship_session_id  uuid NOT NULL
                   REFERENCES control.ship_sessions (ship_session_id) ON DELETE RESTRICT,
  created_at       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_ship_session_usage_session
  ON control.ship_session_usage (ship_session_id);

-- ------------------------------------------------------------
-- ダッシュボード用ビュー
--   参考表示用。マージ可否の判定は署名検証済みファイル (human-gate.js) で行い、
--   このビューを根拠にしてはならない。
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW control.v_ship_pr_latest AS
WITH g AS (
  SELECT DISTINCT ON (pull_request_id)
         pull_request_id, head_sha, base_sha, verdict, risk_level, evaluated_at
    FROM control.gate_evaluations
   ORDER BY pull_request_id, evaluated_at DESC
), q AS (
  SELECT DISTINCT ON (repo, head_sha)
         repo, head_sha, eval_id, verdict, finished_at
    FROM control.quality_evaluations
   ORDER BY repo, head_sha, finished_at DESC NULLS LAST
), m AS (
  SELECT DISTINCT ON (pull_request_id)
         pull_request_id, state, confirmed, merge_commit_sha, observed_at
    FROM control.merge_events
   ORDER BY pull_request_id, observed_at DESC
)
SELECT pr.pull_request_id,
       pr.project_id,
       pr.repo,
       pr.pr_number,
       g.head_sha,
       g.base_sha,
       g.verdict       AS gate_verdict,
       g.risk_level,
       g.evaluated_at  AS gate_evaluated_at,
       q.eval_id       AS quality_eval_id,
       q.verdict       AS quality_verdict,
       (SELECT count(*)
          FROM control.human_approvals a
         WHERE a.pull_request_id = pr.pull_request_id
           AND a.head_sha = g.head_sha
           AND a.base_sha = g.base_sha
           AND a.decision = 'approve'
           AND a.expires_at > now()
           AND NOT EXISTS (SELECT 1 FROM control.approval_revocations r
                            WHERE r.approval_id = a.approval_id)
           AND NOT EXISTS (SELECT 1 FROM control.approval_consumptions c
                            WHERE c.approval_id = a.approval_id)
       )               AS open_approval_count,
       m.state         AS merge_state,
       m.confirmed     AS merge_confirmed,
       m.merge_commit_sha,
       m.observed_at   AS merge_observed_at
  FROM control.pull_requests pr
  LEFT JOIN g ON g.pull_request_id = pr.pull_request_id
  LEFT JOIN q ON q.repo = pr.repo AND q.head_sha = g.head_sha
  LEFT JOIN m ON m.pull_request_id = pr.pull_request_id;
COMMENT ON VIEW control.v_ship_pr_latest IS
  'PR ごとの最新 gate / 品質 / 有効承認数 / マージ観測。参考表示用 (判定の根拠にしない)。';

-- ------------------------------------------------------------
-- 権限
--   追記専用表: app は SELECT, INSERT のみ (UPDATE を付与しない + トリガで二重防御)
--   可変表 (ship_sessions / policy_versions / review_findings): SELECT, INSERT, UPDATE
--   pull_requests / ship_session_usage / 語彙: 下記の通り
-- ------------------------------------------------------------
DO $do$
DECLARE
  t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['ship_state_transitions','quality_evaluations',
                           'test_results','gate_evaluations',
                           'ship_review_attestations','human_approvals',
                           'approval_revocations','approval_consumptions',
                           'merge_events','remediation_events','recovery_events',
                           'pull_requests','ship_session_usage'] LOOP
    PERFORM control.grant_if_role('claudeos_control_app', 'SELECT, INSERT',
              'TABLE control.' || t);
    PERFORM control.revoke_if_role('claudeos_control_app', 'UPDATE',
              'TABLE control.' || t);
  END LOOP;

  FOREACH t IN ARRAY ARRAY['ship_sessions','policy_versions','review_findings'] LOOP
    PERFORM control.grant_if_role('claudeos_control_app',
              'SELECT, INSERT, UPDATE', 'TABLE control.' || t);
  END LOOP;

  PERFORM control.grant_if_role('claudeos_control_app', 'SELECT',
            'TABLE control.ship_run_states');
  PERFORM control.grant_if_role('claudeos_control_app', 'SELECT',
            'TABLE control.v_ship_pr_latest');

  PERFORM control.grant_if_role('claudeos_control_ro', 'SELECT',
            'ALL TABLES IN SCHEMA control');
END
$do$;

INSERT INTO control.schema_migrations (version, filename, checksum)
VALUES ('0006', '0006_ship_native.sql', :'checksum')
ON CONFLICT (version) DO NOTHING;

COMMIT;
