#!/usr/bin/env bash
# ============================================================
# migration-run.sh — 大規模改修の分割実行 (worktree 分離 + run 分割)
#
# 役割: 数十万行規模の改修を「1 回の巨大な作業」にしない。
#   - 改修を group (担当範囲 + 検証コマンド) に分割し、group ごとに
#     git worktree を切って作業ツリーを分離する (互いの未コミット変更が混ざらない)
#   - 各 group は run-ledger の独立 run として追跡する (中断・再開・証跡が残る)
#   - 検証は group のコマンドを worktree 内で実行し、終了コードと変更ファイル
#     の fingerprint を記録する (「通った」の証跡を後から検証できる)
#   - main へは直接触らない。統合は人間が PR を作って行う (自動 merge しない)
#
# 使い方:
#   migration-run.sh plan   --file PLAN.json [--json]
#   migration-run.sh start  --plan PLAN.json [--json]
#   migration-run.sh status [--json]
#   migration-run.sh verify --id GROUP [--json]
#   migration-run.sh finish --id GROUP --status ok|failed [--note N] [--json]
#   migration-run.sh report [--json]
#   migration-run.sh clean  --id GROUP            # worktree を撤去 (branch は残す)
#
# PLAN.json:
#   { "schema": "claudeos.migration-plan/v1",
#     "title": "…", "base": "main",
#     "groups": [ { "id": "api", "paths": ["src/api"], "command": "npm test" } ] }
#
# 環境変数:
#   CCSU_MIGRATION_REPO     対象リポジトリ (既定: CCSU_ROOT の git toplevel)
#   CCSU_MIGRATION_HOME     状態と worktree の置き場 (既定: $CCSU_HOME/migrations)
#   CCSU_MIGRATION_TIMEOUT  検証コマンドの上限秒 (既定: 900)
#
# 終了コード: 0 正常 / 1 検証失敗・実行エラー / 2 引数・プラン不正 / 3 状態違反
# ============================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
# shellcheck source=lib/json.sh
source "$SCRIPT_DIR/../lib/json.sh"
# shellcheck source=lib/run-ledger.sh
source "$SCRIPT_DIR/../lib/run-ledger.sh"

require_cmd jq
require_cmd git

MR_SCHEMA="claudeos.migration-plan/v1"
MR_STATE_SCHEMA="claudeos.migration-state/v1"

usage() { sed -n '2,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

mr__repo() {
  local r="${CCSU_MIGRATION_REPO:-}"
  if [[ -z "$r" ]]; then r="$(git -C "$CCSU_ROOT" rev-parse --show-toplevel 2>/dev/null || true)"; fi
  printf '%s' "$r"
}
mr__home() { printf '%s' "${CCSU_MIGRATION_HOME:-$CCSU_HOME/migrations}"; }
mr__state_file() { printf '%s/state.json' "$(mr__home)"; }
mr__worktree_dir() { printf '%s/trees/%s' "$(mr__home)" "$1"; }
mr__branch() { printf 'migration/%s/%s' "$2" "$1"; }
mr__iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

mr__require_repo() {
  local repo; repo="$(mr__repo)"
  [[ -n "$repo" && -d "$repo/.git" ]] || { log_error "対象リポジトリが見つかりません (CCSU_MIGRATION_REPO を設定してください)"; return 2; }
  printf '%s' "$repo"
}

# mr__load_plan <file> — 検証済みプラン (plan_id 付き) を stdout へ
mr__load_plan() {
  local file="$1"
  [[ -f "$file" ]] || { log_error "プランがありません: $file"; return 2; }
  jq -e . "$file" >/dev/null 2>&1 || { log_error "プランが JSON ではありません: $file"; return 2; }
  local schema; schema="$(json_get "$file" '.schema' '')"
  [[ "$schema" == "$MR_SCHEMA" ]] || { log_error "プラン schema が不正です ($MR_SCHEMA が必要): $schema"; return 2; }
  local n; n="$(json_get "$file" '.groups | length' '0')"
  [[ "$n" =~ ^[0-9]+$ ]] && (( n > 0 )) || { log_error "groups が空です"; return 2; }
  local i id cmd
  for (( i = 0; i < n; i++ )); do
    id="$(json_get "$file" ".groups[$i].id" '')"
    [[ "$id" =~ ^[A-Za-z0-9._-]+$ ]] || { log_error "groups[$i].id は [A-Za-z0-9._-] のみ: $id"; return 2; }
    cmd="$(json_get "$file" ".groups[$i].command" '')"
    [[ -n "$cmd" ]] || { log_error "groups[$i].command が必要です (検証コマンド)"; return 2; }
    [[ "$(json_get "$file" ".groups[$i].paths | type" 'null')" == "array" ]] || { log_error "groups[$i].paths は配列が必要です"; return 2; }
  done
  local canon; canon="$(jq -Sc '{title:(.title // ""), base:(.base // "HEAD"), groups:.groups}' "$file")"
  local pid; pid="mig-$(printf '%s' "$canon" | sha1sum | cut -c1-10)"
  jq -cn --argjson plan "$canon" --arg id "$pid" '{plan_id:$id, title:$plan.title, base:$plan.base, groups:$plan.groups, group_count:($plan.groups|length)}'
}

mr__state_get() { json_get "$(mr__state_file)" "$1" "${2:-}"; }

mr__state_init() {
  local plan_json="$1" repo="$2" head
  head="$(git -C "$repo" rev-parse "$(printf '%s' "$plan_json" | jq -r '.base')" 2>/dev/null || true)"
  [[ -n "$head" ]] || { log_error "base 参照を解決できません"; return 2; }
  mkdir -p "$(mr__home)"
  json_set "$(mr__state_file)" \
    '{schema:$schema, plan_id:$pid, title:$title, base:$base, base_commit:$head, repo:$repo,
      created_at:$at, groups:{}}' \
    --arg schema "$MR_STATE_SCHEMA" --arg pid "$(printf '%s' "$plan_json" | jq -r '.plan_id')" \
    --arg title "$(printf '%s' "$plan_json" | jq -r '.title')" \
    --arg base "$(printf '%s' "$plan_json" | jq -r '.base')" --arg head "$head" \
    --arg repo "$repo" --arg at "$(mr__iso)"
}

