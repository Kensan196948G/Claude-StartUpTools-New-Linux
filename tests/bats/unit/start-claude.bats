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

@test "start-claude: duration 未指定は supervisor 既定 300m を使う" {
  run bash "$SCRIPT" --project MyProj --background
  [ "$status" -eq 0 ]
  grep -q "__run MyProj 300" "$TEST_TEMP/setsid.log"
}

@test "start-claude: duration 300m 超は拒否する" {
  run bash "$SCRIPT" --project MyProj --background --duration 301
  [ "$status" -ne 0 ]
  [[ "$output" == *"上限 300m"* ]]
}

@test "start-claude: foreground の duration 未指定は無制限 (0)" {
  run bash "$SCRIPT" --project MyProj --foreground --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"duration=無制限"* ]]
}

@test "start-claude: foreground は分数上限を適用しない (301m 許可)" {
  run bash "$SCRIPT" --project MyProj --foreground --duration 301 --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"duration=301m"* ]]
  [[ "$output" != *"上限 300m"* ]]
}

@test "start-claude: foreground は foregroundSessionMinutes を既定に使う" {
  cat > "$AI_STARTUP_CONFIG_PATH" <<JSON
{ "projects": "$TEST_TEMP/projects", "projectsDir": "$TEST_TEMP/projects",
  "supervisor": { "defaults": { "foregroundSessionMinutes": 120 } } }
JSON
  run bash "$SCRIPT" --project MyProj --foreground --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"duration=120m"* ]]
}

@test "start-claude: background の duration 0 (無制限) は拒否する" {
  run bash "$SCRIPT" --project MyProj --background --duration 0
  [ "$status" -ne 0 ]
  [[ "$output" == *"foreground / team のみ"* ]]
}

@test "start-claude: 実行中セッションが4件なら新規起動を拒否する" {
  mkdir -p "$CLAUDEOS_HOME/supervisor"
  local p
  for p in RunA RunB RunC RunD; do
    cat > "$CLAUDEOS_HOME/supervisor/${p}.json" <<JSON
{"project":"${p}","status":"running","pid":$$}
JSON
  done
  run bash "$SCRIPT" --project MyProj --background --duration 5
  [ "$status" -ne 0 ]
  [[ "$output" == *"同時実行セッション上限"* ]]
}

@test "start-claude: 実行中セッションが3件なら起動を許可する" {
  mkdir -p "$CLAUDEOS_HOME/supervisor"
  local p
  for p in RunA RunB RunC; do
    cat > "$CLAUDEOS_HOME/supervisor/${p}.json" <<JSON
{"project":"${p}","status":"running","pid":$$}
JSON
  done
  run bash "$SCRIPT" --project MyProj --background --duration 5
  [ "$status" -eq 0 ]
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
  export CCSU_ROOT="$TEST_TEMP/ccsu-root"
  mkdir -p "$CCSU_ROOT/Claude/templates/claude"
  printf '%s\n' 'TEST START PROMPT CONTENT' > "$CCSU_ROOT/Claude/templates/claude/START_PROMPT.md"
  run bash "$SCRIPT" --project MyProj --foreground --duration 5
  [ "$status" -eq 0 ]
  [[ "$output" == *"Claude プロンプト起動"* ]]
  [ -f "$TEST_TEMP/claude.log" ]
  ! grep -q -- "-p" "$TEST_TEMP/claude.log"
  grep -q -- "TEST START PROMPT CONTENT" "$TEST_TEMP/claude.log"
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

@test "start-claude: --team --dry-run は team quad ルートと worktree 計画を表示" {
  run bash "$SCRIPT" --project MyProj --team --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"route=tmux team quad"* ]]
  [[ "$output" == *"team_session=claudeos-team-MyProj"* ]]
  [[ "$output" == *"worktree[backend]=$TEST_TEMP/projects/MyProj/.worktrees/backend"* ]]
  [[ "$output" == *"worktree[frontend]="* ]]
  [[ "$output" == *"worktree[qa]="* ]]
  [[ "$output" == *"duration=無制限"* ]]
}

