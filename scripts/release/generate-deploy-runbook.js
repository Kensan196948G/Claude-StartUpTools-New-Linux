#!/usr/bin/env node
/**
 * scripts/release/generate-deploy-runbook.js (ClaudeOS v8.2.4+)
 *
 * state.json の deploy.ready=true を検知して、deploy-runbook-template.md から
 * 実値を埋めた reports/deploy-runbook.md を生成する。
 *
 * **重要**: 実際のデプロイは人間が手動で実行する。本スクリプトは手順書を生成するだけ。
 *
 * 生成時は state.json の deploy.runbook_path / deploy.runbook_generated を
 * **実際に書いたファイルに基づいて**更新する (--dry では state もファイルも書かない)。
 * これにより session-end フック経由の生成でもフラグと実体が乖離しない。
 *
 * 生成物には必ず commit SHA (git rev-parse HEAD) と、その環境の current release の
 * tree_sha256 (<CLAUDEOS_HOME>/releases/<env>-current/manifest.json) を埋め込む。
 * manifest が無い場合は「未生成」であることを明示する (嘘の値を書かない)。
 *
 * 使い方:
 *   node scripts/release/generate-deploy-runbook.js
 *   node scripts/release/generate-deploy-runbook.js --env staging
 *   node scripts/release/generate-deploy-runbook.js --force      # deploy.ready が false でも生成
 *   node scripts/release/generate-deploy-runbook.js --dry        # stdout のみ (書き込みなし)
 *
 * exit: 0 生成/スキップ / 1 書き込みエラー / 2 引数・テンプレート不備
 */

"use strict";

const fs = require("fs");
const os = require("os");
const path = require("path");
const { execFileSync } = require("child_process");

const TEMPLATE_FILE = path.resolve(
  __dirname, "..", "..", "Claude", "templates", "claudeos", "docs", "deploy-runbook-template.md"
);
const VALID_ENVS = ["staging", "production"];
// 環境ごとの実体 (bin/release-promote.sh の既定と一致させる)
const ENV_TARGETS = {
  staging: { unit: "claudeos-web-startup-stg.service", port: 3742 },
  production: { unit: "claudeos-web-startup.service", port: 3740 },
};

function usage(stream) {
  stream.write(
    [
      "Usage: node scripts/release/generate-deploy-runbook.js [--env staging|production] [--dry] [--force]",
      "",
      "  --env ENV   staging | production (既定 production)",
      "  --dry       stdout に出すだけ (reports/ も state.json も書かない)",
      "  --force     state.deploy.ready が false でも生成する",
      "",
    ].join("\n")
  );
}

function parseArgs(argv) {
  const opts = { dry: false, force: false, env: "production", help: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--dry") opts.dry = true;
    else if (a === "--force") opts.force = true;
    else if (a === "--env") {
      const v = argv[++i];
      if (v === undefined) throw new Error("--env には値が必要です");
      opts.env = v;
    } else if (a === "-h" || a === "--help") opts.help = true;
    else throw new Error(`不明な引数: ${a}`);
  }
  if (!VALID_ENVS.includes(opts.env)) {
    throw new Error(`env は staging|production のいずれかです: ${opts.env}`);
  }
  return opts;
}

function readJson(file) {
  try {
    const v = JSON.parse(fs.readFileSync(file, "utf8"));
    return v && typeof v === "object" && !Array.isArray(v) ? v : null;
  } catch {
    return null;
  }
}

function isPlainObject(v) {
  return !!v && typeof v === "object" && !Array.isArray(v);
}

/** git を失敗許容で実行する (release 成果物には .git が無いため、無い場合は空文字) */
function safeGit(cwd, args) {
  try {
    return execFileSync("git", args, {
      cwd,
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    }).trim();
  } catch {
    return "";
  }
}

/** ClaudeOS ホーム (env 上書き可。テストは一時ディレクトリを渡す) */
function claudeosHome(environ) {
  const v = environ && environ.CLAUDEOS_HOME;
  return v && v.trim() ? v : path.join(os.homedir(), ".claudeos");
}

