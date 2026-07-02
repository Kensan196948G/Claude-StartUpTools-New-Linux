#!/usr/bin/env bats
# ============================================================
# config.bats — lib/config-loader.sh のユニットテスト
# Linux 設定ローダーの主挙動を検証。
# ============================================================

load '../helpers/common-setup'

setup() {
  _bats_common_setup
  export AI_STARTUP_CONFIG_PATH="$TEST_TEMP/config.json"
  cat > "$AI_STARTUP_CONFIG_PATH" <<'JSON'
{
  "projectsDir": "D:\\",
  "linuxUser": "kensan",
  "projects": "/home/kensan/Projects",
  "tools": {
    "defaultTool": "claude",
    "claude": { "enabled": true, "command": "claude" },
    "codex": { "enabled": false, "command": "codex" }
  },
  "notifications": {
    "soundEnabled": true,
    "sounds": { "claude": "%USERPROFILE%\\alert.mp3" }
  },
  "recentProjects": { "historyFile": "%USERPROFILE%\\.ai-startup\\recent.json" }
}
JSON
  source "$REPO_ROOT/lib/config-loader.sh"
}
teardown() { _bats_common_teardown; }

@test "config_projects_dir: projects を優先" {
  run config_projects_dir
  [ "$output" = "/home/kensan/Projects" ]
}

@test "config_linux_user: linuxUser を取得" {
  run config_linux_user
  [ "$output" = "kensan" ]
}

@test "config_default_tool: defaultTool を取得" {
  run config_default_tool
  [ "$output" = "claude" ]
}

@test "config_tool_command: ツールの command を取得" {
  run config_tool_command claude
  [ "$output" = "claude" ]
}

@test "config_tool_enabled: claude は有効 (exit 0)" {
  run config_tool_enabled claude
  [ "$status" -eq 0 ]
}

@test "config_tool_enabled: codex は無効 (exit 非0)" {
  run config_tool_enabled codex
  [ "$status" -ne 0 ]
}

@test "config_sound_enabled: soundEnabled=true (exit 0)" {
  run config_sound_enabled
  [ "$status" -eq 0 ]
}

@test "config_sound_path: USERPROFILE を展開" {
  run config_sound_path claude
  [ "$output" = "$HOME/alert.mp3" ]
}

