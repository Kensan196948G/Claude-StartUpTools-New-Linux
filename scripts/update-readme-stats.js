#!/usr/bin/env node
/**
 * update-readme-stats
 * Auto-injects current version (from CHANGELOG.md) and agent count
 * (from .claude/claudeos/agents/*.md) into README.md.
 * Run manually or in CI to keep README in sync.
 * Exit 0 = updated (or already up-to-date), Exit 1 = error.
 */

const fs = require('fs');
const path = require('path');

const root = path.resolve(__dirname, '..');

/**
 * CHANGELOG.md 先頭から「最新リリース版」の見出しを抽出する。
 *
 * Keep a Changelog 形式の見出し `## [x.y.z] - date` を想定し、
 * 次を許容する:
 *   - `v` プレフィックスの有無（`## [v1.2.3]` / `## [1.2.3]` 両対応）
 *   - semver 後置詞（`-linux` / `-rc.1` / `+build.5` など）
 *   - `[Unreleased]` 見出しはバージョン番号を持たないため自動スキップ
 *
 * @param {string} changelog CHANGELOG.md 全文
 * @returns {string|null} 例 "4.0.0-linux"（`v` は除去）。見つからなければ null
 */
function parseLatestVersion(changelog) {
  const m = changelog.match(/^## \[?v?(\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?)\]?/m);
  return m ? m[1] : null;
}

module.exports = { parseLatestVersion };

// 直接実行されたときのみ README 書き換えを行う（require 時は副作用なし）
if (require.main !== module) {
  return;
}

// --- Read sources ---
const changelog = fs.readFileSync(path.join(root, 'CHANGELOG.md'), 'utf8');
const latestVersion = parseLatestVersion(changelog);
if (!latestVersion) {
  console.error('CHANGELOG.md: latest version line not found');
  process.exit(1);
}

const agentsDir = path.join(root, '.claude', 'claudeos', 'agents');
const agentCount = fs.readdirSync(agentsDir).filter(f => f.endsWith('.md')).length;

const commandsDir = path.join(root, '.claude', 'claudeos', 'commands');
const commandCount = fs.readdirSync(commandsDir).filter(f => f.endsWith('.md')).length;

console.log(`Source — version: ${latestVersion}, agents: ${agentCount}, commands: ${commandCount}`);

// --- Read README ---
let readme = fs.readFileSync(path.join(root, 'README.md'), 'utf8');
const original = readme;

// Patch: バージョン行
readme = readme.replace(
  /(\| バージョン \| \*\*)(v[\d.]+)(\*\*)/,
  `$1${latestVersion}$3`
);

// Patch: Agents 行
readme = readme.replace(
  /(\| Agents \| \*\*)(\d+)(体\*\*)/,
  `$1${agentCount}$3`
);

// Patch: ClaudeOS カーネル行の "N体+Mコマンド" (e.g. "25体+34コマンド")
readme = readme.replace(
  /(\*\*)(\d+)(体\+)(\d+)(コマンド\*\*)/,
  `$1${agentCount}$3${commandCount}$5`
);

// Patch: Mermaid diagram の "N Agent定義から"
readme = readme.replace(
  /(\d+)(Agent定義から)/g,
  `${agentCount}$2`
);

// --- Write back only if changed ---
if (readme === original) {
  console.log('README.md already up-to-date — no changes written.');
  process.exit(0);
}

fs.writeFileSync(path.join(root, 'README.md'), readme, 'utf8');
console.log(`README.md updated — version=${latestVersion}, agents=${agentCount}, commands=${commandCount}`);
process.exit(0);
