#!/usr/bin/env node
'use strict';
// agent-router.js — ClaudeOS v10 Agent Orchestration Router (deterministic, testable)
//
// CTO の前段で「どの実行形態を使うか」を task 特性から決定し、理由を記録する。
// 決定は Claude Code Native の実行形態に対応する:
//   Main            : 現セッションで直接実施 (小規模 / 高リスク・要人間可視)
//   Subagent        : Agent tool (独立した限定作業、結果だけ要る)
//   BackgroundAgent : claude --bg / /background (独立した長時間作業)
//   AgentView       : 複数 background session を claude agents で監視 (複数の独立長時間作業)
//   AgentTeams      : 実験機能。Agent 間の相互通信が本当に必要な場合のみ
//   DynamicWorkflow : /workflows (大量調査 / 大規模監査 / 相互検証)
//   worktree        : 並列コード編集がある場合は git worktree 分離を必須にする
//   ManagedAgent    : Claude Managed Agents (クラウド補完)。入力に managed ブロックがある場合のみ評価する
//                     opt-in。低リスク・読取専用タスクに限り、Local が使えない時か明示要求時だけ選ぶ
//
// 入力 (JSON): { task_type, complexity, risk, files_affected, expected_duration_min, parallelism,
//               security_impact, database_impact, deployment_impact, needs_inter_agent_communication,
//               shared_files, read_only,
//               managed?: { available, requested, local_available, budget_state, duplicate, human_gate,
//                           data_sensitivity, requires_secrets, requires_external_network, max_duration_min,
//                           allowed_task_types[] } }
// 出力 (JSON): { execution, worktree, reasons[], guardrails[], inputs [, managed] }
//   managed ブロック省略時の出力は従来と完全に同一 (配布先プロジェクトの後方互換)。
//   Router は純関数: クレジット残高や稼働状態は呼び出し側 (scripts/tools/managed-agents.js route) が渡す。
//
// CLI:  node scripts/tools/agent-router.js --json '<input json>' [--record]
//       echo '<json>' | node scripts/tools/agent-router.js [--record]
//   --record: state.json の execution.routing_log へ末尾追記 (最新 20 件保持)

const fs = require('fs');
const path = require('path');

const LEVELS = { low: 1, medium: 2, high: 3, critical: 4 };
function lvl(v, def = 'medium') { return LEVELS[String(v || def).toLowerCase()] || LEVELS[def]; }
function num(v, def = 0) { const n = Number(v); return Number.isFinite(n) ? n : def; }
function bool(v) { return v === true || v === 'true' || v === 1 || v === '1'; }

// Managed Agents へ出してよいタスク種別 (初期 PoC: 読取専用の分析・提案のみ)
const MANAGED_TASK_TYPES = ['review', 'code-review', 'diff-analysis', 'qa-analysis', 'test-generation', 'triage', 'docs', 'research', 'check'];

// managedEligibility — Managed Agents を選んでよいかの判定 (純関数)。
//   denied[]  : 選択不可の理由。kind=policy は安全上の拒否で、フォールバックで回避してはならない。
//               kind=capacity は予算・可用性の不足で、Local 経路へ安全に戻してよい。
//   preferred : Local が使えない、または明示要求がある (Local 稼働中というだけでは並列起動しない)。
function managedEligibility(i, m) {
  const denied = [];
  const deny = (kind, code, text) => denied.push({ kind, code, text });
  const allowedTypes = Array.isArray(m.allowed_task_types) && m.allowed_task_types.length
    ? m.allowed_task_types.map((t) => String(t).toLowerCase()) : MANAGED_TASK_TYPES;
  const sensitivity = String(m.data_sensitivity || 'internal').toLowerCase();
  const budget = String(m.budget_state || 'unknown').toLowerCase();
  const maxDuration = num(m.max_duration_min, 30);

  if (bool(m.human_gate)) deny('policy', 'human-gate', '人間承認待ちのタスクは Managed Agents へ出さない');
  if (!i.readOnly) deny('policy', 'not-read-only', '初期 PoC は読取専用タスクのみ');
  if (i.risk > LEVELS.low) deny('policy', 'risk', 'risk が low を超える');
  if (i.security > LEVELS.low) deny('policy', 'security-impact', 'security_impact が low を超える');
  if (i.database > LEVELS.low) deny('policy', 'database-impact', 'Local PostgreSQL へ影響するタスクは対象外');
  if (i.deployment > LEVELS.low) deny('policy', 'deployment-impact', '本番・デプロイへ影響するタスクは対象外');
  if (bool(m.requires_secrets)) deny('policy', 'requires-secrets', 'Secret を必要とするタスクは対象外');
  if (sensitivity !== 'public' && sensitivity !== 'internal') deny('policy', 'data-sensitivity', `データ機密性 ${sensitivity} は対象外`);
  if (bool(m.requires_external_network)) deny('policy', 'external-network', '外部通信が必要なタスクは対象外 (environment は limited networking)');
  if (i.comm) deny('policy', 'inter-agent-communication', 'Agent 間の相互通信が必要なタスクは対象外');
  if (!allowedTypes.includes(i.task_type)) deny('policy', 'task-type', `task_type=${i.task_type} は許可リスト外`);
  if (i.duration > maxDuration) deny('policy', 'duration', `所要時間 ${i.duration}min が上限 ${maxDuration}min を超える`);

  if (!bool(m.available)) deny('capacity', 'managed-unavailable', 'Managed Agents が利用不可 (設定・認証・稼働状態)');
  if (bool(m.duplicate)) deny('capacity', 'duplicate-task', '同一タスク ID のセッションが既に存在する');
  if (budget === 'verify-only') {
    if (i.task_type !== 'check') deny('capacity', 'budget-verify-only', '予算 85% 以上: 低コストの確認処理のみ許可');
  } else if (budget !== 'ok' && budget !== 'warn') {
    deny('capacity', `budget-${budget}`, `予算状態 ${budget} のため新規セッション不可`);
  }

  const localAvailable = m.local_available === undefined ? true : bool(m.local_available);
  const preferred = bool(m.requested) || !localAvailable;
  return { eligible: denied.length === 0, preferred, denied, local_available: localAvailable, budget_state: budget };
}

