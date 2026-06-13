#!/usr/bin/env node
// heartbeat-writer.js (ClaudeOS v9.0)
// SessionStart フックとして heartbeat-daemon.js を detached spawn するフック。
// daemon は 60 秒ごとに heartbeat.json を更新し続け、
// heartbeat-watchdog.js (外部 cron) が更新停止を検知して沈黙 type3 を通知する。
//
// 沈黙 3 類型:
//   type1: API エラー停止     → stop-failure-gate.js (api_failure)
//   type2: 入力待ち沈黙      → notification-gate.js (input_waiting)
//   type3: プロセス消滅 ★本フックが担当
//          SIGKILL / OOM Kill / サーバー再起動で Claude Code が死ぬと
//          daemon の更新が止まり heartbeat-watchdog.js が検知して通知する。
//
// 設計:
//   - stdin の SessionStart ペイロードから session_id を抽出
//   - detached + stdio:ignore + child.unref() で daemon を起動後、即 process.exit(0)
//   - fail-soft: daemon 起動失敗でも運用をブロックしない
//   - stdout には何も出さない（session-start.js の hookSpecificOutput JSON と干渉回避）

"use strict";

const fs   = require("fs");
const path = require("path");
const { spawn } = require("child_process");

const log = (...args) => console.error("[HeartbeatWriter]", ...args);

// stdin から SessionStart ペイロードを読む。fail-soft。
function readStdinJson() {
  try {
    const raw = fs.readFileSync(0, "utf8");
    if (!raw || !raw.trim()) return {};
    return JSON.parse(raw);
  } catch {
    return {};
  }
}

try {
  const input = readStdinJson();

  // session_id: 公式フィールド名と camelCase フォールバック
  const asStr = (v) => (typeof v === "string" && v.trim() ? v.trim() : null);
  const sessionId =
    asStr(input.session_id) ||
    asStr(input.sessionId)  ||
    null;

  const daemon = path.join(__dirname, "heartbeat-daemon.js");

  if (!fs.existsSync(daemon)) {
    log("heartbeat-daemon.js not found — skip");
    process.exit(0);
  }

  const spawnArgs = sessionId ? [daemon, sessionId] : [daemon];
  const child = spawn(process.execPath, spawnArgs, {
    detached: true,
    stdio:    "ignore",
    cwd:      process.cwd(),
  });

  const pid = child.pid;

  // spawn 同期失敗を拾う（unref 後は到達しない）
  child.on("error", (e) => console.error(`[HeartbeatWriter] spawn failed: ${e.message}`));
  child.unref(); // 親の終了をブロックしない

  log(`daemon spawned (pid=${pid} session_id=${sessionId || "null"})`);
} catch (err) {
  // fail-soft: フック自身の例外で運用をブロックしない
  console.error(`[HeartbeatWriter] failed: ${err.message}`);
}

process.exit(0);
