#!/usr/bin/env bash
# ============================================================
# start-claude.sh — ClaudeCode 起動エントリ (Linux native)
#
# Linux ローカル Claude 起動。
#   多重起動防止: supervisor/flock。tmux は --tmux 明示時のみ fallback として使う。
#
# 使い方 (menu.sh から):
#   start-claude.sh --project P --foreground [--duration 300]          # L1: headless/log 既定
#   start-claude.sh --project P --background [--duration 300]          # S1: supervisor BG
#   start-claude.sh --project P --safe-mode  [--duration 300] [--tmux] # 診断: hooks/MCP 無効の素起動
#   --local は互換用 (ローカル一本化のため常にローカル)
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
# shellcheck source=lib/notify.sh
source "$SCRIPT_DIR/../lib/notify.sh"

direct__run_safe_mode() {
  local project="$1" duration="$2" mode="$3" dur_sec log_file stamp safe runner
  dur_sec=$((duration * 60))
  safe="$(ccsu_safe_name "$project")"
  mkdir -p "$CCSU_HOME/logs"
  stamp="$(date +%Y%m%d-%H%M%S)"
  log_file="$CCSU_HOME/logs/manual-safe-${stamp}-${safe}.log"

  if [[ "$mode" == "foreground" ]]; then
    log_info "🩺 safe-mode 直接起動: $project (tmux なし / Ctrl+C 可)"
    ( cd "$(launcher__project_dir "$project")" && timeout --foreground "${dur_sec}s" "$CLAUDE_BIN" --safe-mode )
  else
    if has_cmd setsid; then runner=setsid; else runner=nohup; fi
    "$runner" bash -c 'cd "$1" && timeout --foreground "$2" "$3" --safe-mode' \
      _ "$(launcher__project_dir "$project")" "${dur_sec}s" "$CLAUDE_BIN" >>"$log_file" 2>&1 < /dev/null &
    disown 2>/dev/null || true
    log_ok "safe-mode BG 起動: $project (tmux なし)"
    log_info "  ログ: $log_file"
  fi
}

direct__run_headless_once() {
  local project="$1" duration="$2" mode="$3" dur_sec project_dir prompt="" log_file stamp safe runner
  dur_sec=$((duration * 60))
  project_dir="$(launcher__project_dir "$project")"
  safe="$(ccsu_safe_name "$project")"
  mkdir -p "$CCSU_HOME/logs"
  stamp="$(date +%Y%m%d-%H%M%S)"
  log_file="$CCSU_HOME/logs/manual-direct-${stamp}-${safe}.log"

  template_sync__apply "$project_dir"
  [[ -f "$project_dir/.claude/START_PROMPT.md" ]] && prompt="$(cat "$project_dir/.claude/START_PROMPT.md")"

  if [[ "$mode" == "foreground" ]]; then
    log_info "🔧 直接 headless 起動: $project (tmux なし / Ctrl+C 可)"
    if [[ -f "$SCRIPT_DIR/../libexec/stream-json-tail.sh" ]]; then
      local rc
      set +e
      ( cd "$project_dir" && timeout --foreground "${dur_sec}s" "$CLAUDE_BIN" -p "$prompt" --output-format stream-json --verbose --permission-mode auto ) \
        | bash "$SCRIPT_DIR/../libexec/stream-json-tail.sh"
      rc="${PIPESTATUS[0]}"
      set -e
      return "$rc"
    fi
    ( cd "$project_dir" && timeout --foreground "${dur_sec}s" "$CLAUDE_BIN" -p "$prompt" --output-format stream-json --verbose --permission-mode auto )
  else
    local prompt_file wrapper
    prompt_file="$CCSU_HOME/logs/manual-direct-${stamp}-${safe}.prompt"
    wrapper="$CCSU_HOME/logs/manual-direct-${stamp}-${safe}.sh"
    printf '%s' "$prompt" > "$prompt_file"
    cat > "$wrapper" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
project_dir="$1"; dur="$2"; claude_bin="$3"; prompt_file="$4"
prompt="$(cat "$prompt_file" 2>/dev/null || true)"
cd "$project_dir"
timeout --foreground "$dur" "$claude_bin" -p "$prompt" --output-format stream-json --verbose --permission-mode auto
EOF
    chmod +x "$wrapper"
    if has_cmd setsid; then runner=setsid; else runner=nohup; fi
    "$runner" bash "$wrapper" "$project_dir" "${dur_sec}s" "$CLAUDE_BIN" "$prompt_file" >>"$log_file" 2>&1 < /dev/null &
    disown 2>/dev/null || true
    log_ok "直接 headless BG 起動: $project (tmux なし)"
    log_info "  ログ: $log_file"
  fi
}

