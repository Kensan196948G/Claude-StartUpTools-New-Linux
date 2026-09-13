-- ============================================================
-- claudeos_control / migration 0005_self_improvement.sql
--
-- 目的: 自己改善ループ — 失敗パターンの集約、改善提案、skill の
--       候補・版・評価・昇格、canary 実行、信頼スコア。
-- 前提: 0001〜0004 が適用済みであること。
--
-- 重要な業務規約:
--   自己改善結果 (skills / agents / workflow / routing / prompt) の
--   main 反映は Human Approval Gate の対象。したがって
--   skill_promotions.to_status = 'promoted' は approval_id を要求する。
-- ============================================================

\if :{?checksum}
\else
\set checksum 'unverified'
\endif

BEGIN;

-- ------------------------------------------------------------
-- 改善対象の語彙
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS control.improvement_targets (
  target_kind      text PRIMARY KEY,
  requires_approval boolean    NOT NULL DEFAULT true,
  description      text        NOT NULL DEFAULT '',
  created_at       timestamptz NOT NULL DEFAULT now()
);
INSERT INTO control.improvement_targets
  (target_kind, requires_approval, description) VALUES
  ('skill',          true,  'Skill の追加・改訂'),
  ('agent',          true,  'Agent instruction の改訂'),
  ('workflow',       true,  'Workflow 定義の改訂'),
  ('routing_policy', true,  'agent-router の方針変更'),
  ('prompt',         true,  'プロンプトの改訂'),
  ('test_strategy',  false, 'テスト戦略の追加'),
  ('docs',           false, '文書の改訂')
ON CONFLICT (target_kind) DO NOTHING;

-- ------------------------------------------------------------
-- control.failure_patterns — failure_events の signature を集約した実体
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS control.failure_patterns (
  pattern_id       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  signature        text NOT NULL UNIQUE
                   CHECK (signature ~ '^[0-9a-f]{64}$'),
  title            control.safe_text NOT NULL,
  failure_kind     text NOT NULL,
  occurrence_count integer NOT NULL DEFAULT 1 CHECK (occurrence_count >= 1),
  first_seen_at    timestamptz NOT NULL DEFAULT now(),
  last_seen_at     timestamptz NOT NULL DEFAULT now(),
  root_cause       control.safe_text,
  mitigation       control.safe_text,
  status           text NOT NULL DEFAULT 'observed'
                   CHECK (status IN ('observed','analyzed','mitigated',
                                     'resolved','accepted')),
  severity         text NOT NULL DEFAULT 'medium'
                   CHECK (severity IN ('low','medium','high','critical')),
  evidence         jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ck_failure_patterns_seen_order
    CHECK (last_seen_at >= first_seen_at)
);
SELECT control.ensure_touch_trigger('control', 'failure_patterns');

CREATE INDEX IF NOT EXISTS idx_failure_patterns_open
  ON control.failure_patterns (severity, occurrence_count DESC)
  WHERE status IN ('observed','analyzed');