cmd_plan() {
  local file="" as_json=0
  while (( $# )); do
    case "$1" in --file) file="${2:-}"; shift 2 ;; --json) as_json=1; shift ;; *) log_error "不明な引数: $1"; return 2 ;; esac
  done
  [[ -n "$file" ]] || { log_error "plan: --file が必要です"; return 2; }
  local out; out="$(mr__load_plan "$file")" || return $?
  if (( as_json )); then printf '%s\n' "$out"; else printf '%s\n' "$out" | jq -r '"plan_id=\(.plan_id) base=\(.base) groups=\(.group_count)"'; fi
}

cmd_start() {
  local plan_file="" as_json=0
  while (( $# )); do
    case "$1" in --plan|--file) plan_file="${2:-}"; shift 2 ;; --json) as_json=1; shift ;; *) log_error "不明な引数: $1"; return 2 ;; esac
  done
  [[ -n "$plan_file" ]] || { log_error "start: --plan が必要です"; return 2; }
  local plan; plan="$(mr__load_plan "$plan_file")" || return $?
  local repo; repo="$(mr__require_repo)" || return $?
  local pid; pid="$(printf '%s' "$plan" | jq -r '.plan_id')"

  if [[ -f "$(mr__state_file)" ]] && [[ "$(mr__state_get '.plan_id' '')" == "$pid" ]]; then
    log_info "既に開始済みのプランです (plan_id=$pid)。status を参照してください" >&2
  else
    mr__state_init "$plan" "$repo" || return $?
  fi

  local n; n="$(printf '%s' "$plan" | jq -r '.group_count')"
  local i id cmd branch wt run_id
  for (( i = 0; i < n; i++ )); do
    id="$(printf '%s' "$plan" | jq -r --argjson i "$i" '.groups[$i].id')"
    cmd="$(printf '%s' "$plan" | jq -r --argjson i "$i" '.groups[$i].command')"
    if [[ -n "$(mr__state_get ".groups[\"$id\"].run_id" '')" ]]; then
      log_info "group $id は開始済み (skip)" >&2; continue
    fi
    branch="$(mr__branch "$id" "$pid")"
    wt="$(mr__worktree_dir "$id")"
    if git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"; then
      log_error "branch が既に存在します: $branch (先に clean するか別の plan_id を使ってください)"; return 3
    fi
    mkdir -p "$(dirname "$wt")"
    if ! git -C "$repo" worktree add -q -b "$branch" "$wt" "$(mr__state_get '.base_commit')" 2>/dev/null; then
      log_error "worktree 作成失敗: group=$id"; return 1
    fi
    run_id="$(rl_run_start --project "migration:$pid" --task "group:$id" --worktree "$wt" | tail -n1)"
    [[ -n "$run_id" ]] || { log_error "run 作成失敗: group=$id"; return 1; }
    json_set "$(mr__state_file)" \
      '.groups[$id] = {id:$id, command:$cmd, branch:$branch, worktree:$wt, run_id:$run_id,
                       status:"running", created_at:$at, verify:null, finish:null}' \
      --arg id "$id" --arg cmd "$cmd" --arg branch "$branch" --arg wt "$wt" \
      --arg run_id "$run_id" --arg at "$(mr__iso)"
    log_ok "group $id: branch=$branch worktree=$wt run=$run_id" >&2
  done

  if (( as_json )); then cmd_status --json; else cmd_status; fi
}

