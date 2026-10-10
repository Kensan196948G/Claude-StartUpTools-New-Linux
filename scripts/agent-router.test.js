// agent-router.test.js — ClaudeOS v10 Agent Router の deterministic eval (golden dataset)
// tests/evals/agent-router.golden.json の全ケースが期待どおり routing されることを検証する。
// Self-Improvement で routing policy を変更する場合は、この eval の pass 率が下がる変更を採用しない。
'use strict';
const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');
const { route } = require('./tools/agent-router.js');

const golden = JSON.parse(fs.readFileSync(path.join(__dirname, '..', 'tests', 'evals', 'agent-router.golden.json'), 'utf8'));

for (const c of golden.cases) {
  test(`router golden: ${c.name}`, () => {
    const d = route(c.input);
    assert.strictEqual(d.execution, c.expect.execution, `execution mismatch: ${JSON.stringify(d.reasons)}`);
    if (typeof c.expect.worktree === 'boolean') assert.strictEqual(d.worktree, c.expect.worktree, 'worktree mismatch');
    if (c.expect.guardrail_contains) assert.ok(d.guardrails.some((g) => g.includes(c.expect.guardrail_contains)), `guardrail missing: ${c.expect.guardrail_contains} in ${JSON.stringify(d.guardrails)}`);
    assert.ok(d.reasons.length > 0, 'reasons must be recorded');
  });
}

test('router: AgentTeams is never chosen for high-impact work', () => {
  for (const impact of ['security_impact', 'database_impact', 'deployment_impact']) {
    const d = route({ task_type: 'feature', parallelism: 3, needs_inter_agent_communication: true, [impact]: 'high' });
    assert.notStrictEqual(d.execution, 'AgentTeams');
  }
});

test('router: parallel writes always require a worktree', () => {
  const d = route({ task_type: 'feature', complexity: 'medium', files_affected: 10, expected_duration_min: 20, parallelism: 2 });
  assert.strictEqual(d.worktree, true);
});

test('router CLI: --json prints a decision and --record appends to routing-pending.jsonl (追記専用、state.json は直接触らない)', () => {
  const tmp = fs.mkdtempSync(path.join(require('os').tmpdir(), 'router-'));
  const pending = path.join(tmp, '.claude', 'claudeos', 'data', 'routing-pending.jsonl');
  const out = execFileSync(process.execPath, [path.join(__dirname, 'tools', 'agent-router.js'), '--json', JSON.stringify({ task_type: 'docs', complexity: 'low' }), '--record'], { cwd: tmp, encoding: 'utf8' });
  const d = JSON.parse(out);
  assert.strictEqual(d.execution, 'Main');
  assert.strictEqual(d.recorded, true);
  assert.ok(!fs.existsSync(path.join(tmp, 'state.json')), 'state.json を新規作成・変更してはならない');
  const lines = fs.readFileSync(pending, 'utf8').trim().split('\n');
  assert.strictEqual(lines.length, 1);
  const entry = JSON.parse(lines[0]);
  assert.strictEqual(entry.execution, 'Main');
  assert.strictEqual(entry.task_type, 'docs');
});

test('router CLI: --record を2回呼ぶと routing-pending.jsonl に2行追記される (追記専用、上書きしない)', () => {
  const tmp = fs.mkdtempSync(path.join(require('os').tmpdir(), 'router-'));
  const pending = path.join(tmp, '.claude', 'claudeos', 'data', 'routing-pending.jsonl');
  for (let i = 0; i < 2; i++) {
    execFileSync(process.execPath, [path.join(__dirname, 'tools', 'agent-router.js'), '--json', JSON.stringify({ task_type: 'docs', complexity: 'low' }), '--record'], { cwd: tmp, encoding: 'utf8' });
  }
  const lines = fs.readFileSync(pending, 'utf8').trim().split('\n');
  assert.strictEqual(lines.length, 2);
});

test('agent-router.js: 正本 (scripts/tools) と2つの配布コピーは同一内容', () => {
  const canonical = fs.readFileSync(path.join(__dirname, 'tools', 'agent-router.js'), 'utf8');
  const deployed = fs.readFileSync(path.join(__dirname, '..', '.claude', 'claudeos', 'scripts', 'tools', 'agent-router.js'), 'utf8');
  const template = fs.readFileSync(path.join(__dirname, '..', 'Claude', 'templates', 'claudeos', 'scripts', 'tools', 'agent-router.js'), 'utf8');
  assert.strictEqual(canonical, deployed);
  assert.strictEqual(canonical, template);
});

// --- Managed Agents (opt-in) ---
const { managedEligibility, MANAGED_TASK_TYPES } = require('./tools/agent-router.js');
const lowRisk = (over) => Object.assign({ task_type: 'review', complexity: 'medium', risk: 'low', read_only: true, files_affected: 10 }, over);
const managedOk = (over) => Object.assign({ available: true, budget_state: 'ok' }, over);

