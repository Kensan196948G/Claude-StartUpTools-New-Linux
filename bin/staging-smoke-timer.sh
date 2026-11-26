#!/usr/bin/env bash
# ============================================================
# staging-smoke-timer.sh — Staging 定期検証 (staging-smoke) の systemd --user timer 登録
#
#   目的: Staging を「置いたまま腐らせない」ため、scripts/e2e/staging-smoke.sh を
#         日次で実行する user timer を登録/解除/確認する。
#   対象: Staging のみ。staging-smoke.sh はリリース成果物を空きポートで起動し、
#         一時 CLAUDEOS_HOME で health と主要 API を検査する**読み取り専用＋一時ディレクトリ**
#         のスモークで、本番の unit・ポート・状態には触れない。
#         そのため unit には CLAUDEOS_HOME を渡さない (スクリプト自身が一時ディレクトリを作る)。
#
#   設計・手順: docs/architecture/STAGING_PRODUCTION_RUNBOOK.md (§3)
#
# 使い方:
#   staging-smoke-timer.sh --register [--interval 24h] [--on-calendar "<expr>"] [--dry-run]
#   staging-smoke-timer.sh --unregister [--dry-run]
#   staging-smoke-timer.sh --status
#   staging-smoke-timer.sh --help
#
#   生成する unit (systemd --user):
#     claudeos-staging-smoke.service  Type=oneshot / ExecStart=<repo>/scripts/e2e/staging-smoke.sh --json
#     claudeos-staging-smoke.timer    OnCalendar=<expr> (既定 *-*-* 05:30:00) / Persistent=true
#
#   --interval は日次の省略記法 (24h / 1d のみ)。それ以外の周期は --on-calendar で指定する。
#   --interval と --on-calendar の同時指定は exit 2 (どちらが正か曖昧にしない)。
#
# 安全:
#   - 本番 unit 名・本番ポートは unit に書かない (定数 + 生成本文の自己検査で担保)。
#   - unit 名は固定 (--unit は用意しない)。実 systemd への反映は人間が実行する。
#   - --dry-run は一切書き込まない (unit 本文の表示のみ)。
#   - systemctl は CCSU_SYSTEMCTL_BIN で差し替え可 (bats スタブ用)。
#   - unit の出力先は CCSU_SYSTEMD_UNIT_DIR (未指定なら CCSU_SYSTEMD_UNIT_PATH の親、
#     それも無ければ ~/.config/systemd/user)。テストは一時ディレクトリを指定する。
#
# exit: 0 成功 / 1 実行エラー (systemctl 失敗等) / 2 引数エラー
# ============================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

UNIT_SERVICE="claudeos-staging-smoke.service"
UNIT_TIMER="claudeos-staging-smoke.timer"
DEFAULT_ON_CALENDAR="*-*-* 05:30:00"
SYSTEMCTL="${CCSU_SYSTEMCTL_BIN:-systemctl}"

# 本番リソースの参照を unit 本文に混ぜない (自己検査に使う)
PROD_TOKENS=("claudeos-web-startup" "3740" "3737" "3741")

STG_ACTION=""
STG_DRY_RUN=0
STG_ON_CALENDAR="$DEFAULT_ON_CALENDAR"
STG_ON_CALENDAR_SET=0
STG_INTERVAL=""
UNIT_DIR=""

_usage() {
  cat <<'USAGE'
staging-smoke-timer.sh — Staging 定期検証 (staging-smoke) の systemd --user timer

USAGE:
  bin/staging-smoke-timer.sh --register [--interval 24h] [--on-calendar "<expr>"] [--dry-run]
  bin/staging-smoke-timer.sh --unregister [--dry-run]
  bin/staging-smoke-timer.sh --status

OPTIONS:
  --register         unit を生成し daemon-reload → enable --now <timer>
  --unregister       disable --now して unit を削除
  --status           list-timers / systemctl show の結果を表示
  --interval <d>     日次の省略記法 (24h / 1d のみ)。他の周期は --on-calendar で指定
  --on-calendar <e>  OnCalendar 式 (既定 *-*-* 05:30:00)。Persistent=true で補完実行
  --dry-run          書き込まずに unit 本文と計画を表示
  -h, --help         このヘルプ

生成する unit: claudeos-staging-smoke.service / claudeos-staging-smoke.timer
対象は Staging のみ (本番 unit・本番ポートは書きません)。登録の実行は人間が行います。
USAGE
}

# stg_timer__require_value <opt> <value> — 値を伴うオプションの欠落を exit 2
stg_timer__require_value() {
  local opt="$1" value="${2:-}"
  if [[ -z "$value" ]]; then
    log_error "$opt には値が必要です"
    exit 2
  fi
}

