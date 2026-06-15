#!/usr/bin/env bash
# ============================================================
# credits.sh — Agent SDK クレジット台帳・上限ガード (Linux native)
#
# 役割: 2026-06-15 施行の課金変更 (claude -p / Agent SDK は購読プランで対話枠とは
#       別の月次クレジットを消費) に対応し、headless セッションの消費コストを
#       追記専用台帳 (JSONL) に記録・集計し、予算に対する段階ガードを提供する。
#
# 設計:
#   - 台帳が正本: ~/.claudeos/credits/ledger.jsonl が真実源。state.json は鏡。
#     json_append_line (flock 付) で並列セッションの追記競合を防ぐ。
#   - 段階ガード: 予算比 70%=warn / 85%=verify-only / 95%=stop
#     (CLAUDE.md の残量段階思想と同型)。budget=0 は無制限 (無効)。
#   - 概算: 月次境界は実課金サイクルと厳密一致しない予防ガード。result 未到達時は
#     中間 usage の best-effort 積算で補正する想定 (記録側の責務)。
#
# 前提: common.sh + json.sh が source 済み。jq 必須。
# ============================================================

[[ -n "${_CCSU_CREDITS_LOADED:-}" ]] && return 0
_CCSU_CREDITS_LOADED=1

_ccsu_credits_dir="$(dirname "${BASH_SOURCE[0]}")"
source "$_ccsu_credits_dir/common.sh"
source "$_ccsu_credits_dir/json.sh"

# credits__ledger — 台帳パス (CCSU_CREDITS_LEDGER で上書き可、テスト決定化用)
credits__ledger() { printf '%s' "${CCSU_CREDITS_LEDGER:-$CCSU_HOME/credits/ledger.jsonl}"; }

# ------------------------------------------------------------
# credits__record <cost_usd> [tokens_in] [tokens_out] [project] [ts:iso]
#   台帳へ 1 セッション分の消費を追記。cost 非数は 0 に丸める。
#   ts 省略時は現在時刻 (テストは固定 iso を渡して決定化)。
# ------------------------------------------------------------
credits__record() {
  local cost="$1" tin="${2:-0}" tout="${3:-0}" project="${4:-}" ts="${5:-$(date -Iseconds)}"
  local ledger line
  ledger="$(credits__ledger)"
  [[ "$cost" =~ ^[0-9]+(\.[0-9]+)?$ ]] || cost=0
  [[ "$tin"  =~ ^[0-9]+$ ]] || tin=0
  [[ "$tout" =~ ^[0-9]+$ ]] || tout=0
  line="$(jq -nc --arg ts "$ts" --arg p "$project" \
    --argjson cost "$cost" --argjson tin "$tin" --argjson tout "$tout" \
    '{ts:$ts, project:$p, cost_usd:$cost, tokens_in:$tin, tokens_out:$tout}' 2>/dev/null)" \
    || { log_warn "credits__record: jq 行生成失敗 (skip)"; return 1; }
  json_append_line "$ledger" "$line"
}

# ------------------------------------------------------------
# credits__month_total <month:YYYY-MM> [ledger]
#   指定月の cost_usd 合計を出力 (台帳不在/空は 0)。
# ------------------------------------------------------------
credits__month_total() {
  local month="$1" ledger="${2:-$(credits__ledger)}"
  [[ -f "$ledger" ]] || { printf '0'; return 0; }
  jq -rs --arg m "$month" \
    '[ .[] | select(.ts | startswith($m)) | .cost_usd ] | add // 0' \
    "$ledger" 2>/dev/null || printf '0'
}

# ------------------------------------------------------------
# credits__guard <budget_usd> <spent_usd>
#   予算比に応じた停止理由を出力 (空=継続)。budget<=0 は無効 (無制限)。
#     70%=credit-cap:warn / 85%=credit-cap:verify-only / 95%=credit-cap:stop
# ------------------------------------------------------------
credits__guard() {
  local budget="$1" spent="$2"
  awk -v b="$budget" -v s="$spent" 'BEGIN{
    if (b+0 <= 0) exit 0;
    p = (s+0) * 100 / (b+0);
    if      (p >= 95) print "credit-cap:stop";
    else if (p >= 85) print "credit-cap:verify-only";
    else if (p >= 70) print "credit-cap:warn";
  }'
}
