// state-schema.test.js — state.schema.json と Goal Router 状態の互換性テスト (指示書 §25)
//   - state.json.example / scripts/setup/state-template.json が schema に適合
//   - 旧 state (goal_router なし、goal_type のみ) が引き続き適合 (後方互換)
//   - 新 state (goal_router あり) が適合し、enum 違反は検出される
//   - goal_type enum は Primary 5 + Specialized 6 を含む
const test = require('node:test');
const assert = require('node:assert');
const path = require('path');
const fs = require('fs');
const { validateState, validateFile, loadSchema } = require('./validate-state-example.js');

const root = path.resolve(__dirname, '..');
const schema = loadSchema();
const PRIMARY = ['development', 'mvp-release', 'assessment', 'deep-debug', 'product-assurance'];
const SPECIALIZED = ['production-release', 'hotfix', 'security-emergency', 'refactoring', 'safe-auto-merge', 'pr-babysit'];

const baseState = () => JSON.parse(fs.readFileSync(path.join(root, 'state.json.example'), 'utf8'));

test('state.json.example は schema に適合する', () => {
  assert.deepStrictEqual(validateFile(path.join(root, 'state.json.example'), schema), []);
});

test('scripts/setup/state-template.json (seed) は required 以外の型・enum に適合する', () => {
  assert.deepStrictEqual(validateFile(path.join(root, 'scripts/setup/state-template.json'), schema, { partial: true }), []);
});

test('goal_type enum は Primary 5 分類 + 既存 Specialized 6 種を含む', () => {
  const en = schema.properties.goal_type.enum;
  for (const g of [...PRIMARY, ...SPECIALIZED]) assert.ok(en.includes(g), `${g} missing from goal_type enum`);
});

test('旧 state (goal_router なし / goal_type=mvp-release) は後方互換で適合する', () => {
  const st = baseState();
  delete st.goal_router;
  st.goal_type = 'mvp-release';
  assert.deepStrictEqual(validateState(st, schema), []);
});

test('旧 state (goal_type も無し) も適合する (Router は fallback で動く)', () => {
  const st = baseState();
  delete st.goal_router; delete st.goal_type;
  assert.deepStrictEqual(validateState(st, schema), []);
});

test('新 state (goal_router あり) は適合し specialized_goal は null 許容', () => {
  const st = baseState();
  st.goal_router = {
    mode: 'auto', primary_goal: 'deep-debug', specialized_goal: 'hotfix', effective_goal_type: 'hotfix',
    confidence: 0.85, reason: 'ci-failure', evidence: ['ci:failure', 'phase_mode:maintenance'],
    locked_by_user: false, session_locked: true, route_version: 1, last_routed_at: '2026-09-07T00:00:00Z',
    last_transition_reason: 'reroute:cron',
    evidence_snapshot: { deploy_ready: '', phase_mode: 'maintenance', security_critical: '0', ci: 'failure' },
    history: [{ at: '2026-09-07T00:00:00Z', from: 'development', to: 'deep-debug/hotfix', reason: 'ci-failure', trigger: 'cron' }],
  };
  assert.deepStrictEqual(validateState(st, schema), []);
  st.goal_router.specialized_goal = null;
  assert.deepStrictEqual(validateState(st, schema), []);
});

test('enum 違反 (未知の primary_goal / mode) は検出される', () => {
  const st = baseState();
  st.goal_router = { ...st.goal_router, primary_goal: 'bogus', mode: 'sometimes' };
  const errors = validateState(st, schema);
  assert.ok(errors.some(e => e.includes('goal_router.primary_goal')));
  assert.ok(errors.some(e => e.includes('goal_router.mode')));
});

test('confidence の範囲外 (1.5) は検出される', () => {
  const st = baseState();
  st.goal_router = { ...st.goal_router, confidence: 1.5 };
  assert.ok(validateState(st, schema).some(e => e.includes('goal_router.confidence')));
});

test('goals/*.md は Primary 5 + Specialized 6 の全ファイルが存在し /goal ブロックが 4000 字以内', () => {
  const dir = path.join(root, 'Claude/templates/claudeos/goals');
  for (const g of [...PRIMARY, ...SPECIALIZED]) {
    const f = path.join(dir, `${g}.md`);
    assert.ok(fs.existsSync(f), `${g}.md missing`);
    const raw = fs.readFileSync(f, 'utf8');
    const m = raw.match(/^\/goal "([\s\S]*?)\n"[ \t]*$/m);
    assert.ok(m, `${g}.md: no /goal block`);
    const n = [...m[1]].length + 2;
    assert.ok(n <= 4000, `${g}.md: /goal ${n} chars > 4000`);
    for (const sec of ['■ Goal', '■ Use When', '■ Success Criteria', '■ Stop Conditions']) {
      assert.ok(m[1].includes(sec), `${g}.md: missing section ${sec}`);
    }
  }
});
