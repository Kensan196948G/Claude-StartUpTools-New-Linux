-- ============================================================
-- claudeos_control / migration 0001_foundation.sql
--
-- 目的: control plane の基盤 — migration 台帳、JSONL 生イベントの
--       ステージング、projects / tasks / runs / run_steps。
--
-- 適用:
--   psql -h /var/run/postgresql -d claudeos_control -v ON_ERROR_STOP=1 \
--        -v checksum="$(sha256sum 0001_foundation.sql | cut -c1-64)" \
--        -f 0001_foundation.sql
--
-- 設計規約 (全 migration 共通):
--   1. 追加のみ (additive)。既存列の除去・型変更・既存行の破壊を行わない。
--      ALTER TABLE は使用しない (lib/postgres.sh の migration-risk 検査に
--      抵触させないため。語彙の追加は lookup テーブルへの INSERT で行う)。
--   2. 拡張機能を要求しない。gen_random_uuid() と sha256() は PostgreSQL
--      コア関数 (それぞれ PG13 / PG11 以降) であり pgcrypto は不要。
--   3. secret / credential / token / private key / connection string を
--      いかなる列にも保存しない。自由記述列は control.safe_text ドメインで
--      代表的な秘密パターンを拒否する。検出時はアプリ側で値を出さずに失敗させる。
--   4. 全テーブルに created_at timestamptz NOT NULL DEFAULT now()。
--   5. 可変長の開放的データは jsonb、検索軸は実列。
--   6. ロールは peer 認証下の NOLOGIN グループロール。クライアントは
--      SET ROLE で権限を落とす。ロール未作成でも migration が失敗しないよう
--      GRANT は control.grant_if_role() でガードする。
-- ============================================================

\if :{?checksum}
\else
\set checksum 'unverified'
\endif

BEGIN;

-- ------------------------------------------------------------
-- schema
-- ------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS control;
COMMENT ON SCHEMA control IS
  'ClaudeOS orchestration control plane。秘密情報は格納しない (§7 Security and secrets)。';

REVOKE ALL ON SCHEMA control FROM PUBLIC;

-- ------------------------------------------------------------
-- control.safe_text — 秘密情報の混入を抑止するテキストドメイン
--   NULL は CHECK が NULL を返すため通過する (NOT NULL は各列で指定)。
--   意図的に保守的。誤検知した場合は値をマスクしてから格納すること。
-- ------------------------------------------------------------
DO $do$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_type t
      JOIN pg_namespace n ON n.oid = t.typnamespace
     WHERE n.nspname = 'control' AND t.typname = 'safe_text'
  ) THEN
    CREATE DOMAIN control.safe_text AS text
      CONSTRAINT safe_text_no_credentials CHECK (
        -- 認証情報を含む URI (scheme://user:pass@host)
        VALUE !~* '://[^/@[:space:]]+:[^/@[:space:]]+@'
        -- DB 接続文字列
        AND VALUE !~* '(postgres(ql)?|mysql|mongodb(\+srv)?|redis|amqps?)://'
        -- 既知のトークン接頭辞 / 秘密鍵 PEM
        AND VALUE !~* '(sk-ant-|ghp_[A-Za-z0-9]{10}|gho_[A-Za-z0-9]{10}|github_pat_|AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY-----)'
        -- key=value 形式で秘密らしき値が続くもの
        AND VALUE !~* '(password|passwd|secret|api[_-]?key|access[_-]?token|bearer)[[:space:]]*[=:][[:space:]]*[^[:space:]]{8,}'
      );
    COMMENT ON DOMAIN control.safe_text IS
      '自由記述テキスト。接続文字列・トークン・秘密鍵の混入を拒否する。';
  END IF;
END
$do$;

-- ------------------------------------------------------------
-- 共通ヘルパ
-- ------------------------------------------------------------

-- grant_if_role — 対象ロールが存在する場合のみ GRANT を実行する。
--   p_privs / p_object は migration ファイル内の固定リテラルのみを渡す
--   (外部入力を渡してはならない)。ロール名は %I で quote する。
CREATE OR REPLACE FUNCTION control.grant_if_role(
  p_role text, p_privs text, p_object text
) RETURNS void
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog
AS $fn$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = p_role) THEN
    EXECUTE format('GRANT %s ON %s TO %I', p_privs, p_object, p_role);
  ELSE
    RAISE NOTICE 'role % が存在しないため GRANT (% ON %) を skip しました',
      p_role, p_privs, p_object;
  END IF;
