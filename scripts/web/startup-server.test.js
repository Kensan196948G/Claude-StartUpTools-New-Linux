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

test('projectNames: 登録済みと all_folders の和集合 (フォルダ以下すべてを起動可能に)', () => {
  const names = srv.projectNames({ projects: [{ name: 'A' }], all_folders: ['A', 'B', 'Group/C'] });
  assert.deepEqual([...names].sort(), ['A', 'B', 'Group/C']);
  assert.deepEqual(srv.projectNames({ projects: [{ name: 'A' }] }), ['A']);
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
  // foreground は Web に TTY が無いため tmux を介す (CLI 端末から attach できるようにする)
  assert.deepEqual(
    srv.buildLaunchArgs({ project: 'Alpha-App', mode: 'foreground', duration: 0, dryRun: true }),
    ['--project', 'Alpha-App', '--foreground', '--tmux', '--duration', '0', '--dry-run']);
});

test('buildStopArgs / buildApplyAllArgs', () => {
  assert.deepEqual(srv.buildStopArgs({ project: 'Alpha-App' }), ['stop', 'Alpha-App']);
  assert.deepEqual(srv.buildStopArgs({ project: 'Alpha-App', force: true }), ['stop', 'Alpha-App', '--now']);
  // Web には TTY が無いため stop --all は --yes を付ける (Human Gate は confirm で通過済み)。
  assert.deepEqual(srv.buildStopArgs({ all: true }), ['stop', '--all', '--yes']);
  assert.deepEqual(srv.buildStopArgs({ all: true, force: true }), ['stop', '--all', '--now', '--yes']);
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
  const AUTONOMY_CALLS = path.join(TMP, 'autonomy-calls.log');
  const APPLY_DRY_FAIL = path.join(TMP, 'apply-dry-fail');
  const START_FAIL = path.join(TMP, 'start-fail');

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
  // 起動スタブ: 引数をそのまま stdout に出す。--dry-run 以外は MARK に追記 (実起動の証跡)。
  //   start-fail マーカーがある間は即時失敗する (BUG-05 の再現用)。
  fs.writeFileSync(path.join(FIXTURE, 'bin', 'start-claude.sh'),
    '#!/usr/bin/env bash\n' +
    'if [ -f "' + START_FAIL + '" ]; then echo "start failed (stub)" >&2; exit 3; fi\n' +
    'echo "STUB-START-CLAUDE $*"\n' +
    'case " $* " in *" --dry-run "*) echo "dry-run: 起動しません";; ' +
    '*) printf "%s\\n" "$*" >> "' + MARK + '";; esac\nexit 0\n');
  // autonomy スタブ: 呼び出しを記録する。apply-dry-fail マーカーがある間は --dry-run で exit 1。
  fs.writeFileSync(path.join(FIXTURE, 'bin', 'autonomy.sh'),
    '#!/usr/bin/env bash\n' +
    'echo "STUB-AUTONOMY $*"\n' +
    'printf "%s\\n" "$*" >> "' + AUTONOMY_CALLS + '"\n' +
    'case " $* " in\n' +
    '  *" --dry-run "*) if [ -f "' + APPLY_DRY_FAIL + '" ]; then echo "dry-run failed (stub)" >&2; exit 1; fi ;;\n' +
    'esac\n' +
    'exit 0\n');
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
    // ルートは統合コンソール v2、旧コンソールは /index.html で残す
    const idx = await req(port, 'GET', '/');
    assert.equal(idx.status, 200);
    assert.match(idx.body, /統合コンソール/);
    const legacy = await req(port, 'GET', '/index.html');
    assert.equal(legacy.status, 200);
    assert.match(legacy.body, /Web スタートアップコンソール/);
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

test('HTTP: 起動 CLI の即時失敗は started:true にしない (QA BUG-05)', async () => {
  const fail = path.join(TMP, 'start-fail');
  fs.rmSync(MARK, { force: true });
  fs.writeFileSync(fail, '1');
  try {
    await withServer({}, async (port) => {
      const r = await req(port, 'POST', '/api/startup/launch',
        { project: 'Alpha-App', mode: 'background', duration: 60, confirm: true });
      assert.equal(r.status, 200);
      assert.equal(r.json.ok, false);
      assert.equal(r.json.started, false);
      assert.equal(r.json.error, 'START_FAILED');
      assert.equal(r.json.exitCode, 3);
      assert.match(r.json.stderr, /start failed/);
      assert.equal(fs.existsSync(MARK), false);   // 起動していない
    });
  } finally {
    fs.rmSync(fail, { force: true });
  }
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

test('HTTP: stop --all は非対話でも通るよう --yes を渡す (QA BUG-03)', async () => {
  const calls = path.join(TMP, 'autonomy-calls.log');
  fs.rmSync(calls, { force: true });
  await withServer({}, async (port) => {
    const plan = await req(port, 'POST', '/api/startup/stop', { all: true });
    assert.equal(plan.status, 200);
    assert.equal(plan.json.requiresConfirm, true);
    assert.deepEqual(plan.json.args, ['stop', '--all', '--yes']);

    const real = await req(port, 'POST', '/api/startup/stop', { all: true, confirm: true });
    assert.equal(real.status, 200);
    assert.equal(real.json.ok, true);
    const log = fs.readFileSync(calls, 'utf8');
    assert.match(log, /stop --all --yes/);
  });
});

test('HTTP: apply-all は dry-run 失敗時に実適用へ進まない (QA BUG-02)', async () => {
  const fail = path.join(TMP, 'apply-dry-fail');
  const calls = path.join(TMP, 'autonomy-calls.log');
  fs.rmSync(calls, { force: true });
  fs.writeFileSync(fail, '1');
  try {
    await withServer({}, async (port) => {
      const r = await req(port, 'POST', '/api/startup/apply-all', { confirm: true });
      assert.equal(r.status, 200);
      assert.equal(r.json.ok, false);
      assert.equal(r.json.error, 'PLAN_FAILED');
      assert.equal(r.json.started, undefined);
      const log = fs.existsSync(calls) ? fs.readFileSync(calls, 'utf8') : '';
      assert.ok(!/--yes/.test(log), 'dry-run 失敗時に --yes を起動してはいけない: ' + log);
    });
  } finally {
    fs.rmSync(fail, { force: true });
  }
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

test('HTTP: 64KB 超の本文は 400 BODY_TOO_LARGE を返す (接続断にしない / QA BUG-06)', async () => {
  await withServer({}, async (port) => {
    const payload = JSON.stringify({ pad: 'x'.repeat(70000) });
    const res = await new Promise((resolve, reject) => {
      const r = http.request({ host: '127.0.0.1', port, method: 'POST', path: '/api/startup/plan',
        headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(payload) } },
        rs => {
          let d = '';
          rs.on('data', c => { d += c; });
          rs.on('end', () => resolve({ status: rs.statusCode, body: d }));
        });
      r.on('error', reject);
      r.write(payload);
      r.end();
    });
    assert.equal(res.status, 400);
    assert.equal(JSON.parse(res.body).error, 'BODY_TOO_LARGE');
  });
});

test('parseArgs / usage', () => {
  const a = srv.parseArgs(['--port', '3900', '--lan', '--dry-run-only']);
  assert.equal(a.port, 3900);
  assert.equal(a.host, '0.0.0.0');
  assert.equal(a.dryRunOnly, true);
  assert.equal(srv.parseArgs(['3741']).port, 3741);
  const p = srv.parseArgs(['--pid-file', path.join(TMP, 'web.pid')]);
  assert.equal(p.pidFile, path.join(TMP, 'web.pid'));
  assert.match(srv.usage(), /startup-server\.js/);
  assert.match(srv.usage(), /--pid-file/);
});

test('CLI: --pid-file は自分自身の PID を書き、終了時に消す (QA BUG-01)', async () => {
  const { spawn } = require('child_process');
  const pidFile = path.join(TMP, 'web-startup.pid');
  const root = path.join(__dirname, '..', '..');
  const child = spawn(process.execPath,
    [path.join(root, 'scripts', 'web', 'startup-server.js'), '--port', '0', '--host', '127.0.0.1', '--pid-file', pidFile],
    { cwd: root, env: process.env, stdio: 'ignore' });
  try {
    let content = '';
    for (let i = 0; i < 60 && !content; i++) {
      await new Promise(r => setTimeout(r, 100));
      try { content = fs.readFileSync(pidFile, 'utf8').trim(); } catch { /* まだ書かれていない */ }
    }
    assert.equal(content, String(child.pid));   // pgrep 先頭ではなく自分自身
  } finally {
    child.kill('SIGTERM');
    await new Promise(r => child.on('exit', r));
  }
  assert.equal(fs.existsSync(pidFile), false);  // 停止後に残さない
});

test('isLoopback', () => {
  assert.equal(srv.isLoopback('127.0.0.1'), true);
  assert.equal(srv.isLoopback('localhost'), true);
  assert.equal(srv.isLoopback('0.0.0.0'), false);
  assert.equal(srv.isLoopback('192.168.0.185'), false);
});
/* ---------------------------------------------------------------- 運用情報 (読み取り専用) ---
 * cron / systemd / agents は「実測値を返すか、取得できなければ available:false を返す」。
 * 取得できない環境 (CI 等) でも 200 + ok:true を保ち、嘘の値を返さないことを固定する。
 */
test('HTTP: GET /api/ops/systemd は読み取り専用で unit 一覧を返す', async () => {
  await withServer({}, async (port) => {
    const r = await req(port, 'GET', '/api/ops/systemd');
    assert.equal(r.status, 200);
    assert.equal(r.json.ok, true);
    assert.equal(typeof r.json.available, 'boolean');
    assert.ok(Array.isArray(r.json.units));
    r.json.units.forEach((u) => {
      assert.equal(typeof u.name, 'string');
      assert.equal(typeof u.active, 'string');
      assert.equal(typeof u.enabled, 'boolean', 'enabled は真偽値で返す');
      assert.equal(typeof u.exec_start, 'string', 'ExecStart を実値で返す');
      assert.ok(/^claude/i.test(u.name), 'このプロジェクトの unit のみ返す');
    });
  });
});

test('isCronSchedule: 正しい 5 項目だけを cron と認め、説明コメントの断片は拒否する', () => {
  const t = (s) => srv.isCronSchedule(s.split(' '));
  assert.equal(t('0 2 * * *'), true);
  assert.equal(t('*/5 1-3 * jan mon-fri'), true);
  assert.equal(t('0 2 * * 1,3'), true);
  assert.equal(t('2>&1 then not Do x'), false);
  assert.equal(t('0*:0* a b c d'), false);
  assert.equal(t('2026-07-11]:[STOPPED a b c'), false);
  assert.equal(t('foo bar baz qux quux'), false);
  assert.equal(srv.isCronSchedule(['0', '2', '*']), false);
});

test('HTTP: GET /api/ops/cron は entries 配列を返し、取得不能でも嘘をつかない', async () => {
  await withServer({}, async (port) => {
    const r = await req(port, 'GET', '/api/ops/cron');
    assert.equal(r.status, 200);
    assert.equal(r.json.ok, true);
    assert.equal(typeof r.json.available, 'boolean');
    assert.ok(Array.isArray(r.json.entries));
    if (!r.json.available) {
      assert.equal(r.json.entries.length, 0, '取得不能なら空で返す');
      assert.ok(r.json.note, '取得不能の理由を返す');
    }
    r.json.entries.forEach((e) => {
      assert.equal(typeof e.command, 'string');
      assert.equal(typeof e.disabled, 'boolean');
    });
  });
});

test('HTTP: GET /api/ops/agents は available と data の組を返す', async () => {
  await withServer({}, async (port) => {
    const r = await req(port, 'GET', '/api/ops/agents');
    assert.equal(r.status, 200);
    assert.equal(r.json.ok, true);
    assert.equal(typeof r.json.available, 'boolean');
    if (r.json.available) assert.ok(r.json.data && typeof r.json.data === 'object');
  });
});

test('HTTP: /api/ops/* は GET 以外を受け付けない (読み取り専用)', async () => {
  await withServer({}, async (port) => {
    for (const p of ['/api/ops/cron', '/api/ops/systemd', '/api/ops/agents']) {
      const r = await req(port, 'POST', p, {});
      assert.equal(r.status, 404, p + ' は POST を受け付けない');
    }
  });
});

/* -------------------------------------------------------- SubAgent カタログ API ---
 * config/agent-catalog.json を読むだけで、編集はしない。
 * 実データがあれば counts を返し、無ければ available:false + 理由を返す（嘘の 0 を返さない）。
 */
test('HTTP: GET /api/ops/agent-catalog は実カタログの件数を返す', async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'catalog-root-'));
  fs.mkdirSync(path.join(root, 'config'), { recursive: true });
  fs.writeFileSync(path.join(root, 'config', 'agent-catalog.json'), JSON.stringify({
    schemaVersion: 1,
    first_class: [{ name: 'cto', purpose: '統括', model: 'inherit' }],
    catalog: [{ name: 'architect', when: '設計時' }],
    merge: { 'code-reviewer': ['a', 'b'] },
    remove_candidate: { planner: 'native Plan subagent' },
  }));
  await withServer({ root }, async (port) => {
    const r = await req(port, 'GET', '/api/ops/agent-catalog');
    assert.equal(r.status, 200);
    assert.equal(r.json.ok, true);
    assert.equal(r.json.available, true);
    assert.deepEqual(r.json.counts, { first_class: 1, catalog: 1, merge: 1, remove_candidate: 1 });
    assert.equal(r.json.first_class[0].name, 'cto');
    assert.equal(r.json.catalog[0].name, 'architect');
  });
});

test('HTTP: GET /api/ops/agent-catalog はカタログ不在でも嘘をつかない', async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'catalog-none-'));
  await withServer({ root }, async (port) => {
    const r = await req(port, 'GET', '/api/ops/agent-catalog');
    assert.equal(r.status, 200);
    assert.equal(r.json.ok, true);
    assert.equal(r.json.available, false);
    assert.ok(r.json.note, '理由を返す');
  });
});

