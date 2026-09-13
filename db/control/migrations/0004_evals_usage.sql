-- ============================================================
-- claudeos_control / migration 0004_evals_usage.sql
--
-- 目的: 評価定義と結果、モデル利用量 (token / cost)、失敗イベント、
--       workflow のイベント。
-- 前提: 0001〜0003 が適用済みであること。
--
-- 金額は整数マイクロ USD (cost_micro_usd) で保持する。浮動小数の
-- 累積誤差を避け、集計を決定論的にするため。
-- ============================================================

\if :{?checksum}
\else
\set checksum 'unverified'
\endif

BEGIN;

-- ------------------------------------------------------------
-- control.eval_definitions
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS control.eval_definitions (
  eval_id      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  eval_key     text NOT NULL UNIQUE
               CHECK (eval_key ~ '^[a-z][a-z0-9._-]{0,95}$'),
  eval_kind    text NOT NULL
               CHECK (eval_kind IN ('golden','regression','security',
                                    'outcome','performance','smoke')),
  title        control.safe_text NOT NULL,
  -- 実行方法の参照 (スクリプトの相対パス等)。コマンド全文や秘密は入れない。
  runner_ref   control.safe_text,
  spec         jsonb   NOT NULL DEFAULT '{}'::jsonb,
  -- 合格閾値 (0..1)。NULL なら二値判定のみ。
  pass_threshold numeric(5,4)
               CHECK (pass_threshold IS NULL
                      OR pass_threshold BETWEEN 0 AND 1),
  -- 品質ゲートの必須項目か
  is_required  boolean NOT NULL DEFAULT false,
  is_active    boolean NOT NULL DEFAULT true,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now()
);
SELECT control.ensure_touch_trigger('control', 'eval_definitions');

CREATE INDEX IF NOT EXISTS idx_eval_definitions_required
  ON control.eval_definitions (eval_kind) WHERE is_active AND is_required;

-- ------------------------------------------------------------
-- control.eval_results
--   verdict はリポジトリ規約の 4 値 (PASS / FAIL / BLOCKED / NOT_RUN)。
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS control.eval_results (
  result_id    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  eval_id      uuid NOT NULL
               REFERENCES control.eval_definitions (eval_id) ON DELETE RESTRICT,
  run_id       uuid REFERENCES control.runs (run_id) ON DELETE CASCADE,
  step_id      uuid REFERENCES control.run_steps (step_id) ON DELETE SET NULL,
  agent_id     uuid REFERENCES control.agents (agent_id) ON DELETE SET NULL,
  verdict      text NOT NULL
               CHECK (verdict IN ('PASS','FAIL','BLOCKED','NOT_RUN')),
  score        numeric(6,4) CHECK (score IS NULL OR score BETWEEN 0 AND 1),
  -- 検証対象の commit。head SHA と検証済み commit の一致確認に使う。
  head_sha     text CHECK (head_sha IS NULL OR head_sha ~ '^[0-9a-f]{7,40}$'),
  duration_ms  integer CHECK (duration_ms IS NULL OR duration_ms >= 0),
  evidence     jsonb NOT NULL DEFAULT '{}'::jsonb,
  message      control.safe_text,
  occurred_at  timestamptz NOT NULL DEFAULT now(),
  idempotency_key text NOT NULL DEFAULT gen_random_uuid()::text,
  created_at   timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_eval_results_idem UNIQUE (idempotency_key)
);

CREATE INDEX IF NOT EXISTS idx_eval_results_run
  ON control.eval_results (run_id, occurred_at DESC);
CREATE INDEX IF NOT EXISTS idx_eval_results_failing
  ON control.eval_results (eval_id, occurred_at DESC)
  WHERE verdict IN ('FAIL','BLOCKED');

