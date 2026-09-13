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
