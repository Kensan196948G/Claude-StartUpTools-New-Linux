#!/usr/bin/env bats
# ============================================================
# web-startup.bats — bin/web-startup.sh のテスト
# node / curl / pgrep を PATH スタブ化し、実プロセスを起動せずに
# 起動計画 (--dry-run)・状態表示・非ループバック bind の拒否を検証する。
# ============================================================

load '../helpers/common-setup'

setup() {
  _bats_common_setup
  export CLAUDEOS_HOME="$TEST_TEMP/claudeos"
  mkdir -p "$CLAUDEOS_HOME/logs"
  export WEB_STARTUP_PORT=39919
  make_stub_bin node 'echo "node $*"; exit 0'
  make_stub_bin setsid 'shift; "$@"'
  make_stub_bin curl 'exit 0'
  make_stub_bin pgrep 'echo 12345'
  SCRIPT="$REPO_ROOT/bin/web-startup.sh"
}
teardown() { _bats_common_teardown; }

@test "web-startup: --start --dry-run は起動計画のみ表示しプロセスを起動しない" {
  run bash "$SCRIPT" --start --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"startup-server.js"* ]]
  [[ "$output" == *"--port 39919"* ]]
  [[ "$output" == *"dry-run: プロセスは起動しません"* ]]
  [ ! -f "$CLAUDEOS_HOME/web-startup.pid" ]
}

@test "web-startup: --status は未起動時に停止と表示" {
  run bash "$SCRIPT" --status
  [ "$status" -eq 0 ]
  [[ "$output" == *"停止しています"* ]]
}

@test "web-startup: --start は health 確認後に PID ファイルを書く" {
  run bash "$SCRIPT" --start
  [ "$status" -eq 0 ]
  [[ "$output" == *"起動しました"* ]]
  [[ "$output" == *"http://127.0.0.1:39919"* ]]
  [ -f "$CLAUDEOS_HOME/web-startup.pid" ]
  run cat "$CLAUDEOS_HOME/web-startup.pid"
  [ "$output" = "12345" ]
}

@test "web-startup: 非ループバック bind はパスワード無しで拒否 (fail-closed)" {
  run env -u STARTUP_WEB_PASSWORD -u DASHBOARD_PASSWORD bash "$SCRIPT" --start --lan
  [ "$status" -ne 0 ]
  [[ "$output" == *"STARTUP_WEB_PASSWORD"* ]]
}

@test "web-startup: 不明な引数でエラー" {
  run bash "$SCRIPT" --frobnicate
  [ "$status" -ne 0 ]
}

@test "web-startup: 引数なしは使い方を案内してエラー" {
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"--start"* ]]
}
