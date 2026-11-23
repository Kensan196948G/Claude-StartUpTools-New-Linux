'use strict';
// session-end-routing-flush.test.js — Stop hook (.claude/claudeos/scripts/hooks/session-end.js) が
// routing-pending.jsonl を execution.routing_log へ集約する挙動を検証する (Control Plane emission 強化)。
const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync } = require('child_process');

const HOOK = path.join(__dirname, '..', '.claude', 'claudeos', 'scripts', 'hooks', 'session-end.js');

function makeTmp() {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'session-end-'));
  fs.mkdirSync(path.join(tmp, '.claude', 'claudeos', 'data'), { recursive: true });
  fs.writeFileSync(path.join(tmp, 'state.json'), JSON.stringify({ execution: { routing_log: [] }, dreaming: {}, learning: {} }));
  return tmp;
}

function pendingPath(tmp) { return path.join(tmp, '.claude', 'claudeos', 'data', 'routing-pending.jsonl'); }
function statePath(tmp) { return path.join(tmp, 'state.json'); }
function dataDirPath(tmp) { return path.join(tmp, '.claude', 'claudeos', 'data'); }

function runHook(tmp) {
  // session-end.js はローカルバンクの dataDir を __dirname 基準
  // (.claude/claudeos/data = tracked) で解決する。テストがフックを実行すると
  // 追跡ファイルを書き換えてしまうため、CLAUDEOS_DATA_DIR で一時ディレクトリへ
  // 隔離する。HOME も一時化し、グローバルバンク (~/.claude/data) を実環境へ
  // 書かせない。
  const home = path.join(tmp, 'home');
  fs.mkdirSync(home, { recursive: true });
  execFileSync(process.execPath, [HOOK], {
    cwd: tmp,
    input: '',
    encoding: 'utf8',
    env: {
      ...process.env,
      CLAUDEOS_HEAVY_SYNC: '0',
      CLAUDEOS_DATA_DIR: dataDirPath(tmp),
      HOME: home,
    },
  });
}

test('session-end: routing-pending.jsonl の完全な行を routing_log へ集約し、取り込み済み分は消す', () => {
  const tmp = makeTmp();
  const entries = [
    { at: 't0', execution: 'Main', worktree: false, reasons: ['r1'], task_type: 'docs' },
    { at: 't1', execution: 'Subagent', worktree: true, reasons: ['r2'], task_type: 'feature' },
  ];
  fs.writeFileSync(pendingPath(tmp), entries.map((e) => JSON.stringify(e)).join('\n') + '\n');

  runHook(tmp);

  const state = JSON.parse(fs.readFileSync(statePath(tmp), 'utf8'));
  assert.strictEqual(state.execution.routing_log.length, 2);
  assert.strictEqual(state.execution.routing_log[0].execution, 'Main');
  assert.strictEqual(state.execution.routing_log[1].execution, 'Subagent');
  assert.strictEqual(fs.readFileSync(pendingPath(tmp), 'utf8'), '');
});

test('session-end: 末尾の不完全な行は消費せず次回に残す', () => {
  const tmp = makeTmp();
  const complete = JSON.stringify({ at: 't0', execution: 'Main', worktree: false, reasons: ['r1'], task_type: 'docs' });
  const partial = '{"at":"t1","execution":"Sub';
  fs.writeFileSync(pendingPath(tmp), `${complete}\n${partial}`);

  runHook(tmp);

  const state = JSON.parse(fs.readFileSync(statePath(tmp), 'utf8'));
  assert.strictEqual(state.execution.routing_log.length, 1);
  assert.strictEqual(state.execution.routing_log[0].execution, 'Main');
  assert.strictEqual(fs.readFileSync(pendingPath(tmp), 'utf8'), partial);
});

test('session-end: routing_log は最新20件までしか保持しない', () => {
  const tmp = makeTmp();
  const existing = Array.from({ length: 19 }, (_, i) => ({ at: `old${i}`, execution: 'Main' }));
  fs.writeFileSync(statePath(tmp), JSON.stringify({ execution: { routing_log: existing }, dreaming: {}, learning: {} }));
  const entries = [
    { at: 'new1', execution: 'Subagent', worktree: true, reasons: ['r'], task_type: 'x' },
    { at: 'new2', execution: 'Main', worktree: false, reasons: ['r'], task_type: 'x' },
  ];
  fs.writeFileSync(pendingPath(tmp), entries.map((e) => JSON.stringify(e)).join('\n') + '\n');

  runHook(tmp);

  const state = JSON.parse(fs.readFileSync(statePath(tmp), 'utf8'));
  assert.strictEqual(state.execution.routing_log.length, 20);
  assert.strictEqual(state.execution.routing_log[19].at, 'new2');
});

