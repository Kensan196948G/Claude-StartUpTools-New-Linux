#!/usr/bin/env bash
# ============================================================
# cross-repo-remediate.sh — 横断是正の「実行計画」を作る（plan 専用・適用しない）
#
# repo-integration-status.sh --classify の分類結果（#196）を、人間が Y を出した後に
# 段階ごとに機械的に実行できる計画へ落とす。**このツールは何も変更しない。**
#
# 使い方:
#   cross-repo-remediate.sh --plan [--owner OWNER] [--out FILE] [--input FILE] [--json]
#
#   --plan       必須。計画を生成する
#   --owner O    対象 owner（既定 Kensan196948G）
#   --input F    repo-integration-status.sh --classify --json の出力ファイルを使う
#                （省略時は同ツールを実行して最終行を入力にする）
#   --out FILE   計画 JSON を FILE に書き出す（ローカルファイルのみ。PR/repo は触らない）
#   --json       最終行に 1 行で計画サマリを出す
#   -h, --help   このヘルプ
#
# 計画の 4 段階（GITHUB_POLICY §6 と 2026-11-23 の判断材料レポートに準拠）:
#   1. CI なし repo      … 「最小 CI 追加 PR」か「対象外」の選択肢を出す（選ばない）
#   2. CI あり repo      … ruleset central-auto-merge の POST ボディを生成。
#                          required checks は各 repo の直近ブランチの check-run 名から取る。
#                          取れない repo は needs_manual_check_names に隔離（永久 pending を防ぐ）
#   3. CLEAN+green の PR … deps のマイナー/パッチだけを「マージ候補」、
#                          fix・メジャー bump・docs・unknown は「人間判断」
#   4. controller 定常化 … 提案テキストのみ
#
# --apply は実装していない（このツールは計画を作るだけ）。適用は人間の Y の後に
# lead が段階ごとに手で実行する。書き込み系の gh サブコマンドは一切呼ばない。
#
# gh は CCSU_GH_BIN、status ツールは CCSU_STATUS_BIN で差替可（テスト用）。
# exit: 0 正常 / 1 実行エラー / 2 引数エラー（--apply を含む）
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

GH_BIN="${CCSU_GH_BIN:-gh}"
STATUS_BIN="${CCSU_STATUS_BIN:-$CCSU_ROOT/bin/repo-integration-status.sh}"

OWNER="Kensan196948G"
JSON=0
PLAN=0
OUT=""
INPUT=""