END
$fn$;

-- revoke_if_role — 同上の REVOKE 版 (append-only テーブルの権限剥奪に使う)。
CREATE OR REPLACE FUNCTION control.revoke_if_role(
  p_role text, p_privs text, p_object text
) RETURNS void
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog
AS $fn$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = p_role) THEN
    EXECUTE format('REVOKE %s ON %s FROM %I', p_privs, p_object, p_role);
  END IF;
END
$fn$;

-- default_priv_if_role — 将来作成されるテーブルへの既定権限。
CREATE OR REPLACE FUNCTION control.default_priv_if_role(
  p_owner text, p_grantee text, p_privs text
) RETURNS void
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog
AS $fn$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = p_owner)
     AND EXISTS (SELECT 1 FROM pg_roles WHERE rolname = p_grantee) THEN
    EXECUTE format(
      'ALTER DEFAULT PRIVILEGES FOR ROLE %I IN SCHEMA control GRANT %s ON TABLES TO %I',
      p_owner, p_privs, p_grantee);
  END IF;
END
$fn$;

-- touch_updated_at — 更新時刻の自動維持
CREATE OR REPLACE FUNCTION control.touch_updated_at() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog
AS $fn$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END
$fn$;

-- ensure_touch_trigger — CREATE TRIGGER に IF NOT EXISTS が無いため冪等化する
CREATE OR REPLACE FUNCTION control.ensure_touch_trigger(
  p_schema text, p_table text
) RETURNS void
LANGUAGE plpgsql
SET search_path = pg_catalog
AS $fn$
DECLARE
  v_trg text := 'trg_touch_' || p_table;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger tg
      JOIN pg_class c     ON c.oid = tg.tgrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = p_schema AND c.relname = p_table AND tg.tgname = v_trg
  ) THEN
    EXECUTE format(
      'CREATE TRIGGER %I BEFORE UPDATE ON %I.%I FOR EACH ROW EXECUTE FUNCTION control.touch_updated_at()',
      v_trg, p_schema, p_table);
  END IF;
END
$fn$;

