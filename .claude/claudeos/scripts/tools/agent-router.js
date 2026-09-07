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
//
// 入力 (JSON): { task_type, complexity, risk, files_affected, expected_duration_min, parallelism,
//               security_impact, database_impact, deployment_impact, needs_inter_agent_communication,
//               shared_files, read_only }
// 出力 (JSON): { execution, worktree, reasons[], guardrails[], inputs }
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

  return { execution, worktree, reasons, guardrails, inputs: i };
}

function record(decision, stateFile) {
  try {
    const state = JSON.parse(fs.readFileSync(stateFile, 'utf8'));
    state.execution = state.execution || {};
    const log = Array.isArray(state.execution.routing_log) ? state.execution.routing_log : [];
    log.push({ at: new Date().toISOString(), execution: decision.execution, worktree: decision.worktree, reasons: decision.reasons, task_type: decision.inputs.task_type });
    state.execution.routing_log = log.slice(-20);
    const tmp = `${stateFile}.tmp.${process.pid}`;
    fs.writeFileSync(tmp, JSON.stringify(state, null, 2) + '\n');
    fs.renameSync(tmp, stateFile);
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
  if (args.includes('--record')) decision.recorded = record(decision, path.join(process.cwd(), 'state.json'));
  process.stdout.write(JSON.stringify(decision, null, 2) + '\n');
}

if (require.main === module) main();
module.exports = { route, LEVELS };
