#!/usr/bin/env node
// PostToolUse hook (ClaudeOS v9.0)
// エージェント名義の外部操作 audit trail を JSONL で記録する。
//
// 背景 (agent identity モデル):
// - Trust Level の裏付けとして「行動レベルの証跡」を残す。
// - 記録対象は外部へ影響する書込操作のみ (読取・ローカル編集は対象外):
//     Bash : gh / git の書込サブコマンド (push / commit / merge / create / edit ...)
//     MCP  : mcp__* の write 系ツール (create / update / merge / push / delete ...)
// - 出力: .claude/claudeos/data/audit-log.jsonl (1 行 1 操作)
//
// 設計方針:
//  - fail-soft: いかなる失敗でも exit 0 (Claude 本体のフローを止めない)
//  - 記録はローカル append のみ (外部送信しない)
//  - 1MB 超過で .1 へ単段ローテーション

const fs = require("fs");
const path = require("path");

const AUDIT_FILE = path.join(process.cwd(), ".claude", "claudeos", "data", "audit-log.jsonl");
const MAX_BYTES = 1024 * 1024;
const CMD_MAX_LEN = 300;

// Bash: gh/git の書込サブコマンド判定 (gh api は isGhApiWrite で別判定)
const BASH_WRITE_RE = new RegExp(
  "\\b(?:" +
    "git\\s+(?:push|commit|merge|tag|rebase|reset|revert|cherry-pick|branch\\s+-[dD]|remote\\s+(?:add|remove|set-url))" +
    "|gh\\s+(?:pr|issue|release|repo|label|secret|workflow)\\s+\\S*\\s*(?:create|merge|edit|close|reopen|comment|delete|transfer|set|enable|disable|run|cancel)" +
  ")\\b"
);

// gh api の書込判定: -f/-F/--field/--raw-field/--input を付けると gh は暗黙的に
// POST へ切り替わるため、-X 明示だけを見ると書込を取りこぼす。
// -X GET/HEAD が明示されている場合のみ読取とみなす。
function isGhApiWrite(cmd) {
  if (!/\bgh\s+api\b/.test(cmd)) return false;
  if (/(?:^|\s)(?:-X|--method)[= ]\s*(?:GET|HEAD)\b/i.test(cmd)) return false;
  return /(?:^|\s)(?:-X|--method)[= ]\s*(?:POST|PUT|PATCH|DELETE)\b/i.test(cmd) ||
         /(?:^|\s)(?:-f|-F|--raw-field|--field|--input)\b/.test(cmd);
}

// MCP: write 系ツール名判定
const MCP_WRITE_RE = /^mcp__.+__(?:.*(?:create|update|merge|push|delete|add|write|apply|move|duplicate|send|schedule|label|unlabel).*)$/i;

function readStdin() {
  try { return fs.readFileSync(0, "utf8"); } catch { return ""; }
}

function parseHookInput(raw) {
  if (!raw) return {};
  try { return JSON.parse(raw); } catch { return {}; }
}

function summarize(toolName, toolInput) {
  if (toolName === "Bash") {
    const cmd = String(toolInput.command || "");
    if (!BASH_WRITE_RE.test(cmd) && !isGhApiWrite(cmd)) return null;
    return cmd.replace(/\s+/g, " ").trim().slice(0, CMD_MAX_LEN);
  }
  if (MCP_WRITE_RE.test(toolName)) {
    // MCP 入力は機微情報 (body 本文等) を含み得るため、キー名だけ残す
    const keys = Object.keys(toolInput || {}).slice(0, 10).join(",");
    return `params(${keys})`;
  }
  return null;
}

function rotateIfNeeded(file) {
  try {
    const st = fs.statSync(file);
    if (st.size > MAX_BYTES) fs.renameSync(file, `${file}.1`);
  } catch { /* 初回 (ファイル未存在) は何もしない */ }
}

function main() {
  const input = parseHookInput(readStdin());
  const toolName  = input.tool_name || input.toolName || (input.tool && input.tool.name) || "";
  const toolInput = input.tool_input || input.toolInput || (input.tool && input.tool.input) || {};

  const action = summarize(toolName, toolInput);
  if (!action) process.exit(0);

  const entry = {
    ts: new Date().toISOString(),
    session: process.env.CLAUDE_SESSION_ID || "",
    project: path.basename(process.cwd()),
    tool: toolName,
    action,
  };

  try {
    fs.mkdirSync(path.dirname(AUDIT_FILE), { recursive: true });
    rotateIfNeeded(AUDIT_FILE);
    fs.appendFileSync(AUDIT_FILE, JSON.stringify(entry) + "\n", "utf8");
  } catch (err) {
    console.error(`[audit-trail] append failed: ${err.message}`);
  }
  process.exit(0);
}

try {
  main();
} catch (err) {
  console.error(`[audit-trail] unexpected error: ${err.message}`);
  process.exit(0);
}
