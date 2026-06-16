#!/usr/bin/env bash
# ============================================================
# goal-extract.sh — goals/<type>.md から /goal 本文を抽出・整形 (Linux native)
#
# 役割: cron-launcher / headless 起動が、ClaudeOS goals テンプレート
#       (Claude/templates/claudeos/goals/<goal_type>.md) から
#       `/goal "..."` ディレクティブ本体を取り出し、プロンプト先頭へ注入する。
#       inline 実装だと cron-launcher の副作用と密結合し bats 困難なため、
#       引数 in → stdout out の純粋関数として切り出す (PR-A と同型)。
#
# 設計:
#   - block: 最初の `/goal "` 行から閉じ `"` 行までを逐語抽出 (複数あれば先頭採用)。
#   - ensure_stop: ループ完了条件 `or stop after N turns` 欠落時に閉じ `"` 直前へ補う。
#   - truncate: ≤max 字へ丸める。先頭 (Goal) と末尾 (Stop Conditions) を優先保持し
#     中間を間引く (頭切れ・尻切れでループ条件を失わないため)。
#   - build: type→ファイル解決 (不在は mvp-release フォールバック) → 抽出 → 整形を統合。
#
# 前提: 追加依存なし (awk / 標準コマンドのみ)。jq 不要。
# ============================================================

[[ -n "${_CCSU_GOAL_EXTRACT_LOADED:-}" ]] && return 0
_CCSU_GOAL_EXTRACT_LOADED=1

# goal_extract__defaults — 既定値 (テストや呼び出し側で上書き可)
: "${GOAL_EXTRACT_MAX_CHARS:=4000}"
: "${GOAL_EXTRACT_MAX_TURNS:=20}"
: "${GOAL_EXTRACT_FALLBACK_TYPE:=mvp-release}"

# ------------------------------------------------------------
# goal_extract__block <file>
#   最初の `/goal "` 〜 閉じ `"` ブロックを逐語出力。見つからなければ非0。
# ------------------------------------------------------------
goal_extract__block() {
  local file="$1"
  [[ -f "$file" ]] || return 1
  awk '
    !started && /\/goal[[:space:]]*"/ { started=1; print; next }
    started && /^[[:space:]]*"[[:space:]]*$/ { print; found=1; exit }
    started { print }
    END { if (!found && started) exit 2 }   # 閉じ " 欠落は不完全扱い
  ' "$file"
}

# ------------------------------------------------------------
# goal_extract__strip_block   (本文を stdin で受ける)
#   最初の `/goal "` 行 〜 対応する閉じ `"` 行のブロックを丸ごと除去して出力。
#   用途: START_PROMPT 等に元から埋め込まれた canonical `/goal` を、別途注入する
#         権威 `/goal` ディレクティブと二重化させないため除去する。
#         claude -p は複数行 `/goal "..."` を貪欲にパースし、2 個目の `/goal` や
#         後続本文まで条件へ取り込んで 4000 字制限を超過 (got N>4000) → 0 ターン
#         即終了の crash-loop を起こす。注入 `/goal` を唯一にすることで防ぐ。
#   設計: 行バッファし「開き `/goal "` と対応する閉じ `"` 行が両方揃った時のみ」除去。
#         閉じ `"` 欠落時は何も消さない (非破壊フォールバック)。block/ensure_stop と
#         同じ「閉じは単独 `"` 行」規約を踏襲。単一行 `/goal "..."` は対象外 (テンプレは複数行)。
# ------------------------------------------------------------
goal_extract__strip_block() {
  awk '
    { lines[NR]=$0 }
    !open_nr && /\/goal[[:space:]]*"/ { open_nr=NR; next }
    open_nr && !close_nr && NR>open_nr && /^[[:space:]]*"[[:space:]]*$/ { close_nr=NR }
    END {
      for (i=1;i<=NR;i++) {
        if (open_nr && close_nr && i>=open_nr && i<=close_nr) continue
        print lines[i]
      }
    }
  '
}