usage() { sed -n '2,33p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
bad_args() { log_error "$*"; usage >&2; exit 2; }

while (( $# )); do
  case "$1" in
    --plan)   PLAN=1; shift ;;
    --json)   JSON=1; shift ;;
    --owner)  [[ $# -ge 2 ]] || bad_args "--owner には値が必要です"; OWNER="$2"; shift 2 ;;
    --out)    [[ $# -ge 2 ]] || bad_args "--out には値が必要です"; OUT="$2"; shift 2 ;;
    --input)  [[ $# -ge 2 ]] || bad_args "--input には値が必要です"; INPUT="$2"; shift 2 ;;
    --apply)
      # 計画専用ツール。適用経路は意図的に作らない（人間の Y の後に lead が実行する）。
      log_error "--apply は実装していません。このツールは計画の生成のみを行います"
      log_error "適用は計画を確認した人間の Y の後に、段階ごとに手で実行してください"
      exit 2 ;;
    -h|--help) usage; exit 0 ;;
    *) bad_args "不明な引数: $1" ;;
  esac
done

(( PLAN )) || bad_args "--plan が必要です（このツールは計画の生成のみを行います）"
[[ "$OWNER" =~ ^[A-Za-z0-9._-]+$ ]] || bad_args "--owner が不正です: $OWNER"
has_cmd "$GH_BIN" || { log_error "gh CLI が見つかりません ($GH_BIN)"; exit 1; }
require_cmd jq

TMPD="$(mktemp -d "${TMPDIR:-/tmp}/cross-repo-remediate.XXXXXX")"
# shellcheck disable=SC2064
trap 'rm -rf "$TMPD"' EXIT

SCAN="$TMPD/scan.tsv"
STAGE2="$TMPD/stage2.tsv"
: > "$SCAN"
: > "$STAGE2"

# ── jq プログラムは quoted heredoc で持つ ─────────────────
# $( ) の中に長い jq を直接書くと bash の引用符解析と衝突しやすいので、
# プログラムはファイルに落として jq -f で渡す（'JQ' なので展開されない）。
cat > "$TMPD/p_repo_rows.jq" <<'JQ'
.[] | [.name, (.defaultBranchRef.name // "main")] | @tsv
JQ

cat > "$TMPD/p_branch_count.jq" <<'JQ'
if type == "array" then ([.[] | select(.target == "branch")] | length) else 0 end
JQ

cat > "$TMPD/p_len.jq" <<'JQ'
if type == "array" then length else 0 end
JQ

cat > "$TMPD/p_check_names.jq" <<'JQ'
[ .check_runs[]? | select(.conclusion != "skipped") | .name ] | unique | .[]
JQ

cat > "$TMPD/p_body.jq" <<'JQ'
{
  name: "central-auto-merge",
  target: "branch",
  enforcement: "active",
  conditions: { ref_name: { include: ["refs/heads/\($branch)"], exclude: [] } },
  rules: [
    { type: "pull_request",
      parameters: { required_approving_review_count: 0,
                    dismiss_stale_reviews_on_push: true,
                    require_code_owner_review: false,
                    require_last_push_approval: false,
                    required_review_thread_resolution: false,
                    allowed_merge_methods: ["squash"] } },
    { type: "required_status_checks",
      parameters: { strict_required_status_checks_policy: true,
                    required_status_checks: $checks } },
    { type: "non_fast_forward" },
    { type: "deletion" }
  ],
  bypass_actors: []
}
JQ

cat > "$TMPD/p_counts.jq" <<'JQ'
{ repos: .repos,
  ruleset_missing: .ruleset_missing,
  open_prs: .open_prs,
  clean_green: .clean_green,
  unknown: .unknown,
  pr_types: .pr_types,
  age_buckets: .age_buckets,
  ci_presence: .ci_presence }
JQ

# 段階3: deps のマイナー/パッチだけをマージ候補にする。
# メジャー判定は "from X.a to Y.b" の X != Y（Actions の bump も同じ形なので拾える）。
cat > "$TMPD/p_stage3.jq" <<'JQ'
def is_major:
  ((.title | capture("from (?<a>[0-9]+)\\.[0-9.]+ to (?<b>[0-9]+)\\.") // null) as $m
   | ($m != null and $m.a != $m.b));
[ .prs[]? | . + { major: is_major } ] as $all
| { merge_candidates: [ $all[] | select(.type == "deps" and (.major | not)) ],
    human_judgment:   [ $all[] | select((.type != "deps") or .major) ] }
JQ

cat > "$TMPD/p_lines_to_array.jq" <<'JQ'
split("\n") | map(select(length > 0))
JQ

cat > "$TMPD/p_contexts.jq" <<'JQ'
map({ context: . })
JQ

cat > "$TMPD/p_plan.jq" <<'JQ'
{
  ok: true,
  plan_version: 1,
  apply_supported: false,
  owner: $owner,
  source: { kind: $src, measured: $measured },
  stage1_no_ci: {
    count: $n_no_ci,
    repos: ($no_ci | map({ repo: ., options: ["add_minimal_ci", "exclude_from_policy"], chosen: null })),
    unknown_ci_repos: $ci_unk,
    note: "どちらを選ぶかはこのツールでは決めない。--apply は存在しない"
  },
  stage2_ruleset: {
    ready_count: $n_ready,
    needs_manual_check_names_count: $n_manual,
    ready_repos: $ready,
    needs_manual_check_names: $manual,
    ruleset_name: "central-auto-merge",
    note: "ready_repos の required checks は直近ブランチの check-run 名。適用前に PR での実報告名と突合すること"
  },
  stage3_prs: {
    merge_candidate_count: ($s3.merge_candidates | length),
    human_judgment_count: ($s3.human_judgment | length),
    merge_candidates: $s3.merge_candidates,
    human_judgment: $s3.human_judgment
  },
  stage4_controller: {
    proposal: "auto-merge を arm する実行体が無いため CLEAN+green が滞留する。1) この plan を定期実行して可視化を継続、2) auto-merge 登録を自動化するか人間マージのままにするかを中央ポリシーの手順として決定する。どちらもポリシー変更なので人間の承認が要る"
  }
}
JQ

cat > "$TMPD/p_bodies.jq" <<'JQ'
[ split("\n")[] | select(length > 0) | split("\t")
  | { repo: .[0], branch: .[1], body: (.[2] | fromjson),
      execute: "gh api --method POST repos/\(.[0])/rulesets --input <body.json>" } ] as $bodies
| $plan + { stage2_ruleset: ($plan.stage2_ruleset + { bodies: $bodies }) }
JQ

# ── 1. 入力: 分類結果（repo-integration-status.sh --classify --json） ──
if [[ -n "$INPUT" ]]; then
  [[ -f "$INPUT" ]] || { log_error "入力ファイルがありません: $INPUT"; exit 1; }
  # status ツールの出力は「人間向け表 + 最終行が JSON」。素の JSON ファイルも許す。
  status_json="$(tail -1 "$INPUT")"
  if ! printf '%s' "$status_json" | jq -e '.ok == true' >/dev/null 2>&1; then
    status_json="$(cat "$INPUT")"
  fi
  src_desc="input:$INPUT"
else
  [[ -x "$STATUS_BIN" ]] || { log_error "status ツールが実行できません: $STATUS_BIN"; exit 1; }
  log_info "分類結果を取得します（repo-integration-status.sh --classify）"
  raw="$("$STATUS_BIN" --classify --json --owner "$OWNER" 2>/dev/null)" || {
    log_error "repo-integration-status.sh の実行に失敗しました"; exit 1; }
  status_json="$(printf '%s\n' "$raw" | tail -1)"
  src_desc="status-tool"
fi
printf '%s' "$status_json" | jq -e '.ok == true' >/dev/null 2>&1 || {
  log_error "分類結果の JSON を解釈できません（--classify --json の出力か確認してください）"; exit 1; }

# ── 2. 走査: ruleset なし repo と CI 有無（段階 1/2 の対象を名前で確定する） ──
# 分類結果の ci_presence は with_ci の「件数」しか持たないため、対象 repo 名はここで確定する。
log_info "ruleset と CI 有無を走査します（読み取りのみ）"
repo_list="$("$GH_BIN" repo list "$OWNER" --limit 100 --json name,defaultBranchRef 2>/dev/null)" || {
  log_error "repo 一覧の取得に失敗しました (owner=$OWNER)"; exit 1; }

while IFS=$'\t' read -r repo branch; do
  [[ -z "$repo" ]] && continue
  branch="${branch:-main}"
  class="unknown"
  if rs_raw="$("$GH_BIN" api "repos/$OWNER/$repo/rulesets" 2>/dev/null)"; then
    bn="$(printf '%s' "$rs_raw" | jq -r -f "$TMPD/p_branch_count.jq" 2>/dev/null || printf '0')"
    if [[ "${bn:-0}" -eq 0 ]]; then class="none"; else class="has_ruleset"; fi
  fi
  ci="-"
  if [[ "$class" == "none" ]]; then
    if "$GH_BIN" api "repos/$OWNER/$repo/contents/.github/workflows" >"$TMPD/ci.out" 2>"$TMPD/ci.err"; then
      cnt="$(jq -r -f "$TMPD/p_len.jq" "$TMPD/ci.out" 2>/dev/null || printf '0')"
      if [[ "${cnt:-0}" -gt 0 ]]; then ci="with_ci"; else ci="no_ci"; fi
    elif grep -qiE 'not found|http 404' "$TMPD/ci.err"; then
      ci="no_ci"
    else
      ci="unknown"
    fi
  fi
  printf '%s\t%s\t%s\t%s\n' "$repo" "$branch" "$class" "$ci" >> "$SCAN"
done < <(printf '%s' "$repo_list" | jq -r -f "$TMPD/p_repo_rows.jq")

# ── 3. 段階2: 直近ブランチの check-run 名から ruleset ボディを作る ──
# 取得できない repo は needs_manual_check_names に隔離する（名前を推測しない）。
while IFS=$'\t' read -r repo branch; do
  [[ -z "$repo" ]] && continue
  names=""
  if runs="$("$GH_BIN" api "repos/$OWNER/$repo/commits/$branch/check-runs?per_page=100" 2>/dev/null)"; then
    names="$(printf '%s' "$runs" | jq -r -f "$TMPD/p_check_names.jq" 2>/dev/null || true)"
  fi
  if [[ -z "$names" ]]; then
    printf '%s\t%s\t%s\n' "$repo" "$branch" "MANUAL" >> "$STAGE2"
    continue
  fi
  checks_json="$(printf '%s\n' "$names" | jq -R -s -f "$TMPD/p_lines_to_array.jq" \
    | jq -c -f "$TMPD/p_contexts.jq")"
  body="$(jq -cn --arg branch "$branch" --argjson checks "$checks_json" -f "$TMPD/p_body.jq")"
  printf '%s\t%s\t%s\n' "$repo" "$branch" "$(printf '%s' "$body" | jq -c .)" >> "$STAGE2"
done < <(awk -F'\t' '$3 == "none" && $4 == "with_ci" { print $1 "\t" $2 }' "$SCAN")

# ── 4. 集計 ────────────────────────────────────────────────
read -r n_no_ci n_ci_unknown n_ready n_manual < <(
  awk -F'\t' '
    FILENAME == ARGV[1] {
      if ($3 == "none" && $4 == "no_ci") n++
      else if ($3 == "none" && $4 == "unknown") u++
      next
    }
    { if ($3 == "MANUAL") m++; else r++ }
    END { printf "%d %d %d %d\n", n + 0, u + 0, r + 0, m + 0 }' "$SCAN" "$STAGE2"
)

stage3="$(printf '%s' "$status_json" | jq -c -f "$TMPD/p_stage3.jq")"
measured="$(printf '%s' "$status_json" | jq -c -f "$TMPD/p_counts.jq")"

no_ci_repos="$(awk -F'\t' '$3 == "none" && $4 == "no_ci" { print $1 }' "$SCAN" \
  | jq -R -s -f "$TMPD/p_lines_to_array.jq")"
ci_unknown_repos="$(awk -F'\t' '$3 == "none" && $4 == "unknown" { print $1 }' "$SCAN" \
  | jq -R -s -f "$TMPD/p_lines_to_array.jq")"
stage2_ready_repos="$(awk -F'\t' '$3 != "MANUAL" { print $1 }' "$STAGE2" \
  | jq -R -s -f "$TMPD/p_lines_to_array.jq")"
stage2_manual_repos="$(awk -F'\t' '$3 == "MANUAL" { print $1 }' "$STAGE2" \
  | jq -R -s -f "$TMPD/p_lines_to_array.jq")"
stage2_bodies="$(awk -F'\t' '$3 != "MANUAL" { print $1 "\t" $2 "\t" $3 }' "$STAGE2")"

plan_json="$(jq -cn \
  --arg owner "$OWNER" \
  --arg src "$src_desc" \
  --argjson measured "$measured" \
  --argjson no_ci "$no_ci_repos" \
  --argjson ci_unk "$ci_unknown_repos" \
  --argjson ready "$stage2_ready_repos" \
  --argjson manual "$stage2_manual_repos" \
  --argjson s3 "$stage3" \
  --argjson n_no_ci "$n_no_ci" \
  --argjson n_ready "$n_ready" \
  --argjson n_manual "$n_manual" \
  -f "$TMPD/p_plan.jq")"

if [[ -n "$stage2_bodies" ]]; then
  plan_json="$(printf '%s' "$stage2_bodies" \
    | jq -R -s -c --argjson plan "$plan_json" -f "$TMPD/p_bodies.jq")"
fi

if [[ -n "$OUT" ]]; then
  printf '%s\n' "$plan_json" > "$OUT" || { log_error "書き出しに失敗しました: $OUT"; exit 1; }
fi

# ── 5. 表示 ────────────────────────────────────────────────
merge_n="$(printf '%s' "$stage3" | jq '.merge_candidates | length')"
human_n="$(printf '%s' "$stage3" | jq '.human_judgment | length')"

printf '\n'
printf '  %s横断是正 実行計画（plan のみ・適用しない）%s — %s\n' "$C_CYAN" "$C_RESET" "$OWNER"
printf '  ────────────────────────────────────────────────────────────\n'
printf '  入力          %s\n' "$src_desc"
printf '  1) CI なし     %s repos（CI 不明 %s）\n' "$n_no_ci" "$n_ci_unknown"
printf '  2) ruleset     %s 生成可能 / %s は check 名を手動確認\n' "$n_ready" "$n_manual"
printf '  3) 滞留 PR     マージ候補 %s / 人間判断 %s\n' "$merge_n" "$human_n"
printf '  4) controller  提案のみ（実行なし）\n'
printf '  ────────────────────────────────────────────────────────────\n'

if [[ "$n_no_ci" -gt 0 ]]; then
  printf '  1) 対象: %s\n' "$(printf '%s' "$no_ci_repos" | jq -r 'join(" ")')"
fi
if [[ "$n_ready" -gt 0 ]]; then
  printf '  2) 生成可能: %s\n' "$(printf '%s' "$stage2_ready_repos" | jq -r 'join(" ")')"
fi
if [[ "$n_manual" -gt 0 ]]; then
  printf '  %s! check 名の手動確認 (%s)%s: %s\n' "$C_YELLOW" "$n_manual" "$C_RESET" \
    "$(printf '%s' "$stage2_manual_repos" | jq -r 'join(" ")')"
fi
printf '  3) マージ候補（deps のマイナー/パッチ）:\n'
printf '%s' "$stage3" | jq -r '.merge_candidates[] | "        \(.repo) #\(.number)  \(.age_days)d  \(.type)  \(.title)"'
printf '  3) 人間判断が必要（fix / メジャー / docs / unknown）:\n'
printf '%s' "$stage3" | jq -r '.human_judgment[] | "        \(.repo) #\(.number)  \(.age_days)d  \(.type)\(if .major then "/major" else "" end)  \(.title)"'
printf '\n'

if [[ -n "$OUT" ]]; then
  printf '  計画 JSON を書き出しました: %s\n\n' "$OUT"
fi

if (( JSON )); then
  printf '%s\n' "$plan_json"
fi
