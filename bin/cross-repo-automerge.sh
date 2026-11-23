#!/usr/bin/env bash
# ============================================================
# cross-repo-automerge.sh — 横断自動マージ巡回（dependabot / renovate のマイナー・パッチのみ）
#
# 人間承認 3=Y（横断是正 段階④）により、これまで手作業で回していた
# 「更新 PR の巡回マージ」をレビュー可能なツールにしたもの。
#
# 使い方:
#   cross-repo-automerge.sh [--owner OWNER] [--limit N] [--max-merges N]
#                           [--exclude repo1,repo2] [--dry-run|--apply] [--json]
#
#   --dry-run     （既定）判定と表示だけ。書き込み系 gh を一切呼ばない
#   --apply       実際に update-branch / merge する
#   --max-merges  1 回の実行で merge する上限（既定 10）
#   --exclude     追加で除外する repo（カンマ区切り）
#   --json        最終行に 1 行で結果を出す
#
# 対象の決め方（安全側に倒す）:
#   1. active な branch ruleset を持つ repo だけを対象にする（ruleset の無い repo は触らない）
#   2. 作成者が dependabot / renovate の PR だけ
#   3. タイトルから「マイナー/パッチ更新」と判定できるものだけ。
#      メジャー bump と判定不能は対象外（human に記録して人間に渡す）
#   4. draft は対象外
#
# 動作:
#   - mergeStateStatus=BEHIND  → gh pr update-branch（同一 repo 1 回 1 件まで）
#   - CLEAN かつ 失敗 0・保留 0 → gh pr merge --squash（同一 repo 1 回 1 件まで）
#   - 失敗チェックあり / DIRTY(競合) / 保留あり / その他BLOCKED → スキップして理由を記録
#
# 絶対にしないこと:
#   - チェックを緩める・必須チェックを外す
#   - 失敗したチェックの再実行で押し切る
#   - ruleset / branch protection を回避する（--admin 等）
#   - 人間の PR を触る
#
# 二重実行防止: flock（CCSU_AUTOMERGE_LOCK で差替可）
# 記録: $CLAUDEOS_HOME/logs/cross-repo-automerge.jsonl に 1 実行 1 行追記
# gh は CCSU_GH_BIN で差替可（テスト用）
#
# exit: 0 正常（スキップがあっても）/ 1 実行エラー（gh 失敗・ロック競合等）/ 2 引数エラー
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

GH_BIN="${CCSU_GH_BIN:-gh}"

OWNER="Kensan196948G"
LIMIT=100
MAX_MERGES=10
APPLY=0
JSON=0
EXTRA_EXCLUDE=""

# 既定の除外（人間判断 1=N / 対象外と決定済み）
DEFAULT_EXCLUDE="Codex-StartUpTools,open-design"

