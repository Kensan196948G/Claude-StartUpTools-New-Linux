'use strict';
// 結合テスト: 実リポジトリ (一時) + 偽 gh で、品質 → 判定 → 承認 → マージ → 監視 の全工程を CLI 経由で通す
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const ROOT = path.resolve(__dirname, '..', '..', '..');
const T = fs.mkdtempSync(path.join(os.tmpdir(), 'ship-life-'));
const SHIP_HOME = path.join(T, 'ship');
const FAKE = path.join(T, 'fakegh.json'); // 偽 gh の状態
const REPO = 'acme/widget';

// ---- 一時プロジェクト ----
const PROJ = path.join(T, 'proj');
fs.mkdirSync(PROJ);
const g = (...a) => spawnSync('git', a, { cwd: PROJ, encoding: 'utf8' });
g('init', '-q', '-b', 'main'); g('config', 'user.email', 't@t'); g('config', 'user.name', 't');
fs.writeFileSync(path.join(PROJ, 'test.sh'), 'echo "ok 1 - works"\n');
fs.writeFileSync(path.join(PROJ, 'README.md'), 'hello\n');
g('add', '.'); g('commit', '-qm', 'base');
const BASE = g('rev-parse', 'HEAD').stdout.trim();
g('switch', '-q', '-c', 'feat/x');
fs.mkdirSync(path.join(PROJ, 'lib')); fs.writeFileSync(path.join(PROJ, 'lib', 'a.sh'), 'echo a\n');
g('add', '.'); g('commit', '-qm', 'feat');
const HEAD = g('rev-parse', 'HEAD').stdout.trim();

// ---- 偽 gh (node スクリプト)。状態は FAKE の JSON。呼び出しは calls に記録 ----
const ghScript = path.join(T, 'gh');
fs.writeFileSync(ghScript, `#!/usr/bin/env node
const fs=require('fs');const f=${JSON.stringify(FAKE)};const s=JSON.parse(fs.readFileSync(f,'utf8'));
const a=process.argv.slice(2);s.calls.push(a.join(' '));
const save=()=>fs.writeFileSync(f,JSON.stringify(s));
const pr=s.pr;
if(a[0]==='pr'&&a[1]==='view'&&a.includes('files')){save();console.log(JSON.stringify({files:s.files.map(p=>({path:p}))}));process.exit(0);}
if(a[0]==='pr'&&a[1]==='view'){const want=a[a.indexOf('--json')+1].split(',');const known=['number','state','isDraft','mergeable','mergeStateStatus','headRefOid','headRefName','baseRefName','url','title','author','statusCheckRollup','mergeCommit','autoMergeRequest','files'];const bad=want.filter(f=>!known.includes(f));if(bad.length){save();console.error('Unknown JSON field: "'+bad[0]+'"');process.exit(1);}save();console.log(JSON.stringify({number:7,state:pr.state,isDraft:false,mergeable:'MERGEABLE',mergeStateStatus:'CLEAN',headRefOid:pr.head,headRefName:'feat/x',baseRefName:'main',url:'u',title:'t',author:{login:'k'},statusCheckRollup:pr.checks,mergeCommit:pr.mergeCommit?{oid:pr.mergeCommit}:null,autoMergeRequest:pr.auto?{}:null}));process.exit(0);}
if(a[0]==='api'&&a[1]==='graphql'){save();console.log(JSON.stringify({data:{repository:{pullRequest:{baseRefOid:pr.base,headRefOid:pr.head,reviewThreads:{totalCount:0,nodes:[]}}}}}));process.exit(0);}
if(a[0]==='api'&&String(a[1]).includes('/rules/branches/')){save();console.log(JSON.stringify(s.rules));process.exit(0);}
if(a[0]==='api'&&a.includes('-X')&&String(a[3]).includes('/statuses/')){const sha=a[3].split('/').pop();const ctx=a[a.indexOf('-f',a.indexOf('state=')-2)];s.statuses.push({sha,args:a.slice(4).join(' ')});save();console.log('{}');process.exit(0);}
if(a[0]==='pr'&&a[1]==='merge'&&a.includes('--auto')){const i=a.indexOf('--match-head-commit');if(a[i+1]!==pr.head){save();console.error('head mismatch');process.exit(1);}
  pr.auto=true; if(s.mergeImmediately){pr.state='MERGED';pr.mergeCommit='e'.repeat(40);} save();process.exit(0);}
if(a[0]==='pr'&&a[1]==='merge'&&a.includes('--disable-auto')){pr.auto=false;save();process.exit(0);}
save();console.error('unhandled '+a.join(' '));process.exit(1);
`, { mode: 0o755 });
function setFake(over = {}) {
  const base = { calls: [], statuses: [], files: ['lib/a.sh'], mergeImmediately: true,
    rules: [{ type: 'required_status_checks', parameters: { required_status_checks: [{ context: 'linux-validate' }, { context: 'claudeos/local-quality' }, { context: 'claudeos/human-approval' }] } }],
    pr: { state: 'OPEN', head: HEAD, base: BASE, checks: [{ name: 'linux-validate', status: 'COMPLETED', conclusion: 'SUCCESS' }], auto: false, mergeCommit: null } };
  const s = { ...base, ...over, pr: { ...base.pr, ...(over.pr || {}) } };
  fs.writeFileSync(FAKE, JSON.stringify(s));
}
const fake = () => JSON.parse(fs.readFileSync(FAKE, 'utf8'));

