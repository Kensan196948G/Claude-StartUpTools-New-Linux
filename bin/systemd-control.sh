#!/usr/bin/env bash
# ============================================================
# systemd-control.sh — 登録プロジェクトの systemd (user) 起動制御 CLI (Linux native)
#
# 廃止した Docker 統合 (docker-control.sh) の代替。検出/台帳/unit 生成の実体は
# lib/systemd-manager.sh。本ファイルは CLI 表層。
#
# 使い方:
#   systemd-control.sh status [name]                 # daemon 可用性 / unit 状態
#   systemd-control.sh scan                          # Projects 走査 (推定コマンド/登録状況)
#   systemd-control.sh list                          # 台帳の登録プロジェクト一覧
#   systemd-control.sh register <name> [--command C] # 台帳登録 (command 推定/指定)
#   systemd-control.sh generate <name> [--force]     # unit 生成 + daemon-reload
#   systemd-control.sh unregister <name>             # 台帳 + unit 削除 (disable も)
#   systemd-control.sh start <name>                  # unit start (未生成なら自動 generate)
#   systemd-control.sh stop  <name>                  # unit stop
#   systemd-control.sh restart <name>                # unit restart
#   systemd-control.sh enable  <name>                # enable --now (login 時自動起動 + linger)
#   systemd-control.sh disable <name>                # disable --now
#   systemd-control.sh logs  <name> [args...]        # journalctl --user -u
#   systemd-control.sh start-all                     # enabled=true の台帳を一括 start
#   systemd-control.sh help
#
# 共通: --dry-run で副作用なしの計画表示。
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
# shellcheck source=lib/json.sh
source "$SCRIPT_DIR/../lib/json.sh"
# shellcheck source=lib/config-loader.sh
source "$SCRIPT_DIR/../lib/config-loader.sh"
# shellcheck source=lib/launcher-common.sh
source "$SCRIPT_DIR/../lib/launcher-common.sh"
# shellcheck source=lib/systemd-manager.sh
source "$SCRIPT_DIR/../lib/systemd-manager.sh"

DRY_RUN=0

sc__require_project_exists() {
  local project="$1"
  launcher__project_exists "$project" || die "プロジェクトが存在しません: $(sysd_project_dir "$project")"
}

# dry-run 対応の systemctl --user ラッパ (systemd 不在時は縮退)
sc__systemctl() {
  if (( DRY_RUN )); then log_info "[dry-run] systemctl --user $*"; return 0; fi
  sysd_available || { log_warn "systemctl が見つかりません (systemd 無効環境のため skip)"; return 0; }
  "$SYSTEMCTL" --user "$@"
}

cmd_status() {
  local project="${1:-}"
  printf '%s● systemd (user) 状態%s\n' "$C_CYAN" "$C_RESET"
  if sysd_available; then log_ok "systemctl: 利用可 ($SYSTEMCTL)"; else log_warn "systemctl: 不在 (systemd 無効環境 — 生成/台帳のみ動作)"; fi
  printf '  台帳     : %s\n' "$SYSTEMD_REGISTRY_PATH"
  printf '  unit dir : %s\n' "$SYSTEMD_USER_DIR"
  [[ -n "$project" ]] || return 0
  if (( DRY_RUN )); then log_info "[dry-run] systemctl --user status $(sysd_unit_name "$project")"; return 0; fi
  if sysd_available; then
    "$SYSTEMCTL" --user status "$(sysd_unit_name "$project")" --no-pager 2>/dev/null || log_info "(未起動 or unit 未生成)"
  fi
}

cmd_scan() {
  printf '%s● Projects 走査 (systemd 登録状況)%s\n' "$C_CYAN" "$C_RESET"
  local p cmd reg unit
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    cmd="$(sysd_resolve_command "$p")"
    reg="未登録"; sysd_registry_has "$p" && reg="登録済"
    unit="無"; [[ -f "$(sysd_unit_path "$p")" ]] && unit="有"
    printf '  %-30s cmd=%-22s 台帳=%s unit=%s\n' "$p" "${cmd:-（推定不可）}" "$reg" "$unit"
  done < <(config_project_list)
}

