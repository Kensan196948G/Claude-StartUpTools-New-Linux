#!/usr/bin/env bats
# ============================================================
# template-sync.bats — lib/template-sync.sh のユニットテスト
# ============================================================

load '../helpers/common-setup'

setup() {
  _bats_common_setup

  # CCSU_ROOT → テスト用に差し替え
  export CCSU_ROOT="$TEST_TEMP/ccsu"
  mkdir -p "$CCSU_ROOT/Claude/templates/claude"

  # バックアップ日付スタンプを固定 (冪等テスト)
  export CCSU_TEMPLATE_SYNC_DATE="20991231-000000"

  # config (source 内 common.sh が参照)
  export AI_STARTUP_CONFIG_PATH="$TEST_TEMP/config.json"
  printf '{ "projects": "%s/projects" }\n' "$TEST_TEMP" > "$AI_STARTUP_CONFIG_PATH"

  source "$REPO_ROOT/lib/template-sync.sh"
}
teardown() { _bats_common_teardown; }

# ---- START_PROMPT.md -------------------------------------------
@test "template_sync__apply: START_PROMPT.md を配布する" {
  printf 'prompt content\n' > "$CCSU_ROOT/Claude/templates/claude/START_PROMPT.md"
  local proj="$TEST_TEMP/proj1"
  mkdir -p "$proj"
  run template_sync__apply "$proj"
  [ "$status" -eq 0 ]
  [ -f "$proj/.claude/START_PROMPT.md" ]
  grep -q "prompt content" "$proj/.claude/START_PROMPT.md"
}

@test "template_sync__apply: テンプレートなし時も正常終了" {
  local proj="$TEST_TEMP/proj2"
  mkdir -p "$proj"
  run template_sync__apply "$proj"
  [ "$status" -eq 0 ]
}

@test "template_sync__apply: START_PROMPT.md を毎回上書きする" {
  printf 'v1\n' > "$CCSU_ROOT/Claude/templates/claude/START_PROMPT.md"
  local proj="$TEST_TEMP/proj3"
  mkdir -p "$proj/.claude"
  printf 'old\n' > "$proj/.claude/START_PROMPT.md"
  run template_sync__apply "$proj"
  [ "$status" -eq 0 ]
  grep -q "v1" "$proj/.claude/START_PROMPT.md"
}

# ---- CLAUDE.md -------------------------------------------------
@test "template_sync__apply: CLAUDE.md を初回配布する" {
  printf 'claude md content\n' > "$CCSU_ROOT/Claude/templates/claude/CLAUDE.md"
  local proj="$TEST_TEMP/proj4"
  mkdir -p "$proj"
  run template_sync__apply "$proj"
  [ "$status" -eq 0 ]
  [ -f "$proj/.claude/CLAUDE.md" ]
  grep -q "claude md content" "$proj/.claude/CLAUDE.md"
}

@test "template_sync__apply: CLAUDE.md が同内容ならバックアップを作らない" {
  printf 'same\n' > "$CCSU_ROOT/Claude/templates/claude/CLAUDE.md"
  local proj="$TEST_TEMP/proj5"
  mkdir -p "$proj/.claude"
  printf 'same\n' > "$proj/.claude/CLAUDE.md"
  run template_sync__apply "$proj"
  [ "$status" -eq 0 ]
  # .bak ファイルが存在しないこと
  local bak_count; bak_count="$(find "$proj/.claude" -name "CLAUDE.md.bak-*" | wc -l)"
  [ "$bak_count" -eq 0 ]
}

@test "template_sync__apply: CLAUDE.md が差分ありならバックアップ→上書き" {
  printf 'new content\n' > "$CCSU_ROOT/Claude/templates/claude/CLAUDE.md"
  local proj="$TEST_TEMP/proj6"
  mkdir -p "$proj/.claude"
  printf 'old content\n' > "$proj/.claude/CLAUDE.md"
  run template_sync__apply "$proj"
  [ "$status" -eq 0 ]
  # 固定スタンプのバックアップが作られること
  [ -f "$proj/.claude/CLAUDE.md.bak-20991231-000000" ]
  # 新内容に更新されること
  grep -q "new content" "$proj/.claude/CLAUDE.md"
}

@test "template_sync__apply: .claude ディレクトリがなくても作成する" {
  printf 'x\n' > "$CCSU_ROOT/Claude/templates/claude/START_PROMPT.md"
  local proj="$TEST_TEMP/proj7"
  mkdir -p "$proj"
  run template_sync__apply "$proj"
  [ "$status" -eq 0 ]
  [ -d "$proj/.claude" ]
}
