#!/usr/bin/env bats
# ============================================================
# deploy-prep.bats — bin/deploy-prep.sh のテスト
#
# 検証観点 (D1/D2/D3 の解消):
#   - runbook を実際に生成し、フラグは実ファイルの存在に一致する
#   - --dry-run は state も reports/ も書かない
#   - 生成失敗時は exit 1 で runbook_generated=false に戻す (嘘のフラグを立てない)
#   - 生成物に commit SHA / tree_sha256 が入る
#   - 生成物に placeholder (example.com / コメントアウト deploy / {PLACEHOLDER}) が無い
#   - --checklist-done のときだけ pre_deploy_checklist_done=true
#   - --project はプロジェクト側の state/reports を更新する
#
# 隔離: state は $TEST_TEMP、CLAUDEOS_HOME は $TEST_TEMP/home。
#       実 state.json / 実 ~/.claudeos には触れない。runbook 生成は実 node を使う。
# ============================================================

load '../helpers/common-setup'

setup() {
  _bats_common_setup

  export CLAUDEOS_HOME="$TEST_TEMP/home"
  mkdir -p "$CLAUDEOS_HOME/releases/production-current"
  export CCSU_STATE_FILE="$TEST_TEMP/state.json"
  STATE="$CCSU_STATE_FILE"
  RUNBOOK="$TEST_TEMP/reports/deploy-runbook.md"
  SCRIPT="$REPO_ROOT/bin/deploy-prep.sh"

  # 生成物に埋まる tree_sha256 の fixture (64 hex)
  TREE="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  jq -n --arg tree "$TREE" --arg commit "1111111111111111111111111111111111111111" \
    '{schema_version:1,commit:$commit,short_commit:"1111111",ref:"test",
      built_at:"2026-01-01T00:00:00Z",file_count:1,tree_sha256:$tree,
      files:[{path:"a.txt",sha256:"22",size:2}]}' \
    > "$CLAUDEOS_HOME/releases/production-current/manifest.json"

  # commit が実値で埋まるよう、TEST_TEMP を git リポジトリにする
  git -C "$TEST_TEMP" init -q
  git -C "$TEST_TEMP" config user.email "t@example.invalid"
  git -C "$TEST_TEMP" config user.name "t"
  printf 'x\n' > "$TEST_TEMP/a.txt"
  git -C "$TEST_TEMP" add -A
  git -C "$TEST_TEMP" commit -qm "init"
  HEAD_SHA="$(git -C "$TEST_TEMP" rev-parse HEAD)"

  jq -n '{project:{name:"demo"},goal:{title:"demo"},
          stable:{stable_achieved:false,consecutive_success:0},
          deploy:{ready:false,runbook_generated:false,runbook_path:null,
                  pre_deploy_checklist_done:false,environment:null,notes:""}}' \
    > "$STATE"
}

teardown() { _bats_common_teardown; }

@test "deploy-prep: --dry-run は state も reports/ も書かない" {
  local before; before="$(cat "$STATE")"

  run bash "$SCRIPT" --env staging --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"dry-run"* ]]
  [ "$(cat "$STATE")" = "$before" ]
  [ ! -d "$TEST_TEMP/reports" ]
}

@test "deploy-prep: 実生成し、フラグが実ファイルの存在と一致する" {
  run bash "$SCRIPT" --env staging
  [ "$status" -eq 0 ]

  # 実体
  [ -s "$RUNBOOK" ]

  # フラグ (実体に基づく)
  [ "$(jq -r '.deploy.ready' "$STATE")" = "true" ]
  [ "$(jq -r '.deploy.environment' "$STATE")" = "staging" ]
  [ "$(jq -r '.deploy.runbook_generated' "$STATE")" = "true" ]
  [ "$(jq -r '.deploy.runbook_path' "$STATE")" = "reports/deploy-runbook.md" ]

  # runbook_path が指す先に実ファイルがある
  [ -s "$TEST_TEMP/$(jq -r '.deploy.runbook_path' "$STATE")" ]
}

