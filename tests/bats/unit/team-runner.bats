#!/usr/bin/env bats
# ============================================================
# team-runner.bats — lib/team-runner.sh のユニットテスト
# tmux/claude を PATH スタブ化 (tmux 状態は $TMUX_STATE ファイルマーカー)。
# worktree 系は実 git リポジトリ (空コミット) で検証する。
# ============================================================

load '../helpers/common-setup'

setup() {
  _bats_common_setup
  export TMUX_STATE="$TEST_TEMP/tmux-state"
  mkdir -p "$TMUX_STATE"

  make_stub_bin tmux '
state="${TMUX_STATE:?}"; mkdir -p "$state"
sub="${1:-}"; shift || true
case "$sub" in
  has-session) [[ "${1:-}" == "-t" ]] && shift; [[ -f "$state/${1:-}" ]] && exit 0 || exit 1 ;;
  new-session) name=""; while [[ $# -gt 0 ]]; do [[ "$1" == "-s" ]] && { name="${2:-}"; shift 2; continue; }; shift; done; [[ -n "$name" ]] && touch "$state/$name"; exit 0 ;;
  split-window) printf "%s\n" "$*" >> "$state/split-window.log"; exit 0 ;;
  attach|pipe-pane) exit 0 ;;
  kill-session) [[ "${1:-}" == "-t" ]] && shift; rm -f "$state/${1:-}"; exit 0 ;;
  *) exit 0 ;;
esac
'
  # --help に --name を含める (ccsu_claude_supports_name の probe 用)
  make_stub_bin claude 'if [[ "${1:-}" == "--help" ]]; then echo "  --name <name>  session name"; fi; exit 0'

  export AI_STARTUP_CONFIG_PATH="$TEST_TEMP/config.json"
  cat > "$AI_STARTUP_CONFIG_PATH" <<JSON
{ "projects": "$TEST_TEMP/projects", "projectsDir": "$TEST_TEMP/projects" }
JSON
  export CLAUDEOS_HOME="$TEST_TEMP/claudeos"

  # 実 git リポジトリのプロジェクト (worktree add には有効な HEAD が必要 → 空コミット)
  PROJ_DIR="$TEST_TEMP/projects/MyProj"
  mkdir -p "$PROJ_DIR/.claude"
  git -C "$PROJ_DIR" init -q -b main
  git -C "$PROJ_DIR" -c user.email=test@example.com -c user.name=test \
    commit -q --allow-empty -m "init"

  source "$REPO_ROOT/lib/team-runner.sh"
}
teardown() { _bats_common_teardown; }

@test "team__session_name: claudeos-team- 接頭辞 + 安全化" {
  run team__session_name "My Proj"
  [ "$output" = "claudeos-team-My_Proj" ]
}

@test "team__worktree_dir: <project>/.worktrees/<role> を返す" {
  run team__worktree_dir /path/to/Proj backend
  [ "$output" = "/path/to/Proj/.worktrees/backend" ]
}

@test "team__ensure_exclude: .worktrees/ を .git/info/exclude へ冪等追記" {
  team__ensure_exclude "$PROJ_DIR"
  team__ensure_exclude "$PROJ_DIR"
  run grep -cxF '.worktrees/' "$PROJ_DIR/.git/info/exclude"
  [ "$output" = "1" ]
}

@test "team__ensure_worktree: claudeos/<role> ブランチで worktree を作成しパスを返す" {
  # run は stderr (git の "Preparing worktree") も混合キャプチャするため、
  # 呼び出し側 team_run と同じコマンド置換 (stdout のみ) で契約を検証する
  local result
  result="$(team__ensure_worktree "$PROJ_DIR" backend)"
  [ "$result" = "$PROJ_DIR/.worktrees/backend" ]
  [ -d "$PROJ_DIR/.worktrees/backend" ]
  run git -C "$PROJ_DIR/.worktrees/backend" branch --show-current
  [ "$output" = "claudeos/backend" ]
}

@test "team__ensure_worktree: 既存 worktree は再利用する" {
  team__ensure_worktree "$PROJ_DIR" qa > /dev/null
  run team__ensure_worktree "$PROJ_DIR" qa
  [ "$status" -eq 0 ]
  [ "$output" = "$PROJ_DIR/.worktrees/qa" ]
  # git worktree list 上も 1 エントリのまま (重複登録なし)
  run bash -c "git -C '$PROJ_DIR' worktree list | grep -c 'claudeos/qa'"
  [ "$output" = "1" ]
}

@test "team__pane_cmd: 役割別 --name と per-pane 環境変数を含む" {
  run team__pane_cmd "$PROJ_DIR" backend MyProj 0 ""
  [ "$status" -eq 0 ]
  [[ "$output" == *"--name 'claudeos-MyProj-backend'"* ]]
  [[ "$output" == *"CLAUDE_PROJECT='MyProj'"* ]]
  [[ "$output" == *"CLAUDEOS_HOOKS_DIR='$PROJ_DIR/.claude/claudeos/scripts/hooks'"* ]]
  [[ "$output" == *"timeout --foreground 0s"* ]]
}

@test "team__pane_cmd: CCSU_SESSION_NAME=0 なら --name を付けない" {
  export CCSU_SESSION_NAME=0
  run team__pane_cmd "$PROJ_DIR" backend MyProj 0 ""
  [ "$status" -eq 0 ]
  [[ "$output" != *"--name"* ]]
}

@test "team_run: claudeos-team-<safe> セッションと役割別 worktree を作成する" {
  run team_run MyProj 0
  [ "$status" -eq 0 ]
  [ -f "$TMUX_STATE/claudeos-team-MyProj" ]
  [ -d "$PROJ_DIR/.worktrees/backend" ]
  [ -d "$PROJ_DIR/.worktrees/frontend" ]
  [ -d "$PROJ_DIR/.worktrees/qa" ]
  [[ "$output" == *"4役割一括起動"* ]]
  [[ "$output" == *"claudeos-MyProj-cto"* ]]
  # cto の new-session に加えて 3 役割分の split-window が実行されている
  run grep -c . "$TMUX_STATE/split-window.log"
  [ "$output" = "3" ]
}

@test "team_run: ログディレクトリを作成する" {
  team_run MyProj 0
  [ -d "$CLAUDEOS_HOME/logs" ]
}

@test "team_run: 既に起動中なら再作成せず接続案内" {
  touch "$TMUX_STATE/claudeos-team-MyProj"
  run team_run MyProj 0
  [ "$status" -eq 0 ]
  [[ "$output" == *"既に起動中"* ]]
  # 起動中パスでは worktree を新規作成しない
  [ ! -d "$PROJ_DIR/.worktrees/backend" ]
}

@test "team_run: Git リポジトリでないプロジェクトはエラー" {
  mkdir -p "$TEST_TEMP/projects/NotGit"
  run team_run NotGit 0
  [ "$status" -ne 0 ]
  [[ "$output" == *"Git リポジトリではない"* ]]
}

@test "team_run: プロジェクト不在でエラー" {
  run team_run NoSuchProj 0
  [ "$status" -ne 0 ]
}
