#!/usr/bin/env node
'use strict';
/**
 * ship-api.test.js — Ship Native Control Center API の検証
 *
 *   1) overview の集計 (fixture のレコードから数える。デモデータを作らない)
 *   2) 承認の有効性ラベル (VALID / STALE_HEAD / EXPIRED / REVOKED)
 *   3) 不正な repo / pr は 400、パストラバーサルで ship home の外を読まない
 *   4) 取り消しは Access JWT (メール付き) 必須 (無し → 401 / 不正 → 403)。成功時は revocation + 監査
 *   5) 監査チェーンの整合性を返す (改ざんで ok:false)
 *   6) approve の経路は無い (404)
 */

const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const http = require('node:http');
const crypto = require('node:crypto');

const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'ship-api-test-'));
process.env.CLAUDEOS_HOME = path.join(TMP, 'claudeos');
process.env.CLAUDEOS_SHIP_HOME = path.join(TMP, 'shiphome');
fs.mkdirSync(path.join(process.env.CLAUDEOS_HOME, 'logs'), { recursive: true });

const store = require('../ship/lib/store.js');
const api = require('./ship-api.js');
const srv = require('./startup-server.js');

const REPO = 'acme/widget';
const H1 = 'a'.repeat(40);   // 古い head
const H2 = 'b'.repeat(40);   // 最新 head
const BASE = 'c'.repeat(40);
const HOUR = 3600 * 1000;
const iso = (ms) => new Date(ms).toISOString();
const NOW = Date.now();

