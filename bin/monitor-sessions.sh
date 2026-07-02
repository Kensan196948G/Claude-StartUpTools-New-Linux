#!/usr/bin/env bash
# ============================================================
# monitor-sessions.sh — 登録プロジェクト横断のセッション監視 (Linux native)
#
# 役割: watch-session.sh (実行中セッションへの対話的接続/停止) を補完し、
#       全登録プロジェクトを tmux × cron × supervisor 横断で1覧俯瞰する。
#       独自機能として tmux link-window による複数セッションの統合監視を提供する。
#
# 使い方:
#   monitor-sessions.sh list                  # 全登録プロジェクトの状態を1覧表示
#   monitor-sessions.sh watch [interval_sec]  # 自動更新監視 (既定 5秒, Ctrl-C で終了)
#   monitor-sessions.sh link <project>...     # 複数 tmux セッションを統合監視セッションへ集約
#   monitor-sessions.sh unlink                # 統合監視セッションを解除
#   monitor-sessions.sh attach <project>      # 指定プロジェクトの tmux セッションへ接続
#   monitor-sessions.sh stop <project>        # 指定プロジェクトの tmux セッションを停止
#
# 移植元: ClaudeCode-StartUpTools-New/bin/monitor-sessions.sh の
#         tmux link-window/unlink-window による統合監視という着想のみ
#         (tmux 実行/接続/停止そのものは lib/tmux-runner.sh を再利用)
# ============================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
# shellcheck source=lib/config-loader.sh
source "$SCRIPT_DIR/../lib/config-loader.sh"
# shellcheck source=lib/launcher-common.sh
source "$SCRIPT_DIR/../lib/launcher-common.sh"
# shellcheck source=lib/tmux-runner.sh
source "$SCRIPT_DIR/../lib/tmux-runner.sh"
# shellcheck source=lib/cron-manager.sh
source "$SCRIPT_DIR/../lib/cron-manager.sh"
# shellcheck source=lib/supervisor.sh
source "$SCRIPT_DIR/../lib/supervisor.sh"

# ms__has_cron <project> — 当該プロジェクトの CLAUDEOS cron エントリがあれば 0
ms__has_cron() {
  cron__list 2>/dev/null | awk -F'|' -v p="$1" '$2==p {f=1} END{exit !f}'
}

# ms__list — 全登録プロジェクトを tmux/cron/supervisor 横断で1行ずつ表示
ms__list() {
  printf '  %s📊 Monitor Sessions — 全登録プロジェクト状態%s\n' "$C_CYAN" "$C_RESET"
  printf '  %-28s %-12s %-6s %-6s %-6s\n' "PROJECT" "STATUS" "TMUX" "CRON" "SUP"

  local p run_status tmux_f cron_f sup_f status_disp color found=0
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    found=1
    run_status="$(launcher__project_run_status "$p")"
    tmux__is_running "$p" && tmux_f="🟢" || tmux_f="⚫"
    ms__has_cron "$p"     && cron_f="🟢" || cron_f="⚫"
    sup__is_running "$p"  && sup_f="🟢"  || sup_f="⚫"
    case "$run_status" in
      running)      color="$C_RED";    status_disp="🔴 実行中" ;;
      goal-reached) color="$C_YELLOW"; status_disp="🟡 達成済" ;;
      crash-loop)   color="$C_YELLOW"; status_disp="🟡 クラッシュ" ;;
      blocked)      color="$C_YELLOW"; status_disp="🟡 ブロック" ;;
      *)            color="$C_GREEN";  status_disp="🟢 待機中" ;;
    esac
    printf '  %s%-28s%s %-14s %-6s %-6s %-6s\n' "$color" "$p" "$C_RESET" "$status_disp" "$tmux_f" "$cron_f" "$sup_f"
  done < <(config_project_list)

  (( found == 0 )) && printf '  %s(登録プロジェクトなし)%s\n' "$C_WHITE" "$C_RESET"
}

