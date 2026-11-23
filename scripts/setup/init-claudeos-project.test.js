// init-claudeos-project.test.js — 回帰テスト (第3バッチ #2)
//
// 背景: `npm run test:dry-run` の 1/33 が `ReferenceError: m is not defined`
// (scripts/setup/init-claudeos-project.js の copyDirIfMissing 再帰) で落ちていた。
//   - 再帰呼び出しが未宣言の `m.filter` を渡していた → サブディレクトリを見た瞬間に必ず落ちる。
//   - さらに processProject が per-mapping の filter を渡しておらず、
//     `.claude/agents` の first_class 限定 (v10 Lazy Agent Catalog) が効いていなかった。
// ここでは実ファイルを一時ディレクトリに作り、実ネットワーク・実 state に触れずに検証する。
"use strict";

const test   = require("node:test");
const assert = require("node:assert");
const fs     = require("node:fs");
const os     = require("node:os");
const path   = require("node:path");

const init      = require("./init-claudeos-project.js");
const REPO_ROOT = path.join(__dirname, "..", "..");

function mkTmp(prefix) {
  return fs.mkdtempSync(path.join(os.tmpdir(), prefix));
}

function writeFile(file, content = "x\n") {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, content);
}

function emptyPlan() {
  return { create: 0, skip: 0, srcMissing: [] };
}

// quiet — 対象関数の console.log を集めておく（テスト出力を汚さない / 例外時も必ず戻す）
function quiet(fn) {
  const out = [];
  const original = console.log;
  console.log = (...a) => out.push(a.join(" "));
  try {
    return { value: fn(), out };
  } finally {
    console.log = original;
  }
}

// ── 1. 今回のバグ本体（m is not defined）────────────────────────────────

test("copyDirIfMissing: サブディレクトリを含むツリーでも ReferenceError にならない", () => {
  const src = mkTmp("init-src-");
  writeFile(path.join(src, "a.md"));
  writeFile(path.join(src, "nested", "b.md"));
  writeFile(path.join(src, "nested", "deep", "c.md"));
  const dest = mkTmp("init-dest-");
  const plan = emptyPlan();

  assert.doesNotThrow(() => init.copyDirIfMissing(src, dest, plan, true));
  assert.strictEqual(plan.create, 3);
  assert.deepStrictEqual(fs.readdirSync(dest), [], "dry-run はターゲットに書かない");
});

test("copyDirIfMissing: dryRun=false ではネスト先まで実コピーする", () => {
  const src = mkTmp("init-src-");
  writeFile(path.join(src, "a.md"), "A\n");
  writeFile(path.join(src, "nested", "deep", "c.md"), "C\n");
  const dest = mkTmp("init-dest-");
  const plan = emptyPlan();

  init.copyDirIfMissing(src, dest, plan, false);

  assert.strictEqual(plan.create, 2);
  assert.strictEqual(fs.readFileSync(path.join(dest, "a.md"), "utf8"), "A\n");
  assert.strictEqual(fs.readFileSync(path.join(dest, "nested", "deep", "c.md"), "utf8"), "C\n");
});

test("copyDirIfMissing: filter は再帰に伝播し、除外ファイルは計画にも実コピーにも入らない", () => {
  const src = mkTmp("init-src-");
  writeFile(path.join(src, "keep.md"));
  writeFile(path.join(src, "skip.md"));
  writeFile(path.join(src, "nested", "keep2.md"));
  writeFile(path.join(src, "nested", "skip.md"));
  const dest = mkTmp("init-dest-");
  const plan = emptyPlan();
  const filter = (name) => name !== "skip.md";

  init.copyDirIfMissing(src, dest, plan, false, filter);

  assert.strictEqual(plan.create, 2, "除外された 2 件は計画に入らない");
  assert.ok(fs.existsSync(path.join(dest, "keep.md")));
  assert.ok(fs.existsSync(path.join(dest, "nested", "keep2.md")));
  assert.ok(!fs.existsSync(path.join(dest, "skip.md")));
  assert.ok(!fs.existsSync(path.join(dest, "nested", "skip.md")));
});

// ── 2. --project 解決 ───────────────────────────────────────────────────

