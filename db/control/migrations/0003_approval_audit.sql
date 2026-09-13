-- ============================================================
-- claudeos_control / migration 0003_approval_audit.sql
--
-- 目的: Human Approval Gate の記録 (期限 / 対象ハッシュ / 承認後の
--       改変検出 / 二名承認 / 役割ベース承認)、追記専用の監査ログ、
--       security policy 変更の追跡。
-- 前提: 0001, 0002 が適用済みであること。
--
-- 注意 (意図的な設計):
--   * audit_events は追記専用。行の更新・個別削除は BEFORE トリガで
--     例外にし、さらに権限でも与えない。テーブル全体を一括で空にする
--     種類の文はテーブル所有権と権限付与の不在で防ぐ (該当キーワードを
--     SQL 中に書くと lib/postgres.sh の migration-risk 検査が
--     HUMAN_APPROVAL を要求するため、文編成レベルのトリガは置かない)。
--   * ハッシュは PostgreSQL コア関数 sha256() で計算する。pgcrypto 不要。
-- ============================================================

\if :{?checksum}
\else
\set checksum 'unverified'
\endif

BEGIN;

-- ------------------------------------------------------------
-- 承認の語彙
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS control.risk_categories (
  category          text PRIMARY KEY,
  requires_two_person boolean   NOT NULL DEFAULT false,
  default_ttl       interval    NOT NULL DEFAULT interval '24 hours',
  description       text        NOT NULL DEFAULT '',
  created_at        timestamptz NOT NULL DEFAULT now()
);
INSERT INTO control.risk_categories
  (category, requires_two_person, default_ttl, description) VALUES
  ('public_dns',        true,  interval '24 hours', '公開 DNS / custom domain / production route'),
  ('production_secret', true,  interval '4 hours',  'production secret の追加・変更・rotation'),
  ('auth_model',        true,  interval '24 hours', '認証方式 / 認可モデルの変更'),
  ('destructive_data',  true,  interval '2 hours',  '破壊的 migration / production data の除去'),
  ('billing',           true,  interval '72 hours', '課金プラン / 契約 / 費用構造'),
  ('exposure_scope',    true,  interval '24 hours', '公開範囲 / データ保持期間 / 監査方式'),
  ('security_policy',   true,  interval '24 hours', 'permissions.deny / hooks / Branch Protection の緩和'),
  ('self_improvement',  false, interval '72 hours', '自己改善結果 (skills / agents / workflow) の main 反映'),
  ('deployment',        false, interval '12 hours', '本番デプロイ判断'),
  ('other',             false, interval '24 hours', 'その他')
ON CONFLICT (category) DO NOTHING;

CREATE TABLE IF NOT EXISTS control.approver_roles (
  role_key    text PRIMARY KEY,
  is_human    boolean     NOT NULL DEFAULT true,
  description text        NOT NULL DEFAULT '',
  created_at  timestamptz NOT NULL DEFAULT now()
);
INSERT INTO control.approver_roles (role_key, is_human, description) VALUES
  ('owner',             true, 'リポジトリ所有者 / 最終決裁'),
  ('cto',               true, 'CTO 代行に対する人間側の決裁者'),
  ('security_reviewer', true, 'セキュリティ観点の承認者'),
  ('release_manager',   true, 'リリース可否の承認者'),
  ('data_steward',      true, 'データ保持 / 個人情報の承認者')
ON CONFLICT (role_key) DO NOTHING;