# ms__watch [interval_sec] — list を定期再描画 (Ctrl-C で終了)
ms__watch() {
  local interval="${1:-5}"
  log_info "👁 監視モード開始 (更新間隔 ${interval}s, Ctrl-C で終了)"
  while true; do
    clear
    ms__list
    printf '\n  %s更新間隔 %ss / Ctrl-C で終了%s\n' "$C_WHITE" "$interval" "$C_RESET"
    sleep "$interval" || break
  done
}

# ms__monitor_session — 統合監視用の固定 tmux セッション名
ms__monitor_session() { printf 'claudeos-monitor'; }

# ms__link <project>... — 各プロジェクトの tmux window を統合監視セッションへ集約
ms__link() {
  local -a projects=("$@")
  (( ${#projects[@]} > 0 )) || { log_error "link: 対象プロジェクトを1件以上指定してください"; return 1; }

  local msession; msession="$(ms__monitor_session)"
  local created=0
  if ! "$TMUX_BIN" has-session -t "$msession" 2>/dev/null; then
    "$TMUX_BIN" new-session -d -s "$msession" -n _placeholder
    created=1
  fi

  local p session linked=0
  for p in "${projects[@]}"; do
    session="$(tmux__session_name "$p")"
    if ! "$TMUX_BIN" has-session -t "$session" 2>/dev/null; then
      log_warn "セッション未起動のためスキップ: $p ($session)"
      continue
    fi
    if "$TMUX_BIN" link-window -s "${session}:0" -t "${msession}:" 2>/dev/null; then
      linked=$((linked + 1))
      log_ok "🔗 link: $p → $msession"
    else
      log_warn "link 失敗 (既にリンク済みの可能性): $p"
    fi
  done

  if (( linked > 0 )); then
    (( created )) && "$TMUX_BIN" kill-window -t "${msession}:_placeholder" 2>/dev/null || true
    log_info "  接続: tmux attach -t $msession  (複数プロジェクトを1画面で監視)"
    log_info "  解除: bash bin/monitor-sessions.sh unlink"
  else
    log_warn "link 対象がありませんでした"
    (( created )) && "$TMUX_BIN" kill-session -t "$msession" 2>/dev/null || true
  fi
}

# ms__unlink — 統合監視セッションを解除 (元セッションは link-window のため影響なし)
ms__unlink() {
  local msession; msession="$(ms__monitor_session)"
  if "$TMUX_BIN" has-session -t "$msession" 2>/dev/null; then
    "$TMUX_BIN" kill-session -t "$msession" 2>/dev/null
    log_ok "🔓 統合監視セッションを解除しました: $msession"
  else
    log_warn "統合監視セッションは起動していません: $msession"
  fi
}

main() {
  require_cmd jq
  require_cmd "${CCSU_TMUX_BIN:-tmux}"
  case "${1:-}" in
    list)   ms__list ;;
    watch)  shift; ms__watch "${1:-5}" ;;
    link)   shift; ms__link "$@" ;;
    unlink) ms__unlink ;;
    attach) shift; [[ -n "${1:-}" ]] || { log_error "attach: <project> は必須"; return 1; }; tmux__attach "$1" ;;
    stop)   shift; [[ -n "${1:-}" ]] || { log_error "stop: <project> は必須"; return 1; }; tmux__stop "$1" ;;
    ""|--help|-h)
      printf 'Usage: monitor-sessions.sh list|watch|link|unlink|attach|stop\n'
      printf '  list                  全登録プロジェクトの状態を1覧表示 (tmux/cron/supervisor 横断)\n'
      printf '  watch [interval_sec]  自動更新監視 (既定 5秒間隔, Ctrl-C で終了)\n'
      printf '  link <project>...     複数プロジェクトの tmux セッションを統合監視セッションへ集約\n'
      printf '  unlink                統合監視セッションを解除\n'
      printf '  attach <project>      指定プロジェクトの tmux セッションへ接続\n'
      printf '  stop <project>        指定プロジェクトの tmux セッションを停止\n'
      ;;
    *) log_error "不明なサブコマンド: $1 (list|watch|link|unlink|attach|stop)"; return 1 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
