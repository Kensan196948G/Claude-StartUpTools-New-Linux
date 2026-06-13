#!/usr/bin/env node
// heartbeat-daemon.js (ClaudeOS v9.0)
// heartbeat-writer.js から detached spawn される常駐プロセス。
// 60 秒ごとに heartbeat.json を更新し続ける。
//
// Claude Code が SIGKILL / OOM Kill / サーバー再起動で消滅すると、
// 親プロセスが死んでもこの daemon 自体は OS の孤立プロセスとして残るが、
// 次の SessionStart で新しい daemon が起動される。
// heartbeat-watchdog.js は last_beat の停止を検知して通知する。
//
// 引数:
//   argv[2] = session_id (SessionStart フックから渡す)
//
// 設計:
//   - fail-soft: 書き込み失敗でもループ継続
//   - setInterval を使うためイベントループを保持し、プロセスが生き続ける
//   - SIGTERM で正常終了（cron / supervisor からの停止を受け入れる）

"use strict";

const fs   = require("fs");
const path = require("path");

const PROJECT_ROOT   = process.cwd();
const HEARTBEAT_FILE = path.join(PROJECT_ROOT, "heartbeat.json");
const INTERVAL_MS    = 60_000; // 1 分ごと

const sessionId = process.argv[2] || null;

function writeHeartbeat() {
  let existing = {};
  try {
    existing = JSON.parse(fs.readFileSync(HEARTBEAT_FILE, "utf8"));
  } catch { /* 初回 or 壊れていれば空から開始 */ }

  const now = new Date().toISOString();
  const beat = {
    session_id:  sessionId || existing.session_id || null,
    daemon_pid:  process.pid,
    started_at:  existing.started_at || now,
    last_beat:   now,
    beat_count:  (existing.beat_count || 0) + 1,
  };

  const tmp = `${HEARTBEAT_FILE}.tmp.${process.pid}`;
  try {
    fs.writeFileSync(tmp, JSON.stringify(beat, null, 2) + "\n", "utf8");
    fs.renameSync(tmp, HEARTBEAT_FILE);
  } catch (e) {
    // fail-soft: 書き込み失敗でもデーモンは継続
    try { fs.unlinkSync(tmp); } catch { /* ignore */ }
    console.error(`[HeartbeatDaemon] write failed: ${e.message}`);
  }
}

writeHeartbeat(); // 起動直後に 1 回書き込む

setInterval(writeHeartbeat, INTERVAL_MS); // イベントループを保持する（unref() しない）

process.on("SIGTERM", () => {
  process.exit(0);
});
