#!/usr/bin/env bash
# ============================================================
# stream-json-tail.sh — claude -p --output-format stream-json の整形・抽出 (Linux native)
#
# 役割: headless (claude -p) 経路で stdout に流れる stream-json (1 行 1 JSON) を
#       逐次読み取り、(1) session_id を捕捉して resume 用ファイルへ上書き保存、
#       (2) result イベントの total_cost_usd / usage をクレジット台帳用ファイルへ記録、
#       (3) 各イベントを人間可読の 1 行ログへ変換して stdout へ流す。
#       TUI 経路の pipe-pane + sed フィルタ (cron-launcher L402) を代替する。
#
# 設計 (PR-A/B と同型の純粋関数 + source ガード):
#   - sjt__extract_session_id <json> : .session_id を printf (無ければ空)。
#   - sjt__extract_cost <json>       : type==result の .total_cost_usd を printf。
#   - sjt__human_line <json>         : 1 イベント → 可読 1 行 (未知/壊れ行は空)。
#   - sjt__run                       : stdin を逐次処理し session_id/cost をファイルへ。
#
# parse 耐性: jq が失敗する壊れた行 (timeout 124 等で途中終了) はスキップし、
#             セッション全体を失敗扱いにしない (プラン欠落4 d)。jq 不在も同様に降格。
#
# 出力ファイル (env で受領、未設定なら書かない):
#   SJT_SESSION_ID_FILE : 最新 session_id を上書き (resume 用、中間 init でも書く)
#   SJT_COST_FILE       : result の total_cost_usd を上書き (PR-E ledger が参照)
# ============================================================

[[ -n "${_CCSU_SJT_LOADED:-}" ]] && return 0
_CCSU_SJT_LOADED=1

# ------------------------------------------------------------
# sjt__has_jq — jq が利用可能か
# ------------------------------------------------------------
sjt__has_jq() { command -v jq >/dev/null 2>&1; }

# ------------------------------------------------------------
# sjt__extract_session_id <json_line>
#   .session_id を printf。非 JSON / 欠落 / jq 不在は空 (return 0、降格)。
# ------------------------------------------------------------
sjt__extract_session_id() {
  local line="$1"
  sjt__has_jq || return 0
  printf '%s' "$line" | jq -r '.session_id // empty' 2>/dev/null || return 0
}

# ------------------------------------------------------------
# sjt__extract_cost <json_line>
#   type==result の .total_cost_usd を printf。それ以外/壊れ行は空。
# ------------------------------------------------------------
sjt__extract_cost() {
  local line="$1"
  sjt__has_jq || return 0
  printf '%s' "$line" | jq -r 'select(.type=="result") | .total_cost_usd // empty' 2>/dev/null || return 0
}

# ------------------------------------------------------------
# sjt__human_line <json_line>
#   1 イベントを人間可読の 1 行へ。未知 type / 壊れ行は空 (skip)。
#   - system/init   : 🟢 init session=<id> model=<m>
#   - assistant     : 🤖 <text 先頭120字> | 🛠️ tool:<name>
#   - user          : 👤 tool_result (<is_error?>)
#   - result        : 🏁 result <subtype> cost=$<usd> turns=<n>
# ------------------------------------------------------------
sjt__human_line() {
  local line="$1"
  sjt__has_jq || { printf '%s' "$line"; return 0; }
  printf '%s' "$line" | jq -r '
    if .type=="system" and .subtype=="init" then
      "🟢 init session=\(.session_id // "?") model=\(.model // "?")"
    elif .type=="assistant" then
      ( [ .message.content[]?
          | if .type=="text" then "🤖 " + (.text|gsub("\n";" ")|.[0:120])
            elif .type=="tool_use" then "🛠️ tool:" + (.name // "?")
            else empty end ] | join(" | ") )
    elif .type=="user" then
      ( [ .message.content[]?
          | if .type=="tool_result" then "👤 tool_result" + (if .is_error then " (error)" else "" end)
            else empty end ] | join(" | ") )
    elif .type=="result" then
      "🏁 result \(.subtype // "?") cost=$\(.total_cost_usd // 0) turns=\(.num_turns // 0)"
    else empty end
  ' 2>/dev/null || return 0
}

# ------------------------------------------------------------
# sjt__run — stdin の stream-json を逐次処理
#   各行: human_line を stdout へ / session_id・cost をファイルへ上書き。
#   壊れ行は jq が空を返すので自然に skip される。
# ------------------------------------------------------------
sjt__run() {
  local line sid cost human
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue
    sid="$(sjt__extract_session_id "$line")"
    if [[ -n "$sid" && -n "${SJT_SESSION_ID_FILE:-}" ]]; then
      printf '%s' "$sid" > "$SJT_SESSION_ID_FILE"
    fi
    cost="$(sjt__extract_cost "$line")"
    if [[ -n "$cost" && -n "${SJT_COST_FILE:-}" ]]; then
      printf '%s' "$cost" > "$SJT_COST_FILE"
    fi
    human="$(sjt__human_line "$line")"
    [[ -n "$human" ]] && printf '%s\n' "$human"
  done
}

# source 時は関数定義のみ。直接実行時は stdin を処理 (cron-launcher が pipe で使用)。
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  sjt__run
fi