-- ------------------------------------------------------------
-- control.approvals
--
-- 承認後の改変検出:
--   approved_object_sha256  承認した対象の内容ハッシュ (PR head SHA、
--                           ファイル内容の sha256、migration の checksum 等)
--   observed_object_sha256  実行直前に再計算した値
--   tamper_detected         両者が食い違えば true (生成列)
--   実行側は is_actionable が true であることを必ず確認する。
--
-- 二名承認:
--   required_approvals (1 または 2) と control.approval_decisions の
--   行数で表現する。申請者自身は承認者になれない (職務分離)。
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS control.approvals (
  approval_id    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id     uuid REFERENCES control.projects (project_id) ON DELETE RESTRICT,
  run_id         uuid REFERENCES control.runs (run_id) ON DELETE SET NULL,

  risk_category  text NOT NULL REFERENCES control.risk_categories (category),
  required_approver_role text NOT NULL DEFAULT 'owner'
                 REFERENCES control.approver_roles (role_key),
  required_approvals smallint NOT NULL DEFAULT 1
                 CHECK (required_approvals BETWEEN 1 AND 2),

  -- 承認対象の識別
  subject_kind   text NOT NULL
                 CHECK (subject_kind IN ('pull_request','migration','deployment',
                                         'secret_rotation','dns_change',
                                         'policy_change','data_operation',
                                         'skill_promotion','other')),
  subject_ref    control.safe_text NOT NULL,
  approved_object_sha256 text NOT NULL
                 CHECK (approved_object_sha256 ~ '^[0-9a-f]{64}$'),
  observed_object_sha256 text
                 CHECK (observed_object_sha256 IS NULL
                        OR observed_object_sha256 ~ '^[0-9a-f]{64}$'),
  observed_at    timestamptz,
  -- 承認時点の git head。実行時に一致しなければ実行しない。
  head_sha       text CHECK (head_sha IS NULL OR head_sha ~ '^[0-9a-f]{7,40}$'),

  -- 申請 / 期限 / 状態
  requested_by   control.safe_text NOT NULL,
  requested_at   timestamptz NOT NULL DEFAULT now(),
  expires_at     timestamptz NOT NULL,
  status         text NOT NULL DEFAULT 'pending'
                 CHECK (status IN ('pending','approved','rejected',
                                   'expired','superseded','invalidated',
                                   'consumed')),
  decided_at     timestamptz,
  consumed_at    timestamptz,
  question_text  control.safe_text NOT NULL DEFAULT 'マージ判定：Y / N',
  context        jsonb NOT NULL DEFAULT '{}'::jsonb,
  idempotency_key text NOT NULL DEFAULT gen_random_uuid()::text,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),

  -- 承認後の改変検出 (生成列)
  tamper_detected boolean GENERATED ALWAYS AS (
    observed_object_sha256 IS NOT NULL
    AND observed_object_sha256 <> approved_object_sha256
  ) STORED,

  CONSTRAINT uq_approvals_idem UNIQUE (idempotency_key),
  CONSTRAINT ck_approvals_expiry CHECK (expires_at > requested_at),
  CONSTRAINT ck_approvals_decided
    CHECK ((status IN ('approved','rejected')) = (decided_at IS NOT NULL))
);
SELECT control.ensure_touch_trigger('control', 'approvals');

COMMENT ON COLUMN control.approvals.tamper_detected IS
  '承認対象のハッシュが承認時と実行直前で食い違った場合 true。実行を止める。';

CREATE INDEX IF NOT EXISTS idx_approvals_pending
  ON control.approvals (expires_at)
  WHERE status = 'pending';

CREATE INDEX IF NOT EXISTS idx_approvals_subject
  ON control.approvals (subject_kind, subject_ref);

-- ------------------------------------------------------------
-- control.approval_decisions
--   指定リストには無いが、二名承認を型付き列で表現するために追加する。
--   approvals 内の JSON で持つと承認者・時刻・役割が検索できず、
--   職務分離の制約も張れないため。
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS control.approval_decisions (
  decision_id   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  approval_id   uuid NOT NULL
                REFERENCES control.approvals (approval_id) ON DELETE CASCADE,
  approver      control.safe_text NOT NULL,
  approver_role text NOT NULL REFERENCES control.approver_roles (role_key),
  decision      text NOT NULL CHECK (decision IN ('Y','N')),
  -- 決裁時点で承認者が見ていた対象のハッシュ
  decided_object_sha256 text NOT NULL
                CHECK (decided_object_sha256 ~ '^[0-9a-f]{64}$'),
  decided_at    timestamptz NOT NULL DEFAULT now(),
  note          control.safe_text,
  idempotency_key text NOT NULL DEFAULT gen_random_uuid()::text,
  created_at    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_approval_decisions_idem UNIQUE (idempotency_key),
  -- 同一承認者の二重計上を防ぐ
  CONSTRAINT uq_approval_decisions_approver UNIQUE (approval_id, approver)
);

