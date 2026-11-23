#!/usr/bin/env bash
# ============================================================
# cross-repo-automerge-timer.sh — 横断自動マージ巡回の systemd --user timer 登録
#
#   目的: bin/cross-repo-automerge.sh を毎時回す user timer を登録/解除/確認する。
#   前提: 巡回ツール側は既定 dry-run。timer からは --apply を明示して実行する。
#         対象・安全条件（ruleset 保有 repo のみ / dependabot・renovate の
#         マイナー・パッチのみ / 失敗・保留・競合はスキップ）は巡回ツールが担保する。
#
# 使い方:
#   cross-repo-automerge-timer.sh --register [--on-calendar "<expr>"] [--dry-run]
#   cross-repo-automerge-timer.sh --unregister [--dry-run]
#   cross-repo-automerge-timer.sh --status
#   cross-repo-automerge-timer.sh --help
#
#   生成する unit (systemd --user):
#     claudeos-cross-repo-automerge.service  Type=oneshot / ExecStart=<repo>/bin/cross-repo-automerge.sh --apply --json
#     claudeos-cross-repo-automerge.timer    OnCalendar=<expr> (既定 *-*-* *:15:00) / Persistent=true
#
# 安全:
#   - unit 名は固定（--unit は用意しない）。実 systemd への反映は人間が実行する。
#   - --dry-run は一切書き込まない（unit 本文の表示のみ）。
#   - 本番の web サービス名・ポートは unit 本文に書かない（自己検査で担保）。
#   - systemctl は CCSU_SYSTEMCTL_BIN で差し替え可（bats スタブ用）。
#   - unit の出力先は CCSU_SYSTEMD_UNIT_DIR（未指定なら CCSU_SYSTEMD_UNIT_PATH の親、
#     それも無ければ ~/.config/systemd/user）。
#
# exit: 0 成功 / 1 実行エラー (systemctl 失敗等) / 2 引数エラー
# ============================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

UNIT_SERVICE="claudeos-cross-repo-automerge.service"
UNIT_TIMER="claudeos-cross-repo-automerge.timer"
DEFAULT_ON_CALENDAR="*-*-* *:15:00"
SYSTEMCTL="${CCSU_SYSTEMCTL_BIN:-systemctl}"

# 本番の参照を unit 本文に混ぜない（自己検査に使う）
PROD_TOKENS=("claudeos-web-startup" "3740" "3737" "3741")

ACT=""
DRY_RUN=0
ON_CALENDAR="$DEFAULT_ON_CALENDAR"
UNIT_DIR=""

_usage() {
  cat <<'USAGE'
cross-repo-automerge-timer.sh — 横断自動マージ巡回の systemd --user timer

USAGE:
  bin/cross-repo-automerge-timer.sh --register [--on-calendar "<expr>"] [--dry-run]
  bin/cross-repo-automerge-timer.sh --unregister [--dry-run]
  bin/cross-repo-automerge-timer.sh --status

OPTIONS:
  --register         unit を生成し daemon-reload → enable --now <timer>
  --unregister       disable --now して unit を削除
  --status           list-timers / systemctl show の結果を表示
  --on-calendar <e>  OnCalendar 式 (既定 *-*-* *:15:00 = 毎時 15 分)
  --dry-run          書き込まずに unit 本文と計画を表示
  -h, --help         このヘルプ

生成する unit: claudeos-cross-repo-automerge.service / .timer
ExecStart は bin/cross-repo-automerge.sh --apply --json。登録の実行は人間が行います。
USAGE
}

timer__require_value() {
  local opt="$1" value="${2:-}"
  if [[ -z "$value" ]]; then
    log_error "$opt には値が必要です"
    exit 2
  fi
}

timer__no_control_chars() {
  local name="$1" value="$2"
  case "$value" in
    *$'\n'*|*$'\r'*)
      log_error "$name に改行/復帰文字は使えません"
      exit 2
      ;;
  esac
}