cmd_status() {
  local as_json=0
  while (( $# )); do case "$1" in --json) as_json=1; shift ;; *) shift ;; esac; done
  local sf; sf="$(mr__state_file)"
  [[ -f "$sf" ]] || { log_error "状態ファイルがありません: $sf (start を先に実行)"; return 2; }
  if (( as_json )); then
    jq -c '{schema, plan_id, title, base, base_commit, repo, groups}' "$sf"
  else
    jq -r '"plan=\(.plan_id) base=\(.base // "?")@\(.base_commit[0:8]) repo=\(.repo)",
           (.groups[] | "  \(.id)\t\(.status)\t\(.branch)\trun=\(.run_id)\tverify=\(if .verify == null then "-" else (.verify.exit_code|tostring) end)")' "$sf"
  fi
}

cmd_verify() {
  local id="" as_json=0
  while (( $# )); do
    case "$1" in --id) id="${2:-}"; shift 2 ;; --json) as_json=1; shift ;; *) shift ;; esac
  done
  [[ -n "$id" ]] || { log_error "verify: --id が必要です"; return 2; }
  local sf; sf="$(mr__state_file)"
  local wt cmd run_id
  wt="$(json_get "$sf" ".groups[\"$id\"].worktree" '')"
  cmd="$(json_get "$sf" ".groups[\"$id\"].command" '')"
  run_id="$(json_get "$sf" ".groups[\"$id\"].run_id" '')"
  [[ -n "$wt" && -d "$wt" ]] || { log_error "worktree がありません: group=$id"; return 2; }
  [[ -n "$cmd" ]] || { log_error "検証コマンドがありません: group=$id"; return 2; }

  local log_file; log_file="$(mr__home)/$id.verify.log"
  mkdir -p "$(dirname "$log_file")"
  local started rc=0
  started="$(date +%s)"
  ( cd "$wt" && timeout "${CCSU_MIGRATION_TIMEOUT:-900}" bash -c "$cmd" ) > "$log_file" 2>&1 || rc=$?
  local dur=$(( $(date +%s) - started ))
  local fingerprint; fingerprint="$(git -C "$wt" status --porcelain | sha1sum | cut -c1-16)"
  local changed; changed="$(git -C "$wt" status --porcelain | wc -l | tr -d ' ')"
  local status="passed"; (( rc == 0 )) || status="failed"
  json_set "$sf" \
    '.groups[$id].verify = {status:$status, exit_code:$rc, duration_s:$dur, fingerprint:$fp,
                            changed_files:$changed, log:$log, at:$at}' \
    --arg id "$id" --arg status "$status" --argjson rc "$rc" --argjson dur "$dur" \
    --arg fp "$fingerprint" --argjson changed "$changed" --arg log "$log_file" --arg at "$(mr__iso)"
  if [[ -n "$run_id" ]]; then
    rl_run_checkpoint "$run_id" --phase "verify" --note "$status" >/dev/null 2>&1 || true
  fi
  if (( as_json )); then
    jq -cn --arg id "$id" --arg status "$status" --argjson rc "$rc" --argjson dur "$dur" \
      --arg fp "$fingerprint" --argjson changed "$changed" --arg log "$log_file" \
      '{id:$id, status:$status, exit_code:$rc, duration_s:$dur, fingerprint:$fp, changed_files:$changed, log:$log}'
  else
    printf 'group %s: %s (exit=%s, %ss, changed=%s, log=%s)\n' "$id" "$status" "$rc" "$dur" "$changed" "$log_file"
  fi
  [[ "$status" == "passed" ]]
}