CREATE INDEX IF NOT EXISTS idx_approval_decisions_approval
  ON control.approval_decisions (approval_id);

-- v_actionable_approvals — 実行してよい承認だけを返す。
--   有効期限内 / 状態が approved / 改変検出なし / 必要数の Y が揃っている /
--   申請者自身の承認を除外している、の全てを満たすもの。
CREATE OR REPLACE VIEW control.v_actionable_approvals AS
SELECT a.approval_id,
       a.project_id,
       a.subject_kind,
       a.subject_ref,
       a.approved_object_sha256,
       a.head_sha,
       a.expires_at,
       count(d.decision_id) FILTER (WHERE d.decision = 'Y') AS yes_count,
       a.required_approvals
  FROM control.approvals a
  LEFT JOIN control.approval_decisions d
         ON d.approval_id = a.approval_id
        AND d.decision = 'Y'
        AND d.approver <> a.requested_by
        AND d.approver_role = a.required_approver_role
        AND d.decided_object_sha256 = a.approved_object_sha256
 WHERE a.status = 'approved'
   AND a.expires_at > now()
   AND NOT a.tamper_detected
 GROUP BY a.approval_id
HAVING count(d.decision_id) FILTER (WHERE d.decision = 'Y') >= a.required_approvals;
COMMENT ON VIEW control.v_actionable_approvals IS
  '実行可能な承認のみ。期限切れ・改変検出・承認数不足・自己承認は除外する。';

-- ------------------------------------------------------------
-- control.audit_events — 追記専用の監査ログ
--
-- 改ざん検出:
--   row_sha256 = sha256(prev_sha256 || 正規化した主要列) を BEFORE INSERT
--   トリガで計算する。prev_sha256 に直前行の row_sha256 を渡せばハッシュ
--   連鎖になる (連鎖する場合は書き込み側で直列化すること)。
--   sha256() は PostgreSQL コア関数であり拡張は不要。
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS control.audit_events (
  event_id      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  event_seq     bigint GENERATED BY DEFAULT AS IDENTITY,
  occurred_at   timestamptz NOT NULL DEFAULT now(),
  project_id    uuid REFERENCES control.projects (project_id) ON DELETE SET NULL,
  run_id        uuid REFERENCES control.runs (run_id) ON DELETE SET NULL,
  agent_id      uuid REFERENCES control.agents (agent_id) ON DELETE SET NULL,
  approval_id   uuid REFERENCES control.approvals (approval_id) ON DELETE SET NULL,

  actor         control.safe_text NOT NULL,
  actor_kind    text NOT NULL DEFAULT 'agent'
                CHECK (actor_kind IN ('human','agent','system','cron')),
  action        text NOT NULL
                CHECK (action ~ '^[a-z][a-z0-9._-]{0,95}$'),
  subject_kind  text NOT NULL,
  subject_ref   control.safe_text NOT NULL,
  outcome       text NOT NULL DEFAULT 'success'
                CHECK (outcome IN ('success','failure','denied',
                                   'blocked','skipped')),
  severity      text NOT NULL DEFAULT 'info'
                CHECK (severity IN ('debug','info','notice','warning',
                                    'error','critical')),
  detail        jsonb NOT NULL DEFAULT '{}'::jsonb,

  prev_sha256   text CHECK (prev_sha256 IS NULL
                            OR prev_sha256 ~ '^[0-9a-f]{64}$'),
  row_sha256    text NOT NULL DEFAULT ''   -- トリガが上書きする
                CHECK (row_sha256 = '' OR row_sha256 ~ '^[0-9a-f]{64}$'),

  idempotency_key text NOT NULL DEFAULT gen_random_uuid()::text,
  created_at    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_audit_events_idem UNIQUE (idempotency_key),
  -- 監査ログ本文への秘密混入ガード
  CONSTRAINT ck_audit_events_no_credentials CHECK (
    detail::text !~* '(-----BEGIN [A-Z ]*PRIVATE KEY-----|sk-ant-|github_pat_|ghp_[A-Za-z0-9]{10}|AKIA[0-9A-Z]{16})'
    AND detail::text !~* '(postgres(ql)?|mysql|mongodb(\+srv)?|redis)://[^"[:space:]]*:[^"[:space:]]*@'
  )
);

