#!/usr/bin/env node
'use strict';
/**
 * serve-dashboard-health.test.js — dashboard /api/health の commit / version の検証
 *
 * 検証対象:
 *   1) resolveBuildInfo の commit 解決順 (env.GIT_COMMIT → 実行ルートの manifest.json → "")
 *      - env 優先 / manifest フォールバック / どちらも無い / 不正 manifest
 *      - git コマンドは実行しない (release 成果物には .git が無い)
 *   2) 実際に dashboard を起動したときの /api/health が commit/version を返すこと
 *      (既存キー status/uptime/trust/at も維持されること)
 *
 * 隔離: CLAUDEOS_HOME は一時ディレクトリへ向け、実 ~/.claudeos を読み書きしない。
 *       統合テストは空きポート・HOST=127.0.0.1 で子プロセスを起動し、終了時に kill する。
 *       (本番 3737 / staging 3743 には触れない)
 */

const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const http = require('http');
const net = require('net');
const { spawn } = require('child_process');

const REPO_ROOT = path.resolve(__dirname, '..', '..');
const MOD = path.join(__dirname, 'serve-dashboard.js');
const pkg = require(path.join(REPO_ROOT, 'package.json'));

const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'dashboard-health-test-'));
// モジュール読み込み前に隔離する (load 時の既定パスが実ホームを指さないように)
process.env.CLAUDEOS_HOME = path.join(TMP, 'claudeos');

const dash = require('./serve-dashboard.js');

process.on('exit', () => {
  try { fs.rmSync(TMP, { recursive: true, force: true }); } catch { /* best-effort */ }
});

// 40 桁 SHA (git の完全 SHA と同じ表現)
const ENV_SHA = '3333333333333333333333333333333333333333';
const MANIFEST_SHA = '4444444444444444444444444444444444444444';

/** mkRoot — テスト用の実行ルートを作る (manifest / package.json は任意) */
function mkRoot(name, opts) {
  const o = opts || {};
  const root = path.join(TMP, name);
  fs.mkdirSync(root, { recursive: true });
  if (o.manifest !== undefined) {
    fs.writeFileSync(path.join(root, 'manifest.json'),
      typeof o.manifest === 'string' ? o.manifest : JSON.stringify(o.manifest));
  }
  if (o.version !== undefined) {
    fs.writeFileSync(path.join(root, 'package.json'), JSON.stringify({ name: 'fixture', version: o.version }));
  }
  return root;
}

/** freePort — loopback の空きポートを 1 つ確保する */
function freePort() {
  return new Promise((resolve, reject) => {
    const s = net.createServer();
    s.once('error', reject);
    s.listen(0, '127.0.0.1', () => {
      const { port } = s.address();
      s.close(() => resolve(port));
    });
  });
}

/** waitHealthy — /api/health が 200 を返すまで待つ */
function waitHealthy(port, timeoutMs = 10000) {
  const deadline = Date.now() + timeoutMs;
  return new Promise((resolve, reject) => {
    const retry = (err) => {
      if (Date.now() >= deadline) { reject(err); return; }
      setTimeout(attempt, 150);
    };
    const attempt = () => {
      const req = http.get({ host: '127.0.0.1', port, path: '/api/health', timeout: 1000 }, (res) => {
        let body = '';
        res.on('data', (c) => { body += c; });
        res.on('end', () => {
          if (res.statusCode === 200) { resolve({ statusCode: res.statusCode, body }); return; }
          retry(new Error('/api/health status=' + res.statusCode));
        });
      });
      req.on('timeout', () => req.destroy(new Error('health request timeout')));
      req.on('error', retry);
    };
    attempt();
  });
}

// ---------------------------------------------------------------------------
// 1) 純関数: commit の解決順
// ---------------------------------------------------------------------------

test('resolveBuildInfo: env.GIT_COMMIT があれば manifest より優先する', () => {
  const root = mkRoot('env-first', { manifest: { commit: MANIFEST_SHA }, version: '9.9.9-test' });
  assert.deepEqual(dash.resolveBuildInfo({ root, env: { GIT_COMMIT: ENV_SHA } }),
    { commit: ENV_SHA, version: '9.9.9-test' });
  // 大文字の SHA も正規化して返す
  assert.equal(dash.resolveBuildInfo({ root, env: { GIT_COMMIT: ENV_SHA.toUpperCase() } }).commit, ENV_SHA);
});

