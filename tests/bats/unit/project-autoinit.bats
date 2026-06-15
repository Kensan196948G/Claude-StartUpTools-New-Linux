#!/usr/bin/env bats
# ============================================================
# project-autoinit.bats — lib/project-autoinit.sh のユニットテスト
#
# 検証観点:
#   - 非 Git フォルダ → git init + CLAUDE.md + 初期 commit で登録対象へ昇格
#   - 既存 .git フォルダ → 触らない (冪等)
#   - リポジトリ自身 (CCSU_ROOT) は除外
#   - localExcludes 記載フォルダは除外
#   - .autoInitProjects=false で無効化
# ============================================================

load '../helpers/common-setup'

setup() {
  _bats_common_setup

  # CCSU_ROOT をテンポラリへ隔離し、テンプレートを用意。
  export CCSU_ROOT="$TEST_TEMP/root"
  mkdir -p "$CCSU_ROOT/Claude/templates/claude"
  printf 'TEMPLATE BODY\n' > "$CCSU_ROOT/Claude/templates/claude/CLAUDE.md"

  # projects ディレクトリと config を用意。
  PROJECTS="$TEST_TEMP/projects"
  mkdir -p "$PROJECTS"
  export PROJECTS

  export AI_STARTUP_CONFIG_PATH="$TEST_TEMP/config.json"
  cat > "$AI_STARTUP_CONFIG_PATH" <<JSON
{
  "projects": "$PROJECTS",
  "autoInitProjects": true,
  "localExcludes": ["Skipped"]
}
JSON

  # git identity を固定 (CI で未設定でも commit が通るように)。
  export GIT_AUTHOR_NAME="bats" GIT_AUTHOR_EMAIL="bats@example.com"
  export GIT_COMMITTER_NAME="bats" GIT_COMMITTER_EMAIL="bats@example.com"

  source "$REPO_ROOT/lib/common.sh"
  source "$REPO_ROOT/lib/config-loader.sh"
  source "$REPO_ROOT/lib/project-autoinit.sh"
}
teardown() { _bats_common_teardown; }

@test "新規フォルダを git init + CLAUDE.md + commit で登録対象へ昇格" {
  mkdir -p "$PROJECTS/Fresh"
  run project_autoinit_scan
  [ "$status" -eq 0 ]
  [ -d "$PROJECTS/Fresh/.git" ]
  [ -f "$PROJECTS/Fresh/CLAUDE.md" ]
  run git -C "$PROJECTS/Fresh" rev-parse HEAD
  [ "$status" -eq 0 ]
}

@test "既存 .git フォルダは触らない (冪等)" {
  mkdir -p "$PROJECTS/Existing/.git"
  printf 'ORIGINAL\n' > "$PROJECTS/Existing/CLAUDE.md"
  run project_autoinit_scan
  [ "$status" -eq 0 ]
  # 既存 CLAUDE.md は上書きされない
  run cat "$PROJECTS/Existing/CLAUDE.md"
  [ "$output" = "ORIGINAL" ]
}

@test "localExcludes 記載フォルダは初期化しない" {
  mkdir -p "$PROJECTS/Skipped"
  run project_autoinit_scan
  [ "$status" -eq 0 ]
  [ ! -d "$PROJECTS/Skipped/.git" ]
}

@test ".autoInitProjects=false で無効化" {
  cat > "$AI_STARTUP_CONFIG_PATH" <<JSON
{ "projects": "$PROJECTS", "autoInitProjects": false }
JSON
  mkdir -p "$PROJECTS/Disabled"
  run project_autoinit_scan
  [ "$status" -eq 0 ]
  [ ! -d "$PROJECTS/Disabled/.git" ]
}

@test "既存 CLAUDE.md があれば上書きせず温存する (非破壊)" {
  mkdir -p "$PROJECTS/Keep"
  printf 'USER CONTENT\n' > "$PROJECTS/Keep/CLAUDE.md"
  run project_autoinit_scan
  [ "$status" -eq 0 ]
  [ -d "$PROJECTS/Keep/.git" ]
  run cat "$PROJECTS/Keep/CLAUDE.md"
  [ "$output" = "USER CONTENT" ]
}
