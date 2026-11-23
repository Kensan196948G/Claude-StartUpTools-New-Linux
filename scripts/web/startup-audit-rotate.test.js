#!/usr/bin/env node
'use strict';
/**
 * startup-audit-rotate.test.js — 監査ログのローテーション（サイズ上限＋世代管理）の検証
 *
 * 検証対象:
 *   1) 閾値以上で <log> → <log>.1 へ rename される（内容は変えない）
 *   2) 既存世代が .1 → .2 → .3 へシフトし、keep 世代を超えるものは削除される
 *   3) 閾値未満・ファイル不在では回転しない
 *   4) keep=0 は履歴を残さず切り詰める
 *   5) 回転に失敗しても throw しない（fail-open）
 *   6) appendAudit が env の閾値で回転しつつ「1 リクエスト 1 行」を維持する
 *   7) 既定値は 5 MiB / 3 世代（env で上書き可）
 *
 * 隔離: CLAUDEOS_HOME は一時ディレクトリへ向ける（実 ~/.claudeos は触らない）。
 *       ファイル操作のテストは CLAUDEOS_HOME 配下のケース別ディレクトリで行う。
 */

const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');

const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'startup-audit-rotate-test-'));
// モジュール読み込み前に隔離する (AUDIT_LOG は require 時に確定する)
process.env.CLAUDEOS_HOME = path.join(TMP, 'claudeos');
const LOG_DIR = path.join(process.env.CLAUDEOS_HOME, 'logs');
const AUDIT_LOG = path.join(LOG_DIR, 'web-startup-audit.log');
fs.mkdirSync(LOG_DIR, { recursive: true });

const srv = require('./startup-server.js');

process.on('exit', () => {
  try { fs.chmodSync(LOG_DIR, 0o755); } catch { /* 既に消えている等 */ }
  try { fs.rmSync(TMP, { recursive: true, force: true }); } catch { /* best-effort */ }
});

let seq = 0;
/** caseDir — ケースごとの作業ディレクトリ */
function caseDir() {
  const d = path.join(TMP, 'case-' + (++seq));
  fs.mkdirSync(d, { recursive: true });
  return d;
}

/** logPath — ケース別の監査ログパス */
function logPath() {
  return path.join(caseDir(), 'web-startup-audit.log');
}

function readLines(file) {
  return fs.readFileSync(file, 'utf8').split('\n').filter(Boolean);
}

// ---------------------------------------------------------------------------
// 1) 設定 (既定値 / env 上書き)
// ---------------------------------------------------------------------------

test('auditRotateConfig: 既定は 5 MiB / 3 世代、env で上書きできる', () => {
  assert.deepEqual(srv.auditRotateConfig({}), { maxBytes: 5 * 1024 * 1024, keep: 3 });
  assert.deepEqual(
    srv.auditRotateConfig({ STARTUP_WEB_AUDIT_MAX_BYTES: '1024', STARTUP_WEB_AUDIT_KEEP: '5' }),
    { maxBytes: 1024, keep: 5 });
  // 不正値は既定へフォールバックする (設定ミスで監査を止めない)
  assert.deepEqual(
    srv.auditRotateConfig({ STARTUP_WEB_AUDIT_MAX_BYTES: 'abc', STARTUP_WEB_AUDIT_KEEP: '-1' }),
    { maxBytes: 5 * 1024 * 1024, keep: 3 });
  // keep=0 は「履歴を残さない」として許可する
  assert.equal(srv.auditRotateConfig({ STARTUP_WEB_AUDIT_KEEP: '0' }).keep, 0);
  // 極端な値は上限 100 世代に丸める (設定ミスで回転ループを暴走させない)
  assert.equal(srv.auditRotateConfig({ STARTUP_WEB_AUDIT_KEEP: '1000000' }).keep, 100);
});

// ---------------------------------------------------------------------------
// 2) 回転そのもの
// ---------------------------------------------------------------------------

test('閾値以上なら .1 へ rename する (内容は変えない)', () => {
  const log = logPath();
  fs.writeFileSync(log, 'x'.repeat(200));

  const r = srv.rotateAuditLog(log, { maxBytes: 100, keep: 3 });
  assert.deepEqual(r, { rotated: true, reason: 'rotated' });
  assert.equal(fs.existsSync(log), false, '無印ファイルは .1 へ移る');
  assert.equal(fs.statSync(log + '.1').size, 200, '内容・サイズは保たれる');
  assert.equal(fs.existsSync(log + '.2'), false);
});

