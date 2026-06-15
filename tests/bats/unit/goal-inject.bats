#!/usr/bin/env bats
# ============================================================
# goal-inject.bats — libexec/goal-extract.sh のユニットテスト
#
# 検証観点:
#   - block:   最初の /goal "..." ブロックを逐語抽出 (複数あれば先頭)
#   - ensure_stop: stop 条件欠落時に閉じ " 直前へ補い、既存時は不変
#   - truncate:    max 超過で両端 (Goal/Stop Conditions) を優先保持
#   - resolve:  type→ファイル解決、不在は mvp-release フォールバック
#   - build:    統合 (テンプレ不在は非0)
# ============================================================

load '../helpers/common-setup'

setup() {
  _bats_common_setup
  GOALS="$TEST_TEMP/goals"; mkdir -p "$GOALS"
  source "$REPO_ROOT/libexec/goal-extract.sh"
}
teardown() { _bats_common_teardown; }

# goals テンプレ生成ヘルパ: <type> <body>
_mkgoal() { printf '%s\n' "$2" > "$GOALS/$1.md"; }

# ---- block ----------------------------------------------
@test "goal_extract__block: /goal ブロックを逐語抽出する" {
  _mkgoal demo '# Goal: Demo

/goal "
■ Goal
動かす
- or stop after 20 turns
"

末尾コメント'
  run goal_extract__block "$GOALS/demo.md"
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == '/goal "' ]]
  [[ "$output" == *"■ Goal"* ]]
  [[ "${lines[${#lines[@]}-1]}" == '"' ]]
  [[ "$output" != *"末尾コメント"* ]]
}
@test "goal_extract__block: 複数 /goal は最初のブロックのみ" {
  _mkgoal multi '/goal "
first
"
/goal "
second
"'
  run goal_extract__block "$GOALS/multi.md"
  [[ "$output" == *"first"* ]]
  [[ "$output" != *"second"* ]]
}
@test "goal_extract__block: ファイル不在は非0" {
  run goal_extract__block "$GOALS/none.md"
  [ "$status" -ne 0 ]
}

# ---- ensure_stop ----------------------------------------
@test "goal_extract__ensure_stop: stop 欠落時は閉じ \" 直前へ補う" {
  run bash -c 'printf '\''/goal "\n動く\n"\n'\'' | { source "'"$REPO_ROOT"'/libexec/goal-extract.sh"; goal_extract__ensure_stop 15; }'
  [[ "$output" == *"or stop after 15 turns"* ]]
  [[ "${lines[${#lines[@]}-1]}" == '"' ]]   # stop 行は閉じ " より前
}
@test "goal_extract__ensure_stop: 既に stop があれば重複させない" {
  run bash -c 'printf '\''/goal "\n動く\n- or stop after 20 turns\n"\n'\'' | { source "'"$REPO_ROOT"'/libexec/goal-extract.sh"; goal_extract__ensure_stop 99; }'
  # 既存の 20 を尊重し 99 を足さない
  [[ "$output" == *"stop after 20 turns"* ]]
  [[ "$output" != *"stop after 99 turns"* ]]
}

# ---- truncate -------------------------------------------
@test "goal_extract__truncate: max 以下はそのまま" {
  run bash -c 'printf "short text" | { source "'"$REPO_ROOT"'/libexec/goal-extract.sh"; goal_extract__truncate 4000; }'
  [ "$output" = "short text" ]
}
@test "goal_extract__truncate: 超過で両端を保持し中間省略マーカを挿む" {
  local big; big="$(printf 'HEAD%0.s' {1..50})$(printf 'X%0.s' {1..400})$(printf 'TAIL%0.s' {1..50})"
  run bash -c 'printf "%s" "'"$big"'" | { source "'"$REPO_ROOT"'/libexec/goal-extract.sh"; goal_extract__truncate 200; }'
  [[ "$output" == HEAD* ]]            # 先頭 (Goal 相当) を保持
  [[ "$output" == *TAIL ]]           # 末尾 (Stop Conditions 相当) を保持
  [[ "$output" == *"中間省略"* ]]
  [ "${#output}" -le 220 ]           # おおよそ max + マーカ長に収まる
}

# ---- resolve --------------------------------------------
@test "goal_extract__resolve: 指定 type を解決する" {
  _mkgoal hotfix 'x'
  run goal_extract__resolve hotfix "$GOALS"
  [ "$output" = "$GOALS/hotfix.md" ]
}
@test "goal_extract__resolve: 不在は mvp-release へフォールバック" {
  _mkgoal mvp-release 'x'
  run goal_extract__resolve nonexistent "$GOALS"
  [ "$output" = "$GOALS/mvp-release.md" ]
}
@test "goal_extract__resolve: 両方不在は非0" {
  run goal_extract__resolve nonexistent "$GOALS"
  [ "$status" -ne 0 ]
}

# ---- build (統合) ---------------------------------------
@test "goal_extract__build: 抽出+stop付与を統合し /goal を出力" {
  _mkgoal mvp-release '/goal "
■ Goal
完成させる
"'
  run goal_extract__build mvp-release "$GOALS" 12
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == '/goal "' ]]
  [[ "$output" == *"完成させる"* ]]
  [[ "$output" == *"or stop after 12 turns"* ]]
}
@test "goal_extract__build: テンプレ不在は非0 (START_PROMPT のみ運用へ委譲)" {
  run goal_extract__build whatever "$GOALS"
  [ "$status" -ne 0 ]
}
