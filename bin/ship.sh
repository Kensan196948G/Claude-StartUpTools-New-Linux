#!/usr/bin/env bash
# ============================================================
# ship.sh — ClaudeOS v5.0 Ship Integration Engine エントリ
#
# 使い方:
#   ship.sh capability [--project DIR] [--json]
#   ship.sh run-start --project DIR --repo O/R --mode SH1|SH2|SH3|SH4|SH5|QC|HG [--intent T] [--pr N]
#   ship.sh run-status [--id RUN] [--json]
#   ship.sh run-transition --id RUN --to STATE [--reason R]
#   ship.sh run-stop --id RUN [--reason R]
#   ship.sh discover-pr --repo O/R --branch B
#   ship.sh quality --repo O/R --project DIR --head SHA [--base SHA] [--pr N] [--publish]
#   ship.sh classify --repo O/R --pr N
#   ship.sh gate --repo O/R --pr N [--requirements met|partial|unknown] [--impact-doc F] [--rollback-doc F]
#   ship.sh approvals --repo O/R --pr N
#   ship.sh merge --repo O/R --pr N [--dry-run]
#   ship.sh monitor [--once] [--interval SEC]
#   ship.sh actions --repo O/R
#   ship.sh audit-verify
#
# 人間の承認は bin/ship-approve.sh (AI からは TTY が無く実行できない)。
# /ship・/steward は人が対話型 Claude Code セッションで入力する (公式仕様で headless 不可)。
# ClaudeOS はそれを代行せず、前後の工程 (ローカル品質・品質判定・承認・マージ) を担う。
#
# 終了コード: 0 正常 / 1 判定 NG・拒否 / 2 引数エラー / 3 外部依存エラー
# ============================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
command -v node >/dev/null 2>&1 || { echo "ship.sh: node が必要です" >&2; exit 3; }
case "${1:-}" in
  ""|-h|--help|help) sed -n '2,27p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac
exec node "$SCRIPT_DIR/../scripts/ship/ship.js" "$@"