function seed() {
  fs.rmSync(process.env.CLAUDEOS_SHIP_HOME, { recursive: true, force: true });
  // run: PR 7 は HUMAN_APPROVAL_REQUIRED (最新 head = H2)
  store.writeRecord(store.paths.run('run_alpha_001'), {
    schema: store.SCHEMA.run, run_id: 'run_alpha_001', repo: REPO, project_dir: '/home/someone/Projects/widget',
    mode: 'pr', state: 'HUMAN_APPROVAL_REQUIRED', pr: 7, head_sha: H2, base_sha: BASE, branch: 'feat/x',
    ship: { capability: 'available', status: 'done', notes: 'token ghp_' + 'Z'.repeat(30) }, history: [],
    created_at: iso(NOW - 5 * HOUR), updated_at: iso(NOW - HOUR),
  });
  // run: PR 8 は SHIP_REVIEWING (ship 実行中)
  store.writeRecord(store.paths.run('run_beta_0002'), {
    schema: store.SCHEMA.run, run_id: 'run_beta_0002', repo: REPO, mode: 'pr', state: 'SHIP_REVIEWING', pr: 8,
    head_sha: H1, base_sha: BASE, ship: { status: 'running' }, history: [], created_at: iso(NOW - 2 * HOUR), updated_at: iso(NOW - 2 * HOUR),
  });
  // run: BLOCKED
  store.writeRecord(store.paths.run('run_gamma_003'), {
    schema: store.SCHEMA.run, run_id: 'run_gamma_003', repo: 'acme/other', mode: 'local', state: 'BLOCKED', pr: null,
    head_sha: null, history: [], created_at: iso(NOW - 3 * HOUR), updated_at: iso(NOW - 3 * HOUR),
  });
  // run: COMPLETED (終端: active に数えない)
  store.writeRecord(store.paths.run('run_delta_004'), {
    schema: store.SCHEMA.run, run_id: 'run_delta_004', repo: REPO, mode: 'pr', state: 'COMPLETED', pr: 5,
    head_sha: H1, history: [], created_at: iso(NOW - 9 * HOUR), updated_at: iso(NOW - 8 * HOUR),
  });
  // 品質: H2 は PASS、H1 は FAIL / UNKNOWN
  store.writeRecord(store.paths.quality(REPO, H2, 'eval_h2_pass'), {
    schema: store.SCHEMA.quality, eval_id: 'eval_h2_pass', repo: REPO, head_sha: H2, base_sha: BASE, pr: 7,
    started_at: iso(NOW - 2 * HOUR), finished_at: iso(NOW - 2 * HOUR + 60000), isolation: 'bwrap', verdict: 'PASS',
    checks: [{ id: 'npm-test', category: 'unit', cmd: ['npm', 'test'], exit_code: 0, passed: 10, failed: 0, skipped: 0, duration_ms: 1200,
      log_file: '/etc/passwd', status: 'PASS' }],
    evidence_hash: 'f'.repeat(64), hmac: 'secret-hmac-value',
  });
  store.writeRecord(store.paths.quality(REPO, H1, 'eval_h1_fail'), {
    schema: store.SCHEMA.quality, eval_id: 'eval_h1_fail', repo: REPO, head_sha: H1, verdict: 'FAIL', checks: [],
    started_at: iso(NOW - 6 * HOUR), finished_at: iso(NOW - 6 * HOUR),
  });
  store.writeRecord(store.paths.quality(REPO, H1, 'eval_h1_unkn'), {
    schema: store.SCHEMA.quality, eval_id: 'eval_h1_unkn', repo: REPO, head_sha: H1, verdict: 'UNKNOWN', checks: [],
  });
  // ゲート: PR 7 の H2 は PASS
  store.writeRecord(store.paths.gate(REPO, 7, H2), {
    schema: store.SCHEMA.gate, repo: REPO, pr: 7, head_sha: H2, base_sha: BASE, verdict: 'PASS', risk: 'R2',
    reasons: ['ok'], inputs: {}, evaluated_at: iso(NOW - HOUR),
  });
  store.writeRecord(store.paths.gate(REPO, 7, H1), {
    schema: store.SCHEMA.gate, repo: REPO, pr: 7, head_sha: H1, verdict: 'FAIL', risk: 'R2', reasons: [], evaluated_at: iso(NOW - 4 * HOUR),
  });
  const appr = (id, head, expMs) => store.writeRecord(store.paths.approval(REPO, 7, id), {
    schema: store.SCHEMA.approval, approval_id: id, repo: REPO, pr: 7, head_sha: head, base_sha: BASE, gate_verdict: 'PASS',
    risk: 'R2', approver: 'kensan', issued_at: iso(NOW - HOUR), expires_at: iso(expMs), nonce: 'nonce_' + id, signature: 'sig-' + id, key_id: 'k1',
  });
  appr('appr_stale_01', H1, NOW + HOUR);      // head 不一致
  appr('appr_expired1', H2, NOW - 60000);     // 期限切れ
  appr('appr_revoked1', H2, NOW + HOUR);      // 取り消し済み
  store.writeRecord(store.paths.revocation('appr_revoked1'), { schema: store.SCHEMA.revocation, approval_id: 'appr_revoked1', reason: 'test' });
  // マージ: PR 5 は確認済み、PR 9 は未確認 (MERGED と書いてあっても数えない)
  store.writeRecord(store.paths.merge(REPO, 5), { schema: store.SCHEMA.merge, repo: REPO, pr: 5, state: 'MERGED', merge_commit_sha: 'd'.repeat(40), confirmed: true, at: iso(NOW - 8 * HOUR) });
  store.writeRecord(store.paths.merge(REPO, 9), { schema: store.SCHEMA.merge, repo: REPO, pr: 9, state: 'MERGED', merge_commit_sha: 'e'.repeat(40), confirmed: false, at: iso(NOW) });
  store.appendAudit('run_started', { run_id: 'run_alpha_001' });
  store.appendAudit('gate_evaluated', { pr: 7 });
}