test('session-end: routing-pending.jsonl が存在しなくても失敗しない (fail-soft)', () => {
  const tmp = makeTmp();
  assert.doesNotThrow(() => runHook(tmp));
  const state = JSON.parse(fs.readFileSync(statePath(tmp), 'utf8'));
  assert.deepStrictEqual(state.execution.routing_log, []);
});

test('.claude/claudeos と Claude/templates/claudeos の session-end.js は同一内容', () => {
  const templatePath = path.join(__dirname, '..', 'Claude', 'templates', 'claudeos', 'scripts', 'hooks', 'session-end.js');
  assert.strictEqual(fs.readFileSync(HOOK, 'utf8'), fs.readFileSync(templatePath, 'utf8'));
});

test('reasoning-bank: CLAUDEOS_DATA_DIR は既定 dataDir より優先され、未設定時は従来どおり', () => {
  const rb = require('../.claude/claudeos/scripts/hooks/reasoning-bank.js');
  const tmp = makeTmp();
  const fallback = path.join(tmp, 'fallback');
  const isolated = path.join(tmp, 'isolated');
  const bank = { schema_version: '2.0', entries: [{ id: 'entry-1' }], negative_patterns: [] };
  const prev = process.env.CLAUDEOS_DATA_DIR;
  try {
    process.env.CLAUDEOS_DATA_DIR = isolated;
    rb.saveBank(fallback, bank);
    assert.ok(fs.existsSync(path.join(isolated, 'reasoning-bank.json')), 'CLAUDEOS_DATA_DIR 側へ書く');
    assert.ok(!fs.existsSync(path.join(fallback, 'reasoning-bank.json')), '渡された dataDir へは書かない');
    assert.deepStrictEqual(rb.loadBank(fallback), bank, '読込も同じ隔離先から行う');

    delete process.env.CLAUDEOS_DATA_DIR;
    rb.saveBank(fallback, bank);
    assert.ok(fs.existsSync(path.join(fallback, 'reasoning-bank.json')), '未設定時は従来どおり渡された dataDir へ書く');
  } finally {
    if (prev === undefined) delete process.env.CLAUDEOS_DATA_DIR;
    else process.env.CLAUDEOS_DATA_DIR = prev;
  }
});

test('session-end: 実行しても tracked な .claude/claudeos/data を書き換えない (回帰)', (t) => {
  const repo = path.join(__dirname, '..');
  if (!fs.existsSync(path.join(repo, '.git'))) {
    t.skip('git checkout ではないため skip');
    return;
  }
  const bankPath = path.join(repo, '.claude', 'claudeos', 'data', 'reasoning-bank.json');
  const statusArgs = ['-C', repo, 'status', '--porcelain', '--untracked-files=no'];
  let statusBefore;
  try {
    statusBefore = execFileSync('git', statusArgs, { encoding: 'utf8' });
  } catch {
    t.skip('git を実行できないため skip');
    return;
  }
  const bankBefore = fs.existsSync(bankPath) ? fs.readFileSync(bankPath) : null;

  const tmp = makeTmp();
  fs.writeFileSync(statePath(tmp), JSON.stringify({
    execution: { routing_log: [], last_session_summary: 'テストセッションの要約' },
    stable: { stable_achieved: true },
    dreaming: {},
    learning: {},
  }));
  runHook(tmp);

  const statusAfter = execFileSync('git', statusArgs, { encoding: 'utf8' });
  const bankAfter = fs.existsSync(bankPath) ? fs.readFileSync(bankPath) : null;
  assert.deepStrictEqual(bankAfter, bankBefore, 'tracked reasoning-bank.json がフック実行で書き換わった');
  assert.strictEqual(statusAfter, statusBefore, 'フック実行で tracked ファイルの git status が変化した');
  if (statusBefore === '') {
    assert.strictEqual(statusAfter, '', 'テスト実行後も git status --porcelain は空であること');
  }
});
