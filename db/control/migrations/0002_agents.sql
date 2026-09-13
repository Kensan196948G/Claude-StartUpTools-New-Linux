-- ============================================================
-- claudeos_control / migration 0002_agents.sql
--
-- 目的: Agent の登録、能力、割当 (排他パススコープ)、引き継ぎ、
--       復帰ポイント (checkpoint)。
-- 前提: 0001_foundation.sql が適用済みであること。
-- 規約: 0001 のヘッダを参照 (追加のみ / 拡張不要 / 秘密不保持)。
-- ============================================================

\if :{?checksum}
\else
\set checksum 'unverified'
\endif

BEGIN;

-- ------------------------------------------------------------
-- 実行面 (execution plane) の語彙
--   agent-router skill の決定結果に対応する。新しい実行形態は
--   INSERT だけで追加できる。
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS control.execution_planes (
  plane       text PRIMARY KEY,
  is_parallel boolean     NOT NULL DEFAULT false,
  description text        NOT NULL DEFAULT '',
  created_at  timestamptz NOT NULL DEFAULT now()
);
INSERT INTO control.execution_planes (plane, is_parallel, description) VALUES
  ('main',             false, 'メインセッションで直接実行'),
  ('subagent',         true,  'Task subagent'),
  ('background_agent', true,  'バックグラウンド実行'),
  ('agent_view',       false, 'Agent View で監視しながら実行'),
  ('agent_team',       true,  'Agent Teams (相互通信あり)'),
  ('dynamic_workflow', true,  'Dynamic Workflow'),
  ('worktree',         true,  'git worktree で分離した並列編集'),
  ('managed_agent',    true,  'Managed Agents (API 側サンドボックス)')
ON CONFLICT (plane) DO NOTHING;

-- ------------------------------------------------------------
-- control.agents
--   モデル ID や instruction の参照先は保持するが、API キーや
--   認証情報は一切保持しない。
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS control.agents (
  agent_id       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agent_name     text NOT NULL UNIQUE
                 CHECK (agent_name ~ '^[a-z0-9][a-z0-9._-]{0,63}$'),
  agent_kind     text NOT NULL DEFAULT 'generalist'
                 CHECK (agent_kind IN ('generalist','cto','implementer',
                                       'reviewer','security_reviewer','qa',
                                       'e2e','ci_manager','manager','auditor',
                                       'grader','explorer','planner')),
  execution_plane text NOT NULL DEFAULT 'subagent'
                 REFERENCES control.execution_planes (plane),
  -- モデル識別子のみ (資格情報ではない)
  model_id       text CHECK (model_id IS NULL
                             OR model_id ~ '^[A-Za-z0-9._\[\]-]{1,64}$'),
  -- instruction の所在 (リポジトリ相対パス)。本文は保存しない。
  instruction_ref control.safe_text,
  instruction_sha256 text CHECK (instruction_sha256 IS NULL
                                 OR instruction_sha256 ~ '^[0-9a-f]{64}$'),
  -- Generator と Verifier を分離するための役割フラグ
  is_verifier    boolean NOT NULL DEFAULT false,
  is_active      boolean NOT NULL DEFAULT true,
  metadata       jsonb   NOT NULL DEFAULT '{}'::jsonb,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now()
);
SELECT control.ensure_touch_trigger('control', 'agents');

CREATE INDEX IF NOT EXISTS idx_agents_active_kind
  ON control.agents (agent_kind) WHERE is_active;

-- ------------------------------------------------------------
-- control.agent_capabilities
--   agent-router が割当先を決める際の照合材料。
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS control.agent_capabilities (
  agent_id     uuid NOT NULL
               REFERENCES control.agents (agent_id) ON DELETE CASCADE,
  capability   text NOT NULL
               CHECK (capability ~ '^[a-z][a-z0-9._-]{0,63}$'),
  proficiency  smallint NOT NULL DEFAULT 3 CHECK (proficiency BETWEEN 1 AND 5),
  -- security / database / deployment 影響のある能力は明示する
  is_sensitive boolean NOT NULL DEFAULT false,
  note         control.safe_text,
  created_at   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (agent_id, capability)
);

CREATE INDEX IF NOT EXISTS idx_agent_capabilities_lookup
  ON control.agent_capabilities (capability, proficiency DESC);

-- ------------------------------------------------------------
-- control.agent_assignments
--
-- path_scope は「この割当が排他的に編集してよいリポジトリ相対パス接頭辞」。
-- 同一プロジェクトの同一スコープを同時に 2 つの Agent へ割り当てないことを
-- 部分 UNIQUE 索引で強制する (並列編集は worktree で分離する、という
-- リポジトリ規約の機械的な担保)。
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS control.agent_assignments (
  assignment_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id    uuid NOT NULL
                REFERENCES control.projects (project_id) ON DELETE RESTRICT,
  run_id        uuid NOT NULL
                REFERENCES control.runs (run_id) ON DELETE CASCADE,
  agent_id      uuid NOT NULL
                REFERENCES control.agents (agent_id) ON DELETE RESTRICT,
  task_id       uuid REFERENCES control.tasks (task_id) ON DELETE SET NULL,
  assigned_role text NOT NULL DEFAULT 'implementer'
                CHECK (assigned_role IN ('implementer','reviewer','verifier',
                                         'planner','observer')),
  path_scope    control.safe_text,
  worktree_path control.safe_text,
  branch_name   text CHECK (branch_name IS NULL
                            OR branch_name ~ '^[A-Za-z0-9._/-]{1,200}$'),
  assigned_at   timestamptz NOT NULL DEFAULT now(),
  released_at   timestamptz,
  release_reason control.safe_text,
  idempotency_key text NOT NULL DEFAULT gen_random_uuid()::text,
  created_at    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_agent_assignments_idem UNIQUE (idempotency_key),
  CONSTRAINT ck_agent_assignments_time
    CHECK (released_at IS NULL OR released_at >= assigned_at)
);