timer__validate_on_calendar() {
  local expr="$1"
  timer__no_control_chars "--on-calendar" "$expr"
  if [[ -z "$expr" ]]; then
    log_error "--on-calendar には式が必要です"
    exit 2
  fi
  if [[ ! "$expr" =~ ^[A-Za-z0-9*:,.~/+_\ -]+$ ]]; then
    log_error "--on-calendar に使えない文字が含まれています: $expr"
    exit 2
  fi
  if [[ ! "$expr" =~ [0-9] ]] && \
     [[ ! "$expr" =~ ^(minutely|hourly|daily|weekly|monthly|quarterly|semi-annually|yearly|annually)$ ]]; then
    log_error "--on-calendar の式が不正です (時刻・日付・キーワードのいずれかが必要): $expr"
    exit 2
  fi
}

timer__resolve_unit_dir() {
  if [[ -n "${CCSU_SYSTEMD_UNIT_DIR:-}" ]]; then
    UNIT_DIR="$CCSU_SYSTEMD_UNIT_DIR"
  elif [[ -n "${CCSU_SYSTEMD_UNIT_PATH:-}" ]]; then
    UNIT_DIR="$(dirname "$CCSU_SYSTEMD_UNIT_PATH")"
  else
    UNIT_DIR="$HOME/.config/systemd/user"
  fi
  timer__no_control_chars "unit ディレクトリ" "$UNIT_DIR"
}

timer__service_body() {
  local bash_bin
  bash_bin="$(command -v bash || echo /usr/bin/bash)"
  cat <<EOF
[Unit]
Description=ClaudeOS cross-repo automerge patrol (dependabot/renovate minor-patch only)
After=network.target

[Service]
Type=oneshot
WorkingDirectory=$CCSU_ROOT
# 既定 dry-run のツールを、timer からは --apply で回す。
# 対象・安全条件はツール側が担保する (ruleset 保有 repo のみ / bot のマイナー・パッチのみ /
# 失敗・保留・競合はスキップ / 同一 repo 1 回 1 件)。
ExecStart=$bash_bin $CCSU_ROOT/bin/cross-repo-automerge.sh --apply --json
NoNewPrivileges=yes
PrivateTmp=yes
EOF
}

timer__timer_body() {
  cat <<EOF
[Unit]
Description=Hourly ClaudeOS cross-repo automerge patrol

[Timer]
OnCalendar=$ON_CALENDAR
Persistent=true
Unit=$UNIT_SERVICE

[Install]
WantedBy=timers.target
EOF
}

timer__assert_no_prod_tokens() {
  local body="$1" tok
  for tok in "${PROD_TOKENS[@]}"; do
    if printf '%s\n' "$body" | grep -q -- "$tok"; then
      log_error "生成 unit に本番の参照 ($tok) が含まれます"
      exit 1
    fi
  done
}

timer__write_unit() {
  local path="$1" body="$2" tmpf
  tmpf="$(mktemp "$(dirname "$path")/.am-unit.XXXXXX")"
  if ! printf '%s\n' "$body" > "$tmpf"; then
    rm -f -- "$tmpf"
    die "unit を書き込めません: $path"
  fi
  chmod 644 "$tmpf"
  if ! mv -f -- "$tmpf" "$path"; then
    rm -f -- "$tmpf"
    die "unit を配置できません: $path"
  fi
}

timer__register() {
  local svc_body timer_body
  svc_body="$(timer__service_body)"
  timer_body="$(timer__timer_body)"
  timer__assert_no_prod_tokens "$svc_body"
  timer__assert_no_prod_tokens "$timer_body"

  if (( DRY_RUN )); then
    log_info "dry-run: 横断自動マージ巡回タイマーの登録計画 (systemd --user)"
    log_info "  service = $UNIT_DIR/$UNIT_SERVICE"
    log_info "  timer   = $UNIT_DIR/$UNIT_TIMER"
    log_info "  OnCalendar = $ON_CALENDAR (Persistent=true)"
    log_info "  dry-run: 以下を書き込み、daemon-reload → enable --now $UNIT_TIMER を行います"
    printf '%s\n' "$svc_body" | sed 's/^/    /'
    printf '%s\n' "$timer_body" | sed 's/^/    /'
    log_info "dry-run: systemd への書き込みは行いません"
    return 0
  fi

  mkdir -p -- "$UNIT_DIR" || die "unit ディレクトリを作成できません: $UNIT_DIR"
  timer__write_unit "$UNIT_DIR/$UNIT_SERVICE" "$svc_body"
  timer__write_unit "$UNIT_DIR/$UNIT_TIMER" "$timer_body"
  "$SYSTEMCTL" --user daemon-reload || die "systemctl --user daemon-reload に失敗しました"
  "$SYSTEMCTL" --user enable --now "$UNIT_TIMER" || die "systemctl --user enable --now $UNIT_TIMER に失敗しました"
  if has_cmd loginctl; then
    loginctl enable-linger "$USER" 2>/dev/null || log_warn "loginctl enable-linger に失敗しました (ログアウト中は実行されません)"
  fi
  log_ok "横断自動マージ巡回タイマーを登録しました: $UNIT_TIMER"
  log_info "  OnCalendar = $ON_CALENDAR / Persistent=true"
  log_info "  次回以降: $0 --status で確認 / $0 --unregister で解除"
}

