#!/usr/bin/env bash
# ============================================================
# repo-integration-status.sh — 横断連携の健全性を 1 コマンドで表示
#
# 「他リポジトリとの連携がいまどうなっているか」を GitHub 側の実データから測る。
# 2026-11-23 の連携監査 (task-2) の観点を、再現可能な形に固定したもの。
#
# 判定に使うのは GitHub の実データのみ:
#   - ruleset の有無と必須チェック名（設定ファイルの記載は根拠にしない）
#   - open PR 数（Link ヘッダの last ページ = 実件数）
#   - CLEAN+green の PR（mergeStateStatus=CLEAN かつ失敗チェック 0）
#   - 本リポジトリの台帳（check-project-registry.js --github --json）
#
# 使い方:
#   repo-integration-status.sh [--json] [--limit N] [--owner OWNER]
#
#   --json       最終行に 1 行で機械可読サマリを出す（先頭に人間向け表も出る）
#   --limit N    gh repo list の上限（既定 100）
#   --owner O    対象 owner（既定 Kensan196948G）
#   -h, --help   このヘルプ
#
# --json の最終行:
#   {"ok":true,"owner":"...","repos":76,"ruleset_missing":21,"open_prs":209,
#    "clean_green":4,"registry":{...},"unknown":0}
#   unknown = ruleset か open PR を判定できなかった repo 数（「なし」と混同しない）
#
# 読み取り専用（ruleset / PR / repo を変更しない）。
# 所要時間の目安: repo あたり約 3 API 呼び出し。76 repos で実測 約 3.5 分。
#   範囲は --limit で絞れる（例: --limit 20）。
# gh は CCSU_GH_BIN、node は CCSU_NODE_BIN、台帳スクリプトは CCSU_REGISTRY_SCRIPT で差替可。
# exit: 0 正常 / 1 実行エラー（gh 不在・repo 一覧取得失敗など）/ 2 引数エラー
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

GH_BIN="${CCSU_GH_BIN:-gh}"
NODE_BIN="${CCSU_NODE_BIN:-node}"
REGISTRY_SCRIPT="${CCSU_REGISTRY_SCRIPT:-$CCSU_ROOT/scripts/tools/check-project-registry.js}"

OWNER="Kensan196948G"
LIMIT=100
JSON=0