function route(raw) {
  const i = {
    task_type: String(raw.task_type || 'change').toLowerCase(),
    complexity: lvl(raw.complexity),
    risk: lvl(raw.risk),
    files: num(raw.files_affected, 1),
    duration: num(raw.expected_duration_min, 10),
    parallelism: Math.max(1, num(raw.parallelism, 1)),
    security: lvl(raw.security_impact, 'low'),
    database: lvl(raw.database_impact, 'low'),
    deployment: lvl(raw.deployment_impact, 'low'),
    comm: bool(raw.needs_inter_agent_communication),
    shared: bool(raw.shared_files),
    readOnly: bool(raw.read_only),
  };
  const reasons = [];
  const guardrails = [];
  const highImpact = Math.max(i.security, i.database, i.deployment) >= LEVELS.high || i.risk >= LEVELS.high;
  if (highImpact) guardrails.push('high-impact: Human Approval Gate (§17) と PR 本文の backup/rollback 記載が必須');
  if (i.database >= LEVELS.high) guardrails.push('database: pg-ops.sh migration-risk で破壊的 SQL を事前判定');
  if (i.deployment >= LEVELS.high) guardrails.push('deployment: 本番反映は品質ゲート充足後のみ (§16)');
  if (i.security >= LEVELS.high) guardrails.push('security: security-reviewer による独立レビューを Verify に含める');

  let execution;
  const audit = /audit|migration|research|survey|sweep|inventory/.test(i.task_type);
  if (audit && (i.files >= 50 || i.parallelism >= 4)) {
    execution = 'DynamicWorkflow';
    reasons.push(`大量調査/監査 (task_type=${i.task_type}, files=${i.files}, parallelism=${i.parallelism}) は /workflows で fan-out + 相互検証`);
  } else if (i.comm && i.parallelism >= 2 && !highImpact) {
    execution = 'AgentTeams';
    reasons.push('Agent 間の相互通信が必要かつ並列 (実験機能。同一ファイルを複数 Agent へ割り当てない)');
    guardrails.push('agent-teams: CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 が必要。3〜5 teammate、ファイル所有権を分割');
  } else if (i.comm && highImpact) {
    execution = 'Main';
    reasons.push('相互通信が必要だが高リスクのため Main で逐次実施 (人間可視性を優先)');
  } else if (i.parallelism >= 2 && i.duration >= 30 && !i.shared) {
    execution = 'AgentView';
    reasons.push(`独立した長時間作業 ×${i.parallelism} (>=30min) は claude --bg で並列起動し claude agents で監視`);
  } else if (i.duration >= 30 && !highImpact) {
    execution = 'BackgroundAgent';
    reasons.push(`独立した長時間作業 (${i.duration}min) は background session に切り出す`);
  } else if (i.complexity <= LEVELS.low && i.files <= 3 && i.duration < 30) {
    execution = 'Main';
    reasons.push('小規模 (complexity=low, files<=3, <30min) は Main で直接実施');
  } else if (highImpact && !i.readOnly) {
    execution = 'Main';
    reasons.push('高リスク (security/database/deployment/risk >= high) の書込み作業は Main で人間可視のまま実施');
  } else if (i.files <= 20 || i.readOnly) {
    execution = 'Subagent';
    reasons.push(`限定された独立作業 (files=${i.files}, read_only=${i.readOnly}) は Subagent へ委任し結果だけ受け取る`);
  } else {
    execution = 'Main';
    reasons.push('分類に該当しないため既定の Main');
  }

  const parallelWrites = i.parallelism >= 2 && !i.readOnly;
  const worktree = parallelWrites || (execution === 'BackgroundAgent' && !i.readOnly) || execution === 'AgentView';
  if (worktree) reasons.push('並列/背景の書込みは git worktree で分離 (同一ファイル同時書込み禁止)');
  if (i.shared && parallelWrites) guardrails.push('shared_files=true: 同一ファイルを触る作業は直列化するかファイル所有権を分割');

  const decision = { execution, worktree, reasons, guardrails, inputs: i };

  // --- Managed Agents (opt-in)。managed ブロックが無ければ従来の出力をそのまま返す ---
  const m = raw.managed;
  if (m && typeof m === 'object' && !Array.isArray(m)) {
    const e = managedEligibility(i, m);
    const policyDenied = e.denied.filter((d) => d.kind === 'policy');
    decision.managed = {
      eligible: e.eligible,
      selected: false,
      denied: e.denied.map((d) => d.code),
      // Local の決定は常に保持する (API 障害・予算不足時の戻り先)。
      fallback_execution: execution,
      // 安全上の拒否 (policy) がある場合、Managed を別経路で再試行してはならない。
      // Local 経路へ戻っても既存の Human Approval Gate はそのまま適用される。
      policy_denied: policyDenied.length > 0,
    };
    if (e.eligible && e.preferred) {
      decision.execution = 'ManagedAgent';
      decision.worktree = false;
      decision.managed.selected = true;
      reasons.push(e.local_available
        ? '明示要求のある低リスク・読取専用タスクを Managed Agents (クラウド補完) へ委任'
        : 'Local Agent が利用できないため、許可済みの低リスク・読取専用タスクを Managed Agents へ委任');
      guardrails.push('managed: セッション予算 (budget.max_list_cost) 必須・並列 1・自動再試行は最大 1 回');
    } else if (e.eligible) {
      reasons.push('Managed Agents の条件は満たすが、Local が稼働中で明示要求が無いため並列起動しない');
    } else {
      for (const d of e.denied) reasons.push(`Managed Agents 不可 (${d.code}): ${d.text}`);
      if (policyDenied.length) guardrails.push('managed: 安全上の理由で不可。フォールバックで承認・拒否を回避しない');
    }
  }
  return decision;
}

