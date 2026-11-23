"use strict";
/**
 * scripts/tools/project-registry.test.js
 *
 * 台帳鮮度チェックの回帰テスト。
 * 実リポジトリの config/ に対しては「DRIFT していないこと」を検証する（--fix 適用後の回帰）。
 */

const test = require("node:test");
const assert = require("node:assert");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const reg = require("./project-registry");

function tmpdir() {
  return fs.mkdtempSync(path.join(os.tmpdir(), "registry-test-"));
}

function mkRepo(base, name) {
  const dir = path.join(base, name);
  fs.mkdirSync(path.join(dir, ".git"), { recursive: true });
  return dir;
}

test("isIgnoredProjectName: 隠し・退避・バックアップを除外する", () => {
  assert.equal(reg.isIgnoredProjectName(".hidden"), true);
  assert.equal(reg.isIgnoredProjectName("_shared"), false);
  assert.equal(reg.isIgnoredProjectName("Foo.old"), true);
  assert.equal(reg.isIgnoredProjectName("cleanup-backup-2026"), true);
  assert.equal(reg.isIgnoredProjectName("Normal"), false);
});

test("scanLocalProjects: .git を持つディレクトリだけを昇順で返す", () => {
  const base = tmpdir();
  mkRepo(base, "B-Repo");
  mkRepo(base, "A-Repo");
  fs.mkdirSync(path.join(base, "Not-Repo"));
  fs.mkdirSync(path.join(base, ".hidden-repo", ".git"), { recursive: true });
  fs.mkdirSync(path.join(base, "Old.old", ".git"), { recursive: true });
  assert.deepEqual(reg.scanLocalProjects(base), ["A-Repo", "B-Repo"]);
});

test("scanLocalProjects: exclude で自分自身を外せる", () => {
  const base = tmpdir();
  mkRepo(base, "Self");
  mkRepo(base, "Other");
  assert.deepEqual(reg.scanLocalProjects(base, { exclude: ["Self"] }), ["Other"]);
});

test("checkLinuxRegistry: 実在しない・台帳に無いを両方向で検出する", () => {
  const res = reg.checkLinuxRegistry(
    { basePath: "/p", projects: ["Exists", "Gone"] },
    ["Exists", "NewOne"]
  );
  assert.equal(res.ok, false);
  assert.deepEqual(res.missing, ["Gone"]);
  assert.deepEqual(res.unlisted, ["NewOne"]);
});

test("buildFixedLinuxRegistry: 消えた項目を _stale に退避し、実測へ合わせる", () => {
  const fixed = reg.buildFixedLinuxRegistry(
    { basePath: "/p", projects: ["Gone", "Exists"], _stale: [{ name: "Old", reason: "X" }] },
    ["Exists", "NewOne"],
    "2026-01-01T00:00:00.000Z"
  );
  assert.deepEqual(fixed.projects, ["Exists", "NewOne"]);
  assert.deepEqual(fixed._stale.map((s) => s.name), ["Gone", "Old"]);
  assert.equal(fixed._verified_at, "2026-01-01T00:00:00.000Z");
});

test("checkGithubRegistry: 空 URL と不正 URL を検出する", () => {
  const res = reg.checkGithubRegistry({
    A: { url: "" },
    B: { url: "not-a-url" },
    C: { url: "https://github.com/o/r" },
  });
  assert.equal(res.ok, false);
  assert.deepEqual(res.emptyUrl, ["A"]);
  assert.deepEqual(res.missing.map((m) => m.name), ["B"]);
});

test("checkGithubRegistry: exists が false のものだけ NOT_FOUND にする", () => {
  const res = reg.checkGithubRegistry(
    {
      Live: { url: "https://github.com/o/live" },
      Dead: { url: "https://github.com/o/dead" },
    },
    (repo) => repo === "o/live"
  );
  assert.deepEqual(res.missing, [{ name: "Dead", url: "https://github.com/o/dead", reason: "NOT_FOUND" }]);
});

test("buildFixedGithubRegistry: 消えたものだけ _stale へ移し、実在は残す", () => {
  const fixed = reg.buildFixedGithubRegistry(
    { projects: { Live: { url: "https://github.com/o/live" }, Dead: { url: "https://github.com/o/dead" } } },
    { missing: [{ name: "Dead", url: "https://github.com/o/dead", reason: "NOT_FOUND" }], emptyUrl: [] },
    "2026-01-01T00:00:00.000Z"
  );
  assert.deepEqual(Object.keys(fixed.projects), ["Live"]);
  assert.deepEqual(fixed._stale.map((s) => s.name), ["Dead"]);
});

test("実リポジトリの linux-projects.json は filesystem と一致している（回帰）", () => {
  const root = path.resolve(__dirname, "..", "..");
  const file = path.join(root, "config", "linux-projects.json");
  const data = JSON.parse(fs.readFileSync(file, "utf8"));
  const actual = reg.scanLocalProjects(data.basePath);
  const res = reg.checkLinuxRegistry(data, actual);
  assert.equal(res.ok, true, `drift: missing=${res.missing} unlisted=${res.unlisted}`);
});

test("実リポジトリの github-registry.json は URL 形式が妥当（回帰）", () => {
  const root = path.resolve(__dirname, "..", "..");
  const file = path.join(root, "config", "github-registry.json");
  const data = JSON.parse(fs.readFileSync(file, "utf8"));
  const res = reg.checkGithubRegistry(data.projects);
  assert.equal(res.ok, true, `emptyUrl=${res.emptyUrl} invalid=${JSON.stringify(res.missing)}`);
});