timer__unregister() {
  if (( DRY_RUN )); then
    log_info "dry-run: $UNIT_TIMER を disable --now し、次の unit を削除する計画:"
    log_info "  $UNIT_DIR/$UNIT_SERVICE"
    log_info "  $UNIT_DIR/$UNIT_TIMER"
    log_info "dry-run: systemd は変更しません"
    return 0
  fi
  "$SYSTEMCTL" --user disable --now "$UNIT_TIMER" 2>/dev/null || true
  rm -f -- "$UNIT_DIR/$UNIT_SERVICE" "$UNIT_DIR/$UNIT_TIMER"
  "$SYSTEMCTL" --user daemon-reload 2>/dev/null || true
  log_ok "横断自動マージ巡回タイマーを解除しました: $UNIT_TIMER"
}

timer__status() {
  local svc_path="$UNIT_DIR/$UNIT_SERVICE" timer_path="$UNIT_DIR/$UNIT_TIMER"
  log_info "unit: $UNIT_TIMER"
  log_info "  service file : $svc_path ($([[ -f "$svc_path" ]] && echo 登録済み || echo 未登録))"
  log_info "  timer file   : $timer_path ($([[ -f "$timer_path" ]] && echo 登録済み || echo 未登録))"
  log_info "  list-timers:"
  "$SYSTEMCTL" --user list-timers "$UNIT_TIMER" --all --no-pager 2>/dev/null \
    | sed 's/^/    /' || log_warn "list-timers を取得できません"
  log_info "  timer:"
  "$SYSTEMCTL" --user show "$UNIT_TIMER" \
    --property=UnitFileState,ActiveState,NextElapseUSecRealtime,LastTriggerUSec,Persistent \
    --no-pager 2>/dev/null | sed 's/^/    /' || log_warn "timer の状態を取得できません"
  if [[ -f "$timer_path" ]]; then
    log_info "  OnCalendar: $(grep -E '^OnCalendar=' "$timer_path" 2>/dev/null || echo '(不明)')"
  fi
}

main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --register)   ACT="register"; shift ;;
      --unregister) ACT="unregister"; shift ;;
      --status)     ACT="status"; shift ;;
      --on-calendar)
        timer__require_value "$1" "${2:-}"
        timer__validate_on_calendar "$2"
        ON_CALENDAR="$2"
        shift 2 ;;
      --dry-run)    DRY_RUN=1; shift ;;
      -h|--help)    _usage; exit 0 ;;
      *) log_error "不明な引数: $1"; _usage >&2; exit 2 ;;
    esac
  done

  if [[ -z "$ACT" ]]; then
    log_error "--register / --unregister / --status のいずれかを指定してください"
    _usage >&2
    exit 2
  fi

  timer__resolve_unit_dir
  timer__validate_on_calendar "$ON_CALENDAR"

  if [[ "$ACT" != "status" ]] && (( ! DRY_RUN )); then
    has_cmd "$SYSTEMCTL" || die "systemctl が見つかりません: $SYSTEMCTL"
  fi

  case "$ACT" in
    register)   timer__register ;;
    unregister) timer__unregister ;;
    status)     timer__status ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