-- ------------------------------------------------------------
-- control.schema_migrations — migration 台帳
--   checksum は適用時に psql 変数で渡す。未指定なら 'unverified'。
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS control.schema_migrations (
  version      text PRIMARY KEY
               CHECK (version ~ '^[0-9]{4}$'),
  filename     text        NOT NULL,
  checksum     text        NOT NULL
               CHECK (checksum ~ '^([0-9a-f]{64}|unverified)$'),
  applied_at   timestamptz NOT NULL DEFAULT now(),
  applied_by   text        NOT NULL DEFAULT session_user,
  duration_ms  integer     CHECK (duration_ms IS NULL OR duration_ms >= 0),
  created_at   timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE control.schema_migrations IS
  '適用済み migration の台帳。再適用検出は version と checksum の一致で行う。';

-- ------------------------------------------------------------
-- 語彙 lookup テーブル
--   CHECK 制約ではなく FK を使う理由: 語彙の追加が INSERT だけで完結し、
--   将来にわたって制約の貼り替え (= 破壊的 DDL) が不要になるため。
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS control.run_statuses (
  status      text PRIMARY KEY,
  is_terminal boolean     NOT NULL DEFAULT false,
  description text        NOT NULL DEFAULT '',
  created_at  timestamptz NOT NULL DEFAULT now()
);
INSERT INTO control.run_statuses (status, is_terminal, description) VALUES
  ('queued',    false, '実行待ち'),
  ('leased',    false, 'lease 取得済み / 開始前'),
  ('running',   false, '実行中 (heartbeat 更新中)'),
  ('succeeded', true,  '正常終了'),
  ('failed',    true,  '失敗'),
  ('cancelled', true,  '中止'),
  ('blocked',   true,  'BLOCKED — 人間判断待ち'),
  ('stale',     true,  'lease 失効 / heartbeat 途絶を reconciler が検出')
ON CONFLICT (status) DO NOTHING;

CREATE TABLE IF NOT EXISTS control.step_phases (
  phase       text PRIMARY KEY,
  sort_order  smallint    NOT NULL DEFAULT 0,
  description text        NOT NULL DEFAULT '',
  created_at  timestamptz NOT NULL DEFAULT now()
);
INSERT INTO control.step_phases (phase, sort_order, description) VALUES
  ('monitor',     10, '現状調査'),
  ('plan',        20, '計画'),
  ('development', 30, '実装'),
  ('verify',      40, '検証 (test / lint / build)'),
  ('review',      50, 'レビュー'),
  ('improvement', 60, '改善'),
  ('release',     70, 'リリース / deployment'),
  ('stabilize',   80, 'リリース後安定化')
ON CONFLICT (phase) DO NOTHING;

CREATE TABLE IF NOT EXISTS control.task_statuses (
  status      text PRIMARY KEY,
  is_terminal boolean     NOT NULL DEFAULT false,
  description text        NOT NULL DEFAULT '',
  created_at  timestamptz NOT NULL DEFAULT now()
);
INSERT INTO control.task_statuses (status, is_terminal, description) VALUES
  ('backlog',     false, '未着手'),
  ('ready',       false, '着手可能'),
  ('in_progress', false, '進行中'),
  ('in_review',   false, 'レビュー中'),
  ('blocked',     false, '停止 — 人間判断または外部要因待ち'),
  ('done',        true,  '完了'),
  ('cancelled',   true,  '中止')
ON CONFLICT (status) DO NOTHING;

-- ------------------------------------------------------------
-- control.projects
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS control.projects (
  project_id     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  -- project_key はリポジトリディレクトリ名に対応する安定キー
  project_key    text NOT NULL UNIQUE
                 CHECK (project_key ~ '^[a-z0-9][a-z0-9._-]{0,126}$'),
  display_name   control.safe_text NOT NULL DEFAULT '',
  -- ローカル絶対パスのみ。認証情報付き URL を入れない。
  repo_path      control.safe_text,
  -- GitHub は owner/repo のみ保持する。token 付き clone URL を保存しない。
  remote_slug    text
                 CHECK (remote_slug IS NULL
                        OR remote_slug ~ '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$'),
  default_branch text    NOT NULL DEFAULT 'main',
  is_active      boolean NOT NULL DEFAULT true,
  metadata       jsonb   NOT NULL DEFAULT '{}'::jsonb,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now()
);
SELECT control.ensure_touch_trigger('control', 'projects');

CREATE INDEX IF NOT EXISTS idx_projects_active
  ON control.projects (project_key) WHERE is_active;

-- ------------------------------------------------------------
-- control.tasks
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS control.tasks (
  task_id      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id   uuid NOT NULL
               REFERENCES control.projects (project_id) ON DELETE RESTRICT,
  -- プロジェクト内で一意な人間可読キー (例: "ISSUE-42", "auto/pg-schema")
  task_key     text NOT NULL
               CHECK (task_key ~ '^[A-Za-z0-9][A-Za-z0-9._/-]{0,126}$'),
  title        control.safe_text NOT NULL,
  body         control.safe_text,
  status       text NOT NULL DEFAULT 'backlog'
               REFERENCES control.task_statuses (status),
  -- SDLC 規模判定 (sdlc-scale skill の S / M / L)
  size_class   text CHECK (size_class IS NULL OR size_class IN ('S','M','L')),
  priority     smallint NOT NULL DEFAULT 50
               CHECK (priority BETWEEN 0 AND 100),
  risk_level   text NOT NULL DEFAULT 'normal'
               CHECK (risk_level IN ('low','normal','high','critical')),
  -- GitHub Issue / PR 参照は番号と slug のみ (URL 全体を持たない)
  external_kind text CHECK (external_kind IS NULL
                            OR external_kind IN ('issue','pull_request','none')),
  external_ref  text CHECK (external_ref IS NULL
                            OR external_ref ~ '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+#[0-9]+$'),
  metadata     jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  closed_at    timestamptz,
  CONSTRAINT uq_tasks_project_key UNIQUE (project_id, task_key)
);
SELECT control.ensure_touch_trigger('control', 'tasks');

CREATE INDEX IF NOT EXISTS idx_tasks_open
  ON control.tasks (project_id, priority DESC, created_at)
  WHERE closed_at IS NULL;

-- ------------------------------------------------------------
-- control.task_dependencies — DAG の辺
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS control.task_dependencies (
  task_id            uuid NOT NULL
                     REFERENCES control.tasks (task_id) ON DELETE CASCADE,
  depends_on_task_id uuid NOT NULL
                     REFERENCES control.tasks (task_id) ON DELETE CASCADE,
  dependency_kind    text NOT NULL DEFAULT 'blocks'
                     CHECK (dependency_kind IN ('blocks','relates','subtask_of')),
  created_at         timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (task_id, depends_on_task_id),
  -- 自己参照は禁止。多段の循環検出はアプリ側 (再帰 CTE) で行う。
  CONSTRAINT ck_task_dependencies_no_self CHECK (task_id <> depends_on_task_id)
);

CREATE INDEX IF NOT EXISTS idx_task_dependencies_reverse
  ON control.task_dependencies (depends_on_task_id);

-- ------------------------------------------------------------
-- control.runs — 実行単位 (lease / heartbeat 付き)
--
-- 実行 lease の考え方:
--   * lease_owner    誰が実行中か (host/pid/session 名。秘密を含めない)
--   * lease_token    lease の世代。更新時に一致を要求し、split-brain を防ぐ
--   * lease_expires_at  この時刻を過ぎた running は放棄とみなす
--   * heartbeat_at / heartbeat_seq  生存信号
--
-- lease 取得 (競合安全):
--   UPDATE control.runs SET lease_owner = $1, lease_token = gen_random_uuid(),
--          lease_expires_at = now() + interval '5 minutes',
--          heartbeat_at = now(), status = 'leased'
--    WHERE run_id = $2
--      AND (lease_expires_at IS NULL OR lease_expires_at < now())
--   RETURNING lease_token;
--
-- 放棄検出は control.v_stale_runs を参照する。
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS control.runs (
  run_id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id        uuid NOT NULL
                    REFERENCES control.projects (project_id) ON DELETE RESTRICT,
  task_id           uuid REFERENCES control.tasks (task_id) ON DELETE SET NULL,
  parent_run_id     uuid REFERENCES control.runs (run_id) ON DELETE SET NULL,
  -- 起動経路 (launcher / cron / supervisor / headless / team / worktree)
  run_kind          text NOT NULL DEFAULT 'interactive'
                    CHECK (run_kind IN ('interactive','cron','supervisor',
                                        'headless','team','worktree','manual')),
  -- goal-router が決めた goal type (development / mvp-release / hotfix ...)
  goal_type         text,
  status            text NOT NULL DEFAULT 'queued'
                    REFERENCES control.run_statuses (status),
  attempt           smallint NOT NULL DEFAULT 1 CHECK (attempt >= 1),

  -- --- 実行 lease / heartbeat -------------------------------
  lease_owner       control.safe_text,
  lease_token       uuid,
  lease_expires_at  timestamptz,
  heartbeat_at      timestamptz,
  heartbeat_seq     bigint NOT NULL DEFAULT 0 CHECK (heartbeat_seq >= 0),
  reconciled_at     timestamptz,
  reconcile_reason  control.safe_text,

  -- --- 時刻 / 結果 ------------------------------------------
  queued_at         timestamptz NOT NULL DEFAULT now(),
  started_at        timestamptz,
  ended_at          timestamptz,
  exit_code         smallint,
  -- セッション識別子。URL や token ではなく不透明 ID のみ。
  session_ref       text CHECK (session_ref IS NULL
                                OR session_ref ~ '^[A-Za-z0-9_-]{1,128}$'),
  git_head_sha      text CHECK (git_head_sha IS NULL
                                OR git_head_sha ~ '^[0-9a-f]{7,40}$'),
  summary           control.safe_text,
  metadata          jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT ck_runs_lease_pair
    CHECK ((lease_owner IS NULL) = (lease_token IS NULL)),
  CONSTRAINT ck_runs_lease_expiry_needs_owner
    CHECK (lease_expires_at IS NULL OR lease_owner IS NOT NULL),
  CONSTRAINT ck_runs_time_order
    CHECK (ended_at IS NULL OR started_at IS NULL OR ended_at >= started_at),
  CONSTRAINT ck_runs_no_self_parent
    CHECK (parent_run_id IS NULL OR parent_run_id <> run_id)
);
SELECT control.ensure_touch_trigger('control', 'runs');

-- reconciler 用: 期限切れ lease を持つ実行中 run を狭く走査する
CREATE INDEX IF NOT EXISTS idx_runs_lease_expiry
  ON control.runs (lease_expires_at)
  WHERE status IN ('leased','running');

CREATE INDEX IF NOT EXISTS idx_runs_project_recent
  ON control.runs (project_id, queued_at DESC);

CREATE INDEX IF NOT EXISTS idx_runs_task
  ON control.runs (task_id) WHERE task_id IS NOT NULL;

-- v_stale_runs — 放棄された run の候補。reconciler はこの結果に対して
--   status = 'stale' と reconciled_at を書き戻す。
CREATE OR REPLACE VIEW control.v_stale_runs AS
SELECT r.run_id,
       r.project_id,
       r.task_id,
       r.status,
       r.lease_owner,
       r.lease_expires_at,
       r.heartbeat_at,
       now() - COALESCE(r.heartbeat_at, r.started_at, r.queued_at)
         AS since_last_signal
  FROM control.runs r
 WHERE r.status IN ('leased','running')
   AND (r.lease_expires_at IS NULL OR r.lease_expires_at < now());
COMMENT ON VIEW control.v_stale_runs IS
  'lease 失効または heartbeat 途絶により放棄とみなせる run。reconciler の入力。';

-- ------------------------------------------------------------
-- control.run_steps
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS control.run_steps (
  step_id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  run_id          uuid NOT NULL
                  REFERENCES control.runs (run_id) ON DELETE CASCADE,
  step_seq        integer NOT NULL CHECK (step_seq >= 0),
  phase           text NOT NULL REFERENCES control.step_phases (phase),
  title           control.safe_text NOT NULL DEFAULT '',
  status          text NOT NULL DEFAULT 'running'
                  CHECK (status IN ('running','succeeded','failed',
                                    'skipped','blocked')),
  -- 検証結果は repo 規約の 4 値で表現する
  verdict         text CHECK (verdict IS NULL
                              OR verdict IN ('PASS','FAIL','BLOCKED','NOT_RUN')),
  started_at      timestamptz NOT NULL DEFAULT now(),
  ended_at        timestamptz,
  duration_ms     integer CHECK (duration_ms IS NULL OR duration_ms >= 0),
  detail          jsonb NOT NULL DEFAULT '{}'::jsonb,
  -- 冪等鍵 (下記 ingest_events のコメントを参照)
  idempotency_key text NOT NULL DEFAULT gen_random_uuid()::text,
  created_at      timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_run_steps_seq  UNIQUE (run_id, step_seq),
  CONSTRAINT uq_run_steps_idem UNIQUE (idempotency_key)
);

CREATE INDEX IF NOT EXISTS idx_run_steps_run
  ON control.run_steps (run_id, step_seq);

-- ------------------------------------------------------------
-- 取り込みステージング
--
-- 冪等性の設計 (重要):
--   projection worker は append-only の JSONL を再生するため、同一イベントが
--   複数回投入されうる。調停キーは idempotency_key ただ 1 つとする。
--     idempotency_key = hex(sha256(source_stream || ':' || source_seq || ':'
--                                  || canonical_json(payload)))
--   これは内容が同じなら同じ値になるので、再生は
--     INSERT ... ON CONFLICT (idempotency_key) DO NOTHING
--   で完全な no-op になる。
--
--   (source_stream, source_seq) は「どのファイルの何行目か」を示す第二の
--   自然キーだが、意図的に UNIQUE にしない。UNIQUE を 2 つ持たせると、
--   ファイルのローテーションや書き換えで行番号が振り直された際に
--   ON CONFLICT (idempotency_key) が別制約の違反で例外を投げ、再生が
--   停止してしまうため。順序保証と監査のための索引に留める。
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS control.ingest_batches (
  batch_id      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  source_stream control.safe_text NOT NULL,
  started_at    timestamptz NOT NULL DEFAULT now(),
  finished_at   timestamptz,
  status        text NOT NULL DEFAULT 'running'
                CHECK (status IN ('running','succeeded','failed','partial')),
  read_count    integer NOT NULL DEFAULT 0 CHECK (read_count >= 0),
  inserted_count integer NOT NULL DEFAULT 0 CHECK (inserted_count >= 0),
  duplicate_count integer NOT NULL DEFAULT 0 CHECK (duplicate_count >= 0),
  error_count   integer NOT NULL DEFAULT 0 CHECK (error_count >= 0),
  note          control.safe_text,
  created_at    timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS control.ingest_events (
  event_id        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  -- 取り込み順のカーソル。identity 列なので別途 sequence 権限は不要。
  ingest_seq      bigint GENERATED BY DEFAULT AS IDENTITY,
  idempotency_key text NOT NULL,
  batch_id        uuid REFERENCES control.ingest_batches (batch_id)
                  ON DELETE SET NULL,

  -- 出所 (JSONL の相対パスと行番号)。索引のみで UNIQUE にはしない。
  source_stream   control.safe_text NOT NULL,
  source_seq      bigint NOT NULL CHECK (source_seq >= 0),
  content_sha256  text NOT NULL CHECK (content_sha256 ~ '^[0-9a-f]{64}$'),

  -- 検索軸は実列として持つ
  event_type      text NOT NULL
                  CHECK (event_type ~ '^[a-z][a-z0-9._-]{0,63}$'),
  event_time      timestamptz NOT NULL,
  project_key     text,
  run_ref         text,
  agent_ref       text,

  payload         jsonb NOT NULL,

  -- 射影の状態機械
  projection_state text NOT NULL DEFAULT 'pending'
                   CHECK (projection_state IN ('pending','projected',
                                               'skipped','failed')),
  projected_at     timestamptz,
  projection_error control.safe_text,
  received_at      timestamptz NOT NULL DEFAULT now(),
  created_at       timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT uq_ingest_events_idem UNIQUE (idempotency_key),
  -- 取り込み境界での秘密混入ガード。検出時は値を出さず失敗させる。
  CONSTRAINT ck_ingest_events_no_credentials CHECK (
    payload::text !~* '(-----BEGIN [A-Z ]*PRIVATE KEY-----|sk-ant-|github_pat_|ghp_[A-Za-z0-9]{10}|AKIA[0-9A-Z]{16})'
    AND payload::text !~* '(postgres(ql)?|mysql|mongodb(\+srv)?|redis)://[^"[:space:]]*:[^"[:space:]]*@'
  )
);
COMMENT ON COLUMN control.ingest_events.idempotency_key IS
  'hex(sha256(source_stream || '':'' || source_seq || '':'' || canonical_json))。再生時は ON CONFLICT DO NOTHING で no-op。';

CREATE INDEX IF NOT EXISTS idx_ingest_events_pending
  ON control.ingest_events (ingest_seq)
  WHERE projection_state = 'pending';

CREATE INDEX IF NOT EXISTS idx_ingest_events_source
  ON control.ingest_events (source_stream, source_seq);

CREATE INDEX IF NOT EXISTS idx_ingest_events_type_time
  ON control.ingest_events (event_type, event_time DESC);

CREATE INDEX IF NOT EXISTS idx_ingest_events_payload
  ON control.ingest_events USING gin (payload jsonb_path_ops);

-- ------------------------------------------------------------
-- 権限
--   _app   実行時。SELECT / INSERT / UPDATE のみ (行の除去権限を与えない)
--   _ro    参照専用
--   _audit 監査書き込み専用 (0003 で audit_events への INSERT を得る)
--   保持期間に基づく整理は migrator 権限 + Approval PR の対象とする。
-- ------------------------------------------------------------
DO $do$
DECLARE
  t text;
  v_rw   text[] := ARRAY['projects','tasks','task_dependencies','runs',
                         'run_steps','ingest_batches','ingest_events'];
  v_ro   text[] := ARRAY['schema_migrations','run_statuses','step_phases',
                         'task_statuses'];
BEGIN
  PERFORM control.grant_if_role('claudeos_control_app',   'USAGE', 'SCHEMA control');
  PERFORM control.grant_if_role('claudeos_control_ro',    'USAGE', 'SCHEMA control');
  PERFORM control.grant_if_role('claudeos_control_audit', 'USAGE', 'SCHEMA control');

  FOREACH t IN ARRAY v_rw LOOP
    PERFORM control.grant_if_role('claudeos_control_app',
              'SELECT, INSERT, UPDATE', 'TABLE control.' || t);
  END LOOP;

  FOREACH t IN ARRAY v_ro LOOP
    PERFORM control.grant_if_role('claudeos_control_app', 'SELECT',
              'TABLE control.' || t);
  END LOOP;

  PERFORM control.grant_if_role('claudeos_control_ro', 'SELECT',
            'ALL TABLES IN SCHEMA control');

  PERFORM control.default_priv_if_role('claudeos_control_migrator',
            'claudeos_control_ro', 'SELECT');
END
$do$;

INSERT INTO control.schema_migrations (version, filename, checksum)
VALUES ('0001', '0001_foundation.sql', :'checksum')
ON CONFLICT (version) DO NOTHING;

COMMIT;
