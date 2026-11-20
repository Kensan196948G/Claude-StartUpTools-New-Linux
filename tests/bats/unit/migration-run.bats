#!/usr/bin/env bats
# ============================================================
# migration-run.bats — 大規模改修の分割実行 (worktree 分離 + run 分割)
# 「作業ツリーが混ざらない」「検証を通っていない group を ok で閉じさせない」
# 「main へ自動 merge しない」を固定する。
# ============================================================

load '../helpers/common-setup'

setup() {
  _bats_common_setup
  export CLAUDEOS_HOME="$TEST_TEMP/claudeos"
  export CCSU_MIGRATION_REPO="$TEST_TEMP/repo"
  export CCSU_MIGRATION_HOME="$TEST_TEMP/migrations"
  SCRIPT="$REPO_ROOT/bin/migration-run.sh"

  mkdir -p "$CCSU_MIGRATION_REPO/src/api" "$CCSU_MIGRATION_REPO/src/web"
  git -C "$CCSU_MIGRATION_REPO" init -q -b main .
  git -C "$CCSU_MIGRATION_REPO" config user.email t@example.com
  git -C "$CCSU_MIGRATION_REPO" config user.name tester
  echo api > "$CCSU_MIGRATION_REPO/src/api/a.txt"
  echo web > "$CCSU_MIGRATION_REPO/src/web/w.txt"
  git -C "$CCSU_MIGRATION_REPO" add -A
  git -C "$CCSU_MIGRATION_REPO" commit -qm "init"

  PLAN="$TEST_TEMP/plan.json"
  cat > "$PLAN" <<'JSON'
{ "schema": "claudeos.migration-plan/v1", "title": "分割例", "base": "main",
  "groups": [ { "id": "api", "paths": ["src/api"], "command": "test -f src/api/a.txt && echo api-ok" },
              { "id": "web", "paths": ["src/web"], "command": "echo web-ok" } ] }
JSON
}

teardown() {
  # worktree を残すと後続テストの git 操作が乱れるため撤去する
  if [[ -d "$CCSU_MIGRATION_REPO/.git" ]]; then
    git -C "$CCSU_MIGRATION_REPO" worktree prune >/dev/null 2>&1 || true
  fi
  _bats_common_teardown
}

@test "migration: plan は schema と必須項目を検証する" {
  run bash "$SCRIPT" plan --file "$PLAN" --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.group_count')" -eq 2 ]
  [[ "$(printf '%s' "$output" | jq -r '.plan_id')" == mig-* ]]

  jq '.schema = "wrong"' "$PLAN" > "$TEST_TEMP/bad-schema.json"
  run bash "$SCRIPT" plan --file "$TEST_TEMP/bad-schema.json"
  [ "$status" -eq 2 ]
  jq 'del(.groups[0].command)' "$PLAN" > "$TEST_TEMP/no-cmd.json"
  run bash "$SCRIPT" plan --file "$TEST_TEMP/no-cmd.json"
  [ "$status" -eq 2 ]
  jq '.groups[0].id = "bad id!"' "$PLAN" > "$TEST_TEMP/bad-id.json"
  run bash "$SCRIPT" plan --file "$TEST_TEMP/bad-id.json"
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" plan --file "$TEST_TEMP/does-not-exist.json"
  [ "$status" -eq 2 ]
}