test('既存世代は .1 → .2 → .3 へシフトする', () => {
  const log = logPath();
  fs.writeFileSync(log, 'x'.repeat(10));
  fs.writeFileSync(log + '.1', 'g1\n');
  fs.writeFileSync(log + '.2', 'g2\n');

  const r = srv.rotateAuditLog(log, { maxBytes: 10, keep: 3 });   // 10 >= 10 で回転
  assert.equal(r.rotated, true);
  assert.equal(fs.readFileSync(log + '.1', 'utf8'), 'x'.repeat(10));
  assert.equal(fs.readFileSync(log + '.2', 'utf8'), 'g1\n', '旧 .1 は .2 へ');
  assert.equal(fs.readFileSync(log + '.3', 'utf8'), 'g2\n', '旧 .2 は .3 へ');
});

test('keep 世代を超える古い世代は削除される (最大 keep 世代)', () => {
  const log = logPath();
  fs.writeFileSync(log, 'x'.repeat(100));
  fs.writeFileSync(log + '.1', 'g1\n');
  fs.writeFileSync(log + '.2', 'g2\n');
  fs.writeFileSync(log + '.3', 'g3\n');

  const r = srv.rotateAuditLog(log, { maxBytes: 50, keep: 2 });
  assert.equal(r.rotated, true);
  assert.equal(fs.readFileSync(log + '.1', 'utf8'), 'x'.repeat(100));
  assert.equal(fs.readFileSync(log + '.2', 'utf8'), 'g1\n');
  assert.equal(fs.existsSync(log + '.3'), false, 'keep=2 を超える .3 は残らない');
});

test('keep が減った設定でも余剰世代を掃除する (keep=1)', () => {
  const log = logPath();
  fs.writeFileSync(log, 'x'.repeat(10));
  fs.writeFileSync(log + '.1', 'g1\n');
  fs.writeFileSync(log + '.2', 'g2\n');
  fs.writeFileSync(log + '.3', 'g3\n');

  const r = srv.rotateAuditLog(log, { maxBytes: 10, keep: 1 });
  assert.equal(r.rotated, true);
  assert.equal(fs.readFileSync(log + '.1', 'utf8'), 'x'.repeat(10));
  assert.equal(fs.existsSync(log + '.2'), false);
  assert.equal(fs.existsSync(log + '.3'), false);
});

test('閾値未満では回転しない', () => {
  const log = logPath();
  fs.writeFileSync(log, 'x'.repeat(99));

  const r = srv.rotateAuditLog(log, { maxBytes: 100, keep: 3 });
  assert.deepEqual(r, { rotated: false, reason: 'below-threshold' });
  assert.equal(fs.statSync(log).size, 99);
  assert.equal(fs.existsSync(log + '.1'), false);
});

test('ファイルが無ければ回転せず、ファイルも作らない', () => {
  const log = logPath();
  const r = srv.rotateAuditLog(log, { maxBytes: 1, keep: 3 });
  assert.deepEqual(r, { rotated: false, reason: 'absent' });
  assert.equal(fs.existsSync(log), false);
  assert.equal(fs.existsSync(log + '.1'), false);
});

test('keep=0 は履歴を残さず切り詰める', () => {
  const log = logPath();
  fs.writeFileSync(log, 'x'.repeat(200));

  const r = srv.rotateAuditLog(log, { maxBytes: 100, keep: 0 });
  assert.deepEqual(r, { rotated: true, reason: 'truncated' });
  assert.equal(fs.statSync(log).size, 0);
  assert.equal(fs.existsSync(log + '.1'), false);
});

test('回転に失敗しても throw しない (書き込み不可ディレクトリ・fail-open)', () => {
  const dir = caseDir();
  const log = path.join(dir, 'web-startup-audit.log');
  fs.writeFileSync(log, 'x'.repeat(200));

  fs.chmodSync(dir, 0o555);   // rename には書き込み権限が要る
  let r;
  try {
    r = srv.rotateAuditLog(log, { maxBytes: 100, keep: 3 });
  } finally {
    fs.chmodSync(dir, 0o755);
  }

  if (process.getuid && process.getuid() !== 0) {
    assert.equal(r.rotated, false);
    assert.equal(r.reason, 'rename-failed');
    assert.equal(fs.statSync(log).size, 200, '元ファイルはそのまま残る');
  } else {
    // root は権限で失敗させられないため、契約 (throw しない/真偽値を返す) だけ確認する
    assert.equal(typeof r.rotated, 'boolean');
  }
});

