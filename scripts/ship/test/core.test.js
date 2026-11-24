'use strict';
// store / state-machine / risk / quality-gate のユニットテスト
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { tmpHome, testPolicy, fakePr, H1, H2, B1 } = require('./helpers');

tmpHome();
const store = require('../lib/store');
const sm = require('../lib/state-machine');
const risk = require('../lib/risk');
const gate = require('../lib/quality-gate');

// ---------------- store ----------------
test('store: repo / sha / pr / id の検証はパストラバーサルを拒否する', () => {
  assert.throws(() => store.slug('../etc'), /INVALID_REPO/);
  assert.throws(() => store.slug('o/r/../../x'), /INVALID_REPO/);
  assert.throws(() => store.paths.gate('o/r', 1, 'abc'), /INVALID_HEAD/);
  assert.throws(() => store.paths.gate('o/r', -1, H1), /INVALID_PR/);
  assert.throws(() => store.paths.run('../../x'), /INVALID_ID/);
  assert.equal(store.slug('Kensan196948G/Claude-StartUpTools-New-Linux'), 'Kensan196948G__Claude-StartUpTools-New-Linux');
});

test('store: canonical はキー順に依存しない', () => {
  assert.equal(store.canonical({ b: 1, a: [2, { d: 1, c: 2 }] }), store.canonical({ a: [2, { c: 2, d: 1 }], b: 1 }));
});

test('store: writeRecord は秘密情報を除去して保存する', () => {
  const f = path.join(store.shipHome(), 'x.json');
  store.writeRecord(f, { note: 'token ghp_' + 'A'.repeat(36) + ' and postgres://u:p@h/db', token: 'abc', nested: { password: 'p' } });
  const txt = fs.readFileSync(f, 'utf8');
  assert.doesNotMatch(txt, /ghp_A{20}/);
  assert.doesNotMatch(txt, /u:p@/);
  assert.match(txt, /"token": "\[REDACTED\]"/);
  assert.match(txt, /"password": "\[REDACTED\]"/);
  assert.equal(fs.statSync(f).mode & 0o777, 0o600);
});

test('store: exclusive 書き込みは上書きしない', () => {
  const f = path.join(store.shipHome(), 'ex.json');
  store.writeRecord(f, { a: 1 }, { exclusive: true });
  assert.throws(() => store.writeRecord(f, { a: 2 }, { exclusive: true }), /EEXIST/);
});

test('store: 監査ログは連鎖し、改ざんを検出する', () => {
  store.appendAudit('e1', { x: 1 });
  store.appendAudit('e2', { x: 2 });
  store.appendAudit('e3', { x: 3 });
  assert.equal(store.verifyAuditChain().ok, true);
  const f = store.paths.audit();
  const lines = fs.readFileSync(f, 'utf8').trim().split('\n');
  const e = JSON.parse(lines[1]); e.x = 999; lines[1] = JSON.stringify(e);
  fs.writeFileSync(f, lines.join('\n') + '\n');
  const v = store.verifyAuditChain();
  assert.equal(v.ok, false);
  assert.equal(v.error, 'HASH_MISMATCH');
  fs.rmSync(f);
  store.appendAudit('a'); store.appendAudit('b');
  const l2 = fs.readFileSync(f, 'utf8').trim().split('\n');
  fs.writeFileSync(f, l2[1] + '\n'); // 先頭を削除
  assert.equal(store.verifyAuditChain().error, 'CHAIN_BROKEN');
  fs.rmSync(f);
});

test('store: withLock は同一キーの同時実行を拒否し、死んだ所有者のロックは回収する', () => {
  const inner = store.withLock('k1', () => store.withLock('k1', () => 1));
  assert.equal(inner.locked, true);
  assert.equal(inner.value.locked, false);
  fs.mkdirSync(store.paths.locks(), { recursive: true });
  fs.writeFileSync(path.join(store.paths.locks(), 'k2.lock'), '999999999');
  assert.equal(store.withLock('k2', () => 'ok').value, 'ok');
});

// ---------------- state machine ----------------
function run(state) { return { run_id: 'run_test1', state, head_sha: H1, history: [] }; }

