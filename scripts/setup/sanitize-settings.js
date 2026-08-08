#!/usr/bin/env node
// sanitize-settings.js — settings.json の autocompact thrashing 残骸を除去する
//
// 背景 (#78 → #81 → 本スクリプト):
// - #78 で正本5層から CLAUDE_AUTOCOMPACT_PCT_OVERRIDE を撤去し、コンテキスト注入
//   hook の matcher を startup|resume|clear へ限定した。
// - #81 で init-claudeos-project.js の merge 時 sanitize を追加したが、init/merge は
//   プロジェクト導入時にしか走らないため、既存配布先に残る旧設定は起動しても
//   回収されず thrashing が再発した (2026-08-08 Open-BIM-Information-Platform で実測。
//   worktree コピーも含め残骸が温存されていた)。
// - 本スクリプトは sanitize を単独実行可能に切り出し、template-sync.sh から
//   毎起動時 (L/S/cron/T 全経路 + チーム worktree) に呼ぶ恒久対策の本体。
//
// 除去対象:
//   - 廃止 env CLAUDE_AUTOCOMPACT_PCT_OVERRIDE (50% 強制 compact の旧オーバーライド)
//   - SessionStart matcher "*" のコンテキスト注入 hook (session-start.js 等) を
//     startup|resume|clear へ正規化 (compact 発火での再注入 = thrashing 増幅を防ぐ)。
//     heartbeat-writer.js 等の副作用専用 hook の matcher "*" は保持する。
//
// 使い方: node scripts/setup/sanitize-settings.js <settings.json> [...]
//   - 変更があったファイルのみ書き換え、原本を <file>.bak-autocompact-fix へ退避
//     (初回のみ。既存バックアップは監査用に上書きしない)
//   - 変更なし・ファイル不存在は無出力 (起動ログを汚さない)
//   - parse 失敗は stderr へ警告して続行。起動経路から呼ばれるため exit code は常に 0
"use strict";

const fs = require("fs");

// 旧配布の残骸として回収する env キー (テンプレート側は #78 で撤去済み)
const DEPRECATED_ENV_KEYS = ["CLAUDE_AUTOCOMPACT_PCT_OVERRIDE"];
const SESSION_START_SAFE_MATCHER = "startup|resume|clear";
const CONTEXT_INJECTING_HOOK_SCRIPTS = ["session-start.js", "verify-goal-set.js"];

// hook エントリ内の実行対象を command / args 両形式から復元する
// (旧配布には command:"node" + args:["...session-start.js"] 形式が混在する)。
// null エントリや想定外の形は空扱いにして throw しない
const entryCommands = (e) => (e && Array.isArray(e.hooks) ? e.hooks : []).map(
  (h) => [(h && h.command) || "", ...(h && Array.isArray(h.args) ? h.args : [])].join(" ").trim()
);

// 実行対象 script の basename 一覧 (引用符・パスを除去)。
// 部分一致だと session-start.js.disabled 等の近似名まで誤検出するため完全一致で判定する
const entryScriptBasenames = (e) => entryCommands(e)
  .flatMap((c) => c.split(/\s+/))
  .map((t) => t.replace(/^["']+|["']+$/g, ""))
  .filter(Boolean)
  .map((t) => t.split("/").pop());

// settings オブジェクトを in-place で sanitize し、変更件数を返す
function sanitizeSettingsObject(cur) {
  // 想定外の形 (null / 配列 / 非オブジェクト) は無害に無変更で返す (起動を妨げない)
  if (!cur || typeof cur !== "object" || Array.isArray(cur)) return 0;
  let changed = 0;
  if (cur.env && typeof cur.env === "object") {
    for (const k of DEPRECATED_ENV_KEYS) {
      if (k in cur.env) { delete cur.env[k]; changed++; }
    }
  }
  const ssEntries = (cur.hooks && Array.isArray(cur.hooks.SessionStart)) ? cur.hooks.SessionStart : [];
  for (const e of ssEntries) {
    if (!e || typeof e !== "object") continue;
    const names = entryScriptBasenames(e);
    if ((e.matcher || "*") === "*" && CONTEXT_INJECTING_HOOK_SCRIPTS.some((s) => names.includes(s))) {
      e.matcher = SESSION_START_SAFE_MATCHER;
      changed++;
    }
  }
  return changed;
}

// 1 ファイルを sanitize する。結果: {status: "missing"|"parse-error"|"clean"|"fixed", changed, error?}
function sanitizeSettingsFile(file) {
  if (!fs.existsSync(file)) return { status: "missing", changed: 0 };
  let cur;
  try { cur = JSON.parse(fs.readFileSync(file, "utf8")); }
  catch (e) { return { status: "parse-error", changed: 0, error: e.message }; }

  const changed = sanitizeSettingsObject(cur);
  if (changed === 0) return { status: "clean", changed: 0 };

  const bak = file + ".bak-autocompact-fix";
  if (!fs.existsSync(bak)) fs.copyFileSync(file, bak);
  const tmp = file + ".tmp." + process.pid;
  // tmp+rename は新規ファイル作成のため、元の権限ビット (0600 等) を明示的に引き継ぐ
  const mode = fs.statSync(file).mode & 0o777;
  fs.writeFileSync(tmp, JSON.stringify(cur, null, 2) + "\n", { encoding: "utf8", mode });
  fs.renameSync(tmp, file);
  return { status: "fixed", changed };
}

if (require.main === module) {
  for (const file of process.argv.slice(2)) {
    let r;
    try {
      r = sanitizeSettingsFile(file);
    } catch (e) {
      // fs エラー (EACCES 等) でも exit 0 契約を守る
      console.error(`WARN: settings sanitize 失敗、skip: ${file}: ${e.message}`);
      continue;
    }
    if (r.status === "fixed") {
      console.log(`🩹 settings sanitize: autocompact 残骸 ${r.changed} 件を修復 (${file})`);
    } else if (r.status === "parse-error") {
      console.error(`WARN: settings.json parse 失敗、sanitize skip: ${file}: ${r.error}`);
    }
  }
  // 起動経路 (template-sync.sh) から呼ばれるため、いかなる場合も起動を妨げない
  process.exit(0);
}

module.exports = {
  DEPRECATED_ENV_KEYS,
  SESSION_START_SAFE_MATCHER,
  CONTEXT_INJECTING_HOOK_SCRIPTS,
  entryCommands,
  sanitizeSettingsObject,
  sanitizeSettingsFile,
};
