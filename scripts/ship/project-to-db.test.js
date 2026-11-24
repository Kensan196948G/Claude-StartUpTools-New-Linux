'use strict';
/**
 * project-to-db.test.js — Ship Native → claudeos_control 射影のユニットテスト (DB 不要・密閉)
 *
 * 観点:
 *   - sqlLiteral: 単一引用符の二重化 / バックスラッシュはそのまま / NUL・孤立サロゲート拒否 / 型
 *   - buildProjection: 全種別が ON CONFLICT 付き INSERT で 1 トランザクションに入る / 決定的 (冪等)
 *   - 不正レコードの除外: SHA 形式 / 証跡改ざん / PASS 以外への approve / 秘密混入 / nonce 重複
 *   - SQL インジェクション: 悪意ある文字列がリテラル内に閉じ込められる
 *   - applySql: psql を引数配列で起動し SQL を stdin で渡す / SET LOCAL ROLE / DATABASE_URL を渡さない
 *   - CLI: 既定は dry-run / --apply は --db 必須 / --strict
 */

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const { spawnSync } = require('node:child_process');

const SCRIPT = path.join(__dirname, 'project-to-db.js');
const p2d = require('./project-to-db');
const store = require('./lib/store');

const REPO = 'acme/widget';
const HEAD = 'a'.repeat(40);
const BASE = 'b'.repeat(40);
const MERGE = 'c'.repeat(40);

const TMP_DIRS = [];
test.after(() => { for (const d of TMP_DIRS) fs.rmSync(d, { recursive: true, force: true }); });
function tmpHome() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ship-p2d-'));
  TMP_DIRS.push(dir);
  process.env.CLAUDEOS_SHIP_HOME = dir;
  return dir;
}
function put(file, obj) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, JSON.stringify(obj, null, 2));
}
function sealBody(rec) { const b = { ...rec }; delete b.evidence_hash; delete b.hmac; return store.canonical(b); }

const keyPair = crypto.generateKeyPairSync('ed25519');
const KEY_ID = 'sha256:' + store.sha256(keyPair.publicKey.export({ type: 'spki', format: 'der' }));
const sign = (s) => crypto.sign(null, Buffer.from(s), keyPair.privateKey).toString('base64');

function approvalRec(over = {}) {
  const a = {
    schema: store.SCHEMA.approval, approval_id: 'ha_test_000001', repo: REPO, pr: 7, head_sha: HEAD, base_sha: BASE,
    gate_verdict: 'PASS', gate_hash: 'd'.repeat(64), quality_eval_id: 'qe_test_000001', quality_evidence_hash: null,
    risk: 'R2', approver: 'Kensan', key_id: KEY_ID, issued_at: '2026-11-24T00:00:00.000Z', expires_at: '2026-11-25T00:00:00.000Z',
    nonce: '0123456789abcdef0123456789abcdef', policy_version: '5.0.0', decision: 'approve', ...over,
  };
  a.signature = sign(store.canonical(a));
  return a;
}

