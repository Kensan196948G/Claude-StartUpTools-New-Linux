#!/usr/bin/env bats
# ============================================================
# startup-state.bats — libexec/startup-state.sh のテスト
# 一時プロジェクトディレクトリ + 一時 CLAUDEOS_HOME で JSON 形状を検証する。
# ============================================================

load '../helpers/common-setup'

setup() {
  _bats_common_setup
  export CLAUDEOS_HOME="$TEST_TEMP/claudeos"
  mkdir -p "$CLAUDEOS_HOME/supervisor" "$CLAUDEOS_HOME/foreground" "$CLAUDEOS_HOME/sessions"
  export AI_STARTUP_CONFIG_PATH="$TEST_TEMP/config.json"

  PDIR="$TEST_TEMP/projects"
  mkdir -p "$PDIR/Alpha-App/.git" "$PDIR/Beta-Site/.git"
  mkdir -p "$PDIR/NotARepo"                 # .git 無しは候補にならない
  echo "not json" > "$PDIR/loose.txt"
  cat > "$AI_STARTUP_CONFIG_PATH" <<JSON
{ "projects": "$PDIR", "projectGroups": [], "localExcludes": [] }
JSON
  SCRIPT="$REPO_ROOT/libexec/startup-state.sh"
}
teardown() { _bats_common_teardown; }

@test "startup-state: .git 付きディレクトリのみを列挙する" {
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.projects | length')" -eq 2 ]
  [ "$(echo "$output" | jq -r '[.projects[].name] | sort | join(",")')" = "Alpha-App,Beta-Site" ]
  [ "$(echo "$output" | jq -r '.projects[0].run_status')" = "ok" ]
  [ "$(echo "$output" | jq -r '.projects[0].running')" = "false" ]
}

@test "startup-state: Goal Router の Primary/Specialized と limits を返す" {
  run bash "$SCRIPT"
  [ "$(echo "$output" | jq -r '.goals.primary | length')" -eq 5 ]
  [ "$(echo "$output" | jq -r '.goals.specialized | length')" -eq 6 ]
  [ "$(echo "$output" | jq -r '.goals.primary[0].name')" = "development" ]
  [ "$(echo "$output" | jq -r '.limits.max_sessions')" = "4" ]
}

@test "startup-state: supervisor json の running をセッションとして数える" {
  echo '{"project":"Alpha-App","status":"running","pid":'"$$"',"restarts_today":1}' \
    > "$CLAUDEOS_HOME/supervisor/Alpha-App.json"
  run bash "$SCRIPT"
  [ "$(echo "$output" | jq -r '.sessions.headless[0]')" = "Alpha-App" ]
  [ "$(echo "$output" | jq -r '.sessions.count')" -eq 1 ]
  [ "$(echo "$output" | jq -r '.projects[] | select(.name=="Alpha-App") | .running')" = "true" ]
  [ "$(echo "$output" | jq -r '.projects[] | select(.name=="Alpha-App") | .supervisor.alive')" = "true" ]
}

@test "startup-state: 死んでいる PID は running 扱いしない" {
  echo '{"project":"Alpha-App","status":"running","pid":999999}' \
    > "$CLAUDEOS_HOME/supervisor/Alpha-App.json"
  run bash "$SCRIPT"
  [ "$(echo "$output" | jq -r '.sessions.count')" -eq 0 ]
  [ "$(echo "$output" | jq -r '.projects[] | select(.name=="Alpha-App") | .supervisor.alive')" = "false" ]
}

@test "startup-state: stderr に何も出さない (stdout は JSON のみ / lib 欠落を検知)" {
  # lib 側に関数が無い状態 (CI はコミット済みコードだけで動く) で command not found が
  # stderr に出ると、bats の run が stderr を混ぜて JSON 検証が壊れる。ここで固定する。
  run bash -c 'bash "$1" 2>&1 >/dev/null' _ "$SCRIPT"
  [ -z "$output" ]
}

@test "startup-state: state.json / ~/.claudeos を書き換えない (read-only)" {
  touch "$CLAUDEOS_HOME/supervisor/.keep"
  local before after
  before="$(find "$CLAUDEOS_HOME" -type f -exec md5sum {} \; | sort)"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  after="$(find "$CLAUDEOS_HOME" -type f -exec md5sum {} \; | sort)"
  [ "$before" = "$after" ]
}
