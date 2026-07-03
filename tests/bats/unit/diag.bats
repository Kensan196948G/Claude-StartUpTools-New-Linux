#!/usr/bin/env bats
# ============================================================
# diag.bats — libexec/*.sh 診断ラッパのテスト (メニュー項5-15)
# ============================================================

load '../helpers/common-setup'

setup() {
  _bats_common_setup
  export CLAUDEOS_HOME="$TEST_TEMP/claudeos"
  mkdir -p "$CLAUDEOS_HOME/logs" "$CLAUDEOS_HOME/sessions"
  export AI_STARTUP_CONFIG_PATH="$TEST_TEMP/config.json"
  cat > "$AI_STARTUP_CONFIG_PATH" <<JSON
{ "projects": "$TEST_TEMP/projects", "projectsDir": "$TEST_TEMP/projects" }
JSON
  mkdir -p "$TEST_TEMP/projects/Alpha"
  export CCSU_STATE_FILE="$TEST_TEMP/state.json"
  echo '{ "agent_teams_usage": { "current_session": { "team_create_count": 2, "send_message_count": 5 } } }' > "$CCSU_STATE_FILE"
  LX="$REPO_ROOT/libexec"
}
teardown() { _bats_common_teardown; }

@test "diag-all-tools: exit 0 + 見出し" {
  run bash "$LX/diag-all-tools.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ツール確認"* ]]
}

@test "diag-mounts: exit 0 + 見出し" {
  run bash "$LX/diag-mounts.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"疎通診断"* ]]
}

@test "setup-terminal: exit 0 + tmux 言及" {
  run bash "$LX/setup-terminal.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"tmux"* ]]
}

@test "setup-terminal --apply: ClaudeOS dirs と tmux.conf 管理ブロックを作成" {
  export HOME="$TEST_TEMP/home"
  export CLAUDEOS_HOME="$TEST_TEMP/home/.claudeos"
  mkdir -p "$HOME"
  make_stub_bin tmux 'echo "tmux 3.4"'

  run bash "$LX/setup-terminal.sh" --apply
  [ "$status" -eq 0 ]
  [ -d "$CLAUDEOS_HOME/logs" ]
  [ -d "$CLAUDEOS_HOME/sessions" ]
  [ -d "$CLAUDEOS_HOME/tmp" ]
  [ -f "$HOME/.tmux.conf" ]
  grep -q 'ClaudeOS tmux setup' "$HOME/.tmux.conf"
  grep -q 'set -g mouse on' "$HOME/.tmux.conf"
}

@test "setup-terminal --apply: 既存 tmux.conf を保持して管理ブロックを冪等更新" {
  export HOME="$TEST_TEMP/home"
  export CLAUDEOS_HOME="$TEST_TEMP/home/.claudeos"
  mkdir -p "$HOME"
  printf 'set -g prefix C-a\n' > "$HOME/.tmux.conf"
  make_stub_bin tmux 'echo "tmux 3.4"'

  bash "$LX/setup-terminal.sh" --apply
  run bash "$LX/setup-terminal.sh" --apply
  [ "$status" -eq 0 ]
  grep -q 'set -g prefix C-a' "$HOME/.tmux.conf"
  [ "$(grep -c '^# >>> ClaudeOS tmux setup$' "$HOME/.tmux.conf")" -eq 1 ]
}

@test "setup-terminal --locale-ja --yes: locale 生成と既定化コマンドを実行" {
  export HOME="$TEST_TEMP/home"
  mkdir -p "$HOME"
  export LOCALE_CALLS="$TEST_TEMP/locale-calls.log"
  make_stub_bin tmux 'echo "tmux 3.4"'
  make_stub_bin locale '[[ "${1:-}" == "-a" ]] && exit 0; exit 0'
  make_stub_bin sudo '"$@"'
  make_stub_bin locale-gen 'echo "locale-gen $*" >> "$LOCALE_CALLS"'
  make_stub_bin update-locale 'echo "update-locale $*" >> "$LOCALE_CALLS"'

  run bash "$LX/setup-terminal.sh" --locale-ja --yes
  [ "$status" -eq 0 ]
  grep -q 'locale-gen ja_JP.UTF-8' "$LOCALE_CALLS"
  grep -q 'update-locale LANG=ja_JP.UTF-8' "$LOCALE_CALLS"
}

@test "setup-terminal --locale-ja --yes: system locale tool がなければ profile にフォールバック" {
  export HOME="$TEST_TEMP/home"
  mkdir -p "$HOME"
  make_stub_bin tmux 'echo "tmux 3.4"'
  make_stub_bin locale '[[ "${1:-}" == "-a" ]] && echo "ja_JP.utf8"; exit 0'
  make_stub_bin sudo '"$@"'
  make_stub_bin update-locale 'exit 1'
  make_stub_bin localectl 'exit 1'

  run bash "$LX/setup-terminal.sh" --locale-ja --yes
  [ "$status" -eq 0 ]
  [ -f "$HOME/.profile" ]
  grep -q 'ClaudeOS locale setup' "$HOME/.profile"
  grep -q 'export LANG=ja_JP.UTF-8' "$HOME/.profile"
}

