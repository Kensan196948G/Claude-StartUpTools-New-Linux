#!/usr/bin/env bash
# ============================================================
# start-claude.sh — ClaudeCode 起動エントリ (Linux native)
#
# Linux ローカル Claude 起動。
#   多重起動防止: supervisor/flock。tmux は --tmux 明示時のみ fallback として使う。
#
# 使い方 (menu.sh から):
#   start-claude.sh --project P --foreground [--duration 300] [--dry-run]          # L1: 新規端末タブで Claude TUI (既定 0=無制限)
#   start-claude.sh --project P --background [--duration 300] [--dry-run]          # S1: supervisor BG
#   start-claude.sh --project P --safe-mode  [--duration 300] [--tmux] [--dry-run] # 診断: hooks/MCP 無効の素起動
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
# shellcheck source=lib/model-router.sh
source "$SCRIPT_DIR/../lib/model-router.sh"

claude__select_model() {
  local project="$1" task="$2" source="$3" record="${4:-0}"
  unset CLAUDEOS_SELECTED_MODEL CLAUDEOS_SELECTED_EFFORT CLAUDEOS_SELECTED_MODEL_KEY CLAUDEOS_SELECTED_MODEL_REASON
  model_router__select "$task" || return 0
  [[ "${MODEL_ROUTER_ENABLED:-1}" == "1" && -n "${MODEL_ROUTER_MODEL:-}" ]] || return 0
  export CLAUDEOS_SELECTED_MODEL="$MODEL_ROUTER_MODEL"
  export CLAUDEOS_SELECTED_EFFORT="$MODEL_ROUTER_EFFORT"
  export CLAUDEOS_SELECTED_MODEL_KEY="$MODEL_ROUTER_KEY"
  export CLAUDEOS_SELECTED_MODEL_REASON="$MODEL_ROUTER_REASON"
  (( record )) && model_router__record_selection "$project" "$source" "$task"
}

terminal__open_tab() {
  local title="$1" wrapper="$2"
  shift 2

  [[ "${CCSU_DISABLE_TERMINAL_TAB:-0}" == "1" ]] && return 1

  local wt_bin=""
  if [[ -n "${CCSU_WT_BIN:-}" ]]; then
    wt_bin="$CCSU_WT_BIN"
  elif has_cmd wt.exe; then
    wt_bin="$(command -v wt.exe)"
  fi
  if [[ -n "$wt_bin" ]]; then
    local cmd arg
    printf -v cmd 'bash %q' "$wrapper"
    for arg in "$@"; do printf -v cmd '%s %q' "$cmd" "$arg"; done
    if has_cmd wsl.exe; then
      if [[ -n "${WSL_DISTRO_NAME:-}" ]]; then
        "$wt_bin" -w 0 new-tab --title "$title" wsl.exe -d "$WSL_DISTRO_NAME" --cd "$PWD" bash -lc "$cmd" >/dev/null 2>&1 &
      else
        "$wt_bin" -w 0 new-tab --title "$title" wsl.exe --cd "$PWD" bash -lc "$cmd" >/dev/null 2>&1 &
      fi
    else
      "$wt_bin" -w 0 new-tab --title "$title" bash -lc "$cmd" >/dev/null 2>&1 &
    fi
    disown 2>/dev/null || true
    return 0
  fi

  [[ -n "${DISPLAY:-}" || -n "${WAYLAND_DISPLAY:-}" ]] || return 1

  if has_cmd gnome-terminal; then
    gnome-terminal --tab --title="$title" -- bash "$wrapper" "$@" >/dev/null 2>&1 &
  elif has_cmd konsole; then
    konsole --new-tab -p "tabtitle=$title" -e bash "$wrapper" "$@" >/dev/null 2>&1 &
  elif has_cmd xfce4-terminal; then
    local cmd q
    printf -v cmd 'bash %q' "$wrapper"
    for q in "$@"; do printf -v cmd '%s %q' "$cmd" "$q"; done
    xfce4-terminal --tab --title="$title" --command="$cmd" >/dev/null 2>&1 &
  elif has_cmd mate-terminal; then
    mate-terminal --tab --title="$title" -- bash "$wrapper" "$@" >/dev/null 2>&1 &
  elif has_cmd tilix; then
    tilix --new-process --title="$title" -e bash "$wrapper" "$@" >/dev/null 2>&1 &
  elif has_cmd x-terminal-emulator; then
    x-terminal-emulator -T "$title" -e bash "$wrapper" "$@" >/dev/null 2>&1 &
  elif has_cmd xterm; then
    xterm -T "$title" -e bash "$wrapper" "$@" >/dev/null 2>&1 &
  else
    return 1
  fi
  disown 2>/dev/null || true
}