-- 同一 path_scope の同時割当を禁止する
CREATE UNIQUE INDEX IF NOT EXISTS uq_agent_assignments_active_scope
  ON control.agent_assignments (project_id, path_scope)
  WHERE released_at IS NULL AND path_scope IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_agent_assignments_run
  ON control.agent_assignments (run_id);

CREATE INDEX IF NOT EXISTS idx_agent_assignments_active_agent
  ON control.agent_assignments (agent_id) WHERE released_at IS NULL;

-- ------------------------------------------------------------
-- control.handoffs — Agent 間の作業引き継ぎ
--   受信内容は技術情報として扱い、人間承認の代替にしない
--   (CLAUDE.md §10)。承認は 0003 の approvals でのみ表現する。
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS control.handoffs (
  handoff_id    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  run_id        uuid NOT NULL
                REFERENCES control.runs (run_id) ON DELETE CASCADE,
  from_agent_id uuid REFERENCES control.agents (agent_id) ON DELETE SET NULL,
  to_agent_id   uuid REFERENCES control.agents (agent_id) ON DELETE SET NULL,
  from_step_id  uuid REFERENCES control.run_steps (step_id) ON DELETE SET NULL,
  handoff_kind  text NOT NULL DEFAULT 'work'
                CHECK (handoff_kind IN ('work','review','verification',
                                        'escalation','information')),
  state         text NOT NULL DEFAULT 'offered'
                CHECK (state IN ('offered','accepted','rejected',
                                 'expired','superseded')),
  summary       control.safe_text NOT NULL,
  -- 成果物の参照 (パス / SHA / PR 番号)。本文や秘密は入れない。
  artifacts     jsonb NOT NULL DEFAULT '[]'::jsonb,
  offered_at    timestamptz NOT NULL DEFAULT now(),
  expires_at    timestamptz,
  accepted_at   timestamptz,
  idempotency_key text NOT NULL DEFAULT gen_random_uuid()::text,
  created_at    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_handoffs_idem UNIQUE (idempotency_key),
  CONSTRAINT ck_handoffs_distinct_agents
    CHECK (from_agent_id IS NULL OR to_agent_id IS NULL
           OR from_agent_id <> to_agent_id),
  CONSTRAINT ck_handoffs_accept_state
    CHECK (accepted_at IS NULL OR state = 'accepted')
);

CREATE INDEX IF NOT EXISTS idx_handoffs_open
  ON control.handoffs (to_agent_id, offered_at)
  WHERE state = 'offered';

-- ------------------------------------------------------------
-- control.checkpoints — 復帰ポイント
--   rollback 可能性の担保に使う。git commit SHA と、復元手順を
--   一意に定める参照だけを持つ。
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS control.checkpoints (
  checkpoint_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  run_id        uuid NOT NULL
                REFERENCES control.runs (run_id) ON DELETE CASCADE,
  step_id       uuid REFERENCES control.run_steps (step_id) ON DELETE SET NULL,
  agent_id      uuid REFERENCES control.agents (agent_id) ON DELETE SET NULL,
  label         text NOT NULL
                CHECK (label ~ '^[A-Za-z0-9][A-Za-z0-9._/-]{0,127}$'),
  checkpoint_kind text NOT NULL DEFAULT 'commit'
                CHECK (checkpoint_kind IN ('commit','backup','snapshot',
                                           'state','deployment')),
  git_commit_sha text CHECK (git_commit_sha IS NULL
                             OR git_commit_sha ~ '^[0-9a-f]{7,40}$'),
  -- backup ファイル等の所在。パスのみで、資格情報は含めない。
  artifact_ref  control.safe_text,
  artifact_sha256 text CHECK (artifact_sha256 IS NULL
                              OR artifact_sha256 ~ '^[0-9a-f]{64}$'),
  is_restorable boolean NOT NULL DEFAULT true,
  verified_at   timestamptz,
  state_snapshot jsonb NOT NULL DEFAULT '{}'::jsonb,
  idempotency_key text NOT NULL DEFAULT gen_random_uuid()::text,
  created_at    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_checkpoints_idem  UNIQUE (idempotency_key),
  CONSTRAINT uq_checkpoints_label UNIQUE (run_id, label)
);

CREATE INDEX IF NOT EXISTS idx_checkpoints_restorable
  ON control.checkpoints (run_id, created_at DESC) WHERE is_restorable;

-- ------------------------------------------------------------
-- 権限
-- ------------------------------------------------------------
DO $do$
DECLARE
  t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['agents','agent_capabilities','agent_assignments',
                           'handoffs','checkpoints'] LOOP
    PERFORM control.grant_if_role('claudeos_control_app',
              'SELECT, INSERT, UPDATE', 'TABLE control.' || t);
  END LOOP;

  PERFORM control.grant_if_role('claudeos_control_app', 'SELECT',
            'TABLE control.execution_planes');
  PERFORM control.grant_if_role('claudeos_control_ro', 'SELECT',
            'ALL TABLES IN SCHEMA control');
END
$do$;

INSERT INTO control.schema_migrations (version, filename, checksum)
VALUES ('0002', '0002_agents.sql', :'checksum')
ON CONFLICT (version) DO NOTHING;

COMMIT;
