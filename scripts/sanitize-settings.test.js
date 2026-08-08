'use strict';
/**
 * sanitize-settings.js の単体テスト。
 * `node --test`（npm run test:node）で実行される。
 *
 * 起動経路 (template-sync.sh) から毎回呼ばれる前提の不変条件:
 *   - 廃止 env CLAUDE_AUTOCOMPACT_PCT_OVERRIDE を除去し、カスタム env は保護する
 *   - SessionStart matcher "*" のコンテキスト注入 hook を startup|resume|clear へ
 *     正規化する (command 文字列 / command+args[] / $CLAUDE_PROJECT_DIR 引用形式)
 *   - 非注入 hook (heartbeat-writer.js 等) の matcher "*" は保持する
 *   - 残骸なしなら書き換えもバックアップも行わない (clean)
 *   - 修復時は初回のみ .bak-autocompact-fix へ退避し、2回目以降は上書きしない
 *   - ファイル不存在 / parse 失敗でも throw せず、CLI は常に exit 0 (起動を妨げない)
 */

const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { execFileSync } = require('node:child_process');

const {
  sanitizeSettingsObject,
  sanitizeSettingsFile,
} = require('./setup/sanitize-settings.js');

const SCRIPT = path.join(__dirname, 'setup', 'sanitize-settings.js');

// 残骸入り settings を一時ディレクトリへ書き出す
function writeSettings(obj) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'sanitize-settings-test-'));
  const file = path.join(dir, 'settings.json');
  if (obj !== undefined) fs.writeFileSync(file, typeof obj === 'string' ? obj : JSON.stringify(obj, null, 2));
  return { dir, file };
}

const RESIDUE = {
  env: { CLAUDE_AUTOCOMPACT_PCT_OVERRIDE: '50', MY_CUSTOM: 'keep' },
  hooks: {
    SessionStart: [
      { matcher: '*', hooks: [{ type: 'command', command: 'node .claude/claudeos/scripts/hooks/session-start.js' }] },
      { matcher: '*', hooks: [{ type: 'command', command: 'node .claude/claudeos/scripts/hooks/heartbeat-writer.js' }] },
    ],
  },
};

test('sanitizeSettingsObject: 廃止 env を除去しカスタム env は保護する', () => {
  const cur = JSON.parse(JSON.stringify(RESIDUE));
  const changed = sanitizeSettingsObject(cur);
  assert.equal(changed, 2); // env 1 + matcher 1
  assert.ok(!('CLAUDE_AUTOCOMPACT_PCT_OVERRIDE' in cur.env));
  assert.equal(cur.env.MY_CUSTOM, 'keep');
});

test('sanitizeSettingsObject: 注入 hook の matcher "*" を正規化し非注入 hook は保持する', () => {
  const cur = JSON.parse(JSON.stringify(RESIDUE));
  sanitizeSettingsObject(cur);
  assert.equal(cur.hooks.SessionStart[0].matcher, 'startup|resume|clear'); // session-start.js
  assert.equal(cur.hooks.SessionStart[1].matcher, '*');                    // heartbeat-writer.js
});

test('sanitizeSettingsObject: command+args[] 形式も正規化する', () => {
  const cur = {
    hooks: {
      SessionStart: [
        { matcher: '*', hooks: [{ type: 'command', command: 'node', args: ['.claude/claudeos/scripts/hooks/session-start.js'] }] },
      ],
    },
  };
  assert.equal(sanitizeSettingsObject(cur), 1);
  assert.equal(cur.hooks.SessionStart[0].matcher, 'startup|resume|clear');
});

test('sanitizeSettingsObject: $CLAUDE_PROJECT_DIR 引用形式も正規化する', () => {
  const cur = {
    hooks: {
      SessionStart: [
        { matcher: '*', hooks: [{ type: 'command', command: 'node "$CLAUDE_PROJECT_DIR/.claude/claudeos/scripts/hooks/session-start.js"' }] },
      ],
    },
  };
  assert.equal(sanitizeSettingsObject(cur), 1);
  assert.equal(cur.hooks.SessionStart[0].matcher, 'startup|resume|clear');
});