// ---- テスト用ポリシーと承認鍵 ----
process.env.CLAUDEOS_SHIP_HOME = SHIP_HOME;
const hg = require('../lib/human-gate');
const PASS = 'lifecycle test passphrase';
const bundle = hg.generateKey('Tester', PASS, { kdf: { N: 1 << 10, r: 8, p: 1, maxmem: 64 << 20 }, test: true });
const KEYFILE = path.join(T, 'key.json');
fs.writeFileSync(KEYFILE, JSON.stringify(bundle), { mode: 0o600 });
const pol = JSON.parse(fs.readFileSync(path.join(ROOT, 'config', 'ship-policy.json'), 'utf8'));
pol.humanGate.approverKeys = [{ name: 'Tester', key_id: bundle.key_id, public_key: bundle.public_key }];
pol.merge.centralProfileEnforced = true;
pol.quality.profiles = { t: { checks: [{ id: 'unit', category: 'unit', cmd: ['bash', 'test.sh'], parser: 'tap' }, { id: 'noop-secrets', category: 'secrets', cmd: ['true'] }] } };
const POL = path.join(T, 'policy.json');
fs.writeFileSync(POL, JSON.stringify(pol));

const ENV = { ...process.env, CLAUDEOS_SHIP_HOME: SHIP_HOME, CLAUDEOS_SHIP_GH_BIN: ghScript, CLAUDEOS_SHIP_POLICY: POL,
  CLAUDEOS_SHIP_TRUSTED_POLICY: POL, CLAUDEOS_APPROVER_KEY: KEYFILE };
function ship(args, env = {}) {
  const r = spawnSync('node', [path.join(ROOT, 'scripts/ship/ship.js'), ...args, '--json'], { env: { ...ENV, ...env }, encoding: 'utf8', timeout: 300000 });
  let json = null; try { json = JSON.parse(r.stdout.trim().split('\n').pop()); } catch { /* */ }
  return { ...r, json };
}
function approveCli(args, env = {}) {
  return spawnSync('node', [path.join(ROOT, 'scripts/ship/approve.js'), ...args], { env: { ...ENV, ...env }, encoding: 'utf8', timeout: 120000 });
}
const TESTAUTH = { CLAUDEOS_SHIP_TEST_PASSPHRASE: PASS, CLAUDEOS_SHIP_TEST_CONFIRM: 'yes' };
const ISO = require('../lib/quality').isolationAvailable();

