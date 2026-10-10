#!/usr/bin/env node
'use strict';
/**
 * startup-server.test.js — Web スタートアップコンソールの検証
 *
 * 検証対象:
 *   1) 入力検証 (allowlist / モード / Goal / 分数 / intent 正規化) — シェル注入・任意実行の遮断
 *   2) CLI 引数組み立て (bin/start-claude.sh / bin/autonomy.sh との契約)
 *   3) ログ閲覧パス / 静的配信パスのトラバーサル防止
 *   4) HTTP 統合: state / plan / launch (Human Gate) / stop / apply-all / 静的配信 / 認証 / Origin
 */

const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const http = require('http');

const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'startup-web-test-'));
process.env.CLAUDEOS_HOME = path.join(TMP, 'claudeos');
fs.mkdirSync(path.join(process.env.CLAUDEOS_HOME, 'logs'), { recursive: true });

const srv = require('./startup-server.js');

const GOALS = {
  primary: [{ name: 'development', label_ja: '開発' }, { name: 'deep-debug', label_ja: '詳細デバッグ' }],
  specialized: [{ name: 'hotfix', label_ja: '緊急修正' }],
};
const LIMITS = { max_sessions: 4, max_session_minutes: 300, default_session_minutes: 300, foreground_minutes: 0 };
const ALLOWED = ['Alpha-App', 'Mirai-DX-Project/Beta-Site'];

// ---------------------------------------------------------------------------
// 1) 入力検証
// ---------------------------------------------------------------------------
test('validateProject: allowlist 内のみ許可', () => {
  assert.equal(srv.validateProject('Alpha-App', ALLOWED).ok, true);
  assert.equal(srv.validateProject('Unknown', ALLOWED).error, 'PROJECT_NOT_REGISTERED');
  assert.equal(srv.validateProject('-rf', ALLOWED).error, 'PROJECT_INVALID');
  assert.equal(srv.validateProject('Alpha-App; rm -rf /', ALLOWED).error, 'PROJECT_NOT_REGISTERED');
  assert.equal(srv.validateProject('Alpha-App\nBeta', ALLOWED).error, 'PROJECT_INVALID');
  assert.equal(srv.validateProject('../../etc', ALLOWED).error, 'PROJECT_INVALID');
  assert.equal(srv.validateProject('', ALLOWED).error, 'PROJECT_INVALID');
  assert.equal(srv.validateProject(42, ALLOWED).error, 'PROJECT_INVALID');
});

test('validateProject: allowed が配列でなければ拒否 (fail-closed)', () => {
  assert.equal(srv.validateProject('Alpha-App', undefined).ok, false);
  assert.equal(srv.validateProject('Alpha-App', []).ok, false);
});

test('validateMode: 3 モードのみ', () => {
  ['foreground', 'team', 'background'].forEach(m => assert.equal(srv.validateMode(m).ok, true));
  assert.equal(srv.validateMode('dangerously-skip-permissions').error, 'MODE_INVALID');
  assert.equal(srv.validateMode('--foreground').error, 'MODE_INVALID');
});

test('validateGoal: auto/空は自動判定・未知の Goal は拒否', () => {
  assert.equal(srv.validateGoal('', GOALS).value, '');
  assert.equal(srv.validateGoal('auto', GOALS).value, '');
  assert.equal(srv.validateGoal('hotfix', GOALS).value, 'hotfix');
  assert.equal(srv.validateGoal('rm -rf', GOALS).error, 'GOAL_INVALID');
});

test('validateDuration: background は 1..max、foreground/team は 0 可', () => {
  assert.equal(srv.validateDuration(60, 'background', LIMITS).value, 60);
  assert.equal(srv.validateDuration(0, 'background', LIMITS).error, 'DURATION_UNLIMITED_BACKGROUND');
  assert.equal(srv.validateDuration(301, 'background', LIMITS).error, 'DURATION_OVER_LIMIT');
  assert.equal(srv.validateDuration(0, 'foreground', LIMITS).value, 0);
  assert.equal(srv.validateDuration(9999, 'team', LIMITS).value, 9999);
  assert.equal(srv.validateDuration(-5, 'background', LIMITS).error, 'DURATION_INVALID');
  assert.equal(srv.validateDuration('abc', 'background', LIMITS).error, 'DURATION_INVALID');
  // 既定値 (省略時)
  assert.equal(srv.validateDuration(undefined, 'background', LIMITS).value, 300);
  assert.equal(srv.validateDuration(undefined, 'foreground', LIMITS).value, 0);
});

