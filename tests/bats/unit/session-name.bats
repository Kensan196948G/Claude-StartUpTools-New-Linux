#!/usr/bin/env bats
# ============================================================
# session-name.bats — クロスセッションメッセージング用セッション命名
#   - lib/common.sh: ccsu_claude_session_name / ccsu_claude_supports_name
#   - lib/tmux-runner.sh: tmux_run への --name 注入 (tmux スタブでコマンドを捕捉)
#   - cron-launcher.sh / start-claude.sh: 配線の静的検証
# ============================================================

load '../helpers/common-setup'

setup() {
  _bats_common_setup
  export TMUX_STATE="$TEST_TEMP/tmux-state"
  mkdir -p "$TMUX_STATE"

  # tmux スタブ: new-session の全引数を捕捉しつつセッションをファイルマーカーで再現
  make_stub_bin tmux '
state="${TMUX_STATE:?}"
mkdir -p "$state"
sub="${1:-}"; shift || true
case "$sub" in
  has-session)
    [[ "${1:-}" == "-t" ]] && shift
    [[ -f "$state/${1:-}" ]] && exit 0 || exit 1 ;;
  new-session)
    printf "%s\n" "$*" > "$state/last-new-session"
    name=""
    while [[ $# -gt 0 ]]; do
      if [[ "$1" == "-s" ]]; then name="${2:-}"; shift 2; continue; fi
      shift
    done
    [[ -n "$name" ]] && touch "$state/$name"
    exit 0 ;;
  kill-session)
    [[ "${1:-}" == "-t" ]] && shift
    rm -f "$state/${1:-}"; exit 0 ;;
  *) exit 0 ;;
esac
'
  # claude スタブ: --help に --name を含む (v2.1.196+ 相当)
  make_stub_bin claude 'if [[ "${1:-}" == "--help" ]]; then echo "  -n, --name <name>  session name"; echo probe >> "${TEST_TEMP:?}/probe-count"; fi; exit 0'

  export AI_STARTUP_CONFIG_PATH="$TEST_TEMP/config.json"
  cat > "$AI_STARTUP_CONFIG_PATH" <<JSON
{ "projects": "$TEST_TEMP/projects", "projectsDir": "$TEST_TEMP/projects" }
JSON
  mkdir -p "$TEST_TEMP/projects/MyProj/.claude"
  export CLAUDEOS_HOME="$TEST_TEMP/claudeos"
  unset CCSU_SESSION_ROLE CCSU_SESSION_NAME CCSU_CLAUDE_SAFE_MODE

  source "$REPO_ROOT/lib/tmux-runner.sh"
}
teardown() { _bats_common_teardown; }

# ---- ccsu_claude_session_name ----------------------------------

@test "ccsu_claude_session_name: claudeos-<safe> 基本形" {
  run ccsu_claude_session_name "My Proj"
  [ "$output" = "claudeos-My_Proj" ]
}

@test "ccsu_claude_session_name: CCSU_SESSION_ROLE で役割サフィックス付与" {
  export CCSU_SESSION_ROLE=cto
  run ccsu_claude_session_name "MyProj"
  [ "$output" = "claudeos-MyProj-cto" ]
}

@test "ccsu_claude_session_name: 役割も safe 化される" {
  export CCSU_SESSION_ROLE='q a!'
  run ccsu_claude_session_name "MyProj"
  [ "$output" = "claudeos-MyProj-q_a_" ]
}

# ---- ccsu_claude_supports_name ---------------------------------

@test "ccsu_claude_supports_name: --help に --name があれば成功" {
  run ccsu_claude_supports_name claude
  [ "$status" -eq 0 ]
}

@test "ccsu_claude_supports_name: --name 非対応 claude では非0" {
  make_stub_bin claude 'echo "old help without the flag"; exit 0'
  run ccsu_claude_supports_name claude
  [ "$status" -ne 0 ]
}

@test "ccsu_claude_supports_name: CCSU_SESSION_NAME=0 で無効化" {
  export CCSU_SESSION_NAME=0
  run ccsu_claude_supports_name claude
  [ "$status" -ne 0 ]
}

@test "ccsu_claude_supports_name: probe は同一プロセスで 1 回だけ" {
  ccsu_claude_supports_name claude
  ccsu_claude_supports_name claude
  [ "$(wc -l < "$TEST_TEMP/probe-count")" -eq 1 ]
}

# ---- tmux_run への --name 注入 ---------------------------------

@test "tmux_run: claude コマンドへ --name 'claudeos-<safe>' を付与" {
  run tmux_run MyProj 5 background
  [ "$status" -eq 0 ]
  grep -q -- "--name 'claudeos-MyProj'" "$TMUX_STATE/last-new-session"
}

@test "tmux_run: CCSU_SESSION_ROLE=cto で役割サフィックス付き --name" {
  export CCSU_SESSION_ROLE=cto
  run tmux_run MyProj 5 background
  [ "$status" -eq 0 ]
  grep -q -- "--name 'claudeos-MyProj-cto'" "$TMUX_STATE/last-new-session"
}

@test "tmux_run: CCSU_SESSION_NAME=0 なら --name を付与しない" {
  export CCSU_SESSION_NAME=0
  run tmux_run MyProj 5 background
  [ "$status" -eq 0 ]
  ! grep -q -- "--name" "$TMUX_STATE/last-new-session"
}

@test "tmux_run: --name 非対応 claude には付与しない (旧バージョン互換)" {
  make_stub_bin claude 'echo "old help"; exit 0'
  run tmux_run MyProj 5 background
  [ "$status" -eq 0 ]
  ! grep -q -- "--name" "$TMUX_STATE/last-new-session"
}

@test "tmux_run: safe-mode 診断起動には --name を付与しない" {
  export CCSU_CLAUDE_SAFE_MODE=1
  run tmux_run MyProj 5 background
  [ "$status" -eq 0 ]
  grep -q -- "--safe-mode" "$TMUX_STATE/last-new-session"
  ! grep -q -- "--name" "$TMUX_STATE/last-new-session"
}

# ---- 配線の静的検証 (cron-launcher / start-claude) --------------

@test "cron-launcher: headless _HL_CMD と TUI 両経路に _NAME_ARGS が配線されている" {
  local f="$REPO_ROOT/Claude/templates/linux/cron-launcher.sh"
  grep -q 'CLAUDEOS_SESSION_NAME_ENABLED' "$f"
  grep -q 'CLAUDEOS_SESSION_ROLE' "$f"
  # headless コマンドへの注入
  grep -A1 '_HL_CMD=(' "$f" | grep -q '_NAME_ARGS'
  # TUI wrapper への env 渡しと wrapper 内での利用
  grep -q -- '-e "_CLAUDEOS_SESSION_NAME=' "$f"
  grep -q '_CLAUDEOS_SESSION_NAME:-' "$f"
}

@test "start-claude: TUI wrapper と headless 両経路に session name が配線されている" {
  local f="$REPO_ROOT/bin/start-claude.sh"
  grep -q 'ccsu_claude_supports_name' "$f"
  grep -q 'ccsu_claude_session_name' "$f"
  grep -q 'session_name="${10:-}"' "$f"
  grep -q '"${name_args\[@\]}"' "$f"
}
