#!/usr/bin/env bash
# ============================================================
# dashboard-service.sh — Dashboard 自動起動 登録/解除 (メニュー項DR/DU)
# systemd user service を第一候補、不可なら crontab @reboot フォールバック
#
# CCSU_SYSTEMCTL_BIN で systemctl を差し替え可 (bats スタブ用)
# ============================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
# shellcheck source=lib/config-loader.sh
source "$SCRIPT_DIR/../lib/config-loader.sh"

PROD_UNIT="claudeos-dashboard.service"
SYSTEMCTL="${CCSU_SYSTEMCTL_BIN:-systemctl}"
CRONTAB_BIN="${CCSU_CRONTAB_BIN:-crontab}"
DS_DRY_RUN=0

# --- 引数で受ける値 (未指定は空 = 既定/プロファイルを使う) ---
DS_PROFILE=""
DS_UNIT=""
DS_ROOT=""
DS_PORT=""
DS_HOST=""
DS_CLAUDEOS_HOME=""

# --- 解決後の実効値 ---
UNIT=""
UNIT_PATH=""
ROOT=""
PORT=""
HOST=""
CLAUDEOS_HOME=""

ds__require_value() {
  local opt="$1" value="${2:-}"
  if [[ -z "$value" ]]; then log_error "$opt には値が必要です"; exit 2; fi
}

ds__no_control_chars() {
  local name="$1" value="$2"
  case "$value" in
    *$'\n'*|*$'\r'*) log_error "$name に改行/復帰文字は使えません"; exit 2 ;;
  esac
}

ds__validate_unit_name() {
  local name="$1"
  [[ -n "$name" ]] || { log_error "unit 名が空です"; exit 2; }
  [[ "$name" =~ ^[A-Za-z0-9_.@-]+$ ]] || { log_error "unit 名に使える文字は英数字と . _ @ - のみです: $name"; exit 2; }
}

# ds__resolve — プロファイル既定 → 明示オプションの順で実効値を決める
ds__resolve() {
  local staging=0
  [[ "$DS_PROFILE" == "staging" ]] && staging=1

  if [[ -n "$DS_UNIT" ]]; then UNIT="$DS_UNIT"
  elif (( staging )); then UNIT="claude-startuptools-dashboard-stg.service"
  else UNIT="$PROD_UNIT"; fi

  if (( staging )) && [[ "$UNIT" == "$PROD_UNIT" ]]; then
    log_error "staging プロファイルで本番 unit ($PROD_UNIT) は操作できません"; exit 2
  fi

  ROOT="${DS_ROOT:-$CCSU_ROOT}"

  if [[ -z "$DS_PORT" ]]; then
    if (( staging )); then DS_PORT=3743; else DS_PORT=3737; fi
  fi
  PORT="$DS_PORT"

  if [[ -n "$DS_HOST" ]]; then HOST="$DS_HOST"
  elif (( staging )); then HOST="127.0.0.1"; else HOST=""; fi

  # staging は loopback 固定 (LAN/公開へ bind させない)
  if (( staging )) && [[ "$HOST" != "127.0.0.1" && "$HOST" != "localhost" ]]; then
    log_error "staging プロファイルの HOST は 127.0.0.1 固定です: $HOST"; exit 2
  fi

  if [[ -n "$DS_CLAUDEOS_HOME" ]]; then CLAUDEOS_HOME="$DS_CLAUDEOS_HOME"
  elif (( staging )); then CLAUDEOS_HOME="$HOME/.claudeos-stg"
  else CLAUDEOS_HOME=""; fi

  ds__validate_unit_name "$UNIT"
  ds__no_control_chars "--root" "$ROOT"
  ds__no_control_chars "--host" "$HOST"
  ds__no_control_chars "--claudeos-home" "$CLAUDEOS_HOME"
  UNIT_PATH="${CCSU_SYSTEMD_UNIT_PATH:-$HOME/.config/systemd/user/$UNIT}"
}