test('sanitizeIntent: 改行/制御文字除去と長さ上限', () => {
  assert.equal(srv.sanitizeIntent('  CI を直して\n\n お願い '), 'CI を直して お願い');
  assert.equal(srv.sanitizeIntent('a\u0000b'), 'a b');
  assert.equal(srv.sanitizeIntent(undefined), '');
  assert.equal(srv.sanitizeIntent('x'.repeat(5000)).length, 2000);
});

// ---------------------------------------------------------------------------
// 2) CLI 引数組み立て
// ---------------------------------------------------------------------------
test('buildLaunchArgs: start-claude.sh の契約どおりの順序', () => {
  assert.deepEqual(
    srv.buildLaunchArgs({ project: 'Alpha-App', mode: 'background', goal: 'hotfix', intent: 'CI を直して', duration: 300 }),
    ['--project', 'Alpha-App', '--background', '--goal', 'hotfix', '--intent', 'CI を直して', '--duration', '300']);
  assert.deepEqual(
    srv.buildLaunchArgs({ project: 'Alpha-App', mode: 'foreground', duration: 0, dryRun: true }),
    ['--project', 'Alpha-App', '--foreground', '--duration', '0', '--dry-run']);
});

test('buildStopArgs / buildApplyAllArgs', () => {
  assert.deepEqual(srv.buildStopArgs({ project: 'Alpha-App' }), ['stop', 'Alpha-App']);
  assert.deepEqual(srv.buildStopArgs({ project: 'Alpha-App', force: true }), ['stop', 'Alpha-App', '--now']);
  assert.deepEqual(srv.buildStopArgs({ all: true }), ['stop', '--all']);
  assert.deepEqual(srv.buildApplyAllArgs({ dryRun: true }), ['start', '--all', '--dry-run']);
  assert.deepEqual(srv.buildApplyAllArgs({ dryRun: false, duration: 120 }), ['start', '--all', '--duration', '120', '--yes']);
});

// ---------------------------------------------------------------------------
// 3) パス検証
// ---------------------------------------------------------------------------
test('parseState: 壊れた出力は拒否', () => {
  assert.equal(srv.parseState('{"projects":[]}').ok, true);
  assert.equal(srv.parseState('not json').error, 'STATE_PARSE');
  assert.equal(srv.parseState('{"foo":1}').error, 'STATE_SHAPE');
});

test('resolveLogFile: ~/.claudeos 配下のみ許可', () => {
  const inside = path.join(process.env.CLAUDEOS_HOME, 'logs', 'a.log');
  assert.equal(srv.resolveLogFile(inside), inside);
  assert.equal(srv.resolveLogFile('/etc/passwd'), null);
  assert.equal(srv.resolveLogFile(path.join(process.env.CLAUDEOS_HOME, '..', '..', 'etc', 'shadow')), null);
  assert.equal(srv.resolveLogFile(''), null);
});

test('resolveStaticPath: public 配下のみ', () => {
  const ok = srv.resolveStaticPath('/index.html');
  assert.ok(ok && ok.endsWith(path.join('public', 'index.html')));
  assert.equal(srv.resolveStaticPath('/../../etc/passwd'), null);
  assert.equal(srv.resolveStaticPath('/..%2f..%2fetc%2fpasswd'), null);
});

test('tailLines: 末尾 N 行 (存在しないファイルは空)', () => {
  const f = path.join(TMP, 'tail.log');
  fs.writeFileSync(f, '1\n2\n3\n4\n5\n');
  assert.equal(srv.tailLines(f, 2), '4\n5');
  assert.equal(srv.tailLines(f, 9), '1\n2\n3\n4\n5');
  assert.equal(srv.tailLines(path.join(TMP, 'nope.log'), 5), '');
});

test('checkBasicAuth / checkOrigin', () => {
  assert.equal(srv.checkBasicAuth(undefined, 'u', ''), true);                       // auth 無効
  const hdr = 'Basic ' + Buffer.from('claudeos:secret').toString('base64');
  assert.equal(srv.checkBasicAuth(hdr, 'claudeos', 'secret'), true);
  assert.equal(srv.checkBasicAuth(hdr, 'claudeos', 'wrong'), false);
  assert.equal(srv.checkBasicAuth(undefined, 'claudeos', 'secret'), false);
  assert.equal(srv.checkOrigin(undefined, 'localhost:3740'), true);
  assert.equal(srv.checkOrigin('http://localhost:3740', 'localhost:3740'), true);
  assert.equal(srv.checkOrigin('http://evil.example', 'localhost:3740'), false);
  assert.equal(srv.checkOrigin('not a url', 'localhost:3740'), false);
});