@test "config_sound_path: 未定義 tool は空かつ exit 0 (set -e 安全)" {
  run config_sound_path nosuchtool
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "config_recent_history_path: USERPROFILE を展開" {
  run config_recent_history_path
  [ "$output" = "$HOME/.ai-startup/recent.json" ]
}

@test "config_require: 妥当な config で成功" {
  run config_require
  [ "$status" -eq 0 ]
}

@test "config_require: 不正 JSON で失敗" {
  echo 'broken{' > "$AI_STARTUP_CONFIG_PATH"
  run config_require
  [ "$status" -ne 0 ]
}

@test "config_require: config 不在で失敗" {
  # 二重 source ガードで common.sh は再評価されないため CCSU_CONFIG_PATH を直接上書き
  CCSU_CONFIG_PATH="$TEST_TEMP/nope.json"
  run config_require
  [ "$status" -ne 0 ]
}

@test "config_project_list: .git dir/file を列挙 (ファイル/非Git/隠し除外)" {
  local base="$TEST_TEMP/pl"
  mkdir -p "$base/RepoA/.git" "$base/RepoB/.git" "$base/Worktree" "$base/PlainDir"
  printf 'gitdir: /tmp/main/.git/worktrees/Worktree\n' > "$base/Worktree/.git"
  touch "$base/file.md" "$base/.hidden"
  printf '{ "projects": "%s" }\n' "$base" > "$TEST_TEMP/pl-config.json"
  CCSU_CONFIG_PATH="$TEST_TEMP/pl-config.json"
  run config_project_list
  [[ "$output" == *"RepoA"* ]]
  [[ "$output" == *"RepoB"* ]]
  [[ "$output" == *"Worktree"* ]]
  [[ "$output" != *"PlainDir"* ]]
  [[ "$output" != *"file.md"* ]]
  [[ "$output" != *".hidden"* ]]
}

# --- 検証コマンド自動推定 (config_verify_command / config_infer_*) ---

@test "config_infer_test_command: package.json script→npm test" {
  local d="$TEST_TEMP/vt-npm"; mkdir -p "$d"
  printf '{ "scripts": { "test": "bats" } }\n' > "$d/package.json"
  run config_infer_test_command "$d"
  [ "$output" = "npm test" ]
}

@test "config_infer_test_command: Makefile target→make test (npm より優先)" {
  local d="$TEST_TEMP/vt-make"; mkdir -p "$d"
  printf 'test:\n\techo hi\n' > "$d/Makefile"
  printf '{ "scripts": { "test": "bats" } }\n' > "$d/package.json"
  run config_infer_test_command "$d"
  [ "$output" = "make test" ]
}

@test "config_infer_test_command: pyproject/tests→pytest" {
  local d="$TEST_TEMP/vt-py"; mkdir -p "$d/tests"
  run config_infer_test_command "$d"
  [ "$output" = "pytest" ]
}

@test "config_infer_test_command: Cargo.toml→cargo test / go.mod→go test" {
  local d="$TEST_TEMP/vt-rs"; mkdir -p "$d"; touch "$d/Cargo.toml"
  run config_infer_test_command "$d"; [ "$output" = "cargo test" ]
  local g="$TEST_TEMP/vt-go"; mkdir -p "$g"; touch "$g/go.mod"
  run config_infer_test_command "$g"; [ "$output" = "go test ./..." ]
}

@test "config_infer_lint_command: ruff/flake8 検出→ruff check ." {
  local d="$TEST_TEMP/vl-py"; mkdir -p "$d"
  printf '[tool.ruff]\n' > "$d/pyproject.toml"
  run config_infer_lint_command "$d"
  [ "$output" = "ruff check ." ]
}

@test "config_infer_build_command: 推定不能なら空" {
  local d="$TEST_TEMP/vb-none"; mkdir -p "$d"
  run config_infer_build_command "$d"
  [ -z "$output" ]
}

@test "config_verify_command: config .verify 上書きが推定より優先" {
  local d="$TEST_TEMP/vc-ovr"; mkdir -p "$d"
  printf '{ "scripts": { "test": "bats" } }\n' > "$d/package.json"
  printf '{ "verify": { "testCommand": "make check" } }\n' > "$TEST_TEMP/vc-config.json"
  CCSU_CONFIG_PATH="$TEST_TEMP/vc-config.json"
  run config_verify_command test "$d"
  [ "$output" = "make check" ]
}

@test "config_verify_command: 上書き空文字は検証を明示無効化 (推定へ落とさない)" {
  local d="$TEST_TEMP/vc-dis"; mkdir -p "$d"
  printf '{ "scripts": { "lint": "shellcheck" } }\n' > "$d/package.json"
  printf '{ "verify": { "lintCommand": "" } }\n' > "$TEST_TEMP/vc-config2.json"
  CCSU_CONFIG_PATH="$TEST_TEMP/vc-config2.json"
  run config_verify_command lint "$d"
  [ -z "$output" ]
}

@test "config_verify_command: 上書きキー不在なら推定へフォールバック" {
  local d="$TEST_TEMP/vc-fb"; mkdir -p "$d"
  printf '{ "scripts": { "build": "tsc" } }\n' > "$d/package.json"
  printf '{ "verify": { "testCommand": "make check" } }\n' > "$TEST_TEMP/vc-config3.json"
  CCSU_CONFIG_PATH="$TEST_TEMP/vc-config3.json"
  run config_verify_command build "$d"
  [ "$output" = "npm run build" ]
}
