#!/usr/bin/env bash
# ============================================================
# self-heal.sh — ログ → 原因分類 → 修復提案 (Self-Healing Software の観測層)
#
# 使い方:
#   self-heal.sh scan [--file LOG]... [--dir DIR]... [--since-hours N] [--json] [--out FILE]
#       ログと run-ledger の失敗を signature 単位へ正規化し、頻度順の診断 JSON を返す。
#       問題が見つかれば rc=1 (cron / CI のトリガとして使える)、無ければ rc=0。
#   self-heal.sh run [...scan と同じ...]         # scan して提案 (proposal) を state へ置く
#   self-heal.sh apply --proposal FILE --token T # allowlist 限定。既定 allowlist は空 = 常に拒否
#   self-heal.sh status [--json]
#
# 設計原則 (重要):
#   本番コードを自動で書き換えない。apply が実行できるのは allowlist に明示された
#   修復種別だけで、既定は空。したがって現状 apply は「承認 + allowlist 未設定」を理由に
#   必ず拒否する。修正の適用は人間が Approval PR で行う (CLAUDE.md §5)。
#
# 終了コード: 0 問題なし / 1 問題あり / 2 引数エラー / 3 拒否
# ============================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
# shellcheck source=lib/json.sh
source "$SCRIPT_DIR/../lib/json.sh"
# shellcheck source=lib/run-ledger.sh
source "$SCRIPT_DIR/../lib/run-ledger.sh"
# shellcheck source=lib/policy-engine.sh
source "$SCRIPT_DIR/../lib/policy-engine.sh"

require_cmd jq

SH_STATE_DIR="${CCSU_SELF_HEAL_STATE:-$CCSU_HOME/state/self-heal}"
SH_ALLOWLIST="${CCSU_SELF_HEAL_ALLOWLIST:-}"   # 例: "restart-supervisor,rotate-log"。既定は空。

sh__iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

usage() { sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

# sh__owner <text> — 症状から担当ロールを推定する (ヒューリスティック。断定ではない)
sh__owner() {
  local t; t="$(printf '%s' "$1" | tr 'A-Z' 'a-z')"
  case "$t" in
    *systemd*|*supervisor*|*cron*|*tmux*) printf 'ops' ;;
    *postgres*|*psql*|*migration*|*database*) printf 'ops' ;;
    *cloudflare*|*tunnel*|*dns*)      printf 'ops' ;;
    *secret*|*token*|*permission*|*auth*) printf 'security' ;;
    *test*|*bats*|*assert*)           printf 'qa' ;;
    *lint*|*shellcheck*)              printf 'developer' ;;
    *ci*|*workflow*|*github*)         printf 'ops' ;;
    *) printf 'developer' ;;
  esac
}

# sh__collect_lines <since_hours> <files...> — 期間内のエラー行を "file<TAB>line" で返す
sh__collect_lines() {
  local since_hours="$1"; shift
  local cutoff="" f
  if [[ "$since_hours" =~ ^[0-9]+$ ]] && (( since_hours > 0 )) && [[ -n "${SH_NOW_EPOCH:-}" ]]; then
    cutoff=$(( SH_NOW_EPOCH - since_hours * 3600 ))
  fi
  for f in "$@"; do
    [[ -f "$f" ]] || continue
    mtime="$(stat -c %Y "$f" 2>/dev/null || printf '0')"
    if [[ -n "$cutoff" && "$mtime" =~ ^[0-9]+$ ]] && (( mtime < cutoff )); then continue; fi
    grep -aiE '(error|fatal|traceback|❌|\[err *\]|failed|timeout|refused|denied)' "$f" 2>/dev/null \
      | while IFS= read -r line; do printf '%s\t%s\n' "$f" "$line"; done || true
  done
}

