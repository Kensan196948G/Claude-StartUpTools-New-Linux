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
// 安全条件は明示的に false を渡す (省略・不明値は fail-closed で拒否される)
const managedOk = (over) => Object.assign({ available: true, budget_state: 'ok', data_sensitivity: 'internal', human_gate: false, requires_secrets: false, requires_external_network: false }, over);

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
  const run = (budget_state, task_type) => route(lowRisk({ task_type: task_type || 'review', managed: managedOk({ budget_state, requested: true }) }));
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
  const unavailable = route(lowRisk({ managed: managedOk({ available: false, requested: true }) }));
  assert.strictEqual(unavailable.execution, 'Subagent');
  assert.deepStrictEqual(unavailable.managed.denied, ['managed-unavailable']);
  const dup = route(lowRisk({ managed: managedOk({ requested: true, duplicate: true }) }));
  assert.strictEqual(dup.execution, 'Subagent');
  assert.ok(dup.managed.denied.includes('duplicate-task'));
});

test('router managed: 安全条件は fail-closed (省略・不明値・呼び出し側による緩和では選ばない)', () => {
  const pick = (input) => route(input);
  const denied = [
    lowRisk({ managed: { available: true, budget_state: 'ok', requested: true } }), // 確認項目の省略
    lowRisk({ managed: managedOk({ requested: true, human_gate: 'yes' }) }),
    lowRisk({ managed: managedOk({ requested: true, requires_secrets: 'TRUE' }) }),
    lowRisk({ managed: managedOk({ requested: true, requires_external_network: 'no' }) }),
    lowRisk({ security_impact: 'High ', managed: managedOk({ requested: true }) }),
    lowRisk({ deployment_impact: 'severe', managed: managedOk({ requested: true }) }),
    lowRisk({ database_impact: 'yes', managed: managedOk({ requested: true }) }),
    lowRisk({ risk: undefined, managed: managedOk({ requested: true }) }),
    lowRisk({ read_only: 'yes', managed: managedOk({ requested: true }) }),
    lowRisk({ task_type: 'deploy', managed: managedOk({ requested: true, allowed_task_types: ['deploy'] }) }),
    lowRisk({ expected_duration_min: 600, managed: managedOk({ requested: true, max_duration_min: 9999 }) }),
    lowRisk({ expected_duration_min: 'forever', managed: managedOk({ requested: true }) }),
  ];
  for (const input of denied) {
    const d = pick(input);
    assert.notStrictEqual(d.execution, 'ManagedAgent', JSON.stringify(input));
    assert.strictEqual(d.managed.policy_denied, true, JSON.stringify(input));
  }
  // local_available は明示的な false のときだけ「使えない」と扱う
  assert.strictEqual(pick(lowRisk({ managed: managedOk({ local_available: null }) })).execution, 'Subagent');
  assert.strictEqual(pick(lowRisk({ managed: managedOk({ local_available: false }) })).execution, 'ManagedAgent');
  // 許可リストは狭められるが広げられない
  assert.strictEqual(pick(lowRisk({ managed: managedOk({ requested: true, allowed_task_types: ['docs'] }) })).managed.policy_denied, true);
});

test('router managed: 継承プロパティ名のレベル・曖昧な所要時間・機密性の省略では選ばない', () => {
  const m = () => managedOk({ requested: true });
  const denied = [
    lowRisk({ risk: 'constructor', managed: m() }), lowRisk({ security_impact: '__proto__', managed: m() }),
    lowRisk({ database_impact: 'toString', managed: m() }), lowRisk({ deployment_impact: 'constructor', managed: m() }),
    lowRisk({ security_impact: 3, managed: m() }), lowRisk({ risk: ['low'], managed: m() }),
    lowRisk({ expected_duration_min: ' ', managed: m() }), lowRisk({ expected_duration_min: [], managed: m() }),
    lowRisk({ expected_duration_min: true, managed: m() }), lowRisk({ expected_duration_min: null, managed: m() }),
    lowRisk({ expected_duration_min: '0x10', managed: m() }),
    lowRisk({ managed: managedOk({ requested: true, data_sensitivity: undefined }) }),
    lowRisk({ managed: managedOk({ requested: true, data_sensitivity: ['internal'] }) }),
  ];
  for (const input of denied) {
    const d = route(input);
    assert.notStrictEqual(d.execution, 'ManagedAgent', JSON.stringify(input));
    assert.strictEqual(d.managed.policy_denied, true, JSON.stringify(input));
  }
  assert.strictEqual(route(lowRisk({ expected_duration_min: '25', managed: m() })).execution, 'ManagedAgent');
});

test('router: 継承プロパティ名を影響度に渡しても高影響ガードレールが消えない (Local 側)', () => {
  // "constructor" は LEVELS の自身のキーではないので既定値として扱う (関数が返って比較が NaN になる不具合の再発防止)
  const d = route({ task_type: 'feature', security_impact: 'constructor', database_impact: 'high', files_affected: 5 });
  assert.ok(d.guardrails.some((g) => g.includes('high-impact')));
  assert.strictEqual(d.inputs.security, 1);
});

test('router managed: managed が null / 配列 / 文字列 / 数値でも従来の出力と同じ (managed キーを付けない)', () => {
  for (const c of golden.cases) {
    const base = JSON.stringify(route(c.input));
    for (const junk of [null, [], 'yes', 1, true, undefined]) {
      assert.strictEqual(JSON.stringify(route(Object.assign({}, c.input, { managed: junk }))), base, c.name);
    }
  }
});

test('router managed: 許可タスク種別に書込み・本番系が含まれない', () => {
  assert.ok(MANAGED_TASK_TYPES.includes('review') && MANAGED_TASK_TYPES.includes('docs') && MANAGED_TASK_TYPES.includes('qa-analysis'));
  assert.ok(!MANAGED_TASK_TYPES.includes('deploy') && !MANAGED_TASK_TYPES.includes('migration') && !MANAGED_TASK_TYPES.includes('feature'));
  assert.strictEqual(typeof managedEligibility, 'function');
});
