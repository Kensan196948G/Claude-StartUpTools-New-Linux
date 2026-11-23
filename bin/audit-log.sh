#!/usr/bin/env bash
# ============================================================
# audit-log.sh — Web スタートアップコンソールの監査ログ (JSONL) を読む
#
# 対象: <CLAUDEOS_HOME>/logs/web-startup-audit.log + その世代 (.1 〜 .3)
#   1 リクエスト 1 行の JSONL。世代は #186 のサイズローテーションで作られ、
#   「無印が最新、.1 がその前、.2 がさらに前、…」の順に古くなる。
#   → 本ツールは .3 → .2 → .1 → 無印 の順（時系列の古い順）に連結する。
#
# 使い方:
#   audit-log.sh [--tail N] [--action NAME] [--since ISO|YYYY-MM-DD] [--json] [--files]
#                [--home DIR]
#
#   --tail N    最後の N 行だけ出す（既定 20）。--action/--since で絞った後の末尾。
#   --action N  action フィールドの完全一致で絞る（例: ops-restart）。部分一致しない。
#   --since T   ts フィールドで絞る（この時刻以降）。YYYY-MM-DD / ISO8601 可。
#               タイムゾーン省略時はローカル時刻として解釈し UTC に正規化する。
#   --json      最終行に 1 行の機械可読サマリを出す（それ以外は 1 行 1 JSON）。
#   --files     世代ファイルの一覧とサイズを出す（読み取りのみ。中身は出さない）。
#   --home DIR  CLAUDEOS_HOME を上書き（既定: $CLAUDEOS_HOME か ~/.claudeos）。
#   -h, --help  このヘルプ。
#
# 出力:
#   既定は 1 行 1 JSON（壊れた行はスキップ。スキップ件数は stderr に警告）。
#   --json の最終行:
#     {"ok":true,"lines":N,"files":M,"matched":K,"shown":S,"skipped":B,
#      "first":"<ts>","last":"<ts>"}
#     lines   = 読めた有効行数 / files = 読んだ世代ファイル数
#     matched = 絞り込み後に一致した行数 / shown = 実際に出力した行数
#     skipped = JSON でない・オブジェクトでない行数（壊れた行）
#     生のレコード値（remote / goal 等）はサマリに含めない（ts の範囲のみ）。
#
# 安全:
#   - **読み取り専用**。ログの書き換え・削除・ローテーションを行わない。
#   - jq を必須にする（無ければ exit 1）。壊れた行があっても落ちない。
#
# exit: 0 成功 / 1 ログが無い・読めない・jq が無い / 2 引数エラー
#
# テスト差し替え:
#   CCSU_JQ_BIN          jq 実体（既定 jq）
#   CCSU_AUDIT_LOG_KEEP  世代数（既定 3。.1 〜 .N を読む）
# ============================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

AL_JQ="${CCSU_JQ_BIN:-jq}"
AL_LOG_NAME="web-startup-audit.log"
AL_KEEP="${CCSU_AUDIT_LOG_KEEP:-3}"
AL_HOME="${CLAUDEOS_HOME:-$HOME/.claudeos}"
AL_LOG=""
AL_TAIL=20
AL_ACTION=""
AL_SINCE=""
AL_JSON=0
AL_FILES=0
AL_TMP=""

usage() {
  cat <<'EOF'
audit-log.sh — Web スタートアップコンソールの監査ログ (JSONL) を読む

使い方:
  audit-log.sh [--tail N] [--action NAME] [--since ISO|YYYY-MM-DD] [--json] [--files] [--home DIR]

  --tail N    最後の N 行 (既定 20)。--action / --since で絞った後の末尾 N 行。
  --action N  action の完全一致で絞る (例: ops-restart, ops-plan-rejected)
  --since T   ts が T 以降の行 (YYYY-MM-DD または ISO8601。TZ 省略時はローカル→UTC)
  --json      最終行に 1 行サマリを出す (それ以外は 1 行 1 JSON)
  --files     世代ファイルの一覧とサイズを出す (読み取りのみ)
  --home DIR  CLAUDEOS_HOME を上書き (既定: $CLAUDEOS_HOME か ~/.claudeos)
  -h, --help  このヘルプ

対象: <home>/logs/web-startup-audit.log と .1 〜 .3 (古い順に連結: .3 → .2 → .1 → 無印)
出力: 1 行 1 JSON。壊れた行はスキップし、件数を stderr に出す。
exit: 0 成功 / 1 ログ無し・読めない・jq 無し / 2 引数エラー
読み取り専用 (ログを書き換えない)。
EOF
}

