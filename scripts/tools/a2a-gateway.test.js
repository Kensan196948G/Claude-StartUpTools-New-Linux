'use strict';
const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { loadOrCreateToken, timingSafeEqualStr, tokenPath, RUN_ID_RE } = require('./a2a-gateway.js');

function withIsolatedStateDir(fn) {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'a2a-state-'));
  const prevEnv = process.env.CCSU_CONTROL_STATE_DIR;
  process.env.CCSU_CONTROL_STATE_DIR = tmp;
  try {
    fn(tmp);
  } finally {
    if (prevEnv === undefined) delete process.env.CCSU_CONTROL_STATE_DIR; else process.env.CCSU_CONTROL_STATE_DIR = prevEnv;
    fs.rmSync(tmp, { recursive: true, force: true });
  }
}

test('loadOrCreateToken: 初回はトークンを生成し 0600 で保存する', () => {
  withIsolatedStateDir((tmp) => {
    const token = loadOrCreateToken();
    assert.match(token, /^[0-9a-f]{64}$/);
    const stat = fs.statSync(tokenPath());
    assert.strictEqual(stat.mode & 0o777, 0o600);
  });
});

test('loadOrCreateToken: 2回目は同じトークンを読み戻す (再生成しない)', () => {
  withIsolatedStateDir(() => {
    const t1 = loadOrCreateToken();
    const t2 = loadOrCreateToken();
    assert.strictEqual(t1, t2);
  });
});

test('timingSafeEqualStr: 一致する文字列は true', () => {
  assert.strictEqual(timingSafeEqualStr('abc123', 'abc123'), true);
});
test('timingSafeEqualStr: 不一致は false', () => {
  assert.strictEqual(timingSafeEqualStr('abc123', 'abc124'), false);
});
test('timingSafeEqualStr: 長さが違っても例外を投げず false を返す', () => {
  assert.strictEqual(timingSafeEqualStr('short', 'a-much-longer-token-value'), false);
});
test('timingSafeEqualStr: 空文字列同士も安全に処理する', () => {
  assert.strictEqual(timingSafeEqualStr('', ''), true);
});

test('RUN_ID_RE: 通常の UUID / 識別子を許可する', () => {
  assert.ok(RUN_ID_RE.test('11111111-1111-1111-1111-111111111111'));
  assert.ok(RUN_ID_RE.test('run_stub-id'));
});
test('RUN_ID_RE: パス区切りやインジェクション的な文字列を拒否する', () => {
  assert.ok(!RUN_ID_RE.test('../../etc/passwd'));
  assert.ok(!RUN_ID_RE.test('a/b'));
  assert.ok(!RUN_ID_RE.test("x'; DROP TABLE control.runs; --"));
  assert.ok(!RUN_ID_RE.test(''));
});
