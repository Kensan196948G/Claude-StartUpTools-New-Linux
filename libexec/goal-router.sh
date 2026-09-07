#!/usr/bin/env bash
# ============================================================
# goal-router.sh — 統合 Goal Router CLI (lib/goal-router.sh の薄いラッパ)
#
# 使い方:
#   libexec/goal-router.sh <project|dir> [--goal auto|<name>] [--intent "<text>"]
#                          [--dry-run] [--reroute] [--json] [--explain]
#
#   --dry-run  : state.json を更新せず判定だけ表示 (運用確認・Mission Control 用)
#   --reroute  : session lock を無視して再判定 (CLAUDEOS_GOAL_REROUTE=1 と同義)
#   --json     : 判定結果を JSON で出力
#   --explain  : 収集した Evidence (key=value) も表示
#
# 判定ロジックは lib/goal-router.sh のみ (UI / Supervisor / cron へ複製しない)。
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
# shellcheck source=lib/config-loader.sh
source "$SCRIPT_DIR/../lib/config-loader.sh"
# shellcheck source=lib/launcher-common.sh
source "$SCRIPT_DIR/../lib/launcher-common.sh"
# shellcheck source=lib/goal-router.sh
source "$SCRIPT_DIR/../lib/goal-router.sh"

usage() {
  sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

main() {
  local target="" goal="" intent="" dry=0 as_json=0 explain=0 reroute=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --goal) goal="${2:-}"; shift 2 ;;
      --intent) intent="${2:-}"; shift 2 ;;
      --dry-run) dry=1; shift ;;
      --reroute) reroute=1; shift ;;
      --json) as_json=1; shift ;;
      --explain) explain=1; shift ;;
      -h|--help) usage; return 0 ;;
      -*) log_error "不明な引数: $1"; usage; return 1 ;;
      *) target="$1"; shift ;;
    esac
  done
  [[ -n "$target" ]] || { usage; return 1; }

  local project_dir
  if [[ -d "$target" ]]; then project_dir="$(cd "$target" && pwd)"; else project_dir="$(launcher__project_dir "$target")"; fi
  [[ -d "$project_dir" ]] || { log_error "プロジェクトが存在しません: $project_dir"; return 1; }
  if [[ -n "$goal" && "$goal" != "auto" ]] && ! goal_router__is_goal "$goal"; then
    log_error "--goal は auto / ${GOAL_ROUTER_PRIMARY_GOALS[*]} / ${GOAL_ROUTER_SPECIALIZED_GOALS[*]} のいずれか: $goal"; return 1
  fi
  (( reroute )) && export CLAUDEOS_GOAL_REROUTE=1

  if (( explain )); then
    echo "── Evidence ──"
    goal_router__evidence "$project_dir" "$intent"
    echo "── Route ──"
  fi
  local -a args=( --trigger cli )
  [[ -n "$goal" || -n "$intent" ]] && args=( --trigger user )
  [[ -n "$goal" ]] && args+=( --goal "$goal" )
  [[ -n "$intent" ]] && args+=( --intent "$intent" )
  (( dry )) && args+=( --no-persist )
  goal_router__resolve "$project_dir" "${args[@]}" >/dev/null

  if (( as_json )); then
    GR_PROJECT_DIR="$project_dir" GR_DRY="$dry" python3 - <<'PYEOF'
import json, os
e = os.environ
print(json.dumps({
  "project_dir": e["GR_PROJECT_DIR"], "dry_run": e["GR_DRY"] == "1",
  "primary_goal": e.get("GOAL_ROUTER_PRIMARY", ""), "specialized_goal": e.get("GOAL_ROUTER_SPECIALIZED") or None,
  "effective_goal_type": e.get("GOAL_ROUTER_EFFECTIVE", ""), "confidence": float(e.get("GOAL_ROUTER_CONFIDENCE") or 0),
  "mode": e.get("GOAL_ROUTER_MODE", ""), "reason": e.get("GOAL_ROUTER_REASON", ""),
  "evidence": [x for x in e.get("GOAL_ROUTER_EVIDENCE", "").split(",") if x],
  "transition": e.get("GOAL_ROUTER_TRANSITION", ""), "locked_by_user": e.get("GOAL_ROUTER_LOCKED_BY_USER") == "true",
  "fallback": e.get("GOAL_ROUTER_FALLBACK") == "1",
}, ensure_ascii=False, indent=2))
PYEOF
  else
    echo "🧭 Goal Router: $project_dir"
    echo "  primary_goal        = ${GOAL_ROUTER_PRIMARY:-}"
    echo "  specialized_goal    = ${GOAL_ROUTER_SPECIALIZED:-none}"
    echo "  effective_goal_type = ${GOAL_ROUTER_EFFECTIVE:-}"
    echo "  confidence          = ${GOAL_ROUTER_CONFIDENCE:-0}"
    echo "  mode                = ${GOAL_ROUTER_MODE:-auto} (locked_by_user=${GOAL_ROUTER_LOCKED_BY_USER:-false})"
    echo "  transition          = ${GOAL_ROUTER_TRANSITION:-}"
    echo "  reason              = ${GOAL_ROUTER_REASON:-}"
    echo "  evidence            = ${GOAL_ROUTER_EVIDENCE:-}"
    (( dry )) && echo "  (dry-run: state.json は更新していません)"
  fi
  return 0
}

main "$@"
