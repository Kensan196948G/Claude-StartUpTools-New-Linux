#!/usr/bin/env bash
# ============================================================
# queue.sh — 複数プロジェクト優先度キュー (Linux native)
#
# 役割: config_project_list が列挙した登録プロジェクト群を、各 state.json の
#       緊急度 (security_critical / blocked_issues / 残日数 throttle tier /
#       starvation) でスコア化し、起動順を並べ替える「順序のみ」の層。
#       列挙の正本 (.git 検出・localExcludes 除外) は config-loader が担い、
#       本ライブラリはその出力を受けて整列するだけ (責務分離)。
#
# 設計:
#   - 純粋・決定的: priority は pstate と today/now を入力に整数スコアを出力。
#     order は安定ソート (スコア降順 → 名前昇順) で同点順序を一意化。
#   - starvation 防止: 24h 以上未起動のプロジェクトへ加点し、低優先でも順番が回る。
#   - 起動後の動的再順序化はしない (supervisor は独立プロセス)。再評価は次回 --all 時。
#
# 前提: common.sh + json.sh + supervisor.sh が source 済み (sup__* を利用)。
# ============================================================

[[ -n "${_CCSU_QUEUE_LOADED:-}" ]] && return 0
_CCSU_QUEUE_LOADED=1

_ccsu_queue_dir="$(dirname "${BASH_SOURCE[0]}")"
source "$_ccsu_queue_dir/common.sh"
source "$_ccsu_queue_dir/json.sh"
source "$_ccsu_queue_dir/supervisor.sh"

# スコア重み (大きいほど先に起動)
QUEUE_W_SECURITY=1000   # kpi.security_critical>0
QUEUE_W_BLOCKED=500     # blocked_issues 非空
QUEUE_W_OVERDUE=250     # 締切超過
QUEUE_W_T7=200          # 残7
QUEUE_W_T14=100         # 残14
QUEUE_W_T30=50          # 残30
QUEUE_W_STARVED=50      # 24h 以上未起動

# ------------------------------------------------------------
# queue__project_priority <pstate> [today:YYYY-MM-DD] [now_epoch]
#   state.json の緊急度を整数スコア化。ファイル不在/欠落は 0。
#   now_epoch 省略時は starvation 加点を行わない (決定性のため明示渡し推奨)。
# ------------------------------------------------------------
queue__project_priority() {
  local pstate="$1" today="${2:-$(sup__today)}" now="${3:-}"
  local score=0 sec blocked deadline days tier last le
  [[ -f "$pstate" ]] || { printf '0'; return 0; }

  sec="$(json_get "$pstate" '.kpi.security_critical' '0')"
  blocked="$(json_get "$pstate" '.blocked_issues | length' '0')"
  [[ "$sec" =~ ^[0-9]+$ ]] || sec=0
  [[ "$blocked" =~ ^[0-9]+$ ]] || blocked=0
  (( sec > 0 ))     && score=$(( score + QUEUE_W_SECURITY ))
  (( blocked > 0 )) && score=$(( score + QUEUE_W_BLOCKED ))

  deadline="$(json_get "$pstate" '.project.release_deadline' '')"
  days="$(sup__days_remaining "$deadline" "$today")"
  tier="$(sup__throttle_tier "$days")"
  case "$tier" in
    overdue) score=$(( score + QUEUE_W_OVERDUE )) ;;
    t7)      score=$(( score + QUEUE_W_T7 )) ;;
    t14)     score=$(( score + QUEUE_W_T14 )) ;;
    t30)     score=$(( score + QUEUE_W_T30 )) ;;
  esac

  # starvation 防止: 最終セッションから 24h 以上経過なら加点。
  last="$(json_get "$pstate" '.execution.last_session_at' '')"
  if [[ -n "$now" && -n "$last" ]]; then
    le="$(date -d "$last" +%s 2>/dev/null || printf '')"
    [[ -n "$le" ]] && (( now - le >= 86400 )) && score=$(( score + QUEUE_W_STARVED ))
  fi

  printf '%s' "$score"
}

# ------------------------------------------------------------
# queue__order <projects_base> [today] [now_epoch]
#   stdin からプロジェクト名 (1 行 1 件) を読み、<base>/<name>/state.json の
#   スコアでソートした名前一覧を出力 (スコア降順 → 名前昇順で安定)。
#   例: config_project_list | queue__order "$base" "$today" "$(date +%s)"
# ------------------------------------------------------------
queue__order() {
  local base="$1" today="${2:-$(sup__today)}" now="${3:-}"
  local name pstate score
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    pstate="$base/$name/state.json"
    score="$(queue__project_priority "$pstate" "$today" "$now")"
    printf '%s\t%s\n' "$score" "$name"
  done | sort -t"$(printf '\t')" -k1,1nr -k2,2 | cut -f2-
}