-- ------------------------------------------------------------
-- control.improvement_proposals
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS control.improvement_proposals (
  proposal_id   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  pattern_id    uuid REFERENCES control.failure_patterns (pattern_id)
                ON DELETE SET NULL,
  project_id    uuid REFERENCES control.projects (project_id) ON DELETE RESTRICT,
  run_id        uuid REFERENCES control.runs (run_id) ON DELETE SET NULL,
  target_kind   text NOT NULL
                REFERENCES control.improvement_targets (target_kind),
  -- 改訂対象の所在 (リポジトリ相対パス)
  target_ref    control.safe_text NOT NULL,
  title         control.safe_text NOT NULL,
  rationale     control.safe_text NOT NULL DEFAULT '',
  proposal      jsonb NOT NULL DEFAULT '{}'::jsonb,
  -- 提案を載せた PR (owner/repo#N 形式のみ)
  pr_ref        text CHECK (pr_ref IS NULL
                            OR pr_ref ~ '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+#[0-9]+$'),
  approval_id   uuid REFERENCES control.approvals (approval_id) ON DELETE SET NULL,
  status        text NOT NULL DEFAULT 'draft'
                CHECK (status IN ('draft','proposed','in_review',
                                  'accepted','rejected','applied','withdrawn')),
  applied_at    timestamptz,
  idempotency_key text NOT NULL DEFAULT gen_random_uuid()::text,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_improvement_proposals_idem UNIQUE (idempotency_key),
  CONSTRAINT ck_improvement_proposals_applied
    CHECK ((status = 'applied') = (applied_at IS NOT NULL))
);
SELECT control.ensure_touch_trigger('control', 'improvement_proposals');

CREATE INDEX IF NOT EXISTS idx_improvement_proposals_open
  ON control.improvement_proposals (target_kind, created_at DESC)
  WHERE status IN ('draft','proposed','in_review');
CREATE INDEX IF NOT EXISTS idx_improvement_proposals_payload
  ON control.improvement_proposals USING gin (proposal jsonb_path_ops);

-- ------------------------------------------------------------
-- control.skill_candidates
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS control.skill_candidates (
  candidate_id  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  candidate_key text NOT NULL UNIQUE
                CHECK (candidate_key ~ '^[a-z][a-z0-9-]{0,63}$'),
  pattern_id    uuid REFERENCES control.failure_patterns (pattern_id)
                ON DELETE SET NULL,
  proposal_id   uuid REFERENCES control.improvement_proposals (proposal_id)
                ON DELETE SET NULL,
  origin        text NOT NULL DEFAULT 'failure_pattern'
                CHECK (origin IN ('failure_pattern','manual','proposal',
                                  'usage_analysis')),
  rationale     control.safe_text NOT NULL DEFAULT '',
  status        text NOT NULL DEFAULT 'candidate'
                CHECK (status IN ('candidate','drafted','evaluated',
                                  'promoted','rejected')),
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);
SELECT control.ensure_touch_trigger('control', 'skill_candidates');

-- ------------------------------------------------------------
-- control.skill_versions
--   Skill の本文は保存しない。所在と内容ハッシュのみ。
--   (配布正本は Claude/templates/** であり DB は台帳に徹する)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS control.skill_versions (
  skill_version_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  candidate_id  uuid REFERENCES control.skill_candidates (candidate_id)
                ON DELETE SET NULL,
  skill_key     text NOT NULL
                CHECK (skill_key ~ '^[a-z][a-z0-9-]{0,63}$'),
  version       integer NOT NULL CHECK (version >= 1),
  content_sha256 text NOT NULL CHECK (content_sha256 ~ '^[0-9a-f]{64}$'),
  source_ref    control.safe_text NOT NULL,
  status        text NOT NULL DEFAULT 'draft'
                CHECK (status IN ('draft','canary','promoted','retired')),
  authored_by   control.safe_text,
  notes         control.safe_text,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_skill_versions UNIQUE (skill_key, version)
);
SELECT control.ensure_touch_trigger('control', 'skill_versions');

-- 同一 skill で promoted は同時に 1 版のみ
CREATE UNIQUE INDEX IF NOT EXISTS uq_skill_versions_promoted
  ON control.skill_versions (skill_key) WHERE status = 'promoted';

-- ------------------------------------------------------------
-- control.skill_evaluations — golden eval / 回帰確認の結果
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS control.skill_evaluations (
  skill_evaluation_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  skill_version_id uuid NOT NULL
                REFERENCES control.skill_versions (skill_version_id)
                ON DELETE CASCADE,
  eval_id       uuid REFERENCES control.eval_definitions (eval_id)
                ON DELETE SET NULL,
  eval_result_id uuid REFERENCES control.eval_results (result_id)
                ON DELETE SET NULL,
  run_id        uuid REFERENCES control.runs (run_id) ON DELETE SET NULL,
  verdict       text NOT NULL
                CHECK (verdict IN ('PASS','FAIL','BLOCKED','NOT_RUN')),
  score         numeric(6,4) CHECK (score IS NULL OR score BETWEEN 0 AND 1),
  -- 基準版との差分 (正なら改善)
  baseline_score numeric(6,4)
                CHECK (baseline_score IS NULL OR baseline_score BETWEEN 0 AND 1),
  evidence      jsonb NOT NULL DEFAULT '{}'::jsonb,
  occurred_at   timestamptz NOT NULL DEFAULT now(),
  idempotency_key text NOT NULL DEFAULT gen_random_uuid()::text,
  created_at    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_skill_evaluations_idem UNIQUE (idempotency_key)
);

CREATE INDEX IF NOT EXISTS idx_skill_evaluations_version
  ON control.skill_evaluations (skill_version_id, occurred_at DESC);

-- ------------------------------------------------------------
-- control.skill_promotions
--   promoted への昇格は必ず承認を伴う (自己改善結果の main 反映は
--   Human Approval Gate 対象)。
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS control.skill_promotions (
  promotion_id  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  skill_version_id uuid NOT NULL
                REFERENCES control.skill_versions (skill_version_id)
                ON DELETE RESTRICT,
  from_status   text NOT NULL
                CHECK (from_status IN ('draft','canary','promoted','retired')),
  to_status     text NOT NULL
                CHECK (to_status IN ('draft','canary','promoted','retired')),
  approval_id   uuid REFERENCES control.approvals (approval_id) ON DELETE SET NULL,
  -- 昇格の根拠 PR
  pr_ref        text CHECK (pr_ref IS NULL
                            OR pr_ref ~ '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+#[0-9]+$'),
  promoted_by   control.safe_text NOT NULL,
  rationale     control.safe_text NOT NULL DEFAULT '',
  occurred_at   timestamptz NOT NULL DEFAULT now(),
  idempotency_key text NOT NULL DEFAULT gen_random_uuid()::text,
  created_at    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_skill_promotions_idem UNIQUE (idempotency_key),
  CONSTRAINT ck_skill_promotions_transition CHECK (from_status <> to_status),
  CONSTRAINT ck_skill_promotions_needs_approval
    CHECK (to_status <> 'promoted' OR approval_id IS NOT NULL)
);

CREATE INDEX IF NOT EXISTS idx_skill_promotions_version
  ON control.skill_promotions (skill_version_id, occurred_at DESC);

-- ------------------------------------------------------------
-- control.canary_runs — 新版を限定適用して基準版と比較する
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS control.canary_runs (
  canary_id     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  skill_version_id uuid NOT NULL
                REFERENCES control.skill_versions (skill_version_id)
                ON DELETE CASCADE,
  run_id        uuid REFERENCES control.runs (run_id) ON DELETE SET NULL,
  baseline_run_id uuid REFERENCES control.runs (run_id) ON DELETE SET NULL,
  outcome       text NOT NULL DEFAULT 'running'
                CHECK (outcome IN ('running','improved','neutral',
                                   'regressed','aborted')),
  -- 指標差分 (成功率 / 所要時間 / token 消費など)
  delta         jsonb NOT NULL DEFAULT '{}'::jsonb,
  sample_size   integer NOT NULL DEFAULT 0 CHECK (sample_size >= 0),
  started_at    timestamptz NOT NULL DEFAULT now(),
  ended_at      timestamptz,
  note          control.safe_text,
  idempotency_key text NOT NULL DEFAULT gen_random_uuid()::text,
  created_at    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_canary_runs_idem UNIQUE (idempotency_key),
  CONSTRAINT ck_canary_runs_distinct_runs
    CHECK (run_id IS NULL OR baseline_run_id IS NULL
           OR run_id <> baseline_run_id),
  CONSTRAINT ck_canary_runs_time
    CHECK (ended_at IS NULL OR ended_at >= started_at)
);

CREATE INDEX IF NOT EXISTS idx_canary_runs_active
  ON control.canary_runs (skill_version_id, started_at DESC)
  WHERE outcome = 'running';

-- ------------------------------------------------------------
-- control.trust_scores
--   Agent / Skill / Workflow の信頼度を期間ごとに記録する。
--   過去値を書き換えず、新しい計算結果を追記していく。
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS control.trust_scores (
  trust_score_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  subject_kind  text NOT NULL
                CHECK (subject_kind IN ('agent','skill','workflow',
                                        'routing_policy','project')),
  subject_ref   text NOT NULL
                CHECK (subject_ref ~ '^[A-Za-z0-9][A-Za-z0-9._/-]{0,127}$'),
  agent_id      uuid REFERENCES control.agents (agent_id) ON DELETE SET NULL,
  skill_version_id uuid REFERENCES control.skill_versions (skill_version_id)
                ON DELETE SET NULL,
  score         numeric(5,4) NOT NULL CHECK (score BETWEEN 0 AND 1),
  sample_size   integer NOT NULL DEFAULT 0 CHECK (sample_size >= 0),
  success_count integer NOT NULL DEFAULT 0 CHECK (success_count >= 0),
  failure_count integer NOT NULL DEFAULT 0 CHECK (failure_count >= 0),
  window_start  timestamptz NOT NULL,
  window_end    timestamptz NOT NULL,
  computed_at   timestamptz NOT NULL DEFAULT now(),
  method        text NOT NULL DEFAULT 'v1'
                CHECK (method ~ '^[a-z0-9][a-z0-9._-]{0,31}$'),
  detail        jsonb NOT NULL DEFAULT '{}'::jsonb,
  idempotency_key text NOT NULL DEFAULT gen_random_uuid()::text,
  created_at    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_trust_scores_idem UNIQUE (idempotency_key),
  CONSTRAINT uq_trust_scores_window
    UNIQUE (subject_kind, subject_ref, method, window_start, window_end),
  CONSTRAINT ck_trust_scores_window CHECK (window_end > window_start),
  CONSTRAINT ck_trust_scores_counts
    CHECK (success_count + failure_count <= sample_size)
);

CREATE INDEX IF NOT EXISTS idx_trust_scores_latest
  ON control.trust_scores (subject_kind, subject_ref, computed_at DESC);

-- 各対象の最新スコア
CREATE OR REPLACE VIEW control.v_trust_scores_latest AS
SELECT DISTINCT ON (subject_kind, subject_ref, method)
       subject_kind, subject_ref, method, score, sample_size,
       window_start, window_end, computed_at
  FROM control.trust_scores
 ORDER BY subject_kind, subject_ref, method, computed_at DESC;

-- ------------------------------------------------------------
-- 権限
-- ------------------------------------------------------------
DO $do$
DECLARE
  t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['failure_patterns','improvement_proposals',
                           'skill_candidates','skill_versions',
                           'skill_evaluations','skill_promotions',
                           'canary_runs','trust_scores'] LOOP
    PERFORM control.grant_if_role('claudeos_control_app',
              'SELECT, INSERT, UPDATE', 'TABLE control.' || t);
  END LOOP;

  PERFORM control.grant_if_role('claudeos_control_app', 'SELECT',
            'TABLE control.improvement_targets');
  PERFORM control.grant_if_role('claudeos_control_ro', 'SELECT',
            'ALL TABLES IN SCHEMA control');
END
$do$;

INSERT INTO control.schema_migrations (version, filename, checksum)
VALUES ('0005', '0005_self_improvement.sql', :'checksum')
ON CONFLICT (version) DO NOTHING;

COMMIT;