usage() { sed -n '2,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

# ── 引数解析 ────────────────────────────────────────────────
bad_args() { log_error "$*"; usage >&2; exit 2; }

while (( $# )); do
  case "$1" in
    --json)  JSON=1; shift ;;
    --limit) [[ $# -ge 2 ]] || bad_args "--limit には値が必要です"; LIMIT="$2"; shift 2 ;;
    --owner) [[ $# -ge 2 ]] || bad_args "--owner には値が必要です"; OWNER="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) bad_args "不明な引数: $1" ;;
  esac
done

[[ "$LIMIT" =~ ^[0-9]+$ ]] && (( LIMIT >= 1 )) || bad_args "--limit は 1 以上の整数: $LIMIT"
[[ "$OWNER" =~ ^[A-Za-z0-9._-]+$ ]] || bad_args "--owner が不正です: $OWNER"

has_cmd "$GH_BIN" || { log_error "gh CLI が見つかりません ($GH_BIN)"; exit 1; }
require_cmd jq

# ── 一時領域 ────────────────────────────────────────────────
TMPD="$(mktemp -d "${TMPDIR:-/tmp}/repo-integration-status.XXXXXX")"
# shellcheck disable=SC2064
trap 'rm -rf "$TMPD"' EXIT

ROWS="$TMPD/repos.tsv"
CLEAN="$TMPD/clean.tsv"
: > "$ROWS"
: > "$CLEAN"

# ── gh 呼び出し（失敗を握り潰さず、呼び出し側で unknown に落とす） ──
gh_api() { "$GH_BIN" api "$@" 2>/dev/null; }

# _count_open_prs <repo> — open PR の実件数を返す。
#   per_page=1 で取り、Link ヘッダの rel="last" の page 番号を件数として使う
#   （per_page=1 なので last ページ番号 = 総件数）。Link が無ければ本文の要素数。
_count_open_prs() {
  local repo="$1" raw last body
  if ! raw="$("$GH_BIN" api --include "repos/$OWNER/$repo/pulls?state=open&per_page=1" 2>/dev/null)"; then
    return 1
  fi
  last="$(printf '%s\n' "$raw" | tr -d '\r' | grep -i '^link:' \
    | sed -n 's/.*[?&]page=\([0-9][0-9]*\)>;[[:space:]]*rel="last".*/\1/p' | head -1)" || true
  if [[ -n "$last" ]]; then
    printf '%s' "$last"
    return 0
  fi
  body="$(printf '%s\n' "$raw" | tr -d '\r' | awk 'seen { print } /^$/ { seen = 1 }')"
  printf '%s' "$body" | jq -r 'if type == "array" then length else 0 end' 2>/dev/null || printf '0'
}

# _clean_green_prs <repo> — CLEAN+green の PR を "repo<TAB>#num<TAB>title" で追記
_clean_green_prs() {
  local repo="$1" prs
  prs="$("$GH_BIN" pr list -R "$OWNER/$repo" --state open --limit 100 \
    --json number,title,mergeStateStatus,isDraft,statusCheckRollup 2>/dev/null)" || prs='[]'
  printf '%s' "$prs" | jq -r --arg repo "$repo" '
    [ .[]
      | select(.mergeStateStatus == "CLEAN" and .isDraft == false)
      | select(([ .statusCheckRollup[]?
                  | select(((.conclusion // .state // "")
                      | test("FAILURE|ERROR|TIMED_OUT|CANCELLED|STARTUP_FAILURE|ACTION_REQUIRED")))
                ] | length) == 0)
      | "\($repo)\t#\(.number)\t\(.title)"
    ] | .[]' >> "$CLEAN" 2>/dev/null || true
}

# ── 本題: repo ごとに ruleset / open PR を実測 ─────────────
log_info "owner=$OWNER limit=$LIMIT を走査します"

if ! repo_names="$("$GH_BIN" repo list "$OWNER" --limit "$LIMIT" --json name 2>/dev/null | jq -r '.[].name')"; then
  log_error "repo 一覧の取得に失敗しました (owner=$OWNER)"
  exit 1
fi
if [[ -z "$repo_names" ]]; then
  log_error "repo が 1 件も返りませんでした (owner=$OWNER / limit=$LIMIT)"
  exit 1
fi

while IFS= read -r repo; do
  [[ -z "$repo" ]] && continue

  class="unknown"
  rs_unknown=0
  pr_unknown=0
  open_pr=0
  rs_names=""
  req_checks=""

  if rs_raw="$(gh_api "repos/$OWNER/$repo/rulesets")"; then
    branch_n="$(printf '%s' "$rs_raw" | jq -r 'if type == "array" then ([.[] | select(.target == "branch")] | length) else 0 end' 2>/dev/null || printf '0')"
    if [[ "${branch_n:-0}" -eq 0 ]]; then
      class="none"
    else
      rs_names="$(printf '%s' "$rs_raw" | jq -r '[.[] | select(.target == "branch") | .name] | join(",")' 2>/dev/null || true)"
      if printf '%s' "$rs_names" | grep -q 'central-auto-merge'; then
        class="central"
      else
        class="other"
      fi
      # 必須チェック名: 最初の branch ruleset の詳細から取得（失敗しても presence は確定済み）
      rid="$(printf '%s' "$rs_raw" | jq -r '[.[] | select(.target == "branch")][0].id' 2>/dev/null || true)"
      if [[ -n "$rid" && "$rid" != "null" ]]; then
        detail="$(gh_api "repos/$OWNER/$repo/rulesets/$rid")" || detail=""
        req_checks="$(printf '%s' "$detail" | jq -r '[.rules[]? | select(.type == "required_status_checks") | .parameters.required_status_checks[]?.context] | join(",")' 2>/dev/null || true)"
      fi
    fi
  else
    rs_unknown=1
    rs_names="unknown"
  fi

  if n="$(_count_open_prs "$repo")"; then
    open_pr="${n:-0}"
    if [[ "$open_pr" -gt 0 ]]; then
      _clean_green_prs "$repo"
    fi
  else
    pr_unknown=1
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$repo" "$class" "$rs_unknown" "$pr_unknown" "$open_pr" "$rs_names" "$req_checks" >> "$ROWS"
done <<< "$repo_names"

# ── 集計 ───────────────────────────────────────────────────
read -r repos central other missing open_prs clean_green unknown < <(
  awk -F'\t' '
    { total++
      if ($2 == "central")      c++
      else if ($2 == "other")   o++
      else if ($2 == "none")    m++
      if ($3 == "1" || $4 == "1") unk[$1] = 1
      if ($5 ~ /^[0-9]+$/)      pr += $5 }
    END { for (k in unk) u++
          printf "%d %d %d %d %d %d %d\n", total, c + 0, o + 0, m + 0, pr + 0, 0, u + 0 }' "$ROWS"
)
# clean_green は実ファイル行数（awk では数えない）
clean_green="$(wc -l < "$CLEAN" | tr -d ' ')"
repos_with_pr="$(awk -F'\t' '$5 > 0' "$ROWS" | wc -l | tr -d ' ')"

# ── 台帳サマリ ─────────────────────────────────────────────
registry_json='{"ok":false,"error":"unavailable"}'
reg_state="unavailable"
if has_cmd "$NODE_BIN" && [[ -f "$REGISTRY_SCRIPT" ]]; then
  if reg_raw="$("$NODE_BIN" "$REGISTRY_SCRIPT" --github --json 2>/dev/null)"; then
    if summary="$(printf '%s' "$reg_raw" | jq -c '
      { ok: (.ok // false),
        linux: { registered: (.linux.registered // 0), missing: ((.linux.missing // []) | length) },
        github: { total: (.github.total // 0), missing: ((.github.missing // []) | length) } }' 2>/dev/null)"; then
      registry_json="$summary"
      reg_state="ok"
    else
      registry_json='{"ok":false,"error":"parse_failed"}'
      reg_state="parse_failed"
    fi
  else
    registry_json='{"ok":false,"error":"check_failed"}'
    reg_state="check_failed"
  fi
fi

reg_line="$(printf '%s' "$registry_json" | jq -r '
  if .ok then "linux \(.linux.registered - .linux.missing)/\(.linux.registered) 一致 / github \(.github.total - .github.missing)/\(.github.total) 一致"
  else "取得できず (\(.error // "unknown"))" end' 2>/dev/null || printf '%s' "$reg_state")"

# ── 人間向けサマリ ─────────────────────────────────────────
printf '\n'
printf '  %s🔗 Repo Integration Status%s — %s\n' "$C_CYAN" "$C_RESET" "$OWNER"
printf '  ────────────────────────────────────────────────────────────\n'
printf '  走査          %s repos (limit %s)\n' "$repos" "$LIMIT"
printf '  ruleset       central-auto-merge %s / 別名 %s / なし %s / unknown %s\n' \
  "$central" "$other" "$missing" "$unknown"
printf '  open PR       %s 件 (%s repos)\n' "$open_prs" "$repos_with_pr"
printf '  CLEAN+green   %s 件（required checks 通過・未マージ）\n' "$clean_green"
if [[ "$clean_green" -gt 0 ]]; then
  while IFS=$'\t' read -r c_repo c_num c_title; do
    [[ -z "$c_repo" ]] && continue
    # cut -c はバイト単位でマルチバイト文字を壊すため、タイトルは切り詰めない
    printf '                  %-38s %-6s %s\n' "$c_repo" "$c_num" "$c_title"
  done < "$CLEAN"
fi
printf '  台帳          %s\n' "$reg_line"
printf '  ────────────────────────────────────────────────────────────\n'

if [[ "$missing" -gt 0 ]]; then
  printf '  %s⚠ ruleset なし (%s)%s: %s\n' "$C_YELLOW" "$missing" "$C_RESET" \
    "$(awk -F'\t' '$2 == "none" { printf "%s ", $1 }' "$ROWS" | sed 's/ $//')"
fi
if [[ "$other" -gt 0 ]]; then
  printf '  %s⚠ 別名 ruleset (%s)%s: %s\n' "$C_YELLOW" "$other" "$C_RESET" \
    "$(awk -F'\t' '$2 == "other" { printf "%s(%s) ", $1, $6 }' "$ROWS" | sed 's/ $//')"
fi
if [[ "$unknown" -gt 0 ]]; then
  printf '  %s⚠ unknown (%s)%s: %s\n' "$C_YELLOW" "$unknown" "$C_RESET" \
    "$(awk -F'\t' '($3 == "1" || $4 == "1") { printf "%s ", $1 }' "$ROWS" | sed 's/ $//')"
fi
printf '\n'

# ── 機械可読サマリ（最終行 1 行） ──────────────────────────
if (( JSON )); then
  jq -cn \
    --arg owner "$OWNER" \
    --argjson repos "$repos" \
    --argjson missing "$missing" \
    --argjson open_prs "$open_prs" \
    --argjson clean_green "$clean_green" \
    --argjson registry "$registry_json" \
    --argjson unknown "$unknown" \
    '{ok:true, owner:$owner, repos:$repos, ruleset_missing:$missing,
      open_prs:$open_prs, clean_green:$clean_green, registry:$registry, unknown:$unknown}'
fi