test('ライフサイクル: run → 品質 → (Ship 署名) → 判定 PASS → 承認 → マージ → 完了', { skip: !ISO && 'bwrap 不可' }, () => {
  setFake();
  const run = ship(['run-start', '--project', PROJ, '--repo', REPO, '--mode', 'SH2', '--intent', 'feature', '--pr', '7']);
  assert.equal(run.status, 0, run.stderr);
  const id = run.json.run_id;
  for (const s of ['PLANNING', 'IMPLEMENTING', 'LOCAL_TESTING', 'PR_CREATING', 'SHIP_STARTING', 'SHIP_REVIEWING', 'SHIP_REVALIDATING', 'QUALITY_EVALUATING']) {
    assert.equal(ship(['run-transition', '--id', id, '--to', s]).status, 0, s);
  }
  // ローカル品質 + Commit Status 登録
  const q = ship(['quality', '--repo', REPO, '--project', PROJ, '--head', HEAD, '--base', BASE, '--pr', '7', '--profile', 't', '--publish']);
  assert.equal(q.status, 0, q.stdout + q.stderr);
  assert.equal(q.json.verdict, 'PASS');
  assert.ok(fake().statuses.some((s) => s.sha === HEAD && /context=claudeos\/local-quality/.test(s.args) && /state=success/.test(s.args)));
  // Ship 証跡が無い間は gate UNKNOWN (R2 は Ship 必須) → 承認できない
  let gate = ship(['gate', '--repo', REPO, '--pr', '7', '--requirements', 'met']);
  assert.equal(gate.json.verdict, 'UNKNOWN', gate.json.reasons.join('\n'));
  let ap = approveCli(['approve', '--repo', REPO, '--pr', '7', '--head', HEAD], TESTAUTH);
  assert.notEqual(ap.status, 0);
  assert.match(ap.stderr, /GATE_NOT_PASS/);
  // 人が /ship の結果を署名
  const at = approveCli(['ship-attest', '--repo', REPO, '--pr', '7', '--head', HEAD, '--reviewed', 'yes', '--important-open', '0', '--watch', 'checks-pass-comments-answered'], TESTAUTH);
  assert.equal(at.status, 0, at.stderr);
  const rollback = path.join(T, 'rollback.md'); fs.writeFileSync(rollback, 'git revert <merge-commit> で戻す。'.repeat(20));
  gate = ship(['gate', '--repo', REPO, '--pr', '7', '--requirements', 'met', '--rollback-doc', rollback]);
  assert.equal(gate.json.verdict, 'PASS', gate.json.reasons.join('\n'));
  assert.equal(gate.json.risk, 'R2');
  assert.equal(ship(['run-transition', '--id', id, '--to', 'HUMAN_APPROVAL_REQUIRED']).status, 0);
  // 間違った head を指定した承認は拒否
  ap = approveCli(['approve', '--repo', REPO, '--pr', '7', '--head', BASE], TESTAUTH);
  assert.match(ap.stderr, /HEAD_MISMATCH/);
  // 正しい承認
  ap = approveCli(['approve', '--repo', REPO, '--pr', '7', '--head', HEAD], TESTAUTH);
  assert.equal(ap.status, 0, ap.stderr);
  assert.ok(fake().statuses.some((s) => s.sha === HEAD && /context=claudeos\/human-approval/.test(s.args)));
  // 承認一覧
  const list = ship(['approvals', '--repo', REPO, '--pr', '7']);
  assert.equal(list.json.approvals.filter((a) => a.valid).length, 1);
  // マージ (dry-run → 本番)
  assert.equal(ship(['merge', '--repo', REPO, '--pr', '7', '--dry-run']).json.state, 'DRY_RUN_OK');
  const m = ship(['merge', '--repo', REPO, '--pr', '7']);
  assert.equal(m.json.state, 'MERGED', JSON.stringify(m.json));
  assert.ok(fake().calls.some((c) => c === `pr merge 7 --repo ${REPO} --auto --squash --match-head-commit ${HEAD}`));
  // run を承認経路で進める: monitor が GitHub の MERGED を確認して完了させるには MERGE_QUEUED 状態が必要
  const runFile = path.join(SHIP_HOME, 'runs', id + '.json');
  const r = JSON.parse(fs.readFileSync(runFile, 'utf8'));
  const sm = require('../lib/state-machine');
  sm.transition(r, 'HUMAN_APPROVED', { approval_verified: true, approval_id: 'ha_from_test' });
  sm.transition(r, 'MERGE_QUEUED', { approval_verified: true });
  fs.writeFileSync(runFile, JSON.stringify(r));
  const mon = ship(['monitor', '--once']);
  assert.equal(mon.status, 0, mon.stderr);
  assert.equal(JSON.parse(fs.readFileSync(runFile, 'utf8')).state, 'COMPLETED');
  assert.equal(ship(['audit-verify']).json.ok, true);
});

