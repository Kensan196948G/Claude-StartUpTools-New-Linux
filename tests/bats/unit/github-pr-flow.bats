#!/usr/bin/env bats
# ============================================================
# github-pr-flow.bats — lib/github-pr-flow.sh のユニットテスト
# 純粋関数 (remote 解析 / 保護ブランチ / rollup 集計 / ゲート評価) を検証。
# gh 依存の副作用は対象外 (bin 側)。
# ============================================================

load '../helpers/common-setup'

setup() {
  _bats_common_setup
  source "$REPO_ROOT/lib/github-pr-flow.sh"
}
teardown() { _bats_common_teardown; }

@test "prflow__remote_to_repo: ssh 形式" {
  run prflow__remote_to_repo "git@github.com:Owner/Repo.git"
  [ "$output" = "Owner/Repo" ]
}

@test "prflow__remote_to_repo: https 形式 (.git 有無)" {
  run prflow__remote_to_repo "https://github.com/Owner/My-Repo"
  [ "$output" = "Owner/My-Repo" ]
  run prflow__remote_to_repo "https://github.com/Owner/My-Repo.git"
  [ "$output" = "Owner/My-Repo" ]
}

@test "prflow__remote_to_repo: 非 GitHub は空" {
  run prflow__remote_to_repo "https://gitlab.com/o/r.git"
  [ -z "$output" ]
}

@test "prflow__is_protected_branch: main/master/develop は保護" {
  run prflow__is_protected_branch main;    [ "$status" -eq 0 ]
  run prflow__is_protected_branch master;  [ "$status" -eq 0 ]
  run prflow__is_protected_branch develop; [ "$status" -eq 0 ]
}

@test "prflow__is_protected_branch: feature ブランチは非保護" {
  run prflow__is_protected_branch feat/x
  [ "$status" -ne 0 ]
}

@test "prflow__rollup_summary: conclusion と state 両系統を集計" {
  run prflow__rollup_summary '[{"conclusion":"SUCCESS"},{"conclusion":"SKIPPED"},{"conclusion":"FAILURE"},{"status":"IN_PROGRESS"},{"state":"SUCCESS"}]'
  [ "$output" = "success=3 pending=1 failure=1 total=5" ]
}

@test "prflow__rollup_summary: 空配列は全 0" {
  run prflow__rollup_summary '[]'
  [ "$output" = "success=0 pending=0 failure=0 total=0" ]
}

@test "prflow__rollup_summary: 小文字 conclusion も正規化" {
  run prflow__rollup_summary '[{"conclusion":"success"},{"state":"failure"}]'
  [ "$output" = "success=1 pending=0 failure=1 total=2" ]
}

@test "prflow__gate_eval: 完全にクリーンな feature PR は ALLOW" {
  local pr='{"isDraft":false,"mergeable":"MERGEABLE","baseRefName":"feat-base","reviewDecision":"APPROVED","statusCheckRollup":[{"conclusion":"SUCCESS"}]}'
  run prflow__gate_eval "$pr"
  [ "${lines[0]}" = "decision=ALLOW" ]
}

@test "prflow__gate_eval: base=main は他が完璧でも BLOCK (人間最終決断)" {
  local pr='{"isDraft":false,"mergeable":"MERGEABLE","baseRefName":"main","reviewDecision":"APPROVED","statusCheckRollup":[{"conclusion":"SUCCESS"}]}'
  run prflow__gate_eval "$pr"
  [ "${lines[0]}" = "decision=BLOCK" ]
  [[ "$output" == *"保護ブランチ"* ]]
}

@test "prflow__gate_eval: draft は BLOCK" {
  local pr='{"isDraft":true,"mergeable":"MERGEABLE","baseRefName":"feat-base","reviewDecision":"APPROVED","statusCheckRollup":[{"conclusion":"SUCCESS"}]}'
  run prflow__gate_eval "$pr"
  [ "${lines[0]}" = "decision=BLOCK" ]
  [[ "$output" == *"draft"* ]]
}

@test "prflow__gate_eval: CI failure/pending は BLOCK" {
  local pr='{"isDraft":false,"mergeable":"MERGEABLE","baseRefName":"feat-base","reviewDecision":"APPROVED","statusCheckRollup":[{"conclusion":"FAILURE"}]}'
  run prflow__gate_eval "$pr"
  [ "${lines[0]}" = "decision=BLOCK" ]
  [[ "$output" == *"CI failure=1"* ]]
}

@test "prflow__gate_eval: CI 成功ゼロ (チェック無し) は BLOCK" {
  local pr='{"isDraft":false,"mergeable":"MERGEABLE","baseRefName":"feat-base","reviewDecision":"APPROVED","statusCheckRollup":[]}'
  run prflow__gate_eval "$pr"
  [ "${lines[0]}" = "decision=BLOCK" ]
  [[ "$output" == *"success=0"* ]]
}

@test "prflow__gate_eval: mergeable!=MERGEABLE は BLOCK" {
  local pr='{"isDraft":false,"mergeable":"CONFLICTING","baseRefName":"feat-base","reviewDecision":"APPROVED","statusCheckRollup":[{"conclusion":"SUCCESS"}]}'
  run prflow__gate_eval "$pr"
  [ "${lines[0]}" = "decision=BLOCK" ]
  [[ "$output" == *"mergeable"* ]]
}

@test "prflow__gate_eval: review=CHANGES_REQUESTED は BLOCK" {
  local pr='{"isDraft":false,"mergeable":"MERGEABLE","baseRefName":"feat-base","reviewDecision":"CHANGES_REQUESTED","statusCheckRollup":[{"conclusion":"SUCCESS"}]}'
  run prflow__gate_eval "$pr"
  [ "${lines[0]}" = "decision=BLOCK" ]
  [[ "$output" == *"CHANGES_REQUESTED"* ]]
}