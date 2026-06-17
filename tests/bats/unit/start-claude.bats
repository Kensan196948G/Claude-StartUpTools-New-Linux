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
  make_stub_bin claude 'exit 0'
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

@test "start-claude: --safe-mode は supervisor 非経由で tmux セッションを直接起動" {
  run bash "$SCRIPT" --project MyProj --safe-mode --background --duration 5
  [ "$status" -eq 0 ]
  [[ "$output" == *"safe-mode 診断起動"* ]]
  # supervisor (autonomy.sh) を経由しない → state ファイルなし
  [ ! -f "$CLAUDEOS_HOME/supervisor/MyProj.json" ]
  # tmux_run 直接呼び出しでセッションは作成される
  [ -f "$TMUX_STATE/claudeos-MyProj" ]
}

@test "start-claude: foreground headless は tmux 外で即復帰し追尾手順を案内" {
  # tmux 外: ブロックせず即復帰し、別端末での tail -f 手順を案内する。
  # 旧実装の `tail -f` はここで run を永久ブロックしていた → 即復帰の回帰防止。
  unset TMUX
  mkdir -p "$CCSU_SUP_DIR"
  printf 'log line\n' > "$CCSU_SUP_DIR/MyProj.log"
  run bash "$SCRIPT" --project MyProj --foreground --duration 5
  [ "$status" -eq 0 ]
  [[ "$output" == *"tail -f"* ]]
  [[ "$output" == *"メニュー操作へ戻ります"* ]]
  # tmux 外なので別ウィンドウは開かない
  [ ! -f "$TMUX_STATE/new-window.log" ]
}

@test "start-claude: foreground headless は tmux 内で別ウィンドウを開き即復帰" {
  # tmux 内: 追尾ログを別ウィンドウ(別タブ)へ逃がし、メニュー端末は即解放する。
  export TMUX="/tmp/fake,0,0"
  mkdir -p "$CCSU_SUP_DIR"
  printf 'log line\n' > "$CCSU_SUP_DIR/MyProj.log"
  run bash "$SCRIPT" --project MyProj --foreground --duration 5
  [ "$status" -eq 0 ]
  [[ "$output" == *"別ウィンドウ(別タブ)で開きました"* ]]
  # tmux new-window が呼ばれ follow:<project> 名で追尾が開く
  [ -f "$TMUX_STATE/new-window.log" ]
  grep -q "follow:MyProj" "$TMUX_STATE/new-window.log"
}
