'use strict';
/**
 * update-readme-stats の parseLatestVersion 単体テスト。
 * `node --test`（npm run test:node）で実行される。
 * Issue #14: CHANGELOG 見出しが v 無し / 後置詞付き / [Unreleased] 先頭でも
 * 最新リリース版を正しく抽出できることを保証する回帰テスト。
 */

const { test } = require('node:test');
const assert = require('node:assert/strict');

const { parseLatestVersion } = require('./update-readme-stats.js');

test('v 無し + 後置詞付き ([4.0.0-linux]) を抽出する', () => {
  const changelog = [
    '# Changelog',
    '',
    '## [Unreleased]',
    '',
    '## [4.0.0-linux] - 2026-06-07',
    '',
    '## [3.9.0] - 2026-05-01',
  ].join('\n');
  assert.equal(parseLatestVersion(changelog), '4.0.0-linux');
});

test('[Unreleased] 見出しはスキップする', () => {
  const changelog = '## [Unreleased]\n\n## [1.2.3] - 2026-01-01\n';
  assert.equal(parseLatestVersion(changelog), '1.2.3');
});

test('v プレフィックス付き ([v2.0.0]) は v を除去して抽出する', () => {
  const changelog = '## [v2.0.0] - 2026-02-02\n';
  assert.equal(parseLatestVersion(changelog), '2.0.0');
});

test('角括弧なし見出し (## 1.0.0) も抽出する', () => {
  const changelog = '## 1.0.0 - 2026-03-03\n';
  assert.equal(parseLatestVersion(changelog), '1.0.0');
});

test('+ build メタデータ後置詞 (1.0.0+build.5) を保持する', () => {
  const changelog = '## [1.0.0+build.5] - 2026-04-04\n';
  assert.equal(parseLatestVersion(changelog), '1.0.0+build.5');
});

test('バージョン見出しが無ければ null を返す', () => {
  const changelog = '# Changelog\n\n## [Unreleased]\n\nNothing released yet.\n';
  assert.equal(parseLatestVersion(changelog), null);
});
