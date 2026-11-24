'use strict';
// Local Quality Engine: 隔離・SHA 固定・判定・封印 (bwrap が使える環境では実際に隔離実行する)
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { tmpHome, testPolicy } = require('./helpers');

tmpHome();
const store = require('../lib/store');
const quality = require('../lib/quality');

function mkRepo(files) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'qrepo-'));
  const g = (...a) => spawnSync('git', a, { cwd: dir, encoding: 'utf8' });
  g('init', '-q', '-b', 'main'); g('config', 'user.email', 't@t'); g('config', 'user.name', 't');
  for (const [f, c] of Object.entries(files)) { fs.mkdirSync(path.dirname(path.join(dir, f)), { recursive: true }); fs.writeFileSync(path.join(dir, f), c); }
  g('add', '.'); g('commit', '-qm', 'c1');
  return { dir, head: g('rev-parse', 'HEAD').stdout.trim(), g };
}
function pol(checks) {
  return testPolicy({ quality: { profiles: { t: { checks } }, checkTimeoutSec: 60 } });
}
const ISO = quality.isolationAvailable();

test('parseCounts: bats と node --test の TAP から件数を出す', () => {
  assert.deepEqual(quality.parseCounts('ok 1 a\nok 2 b\nnot ok 3 c\n'), { passed: 2, failed: 1, skipped: 0 });
  assert.deepEqual(quality.parseCounts('ok 1 a # skip x\nok 2 b\n'), { passed: 1, failed: 0, skipped: 1 });
  const mixed = 'ok 1 bats\nok 2 bats\nok 1 - node\n# pass 1\n# fail 0\n# skipped 0\n';
  assert.deepEqual(quality.parseCounts(mixed), { passed: 3, failed: 0, skipped: 0 });
  assert.equal(quality.parseCounts('no tap here'), null);
});

test('sandboxArgv: ネットワーク遮断・HOME 隠蔽・clearenv・ro root を必ず含む', () => {
  const a = quality.sandboxArgv(['npm', 'test'], { workDir: '/w', home: '/home/u', env: { PATH: '/usr/bin' } });
  for (const f of ['--unshare-net', '--clearenv', '--die-with-parent', '--unshare-pid']) assert.ok(a.includes(f), f);
  assert.deepEqual(a.slice(0, 3), ['--ro-bind', '/', '/']);
  const i = a.indexOf('--tmpfs', a.indexOf('/tmp')); assert.equal(a[i + 1], '/home/u');
  assert.ok(!a.join(' ').includes('GITHUB_TOKEN'));
  // Actions ランナー相当の非機密変数 (USER 等) は渡す。set -u のスクリプトが落ちないように
  for (const k of ['USER', 'LOGNAME', 'SHELL', 'CI']) assert.ok(a.includes(k), k);
  assert.deepEqual(a.slice(-3), ['--', 'npm', 'test']);
});

test('prepareCheckout: 指定 SHA に detach し、古い SHA でもその SHA を取り出す', () => {
  const r = mkRepo({ 'a.txt': '1' });
  fs.writeFileSync(path.join(r.dir, 'a.txt'), '2'); r.g('commit', '-qam', 'c2');
  const work = fs.mkdtempSync(path.join(os.tmpdir(), 'qwork-'));
  const d = quality.prepareCheckout(r.dir, r.head, work);
  assert.equal(fs.readFileSync(path.join(d, 'a.txt'), 'utf8'), '1');
  assert.throws(() => quality.prepareCheckout(r.dir, 'f'.repeat(40), work), /CHECKOUT_FAILED/);
  assert.throws(() => quality.prepareCheckout(r.dir, 'HEAD', work), /INVALID_SHA/);
});