test("resolveTargetPath: --project は config の basePath / projectsDir から解決する", () => {
  const cfgRoot = mkTmp("init-cfg-");
  const cfgPath = path.join(cfgRoot, "config.json");
  writeFile(cfgPath, JSON.stringify({ basePath: path.join(cfgRoot, "Projects") }));

  const basePath = quiet(() => init.resolveTargetPath({
    target: null, projectFilter: "Demo", configPath: cfgPath,
  })).value;
  assert.strictEqual(basePath, path.join(cfgRoot, "Projects", "Demo"));

  const cfgPath2 = path.join(cfgRoot, "linux-projects.json");
  writeFile(cfgPath2, JSON.stringify({ projectsDir: path.join(cfgRoot, "projects2") }));
  const projectsDir = quiet(() => init.resolveTargetPath({
    target: null, projectFilter: "Other", configPath: cfgPath2,
  })).value;
  assert.strictEqual(projectsDir, path.join(cfgRoot, "projects2", "Other"));
});

test("resolveTargetPath: --target は --project/config より優先される", () => {
  const resolved = init.resolveTargetPath({
    target: "./SomeProject", projectFilter: "Ignored", configPath: "/nonexistent/config.json",
  });
  assert.strictEqual(resolved, path.resolve("./SomeProject"));
});

// ── 3. dry-run 計画（イベント: 実テンプレートを読むが書き込みはしない） ──

test("processProject: dry-run はターゲットに何も書かず、計画 (create>0) を返す", () => {
  const target = mkTmp("init-proj-");

  const { value: totals, out } = quiet(() => init.processProject(target, true, false));

  assert.ok(totals.create > 0, "create が 0 (テンプレートが見つからない可能性)");
  assert.deepStrictEqual(fs.readdirSync(target), [], "dry-run は 1 ファイルも書かない");
  assert.ok(out.some(l => l.includes("[DRY-RUN]")), "dry-run のラベルが出ていない");
});

test("planDirMapping: .claude/agents は per-mapping の first_class フィルタを適用する", () => {
  const mapping = init.MAPPINGS.find(m => m.dest === ".claude/agents");
  assert.ok(mapping, ".claude/agents の mapping が無い");
  assert.strictEqual(typeof mapping.filter, "function", "first_class フィルタが未配線");

  const srcDir = path.join(REPO_ROOT, mapping.src);
  const catalog = JSON.parse(fs.readFileSync(path.join(REPO_ROOT, "config", "agent-catalog.json"), "utf8"));
  const firstClass = catalog.first_class
    .map(a => `${a.name}.md`)
    .filter(name => fs.existsSync(path.join(srcDir, name)));
  const allEntries = fs.readdirSync(srcDir);

  assert.ok(firstClass.length > 0, "first_class が空");
  assert.ok(firstClass.length < allEntries.length, "フィルタが効かないと全件配布になる");

  const target = mkTmp("init-agents-");
  const plan = init.planDirMapping(mapping, target, true);

  assert.strictEqual(plan.create, firstClass.length, "first_class 以外まで計画に入っている");
  assert.deepStrictEqual(fs.readdirSync(target), []);
});

// ── 4. copy-if-missing の不変条件 ───────────────────────────────────────

test("copyFileIfMissing: 既存ファイルは上書きせず skip、無ければ create", () => {
  const src = mkTmp("init-fsrc-");
  writeFile(path.join(src, "state.json"), "NEW\n");
  const target = mkTmp("init-fdest-");

  const existing = path.join(target, "state.json");
  writeFile(existing, "KEEP\n");
  const plan1 = emptyPlan();
  init.copyFileIfMissing(path.join(src, "state.json"), existing, plan1, false);
  assert.strictEqual(plan1.skip, 1);
  assert.strictEqual(fs.readFileSync(existing, "utf8"), "KEEP\n");

  const fresh = path.join(target, "other.json");
  const plan2 = emptyPlan();
  init.copyFileIfMissing(path.join(src, "state.json"), fresh, plan2, false);
  assert.strictEqual(plan2.create, 1);
  assert.strictEqual(fs.readFileSync(fresh, "utf8"), "NEW\n");
});