/* ------------------------------------------------------ Managed Agents API ---
 * config/roster はリポジトリ、registry/ledger/decisions は CLAUDEOS_HOME 配下。
 * 読めた分だけ返し、config が無ければ available:false + 理由を返す（嘘をつかない）。
 */
test('HTTP: GET /api/ops/managed-agents は台帳から使用量と履歴を返す', async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'ma-root-'));
  fs.mkdirSync(path.join(root, 'config'), { recursive: true });
  fs.writeFileSync(path.join(root, 'config', 'managed-agents-roster.json'),
    JSON.stringify({ agents: { 'repository-review': {}, 'quality-assurance': {} } }));

  const stateDir = path.join(process.env.CLAUDEOS_HOME, 'managed-agents');
  fs.mkdirSync(stateDir, { recursive: true });
  const nowIso = new Date().toISOString();
  fs.writeFileSync(path.join(stateDir, 'registry.json'),
    JSON.stringify({ agents: { 'repository-review': { id: 'agent_x' } } }));
  fs.writeFileSync(path.join(stateDir, 'ledger.jsonl'),
    [JSON.stringify({ type: 'reserve', ts: nowIso, task_id: 't-1', cents: 50, role: 'repository-review' })].join('\n') + '\n');
  fs.writeFileSync(path.join(stateDir, 'decisions.jsonl'), JSON.stringify({ ts: nowIso, kind: 'route' }) + '\n');

  await withServer({ root }, async (port) => {
    const r = await req(port, 'GET', '/api/ops/managed-agents');
    assert.equal(r.status, 200);
    assert.equal(r.json.ok, true);
    assert.equal(r.json.available, true);
    assert.equal(r.json.roster.count, 2);
    assert.equal(r.json.registry.count, 1);
    assert.equal(r.json.usage.month_cents, 50, '台帳の cents を今月分で合計する');
    assert.equal(r.json.usage.today_count, 1);
    assert.equal(r.json.config.available, false, 'config が無ければ false');
    assert.ok(r.json.config.note, '理由を返す');
    assert.ok(Array.isArray(r.json.log) && r.json.log.length === 1);
  });
});