@test "deploy-prep: 生成物に commit SHA と tree_sha256 が入る" {
  run bash "$SCRIPT" --env production
  [ "$status" -eq 0 ]

  grep -qF "$HEAD_SHA" "$RUNBOOK"
  grep -qF "$TREE" "$RUNBOOK"
  # production の実体 (unit / port) が埋まっている
  grep -qF "claudeos-web-startup.service" "$RUNBOOK"
  grep -qF "127.0.0.1:3740/api/health" "$RUNBOOK"
}

@test "deploy-prep: 生成物に placeholder が無い (example.com / コメントアウト deploy / {KEY})" {
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]

  ! grep -q "example.com" "$RUNBOOK"
  ! grep -qE '\{[A-Z_][A-Z0-9_]*\}' "$RUNBOOK"
  ! grep -qE '^[[:space:]]*#[[:space:]]*(npm run deploy|docker-compose[^#]*deploy)' "$RUNBOOK"
  # 実コマンドが記載されている
  grep -qF "bin/release-build.sh" "$RUNBOOK"
  grep -qF "bin/release-promote.sh --env staging" "$RUNBOOK"
  grep -qF "bin/release-promote.sh --env production" "$RUNBOOK"
  grep -qF "scripts/release/post-deploy-smoke.sh" "$RUNBOOK"
}

@test "deploy-prep: 生成失敗時は exit 1 で runbook_generated=false に戻す" {
  # node を失敗するスタブに差し替える (実際の生成を失敗させる)
  make_stub_bin node 'exit 1'

  run bash "$SCRIPT" --env staging
  [ "$status" -eq 1 ]
  [[ "$output" == *"生成できませんでした"* ]]
  [ "$(jq -r '.deploy.runbook_generated' "$STATE")" = "false" ]
  [ "$(jq -r '.deploy.runbook_path' "$STATE")" = "null" ]
  [ ! -f "$RUNBOOK" ]
}

@test "deploy-prep: --checklist-done 指定時のみ pre_deploy_checklist_done=true" {
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.deploy.pre_deploy_checklist_done' "$STATE")" = "false" ]

  run bash "$SCRIPT" --checklist-done
  [ "$status" -eq 0 ]
  [ "$(jq -r '.deploy.pre_deploy_checklist_done' "$STATE")" = "true" ]
}

@test "deploy-prep: 不正な env / 不明な引数は exit 1" {
  run bash "$SCRIPT" --env prod
  [ "$status" -eq 1 ]

  run bash "$SCRIPT" --frobnicate
  [ "$status" -eq 1 ]
}

@test "deploy-prep: --project はプロジェクト側の state と reports を更新する" {
  export AI_STARTUP_CONFIG_PATH="$TEST_TEMP/config.json"
  printf '{ "projects": "%s/projects" }\n' "$TEST_TEMP" > "$AI_STARTUP_CONFIG_PATH"
  mkdir -p "$TEST_TEMP/projects/demo"
  jq -n '{deploy:{ready:false,runbook_generated:false,runbook_path:null,
                  pre_deploy_checklist_done:false,environment:null,notes:""}}' \
    > "$TEST_TEMP/projects/demo/state.json"

  # CCSU_STATE_FILE 側は触らないことも確認する
  local repo_state_before; repo_state_before="$(cat "$STATE")"

  run bash "$SCRIPT" --project demo --env staging
  [ "$status" -eq 0 ]
  [ -s "$TEST_TEMP/projects/demo/reports/deploy-runbook.md" ]
  [ "$(jq -r '.deploy.runbook_generated' "$TEST_TEMP/projects/demo/state.json")" = "true" ]
  [ "$(jq -r '.deploy.runbook_path' "$TEST_TEMP/projects/demo/state.json")" = "reports/deploy-runbook.md" ]
  [ "$(cat "$STATE")" = "$repo_state_before" ]
}