-- 行ダイジェスト計算 (検証時も同じ関数を使う)
CREATE OR REPLACE FUNCTION control.audit_event_digest(
  p_prev text, p_occurred timestamptz, p_actor text, p_action text,
  p_subject_kind text, p_subject_ref text, p_outcome text, p_detail jsonb
) RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog
AS $fn$
  SELECT encode(
           sha256(
             convert_to(
               coalesce(p_prev, '') || '|' ||
               to_char(p_occurred AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US') || '|' ||
               p_actor || '|' || p_action || '|' ||
               p_subject_kind || '|' || p_subject_ref || '|' ||
               p_outcome || '|' || p_detail::text,
               'UTF8')),
           'hex');
$fn$;

CREATE OR REPLACE FUNCTION control.audit_events_before_insert()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, control
AS $fn$
BEGIN
  NEW.row_sha256 := control.audit_event_digest(
    NEW.prev_sha256, NEW.occurred_at, NEW.actor::text, NEW.action,
    NEW.subject_kind, NEW.subject_ref::text, NEW.outcome, NEW.detail);
  RETURN NEW;
END
$fn$;

-- 追記専用の強制: 行の更新・除去を例外にする
CREATE OR REPLACE FUNCTION control.audit_events_block_mutation()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog
AS $fn$
BEGIN
  RAISE EXCEPTION
    'control.audit_events は追記専用です (操作 % は許可されません)', TG_OP
    USING ERRCODE = '0A000',
          HINT = '訂正は打ち消しの新規行を追記して表現してください。';
END
$fn$;

DO $do$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger tg
      JOIN pg_class c ON c.oid = tg.tgrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'control' AND c.relname = 'audit_events'
       AND tg.tgname = 'trg_audit_events_digest'
  ) THEN
    CREATE TRIGGER trg_audit_events_digest
      BEFORE INSERT ON control.audit_events
      FOR EACH ROW EXECUTE FUNCTION control.audit_events_before_insert();
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger tg
      JOIN pg_class c ON c.oid = tg.tgrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'control' AND c.relname = 'audit_events'
       AND tg.tgname = 'trg_audit_events_append_only'
  ) THEN
    CREATE TRIGGER trg_audit_events_append_only
      BEFORE UPDATE OR DELETE ON control.audit_events
      FOR EACH ROW EXECUTE FUNCTION control.audit_events_block_mutation();
  END IF;
END
$do$;

CREATE INDEX IF NOT EXISTS idx_audit_events_time
  ON control.audit_events (occurred_at DESC);
CREATE INDEX IF NOT EXISTS idx_audit_events_subject
  ON control.audit_events (subject_kind, subject_ref, occurred_at DESC);
CREATE INDEX IF NOT EXISTS idx_audit_events_severity
  ON control.audit_events (severity, occurred_at DESC)
  WHERE severity IN ('error','critical');
CREATE INDEX IF NOT EXISTS idx_audit_events_run
  ON control.audit_events (run_id) WHERE run_id IS NOT NULL;