@test "migration: start は group ごとに worktree と branch と run を作る" {
  # 進捗ログは stderr に出るため、標準出力 (JSON) だけを取り出す
  output="$(bash "$SCRIPT" start --plan "$PLAN" --json 2>/dev/null)"
  status=$?
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.groups.api.status')" = "running" ]
  [[ "$(printf '%s' "$output" | jq -r '.groups.api.branch')" == migration/*/api ]]
  # [[ ]] でないと右辺がパターンとして扱われない ([ ] は文字列一致のみ)
  [[ "$(printf '%s' "$output" | jq -r '.groups.api.run_id')" == run-* ]]
  # 実体としての worktree が存在し、別々のディレクトリである
  api_wt="$(printf '%s' "$output" | jq -r '.groups.api.worktree')"
  web_wt="$(printf '%s' "$output" | jq -r '.groups.web.worktree')"
  [ -d "$api_wt" ]
  [ -d "$web_wt" ]
  [ "$api_wt" != "$web_wt" ]
  git -C "$CCSU_MIGRATION_REPO" worktree list | grep -q "$api_wt"
  git -C "$CCSU_MIGRATION_REPO" branch --list 'migration/*' | grep -q api
}

@test "migration: 検証コマンドは worktree 内で実行され、結果と fingerprint を残す" {
  bash "$SCRIPT" start --plan "$PLAN" --json >/dev/null 2>&1
  run bash "$SCRIPT" verify --id api --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.status')" = "passed" ]
  [ "$(printf '%s' "$output" | jq -r '.exit_code')" -eq 0 ]
  [[ "$(printf '%s' "$output" | jq -r '.fingerprint')" =~ ^[0-9a-f]{16}$ ]]
  grep -q api-ok "$(printf '%s' "$output" | jq -r '.log')"
}

@test "migration: 失敗した検証は passed にならず finish ok を拒否する" {
  jq '.groups[0].command = "exit 7"' "$PLAN" > "$TEST_TEMP/fail.json"
  bash "$SCRIPT" start --plan "$TEST_TEMP/fail.json" --json >/dev/null 2>&1
  run bash "$SCRIPT" verify --id api --json
  [ "$status" -ne 0 ]
  [ "$(printf '%s' "$output" | jq -r '.status')" = "failed" ]
  [ "$(printf '%s' "$output" | jq -r '.exit_code')" -eq 7 ]
  # 検証が failures を残すので、run-ledger の失敗記録にも載る
  run bash "$REPO_ROOT/bin/run-ledger.sh" failures --json
  [ "$status" -eq 0 ]
  run bash "$SCRIPT" finish --id api --status ok
  [ "$status" -eq 3 ]
}

@test "migration: 検証前の group は ok で閉じられない (rc=3)" {
  bash "$SCRIPT" start --plan "$PLAN" --json >/dev/null 2>&1
  run bash "$SCRIPT" finish --id api --status ok
  [ "$status" -eq 3 ]
  [[ "$output" == *検証* ]]
  # failed なら閉じられる (失敗を失敗として記録するのは正しい)
  run bash "$SCRIPT" finish --id api --status failed --note "手動中断"
  [ "$status" -eq 0 ]
}

@test "migration: report は統合を人間ゲートとして提示する (自動 merge しない)" {
  bash "$SCRIPT" start --plan "$PLAN" --json >/dev/null 2>&1
  bash "$SCRIPT" verify --id api >/dev/null
  bash "$SCRIPT" finish --id api --status ok >/dev/null
  run bash "$SCRIPT" report --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.integration.mode')" = "human_gated" ]
  [ "$(printf '%s' "$output" | jq -r '.counts.ok')" -eq 1 ]
  [[ "$(printf '%s' "$output" | jq -r '.integration.next[0]')" == "git push -u origin migration/"* ]]
  [[ "$(printf '%s' "$output" | jq -r '.integration.note')" == *Squash\ Merge* ]]
}

@test "migration: status/clean は worktree を撤去するが branch は残す" {
  bash "$SCRIPT" start --plan "$PLAN" --json >/dev/null 2>&1
  run bash "$SCRIPT" status --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.groups | length')" -eq 2 ]
  wt="$(printf '%s' "$output" | jq -r '.groups.api.worktree')"
  run bash "$SCRIPT" clean --id api
  [ "$status" -eq 0 ]
  [ ! -d "$wt" ]
  git -C "$CCSU_MIGRATION_REPO" branch --list 'migration/*' | grep -q api
}

@test "migration: 同じプランの二重 start は既存 run を再利用する" {
  bash "$SCRIPT" start --plan "$PLAN" --json >/dev/null 2>&1
  first="$(bash "$SCRIPT" status --json | jq -r '.groups.api.run_id')"
  output="$(bash "$SCRIPT" start --plan "$PLAN" --json 2>/dev/null)"
  status=$?
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.groups.api.run_id')" = "$first" ]
}
