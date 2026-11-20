#!/usr/bin/env bats
# ============================================================
# web-terminal.bats — bin/web-terminal.sh のテスト
# tmux と start-claude.sh を PATH/環境スタブ化し、実セッションを起動せずに
# allowlist 検証・attach 経路・新規起動経路を検証する。
# ============================================================

load '../helpers/common-setup'

setup() {
  _bats_common_setup
  export CLAUDEOS_HOME="$TEST_TEMP/claudeos"
  mkdir -p "$CLAUDEOS_HOME/logs"
  export TMUX_STATE="$TEST_TEMP/tmux-state"
  mkdir -p "$TMUX_STATE"

  make_stub_bin tmux '
state="${TMUX_STATE:?}"; mkdir -p "$state"
sub="${1:-}"; shift || true
case "$sub" in
  has-session) [[ "${1:-}" == "-t" ]] && shift; [[ -f "$state/${1:-}" ]] && exit 0 || exit 1 ;;
  attach)      printf "%s\n" "$*" >> "$state/attach.log"; exit 0 ;;
  ls)          for f in "$state"/claudeos-*; do [[ -e "$f" ]] || continue; printf "%s: 1 windows\n" "$(basename "$f")"; done; exit 0 ;;
  *) exit 0 ;;
esac
'
  make_stub_bin start-claude-stub 'printf "%s\n" "$*" > "$TEST_TEMP/launcher-args"; exit 0'
  export CCSU_START_CLAUDE_BIN="$STUB_BIN/start-claude-stub"

  export AI_STARTUP_CONFIG_PATH="$TEST_TEMP/config.json"
  cat > "$AI_STARTUP_CONFIG_PATH" <<JSON
{ "projects": "$TEST_TEMP/projects", "projectsDir": "$TEST_TEMP/projects" }
JSON
  mkdir -p "$TEST_TEMP/projects/MyProj/.git" "$TEST_TEMP/projects/Other-Proj/.git"
  SCRIPT="$REPO_ROOT/bin/web-terminal.sh"
}
teardown() { _bats_common_teardown; }

@test "web-terminal: --help は使い方を表示して exit 0" {
  run bash "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--project"* ]]
}

@test "web-terminal: --list は登録プロジェクトを列挙する" {
  run bash "$SCRIPT" --list
  [ "$status" -eq 0 ]
  [[ "$output" == *"MyProj"* ]]
  [[ "$output" == *"Other-Proj"* ]]
}

@test "web-terminal: 存在しない project は拒否 (exit 2)" {
  run bash "$SCRIPT" --project claudeos-root
  [ "$status" -eq 2 ]
  [[ "$output" == *"存在しない project"* ]]
  [ ! -f "$TEST_TEMP/launcher-args" ]
}

@test "web-terminal: 実在するフォルダは Git 未登録でも許可される (フォルダ以下すべて)" {
  mkdir -p "$TEST_TEMP/projects/Plain-Dir"
  run bash "$SCRIPT" --project Plain-Dir
  [ "$status" -eq 0 ]
  run cat "$TEST_TEMP/launcher-args"
  [[ "$output" == *"--project Plain-Dir"* ]]
}

@test "web-terminal: 稼働中セッションがあれば attach する" {
  touch "$TMUX_STATE/claudeos-MyProj"
  run bash "$SCRIPT" --project MyProj
  [ "$status" -eq 0 ]
  run cat "$TMUX_STATE/attach.log"
  [[ "$output" == *"-t claudeos-MyProj"* ]]
  [ ! -f "$TEST_TEMP/launcher-args" ]
}

@test "web-terminal: セッションが無ければ start-claude.sh を foreground+tmux で起動する" {
  run bash "$SCRIPT" --project Other-Proj
  [ "$status" -eq 0 ]
  run cat "$TEST_TEMP/launcher-args"
  [[ "$output" == *"--project Other-Proj"* ]]
  [[ "$output" == *"--foreground"* ]]
  [[ "$output" == *"--tmux"* ]]
}

@test "web-terminal: 接続操作は監査ログに記録される" {
  touch "$TMUX_STATE/claudeos-MyProj"
  run bash "$SCRIPT" --project MyProj
  [ "$status" -eq 0 ]
  [ -f "$CLAUDEOS_HOME/logs/web-startup-audit.log" ]
  run grep -c "terminal_attach" "$CLAUDEOS_HOME/logs/web-startup-audit.log"
  [ "$output" -ge 1 ]
}