// ---------------------------------------------------------------------------
test('overview: fixture から数える (デモデータは作らない)', () => {
  seed();
  const o = api.overview(NOW);
  assert.equal(o.counts.projects, 2, 'acme/widget と acme/other');
  assert.equal(o.counts.runs_active, 3, 'COMPLETED は除外');
  assert.equal(o.counts.ship_running, 1);
  assert.equal(o.counts.quality_evaluating, 0);
  assert.equal(o.counts.approval_pending, 1, 'PR 7: gate PASS で有効な承認が無い');
  assert.equal(o.counts.merged, 1, 'confirmed=false の PR 9 は数えない');
  assert.equal(o.counts.blocked_or_failed, 1);
  assert.equal(o.local_quality_success_rate, 0.5, 'PASS 1 / (PASS+FAIL) 2。UNKNOWN は分母外');
  assert.equal(o.ship_capability, null, 'capability.json が無ければ null');
  assert.equal(o.actions, null);
  assert.match(o.actions_note, /bin\/ship\.sh actions/);
  const p7 = o.prs.find((p) => p.pr === 7);
  assert.equal(p7.pending_approval, true);
  assert.equal(p7.latest_head, H2);
  assert.equal(p7.approve_command, `bin/ship-approve.sh approve --repo ${REPO} --pr 7 --head ${H2}`);
  assert.ok(o.states.includes('HUMAN_APPROVAL_REQUIRED'));
});

test('overview: 空の ship home でも 0 / null を返す', () => {
  fs.rmSync(process.env.CLAUDEOS_SHIP_HOME, { recursive: true, force: true });
  const o = api.overview(NOW);
  assert.deepEqual(o.counts, { projects: 0, runs_active: 0, ship_running: 0, quality_evaluating: 0, approval_pending: 0, merged: 0, blocked_or_failed: 0 });
  assert.equal(o.local_quality_success_rate, null);
  assert.deepEqual(o.prs, []);
});

test('overview: capability.json / actions-usage.json があれば返す', () => {
  seed();
  fs.writeFileSync(path.join(process.env.CLAUDEOS_SHIP_HOME, 'capability.json'), JSON.stringify({ available: true, claude_version: '2.1.400' }));
  fs.writeFileSync(path.join(process.env.CLAUDEOS_SHIP_HOME, 'actions-usage.json'), JSON.stringify({ minutes: 12 }));
  const o = api.overview(NOW);
  assert.equal(o.ship_capability.available, true);
  assert.equal(o.actions.minutes, 12);
  assert.equal(o.actions_note, null);
});

test('prDetail: 承認の有効性ラベル (STALE_HEAD / EXPIRED / REVOKED)', () => {
  seed();
  const d = api.prDetail(REPO, '7', NOW);
  const v = Object.fromEntries(d.approvals.map((a) => [a.approval_id, a.validity]));
  assert.deepEqual(v, { appr_stale_01: 'STALE_HEAD', appr_expired1: 'EXPIRED', appr_revoked1: 'REVOKED' });
  assert.equal(d.pending_approval, true);
  assert.match(d.enforcement_note, /human-gate\.js/);
  // 署名・nonce は返さない
  const s = JSON.stringify(d);
  assert.ok(!s.includes('sig-appr') && !s.includes('nonce_appr'), '署名・nonce を返さない');
});

test('prDetail: 有効な承認があれば VALID で pending ではない', () => {
  seed();
  store.writeRecord(store.paths.approval(REPO, 7, 'appr_valid_01'), {
    schema: store.SCHEMA.approval, approval_id: 'appr_valid_01', repo: REPO, pr: 7, head_sha: H2, base_sha: BASE,
    gate_verdict: 'PASS', risk: 'R2', approver: 'kensan', issued_at: iso(NOW), expires_at: iso(NOW + HOUR), nonce: 'n', signature: 's', key_id: 'k1',
  });
  const d = api.prDetail(REPO, 7, NOW);
  assert.equal(d.approvals.find((a) => a.approval_id === 'appr_valid_01').validity, 'VALID');
  assert.equal(d.pending_approval, false);
  assert.equal(api.overview(NOW).counts.approval_pending, 0);
});

