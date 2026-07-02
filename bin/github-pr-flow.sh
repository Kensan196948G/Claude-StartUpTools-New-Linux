#!/usr/bin/env bash
# ============================================================
# github-pr-flow.sh — GitHub PR フロー安全ラッパー CLI (Linux native)
#
# PR フロー準備状態の点検と、CLAUDE.md 自動 merge 条件の実行時ゲート評価。
# ゲートは「判定のみ」。実際の merge/tag/公開は行わない (人間/CTO の決定境界を尊重)。
#
# 使い方 (対象リポジトリのディレクトリ内で実行、既定はカレント):
#   github-pr-flow.sh check [--json]           # gh/auth/remote/branch/PR/CI の準備点検
#   github-pr-flow.sh gate  [--json]           # 現ブランチ PR の自動 merge ゲート評価
#   github-pr-flow.sh create-draft [--base B] [--title T]   # 明示的な draft PR 作成 (gated)
#
# 安全: create-draft のみ書き込み。gate は判定を返すだけで merge しない。
#       ゲート ALLOW でも実 merge は運用者/CTO の明示操作 (gh pr merge --auto --squash)。
# ============================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
# shellcheck source=lib/github-pr-flow.sh
source "$SCRIPT_DIR/../lib/github-pr-flow.sh"

PRFLOW_PR_FIELDS="number,title,url,isDraft,state,mergeable,baseRefName,reviewDecision,statusCheckRollup"

# prf__current_branch — カレントブランチ
prf__current_branch() { git branch --show-current 2>/dev/null || true; }

# prf__pr_json — 現ブランチの PR を JSON で取得 (無ければ空)
prf__pr_json() {
  gh pr view --json "$PRFLOW_PR_FIELDS" 2>/dev/null || true
}

# prf__check [--json] — 準備点検
prf__check() {
  local json=0; [[ "${1:-}" == "--json" ]] && json=1
  local gh_ok=0 auth_ok=0 branch repo branch_ok=0 pr_raw="" pr_ok=0 ci="not checked" ci_ok=1
  has_cmd gh && gh_ok=1
  branch="$(prf__current_branch)"
  repo="$(prflow__remote_to_repo "$(git remote get-url origin 2>/dev/null || true)")"
  if [[ -n "$branch" ]] && ! prflow__is_protected_branch "$branch"; then branch_ok=1; fi
  if (( gh_ok )) && gh auth status >/dev/null 2>&1; then auth_ok=1; fi
  if (( gh_ok && auth_ok && branch_ok )); then
    pr_raw="$(prf__pr_json)"
    [[ -n "$pr_raw" ]] && pr_ok=1
  fi
  if (( pr_ok )); then
    local rollup; rollup="$(prflow__rollup_summary "$(printf '%s' "$pr_raw" | jq -c '.statusCheckRollup // []')")"
    ci="$rollup"
    { [[ "$rollup" == *"failure=0"* && "$rollup" == *"pending=0"* ]]; } || ci_ok=0
  fi

  if (( json )); then
    jq -n --argjson gh "$gh_ok" --argjson auth "$auth_ok" --arg branch "$branch" \
      --argjson branchOk "$branch_ok" --arg repo "$repo" --argjson prOk "$pr_ok" \
      --arg ci "$ci" --argjson ciOk "$ci_ok" \
      '{ghCli:($gh==1), ghAuth:($auth==1), branch:$branch, branchOk:($branchOk==1), repository:$repo, prFound:($prOk==1), ci:$ci, ciOk:($ciOk==1)}'
    return 0
  fi

  printf '\n  %s🔀 GitHub PR Flow Check%s\n' "$C_CYAN" "$C_RESET"
  printf '  📦 Repository : %s\n' "${repo:-（GitHub remote なし）}"
  printf '  🌿 Branch     : %s\n\n' "${branch:-（不明）}"
  _prf_line "$gh_ok"     "gh CLI"        "$( ((gh_ok))   && echo available || echo 'gh not found')"
  _prf_line "$auth_ok"   "gh auth"       "$( ((auth_ok)) && echo authenticated || echo 'not authenticated')"
  _prf_line "$([[ -n "$repo" ]] && echo 1 || echo 0)" "GitHub remote" "${repo:-origin is not GitHub}"
  _prf_line "$branch_ok" "Current branch" "$( ((branch_ok)) && echo "$branch" || echo "$branch (保護ブランチ/不明)")"
  _prf_line "$pr_ok"     "Pull request"  "$( ((pr_ok)) && printf '%s' "$(printf '%s' "$pr_raw" | jq -r '"#\(.number) \(.state) draft=\(.isDraft)"')" || echo 'PR 未検出 (create-draft で作成可)')"
  _prf_line "$ci_ok"     "PR checks"     "$ci"
  printf '\n'
}

_prf_line() {
  local ok="$1" name="$2" detail="$3" color mark
  if [[ "$ok" == "1" ]]; then color="$C_GREEN"; mark="✅"; else color="$C_YELLOW"; mark="⚠️"; fi
  printf '  %s%s %-16s%s %s\n' "$color" "$mark" "$name" "$C_RESET" "$detail"
}