// ---------------------------------------------------------------------------
// 4) HTTP 統合 (fixture root に CLI スタブを置いて実 HTTP で叩く)
// ---------------------------------------------------------------------------
const FIXTURE = path.join(TMP, 'repo');
const MARK = path.join(TMP, 'launch-mark.txt');

function writeStubs() {
  fs.mkdirSync(path.join(FIXTURE, 'bin'), { recursive: true });
  fs.mkdirSync(path.join(FIXTURE, 'libexec'), { recursive: true });

  const state = {
    generated_at: '2026-01-01T00:00:00+09:00', host: 'testhost',
    projects_dir: '/tmp/projects', config_path: '/tmp/config.json', groups: ['Mirai-DX-Project'],
    projects: [
      { name: 'Alpha-App', dir: '/tmp/projects/Alpha-App', group: '', run_status: 'ok', running: false,
        supervisor: null, foreground: null, tmux: { name: 'claudeos-Alpha-App', active: false }, log_file: '' },
      { name: 'Mirai-DX-Project/Beta-Site', dir: '/tmp/projects/Mirai-DX-Project/Beta-Site',
        group: 'Mirai-DX-Project', run_status: 'running', running: true,
        supervisor: { file: '/tmp/sup.json', status: 'running', pid: 1, alive: true, restarts_today: 2 },
        foreground: null, tmux: { name: 'claudeos-Beta-Site', active: true },
        log_file: path.join(process.env.CLAUDEOS_HOME, 'logs', 'Beta-Site.log') },
    ],
    goals: GOALS,
    sessions: { tmux: ['claudeos-Beta-Site'], headless: ['Mirai-DX-Project/Beta-Site'], foreground: [],
                history: [{ file: 'x', project: 'Alpha-App', status: 'completed', start_time: '2026-01-01T00:00:00+09:00' }],
                count: 2 },
    limits: LIMITS,
  };
  fs.writeFileSync(path.join(FIXTURE, 'libexec', 'startup-state.sh'),
    '#!/usr/bin/env bash\ncat <<\'JSON\'\n' + JSON.stringify(state, null, 2) + '\nJSON\n');
  // 起動スタブ: 引数をそのまま stdout に出す。--dry-run 以外は MARK に追記 (実起動の証跡)
  fs.writeFileSync(path.join(FIXTURE, 'bin', 'start-claude.sh'),
    '#!/usr/bin/env bash\necho "STUB-START-CLAUDE $*"\n' +
    'case " $* " in *" --dry-run "*) echo "dry-run: 起動しません";; ' +
    '*) printf "%s\\n" "$*" >> "' + MARK + '";; esac\nexit 0\n');
  fs.writeFileSync(path.join(FIXTURE, 'bin', 'autonomy.sh'),
    '#!/usr/bin/env bash\necho "STUB-AUTONOMY $*"\nexit 0\n');
}
writeStubs();

async function withServer(cfg, fn) {
  const server = srv.createServer(Object.assign({ root: FIXTURE, port: 0, host: '127.0.0.1' }, cfg || {}));
  await new Promise(r => server.listen(0, '127.0.0.1', r));
  const port = server.address().port;
  try { await fn(port); } finally { await new Promise(r => server.close(r)); }
}

function req(port, method, urlPath, body, headers) {
  return new Promise((resolve, reject) => {
    const payload = body === undefined ? null : JSON.stringify(body);
    const r = http.request({ host: '127.0.0.1', port, method, path: urlPath,
      headers: Object.assign(payload ? { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(payload) } : {}, headers || {}) },
      (res) => {
        let data = '';
        res.on('data', d => { data += d; });
        res.on('end', () => {
          let json = null;
          try { json = JSON.parse(data); } catch { /* HTML/空はそのまま */ }
          resolve({ status: res.statusCode, headers: res.headers, body: data, json });
        });
      });
    r.on('error', reject);
    if (payload) r.write(payload);
    r.end();
  });
}

test('HTTP: /api/health と /api/startup/state', async () => {
  await withServer({}, async (port) => {
    const h = await req(port, 'GET', '/api/health');
    assert.equal(h.status, 200);
    assert.equal(h.json.ok, true);

    const s = await req(port, 'GET', '/api/startup/state');
    assert.equal(s.status, 200);
    assert.equal(s.json.ok, true);
    assert.equal(s.json.state.projects.length, 2);
    assert.equal(s.json.state.sessions.count, 2);
    assert.equal(s.json.server.modes.length, 3);
    assert.equal(s.json.server.authRequired, false);
  });
});