/* ------------------------------------------------------------ Cron スナップショット ---
 * サービスは NoNewPrivileges=yes で crontab を読めないため、ユーザー側タイマーが書く
 * スナップショットを優先して読む。スナップショットが無ければ直接 crontab を試す。
 */
test('HTTP: GET /api/ops/cron はスナップショットを優先して返す', async () => {
  const snapFile = path.join(process.env.CLAUDEOS_HOME, 'cron-snapshot.json');
  fs.mkdirSync(process.env.CLAUDEOS_HOME, { recursive: true });
  fs.writeFileSync(snapFile, JSON.stringify({
    generated_at: '2026-11-21T10:00:00+09:00', source: 'crontab -l', ok: true, count: 1,
    entries: [{ disabled: false, minute: '30', hour: '4', dom: '*', month: '*', dow: '1-5', command: '/home/kensan/x.sh' }],
  }));
  try {
    await withServer({}, async (port) => {
      const r = await req(port, 'GET', '/api/ops/cron');
      assert.equal(r.status, 200);
      assert.equal(r.json.ok, true);
      assert.equal(r.json.available, true);
      assert.equal(r.json.source, 'snapshot');
      assert.equal(r.json.count, 1);
      assert.equal(r.json.entries[0].command, '/home/kensan/x.sh');
    });
  } finally {
    fs.unlinkSync(snapFile);
  }
});