test('監視: 承認後に head が変わると run は SHIP_REVALIDATING へ戻り、auto-merge は解除される', { skip: !ISO && 'bwrap 不可' }, () => {
  setFake({ mergeImmediately: false });
  g('switch', '-q', '-c', 'feat/y');
  const run = ship(['run-start', '--project', PROJ, '--repo', REPO, '--mode', 'SH4', '--pr', '8']);
  const id = run.json.run_id;
  const runFile = path.join(SHIP_HOME, 'runs', id + '.json');
  const r = JSON.parse(fs.readFileSync(runFile, 'utf8'));
  const sm = require('../lib/state-machine');
  for (const s of ['PLANNING', 'IMPLEMENTING', 'LOCAL_TESTING', 'QUALITY_EVALUATING']) sm.transition(r, s);
  sm.transition(r, 'HUMAN_APPROVAL_REQUIRED', { gate_verdict: 'PASS' });
  sm.transition(r, 'HUMAN_APPROVED', { approval_verified: true, approval_id: 'ha_x' });
  sm.transition(r, 'MERGE_QUEUED', { approval_verified: true });
  r.head_sha = HEAD; r.base_sha = BASE;
  fs.writeFileSync(runFile, JSON.stringify(r));
  setFake({ mergeImmediately: false, pr: { head: 'f'.repeat(40), auto: true } });
  ship(['monitor', '--once']);
  const after = JSON.parse(fs.readFileSync(runFile, 'utf8'));
  assert.equal(after.state, 'SHIP_REVALIDATING');
  assert.ok(fake().calls.some((c) => c.startsWith('pr merge 8') && c.includes('--disable-auto')));
});

test('監視: ClaudeOS の承認経路を通らずにマージされた run は成功扱いにせず STOPPED', { skip: !ISO && 'bwrap 不可' }, () => {
  g('switch', '-q', '-c', 'feat/z');
  setFake({ pr: { state: 'MERGED', mergeCommit: 'e'.repeat(40) } });
  const run = ship(['run-start', '--project', PROJ, '--repo', REPO, '--mode', 'SH2', '--pr', '9']);
  ship(['monitor', '--once']);
  const after = JSON.parse(fs.readFileSync(path.join(SHIP_HOME, 'runs', run.json.run_id + '.json'), 'utf8'));
  assert.equal(after.state, 'STOPPED');
  assert.ok(after.history.some((h) => h.evidence.reason === 'MERGED_OUTSIDE_HUMAN_GATE'));
});

test('監視: GitHub 障害が続くと指数バックオフし、閾値でサーキットを開いて BLOCKED', { skip: !ISO && 'bwrap 不可' }, () => {
  g('switch', '-q', '-c', 'feat/w');
  setFake();
  const run = ship(['run-start', '--project', PROJ, '--repo', REPO, '--mode', 'SH2', '--pr', '10']);
  const brokenGh = path.join(T, 'gh-broken'); fs.writeFileSync(brokenGh, '#!/bin/sh\necho "HTTP 503 Service Unavailable" >&2\nexit 1\n', { mode: 0o755 });
  for (let i = 0; i < 5; i++) ship(['monitor', '--once'], { CLAUDEOS_SHIP_GH_BIN: brokenGh });
  const after = JSON.parse(fs.readFileSync(path.join(SHIP_HOME, 'runs', run.json.run_id + '.json'), 'utf8'));
  assert.equal(after.state, 'BLOCKED');
  assert.ok(Date.parse(after.next_retry_at) > Date.now());
});

