#!/usr/bin/env bash
# ============================================================
# run-ledger.sh — Durable Agent Execution 台帳 CLI
#
# 使い方:
#   run-ledger.sh start --project P --task T [--kind task|child] [--owner O]
#                              [--parent run-id] [--ttl 900] [--worktree PATH]
#   run-ledger.sh heartbeat <run-id> [--note N]
#   run-ledger.sh checkpoint <run-id> --phase P [--note N] [--state-file F]
#   run-ledger.sh finish <run-id> --status completed|failed|blocked [--note N]
#   run-ledger.sh resume <run-id> [--note N]        # checkpoint 必須。再開計画を JSON で返す
#   run-ledger.sh reconcile [--stale-seconds N] [--json]   # heartbeat 途絶 / PID 消滅を検出
#   run-ledger.sh list [--status S] [--all] [--json]
#   run-ledger.sh tree [--parent run-id] [--json]
#   run-ledger.sh stats [--json]
#   run-ledger.sh get <run-id>            # run.json 全体 (compact JSON)
#   run-ledger.sh events <run-id> [--tail N]
#   run-ledger.sh failures [--json] [--signature S] [--count]
#   run-ledger.sh signature "<自由文>"     # 失敗 signature の計算 (同一性判定)
#
# 終了コード: 0 正常 / 1 実行エラー / 2 引数エラー / 3 状態遷移違反 / 4 再開不能
#
# 保存先: $CLAUDEOS_HOME/runs/ (CCSU_RUNS_DIR / CLAUDEOS_RUNS_DIR で上書き可)
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

usage() {
  sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

cmd="${1:-}"; shift || true
case "$cmd" in
  start)      rl_run_start "$@" ;;
  heartbeat)  rl_run_heartbeat "$@" ;;
  checkpoint) rl_run_checkpoint "$@" ;;
  finish)     rl_run_finish "$@" ;;
  resume)     rl_run_resume "$@" ;;
  reconcile)  rl_run_reconcile "$@" ;;
  list)       rl_run_list "$@" ;;
  tree)       rl_run_tree "$@" ;;
  stats)      rl_run_stats "$@" ;;
  get)
    id="${1:-}"
    rl__valid_id "$id" || die "不正な run-id: $id"
    rl_run_json "$id" || die "run が存在しません: $id"
    printf '\n'
    ;;
  events)
    id="${1:-}"; shift || true
    tail_n=0
    while (( $# )); do
      case "$1" in
        --tail) tail_n="${2:-0}"; shift 2 ;;
        *) shift ;;
      esac
    done
    rl__valid_id "$id" || die "不正な run-id: $id"
    f="$(rl_run_events_file "$id")"
    [[ -f "$f" ]] || die "events がありません: $id"
    if (( tail_n > 0 )); then tail -n "$tail_n" "$f"; else cat "$f"; fi
    ;;
  failures)
    show_json=0; sig_filter=""; count_only=0
    while (( $# )); do
      case "$1" in
        --json) show_json=1; shift ;;
        --count) count_only=1; shift ;;
        --signature) sig_filter="${2:-}"; shift 2 ;;
        *) shift ;;
      esac
    done
    f="$(rl_failures_file)"
    [[ -f "$f" ]] || { (( show_json )) && printf '[]\n'; exit 0; }
    if (( count_only )); then
      if [[ -n "$sig_filter" ]]; then
        jq -s --arg s "$sig_filter" '[.[] | select(.signature==$s)] | length' "$f"
      else
        jq -s 'length' "$f"
      fi
      exit 0
    fi
    if (( show_json )); then
      if [[ -n "$sig_filter" ]]; then
        jq -s -c --arg s "$sig_filter" '[.[] | select(.signature==$s)]' "$f"
      else
        jq -s -c . "$f"
      fi
      exit 0
    fi
    if [[ -n "$sig_filter" ]]; then
      jq -r --arg s "$sig_filter" 'select(.signature==$s) | "\(.at)\t\(.run_id)\t\(.status)\t\(.note)"' "$f"
    else
      jq -r '"\(.at)\t\(.run_id)\t\(.status)\t\(.signature)"' "$f"
    fi
    ;;
  signature)
    [[ -n "${1:-}" ]] || die "signature には対象文字列が必要です"
    rl_signature "$1"
    printf '\n'
    ;;
  ""|-h|--help|help) usage ;;
  *) log_error "不明なサブコマンド: $cmd"; usage; exit 2 ;;
esac
