#!/usr/bin/env bash
# ============================================================
# github-pr-flow.sh — GitHub PR フロー安全ラッパー (Linux native)
#
# 役割: PR フローの準備状態を点検し、CLAUDE.md の自動 merge 条件を
#       「実行時ゲート」として評価する。ゲートは判定のみ (merge は実行しない)。
#       純粋関数 (remote 解析 / 保護ブランチ / CI ロールアップ集計 / ゲート評価) を
#       lib に集約し、gh 依存の副作用は bin/github-pr-flow.sh に置く。
#
# 移植元: Codex-StartUpTools-New-Linux/scripts/lib/GitHubPrFlow.psm1
#   の readiness チェック + rollup 集計 + draft PR 明示ゲート概念。
#   Claude 向けに「自動 merge 条件ゲート評価」を追加 (実行はしない)。
# ============================================================

[[ -n "${_CCSU_PRFLOW_LOADED:-}" ]] && return 0
_CCSU_PRFLOW_LOADED=1

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# 保護ブランチ (自動 merge の base に来たら人間最終決断へ回す)
PRFLOW_PROTECTED_BRANCHES=("main" "master" "develop")

# prflow__remote_to_repo <url> — git remote URL → owner/repo (非 GitHub は空)
prflow__remote_to_repo() {
  local url="$1"
  [[ -n "$url" ]] || { printf ''; return 0; }
  # git@github.com:owner/repo.git / https://github.com/owner/repo(.git)
  if [[ "$url" =~ github\.com[:/]([^/]+)/([^/]+?)(\.git)?$ ]]; then
    printf '%s/%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]%.git}"
  else
    printf ''
  fi
}

# prflow__is_protected_branch <branch> — 保護ブランチなら 0
prflow__is_protected_branch() {
  local b="$1" p
  for p in "${PRFLOW_PROTECTED_BRANCHES[@]}"; do
    [[ "$b" == "$p" ]] && return 0
  done
  return 1
}

# prflow__rollup_summary <statusCheckRollup-json> — success/pending/failure/total を1行
#   出力: "success=<n> pending=<n> failure=<n> total=<n>"
#   conclusion (Check Runs) と state (Commit Status) の両系統を正規化する。
prflow__rollup_summary() {
  local json="${1:-[]}"
  printf '%s' "$json" | jq -r '
    (if type=="array" then . else [] end)
    | reduce .[] as $c ({success:0,pending:0,failure:0};
        (($c.conclusion // "") | ascii_upcase) as $concl |
        (($c.state // "") | ascii_upcase) as $state |
        if ($concl|IN("SUCCESS","NEUTRAL","SKIPPED")) or ($state=="SUCCESS")
          then .success += 1
        elif ($concl|IN("FAILURE","CANCELLED","TIMED_OUT","ACTION_REQUIRED")) or ($state|IN("ERROR","FAILURE"))
          then .failure += 1
        else .pending += 1
        end)
    | "success=\(.success) pending=\(.pending) failure=\(.failure) total=\(.success+.pending+.failure)"
  ' 2>/dev/null || printf 'success=0 pending=0 failure=0 total=0'
}

# prflow__gate_eval <pr-json> — 自動 merge ゲートを評価 (判定のみ)
#   入力: gh pr view --json number,isDraft,mergeable,baseRefName,reviewDecision,statusCheckRollup
#   出力: 1行目 "decision=ALLOW|BLOCK"、以降 blocking 理由を1行ずつ
prflow__gate_eval() {
  local json="$1"
  local is_draft mergeable base review rollup fail pend succ
  is_draft="$(printf '%s' "$json"  | jq -r '.isDraft // false' 2>/dev/null || echo true)"
  mergeable="$(printf '%s' "$json" | jq -r '.mergeable // "UNKNOWN"' 2>/dev/null || echo UNKNOWN)"
  base="$(printf '%s' "$json"      | jq -r '.baseRefName // ""' 2>/dev/null || echo '')"
  review="$(printf '%s' "$json"    | jq -r '.reviewDecision // ""' 2>/dev/null || echo '')"
  rollup="$(prflow__rollup_summary "$(printf '%s' "$json" | jq -c '.statusCheckRollup // []' 2>/dev/null || echo '[]')")"
  succ="${rollup#success=}"; succ="${succ%% *}"
  fail="$(printf '%s' "$rollup" | sed 's/.*failure=\([0-9]*\).*/\1/')"
  pend="$(printf '%s' "$rollup" | sed 's/.*pending=\([0-9]*\).*/\1/')"

  local -a reasons=()
  [[ "$is_draft" == "true" ]] && reasons+=("PR は draft 状態")
  [[ "$mergeable" != "MERGEABLE" ]] && reasons+=("mergeable != MERGEABLE (=$mergeable)")
  (( fail > 0 )) && reasons+=("CI failure=$fail")
  (( pend > 0 )) && reasons+=("CI pending=$pend (未完了)")
  (( succ == 0 )) && reasons+=("CI success=0 (成功チェックなし)")
  [[ "$review" == "CHANGES_REQUESTED" ]] && reasons+=("review=CHANGES_REQUESTED")
  if [[ -n "$base" ]] && prflow__is_protected_branch "$base"; then
    reasons+=("base=$base は保護ブランチ (人間最終決断)")
  fi

  if (( ${#reasons[@]} == 0 )); then
    printf 'decision=ALLOW\n'
  else
    printf 'decision=BLOCK\n'
    printf '%s\n' "${reasons[@]}"
  fi
}