# stg_timer__no_control_chars <name> <value> — unit への行注入 (改行/CR) を拒否
stg_timer__no_control_chars() {
  local name="$1" value="$2"
  case "$value" in
    *$'\n'*|*$'\r'*)
      log_error "$name に改行/復帰文字は使えません"
      exit 2
      ;;
  esac
}

# stg_timer__validate_on_calendar <expr> — OnCalendar 式の検証 (exit 2)
#   systemd の文法全体は再実装しない。ここでは「空白区切りの英数字・記号のみ」かつ
#   「数値か時刻キーワードを含む」ことを確認し、明らかな誤りと行注入だけを弾く。
stg_timer__validate_on_calendar() {
  local expr="$1"
  stg_timer__no_control_chars "--on-calendar" "$expr"
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

# stg_timer__apply_interval <value> — --interval を日次の OnCalendar へ写す
stg_timer__apply_interval() {
  local value="$1"
  case "$value" in
    24h|24H|1d|1D)
      # 既定と同じ日次。明示指定でも意味が変わらないことを保証する。
      STG_ON_CALENDAR="$DEFAULT_ON_CALENDAR"
      STG_ON_CALENDAR_SET=1
      ;;
    *)
      log_error "--interval は日次 (24h / 1d) のみ対応です: $value"
      log_error "  他の周期は --on-calendar で指定してください (例: --on-calendar '*-*-* 05:30,17:30:00')"
      exit 2
      ;;
  esac
}

# stg_timer__resolve_unit_dir — unit の出力先を決める
stg_timer__resolve_unit_dir() {
  if [[ -n "${CCSU_SYSTEMD_UNIT_DIR:-}" ]]; then
    UNIT_DIR="$CCSU_SYSTEMD_UNIT_DIR"
  elif [[ -n "${CCSU_SYSTEMD_UNIT_PATH:-}" ]]; then
    UNIT_DIR="$(dirname "$CCSU_SYSTEMD_UNIT_PATH")"
  else
    UNIT_DIR="$HOME/.config/systemd/user"
  fi
  stg_timer__no_control_chars "unit ディレクトリ" "$UNIT_DIR"
}

# stg_timer__service_body — service unit の本文 (stdout)
stg_timer__service_body() {
  local bash_bin
  bash_bin="$(command -v bash || echo /usr/bin/bash)"
  cat <<EOF
[Unit]
Description=ClaudeOS staging smoke (release artifact health check, read-only)
Documentation=file:$CCSU_ROOT/docs/architecture/STAGING_PRODUCTION_RUNBOOK.md
After=network.target

[Service]
Type=oneshot
WorkingDirectory=$CCSU_ROOT
# Staging 専用の読み取りスモーク。空きポートで起動し、状態は一時 CLAUDEOS_HOME に閉じる。
# CLAUDEOS_HOME は渡さない (staging-smoke.sh 自身が mktemp で作る)。
ExecStart=$bash_bin $CCSU_ROOT/scripts/e2e/staging-smoke.sh --json
NoNewPrivileges=yes
PrivateTmp=yes
EOF
}

# stg_timer__timer_body — timer unit の本文 (stdout)
stg_timer__timer_body() {
  cat <<EOF
[Unit]
Description=Daily ClaudeOS staging smoke (staging-smoke.sh)

[Timer]
OnCalendar=$STG_ON_CALENDAR
Persistent=true
Unit=$UNIT_SERVICE

[Install]
WantedBy=timers.target
EOF
}

# stg_timer__assert_staging_only <body> — 本番の参照が混ざっていないことを自己検査
stg_timer__assert_staging_only() {
  local body="$1" tok
  for tok in "${PROD_TOKENS[@]}"; do
    if printf '%s\n' "$body" | grep -q -- "$tok"; then
      log_error "生成 unit に本番の参照 ($tok) が含まれます (Staging 専用に反します)"
      exit 1
    fi
  done
}