test('router managed: managed ブロックが無ければ出力は従来と完全に同一 (配布先の後方互換)', () => {
  for (const c of golden.cases) {
    const d = route(c.input);
    assert.deepStrictEqual(Object.keys(d), ['execution', 'worktree', 'reasons', 'guardrails', 'inputs'], c.name);
    assert.notStrictEqual(d.execution, 'ManagedAgent');
  }
});

test('router managed: golden の全ケースは managed 利用可能でも明示要求が無ければ実行先が変わらない', () => {
  for (const c of golden.cases) {
    const d = route(Object.assign({}, c.input, { managed: managedOk() }));
    assert.strictEqual(d.execution, c.expect.execution, c.name);
    assert.strictEqual(d.managed.selected, false);
  }
});

test('router managed: 明示要求 + 低リスク・読取専用だけが ManagedAgent、Local の決定は fallback に残る', () => {
  const d = route(lowRisk({ managed: managedOk({ requested: true }) }));
  assert.strictEqual(d.execution, 'ManagedAgent');
  assert.strictEqual(d.worktree, false);
  assert.strictEqual(d.managed.fallback_execution, 'Subagent');
  assert.strictEqual(d.managed.policy_denied, false);
  assert.ok(d.guardrails.some((g) => g.includes('セッション予算')));
});

test('router managed: 高リスク・書込み・DB/デプロイ影響・Secret・人間承認待ちは明示要求があっても選ばない', () => {
  const denied = [
    lowRisk({ read_only: false }), lowRisk({ risk: 'high' }), lowRisk({ security_impact: 'medium' }),
    lowRisk({ database_impact: 'high' }), lowRisk({ deployment_impact: 'high' }), lowRisk({ task_type: 'deploy' }),
    lowRisk({ needs_inter_agent_communication: true }), lowRisk({ expected_duration_min: 120 }),
  ];
  for (const input of denied) {
    const d = route(Object.assign({}, input, { managed: managedOk({ requested: true, local_available: false }) }));
    assert.notStrictEqual(d.execution, 'ManagedAgent', JSON.stringify(input));
    assert.strictEqual(d.managed.policy_denied, true, JSON.stringify(input));
  }
  for (const m of [{ requires_secrets: true }, { human_gate: true }, { data_sensitivity: 'pii' }, { requires_external_network: true }]) {
    const d = route(lowRisk({ managed: managedOk(Object.assign({ requested: true }, m)) }));
    assert.notStrictEqual(d.execution, 'ManagedAgent', JSON.stringify(m));
    assert.strictEqual(d.managed.policy_denied, true);
  }
});

test('router managed: 予算段階 — warn は可、verify-only は check のみ、stop / exhausted / 不明は不可 (capacity)', () => {
  const run = (budget_state, task_type) => route(lowRisk({ task_type: task_type || 'review', managed: { available: true, budget_state, requested: true } }));
  assert.strictEqual(run('warn').execution, 'ManagedAgent');
  assert.notStrictEqual(run('verify-only').execution, 'ManagedAgent');
  assert.strictEqual(run('verify-only', 'check').execution, 'ManagedAgent');
  for (const s of ['budget_stop', 'budget_exhausted', 'unknown', '']) {
    const d = run(s);
    assert.notStrictEqual(d.execution, 'ManagedAgent', s);
    assert.strictEqual(d.managed.policy_denied, false, '予算不足は安全上の拒否ではない');
  }
});

test('router managed: 利用不可・重複タスクは capacity 拒否で Local の決定を返す', () => {
  const unavailable = route(lowRisk({ managed: { available: false, budget_state: 'ok', requested: true } }));
  assert.strictEqual(unavailable.execution, 'Subagent');
  assert.deepStrictEqual(unavailable.managed.denied, ['managed-unavailable']);
  const dup = route(lowRisk({ managed: managedOk({ requested: true, duplicate: true }) }));
  assert.strictEqual(dup.execution, 'Subagent');
  assert.ok(dup.managed.denied.includes('duplicate-task'));
});

test('router managed: 許可タスク種別に書込み・本番系が含まれない', () => {
  assert.ok(MANAGED_TASK_TYPES.includes('review') && MANAGED_TASK_TYPES.includes('docs') && MANAGED_TASK_TYPES.includes('qa-analysis'));
  assert.ok(!MANAGED_TASK_TYPES.includes('deploy') && !MANAGED_TASK_TYPES.includes('migration') && !MANAGED_TASK_TYPES.includes('feature'));
  assert.strictEqual(typeof managedEligibility, 'function');
});
