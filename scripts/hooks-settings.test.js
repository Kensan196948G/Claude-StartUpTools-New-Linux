// hooks-settings.test.js (ClaudeOS v10) — settings.json の hook 配線整合性テスト
// - 参照する hook スクリプトがテンプレート (正本) と runtime の両方に存在する
// - command は ${CLAUDE_PROJECT_DIR} で絶対化されている (worktree / team モードで相対パスは失敗する)
// - runtime と template の hooks ブロックが一致する (配布差分の再発防止)
"use strict";
const test = require("node:test");
const assert = require("node:assert");
const fs = require("fs");
const path = require("path");
const ROOT = path.resolve(__dirname, "..");
const FILES = [".claude/settings.json", "Claude/templates/claude/settings.json"];
const T = path.join(ROOT, "Claude/templates/claudeos/scripts/hooks");
const R = path.join(ROOT, ".claude/claudeos/scripts/hooks");
function commands(settings) {
  const out = [];
  for (const [event, entries] of Object.entries(settings.hooks || {})) {
    for (const e of entries) for (const h of e.hooks || []) if (h.type === "command") out.push({ event, command: h.command });
  }
  return out;
}
for (const rel of FILES) {
  test(`${rel}: hook scripts exist in template and runtime`, () => {
    const s = JSON.parse(fs.readFileSync(path.join(ROOT, rel), "utf8"));
    const cmds = commands(s);
    assert.ok(cmds.length > 0, "no hook commands");
    for (const { event, command } of cmds) {
      const m = command.match(/scripts\/hooks\/([A-Za-z0-9._-]+\.js)/);
      assert.ok(m, `${event}: unrecognized command ${command}`);
      assert.ok(fs.existsSync(path.join(T, m[1])), `${event}: ${m[1]} missing in template`);
      assert.ok(fs.existsSync(path.join(R, m[1])), `${event}: ${m[1]} missing in runtime`);
      assert.ok(command.includes("${CLAUDE_PROJECT_DIR}"), `${event}: ${m[1]} must use \${CLAUDE_PROJECT_DIR}`);
    }
  });
}
test("runtime and template hooks blocks are identical", () => {
  const a = JSON.parse(fs.readFileSync(path.join(ROOT, FILES[0]), "utf8")).hooks;
  const b = JSON.parse(fs.readFileSync(path.join(ROOT, FILES[1]), "utf8")).hooks;
  assert.deepStrictEqual(a, b);
});
test("Stop hook is async (no per-turn blocking)", () => {
  const s = JSON.parse(fs.readFileSync(path.join(ROOT, FILES[0]), "utf8"));
  for (const e of s.hooks.Stop) for (const h of e.hooks) assert.strictEqual(h.async, true);
});
test("project settings do not carry ignored defaultMode", () => {
  for (const rel of FILES) {
    const s = JSON.parse(fs.readFileSync(path.join(ROOT, rel), "utf8"));
    assert.strictEqual((s.permissions || {}).defaultMode, undefined, `${rel} defaultMode is ignored at project level (>=2.1.257)`);
  }
});
test("deny list closes wrapper / force-push / admin-merge bypasses", () => {
  const s = JSON.parse(fs.readFileSync(path.join(ROOT, FILES[0]), "utf8"));
  const deny = s.permissions.deny;
  for (const rule of ["Bash(bash -c *)", "Bash(env *)", "Bash(git push --force*)", "Bash(gh pr merge --admin*)", "mcp__github__merge_pull_request", "Bash(git commit * --no-verify*)"]) {
    assert.ok(deny.includes(rule), `missing deny: ${rule}`);
  }
  for (const rule of ["Bash(bash *)", "Bash(sh *)", "Bash(env *)", "Bash(curl *)", "Bash(kill *)", "Bash(rm *)", "mcp__github__*"]) {
    assert.ok(!s.permissions.allow.includes(rule), `over-broad allow still present: ${rule}`);
  }
});