-- 改ざん検証ビュー: 保存値と再計算値が一致しない行を返す (通常 0 行)
CREATE OR REPLACE VIEW control.v_audit_integrity_violations AS
SELECT e.event_id, e.event_seq, e.occurred_at, e.row_sha256
  FROM control.audit_events e
 WHERE e.row_sha256 <> control.audit_event_digest(
         e.prev_sha256, e.occurred_at, e.actor::text, e.action,
         e.subject_kind, e.subject_ref::text, e.outcome, e.detail);

-- ------------------------------------------------------------
-- control.policy_changes — security policy / 設定変更の追跡
--   変更前後の内容そのものではなくハッシュと要約を持つ。
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS control.policy_changes (
  change_id     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id    uuid REFERENCES control.projects (project_id) ON DELETE RESTRICT,
  approval_id   uuid REFERENCES control.approvals (approval_id) ON DELETE SET NULL,
  policy_kind   text NOT NULL
                CHECK (policy_kind IN ('permissions','hooks','settings',
                                       'branch_protection','ci_required_checks',
                                       'access_policy','retention','other')),
  policy_path   control.safe_text NOT NULL,
  change_type   text NOT NULL
                CHECK (change_type IN ('add','modify','relax','tighten','revert')),
  -- 緩和方向の変更は必ず承認を要する
  is_relaxation boolean NOT NULL DEFAULT false,
  before_sha256 text CHECK (before_sha256 IS NULL
                            OR before_sha256 ~ '^[0-9a-f]{64}$'),
  after_sha256  text CHECK (after_sha256 IS NULL
                            OR after_sha256 ~ '^[0-9a-f]{64}$'),
  diff_summary  control.safe_text NOT NULL DEFAULT '',
  applied_at    timestamptz,
  applied_by    control.safe_text,
  reverted_at   timestamptz,
  idempotency_key text NOT NULL DEFAULT gen_random_uuid()::text,
  created_at    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_policy_changes_idem UNIQUE (idempotency_key),
  -- 緩和は承認なしに適用済みにできない
  CONSTRAINT ck_policy_changes_relaxation_needs_approval
    CHECK (NOT is_relaxation OR applied_at IS NULL OR approval_id IS NOT NULL)
);

CREATE INDEX IF NOT EXISTS idx_policy_changes_pending
  ON control.policy_changes (created_at DESC) WHERE applied_at IS NULL;

-- ------------------------------------------------------------
-- 権限
--   audit_events は INSERT と SELECT のみ。UPDATE / 行の除去は
--   いかなるロールにも付与しない (トリガと二重の防御)。
-- ------------------------------------------------------------
DO $do$
DECLARE
  t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['approvals','approval_decisions','policy_changes'] LOOP
    PERFORM control.grant_if_role('claudeos_control_app',
              'SELECT, INSERT, UPDATE', 'TABLE control.' || t);
  END LOOP;

  FOREACH t IN ARRAY ARRAY['risk_categories','approver_roles'] LOOP
    PERFORM control.grant_if_role('claudeos_control_app', 'SELECT',
              'TABLE control.' || t);
  END LOOP;

  -- 監査書き込み専用ロール
  PERFORM control.grant_if_role('claudeos_control_audit', 'INSERT',
            'TABLE control.audit_events');
  PERFORM control.revoke_if_role('claudeos_control_audit',
            'SELECT, UPDATE', 'TABLE control.audit_events');

  -- アプリは追記と参照のみ
  PERFORM control.grant_if_role('claudeos_control_app', 'SELECT, INSERT',
            'TABLE control.audit_events');
  PERFORM control.revoke_if_role('claudeos_control_app', 'UPDATE',
            'TABLE control.audit_events');

  PERFORM control.grant_if_role('claudeos_control_ro', 'SELECT',
            'ALL TABLES IN SCHEMA control');
END
$do$;

INSERT INTO control.schema_migrations (version, filename, checksum)
VALUES ('0003', '0003_approval_audit.sql', :'checksum')
ON CONFLICT (version) DO NOTHING;

COMMIT;