/* --------------------------------------------------- 診断 / DevOps / SecOps ---
 * 実行系の画面は「許可したコマンドだけを実行する」allowlist 方式。
 * 任意コマンドを受け付けないこと、実測値を返すことを固定する。
 */
test('HTTP: GET /api/ops/diag は許可した診断だけを実行する', async () => {
  await withServer({}, async (port) => {
    const ok = await req(port, 'GET', '/api/ops/diag?name=all-tools');
    assert.equal(ok.status, 200);
    assert.equal(ok.json.ok, true);
    assert.equal(typeof ok.json.output, 'string');
    assert.ok(ok.json.output.length > 0, '診断の出力が空でない');

    const bad = await req(port, 'GET', '/api/ops/diag?name=rm-rf');
    assert.equal(bad.status, 400, 'allowlist 外は実行しない');
    assert.equal(bad.json.error, 'UNKNOWN_DIAG');
    assert.ok(Array.isArray(bad.json.allowed) && bad.json.allowed.length > 0);
  });
});

test('HTTP: GET /api/ops/devops は読み取り専用の実測値を返す', async () => {
  await withServer({}, async (port) => {
    const r = await req(port, 'GET', '/api/ops/devops');
    assert.equal(r.status, 200);
    assert.equal(r.json.ok, true);
    assert.equal(typeof r.json.release.head, 'string');
    assert.ok(!/deploy|restart/i.test(r.json.note || ''), 'デプロイ等を行わないことを明記');
  });
});

test('HTTP: GET /api/ops/secops はツールの有無を返す（実行はしない）', async () => {
  await withServer({}, async (port) => {
    const r = await req(port, 'GET', '/api/ops/secops');
    assert.equal(r.status, 200);
    assert.equal(r.json.ok, true);
    assert.equal(typeof r.json.tools, 'object');
    assert.equal(typeof r.json.tools.gitleaks.present, 'boolean');
    assert.ok(/有無の確認のみ/.test(r.json.note || ''), '実行しないことを明記');
  });
});

/* ------------------------------------------------- release-check バックグラウンドジョブ ---
 * 実チェックは数分かかるため同期 HTTP では返さない。start でジョブを起こし、
 * GET で状態を返す (UI はポーリング)。二重起動は既存ジョブを返す。
 */
test('HTTP: release-check はジョブとして開始し、状態を返す', async () => {
  await withServer({}, async (port) => {
    const start = await req(port, 'POST', '/api/ops/release-check/start', { dry: true });
    assert.equal(start.status, 200);
    assert.equal(start.json.ok, true);
    assert.ok(start.json.job && start.json.job.id, 'job id を返す');
    assert.ok(['running', 'done'].includes(start.json.job.status));

    const again = await req(port, 'POST', '/api/ops/release-check/start', { dry: true });
    assert.equal(again.status, 200);
    assert.equal(again.json.job.id, start.json.job.id, '同時実行は既存ジョブを返す');

    const status = await req(port, 'GET', '/api/ops/release-check');
    assert.equal(status.status, 200);
    assert.ok(status.json.job && typeof status.json.job === 'object');
    assert.equal(typeof status.json.job.checks, 'object');
  });
});

/* ------------------------------------------- Supervisor 全適用 (計画のみ) ---
 * 全プロジェクトへの一括適用は影響が大きいため、confirm 無しでは計画だけを返し、
 * 実適用を開始しない。画面はこの契約に依存している。
 */
test('HTTP: apply-all は confirm 無しなら計画のみを返し、実行しない', async () => {
  await withServer({}, async (port) => {
    const r = await req(port, 'POST', '/api/startup/apply-all', {});
    assert.equal(r.status, 200);
    assert.equal(r.json.requiresConfirm, true, 'confirm 待ちであることを返す');
    assert.equal(r.json.started, undefined, '実適用を開始していない');
    assert.equal(typeof r.json.plan, 'string');
    assert.ok(r.json.plan.length > 0, '計画の本文が空でない');
  });
});

/* --------------------------------------------------- 旧 UI の画面 URL の扱い ---
 * 旧設計プロトタイプは画面ごとに HTML があった。単一ページへ集約したため、
 * ブックマークからの流入が 404 にならないよう 302 で `/` へ送る。
 */
test('HTTP: 旧画面 URL は 302 で / へリダイレクトする', async () => {
  await withServer({}, async (port) => {
    for (const p of ['/startup-console.html', '/session-monitor.html', '/logs-audit.html', '/mission-control.html']) {
      const r = await req(port, 'GET', p);
      assert.equal(r.status, 302, p + ' は 302');
      assert.equal(r.headers && r.headers.location, '/', p + ' の遷移先は /');
    }
    // 旧コンソールは /index.html で引き続き参照できる (誤って潰さない)
    const legacy = await req(port, 'GET', '/index.html');
    assert.equal(legacy.status, 200);
  });
});