bad_args() {
  log_error "$*"
  usage >&2
  exit 2
}

# al__normalize_since <value> — --since を UTC の ISO8601 (ミリ秒 3 桁, Z) へ正規化
#   形式不正は exit 2。タイムゾーン省略時はローカル時刻として解釈する。
al__normalize_since() {
  local s="$1" norm=""
  if [[ ! "$s" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}([T\ ][0-9]{2}:[0-9]{2}(:[0-9]{2})?(\.[0-9]{1,9})?(Z|[+-][0-9]{2}:?[0-9]{2})?)?$ ]]; then
    bad_args "--since の形式が不正です: $s (YYYY-MM-DD または ISO8601)"
  fi
  norm="$(date -u -d "$s" '+%Y-%m-%dT%H:%M:%S.%3NZ' 2>/dev/null)" || bad_args "--since を解釈できません: $s"
  printf '%s' "$norm"
}

# al__collect_files <log> <keep> — 存在する世代を古い順に出力 (.keep → … → .1 → 無印)
al__collect_files() {
  local log="$1" keep="$2" i f
  for ((i = keep; i >= 1; i--)); do
    f="$log.$i"
    if [[ -f "$f" ]]; then printf '%s\n' "$f"; fi
  done
  if [[ -f "$log" ]]; then printf '%s\n' "$log"; fi
  return 0
}