@test "setup-terminal: clipboard_copy_command/paste_command が 4 ツールを正しく対応付ける" {
  run bash -c '
    source "'"$LX"'/setup-terminal.sh"
    for t in wayland xclip xsel osc52; do
      printf "%s|copy=%s|paste=%s\n" "$t" "$(clipboard_copy_command "$t")" "$(clipboard_paste_command "$t")"
    done
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"wayland|copy=wl-copy|paste=wl-paste -n"* ]]
  [[ "$output" == *"xclip|copy=xclip -selection clipboard -in|paste=xclip -selection clipboard -out"* ]]
  [[ "$output" == *"xsel|copy=xsel --clipboard --input|paste=xsel --clipboard --output"* ]]
  # osc52 は OS ツール不要 (set-clipboard on が OSC52 を送出するため copy/paste コマンドは空)
  [[ "$output" == *"osc52|copy=|paste="* ]]
}

@test "setup-terminal: print_tmux_block がマウス/スクロール/コピー&ペースト(ツール検出)を出力" {
  run bash -c '
    source "'"$LX"'/setup-terminal.sh"
    detect_clipboard_tool() { printf "xclip\n"; }
    print_tmux_block
  '
  [ "$status" -eq 0 ]
  # マウス操作とスクロールの基本
  [[ "$output" == *"set -g mouse on"* ]]
  [[ "$output" == *"setw -g mode-keys vi"* ]]
  [[ "$output" == *"bind -n WheelUpPane"* ]]
  [[ "$output" == *"bind -n WheelDownPane send-keys -M"* ]]
  # OS クリップボード連携
  [[ "$output" == *"set -g set-clipboard on"* ]]
  # ドラッグ選択/copy-mode 内 Ctrl+C で検出ツールへ copy-pipe
  [[ "$output" == *'bind -T copy-mode-vi MouseDragEnd1Pane send -X copy-pipe-and-cancel "xclip -selection clipboard -in"'* ]]
  [[ "$output" == *'bind -T copy-mode-vi C-c'*'copy-pipe-and-cancel "xclip -selection clipboard -in"'* ]]
  # Ctrl+V で OS クリップボード → ペイン
  [[ "$output" == *'bind -n C-v run "xclip -selection clipboard -out | tmux load-buffer - && tmux paste-buffer -p"'* ]]
}

@test "setup-terminal: print_tmux_block はツール未検出時 OSC52 フォールバックを出力" {
  run bash -c '
    source "'"$LX"'/setup-terminal.sh"
    detect_clipboard_tool() { printf "osc52\n"; }
    print_tmux_block
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"set -g set-clipboard on"* ]]
  # copy-pipe-and-cancel は引数なし (OSC52 送出に委ねる)
  [[ "$output" == *"bind -T copy-mode-vi C-c              send -X copy-pipe-and-cancel"* ]]
  [[ "$output" != *'copy-pipe-and-cancel "'* ]]
  # ペーストは tmux 内バッファ
  [[ "$output" == *"bind -n C-v paste-buffer -p"* ]]
}

@test "diag-mcp-health: exit 0" {
  run bash "$LX/diag-mcp-health.sh"
  [ "$status" -eq 0 ]
}

@test "diag-agent-teams: state の count を表示" {
  run bash "$LX/diag-agent-teams.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"TeammateSpawn=2"* ]]
}

@test "diag-worktree: exit 0" {
  run bash "$LX/diag-worktree.sh"
  [ "$status" -eq 0 ]
}

@test "diag-architecture: exit 0 + 見出し" {
  run bash "$LX/diag-architecture.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Architecture Check"* ]]
}

@test "watch-claude-log --once: 最新ログを表示" {
  echo "TEST_LOG_LINE_42" > "$CLAUDEOS_HOME/logs/cron-test.log"
  run bash "$LX/watch-claude-log.sh" --once
  [ "$status" -eq 0 ]
  [[ "$output" == *"TEST_LOG_LINE_42"* ]]
}

@test "watch-claude-log --once: ログなしでも exit 0" {
  run bash "$LX/watch-claude-log.sh" --once
  [ "$status" -eq 0 ]
}

@test "watch-session --once: セッションを表示" {
  echo '{ "project": "Alpha", "status": "running", "start_time": "2026-06-01T10:00:00" }' > "$CLAUDEOS_HOME/sessions/s1.json"
  run bash "$LX/watch-session.sh" --once
  [ "$status" -eq 0 ]
  [[ "$output" == *"Alpha"* ]]
}