test('approvalValidity: 最新 head 不明は STALE_HEAD、期限不正は EXPIRED', () => {
  seed();
  assert.equal(api.approvalValidity({ approval_id: 'x_unknown_1', head_sha: H2, expires_at: iso(NOW + HOUR) }, null, NOW).state, 'STALE_HEAD');
  assert.equal(api.approvalValidity({ approval_id: 'x_unknown_2', head_sha: H2, expires_at: 'garbage' }, H2, NOW).state, 'EXPIRED');
  assert.equal(api.approvalValidity({ approval_id: 'x_unknown_3', head_sha: H2, expires_at: iso(NOW + HOUR) }, H2, NOW).state, 'VALID');
});

test('prDetail: 品質証跡の SHA 一致・秘密/外部パスを返さない', () => {
  seed();
  const d = api.prDetail(REPO, 7, NOW);
  const q2 = d.quality.find((q) => q.head_sha === H2);
  assert.equal(q2.verdict, 'PASS');
  assert.equal(q2.sha_match, true);
  assert.equal(q2.hmac_present, true);
  assert.equal(q2.checks[0].log_file, '[PATH_HIDDEN]', 'ship home 外のパスは隠す');
  const q1 = d.quality.find((q) => q.head_sha === H1);
  assert.equal(q1.sha_match, false);
  const s = JSON.stringify(d);
  assert.ok(!s.includes('secret-hmac-value'), 'HMAC 値を返さない');
  assert.ok(!s.includes('/etc/passwd'));
  const runs = JSON.stringify(api.listRuns());
  assert.ok(!runs.includes('ghp_ZZZZ'), 'トークンは redact');
  assert.ok(!runs.includes('/home/someone'), 'project_dir の絶対パスは返さない');
});

test('prDetail: 不正な repo / pr は例外 (トラバーサル不可)', () => {
  seed();
  for (const bad of ['../etc', 'acme/../x', 'acme', 'acme/widget/extra', '..%2f..', '', 'a/b;rm']) {
    assert.throws(() => api.prDetail(bad, 7), /INVALID_REPO/, bad);
  }
  for (const bad of ['0', '-1', 'abc', '1.5', '99999999999']) {
    assert.throws(() => api.prDetail(REPO, bad), /INVALID_PR/, bad);
  }
});

test('auditTail: 監査チェーンの整合性を返し、改ざんを検出する', () => {
  seed();
  const a = api.auditTail('1');
  assert.equal(a.entries.length, 1);
  assert.equal(a.total, 2);
  assert.deepEqual(a.chain, { ok: true, entries: 2 });
  const file = store.paths.audit();
  const lines = fs.readFileSync(file, 'utf8').trim().split('\n');
  const e = JSON.parse(lines[0]); e.event = 'tampered';
  lines[0] = JSON.stringify(e);
  fs.writeFileSync(file, lines.join('\n') + '\n');
  const b = api.auditTail(50);
  assert.equal(b.chain.ok, false);
  assert.equal(b.chain.error, 'HASH_MISMATCH');
  assert.equal(api.auditTail('9999').limit, 500, '上限 500');
});

test('revokeApproval: 入力検証・メール必須・二重取り消しは 409', () => {
  seed();
  assert.equal(api.revokeApproval({ approval_id: '../../x', reason: 'r' }, 'a@b.c').status, 400);
  assert.equal(api.revokeApproval({ approval_id: 'appr_stale_01' }, 'a@b.c').status, 400, 'reason 必須');
  assert.equal(api.revokeApproval({ approval_id: 'appr_stale_01', reason: 'r' }, 'sub-only').status, 403);
  assert.equal(api.revokeApproval({ approval_id: 'appr_nothere', reason: 'r' }, 'a@b.c').status, 404);
  const ok = api.revokeApproval({ approval_id: 'appr_stale_01', reason: '誤承認' }, 'a@b.c');
  assert.equal(ok.status, 200);
  assert.ok(fs.existsSync(store.paths.revocation('appr_stale_01')));
  assert.equal(api.revokeApproval({ approval_id: 'appr_stale_01', reason: 'again' }, 'a@b.c').status, 409);
  assert.equal(api.prDetail(REPO, 7, NOW).approvals.find((x) => x.approval_id === 'appr_stale_01').validity, 'REVOKED');
});