# ------------------------------------------------------------
# goal_extract__ensure_stop <max_turns>   (本文を stdin で受ける)
#   `stop after` を含まなければ、閉じ `"` 行の直前へ
#   `- or stop after <N> turns` を挿入して出力。
# ------------------------------------------------------------
goal_extract__ensure_stop() {
  local turns="${1:-$GOAL_EXTRACT_MAX_TURNS}"
  [[ "$turns" =~ ^[0-9]+$ ]] || turns="$GOAL_EXTRACT_MAX_TURNS"
  awk -v n="$turns" '
    { lines[NR]=$0 }
    /stop after/ { has=1 }
    END {
      if (has) { for (i=1;i<=NR;i++) print lines[i]; exit }
      # 末尾側の閉じ " 行を探し、その直前へ stop 行を挿入
      close_at=0
      for (i=NR;i>=1;i--) if (lines[i] ~ /^[[:space:]]*"[[:space:]]*$/) { close_at=i; break }
      for (i=1;i<=NR;i++) {
        if (i==close_at) print "- or stop after " n " turns"
        print lines[i]
      }
      if (close_at==0) print "- or stop after " n " turns"   # 閉じ " 不在でも条件は残す
    }
  '
}

# ------------------------------------------------------------
# goal_extract__truncate <max_chars>   (本文を stdin で受ける)
#   max 以下ならそのまま。超過時は先頭 60% と末尾 40% を残し中間を間引く
#   (Goal は先頭・Stop Conditions と閉じ " は末尾に在るため両端を優先保持)。
# ------------------------------------------------------------
goal_extract__truncate() {
  local max="${1:-$GOAL_EXTRACT_MAX_CHARS}" text
  [[ "$max" =~ ^[0-9]+$ ]] || max="$GOAL_EXTRACT_MAX_CHARS"
  text="$(cat)"
  if (( ${#text} <= max )); then
    printf '%s' "$text"
    return 0
  fi
  local marker=$'\n... (中間省略) ...\n'
  local budget=$(( max - ${#marker} ))
  (( budget < 0 )) && budget=0
  local head_len=$(( budget * 60 / 100 ))
  local tail_len=$(( budget - head_len ))
  printf '%s%s%s' "${text:0:head_len}" "$marker" "${text: -tail_len}"
}

# ------------------------------------------------------------
# goal_extract__resolve <goal_type> <goals_dir>
#   <dir>/<type>.md を返す。不在なら <dir>/<fallback>.md。両方不在は非0。
# ------------------------------------------------------------
goal_extract__resolve() {
  local goal_type="$1" dir="$2" f
  f="$dir/${goal_type}.md"
  [[ -f "$f" ]] && { printf '%s' "$f"; return 0; }
  f="$dir/${GOAL_EXTRACT_FALLBACK_TYPE}.md"
  [[ -f "$f" ]] && { printf '%s' "$f"; return 0; }
  return 1
}

# ------------------------------------------------------------
# goal_extract__build <goal_type> <goals_dir> [max_turns] [max_chars]
#   解決 → 抽出 → stop 付与 → 丸め を統合し /goal ディレクティブを出力。
#   テンプレ不在/抽出失敗は非0 (呼び出し側で START_PROMPT のみ運用へフォールバック)。
# ------------------------------------------------------------
goal_extract__build() {
  local goal_type="$1" dir="$2" turns="${3:-$GOAL_EXTRACT_MAX_TURNS}" max="${4:-$GOAL_EXTRACT_MAX_CHARS}"
  local file block
  file="$(goal_extract__resolve "$goal_type" "$dir")" || return 1
  block="$(goal_extract__block "$file")" || return 1
  [[ -n "$block" ]] || return 1
  printf '%s' "$block" \
    | goal_extract__ensure_stop "$turns" \
    | goal_extract__truncate "$max"
}
