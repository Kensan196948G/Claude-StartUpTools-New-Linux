#!/usr/bin/env bash
# ============================================================
# computer-use.sh — GUI 観測と操作 (Computer Use / Multimodal Computer Use)
#
# 役割: 画面を見て操作する経路を、統制された形でだけ提供する。
#   - 判定順序は「1) ポリシー判定 → 2) 実行可能性 → 3) 実行」。承認が無ければ
#     画面を撮ることすらしない (撮影は情報取得であり、無断で行わせない)
#   - 実行する操作は allowlist の動詞のみ。プランは事前検証してから 1 ステップずつ
#   - 既定は dry-run。--confirm を付けた 1 ステップだけが実際に発火する
#     (無人ループを作らない。長時間の自動操作は plan を分割して人間が承認する)
#   - GUI が無い環境 (headless) では実行せず、理由付きで rc=3 を返す
#
# 使い方:
#   computer-use.sh probe                      # 環境診断 (display / 使用可能ツール)
#   computer-use.sh observe --out FILE [--token T]
#   computer-use.sh plan --file PLAN.json      # プラン検証 (実行しない)
#   computer-use.sh act --plan PLAN.json --step N [--token T] [--confirm]
#   computer-use.sh policy <action> [--token T]   # 判定だけ確認 (screen:capture|screen:input)
#
# プランの形式 (JSON):
#   { "schema": "claudeos.computer-use-plan/v1",
#     "steps": [ {"verb":"click","x":10,"y":20,"note":"..."}, {"verb":"type","text":"hello"} ] }
#
# 終了コード: 0 成功 / 1 ポリシー拒否 / 2 引数エラー / 3 利用不可・承認待ち / 4 プラン不正
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

CU_AGENT="computer-use"
CU_ALLOWED_VERBS="move click type key wait observe screenshot"
CU_LOG="${CCSU_COMPUTER_USE_LOG:-$CCSU_HOME/logs/computer-use.jsonl}"

cu__iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
cu__log() { json_append_line "$CU_LOG" "$1"; }

usage() { sed -n '2,27p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

cu__display_present() {
  [[ -n "${DISPLAY:-}" || -n "${WAYLAND_DISPLAY:-}" ]]
}

cu__tool() { command -v "$1" >/dev/null 2>&1; }

# cu__capture_tool — 画面取得に使えるツールを優先順で選ぶ
cu__capture_tool() {
  if cu__tool grim && [[ -n "${WAYLAND_DISPLAY:-}" ]]; then printf 'grim'; return 0; fi
  if cu__tool import; then printf 'import'; return 0; fi
  if cu__tool gnome-screenshot; then printf 'gnome-screenshot'; return 0; fi
  if cu__tool scrot; then printf 'scrot'; return 0; fi
  if cu__tool xwd; then printf 'xwd'; return 0; fi
  return 1
}

cmd_probe() {
  local display="${DISPLAY:-}" wayland="${WAYLAND_DISPLAY:-}" session="${XDG_SESSION_TYPE:-unknown}"
  local present=false
  cu__display_present && present=true
  local capture=""; capture="$(cu__capture_tool || true)"
  jq -cn --arg schema "claudeos.computer-use-probe/v1" \
    --arg display "$display" --arg wayland "$wayland" --arg session "$session" \
    --argjson present "$present" --arg capture "$capture" \
    --argjson xdotool "$(cu__tool xdotool && printf true || printf false)" \
    --argjson ydotool "$(cu__tool ydotool && printf true || printf false)" \
    --argjson wtype "$(cu__tool wtype && printf true || printf false)" \
    --arg note "$( [[ "$present" == "true" ]] && printf 'GUI セッションあり' || printf 'headless: 画面観測・入力は実行できない' )" \
    '{schema:$schema, display:$display, wayland_display:$wayland, session_type:$session,
      gui_available:$present, capture_tool:(if $capture=="" then null else $capture end),
      input_tools:{xdotool:$xdotool, ydotool:$ydotool, wtype:$wtype},
      note:$note}'
  [[ "$present" == "true" ]]
}

# cu__policy <action> [--token T] — ポリシー判定。allow 以外は理由を出して非 0
#   既定では判定理由を stdout/stderr へ出さない (呼び出し側の JSON 出力を汚さない)。
#   CCSU_COMPUTER_USE_VERBOSE=1 のときだけ stderr に 1 行出す。
cu__policy() {
  local action="$1"; shift || true
  local dec; dec="$(policy_decision "$CU_AGENT" "$action" "$@")"
  if [[ "${CCSU_COMPUTER_USE_VERBOSE:-0}" == "1" ]]; then
    printf '%s\n' "$dec" | jq -r '"\(.decision)\t\(.reasons|join(","))"' >&2
  fi
  case "$(printf '%s' "$dec" | jq -r '.decision')" in
    allow) return 0 ;;
    approval_required) return 3 ;;
    *) return 1 ;;
  esac
}