# al__files_report — --files: 一覧とサイズ（中身は出さない）
al__files_report() {
  local -a files=()
  local f bytes lines total=0 count=0
  local json_rows="$AL_TMP/files.jsonl"
  mapfile -t files < <(al__collect_files "$AL_LOG" "$AL_KEEP")

  if (( ${#files[@]} == 0 )); then
    log_error "監査ログが見つかりません: $AL_LOG (home=$AL_HOME)"
    return 1
  fi

  : > "$json_rows"
  if (( AL_JSON == 0 )); then
    printf '%-52s %10s %8s\n' "FILE" "BYTES" "LINES"
  fi
  for f in "${files[@]}"; do
    bytes="$(stat -c '%s' "$f" 2>/dev/null || printf '0')"
    lines="$(wc -l < "$f" 2>/dev/null | tr -d ' ' || printf '0')"
    total=$(( total + bytes ))
    count=$(( count + 1 ))
    if (( AL_JSON == 0 )); then
      printf '%-52s %10s %8s\n' "$(basename "$f")" "$bytes" "$lines"
    fi
    printf '%s\n' "$(jq -n -c --arg name "$(basename "$f")" --argjson bytes "$bytes" --argjson lines "$lines" \
      '{name:$name, bytes:$bytes, lines:$lines}')" >> "$json_rows"
  done

  if (( AL_JSON == 1 )); then
    jq -n -c --argjson total "$total" --argjson count "$count" \
      --slurpfile gens "$json_rows" \
      '{ok:true, files:$count, total_bytes:$total, generations:$gens}'
  fi
  return 0
}

# al__read — ログを古い順に連結して絞り込み、1 行 1 JSON で出力する
al__read() {
  local -a files=()
  local total=0 valid=0 skipped=0 matched=0 shown_count=0
  local first="" last="" shown=""
  local all="$AL_TMP/all.jsonl" parsed="$AL_TMP/parsed.json"
  local filtered="$AL_TMP/filtered.json"
  mapfile -t files < <(al__collect_files "$AL_LOG" "$AL_KEEP")

  if (( ${#files[@]} == 0 )); then
    log_error "監査ログが見つかりません: $AL_LOG (home=$AL_HOME)"
    return 1
  fi

  if ! cat "${files[@]}" > "$all" 2>/dev/null; then
    log_error "監査ログを読めません: $AL_LOG"
    return 1
  fi

  # 総行数（末尾に改行が無い行も数える）
  total="$(awk 'END { print NR + 0 }' "$all")"
  # 各行を JSON として解釈し、オブジェクトだけを残す（壊れた行・空行は捨てる）
  jq -R -s -c 'split("\n") | map(fromjson?) | map(select(type == "object"))' "$all" > "$parsed"
  valid="$(jq 'length' "$parsed")"
  skipped=$(( total - valid ))

  if (( skipped > 0 )); then
    log_warn "壊れた行 (JSON でない/オブジェクトでない) を ${skipped} 件スキップしました"
  fi

  # 絞り込み: action は完全一致、since は ts の辞書順比較 (ISO8601 固定幅)
  jq -c --arg a "$AL_ACTION" --arg s "$AL_SINCE" '
    map(select(
      (($a == "") or ((.action | tostring) == $a))
      and (($s == "") or ((.ts // "") >= $s))
    ))' "$parsed" > "$filtered"
  matched="$(jq 'length' "$filtered")"
  shown_count="$(jq -c --argjson n "$AL_TAIL" '.[-($n):] | length' "$filtered")"
  shown="$(jq -c --argjson n "$AL_TAIL" '.[-($n):] | .[]' "$filtered")"
  if [[ -n "$shown" ]]; then
    printf '%s\n' "$shown"
  fi

  first="$(jq -r '[.[].ts | select(type == "string")] | (.[0] // "")' "$filtered")"
  last="$(jq -r '[.[].ts | select(type == "string")] | (.[-1] // "")' "$filtered")"

  if (( AL_JSON == 1 )); then
    jq -n -c \
      --argjson lines "$valid" --argjson files "${#files[@]}" \
      --argjson matched "$matched" --argjson shown "$shown_count" \
      --argjson skipped "$skipped" --arg first "$first" --arg last "$last" \
      '{ok:true, lines:$lines, files:$files, matched:$matched, shown:$shown,
        skipped:$skipped, first:$first, last:$last}'
  fi
  return 0
}

main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --tail)   [[ $# -ge 2 ]] || bad_args "--tail には値が必要です"; AL_TAIL="$2"; shift 2 ;;
      --action) [[ $# -ge 2 ]] || bad_args "--action には値が必要です"; AL_ACTION="$2"; shift 2 ;;
      --since)  [[ $# -ge 2 ]] || bad_args "--since には値が必要です"; AL_SINCE="$2"; shift 2 ;;
      --home)   [[ $# -ge 2 ]] || bad_args "--home には値が必要です"; AL_HOME="$2"; shift 2 ;;
      --json)   AL_JSON=1; shift ;;
      --files)  AL_FILES=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) bad_args "不明な引数: $1" ;;
    esac
  done

  [[ "$AL_TAIL" =~ ^[1-9][0-9]*$ ]] || bad_args "--tail は 1 以上の整数で指定してください: $AL_TAIL"
  [[ "$AL_KEEP" =~ ^[0-9]+$ ]] || AL_KEEP=3
  if [[ -n "$AL_SINCE" ]]; then
    AL_SINCE="$(al__normalize_since "$AL_SINCE")" || exit 2
  fi
  AL_LOG="$AL_HOME/logs/$AL_LOG_NAME"

  require_cmd "$AL_JQ" "apt install jq"

  AL_TMP="$(mktemp -d)"
  trap 'rm -rf "$AL_TMP"' EXIT

  if (( AL_FILES == 1 )); then
    al__files_report
  else
    al__read
  fi
}

main "$@"