/**
 * 生成物に埋める実値 (commit / tree_sha256 / branch / tag) を解決する。
 * tree_sha256 は <CLAUDEOS_HOME>/releases/<env>-current/manifest.json から読む
 * (production なら本番で稼働中の成果物の識別子)。
 */
function resolveBuildInfo({ cwd, env, environ }) {
  const commit = safeGit(cwd, ["rev-parse", "HEAD"]);
  const branch = safeGit(cwd, ["rev-parse", "--abbrev-ref", "HEAD"]);
  const tag = safeGit(cwd, ["describe", "--tags", "--abbrev=0"]);
  const releasesDir = path.join(claudeosHome(environ), "releases");
  const manifestPath = path.join(releasesDir, `${env}-current`, "manifest.json");
  const manifest = readJson(manifestPath);
  const treeSha256 = manifest && typeof manifest.tree_sha256 === "string" ? manifest.tree_sha256 : "";
  const manifestCommit = manifest && typeof manifest.commit === "string" ? manifest.commit : "";
  return {
    commit,
    shortCommit: commit ? commit.slice(0, 7) : "",
    branch,
    tag,
    treeSha256,
    manifestCommit,
    manifestPath,
    releasesDir,
  };
}

function buildContext(state, opts, info) {
  const s = isPlainObject(state) ? state : {};
  const stable = isPlainObject(s.stable) ? s.stable : {};
  const project = isPlainObject(s.project) ? s.project : {};
  const goal = isPlainObject(s.goal) ? s.goal : {};
  const target = ENV_TARGETS[opts.env];
  const healthUrl = `http://127.0.0.1:${target.port}/api/health`;
  const projectName = goal.title || project.name || path.basename(info.cwd || process.cwd());
  const stableStatus = stable.stable_achieved
    ? `✅ STABLE 達成（連続 ${stable.consecutive_success} 回）`
    : `⚠️ STABLE 未達（連続 ${stable.consecutive_success || 0} 回）`;
  return {
    DATE: new Date().toISOString().slice(0, 10),
    PROJECT: String(projectName),
    ENVIRONMENT: opts.env,
    UNIT: target.unit,
    PORT: String(target.port),
    HEALTH_URL: healthUrl,
    STABLE_STATUS: stableStatus,
    STABLE_PR: stable.stable_achieved_pr ? `#${stable.stable_achieved_pr}` : "—",
    GIT_BRANCH: info.branch || "不明（git リポジトリではありません）",
    GIT_COMMIT: info.commit || "不明（git リポジトリではありません）",
    GIT_COMMIT_SHORT: info.shortCommit || "不明",
    GIT_TAG: info.tag || "(no tag)",
    TREE_SHA256:
      info.treeSha256 ||
      "未生成（bin/release-build.sh と bin/release-promote.sh で <CLAUDEOS_HOME>/releases/" +
        opts.env +
        "-current を作成してください）",
    CURRENT_MANIFEST_COMMIT: info.manifestCommit || "（manifest なし）",
    RELEASES_DIR: info.releasesDir,
    RELEASE_DEADLINE: project.release_deadline || "(未設定)",
    DEPLOY_READY: s.deploy && s.deploy.ready ? "true" : "false",
    GENERATED_AT: new Date().toISOString(),
  };
}

/** テンプレートの {KEY} を ctx で置換する。未知キーはそのまま残す (呼び出し側が検出する) */
function render(template, ctx) {
  return template.replace(/\{([A-Z_][A-Z0-9_]*)\}/g, (all, key) =>
    Object.prototype.hasOwnProperty.call(ctx, key) ? String(ctx[key]) : all
  );
}

/** 未置換の placeholder を列挙する (テスト・警告用) */
function findPlaceholders(text) {
  const found = new Set();
  const re = /\{([A-Z_][A-Z0-9_]*)\}/g;
  let m;
  while ((m = re.exec(text)) !== null) found.add(m[0]);
  return [...found];
}

/** state.json を原子的に書き換える (tmp → rename) */
function atomicWriteJson(file, obj) {
  const dir = path.dirname(file);
  fs.mkdirSync(dir, { recursive: true });
  const tmp = path.join(dir, `.${path.basename(file)}.${process.pid}.tmp`);
  fs.writeFileSync(tmp, JSON.stringify(obj, null, 2) + "\n", "utf8");
  fs.renameSync(tmp, file);
}