usage() { sed -n '2,50p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
bad_args() { log_error "$*"; usage >&2; exit 2; }

while (( $# )); do
  case "$1" in
    --owner)      [[ $# -ge 2 ]] || bad_args "--owner には値が必要です"; OWNER="$2"; shift 2 ;;
    --limit)      [[ $# -ge 2 ]] || bad_args "--limit には値が必要です"; LIMIT="$2"; shift 2 ;;
    --max-merges) [[ $# -ge 2 ]] || bad_args "--max-merges には値が必要です"; MAX_MERGES="$2"; shift 2 ;;
    --exclude)    [[ $# -ge 2 ]] || bad_args "--exclude には値が必要です"; EXTRA_EXCLUDE="$2"; shift 2 ;;
    --dry-run)    APPLY=0; shift ;;
    --apply)      APPLY=1; shift ;;
    --json)       JSON=1; shift ;;
    -h|--help)    usage; exit 0 ;;
    *) bad_args "不明な引数: $1" ;;
  esac
done

[[ "$LIMIT" =~ ^[0-9]+$ ]] && (( LIMIT >= 1 )) || bad_args "--limit は 1 以上の整数: $LIMIT"
[[ "$MAX_MERGES" =~ ^[0-9]+$ ]] && (( MAX_MERGES >= 0 )) || bad_args "--max-merges は 0 以上の整数: $MAX_MERGES"
[[ "$OWNER" =~ ^[A-Za-z0-9._-]+$ ]] || bad_args "--owner が不正です: $OWNER"
has_cmd "$GH_BIN" || { log_error "gh CLI が見つかりません ($GH_BIN)"; exit 1; }
require_cmd jq

MODE_NAME="dry-run"; (( APPLY )) && MODE_NAME="apply"
EXCLUDES="$DEFAULT_EXCLUDE"
[[ -n "$EXTRA_EXCLUDE" ]] && EXCLUDES="$EXCLUDES,$EXTRA_EXCLUDE"

CLAUDEOS_HOME="${CLAUDEOS_HOME:-$HOME/.claudeos}"
LOG_DIR="${CCSU_AUTOMERGE_LOG_DIR:-$CLAUDEOS_HOME/logs}"
LOG_FILE="$LOG_DIR/cross-repo-automerge.jsonl"
LOCK_FILE="${CCSU_AUTOMERGE_LOCK:-$CLAUDEOS_HOME/locks/cross-repo-automerge.lock}"

# ── flock: 二重実行防止（取れなければ即終了。待たない） ──
has_cmd flock || { log_error "flock が見つかりません（二重実行を防げないため中止します）"; exit 1; }
mkdir -p "$(dirname "$LOCK_FILE")" || { log_error "ロックディレクトリを作れません: $(dirname "$LOCK_FILE")"; exit 1; }
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  log_error "別の巡回が実行中です（$LOCK_FILE がロックされています）"
  if (( JSON )); then
    jq -cn --arg mode "$MODE_NAME" '{ok:false, mode:$mode, error:"LOCKED",
      repos_scanned:0, merged:[], updated:[], skipped:[], human:[]}'
  fi
  exit 1
fi

TMPD="$(mktemp -d "${TMPDIR:-/tmp}/cross-repo-automerge.XXXXXX")"
# shellcheck disable=SC2064
trap 'rm -rf "$TMPD"' EXIT

# ── jq プログラム（quoted heredoc） ──────────────────────
cat > "$TMPD/p_branch_count.jq" <<'JQ'
if type == "array" then ([.[] | select(.target == "branch" and (.enforcement // "active") == "active")] | length) else 0 end
JQ

# PR を分類する。bot / 種別 / draft / 失敗数 / 保留数 を1つの要素にまとめる。
cat > "$TMPD/p_classify.jq" <<'JQ'
def bump_kind:
  ( .title | capture("from (?<a>[0-9]+)\\.[0-9.]+ to (?<b>[0-9]+)\\.") // null ) as $m
  | if $m == null
    then ( if (.title | ascii_downcase | test("minor-patch|minor/patch|minor and patch|bump the .*-patch"))
           then "minor_patch" else "unknown" end )
    else ( if $m.a == $m.b then "minor_patch" else "major" end )
    end;
[ .[] | {
    number: .number,
    title: .title,
    draft: (.isDraft // false),
    state: (.mergeStateStatus // "UNKNOWN"),
    bot: (((.author.login // "") | ascii_downcase) | test("dependabot|renovate")),
    kind: bump_kind,
    failures: ([ .statusCheckRollup[]?
                | select(((.conclusion // .state // "")
                    | test("FAILURE|ERROR|TIMED_OUT|CANCELLED|STARTUP_FAILURE|ACTION_REQUIRED"))) ] | length),
    pending: ([ .statusCheckRollup[]?
               | select(((.status // "") | test("IN_PROGRESS|QUEUED|PENDING|WAITING"))) ] | length)
  } ]
JQ

cat > "$TMPD/p_result.jq" <<'JQ'
{ ok: true,
  mode: $mode,
  repos_scanned: $scanned,
  merged: $merged,
  updated: $updated,
  skipped: $skipped,
  human: $human }
JQ

# ── 収集 ────────────────────────────────────────────────
: > "$TMPD/merged.jsonl"
: > "$TMPD/updated.jsonl"
: > "$TMPD/skipped.jsonl"
: > "$TMPD/human.jsonl"

log_info "巡回を開始します（mode=$MODE_NAME / owner=$OWNER / max-merges=$MAX_MERGES）"

repo_list="$("$GH_BIN" repo list "$OWNER" --limit "$LIMIT" --json name 2>/dev/null)" || {
  log_error "repo 一覧の取得に失敗しました (owner=$OWNER)"; exit 1; }

# is_excluded <repo> — 除外リスト（カンマ区切り）に含まれるか
#   for で回す。パイプ + set -e だと最初の不一致で subshell が落ちるため使わない。
is_excluded() {
  local repo="$1" e
  for e in ${EXCLUDES//,/ }; do
    if [[ -n "$e" && "$e" == "$repo" ]]; then
      return 0
    fi
  done
  return 1
}

repos_scanned=0
merges_done=0

while IFS= read -r repo; do
  [[ -z "$repo" ]] && continue

  if is_excluded "$repo"; then
    continue
  fi

  # ruleset を持つ repo だけ対象。無い repo は触らない（数にも入れない）。
  rs="$("$GH_BIN" api "repos/$OWNER/$repo/rulesets" 2>/dev/null)" || continue
  branch_n="$(printf '%s' "$rs" | jq -r -f "$TMPD/p_branch_count.jq" 2>/dev/null || printf '0')"
  [[ "${branch_n:-0}" -gt 0 ]] || continue
  repos_scanned=$((repos_scanned + 1))

  prs="$("$GH_BIN" pr list -R "$OWNER/$repo" --state open --limit 100 \
    --json number,title,author,isDraft,mergeStateStatus,statusCheckRollup 2>/dev/null)" || continue
  classified="$(printf '%s' "$prs" | jq -c -f "$TMPD/p_classify.jq" 2>/dev/null || printf '[]')"

  repo_merged=0
  repo_updated=0
  while IFS= read -r row; do
    [[ -z "$row" ]] && continue
    num="$(printf '%s' "$row" | jq -r '.number')"
    draft="$(printf '%s' "$row" | jq -r '.draft')"
    state="$(printf '%s' "$row" | jq -r '.state')"
    bot="$(printf '%s' "$row" | jq -r '.bot')"
    kind="$(printf '%s' "$row" | jq -r '.kind')"
    fails="$(printf '%s' "$row" | jq -r '.failures')"
    pend="$(printf '%s' "$row" | jq -r '.pending')"

    # 人間の PR は触らない（記録もしない）
    [[ "$bot" == "true" ]] || continue

    add_skip() { jq -cn --arg repo "$repo" --argjson pr "$num" --arg reason "$1" '{repo:$repo, pr:$pr, reason:$reason}' >> "$TMPD/skipped.jsonl"; }
    add_human() { jq -cn --arg repo "$repo" --argjson pr "$num" --arg reason "$1" '{repo:$repo, pr:$pr, reason:$reason}' >> "$TMPD/human.jsonl"; }

    if [[ "$draft" == "true" ]]; then add_skip "draft"; continue; fi
    if [[ "$kind" == "major" ]]; then add_human "major_bump"; continue; fi
    if [[ "$kind" == "unknown" ]]; then add_human "unclassified"; continue; fi

    if [[ "$fails" -gt 0 ]]; then add_skip "checks_failed"; continue; fi
    if [[ "$state" == "DIRTY" ]]; then add_skip "conflict"; continue; fi

    if [[ "$state" == "BEHIND" ]]; then
      # 同一 repo につき 1 回 1 件だけ update する（CI の同時再計算を避ける）
      if [[ "$repo_updated" -ge 1 ]]; then add_skip "behind_already_updated"; continue; fi
      repo_updated=$((repo_updated + 1))
      if (( APPLY )); then
        if "$GH_BIN" pr update-branch "$num" -R "$OWNER/$repo" >/dev/null 2>&1; then
          jq -cn --arg repo "$repo" --argjson pr "$num" '{repo:$repo, pr:$pr}' >> "$TMPD/updated.jsonl"
        else
          add_skip "update_branch_failed"
        fi
      else
        jq -cn --arg repo "$repo" --argjson pr "$num" '{repo:$repo, pr:$pr, dry_run:true}' >> "$TMPD/updated.jsonl"
      fi
      continue
    fi

    if [[ "$state" == "CLEAN" && "$fails" -eq 0 && "$pend" -eq 0 ]]; then
      # 同一 repo 1 回 1 件。上限に達したら human へ（取りこぼさず可視化）
      if [[ "$repo_merged" -ge 1 ]]; then add_skip "repo_limit_reached"; continue; fi
      if [[ "$merges_done" -ge "$MAX_MERGES" ]]; then add_skip "max_merges_reached"; continue; fi
      repo_merged=$((repo_merged + 1))
      merges_done=$((merges_done + 1))
      if (( APPLY )); then
        if "$GH_BIN" pr merge "$num" -R "$OWNER/$repo" --squash >/dev/null 2>&1; then
          jq -cn --arg repo "$repo" --argjson pr "$num" '{repo:$repo, pr:$pr}' >> "$TMPD/merged.jsonl"
        else
          add_skip "merge_failed"
        fi
      else
        jq -cn --arg repo "$repo" --argjson pr "$num" '{repo:$repo, pr:$pr, dry_run:true}' >> "$TMPD/merged.jsonl"
      fi
      continue
    fi

    if [[ "$state" == "BLOCKED" && "$pend" -gt 0 ]]; then add_skip "checks_pending"; continue; fi
    if [[ "$state" == "BLOCKED" ]]; then add_skip "blocked"; continue; fi
    if [[ "$pend" -gt 0 ]]; then add_skip "checks_pending"; continue; fi
    add_skip "status:${state}"
  done < <(printf '%s' "$classified" | jq -c '.[]')
done < <(printf '%s' "$repo_list" | jq -r '.[].name')

# ── 結果 ────────────────────────────────────────────────
result="$(jq -cn \
  --arg mode "$MODE_NAME" \
  --argjson scanned "$repos_scanned" \
  --argjson merged "$(jq -s -c '.' "$TMPD/merged.jsonl")" \
  --argjson updated "$(jq -s -c '.' "$TMPD/updated.jsonl")" \
  --argjson skipped "$(jq -s -c '.' "$TMPD/skipped.jsonl")" \
  --argjson human "$(jq -s -c '.' "$TMPD/human.jsonl")" \
  -f "$TMPD/p_result.jq")"

mkdir -p "$LOG_DIR" 2>/dev/null || true
jq -c --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '. + {at:$at}' <<<"$result" >> "$LOG_FILE" 2>/dev/null || \
  log_warn "ログを書けませんでした: $LOG_FILE"

printf '\n'
printf '  %s横断自動マージ巡回%s — %s（mode=%s）\n' "$C_CYAN" "$C_RESET" "$OWNER" "$MODE_NAME"
printf '  ────────────────────────────────────────────────────────────\n'
printf '  対象 repo     %s（active ruleset 保有・除外済）\n' "$repos_scanned"
printf '  merge         %s 件\n' "$(printf '%s' "$result" | jq -r '.merged | length')"
printf '  update        %s 件\n' "$(printf '%s' "$result" | jq -r '.updated | length')"
printf '  スキップ      %s 件\n' "$(printf '%s' "$result" | jq -r '.skipped | length')"
printf '  人間判断      %s 件\n' "$(printf '%s' "$result" | jq -r '.human | length')"
printf '  ────────────────────────────────────────────────────────────\n'
if (( APPLY )); then
  printf '  %s実行しました（--apply）%s\n' "$C_GREEN" "$C_RESET"
else
  printf '  %sdry-run: 書き込み系の gh は呼んでいません%s\n' "$C_YELLOW" "$C_RESET"
fi
printf '%s' "$result" | jq -r '.merged[]? | "    merge  \(.repo) #\(.pr)"'
printf '%s' "$result" | jq -r '.updated[]? | "    update \(.repo) #\(.pr)"'
printf '%s' "$result" | jq -r '.skipped[]? | "    skip   \(.repo) #\(.pr)  \(.reason)"' | head -30
printf '%s' "$result" | jq -r '.human[]? | "    human  \(.repo) #\(.pr)  \(.reason)"' | head -20
printf '\n'

if (( JSON )); then
  printf '%s\n' "$result"
fi