terminal__unavailable_hint() {
  if ! has_cmd wt.exe && [[ -z "${CCSU_WT_BIN:-}" ]] && [[ -z "${DISPLAY:-}" && -z "${WAYLAND_DISPLAY:-}" ]]; then
    printf 'wt.exe 未検出かつ Linux GUI DISPLAY 未設定です。WSL ではない Linux/SSH 環境からクライアント側 Windows Terminal タブは自動生成できません。'
  elif ! has_cmd wt.exe && [[ -z "${CCSU_WT_BIN:-}" ]]; then
    printf 'wt.exe 未検出です。Linux GUI 端末も対応コマンドが見つかりません。'
  else
    printf '対応する端末起動コマンドでタブ作成に失敗しました。'
  fi
}

session__foreground_dir() { printf '%s/foreground' "$CCSU_HOME"; }

session__running_supervisor_count() {
  local sup_dir="${CCSU_SUP_DIR:-$CCSU_HOME/supervisor}"
  [[ -d "$sup_dir" ]] || { printf '0'; return; }
  local f pid n=0
  for f in "$sup_dir"/*.json; do
    [[ -f "$f" ]] || continue
    [[ "$(json_get "$f" '.status' '')" == "running" ]] || continue
    pid="$(json_get "$f" '.pid' '0')"
    [[ "$pid" != "0" ]] && kill -0 "$pid" 2>/dev/null && n=$((n + 1))
  done
  printf '%s' "$n"
}

session__running_foreground_count() {
  local fg_dir; fg_dir="$(session__foreground_dir)"
  [[ -d "$fg_dir" ]] || { printf '0'; return; }
  local f pid n=0
  for f in "$fg_dir"/*.json; do
    [[ -f "$f" ]] || continue
    [[ "$(json_get "$f" '.status' '')" == "running" ]] || continue
    pid="$(json_get "$f" '.pid' '0')"
    [[ "$pid" != "0" ]] && kill -0 "$pid" 2>/dev/null && n=$((n + 1))
  done
  printf '%s' "$n"
}

session__running_tmux_count() {
  has_cmd "$TMUX_BIN" || { printf '0'; return; }
  "$TMUX_BIN" ls 2>/dev/null | grep -c '^claudeos-' || true
}

session__running_count() {
  local a b c
  a="$(session__running_supervisor_count)"
  b="$(session__running_foreground_count)"
  c="$(session__running_tmux_count)"
  printf '%s' "$((a + b + c))"
}

session__enforce_launch_limits() {
  local duration="$1" mode="${2:-background}"
  local max_sessions="${CCSU_MAX_SESSIONS:-4}"
  local max_minutes="${CCSU_MAX_SESSION_MINUTES:-300}"

  [[ "$max_minutes" =~ ^[0-9]+$ ]] || max_minutes=300
  [[ "$max_sessions" =~ ^[0-9]+$ ]] || max_sessions=4

  # foreground (L1 対話 TUI) は人間が席にいる前提のため分数上限を適用しない。
  # BG/cron の自律実行だけ省クレジットガード (CCSU_MAX_SESSION_MINUTES) を維持する。
  if [[ "$mode" != "foreground" ]] && (( max_minutes > 0 && duration > max_minutes )); then
    log_error "duration=${duration}m は上限 ${max_minutes}m を超えています"
    return 1
  fi

  local running; running="$(session__running_count)"
  if (( max_sessions > 0 && running >= max_sessions )); then
    log_error "同時実行セッション上限に達しています: ${running}/${max_sessions}"
    log_info "  15 セッション状態監視から不要なセッションを停止してから起動してください"
    return 1
  fi
}

# duration (分) → ログ表示ラベル。0 = 無制限 (menu.sh 側の表示と同義)。
session__duration_label() {
  if (( $1 == 0 )); then printf '無制限'; else printf '%sm' "$1"; fi
}

direct__run_tui_foreground() {
  local project="$1" duration="$2" dur_sec project_dir safe stamp wrapper title prompt_file
  # dur_sec=0 は GNU timeout の「タイムアウト無効化」= 無制限として機能する
  dur_sec=$((duration * 60))
  project_dir="$(launcher__project_dir "$project")"
  safe="$(ccsu_safe_name "$project")"
  mkdir -p "$CCSU_HOME/logs" "$(session__foreground_dir)"
  stamp="$(date +%Y%m%d-%H%M%S)"
  wrapper="$CCSU_HOME/logs/manual-tui-${stamp}-${safe}.sh"
  title="Claude: $project"
  local state_file; state_file="$(session__foreground_dir)/${safe}.json"

  template_sync__apply "$project_dir"
  prompt_file="$project_dir/.claude/START_PROMPT.md"
  local -a model_args=()
  [[ -n "${CLAUDEOS_SELECTED_MODEL:-}" ]] && model_args=(--model "$CLAUDEOS_SELECTED_MODEL" --effort "$CLAUDEOS_SELECTED_EFFORT")
  # クロスセッションメッセージング用の安定セッション名 (claude v2.1.196+ のみ付与)
  local session_name=""
  ccsu_claude_supports_name "$CLAUDE_BIN" && session_name="$(ccsu_claude_session_name "$project")"
  cat > "$wrapper" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
project_dir="$1"; dur="$2"; claude_bin="$3"; title="$4"; state_file="$5"; project="$6"; prompt_file="$7"; model="$8"; effort="$9"; session_name="${10:-}"
model_args=()
[[ -n "$model" ]] && model_args=(--model "$model" --effort "$effort")
[[ -n "$session_name" ]] && model_args+=(--name "$session_name")
started="$(date -Iseconds)"
mkdir -p "$(dirname "$state_file")"
printf '{"project":"%s","status":"running","pid":%s,"started_at":"%s","mode":"foreground-tui"}\n' \
  "$project" "$$" "$started" > "$state_file"
printf '\033]0;%s\007' "$title"
cd "$project_dir" || exit 1
set +e
if [[ -f "$prompt_file" ]] && [[ -s "$prompt_file" ]]; then
  timeout --foreground "$dur" "$claude_bin" "${model_args[@]}" "$(cat "$prompt_file")"
else
  timeout --foreground "$dur" "$claude_bin" "${model_args[@]}"
fi
rc=$?
ended="$(date -Iseconds)"
printf '{"project":"%s","status":"completed","pid":0,"started_at":"%s","ended_at":"%s","mode":"foreground-tui","exit_code":%s}\n' \
  "$project" "$started" "$ended" "$rc" > "$state_file"
printf '\nClaude exited (code=%s). Enter で閉じます: ' "$rc"
read -r _ || true
exit "$rc"
EOF
  chmod +x "$wrapper"

  if terminal__open_tab "$title" "$wrapper" "$project_dir" "${dur_sec}s" "$CLAUDE_BIN" "$title" "$state_file" "$project" "$prompt_file" "${CLAUDEOS_SELECTED_MODEL:-}" "${CLAUDEOS_SELECTED_EFFORT:-}" "$session_name"; then
    log_ok "🖥️  Claude プロンプトを新規端末タブで起動しました: $project"
    log_info "  duration=$(session__duration_label "$duration") / tmux なし"
    log_info "  START_PROMPT.md を初期プロンプトとして渡します"
    return 0
  fi

  log_warn "新規端末タブを開けませんでした: $(terminal__unavailable_hint)"
  log_warn "現在の端末で Claude プロンプトを起動します。"
  log_info "🖥️  Claude プロンプト起動: $project (tmux なし / Ctrl+C 可)"
  log_info "  START_PROMPT.md を初期プロンプトとして渡します"
  [[ -n "$session_name" ]] && model_args+=(--name "$session_name")
  (
    started="$(date -Iseconds)"
    printf '{"project":"%s","status":"running","pid":%s,"started_at":"%s","mode":"foreground-tui"}\n' \
      "$project" "$$" "$started" > "$state_file"
    if [[ -f "$prompt_file" ]] && [[ -s "$prompt_file" ]]; then
      cd "$project_dir" && timeout --foreground "${dur_sec}s" "$CLAUDE_BIN" "${model_args[@]}" "$(cat "$prompt_file")"
    else
      cd "$project_dir" && timeout --foreground "${dur_sec}s" "$CLAUDE_BIN" "${model_args[@]}"
    fi
    rc=$?
    ended="$(date -Iseconds)"
    printf '{"project":"%s","status":"completed","pid":0,"started_at":"%s","ended_at":"%s","mode":"foreground-tui","exit_code":%s}\n' \
      "$project" "$started" "$ended" "$rc" > "$state_file"
    exit "$rc"
  )
}

direct__run_safe_mode() {
  local project="$1" duration="$2" mode="$3" dur_sec log_file stamp safe runner
  dur_sec=$((duration * 60))
  safe="$(ccsu_safe_name "$project")"
  mkdir -p "$CCSU_HOME/logs"
  stamp="$(date +%Y%m%d-%H%M%S)"
  log_file="$CCSU_HOME/logs/manual-safe-${stamp}-${safe}.log"
  local -a model_args=()
  [[ -n "${CLAUDEOS_SELECTED_MODEL:-}" ]] && model_args=(--model "$CLAUDEOS_SELECTED_MODEL" --effort "$CLAUDEOS_SELECTED_EFFORT")

  if [[ "$mode" == "foreground" ]]; then
    log_info "🩺 safe-mode 直接起動: $project (tmux なし / Ctrl+C 可)"
    ( cd "$(launcher__project_dir "$project")" && timeout --foreground "${dur_sec}s" "$CLAUDE_BIN" "${model_args[@]}" --safe-mode )
  else
    if has_cmd setsid; then runner=setsid; else runner=nohup; fi
    "$runner" bash -c 'cd "$1" && shift; timeout --foreground "$1" "$2" "${@:3}" --safe-mode' \
      _ "$(launcher__project_dir "$project")" "${dur_sec}s" "$CLAUDE_BIN" "${model_args[@]}" >>"$log_file" 2>&1 < /dev/null &
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
  local -a model_args=()
  [[ -n "${CLAUDEOS_SELECTED_MODEL:-}" ]] && model_args=(--model "$CLAUDEOS_SELECTED_MODEL" --effort "$CLAUDEOS_SELECTED_EFFORT")
  # クロスセッションメッセージング用の安定セッション名 (claude v2.1.196+ のみ付与)
  local -a name_args=()
  ccsu_claude_supports_name "$CLAUDE_BIN" && name_args=(--name "$(ccsu_claude_session_name "$project")")

  if [[ "$mode" == "foreground" ]]; then
    log_info "🔧 直接 headless 起動: $project (tmux なし / Ctrl+C 可)"
    if [[ -f "$SCRIPT_DIR/../libexec/stream-json-tail.sh" ]]; then
      local rc
      set +e
      ( cd "$project_dir" && timeout --foreground "${dur_sec}s" "$CLAUDE_BIN" -p "$prompt" --output-format stream-json --verbose --permission-mode auto "${model_args[@]}" "${name_args[@]}" ) \
        | bash "$SCRIPT_DIR/../libexec/stream-json-tail.sh"
      rc="${PIPESTATUS[0]}"
      set -e
      return "$rc"
    fi
    ( cd "$project_dir" && timeout --foreground "${dur_sec}s" "$CLAUDE_BIN" -p "$prompt" --output-format stream-json --verbose --permission-mode auto "${model_args[@]}" "${name_args[@]}" )
  else
    local prompt_file wrapper
    prompt_file="$CCSU_HOME/logs/manual-direct-${stamp}-${safe}.prompt"
    wrapper="$CCSU_HOME/logs/manual-direct-${stamp}-${safe}.sh"
    printf '%s' "$prompt" > "$prompt_file"
    cat > "$wrapper" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
project_dir="$1"; dur="$2"; claude_bin="$3"; prompt_file="$4"
shift 4
prompt="$(cat "$prompt_file" 2>/dev/null || true)"
cd "$project_dir"
timeout --foreground "$dur" "$claude_bin" -p "$prompt" --output-format stream-json --verbose --permission-mode auto "$@"
EOF
    chmod +x "$wrapper"
    if has_cmd setsid; then runner=setsid; else runner=nohup; fi
    "$runner" bash "$wrapper" "$project_dir" "${dur_sec}s" "$CLAUDE_BIN" "$prompt_file" "${model_args[@]}" "${name_args[@]}" >>"$log_file" 2>&1 < /dev/null &
    disown 2>/dev/null || true
    log_ok "直接 headless BG 起動: $project (tmux なし)"
    log_info "  ログ: $log_file"
  fi
}

main() {
  local project="" mode="foreground" duration="" safe_mode=0 use_tmux=0 dry_run=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --project)    project="$2"; shift 2 ;;
      --foreground) mode="foreground"; shift ;;
      --background) mode="background"; shift ;;
      --duration)   duration="$2"; shift 2 ;;
      --safe-mode)  safe_mode=1; shift ;;
      --tmux)       use_tmux=1; shift ;;
      --dry-run)    dry_run=1; shift ;;
      --local)      shift ;;   # 互換: ローカル一本化のため無視
      *) log_error "不明な引数: $1"; exit 1 ;;
    esac
  done

  if [[ -z "$duration" ]]; then
    if [[ "$mode" == "foreground" ]]; then
      # L1 即起動: 既定は 0 = 無制限 (GNU timeout は duration 0 でタイムアウト無効化)。
      # 分数を区切りたい場合は config の foregroundSessionMinutes か --duration で指定する。
      duration="$(config_get '.supervisor.defaults.foregroundSessionMinutes' '0')"
    else
      duration="$(config_get '.supervisor.defaults.sessionMinutes' "$(config_get '.cron.defaultDurationMinutes' '300')")"
    fi
  fi
  [[ "$duration" =~ ^[0-9]+$ ]] || { log_error "duration は数値で指定してください: $duration"; exit 1; }
  if (( duration == 0 )) && [[ "$mode" != "foreground" ]]; then
    log_error "duration=0 (無制限) は foreground のみ対応しています"
    exit 1
  fi
  session__enforce_launch_limits "$duration" "$mode" || exit 1

  if (( dry_run )); then
    if ! has_cmd claude; then
      log_warn "dry-run: claude CLI が見つかりません (実起動時は npm i -g @anthropic-ai/claude-code が必要)"
    fi
  else
    require_cmd claude "npm i -g @anthropic-ai/claude-code"
  fi

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

  local model_task="${CLAUDEOS_MODEL_TASK:-normal}"
  local record_model=0
  if (( dry_run )); then
    record_model=0
  elif (( safe_mode )); then
    record_model=1
  elif [[ "$mode" == "foreground" ]]; then
    record_model=1
  fi
  claude__select_model "$project" "$model_task" "start-claude" "$record_model" || true

  if (( dry_run )); then
    log_info "dry-run: Claude 起動計画"
    log_info "  project=$project"
    log_info "  project_dir=$(launcher__project_dir "$project")"
    log_info "  mode=$mode"
    log_info "  duration=$(session__duration_label "$duration")"
    log_info "  safe_mode=$safe_mode"
    log_info "  tmux=$use_tmux"
    if [[ -n "${CLAUDEOS_SELECTED_MODEL:-}" ]]; then
      log_info "  model=$CLAUDEOS_SELECTED_MODEL"
      log_info "  effort=$CLAUDEOS_SELECTED_EFFORT"
      log_info "  model_reason=$CLAUDEOS_SELECTED_MODEL_REASON"
    fi
    if (( safe_mode )); then
      log_info "  route=$([[ "$use_tmux" == "1" ]] && printf 'tmux safe-mode' || printf 'direct safe-mode')"
    elif [[ "$mode" == "foreground" ]]; then
      log_info "  route=$([[ "$use_tmux" == "1" ]] && printf 'tmux foreground' || printf 'terminal/direct TUI')"
    else
      log_info "  route=autonomy supervisor background"
    fi
    log_info "dry-run: Claude 起動・template sync・通知・supervisor 起動は行いません"
    return 0
  fi

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

  # L1 foreground はプロンプト操作用。S1/cron の自律 headless とは分離し、
  # 新規端末タブで通常の Claude TUI を開く。
  if [[ "$mode" == "foreground" ]]; then
    if (( use_tmux )); then
      tmux_run "$project" "$duration" "$mode"
    else
      direct__run_tui_foreground "$project" "$duration"
    fi
    return 0
  fi

  local safe
  safe="$(ccsu_safe_name "$project")"

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

}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