test('sanitizeSettingsFile: 残骸ありなら fixed + バックアップ作成 + 書き換え', () => {
  const { dir, file } = writeSettings(RESIDUE);
  const r = sanitizeSettingsFile(file);
  assert.equal(r.status, 'fixed');
  assert.equal(r.changed, 2);
  assert.ok(fs.existsSync(file + '.bak-autocompact-fix'));
  const after = JSON.parse(fs.readFileSync(file, 'utf8'));
  assert.ok(!('CLAUDE_AUTOCOMPACT_PCT_OVERRIDE' in after.env));
  // バックアップは修復前の原本を保持している
  const bak = JSON.parse(fs.readFileSync(file + '.bak-autocompact-fix', 'utf8'));
  assert.equal(bak.env.CLAUDE_AUTOCOMPACT_PCT_OVERRIDE, '50');
  fs.rmSync(dir, { recursive: true, force: true });
});

test('sanitizeSettingsFile: 残骸なしなら clean で書き換えもバックアップもしない', () => {
  const clean = {
    env: { MY_CUSTOM: 'keep' },
    hooks: { SessionStart: [{ matcher: 'startup|resume|clear', hooks: [{ type: 'command', command: 'node .claude/claudeos/scripts/hooks/session-start.js' }] }] },
  };
  const { dir, file } = writeSettings(clean);
  const before = fs.statSync(file).mtimeMs;
  const r = sanitizeSettingsFile(file);
  assert.equal(r.status, 'clean');
  assert.ok(!fs.existsSync(file + '.bak-autocompact-fix'));
  assert.equal(fs.statSync(file).mtimeMs, before);
  fs.rmSync(dir, { recursive: true, force: true });
});

test('sanitizeSettingsFile: 冪等 — 2回目は clean、初回バックアップは上書きされない', () => {
  const { dir, file } = writeSettings(RESIDUE);
  assert.equal(sanitizeSettingsFile(file).status, 'fixed');
  const bakPath = file + '.bak-autocompact-fix';
  const bakBefore = fs.readFileSync(bakPath, 'utf8');
  assert.equal(sanitizeSettingsFile(file).status, 'clean');
  assert.equal(fs.readFileSync(bakPath, 'utf8'), bakBefore);
  fs.rmSync(dir, { recursive: true, force: true });
});

test('sanitizeSettingsFile: ファイル不存在は missing (throw しない)', () => {
  const { dir, file } = writeSettings(undefined);
  assert.equal(sanitizeSettingsFile(file).status, 'missing');
  fs.rmSync(dir, { recursive: true, force: true });
});

test('sanitizeSettingsFile: parse 失敗は parse-error でファイルへ触れない', () => {
  const { dir, file } = writeSettings('{ broken json');
  const r = sanitizeSettingsFile(file);
  assert.equal(r.status, 'parse-error');
  assert.ok(r.error);
  assert.equal(fs.readFileSync(file, 'utf8'), '{ broken json');
  assert.ok(!fs.existsSync(file + '.bak-autocompact-fix'));
  fs.rmSync(dir, { recursive: true, force: true });
});

test('CLI: 修復・parse 失敗・不存在いずれでも exit 0 (起動を妨げない)', () => {
  const fixed = writeSettings(RESIDUE);
  const broken = writeSettings('{ broken json');
  const missingPath = path.join(fixed.dir, 'no-such.json');
  // execFileSync は exit != 0 で throw する — throw しないこと自体が検証
  const out = execFileSync(process.execPath, [SCRIPT, fixed.file, broken.file, missingPath], { encoding: 'utf8' });
  assert.match(out, /修復/);
  const after = JSON.parse(fs.readFileSync(fixed.file, 'utf8'));
  assert.ok(!('CLAUDE_AUTOCOMPACT_PCT_OVERRIDE' in after.env));
  fs.rmSync(fixed.dir, { recursive: true, force: true });
  fs.rmSync(broken.dir, { recursive: true, force: true });
});