test('isolation が使えないとき allowUnisolated=false なら実行せず UNKNOWN (fail-closed)', { skip: ISO ? false : 'bwrap 不可環境では別テストで検証' }, () => {
  // bwrap を PATH から外した状態を再現
  const r = mkRepo({ 'x': '1' });
  const savedPath = process.env.PATH;
  const fake = fs.mkdtempSync(path.join(os.tmpdir(), 'nobw-'));
  fs.writeFileSync(path.join(fake, 'bwrap'), '#!/bin/sh\nexit 1\n', { mode: 0o755 });
  process.env.PATH = fake + ':' + savedPath;
  try {
    const rec = quality.runQuality({ repo: 'o/r', repoDir: r.dir, headSha: r.head, policy: pol([{ id: 'ok', category: 'unit', cmd: ['true'] }]), profile: 't' });
    assert.equal(rec.verdict, 'UNKNOWN');
    assert.equal(rec.checks.length, 0);
    assert.match(rec.reasons[0], /ISOLATION_UNAVAILABLE/);
  } finally { process.env.PATH = savedPath; }
});

test('隔離実行: 成功 → PASS、証跡は封印され HMAC 検証に通る', { skip: !ISO && 'bwrap 不可' }, () => {
  const r = mkRepo({ 'ok.sh': 'echo ok 1 - a\necho ok 2 - b\n' });
  const rec = quality.runQuality({ repo: 'o/r', repoDir: r.dir, headSha: r.head, pr: 1, policy: pol([{ id: 'u', category: 'unit', cmd: ['bash', 'ok.sh'], parser: 'tap' }]), profile: 't' });
  assert.equal(rec.verdict, 'PASS', JSON.stringify(rec.checks));
  assert.equal(rec.checks[0].passed, 2);
  assert.match(rec.isolation, /bwrap/);
  assert.equal(quality.verifySeal(rec).ok, true);
  assert.equal(quality.latestEvidence('o/r', r.head).evidence.eval_id, rec.eval_id);
});

test('隔離実行: 失敗は FAIL / exit 0 でも not ok があれば FAIL (assertion 見逃し防止)', { skip: !ISO && 'bwrap 不可' }, () => {
  const r = mkRepo({ 'f.sh': 'exit 3\n', 'lie.sh': 'echo "ok 1 a"; echo "not ok 2 b"; exit 0\n' });
  const rec = quality.runQuality({ repo: 'o/r', repoDir: r.dir, headSha: r.head, policy: pol([
    { id: 'f', category: 'unit', cmd: ['bash', 'f.sh'] }, { id: 'lie', category: 'unit', cmd: ['bash', 'lie.sh'], parser: 'tap' }]), profile: 't' });
  assert.equal(rec.verdict, 'FAIL');
  assert.equal(rec.checks[0].exit_code, 3);
  assert.equal(rec.checks[1].status, 'FAIL');
  assert.equal(rec.checks[1].reason, 'FAILED_COUNT_NONZERO');
});

test('隔離実行: テストコードからネットワーク・HOME の認証情報・ship home (証跡/鍵) に届かない', { skip: !ISO && 'bwrap 不可' }, () => {
  const probe = [
    'set +e',
    'test -e "$HOME/.config/gh" && echo LEAK_GH',
    'test -e "$HOME/.claude" && echo LEAK_CLAUDE',
    `test -e "${store.shipHome()}/keys" && echo LEAK_SHIPHOME_VISIBLE`,
    // 書けても sandbox 内の使い捨て tmpfs に入るだけ。実ファイルが出来ないことをホスト側で確認する
    `echo x > "${store.shipHome()}/pwn" 2>/dev/null && echo TMPFS_WRITE_ONLY`,
    'env | grep -E "GITHUB_TOKEN|GH_TOKEN|ANTHROPIC" && echo LEAK_ENV',
    '(exec 3<>/dev/tcp/1.1.1.1/443) 2>/dev/null && echo LEAK_NET',
    'echo PROBE_DONE',
  ].join('\n');
  // ship home の鍵を事前に作っておく (見えたら漏洩)
  quality.seal({ a: 1 });
  const r = mkRepo({ 'probe.sh': probe });
  process.env.GITHUB_TOKEN = 'ghp_' + 'Z'.repeat(36);
  const keep = process.env.CLAUDEOS_SHIP_KEEP_WORK; process.env.CLAUDEOS_SHIP_KEEP_WORK = '';
  const rec = quality.runQuality({ repo: 'o/r', repoDir: r.dir, headSha: r.head, policy: pol([{ id: 'p', category: 'security', cmd: ['bash', 'probe.sh'] }]), profile: 't' });
  delete process.env.GITHUB_TOKEN; if (keep !== undefined) process.env.CLAUDEOS_SHIP_KEEP_WORK = keep;
  const log = fs.readFileSync(path.join(store.shipHome(), rec.checks[0].log_file), 'utf8');
  assert.match(log, /PROBE_DONE/);
  assert.doesNotMatch(log, /LEAK_/);
  // HOME 配下に ship home がある実運用でも隠れる (ここではテスト用 /tmp 配下なので可視性はスキップせず ro を確認)
  assert.equal(fs.existsSync(path.join(store.shipHome(), 'pwn')), false);
});