cmd_list() {
  printf '%s● systemd 台帳%s\n' "$C_CYAN" "$C_RESET"
  local any=0 p cmd en
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    any=1
    cmd="$(sysd_registry_get "$p" command)"
    en="$(sysd_registry_get "$p" enabled)"
    printf '  %-30s enabled=%-5s cmd=%s\n' "$p" "${en:-false}" "$cmd"
  done < <(sysd_registry_list)
  (( any )) || log_info "（台帳は空。register で登録してください）"
}

cmd_register() {
  local project="$1"; shift || true
  local cmd=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --command) cmd="${2:-}"; shift 2 ;;
      *) shift ;;
    esac
  done
  sc__require_project_exists "$project"
  [[ -n "$cmd" ]] || cmd="$(sysd_resolve_command "$project")"
  [[ -n "$cmd" ]] || die "起動コマンドを解決できません: $project (--command で明示指定するか package.json/server.js 等を用意)"
  local wd ts
  wd="$(sysd_project_dir "$project")"
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if (( DRY_RUN )); then log_info "[dry-run] 台帳登録: $project → command='$cmd' workingDir='$wd'"; return 0; fi
  sysd_registry_put "$project" "$cmd" "$wd" false "$ts"
  log_ok "台帳登録: $project (command='$cmd')"
  log_info "  unit 生成: $(basename "$0") generate $project"
}

cmd_generate() {
  local project="$1" force="${2:-}"
  sc__require_project_exists "$project"
  local cmd wd path
  cmd="$(sysd_resolve_command "$project")"
  [[ -n "$cmd" ]] || die "起動コマンドを解決できません: $project (register --command で指定してください)"
  wd="$(sysd_project_dir "$project")"
  path="$(sysd_unit_path "$project")"
  if [[ -f "$path" && "$force" != "--force" ]]; then
    log_warn "unit 既存 (上書きは --force): $path"; return 0
  fi
  if (( DRY_RUN )); then
    log_info "[dry-run] unit 生成: $path"
    log_info "  ExecStart=/bin/bash -lc '$cmd'  (WorkingDirectory=$wd)"
    return 0
  fi
  sysd_write_unit "$project" "$cmd" "$wd"
  sysd_daemon_reload
  log_ok "unit 生成: $path"
  log_info "  起動: $(basename "$0") start $project    /    自動起動: $(basename "$0") enable $project"
}

cmd_unregister() {
  local project="$1"
  if (( DRY_RUN )); then log_info "[dry-run] disable + unit 削除 + 台帳削除: $project"; return 0; fi
  sc__systemctl disable --now "$(sysd_unit_name "$project")" 2>/dev/null || true
  sysd_remove_unit "$project"
  sysd_registry_remove "$project"
  sysd_daemon_reload
  log_ok "unregister: $project (台帳 + unit 削除)"
}

cmd_start() {
  local project="$1"
  sc__require_project_exists "$project"
  if [[ ! -f "$(sysd_unit_path "$project")" ]] && (( ! DRY_RUN )); then
    log_info "unit 未生成のため生成します: $project"
    cmd_generate "$project"
  fi
  sc__systemctl start "$(sysd_unit_name "$project")"
  (( DRY_RUN )) || log_ok "start: $(sysd_unit_name "$project")"
}

cmd_stop() {
  local project="$1"
  sc__systemctl stop "$(sysd_unit_name "$project")" || true
  (( DRY_RUN )) || log_ok "stop: $(sysd_unit_name "$project")"
}

cmd_restart() {
  local project="$1"
  sc__systemctl restart "$(sysd_unit_name "$project")" || true
  (( DRY_RUN )) || log_ok "restart: $(sysd_unit_name "$project")"
}

cmd_enable() {
  local project="$1"
  sc__require_project_exists "$project"
  if [[ ! -f "$(sysd_unit_path "$project")" ]] && (( ! DRY_RUN )); then cmd_generate "$project"; fi
  sc__systemctl enable --now "$(sysd_unit_name "$project")"
  if (( ! DRY_RUN )); then
    sysd_registry_has "$project" && sysd_registry_set_enabled "$project" true
    if command -v loginctl >/dev/null 2>&1; then loginctl enable-linger "$USER" 2>/dev/null || true; fi
    log_ok "enable --now: $(sysd_unit_name "$project") (login 時自動起動)"
  fi
}