// ---------------------------------------------------------------------------
// HTTP 統合 (startup-server.js の経路)
// ---------------------------------------------------------------------------
const { publicKey: PUB, privateKey: PRIV } = crypto.generateKeyPairSync('rsa', { modulusLength: 2048 });
const JWK = Object.assign(PUB.export({ format: 'jwk' }), { kid: 'test-kid', alg: 'RS256', use: 'sig' });
const b64u = (b) => Buffer.from(b).toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
function signJwt(over) {
  const header = { alg: 'RS256', kid: 'test-kid', typ: 'JWT' };
  const payload = Object.assign({ iss: 'https://test.cloudflareaccess.com', aud: ['aud-1'], email: 'kensan@example.test',
    exp: Math.floor(Date.now() / 1000) + 300 }, over || {});
  const input = b64u(JSON.stringify(header)) + '.' + b64u(JSON.stringify(payload));
  return input + '.' + b64u(crypto.sign('RSA-SHA256', Buffer.from(input), PRIV));
}

async function withServer(cfg, fn) {
  const server = srv.createServer(Object.assign({ authPass: '', accessTeamDomain: 'test.cloudflareaccess.com', accessAud: 'aud-1',
    accessKeys: async () => [JWK] }, cfg || {}));
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  try { await fn(server.address().port); } finally { await new Promise((r) => server.close(r)); }
}
function req(port, method, p, body, headers) {
  return new Promise((resolve, reject) => {
    const data = body === undefined ? null : (typeof body === 'string' ? body : JSON.stringify(body));
    const h = Object.assign({}, data ? { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(data) } : {}, headers || {});
    const r = http.request({ host: '127.0.0.1', port, method, path: p, headers: h }, (res) => {
      let d = '';
      res.on('data', (c) => { d += c; });
      res.on('end', () => { let j = null; try { j = JSON.parse(d); } catch { /* 非 JSON */ } resolve({ status: res.statusCode, json: j, body: d }); });
    });
    r.on('error', reject);
    if (data) r.write(data);
    r.end();
  });
}

test('HTTP: GET /api/ship/* の応答と 400', async () => {
  seed();
  await withServer({}, async (port) => {
    const o = await req(port, 'GET', '/api/ship/overview');
    assert.equal(o.status, 200);
    assert.equal(o.json.ok, true);
    assert.equal(o.json.counts.approval_pending, 1);
    const runs = await req(port, 'GET', '/api/ship/runs');
    assert.equal(runs.status, 200);
    assert.equal(runs.json.runs.length, 4);
    const pr = await req(port, 'GET', '/api/ship/pr?repo=' + encodeURIComponent(REPO) + '&pr=7');
    assert.equal(pr.status, 200);
    assert.equal(pr.json.approvals.length, 3);
    for (const q of ['repo=..%2F..%2Fetc&pr=7', 'repo=acme%2Fwidget&pr=0', 'repo=acme%2Fwidget&pr=..%2F1', 'pr=7', 'repo=acme%2F..&pr=1']) {
      const r = await req(port, 'GET', '/api/ship/pr?' + q);
      assert.equal(r.status, 400, q);
    }
    const au = await req(port, 'GET', '/api/ship/audit?limit=5');
    assert.equal(au.status, 200);
    assert.equal(au.json.chain.ok, true);
    // approve の経路は無い
    const ap = await req(port, 'POST', '/api/ship/approvals/approve', { approval_id: 'x' }, { Origin: 'http://127.0.0.1:' + port });
    assert.equal(ap.status, 404);
    const unk = await req(port, 'GET', '/api/ship/../../etc/passwd');
    assert.notEqual(unk.status, 200);
  });
});