ds__register() {
  local node dash pdir
  ds__resolve
  node="$(command -v node || echo /usr/bin/node)"
  dash="$ROOT/scripts/dashboards/serve-dashboard.js"
  pdir="$(config_projects_dir)"
  if (( DS_DRY_RUN )); then
    log_info "dry-run: Dashboard 自動起動登録計画"
    log_info "  unit=$UNIT_PATH"
    log_info "  ExecStart=$node $dash $PORT"
    log_info "  AI_STARTUP_PROJECTS_DIR=$pdir"
    if [[ -n "$HOST" ]]; then log_info "  HOST=$HOST"; fi
    if [[ -n "$CLAUDEOS_HOME" ]]; then log_info "  CLAUDEOS_HOME=$CLAUDEOS_HOME"; fi
    log_info "dry-run: systemd/crontab への書き込みは行いません"
    return 0
  fi
  if ! has_cmd "$SYSTEMCTL"; then
    log_warn "systemd (systemctl) が無いため crontab @reboot を使用します"
    ds__register_cron; return
  fi
  mkdir -p "$(dirname "$UNIT_PATH")"
  cat > "$UNIT_PATH" <<EOF
[Unit]
Description=ClaudeOS Dashboard (Mission Control)
After=network.target

[Service]
Type=simple
WorkingDirectory=$ROOT
Environment=AI_STARTUP_PROJECTS_DIR=$pdir
EOF
  if [[ -n "$HOST" ]]; then printf 'Environment=HOST=%s\n' "$HOST" >> "$UNIT_PATH"; fi
  if [[ -n "$CLAUDEOS_HOME" ]]; then printf 'Environment=CLAUDEOS_HOME=%s\n' "$CLAUDEOS_HOME" >> "$UNIT_PATH"; fi
  cat >> "$UNIT_PATH" <<EOF
ExecStart=$node $dash $PORT
Restart=on-failure

[Install]
WantedBy=default.target
EOF
  "$SYSTEMCTL" --user daemon-reload
  "$SYSTEMCTL" --user enable --now "$UNIT"
  command -v loginctl >/dev/null 2>&1 && (loginctl enable-linger "$USER" 2>/dev/null || true)
  log_ok "systemd user service 登録: $UNIT (http://${HOST:-localhost}:$PORT)"
}

ds__register_cron() {
  local pdir cmd envs=""
  ds__resolve
  pdir="$(config_projects_dir)"
  if [[ -n "$HOST" ]]; then envs="$envs HOST=$HOST"; fi
  if [[ -n "$CLAUDEOS_HOME" ]]; then envs="$envs CLAUDEOS_HOME=$CLAUDEOS_HOME"; fi
  cmd="@reboot cd $ROOT && AI_STARTUP_PROJECTS_DIR=$pdir$envs node scripts/dashboards/serve-dashboard.js $PORT >> ${CLAUDEOS_HOME:-$HOME/.claudeos}/logs/dashboard.log 2>&1"
  if (( DS_DRY_RUN )); then
    log_info "dry-run: crontab @reboot 登録予定"
    log_info "  $cmd"
    log_info "dry-run: crontab は変更しません"
    return 0
  fi
  ( "$CRONTAB_BIN" -l 2>/dev/null | grep -v 'serve-dashboard.js' || true; printf '%s\n' "$cmd" ) | "$CRONTAB_BIN" -
  log_ok "crontab @reboot 登録 (systemd 代替)"
}

ds__unregister() {
  ds__resolve
  if (( DS_DRY_RUN )); then
    log_info "dry-run: Dashboard 自動起動解除予定"
    log_info "  systemd unit=$UNIT"
    log_info "  unit path=$UNIT_PATH"
    log_info "  crontab pattern=serve-dashboard.js"
    log_info "dry-run: systemd/crontab は変更しません"
    return 0
  fi
  if has_cmd "$SYSTEMCTL"; then
    "$SYSTEMCTL" --user disable --now "$UNIT" 2>/dev/null || true
    rm -f "$UNIT_PATH"
    "$SYSTEMCTL" --user daemon-reload 2>/dev/null || true
  fi
  if has_cmd "$CRONTAB_BIN"; then
    "$CRONTAB_BIN" -l 2>/dev/null | grep -v 'serve-dashboard.js' | "$CRONTAB_BIN" - 2>/dev/null || true
  fi
  log_ok "Dashboard 自動起動を解除しました"
}

main() {
  local action=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --register)   action="register"; shift ;;
      --unregister) action="unregister"; shift ;;
      --run-now)    shift ;;   # systemd enable --now で兼ねる
      --status)     action="status"; shift ;;
      --dry-run)    DS_DRY_RUN=1; shift ;;
      --unit)       ds__require_value "$1" "${2:-}"; DS_UNIT="$2"; shift 2 ;;
      --root)       ds__require_value "$1" "${2:-}"; DS_ROOT="$2"; shift 2 ;;
      --port)       ds__require_value "$1" "${2:-}"; DS_PORT="$2"; shift 2 ;;
      --host)       ds__require_value "$1" "${2:-}"; DS_HOST="$2"; shift 2 ;;
      --claudeos-home) ds__require_value "$1" "${2:-}"; DS_CLAUDEOS_HOME="$2"; shift 2 ;;
      --profile)
                    ds__require_value "$1" "${2:-}"
                    case "$2" in
                      production|staging) DS_PROFILE="$2" ;;
                      *) log_error "--profile は production / staging のいずれかです: $2"; exit 2 ;;
                    esac
                    shift 2 ;;
      *) log_error "不明な引数: $1"; exit 1 ;;
    esac
  done
  case "$action" in
    register)   ds__register ;;
    unregister) ds__unregister ;;
    status)     ds__resolve; "$SYSTEMCTL" --user status "$UNIT" --no-pager 2>/dev/null || echo "(未登録)" ;;
    *) log_error "--register / --unregister / --status のいずれかを指定"; exit 1 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