test('HTTP: 静的配信 (index.html / app.js) とトラバーサル拒否', async () => {
  await withServer({}, async (port) => {
    const idx = await req(port, 'GET', '/');
    assert.equal(idx.status, 200);
    assert.match(idx.body, /Web スタートアップコンソール/);
    const js = await req(port, 'GET', '/app.js');
    assert.equal(js.status, 200);
    const bad = await req(port, 'GET', '/../startup-server.js');
    assert.equal(bad.status, 404);
  });
});

test('HTTP: /api/startup/plan は CLI に --dry-run で渡る', async () => {
  await withServer({}, async (port) => {
    const r = await req(port, 'POST', '/api/startup/plan',
      { project: 'Alpha-App', mode: 'background', goal: 'hotfix', intent: 'CI を直して', duration: 120 });
    assert.equal(r.status, 200);
    assert.equal(r.json.ok, true);
    assert.match(r.json.plan, /STUB-START-CLAUDE --project Alpha-App --background --goal hotfix --intent CI を直して --duration 120 --dry-run/);
    assert.deepEqual(r.json.capacity, { running: 2, max: 4 });   // 同時実行の余力も返す
    assert.equal(fs.existsSync(MARK), false);   // 計画だけでは実起動しない
  });
});

test('HTTP: 未確認の launch は実行せず計画を返す (Human Gate)', async () => {
  await withServer({}, async (port) => {
    const r = await req(port, 'POST', '/api/startup/launch',
      { project: 'Alpha-App', mode: 'background', duration: 60 });
    assert.equal(r.status, 200);
    assert.equal(r.json.requiresConfirm, true);
    assert.equal(r.json.started, undefined);
    assert.equal(fs.existsSync(MARK), false);
  });
});

test('HTTP: confirm 付き launch が実起動し CLI 引数が一致する', async () => {
  fs.rmSync(MARK, { force: true });
  await withServer({}, async (port) => {
    const r = await req(port, 'POST', '/api/startup/launch',
      { project: 'Alpha-App', mode: 'team', goal: 'auto', intent: '評価して', duration: 0, confirm: true });
    assert.equal(r.status, 200);
    assert.equal(r.json.started, true);
    assert.ok(r.json.pid > 0);
    let mark = '';
    for (let i = 0; i < 40 && !mark; i++) {
      await new Promise(res => setTimeout(res, 50));
      if (fs.existsSync(MARK)) mark = fs.readFileSync(MARK, 'utf8').trim();
    }
    assert.equal(mark, '--project Alpha-App --team --intent 評価して --duration 0');
  });
});

test('HTTP: dryRunOnly なら confirm 付きでも実起動しない', async () => {
  fs.rmSync(MARK, { force: true });
  await withServer({ dryRunOnly: true }, async (port) => {
    const r = await req(port, 'POST', '/api/startup/launch',
      { project: 'Alpha-App', mode: 'background', duration: 60, confirm: true });
    assert.equal(r.json.started, undefined);
    assert.equal(r.json.dryRunOnly, true);
    assert.equal(fs.existsSync(MARK), false);
  });
});

test('HTTP: 未登録プロジェクト / 不正モードは 400', async () => {
  await withServer({}, async (port) => {
    const a = await req(port, 'POST', '/api/startup/plan', { project: 'Nope', mode: 'background' });
    assert.equal(a.status, 400);
    assert.equal(a.json.error, 'PROJECT_NOT_REGISTERED');
    const b = await req(port, 'POST', '/api/startup/plan', { project: 'Alpha-App', mode: '--team' });
    assert.equal(b.status, 400);
    assert.equal(b.json.error, 'MODE_INVALID');
    const c = await req(port, 'POST', '/api/startup/launch', { project: 'Alpha-App', mode: 'background', goal: 'nope' });
    assert.equal(c.status, 400);
    assert.equal(c.json.error, 'GOAL_INVALID');
  });
});

test('HTTP: stop は実行中のみ・確認なしでは実行しない', async () => {
  await withServer({}, async (port) => {
    const notRunning = await req(port, 'POST', '/api/startup/stop', { project: 'Alpha-App' });
    assert.equal(notRunning.status, 409);
    assert.equal(notRunning.json.error, 'NOT_RUNNING');

    const dry = await req(port, 'POST', '/api/startup/stop', { project: 'Mirai-DX-Project/Beta-Site' });
    assert.equal(dry.status, 200);
    assert.equal(dry.json.requiresConfirm, true);
    assert.match(dry.json.plan, /autonomy.sh stop Mirai-DX-Project\/Beta-Site/);

    const real = await req(port, 'POST', '/api/startup/stop',
      { project: 'Mirai-DX-Project/Beta-Site', confirm: true });
    assert.equal(real.status, 200);
    assert.match(real.json.output, /STUB-AUTONOMY stop Mirai-DX-Project\/Beta-Site/);

    const forced = await req(port, 'POST', '/api/startup/stop',
      { project: 'Mirai-DX-Project/Beta-Site', force: true, confirm: true });
    assert.match(forced.json.output, /stop Mirai-DX-Project\/Beta-Site --now/);
  });
});