cmd_disable() {
  local project="$1"
  sc__systemctl disable --now "$(sysd_unit_name "$project")" || true
  if (( ! DRY_RUN )); then
    sysd_registry_has "$project" && sysd_registry_set_enabled "$project" false
    log_ok "disable: $(sysd_unit_name "$project")"
  fi
}

cmd_logs() {
  local project="$1"; shift || true
  if (( DRY_RUN )); then log_info "[dry-run] journalctl --user -u $(sysd_unit_name "$project") $*"; return 0; fi
  has_cmd journalctl || { log_warn "journalctl が見つかりません"; return 0; }
  journalctl --user -u "$(sysd_unit_name "$project")" "$@"
}

cmd_start_all() {
  local p n=0
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    cmd_start "$p"; n=$((n + 1))
  done < <(sysd_registry_enabled_list)
  log_info "start-all: enabled=true の $n 件を対象"
}

usage() {
  cat <<'USAGE'
📦 systemd-control.sh — 登録プロジェクトの systemd (user) 起動制御
  status [name]                    daemon 可用性 / unit 状態
  scan                             Projects 走査 (推定コマンド/登録状況)
  list                             台帳の登録一覧
  register <name> [--command CMD]  台帳登録 (command 推定 or 明示指定)
  generate <name> [--force]        unit 生成 + daemon-reload
  unregister <name>                台帳 + unit 削除 (disable も実行)
  start <name>                     unit start (未生成なら自動 generate)
  stop <name>                      unit stop
  restart <name>                   unit restart
  enable <name>                    enable --now (login 時自動起動 + linger)
  disable <name>                   disable --now
  logs <name> [args...]            journalctl --user -u
  start-all                        enabled=true の台帳を一括 start
  help                             このヘルプ
  共通: --dry-run で副作用なしの計画表示
USAGE
}

main() {
  # --dry-run は verb の前後どちらに来てもよい。先に全引数から抽出してから verb を決める。
  local a; local -a args=()
  for a in "$@"; do
    if [[ "$a" == "--dry-run" ]]; then DRY_RUN=1; else args+=("$a"); fi
  done
  local verb="${args[0]:-help}"
  local -a rest=()
  (( ${#args[@]} > 1 )) && rest=("${args[@]:1}")
  case "$verb" in
    status)     cmd_status "${rest[0]:-}" ;;
    scan)       cmd_scan ;;
    list)       cmd_list ;;
    register)   [[ ${#rest[@]} -ge 1 ]] || die "register <name> [--command CMD]"; cmd_register "${rest[@]}" ;;
    generate)   [[ ${#rest[@]} -ge 1 ]] || die "generate <name> [--force]"; cmd_generate "${rest[@]}" ;;
    unregister) [[ ${#rest[@]} -ge 1 ]] || die "unregister <name>"; cmd_unregister "${rest[0]}" ;;
    start)      [[ ${#rest[@]} -ge 1 ]] || die "start <name>"; cmd_start "${rest[0]}" ;;
    stop)       [[ ${#rest[@]} -ge 1 ]] || die "stop <name>"; cmd_stop "${rest[0]}" ;;
    restart)    [[ ${#rest[@]} -ge 1 ]] || die "restart <name>"; cmd_restart "${rest[0]}" ;;
    enable)     [[ ${#rest[@]} -ge 1 ]] || die "enable <name>"; cmd_enable "${rest[0]}" ;;
    disable)    [[ ${#rest[@]} -ge 1 ]] || die "disable <name>"; cmd_disable "${rest[0]}" ;;
    logs)       [[ ${#rest[@]} -ge 1 ]] || die "logs <name> [args...]"; cmd_logs "${rest[@]}" ;;
    start-all)  cmd_start_all ;;
    help|-h|--help) usage ;;
    *) log_error "不明なサブコマンド: $verb"; usage; exit 1 ;;
  esac
}

main "$@"
