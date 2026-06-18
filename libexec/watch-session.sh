#!/usr/bin/env bash
# ============================================================
# watch-session.sh — セッション状態監視 / 操作 (メニュー項15)
#
# 対話モード (既定): 実行中 headless セッションを番号付きで列挙し、
#   番号選択 → [l]ログ/[s]停止 を選べる。tmux は --tmux 明示時だけ表示する。
# --once: 非対話の1回表示 (bats用)。
# ============================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
# shellcheck source=lib/json.sh
source "$SCRIPT_DIR/../lib/json.sh"

TMUX_BIN="${CCSU_TMUX_BIN:-tmux}"
_SUP_DIR="${CCSU_SUP_DIR:-${CCSU_HOME}/supervisor}"
_FG_DIR="${CCSU_FOREGROUND_DIR:-${CCSU_HOME}/foreground}"

terminal__open_command() {
  local title="$1" command="$2"

  [[ "${CCSU_DISABLE_TERMINAL_TAB:-0}" == "1" ]] && return 1

  local wt_bin=""
  if [[ -n "${CCSU_WT_BIN:-}" ]]; then
    wt_bin="$CCSU_WT_BIN"
  elif has_cmd wt.exe; then
    wt_bin="$(command -v wt.exe)"
  fi
  if [[ -n "$wt_bin" ]]; then
    if has_cmd wsl.exe; then
      if [[ -n "${WSL_DISTRO_NAME:-}" ]]; then
        "$wt_bin" -w 0 new-tab --title "$title" wsl.exe -d "$WSL_DISTRO_NAME" --cd "$PWD" bash -lc "$command" >/dev/null 2>&1 &
      else
        "$wt_bin" -w 0 new-tab --title "$title" wsl.exe --cd "$PWD" bash -lc "$command" >/dev/null 2>&1 &
      fi
    else
      "$wt_bin" -w 0 new-tab --title "$title" bash -lc "$command" >/dev/null 2>&1 &
    fi
    disown 2>/dev/null || true
    return 0
  fi

  [[ -n "${DISPLAY:-}" || -n "${WAYLAND_DISPLAY:-}" ]] || return 1

  if has_cmd gnome-terminal; then
    gnome-terminal --tab --title="$title" -- bash -lc "$command" >/dev/null 2>&1 &
  elif has_cmd konsole; then
    konsole --new-tab -p "tabtitle=$title" -e bash -lc "$command" >/dev/null 2>&1 &
  elif has_cmd xfce4-terminal; then
    local cmd
    printf -v cmd 'bash -lc %q' "$command"
    xfce4-terminal --tab --title="$title" --command="$cmd" >/dev/null 2>&1 &
  elif has_cmd mate-terminal; then
    mate-terminal --tab --title="$title" -- bash -lc "$command" >/dev/null 2>&1 &
  elif has_cmd tilix; then
    tilix --new-process --title="$title" -e bash -lc "$command" >/dev/null 2>&1 &
  elif has_cmd x-terminal-emulator; then
    x-terminal-emulator -T "$title" -e bash -lc "$command" >/dev/null 2>&1 &
  elif has_cmd xterm; then
    xterm -T "$title" -e bash -lc "$command" >/dev/null 2>&1 &
  else
    return 1
  fi
  disown 2>/dev/null || true
}

terminal__unavailable_hint() {
  if ! has_cmd wt.exe && [[ -z "${CCSU_WT_BIN:-}" ]] && [[ -z "${DISPLAY:-}" && -z "${WAYLAND_DISPLAY:-}" ]]; then
    printf 'wt.exe 未検出かつ Linux GUI DISPLAY 未設定です。WSL ではない Linux/SSH 環境からクライアント側 Windows Terminal タブは自動生成できません。'
  elif ! has_cmd wt.exe && [[ -z "${CCSU_WT_BIN:-}" ]]; then
    printf 'wt.exe 未検出です。Linux GUI 端末も対応コマンドが見つかりません。'
  else
    printf '対応する端末起動コマンドでタブ作成に失敗しました。'
  fi
}

