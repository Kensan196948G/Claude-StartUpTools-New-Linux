'use strict';
/**
 * init-claudeos-project.js mergeSettings の単体テスト。
 * `node --test`（npm run test:node）で実行される。
 *
 * autocompact thrashing 対策 (#78 配布側フォロー) が守る不変条件:
 *   - 廃止 env CLAUDE_AUTOCOMPACT_PCT_OVERRIDE を merge 時に除去する
 *   - SessionStart matcher "*" でコンテキスト注入 hook (session-start.js 等) を
 *     実行するエントリを startup|resume|clear へ正規化する (command / args 両形式)
 *   - 非注入 hook (heartbeat-writer.js 等) の matcher "*" は保持する
 *   - 既存のカスタム env / permissions は保護する
 *   - 正規化後にテンプレートと同一シグネチャなら重複追加しない
 */

const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const { mergeSettings } = require('./setup/init-claudeos-project.js');

const TEMPLATE = {
  env: { ENABLE_TOOL_SEARCH: 'true' },
  hooks: {
    SessionStart: [
      {
        matcher: 'startup|resume|clear',
        hooks: [{ type: 'command', command: 'node .claude/claudeos/scripts/hooks/session-start.js' }],
      },
      {
        matcher: '*',
        hooks: [{ type: 'command', command: 'node .claude/claudeos/scripts/hooks/heartbeat-writer.js' }],
      },
    ],
  },
};

function runMerge(current, template = TEMPLATE) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'init-claudeos-test-'));
  const srcPath = path.join(dir, 'template.json');
  const destPath = path.join(dir, 'settings.json');
  fs.writeFileSync(srcPath, JSON.stringify(template, null, 2));
  fs.writeFileSync(destPath, JSON.stringify(current, null, 2));
  const plan = { create: 0, skip: 0, merge: 0, srcMissing: [] };
  mergeSettings(srcPath, destPath, plan, false);
  const result = JSON.parse(fs.readFileSync(destPath, 'utf8'));
  fs.rmSync(dir, { recursive: true, force: true });
  return { result, plan };
}

test('廃止 env CLAUDE_AUTOCOMPACT_PCT_OVERRIDE を除去する', () => {
  const { result } = runMerge({
    env: { CLAUDE_AUTOCOMPACT_PCT_OVERRIDE: '50', MY_CUSTOM: 'keep' },
  });
  assert.ok(!('CLAUDE_AUTOCOMPACT_PCT_OVERRIDE' in result.env));
  assert.equal(result.env.MY_CUSTOM, 'keep');
});

test('テンプレート側に廃止 env が居ても追加しない', () => {
  const { result } = runMerge(
    { env: {} },
    { env: { CLAUDE_AUTOCOMPACT_PCT_OVERRIDE: '50', ENABLE_TOOL_SEARCH: 'true' } }
  );
  assert.ok(!('CLAUDE_AUTOCOMPACT_PCT_OVERRIDE' in result.env));
  assert.equal(result.env.ENABLE_TOOL_SEARCH, 'true');
});

test('SessionStart matcher "*" + session-start.js (command 形式) を正規化する', () => {
  const { result } = runMerge({
    hooks: {
      SessionStart: [
        { matcher: '*', hooks: [{ type: 'command', command: 'node .claude/claudeos/scripts/hooks/session-start.js' }] },
      ],
    },
  });
  const matchers = result.hooks.SessionStart.map((e) => e.matcher);
  assert.ok(!matchers.some((m, i) => m === '*' &&
    JSON.stringify(result.hooks.SessionStart[i]).includes('session-start.js')));
  assert.ok(matchers.includes('startup|resume|clear'));
});

test('command:"node" + args 形式のエントリも正規化する', () => {
  const { result } = runMerge({
    hooks: {
      SessionStart: [
        { matcher: '*', hooks: [{ type: 'command', command: 'node', args: ['.claude/claudeos/scripts/hooks/session-start.js'] }] },
      ],
    },
  });
  const entry = result.hooks.SessionStart.find((e) =>
    JSON.stringify(e).includes('session-start.js'));
  assert.equal(entry.matcher, 'startup|resume|clear');
});

test('非注入 hook (heartbeat-writer.js) の matcher "*" は保持する', () => {
  const { result } = runMerge({
    hooks: {
      SessionStart: [
        { matcher: '*', hooks: [{ type: 'command', command: 'node .claude/claudeos/scripts/hooks/heartbeat-writer.js' }] },
      ],
    },
  });
  const entry = result.hooks.SessionStart.find((e) =>
    JSON.stringify(e).includes('heartbeat-writer.js'));
  assert.equal(entry.matcher, '*');
});

test('正規化後にテンプレートと同一シグネチャなら重複追加しない', () => {
  const { result } = runMerge({
    hooks: {
      SessionStart: [
        // args 形式だが結合するとテンプレートの command 形式と同一コマンド列になる
        { matcher: '*', hooks: [{ type: 'command', command: 'node', args: ['.claude/claudeos/scripts/hooks/session-start.js'] }] },
      ],
    },
  });
  const sessionStartEntries = result.hooks.SessionStart.filter((e) =>
    JSON.stringify(e).includes('session-start.js'));
  assert.equal(sessionStartEntries.length, 1);
});

test('サニタイズ不要なら up-to-date (kept) のまま変更しない', () => {
  const { plan } = runMerge({
    env: { ENABLE_TOOL_SEARCH: 'true' },
    hooks: TEMPLATE.hooks,
  });
  assert.equal(plan.merge, 0);
  assert.equal(plan.skip, 1);
});