test('HTTP: Basic 認証が有効なら /api/ship/* も 401', async () => {
  seed();
  await withServer({ authPass: 'pw' }, async (port) => {
    assert.equal((await req(port, 'GET', '/api/ship/overview')).status, 401);
  });
});

test('HTTP: 取り消しは JWT (メール) 必須', async () => {
  seed();
  await withServer({}, async (port) => {
    const origin = { Origin: 'http://127.0.0.1:' + port };
    const body = { approval_id: 'appr_stale_01', reason: 'テスト取り消し' };
    const noJwt = await req(port, 'POST', '/api/ship/approvals/revoke', body, origin);
    assert.equal(noJwt.status, 401);
    const noEmail = await req(port, 'POST', '/api/ship/approvals/revoke', body, Object.assign({ 'Cf-Access-Jwt-Assertion': signJwt({ email: undefined, sub: 'svc-123' }) }, origin));
    assert.equal(noEmail.status, 403, 'sub だけの JWT は拒否');
    const badAud = await req(port, 'POST', '/api/ship/approvals/revoke', body, Object.assign({ 'Cf-Access-Jwt-Assertion': signJwt({ aud: ['other'] }) }, origin));
    assert.equal(badAud.status, 403);
    const noOrigin = await req(port, 'POST', '/api/ship/approvals/revoke', body, { 'Cf-Access-Jwt-Assertion': signJwt() });
    assert.equal(noOrigin.status, 403, 'Origin 必須');
    assert.ok(!fs.existsSync(store.paths.revocation('appr_stale_01')), '拒否時は書かない');
    const getRevoke = await req(port, 'GET', '/api/ship/approvals/revoke');
    assert.equal(getRevoke.status, 405);

    const ok = await req(port, 'POST', '/api/ship/approvals/revoke', body, Object.assign({ 'Cf-Access-Jwt-Assertion': signJwt() }, origin));
    assert.equal(ok.status, 200);
    assert.equal(ok.json.revoked_by, 'kensan@example.test');
    const rec = store.readRecord(store.paths.revocation('appr_stale_01'));
    assert.equal(rec.revoked_by, 'kensan@example.test');
    const audit = api.auditTail(50);
    const last = audit.entries[audit.entries.length - 1];
    assert.equal(last.event, 'approval_revoked');
    assert.equal(last.approval_id, 'appr_stale_01');
    assert.equal(last.actor, 'kensan@example.test');
    assert.equal(audit.chain.ok, true);
    const again = await req(port, 'POST', '/api/ship/approvals/revoke', body, Object.assign({ 'Cf-Access-Jwt-Assertion': signJwt() }, origin));
    assert.equal(again.status, 409);
  });
});

test('HTTP: Access 未設定なら取り消しは 403 (fail-closed)', async () => {
  seed();
  await withServer({ accessTeamDomain: '', accessAud: '' }, async (port) => {
    const r = await req(port, 'POST', '/api/ship/approvals/revoke', { approval_id: 'appr_stale_01', reason: 'r' },
      { Origin: 'http://127.0.0.1:' + port, 'Cf-Access-Jwt-Assertion': signJwt() });
    assert.equal(r.status, 403);
    assert.equal(r.json.error, 'SHIP_AUTH_NOT_CONFIGURED');
  });
});

test('静的配信: ship.html / ship.js / ship.css と index.html のナビ', async () => {
  await withServer({}, async (port) => {
    for (const f of ['/ship.html', '/ship.js', '/ship.css']) assert.equal((await req(port, 'GET', f)).status, 200, f);
    const html = (await req(port, 'GET', '/ship.html')).body;
    assert.ok(!/https?:\/\/(?!127\.0\.0\.1)[^"']*\.(js|css)/.test(html), '外部 CDN を読まない');
    assert.match(html, /aria-live/);
    assert.match((await req(port, 'GET', '/index.html')).body, /href="\/ship\.html"/);
  });
});

test.after(() => { fs.rmSync(TMP, { recursive: true, force: true }); });