test('resolveBuildInfo: env が無ければ実行ルートの manifest.json の commit を使う', () => {
  const root = mkRoot('manifest-fallback', {
    manifest: { schema_version: 1, commit: MANIFEST_SHA, file_count: 1 },
    version: '1.2.3',
  });
  assert.equal(dash.resolveBuildInfo({ root, env: {} }).commit, MANIFEST_SHA);
  // 空文字・空白だけの env は「無い」と同じ扱い
  assert.equal(dash.resolveBuildInfo({ root, env: { GIT_COMMIT: '   ' } }).commit, MANIFEST_SHA);
});

test('resolveBuildInfo: env も manifest も無ければ commit/version は空文字 (例外を投げない)', () => {
  const root = mkRoot('nothing', { version: '0.0.0' });
  const info = dash.resolveBuildInfo({ root, env: {} });
  assert.equal(info.commit, '');
  assert.equal(info.version, '0.0.0');

  // ルート自体が存在しない場合も空文字
  assert.deepEqual(dash.resolveBuildInfo({ root: path.join(TMP, 'no-such-dir'), env: {} }),
    { commit: '', version: '' });
  // 引数なしでも例外にしない
  assert.deepEqual(dash.resolveBuildInfo(), { commit: '', version: '' });
});

test('resolveBuildInfo: manifest が壊れている/形が違う場合は空文字 (不正 env は manifest へ)', () => {
  // JSON として壊れている
  const broken = mkRoot('broken-json', { manifest: '{"commit": ' });
  assert.equal(dash.resolveBuildInfo({ root: broken, env: {} }).commit, '');
  // commit が 40 桁 SHA でない (短縮 SHA)
  const shortSha = mkRoot('short-sha', { manifest: { commit: 'abc1234' } });
  assert.equal(dash.resolveBuildInfo({ root: shortSha, env: {} }).commit, '');
  // commit キーが無い
  const noCommit = mkRoot('no-commit', { manifest: { schema_version: 1 } });
  assert.equal(dash.resolveBuildInfo({ root: noCommit, env: {} }).commit, '');
  // 不正な env.GIT_COMMIT は「無い」ものとして manifest へフォールバックする
  const fallback = mkRoot('bad-env', { manifest: { commit: MANIFEST_SHA } });
  assert.equal(dash.resolveBuildInfo({ root: fallback, env: { GIT_COMMIT: 'deadbeef' } }).commit, MANIFEST_SHA);
});

// ---------------------------------------------------------------------------
// 2) 統合: 実際に dashboard を起動して /api/health を見る
// ---------------------------------------------------------------------------

test('/api/health: 起動した dashboard が commit と version を返す (既存キーも維持)', { timeout: 30000 }, async () => {
  const port = await freePort();
  const env = {
    ...process.env,
    CLAUDEOS_HOME: path.join(TMP, 'smoke-home'),
    HOST: '127.0.0.1',
    GIT_COMMIT: ENV_SHA,
  };
  delete env.DASHBOARD_PASSWORD;   // health は常に public だが、認証有効時の挙動を持ち込まない

  const child = spawn(process.execPath, [MOD, String(port)], {
    cwd: REPO_ROOT, env, stdio: ['ignore', 'pipe', 'pipe'],
  });
  let stderr = '';
  child.stderr.on('data', (d) => { stderr += d.toString(); });
  child.stdout.on('data', () => { /* 起動ログは読み捨てる (パイプ詰まり防止) */ });

  try {
    const res = await waitHealthy(port);
    assert.equal(res.statusCode, 200);
    const health = JSON.parse(res.body);

    // 追加キー
    assert.equal(health.commit, ENV_SHA);
    assert.equal(health.version, pkg.version);
    assert.equal(typeof health.commit, 'string');
    assert.equal(typeof health.version, 'string');

    // 既存キー (後方互換)
    assert.equal(health.status, 'ok');
    assert.equal(typeof health.uptime, 'number');
    assert.equal(typeof health.trust, 'object');
    assert.equal(typeof health.at, 'string');
    assert.ok(!Number.isNaN(Date.parse(health.at)), 'at は ISO8601 として解釈できる');
  } catch (e) {
    throw new Error(e.message + '\n--- child stderr ---\n' + stderr);
  } finally {
    child.kill('SIGKILL');
    await new Promise((resolve) => {
      if (child.exitCode !== null) { resolve(); return; }
      child.once('exit', resolve);
      setTimeout(resolve, 2000);
    });
  }
});