test('state: 正規の経路を順に進める', () => {
  const r = run('IDLE');
  for (const s of ['DISCOVERY', 'PLANNING', 'IMPLEMENTING', 'LOCAL_TESTING', 'PR_CREATING', 'SHIP_STARTING', 'SHIP_REVIEWING', 'SHIP_REVALIDATING', 'QUALITY_EVALUATING']) sm.transition(r, s);
  sm.transition(r, 'HUMAN_APPROVAL_REQUIRED', { gate_verdict: 'PASS' });
  sm.transition(r, 'HUMAN_APPROVED', { approval_verified: true, approval_id: 'ha_x' });
  sm.transition(r, 'MERGE_QUEUED', { approval_verified: true });
  sm.transition(r, 'MERGED', { merge_confirmed: true, merge_commit_sha: H2 });
  sm.transition(r, 'COMPLETED');
  assert.equal(r.state, 'COMPLETED');
  assert.equal(r.history.length, 14); // 9 + 承認要求/承認/キュー/MERGED/COMPLETED の 5
  assert.deepEqual(r.history.map((h) => h.to).slice(-2), ['MERGED', 'COMPLETED']);
});

test('state: 有効な人間承認なしに HUMAN_APPROVED / MERGING へ進めない', () => {
  assert.equal(sm.canTransition('HUMAN_APPROVAL_REQUIRED', 'HUMAN_APPROVED', {}).reason, 'HUMAN_APPROVAL_NOT_VERIFIED');
  assert.equal(sm.canTransition('HUMAN_APPROVAL_REQUIRED', 'HUMAN_APPROVED', { approval_id: 'x' }).ok, false);
  assert.equal(sm.canTransition('HUMAN_APPROVAL_REQUIRED', 'MERGING', { approval_verified: true }).ok, false);
  assert.equal(sm.canTransition('QUALITY_EVALUATING', 'MERGE_QUEUED', { approval_verified: true }).ok, false);
  assert.equal(sm.canTransition('HUMAN_APPROVED', 'MERGE_QUEUED', {}).reason, 'HUMAN_APPROVAL_NOT_VERIFIED');
});

test('state: gate PASS 以外で HUMAN_APPROVAL_REQUIRED へ進めない', () => {
  for (const v of ['CONDITIONAL', 'FAIL', 'UNKNOWN', 'BLOCKED', undefined]) {
    assert.equal(sm.canTransition('QUALITY_EVALUATING', 'HUMAN_APPROVAL_REQUIRED', { gate_verdict: v }).ok, false, String(v));
  }
});

test('state: GitHub の確認なしに MERGED にしない', () => {
  assert.equal(sm.canTransition('MERGE_QUEUED', 'MERGED', { merge_confirmed: true }).reason, 'MERGE_NOT_CONFIRMED');
  assert.equal(sm.canTransition('MERGE_QUEUED', 'MERGED', { merge_commit_sha: H1 }).reason, 'MERGE_NOT_CONFIRMED');
});

test('state: 終端からは遷移しない / 不正遷移は例外', () => {
  for (const t of ['COMPLETED', 'FAILED', 'STOPPED']) assert.equal(sm.canTransition(t, 'DISCOVERY').reason, 'TERMINAL_STATE');
  assert.throws(() => sm.transition(run('IDLE'), 'MERGED', { merge_confirmed: true, merge_commit_sha: H1 }), /ILLEGAL_TRANSITION/);
  assert.equal(sm.canTransition('IMPLEMENTING', 'BLOCKED').ok, true);
  assert.equal(sm.canTransition('BLOCKED', 'HUMAN_APPROVED', { approval_verified: true, approval_id: 'x' }).ok, false);
});

test('state: 承認後に head が変わると SHIP_REVALIDATING へ戻る (承認失効)', () => {
  const r = run('HUMAN_APPROVED');
  const c = sm.onHeadChanged(r, H2);
  assert.equal(c.changed, true);
  assert.equal(r.state, 'SHIP_REVALIDATING');
  assert.equal(r.head_sha, H2);
  const r2 = run('IMPLEMENTING');
  sm.onHeadChanged(r2, H2);
  assert.equal(r2.state, 'IMPLEMENTING');
});

test('state: 全状態が遷移表に定義され、遷移先は既知の状態だけ', () => {
  for (const s of sm.STATES) {
    assert.ok(Array.isArray(sm.TRANSITIONS[s]), s);
    for (const t of sm.TRANSITIONS[s]) assert.ok(sm.STATES.includes(t), `${s}->${t}`);
  }
  assert.equal(sm.STATES.length, 22);
});