/** writeFixtures(home) — 全種別 1 件ずつの正常なストア */
function writeFixtures(home) {
  const q = {
    schema: store.SCHEMA.quality, eval_id: 'qe_test_000001', repo: REPO, pr: 7, head_sha: HEAD, base_sha: BASE,
    profile: 'claudeos-self', policy_version: '5.0.0', started_at: '2026-11-24T00:00:00.000Z', finished_at: '2026-11-24T00:05:00.000Z',
    host: 'devbox', node: 'v22', isolation: 'bwrap(net=none,home=tmpfs,ro-root)', verdict: 'PASS', reasons: [],
    checks: [
      { id: 'npm-test', category: 'unit+regression', cmd: 'npm test', exit_code: 0, passed: 120, failed: 0, skipped: 2, duration_ms: 4000, log_file: 'quality/x/npm-test.log', status: 'PASS' },
      { id: 'secrets-scan', category: 'secrets', cmd: '@secrets', exit_code: 0, passed: null, failed: null, skipped: null, duration_ms: 900, log_file: 'quality/x/secrets.log', status: 'PASS' },
    ],
  };
  q.evidence_hash = store.sha256(sealBody(q));
  q.hmac = 'f'.repeat(64);
  put(store.paths.quality(REPO, HEAD, q.eval_id), q);

  put(store.paths.run('run_test_000001'), {
    schema: store.SCHEMA.run, run_id: 'run_test_000001', repo: REPO, project_dir: '/home/u/widget', mode: 'SH2', state: 'SHIP_REVIEWING',
    intent: 'x', pr: 7, head_sha: HEAD, base_sha: BASE, branch: 'feat/x', ship: { capability: 'available', status: 'not-started' }, retries: 0,
    created_at: '2026-11-24T00:00:00.000Z', updated_at: '2026-11-24T01:00:00.000Z',
    history: [
      { from: 'IDLE', to: 'DISCOVERY', at: '2026-11-24T00:00:00.000Z', evidence: { reason: 'run-start' } },
      { from: 'DISCOVERY', to: 'PLANNING', at: '2026-11-24T00:10:00.000Z', evidence: {} },
    ],
  });
  put(store.paths.gate(REPO, 7, HEAD), {
    schema: store.SCHEMA.gate, repo: REPO, pr: 7, head_sha: HEAD, base_sha: BASE, verdict: 'PASS', risk: 'R2',
    risk_detail: [{ file: 'src/a.js', level: 'R2', pattern: null }], reasons: [], checks: [{ id: 'local.verdict', result: 'PASS' }],
    quality_eval_id: q.eval_id, ship_source: null, policy_version: '5.0.0', evaluated_at: '2026-11-24T00:06:00.000Z', gate_hash: 'd'.repeat(64),
  });
  const att = { schema: 'claudeos.ship-attestation/v1', attestation_id: 'sa_test_000001', repo: REPO, pr: 7, head_sha: HEAD, reviewed: true,
    review_effort: 'high', important_open: 0, watch_status: 'checks-pass-comments-answered', notes: 'ok', approver: 'Kensan', key_id: KEY_ID,
    issued_at: '2026-11-24T00:05:30.000Z', nonce: 'fedcba9876543210fedcba9876543210' };
  att.signature = sign(store.canonical(att));
  put(path.join(home, 'ship-evidence', store.slug(REPO), 'pr-7', att.attestation_id + '.json'), att);
  const a = approvalRec();
  put(store.paths.approval(REPO, 7, a.approval_id), a);
  put(store.paths.revocation(a.approval_id), { schema: store.SCHEMA.revocation, approval_id: a.approval_id, reason: 'test', actor: 'Kensan', at: '2026-11-24T02:00:00.000Z' });
  fs.mkdirSync(path.dirname(store.paths.consumed(a.nonce)), { recursive: true });
  fs.writeFileSync(store.paths.consumed(a.nonce), a.approval_id + '\n');
  put(store.paths.merge(REPO, 7), { schema: store.SCHEMA.merge, repo: REPO, pr: 7, at: '2026-11-24T03:00:00.000Z', expected_head: HEAD,
    state: 'MERGED', confirmed: true, merge_commit_sha: MERGE, head_sha: HEAD });
  store.appendAudit('run_started', { run_id: 'run_test_000001', repo: REPO, mode: 'SH2' });
  store.appendAudit('quality_evaluated', { repo: REPO, pr: 7, head_sha: HEAD, eval_id: q.eval_id, verdict: 'PASS' });
  return { quality: q, approval: a };
}

// ------------------------------------------------------------
test('sqlLiteral: 単一引用符を二重化し、バックスラッシュはそのまま', () => {
  assert.equal(p2d.sqlLiteral("O'Brien"), "'O''Brien'");
  assert.equal(p2d.sqlLiteral("''"), "''''''");
  assert.equal(p2d.sqlLiteral('a\\b'), "'a\\b'");
  assert.equal(p2d.sqlLiteral('改行\nタブ\t'), "'改行\nタブ\t'");
  assert.equal(p2d.sqlLiteral("x'); DROP TABLE control.projects; --"), "'x''); DROP TABLE control.projects; --'");
  assert.equal(p2d.sqlLiteral('😀'), "'😀'");
});

test('sqlLiteral: NULL / boolean / 数値 / 型拒否', () => {
  assert.equal(p2d.sqlLiteral(null), 'NULL');
  assert.equal(p2d.sqlLiteral(undefined), 'NULL');
  assert.equal(p2d.sqlLiteral(true), 'TRUE');
  assert.equal(p2d.sqlLiteral(false), 'FALSE');
  assert.equal(p2d.sqlLiteral(42), '42');
  assert.equal(p2d.sqlLiteral(-1.5), '-1.5');
  assert.throws(() => p2d.sqlLiteral(NaN), /NON_FINITE/);
  assert.throws(() => p2d.sqlLiteral(Infinity), /NON_FINITE/);
  assert.throws(() => p2d.sqlLiteral({}), /UNSUPPORTED/);
  assert.throws(() => p2d.sqlLiteral([1]), /UNSUPPORTED/);
});

