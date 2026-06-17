#!/usr/bin/env bash
# ============================================================
# watch-session.sh — セッション状態監視 / 操作 (メニュー項15)
#
# 対話モード (既定): 実行中セッション (headless 🤖 / tmux 🖥) を番号付きで
#   列挙し、番号選択 → [l]ログ/[a]接続 / [s]停止 を選べる。
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
  local sdir="$1"
  local hp; hp="$(_running_headless_projects)"
  printf '  %s● 実行中の ClaudeOS セッション (headless 🤖):%s\n' "$C_GREEN" "$C_RESET"
  if [[ -n "$hp" ]]; then
    printf '%s\n' "$hp" | sed 's/^/      🤖 /'
  else
    printf '      (実行中なし)\n'
  fi
  if has_cmd "$TMUX_BIN"; then
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

# headless セッション操作: [l]ログ追尾 / [s]停止 / [k]即停止 / [c]キャンセル
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
  printf '    %s[l]%s ログ追尾   %s[s]%s 停止   %s[k]%s 即停止   %s[c]%s キャンセル\n' \
    "$C_YELLOW" "$C_RESET" "$C_YELLOW" "$C_RESET" "$C_RED" "$C_RESET" "$C_WHITE" "$C_RESET"
  local op; read -rp "  操作: " op
  case "${op,,}" in
    l)
      if [[ -f "$suplog" ]]; then
        if [[ -n "${TMUX:-}" ]] && has_cmd "$TMUX_BIN"; then
          local q; printf -v q '%q' "$suplog"
          # shellcheck disable=SC2086
          if "$TMUX_BIN" new-window -n "follow:$proj" "tail -n 30 -f $q" 2>/dev/null; then
            log_ok "追尾ログを tmux 別ウィンドウで開きました (Ctrl-b n で切替)"
          else
            log_warn "別ウィンドウ生成失敗 — 手動追尾: tail -f $suplog"
          fi
        else
          log_info "別端末で追尾: tail -f $suplog"
        fi
      else
        log_warn "ログファイルが見つかりません: $suplog"
      fi
      sleep 2 ;;
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

# tmux セッション操作: [a]接続 / [s]停止 / [c]キャンセル
_session_action_tmux() {
  local s="$1" safe="${1#claudeos-}"
  printf '\n  選択: %s🖥  %s%s  [tmux]\n' "$C_GREEN" "$s" "$C_RESET"
  printf '    %s[a]%s 接続(attach)   %s[s]%s 停止(kill)   %s[c]%s キャンセル\n' \
    "$C_YELLOW" "$C_RESET" "$C_YELLOW" "$C_RESET" "$C_WHITE" "$C_RESET"
  local op; read -rp "  操作: " op
  case "${op,,}" in
    a) log_info "接続します... (Ctrl-b d でデタッチ=BG継続)"; sleep 1
       "$TMUX_BIN" attach -t "$s" || true ;;
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
  local sdir="$1"
  while true; do
    clear 2>/dev/null || true
    log_info "セッション状態監視 ($(date +%H:%M:%S))"

    local -a headless_prjs tmux_sess
    mapfile -t headless_prjs < <(_running_headless_projects)
    mapfile -t tmux_sess < <(_running_tmux_sessions)

    printf '\n  %s● 実行中の ClaudeOS セッション:%s\n' "$C_GREEN" "$C_RESET"
    local idx=1 started cost info
    if (( ${#headless_prjs[@]} == 0 && ${#tmux_sess[@]} == 0 )); then
      printf '      (実行中なし)\n'
    else
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
        local total=$(( ${#headless_prjs[@]} + ${#tmux_sess[@]} ))
        if (( choice >= 1 && choice <= total )); then
          if (( choice <= ${#headless_prjs[@]} )); then
            _session_action_headless "${headless_prjs[$((choice - 1))]}"
          else
            local ti=$(( choice - ${#headless_prjs[@]} - 1 ))
            _session_action_tmux "${tmux_sess[$ti]}"
          fi
        else
          log_warn "範囲外の番号です: $choice"; sleep 1
        fi ;;
    esac
  done
}

main() {
  local once=0; [[ "${1:-}" == "--once" ]] && once=1
  local sdir="${CCSU_SESSIONS_DIR:-$CCSU_HOME/sessions}"
  [[ -d "$sdir" ]] || { log_warn "セッションディレクトリがありません: $sdir"; return 0; }
  if (( once )); then
    _render_once "$sdir"
  else
    _interactive_menu "$sdir"
  fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
