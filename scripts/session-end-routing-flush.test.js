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

function runHook(tmp) {
  execFileSync(process.execPath, [HOOK], { cwd: tmp, input: '', encoding: 'utf8', env: { ...process.env, CLAUDEOS_HEAVY_SYNC: '0' } });
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