test('sqlLiteral: NUL バイトと孤立サロゲートを拒否する', () => {
  assert.throws(() => p2d.sqlLiteral('a\u0000b'), /NUL_BYTE/);
  assert.throws(() => p2d.sqlLiteral('a\uD800b'), /MALFORMED_UNICODE/);
  assert.throws(() => p2d.sqlJson({ k: 'v\u0000' }), /NUL_BYTE/);
  assert.throws(() => p2d.sqlJson({ ['k\u0000']: 'v' }), /NUL_BYTE/);
});

test('sqlJson: jsonb リテラル。引用符は二重化される', () => {
  assert.equal(p2d.sqlJson({ a: "it's" }), `'{"a":"it''s"}'::jsonb`);
  assert.equal(p2d.sqlJson([]), `'[]'::jsonb`);
});

test('projectKey: control.projects.project_key の形式に収まる', () => {
  assert.equal(p2d.projectKey('Acme/Widget'), 'gh.acme__widget');
  const long = 'a'.repeat(100) + '/' + 'b'.repeat(100);
  assert.match(p2d.projectKey(long), /^[a-z0-9][a-z0-9._-]{0,126}$/);
});

test('buildProjection: 全種別を ON CONFLICT 付きで 1 トランザクションに出力する', () => {
  const home = tmpHome();
  writeFixtures(home);
  const { sql, summary } = p2d.buildProjection();
  assert.deepEqual(summary.rejected, []);
  assert.deepEqual(summary.counts, { run: 1, quality: 1, gate: 1, attestation: 1, approval: 1, revocation: 1, consumption: 1, merge: 1, audit: 2 });
  assert.equal(summary.audit_chain.ok, true);
  assert.match(sql, /^-- generated/);
  assert.match(sql, /\nBEGIN;\nSET LOCAL standard_conforming_strings = on;/);
  assert.match(sql, /\nCOMMIT;\n$/);
  for (const t of ['policy_versions', 'projects', 'pull_requests', 'ship_sessions', 'ship_state_transitions', 'quality_evaluations',
    'test_results', 'gate_evaluations', 'ship_review_attestations', 'human_approvals', 'approval_revocations',
    'approval_consumptions', 'merge_events', 'audit_events']) {
    assert.match(sql, new RegExp('INSERT INTO control\\.' + t + ' '), t);
  }
  // 全 INSERT が冪等 (ON CONFLICT 付き)
  const inserts = sql.split('INSERT INTO').length - 1;
  const conflicts = sql.split('ON CONFLICT').length - 1;
  assert.equal(inserts, conflicts);
  // HMAC 値は射影しない
  assert.ok(!sql.includes('f'.repeat(64)));
  // 承認の衝突対象は approval_id のみ (nonce 重複は UNIQUE 違反として表面化させる)
  assert.match(sql, /INSERT INTO control\.human_approvals[\s\S]*?ON CONFLICT \(approval_id\) DO NOTHING;/);
  // ship_sessions は新しい時だけ上書き
  assert.match(sql, /WHERE control\.ship_sessions\.source_updated_at < EXCLUDED\.source_updated_at;/);
});

test('buildProjection: 同じストアからは同じ SQL (決定的 = 再投入は no-op)', () => {
  tmpHome();
  writeFixtures(process.env.CLAUDEOS_SHIP_HOME);
  const a = p2d.buildProjection().sql;
  const b = p2d.buildProjection().sql;
  assert.equal(a, b);
});

test('buildProjection: 空のストアでも妥当な (空の) トランザクション', () => {
  tmpHome();
  const { sql, summary } = p2d.buildProjection();
  assert.equal(summary.rejected.length, 0);
  assert.match(sql, /BEGIN;[\s\S]*COMMIT;\n$/);
  assert.ok(!sql.includes('INSERT INTO'));
});

