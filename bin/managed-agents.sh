#!/usr/bin/env bash
# ============================================================
# managed-agents.sh — Claude Managed Agents 運用 CLI (ClaudeOS)
#
# Local Claude Code が主系。Managed Agents は低リスク・読取専用タスクのクラウド補完先。
# 実処理は scripts/tools/managed-agents.js (adapter) に委譲する薄い入口で、出力は JSON。
#
# 使い方:
#   managed-agents.sh status [--probe]             設定・予算・Agent 定義の状態 (--probe は live のみ API を 1 回呼ぶ)
#   managed-agents.sh agents list|plan|sync        Agent 定義の一覧 / 同期計画 / 同期 (sync は mode=live のみ実行)
#   managed-agents.sh env plan|ensure              Environment (limited networking) の計画 / 作成
#   managed-agents.sh route --json '<task>'        Agent Router で実行先を判定 (Managed 可否と理由を記録)
#   managed-agents.sh session create|run ...       予算付きセッション作成 / 完了まで監視
#   managed-agents.sh session wait|get|events|interrupt|close --session-id S
#   managed-agents.sh budget status                Managed Agents 用台帳の集計
#   managed-agents.sh budget reconcile --console-usd N   Console の実績と照合
#
# mode=disabled / dry-run では API を呼ばない。API キーは環境変数 ANTHROPIC_API_KEY のみ (値は出力しない)。
# 終了コード: 0 成功 / 2 設定 / 3 予算 / 4 認証・権限 (BLOCKED) / 5 API 障害 / 6 重複 / 7 ポリシー拒否 / 8 タイムアウト
# ============================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
# shellcheck source=lib/managed-agents.sh
source "$SCRIPT_DIR/../lib/managed-agents.sh"

if [[ $# -eq 0 || "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 0
fi

require_cmd node
ma__cli "$@"
