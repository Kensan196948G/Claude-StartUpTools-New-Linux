#!/usr/bin/env bats
# ============================================================
# dashboard-service-staging.bats — bin/dashboard-service.sh の staging プロファイル
#
# Staging dashboard を本番と分離して起動するための引数化
# (--unit / --root / --port / --host / --claudeos-home / --profile staging) を検証する。
# 実 systemd / crontab は触らない（systemctl はスタブ、書き込みは一時パス）。
# ============================================================

load '../helpers/common-setup'

setup() {
  _bats_common_setup
  make_stub_bin systemctl 'echo "systemctl $*"; exit 0'
  make_stub_bin loginctl 'exit 0'
  make_stub_bin crontab 'exit 0'
  export CCSU_SYSTEMD_UNIT_PATH="$TEST_TEMP/units/unit.service"
  export CCSU_SYSTEMCTL_BIN="$STUB_BIN/systemctl"
  export CCSU_CRONTAB_BIN="$STUB_BIN/crontab"
  SCRIPT="$REPO_ROOT/bin/dashboard-service.sh"
}
teardown() { _bats_common_teardown; }

@test "dashboard-service: 既定の dry-run は従来どおり (HOST/CLAUDEOS_HOME 行を足さない)" {
  run bash "$SCRIPT" --register --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"serve-dashboard.js 3737"* ]]
  [[ "$output" != *"HOST="* ]]
  [[ "$output" != *"CLAUDEOS_HOME="* ]]
  [ ! -e "$CCSU_SYSTEMD_UNIT_PATH" ]
}

@test "dashboard-service: --profile staging は stg unit / 3743 / loopback / stg HOME を出す" {
  run bash "$SCRIPT" --register --profile staging --root /srv/rel --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"serve-dashboard.js 3743"* ]]
  [[ "$output" == *"HOST=127.0.0.1"* ]]
  [[ "$output" == *"CLAUDEOS_HOME=$HOME/.claudeos-stg"* ]]
}

@test "dashboard-service: --register で staging unit を生成し本番 unit を書かない" {
  run bash "$SCRIPT" --register --profile staging --root /srv/rel
  [ "$status" -eq 0 ]
  [ -f "$CCSU_SYSTEMD_UNIT_PATH" ]
  grep -q 'WorkingDirectory=/srv/rel' "$CCSU_SYSTEMD_UNIT_PATH"
  grep -q 'Environment=HOST=127.0.0.1' "$CCSU_SYSTEMD_UNIT_PATH"
  grep -q 'Environment=CLAUDEOS_HOME=' "$CCSU_SYSTEMD_UNIT_PATH"
  grep -q 'serve-dashboard.js 3743' "$CCSU_SYSTEMD_UNIT_PATH"
  # 本番 unit 名のファイルは作られない
  [ ! -e "$HOME/.config/systemd/user/claudeos-dashboard.service" ]
}

@test "dashboard-service: staging で本番 unit 名を明示すると拒否される" {
  run bash "$SCRIPT" --register --profile staging --unit claudeos-dashboard.service
  [ "$status" -eq 2 ]
  [[ "$output" == *"本番 unit"* ]]
  [ ! -e "$CCSU_SYSTEMD_UNIT_PATH" ]
}

@test "dashboard-service: staging で loopback 以外の HOST は拒否される" {
  run bash "$SCRIPT" --register --profile staging --host 0.0.0.0
  [ "$status" -eq 2 ]
  [[ "$output" == *"127.0.0.1 固定"* ]]
}

@test "dashboard-service: 不正な unit 名は exit 2" {
  run bash "$SCRIPT" --register --unit 'bad/name'
  [ "$status" -eq 2 ]
  [[ "$output" == *"unit 名"* ]]
}

@test "dashboard-service: --port / --root / --unit の明示指定が優先される" {
  run bash "$SCRIPT" --register --profile staging --unit my-dash.service --port 3799 --root /srv/other --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"serve-dashboard.js 3799"* ]]
  [[ "$output" == *"/srv/other/scripts/dashboards/serve-dashboard.js"* ]]
}