cmd_policy() {
  local action="${1:-}"; shift || true
  [[ -n "$action" ]] || { log_error "policy には action (screen:capture|screen:input) が必要です"; return 2; }
  policy_check "$CU_AGENT" "$action" "$@"
}

cmd_observe() {
  local out="" token=""
  while (( $# )); do
    case "$1" in
      --out)   out="${2:-}"; shift 2 ;;
      --token) token="${2:-}"; shift 2 ;;
      *) shift ;;
    esac
  done
  [[ -n "$out" ]] || { log_error "observe: --out が必要です"; return 2; }

  local -a tok=()
  [[ -n "$token" ]] && tok=(--token "$token")
  if ! cu__policy "screen:capture" "${tok[@]+"${tok[@]}"}"; then
    log_error "observe: ポリシーにより画面取得が許可されていません (承認トークンが必要: policy-check.sh issue cto)"
    return 3
  fi
  if ! cu__display_present; then
    log_error "observe: GUI がありません (headless)。DISPLAY/WAYLAND_DISPLAY 未設定"
    return 3
  fi
  local tool; tool="$(cu__capture_tool)" || { log_error "observe: 画面取得ツールがありません (grim/import/scrot/xwd)"; return 3; }
  mkdir -p "$(dirname "$out")"
  case "$tool" in
    grim)      grim "$out" ;;
    import)    import -window root "$out" ;;
    gnome-screenshot) gnome-screenshot -f "$out" ;;
    scrot)     scrot "$out" ;;
    xwd)       xwd -root -silent | convert xwd:- "$out" ;;
  esac
  cu__log "$(jq -cn --arg at "$(cu__iso)" --arg out "$out" --arg tool "$tool" '{at:$at, event:"observe", tool:$tool, out:$out}')"
  jq -cn --arg out "$out" --arg tool "$tool" '{ok:true, out:$out, capture_tool:$tool}'
}

# cu__validate_plan <file> — 検証済みのプラン (steps を verb 順に正規化) を stdout へ
cu__validate_plan() {
  local file="$1"
  [[ -f "$file" ]] || { log_error "プランがありません: $file"; return 4; }
  jq -e . "$file" >/dev/null 2>&1 || { log_error "プランが JSON ではありません: $file"; return 4; }
  [[ "$(json_get "$file" '.schema' '')" == "claudeos.computer-use-plan/v1" ]] || {
    log_error "プラン schema が不正です (claudeos.computer-use-plan/v1 が必要)"; return 4; }
  local n; n="$(json_get "$file" '.steps | length' '0')"
  [[ "$n" =~ ^[0-9]+$ ]] && (( n > 0 )) || { log_error "steps が空です"; return 4; }

  local i verb
  for (( i = 0; i < n; i++ )); do
    verb="$(json_get "$file" ".steps[$i].verb" '')"
    [[ -n "$verb" ]] || { log_error "steps[$i].verb がありません"; return 4; }
    if ! printf '%s\n' $CU_ALLOWED_VERBS | grep -qx "$verb"; then
      log_error "steps[$i].verb は allowlist 外です: $verb (許可: $CU_ALLOWED_VERBS)"; return 4
    fi
    case "$verb" in
      click|move)
        json_get "$file" ".steps[$i].x" '' | grep -Eq '^[0-9]+$' || { log_error "steps[$i] に x (整数) が必要です"; return 4; }
        json_get "$file" ".steps[$i].y" '' | grep -Eq '^[0-9]+$' || { log_error "steps[$i] に y (整数) が必要です"; return 4; }
        ;;
      type)
        json_get "$file" ".steps[$i].text" '' >/dev/null
        [[ "$(json_get "$file" ".steps[$i].text | type" 'null')" == "string" ]] || { log_error "steps[$i] に text (文字列) が必要です"; return 4; }
        ;;
      key)
        [[ -n "$(json_get "$file" ".steps[$i].keys" '')" ]] || { log_error "steps[$i] に keys が必要です"; return 4; }
        ;;
      wait)
        json_get "$file" ".steps[$i].seconds" '' | grep -Eq '^[0-9]+$' || { log_error "steps[$i] に seconds (整数) が必要です"; return 4; }
        ;;
    esac
  done
  jq -c '{schema, step_count:(.steps|length), steps:[.steps[] | {verb, x, y, text, keys, seconds, note}]}' "$file"
}

