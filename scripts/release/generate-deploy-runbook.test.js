#!/usr/bin/env node
/**
 * generate-deploy-runbook.test.js — runbook 生成スクリプトのテスト
 *
 * 契約:
 *   - 生成物に commit SHA (git rev-parse HEAD) と tree_sha256 (env-current manifest) が入る
 *   - 生成時に state.deploy.runbook_path / runbook_generated を実ファイルに基づいて更新する
 *   - --dry は state も reports/ も書かない
 *   - テンプレート/生成物に placeholder (example.com / コメントアウト deploy / {KEY}) が無い
 *   - state template に deploy ブロックがある (D6)
 *
 * 隔離: 一時ディレクトリに git リポジトリと state.json を作り、
 *       CLAUDEOS_HOME も一時ディレクトリへ向ける (実 ~/.claudeos を読まない)。
 */

"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { execFileSync, spawnSync } = require("node:child_process");

const SCRIPT = path.join(__dirname, "generate-deploy-runbook.js");
const MODULE = require(SCRIPT);
const REPO_ROOT = path.resolve(__dirname, "..", "..");
const TEMPLATE = path.join(REPO_ROOT, "Claude", "templates", "claudeos", "docs", "deploy-runbook-template.md");
const STATE_TEMPLATE = path.join(REPO_ROOT, "scripts", "setup", "state-template.json");
const STATE_EXAMPLE = path.join(REPO_ROOT, "state.json.example");
const SCHEMA = path.join(REPO_ROOT, "state.schema.json");

const TREE = "b".repeat(64);

function git(cwd, ...args) {
  return execFileSync("git", args, {
    cwd,
    encoding: "utf8",
    stdio: ["ignore", "pipe", "ignore"],
  }).trim();
}

/** 一時ディレクトリに「git リポジトリ + state.json + env-current manifest」を作る */
function makeFixture({ ready = true } = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "deploy-runbook-"));
  const home = path.join(dir, "claudeos-home");
  const manifestDir = path.join(home, "releases", "production-current");
  fs.mkdirSync(manifestDir, { recursive: true });
  fs.writeFileSync(
    path.join(manifestDir, "manifest.json"),
    JSON.stringify({ schema_version: 1, commit: "c".repeat(40), tree_sha256: TREE, files: [] })
  );

  git(dir, "init", "-q");
  git(dir, "config", "user.email", "t@example.invalid");
  git(dir, "config", "user.name", "t");
  fs.writeFileSync(
    path.join(dir, "state.json"),
    JSON.stringify(
      {
        project: { name: "demo" },
        goal: { title: "demo" },
        stable: { stable_achieved: false, consecutive_success: 0 },
        deploy: {
          ready,
          runbook_generated: false,
          runbook_path: null,
          pre_deploy_checklist_done: false,
          environment: null,
          notes: "",
        },
      },
      null,
      2
    ) + "\n"
  );
  fs.writeFileSync(path.join(dir, "a.txt"), "x\n");
  git(dir, "add", "-A");
  git(dir, "commit", "-qm", "init");
  const head = git(dir, "rev-parse", "HEAD");
  return { dir, home, head, stateFile: path.join(dir, "state.json"), runbook: path.join(dir, "reports", "deploy-runbook.md") };
}

function cleanup(fx) {
  fs.rmSync(fx.dir, { recursive: true, force: true });
}

function run(fx, args) {
  return spawnSync(process.execPath, [SCRIPT, ...args], {
    cwd: fx.dir,
    encoding: "utf8",
    env: { ...process.env, CLAUDEOS_HOME: fx.home },
  });
}

function readText(file) {
  return fs.readFileSync(file, "utf8");
}

function readJsonFile(file) {
  return JSON.parse(readText(file));
}

function assertNoPlaceholders(text) {
  const leftover = text.match(/\{[A-Z_][A-Z0-9_]*\}/g) || [];
  assert.deepEqual(leftover, [], `未置換 placeholder: ${leftover.join(", ")}`);
}