test('隔離実行: チェックがリポジトリの HEAD を動かしたら UNKNOWN', { skip: !ISO && 'bwrap 不可' }, () => {
  const r = mkRepo({ 'mv.sh': 'git -c user.email=a@a -c user.name=a commit -q --allow-empty -m x\n' });
  const rec = quality.runQuality({ repo: 'o/r', repoDir: r.dir, headSha: r.head, policy: pol([{ id: 'm', category: 'unit', cmd: ['bash', 'mv.sh'] }]), profile: 't' });
  assert.equal(rec.verdict, 'UNKNOWN');
  assert.ok(rec.reasons.includes('HEAD_MOVED_DURING_RUN'));
});

test('シークレット検査: 差分パッチ (履歴) に入った秘密も検出する。ログに値を残さない', { skip: (!ISO || spawnSync('bash', ['-c', 'command -v trivy']).status !== 0) && 'bwrap/trivy 不可' }, () => {
  const tok = 'ghp_' + 'Q1w2E3r4T5y6U7i8O9p0A1s2D3f4G5h6J7k8';
  const r = mkRepo({ 'readme.txt': 'hello' });
  const base = r.head;
  fs.writeFileSync(path.join(r.dir, 'cfg.txt'), `token=${tok}\n`); r.g('add', '.'); r.g('commit', '-qm', 'add');
  fs.rmSync(path.join(r.dir, 'cfg.txt')); r.g('commit', '-qam', 'remove'); // ツリーからは消えたが履歴に残る
  const head = r.g('rev-parse', 'HEAD').stdout.trim();
  const rec = quality.runQuality({ repo: 'o/r', repoDir: r.dir, headSha: head, baseSha: base, policy: pol([{ id: 's', category: 'secrets', cmd: ['@secrets'] }]), profile: 't' });
  assert.equal(rec.checks[0].status, 'FAIL', JSON.stringify(rec.checks[0]));
  assert.equal(rec.verdict, 'FAIL');
  const log = fs.readFileSync(path.join(store.shipHome(), rec.checks[0].log_file), 'utf8');
  assert.doesNotMatch(log, new RegExp(tok));
  assert.match(log, /target=tree exit=0 findings=0/); // ツリーからは消えている
  assert.match(log, /target=base\.\.head patch exit=1 findings=2/); // 追加行と削除行の 2 箇所
  assert.match(log, /^range\.patch:\d+ github-pat$/m);
});

test('未知のプロファイル / 不正 SHA は拒否', () => {
  assert.throws(() => quality.runQuality({ repo: 'o/r', repoDir: '/x', headSha: 'a'.repeat(40), policy: pol([]), profile: 'nope' }), /UNKNOWN_PROFILE/);
  assert.throws(() => quality.runQuality({ repo: 'o/r', repoDir: '/x', headSha: 'zz', policy: pol([]), profile: 't' }), /INVALID_HEAD/);
});
