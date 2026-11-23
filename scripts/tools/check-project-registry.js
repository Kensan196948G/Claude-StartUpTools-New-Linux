#!/usr/bin/env node
/**
 * scripts/tools/check-project-registry.js
 *
 * プロジェクト台帳の鮮度を検査する CLI。CI とローカルで同じ判定を使う。
 *
 *   node scripts/tools/check-project-registry.js            # ローカル台帳のみ検査
 *   node scripts/tools/check-project-registry.js --json     # 1 行 JSON
 *   node scripts/tools/check-project-registry.js --github   # GitHub 実在も gh api で検査
 *   node scripts/tools/check-project-registry.js --fix      # 実測に合わせて台帳を更新
 *   node scripts/tools/check-project-registry.js --fix --github
 *
 * 台帳から消えた項目は情報を失わないよう `_stale` に理由付きで退避する。
 * exit: 0 = 一致 / 1 = 乖離あり（--fix 無し）または修復失敗 / 2 = 引数エラー
 */

"use strict";

const fs = require("fs");
const path = require("path");
const { execFileSync } = require("child_process");

const registry = require("./project-registry");

const REPO_ROOT = path.resolve(__dirname, "..", "..");

function parseArgs(argv) {
  const o = { root: REPO_ROOT, base: "", json: false, fix: false, github: false, quiet: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--root") o.root = path.resolve(argv[++i]);
    else if (a === "--base") o.base = path.resolve(argv[++i]);
    else if (a === "--json") o.json = true;
    else if (a === "--fix") o.fix = true;
    else if (a === "--github") o.github = true;
    else if (a === "--quiet") o.quiet = true;
    else if (a === "-h" || a === "--help") {
      process.stdout.write(
        "usage: check-project-registry.js [--root DIR] [--base DIR] [--json] [--fix] [--github] [--quiet]\n"
      );
      process.exit(0);
    } else {
      process.stderr.write(`unknown argument: ${a}\n`);
      process.exit(2);
    }
  }
  return o;
}

function readJson(file) {
  return JSON.parse(fs.readFileSync(file, "utf8"));
}

function writeJsonAtomic(file, value) {
  const tmp = `${file}.tmp-${process.pid}`;
  fs.writeFileSync(tmp, `${JSON.stringify(value, null, 2)}\n`, "utf8");
  fs.renameSync(tmp, file);
}

/** gh api で repository の存在を確認する。gh が無い/失敗時は null（未確認）。 */
function makeGithubExists() {
  const cache = new Map();
  return (repo) => {
    if (cache.has(repo)) return cache.get(repo);
    let result;
    try {
      execFileSync("gh", ["api", `repos/${repo}`, "--jq", ".full_name"], {
        stdio: ["ignore", "pipe", "pipe"],
        timeout: 10000,
        encoding: "utf8",
      });
      result = true;
    } catch (e) {
      // 404 は「存在しない」、それ以外（認証・レート）は未確認として扱う
      const msg = String((e && (e.stderr || e.message)) || "");
      if (/Not Found|404/i.test(msg)) result = false;
      else result = null;
    }
    cache.set(repo, result);
    return result;
  };
}

function main() {
  const opts = parseArgs(process.argv.slice(2));
  const linuxFile = path.join(opts.root, "config", "linux-projects.json");
  const githubFile = path.join(opts.root, "config", "github-registry.json");
  const out = { ok: true, checked_at: new Date().toISOString(), linux: null, github: null, fixed: false, unknown: [] };

  // --- linux-projects.json ---
  let linux = null;
  try {
    linux = readJson(linuxFile);
  } catch (e) {
    out.ok = false;
    out.linux = { ok: false, error: `READ_FAILED: ${e.message}` };
  }
  if (linux) {
    const base = opts.base || linux.basePath;
    if (!base) {
      out.ok = false;
      out.linux = { ok: false, error: "NO_BASE_PATH" };
    } else {
      const actual = registry.scanLocalProjects(base);
      const res = registry.checkLinuxRegistry(linux, actual);
      out.linux = res;
      if (!res.ok) out.ok = false;
      if (opts.fix && !res.ok) {
        writeJsonAtomic(linuxFile, registry.buildFixedLinuxRegistry(linux, actual));
        out.fixed = true;
        const after = registry.checkLinuxRegistry(readJson(linuxFile), actual);
        out.linux = after;
      }
    }
  }

  // --- github-registry.json ---
  let github = null;
  try {
    github = readJson(githubFile);
  } catch (e) {
    if (opts.github) {
      out.ok = false;
      out.github = { ok: false, error: `READ_FAILED: ${e.message}` };
    }
  }
  if (github && github.projects) {
    let exists = null;
    if (opts.github) {
      const probe = makeGithubExists();
      const cache = new Map();
      exists = (repo) => {
        if (!cache.has(repo)) cache.set(repo, probe(repo));
        return cache.get(repo) === true; // null（未確認）は「存在しない」と断定しない
      };
      // 未確認のものは missing に入れないよう、先に全件 probe して状態を持つ
      const state = new Map();
      for (const entry of Object.values(github.projects)) {
        const url = String((entry && entry.url) || "").trim();
        const m = url.match(/^https:\/\/github\.com\/([^/]+)\/([^/#?]+?)(?:\.git)?\/?$/i);
        if (!m) continue;
        const full = `${m[1]}/${m[2]}`;
        if (!state.has(full)) state.set(full, probe(full));
      }
      exists = (repo) => state.get(repo) === true;
    }
    const res = registry.checkGithubRegistry(github.projects, exists || undefined);
    if (opts.github) {
      // 未確認（null）の項目は unknown に回し、ok 判定から除外する
      const probe = makeGithubExists();
      for (const [name, entry] of Object.entries(github.projects)) {
        const url = String((entry && entry.url) || "").trim();
        const m = url.match(/^https:\/\/github\.com\/([^/]+)\/([^/#?]+?)(?:\.git)?\/?$/i);
        if (!m) continue;
        if (probe(`${m[1]}/${m[2]}`) === null) out.unknown.push(name);
      }
      const unknownSet = new Set(out.unknown);
      res.missing = res.missing.filter((m) => !unknownSet.has(m.name));
      res.ok = res.missing.length === 0 && res.emptyUrl.length === 0;
    }
    out.github = res;
    if (!res.ok) out.ok = false;
    if (opts.fix && !res.ok) {
      writeJsonAtomic(githubFile, registry.buildFixedGithubRegistry(github, res));
      out.fixed = true;
      const after = registry.checkGithubRegistry(readJson(githubFile).projects, exists || undefined);
      if (opts.github) {
        const unknownSet = new Set(out.unknown);
        after.missing = after.missing.filter((m) => !unknownSet.has(m.name));
        after.ok = after.missing.length === 0 && after.emptyUrl.length === 0;
      }
      out.github = after;
    }
  }

  if (opts.fix) {
    out.ok = Boolean(out.linux && out.linux.ok !== false && (!out.github || out.github.ok !== false));
  }

  if (opts.json) {
    process.stdout.write(`${JSON.stringify(out)}\n`);
  } else if (!opts.quiet) {
    const l = out.linux || {};
    process.stdout.write(
      `linux-projects: registered=${l.registered ?? "?"} actual=${l.actual ?? "?"} ` +
        `missing=${(l.missing || []).length} unlisted=${(l.unlisted || []).length}\n`
    );
    for (const m of l.missing || []) process.stdout.write(`  - 実在しない: ${m}\n`);
    for (const m of l.unlisted || []) process.stdout.write(`  - 台帳に無い: ${m}\n`);
    if (out.github) {
      const g = out.github;
      process.stdout.write(
        `github-registry: total=${g.total ?? "?"} missing=${(g.missing || []).length} emptyUrl=${(g.emptyUrl || []).length}\n`
      );
      for (const m of g.missing || []) process.stdout.write(`  - ${m.reason}: ${m.name} (${m.url})\n`);
      for (const n of g.emptyUrl || []) process.stdout.write(`  - EMPTY_URL: ${n}\n`);
    }
    if (out.unknown.length) process.stdout.write(`未確認（gh 応答なし）: ${out.unknown.join(", ")}\n`);
    process.stdout.write(out.ok ? "RESULT: OK\n" : "RESULT: DRIFT\n");
  }

  process.exit(out.ok ? 0 : 1);
}

if (require.main === module) main();

module.exports = { parseArgs, makeGithubExists };