function assertNoDeadPlaceholders(text) {
  assert.equal(text.includes("example.com"), false, "example.com が残っている");
  assert.doesNotMatch(text, /^[ \t]*#[ \t]*(npm run deploy|docker-compose[^\n#]*deploy)/m, "コメントアウトされた deploy コマンドが残っている");
  assertNoPlaceholders(text);
}

// ------------------------------------------------------------
// 引数 / 純関数
// ------------------------------------------------------------

test("parseArgs: 既定は production / --env staging / 不正 env・不明引数は throw", () => {
  assert.equal(MODULE.parseArgs([]).env, "production");
  assert.equal(MODULE.parseArgs(["--env", "staging"]).env, "staging");
  assert.equal(MODULE.parseArgs(["--dry"]).dry, true);
  assert.throws(() => MODULE.parseArgs(["--env", "prod"]), /staging\|production/);
  assert.throws(() => MODULE.parseArgs(["--nope"]), /不明な引数/);
});

test("buildContext: env ごとの unit/port/health と commit を埋める", () => {
  const info = { commit: "d".repeat(40), shortCommit: "ddddddd", branch: "main", tag: "v1", treeSha256: TREE, manifestCommit: "c".repeat(40), releasesDir: "/tmp/rel", cwd: "/tmp/demo" };
  const prod = MODULE.buildContext({ deploy: { ready: true } }, { env: "production" }, info);
  assert.equal(prod.ENVIRONMENT, "production");
  assert.equal(prod.UNIT, "claudeos-web-startup.service");
  assert.equal(prod.PORT, "3740");
  assert.equal(prod.HEALTH_URL, "http://127.0.0.1:3740/api/health");
  assert.equal(prod.GIT_COMMIT, "d".repeat(40));
  assert.equal(prod.TREE_SHA256, TREE);

  const stg = MODULE.buildContext({ deploy: { ready: true } }, { env: "staging" }, info);
  assert.equal(stg.UNIT, "claudeos-web-startup-stg.service");
  assert.equal(stg.PORT, "3742");
});

test("buildContext: manifest 不在なら tree_sha256 は『未生成』を明示する (嘘を書かない)", () => {
  const info = { commit: "d".repeat(40), shortCommit: "ddddddd", branch: "main", tag: "", treeSha256: "", manifestCommit: "", releasesDir: "/tmp/rel", cwd: "/tmp/demo" };
  const ctx = MODULE.buildContext({}, { env: "production" }, info);
  assert.match(ctx.TREE_SHA256, /未生成/);
  assert.equal(ctx.GIT_BRANCH, "main");
});

test("resolveBuildInfo: CLAUDEOS_HOME の env-current manifest から tree_sha256 を読む", () => {
  const fx = makeFixture();
  try {
    const info = MODULE.resolveBuildInfo({ cwd: fx.dir, env: "production", environ: { CLAUDEOS_HOME: fx.home } });
    assert.equal(info.commit, fx.head);
    assert.equal(info.treeSha256, TREE);
    assert.equal(info.manifestCommit, "c".repeat(40));
  } finally {
    cleanup(fx);
  }
});

// ------------------------------------------------------------
// 統合 (実プロセス)
// ------------------------------------------------------------

test("生成: runbook を書き、state の runbook_path/runbook_generated を実体に基づいて更新する", () => {
  const fx = makeFixture();
  try {
    const r = run(fx, []);
    assert.equal(r.status, 0, r.stderr);
    const runbook = readText(fx.runbook);
    assert.equal(runbook.includes(fx.head), true, "commit SHA が入っていない");
    assert.equal(runbook.includes(TREE), true, "tree_sha256 が入っていない");
    assert.equal(runbook.includes("claudeos-web-startup.service"), true);
    assert.equal(runbook.includes("127.0.0.1:3740/api/health"), true);
    assertNoDeadPlaceholders(runbook);

    const state = readJsonFile(fx.stateFile);
    assert.equal(state.deploy.runbook_generated, true);
    assert.equal(state.deploy.runbook_path, "reports/deploy-runbook.md");
    assert.equal(fs.existsSync(path.join(fx.dir, state.deploy.runbook_path)), true);
    // 既存フィールドを壊さない
    assert.equal(state.project.name, "demo");
    assert.equal(state.deploy.pre_deploy_checklist_done, false);
  } finally {
    cleanup(fx);
  }
});

test("--dry: 何も書かない (reports も state も)", () => {
  const fx = makeFixture();
  try {
    const before = readText(fx.stateFile);
    const r = run(fx, ["--dry"]);
    assert.equal(r.status, 0, r.stderr);
    assert.match(r.stdout, /# デプロイ手順書/);
    assert.equal(fs.existsSync(fx.runbook), false);
    assert.equal(readText(fx.stateFile), before);
  } finally {
    cleanup(fx);
  }
});

test("deploy.ready=false は --force 無しでスキップ、--force で生成する", () => {
  const fx = makeFixture({ ready: false });
  try {
    const before = readText(fx.stateFile);
    const skip = run(fx, []);
    assert.equal(skip.status, 0, skip.stderr);
    assert.match(skip.stdout, /Skip generation/);
    assert.equal(fs.existsSync(fx.runbook), false);
    assert.equal(readText(fx.stateFile), before);

    const forced = run(fx, ["--force"]);
    assert.equal(forced.status, 0, forced.stderr);
    assert.equal(fs.existsSync(fx.runbook), true);
    assert.equal(readJsonFile(fx.stateFile).deploy.runbook_generated, true);
  } finally {
    cleanup(fx);
  }
});

test("不正な引数は exit 2 でファイルを書かない", () => {
  const fx = makeFixture();
  try {
    const r = run(fx, ["--env", "prod"]);
    assert.equal(r.status, 2);
    assert.match(r.stderr, /staging\|production/);
    assert.equal(fs.existsSync(fx.runbook), false);
  } finally {
    cleanup(fx);
  }
});

// ------------------------------------------------------------
// テンプレート / state 定義
// ------------------------------------------------------------

test("テンプレート: 実行不能 placeholder が無く、実コマンドを記載する", () => {
  const template = readText(TEMPLATE);
  // {KEY} はテンプレートの正規メカニズムなので残ってよい。
  // 除去対象は「実行不能な固定値」と「コメントアウトされた deploy コマンド」。
  assert.equal(template.includes("example.com"), false, "example.com が残っている");
  assert.doesNotMatch(
    template,
    /^[ \t]*#[ \t]*(npm run deploy|docker-compose[^\n#]*deploy)/m,
    "コメントアウトされた deploy コマンドが残っている"
  );
  assert.equal(/bin\/release-build\.sh/.test(template), true);
  assert.match(template, /bin\/release-promote\.sh --env staging/);
  assert.match(template, /bin\/release-promote\.sh --env production/);
  assert.match(template, /scripts\/release\/post-deploy-smoke\.sh/);
  assert.match(template, /--rollback/);
});

test("render: テンプレートの全 placeholder が埋まる", () => {
  const template = readText(TEMPLATE);
  const info = { commit: "e".repeat(40), shortCommit: "eeeeeee", branch: "main", tag: "v1", treeSha256: TREE, manifestCommit: "c".repeat(40), releasesDir: "/tmp/rel", cwd: "/tmp/demo" };
  const ctx = MODULE.buildContext({ deploy: { ready: true } }, { env: "production" }, info);
  const rendered = MODULE.render(template, ctx);
  assert.deepEqual(MODULE.findPlaceholders(rendered), []);
  assert.equal(rendered.includes(TREE), true);
  assert.equal(rendered.includes("e".repeat(40)), true);
});

test("state 定義: deploy ブロックが schema / template / example で一致し、死んだフラグが無い", () => {
  const schemaDeploy = readJsonFile(SCHEMA).properties.deploy.properties;
  const templateDeploy = readJsonFile(STATE_TEMPLATE).deploy;
  const exampleDeploy = readJsonFile(STATE_EXAMPLE).deploy;

  const schemaKeys = Object.keys(schemaDeploy).sort();
  assert.deepEqual(Object.keys(templateDeploy).sort(), schemaKeys, "state-template.json の deploy キーが schema と不一致");
  assert.deepEqual(Object.keys(exampleDeploy).sort(), schemaKeys, "state.json.example の deploy キーが schema と不一致");

  // 書き込み主体が無かったフィールドは削除済み (D3)
  for (const dead of ["executed_at", "executed_by", "post_deploy_verified"]) {
    assert.equal(dead in schemaDeploy, false, `${dead} が schema に残っている`);
    assert.equal(dead in templateDeploy, false, `${dead} が state-template に残っている`);
    assert.equal(dead in exampleDeploy, false, `${dead} が state.json.example に残っている`);
  }

  // 書き込み主体があるフィールドは残っている
  for (const alive of ["ready", "runbook_generated", "runbook_path", "pre_deploy_checklist_done", "environment", "notes"]) {
    assert.equal(alive in schemaDeploy, true, `${alive} が schema に無い`);
  }

  // template の deploy は型が schema と整合する (partial state として valid)
  assert.equal(templateDeploy.ready, false);
  assert.equal(templateDeploy.runbook_path, null);
});
