#!/usr/bin/env bash
# ============================================================
# ship-approve.sh — ClaudeOS Human Gate (人間専用)
#
# 使い方:
#   ship-approve.sh keygen --name NAME
#   ship-approve.sh attach-app --app-id N --installation-id N --pem FILE
#   ship-approve.sh show    --repo O/R --pr N
#   ship-approve.sh approve --repo O/R --pr N --head SHA
#   ship-approve.sh reject  --repo O/R --pr N --head SHA --reason R
#   ship-approve.sh revoke  --id APPROVAL_ID --reason R
#   ship-approve.sh ship-attest --repo O/R --pr N --head SHA --workdir DIR --reviewed yes|no \
#        --important-open N --watch checks-pass-comments-answered|stopped|running|not-started
#        (DIR は /ship を実行した作業フォルダ。版が SHA と同じで未コミットの変更が無いこと。
#         --reviewed yes では重大な指摘の件数を端末で入力し直す)
#   ship-approve.sh ship-attest --kind human-diff --repo O/R --pr N --head SHA --important-open N
#
# パスフレーズと確認は端末 (/dev/tty) からのみ入力する。パイプ・引数・環境変数では受け付けない。
# 承認は head SHA と base SHA に固定され、どちらかが変われば無効になる。
# ============================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
case "${1:-}" in
  ""|-h|--help|help)
    awk 'NR==1 {next} NR>2 && /^# =+$/ {print ""; exit} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "${BASH_SOURCE[0]}"
    exit 0 ;;

esac
exec node "$SCRIPT_DIR/../scripts/ship/approve.js" "$@"