# stg_timer__write_unit <path> <body> — 同一ディレクトリ内で作って rename する
stg_timer__write_unit() {
  local path="$1" body="$2" tmpf
  tmpf="$(mktemp "$(dirname "$path")/.stg-unit.XXXXXX")"
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

stg_timer__register() {
  local svc_body timer_body
  svc_body="$(stg_timer__service_body)"
  timer_body="$(stg_timer__timer_body)"
  stg_timer__assert_staging_only "$svc_body"
  stg_timer__assert_staging_only "$timer_body"

  if (( STG_DRY_RUN )); then
    log_info "dry-run: Staging 定期検証タイマーの登録計画 (systemd --user)"
    log_info "  service = $UNIT_DIR/$UNIT_SERVICE"
    log_info "  timer   = $UNIT_DIR/$UNIT_TIMER"
    log_info "  OnCalendar = $STG_ON_CALENDAR (Persistent=true)"
    log_info "  dry-run: 以下を書き込み、daemon-reload → enable --now $UNIT_TIMER を行います"
    printf '%s\n' "$svc_body" | sed 's/^/    /'
    printf '%s\n' "$timer_body" | sed 's/^/    /'
    log_info "dry-run: systemd への書き込みは行いません"
    return 0
  fi

  mkdir -p -- "$UNIT_DIR" || die "unit ディレクトリを作成できません: $UNIT_DIR"
  stg_timer__write_unit "$UNIT_DIR/$UNIT_SERVICE" "$svc_body"
  stg_timer__write_unit "$UNIT_DIR/$UNIT_TIMER" "$timer_body"
  "$SYSTEMCTL" --user daemon-reload || die "systemctl --user daemon-reload に失敗しました"
  "$SYSTEMCTL" --user enable --now "$UNIT_TIMER" || die "systemctl --user enable --now $UNIT_TIMER に失敗しました"
  # ログアウト中も回すため linger を有効化する (失敗しても登録自体は成立させる)
  if has_cmd loginctl; then
    loginctl enable-linger "$USER" 2>/dev/null || log_warn "loginctl enable-linger に失敗しました (ログアウト中は実行されません)"
  fi
  log_ok "Staging 定期検証タイマーを登録しました: $UNIT_TIMER"
  log_info "  OnCalendar = $STG_ON_CALENDAR / Persistent=true"
  log_info "  次回以降: $0 --status で確認 / $0 --unregister で解除"
}

stg_timer__unregister() {
  if (( STG_DRY_RUN )); then
    log_info "dry-run: $UNIT_TIMER を disable --now し、次の unit を削除する計画:"
    log_info "  $UNIT_DIR/$UNIT_SERVICE"
    log_info "  $UNIT_DIR/$UNIT_TIMER"
    log_info "dry-run: systemd は変更しません"
    return 0
  fi
  "$SYSTEMCTL" --user disable --now "$UNIT_TIMER" 2>/dev/null || true
  rm -f -- "$UNIT_DIR/$UNIT_SERVICE" "$UNIT_DIR/$UNIT_TIMER"
  "$SYSTEMCTL" --user daemon-reload 2>/dev/null || true
  log_ok "Staging 定期検証タイマーを解除しました: $UNIT_TIMER"
}

stg_timer__status() {
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
  log_info "  最後の実行 (service):"
  "$SYSTEMCTL" --user show "$UNIT_SERVICE" \
    --property=ActiveState,Result,ExecMainStatus,ExecMainExitTimestamp \
    --no-pager 2>/dev/null | sed 's/^/    /' || log_warn "service の状態を取得できません"
  if [[ -f "$timer_path" ]]; then
    log_info "  OnCalendar: $(grep -E '^OnCalendar=' "$timer_path" 2>/dev/null || echo '(不明)')"
  fi
}

main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --register)   STG_ACTION="register"; shift ;;
      --unregister) STG_ACTION="unregister"; shift ;;
      --status)     STG_ACTION="status"; shift ;;
      --interval)
        stg_timer__require_value "$1" "${2:-}"
        if (( STG_ON_CALENDAR_SET )); then
          log_error "--interval と --on-calendar は同時に指定できません"
          exit 2
        fi
        STG_INTERVAL="$2"
        stg_timer__apply_interval "$2"
        shift 2 ;;
      --on-calendar)
        stg_timer__require_value "$1" "${2:-}"
        if [[ -n "$STG_INTERVAL" ]]; then
          log_error "--interval と --on-calendar は同時に指定できません"
          exit 2
        fi
        stg_timer__validate_on_calendar "$2"
        STG_ON_CALENDAR="$2"
        STG_ON_CALENDAR_SET=1
        shift 2 ;;
      --dry-run)    STG_DRY_RUN=1; shift ;;
      -h|--help)    _usage; exit 0 ;;
      *) log_error "不明な引数: $1"; _usage >&2; exit 2 ;;
    esac
  done

  if [[ -z "$STG_ACTION" ]]; then
    log_error "--register / --unregister / --status のいずれかを指定してください"
    _usage >&2
    exit 2
  fi

  stg_timer__resolve_unit_dir
  # --interval 未指定でも既定値を検証する (定数の取り違えを検出)
  stg_timer__validate_on_calendar "$STG_ON_CALENDAR"

  if [[ "$STG_ACTION" != "status" ]] && (( ! STG_DRY_RUN )); then
    has_cmd "$SYSTEMCTL" || die "systemctl が見つかりません: $SYSTEMCTL"
  fi

  case "$STG_ACTION" in
    register)   stg_timer__register ;;
    unregister) stg_timer__unregister ;;
    status)     stg_timer__status ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