test('不正レコード: 短縮 SHA / 改ざんされた証跡 / PASS 以外への approve / 秘密混入は除外', () => {
  const home = tmpHome();
  const { quality } = writeFixtures(home);
  // 短縮 SHA の gate
  put(path.join(home, 'gates', store.slug(REPO), 'pr-8', 'x.json'), { repo: REPO, pr: 8, head_sha: 'abc1234', base_sha: BASE,
    verdict: 'PASS', risk: 'R1', reasons: [], evaluated_at: '2026-11-24T00:00:00Z' });
  // 改ざんされた証跡 (verdict を書き換え、evidence_hash は元のまま)
  const tampered = { ...quality, eval_id: 'qe_test_tamper1', verdict: 'FAIL' };
  put(store.paths.quality(REPO, HEAD, tampered.eval_id), tampered);
  // gate FAIL に approve
  put(store.paths.approval(REPO, 7, 'ha_test_badpass'), approvalRec({ approval_id: 'ha_test_badpass', nonce: 'n'.repeat(32), gate_verdict: 'FAIL' }));
  // approver に秘密らしき文字列
  put(store.paths.approval(REPO, 7, 'ha_test_secret'), approvalRec({ approval_id: 'ha_test_secret', nonce: 'm'.repeat(32), approver: 'x ghp_abcdefghijklmnop' }));
  // 不正な状態語彙の run
  put(store.paths.run('run_test_badstate'), { run_id: 'run_test_badstate', repo: REPO, mode: 'SH1', state: 'NOPE', created_at: '2026-11-24T00:00:00Z', updated_at: '2026-11-24T00:00:00Z' });
  // 壊れた JSON
  fs.writeFileSync(path.join(home, 'runs', 'run_test_broken.json'), '{');

  const { sql, summary } = p2d.buildProjection();
  const reasons = Object.fromEntries(summary.rejected.map((r) => [path.basename(r.file), r.reason]));
  assert.equal(reasons['x.json'], 'INVALID_HEAD_SHA');
  assert.equal(reasons['qe_test_tamper1.json'], 'EVIDENCE_HASH_MISMATCH');
  assert.equal(reasons['ha_test_badpass.json'], 'APPROVE_WITHOUT_PASS');
  assert.equal(reasons['ha_test_secret.json'], 'SECRET_PATTERN_APPROVER');
  assert.equal(reasons['run_test_badstate.json'], 'INVALID_STATE');
  assert.equal(reasons['run_test_broken.json'], 'UNREADABLE');
  assert.ok(!sql.includes('abc1234'));
  assert.ok(!sql.includes('ha_test_badpass') && !sql.includes('ghp_'));
  assert.equal(summary.counts.approval, 1);
});

test('不正レコード: 同一 nonce の承認 2 件目はストア段階で除外 (リプレイ)', () => {
  const home = tmpHome();
  const { approval } = writeFixtures(home);
  put(store.paths.approval(REPO, 7, 'ha_test_replay1'), approvalRec({ approval_id: 'ha_test_replay1', nonce: approval.nonce }));
  const { summary } = p2d.buildProjection();
  const dup = summary.rejected.find((r) => r.file.endsWith('ha_test_replay1.json') || r.file.endsWith('ha_test_000001.json'));
  assert.ok(dup, JSON.stringify(summary.rejected));
  assert.match(dup.reason, /^DUPLICATE_NONCE/);
  assert.equal(summary.counts.approval, 1);
});

test('不正レコード: 使用記録の nonce が承認と食い違えば除外', () => {
  const home = tmpHome();
  writeFixtures(home);
  fs.writeFileSync(store.paths.consumed('zzzzzzzzzzzz'), 'ha_test_000001\n');
  const { summary } = p2d.buildProjection();
  assert.ok(summary.rejected.some((r) => r.kind === 'consumption' && r.reason === 'NONCE_MISMATCH'));
});

test('SQL インジェクション: 悪意ある notes はリテラル内に閉じ込められる', () => {
  const home = tmpHome();
  writeFixtures(home);
  const evil = "x'); DROP TABLE control.projects; --";
  const att = { schema: 'claudeos.ship-attestation/v1', attestation_id: 'sa_test_evil01', repo: REPO, pr: 7, head_sha: HEAD, reviewed: false,
    review_effort: 'high', important_open: 1, watch_status: 'running', notes: evil, approver: 'K', key_id: KEY_ID,
    issued_at: '2026-11-24T00:00:00.000Z', nonce: 'e'.repeat(32) };
  att.signature = sign(store.canonical(att));
  put(path.join(home, 'ship-evidence', store.slug(REPO), 'pr-7', att.attestation_id + '.json'), att);
  const { sql } = p2d.buildProjection();
  assert.ok(sql.includes("'x''); DROP TABLE control.projects; --'"));
  // 引用符の外に出た DROP は無い: リテラルを除去した残りに DROP が現れない
  const outside = sql.replace(/'(?:[^']|'')*'/g, "''");
  assert.ok(!/DROP/i.test(outside));
});

