#!/usr/bin/env bash
# ============================================================
# improver-gate.sh — Self-Improvement 昇格ゲート CLI
#
# 使い方:
#   improver-gate.sh evaluate <signature> [--min-evidence N] [--evidence-file F]
#       → 証拠数だけを判定 (rc=0 証拠十分 / 1 不足)
#   improver-gate.sh evidence [--evidence-file F]        # 証拠のある signature 一覧
#   improver-gate.sh eval [--cmd CMD] [--timeout S]      # 回帰 eval を実行し結果 JSON を返す
#   improver-gate.sh promote <signature> --proposal F (--eval-result-file F | --run-eval)
#                          [--token T] [--min-evidence N] [--dry-run]
#       → 4 要件 (証拠 / 回帰 eval pass / 承認トークン / 提案) を満たすときだけ昇格記録を作る
#   improver-gate.sh status [--json]                     # 昇格済み一覧
#
# 終了コード: 0 可 / 1 拒否 / 2 引数エラー
# ============================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
# shellcheck source=lib/json.sh
source "$SCRIPT_DIR/../lib/json.sh"
# shellcheck source=lib/policy-engine.sh
source "$SCRIPT_DIR/../lib/policy-engine.sh"
# shellcheck source=lib/improver-gate.sh
source "$SCRIPT_DIR/../lib/improver-gate.sh"

require_cmd jq

usage() { sed -n '2,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

cmd="${1:-}"; shift || true
case "$cmd" in
  evaluate) ig_evaluate "$@" ;;
  evidence)
    extra=""
    while (( $# )); do
      case "$1" in --evidence-file) extra="${2:-}"; shift 2 ;; *) shift ;; esac
    done
    if [[ -n "$extra" ]]; then ig_distinct_signatures --evidence-file "$extra"; else ig_distinct_signatures; fi
    ;;
  eval)     ig_run_eval "$@" ;;
  promote)  ig_promote "$@" ;;
  status)   ig_status "$@" ;;
  ""|-h|--help|help) usage ;;
  *) log_error "不明なサブコマンド: $cmd"; usage; exit 2 ;;
esac
