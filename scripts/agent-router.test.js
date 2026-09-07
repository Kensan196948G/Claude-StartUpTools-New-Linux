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

test('router CLI: --json prints a decision and --record appends to state.json routing_log (max 20)', () => {
  const tmp = fs.mkdtempSync(path.join(require('os').tmpdir(), 'router-'));
  const state = path.join(tmp, 'state.json');
  fs.writeFileSync(state, JSON.stringify({ goal: {}, execution: { routing_log: Array.from({ length: 20 }, (_, i) => ({ at: `t${i}` })) } }));
  const out = execFileSync(process.execPath, [path.join(__dirname, 'tools', 'agent-router.js'), '--json', JSON.stringify({ task_type: 'docs', complexity: 'low' }), '--record'], { cwd: tmp, encoding: 'utf8' });
  const d = JSON.parse(out);
  assert.strictEqual(d.execution, 'Main');
  assert.strictEqual(d.recorded, true);
  const s = JSON.parse(fs.readFileSync(state, 'utf8'));
  assert.strictEqual(s.execution.routing_log.length, 20);
  assert.strictEqual(s.execution.routing_log[19].execution, 'Main');
});
