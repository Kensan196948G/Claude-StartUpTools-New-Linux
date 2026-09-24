#!/usr/bin/env bash
# ============================================================
# web-startup.sh — Web スタートアップコンソールの起動/停止/状態 (メニュー項WS)
#
#   bin/menu.sh (L1/T1/S1/全適用/停止) をブラウザから使うための Web 版。
#   実体は scripts/web/startup-server.js (Node 組み込みのみ) で、
#   起動・停止・全適用は既存 CLI (bin/start-claude.sh / bin/autonomy.sh) を呼ぶ。
#
# 使い方:
#   web-startup.sh --start [--port N] [--host ADDR] [--lan] [--dry-run-only]
#   web-startup.sh --stop
#   web-startup.sh --status
#   web-startup.sh --dry-run         # 実行計画のみ (何も起動しない)
#
# 安全:
#   - 既定 bind は 127.0.0.1 (LAN 公開は --lan + STARTUP_WEB_PASSWORD 必須)。
#   - 停止は PID ファイルの PID と起動コマンドの一致を確認してから行う。
# ============================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
# shellcheck source=lib/config-loader.sh
source "$SCRIPT_DIR/../lib/config-loader.sh"

PORT="${WEB_STARTUP_PORT:-3740}"
HOST="${WEB_STARTUP_HOST:-127.0.0.1}"
PID_FILE="${CCSU_HOME}/web-startup.pid"
LOG_FILE="${CCSU_HOME}/logs/web-startup.log"
SERVER_JS="$CCSU_ROOT/scripts/web/startup-server.js"
WS_DRY_RUN=0
WS_DRY_RUN_ONLY=0
NODE_BIN="$(command -v node || echo /usr/bin/node)"

# ws__pid — 稼働中 PID (無ければ空)。PID ファイルだけでなく実プロセスを確認する。
ws__pid() {
  [[ -f "$PID_FILE" ]] || return 0
  local pid; pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 0
  kill -0 "$pid" 2>/dev/null || return 0
  # 起動コマンドに startup-server.js が含まれることを確認 (PID 再利用への防御)
  if [[ -r "/proc/$pid/cmdline" ]] && ! tr '\0' ' ' < "/proc/$pid/cmdline" | grep -q 'startup-server.js'; then
    return 0
  fi
  printf '%s' "$pid"
}

ws__url() { printf 'http://%s:%s' "$([[ "$HOST" == "0.0.0.0" ]] && printf 'localhost' || printf '%s' "$HOST")" "$PORT"; }

ws__status() {
  local pid; pid="$(ws__pid)"
  if [[ -n "$pid" ]]; then
    log_ok "Web スタートアップコンソール 稼働中 (pid=$pid)"
    log_info "  URL: $(ws__url)"
    log_info "  ログ: $LOG_FILE"
    if has_cmd curl; then
      local h; h="$(curl -fsS --max-time 3 "$(ws__url)/api/health" 2>/dev/null || true)"
      [[ -n "$h" ]] && log_info "  health: $h" || log_warn "  health: 応答なし"
    fi
    return 0
  fi
  log_info "Web スタートアップコンソールは停止しています"
}

ws__start() {
  local pid; pid="$(ws__pid)"
  if [[ -n "$pid" ]]; then
    log_warn "既に稼働中です (pid=$pid, $(ws__url))"
    return 0
  fi
  [[ -f "$SERVER_JS" ]] || die "サーバが見つかりません: $SERVER_JS"
  if ! has_cmd node; then die "node が見つかりません (Node.js 18+ が必要)"; fi

  local -a args=("$SERVER_JS" --port "$PORT" --host "$HOST")
  (( WS_DRY_RUN_ONLY )) && args+=(--dry-run-only)

  if (( WS_DRY_RUN )); then
    log_info "dry-run: Web スタートアップコンソール起動計画"
    log_info "  command=$NODE_BIN ${args[*]}"
    log_info "  cwd=$CCSU_ROOT"
    log_info "  pidfile=$PID_FILE"
    log_info "  log=$LOG_FILE"
    log_info "  url=$(ws__url)"
    [[ -n "${STARTUP_WEB_PASSWORD:-${DASHBOARD_PASSWORD:-}}" ]] \
      && log_info "  auth=required" || log_info "  auth=off (loopback のみ許可)"
    log_info "dry-run: プロセスは起動しません"
    return 0
  fi

  if [[ "$HOST" != "127.0.0.1" && "$HOST" != "::1" && "$HOST" != "localhost" ]] \
     && [[ -z "${STARTUP_WEB_PASSWORD:-${DASHBOARD_PASSWORD:-}}" ]]; then
    die "非ループバック ($HOST) へ bind するには STARTUP_WEB_PASSWORD が必要です"
  fi

  mkdir -p "$CCSU_HOME/logs"
  local runner; if has_cmd setsid; then runner=setsid; else runner=nohup; fi
  ( cd "$CCSU_ROOT" && "$runner" "$NODE_BIN" "${args[@]}" >>"$LOG_FILE" 2>&1 < /dev/null & )
  disown 2>/dev/null || true

  # health check (最大 10 秒)。起動待ちは固定 sleep せず polling。
  local i=0
  while (( i < 20 )); do
    i=$((i + 1))
    if has_cmd curl && curl -fsS --max-time 2 "$(ws__url)/api/health" >/dev/null 2>&1; then
      local pid2; pid2="$(pgrep -f 'startup-server.js' | head -1 || true)"
      [[ -n "$pid2" ]] && printf '%s\n' "$pid2" > "$PID_FILE"
      log_ok "起動しました: $(ws__url) (pid=${pid2:-?})"
      log_info "  ログ: $LOG_FILE"
      return 0
    fi
    sleep 0.5
  done
  log_error "起動を確認できませんでした。ログを確認してください: $LOG_FILE"
  return 1
}

ws__stop() {
  local pid; pid="$(ws__pid)"
  if [[ -z "$pid" ]]; then
    log_info "稼働していません (PID ファイル: $PID_FILE)"
    rm -f "$PID_FILE" 2>/dev/null || true
    return 0
  fi
  if (( WS_DRY_RUN )); then
    log_info "dry-run: kill $pid (Web スタートアップコンソール)"
    return 0
  fi
  kill "$pid" 2>/dev/null || true
  local i=0
  while (( i < 20 )) && kill -0 "$pid" 2>/dev/null; do sleep 0.5; i=$((i + 1)); done
  if kill -0 "$pid" 2>/dev/null; then
    log_warn "応答が無いため強制終了します (pid=$pid)"
    kill -9 "$pid" 2>/dev/null || true
  fi
  rm -f "$PID_FILE" 2>/dev/null || true
  log_ok "停止しました (pid=$pid)"
}

main() {
  local action=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --start)         action="start"; shift ;;
      --stop)          action="stop"; shift ;;
      --status)        action="status"; shift ;;
      --port)          PORT="$2"; shift 2 ;;
      --host)          HOST="$2"; shift 2 ;;
      --lan)           HOST="0.0.0.0"; shift ;;
      --dry-run-only)  WS_DRY_RUN_ONLY=1; shift ;;
      --dry-run)       WS_DRY_RUN=1; shift ;;
      *) log_error "不明な引数: $1"; exit 1 ;;
    esac
  done
  case "$action" in
    start)  ws__start ;;
    stop)   ws__stop ;;
    status) ws__status ;;
    *) log_error "--start / --stop / --status のいずれかを指定してください"; exit 1 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi