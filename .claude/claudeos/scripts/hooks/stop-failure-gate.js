#!/usr/bin/env node
// StopFailure hook (ClaudeOS v9.0)
// ターンが API エラー (billing_error / rate_limit / overloaded / authentication_failed /
// server_error など) で終了した時に発火する。正常終了時の Stop (session-end.js) とは
// 排他で、無人 cron 運用が API エラーで沈黙停止する死角を埋めるための通知専用フック。
//
// hooks-guide: StopFailure の stdout / exit code は無視される。よって通知を投げっぱなしにし、
// 何があっても運用をブロックしない fail-soft 設計に徹する。
//
// 動作: stdin の StopFailure ペイロードからエラー種別を抽出し、webhook-notifier.js を
//       api_failure イベントで detached spawn する（親プロセスをブロックしない）。
//
// 参照: 公式 hooks ガイド StopFailure。matcher はエラー種別文字列にマッチし、ペイロードの
//       `error` フィールドに種別が入る。公式の種別一覧:
//       rate_limit / overloaded / authentication_failed / oauth_org_not_allowed /
//       billing_error / invalid_request / model_not_found / server_error /
//       max_output_tokens / unknown。本フックは settings.json 側で matcher="*" を用い、
//       全種別（将来追加分・unknown 含む）を捕捉して沈黙停止の死角をなくす。
//
// 既知の制約（フォローアップ Issue で追跡。本フックのスコープ外）:
//   - StopFailure が発火しない異常終了（SIGKILL / OOM kill / ホスト再起動 / dispatcher
//     到達前クラッシュ）は本フックでは検知不能。cron / Supervisor 側の heartbeat
//     watchdog で別途補完する。
//   - 通知の最終到達（Webhook の HTTP 成功）は detached + stdio:ignore のため親から不可視。
//     本フックは「通知プロセスの起動（spawn）」までを保証し、到達保証は webhook 側の課題。

"use strict";

const fs = require("fs");
const path = require("path");

// StopFailure の出力は無視されるため、ログは stderr に寄せる（デバッグ用）。
const log = (...args) => console.error("[StopFailure]", ...args);

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
  // 通知に [object Object] や巨大 payload を混ぜないためのガード（レビュー指摘 M1/L3）。
  const asStr = (v) => (typeof v === "string" && v.trim() ? v.trim() : null);

  // エラー種別の抽出。公式仕様では種別文字列が `error` フィールドに入る（rate_limit など）。
  // バージョン差・将来変更に備え、文字列形を最優先しつつ旧候補とオブジェクト形も順に探す。
  // 種別が取れなくても通知は必ず行い、沈黙停止を防ぐ（見つからなければ "unknown"）。
  const reason =
    asStr(input.error) ||                                     // 公式: error 種別文字列
    asStr(input.reason) ||                                    // 後方互換フォールバック
    asStr(input.error_type) ||
    asStr(input.stop_failure_reason) ||
    (input.error && typeof input.error === "object" &&
      (asStr(input.error.type) || asStr(input.error.message))) ||
    "unknown";

  // エラー詳細メッセージ（任意。あれば通知に添える）。過大な本文は webhook 側の
  // 200字フィルタ任せにせず、ここで上限を掛けて generic HTTPS への過大 payload を防ぐ。
  const MAX_DETAIL = 500;
  const rawDetail =
    asStr(input.error_details) ||                             // 公式: エラー詳細
    asStr(input.last_assistant_message) ||                    // 公式: エラーメッセージ本文
    (input.error && typeof input.error === "object" && asStr(input.error.message)) ||
    asStr(input.message) ||
    asStr(input.detail) ||
    null;
  const detail = rawDetail ? rawDetail.slice(0, MAX_DETAIL) : null;

  // セッション ID（あれば添える。沈黙したセッションの transcript 特定に役立つ）。
  const sessionId = asStr(input.session_id) || asStr(input.sessionId) || null;

  const { spawn } = require("child_process");
  const notifier = path.join(__dirname, "webhook-notifier.js");

  if (fs.existsSync(notifier)) {
    // webhook-notifier は cwd の state.json を読み、webhook.enabled / events[event] の
    // 二重ゲートで送信可否を決める。cwd がプロジェクトルートからずれて state.json が
    // 不在だと通知は黙って落ちるため、ここで存在を確認し、不在なら警告して誤認を防ぐ。
    if (!fs.existsSync(path.join(process.cwd(), "state.json"))) {
      log(`warning: state.json が cwd(${process.cwd()})に無い — 通知が無効化されている可能性`);
    }
    const payload = JSON.stringify({ reason, detail, session: sessionId, hook: "StopFailure" });
    const child = spawn(process.execPath, [notifier, "api_failure", payload], {
      detached: true,
      stdio: "ignore",
      cwd: process.cwd(),
    });
    // detached 子の起動失敗（同期 throw 以外）を拾う。沈黙停止対策フック自身が無音で
    // 死なないようにするための最小ハンドラ（レビュー指摘 M2 / Codex H4 部分対応）。
    child.on("error", (e) => console.error(`[StopFailure] spawn failed: ${e.message}`));
    child.unref(); // 親の終了をブロックしない
    // ここで保証できるのは「通知プロセスを起動した」ところまで。送信成功は detached +
    // stdio:ignore のため親から不可視なので、誤認を避けて "spawned" と記す（Codex H2）。
    log(`api_failure notifier spawned (reason=${reason})`);
  } else {
    log("webhook-notifier.js not found — skip");
  }
} catch (err) {
  // fail-soft: 通知に失敗しても hook はブロックしない
  console.error(`[StopFailure] failed: ${err.message}`);
}

process.exit(0);
