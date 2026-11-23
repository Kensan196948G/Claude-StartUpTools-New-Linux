#!/usr/bin/env node
'use strict';
/**
 * serve-dashboard.test.js — dashboard の CLAUDEOS_HOME 対応の検証 (P0-1)
 *
 * 背景:
 *   serve-dashboard.js は状態パスを `os.homedir()/.claudeos` にハードコードしていた。
 *   そのため staging dashboard が本番の cron-registry / sessions / job-history /
 *   supervisor state / dashboard.log を共有・上書きしうる状態だった。
 *
 * 検証対象（旧実装の 6 箇所すべて）:
 *   L23  cron-registry.json      → cronRegistry
 *   L24  sessions/               → sessionsDir
 *   L83  job-history.json        → jobHistory
 *   L1244 supervisor/state.json  → supervisorState
 *   L1566 dashboard.log          → dashboardLog
 *   L1586 supervisor/state.json  → supervisorState（watch 用・L1244 と同一パス）
 *
 * 方針:
 *   - CLAUDEOS_HOME 設定時: 読み書きする全パスがその配下になること
 *   - CLAUDEOS_HOME 未設定時: 従来と完全に同一パスになること（回帰）
 *   - 実 ~/.claudeos を汚さないこと（テストは tmp に隔離）
 */

const { test, after } = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const net = require('net');
const http = require('http');
const { execFileSync, spawn } = require('child_process');

const MOD = path.join(__dirname, 'serve-dashboard.js');
const REPO_ROOT = path.resolve(__dirname, '..', '..');

// ── テスト用の隔離された状態ルート（実 ~/.claudeos は使わない）─────────────
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'dash-claudeos-home-test-'));
const HOME = path.join(TMP, 'claudeos');
process.env.CLAUDEOS_HOME = HOME;

// require は副作用（ディレクトリ作成・状態ファイル書き込み）を持たないこと
const HOME_EXISTED_AT_LOAD = fs.existsSync(HOME);

const dash = require('./serve-dashboard.js');

after(() => fs.rmSync(TMP, { recursive: true, force: true }));

// 旧実装と同一の式（未設定時の期待値）
const LEGACY_HOME = path.join(os.homedir(), '.claudeos');
const legacyPaths = {
  home: LEGACY_HOME,
  cronRegistry: path.join(LEGACY_HOME, 'cron-registry.json'),
  sessionsDir: path.join(LEGACY_HOME, 'sessions'),
  jobHistory: path.join(LEGACY_HOME, 'job-history.json'),
  supervisorState: path.join(LEGACY_HOME, 'supervisor', 'state.json'),
  dashboardLog: path.join(LEGACY_HOME, 'dashboard.log'),
};

/** 子プロセスでモジュールを読み、ロード時の状態パスを返す（env を厳密に制御する） */
function loadPathsInChild(claudeosHome) {
  const env = { ...process.env, DASH_MOD: MOD };
  // 親の値を持ち込まない（未設定 = 既定挙動を検証できるようにする）
  delete env.CLAUDEOS_HOME;
  if (claudeosHome !== undefined) env.CLAUDEOS_HOME = claudeosHome;

  const script =
    'const m=require(process.env.DASH_MOD);' +
    'process.stdout.write(JSON.stringify({CLAUDEOS_HOME:m.CLAUDEOS_HOME,paths:m.CLAUDEOS_PATHS}))';
  const out = execFileSync(process.execPath, ['-e', script], { env, encoding: 'utf8' });
  return JSON.parse(out);
}

/** 空きポートを 1 つ確保する（loopback のみ） */
function freePort() {
  return new Promise((resolve, reject) => {
    const srv = net.createServer();
    srv.once('error', reject);
    srv.listen(0, '127.0.0.1', () => {
      const { port } = srv.address();
      srv.close(() => resolve(port));
    });
  });
}