# prf__gate [--json] — 自動 merge ゲート評価
prf__gate() {
  local json=0; [[ "${1:-}" == "--json" ]] && json=1
  has_cmd gh || { log_error "gh CLI が見つかりません"; return 1; }
  gh auth status >/dev/null 2>&1 || { log_error "gh 未認証です (gh auth login)"; return 1; }
  local pr_raw; pr_raw="$(prf__pr_json)"
  [[ -n "$pr_raw" ]] || { log_error "現ブランチに PR が見つかりません"; return 1; }

  local eval_out decision
  eval_out="$(prflow__gate_eval "$pr_raw")"
  decision="${eval_out%%$'\n'*}"; decision="${decision#decision=}"
  local reasons; reasons="${eval_out#*$'\n'}"; [[ "$reasons" == "$eval_out" ]] && reasons=""

  if (( json )); then
    local reasons_json="[]"
    [[ -n "$reasons" ]] && reasons_json="$(printf '%s\n' "$reasons" | jq -R -s 'split("\n")|map(select(length>0))')"
    jq -n --arg decision "$decision" --argjson reasons "$reasons_json" \
      --argjson pr "$pr_raw" \
      '{decision:$decision, reasons:$reasons, pr:{number:$pr.number, base:$pr.baseRefName, mergeable:$pr.mergeable, isDraft:$pr.isDraft}}'
    [[ "$decision" == "ALLOW" ]] && return 0 || return 1
  fi

  printf '\n  %s🛂 Auto-merge Gate%s  (%s)\n' "$C_CYAN" "$C_RESET" "$(printf '%s' "$pr_raw" | jq -r '"#\(.number) → \(.baseRefName)"')"
  if [[ "$decision" == "ALLOW" ]]; then
    printf '  %s✅ ALLOW%s — 自動 merge 条件を満たします\n' "$C_GREEN" "$C_RESET"
    printf '     %s運用者/CTO が明示実行: gh pr merge --auto --squash%s\n\n' "$C_WHITE" "$C_RESET"
    return 0
  else
    printf '  %s⛔ BLOCK%s — 以下により自動 merge 不可:\n' "$C_RED" "$C_RESET"
    printf '%s\n' "$reasons" | while IFS= read -r r; do [[ -n "$r" ]] && printf '     %s• %s%s\n' "$C_YELLOW" "$r" "$C_RESET"; done
    printf '\n'
    return 1
  fi
}

# prf__create_draft [--base B] [--title T] — 明示的な draft PR 作成 (gated)
prf__create_draft() {
  local base="main" title="Prepare release"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --base)  base="$2";  shift 2 ;;
      --title) title="$2"; shift 2 ;;
      *) log_error "create-draft: 不明な引数: $1"; return 1 ;;
    esac
  done
  has_cmd gh || { log_error "gh CLI が見つかりません"; return 1; }
  gh auth status >/dev/null 2>&1 || { log_error "gh 未認証です (gh auth login)"; return 1; }
  local branch; branch="$(prf__current_branch)"
  if prflow__is_protected_branch "$branch"; then
    log_error "保護ブランチ ($branch) からは draft PR を作成しません"; return 1
  fi
  if [[ -n "$(prf__pr_json)" ]]; then
    log_warn "既に PR が存在します。作成をスキップします"; return 0
  fi
  local body_file; body_file="$(mktemp)"
  cat > "$body_file" <<'BODY'
## Summary

- リリース準備の変更をまとめる draft PR です。

## Human Decision Gates

- タグ作成・本番公開は自動化しない (人間最終決断)。
- merge は自動 merge 条件成立時のみ CTO、main 宛は人間が判断。
BODY
  log_info "📝 draft PR 作成: base=$base title=\"$title\""
  gh pr create --draft --base "$base" --title "$title" --body-file "$body_file"
  rm -f "$body_file"
  log_ok "draft PR を作成しました (自動 merge は行いません)"
}

main() {
  require_cmd jq
  require_cmd git
  case "${1:-}" in
    check)        shift; prf__check "${1:-}" ;;
    gate)         shift; prf__gate "${1:-}" ;;
    create-draft) shift; prf__create_draft "$@" ;;
    ""|--help|-h)
      printf 'Usage: github-pr-flow.sh check|gate|create-draft\n'
      printf '  check [--json]                     gh/auth/remote/branch/PR/CI の準備点検\n'
      printf '  gate  [--json]                     現ブランチ PR の自動 merge ゲート評価 (判定のみ)\n'
      printf '  create-draft [--base B] [--title T]  明示的な draft PR 作成 (保護ブランチ拒否)\n'
      printf '\n  ゲートは merge を実行しません。ALLOW 後の実 merge は運用者/CTO の明示操作です。\n'
      ;;
    *) log_error "不明なサブコマンド: $1 (check|gate|create-draft)"; return 1 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
