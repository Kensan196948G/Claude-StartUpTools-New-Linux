#!/usr/bin/env node
// heartbeat-watchdog.js (ClaudeOS v9.0)
// 外部 cron から定期実行。heartbeat.json の last_beat が閾値以上古ければ
// webhook-notifier.js 経由で api_failure イベントを通知する。
//
// 沈黙 type3 (SIGKILL / OOM Kill / 再起動) のプロセス消滅を検知する外部監視。
// heartbeat-daemon.js が生きていれば 60 秒ごとに last_beat を更新し続ける。
// 更新停止 = Claude Code またはデーモンが消滅した、と判定して通知する。
//
// 使い方 (cron 例):
//   */5 * * * * cd /path/to/project && node .claude/claudeos/scripts/hooks/heartbeat-watchdog.js
//
// 環境変数:
//   HEARTBEAT_STALE_SEC  — 失活判定秒数（デフォルト 300 = 5 分）
//   TEAMS_WEBHOOK_URL    — Teams Incoming Webhook URL
//   HTTPS_WEBHOOK_URL    — 汎用 HTTPS エンドポイント URL
//   HTTPS_WEBHOOK_SECRET — HMAC-256 署名シークレット（任意）
//
// 設計:
//   - fail-soft: heartbeat.json 不在・parse エラー・通知失敗でも exit 0
//   - heartbeat.json 不在は "デーモン未起動" と解釈し通知しない（アラート抑制）
//   - 通知可否は webhook-notifier.js 内の state.json 二重ゲートが決定する

"use strict";

const fs   = require("fs");
const path = require("path");

const PROJECT_ROOT   = process.cwd();
const HEARTBEAT_FILE = path.join(PROJECT_ROOT, "heartbeat.json");
const STALE_SEC      = parseInt(process.env.HEARTBEAT_STALE_SEC || "300", 10);

const log = (...args) => console.error("[HeartbeatWatchdog]", ...args);

async function main() {
  // heartbeat.json 不在 = デーモン未起動（type3 ではない）。通知しない。
  if (!fs.existsSync(HEARTBEAT_FILE)) {
    log("heartbeat.json not found — no daemon running (skip)");
    return;
  }

  let beat = {};
  try {
    beat = JSON.parse(fs.readFileSync(HEARTBEAT_FILE, "utf8"));
  } catch (e) {
    log(`heartbeat.json parse error: ${e.message}`);
    return;
  }

  if (!beat.last_beat) {
    log("heartbeat.json: missing last_beat field (skip)");
    return;
  }

  const lastBeatMs = Date.parse(beat.last_beat);
  if (isNaN(lastBeatMs)) {
    log(`heartbeat.json: invalid last_beat "${beat.last_beat}" (skip)`);
    return;
  }

  const elapsedSec = (Date.now() - lastBeatMs) / 1000;

  if (elapsedSec < STALE_SEC) {
    log(`heartbeat fresh (elapsed=${Math.round(elapsedSec)}s threshold=${STALE_SEC}s)`);
    return;
  }

  log(`heartbeat STALE (elapsed=${Math.round(elapsedSec)}s threshold=${STALE_SEC}s session_id=${beat.session_id || "null"}) — notifying`);

  const notifier = path.join(__dirname, "webhook-notifier.js");
  if (!fs.existsSync(notifier)) {
    log("webhook-notifier.js not found — skip notification");
    return;
  }

  const { notify } = require(notifier);
  await notify("api_failure", {
    reason:        "heartbeat_stale",
    elapsed_sec:   Math.round(elapsedSec),
    threshold_sec: STALE_SEC,
    session_id:    beat.session_id  || null,
    daemon_pid:    beat.daemon_pid  || null,
    last_beat:     beat.last_beat,
    beat_count:    beat.beat_count  || null,
  });
}

main().catch((err) => {
  // fail-soft: watchdog クラッシュで cron を止めない
  console.error(`[HeartbeatWatchdog] fatal: ${err.message}`);
});