// record — 決定を追記専用の routing-pending.jsonl へ 1 行足す。
//   以前は state.json.execution.routing_log を直接 read-modify-write していたが、
//   複数プロセスからの同時書込みで競合しうるうえ、Control Plane 射影ワーカー
//   (scripts/tools/control-projection.js) が読める形にするため、audit-trail.js と
//   同じ「追記専用 JSONL + 別プロセスが後で集約」方式へ統一した。
//   state.json への反映 (最新20件) は hooks/session-end.js が担う。
function record(decision, dataDir) {
  try {
    fs.mkdirSync(dataDir, { recursive: true });
    const entry = {
      at: new Date().toISOString(),
      execution: decision.execution,
      worktree: decision.worktree,
      reasons: decision.reasons,
      task_type: decision.inputs.task_type,
      project: path.basename(process.cwd()),
    };
    fs.appendFileSync(path.join(dataDir, 'routing-pending.jsonl'), JSON.stringify(entry) + '\n', 'utf8');
    return true;
  } catch { return false; }
}

function main() {
  const args = process.argv.slice(2);
  let input = null;
  const ji = args.indexOf('--json');
  if (ji >= 0) input = JSON.parse(args[ji + 1] || '{}');
  else {
    let raw = '';
    try { raw = fs.readFileSync(0, 'utf8'); } catch { raw = ''; }
    input = raw.trim() ? JSON.parse(raw) : {};
  }
  const decision = route(input);
  if (args.includes('--record')) decision.recorded = record(decision, path.join(process.cwd(), '.claude', 'claudeos', 'data'));
  process.stdout.write(JSON.stringify(decision, null, 2) + '\n');
}

if (require.main === module) main();
module.exports = { route, managedEligibility, LEVELS, MANAGED_TASK_TYPES };
