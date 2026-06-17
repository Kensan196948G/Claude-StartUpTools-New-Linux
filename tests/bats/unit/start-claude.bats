#!/usr/bin/env bats
# ============================================================
# start-claude.bats — bin/start-claude.sh のテスト
# tmux/claude を PATH スタブ化。attach 回避のため background 中心。
# ============================================================

load '../helpers/common-setup'

setup() {
  _bats_common_setup
  export TMUX_STATE="$TEST_TEMP/tmux-state"; mkdir -p "$TMUX_STATE"
  make_stub_bin tmux '
state="${TMUX_STATE:?}"; mkdir -p "$state"
sub="${1:-}"; shift || true
case "$sub" in
  has-session) [[ "${1:-}" == "-t" ]] && shift; [[ -f "$state/${1:-}" ]] && exit 0 || exit 1 ;;
  new-session) name=""; while [[ $# -gt 0 ]]; do [[ "$1" == "-s" ]] && { name="${2:-}"; shift 2; continue; }; shift; done; [[ -n "$name" ]] && touch "$state/$name"; exit 0 ;;
  new-window) printf "%s\n" "$*" >> "$state/new-window.log"; exit 0 ;;
  pipe-pane|attach) exit 0 ;;
  kill-session) [[ "${1:-}" == "-t" ]] && shift; rm -f "$state/${1:-}"; exit 0 ;;
  *) exit 0 ;;
esac
'
  make_stub_bin claude 'printf "%s\n" "$*" >> "$TEST_TEMP/claude.log"; exit 0'
  make_stub_bin gnome-terminal '
printf "%s\n" "$*" >> "$TEST_TEMP/terminal.log"
exit 0
'
  make_stub_bin setsid '
echo "$@" >> "$TEST_TEMP/setsid.log"
p="${4:-}"
safe="$(printf "%s" "$p" | tr -c "A-Za-z0-9_-" "_")"
[[ -n "$p" ]] && { mkdir -p "$CLAUDEOS_HOME/supervisor"; printf "{\"project\":\"%s\",\"status\":\"running\",\"pid\":%s}\n" "$p" "$$" > "$CLAUDEOS_HOME/supervisor/$safe.json"; }
exit 0
'
  export AI_STARTUP_CONFIG_PATH="$TEST_TEMP/config.json"
  cat > "$AI_STARTUP_CONFIG_PATH" <<JSON
{ "projects": "$TEST_TEMP/projects", "projectsDir": "$TEST_TEMP/projects" }
JSON
  mkdir -p "$TEST_TEMP/projects/MyProj/.claude"
  export CLAUDEOS_HOME="$TEST_TEMP/claudeos"
  export CCSU_SUP_DIR="$CLAUDEOS_HOME/supervisor"
  export CCSU_SUP_CRON_LAUNCHER="$TEST_TEMP/cron-launcher.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$CCSU_SUP_CRON_LAUNCHER"; chmod +x "$CCSU_SUP_CRON_LAUNCHER"
  export CCSU_SKIP_ENV_FILE=1   # 実 ~/.env-claudeos を読み込まない (メール watcher を起動させない)
  SCRIPT="$REPO_ROOT/bin/start-claude.sh"
}
teardown() { _bats_common_teardown; }

@test "start-claude: --background で起動しセッション作成" {
  run bash "$SCRIPT" --project MyProj --background --duration 5
  [ "$status" -eq 0 ]
  [ -f "$CLAUDEOS_HOME/supervisor/MyProj.json" ]
  grep -q "__run MyProj" "$TEST_TEMP/setsid.log"
}

@test "start-claude: project 不在でエラー" {
  run bash "$SCRIPT" --project NoSuch --background
  [ "$status" -ne 0 ]
}

@test "start-claude: --local 互換フラグを受理" {
  run bash "$SCRIPT" --project MyProj --local --background --duration 5
  [ "$status" -eq 0 ]
}

@test "start-claude: 不明な引数でエラー" {
  run bash "$SCRIPT" --project MyProj --frobnicate
  [ "$status" -ne 0 ]
}

@test "start-claude: background はログ案内を出す" {
  run bash "$SCRIPT" --project MyProj --background --duration 5
  [[ "$output" == *"supervisor 起動"* ]]
}

@test "start-claude: duration 未指定は supervisor 既定 180m を使う" {
  run bash "$SCRIPT" --project MyProj --background
  [ "$status" -eq 0 ]
  grep -q "__run MyProj 180" "$TEST_TEMP/setsid.log"
}

@test "start-claude: duration 180m 超は拒否する" {
  run bash "$SCRIPT" --project MyProj --background --duration 181
  [ "$status" -ne 0 ]
  [[ "$output" == *"上限 180m"* ]]
}

