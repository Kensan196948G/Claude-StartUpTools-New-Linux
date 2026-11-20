#!/usr/bin/env bash
# ============================================================
# policy-check.sh — Agent Identity / Policy Engine CLI
#
# 使い方:
#   policy-check.sh check <agent> <action> [--resource R] [--mode M] [--token T]
#       → 判定 JSON。終了コード 0=allow / 1=deny / 3=approval_required
#   policy-check.sh explain <agent> <action>          # 人が読む形で理由を表示
#   policy-check.sh agents                            # 定義済み agent 一覧
#   policy-check.sh issue <agent> [--ttl 900]         # identity token 発行 (stdout)
#   policy-check.sh verify <token>                    # token 検証
#   policy-check.sh audit [--tail N] [--json]         # 監査証跡 (JSONL)
#   policy-check.sh matrix [--json]                   # 全 agent × 主要 action の判定表
#
# ポリシー正本: config/agent-policy.json (CLAUDEOS_AGENT_POLICY で上書き可)
# 監査ログ: ~/.claudeos/logs/policy-audit.jsonl
# ============================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
# shellcheck source=lib/json.sh
source "$SCRIPT_DIR/../lib/json.sh"
# shellcheck source=lib/policy-engine.sh
source "$SCRIPT_DIR/../lib/policy-engine.sh"

require_cmd jq
require_cmd openssl

usage() { sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

cmd="${1:-}"; shift || true
case "$cmd" in
  check)
    policy_check "$@"
    ;;
  explain)
    agent="${1:-}"; action="${2:-}"
    out="$(policy_decision "$agent" "$action")"
    printf '%s\n' "$out" | jq -r '"agent : \(.agent)\naction: \(.action)\n判定  : \(.decision)\nrisk  : \(.risk) (agent 上限 \(.agent_max_risk))\n理由  : \(.reasons | join(" / "))"'
    case "$(printf '%s' "$out" | jq -r '.decision')" in
      allow) exit 0 ;;
      approval_required) exit 3 ;;
      *) exit 1 ;;
    esac
    ;;
  agents)
    jq -r '.agents | to_entries[] | "\(.key)\t\(.value.max_risk)\t\(.value.role)"' "$(policy__config_path)"
    ;;
  issue)
    policy_token_issue "$@"
    ;;
  verify)
    token="${1:-}"
    policy_token_verify "$token"
    ;;
  audit)
    tail_n=0; as_json=0
    while (( $# )); do
      case "$1" in
        --tail) tail_n="${2:-0}"; shift 2 ;;
        --json) as_json=1; shift ;;
        *) shift ;;
      esac
    done
    f="$(policy__audit_file)"
    [[ -f "$f" ]] || { log_info "監査ログはまだありません: $f"; exit 0; }
    if (( tail_n > 0 )); then
      if (( as_json )); then tail -n "$tail_n" "$f" | jq -s -c .; else tail -n "$tail_n" "$f"; fi
    else
      if (( as_json )); then jq -s -c . "$f"; else cat "$f"; fi
    fi
    ;;
  matrix)
    policy_matrix "$@"
    ;;
  ""|-h|--help|help) usage ;;
  *) log_error "不明なサブコマンド: $cmd"; usage; exit 2 ;;
esac