-- ------------------------------------------------------------
-- control.model_usage
--   API キーや組織 ID は保持しない。モデル識別子と数量のみ。
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS control.model_usage (
  usage_id     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  run_id       uuid REFERENCES control.runs (run_id) ON DELETE CASCADE,
  step_id      uuid REFERENCES control.run_steps (step_id) ON DELETE SET NULL,
  agent_id     uuid REFERENCES control.agents (agent_id) ON DELETE SET NULL,
  project_id   uuid REFERENCES control.projects (project_id) ON DELETE SET NULL,

  model_id     text NOT NULL
               CHECK (model_id ~ '^[A-Za-z0-9._\[\]-]{1,64}$'),
  request_kind text NOT NULL DEFAULT 'message'
               CHECK (request_kind IN ('message','tool','embedding',
                                       'batch','subagent')),

  input_tokens          bigint NOT NULL DEFAULT 0 CHECK (input_tokens >= 0),
  output_tokens         bigint NOT NULL DEFAULT 0 CHECK (output_tokens >= 0),
  cache_read_tokens     bigint NOT NULL DEFAULT 0 CHECK (cache_read_tokens >= 0),
  cache_creation_tokens bigint NOT NULL DEFAULT 0 CHECK (cache_creation_tokens >= 0),
  total_tokens bigint GENERATED ALWAYS AS
               (input_tokens + output_tokens + cache_creation_tokens) STORED,

  -- 整数マイクロ USD。丸め誤差を避けるため numeric/float を使わない。
  cost_micro_usd bigint NOT NULL DEFAULT 0 CHECK (cost_micro_usd >= 0),
  currency     char(3) NOT NULL DEFAULT 'USD' CHECK (currency ~ '^[A-Z]{3}$'),

  occurred_at  timestamptz NOT NULL DEFAULT now(),
  idempotency_key text NOT NULL DEFAULT gen_random_uuid()::text,
  created_at   timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_model_usage_idem UNIQUE (idempotency_key)
);
COMMENT ON COLUMN control.model_usage.cost_micro_usd IS
  '1e-6 USD 単位の整数。表示時に 1,000,000 で割る。';

CREATE INDEX IF NOT EXISTS idx_model_usage_time
  ON control.model_usage (occurred_at DESC);
CREATE INDEX IF NOT EXISTS idx_model_usage_project_model
  ON control.model_usage (project_id, model_id, occurred_at DESC);

-- 日次集計ビュー (予算監視用)
CREATE OR REPLACE VIEW control.v_model_usage_daily AS
SELECT date_trunc('day', occurred_at) AS usage_day,
       project_id,
       model_id,
       sum(input_tokens)  AS input_tokens,
       sum(output_tokens) AS output_tokens,
       sum(total_tokens)  AS total_tokens,
       sum(cost_micro_usd) AS cost_micro_usd,
       count(*)           AS request_count
  FROM control.model_usage
 GROUP BY 1, 2, 3;

-- ------------------------------------------------------------
-- control.failure_events
--   signature は正規化した失敗の指紋。同一 failure ×2 で根本原因分析、
--   同一 strategy ×3 で戦略変更、というリポジトリ規約の判定に使う。
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS control.failure_events (
  failure_id   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  run_id       uuid REFERENCES control.runs (run_id) ON DELETE CASCADE,
  step_id      uuid REFERENCES control.run_steps (step_id) ON DELETE SET NULL,
  agent_id     uuid REFERENCES control.agents (agent_id) ON DELETE SET NULL,
  project_id   uuid REFERENCES control.projects (project_id) ON DELETE SET NULL,

  failure_kind text NOT NULL
               CHECK (failure_kind IN ('test','lint','typecheck','build',
                                       'ci','security','deployment','migration',
                                       'permission','timeout','external',
                                       'tool','unknown')),
  -- 正規化済みの指紋 (可変部分を除去したメッセージの sha256 等)
  signature    text NOT NULL
               CHECK (signature ~ '^[0-9a-f]{64}$'),
  strategy_key text CHECK (strategy_key IS NULL
                           OR strategy_key ~ '^[a-z][a-z0-9._-]{0,63}$'),
  attempt_index smallint NOT NULL DEFAULT 1 CHECK (attempt_index >= 1),
  message      control.safe_text NOT NULL DEFAULT '',
  detail       jsonb NOT NULL DEFAULT '{}'::jsonb,
  is_resolved  boolean NOT NULL DEFAULT false,
  resolved_at  timestamptz,
  occurred_at  timestamptz NOT NULL DEFAULT now(),
  idempotency_key text NOT NULL DEFAULT gen_random_uuid()::text,
  created_at   timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_failure_events_idem UNIQUE (idempotency_key),
  CONSTRAINT ck_failure_events_resolved
    CHECK (is_resolved = (resolved_at IS NOT NULL))
);

