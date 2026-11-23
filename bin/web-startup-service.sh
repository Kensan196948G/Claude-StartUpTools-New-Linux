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
# 複数インスタンス (Staging 等):
#   web-startup-service.sh --register --profile staging              # stg unit/3742/stg env-file/stg HOME
#   web-startup-service.sh --register --unit NAME [--root DIR] [--port N]
#                                      [--env-file PATH] [--claudeos-home DIR]
#   明示オプションは --profile の既定値より優先される。
#   既定 (オプション無し) の挙動は従来と完全に同一:
#     unit=claudeos-web-startup.service / port=3740 / env-file=~/.config/claudeos-web-startup.env /
#     unit に Environment=CLAUDEOS_HOME を入れない / root=$CCSU_ROOT。
#
# 安全:
#   - bind は常に 127.0.0.1 (公開は Cloudflare Tunnel 側。LAN へは出さない)。
#     --lan / --host / --bind はエラーにする (0.0.0.0 を許可しない)。
#   - secret は生成しない。認証を足す場合は人間が env-file (0600) を作る。
#   - unit 名は [A-Za-z0-9_.@-] のみ (/ や空白は exit 2 で拒否)。
#   - staging プロファイルでは本番 unit 名を明示指定しても拒否する (本番を触らない)。
#   - systemctl は CCSU_SYSTEMCTL_BIN で差し替え可 (bats スタブ用)。
#   - unit 生成先は CCSU_SYSTEMD_UNIT_PATH (単体テスト用) または ~/.config/systemd/user/<unit>。
# ============================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

PROD_UNIT="claudeos-web-startup.service"
SYSTEMCTL="${CCSU_SYSTEMCTL_BIN:-systemctl}"

# --- 引数で受ける値 (未指定は空。空 = プロファイル既定を使う) ---
WS_PROFILE=""
WS_UNIT=""
WS_ROOT=""
WS_ENV_FILES=()
WS_ENV_EXTRA=()
WS_CLAUDEOS_HOME=""
WS_PORT="${WEB_STARTUP_PORT:-}"
WS_ACTION=""
WS_DRY_RUN=0

# --- 解決後の実効値 (ws_svc__resolve が埋める) ---
UNIT=""
UNIT_PATH=""
ROOT=""
ENV_FILES=()
CLAUDEOS_HOME=""

# ws_svc__require_value <opt> <value> — 値を伴うオプションの欠落を exit 2 で落とす
ws_svc__require_value() {
  local opt="$1" value="${2:-}"
  if [[ -z "$value" ]]; then
    log_error "$opt には値が必要です"
    exit 2
  fi
}

# ws_svc__no_control_chars <name> <value> — unit への行注入 (改行/CR) を拒否
ws_svc__no_control_chars() {
  local name="$1" value="$2"
  case "$value" in
    *$'\n'*|*$'\r'*)
      log_error "$name に改行/復帰文字は使えません"
      exit 2
      ;;
  esac
}

# ws_svc__validate_unit_name <name> — unit 名の検証 (exit 2)
ws_svc__validate_unit_name() {
  local name="$1"
  if [[ -z "$name" ]]; then
    log_error "unit 名が空です"
    exit 2
  fi
  if [[ ! "$name" =~ ^[A-Za-z0-9_.@-]+$ ]]; then
    log_error "unit 名に使える文字は英数字と . _ @ - のみです (/ や空白は不可): $name"
    exit 2
  fi
}

# ws_svc__env_value <value> — Environment= に入れる値を systemd 用に整える
#   空白/引用符を含む場合だけ全体を "..." で囲む (systemd は Environment="VAR=value with space" を許す)
ws_svc__env_value() {
  local value="$1"
  if [[ "$value" == *[[:space:]]* || "$value" == *'"'* ]]; then
    printf '"%s"' "${value//\"/\\\"}"
  else
    printf '%s' "$value"
  fi
}

