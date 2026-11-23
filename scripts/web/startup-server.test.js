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

test('tailLines: 巨大ログは末尾の一部だけ読み、欠けた先頭行は捨てて末尾 N 行を返す', () => {
  const f = path.join(TMP, 'big.log');
  const lines = [];
  for (let i = 1; i <= 60000; i++) lines.push('line-' + i + '-' + 'x'.repeat(20));   // 約 1.7MB (> 512KB)
  fs.writeFileSync(f, lines.join('\n') + '\n');
  const out = srv.tailLines(f, 3).split('\n');
  assert.deepEqual(out, ['line-59998-' + 'x'.repeat(20), 'line-59999-' + 'x'.repeat(20), 'line-60000-' + 'x'.repeat(20)]);
  const many = srv.tailLines(f, 2000).split('\n');
  assert.equal(many.length, 2000);
  assert.ok(many[0].startsWith('line-'), '先頭は欠けていない完全な行');
});

test('resolveLogFile: 配下の外を指すシンボリックリンクは拒否する', () => {
  const outside = path.join(TMP, 'outside-secret.txt');
  fs.writeFileSync(outside, 'secret');
  const link = path.join(process.env.CLAUDEOS_HOME, 'link-to-outside.log');
  fs.rmSync(link, { force: true });
  fs.symlinkSync(outside, link);
  try {
    assert.equal(srv.resolveLogFile(link), null);
  } finally {
    fs.rmSync(link, { force: true });
  }
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

test('HTTP: /api/startup/state?refresh=1 は 20 秒キャッシュを捨てて再走査する (連打は 3 秒間抑止)', async () => {
  const root = path.join(TMP, 'repo-refresh');
  const counter = path.join(TMP, 'state-scan-count.txt');
  fs.rmSync(counter, { force: true });
  fs.mkdirSync(path.join(root, 'libexec'), { recursive: true });
  const base = fs.readFileSync(path.join(FIXTURE, 'libexec', 'startup-state.sh'), 'utf8');
  fs.writeFileSync(path.join(root, 'libexec', 'startup-state.sh'),
    base.replace('#!/usr/bin/env bash\n', '#!/usr/bin/env bash\necho x >> "' + counter + '"\n'));
  const scans = () => (fs.existsSync(counter) ? fs.readFileSync(counter, 'utf8').split('\n').filter(Boolean).length : 0);
  await withServer({ root }, async (port) => {
    await req(port, 'GET', '/api/startup/state');
    assert.equal(scans(), 1);
    await req(port, 'GET', '/api/startup/state');
    assert.equal(scans(), 1, '通常取得はキャッシュを使う');
    const quick = await req(port, 'GET', '/api/startup/state?refresh=1');
    assert.equal(quick.json.ok, true);
    assert.equal(scans(), 1, '直後の再読み込み連打は再走査しない');
    await new Promise(r => setTimeout(r, 3200));
    const forced = await req(port, 'GET', '/api/startup/state?refresh=1');
    assert.equal(forced.json.ok, true);
    assert.equal(scans(), 2, '3 秒以上経過後の再読み込みはキャッシュを捨てて再走査する');
  });
});

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

test('HTTP: 背景起動は supervisor が実在するまで started:true にしない (CLI exit 0 だけでは不十分)', async () => {
  const supDir = path.join(TMP, 'sup-unconfirmed');
  fs.rmSync(supDir, { recursive: true, force: true });
  fs.mkdirSync(supDir, { recursive: true });
  await withServer({ supervisorDir: supDir, launchConfirmMs: 400 }, async (port) => {
    // 状態ファイルなし (CLI は exit 0 だが supervisor が居ない)
    const a = await req(port, 'POST', '/api/startup/launch',
      { project: 'Alpha-App', mode: 'background', duration: 60, confirm: true });
    assert.equal(a.json.ok, false);
    assert.equal(a.json.started, false);
    assert.equal(a.json.error, 'START_NOT_CONFIRMED');
    assert.match(a.json.message, /稼働を確認できませんでした/);
    // 即停止していた場合は理由を添える
    fs.writeFileSync(path.join(supDir, 'Alpha-App.json'),
      JSON.stringify({ status: 'blocked', last_reason: 'blocked_issues', pid: 999999 }));
    const b = await req(port, 'POST', '/api/startup/launch',
      { project: 'Alpha-App', mode: 'background', duration: 60, confirm: true });
    assert.equal(b.json.started, false);
    assert.match(b.json.message, /status=blocked: blocked_issues/);
  });
});

test('HTTP: 背景起動は supervisor が running かつ pid 生存なら started:true', async () => {
  const supDir = path.join(TMP, 'sup-confirmed');
  fs.rmSync(supDir, { recursive: true, force: true });
  fs.mkdirSync(supDir, { recursive: true });
  fs.writeFileSync(path.join(supDir, 'Alpha-App.json'),
    JSON.stringify({ status: 'running', pid: process.pid }));   // テストプロセス自身 = 生存
  await withServer({ supervisorDir: supDir, launchConfirmMs: 400 }, async (port) => {
    const r = await req(port, 'POST', '/api/startup/launch',
      { project: 'Alpha-App', mode: 'background', duration: 60, confirm: true });
    assert.equal(r.json.ok, true);
    assert.equal(r.json.started, true);
  });
});

test('HTTP: /api/startup/log は log_file が無い (登録外の) プロジェクトでも supervisor ログを返す', async () => {
  const supDir = path.join(process.env.CLAUDEOS_HOME, 'supervisor-log-test');
  fs.rmSync(supDir, { recursive: true, force: true });
  fs.mkdirSync(supDir, { recursive: true });
  await withServer({ supervisorDir: supDir }, async (port) => {
    // Alpha-App は fixture 上 log_file が空 → ログ無しは 404
    const none = await req(port, 'GET', '/api/startup/log?project=Alpha-App&lines=5');
    assert.equal(none.status, 404);
    assert.equal(none.json.error, 'LOG_NOT_FOUND');
    fs.writeFileSync(path.join(supDir, 'Alpha-App.log'), 'line1\nline2\nline3\n');
    const r = await req(port, 'GET', '/api/startup/log?project=Alpha-App&lines=2');
    assert.equal(r.status, 200);
    assert.equal(r.json.content, 'line2\nline3');
  });
  fs.rmSync(supDir, { recursive: true, force: true });
});

test('supervisorStateFile: ccsu_safe_name と同じ規則 (非 [A-Za-z0-9_-] は 1 バイトずつ _)', () => {
  assert.equal(srv.supervisorStateFile('/s', 'Alpha-App'), '/s/Alpha-App.json');
  assert.equal(srv.supervisorStateFile('/s', 'a/b.c'), '/s/a_b_c.json');
  assert.equal(srv.supervisorStateFile('/s', 'あ'), '/s/___.json');   // UTF-8 3 バイト
  // bash 側 (lib/common.sh の ccsu_safe_name) と出力が一致すること (ASCII / 非 ASCII)
  const { execFileSync } = require('child_process');
  for (const name of ['Alpha-App', 'a/b.c', 'みらい-Project', 'x あ/y']) {
    const bashSafe = execFileSync('bash', ['-c', 'source "$1/lib/common.sh"; ccsu_safe_name "$2"', '_', path.join(__dirname, '..', '..'), name],
      { encoding: 'utf8' });
    assert.equal(srv.supervisorStateFile('/s', name), '/s/' + bashSafe + '.json', name);
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

// ---------------------------------------------------------------------------
// 5) プロンプト送信 (POST /api/session/prompt) — Approval PR で導入した高リスク機能
//    実 claude は呼ばず、スタブで引数・環境・ストリームを検証する。
// ---------------------------------------------------------------------------
const SID1 = '11111111-1111-4111-8111-111111111111';
const SID2 = '22222222-2222-4222-8222-222222222222';

const { publicKey: ACC_PUB, privateKey: ACC_PRIV } = require('crypto').generateKeyPairSync('rsa', { modulusLength: 2048 });
const ACC_JWK = Object.assign(ACC_PUB.export({ format: 'jwk' }), { kid: 'test-kid', alg: 'RS256', use: 'sig' });
const b64u = (b) => Buffer.from(b).toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
function signJwt(over, key, hdr) {
  const header = Object.assign({ alg: 'RS256', kid: 'test-kid', typ: 'JWT' }, hdr || {});
  const payload = Object.assign({ iss: 'https://test.cloudflareaccess.com', aud: ['aud-1'], email: 'kensan@example.test',
    exp: Math.floor(Date.now() / 1000) + 300 }, over || {});
  const input = b64u(JSON.stringify(header)) + '.' + b64u(JSON.stringify(payload));
  return input + '.' + b64u(require('crypto').sign('RSA-SHA256', Buffer.from(input), key || ACC_PRIV));
}
// 既定で正しい Origin と Access JWT を付けて POST する (個別の拒否テストでは headers で上書き)
function pp(port, body, headers) {
  return req(port, 'POST', '/api/session/prompt', body,
    Object.assign({ Origin: 'http://127.0.0.1:' + port, 'Cf-Access-Jwt-Assertion': signJwt() }, headers || {}));
}

function promptFixture(name) {
  const base = path.join(TMP, 'prompt-' + name);
  fs.rmSync(base, { recursive: true, force: true });
  const f = {
    base,
    root: path.join(base, 'repo'),
    projects: path.join(base, 'projects'),
    sup: path.join(base, 'sup'),
    sess: path.join(base, 'sess'),
    web: path.join(base, 'web'),
    argv: path.join(base, 'argv.txt'),
    env: path.join(base, 'env.txt'),
    pid: path.join(base, 'stub.pid'),
    gpid: path.join(base, 'stub-grand.pid'),
    claude: path.join(base, 'claude-stub'),
  };
  [f.root + '/libexec', f.projects + '/Alpha-App', f.projects + '/Mirai-DX-Project/Beta-Site', f.sup, f.sess].forEach(d => fs.mkdirSync(d, { recursive: true }));
  const stateSh = fs.readFileSync(path.join(FIXTURE, 'libexec', 'startup-state.sh'), 'utf8').split('/tmp/projects').join(f.projects);
  fs.writeFileSync(path.join(f.root, 'libexec', 'startup-state.sh'), stateSh);
  fs.writeFileSync(f.claude, [
    '#!/usr/bin/env bash',
    'if [ "${1:-}" = "--help" ]; then echo "  --permission-prompts <target>"; exit 0; fi',
    'printf "%s\\n" "$*" >> "$STUB_ARGV"',
    'env | sort > "$STUB_ENV"',
    'echo $$ > "$STUB_PID"',
    'case "${STUB_MODE:-ok}" in',
    '  sleep) exec sleep 30 ;;',
    '  grandchild) sleep 30 & echo $! > "$STUB_GPID"; wait ;;',
    '  holdpipe) ( sleep 20 & ) ; echo \'{"type":"result","subtype":"success","session_id":"' + SID1 + '"}\'; exit 0 ;;',
    '  noresult) exit 1 ;;',
    '  initsleep) echo \'{"type":"system","subtype":"init","session_id":"' + SID1 + '"}\'; exec sleep 30 ;;',
    '  errresult) echo \'{"type":"system","subtype":"init","session_id":"' + SID1 + '"}\'; echo \'{"type":"result","subtype":"error_max_budget_usd","is_error":true,"session_id":"' + SID1 + '"}\'; exit 1 ;;',
    '  fail) echo "boom" >&2; exit 3 ;;',
    'esac',
    'echo \'{"type":"system","subtype":"init","session_id":"' + SID1 + '"}\'',
    'echo \'{"type":"assistant","message":{"content":[{"type":"text","text":"hello"}]},"session_id":"' + SID1 + '"}\'',
    'echo "not-json line"',
    'echo \'{"type":"result","subtype":"success","session_id":"' + SID1 + '","total_cost_usd":0.01}\'',
  ].join('\n') + '\n', { mode: 0o755 });
  f.cfg = (extra) => Object.assign({ root: f.root, claudeBin: f.claude, supervisorDir: f.sup, sessionsDir: f.sess,
    webPromptDir: f.web, promptTimeoutMs: 20000,
    promptEnvPass: ['STUB_ARGV', 'STUB_ENV', 'STUB_PID', 'STUB_GPID', 'STUB_MODE'],   // スタブが使うテスト用変数だけ明示的に通す
    promptEnabled: true, accessTeamDomain: 'test.cloudflareaccess.com', accessAud: 'aud-1', accessKeys: async () => [ACC_JWK] }, extra || {});
  return f;
}

async function withPromptEnv(f, mode, fn) {
  const keep = {};
  const set = { STUB_ARGV: f.argv, STUB_ENV: f.env, STUB_PID: f.pid, STUB_GPID: f.gpid, STUB_MODE: mode || 'ok' };
  Object.keys(set).forEach((k) => { keep[k] = process.env[k]; process.env[k] = set[k]; });
  try { await fn(); } finally {
    Object.keys(set).forEach((k) => { if (keep[k] === undefined) delete process.env[k]; else process.env[k] = keep[k]; });
  }
}

const argvLines = (f) => (fs.existsSync(f.argv) ? fs.readFileSync(f.argv, 'utf8').split('\n').filter(Boolean) : []);
const ndjson = (body) => body.split('\n').filter(Boolean).map(l => JSON.parse(l));

test('prompt: ヘルパ (scrubEnv / validate / buildPromptArgs / findAutonomousSessionId / resolveProjectDir)', () => {
  const e = srv.scrubEnv({ PATH: '/bin', HOME: '/h', ANTHROPIC_API_KEY: 'k', GITHUB_TOKEN: 't', STARTUP_WEB_PASSWORD: 'p',
    CLAUDEOS_SMTP_PASS: 's', MY_SECRET: 'x', CLOUDFLARE_API_TOKEN: 'c', DATABASE_URL: 'd', CLAUDE_CODE_OAUTH_TOKEN: 'keep', LANG: 'ja' });
  assert.deepEqual(Object.keys(e).sort(), ['CLAUDE_CODE_OAUTH_TOKEN', 'HOME', 'LANG', 'PATH']);
  const e2 = srv.scrubEnv({ OPENAI_API_KEY: 'a', GOOGLE_API_KEY: 'b', SSH_AUTH_SOCK: '/s', POSTGRES_URL: 'u', SENTRY_DSN: 'd', CF_ACCESS_AUD: 'x', STARTUP_WEB_ALLOWED_HOSTS: 'h', ANTHROPIC_AUTH_TOKEN: 'keep', TERM: 'xterm', NODE_ENV: 'test' });
  assert.deepEqual(Object.keys(e2).sort(), ['ANTHROPIC_AUTH_TOKEN', 'NODE_ENV', 'TERM'], '強化した denylist (API キー・DSN・接続文字列・ssh agent) と、claude 自身の認証の例外');
  assert.equal(srv.validatePromptText('  hi  ').value, 'hi');
  assert.equal(srv.validatePromptText('').error, 'PROMPT_REQUIRED');
  assert.equal(srv.validatePromptText(5).error, 'PROMPT_REQUIRED');
  assert.equal(srv.validatePromptText('x'.repeat(srv.PROMPT_MAX_CHARS + 1)).error, 'PROMPT_TOO_LONG');
  assert.equal(srv.validatePromptText('a\u0000b').error, 'PROMPT_INVALID');
  assert.equal(srv.validatePromptModel(undefined).value, 'auto');
  assert.equal(srv.validatePromptModel('opus').value, 'opus');
  assert.equal(srv.validatePromptModel('gpt').error, 'MODEL_INVALID');
  const a = srv.buildPromptArgs({ text: '--rm -rf', resumeId: SID1, fork: true, model: 'sonnet', budgetUsd: 2, permissionMode: 'auto', noPermissionPrompts: true });
  assert.deepEqual(a.slice(-2), ['--', '--rm -rf'], '本文は -- の後ろ (先頭が - でもオプション扱いにしない)');
  assert.ok(a.join(' ').includes('--resume ' + SID1 + ' --fork-session'));
  assert.ok(a.join(' ').includes('--permission-prompts none'));
  assert.ok(a.join(' ').includes('--model sonnet'));
  assert.ok(a.join(' ').includes('--max-budget-usd 2'));
  assert.ok(!srv.buildPromptArgs({ text: 'x', model: 'auto' }).includes('--model'));
  assert.ok(!srv.buildPromptArgs({ text: 'x', fork: true }).includes('--fork-session'), 'resume 無しでは fork しない');
  // 自律セッション ID は JSON の project フィールドで照合 (非 ASCII 名は safe 名が衝突する)
  const d = path.join(TMP, 'sess-find');
  fs.rmSync(d, { recursive: true, force: true });
  fs.mkdirSync(d, { recursive: true });
  fs.writeFileSync(path.join(d, '20260101-___.json'), JSON.stringify({ project: 'みらい', sessionId: SID1 }));
  fs.writeFileSync(path.join(d, '20260102-___.json'), JSON.stringify({ project: 'ほか', sessionId: SID2 }));
  fs.writeFileSync(path.join(d, 'bad.json'), JSON.stringify({ project: 'みらい', sessionId: 'not-a-uuid' }));
  assert.equal(srv.findAutonomousSessionId(d, 'みらい'), SID1);
  assert.equal(srv.findAutonomousSessionId(d, 'ほか'), SID2);
  assert.equal(srv.findAutonomousSessionId(d, 'none'), '');
  // 系譜の保存/読み出し
  const w = path.join(TMP, 'web-lineage');
  fs.rmSync(w, { recursive: true, force: true });
  assert.equal(srv.writeWebLineage(w, 'a/b', SID1, ''), true);
  assert.equal(srv.readWebLineage(w, 'a/b'), SID1);
  assert.equal(srv.writeWebLineage(w, 'a/b', 'bad', ''), false);
  // projects_dir の外へ出るシンボリックリンクは拒否
  const pd = path.join(TMP, 'projdir');
  fs.rmSync(pd, { recursive: true, force: true });
  fs.mkdirSync(path.join(pd, 'ok'), { recursive: true });
  fs.symlinkSync(TMP, path.join(pd, 'escape'));
  assert.equal(srv.resolveProjectDir({ projects_dir: pd }, 'ok'), fs.realpathSync(path.join(pd, 'ok')));
  assert.equal(srv.resolveProjectDir({ projects_dir: pd }, 'escape'), '');
  assert.equal(srv.resolveProjectDir({ projects_dir: pd }, '../x'), '');
  assert.equal(srv.resolveProjectDir({}, 'ok'), '');
});

test('prompt: confirm 無しは実行せず確認内容 (Human Gate) を返す', async () => {
  const f = promptFixture('gate');
  await withPromptEnv(f, 'ok', async () => {
    await withServer(f.cfg(), async (port) => {
      const r = await pp(port, { project: 'Alpha-App', text: 'こんにちは', model: 'sonnet' });
      assert.equal(r.status, 200);
      assert.equal(r.json.requiresConfirm, true);
      assert.equal(r.json.resumed, false);
      assert.match(r.json.command, /^claude -p --output-format stream-json .* -- <本文 5 文字>$/);
      assert.ok(!r.json.command.includes('-- --'), '確認画面のコマンドで -- が二重にならない');
      assert.ok(!r.json.command.includes('こんにちは'), '確認画面のコマンドに本文は含めない');
      assert.equal(argvLines(f).length, 0, '実行していない');
    });
  });
});

test('prompt: confirm 付きは NDJSON でストリーミングし、会話系譜を保存して次回は --resume する', async () => {
  const f = promptFixture('stream');
  await withPromptEnv(f, 'ok', async () => {
    await withServer(f.cfg(), async (port) => {
      const r = await pp(port, { project: 'Alpha-App', text: 'hello', confirm: true });
      assert.equal(r.status, 200);
      assert.match(r.headers['content-type'], /application\/x-ndjson/);
      const ev = ndjson(r.body);
      assert.equal(ev[0].type, 'web/start');
      assert.equal(ev[0].resumed, false);
      assert.ok(ev.some(e => e.type === 'system' && e.subtype === 'init'));
      assert.ok(ev.some(e => e.type === 'assistant'));
      assert.ok(ev.some(e => e.type === 'web/raw' && e.text === 'not-json line'), 'JSON でない行は web/raw として包む');
      assert.ok(ev.some(e => e.type === 'result'));
      const end = ev[ev.length - 1];
      assert.equal(end.type, 'web/end');
      assert.equal(end.exitCode, 0);
      assert.equal(end.sessionId, SID1);
      assert.equal(srv.readWebLineage(f.web, 'Alpha-App'), SID1, '会話系譜を保存した');
      const first = argvLines(f)[0];
      assert.ok(first.includes('--permission-prompts none') && first.includes('--max-budget-usd 2') && first.includes('-- hello'));
      assert.ok(!first.includes('--resume'), '初回は新規会話');

      const r2 = await pp(port, { project: 'Alpha-App', text: 'next', confirm: true });
      const ev2 = ndjson(r2.body);
      assert.equal(ev2[0].resumed, true);
      const second = argvLines(f)[1];
      assert.ok(second.includes('--resume ' + SID1), '2 回目は Web の会話系譜を --resume');
      assert.ok(!second.includes('--fork-session'));
    });
  });
});

test('prompt: 初回は直近の自律セッションを --fork-session で分岐する (元の会話に書き込まない)', async () => {
  const f = promptFixture('fork');
  fs.writeFileSync(path.join(f.sess, '20260101-Alpha-App.json'), JSON.stringify({ project: 'Alpha-App', sessionId: SID2 }));
  await withPromptEnv(f, 'ok', async () => {
    await withServer(f.cfg(), async (port) => {
      const r = await pp(port, { project: 'Alpha-App', text: 'hi', confirm: true });
      const ev = ndjson(r.body);
      assert.equal(ev[0].resumed, true);
      assert.equal(ev[0].forked, true);
      assert.ok(argvLines(f)[0].includes('--resume ' + SID2 + ' --fork-session'));
      assert.equal(srv.readWebLineage(f.web, 'Alpha-App'), SID1, '以後は分岐後の Web 専用 ID を使う');
    });
  });
});

test('prompt: 入力検証 (長さ・空・NUL・モデル・未登録プロジェクト) と先頭が - の本文', async () => {
  const f = promptFixture('validate');
  await withPromptEnv(f, 'ok', async () => {
    await withServer(f.cfg(), async (port) => {
      const post = (b) => pp(port, Object.assign({ project: 'Alpha-App', text: 'x', confirm: true }, b));
      assert.equal((await post({ text: 'x'.repeat(srv.PROMPT_MAX_CHARS + 1) })).json.error, 'PROMPT_TOO_LONG');
      assert.equal((await post({ text: '   ' })).json.error, 'PROMPT_REQUIRED');
      assert.equal((await post({ text: 'a\u0000b' })).json.error, 'PROMPT_INVALID');
      assert.equal((await post({ model: 'gpt-9' })).json.error, 'MODEL_INVALID');
      assert.equal((await post({ project: 'Nope' })).status, 400);
      assert.equal((await post({ project: '../etc' })).status, 400);
      assert.equal(argvLines(f).length, 0, '検証エラーでは実行しない');
      const r = await post({ text: '--help me' });
      assert.equal(r.status, 200);
      assert.ok(argvLines(f)[0].includes('-- --help me'), '先頭が - の本文もオプションにならない');
    });
  });
});

test('prompt: dryRunOnly では拒否し、Origin が不正な POST も拒否する', async () => {
  const f = promptFixture('guards');
  await withPromptEnv(f, 'ok', async () => {
    await withServer(f.cfg({ dryRunOnly: true }), async (port) => {
      const r = await pp(port, { project: 'Alpha-App', text: 'x', confirm: true });
      assert.equal(r.status, 403);
      assert.equal(r.json.error, 'DRY_RUN_ONLY');
    });
    await withServer(f.cfg(), async (port) => {
      const r = await pp(port, { project: 'Alpha-App', text: 'x', confirm: true }, { Origin: 'http://evil.example' });
      assert.equal(r.status, 403);
      assert.equal(r.json.error, 'ORIGIN_REJECTED');
    });
    assert.equal(argvLines(f).length, 0);
  });
});

test('prompt: 自律実行中 (state 上 running / supervisor 稼働) のプロジェクトには送らない', async () => {
  const f = promptFixture('running');
  await withPromptEnv(f, 'ok', async () => {
    await withServer(f.cfg(), async (port) => {
      // fixture の Beta-Site は running:true / headless
      const a = await pp(port, { project: 'Mirai-DX-Project/Beta-Site', text: 'x', confirm: true });
      assert.equal(a.status, 409);
      assert.equal(a.json.error, 'SESSION_RUNNING');
      // supervisor が稼働 (status=running かつ pid 生存) していれば Alpha-App も拒否
      fs.writeFileSync(path.join(f.sup, 'Alpha-App.json'), JSON.stringify({ status: 'running', pid: process.pid }));
      const b = await pp(port, { project: 'Alpha-App', text: 'x' });
      assert.equal(b.status, 409, '確認前の段階でも拒否 (無駄な確認をさせない)');
      assert.equal(b.json.error, 'SESSION_RUNNING');
      assert.equal(argvLines(f).length, 0);
    });
  });
});

test('prompt: claude の機能確認に失敗したら 503 (起動しない)、異常終了は web/end に stderr を載せる', async () => {
  const f = promptFixture('fail');
  await withPromptEnv(f, 'ok', async () => {
    await withServer(f.cfg({ claudeBin: path.join(f.base, 'no-such-claude') }), async (port) => {
      const r = await pp(port, { project: 'Alpha-App', text: 'x', confirm: true });
      assert.equal(r.status, 503);
      assert.equal(r.json.error, 'CLAUDE_UNAVAILABLE');
    });
  });
  await withPromptEnv(f, 'fail', async () => {
    await withServer(f.cfg(), async (port) => {
      const r = await pp(port, { project: 'Alpha-App', text: 'x', confirm: true });
      const end = ndjson(r.body).pop();
      assert.equal(end.type, 'web/end');
      assert.equal(end.exitCode, 3);
      assert.match(end.stderr, /boom/);
    });
  });
});

test('prompt: 子プロセスへ秘密の環境変数を渡さない (claude 自身の認証だけ残す)', async () => {
  const f = promptFixture('env');
  const keys = { ANTHROPIC_API_KEY: 'k', GITHUB_TOKEN: 'g', SERVICE_PASSWORD: 'p', MY_SECRET_X: 's', CLAUDE_CODE_OAUTH_TOKEN: 'keepme' };
  const saved = {};
  Object.keys(keys).forEach((k) => { saved[k] = process.env[k]; process.env[k] = keys[k]; });
  try {
    await withPromptEnv(f, 'ok', async () => {
      await withServer(f.cfg(), async (port) => {
        await pp(port, { project: 'Alpha-App', text: 'x', confirm: true });
        const envText = fs.readFileSync(f.env, 'utf8');
        assert.ok(envText.includes('CLAUDE_CODE_OAUTH_TOKEN=keepme'));
        ['ANTHROPIC_API_KEY=', 'GITHUB_TOKEN=', 'SERVICE_PASSWORD=', 'MY_SECRET_X='].forEach(k => assert.ok(!envText.includes(k), k + ' が渡っている'));
      });
    });
  } finally {
    Object.keys(keys).forEach((k) => { if (saved[k] === undefined) delete process.env[k]; else process.env[k] = saved[k]; });
  }
});

test('prompt: 同時 1 件 / クライアント切断で子プロセスを終了して解放する', async () => {
  const f = promptFixture('abort');
  await withPromptEnv(f, 'sleep', async () => {
    await withServer(f.cfg(), async (port) => {
      // 1 件目 (30 秒 sleep) を開始し、web/start を受け取るまで待つ
      const first = http.request({ host: '127.0.0.1', port, method: 'POST', path: '/api/session/prompt',
        headers: { 'Content-Type': 'application/json', Origin: 'http://127.0.0.1:' + port, 'Cf-Access-Jwt-Assertion': signJwt() } });
      const got = new Promise((resolve) => {
        first.on('response', (res) => { res.once('data', () => resolve(res)); });
      });
      first.on('error', () => { /* 切断時の ECONNRESET は想定内 */ });
      first.end(JSON.stringify({ project: 'Alpha-App', text: 'long', confirm: true }));
      const res1 = await got;
      // 実行中に 2 件目 → 409
      const second = await pp(port, { project: 'Alpha-App', text: 'again', confirm: true });
      assert.equal(second.status, 409);
      assert.equal(second.json.error, 'OPERATION_IN_PROGRESS');
      // 切断 → 子プロセス (sleep) が終了する
      for (let i = 0; i < 50 && !fs.existsSync(f.pid); i++) await new Promise(r => setTimeout(r, 100));
      const pid = Number(fs.readFileSync(f.pid, 'utf8').trim());
      assert.ok(pid > 0);
      res1.destroy();
      first.destroy();
      let alive = true;
      for (let i = 0; i < 60 && alive; i++) {
        await new Promise(r => setTimeout(r, 100));
        try { process.kill(pid, 0); } catch { alive = false; }
      }
      assert.equal(alive, false, '切断後も子プロセスが残っている');
      // 解放され、次の送信ができる
      await withPromptEnv(f, 'ok', async () => {
        const r3 = await pp(port, { project: 'Alpha-App', text: 'after', confirm: true });
        assert.equal(r3.status, 200);
      });
    });
  });
});

test('prompt: 時間上限を超えたら終了し timedOut を返す', async () => {
  const f = promptFixture('timeout');
  await withPromptEnv(f, 'sleep', async () => {
    await withServer(f.cfg({ promptTimeoutMs: 400 }), async (port) => {
      const r = await pp(port, { project: 'Alpha-App', text: 'x', confirm: true });
      const end = ndjson(r.body).pop();
      assert.equal(end.type, 'web/end');
      assert.equal(end.timedOut, true);
    });
  });
});

test('prompt: 既定で無効 (STARTUP_WEB_PROMPT_ENABLE 未設定は 403)。拒否は監査ログに残り、本文は記録しない', async () => {
  const f = promptFixture('disabled');
  await withPromptEnv(f, 'ok', async () => {
    await withServer(f.cfg({ promptEnabled: false }), async (port) => {
      const r = await pp(port, { project: 'Alpha-App', text: 'TOPSECRET-PROMPT-XYZ', confirm: true });
      assert.equal(r.status, 403);
      assert.equal(r.json.error, 'PROMPT_DISABLED');
      assert.equal(argvLines(f).length, 0);
    });
  });
  const audit = path.join(process.env.CLAUDEOS_HOME, 'logs', 'web-startup-audit.log');
  const log = fs.readFileSync(audit, 'utf8');
  assert.ok(log.includes('prompt-rejected') && log.includes('PROMPT_DISABLED'), '拒否も監査に残す');
  assert.ok(!log.includes('TOPSECRET-PROMPT-XYZ'), '監査ログに本文を残さない');
});

test('prompt: 認証 (Access JWT) — 無し/署名不正/aud 不一致/期限切れ/alg 不正は拒否、未設定でも拒否 (fail-closed)', async () => {
  const f = promptFixture('auth');
  const { privateKey: otherKey } = require('crypto').generateKeyPairSync('rsa', { modulusLength: 2048 });
  await withPromptEnv(f, 'ok', async () => {
    await withServer(f.cfg(), async (port) => {
      const post = (jwt) => req(port, 'POST', '/api/session/prompt', { project: 'Alpha-App', text: 'x', confirm: true },
        Object.assign({ Origin: 'http://127.0.0.1:' + port }, jwt === undefined ? {} : { 'Cf-Access-Jwt-Assertion': jwt }));
      const detail = async (jwt) => { const r = await post(jwt); assert.equal(r.status, 403); assert.equal(r.json.error, 'PROMPT_AUTH_FAILED'); return r.json.detail; };
      assert.equal(await detail(undefined), 'JWT_MALFORMED');
      assert.equal(await detail('a.b.c'), 'JWT_INVALID');
      assert.equal(await detail(signJwt({}, otherKey)), 'JWT_SIGNATURE');
      assert.equal(await detail(signJwt({ aud: ['other'] })), 'JWT_AUD');
      assert.equal(await detail(signJwt({ iss: 'https://evil.cloudflareaccess.com' })), 'JWT_ISS');
      assert.equal(await detail(signJwt({ exp: Math.floor(Date.now() / 1000) - 10 })), 'JWT_EXPIRED');
      assert.equal(await detail(signJwt({}, null, { alg: 'none' })), 'JWT_ALG');
      assert.equal(await detail(signJwt({}, null, { kid: 'unknown' })), 'JWT_KEY_UNKNOWN');
      assert.equal(argvLines(f).length, 0, '認証できないときは実行しない');
      const ok = await post(signJwt());
      assert.equal(ok.status, 200);
    });
    // 認証が一切設定されていなければ、有効化されていても拒否する
    await withServer(f.cfg({ accessTeamDomain: '', accessAud: '' }), async (port) => {
      const r = await pp(port, { project: 'Alpha-App', text: 'x', confirm: true });
      assert.equal(r.status, 403);
      assert.equal(r.json.error, 'PROMPT_AUTH_NOT_CONFIGURED');
    });
    // Basic パスワードが設定されていればそれで通る (共通の Basic 認証)
    await withServer(f.cfg({ accessTeamDomain: '', accessAud: '', authPass: 'pw' }), async (port) => {
      const basic = 'Basic ' + Buffer.from('claudeos:pw').toString('base64');
      const r = await req(port, 'POST', '/api/session/prompt', { project: 'Alpha-App', text: 'x', confirm: true },
        { Origin: 'http://127.0.0.1:' + port, Authorization: basic });
      assert.equal(r.status, 200);
      const bad = await req(port, 'POST', '/api/session/prompt', { project: 'Alpha-App', text: 'x', confirm: true },
        { Origin: 'http://127.0.0.1:' + port });
      assert.equal(bad.status, 401);
    });
  });
});

// F4 (QA TC-F4-08 / 人間判断 2026-11-23「1」= メール必須):
//   verifyAccessJwt は email クレームが無いと sub を email 欄へ入れて返すため、
//   authenticatePrompt は v.ok だけを見ると sub だけの JWT で送信できてしまう。
//   実起動・Systemd 再起動と同じ「メール形式」基準にそろえる。
test('F4: sub だけ / メール形式でない Access JWT ではプロンプト送信を実行しない (TC-F4-08)', async () => {
  const f = promptFixture('f4-email');
  const usageFile = path.join(f.web, 'usage-' + srv.usageDay() + '.json');
  await withPromptEnv(f, 'ok', async () => {
    await withServer(f.cfg(), async (port) => {
      const post = (jwt) => req(port, 'POST', '/api/session/prompt', { project: 'Alpha-App', text: 'x', confirm: true },
        { Origin: 'http://127.0.0.1:' + port, 'Cf-Access-Jwt-Assertion': jwt });
      // (a) email クレームが無く sub だけの JWT
      const subOnly = await post(signJwt({ email: undefined, sub: 'svc-abc-123' }));
      assert.equal(subOnly.status, 403);
      assert.equal(subOnly.json.error, 'PROMPT_AUTH_FAILED');
      assert.equal(subOnly.json.detail, 'NO_EMAIL');
      // (b) メール形式でない値
      const nonEmail = await post(signJwt({ email: 'svc-account' }));
      assert.equal(nonEmail.status, 403);
      assert.equal(nonEmail.json.error, 'PROMPT_AUTH_FAILED');
      assert.equal(nonEmail.json.detail, 'NO_EMAIL');
      assert.equal(argvLines(f).length, 0, '拒否では claude を起動しない');
      assert.equal(fs.existsSync(usageFile), false, '拒否では使用量を消費しない');
      // (c) メール形式は従来どおり通る (sub が併存していても可)
      const ok = await post(signJwt({ email: 'prompt-audit@example.test', sub: 'svc-abc-123' }));
      assert.equal(ok.status, 200);
    });
  });
  assert.equal(argvLines(f).length, 1, '成功した 1 回だけ claude を起動する');
  const usage = JSON.parse(fs.readFileSync(usageFile, 'utf8'));
  assert.equal(usage.count, 1, '使用量は成功の 1 回だけ');
  const log = fs.readFileSync(path.join(process.env.CLAUDEOS_HOME, 'logs', 'web-startup-audit.log'), 'utf8');
  assert.ok(log.includes('prompt-rejected') && log.includes('PROMPT_AUTH_FAILED'), '拒否は prompt-rejected として監査に残す');
  assert.ok(log.includes('prompt-audit@example.test'), '成功時の実行者はメールで監査する');
  assert.equal(log.includes('"user":"svc-abc-123"'), false, 'sub を実行者として記録しない');
});

test('F4: Basic 認証の経路は不変 (authUser がメール形式でなくても通る)', async () => {
  const f = promptFixture('f4-basic');
  await withPromptEnv(f, 'ok', async () => {
    await withServer(f.cfg({ accessTeamDomain: '', accessAud: '', authPass: 'pw', authUser: 'claudeos' }), async (port) => {
      const basic = 'Basic ' + Buffer.from('claudeos:pw').toString('base64');
      const r = await req(port, 'POST', '/api/session/prompt', { project: 'Alpha-App', text: 'x', confirm: true },
        { Origin: 'http://127.0.0.1:' + port, Authorization: basic });
      assert.equal(r.status, 200, 'Basic は変更しない');
    });
  });
  assert.equal(argvLines(f).length, 1);
});

test('prompt: Host 許可リスト・Origin 必須・JSON のみ・Sec-Fetch-Site (DNS rebinding / CSRF 対策)', async () => {
  const f = promptFixture('origin');
  await withPromptEnv(f, 'ok', async () => {
    await withServer(f.cfg({ allowedHosts: ['claude.example.com'] }), async (port) => {
      const body = { project: 'Alpha-App', text: 'x', confirm: true };
      // DNS rebinding: 攻撃者のドメインへ向けた Host / Origin は (一致していても) 拒否
      const a = await pp(port, body, { Host: 'evil.example', Origin: 'http://evil.example' });
      assert.equal(a.status, 403);
      assert.equal(a.json.error, 'HOST_REJECTED');
      // 公開ホスト名 (許可リスト) は通る
      const b = await pp(port, body, { Host: 'claude.example.com', Origin: 'https://claude.example.com' });
      assert.equal(b.status, 200);
      // Origin 無しは拒否 (curl や他のプロセスからの無署名 POST)
      const c = await req(port, 'POST', '/api/session/prompt', body, { 'Cf-Access-Jwt-Assertion': signJwt() });
      assert.equal(c.status, 403);
      assert.equal(c.json.error, 'ORIGIN_REQUIRED');
      // Content-Type が JSON でなければ拒否 (単純リクエストでの CSRF を避ける)
      const d = await pp(port, body, { 'Content-Type': 'text/plain' });
      assert.equal(d.status, 415);
      // クロスサイトのブラウザ文脈は拒否
      const e = await pp(port, body, { 'Sec-Fetch-Site': 'cross-site' });
      assert.equal(e.status, 403);
      assert.equal(e.json.error, 'CROSS_SITE_REJECTED');
      assert.equal(argvLines(f).length, 1, '通った 1 件 (公開ホスト) だけ実行された');
    });
  });
});

test('prompt: 本文が JSON オブジェクトでなければ 400 (null / 配列でサーバーが落ちない)', async () => {
  const f = promptFixture('body');
  await withPromptEnv(f, 'ok', async () => {
    await withServer(f.cfg(), async (port) => {
      for (const raw of ['null', '[]', '"x"', '5']) {
        const r = await new Promise((resolve, reject) => {
          const h = http.request({ host: '127.0.0.1', port, method: 'POST', path: '/api/session/prompt',
            headers: { 'Content-Type': 'application/json', Origin: 'http://127.0.0.1:' + port, 'Cf-Access-Jwt-Assertion': signJwt(), 'Content-Length': Buffer.byteLength(raw) } },
            (res) => { let d = ''; res.on('data', c => { d += c; }); res.on('end', () => resolve({ status: res.statusCode, body: d })); });
          h.on('error', reject);
          h.end(raw);
        });
        assert.equal(r.status, 400, raw);
      }
      const alive = await pp(port, { project: 'Alpha-App', text: 'x' });
      assert.equal(alive.status, 200, 'サーバーは生きている');
    });
  });
});

test('prompt: 予算・時間の設定が不正でも上限は無効化されない (NaN / 0 / 負数は既定値へ)', async () => {
  assert.equal(srv.positiveNumber('abc', 2), 2);
  assert.equal(srv.positiveNumber(0, 2), 2);
  assert.equal(srv.positiveNumber(-1, 2), 2);
  assert.equal(srv.positiveNumber(undefined, 2), 2);
  assert.equal(srv.positiveNumber('0.5', 2), 0.5);
  const f = promptFixture('budget');
  const keep = process.env.STARTUP_WEB_PROMPT_BUDGET_USD;
  process.env.STARTUP_WEB_PROMPT_BUDGET_USD = 'abc';
  try {
    await withPromptEnv(f, 'ok', async () => {
      await withServer(f.cfg(), async (port) => {
        const r = await pp(port, { project: 'Alpha-App', text: 'x', confirm: true });
        assert.equal(r.status, 200);
        assert.ok(argvLines(f)[0].includes('--max-budget-usd 2'), '不正値でも既定の上限が付く');
      });
    });
  } finally {
    if (keep === undefined) delete process.env.STARTUP_WEB_PROMPT_BUDGET_USD; else process.env.STARTUP_WEB_PROMPT_BUDGET_USD = keep;
  }
});

test('prompt: ブラウザへ中継するイベントは許可リスト (ツール結果・入力・hook は中継しない)', () => {
  const s = srv.sanitizePromptEvent;
  assert.equal(s({ type: 'system', subtype: 'hook_response', output: 'x' }), null);
  assert.equal(s({ type: 'rate_limit_event' }), null);
  assert.deepEqual(s({ type: 'user', message: { content: [{ type: 'tool_result', content: 'FILE CONTENTS SECRET' }] } }), { type: 'user' });
  const a = s({ type: 'assistant', message: { content: [{ type: 'text', text: 'hi' }, { type: 'tool_use', name: 'Bash', input: { command: 'cat ~/.env' } }, { type: 'thinking', thinking: 'x' }] } });
  assert.deepEqual(a.message.content, [{ type: 'text', text: 'hi' }, { type: 'tool_use', name: 'Bash' }], 'tool_use の入力は中継しない');
  assert.equal(s({ type: 'stream_event', event: { type: 'content_block_start' } }), null);
  assert.equal(s({ type: 'stream_event', event: { type: 'content_block_delta', delta: { type: 'input_json_delta', partial_json: '{' } } }), null);
  assert.equal(s({ type: 'stream_event', event: { type: 'content_block_delta', delta: { type: 'text_delta', text: 'a' } } }).event.delta.text, 'a');
  assert.equal(s({ type: 'system', subtype: 'init', session_id: SID1, model: 'm', permissionMode: 'plan', cwd: '/secret', tools: ['x'] }).cwd, undefined);
  assert.equal(s({ type: 'result', subtype: 'success', result: 'ok', total_cost_usd: 0.1, session_id: SID1, usage: { x: 1 } }).usage, undefined);
});

test('prompt: 中断/切断で孫プロセスも停止する (プロセスグループ)', async () => {
  const f = promptFixture('group');
  await withPromptEnv(f, 'grandchild', async () => {
    await withServer(f.cfg(), async (port) => {
      const first = http.request({ host: '127.0.0.1', port, method: 'POST', path: '/api/session/prompt',
        headers: { 'Content-Type': 'application/json', Origin: 'http://127.0.0.1:' + port, 'Cf-Access-Jwt-Assertion': signJwt() } });
      const got = new Promise((resolve) => { first.on('response', (res) => { res.once('data', () => resolve(res)); }); });
      first.on('error', () => { /* 切断時は想定内 */ });
      first.end(JSON.stringify({ project: 'Alpha-App', text: 'long', confirm: true }));
      const res1 = await got;
      for (let i = 0; i < 50 && !fs.existsSync(f.gpid); i++) await new Promise(r => setTimeout(r, 100));
      const child = Number(fs.readFileSync(f.pid, 'utf8').trim());
      const grand = Number(fs.readFileSync(f.gpid, 'utf8').trim());
      assert.ok(child > 0 && grand > 0);
      res1.destroy();
      first.destroy();
      const alive = (p) => { try { process.kill(p, 0); return true; } catch { return false; } };
      for (let i = 0; i < 80 && (alive(child) || alive(grand)); i++) await new Promise(r => setTimeout(r, 100));
      assert.equal(alive(child), false, 'claude 本体が残っている');
      assert.equal(alive(grand), false, '孫プロセス (ツールが起動したもの) が残っている');
    });
  });
});

test('prompt: 孫が stdout を握ったままでも、終了後 数秒でロックを解放して応答を終える', async () => {
  const f = promptFixture('holdpipe');
  await withPromptEnv(f, 'holdpipe', async () => {
    await withServer(f.cfg(), async (port) => {
      const t0 = Date.now();
      const r = await pp(port, { project: 'Alpha-App', text: 'x', confirm: true });
      assert.equal(r.status, 200);
      assert.ok(Date.now() - t0 < 12000, '孫 (20 秒) の終了を待たずに確定する');
      assert.equal(ndjson(r.body).pop().type, 'web/end');
      const r2 = await pp(port, { project: 'Alpha-App', text: 'again', confirm: true });
      assert.equal(r2.status, 200, 'ロックが解放されている');
    });
  });
});

test('prompt: resume に失敗した系譜は捨てて、次回は新規会話から始められる', async () => {
  const f = promptFixture('lineage-reset');
  srv.writeWebLineage(f.web, 'Alpha-App', SID2, '');
  await withPromptEnv(f, 'noresult', async () => {
    await withServer(f.cfg(), async (port) => {
      const r = await pp(port, { project: 'Alpha-App', text: 'x', confirm: true });
      const end = ndjson(r.body).pop();
      assert.equal(end.type, 'web/end');
      assert.equal(end.lineageReset, true);
      assert.equal(srv.readWebLineage(f.web, 'Alpha-App'), '', '壊れた系譜を捨てた');
    });
  });
  await withPromptEnv(f, 'ok', async () => {
    await withServer(f.cfg(), async (port) => {
      const r = await pp(port, { project: 'Alpha-App', text: 'again', confirm: true });
      assert.equal(ndjson(r.body)[0].resumed, false, '新規会話から再開できる');
    });
  });
});

test('prompt: 系譜ファイルは project ごとに分離され、別 project の ID は使わない', () => {
  const d = path.join(TMP, 'lineage-sep');
  fs.rmSync(d, { recursive: true, force: true });
  assert.notEqual(srv.webLineageFile(d, 'a.b'), srv.webLineageFile(d, 'a_b'), 'safe 名が同じでもファイルは別');
  srv.writeWebLineage(d, 'a.b', SID1, '');
  assert.equal(srv.readWebLineage(d, 'a.b'), SID1);
  assert.equal(srv.readWebLineage(d, 'a_b'), '');
  // ファイルを別 project の位置へ置き換えられても、project 不一致なら使わない
  fs.copyFileSync(srv.webLineageFile(d, 'a.b'), srv.webLineageFile(d, 'a_b'));
  assert.equal(srv.readWebLineage(d, 'a_b'), '');
  srv.removeWebLineage(d, 'a.b');
  assert.equal(srv.readWebLineage(d, 'a.b'), '');
});

test('prompt: 会話の実行中は同じプロジェクトを起動できない (逆方向の排他)', async () => {
  const f = promptFixture('exclusive');
  await withPromptEnv(f, 'sleep', async () => {
    await withServer(f.cfg(), async (port) => {
      const first = http.request({ host: '127.0.0.1', port, method: 'POST', path: '/api/session/prompt',
        headers: { 'Content-Type': 'application/json', Origin: 'http://127.0.0.1:' + port, 'Cf-Access-Jwt-Assertion': signJwt() } });
      const got = new Promise((resolve) => { first.on('response', (res) => { res.once('data', () => resolve(res)); }); });
      first.on('error', () => { /* 切断時は想定内 */ });
      first.end(JSON.stringify({ project: 'Alpha-App', text: 'long', confirm: true }));
      const res1 = await got;
      const l = await req(port, 'POST', '/api/startup/launch', { project: 'Alpha-App', mode: 'background', duration: 60, confirm: true });
      assert.equal(l.status, 409);
      assert.equal(l.json.error, 'PROMPT_IN_PROGRESS');
      res1.destroy();
      first.destroy();
      for (let i = 0; i < 50; i++) { await new Promise(r => setTimeout(r, 100)); }
    });
  });
});

test('prompt: 系譜を捨てるのは resume 自体が失敗したときだけ (エラー結果・タイムアウトでは会話を保持する)', async () => {
  const f = promptFixture('lineage-keep');
  srv.writeWebLineage(f.web, 'Alpha-App', SID2, '');
  // 予算超過などのエラー結果 (init は来ている) → 会話は claude 側に残っているので保持する
  await withPromptEnv(f, 'errresult', async () => {
    await withServer(f.cfg(), async (port) => {
      const r = await pp(port, { project: 'Alpha-App', text: 'x', confirm: true });
      const end = ndjson(r.body).pop();
      assert.equal(end.exitCode, 1);
      assert.equal(end.lineageReset, false);
      assert.equal(srv.readWebLineage(f.web, 'Alpha-App'), SID1, '会話 (session_id) を保持・更新する');
    });
  });
  // タイムアウト (init 後に長時間実行) → 保持する
  srv.writeWebLineage(f.web, 'Alpha-App', SID2, '');
  await withPromptEnv(f, 'initsleep', async () => {
    await withServer(f.cfg({ promptTimeoutMs: 400 }), async (port) => {
      const r = await pp(port, { project: 'Alpha-App', text: 'x', confirm: true });
      const end = ndjson(r.body).pop();
      assert.equal(end.timedOut, true);
      assert.equal(end.lineageReset, false);
      assert.notEqual(srv.readWebLineage(f.web, 'Alpha-App'), '', 'タイムアウトでも会話を失わない');
    });
  });
});

test('prompt: JWT の kid は文字列必須 / JWKS 取得失敗は区別 / 未知 kid は鍵を 1 度だけ再取得 (ローテーション)', async () => {
  const f = promptFixture('jwks');
  await withPromptEnv(f, 'ok', async () => {
    const body = { project: 'Alpha-App', text: 'x', confirm: true };
    await withServer(f.cfg(), async (port) => {
      const r = await pp(port, body, { 'Cf-Access-Jwt-Assertion': signJwt({}, null, { kid: undefined }) });
      assert.equal(r.json.detail, 'JWT_KEY_UNKNOWN', 'kid が無いトークンは拒否');
    });
    await withServer(f.cfg({ accessKeys: async () => { throw new Error('network down'); } }), async (port) => {
      const r = await pp(port, body);
      assert.equal(r.status, 403);
      assert.equal(r.json.detail, 'JWKS_UNAVAILABLE', '鍵を取得できないときは fail-closed で、理由を区別する');
    });
    const calls = [];
    await withServer(f.cfg({ accessKeys: async (force) => { calls.push(!!force); return force ? [ACC_JWK] : []; } }), async (port) => {
      const r = await pp(port, body);
      assert.equal(r.status, 200, '鍵のローテーション直後でも、再取得して検証できる');
      assert.deepEqual(calls, [false, true]);
    });
  });
});

test('prompt: 認証前の拒否の監査は同じ理由につき 1 分に 1 件へ間引く (ログ肥大の防止)', async () => {
  const f = promptFixture('audit-throttle');
  const audit = path.join(process.env.CLAUDEOS_HOME, 'logs', 'web-startup-audit.log');
  const count = () => (fs.existsSync(audit) ? fs.readFileSync(audit, 'utf8').split('\n').filter(l => l.includes('prompt-rejected') && l.includes('HOST_REJECTED')).length : 0);
  const before = count();
  await withPromptEnv(f, 'ok', async () => {
    await withServer(f.cfg(), async (port) => {
      for (let i = 0; i < 5; i++) {
        const r = await pp(port, { project: 'Alpha-App', text: 'x', confirm: true }, { Host: 'evil.example', Origin: 'http://evil.example' });
        assert.equal(r.json.error, 'HOST_REJECTED');
      }
    });
  });
  assert.equal(count() - before, 1, '5 回拒否しても監査は 1 件');
});

// ---------------------------------------------------------------------------
// 6) 登録外フォルダ (all_folders 由来) の稼働判定 — 停止ボタンが NOT_RUNNING にならないこと
// ---------------------------------------------------------------------------
test('isProjectRunning: 登録済み running に加え、state.sessions (headless / foreground / tmux) でも判定する', () => {
  const st = { projects: [{ name: 'Reg', running: true }, { name: 'Idle', running: false }],
    sessions: { headless: ['Gamma'], foreground: ['Fg'], tmux: ['claudeos-Business-Project_X', 'claudeos-team-Tm'] } };
  assert.equal(srv.isProjectRunning(st, 'Reg'), true);
  assert.equal(srv.isProjectRunning(st, 'Idle'), false);
  assert.equal(srv.isProjectRunning(st, 'Gamma'), true, '登録外でも headless の稼働を認識する');
  assert.equal(srv.isProjectRunning(st, 'Fg'), true);
  assert.equal(srv.isProjectRunning(st, 'Business-Project/X'), true, 'tmux 名 (/ は _) から判定する');
  assert.equal(srv.isProjectRunning(st, 'Tm'), true);
  assert.equal(srv.isProjectRunning(st, 'Nope'), false);
  assert.equal(srv.isProjectRunning({}, 'Reg'), false);
});

test('HTTP: 登録外フォルダの稼働中セッションも停止できる (NOT_RUNNING にならない)', async () => {
  const root = path.join(TMP, 'repo-stop-unreg');
  fs.rmSync(root, { recursive: true, force: true });
  fs.mkdirSync(path.join(root, 'libexec'), { recursive: true });
  const base = fs.readFileSync(path.join(FIXTURE, 'libexec', 'startup-state.sh'), 'utf8');
  const a = base.indexOf("<<'JSON'\n") + "<<'JSON'\n".length;
  const b = base.lastIndexOf('\nJSON\n');
  const state = JSON.parse(base.slice(a, b));
  state.all_folders = ['Gamma', 'Delta'];                 // 登録外のフォルダ
  state.sessions.headless = ['Gamma'];                    // Gamma だけが稼働中
  fs.writeFileSync(path.join(root, 'libexec', 'startup-state.sh'),
    '#!/usr/bin/env bash\ncat <<\'JSON\'\n' + JSON.stringify(state) + '\nJSON\n');
  await withServer({ root }, async (port) => {
    const run = await req(port, 'POST', '/api/startup/stop', { project: 'Gamma' });
    assert.equal(run.status, 200, '稼働中の登録外フォルダは確認画面 (requiresConfirm) まで進む');
    assert.equal(run.json.requiresConfirm, true);
    const idle = await req(port, 'POST', '/api/startup/stop', { project: 'Delta' });
    assert.equal(idle.status, 409, '稼働していない登録外フォルダは NOT_RUNNING');
    assert.equal(idle.json.error, 'NOT_RUNNING');
  });
});

// ---------------------------------------------------------------------------
// ハードニング (Approval PR): 環境変数 allowlist / 日次上限 / 変更系の共通検査 / apply-all の排他
// ---------------------------------------------------------------------------
test('hardening: scrubEnv は allowlist 方式 (未知の名前は渡さない・接頭辞内の秘密は除く・運用者の明示は渡す)', () => {
  const e = srv.scrubEnv({
    PATH: '/bin', HOME: '/h', LANG: 'ja', LC_ALL: 'C', XDG_RUNTIME_DIR: '/run', CLAUDE_CONFIG_DIR: '/c', ANTHROPIC_BASE_URL: 'https://x',
    SOME_APP_VAR: 'v', GIT_ASKPASS: 'a', MY_INTERNAL_URL: 'u',                   // allowlist に無い → 渡さない
    ANTHROPIC_API_KEY: 'k', CLAUDE_FOO_TOKEN: 't', CLAUDE_CODE_OAUTH_TOKEN: 'keep',  // 接頭辞に合っても秘密らしい名前は除く / 認証は残す
  });
  assert.deepEqual(Object.keys(e).sort(),
    ['ANTHROPIC_BASE_URL', 'CLAUDE_CODE_OAUTH_TOKEN', 'CLAUDE_CONFIG_DIR', 'HOME', 'LANG', 'LC_ALL', 'PATH', 'XDG_RUNTIME_DIR']);
  const x = srv.scrubEnv({ SOME_APP_VAR: 'v', ANTHROPIC_API_KEY: 'k', OTHER: 'o' }, ['SOME_APP_VAR', 'ANTHROPIC_API_KEY']);
  assert.deepEqual(Object.keys(x).sort(), ['ANTHROPIC_API_KEY', 'SOME_APP_VAR'], '運用者が明示した名前は allowlist / denylist を越えて渡る');
});

test('hardening: 日次使用量のヘルパ (読み書き・上限判定・古い日の掃除・破損ファイルは 0 扱い)', () => {
  const dir = path.join(TMP, 'usage-helper');
  fs.rmSync(dir, { recursive: true, force: true });
  const day = srv.usageDay(new Date(2026, 10, 5));
  assert.equal(day, '2026-11-05');
  assert.deepEqual(srv.readPromptUsage(dir, day), { day, count: 0, spentUsd: 0 });
  // 掃除は「今日より古い日」だけ。日付をまたぐ精算 (昨日のファイルへの書き込み) で当日分を消さない
  const today = srv.usageDay();
  const yesterday = srv.usageDay(new Date(Date.now() - 86400000));
  const old = srv.usageDay(new Date(Date.now() - 5 * 86400000));
  assert.equal(srv.writePromptUsage(dir, { day: old, count: 3, spentUsd: 1.5 }), true);
  assert.equal(srv.writePromptUsage(dir, { day: today, count: 2, spentUsd: 0.5 }), true);
  assert.equal(srv.writePromptUsage(dir, { day: yesterday, count: 1, spentUsd: 0.2 }), true, '昨日 (日付またぎ) の精算');
  assert.deepEqual(fs.readdirSync(dir).sort(), ['usage-' + yesterday + '.json', 'usage-' + today + '.json'].sort(), '当日分は消えず、古い日だけ掃除される');
  assert.equal(srv.readPromptUsage(dir, today).count, 2, '当日の使用量は日付またぎの精算でリセットされない');
  fs.writeFileSync(path.join(dir, 'usage-' + today + '.json'), '{broken');
  const bad = srv.readPromptUsage(dir, today);
  assert.equal(bad.corrupt, true, '破損は「不明」(fail-closed)');
  assert.equal(srv.checkPromptDailyLimit(bad, { maxCount: 99, budgetUsd: 99, perRunUsd: 1 }).error, 'PROMPT_USAGE_UNREADABLE');
  assert.deepEqual(srv.readPromptUsage(dir, '2000-01-01'), { day: '2000-01-01', count: 0, spentUsd: 0 }, 'ファイル無しは 0');
  const lim = { maxCount: 2, budgetUsd: 3, perRunUsd: 1 };
  assert.equal(srv.checkPromptDailyLimit({ count: 2, spentUsd: 0 }, lim).error, 'PROMPT_DAILY_LIMIT');
  assert.equal(srv.checkPromptDailyLimit({ count: 1, spentUsd: 2.5 }, lim).error, 'PROMPT_DAILY_BUDGET');
  assert.equal(srv.checkPromptDailyLimit({ count: 1, spentUsd: 2 }, lim).ok, true);
});

test('hardening: 日次の回数上限と累計予算 (実コストで精算し、上限到達で 429)', async () => {
  const f = promptFixture('daily');
  await withPromptEnv(f, 'ok', async () => {
    // 回数上限 1: 1 件目は通り、2 件目は 429
    await withServer(f.cfg({ promptDailyMax: 1 }), async (port) => {
      const pre = await pp(port, { project: 'Alpha-App', text: 'x' });
      assert.equal(pre.json.daily.count, 0);
      assert.equal(pre.json.daily.max, 1);
      const r1 = await pp(port, { project: 'Alpha-App', text: 'x', confirm: true });
      assert.equal(r1.status, 200);
      const u = srv.readPromptUsage(f.web, srv.usageDay());
      assert.equal(u.count, 1);
      assert.ok(Math.abs(u.spentUsd - 0.01) < 1e-9, '予約 (予算 2 USD) ではなく実コスト 0.01 USD で精算される: ' + u.spentUsd);
      const r2 = await pp(port, { project: 'Alpha-App', text: 'y', confirm: true });
      assert.equal(r2.status, 429);
      assert.equal(r2.json.error, 'PROMPT_DAILY_LIMIT');
      const pre2 = await pp(port, { project: 'Alpha-App', text: 'y' });
      assert.equal(pre2.status, 429, 'プレビューの時点でも拒否する');
    });
    // 累計予算: 既に 0.01 USD 使用済み。上限 2.005 USD、1 回の予算 2 USD → 0.01 + 2 > 2.005 で拒否
    await withServer(f.cfg({ promptDailyBudgetUsd: 2.005, promptDailyMax: 50 }), async (port) => {
      const r = await pp(port, { project: 'Alpha-App', text: 'z', confirm: true });
      assert.equal(r.status, 429);
      assert.equal(r.json.error, 'PROMPT_DAILY_BUDGET');
      assert.equal(srv.readPromptUsage(f.web, srv.usageDay()).count, 1, '拒否した送信は回数に数えない');
    });
  });
});

test('hardening: 使用量を書き込めないときは送信しない (上限を守れないため)', async () => {
  const f = promptFixture('usage-fail');
  fs.mkdirSync(f.web, { recursive: true });
  fs.writeFileSync(path.join(f.web, 'blocker'), 'x');
  await withPromptEnv(f, 'ok', async () => {
    // webPromptDir にファイルを指定 → mkdir/書き込みが失敗する
    await withServer(f.cfg({ webPromptDir: path.join(f.web, 'blocker') }), async (port) => {
      const r = await pp(port, { project: 'Alpha-App', text: 'x', confirm: true });
      assert.equal(r.status, 500);
      assert.equal(r.json.error, 'USAGE_WRITE_FAILED');
      assert.equal(fs.existsSync(f.argv), false, 'claude は起動していない');
    });
  });
});

test('hardening: 変更系 POST の共通検査 (Host 許可リスト / JSON のみ / Sec-Fetch-Site)', async () => {
  await withServer({}, async (port) => {
    const evil = await req(port, 'POST', '/api/startup/stop', { project: 'Alpha' }, { Host: 'evil.example.com' });
    assert.equal(evil.status, 403);
    assert.equal(evil.json.error, 'HOST_REJECTED', 'DNS rebinding: 許可リスト外の名前は拒否');
    const lan = await req(port, 'POST', '/api/startup/stop', { project: 'Alpha' }, { Host: '192.168.1.10:3812' });
    assert.notEqual(lan.status, 403, 'IP リテラルは許可 (DNS 名を使う rebinding の対象外)');
    const text = await req(port, 'POST', '/api/startup/stop', { project: 'Alpha' }, { 'Content-Type': 'text/plain' });
    assert.equal(text.status, 415);
    assert.equal(text.json.error, 'UNSUPPORTED_MEDIA_TYPE');
    const cross = await req(port, 'POST', '/api/startup/stop', { project: 'Alpha' }, { 'Sec-Fetch-Site': 'cross-site' });
    assert.equal(cross.status, 403);
    assert.equal(cross.json.error, 'CROSS_SITE_REJECTED');
    const same = await req(port, 'POST', '/api/startup/stop', { project: 'Alpha' }, { 'Sec-Fetch-Site': 'same-origin' });
    assert.notEqual(same.status, 403);
    const get = await req(port, 'GET', '/api/startup/state', undefined, { Host: 'evil.example.com' });
    assert.equal(get.status, 200, '読み取り (GET) は対象外');
  });
  await withServer({ allowedHosts: ['claude-startuptools.example.com'] }, async (port) => {
    const ok = await req(port, 'POST', '/api/startup/stop', { project: 'Alpha' }, { Host: 'claude-startuptools.example.com' });
    assert.notEqual(ok.status, 403, '許可リストの公開ホスト名は通る');
  });
});

test('hardening: Web 会話の実行中は apply-all を実適用しない (起動と同じ排他)', async () => {
  const f = promptFixture('applyall-excl');
  await withPromptEnv(f, 'sleep', async () => {
    await withServer(f.cfg(), async (port) => {
      const first = http.request({ host: '127.0.0.1', port, method: 'POST', path: '/api/session/prompt',
        headers: { 'Content-Type': 'application/json', Origin: 'http://127.0.0.1:' + port, 'Cf-Access-Jwt-Assertion': signJwt() } });
      const got = new Promise((resolve) => { first.on('response', (res) => { res.once('data', () => resolve(res)); }); });
      first.on('error', () => { /* 切断時の ECONNRESET は想定内 */ });
      first.end(JSON.stringify({ project: 'Alpha-App', text: 'long', confirm: true }));
      const res1 = await got;
      // スタブが pid を書くまで待つ (切断すると子を即停止するため、先に待たないと CI のような遅い環境で pid が書かれない)
      for (let i = 0; i < 100 && !fs.existsSync(f.pid); i++) await new Promise(r => setTimeout(r, 100));
      const blocked = await req(port, 'POST', '/api/startup/apply-all', { confirm: true });
      assert.equal(blocked.status, 409);
      assert.equal(blocked.json.error, 'PROMPT_IN_PROGRESS');
      const pid = fs.existsSync(f.pid) ? Number(fs.readFileSync(f.pid, 'utf8').trim()) : 0;
      res1.destroy();
      first.destroy();
      for (let i = 0; i < 60 && pid > 0; i++) { await new Promise(r => setTimeout(r, 100)); try { process.kill(pid, 0); } catch { break; } }
    });
  });
});

test('hardening: 起動できなかった送信 (spawn 失敗) は使用量に数えない / 使用量ファイル破損時は送信しない', async () => {
  const f = promptFixture('refund');
  // --help だけ成功し、その直後に自分自身を消す → 本番の spawn が ENOENT になる
  fs.writeFileSync(f.claude, '#!/usr/bin/env bash\nif [ "${1:-}" = "--help" ]; then echo "  --permission-prompts <target>"; rm -f "$0"; exit 0; fi\nexit 0\n', { mode: 0o755 });
  await withServer(f.cfg(), async (port) => {
    const r = await pp(port, { project: 'Alpha-App', text: 'x', confirm: true });
    assert.equal(r.status, 500);
    assert.equal(r.json.error, 'SPAWN_FAILED');
    const u = srv.readPromptUsage(f.web, srv.usageDay());
    assert.equal(u.count, 0, '起動できなかった送信は回数に数えない');
    assert.equal(u.spentUsd, 0, '確保した予算も戻る');
  });
  const g = promptFixture('corrupt');
  fs.mkdirSync(g.web, { recursive: true });
  fs.writeFileSync(path.join(g.web, 'usage-' + srv.usageDay() + '.json'), '{broken');
  await withPromptEnv(g, 'ok', async () => {
    await withServer(g.cfg(), async (port) => {
      const r = await pp(port, { project: 'Alpha-App', text: 'x', confirm: true });
      assert.equal(r.status, 429);
      assert.equal(r.json.error, 'PROMPT_USAGE_UNREADABLE');
      assert.equal(fs.existsSync(g.argv), false, '使用量が読めないときは claude を起動しない');
    });
  });
});

test('hardening: Host は大文字小文字を区別せず比較し、loopback はポート省略も許可する', async () => {
  await withServer({ allowedHosts: ['Claude-StartUpTools.Example.com'] }, async (port) => {
    const up = await req(port, 'POST', '/api/startup/stop', { project: 'Alpha' }, { Host: 'CLAUDE-startuptools.example.COM' });
    assert.notEqual(up.status, 403, '大文字小文字違いの Host は許可リストと一致扱い');
    const lo = await req(port, 'POST', '/api/startup/stop', { project: 'Alpha' }, { Host: 'localhost' });
    assert.notEqual(lo.status, 403, 'ポート省略の localhost (リバースプロキシ経由) も許可');
  });
});

// ---------------------------------------------------------------------------
// 変更系操作の「計画のみ」(段階 1): POST /api/ops/plan は CLI を必ず --dry-run 付きで実行し、実データを変更しない
// ---------------------------------------------------------------------------
function opsFixture() {
  const root = path.join(TMP, 'repo-ops-plan');
  fs.rmSync(root, { recursive: true, force: true });
  fs.mkdirSync(path.join(root, 'libexec'), { recursive: true });
  fs.mkdirSync(path.join(root, 'bin'), { recursive: true });
  fs.copyFileSync(path.join(FIXTURE, 'libexec', 'startup-state.sh'), path.join(root, 'libexec', 'startup-state.sh'));
  const calls = path.join(TMP, 'ops-plan-calls.txt');
  fs.rmSync(calls, { force: true });
  ['cron-schedule.sh', 'systemd-control.sh'].forEach((n) => {
    fs.writeFileSync(path.join(root, 'bin', n), '#!/usr/bin/env bash\nprintf "%s %s\\n" "' + n + '" "$*" >> "' + calls + '"\nprintf "\\033[32mPLAN\\033[0m %s\\n" "$*"\n', { mode: 0o755 });
  });
  return { root, calls, lines: () => (fs.existsSync(calls) ? fs.readFileSync(calls, 'utf8').split('\n').filter(Boolean) : []) };
}

test('ops-plan: cron add / systemd の計画は --dry-run 付きで実行し、出力 (ANSI 除去) を返す', async () => {
  const f = opsFixture();
  await withServer({ root: f.root }, async (port) => {
    const c = await req(port, 'POST', '/api/ops/plan', { op: 'cron-add', project: 'Alpha-App', time: '21:30', dow: '1,2,3', duration: 120 });
    assert.equal(c.status, 200);
    assert.equal(c.json.ok, true);
    assert.equal(c.json.dryRun, true);
    assert.equal(c.json.command, 'bash bin/cron-schedule.sh add --project Alpha-App --time 21:30 --dow 1,2,3 --duration 120 --dry-run');
    assert.equal(c.json.plan, 'PLAN add --project Alpha-App --time 21:30 --dow 1,2,3 --duration 120 --dry-run', 'ANSI 色コードは除去される');
    for (const verb of ['start', 'stop', 'restart', 'enable', 'disable']) {
      const s = await req(port, 'POST', '/api/ops/plan', { op: 'systemd-' + verb, project: 'Alpha-App' });
      assert.equal(s.status, 200, verb);
      assert.equal(s.json.command, 'bash bin/systemd-control.sh ' + verb + ' Alpha-App --dry-run');
    }
    const lines = f.lines();
    assert.equal(lines.length, 6);
    lines.forEach((l) => assert.ok(l.endsWith(' --dry-run'), '必ず --dry-run が付く: ' + l));
  });
});

test('ops-plan: 許可リスト外の操作・未登録プロジェクト・不正な引数は CLI を実行せず 400', async () => {
  const f = opsFixture();
  await withServer({ root: f.root }, async (port) => {
    const bad = [
      [{ op: 'cron-remove', project: 'Alpha-App' }, 'OP_INVALID'],
      [{ op: 'cron-run-now', project: 'Alpha-App' }, 'OP_INVALID'],
      [{ op: 'systemd-unregister', project: 'Alpha-App' }, 'OP_INVALID'],
      [{ op: '__proto__', project: 'Alpha-App' }, 'OP_INVALID'],
      [{ op: 'systemd-start', project: 'Nope' }, 'PROJECT_NOT_REGISTERED'],
      [{ op: 'systemd-start', project: 'Alpha-App\nx' }, 'PROJECT_INVALID'],
      [{ op: 'systemd-start', project: 'Alpha-App; rm -rf /' }, 'PROJECT_NOT_REGISTERED'],
      [{ op: 'cron-add', project: 'Alpha-App', time: '25:00', dow: '1', duration: 60 }, 'TIME_INVALID'],
      [{ op: 'cron-add', project: 'Alpha-App', time: '21:00', dow: '7', duration: 60 }, 'DOW_INVALID'],
      [{ op: 'cron-add', project: 'Alpha-App', time: '21:00', dow: '1;2', duration: 60 }, 'DOW_INVALID'],
      [{ op: 'cron-add', project: 'Alpha-App', time: '21:00', dow: '1', duration: 0 }, 'DURATION_INVALID'],
      [{ op: 'cron-add', project: 'Alpha-App', time: '21:00', dow: '1', duration: 5000 }, 'DURATION_INVALID'],
      [{ op: 'cron-add', project: 'Alpha-App', time: '21:00', dow: '1', duration: 60, goal: 'evil' }, 'GOAL_INVALID'],
    ];
    for (const [body, err] of bad) {
      const r = await req(port, 'POST', '/api/ops/plan', body);
      assert.equal(r.status, 400, JSON.stringify(body));
      assert.equal(r.json.error, err, JSON.stringify(body));
    }
    const arr = await req(port, 'POST', '/api/ops/plan', [1]);
    assert.equal(arr.status, 400);
    assert.equal(arr.json.error, 'BODY_NOT_OBJECT');
    assert.deepEqual(f.lines(), [], '検証に失敗した要求では CLI を実行しない');
  });
});

test('ops-plan: 共通の変更系検査 (Host) が掛かる', async () => {
  const f = opsFixture();
  await withServer({ root: f.root }, async (port) => {
    const r = await req(port, 'POST', '/api/ops/plan', { op: 'systemd-start', project: 'Alpha-App' }, { Host: 'evil.example.com' });
    assert.equal(r.status, 403);
    assert.deepEqual(f.lines(), []);
  });
});

test('ops-plan: duration の型を厳密に検査し、末尾改行の time を通さない (レビュー指摘)', async () => {
  const f = opsFixture();
  await withServer({ root: f.root }, async (port) => {
    const base = { op: 'cron-add', project: 'Alpha-App', time: '21:00', dow: '1' };
    for (const d of [true, [60], '1e2', '60 ', '-5', null, {}]) {
      const r = await req(port, 'POST', '/api/ops/plan', Object.assign({}, base, { duration: d }));
      assert.equal(r.status, 400, 'duration=' + JSON.stringify(d));
      assert.equal(r.json.error, 'DURATION_INVALID');
    }
    const ok = await req(port, 'POST', '/api/ops/plan', Object.assign({}, base, { duration: '60' }));
    assert.equal(ok.status, 200, '数字だけの文字列は許可');
    const nl = await req(port, 'POST', '/api/ops/plan', Object.assign({}, base, { time: '21:00\n', duration: 60 }));
    assert.equal(nl.json.error, 'TIME_INVALID');
    assert.equal(f.lines().length, 1, '検証に失敗した要求では CLI を実行しない');
  });
});

test('ops-plan: CLI が失敗したら ok:false と stderr を返し、出力は切り詰め、成功時は stderr を返さない', async () => {
  const f = opsFixture();
  fs.writeFileSync(path.join(f.root, 'bin', 'systemd-control.sh'),
    '#!/usr/bin/env bash\nif [ "$1" = "stop" ]; then echo "boom: /home/x/secret-path" >&2; exit 3; fi\nif [ "$1" = "start" ]; then head -c 20000 /dev/zero | tr "\\0" "A"; echo "noise" >&2; exit 0; fi\nexit 0\n', { mode: 0o755 });
  await withServer({ root: f.root }, async (port) => {
    const bad = await req(port, 'POST', '/api/ops/plan', { op: 'systemd-stop', project: 'Alpha-App' });
    assert.equal(bad.status, 200);
    assert.equal(bad.json.ok, false);
    assert.equal(bad.json.exitCode, 3);
    assert.match(bad.json.stderr, /boom/);
    const big = await req(port, 'POST', '/api/ops/plan', { op: 'systemd-start', project: 'Alpha-App' });
    assert.equal(big.json.ok, true);
    assert.equal(big.json.plan.length, 4000, '出力は 4000 文字で切り詰める');
    assert.equal(big.json.stderr, '', '成功時は stderr (環境依存の情報) を返さない');
  });
});

test('ops-plan: 同時実行の上限 (3 本まで。超えたら 429) と計画専用の短い制限時間', async () => {
  const f = opsFixture();
  fs.writeFileSync(path.join(f.root, 'bin', 'systemd-control.sh'), '#!/usr/bin/env bash\nsleep 1\necho done\n', { mode: 0o755 });
  await withServer({ root: f.root }, async (port) => {
    const rs = await Promise.all([1, 2, 3, 4, 5].map(() => req(port, 'POST', '/api/ops/plan', { op: 'systemd-start', project: 'Alpha-App' })));
    const codes = rs.map((r) => r.status).sort();
    assert.equal(codes.filter((c) => c === 200).length, 3, '同時に走るのは 3 本');
    assert.equal(codes.filter((c) => c === 429).length, 2);
    assert.equal(rs.find((r) => r.status === 429).json.error, 'OPS_PLAN_BUSY');
    const after = await req(port, 'POST', '/api/ops/plan', { op: 'systemd-start', project: 'Alpha-App' });
    assert.equal(after.status, 200, '解放されたら再び実行できる');
  });
  fs.writeFileSync(path.join(f.root, 'bin', 'systemd-control.sh'), '#!/usr/bin/env bash\nsleep 5\n', { mode: 0o755 });
  await withServer({ root: f.root, opsPlanTimeoutMs: 300 }, async (port) => {
    const t = await req(port, 'POST', '/api/ops/plan', { op: 'systemd-start', project: 'Alpha-App' });
    assert.equal(t.json.exitCode, 124, '制限時間で打ち切る');
    assert.equal(t.json.ok, false);
  });
});

// ---------------------------------------------------------------------------
// 変更系操作の実行 (段階 2 / Approval PR): POST /api/ops/systemd/restart
//   スタブの systemd-control.sh で、認証・フラグ・保護対象・日次上限・同時実行・成否判定・監査を検証する (実 systemd は触らない)。
// ---------------------------------------------------------------------------
function opsExecFixture(name) {
  const f = promptFixture('opsexec-' + name);
  fs.mkdirSync(path.join(f.root, 'bin'), { recursive: true });
  // 台帳 (固定フィクスチャ) の Beta-Site を保護対象の名前に差し替える
  const stPath = path.join(f.root, 'libexec', 'startup-state.sh');
  fs.writeFileSync(stPath, fs.readFileSync(stPath, 'utf8').split('Beta-Site').join('Cloudflared-Tools'));
  f.calls = path.join(f.base, 'ops-calls.txt');
  f.ops = path.join(f.base, 'web-ops');
  fs.writeFileSync(path.join(f.root, 'bin', 'systemd-control.sh'), [
    '#!/usr/bin/env bash',
    'printf "%s\\n" "$*" >> "' + f.calls + '"',
    '[ -f "' + path.join(f.base, 'slow') + '" ] && sleep 1',
    '[ -f "' + path.join(f.base, 'fail') + '" ] && { echo "Unit not loaded" >&2; exit 5; }',
    'echo "restart ok: $2"',
  ].join('\n') + '\n', { mode: 0o755 });
  f.callLines = () => (fs.existsSync(f.calls) ? fs.readFileSync(f.calls, 'utf8').split('\n').filter(Boolean) : []);
  f.cfg2 = (extra) => f.cfg(Object.assign({ opsRestartEnabled: true, webOpsDir: f.ops, opsDailyMax: 20 }, extra || {}));
  return f;
}
const rs = (port, body, headers) => req(port, 'POST', '/api/ops/systemd/restart', body,
  Object.assign({ Origin: 'http://127.0.0.1:' + port, 'Cf-Access-Jwt-Assertion': signJwt() }, headers || {}));

test('ops-restart: ヘルパ (checkOpsDailyLimit / isProtectedOpsTarget)', () => {
  assert.deepEqual(srv.checkOpsDailyLimit({ count: 0 }, 2), { ok: true });
  assert.equal(srv.checkOpsDailyLimit({ count: 2 }, 2).error, 'OPS_DAILY_LIMIT');
  assert.equal(srv.checkOpsDailyLimit({ count: 0, corrupt: true }, 2).error, 'OPS_USAGE_UNREADABLE', '破損は fail-closed');
  ['web-startup', 'Web-Startup-Tools', 'cloudflared', 'my-Tunnel-svc'].forEach(n => assert.equal(srv.isProtectedOpsTarget(n), true, n));
  ['Alpha-App', 'Mirai-DX-Project'].forEach(n => assert.equal(srv.isProtectedOpsTarget(n), false, n));
});

test('ops-restart: 子プロセスの環境は絞る (サーバーの秘密・claude の認証は渡さず、systemctl --user に必要な変数は通す)', () => {
  const e = srv.opsChildEnv({ PATH: '/bin', HOME: '/h', XDG_RUNTIME_DIR: '/run/user/1000', DBUS_SESSION_BUS_ADDRESS: 'unix:path=/run/user/1000/bus', CLAUDEOS_HOME: '/h/.claudeos',
    STARTUP_WEB_PASSWORD: 'p', CF_ACCESS_AUD: 'a', CLAUDE_CODE_OAUTH_TOKEN: 't', ANTHROPIC_API_KEY: 'k', GITHUB_TOKEN: 'g', MY_SECRET: 's', LANG: 'ja' });
  assert.deepEqual(Object.keys(e).sort(), ['CLAUDEOS_HOME', 'DBUS_SESSION_BUS_ADDRESS', 'HOME', 'LANG', 'PATH', 'XDG_RUNTIME_DIR']);
});

test('ops-restart: 既定で無効 (STARTUP_WEB_OPS_RESTART_ENABLE 未設定は 403 で何も実行しない)', async () => {
  const f = opsExecFixture('disabled');
  await withServer(f.cfg({}), async (port) => {
    const r = await rs(port, { project: 'Alpha-App', confirm: true });
    assert.equal(r.status, 403);
    assert.equal(r.json.error, 'OPS_DISABLED');
  });
  assert.equal(f.callLines().length, 0);
});

test('ops-restart: 認証は Access JWT のみ — JWT 無し/不正は拒否、Basic が設定されていても JWT 無しは拒否、Access 未設定は拒否 (fail-closed)', async () => {
  const f = opsExecFixture('auth');
  await withServer(f.cfg2({}), async (port) => {
    const noJwt = await req(port, 'POST', '/api/ops/systemd/restart', { project: 'Alpha-App', confirm: true }, { Origin: 'http://127.0.0.1:' + port });
    assert.equal(noJwt.json.error, 'OPS_AUTH_FAILED');
    const bad = await rs(port, { project: 'Alpha-App', confirm: true }, { 'Cf-Access-Jwt-Assertion': signJwt({ aud: ['other'] }) });
    assert.equal(bad.json.error, 'OPS_AUTH_FAILED');
    const noOrigin = await req(port, 'POST', '/api/ops/systemd/restart', { project: 'Alpha-App', confirm: true }, { 'Cf-Access-Jwt-Assertion': signJwt() });
    assert.equal(noOrigin.json.error, 'ORIGIN_REQUIRED', 'Origin 必須 (checkMutationRequest より厳格)');
  });
  // Basic だけ設定 (Access 無し): プロンプト送信なら通る構成でも、変更系は実行しない
  const basic = 'Basic ' + Buffer.from('u:pw').toString('base64');
  await withServer(f.cfg2({ authUser: 'u', authPass: 'pw', accessTeamDomain: '', accessAud: '' }), async (port) => {
    const r = await rs(port, { project: 'Alpha-App', confirm: true }, { Authorization: basic });
    assert.equal(r.status, 403);
    assert.equal(r.json.error, 'OPS_AUTH_NOT_CONFIGURED');
  });
  // Basic と Access の両方が設定されていても、JWT が無ければ Basic では実行しない
  await withServer(f.cfg2({ authUser: 'u', authPass: 'pw' }), async (port) => {
    const r = await req(port, 'POST', '/api/ops/systemd/restart', { project: 'Alpha-App', confirm: true }, { Origin: 'http://127.0.0.1:' + port, Authorization: basic });
    assert.equal(r.json.error, 'OPS_AUTH_FAILED');
  });
  assert.equal(f.callLines().length, 0, '拒否では systemd-control を一度も呼ばない');
});

test('ops-restart: 実行者 (メール) を特定できない JWT では実行しない', async () => {
  const f = opsExecFixture('noemail');
  await withServer(f.cfg2({}), async (port) => {
    const r = await rs(port, { project: 'Alpha-App', confirm: true }, { 'Cf-Access-Jwt-Assertion': signJwt({ email: '' }) });
    assert.equal(r.status, 403);
    assert.equal(r.json.error, 'OPS_AUTH_FAILED');
  });
  assert.equal(f.callLines().length, 0);
});

// BUG-09 (QA run_mwt5kqy1_4e9525ee / TC-F3-02):
//   verifyAccessJwt は email クレームが無いと sub を email 欄へ入れて返すため、
//   `!jwt.email` だけの判定では sub だけの Access JWT が変更系 API を実行できてしまう。
//   実起動 (requireLaunchJwt) と同じ「メール形式」基準にそろえる。
test('BUG-09: sub だけの Access JWT では systemd 再起動を実行しない (403 / 呼び出し 0 / 使用量を消費しない)', async () => {
  const f = opsExecFixture('bug09-subonly');
  await withServer(f.cfg2({}), async (port) => {
    const subOnly = await rs(port, { project: 'Alpha-App', confirm: true }, { 'Cf-Access-Jwt-Assertion': signJwt({ email: undefined, sub: 'svc-abc-123' }) });
    assert.equal(subOnly.status, 403, 'sub だけの JWT は実行者を特定できない');
    assert.equal(subOnly.json.error, 'OPS_AUTH_FAILED');
    const nonEmail = await rs(port, { project: 'Alpha-App', confirm: true }, { 'Cf-Access-Jwt-Assertion': signJwt({ email: 'svc-account' }) });
    assert.equal(nonEmail.status, 403, 'メール形式でない値も拒否する');
    assert.equal(nonEmail.json.error, 'OPS_AUTH_FAILED');
  });
  assert.equal(f.callLines().length, 0, 'systemd-control.sh を一度も呼ばない');
  // 拒否は使用量の確保より前なので、当日の使用量ファイル自体が作られない
  const usage = path.join(f.ops, 'usage-' + srv.usageDay() + '.json');
  assert.equal(fs.existsSync(usage), false, '拒否では使用量カウンタを消費しない');
});

test('BUG-09: メール形式の JWT は従来どおり実行し、監査の実行者はメール (sub ではない)', async () => {
  const f = opsExecFixture('bug09-ok');
  let log = '';
  await withServer(f.cfg2({}), async (port) => {
    const r = await rs(port, { project: 'Alpha-App', confirm: true }, { 'Cf-Access-Jwt-Assertion': signJwt({ email: 'ops-audit@example.test', sub: 'svc-abc-123' }) });
    assert.equal(r.status, 200, 'email と sub の両方がある JWT は通す');
    assert.equal(r.json.ok, true);
    assert.deepEqual(r.json.daily, { count: 1, max: 20 });
  });
  assert.deepEqual(f.callLines(), ['restart Alpha-App']);
  assert.equal(fs.existsSync(path.join(f.ops, 'usage-' + srv.usageDay() + '.json')), true, '成功時は使用量を 1 回消費する');
  log = fs.readFileSync(path.join(process.env.CLAUDEOS_HOME, 'logs', 'web-startup-audit.log'), 'utf8');
  assert.ok(log.includes('ops-restart') && log.includes('ops-audit@example.test'), '監査の実行者はメール');
  // sub だけの拒否が実行者として記録されていないこと (BUG-09 の回帰確認)
  assert.equal(log.includes('"user":"svc-abc-123"'), false, 'sub を実行者として記録しない');
});

test('BUG-09: isEmailLike — メール形式の判定 (実起動と変更系で共通)', () => {
  assert.equal(srv.isEmailLike('kensan@example.test'), true);
  assert.equal(srv.isEmailLike('svc-account'), false);
  assert.equal(srv.isEmailLike('svc-abc-123'), false);
  assert.equal(srv.isEmailLike(''), false);
  assert.equal(srv.isEmailLike(undefined), false);
  assert.equal(srv.isEmailLike(null), false);
});

test('ops-restart: confirm=true が無ければ実行しない。不正な project・保護対象 (web-startup / cloudflared / tunnel) は拒否', async () => {
  const f = opsExecFixture('guards');
  await withServer(f.cfg2({}), async (port) => {
    assert.equal((await rs(port, { project: 'Alpha-App' })).json.error, 'CONFIRM_REQUIRED');
    assert.equal((await rs(port, { project: 'Alpha-App', confirm: 'true' })).json.error, 'CONFIRM_REQUIRED', '文字列の true は確認と見なさない');
    assert.equal((await rs(port, { project: 'No-Such', confirm: true })).json.error, 'PROJECT_NOT_REGISTERED');
    assert.equal((await rs(port, { project: 'x; reboot', confirm: true })).json.error, 'PROJECT_NOT_REGISTERED');
    const prot = await rs(port, { project: 'Mirai-DX-Project/Cloudflared-Tools', confirm: true });
    assert.equal(prot.status, 403);
    assert.equal(prot.json.error, 'OPS_TARGET_PROTECTED', '自己ロックアウトを避けるため固定で拒否');
    const arr = await req(port, 'POST', '/api/ops/systemd/restart', [1], { Origin: 'http://127.0.0.1:' + port, 'Cf-Access-Jwt-Assertion': signJwt() });
    assert.equal(arr.json.error, 'BODY_NOT_OBJECT');
  });
  assert.equal(f.callLines().length, 0);
});

test('ops-restart: 成功は systemd-control restart <project> を 1 回だけ実行し、監査ログに JWT のメールを残す', async () => {
  const f = opsExecFixture('ok');
  await withServer(f.cfg2({}), async (port) => {
    const r = await rs(port, { project: 'Alpha-App', confirm: true }, { 'Cf-Access-Jwt-Assertion': signJwt({ email: 'ops-audit@example.test' }) });
    assert.equal(r.status, 200);
    assert.equal(r.json.ok, true);
    assert.equal(r.json.exitCode, 0);
    assert.match(r.json.output, /restart ok: Alpha-App/);
    assert.deepEqual(r.json.daily, { count: 1, max: 20 });
  });
  assert.deepEqual(f.callLines(), ['restart Alpha-App']);
  const log = fs.readFileSync(path.join(process.env.CLAUDEOS_HOME, 'logs', 'web-startup-audit.log'), 'utf8');
  assert.ok(log.includes('ops-restart') && log.includes('ops-audit@example.test'), '操作・対象・認証主体を記録する');
});

test('ops-restart: スクリプトが失敗したら ok:false / RESTART_FAILED (成功と誤報しない)。失敗も使用済みに数える', async () => {
  const f = opsExecFixture('fail');
  fs.writeFileSync(path.join(f.base, 'fail'), '');
  await withServer(f.cfg2({}), async (port) => {
    const r = await rs(port, { project: 'Alpha-App', confirm: true });
    assert.equal(r.status, 200);
    assert.equal(r.json.ok, false);
    assert.equal(r.json.error, 'RESTART_FAILED');
    assert.equal(r.json.exitCode, 5);
    assert.match(r.json.stderr, /Unit not loaded/);
    assert.equal(r.json.daily.count, 1);
  });
});

test('ops-restart: 日次上限 (専用カウンタ。プロンプト送信と共有しない)・破損は fail-closed', async () => {
  const f = opsExecFixture('daily');
  await withServer(f.cfg2({ opsDailyMax: 2 }), async (port) => {
    assert.equal((await rs(port, { project: 'Alpha-App', confirm: true })).json.ok, true);
    assert.equal((await rs(port, { project: 'Alpha-App', confirm: true })).json.ok, true);
    const third = await rs(port, { project: 'Alpha-App', confirm: true });
    assert.equal(third.status, 429);
    assert.equal(third.json.error, 'OPS_DAILY_LIMIT');
    assert.deepEqual(third.json.daily, { count: 2, max: 2 });
  });
  assert.equal(f.callLines().length, 2, '上限超過では実行しない');
  assert.ok(!fs.existsSync(f.web) || fs.readdirSync(f.web).every(n => !n.startsWith('usage-')), 'プロンプト用の使用量ファイルには書かない');
  fs.writeFileSync(path.join(f.ops, 'usage-' + srv.usageDay() + '.json'), '{broken');
  await withServer(f.cfg2({}), async (port) => {
    const r = await rs(port, { project: 'Alpha-App', confirm: true });
    assert.equal(r.status, 429);
    assert.equal(r.json.error, 'OPS_USAGE_UNREADABLE');
  });
  assert.equal(f.callLines().length, 2);
});

test('ops-restart: 実行中の再起動があるときは 409 (同時実行は 1 件)', async () => {
  const f = opsExecFixture('concurrent');
  fs.writeFileSync(path.join(f.base, 'slow'), '');
  await withServer(f.cfg2({}), async (port) => {
    const first = rs(port, { project: 'Alpha-App', confirm: true });
    await new Promise(r => setTimeout(r, 300));
    const second = await rs(port, { project: 'Alpha-App', confirm: true });
    assert.equal(second.status, 409);
    assert.equal(second.json.error, 'OPS_IN_PROGRESS');
    assert.equal((await first).json.ok, true);
    const after = await rs(port, { project: 'Alpha-App', confirm: true });
    assert.equal(after.json.ok, true, '完了後は再び実行できる');
  });
  assert.equal(f.callLines().length, 2);
});

// ---------------------------------------------------------------------------
// 実起動 (launch / apply-all の confirm=true) の追加認証 (Approval PR): STARTUP_WEB_LAUNCH_REQUIRE_JWT=1
//   Cloudflare のエッジ認証を迂回された場合 (オリジンへの直接アクセス) でも実起動できないようにする。計画の表示は従来どおり。
// ---------------------------------------------------------------------------
const jwtCfg = (extra) => Object.assign({ launchRequireJwt: true, accessTeamDomain: 'test.cloudflareaccess.com', accessAud: 'aud-1', accessKeys: async () => [ACC_JWK] }, extra || {});
const launchBody = { project: 'Alpha-App', mode: 'team', goal: 'auto', intent: '評価して', duration: 0, confirm: true };   // team: スタブは supervisor を作らないため background は起動確認で失敗する

test('launch-jwt: 既定 (フラグ無し) は従来どおり JWT 無しで実起動できる (後方互換)', async () => {
  fs.rmSync(MARK, { force: true });
  await withServer({}, async (port) => {
    const r = await req(port, 'POST', '/api/startup/launch', launchBody);
    assert.equal(r.json.started, true);
  });
});

test('launch-jwt: 有効時、JWT 無し・不正・未設定の実起動は拒否 (fail-closed)。Basic では代替できない。実起動しない', async () => {
  fs.rmSync(MARK, { force: true });
  await withServer(jwtCfg({ authUser: 'u', authPass: 'pw' }), async (port) => {
    const basic = { Authorization: 'Basic ' + Buffer.from('u:pw').toString('base64') };
    const none = await req(port, 'POST', '/api/startup/launch', launchBody, basic);
    assert.equal(none.status, 403);
    assert.equal(none.json.error, 'AUTH_JWT_REQUIRED', 'Basic が通っても JWT が無ければ拒否');
    const bad = await req(port, 'POST', '/api/startup/launch', launchBody, Object.assign({ 'Cf-Access-Jwt-Assertion': signJwt({ aud: ['other'] }) }, basic));
    assert.equal(bad.json.error, 'AUTH_JWT_REQUIRED');
    const noEmail = await req(port, 'POST', '/api/startup/launch', launchBody, Object.assign({ 'Cf-Access-Jwt-Assertion': signJwt({ email: '' }) }, basic));
    assert.equal(noEmail.json.error, 'AUTH_JWT_REQUIRED', '実行者を特定できない JWT は拒否');
    const all = await req(port, 'POST', '/api/startup/apply-all', { confirm: true }, basic);
    assert.equal(all.status, 403);
    assert.equal(all.json.error, 'AUTH_JWT_REQUIRED', 'apply-all の実適用も同じ');
  });
  await withServer(jwtCfg({ accessTeamDomain: '', accessAud: '' }), async (port) => {
    const r = await req(port, 'POST', '/api/startup/launch', launchBody, { 'Cf-Access-Jwt-Assertion': signJwt() });
    assert.equal(r.status, 403);
    assert.equal(r.json.error, 'AUTH_NOT_CONFIGURED', 'Access 未設定のまま有効化しても実起動しない');
  });
  assert.equal(fs.existsSync(MARK), false, '拒否では CLI を起動しない');
});

test('launch-jwt: 署名不正・期限切れ・鍵の取得失敗 (JWKS 例外)・sub だけの JWT・truthy な confirm は、実起動しない (apply-all の実適用も走らない)', async () => {
  fs.rmSync(MARK, { force: true });
  const autoLog = path.join(TMP, 'autonomy-calls.log');
  const calls = () => (fs.existsSync(autoLog) ? fs.readFileSync(autoLog, 'utf8').split('\n').filter(Boolean).length : 0);
  const { privateKey: otherKey } = require('crypto').generateKeyPairSync('rsa', { modulusLength: 2048 });
  const before = calls();
  await withServer(jwtCfg(), async (port) => {
    const post = (jwt) => req(port, 'POST', '/api/startup/launch', launchBody, { 'Cf-Access-Jwt-Assertion': jwt });
    assert.equal((await post(signJwt({}, otherKey))).json.error, 'AUTH_JWT_REQUIRED', '署名不正');
    assert.equal((await post(signJwt({ exp: Math.floor(Date.now() / 1000) - 10 }))).json.error, 'AUTH_JWT_REQUIRED', '期限切れ');
    assert.equal((await post(signJwt({ email: undefined, sub: 'abc-123' }))).json.error, 'AUTH_JWT_REQUIRED', 'メールが無く sub だけの JWT は実行者を特定できない');
    const all = await req(port, 'POST', '/api/startup/apply-all', { confirm: true }, { 'Cf-Access-Jwt-Assertion': signJwt({ email: '' }) });
    assert.equal(all.status, 403);
    // truthy でも === true でない confirm は、ゲートを通らなくてもハンドラが計画のみにする (実起動しない)
    for (const c of ['true', 1, {}]) {
      const r = await req(port, 'POST', '/api/startup/launch', Object.assign({}, launchBody, { confirm: c }));
      assert.equal(r.json.started, undefined, 'confirm=' + JSON.stringify(c));
      assert.equal(r.json.requiresConfirm, true);
    }
  });
  await withServer(jwtCfg({ accessKeys: async () => { throw new Error('network down'); } }), async (port) => {
    const r = await req(port, 'POST', '/api/startup/launch', launchBody, { 'Cf-Access-Jwt-Assertion': signJwt() });
    assert.equal(r.status, 403, '鍵を取得できないときは通さない (fail-closed)');
    assert.equal(r.json.error, 'AUTH_JWT_REQUIRED');
  });
  assert.equal(fs.existsSync(MARK), false, '拒否では CLI を起動しない');
  assert.equal(calls(), before, '拒否では apply-all の CLI を呼ばない');
  const log = fs.readFileSync(path.join(process.env.CLAUDEOS_HOME, 'logs', 'web-startup-audit.log'), 'utf8');
  assert.ok(log.split('\n').some(l => l.includes('launch-rejected') && l.includes('"detail"')), '拒否の内部理由 (detail) は監査にだけ残す');
});

test('launch-jwt: 有効時でも、計画の表示 (confirm 無し) と dryRunOnly は JWT 無しで使える。実起動は何も起きない', async () => {
  fs.rmSync(MARK, { force: true });
  await withServer(jwtCfg(), async (port) => {
    const plan = await req(port, 'POST', '/api/startup/launch', Object.assign({}, launchBody, { confirm: undefined }));
    assert.equal(plan.status, 200);
    assert.equal(plan.json.requiresConfirm, true);
    const allPlan = await req(port, 'POST', '/api/startup/apply-all', {});
    assert.equal(allPlan.json.requiresConfirm, true);
  });
  await withServer(jwtCfg({ dryRunOnly: true }), async (port) => {
    const r = await req(port, 'POST', '/api/startup/launch', launchBody);
    assert.equal(r.json.dryRunOnly, true);
    assert.equal(r.json.started, undefined);
  });
  assert.equal(fs.existsSync(MARK), false);
});

test('launch-jwt: 有効時、正しい JWT なら実起動でき、監査ログに実行者のメールを残す', async () => {
  fs.rmSync(MARK, { force: true });
  await withServer(jwtCfg(), async (port) => {
    const r = await req(port, 'POST', '/api/startup/launch', launchBody, { 'Cf-Access-Jwt-Assertion': signJwt({ email: 'launch-audit@example.test' }) });
    assert.equal(r.status, 200);
    assert.equal(r.json.started, true);
    const all = await req(port, 'POST', '/api/startup/apply-all', { confirm: true }, { 'Cf-Access-Jwt-Assertion': signJwt({ email: 'launch-audit@example.test' }) });
    assert.equal(all.json.started, true);
  });
  const log = fs.readFileSync(path.join(process.env.CLAUDEOS_HOME, 'logs', 'web-startup-audit.log'), 'utf8');
  assert.ok(log.split('\n').some(l => l.includes('"action":"launch"') && l.includes('launch-audit@example.test')), 'launch の監査に実行者を残す');
  assert.ok(log.split('\n').some(l => l.includes('"action":"apply-all"') && l.includes('launch-audit@example.test')), 'apply-all の監査に実行者を残す');
  assert.ok(log.includes('launch-rejected') && log.includes('AUTH_JWT_REQUIRED'), '拒否も監査に残す');
});