@test "start-claude: --team は分数上限を適用しない (301m 許可)" {
  run bash "$SCRIPT" --project MyProj --team --duration 301 --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"duration=301m"* ]]
  [[ "$output" != *"上限 300m"* ]]
}

# ---- v10 統合 Goal Router (L1 / S1 / T1 経路) ----------------------
@test "start-claude: --dry-run は Goal Router の判定 (goal_effective) を表示し state.json を更新しない" {
  printf '{"goal_type":"refactoring","project":{"phase_mode":"development"}}' > "$TEST_TEMP/projects/MyProj/state.json"
  CLAUDEOS_GOAL_ROUTER_GH=0 run bash "$SCRIPT" --project MyProj --foreground --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"goal_primary=development"* ]]
  [[ "$output" == *"goal_effective=refactoring"* ]]
  run grep -c goal_router "$TEST_TEMP/projects/MyProj/state.json"; [ "$output" = "0" ]
}
@test "start-claude: --goal deep-debug は manual override として採用され dry-run に反映される" {
  CLAUDEOS_GOAL_ROUTER_GH=0 run bash "$SCRIPT" --project MyProj --background --goal deep-debug --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"goal_effective=deep-debug"* ]]
  [[ "$output" == *"goal_mode=manual"* ]]
}
@test "start-claude: --intent は user intent として Router に渡る" {
  CLAUDEOS_GOAL_ROUTER_GH=0 run bash "$SCRIPT" --project MyProj --foreground --intent "全体を評価して" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"goal_primary=assessment"* ]]
}
@test "start-claude: 不正な --goal は拒否する" {
  run bash "$SCRIPT" --project MyProj --foreground --goal bogus --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"--goal は auto"* ]]
}
@test "start-claude: --background --goal assessment は state.json に manual lock を永続化する (S1 → cron-launcher が参照)" {
  printf '{"goal_type":"mvp-release"}' > "$TEST_TEMP/projects/MyProj/state.json"
  CLAUDEOS_GOAL_ROUTER_GH=0 run bash "$SCRIPT" --project MyProj --background --goal assessment
  [ "$status" -eq 0 ]
  run python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d['goal_router']['mode'], d['goal_router']['effective_goal_type'], d['goal_type'])" "$TEST_TEMP/projects/MyProj/state.json"
  [ "$output" = "manual assessment mvp-release" ]
}
@test "start-claude: foreground 直起動は Router の /goal を合成したプロンプトを渡す (START_PROMPT の本文も保持)" {
  unset TMUX DISPLAY WAYLAND_DISPLAY
  export CCSU_ROOT="$TEST_TEMP/ccsu-root"
  mkdir -p "$CCSU_ROOT/Claude/templates/claude"
  printf '%s\n' 'TEST START PROMPT CONTENT' > "$CCSU_ROOT/Claude/templates/claude/START_PROMPT.md"
  printf '{"goal_type":"hotfix"}' > "$TEST_TEMP/projects/MyProj/state.json"
  CLAUDEOS_GOAL_ROUTER_GH=0 run bash "$SCRIPT" --project MyProj --foreground --duration 5
  [ "$status" -eq 0 ]
  grep -q -- "TEST START PROMPT CONTENT" "$TEST_TEMP/claude.log"
  grep -q -- '/goal "' "$TEST_TEMP/claude.log"
  grep -q -- '\[Goal Router\] primary=deep-debug specialized=hotfix effective_goal_type=hotfix' "$TEST_TEMP/claude.log"
}
@test "start-claude: --safe-mode は Goal Router を通さない (診断起動)" {
  printf '{"goal_type":"mvp-release"}' > "$TEST_TEMP/projects/MyProj/state.json"
  run bash "$SCRIPT" --project MyProj --safe-mode --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" != *"goal_effective="* ]]
}