test('applySql: psql を引数配列で起動し、SQL を stdin で渡す (SET LOCAL ROLE / DATABASE_URL 除去)', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ship-p2d-bin-'));
  TMP_DIRS.push(dir);
  const log = path.join(dir, 'log.json');
  fs.writeFileSync(path.join(dir, 'psql'), `#!/usr/bin/env node
const fs = require('fs');
const input = fs.readFileSync(0, 'utf8');
fs.writeFileSync(${JSON.stringify(log)}, JSON.stringify({ argv: process.argv.slice(2), input, dburl: process.env.DATABASE_URL || null, pghost: process.env.PGHOST }));
`, { mode: 0o755 });
  const saved = { PG_BIN: process.env.PG_BIN, DATABASE_URL: process.env.DATABASE_URL, PGHOST: process.env.PGHOST };
  process.env.PG_BIN = dir;
  process.env.DATABASE_URL = 'postgresql://u:p@h/db';
  delete process.env.PGHOST;
  try {
    const r = p2d.applySql('BEGIN;\nSELECT 1;\nCOMMIT;\n', { db: 'claudeos_ship_mig_test_x', role: 'claudeos_control_app' });
    assert.equal(r.status, 0);
    const got = JSON.parse(fs.readFileSync(log, 'utf8'));
    assert.deepEqual(got.argv, ['-X', '-q', '-v', 'ON_ERROR_STOP=1', '-h', '/var/run/postgresql', '-d', 'claudeos_ship_mig_test_x', '-f', '-']);
    assert.equal(got.input, 'BEGIN;\nSET LOCAL ROLE "claudeos_control_app";\nSELECT 1;\nCOMMIT;\n');
    assert.equal(got.dburl, null);
    assert.equal(got.pghost, '/var/run/postgresql');
    assert.throws(() => p2d.applySql('BEGIN;', { db: 'bad;name', role: 'none' }), /INVALID_DB_NAME/);
    assert.throws(() => p2d.applySql('BEGIN;', { db: 'ok', role: 'x"; DROP' }), /INVALID_ROLE_NAME/);
    p2d.applySql('BEGIN;\nCOMMIT;\n', { db: 'ok', role: 'none' });
    assert.ok(!JSON.parse(fs.readFileSync(log, 'utf8')).input.includes('SET LOCAL ROLE'));
  } finally {
    for (const [k, v] of Object.entries(saved)) { if (v === undefined) delete process.env[k]; else process.env[k] = v; }
  }
});

test('CLI: 既定は dry-run (JSON 要約のみ、SQL を出さない)', () => {
  const home = tmpHome();
  writeFixtures(home);
  const r = spawnSync(process.execPath, [SCRIPT, '--home', home], { encoding: 'utf8' });
  assert.equal(r.status, 0, r.stderr);
  const out = JSON.parse(r.stdout);
  assert.equal(out.mode, 'dry-run');
  assert.equal(out.counts.approval, 1);
  assert.ok(!r.stdout.includes('INSERT INTO'));
});

test('CLI: --sql は SQL を stdout へ / --apply は --db 必須 / 不明な引数は 2', () => {
  const home = tmpHome();
  writeFixtures(home);
  const r = spawnSync(process.execPath, [SCRIPT, '--sql', '--home', home], { encoding: 'utf8' });
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stdout, /BEGIN;[\s\S]*COMMIT;/);
  assert.equal(spawnSync(process.execPath, [SCRIPT, '--apply', '--home', home], { encoding: 'utf8' }).status, 2);
  assert.equal(spawnSync(process.execPath, [SCRIPT, '--bogus'], { encoding: 'utf8' }).status, 2);
});

test('CLI: --strict は除外が 1 件でもあれば 3 で止まる', () => {
  const home = tmpHome();
  writeFixtures(home);
  fs.writeFileSync(path.join(home, 'runs', 'run_test_broken.json'), '{');
  const r = spawnSync(process.execPath, [SCRIPT, '--sql', '--strict', '--home', home], { encoding: 'utf8' });
  assert.equal(r.status, 3);
  assert.equal(r.stdout, '');
});