/** /api/health が 200 を返すまで待つ */
function waitHealthy(port, timeoutMs = 10000) {
  const deadline = Date.now() + timeoutMs;
  return new Promise((resolve, reject) => {
    const attempt = () => {
      const req = http.get({ host: '127.0.0.1', port, path: '/api/health', timeout: 1000 }, (res) => {
        let body = '';
        res.on('data', (c) => { body += c; });
        res.on('end', () => {
          if (res.statusCode === 200) { resolve({ status: res.statusCode, body }); return; }
          retry(new Error(`/api/health status=${res.statusCode}`));
        });
      });
      req.on('timeout', () => req.destroy(new Error('health request timeout')));
      req.on('error', retry);
    };
    const retry = (err) => {
      if (Date.now() >= deadline) { reject(err); return; }
      setTimeout(attempt, 150);
    };
    attempt();
  });
}

// ---------------------------------------------------------------------------
// 1) CLAUDEOS_HOME 設定時: 旧実装の 6 箇所すべてが CLAUDEOS_HOME 配下になる
// ---------------------------------------------------------------------------
test('CLAUDEOS_HOME 設定時、状態 5 パス（6 呼び出し箇所）がすべて配下に移る', () => {
  assert.equal(dash.CLAUDEOS_HOME, HOME);

  const expected = {
    cronRegistry: path.join(HOME, 'cron-registry.json'),      // L23
    sessionsDir: path.join(HOME, 'sessions'),                 // L24
    jobHistory: path.join(HOME, 'job-history.json'),          // L83
    supervisorState: path.join(HOME, 'supervisor', 'state.json'), // L1244 / L1586
    dashboardLog: path.join(HOME, 'dashboard.log'),           // L1566
  };

  for (const [key, want] of Object.entries(expected)) {
    assert.equal(dash.CLAUDEOS_PATHS[key], want, `${key} は CLAUDEOS_HOME 配下であること`);
    // 配下判定（前方一致だけでは /home/x/.claudeos-stg を取り違えるため区切りまで見る）
    assert.ok(
      dash.CLAUDEOS_PATHS[key].startsWith(HOME + path.sep),
      `${key} は ${HOME} 配下であること`
    );
  }
  assert.equal(dash.CLAUDEOS_PATHS.home, HOME);
});

test('CLAUDEOS_HOME 設定時、実 ~/.claudeos 配下のパスへフォールバックしない', () => {
  for (const [key, p] of Object.entries(dash.CLAUDEOS_PATHS)) {
    if (key === 'home') continue;
    assert.ok(
      !p.startsWith(LEGACY_HOME + path.sep),
      `${key} が本番状態 (${LEGACY_HOME}) を指している`
    );
  }
});

// ---------------------------------------------------------------------------
// 2) パス解決関数: 任意の home を渡せる（純粋関数・モジュール状態に依存しない）
// ---------------------------------------------------------------------------
test('claudeosPaths(home): 任意の home で全パスがその配下に解決される', () => {
  const other = path.join(TMP, 'staging', '.claudeos-stg');
  const p = dash.claudeosPaths(other);

  assert.equal(p.home, other);
  assert.equal(p.cronRegistry, path.join(other, 'cron-registry.json'));
  assert.equal(p.sessionsDir, path.join(other, 'sessions'));
  assert.equal(p.jobHistory, path.join(other, 'job-history.json'));
  assert.equal(p.supervisorState, path.join(other, 'supervisor', 'state.json'));
  assert.equal(p.dashboardLog, path.join(other, 'dashboard.log'));
  for (const [key, v] of Object.entries(p)) {
    if (key === 'home') continue;
    assert.ok(v.startsWith(other + path.sep), `${key} は渡した home 配下であること`);
  }
});

test('claudeosPaths(): 引数省略時はロード時の CLAUDEOS_HOME を使う', () => {
  assert.deepEqual(dash.claudeosPaths(), dash.CLAUDEOS_PATHS);
});

// ---------------------------------------------------------------------------
// 3) 回帰: CLAUDEOS_HOME 未設定時は従来と完全に同一パス
// ---------------------------------------------------------------------------
test('回帰: CLAUDEOS_HOME 未設定時、全パスが従来の ~/.claudeos と完全一致する', () => {
  const { CLAUDEOS_HOME, paths } = loadPathsInChild(undefined);

  assert.equal(CLAUDEOS_HOME, LEGACY_HOME);
  assert.deepEqual(paths, legacyPaths, '未設定時の既定パスが旧実装から変わっていないこと');
});

