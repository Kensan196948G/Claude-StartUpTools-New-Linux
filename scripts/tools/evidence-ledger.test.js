// evidence-ledger.test.js — 証拠台帳の出所検証・仮説状態遷移・秘密拒否を検証する
'use strict';
const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { execFileSync } = require('node:child_process');

const CLI = path.join(__dirname, 'evidence-ledger.js');

function sandbox() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'evled-'));
  const src = path.join(root, 'source.md');
  fs.writeFileSync(src, '観測された事実のメモ\n');
  return { root, src, ledger: path.join(root, 'ledger.json'), env: { CCSU_EVIDENCE_LEDGER: path.join(root, 'ledger.json') } };
}

function run(args, env) {
  try {
    return { code: 0, stdout: execFileSync(process.execPath, [CLI, ...args], { encoding: 'utf8', env: { ...process.env, ...env } }) };
  } catch (e) {
    return { code: e.status, stdout: e.stdout ? String(e.stdout) : '' };
  }
}

test('evidence-ledger: 実在する出所を持つ主張を登録し sha256 を記録する', () => {
  const sb = sandbox();
  const r = run(['claim', '--text', 'この設定は再現する', '--source', sb.src, '--confidence', '0.6'], sb.env);
  assert.strictEqual(r.code, 0, r.stdout);
  const claim = JSON.parse(r.stdout);
  assert.strictEqual(claim.source_kind, 'local-file');
  assert.strictEqual(claim.source_exists, true);
  assert.match(claim.source_sha256, /^[0-9a-f]{64}$/);
  assert.strictEqual(claim.confidence, 0.6);
  assert.strictEqual(claim.status, 'unverified');
});

test('evidence-ledger: 出所が無い/存在しない主張は登録時に拒否・unsupported になる', () => {
  const sb = sandbox();
  const noSource = run(['claim', '--text', '出所なしの主張'], sb.env);
  assert.strictEqual(noSource.code, 2);
  const missing = run(['claim', '--text', '存在しないファイル', '--source', path.join(sb.root, 'nope.md')], sb.env);
  assert.strictEqual(missing.code, 1);
  assert.strictEqual(JSON.parse(missing.stdout).status, 'unsupported');
});

test('evidence-ledger: URL 出所は取得せず記録のみ (source_kind=url)', () => {
  const sb = sandbox();
  const r = run(['claim', '--text', '外部仕様に準拠', '--source', 'https://example.com/spec', '--locator', '§3.2'], sb.env);
  assert.strictEqual(r.code, 0);
  const c = JSON.parse(r.stdout);
  assert.strictEqual(c.source_kind, 'url');
  assert.strictEqual(c.source_exists, null);
  assert.strictEqual(c.locator, '§3.2');
});

test('evidence-ledger: 同一内容の主張は重複登録しない', () => {
  const sb = sandbox();
  const a = JSON.parse(run(['claim', '--text', '同一主張', '--source', sb.src], sb.env).stdout);
  const b = run(['claim', '--text', '同一主張', '--source', sb.src], sb.env);
  assert.strictEqual(JSON.parse(b.stdout).skipped, 'duplicate');
  assert.strictEqual(JSON.parse(b.stdout).id, a.id);
  const data = JSON.parse(fs.readFileSync(sb.ledger, 'utf8'));
  assert.strictEqual(data.claims.length, 1);
});

test('evidence-ledger: 観測だけで仮説の状態が決まる (推測を混ぜない)', () => {
  const sb = sandbox();
  const hyp = JSON.parse(run(['hypothesis', '--text', '再試行で失敗率が下がる', '--prediction', '失敗率 < 1%'], sb.env).stdout);
  assert.strictEqual(hyp.status, 'open');

  const o1 = JSON.parse(run(['observe', '--hypothesis', hyp.id, '--verdict', 'supports', '--note', 'n=30 で 0 件'], sb.env).stdout);
  assert.strictEqual(o1.status, 'supported');
  run(['observe', '--hypothesis', hyp.id, '--verdict', 'supports'], sb.env);
  const o3 = JSON.parse(run(['observe', '--hypothesis', hyp.id, '--verdict', 'refutes', '--note', 'n=200 で 3 件'], sb.env).stdout);
  assert.strictEqual(o3.status, 'mixed');
  assert.deepStrictEqual(o3.observations, { supports: 2, refutes: 1, inconclusive: 0 });
});

test('evidence-ledger: refutes のみなら refuted になる', () => {
  const sb = sandbox();
  const hyp = JSON.parse(run(['hypothesis', '--text', 'A', '--prediction', 'B'], sb.env).stdout);
  const o = JSON.parse(run(['observe', '--hypothesis', hyp.id, '--verdict', 'refutes'], sb.env).stdout);
  assert.strictEqual(o.status, 'refuted');
});

test('evidence-ledger: 未知の仮説・証拠 ID を拒否する', () => {
  const sb = sandbox();
  assert.strictEqual(run(['observe', '--hypothesis', 'hyp-nope', '--verdict', 'supports'], sb.env).code, 2);
  const hyp = JSON.parse(run(['hypothesis', '--text', 'A', '--prediction', 'B'], sb.env).stdout);
  assert.strictEqual(run(['observe', '--hypothesis', hyp.id, '--verdict', 'supports', '--evidence', 'claim-nope'], sb.env).code, 2);
});

test('evidence-ledger: verify は出所の改変 (sha256 不一致) を検出する', () => {
  const sb = sandbox();
  run(['claim', '--text', 'C', '--source', sb.src], sb.env);
  let v = run(['verify'], sb.env);
  assert.strictEqual(v.code, 0, v.stdout);
  assert.strictEqual(JSON.parse(v.stdout).broken, 0);
  fs.appendFileSync(sb.src, '改変\n');
  v = run(['verify'], sb.env);
  assert.strictEqual(v.code, 1);
  const res = JSON.parse(v.stdout);
  assert.strictEqual(res.broken, 1);
  assert.strictEqual(res.results[0].sha256_match, false);
});

test('evidence-ledger: 秘密情報を含む主張は登録しない', () => {
  const sb = sandbox();
  const r = run(['claim', '--text', 'key は sk-abcdef0123456789ABCDEF である', '--source', sb.src], sb.env);
  assert.strictEqual(r.code, 2);
  assert.strictEqual(fs.existsSync(sb.ledger), false);
});

test('evidence-ledger: brief は引用付きの判断用ブリーフを出力する', () => {
  const sb = sandbox();
  const hyp = JSON.parse(run(['hypothesis', '--text', 'H1', '--prediction', 'P1'], sb.env).stdout);
  run(['observe', '--hypothesis', hyp.id, '--verdict', 'supports'], sb.env);
  run(['claim', '--text', 'C1', '--source', sb.src, '--locator', 'L1'], sb.env);
  const out = path.join(sb.root, 'brief.md');
  const r = run(['brief', '--out', out], sb.env);
  assert.strictEqual(r.code, 0, r.stdout);
  const md = fs.readFileSync(out, 'utf8');
  assert.match(md, /# 証拠ブリーフ/);
  assert.match(md, /\[supported\] H1/);
  assert.match(md, /出所: .*source\.md \(L1\) sha256=/);
  assert.match(md, /C1/);
});