test('承認 CLI: 信頼鍵に登録されていない鍵では承認できない', { skip: !ISO && 'bwrap 不可' }, () => {
  setFake();
  const p2 = JSON.parse(fs.readFileSync(POL, 'utf8')); p2.humanGate.approverKeys = [];
  const P2 = path.join(T, 'p2.json'); fs.writeFileSync(P2, JSON.stringify(p2));
  const gateDir = path.join(SHIP_HOME, 'gates', 'acme__widget', 'pr-7');
  assert.ok(fs.existsSync(path.join(gateDir, HEAD + '.json')));
  const ap = approveCli(['approve', '--repo', REPO, '--pr', '7', '--head', HEAD], { ...TESTAUTH, CLAUDEOS_SHIP_TRUSTED_POLICY: P2 });
  assert.notEqual(ap.status, 0);
  assert.match(ap.stderr, /KEY_NOT_TRUSTED/);
});

test('human-diff CLI: R0 の PR は差分確認の署名で gate PASS、R2 では署名を拒否', { skip: !ISO && 'bwrap 不可' }, () => {
  // R0 (文書のみ)
  setFake({ files: ['docs/a.md', 'README.md'] });
  fs.rmSync(path.join(SHIP_HOME, 'ship-evidence'), { recursive: true, force: true });
  const q = ship(['quality', '--repo', REPO, '--project', PROJ, '--head', HEAD, '--base', BASE, '--pr', '7', '--profile', 't']);
  assert.equal(q.json.verdict, 'PASS', q.stdout + q.stderr);
  let gate = ship(['gate', '--repo', REPO, '--pr', '7', '--requirements', 'met']);
  assert.equal(gate.json.risk, 'R0');
  assert.equal(gate.json.verdict, 'CONDITIONAL', gate.json.reasons.join('\n'));
  const at = approveCli(['ship-attest', '--kind', 'human-diff', '--repo', REPO, '--pr', '7', '--head', HEAD, '--important-open', '0'], TESTAUTH);
  assert.equal(at.status, 0, at.stdout + at.stderr);
  assert.match(at.stdout, /変更ファイル \(2\)/);
  assert.match(at.stdout, /"review_kind":"human-diff","files_reviewed":2/);
  gate = ship(['gate', '--repo', REPO, '--pr', '7', '--requirements', 'met']);
  assert.equal(gate.json.verdict, 'PASS', gate.json.reasons.join('\n'));
  assert.match(gate.json.ship_source, /^human-diff-attestation:sa_/);

  // 同じ署名が残っていても、PR が R2 の変更を含むようになれば gate は認めない
  setFake({ files: ['docs/a.md', 'CLAUDE.md'] });
  gate = ship(['gate', '--repo', REPO, '--pr', '7', '--requirements', 'met']);
  assert.equal(gate.json.risk, 'R2');
  assert.notEqual(gate.json.verdict, 'PASS');
  assert.equal(gate.json.ship_source, null);
  // R2 では署名そのものを拒否する
  const bad = approveCli(['ship-attest', '--kind', 'human-diff', '--repo', REPO, '--pr', '7', '--head', HEAD, '--important-open', '0'], TESTAUTH);
  assert.notEqual(bad.status, 0);
  assert.match(bad.stderr, /HUMAN_DIFF_NOT_ALLOWED_FOR_R2/);
  // 不明な種類は拒否
  const unk = approveCli(['ship-attest', '--kind', 'auto', '--repo', REPO, '--pr', '7', '--head', HEAD, '--important-open', '0'], TESTAUTH);
  assert.match(unk.stderr, /REVIEW_KIND_INVALID/);
});

test.after(() => fs.rmSync(T, { recursive: true, force: true }));
