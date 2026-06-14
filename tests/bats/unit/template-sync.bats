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
  # 100 bytes 以上のテンプレートが必要（サイズガード対応）
  printf '# ClaudeOS project template\n%0.sx' {1..90} > "$CCSU_ROOT/Claude/templates/claude/CLAUDE.md"
  local proj="$TEST_TEMP/proj4"
  mkdir -p "$proj"
  run template_sync__apply "$proj"
  [ "$status" -eq 0 ]
  [ -f "$proj/.claude/CLAUDE.md" ]
  grep -q "ClaudeOS project template" "$proj/.claude/CLAUDE.md"
}

@test "template_sync__apply: CLAUDE.md が既に存在する場合は上書きしない" {
  printf '# ClaudeOS project template\n%0.sx' {1..90} > "$CCSU_ROOT/Claude/templates/claude/CLAUDE.md"
  local proj="$TEST_TEMP/proj5"
  mkdir -p "$proj/.claude"
  printf '# project specific config\n%0.sx' {1..90} > "$proj/.claude/CLAUDE.md"
  run template_sync__apply "$proj"
  [ "$status" -eq 0 ]
  # プロジェクト固有設定が保護されること
  grep -q "project specific config" "$proj/.claude/CLAUDE.md"
  # バックアップが作られないこと
  local bak_count; bak_count="$(find "$proj/.claude" -name "CLAUDE.md.bak-*" | wc -l)"
  [ "$bak_count" -eq 0 ]
}

@test "template_sync__apply: CLAUDE.md が存在しない場合のみ初回配布する" {
  printf '# ClaudeOS project template new\n%0.sx' {1..90} > "$CCSU_ROOT/Claude/templates/claude/CLAUDE.md"
  local proj="$TEST_TEMP/proj6"
  mkdir -p "$proj"
  run template_sync__apply "$proj"
  [ "$status" -eq 0 ]
  # 存在しなかった場合は作成されること
  [ -f "$proj/.claude/CLAUDE.md" ]
  grep -q "ClaudeOS project template new" "$proj/.claude/CLAUDE.md"
}

@test "template_sync__apply: .claude ディレクトリがなくても作成する" {
  printf 'x\n' > "$CCSU_ROOT/Claude/templates/claude/START_PROMPT.md"
  local proj="$TEST_TEMP/proj7"
  mkdir -p "$proj"
  run template_sync__apply "$proj"
  [ "$status" -eq 0 ]
  [ -d "$proj/.claude" ]
}

# ---- CLAUDE.md サイズガード ------------------------------------
@test "template_sync__apply: CLAUDE.md テンプレートが 100 bytes 未満なら配布しない" {
  # 12 bytes のプレースホルダー（今回の障害再現）
  printf 'new content\n' > "$CCSU_ROOT/Claude/templates/claude/CLAUDE.md"
  local proj="$TEST_TEMP/proj8"
  mkdir -p "$proj/.claude"
  printf 'existing project config\n' > "$proj/.claude/CLAUDE.md"
  run template_sync__apply "$proj"
  [ "$status" -eq 0 ]
  # 既存ファイルが上書きされていないこと
  grep -q "existing project config" "$proj/.claude/CLAUDE.md"
  # バックアップが作られていないこと
  local bak_count; bak_count="$(find "$proj/.claude" -name "CLAUDE.md.bak-*" | wc -l)"
  [ "$bak_count" -eq 0 ]
}

@test "template_sync__apply: CLAUDE.md テンプレートが 100 bytes 未満なら警告ログを出す" {
  printf 'tiny\n' > "$CCSU_ROOT/Claude/templates/claude/CLAUDE.md"
  local proj="$TEST_TEMP/proj9"
  mkdir -p "$proj"
  run template_sync__apply "$proj"
  [ "$status" -eq 0 ]
  [[ "$output" == *"テンプレートが小さすぎます"* ]]
}

@test "template_sync__apply: CLAUDE.md テンプレートが 100 bytes 以上なら配布する" {
  # 100 bytes を超えるテンプレートは正常配布
  printf '%0.s=' {1..101} > "$CCSU_ROOT/Claude/templates/claude/CLAUDE.md"
  local proj="$TEST_TEMP/proj10"
  mkdir -p "$proj"
  run template_sync__apply "$proj"
  [ "$status" -eq 0 ]
  [ -f "$proj/.claude/CLAUDE.md" ]
}

# ---- .coderabbit.yaml ------------------------------------------
@test "template_sync__apply: .coderabbit.yaml を初回配布する" {
  printf 'language: "ja-JP"\n' > "$CCSU_ROOT/Claude/templates/claude/.coderabbit.yaml"
  local proj="$TEST_TEMP/proj11"
  mkdir -p "$proj"
  run template_sync__apply "$proj"
  [ "$status" -eq 0 ]
  [ -f "$proj/.coderabbit.yaml" ]
  grep -q 'ja-JP' "$proj/.coderabbit.yaml"
}

@test "template_sync__apply: .coderabbit.yaml が同一内容なら上書きもバックアップもしない" {
  printf 'language: "ja-JP"\n' > "$CCSU_ROOT/Claude/templates/claude/.coderabbit.yaml"
  local proj="$TEST_TEMP/proj12"
  mkdir -p "$proj"
  printf 'language: "ja-JP"\n' > "$proj/.coderabbit.yaml"
  run template_sync__apply "$proj"
  [ "$status" -eq 0 ]
  local bak_count; bak_count="$(find "$proj" -maxdepth 1 -name ".coderabbit.yaml.bak-*" | wc -l)"
  [ "$bak_count" -eq 0 ]
}

@test "template_sync__apply: .coderabbit.yaml が差分ありならバックアップして上書き" {
  printf 'language: "ja-JP"\n' > "$CCSU_ROOT/Claude/templates/claude/.coderabbit.yaml"
  local proj="$TEST_TEMP/proj13"
  mkdir -p "$proj"
  printf 'language: "en-US"\n' > "$proj/.coderabbit.yaml"
  run template_sync__apply "$proj"
  [ "$status" -eq 0 ]
  # テンプレートの内容に更新されていること
  grep -q 'ja-JP' "$proj/.coderabbit.yaml"
  # バックアップが作られていること
  local bak_count; bak_count="$(find "$proj" -maxdepth 1 -name ".coderabbit.yaml.bak-*" | wc -l)"
  [ "$bak_count" -eq 1 ]
}

@test "template_sync__apply: .coderabbit.yaml テンプレートなしでも正常終了" {
  local proj="$TEST_TEMP/proj14"
  mkdir -p "$proj"
  run template_sync__apply "$proj"
  [ "$status" -eq 0 ]
  [ ! -f "$proj/.coderabbit.yaml" ]
}