CREATE INDEX IF NOT EXISTS idx_failure_events_signature
  ON control.failure_events (signature, occurred_at DESC);
CREATE INDEX IF NOT EXISTS idx_failure_events_strategy
  ON control.failure_events (run_id, strategy_key, occurred_at)
  WHERE strategy_key IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_failure_events_open
  ON control.failure_events (occurred_at DESC) WHERE NOT is_resolved;

-- 反復失敗の検出 (同一 signature が 2 回以上、同一 strategy が 3 回以上)
CREATE OR REPLACE VIEW control.v_repeated_failures AS
SELECT run_id,
       signature,
       strategy_key,
       count(*)          AS occurrence_count,
       min(occurred_at)  AS first_seen,
       max(occurred_at)  AS last_seen,
       (count(*) >= 2)   AS needs_root_cause_analysis,
       (strategy_key IS NOT NULL AND count(*) >= 3) AS needs_strategy_change
  FROM control.failure_events
 WHERE NOT is_resolved
 GROUP BY run_id, signature, strategy_key
HAVING count(*) >= 2;

-- ------------------------------------------------------------
-- control.workflow_events
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS control.workflow_events (
  workflow_event_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  run_id       uuid REFERENCES control.runs (run_id) ON DELETE CASCADE,
  step_id      uuid REFERENCES control.run_steps (step_id) ON DELETE SET NULL,
  agent_id     uuid REFERENCES control.agents (agent_id) ON DELETE SET NULL,
  workflow_key text NOT NULL
               CHECK (workflow_key ~ '^[a-z][a-z0-9._-]{0,95}$'),
  node_key     text NOT NULL
               CHECK (node_key ~ '^[a-z0-9][a-z0-9._-]{0,95}$'),
  event_kind   text NOT NULL
               CHECK (event_kind IN ('enter','exit','branch','skip',
                                     'retry','error','wait')),
  -- 分岐理由 / routing 判断の記録 (routing_log の DB 側表現)
  decision     control.safe_text,
  duration_ms  integer CHECK (duration_ms IS NULL OR duration_ms >= 0),
  payload      jsonb NOT NULL DEFAULT '{}'::jsonb,
  occurred_at  timestamptz NOT NULL DEFAULT now(),
  idempotency_key text NOT NULL DEFAULT gen_random_uuid()::text,
  created_at   timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_workflow_events_idem UNIQUE (idempotency_key)
);

CREATE INDEX IF NOT EXISTS idx_workflow_events_run
  ON control.workflow_events (run_id, occurred_at);
CREATE INDEX IF NOT EXISTS idx_workflow_events_node
  ON control.workflow_events (workflow_key, node_key, occurred_at DESC);

-- ------------------------------------------------------------
-- 権限
-- ------------------------------------------------------------
DO $do$
DECLARE
  t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['eval_definitions','eval_results','model_usage',
                           'failure_events','workflow_events'] LOOP
    PERFORM control.grant_if_role('claudeos_control_app',
              'SELECT, INSERT, UPDATE', 'TABLE control.' || t);
  END LOOP;

  PERFORM control.grant_if_role('claudeos_control_ro', 'SELECT',
            'ALL TABLES IN SCHEMA control');
END
$do$;

INSERT INTO control.schema_migrations (version, filename, checksum)
VALUES ('0004', '0004_evals_usage.sql', :'checksum')
ON CONFLICT (version) DO NOTHING;

COMMIT;