# ws_svc__resolve — プロファイル既定 → 明示オプションの順で実効値を決める
ws_svc__resolve() {
  local staging=0
  [[ "$WS_PROFILE" == "staging" ]] && staging=1

  # unit 名
  if [[ -n "$WS_UNIT" ]]; then
    UNIT="$WS_UNIT"
  elif (( staging )); then
    UNIT="claudeos-web-startup-stg.service"
  else
    UNIT="$PROD_UNIT"
  fi

  # staging は本番 unit を絶対に触らない (明示指定でも拒否)
  if (( staging )) && [[ "$UNIT" == "$PROD_UNIT" ]]; then
    log_error "staging プロファイルで本番 unit ($PROD_UNIT) は操作できません"
    exit 2
  fi

  # root (unit の WorkingDirectory / server パス)
  ROOT="${WS_ROOT:-$CCSU_ROOT}"

  # env-file (複数指定可: --env-file を繰り返すと unit に複数の EnvironmentFile を出す)
  if (( ${#WS_ENV_FILES[@]} > 0 )); then
    ENV_FILES=("${WS_ENV_FILES[@]}")
  elif (( staging )); then
    ENV_FILES=("$HOME/.config/claudeos-web-startup-stg.env")
  else
    ENV_FILES=("$HOME/.config/claudeos-web-startup.env")
  fi

  # CLAUDEOS_HOME (既定では unit に入れない = 従来どおり環境変数を追加しない)
  if [[ -n "$WS_CLAUDEOS_HOME" ]]; then
    CLAUDEOS_HOME="$WS_CLAUDEOS_HOME"
  elif (( staging )); then
    CLAUDEOS_HOME="$HOME/.claudeos-stg"
  else
    CLAUDEOS_HOME=""
  fi

  # port (CLI --port > WEB_STARTUP_PORT > プロファイル既定)
  if [[ -z "$WS_PORT" ]]; then
    if (( staging )); then WS_PORT=3742; else WS_PORT=3740; fi
  fi

  ws_svc__validate_unit_name "$UNIT"
  ws_svc__no_control_chars "--root" "$ROOT"
  local _f
  for _f in "${ENV_FILES[@]}"; do
    ws_svc__no_control_chars "--env-file" "$_f"
  done
  local _kv0
  for _kv0 in "${WS_ENV_EXTRA[@]}"; do
    ws_svc__no_control_chars "--env" "$_kv0"
  done
  ws_svc__no_control_chars "--claudeos-home" "$CLAUDEOS_HOME"

  UNIT_PATH="${CCSU_SYSTEMD_UNIT_PATH:-$HOME/.config/systemd/user/$UNIT}"
}

# ws_svc__unit_body — unit ファイル内容 (stdout)
#   既定 (CLAUDEOS_HOME 空) の出力は従来とバイト単位で同一。
ws_svc__unit_body() {
  local node server
  node="$(command -v node || echo /usr/bin/node)"
  server="$ROOT/scripts/web/startup-server.js"
  cat <<EOF
[Unit]
Description=ClaudeOS Web Startup Console (bin/menu.sh の Web 版)
Documentation=$ROOT/docs/architecture/WEB_STARTUP_TOOL.md
After=network.target

[Service]
Type=simple
WorkingDirectory=$ROOT
# STARTUP_WEB_PASSWORD / STARTUP_WEB_USER を置く場合のみ (0600)。'-' = 無くても起動する
# (loopback bind + Cloudflare Access が入口制御の主体。Basic は多層防御)
EOF
  local _ef
  for _ef in "${ENV_FILES[@]}"; do
    printf 'EnvironmentFile=-%s\n' "$_ef"
  done
  local _kv
  for _kv in "${WS_ENV_EXTRA[@]}"; do
    # --env KEY=VALUE (systemd の Environment=)。値の検証は ws_svc__resolve 側で行う
    printf 'Environment=%s\n' "$(ws_svc__env_value "$_kv")"
  done
  if [[ -n "$CLAUDEOS_HOME" ]]; then
    # 状態ディレクトリの分離 (Staging が本番の ~/.claudeos を共有しない)
    printf 'Environment=CLAUDEOS_HOME=%s\n' "$(ws_svc__env_value "$CLAUDEOS_HOME")"
  fi
  cat <<EOF
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
    log_info "  env-file=$(printf '%s,' "${ENV_FILES[@]}" | sed 's/,$//') (任意。無ければ Basic 認証なしで起動)"
    if [[ -n "$WS_ROOT" ]]; then log_info "  root=$ROOT"; fi
    if [[ -n "$CLAUDEOS_HOME" ]]; then log_info "  claudeos-home=$CLAUDEOS_HOME"; fi
    local _kv2
    for _kv2 in "${WS_ENV_EXTRA[@]}"; do log_info "  env=$_kv2"; done
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
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --register)   WS_ACTION="register"; shift ;;
      --unregister) WS_ACTION="unregister"; shift ;;
      --status)     WS_ACTION="status"; shift ;;
      --run-now)    shift ;;                    # enable --now が兼ねる (dashboard-service 互換)
      --port)       ws_svc__require_value "$1" "${2:-}"; WS_PORT="$2"; shift 2 ;;
      --unit)       ws_svc__require_value "$1" "${2:-}"; WS_UNIT="$2"; shift 2 ;;
      --root)       ws_svc__require_value "$1" "${2:-}"; WS_ROOT="$2"; shift 2 ;;
      --env-file)   ws_svc__require_value "$1" "${2:-}"; WS_ENV_FILES+=("$2"); shift 2 ;;
      --env)        ws_svc__require_value "$1" "${2:-}"
                    case "$2" in
                      [A-Za-z_][A-Za-z0-9_]*=*) WS_ENV_EXTRA+=("$2") ;;
                      *) log_error "--env は KEY=VALUE 形式です: $2"; exit 2 ;;
                    esac
                    shift 2 ;;
      --claudeos-home)
                    ws_svc__require_value "$1" "${2:-}"; WS_CLAUDEOS_HOME="$2"; shift 2 ;;
      --profile)
                    ws_svc__require_value "$1" "${2:-}"
                    case "$2" in
                      production|staging) WS_PROFILE="$2" ;;
                      *) log_error "--profile は production / staging のいずれかです: $2"; exit 2 ;;
                    esac
                    shift 2 ;;
      --dry-run)    WS_DRY_RUN=1; shift ;;
      # bind は 127.0.0.1 固定。LAN へ出す口は用意しない (公開は Cloudflare Tunnel 側)
      --lan|--host|--bind|--listen)
                    log_error "bind は 127.0.0.1 固定です ($1 は未対応)。LAN 公開は Cloudflare Tunnel + Access を使う"
                    exit 2 ;;
      *) log_error "不明な引数: $1"; exit 1 ;;
    esac
  done
  ws_svc__resolve
  [[ "$WS_PORT" =~ ^[0-9]+$ ]] || die "port は数値で指定してください: $WS_PORT"
  case "$WS_ACTION" in
    register)   ws_svc__register ;;
    unregister) ws_svc__unregister ;;
    status)     ws_svc__status ;;
    *) log_error "--register / --unregister / --status のいずれかを指定"; exit 1 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