// ---------------- risk ----------------
const pol = testPolicy();
test('risk: パスからレベルを判定し最大を採る', () => {
  assert.equal(risk.classify(['docs/a.md'], pol.risk).level, 'R0');
  assert.equal(risk.classify(['tests/bats/unit/x.bats'], pol.risk).level, 'R1');
  assert.equal(risk.classify(['lib/supervisor.sh'], pol.risk).level, 'R2');
  assert.equal(risk.classify(['docs/a.md', 'db/control/migrations/0006.sql'], pol.risk).level, 'R3');
  assert.equal(risk.classify(['README.md', 'config/ship-policy.json'], pol.risk).level, 'R4');
  assert.equal(risk.classify(['.github/workflows/ci.yml'], pol.risk).level, 'R4');
  assert.equal(risk.classify(['Claude/templates/claude/claudeos/scripts/hooks/x.js'], pol.risk).level, 'R4');
});
test('risk: エージェントの指示書は Markdown でも R0 にしない (R2)', () => {
  // プロンプト注入の経路になり得るため、**/*.md (R0) より先に R2 として評価する
  for (const f of ['CLAUDE.md', 'AGENTS.md', '.claude/CLAUDE.md', '.claude/rules/hooks.md', '.claude/commands/x.md',
    'Claude/templates/claude/CLAUDE.md', '.claude/skills/verify-startuptools/SKILL.md', 'Codex/templates/x/AGENTS.md',
    '.agents/skills/a/SKILL.md', 'sub/dir/CLAUDE.md']) {
    assert.equal(risk.classifyFile(f, pol.risk).level, 'R2', f);
  }
  // 通常の文書は R0 のまま
  for (const f of ['README.md', 'CHANGELOG.md', 'docs/architecture/X.md', 'reports/ship-native/COMPLETION_REPORT.md']) {
    assert.equal(risk.classifyFile(f, pol.risk).level, 'R0', f);
  }
  // 指示書を 1 つでも含む PR は R2 以上 (最大値)
  assert.equal(risk.classify(['docs/a.md', 'CLAUDE.md'], pol.risk).level, 'R2');
  // 既存の上位規則は優先されたまま
  assert.equal(risk.classifyFile('.claude/settings.json', pol.risk).level, 'R4');
  assert.equal(risk.classifyFile('Claude/templates/claude/claudeos/scripts/hooks/x.js', pol.risk).level, 'R4');
});
test('risk: 変更ファイルが取れない場合は安全側 R4', () => {
  assert.equal(risk.classify([], pol.risk).level, 'R4');
  assert.equal(risk.classify(null, pol.risk).level, 'R4');
});
test('risk: R3 以上は影響分析とロールバック手順を要求する', () => {
  const r = risk.classify(['db/x.sql'], pol.risk);
  assert.equal(r.requirements.impactAnalysis, true);
  assert.equal(r.requirements.rollbackPlan, true);
});
test('risk: glob の ** と * の区別', () => {
  assert.ok(risk.globToRegExp('docs/**').test('docs/a/b/c.md'));
  assert.ok(!risk.globToRegExp('bin/*.sh').test('bin/a/b.sh'));
  assert.ok(risk.globToRegExp('**/hooks/**').test('hooks/x.js'));
});

// ---------------- quality gate ----------------
function goodInputs(over = {}) {
  return {
    pr: fakePr(), headSha: H1, baseSha: B1,
    quality: { evidence: { eval_id: 'qe_1', head_sha: H1, base_sha: B1, verdict: 'PASS', checks: [{ id: 's', category: 'secrets', status: 'PASS' }] }, rejected: [] },
    ship: { reviewed: true, importantFindingsOpen: 0, source: 'human-signed-attestation:sa_1' },
    risk: risk.classify(['lib/x.sh'], pol.risk), riskDocs: { rollbackPlan: true }, requirements: { status: 'met' }, residual: [],
    ...over,
  };
}
test('gate: 全条件を満たせば PASS', () => {
  const r = gate.evaluate(goodInputs(), pol);
  assert.equal(r.verdict, 'PASS', r.reasons.join('\n'));
});
test('gate: 古い SHA の証跡は流用できない', () => {
  const i = goodInputs(); i.quality.evidence.head_sha = H2;
  assert.equal(gate.evaluate(i, pol).verdict, 'FAIL');
  assert.equal(gate.evaluate(goodInputs({ headSha: H2 }), pol).verdict, 'FAIL'); // PR head と不一致
});
test('gate: 証跡なし / ローカル FAIL / シークレット検出', () => {
  assert.equal(gate.evaluate(goodInputs({ quality: { evidence: null, rejected: [{}] } }), pol).verdict, 'UNKNOWN');
  const f = goodInputs(); f.quality.evidence.verdict = 'FAIL';
  assert.equal(gate.evaluate(f, pol).verdict, 'FAIL');
  const s = goodInputs(); s.quality.evidence.checks[0].status = 'FAIL';
  assert.equal(gate.evaluate(s, pol).verdict, 'FAIL');
  const n = goodInputs(); n.quality.evidence.checks = [];
  assert.equal(gate.evaluate(n, pol).verdict, 'UNKNOWN');
});
test('gate: Ship 必須リスクで Ship 証跡がなければ UNKNOWN、重大所見が残れば FAIL', () => {
  assert.equal(gate.evaluate(goodInputs({ ship: null }), pol).verdict, 'UNKNOWN');
  assert.equal(gate.evaluate(goodInputs({ ship: { reviewed: true, importantFindingsOpen: 2 } }), pol).verdict, 'FAIL');
  assert.equal(gate.evaluate(goodInputs({ ship: { reviewed: true, importantFindingsOpen: null } }), pol).verdict, 'UNKNOWN');
  // R0 では Ship は必須ではないが、未実施は人の判断 (CONDITIONAL)
  assert.equal(gate.evaluate(goodInputs({ ship: null, risk: risk.classify(['docs/a.md'], pol.risk) }), pol).verdict, 'CONDITIONAL');
});
test('gate: PR 状態 (draft / closed / conflict / 未解決スレッド / 失敗チェック / 不許可 base)', () => {
  assert.equal(gate.evaluate(goodInputs({ pr: fakePr({ isDraft: true }) }), pol).verdict, 'FAIL');
  assert.equal(gate.evaluate(goodInputs({ pr: fakePr({ state: 'CLOSED' }) }), pol).verdict, 'FAIL');
  assert.equal(gate.evaluate(goodInputs({ pr: fakePr({ mergeable: 'CONFLICTING' }) }), pol).verdict, 'FAIL');
  assert.equal(gate.evaluate(goodInputs({ pr: fakePr({ reviewThreadsUnresolved: 1 }) }), pol).verdict, 'FAIL');
  assert.equal(gate.evaluate(goodInputs({ pr: fakePr({ reviewThreadsUnresolved: null }) }), pol).verdict, 'UNKNOWN');
  assert.equal(gate.evaluate(goodInputs({ pr: fakePr({ statusChecks: [{ name: 'linux-validate', conclusion: 'FAILURE' }] }) }), pol).verdict, 'FAIL');
  assert.equal(gate.evaluate(goodInputs({ pr: fakePr({ baseRefName: 'release' }) }), pol).verdict, 'FAIL');
  assert.equal(gate.evaluate(goodInputs({ pr: null }), pol).verdict, 'BLOCKED');
});
test('gate: 自分自身の context (品質・承認) の pending は判定を循環させない', () => {
  const r = gate.evaluate(goodInputs({ pr: fakePr({ statusChecks: [{ name: 'claudeos/human-approval', status: 'PENDING' }] }) }), pol);
  assert.equal(r.verdict, 'PASS', r.reasons.join('\n'));
});
test('gate: R3 で影響分析が無ければ CONDITIONAL (自動マージ不可)', () => {
  const r = gate.evaluate(goodInputs({ risk: risk.classify(['db/x.sql'], pol.risk), riskDocs: { rollbackPlan: true } }), pol);
  assert.equal(r.verdict, 'CONDITIONAL');
});
test('gate: 証跡の base が古ければ再検証待ち (UNKNOWN)', () => {
  const i = goodInputs(); i.quality.evidence.base_sha = 'e'.repeat(40);
  assert.equal(gate.evaluate(i, pol).verdict, 'UNKNOWN');
});
