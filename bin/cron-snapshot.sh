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
#   ClaudeOS が登録したエントリ (直前に `# CLAUDEOS:<id> project=... duration=...` の印がある cron 行) には
#   "claudeos":{"id","project","duration","created","goal"} を付ける。印の無い行 (他用途の cron) には付けない。
#   Web の将来の「今すぐ実行」が、実行してよい対象 (ClaudeOS 管理分) だけを判定するための情報。
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
# 先頭 5 語が cron のスケジュール書式でない行 (説明コメント等) はエントリにしない。
#   例: "# 2>&1 then not Do ..." のように 6 語以上ある説明コメントを無効 cron と誤認しない。
entries_json="$(printf '%s\n' "$crontab_text" | awk -v prefix="${CCSU_CRON_PREFIX:-CLAUDEOS}" '
  # 1 要素: * / 数字 / 範囲 / 名前(names に含まれる 3 文字) + 任意の /step
  function okend(s, names) {
    if (s == "*" || s ~ /^[0-9]+$/) return 1
    return (length(s) == 3 && index(names, " " tolower(s) " ") > 0)
  }
  function okpart(p, names,   a, k) {
    sub(/\/[0-9]+$/, "", p)
    k = split(p, a, "-")
    if (k == 1) return okend(a[1], names)
    if (k == 2) return (a[1] != "*" && okend(a[1], names) && okend(a[2], names))
    return 0
  }
  function okfield(s, names,   parts, n, i) {
    n = split(s, parts, ",")
    for (i = 1; i <= n; i++) if (!okpart(parts[i], names)) return 0
    return (n > 0)
  }
  function okschedule(f) {
    return okfield(f[1], "") && okfield(f[2], "") && okfield(f[3], "") \
        && okfield(f[4], " jan feb mar apr may jun jul aug sep oct nov dec ") \
        && okfield(f[5], " sun mon tue wed thu fri sat ")
  }
  function jesc(x) { gsub(/\\/, "\\\\", x); gsub(/"/, "\\\"", x); gsub(/[\001-\037]/, "", x); return x }
  # 印 (# CLAUDEOS:<id> project=P duration=N created=T [goal=G]) から必要な項目を取り出す。id は英数字と _ - のみ
  function parse_marker(l,   rest, id, p, d, c, g, m) {
    rest = l; sub(/^#[ \t]*/, "", rest)
    if (index(rest, prefix ":") != 1) return ""
    rest = substr(rest, length(prefix) + 2)
    if (!match(rest, /^[A-Za-z0-9_-]+/)) return ""
    id = substr(rest, 1, RLENGTH); rest = substr(rest, RLENGTH + 1)
    if (rest != "" && substr(rest, 1, 1) !~ /[ \t]/) return ""
    p = ""; d = ""; c = ""; g = ""
    if (match(rest, /project=[^ \t]+/)) p = substr(rest, RSTART + 8, RLENGTH - 8)
    if (match(rest, /duration=[0-9]+/)) d = substr(rest, RSTART + 9, RLENGTH - 9)
    if (match(rest, /created=[^ \t]+/)) c = substr(rest, RSTART + 8, RLENGTH - 8)
    if (match(rest, /goal=[A-Za-z0-9_-]+/)) g = substr(rest, RSTART + 5, RLENGTH - 5)
    if (p == "" || d == "") return ""   # 対象 (project) と時間が読めない印は、管理対象と見なさない
    return "{\"id\":\"" id "\",\"project\":\"" jesc(p) "\",\"duration\":" d ",\"created\":\"" jesc(c) "\",\"goal\":\"" g "\"}"
  }
  BEGIN { first = 1; printf "["; pending = "" }
  {
    line = $0
    gsub(/^[ \t]+|[ \t]+$/, "", line)
    if (line == "") next
    mk = parse_marker(line)
    if (mk != "") { pending = mk; next }   # 印の行そのものはエントリにしない。直後の行に付ける
    meta = pending; pending = ""            # 印は直後の 1 行だけに有効 (cron__list と同じ)
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
    if (!okschedule(f)) next
    cmd = f[6]
    for (i = 7; i <= n; i++) cmd = cmd " " f[i]
    gsub(/\\/, "\\\\", cmd); gsub(/"/, "\\\"", cmd)
    if (!first) printf ","
    first = 0
    printf "{\"disabled\":%s,\"minute\":\"%s\",\"hour\":\"%s\",\"dom\":\"%s\",\"month\":\"%s\",\"dow\":\"%s\",\"command\":\"%s\"%s}", \
      (disabled ? "true" : "false"), f[1], f[2], f[3], f[4], f[5], cmd, (meta != "" ? ",\"claudeos\":" meta : "")
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