// ---------------------------------------------------------------------------
// 3) appendAudit (env 駆動・1 リクエスト 1 行)
// ---------------------------------------------------------------------------

test('appendAudit: env の閾値で回転し、1 回 1 行を維持する', () => {
  const prevMax = process.env.STARTUP_WEB_AUDIT_MAX_BYTES;
  const prevKeep = process.env.STARTUP_WEB_AUDIT_KEEP;
  process.env.STARTUP_WEB_AUDIT_MAX_BYTES = '1';   // 1 行 (数十バイト) で即回転
  process.env.STARTUP_WEB_AUDIT_KEEP = '2';
  try {
    fs.rmSync(AUDIT_LOG, { force: true });
    for (const n of [1, 2, 3]) fs.rmSync(AUDIT_LOG + '.' + n, { force: true });

    srv.appendAudit({ action: 'rotate-test', n: 1 });
    assert.equal(readLines(AUDIT_LOG).length, 1, '1 回の追記で 1 行');

    srv.appendAudit({ action: 'rotate-test', n: 2 });
    const lines = readLines(AUDIT_LOG);
    assert.equal(lines.length, 1, '回転後も 1 回 1 行 (追記は続く)');
    assert.equal(JSON.parse(lines[0]).n, 2, '新しい行が無印ファイルに入る');
    assert.equal(readLines(AUDIT_LOG + '.1').length, 1, '直前の 1 行は .1 に残る');
    assert.equal(JSON.parse(readLines(AUDIT_LOG + '.1')[0]).n, 1);

    srv.appendAudit({ action: 'rotate-test', n: 3 });
    assert.equal(readLines(AUDIT_LOG + '.1').length, 1);
    assert.equal(readLines(AUDIT_LOG + '.2').length, 1, '2 世代目まで残る');
    assert.equal(fs.existsSync(AUDIT_LOG + '.3'), false, 'keep=2 を超える世代は作らない');
  } finally {
    if (prevMax === undefined) delete process.env.STARTUP_WEB_AUDIT_MAX_BYTES;
    else process.env.STARTUP_WEB_AUDIT_MAX_BYTES = prevMax;
    if (prevKeep === undefined) delete process.env.STARTUP_WEB_AUDIT_KEEP;
    else process.env.STARTUP_WEB_AUDIT_KEEP = prevKeep;
  }
});

test('appendAudit: 追記できない状況でも throw せず stderr に 1 行だけ出す', (t) => {
  if (process.getuid && process.getuid() === 0) {
    t.skip('root ではファイル権限で追記を失敗させられない');
    return;
  }
  fs.rmSync(AUDIT_LOG, { force: true });
  for (const n of [1, 2, 3]) fs.rmSync(AUDIT_LOG + '.' + n, { force: true });
  srv.appendAudit({ action: 'before-block' });
  const before = fs.readFileSync(AUDIT_LOG, 'utf8');

  // 既存ファイルへの追記はディレクトリではなくファイルの書き込み権限で決まる
  fs.chmodSync(AUDIT_LOG, 0o444);
  const origWrite = process.stderr.write;
  const warns = [];
  process.stderr.write = (chunk) => { warns.push(String(chunk)); return true; };
  try {
    assert.doesNotThrow(() => srv.appendAudit({ action: 'blocked' }));
  } finally {
    process.stderr.write = origWrite;
    fs.chmodSync(AUDIT_LOG, 0o644);
  }
  assert.equal(warns.length, 1, 'stderr へ 1 行だけ (握りつぶさない)');
  assert.match(warns[0], /追記できません/);
  assert.equal(fs.readFileSync(AUDIT_LOG, 'utf8'), before, '書けなかったので内容は変わらない');

  srv.appendAudit({ action: 'after-restore' });
  assert.match(fs.readFileSync(AUDIT_LOG, 'utf8'), /after-restore/, '復旧後は追記できる');
});