test('HTTP: apply-all は計画 → 確認の 2 段階', async () => {
  await withServer({}, async (port) => {
    const plan = await req(port, 'POST', '/api/startup/apply-all', {});
    assert.equal(plan.status, 200);
    assert.equal(plan.json.requiresConfirm, true);
    assert.match(plan.json.plan, /STUB-AUTONOMY start --all --dry-run/);

    const apply = await req(port, 'POST', '/api/startup/apply-all', { confirm: true });
    assert.equal(apply.json.started, true);
    assert.match(apply.json.plan, /--dry-run/);      // 実行前に必ず dry-run が走る
  });
});

test('HTTP: ログ閲覧は ~/.claudeos 配下のみ・未登録は 400', async () => {
  const logFile = path.join(process.env.CLAUDEOS_HOME, 'logs', 'Beta-Site.log');
  fs.writeFileSync(logFile, 'line1\nline2\nline3\n');
  await withServer({}, async (port) => {
    const ok = await req(port, 'GET', '/api/startup/log?project=' + encodeURIComponent('Mirai-DX-Project/Beta-Site') + '&lines=2');
    assert.equal(ok.status, 200);
    assert.equal(ok.json.content, 'line2\nline3');
    const bad = await req(port, 'GET', '/api/startup/log?project=Nope');
    assert.equal(bad.status, 400);
  });
});

test('HTTP: Basic 認証 (パスワード設定時)', async () => {
  await withServer({ authPass: 'secret', authUser: 'claudeos' }, async (port) => {
    const no = await req(port, 'GET', '/api/startup/state');
    assert.equal(no.status, 401);
    const health = await req(port, 'GET', '/api/health');   // health は常に公開
    assert.equal(health.status, 200);
    const ok = await req(port, 'GET', '/api/startup/state', undefined,
      { Authorization: 'Basic ' + Buffer.from('claudeos:secret').toString('base64') });
    assert.equal(ok.status, 200);
    assert.equal(ok.json.ok, true);
  });
});

test('HTTP: 他サイト Origin からの変更系 POST は 403', async () => {
  await withServer({}, async (port) => {
    const r = await req(port, 'POST', '/api/startup/plan',
      { project: 'Alpha-App', mode: 'background' }, { Origin: 'http://evil.example' });
    assert.equal(r.status, 403);
    assert.equal(r.json.error, 'ORIGIN_REJECTED');
  });
});

test('HTTP: 空 body / 不正 JSON の扱い', async () => {
  await withServer({}, async (port) => {
    // 空 body → 入力検証で弾かれる (400)
    const empty = await req(port, 'POST', '/api/startup/plan', undefined, { 'Content-Type': 'application/json' });
    assert.equal(empty.status, 400);
    assert.equal(empty.json.error, 'PROJECT_INVALID');
    // 不正 JSON → BODY_INVALID_JSON
    const bad = await req(port, 'POST', '/api/startup/plan', undefined, { 'Content-Type': 'application/json' });
    assert.ok(bad.json !== null);
    const raw = await new Promise((resolve, reject) => {
      const r = http.request({ host: '127.0.0.1', port, method: 'POST', path: '/api/startup/plan',
        headers: { 'Content-Type': 'application/json' } }, res => {
        let d = ''; res.on('data', c => { d += c; });
        res.on('end', () => resolve({ status: res.statusCode, body: d }));
      });
      r.on('error', reject); r.write('{not json'); r.end();
    });
    assert.equal(raw.status, 400);
    assert.equal(JSON.parse(raw.body).error, 'BODY_INVALID_JSON');
  });
});

test('parseArgs / usage', () => {
  const a = srv.parseArgs(['--port', '3900', '--lan', '--dry-run-only']);
  assert.equal(a.port, 3900);
  assert.equal(a.host, '0.0.0.0');
  assert.equal(a.dryRunOnly, true);
  assert.equal(srv.parseArgs(['3741']).port, 3741);
  assert.match(srv.usage(), /startup-server\.js/);
});

test('isLoopback', () => {
  assert.equal(srv.isLoopback('127.0.0.1'), true);
  assert.equal(srv.isLoopback('localhost'), true);
  assert.equal(srv.isLoopback('0.0.0.0'), false);
  assert.equal(srv.isLoopback('192.168.0.185'), false);
});