@test "start-claude: 実行中セッションが2件なら新規起動を拒否する" {
  mkdir -p "$CLAUDEOS_HOME/supervisor"
  cat > "$CLAUDEOS_HOME/supervisor/RunA.json" <<JSON
{"project":"RunA","status":"running","pid":$$}
JSON
  cat > "$CLAUDEOS_HOME/supervisor/RunB.json" <<JSON
{"project":"RunB","status":"running","pid":$$}
JSON
  run bash "$SCRIPT" --project MyProj --background --duration 5
  [ "$status" -ne 0 ]
  [[ "$output" == *"同時実行セッション上限"* ]]
}

@test "start-claude: --safe-mode は既定で tmux なし直接起動" {
  run bash "$SCRIPT" --project MyProj --safe-mode --background --duration 5
  [ "$status" -eq 0 ]
  [[ "$output" == *"safe-mode 診断起動"* ]]
  # supervisor (autonomy.sh) を経由しない → state ファイルなし
  [ ! -f "$CLAUDEOS_HOME/supervisor/MyProj.json" ]
  [ ! -f "$TMUX_STATE/claudeos-MyProj" ]
}

@test "start-claude: --safe-mode --tmux は tmux セッションを直接起動" {
  run bash "$SCRIPT" --project MyProj --safe-mode --tmux --background --duration 5
  [ "$status" -eq 0 ]
  [ -f "$TMUX_STATE/claudeos-MyProj" ]
}

@test "start-claude: foreground は新規端末タブで Claude プロンプトを起動する" {
  export DISPLAY=":99"
  run bash "$SCRIPT" --project MyProj --foreground --duration 5
  [ "$status" -eq 0 ]
  [[ "$output" == *"Claude プロンプトを新規端末タブで起動しました"* ]]
  [ -f "$TEST_TEMP/terminal.log" ]
  grep -q -- "--tab" "$TEST_TEMP/terminal.log"
  grep -q -- "Claude: MyProj" "$TEST_TEMP/terminal.log"
  [ ! -f "$CLAUDEOS_HOME/supervisor/MyProj.json" ]
  [ ! -f "$TMUX_STATE/new-window.log" ]
}

@test "start-claude: DISPLAY なしでも wt.exe があれば Windows Terminal タブを使う" {
  rm -f "$TEST_TEMP/terminal.log"
  make_stub_bin wt.exe '
printf "%s\n" "$*" >> "$TEST_TEMP/wt.log"
exit 0
'
  unset DISPLAY
  unset WAYLAND_DISPLAY
  run bash "$SCRIPT" --project MyProj --foreground --duration 5
  [ "$status" -eq 0 ]
  [[ "$output" == *"Claude プロンプトを新規端末タブで起動しました"* ]]
  [ -f "$TEST_TEMP/wt.log" ]
  grep -q -- "new-tab" "$TEST_TEMP/wt.log"
  grep -q -- "Claude: MyProj" "$TEST_TEMP/wt.log"
}

@test "start-claude: foreground は端末タブ不可なら現在端末で Claude プロンプトを起動する" {
  unset TMUX
  unset DISPLAY
  unset WAYLAND_DISPLAY
  run bash "$SCRIPT" --project MyProj --foreground --duration 5
  [ "$status" -eq 0 ]
  [[ "$output" == *"Claude プロンプト起動"* ]]
  [ -f "$TEST_TEMP/claude.log" ]
  ! grep -q -- "-p" "$TEST_TEMP/claude.log"
  [ ! -f "$CLAUDEOS_HOME/supervisor/MyProj.json" ]
  [ ! -f "$TMUX_STATE/new-window.log" ]
}

@test "start-claude: foreground は tmux 内でも既定で端末タブを使う" {
  export TMUX="/tmp/fake,0,0"
  export DISPLAY=":99"
  run bash "$SCRIPT" --project MyProj --foreground --duration 5
  [ "$status" -eq 0 ]
  [[ "$output" == *"Claude プロンプトを新規端末タブで起動しました"* ]]
  [ ! -f "$CLAUDEOS_HOME/supervisor/MyProj.json" ]
  [ -f "$TEST_TEMP/terminal.log" ]
  [ ! -f "$TMUX_STATE/new-window.log" ]
}

@test "start-claude: foreground --tmux は tmux fallback を使う" {
  export TMUX="/tmp/fake,0,0"
  run bash "$SCRIPT" --project MyProj --foreground --tmux --duration 5
  [ "$status" -eq 0 ]
  [ -f "$TMUX_STATE/claudeos-MyProj" ]
  [ ! -f "$CLAUDEOS_HOME/supervisor/MyProj.json" ]
}
