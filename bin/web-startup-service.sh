#!/usr/bin/env bash
# ============================================================
# web-startup-service.sh — Web スタートアップコンソールの systemd --user 常駐登録
#
#   bin/dashboard-service.sh と同型 (systemd user service が第一候補)。
#   Cloudflare Tunnel + Access で公開する構成の origin 側 (127.0.0.1:3740) を常時稼働させる。
#   設計・手順: docs/architecture/WEB_STARTUP_PUBLIC_ACCESS.md
#
# 使い方:
#   web-startup-service.sh --register [--port N] [--env-file PATH]   # unit 生成 + enable --now
#   web-startup-service.sh --unregister                              # 停止 + unit 削除
#   web-startup-service.sh --status
#   web-startup-service.sh --dry-run                                 # 実行計画のみ (何も書かない)
#
# 安全:
#   - bind は常に 127.0.0.1 (公開は Cloudflare Tunnel 側。LAN へは出さない)。
#   - secret は生成しない。認証を足す場合は人間が env-file (0600) を作る。
#   - systemctl は CCSU_SYSTEMCTL_BIN で差し替え可 (bats スタブ用)。
# ============================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

UNIT="claudeos-web-startup.service"
UNIT_PATH="${CCSU_SYSTEMD_UNIT_PATH:-$HOME/.config/systemd/user/$UNIT}"
SYSTEMCTL="${CCSU_SYSTEMCTL_BIN:-systemctl}"
ENV_FILE_DEFAULT="$HOME/.config/claudeos-web-startup.env"
WS_PORT="${WEB_STARTUP_PORT:-3740}"
ENV_FILE="$ENV_FILE_DEFAULT"
WS_DRY_RUN=0

# ws_svc__unit_body — unit ファイル内容 (stdout)
ws_svc__unit_body() {
  local node server
  node="$(command -v node || echo /usr/bin/node)"
  server="$CCSU_ROOT/scripts/web/startup-server.js"
  cat <<EOF
[Unit]
Description=ClaudeOS Web Startup Console (bin/menu.sh の Web 版)
Documentation=$CCSU_ROOT/docs/architecture/WEB_STARTUP_TOOL.md
After=network.target

[Service]
Type=simple
WorkingDirectory=$CCSU_ROOT
# STARTUP_WEB_PASSWORD / STARTUP_WEB_USER を置く場合のみ (0600)。'-' = 無くても起動する
# (loopback bind + Cloudflare Access が入口制御の主体。Basic は多層防御)
EnvironmentFile=-$ENV_FILE
ExecStart=$node $server --port $WS_PORT --host 127.0.0.1
Restart=on-failure
RestartSec=3
# 実行に必要な範囲だけ許可する (Claude 起動のため bash/claude/tmux/git を呼ぶので
# ProtectHome / ProtectSystem は付けない。付けるとプロジェクトと ~/.claudeos を読めない)
NoNewPrivileges=yes
PrivateTmp=yes

[Install]
WantedBy=default.target
EOF
}

ws_svc__register() {
  local body
  body="$(ws_svc__unit_body)"
  if (( WS_DRY_RUN )); then
    log_info "dry-run: Web スタートアップコンソール systemd --user 登録計画"
    log_info "  unit=$UNIT_PATH"
    log_info "  env-file=$ENV_FILE (任意。無ければ Basic 認証なしで起動)"
    printf '%s\n' "$body" | sed 's/^/    /'
    log_info "dry-run: systemd への書き込みは行いません"
    return 0
  fi
  mkdir -p "$(dirname "$UNIT_PATH")"
  printf '%s\n' "$body" > "$UNIT_PATH"
  "$SYSTEMCTL" --user daemon-reload
  "$SYSTEMCTL" --user enable --now "$UNIT"
  command -v loginctl >/dev/null 2>&1 && (loginctl enable-linger "$USER" 2>/dev/null || true)
  log_ok "systemd user service 登録: $UNIT (http://127.0.0.1:$WS_PORT)"
  log_info "  公開する場合は Cloudflare Tunnel + Access を人間が適用する: docs/architecture/WEB_STARTUP_PUBLIC_ACCESS.md"
}

ws_svc__unregister() {
  if (( WS_DRY_RUN )); then
    log_info "dry-run: $UNIT を disable --now し $UNIT_PATH を削除する計画"
    log_info "dry-run: systemd は変更しません"
    return 0
  fi
  "$SYSTEMCTL" --user disable --now "$UNIT" 2>/dev/null || true
  rm -f "$UNIT_PATH"
  "$SYSTEMCTL" --user daemon-reload 2>/dev/null || true
  log_ok "Web スタートアップコンソールの常駐登録を解除しました"
}

ws_svc__status() {
  "$SYSTEMCTL" --user status "$UNIT" --no-pager 2>/dev/null || echo "(未登録)"
}

main() {
  local action=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --register)   action="register"; shift ;;
      --unregister) action="unregister"; shift ;;
      --status)     action="status"; shift ;;
      --run-now)    shift ;;                    # enable --now が兼ねる (dashboard-service 互換)
      --port)       WS_PORT="$2"; shift 2 ;;
      --env-file)   ENV_FILE="$2"; shift 2 ;;
      --dry-run)    WS_DRY_RUN=1; shift ;;
      *) log_error "不明な引数: $1"; exit 1 ;;
    esac
  done
  [[ "$WS_PORT" =~ ^[0-9]+$ ]] || die "port は数値で指定してください: $WS_PORT"
  case "$action" in
    register)   ws_svc__register ;;
    unregister) ws_svc__unregister ;;
    status)     ws_svc__status ;;
    *) log_error "--register / --unregister / --status のいずれかを指定"; exit 1 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