/**
 * deploy 配下のフィールドを更新する。state.json が無い/不正なら何もせず false。
 * (state を持たないディレクトリで --force 生成した場合に、空の state.json を
 *  作らないため)
 */
function updateStateFile(stateFile, values) {
  const state = readJson(stateFile);
  if (!state) return false;
  const deploy = isPlainObject(state.deploy) ? state.deploy : {};
  state.deploy = Object.assign({}, deploy, values);
  atomicWriteJson(stateFile, state);
  return true;
}

function main(argv = process.argv.slice(2), environ = process.env) {
  let opts;
  try {
    opts = parseArgs(argv);
  } catch (e) {
    console.error(`[deploy-runbook] ${e.message}`);
    return 2;
  }
  if (opts.help) {
    usage(process.stdout);
    return 0;
  }
  if (!fs.existsSync(TEMPLATE_FILE)) {
    console.error(`[deploy-runbook] template not found: ${TEMPLATE_FILE}`);
    return 2;
  }

  const cwd = process.cwd();
  const stateFile = path.join(cwd, "state.json");
  const outFile = path.join(cwd, "reports", "deploy-runbook.md");
  const state = readJson(stateFile) || {};
  const deployReady = !!(isPlainObject(state.deploy) && state.deploy.ready);

  if (!deployReady && !opts.force) {
    console.log("[deploy-runbook] state.deploy.ready is not true. Skip generation.");
    console.log("                 Set state.deploy.ready=true, or pass --force to generate anyway.");
    return 0;
  }

  const info = resolveBuildInfo({ cwd, env: opts.env, environ });
  info.cwd = cwd;
  const ctx = buildContext(state, opts, info);
  const rendered =
    `<!-- Auto-generated by scripts/release/generate-deploy-runbook.js at ${ctx.GENERATED_AT} -->\n` +
    "<!-- 重要: 実際のデプロイ実行は人間（ユーザー）が手動で行う。本書は手順書のみ。 -->\n\n" +
    render(fs.readFileSync(TEMPLATE_FILE, "utf8"), ctx);

  const leftover = findPlaceholders(rendered);
  if (leftover.length) {
    console.error(`[deploy-runbook] WARN 未置換の placeholder: ${leftover.join(", ")}`);
  }

  if (opts.dry) {
    process.stdout.write(rendered.endsWith("\n") ? rendered : `${rendered}\n`);
    return 0;
  }

  try {
    fs.mkdirSync(path.dirname(outFile), { recursive: true });
    fs.writeFileSync(outFile, rendered, "utf8");
  } catch (e) {
    console.error(`[deploy-runbook] runbook を書けません: ${e.message}`);
    return 1;
  }

  const relPath = path.relative(cwd, outFile).split(path.sep).join("/");
  console.log(`[deploy-runbook] wrote ${relPath}`);
  console.log(
    `[deploy-runbook] env=${ctx.ENVIRONMENT} commit=${ctx.GIT_COMMIT} tree_sha256=${ctx.TREE_SHA256}`
  );

  // フラグは「実際に書けた runbook」に基づいて立てる
  try {
    const updated = updateStateFile(stateFile, {
      runbook_path: relPath,
      runbook_generated: true,
    });
    if (updated) {
      console.log("[deploy-runbook] state.deploy.runbook_path / runbook_generated を更新");
    } else {
      console.error("[deploy-runbook] state.json が無い/不正のため state は更新しません");
    }
  } catch (e) {
    console.error(`[deploy-runbook] state.json を更新できません: ${e.message}`);
    return 1;
  }

  console.log("[deploy-runbook] ⚠️ デプロイ実行は人間が手動で行ってください");
  return 0;
}

if (require.main === module) {
  process.exitCode = main();
}

module.exports = {
  parseArgs,
  buildContext,
  render,
  resolveBuildInfo,
  updateStateFile,
  findPlaceholders,
  main,
  TEMPLATE_FILE,
};
