#!/usr/bin/env bats
# ============================================================
# release-check.bats — lib/release-check.sh のユニットテスト
# 複合ゲート (git/README/gitignore/test/lint/build) を検証。
# ============================================================

load '../helpers/common-setup'

setup() {
  _bats_common_setup
  export AI_STARTUP_CONFIG_PATH="$TEST_TEMP/config.json"
  export PROJ="$TEST_TEMP/proj"
  mkdir -p "$PROJ"
  printf '{ "projects": "%s" }\n' "$TEST_TEMP" > "$AI_STARTUP_CONFIG_PATH"
  source "$REPO_ROOT/lib/release-check.sh"
}
teardown() { _bats_common_teardown; }

_git_init_clean() {
  git -C "$PROJ" init -q
  git -C "$PROJ" config user.email t@t
  git -C "$PROJ" config user.name t
  git -C "$PROJ" add -A 2>/dev/null || true
  git -C "$PROJ" commit -qm init 2>/dev/null || true
}

@test "relchk__git_state: 非 git は NG" {
  run relchk__git_state "$PROJ" 0
  [[ "$output" == *"|NG|"* ]]
}

@test "relchk__git_state: clean worktree は OK" {
  echo x > "$PROJ/f"; _git_init_clean
  run relchk__git_state "$PROJ" 0
  [[ "$output" == "Git worktree|OK|clean" ]]
}

@test "relchk__git_state: dirty は NG / --allow-dirty で OK" {
  echo x > "$PROJ/f"; _git_init_clean
  echo y > "$PROJ/untracked"
  run relchk__git_state "$PROJ" 0
  [[ "$output" == *"|NG|"* ]]
  run relchk__git_state "$PROJ" 1
  [[ "$output" == *"|OK|"* ]]
}

@test "relchk__readme: 不在は NG / 非空は OK" {
  run relchk__readme "$PROJ"
  [[ "$output" == *"|NG|"* ]]
  echo "# hi" > "$PROJ/README.md"
  run relchk__readme "$PROJ"
  [[ "$output" == "README|OK|present" ]]
}

@test "relchk__readme: config 必須テキスト欠落は NG" {
  printf '{ "projects": "%s", "releaseCheck": { "readmeRequires": ["Release手順"] } }\n' "$TEST_TEMP" > "$AI_STARTUP_CONFIG_PATH"
  CCSU_CONFIG_PATH="$AI_STARTUP_CONFIG_PATH"
  echo "# hi" > "$PROJ/README.md"
  run relchk__readme "$PROJ"
  [[ "$output" == *"|NG|"* ]]
  [[ "$output" == *"Release手順"* ]]
}

@test "relchk__gitignore: 不在は NG / 存在は OK" {
  run relchk__gitignore "$PROJ"
  [[ "$output" == *"|NG|"* ]]
  printf 'logs/\n' > "$PROJ/.gitignore"
  run relchk__gitignore "$PROJ"
  [[ "$output" == "Runtime gitignore|OK|present" ]]
}

@test "relchk__gitignore: config 必須パターン欠落は NG" {
  printf '{ "projects": "%s", "releaseCheck": { "gitignoreRequires": ["state.json"] } }\n' "$TEST_TEMP" > "$AI_STARTUP_CONFIG_PATH"
  CCSU_CONFIG_PATH="$AI_STARTUP_CONFIG_PATH"
  printf 'logs/\n' > "$PROJ/.gitignore"
  run relchk__gitignore "$PROJ"
  [[ "$output" == *"|NG|"* ]]
  [[ "$output" == *"state.json"* ]]
}

@test "relchk__verify: コマンド未定義は SKIP" {
  run relchk__verify "$PROJ" test
  [[ "$output" == "Test|SKIP|コマンド未定義" ]]
}

@test "relchk__verify: 成功コマンドは OK" {
  printf '{ "scripts": { "test": "true" } }\n' > "$PROJ/package.json"
  run relchk__verify "$PROJ" test
  [[ "$output" == "Test|OK|npm test" ]]
}

@test "relchk__verify: 失敗コマンドは NG (exit 付き)" {
  printf '{ "scripts": { "lint": "false" } }\n' > "$PROJ/package.json"
  run relchk__verify "$PROJ" lint
  [[ "$output" == *"Lint|NG|npm run lint (exit="* ]]
}

@test "relchk__verify: CCSU_RELCHK_DRYRUN=1 は実行せず SKIP" {
  printf '{ "scripts": { "test": "false" } }\n' > "$PROJ/package.json"
  CCSU_RELCHK_DRYRUN=1 run relchk__verify "$PROJ" test
  [[ "$output" == *"|SKIP|dry-run: npm test"* ]]
}

@test "relchk__collect + relchk__passed: 全 OK/SKIP なら passed" {
  echo x > "$PROJ/f"; _git_init_clean
  echo "# hi" > "$PROJ/README.md"
  printf 'logs/\n' > "$PROJ/.gitignore"
  git -C "$PROJ" add -A; git -C "$PROJ" commit -qm docs
  local results; results="$(relchk__collect "$PROJ")"
  run relchk__passed "$results"
  [ "$status" -eq 0 ]
}

@test "relchk__collect + relchk__passed: NG があれば fail" {
  # README/gitignore 無し → NG 複数
  echo x > "$PROJ/f"; _git_init_clean
  local results; results="$(relchk__collect "$PROJ")"
  run relchk__passed "$results"
  [ "$status" -ne 0 ]
}

@test "relchk__collect: --skip-tests/--skip-lint/--skip-build で verify 行が出ない" {
  echo x > "$PROJ/f"; _git_init_clean
  printf '{ "scripts": { "test": "true", "lint": "true", "build": "true" } }\n' > "$PROJ/package.json"
  local results; results="$(relchk__collect "$PROJ" --skip-tests --skip-lint --skip-build)"
  [[ "$results" != *"Test|"* ]]
  [[ "$results" != *"Lint|"* ]]
  [[ "$results" != *"Build|"* ]]
}