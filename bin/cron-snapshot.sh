#!/usr/bin/env bash
# ============================================================
# cron-snapshot.sh — crontab の内容をスナップショットとして書き出す
#
# なぜ必要か: Web サービス (claudeos-web-startup.service) は
#   NoNewPrivileges=yes で動いており、crontab が spool を読むための
#   setgid 昇格が阻害される (crontabs/<user>: Permission denied)。
#   硬化を弱めずに Cron 画面へ実データを出すため、ユーザー文脈の
#   タイマーがここでスナップショットを書き、API はそれを読む。
#
# 使い方:
#   bash bin/cron-snapshot.sh            # 既定の出力先へ書く
#   bash bin/cron-snapshot.sh --stdout   # 標準出力へ (確認用)
#
# 出力: $CLAUDEOS_HOME/cron-snapshot.json
#   {"generated_at":"...","source":"crontab -l","ok":true,"count":N,"entries":[...]}
# 秘密情報は含まない (crontab の内容そのもの)。書き込みは自分の HOME 配下のみ。
# ============================================================
set -euo pipefail

CCSU_HOME="${CLAUDEOS_HOME:-$HOME/.claudeos}"
OUT="$CCSU_HOME/cron-snapshot.json"
TO_STDOUT=0
[[ "${1:-}" == "--stdout" ]] && TO_STDOUT=1

crontab_text=""
if command -v crontab >/dev/null 2>&1; then
  crontab_text="$(crontab -l 2>/dev/null || true)"
fi

# 5 フィールド + コマンド。先頭 # は無効行 (DISABLED マーカー付きも含む)。
entries_json="$(printf '%s\n' "$crontab_text" | awk '
  BEGIN { first = 1; printf "[" }
  {
    line = $0
    gsub(/^[ \t]+|[ \t]+$/, "", line)
    if (line == "") next
    disabled = 0
    body = line
    if (substr(line, 1, 1) == "#") {
      disabled = 1
      sub(/^#[A-Za-z0-9_-]*#[ \t]*/, "", body)
      if (substr(body, 1, 1) == "#") sub(/^#[ \t]*/, "", body)
      if (body ~ /^[A-Za-z_]+=/) next
    }
    n = split(body, f, /[ \t]+/)
    if (n < 6) next
    cmd = f[6]
    for (i = 7; i <= n; i++) cmd = cmd " " f[i]
    gsub(/\\/, "\\\\", cmd); gsub(/"/, "\\\"", cmd)
    if (!first) printf ","
    first = 0
    printf "{\"disabled\":%s,\"minute\":\"%s\",\"hour\":\"%s\",\"dom\":\"%s\",\"month\":\"%s\",\"dow\":\"%s\",\"command\":\"%s\"}", \
      (disabled ? "true" : "false"), f[1], f[2], f[3], f[4], f[5], cmd
  }
  END { printf "]" }
')"

count="$(printf '%s' "$entries_json" | jq 'length' 2>/dev/null || echo 0)"
json="$(jq -n --arg at "$(date -Is)" --argjson c "$count" --argjson e "$entries_json" \
  '{generated_at:$at, source:"crontab -l", ok:true, count:$c, entries:$e}')"

if [[ "$TO_STDOUT" == "1" ]]; then
  printf '%s\n' "$json"
  exit 0
fi

mkdir -p "$CCSU_HOME"
printf '%s\n' "$json" > "$OUT.tmp"
mv "$OUT.tmp" "$OUT"
printf 'cron-snapshot: %s 件 -> %s\n' "$count" "$OUT"
