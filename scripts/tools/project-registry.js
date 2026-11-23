"use strict";
/**
 * scripts/tools/project-registry.js
 *
 * プロジェクト台帳（config/linux-projects.json / config/github-registry.json）の
 * 鮮度を判定する純関数。ファイル I/O とネットワークは呼び出し側に任せ、
 * ここでは「台帳の内容」と「実測値」を突き合わせるだけにする（テスト容易性のため）。
 *
 * 背景: 2026-11-23 の実測で linux-projects.json は 22 件中 1 件しか実在せず、
 * github-registry.json は 20 件中 6 件しか GitHub に存在しなかった。
 * 台帳が古いとダッシュボードが 404 リンクを出し、運用判断を誤らせる。
 */

const fs = require("fs");
const path = require("path");

/** 台帳に入れないディレクトリ名（隠しディレクトリ・退避・バックアップ）。 */
function isIgnoredProjectName(name) {
  if (!name || name.startsWith(".")) return true;
  if (name.endsWith(".old")) return true;
  if (/backup/i.test(name)) return true;
  return false;
}

/**
 * ディレクトリが Git リポジトリの「主チェックアウト」か。
 * `git worktree add` で作られた作業ツリーは `.git` がファイルなので除外する
 * （プロジェクト候補・起動対象ではないため）。
 */
function isGitRepo(dir) {
  try {
    return fs.statSync(path.join(dir, ".git")).isDirectory();
  } catch {
    return false;
  }
}

/**
 * basePath 直下の Git リポジトリ名を昇順で返す。
 * @param {string} base
 * @param {{exclude?: string[]}} [opts]
 * @returns {string[]}
 */
function scanLocalProjects(base, opts = {}) {
  const exclude = new Set(opts.exclude || []);
  const names = [];
  let entries;
  try {
    entries = fs.readdirSync(base, { withFileTypes: true });
  } catch {
    return names;
  }
  for (const e of entries) {
    if (!e.isDirectory()) continue;
    if (isIgnoredProjectName(e.name)) continue;
    if (exclude.has(e.name)) continue;
    if (!isGitRepo(path.join(base, e.name))) continue;
    names.push(e.name);
  }
  return names.sort();
}

/**
 * linux-projects.json を実測と突き合わせる。
 * @param {{basePath: string, projects: string[]}} registry
 * @param {string[]} actual  scanLocalProjects の結果
 */
function checkLinuxRegistry(registry, actual) {
  const registered = Array.isArray(registry.projects) ? registry.projects.slice() : [];
  const actualSet = new Set(actual);
  const registeredSet = new Set(registered);
  const missing = registered.filter((n) => !actualSet.has(n));
  const unlisted = actual.filter((n) => !registeredSet.has(n));
  return {
    ok: missing.length === 0 && unlisted.length === 0,
    basePath: registry.basePath || "",
    registered: registered.length,
    actual: actual.length,
    missing,
    unlisted,
  };
}

/**
 * github-registry.json を「GitHub に実在するか」の実測と突き合わせる。
 * @param {Record<string, {url?: string}>} projects
 * @param {(repo: string) => boolean} exists  省略時は判定しない（空 URL のみ検査）
 */
function checkGithubRegistry(projects, exists) {
  const missing = [];
  const emptyUrl = [];
  for (const [name, entry] of Object.entries(projects || {})) {
    const url = String((entry && entry.url) || "").trim();
    if (!url) {
      emptyUrl.push(name);
      continue;
    }
    const m = url.match(/^https:\/\/github\.com\/([^/]+)\/([^/#?]+?)(?:\.git)?\/?$/i);
    if (!m) {
      missing.push({ name, url, reason: "INVALID_URL" });
      continue;
    }
    if (typeof exists === "function" && !exists(`${m[1]}/${m[2]}`)) {
      missing.push({ name, url, reason: "NOT_FOUND" });
    }
  }
  return {
    ok: missing.length === 0 && emptyUrl.length === 0,
    total: Object.keys(projects || {}).length,
    missing,
    emptyUrl,
  };
}

/**
 * linux-projects.json を実測に合わせた新しい台帳へ作り直す。
 * 消えた名前は情報を失わないよう `_stale` に理由付きで退避する。
 * @param {{basePath: string, projects: string[]}} registry
 * @param {string[]} actual
 * @param {string} [now]
 */
function buildFixedLinuxRegistry(registry, actual, now = new Date().toISOString()) {
  const registered = Array.isArray(registry.projects) ? registry.projects.slice() : [];
  const actualSet = new Set(actual);
  const stale = registered
    .filter((n) => !actualSet.has(n))
    .map((name) => ({ name, reason: "NOT_FOUND_UNDER_BASE", checked_at: now }));
  const previousStale = Array.isArray(registry._stale) ? registry._stale : [];
  const mergedStale = previousStale
    .filter((s) => s && s.name && !actualSet.has(s.name))
    .concat(stale);
  const byName = new Map();
  for (const s of mergedStale) byName.set(s.name, s);
  return {
    ...registry,
    projects: actual.slice().sort(),
    _stale: Array.from(byName.values()).sort((a, b) => a.name.localeCompare(b.name)),
    _verified_at: now,
  };
}

/**
 * github-registry.json から「実在しない」「URL が空」の項目を `_stale` へ移す。
 * @param {{projects: Record<string, unknown>}} registry
 * @param {{missing: Array<{name: string, url?: string, reason: string}>, emptyUrl: string[]}} result
 * @param {string} [now]
 */
function buildFixedGithubRegistry(registry, result, now = new Date().toISOString()) {
  const projects = { ...(registry.projects || {}) };
  const stale = [];
  for (const m of result.missing || []) {
    if (Object.prototype.hasOwnProperty.call(projects, m.name)) {
      delete projects[m.name];
      stale.push({ name: m.name, url: m.url || "", reason: m.reason, checked_at: now });
    }
  }
  for (const name of result.emptyUrl || []) {
    if (Object.prototype.hasOwnProperty.call(projects, name)) {
      delete projects[name];
      stale.push({ name, url: "", reason: "EMPTY_URL", checked_at: now });
    }
  }
  const previousStale = Array.isArray(registry._stale) ? registry._stale : [];
  const byName = new Map();
  for (const s of previousStale.concat(stale)) {
    if (s && s.name) byName.set(s.name, s);
  }
  return {
    ...registry,
    projects,
    _stale: Array.from(byName.values()).sort((a, b) => a.name.localeCompare(b.name)),
    _verified_at: now,
  };
}

module.exports = {
  isIgnoredProjectName,
  isGitRepo,
  scanLocalProjects,
  checkLinuxRegistry,
  checkGithubRegistry,
  buildFixedLinuxRegistry,
  buildFixedGithubRegistry,
};