cmd_finish() {
  local id="" status="" note="" as_json=0
  while (( $# )); do
    case "$1" in
      --id) id="${2:-}"; shift 2 ;;
      --status) status="${2:-}"; shift 2 ;;
      --note) note="${2:-}"; shift 2 ;;
      --json) as_json=1; shift ;;
      *) shift ;;
    esac
  done
  [[ -n "$id" ]] || { log_error "finish: --id が必要です"; return 2; }
  [[ "$status" =~ ^(ok|failed|blocked)$ ]] || { log_error "finish: --status は ok|failed|blocked"; return 2; }
  local sf; sf="$(mr__state_file)"
  local run_id; run_id="$(json_get "$sf" ".groups[\"$id\"].run_id" '')"
  [[ -n "$run_id" ]] || { log_error "run がありません: group=$id"; return 2; }

  # 検証を通っていない group を ok で閉じさせない
  if [[ "$status" == "ok" ]]; then
    local vstatus; vstatus="$(json_get "$sf" ".groups[\"$id\"].verify.status" '')"
    [[ "$vstatus" == "passed" ]] || { log_error "finish: 検証が passed ではありません (group=$id, verify=${vstatus:-未実行})"; return 3; }
  fi
  local rl_status="completed"
  [[ "$status" == "failed" ]] && rl_status="failed"
  [[ "$status" == "blocked" ]] && rl_status="blocked"
  rl_run_finish "$run_id" --status "$rl_status" --note "${note:-group $id: $status}" >/dev/null 2>&1 || true
  json_set "$sf" '.groups[$id].status = $s | .groups[$id].finish = {status:$s, note:$n, at:$at}' \
    --arg id "$id" --arg s "$status" --arg n "$note" --arg at "$(mr__iso)"
  if (( as_json )); then
    jq -cn --arg id "$id" --arg status "$status" --arg run "$run_id" --arg rl "$rl_status" \
      '{id:$id, status:$status, run_id:$run, run_ledger_status:$rl}'
  else
    printf 'group %s: %s (run=%s -> %s)\n' "$id" "$status" "$run_id" "$rl_status"
  fi
}

cmd_report() {
  local as_json=0
  while (( $# )); do case "$1" in --json) as_json=1; shift ;; *) shift ;; esac; done
  local sf; sf="$(mr__state_file)"
  [[ -f "$sf" ]] || { log_error "状態ファイルがありません: $sf"; return 2; }
  local summary; summary="$(jq -c '
    {schema:"claudeos.migration-report/v1", plan_id, title, base, base_commit, repo,
     groups: [.groups[] | {id, status, branch, worktree, run_id,
                           verify_status:(.verify.status // null), verify_exit:(.verify.exit_code // null),
                           fingerprint:(.verify.fingerprint // null), changed_files:(.verify.changed_files // null)}],
     counts: (.groups | [.[] | .status] | group_by(.) | map({(.[0]): length}) | add),
     integration: {mode:"human_gated",
                   note:"main への統合は自動化しません。上の branch を push し、人間が PR を作成してレビュー後に Squash Merge します",
                   next: ([.groups[] | select(.verify.status == "passed") | .branch] | map("git push -u origin " + .))}}' "$sf")"
  if (( as_json )); then printf '%s\n' "$summary"; else printf '%s\n' "$summary" | jq -r '.groups[] | "  \(.id)\t\(.status)\tverify=\(.verify_status // "-") \t\(.branch)"'; fi
}

cmd_clean() {
  local id=""
  while (( $# )); do case "$1" in --id) id="${2:-}"; shift 2 ;; *) shift ;; esac; done
  [[ -n "$id" ]] || { log_error "clean: --id が必要です"; return 2; }
  local sf repo wt
  sf="$(mr__state_file)"; repo="$(mr__require_repo)" || return $?
  wt="$(json_get "$sf" ".groups[\"$id\"].worktree" '')"
  [[ -n "$wt" && -d "$wt" ]] || { log_error "worktree がありません: group=$id"; return 2; }
  git -C "$repo" worktree remove --force "$wt" || { log_error "worktree 撤去失敗: $wt"; return 1; }
  log_ok "撤去しました: $wt (branch は残しています)"
}

case "${1:-}" in
  plan)   shift; cmd_plan "$@" ;;
  start)  shift; cmd_start "$@" ;;
  status) shift; cmd_status "$@" ;;
  verify) shift; cmd_verify "$@" ;;
  finish) shift; cmd_finish "$@" ;;
  report) shift; cmd_report "$@" ;;
  clean)  shift; cmd_clean "$@" ;;
  ""|-h|--help|help) usage ;;
  *) log_error "不明なサブコマンド: ${1:-}"; usage; exit 2 ;;
esac