test('回帰: 未設定時の既定は旧実装の式 path.join(os.homedir(), ".claudeos", ...) と同値', () => {
  const { paths } = loadPathsInChild(undefined);
  const legacy = {
    cronRegistry: path.join(os.homedir(), '.claudeos', 'cron-registry.json'),
    sessionsDir: path.join(os.homedir(), '.claudeos', 'sessions'),
    jobHistory: path.join(os.homedir(), '.claudeos', 'job-history.json'),
    supervisorState: path.join(os.homedir(), '.claudeos', 'supervisor', 'state.json'),
    dashboardLog: path.join(os.homedir(), '.claudeos', 'dashboard.log'),
  };
  for (const [key, want] of Object.entries(legacy)) {
    assert.equal(paths[key], want, `${key} が旧実装と一致しない`);
  }
});

// ---------------------------------------------------------------------------
// 4) env はモジュールロード時に解決される（設定すれば子プロセスでも効く）
// ---------------------------------------------------------------------------
test('モジュールロード時: CLAUDEOS_HOME を子プロセスでも尊重する', () => {
  const custom = path.join(TMP, 'child-home');
  const { CLAUDEOS_HOME, paths } = loadPathsInChild(custom);

  assert.equal(CLAUDEOS_HOME, custom);
  assert.equal(paths.cronRegistry, path.join(custom, 'cron-registry.json'));
  assert.equal(paths.sessionsDir, path.join(custom, 'sessions'));
  assert.equal(paths.jobHistory, path.join(custom, 'job-history.json'));
  assert.equal(paths.supervisorState, path.join(custom, 'supervisor', 'state.json'));
  assert.equal(paths.dashboardLog, path.join(custom, 'dashboard.log'));
  for (const [key, v] of Object.entries(paths)) {
    if (key === 'home') continue;
    assert.ok(v.startsWith(custom + path.sep), `${key} が CLAUDEOS_HOME 配下でない`);
  }
});

// ---------------------------------------------------------------------------
// 5) 副作用: require だけでは状態ディレクトリを作らない
// ---------------------------------------------------------------------------
test('require しても CLAUDEOS_HOME 配下にファイルを作らない', () => {
  assert.equal(HOME_EXISTED_AT_LOAD, false, 'require 時に状態ディレクトリを作ってはいけない');
  assert.equal(fs.existsSync(HOME), false);
});

// ---------------------------------------------------------------------------
// 6) 起動スモーク: CLAUDEOS_HOME + HOST=127.0.0.1 + 空きポートで /api/health 200
// ---------------------------------------------------------------------------
test('起動スモーク: CLAUDEOS_HOME を指定して loopback で起動し /api/health が 200', { timeout: 30000 }, async () => {
  const port = await freePort();
  const smokeHome = path.join(TMP, 'smoke-home');
  const env = { ...process.env, CLAUDEOS_HOME: smokeHome, HOST: '127.0.0.1' };
  delete env.DASHBOARD_PASSWORD; // auth 無効（/api/health は常に public だが明示する）

  const child = spawn(process.execPath, [MOD, String(port)], {
    cwd: REPO_ROOT,
    env,
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  let stderr = '';
  child.stderr.on('data', (d) => { stderr += d.toString(); });

  try {
    const res = await waitHealthy(port);
    assert.equal(res.status, 200);
    const health = JSON.parse(res.body);
    assert.equal(health.status, 'ok');
    assert.equal(typeof health.uptime, 'number');

    // 起動だけで本番状態を書き換えていないこと（cron-registry / job-history を作らない）
    assert.equal(fs.existsSync(path.join(smokeHome, 'cron-registry.json')), false);
    assert.equal(fs.existsSync(path.join(smokeHome, 'job-history.json')), false);
  } catch (e) {
    throw new Error(`${e.message}\n--- child stderr ---\n${stderr}`);
  } finally {
    child.kill('SIGKILL');
    await new Promise((resolve) => {
      if (child.exitCode !== null) { resolve(); return; }
      child.once('exit', resolve);
      setTimeout(resolve, 2000);
    });
  }
});