main_scan() {
  local since_hours=0 as_json=0 out="" run_mode="${1:-scan}"
  shift || true
  local files=() dirs=()
  while (( $# )); do
    case "$1" in
      --file) files+=("${2:-}"); shift 2 ;;
      --dir)  dirs+=("${2:-}");  shift 2 ;;
      --since-hours) since_hours="${2:-0}"; shift 2 ;;
      --json) as_json=1; shift ;;
      --out)  out="${2:-}"; shift 2 ;;
      *) shift ;;
    esac
  done

  # --file / --dir が指定されていればそれだけを見る (既定ディレクトリを勝手に足さない)
  if ((${#files[@]} == 0)) && ((${#dirs[@]} == 0)); then
    dirs=("$CCSU_ROOT/logs" "$CCSU_HOME/logs")
  fi
  local d lf
  for d in "${dirs[@]}"; do
    [[ -d "$d" ]] || continue
    while IFS= read -r lf; do
      [[ -n "$lf" ]] && files+=("$lf")
    done < <(find "$d" -maxdepth 2 -type f \( -name '*.log' -o -name '*.jsonl' \) 2>/dev/null | sort || true)
  done

  SH_NOW_EPOCH="$(date +%s)"
  # 明示 --file と --dir 展開の重複を排除 (同一ログを 2 回数えない)
  local uniq=() u
  if ((${#files[@]})); then
    while IFS= read -r u; do
      [[ -n "$u" ]] && uniq+=("$u")
    done < <(printf '%s\n' "${files[@]}" | awk '!seen[$0]++')
    files=("${uniq[@]}")
  fi

  local work
  work="$(mktemp "${TMPDIR:-/tmp}/self-heal.XXXXXX")"
  trap 'rm -f "$work"' RETURN

  sh__collect_lines "$since_hours" "${files[@]-}" > "$work" || true

  # run-ledger の失敗記録も signature として合流させる
  local fail_file; fail_file="$(rl_failures_file)"
  local failures='[]'
  [[ -f "$fail_file" ]] && failures="$(jq -s -c '[.[] | {signature, note, at, run_id, project}]' "$fail_file" 2>/dev/null || printf '[]')"

  local by_sig='{}'
  # ログ行を signature 集計へ
  local sig acc_note
  while IFS=$'\t' read -r src line; do
    [[ -n "${line:-}" ]] || continue
    sig="$(rl_signature "$line")"
    by_sig="$(jq -cn --argjson acc "$by_sig" --arg sig "$sig" --arg src "$src" --arg line "$line" --arg at "$(sh__iso)" \
      '$acc | .[$sig] = (($acc[$sig] // {signature:$sig, count:0, sources:[], samples:[]})
        | .count = (.count + 1)
        | .sources = ((.sources + [$src]) | unique)
        | .samples = ((.samples + [$line]) | unique | .[:3])
        | .last_at = $at
        | .first_at = (.first_at // $at))')"
  done < "$work"

  # run-ledger の失敗を合算
  local n i
  n="$(printf '%s' "$failures" | jq 'length')"
  for (( i = 0; i < n; i++ )); do
    sig="$(printf '%s' "$failures" | jq -r ".[$i].signature")"
    acc_note="$(printf '%s' "$failures" | jq -r ".[$i].note")"
    [[ -n "$sig" ]] || continue
    by_sig="$(jq -cn --argjson acc "$by_sig" --arg sig "$sig" --arg note "$acc_note" --arg at "$(sh__iso)" \
      '$acc | .[$sig] = (($acc[$sig] // {signature:$sig, count:0, sources:[], samples:[]})
        | .count = (.count + 1)
        | .sources = ((.sources + ["run-ledger:failures.jsonl"]) | unique)
        | .samples = ((.samples + [$note]) | unique | .[:3])
        | .last_at = $at
        | .first_at = (.first_at // $at))')"
  done

  local issues
  issues="$(printf '%s' "$by_sig" | jq -c '[.[] | . + {candidate_owner: null}] | sort_by(-.count)')"
  # candidate_owner を bash 側で付ける (jq に bash 関数は渡せないため)
  local sigs
  sigs="$(printf '%s' "$issues" | jq -r '.[].signature')"
  for sig in $sigs; do
    local smp own
    smp="$(printf '%s' "$issues" | jq -r --arg s "$sig" '.[] | select(.signature==$s) | .samples[0] // ""')"
    own="$(sh__owner "$smp")"
    issues="$(printf '%s' "$issues" | jq -c --arg s "$sig" --arg o "$own" '[.[] | if .signature==$s then .candidate_owner=$o else . end]')"
  done

  local issue_count; issue_count="$(printf '%s' "$issues" | jq 'length')"
  local report
  report="$(jq -cn --arg schema "claudeos.self-heal-report/v1" --arg at "$(sh__iso)" \
    --argjson inputs "$(printf '%s\n' "${files[@]-}" | jq -R -s 'split("\n") | map(select(. != ""))')" \
    --argjson issue_count "$issue_count" --argjson issues "$issues" \
    --argjson allowlist "$(jq -Rn --arg s "$SH_ALLOWLIST" '$s | split(",") | map(select(. != ""))')" \
    '{schema:$schema, generated_at:$at, inputs:$inputs, issue_count:$issue_count, issues:$issues,
      remediation:{mode:"propose-only", allowlist:$allowlist,
                   note:"自動適用はしない。apply は allowlist に一致する種別 + 承認トークンが必要"}}')"

  if [[ -n "$out" ]]; then
    mkdir -p "$(dirname "$out")"
    printf '%s\n' "$report" | jq . > "$out"
  fi

  if [[ "$run_mode" == "run" ]]; then
    mkdir -p "$SH_STATE_DIR"
    printf '%s\n' "$report" > "$SH_STATE_DIR/latest.json"
    if (( issue_count > 0 )); then
      # 提案 (proposal) を残す。適用は人間が Approval PR で行う。
      printf '%s\n' "$report" | jq -c '{schema:"claudeos.self-heal-proposal/v1", created_at:.generated_at,
        targets:[.issues[] | {signature, count, candidate_owner, samples}], apply:"human-approval-required"}' \
        > "$SH_STATE_DIR/proposal-$(date -u +%Y%m%dT%H%M%SZ).json"
    fi
  fi

  if (( as_json )); then
    printf '%s\n' "$report" | jq -c .
  else
    printf '%s\n' "$report" | jq -r '"issues=\(.issue_count)"'
    printf '%s\n' "$report" | jq -r '.issues[] | "  [\(.count)] \(.signature)  owner=\(.candidate_owner)\n      \((.samples[0] // "")[0:120])"'
  fi
  (( issue_count > 0 )) && return 1 || return 0
}

case "${1:-}" in
  scan)   main_scan scan "${@:2}" ;;
  run)    main_scan run "${@:2}" ;;
  apply)
    shift
    prop=""; token=""
    while (( $# )); do
      case "$1" in
        --proposal) prop="${2:-}"; shift 2 ;;
        --token)    token="${2:-}"; shift 2 ;;
        *) shift ;;
      esac
    done
    [[ -n "$prop" ]] || die "--proposal が必要です"
    [[ -f "$prop" ]] || die "提案ファイルがありません: $prop"
    kind="$(json_get "$prop" '.kind' '')"
    if [[ -z "$SH_ALLOWLIST" ]]; then
      log_error "self-heal: allowlist が空です。自動適用は行いません (CCSU_SELF_HEAL_ALLOWLIST で明示した種別のみ適用可)"
      exit 3
    fi
    if [[ -z "$token" ]]; then
      log_error "self-heal: 承認トークンが必要です (policy-check.sh issue cto)"
      exit 3
    fi
    if ! policy_decision self-heal edit:src --token "$token" | jq -e '.decision=="allow"' >/dev/null; then
      log_error "self-heal: 承認が拒否されました (改善者以外の承認が必要)"
      exit 3
    fi
    if ! printf '%s' "$SH_ALLOWLIST" | tr ',' '\n' | grep -qx "$kind"; then
      log_error "self-heal: allowlist に無い種別です: ${kind:-<empty>}"
      exit 3
    fi
    log_warn "self-heal: allowlist 一致のため適用します (kind=$kind)"
    ;;
  status)
    mkdir -p "$SH_STATE_DIR"
    if [[ -f "$SH_STATE_DIR/latest.json" ]]; then
      if [[ "${2:-}" == "--json" ]]; then jq -c . "$SH_STATE_DIR/latest.json"; else jq -r '"issue_count=\(.issue_count) generated_at=\(.generated_at)"' "$SH_STATE_DIR/latest.json"; fi
    else
      log_info "まだ診断結果がありません (self-heal.sh scan)"
    fi
    ;;
  ""|-h|--help|help) usage ;;
  *) log_error "不明なサブコマンド: ${1:-}"; usage; exit 2 ;;
esac