main() {
  local project="" mode="foreground" duration=300 safe_mode=0 use_tmux=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --project)    project="$2"; shift 2 ;;
      --foreground) mode="foreground"; shift ;;
      --background) mode="background"; shift ;;
      --duration)   duration="$2"; shift 2 ;;
      --safe-mode)  safe_mode=1; shift ;;
      --tmux)       use_tmux=1; shift ;;
      --local)      shift ;;   # 互換: ローカル一本化のため無視
      *) log_error "不明な引数: $1"; exit 1 ;;
    esac
  done

  require_cmd claude "npm i -g @anthropic-ai/claude-code"

  # メール送信用に ~/.env-claudeos を読み込む (SMTP creds / CLAUDEOS_EMAIL_ENABLED)。
  # cron-launcher.sh と同様。set -a で sourced 変数を確実に export し、
  # tmux_run が起動する終了レポート watcher (setsid 子プロセス) へ継承させる。
  # テストは CCSU_SKIP_ENV_FILE=1 でスキップ。
  if [[ "${CCSU_SKIP_ENV_FILE:-0}" != "1" && -f "$HOME/.env-claudeos" ]]; then
    # shellcheck disable=SC1091
    set -a; source "$HOME/.env-claudeos"; set +a
  fi

  [[ -z "$project" ]] && project="$(launcher__select_project)"
  [[ -n "$project" ]] || { log_error "プロジェクトが選択されていません"; exit 1; }
  launcher__project_exists "$project" || { log_error "プロジェクトが存在しません: $(launcher__project_dir "$project")"; exit 1; }

  notify__play claude   # 起動通知音 (非ブロッキング・失敗無害)

  # --safe-mode: 診断起動 (claude 2.1.169+ の --safe-mode で hooks/MCP 無効の素起動)。
  # supervisor (autonomy.sh) を経由しない。tmux は --tmux 明示時だけ使う。
  # 環境起因の起動不能・hook 暴走などの切り分けに使う。
  if [[ "$safe_mode" == "1" ]]; then
    log_info "🩺 safe-mode 診断起動: supervisor 非経由・自動再起動なし ($project)"
    if (( use_tmux )); then
      CCSU_CLAUDE_SAFE_MODE=1 tmux_run "$project" "$duration" "$mode"
    else
      direct__run_safe_mode "$project" "$duration" "$mode"
    fi
    return 0
  fi

  local safe session
  safe="$(ccsu_safe_name "$project")"
  session="claudeos-$safe"

  # supervisor state ファイル: start 前の mtime を baseline として記録する。
  # start 後に mtime が前進する (= supervisor が今回 state を書き換えた) のを
  # 待ってから status を読むことで、前回 run の stale な blocked/stopped/goal-reached
  # を誤検出しないようにする (ファイル存在チェックだけでは古い状態を拾う)。
  # supervisor.sh と同一の解決式に揃える (CCSU_SUP_DIR / CLAUDEOS_HOME 上書きを尊重)。
  # 既定 (両 override 未設定) は $HOME/.claudeos/supervisor で従来どおり非破壊。
  local _sup_state="${CCSU_SUP_DIR:-$CCSU_HOME/supervisor}/${safe}.json"
  local _sup_mtime_before
  _sup_mtime_before="$(stat -c %Y "$_sup_state" 2>/dev/null || echo 0)"

  # supervisor 経由で起動 (--force: cron 競合があっても手動起動を優先)
  bash "$SCRIPT_DIR/autonomy.sh" start "$project" --duration "$duration" --force || {
    log_error "🤖 supervisor 起動に失敗しました: $project"; exit 1
  }

  # supervisor が今回の起動で state を更新する (mtime 前進) のを最大 ~3 秒待機。
  # mtime が動かないまま timeout した場合は従来どおり現状の state を読む。
  local _w _sup_mtime_now
  for ((_w = 0; _w < 15; _w++)); do
    _sup_mtime_now="$(stat -c %Y "$_sup_state" 2>/dev/null || echo 0)"
    [[ "$_sup_mtime_now" -gt "$_sup_mtime_before" ]] && break
    sleep 0.2
  done

  # supervisor が即時停止した場合 (blocked/stopped/goal-reached) を検出し対処
  local _sup_status="" _sup_reason=""
  if [[ -f "$_sup_state" ]]; then
    _sup_status="$(jq -r '.status // ""' "$_sup_state" 2>/dev/null || true)"
    _sup_reason="$(jq -r '.last_reason // ""' "$_sup_state" 2>/dev/null || true)"
  fi

  if [[ "$_sup_status" =~ ^(blocked|stopped|goal-reached)$ ]]; then
    log_warn "🛑 supervisor 停止 (status=$_sup_status)"
    log_warn "📋 停止理由: $_sup_reason"

    # プロジェクトの blocked_issues をリスト表示
    local _pstate _blocked_list
    _pstate="$(config_projects_dir)/$project/state.json"
    if [[ -f "$_pstate" ]] && has_cmd jq; then
      _blocked_list="$(jq -r '.blocked_issues[]? // empty' "$_pstate" 2>/dev/null || true)"
      if [[ -n "$_blocked_list" ]]; then
        log_warn "🚫 Blocked Issues:"
        while IFS= read -r _bi; do
          log_warn "  🔒 $_bi"
        done <<< "$_blocked_list"
      fi
    fi

    printf "\n"
    log_info "📌 ※ supervisorは blocked_issues が存在する間、自律起動を行いません"
    log_info "📌 ※ Y で起動した場合: 自動再起動なし (手動起動モード)"

    if [[ "$mode" == "foreground" ]]; then
      local _ans
      printf "  直接起動しますか? (Y/N): "
      read -r _ans
      if [[ "${_ans^^}" == "Y" ]]; then
        log_info "🔧 手動モードで起動します (supervisor なし・自動再起動なし)"
        if (( use_tmux )); then
          tmux_run "$project" "$duration" "$mode"
        else
          direct__run_headless_once "$project" "$duration" "$mode"
        fi
      else
        log_info "⏹️  起動をキャンセルしました"
        log_info "  💡 blocked_issues を解消すると supervisor 経由で正常起動できます"
      fi
    elif [[ "$mode" == "background" ]]; then
      local _ans
      printf "  直接起動しますか? (Y/N) [背景: 自動再起動なし]: "
      read -r _ans
      if [[ "${_ans^^}" == "Y" ]]; then
        log_info "🔧 手動モードで起動します (supervisor なし・自動再起動なし)"
        if (( use_tmux )); then
          tmux_run "$project" "$duration" "$mode"
        else
          direct__run_headless_once "$project" "$duration" "$mode"
        fi
      else
        log_info "⏹️  起動をキャンセルしました"
      fi
    fi
    return 0
  fi

  if [[ "$mode" == "foreground" ]]; then
    if [[ "${CLAUDEOS_HEADLESS:-1}" == "1" ]]; then
      # headless 既定: cron-launcher は `claude -p` を回すだけで対話 tmux セッション
      # (claudeos-<safe>) を生成しない。よって tmux を待つのは構造的に空振りする。
      # 代わりに supervisor が setsid 経由で書き出す per-project ログを追尾し、
      # foreground らしい「進捗が見える」体験を提供する (Ctrl-C で tail 終了・
      # supervisor は独立プロセスのため停止しない)。
      local _suplog="${_sup_state%.json}.log"
      log_info "🚀 headless モードで起動中: $project"
      log_info "  💡 対話 tmux セッションは生成されません (headless: claude -p)"
      log_info "  📡 supervisor は独立プロセスで継続します (Ctrl-C で追尾終了・supervisor は停止しません)"
      log_info "  📊 状態: bash bin/autonomy.sh status $project"
      log_info "  🛑 停止: bash bin/autonomy.sh stop $project    (--now で即停止)"
      # ログが書き出されるまで軽く待機 (最大 ~5 秒)
      local _t
      for ((_t = 0; _t < 25; _t++)); do
        [[ -f "$_suplog" ]] && break
        sleep 0.2
      done
      if [[ -f "$_suplog" ]]; then
        if (( use_tmux )) && [[ -n "${TMUX:-}" ]] && command -v "$TMUX_BIN" >/dev/null 2>&1; then
          # tmux 内: 追尾ログを別ウィンドウ(別タブ)で開き、メニュー端末は即解放する。
          # new-window は本スクリプトのプロセスから独立するため、戻っても supervisor は継続。
          local _q
          printf -v _q '%q' "$_suplog"
          # shellcheck disable=SC2086  # _q は printf %q で安全に pre-quote 済み
          if "$TMUX_BIN" new-window -n "follow:$(basename "$project")" "tail -n 20 -f $_q" 2>/dev/null; then
            log_ok "  🪟 追尾ログを tmux 別ウィンドウ(別タブ)で開きました: $_suplog"
            log_info "     Ctrl-b n / Ctrl-b w で切替・閉じても supervisor は継続します"
          else
            log_warn "  ⚠️  tmux 別ウィンドウ生成に失敗 — 手動で追尾してください"
            log_info "  📜 別タブで追尾: tail -f $_suplog"
          fi
        else
          # tmux 外: メニュー端末をブロックせず即復帰し、別端末での追尾手順を案内する。
          log_info "  📜 別タブ/別端末で追尾するには: tail -f $_suplog"
          log_info "     (この端末はメニュー操作へ戻ります・supervisor は独立継続)"
        fi
      else
        log_warn "  ⏳ ログ未生成: $_suplog"
        log_info "  🔍 確認: bash bin/autonomy.sh status $project"
      fi
    else
      if (( use_tmux )); then
        # TUI + tmux 明示時のみ従来どおり tmux セッションへ attach。
        local i
        for ((i = 0; i < 60; i++)); do
          "$TMUX_BIN" has-session -t "$session" 2>/dev/null && break
          sleep 0.5
        done
        if "$TMUX_BIN" has-session -t "$session" 2>/dev/null; then
          log_info "🔗 セッションへ接続: $session"
          "$TMUX_BIN" attach-session -t "$session"
        else
          log_warn "⏱️  tmux セッション起動待ちタイムアウト: $session"
          log_info "  🔍 確認: tmux ls  /  bash bin/autonomy.sh status $project"
        fi
      else
        local _suplog="${_sup_state%.json}.log"
        log_info "🚀 TUI fallback を tmux なしで起動しました: $project"
        log_info "  📜 ログ: $_suplog"
        log_info "  📊 状態: bash bin/autonomy.sh status $project"
      fi
    fi
  fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