cmd_plan() {
  local file="" 
  while (( $# )); do
    case "$1" in --file) file="${2:-}"; shift 2 ;; *) shift ;; esac
  done
  [[ -n "$file" ]] || { log_error "plan: --file が必要です"; return 2; }
  local validated; validated="$(cu__validate_plan "$file")" || return $?
  printf '%s\n' "$validated"
}

cmd_act() {
  local plan="" step=-1 token="" confirm=0
  while (( $# )); do
    case "$1" in
      --plan)    plan="${2:-}"; shift 2 ;;
      --step)    step="${2:--1}"; shift 2 ;;
      --token)   token="${2:-}"; shift 2 ;;
      --confirm) confirm=1; shift ;;
      *) shift ;;
    esac
  done
  [[ -n "$plan" ]] || { log_error "act: --plan が必要です"; return 2; }
  [[ "$step" =~ ^[0-9]+$ ]] || { log_error "act: --step は 0 以上の整数 (1 回に 1 ステップだけ実行)"; return 2; }

  local validated; validated="$(cu__validate_plan "$plan")" || return $?
  local n; n="$(printf '%s' "$validated" | jq -r '.step_count')"
  (( step < n )) || { log_error "act: --step $step は範囲外 (0..$((n-1)))"; return 2; }
  local verb; verb="$(printf '%s' "$validated" | jq -r --argjson i "$step" '.steps[$i].verb')"

  # 1) ポリシー (画面入力は承認必須)
  local -a tok=()
  [[ -n "$token" ]] && tok=(--token "$token")
  if ! cu__policy "screen:input" "${tok[@]+"${tok[@]}"}"; then
    log_error "act: ポリシーにより GUI 操作が許可されていません (承認トークンが必要)"
    return 3
  fi
  # 2) 実行可能性
  if ! cu__display_present; then
    log_error "act: GUI がありません (headless)。実行できません"
    return 3
  fi
  # 3) 実行 (既定は dry-run)
  local detail
  detail="$(printf '%s' "$validated" | jq -c --argjson i "$step" '.steps[$i]')"
  if (( ! confirm )); then
    cu__log "$(jq -cn --arg at "$(cu__iso)" --argjson step "$step" --arg verb "$verb" '{at:$at, event:"act_dry_run", step:$step, verb:$verb}')"
    jq -cn --argjson step "$step" --arg verb "$verb" --argjson detail "$detail" \
      '{ok:false, dry_run:true, step:$step, verb:$verb, detail:$detail, hint:"実行するには --confirm を付ける"}'
    return 0
  fi
  case "$verb" in
    wait)
      sleep "$(printf '%s' "$detail" | jq -r '.seconds')" ;;
    observe|screenshot)
      log_warn "act: $verb は observe サブコマンドを使ってください"; return 2 ;;
    *)
      cu__tool xdotool || { log_error "act: xdotool がありません"; return 3; }
      case "$verb" in
        move)  xdotool mousemove "$(printf '%s' "$detail" | jq -r '.x')" "$(printf '%s' "$detail" | jq -r '.y')" ;;
        click) xdotool mousemove "$(printf '%s' "$detail" | jq -r '.x')" "$(printf '%s' "$detail" | jq -r '.y')" click 1 ;;
        type)  xdotool type --delay 20 -- "$(printf '%s' "$detail" | jq -r '.text')" ;;
        key)   xdotool key -- "$(printf '%s' "$detail" | jq -r '.keys')" ;;
      esac
      ;;
  esac
  cu__log "$(jq -cn --arg at "$(cu__iso)" --argjson step "$step" --arg verb "$verb" '{at:$at, event:"act_confirmed", step:$step, verb:$verb}')"
  jq -cn --argjson step "$step" --arg verb "$verb" '{ok:true, executed:true, step:$step, verb:$verb}'
}

case "${1:-}" in
  probe)   cmd_probe ;;
  observe) shift; cmd_observe "$@" ;;
  plan)    shift; cmd_plan "$@" ;;
  act)     shift; cmd_act "$@" ;;
  policy)  shift; cmd_policy "$@" ;;
  ""|-h|--help|help) usage ;;
  *) log_error "不明なサブコマンド: ${1:-}"; usage; exit 2 ;;
esac
