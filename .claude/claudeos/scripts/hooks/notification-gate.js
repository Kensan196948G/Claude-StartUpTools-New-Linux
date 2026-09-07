#!/usr/bin/env node
// Notification hook (ClaudeOS v9.0)
// Claude Code が人間の応答を待って停止した時に発火する。ツール許可ダイアログ
// (permission_prompt) や次プロンプト入力待ち (idle_prompt) が代表で、無人 cron 運用では
// この「入力待ち沈黙」が永久に進まない死角になる。それを検知して外部通知する観測専用フック。
//
// 沈黙 3 類型のうち本フックがカバーするのは type2（入力待ち沈黙）。type1（API エラー沈黙）は
// stop-failure-gate.js（api_failure）が、type3（プロセス消滅: SIGKILL / OOM / 再起動）は
// 別途 heartbeat watchdog が担当する。本フックと stop-failure-gate.js は双子の fail-soft 設計。
//
// hooks-guide: Notification は通知が発火済みのため出力でブロックできない（観測専用）。
// stdout / exit code は運用に影響しないので、何があっても運用をブロックしない fail-soft に徹する。
//
// 動作: stdin の Notification ペイロードから notification_type（種別）と message（本文）を抽出し、
//       webhook-notifier.js を input_waiting イベントで detached spawn する（親をブロックしない）。
//
// 参照: 公式 hooks ガイド Notification。単一イベントで matcher が種別を区別する。種別は
//       ペイロードの `notification_type` に入る。代表値:
//       idle_prompt（次プロンプト入力待ち）/ permission_prompt（ツール許可待ち）/
//       auth_success / elicitation_*（MCP elicitation）/ ""（全発火）。本フックは settings.json 側で
//       matcher="idle_prompt" と "permission_prompt" の 2 エントリを配線し、無人運用で致命的な
//       2 種の入力待ちだけを通知する（auth_success 等の情報通知はノイズになるため拾わない）。
//
// 既知の制約（フォローアップ Issue で追跡。本フックのスコープ外）:
//   - Notification が発火しない異常終了（type3: SIGKILL / OOM / 再起動）は検知不能。
//   - 通知の最終到達（Webhook の HTTP 成功）は detached + stdio:ignore のため親から不可視。
//     本フックは「通知プロセスの起動（spawn）」までを保証し、到達保証は webhook 側の課題。

"use strict";

const fs = require("fs");
const path = require("path");

// Notification の出力は運用に影響しないため、ログは stderr に寄せる（デバッグ用）。
const log = (...args) => console.error("[Notification]", ...args);

// stdin から JSON を読む（hook 入力）。空 / 非 JSON / TTY でも落ちないよう fail-soft。
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

  // 値の正規化: 文字列かつ非空のものだけを採用する。オブジェクト・配列・数値が来ても
  // 通知に [object Object] や巨大 payload を混ぜないためのガード（stop-failure-gate.js と共通）。
  const asStr = (v) => (typeof v === "string" && v.trim() ? v.trim() : null);

  // 通知種別の抽出。公式仕様では種別文字列が `notification_type` フィールドに入る
  // （idle_prompt / permission_prompt など）。バージョン差・将来変更に備え、文字列形を
  // 最優先しつつ別名候補も順に探す。種別が取れなくても通知は必ず行う（既定 "unknown"）。
  // 長さ上限: webhook 側の facts 展開で過大表示を防ぐ。公式値は短い固定文字列だが将来変更に備える。
  const MAX_TYPE = 100;
  const notificationType = (
    asStr(input.notification_type) ||                         // 公式: 種別文字列
    asStr(input.notificationType) ||                          // camelCase フォールバック
    asStr(input.type) ||
    "unknown"
  ).slice(0, MAX_TYPE);

  // 通知本文（任意。あれば添える）。過大な本文は webhook 側の 200 字フィルタ任せにせず、
  // ここで上限を掛けて generic HTTPS への過大 payload を防ぐ（stop-failure-gate.js と共通）。
  const MAX_DETAIL = 500;
  const rawMessage =
    asStr(input.message) ||                                   // 公式: 通知本文
    asStr(input.body) ||
    asStr(input.text) ||
    null;
  const message = rawMessage ? rawMessage.slice(0, MAX_DETAIL) : null;

  // セッション ID / transcript（あれば添える。沈黙したセッションの特定に役立つ）。
  // sessionId: 過大文字列対策で上限あり。transcriptPath: フルパスは内部情報漏洩になるため
  // ファイル名部分のみ（path.basename）を通知に乗せる。
  const MAX_SESSION = 128;
  const rawSessionId   = asStr(input.session_id) || asStr(input.sessionId) || null;
  const sessionId      = rawSessionId ? rawSessionId.slice(0, MAX_SESSION) : null;
  const rawTranscript  = asStr(input.transcript_path) || asStr(input.transcriptPath) || null;
  const transcriptPath = rawTranscript ? path.basename(rawTranscript) : null;

  const { spawn } = require("child_process");
  const notifier = path.join(__dirname, "webhook-notifier.js");

  if (fs.existsSync(notifier)) {
    // webhook-notifier は cwd の state.json を読み、webhook.enabled / events[event] の
    // 二重ゲートで送信可否を決める。cwd がプロジェクトルートからずれて state.json が
    // 不在だと通知は黙って落ちるため、ここで存在を確認し、不在なら警告して誤認を防ぐ。
    if (!fs.existsSync(path.join(process.cwd(), "state.json"))) {
      log(`warning: state.json が cwd(${process.cwd()})に無い — 通知が無効化されている可能性`);
    }
    const payload = JSON.stringify({
      notification_type: notificationType,
      message,
      session:    sessionId,
      transcript: transcriptPath,
      hook:       "Notification",
    });
    const child = spawn(process.execPath, [notifier, "input_waiting", payload], {
      detached: true,
      stdio: "ignore",
      cwd: process.cwd(),
    });
    // detached 子の起動失敗（同期 throw 以外）を拾う。沈黙停止対策フック自身が無音で
    // 死なないようにするための最小ハンドラ（stop-failure-gate.js と共通）。
    // detached 子の起動失敗（同期 throw 以外）を拾う。沈黙停止対策フック自身が無音で
    // 死なないようにするための最小ハンドラ（stop-failure-gate.js と共通）。
    child.on("error", (e) => console.error(`[Notification] spawn failed: ${e.message}`));
    // child.unref() 後は process.exit(0) を経由して親は終了するため、
    // この on('error') ハンドラが実際に呼ばれるのは unref() 前に spawn が同期失敗した場合のみ。
    child.unref(); // 親の終了をブロックしない
    // ここで保証できるのは「通知プロセスを起動した」ところまで。送信成功は detached +
    // stdio:ignore のため親から不可視なので、誤認を避けて "spawned" と記す。
    log(`input_waiting notifier spawned (notification_type=${notificationType})`);
  } else {
    log("webhook-notifier.js not found — skip");
  }
} catch (err) {
  // fail-soft: 通知に失敗しても hook はブロックしない
  console.error(`[Notification] failed: ${err.message}`);
}

process.exit(0);