# 実行中の claudeos-* tmux セッション名 (1行1名)
_running_tmux_sessions() {
  "$TMUX_BIN" ls 2>/dev/null | grep '^claudeos-' | cut -d: -f1 || true
}

# headless supervisor で実行中のプロジェクト名 (status=running かつ PID 生存)
_running_headless_projects() {
  [[ -d "$_SUP_DIR" ]] || return 0
  local f proj pid
  for f in "$_SUP_DIR"/*.json; do
    [[ -f "$f" ]] || continue
    [[ "$(json_get "$f" '.status' '')" == "running" ]] || continue
    proj="$(json_get "$f" '.project' '')"
    pid="$(json_get "$f" '.pid' '0')"
    [[ -n "$proj" && "$pid" != "0" ]] || continue
    kill -0 "$pid" 2>/dev/null && printf '%s\n' "$proj" || true
  done
}

_running_foreground_projects() {
  [[ -d "$_FG_DIR" ]] || return 0
  local f proj pid
  for f in "$_FG_DIR"/*.json; do
    [[ -f "$f" ]] || continue
    [[ "$(json_get "$f" '.status' '')" == "running" ]] || continue
    proj="$(json_get "$f" '.project' '')"
    pid="$(json_get "$f" '.pid' '0')"
    [[ -n "$proj" && "$pid" != "0" ]] || continue
    kill -0 "$pid" 2>/dev/null && printf '%s\n' "$proj" || true
  done
}

# 最近のセッション履歴 (最新15件)
_render_history() {
  local sdir="$1" f n=0
  printf '  %s最近のセッション履歴 (最新15件):%s\n' "$C_CYAN" "$C_RESET"
  while IFS= read -r f; do
    [[ -f "$f" ]] || continue
    n=$((n + 1))
    printf '      %-30s %-10s %s\n' \
      "$(json_get "$f" '.project' '?')" \
      "$(json_get "$f" '.status' '?')" \
      "$(json_get "$f" '.start_time' '?')"
  done < <(ls -t "$sdir"/*.json 2>/dev/null | head -15)
  if (( n == 0 )); then printf '      (記録なし)\n'; fi
  return 0
}

# 非対話表示 (--once / bats)
_render_once() {
  local sdir="$1" show_tmux="${2:-0}"
  local hp; hp="$(_running_headless_projects)"
  local fp; fp="$(_running_foreground_projects)"
  printf '  %s● 実行中の ClaudeOS セッション (foreground 🖥):%s\n' "$C_GREEN" "$C_RESET"
  if [[ -n "$fp" ]]; then
    printf '%s\n' "$fp" | sed 's/^/      🖥  /'
  else
    printf '      (実行中なし)\n'
  fi
  printf '\n'
  printf '  %s● 実行中の ClaudeOS セッション (headless 🤖):%s\n' "$C_GREEN" "$C_RESET"
  if [[ -n "$hp" ]]; then
    printf '%s\n' "$hp" | sed 's/^/      🤖 /'
  else
    printf '      (実行中なし)\n'
  fi
  if (( show_tmux )) && has_cmd "$TMUX_BIN"; then
    printf '\n  %s● 実行中の ClaudeOS セッション (tmux 🖥):%s\n' "$C_GREEN" "$C_RESET"
    local r; r="$(_running_tmux_sessions)"
    if [[ -n "$r" ]]; then
      printf '%s\n' "$r" | sed 's/^/      🖥  /'
    else
      printf '      (実行中なし)\n'
    fi
  fi
  printf '\n'
  _render_history "$sdir"
}

# headless セッション操作: [a]接続 / [l]ログ追尾 / [s]停止 / [k]即停止 / [c]キャンセル
_session_action_headless() {
  local proj="$1"
  local safe; safe="$(ccsu_safe_name "$proj")"
  local supjson="$_SUP_DIR/${safe}.json"
  local suplog="$_SUP_DIR/${safe}.log"
  local started cost
  started="$(json_get "$supjson" '.started_at' '?')"
  cost="$(json_get "$supjson" '.month_spent_usd' '?')"

  printf '\n  選択: %s🤖 %s%s  [headless]\n' "$C_GREEN" "$proj" "$C_RESET"
  printf '    起動: %s   当月コスト: $%s\n' "$started" "$cost"
  printf '    %s[a]%s 接続(新規タブ)   %s[l]%s ログ追尾   %s[s]%s 停止   %s[k]%s 即停止   %s[c]%s キャンセル\n' \
    "$C_YELLOW" "$C_RESET" "$C_YELLOW" "$C_RESET" "$C_YELLOW" "$C_RESET" "$C_RED" "$C_RESET" "$C_WHITE" "$C_RESET"
  local op; read -rp "  操作: " op
  case "${op,,}" in
    a)
      if [[ -f "$suplog" ]]; then
        local q cmd
        printf -v q '%q' "$suplog"
        cmd="tail -n 80 -f $q"
        if terminal__open_command "Claude log: $proj" "$cmd"; then
          log_ok "新規端末タブで接続しました: $proj"
        else
          log_warn "新規端末タブを開けませんでした: $(terminal__unavailable_hint)"
          log_warn "現在の端末でログ追尾します。"
          tail -n 80 -f "$suplog" || true
        fi
      else
        log_warn "ログファイルが見つかりません: $suplog"
      fi
      sleep 1 ;;
    l)
      if [[ -f "$suplog" ]]; then
        tail -n 80 -f "$suplog" || true
      else
        log_warn "ログファイルが見つかりません: $suplog"
      fi
      sleep 1 ;;
    s)
      log_info "停止中: $proj"
      if bash "$SCRIPT_DIR/../bin/autonomy.sh" stop "$proj"; then
        log_ok "停止しました: $proj"
      else
        log_warn "停止に失敗しました: $proj"
      fi
      sleep 1 ;;
    k)
      log_warn "即停止中: $proj"
      if bash "$SCRIPT_DIR/../bin/autonomy.sh" stop "$proj" --now; then
        log_ok "即停止しました: $proj"
      else
        log_warn "停止に失敗しました: $proj"
      fi
      sleep 1 ;;
    *) : ;;
  esac
}

_session_action_foreground() {
  local proj="$1"
  local safe; safe="$(ccsu_safe_name "$proj")"
  local fgjson="$_FG_DIR/${safe}.json"
  local started pid
  started="$(json_get "$fgjson" '.started_at' '?')"
  pid="$(json_get "$fgjson" '.pid' '?')"

  printf '\n  選択: %s🖥  %s%s  [foreground]\n' "$C_GREEN" "$proj" "$C_RESET"
  printf '    起動: %s   pid=%s\n' "$started" "$pid"
  printf '    %s[c]%s 接続情報   %s[k]%s 即停止   %s[x]%s キャンセル\n' \
    "$C_YELLOW" "$C_RESET" "$C_RED" "$C_RESET" "$C_WHITE" "$C_RESET"
  local op; read -rp "  操作: " op
  case "${op,,}" in
    c) log_info "foreground TUI は起動済みの端末タブで操作してください: $proj"; sleep 2 ;;
    k)
      if [[ "$pid" =~ ^[0-9]+$ ]] && kill "$pid" 2>/dev/null; then
        log_ok "停止しました: $proj"
      else
        log_warn "停止できませんでした: $proj"
      fi
      sleep 1 ;;
    *) : ;;
  esac
}

_connect_project() {
  local proj="$1"
  local safe; safe="$(ccsu_safe_name "$proj")"
  local supjson="$_SUP_DIR/${safe}.json"
  local suplog="$_SUP_DIR/${safe}.log"
  local fgjson="$_FG_DIR/${safe}.json"
  local pid q cmd

  if [[ -f "$fgjson" ]] && [[ "$(json_get "$fgjson" '.status' '')" == "running" ]]; then
    pid="$(json_get "$fgjson" '.pid' '0')"
    if [[ "$pid" != "0" ]] && kill -0 "$pid" 2>/dev/null; then
      log_info "foreground TUI は既に開いている端末タブで操作してください: $proj"
      return 0
    fi
  fi

  if [[ -f "$supjson" ]] && [[ "$(json_get "$supjson" '.status' '')" == "running" ]]; then
    pid="$(json_get "$supjson" '.pid' '0')"
    if [[ "$pid" != "0" ]] && kill -0 "$pid" 2>/dev/null; then
      if [[ -f "$suplog" ]]; then
        printf -v q '%q' "$suplog"
        cmd="tail -n 80 -f $q"
        if terminal__open_command "Claude log: $proj" "$cmd"; then
          log_ok "新規端末タブで接続しました: $proj"
        else
          log_warn "新規端末タブを開けませんでした: $(terminal__unavailable_hint)"
          log_warn "現在の端末でログ追尾します。"
          tail -n 80 -f "$suplog" || true
        fi
        return 0
      fi
      log_warn "ログファイルが見つかりません: $suplog"
      return 1
    fi
  fi

  if has_cmd "$TMUX_BIN" && "$TMUX_BIN" has-session -t "claudeos-$safe" 2>/dev/null; then
    printf -v q '%q' "claudeos-$safe"
    cmd="$(printf '%q' "$TMUX_BIN") attach -t $q"
    if terminal__open_command "tmux: claudeos-$safe" "$cmd"; then
      log_ok "新規端末タブで接続しました: claudeos-$safe"
    else
      "$TMUX_BIN" attach -t "claudeos-$safe" || true
    fi
    return 0
  fi

  log_warn "実行中セッションが見つかりません: $proj"
  return 1
}

# tmux セッション操作: [a]接続 / [s]停止 / [c]キャンセル
_session_action_tmux() {
  local s="$1" safe="${1#claudeos-}"
  printf '\n  選択: %s🖥  %s%s  [tmux]\n' "$C_GREEN" "$s" "$C_RESET"
  printf '    %s[a]%s 接続(attach)   %s[s]%s 停止(kill)   %s[c]%s キャンセル\n' \
    "$C_YELLOW" "$C_RESET" "$C_YELLOW" "$C_RESET" "$C_WHITE" "$C_RESET"
  local op; read -rp "  操作: " op
  case "${op,,}" in
    a)
       local q cmd
       printf -v q '%q' "$s"
       cmd="$(printf '%q' "$TMUX_BIN") attach -t $q"
       if terminal__open_command "tmux: $s" "$cmd"; then
         log_ok "新規端末タブで接続しました: $s"
       else
         log_warn "新規端末タブを開けませんでした: $(terminal__unavailable_hint)"
         log_warn "現在の端末で接続します。"
         "$TMUX_BIN" attach -t "$s" || true
       fi
       sleep 1 ;;
    s) if "$TMUX_BIN" kill-session -t "$s" 2>/dev/null; then
         log_ok "停止しました: $s"
       else
         log_warn "停止失敗 (既に終了?): $s"
       fi
       "$TMUX_BIN" kill-session -t "_keeper_$safe" 2>/dev/null || true
       sleep 1 ;;
    *) : ;;
  esac
}

# 対話メニュー: headless 🤖 → tmux 🖥 を統合番号選択
_interactive_menu() {
  local sdir="$1" show_tmux="${2:-0}"
  while true; do
    clear 2>/dev/null || true
    log_info "セッション状態監視 ($(date +%H:%M:%S))"

    local -a foreground_prjs headless_prjs tmux_sess
    mapfile -t foreground_prjs < <(_running_foreground_projects)
    mapfile -t headless_prjs < <(_running_headless_projects)
    if (( show_tmux )); then
      mapfile -t tmux_sess < <(_running_tmux_sessions)
    else
      tmux_sess=()
    fi

    printf '\n  %s● 実行中の ClaudeOS セッション:%s\n' "$C_GREEN" "$C_RESET"
    local idx=1 started cost info
    if (( ${#foreground_prjs[@]} == 0 && ${#headless_prjs[@]} == 0 && ${#tmux_sess[@]} == 0 )); then
      printf '      (実行中なし)\n'
    else
      local fp fgsafe fgjson
      for fp in "${foreground_prjs[@]}"; do
        fgsafe="$(ccsu_safe_name "$fp")"
        fgjson="$_FG_DIR/${fgsafe}.json"
        started="$(json_get "$fgjson" '.started_at' '?')"
        printf '      %s[%d]%s 🖥  %-30s %s\n' \
          "$C_YELLOW" "$idx" "$C_RESET" "$fp" "$started"
        idx=$((idx + 1))
      done
      local p safe supjson
      for p in "${headless_prjs[@]}"; do
        safe="$(ccsu_safe_name "$p")"
        supjson="$_SUP_DIR/${safe}.json"
        started="$(json_get "$supjson" '.started_at' '?')"
        cost="$(json_get "$supjson" '.month_spent_usd' '?')"
        printf '      %s[%d]%s 🤖 %-30s %s  $%s\n' \
          "$C_YELLOW" "$idx" "$C_RESET" "$p" "$started" "$cost"
        idx=$((idx + 1))
      done
      local s
      for s in "${tmux_sess[@]}"; do
        info="$("$TMUX_BIN" ls 2>/dev/null | grep "^${s}:" | head -1 || true)"
        printf '      %s[%d]%s 🖥  %s\n' "$C_YELLOW" "$idx" "$C_RESET" "${info:-$s}"
        idx=$((idx + 1))
      done
    fi
    printf '\n'
    _render_history "$sdir"

    printf '\n  %s操作:%s 番号=選択(接続/停止)   r=再表示   0=戻る\n' "$C_CYAN" "$C_RESET"
    local choice; read -rp "  入力: " choice
    case "$choice" in
      0) return 0 ;;
      r|R|"") continue ;;
      *[!0-9]*) log_warn "無効な入力です"; sleep 1 ;;
      *)
        local total=$(( ${#foreground_prjs[@]} + ${#headless_prjs[@]} + ${#tmux_sess[@]} ))
        if (( choice >= 1 && choice <= total )); then
          if (( choice <= ${#foreground_prjs[@]} )); then
            _session_action_foreground "${foreground_prjs[$((choice - 1))]}"
          elif (( choice <= ${#foreground_prjs[@]} + ${#headless_prjs[@]} )); then
            _session_action_headless "${headless_prjs[$((choice - ${#foreground_prjs[@]} - 1))]}"
          else
            local ti=$(( choice - ${#foreground_prjs[@]} - ${#headless_prjs[@]} - 1 ))
            _session_action_tmux "${tmux_sess[$ti]}"
          fi
        else
          log_warn "範囲外の番号です: $choice"; sleep 1
        fi ;;
    esac
  done
}

main() {
  local once=0 show_tmux="${CLAUDEOS_WATCH_TMUX:-0}" connect_project=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --once) once=1; shift ;;
      --tmux) show_tmux=1; shift ;;
      --connect) connect_project="$2"; shift 2 ;;
      *) log_error "不明な引数: $1"; return 1 ;;
    esac
  done
  local sdir="${CCSU_SESSIONS_DIR:-$CCSU_HOME/sessions}"
  [[ -d "$sdir" ]] || { log_warn "セッションディレクトリがありません: $sdir"; return 0; }
  if [[ -n "$connect_project" ]]; then
    _connect_project "$connect_project"
  elif (( once )); then
    _render_once "$sdir" "$show_tmux"
  else
    _interactive_menu "$sdir" "$show_tmux"
  fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
