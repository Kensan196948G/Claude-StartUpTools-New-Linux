#!/usr/bin/env bats
# ============================================================
# supervisor-manifest.bats — lib/supervisor-manifest.sh のユニットテスト
# 分類 (Managed/Missing/Foreign/Invalid) と diff/apply を検証。
# ============================================================

load '../helpers/common-setup'

setup() {
  _bats_common_setup
  export AI_STARTUP_CONFIG_PATH="$TEST_TEMP/config.json"
  export PROJ="$TEST_TEMP/projects"
  mkdir -p "$PROJ/Alpha/.git" "$PROJ/Beta/.git" "$PROJ/Gamma/.git" "$PROJ/Delta/.git"
  printf '{ "projects": "%s" }\n' "$PROJ" > "$AI_STARTUP_CONFIG_PATH"
  source "$REPO_ROOT/lib/supervisor-manifest.sh"
}
teardown() { _bats_common_teardown; }

_write_manifest() {
  local dir="$1" content="$2"
  mkdir -p "$dir/.claude/claudeos"
  printf '%s\n' "$content" > "$dir/.claude/claudeos/supervisor-manifest.json"
}

@test "supman__classify: manifest 不在は Missing" {
  run supman__classify "$PROJ/Beta"
  [ "$output" = "Missing" ]
}

@test "supman__classify: 壊れた JSON は Invalid" {
  _write_manifest "$PROJ/Delta" '{ not json'
  run supman__classify "$PROJ/Delta"
  [ "$output" = "Invalid" ]
}

@test "supman__classify: 他ツール管理は Foreign" {
  _write_manifest "$PROJ/Gamma" '{"managedBy":"SomeOtherTool","sshEnabled":true}'
  run supman__classify "$PROJ/Gamma"
  [ "$output" = "Foreign" ]
}

@test "supman__classify: sshEnabled=true は managedBy 一致でも Foreign (SSH 禁止監査)" {
  _write_manifest "$PROJ/Gamma" '{"managedBy":"Claude-StartUpTools-New-Linux","sshEnabled":true}'
  run supman__classify "$PROJ/Gamma"
  [ "$output" = "Foreign" ]
}

@test "supman__apply → supman__classify: 適用後は Managed" {
  supman__apply "$PROJ/Alpha" >/dev/null
  run supman__classify "$PROJ/Alpha"
  [ "$output" = "Managed" ]
}

@test "supman__apply: manifest に必須ポリシーキーが揃う" {
  supman__apply "$PROJ/Alpha" >/dev/null
  local m="$PROJ/Alpha/.claude/claudeos/supervisor-manifest.json"
  [ "$(jq -r '.managedBy' "$m")" = "Claude-StartUpTools-New-Linux" ]
  [ "$(jq -r '.sshEnabled' "$m")" = "false" ]
  [ "$(jq -r '.project' "$m")" = "Alpha" ]
  [ "$(jq -r '.supervisorAppliedAt' "$m")" != "null" ]
}

@test "supman__diff: Missing は action=Create" {
  run supman__diff "$PROJ/Beta"
  [ "${lines[0]}" = "action=Create" ]
}

@test "supman__diff: Invalid は action=ReplaceInvalid" {
  _write_manifest "$PROJ/Delta" '{ broken'
  run supman__diff "$PROJ/Delta"
  [ "${lines[0]}" = "action=ReplaceInvalid" ]
}

@test "supman__diff: 適用直後の再 diff は RefreshTimestamp (appliedAt は比較対象外)" {
  supman__apply "$PROJ/Alpha" >/dev/null
  run supman__diff "$PROJ/Alpha"
  [ "${lines[0]}" = "action=RefreshTimestamp" ]
}

@test "supman__diff: Foreign は action=Update + 変更キー行 (複数行でも SIGPIPE しない)" {
  _write_manifest "$PROJ/Gamma" '{"managedBy":"SomeOtherTool","sshEnabled":true}'
  run supman__diff "$PROJ/Gamma"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "action=Update" ]
  [[ "$output" == *"managedBy|SomeOtherTool|Claude-StartUpTools-New-Linux|Changed"* ]]
  [[ "$output" == *"sshEnabled|true|false|Changed"* ]]
}

@test "supman__apply: Foreign は既定で保護 (未変更)" {
  _write_manifest "$PROJ/Gamma" '{"managedBy":"SomeOtherTool","sshEnabled":true}'
  supman__apply "$PROJ/Gamma" >/dev/null 2>&1
  run supman__classify "$PROJ/Gamma"
  [ "$output" = "Foreign" ]
}

@test "supman__apply: CCSU_SUPMAN_FORCE=1 で Foreign を上書きし Managed 化" {
  _write_manifest "$PROJ/Gamma" '{"managedBy":"SomeOtherTool","sshEnabled":true}'
  CCSU_SUPMAN_FORCE=1 supman__apply "$PROJ/Gamma" >/dev/null 2>&1
  run supman__classify "$PROJ/Gamma"
  [ "$output" = "Managed" ]
}

@test "supman__apply --preview: 書き込まず Missing のまま" {
  supman__apply "$PROJ/Beta" --preview >/dev/null
  run supman__classify "$PROJ/Beta"
  [ "$output" = "Missing" ]
}

@test "supman__report: 集計行に total と各分類数が出る" {
  supman__apply "$PROJ/Alpha" >/dev/null
  _write_manifest "$PROJ/Gamma" '{"managedBy":"Other"}'
  _write_manifest "$PROJ/Delta" '{ broken'
  run supman__report
  [[ "$output" == *"total=4"* ]]
  [[ "$output" == *"Managed=1"* ]]
  [[ "$output" == *"Foreign=1"* ]]
  [[ "$output" == *"Invalid=1"* ]]
}

@test "supman__human_decision_json: config 上書きを尊重" {
  printf '{ "projects": "%s", "supervisor": { "humanDecisionRequired": ["only-this"] } }\n' "$PROJ" > "$AI_STARTUP_CONFIG_PATH"
  CCSU_CONFIG_PATH="$AI_STARTUP_CONFIG_PATH"
  run supman__human_decision_json
  [[ "$output" == *"only-this"* ]]
}