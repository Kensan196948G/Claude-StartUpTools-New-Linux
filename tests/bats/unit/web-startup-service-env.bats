#!/usr/bin/env bats
# ============================================================
# web-startup-service-env.bats — 複数 EnvironmentFile と --env のテスト
#
# 本番 unit は「既存の secret 入り env-file」を保ったまま、追加の環境変数
# （例: AI_STARTUP_CONFIG_PATH）を unit に持たせたい。そのための
#   --env-file の複数指定 / --env KEY=VALUE
# を検証する。実 systemd は触らない（systemctl はスタブ）。
# ============================================================

load '../helpers/common-setup'

setup() {
  _bats_common_setup
  make_stub_bin systemctl 'echo "systemctl $*"; exit 0'
  make_stub_bin loginctl 'exit 0'
  export CCSU_SYSTEMD_UNIT_PATH="$TEST_TEMP/units/unit.service"
  SCRIPT="$REPO_ROOT/bin/web-startup-service.sh"
  A_ENV="$TEST_TEMP/a.env"
  B_ENV="$TEST_TEMP/b.env"
}
teardown() { _bats_common_teardown; }

@test "env: --env-file を複数指定すると unit に複数の EnvironmentFile が出る" {
  run bash "$SCRIPT" --register --unit test-multi.service \
    --env-file "$A_ENV" --env-file "$B_ENV" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"EnvironmentFile=-$A_ENV"* ]]
  [[ "$output" == *"EnvironmentFile=-$B_ENV"* ]]
  [[ "$output" == *"env-file=$A_ENV,$B_ENV"* ]]
  [ ! -e "$CCSU_SYSTEMD_UNIT_PATH" ]
}

@test "env: --env KEY=VALUE は Environment= 行になり、KEY の無い値は exit 2" {
  run bash "$SCRIPT" --register --unit test-kv.service \
    --env AI_STARTUP_CONFIG_PATH=/tmp/config.json --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Environment=AI_STARTUP_CONFIG_PATH=/tmp/config.json"* ]]
  [[ "$output" == *"env=AI_STARTUP_CONFIG_PATH=/tmp/config.json"* ]]

  run bash "$SCRIPT" --register --unit test-kv.service --env NOEQUALS --dry-run
  [ "$status" -eq 2 ]
  [[ "$output" == *"KEY=VALUE"* ]]
}

@test "env: 既定（単一 env-file・--env なし）の本文は従来どおりで Environment= が増えない" {
  run bash "$SCRIPT" --register --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"EnvironmentFile=-"* ]]
  local count
  count="$(printf '%s\n' "$output" | grep -c '^ *Environment=' || true)"
  [ "$count" -eq 0 ]
}

@test "env: --env の値に改行があると unit への行注入として拒否される" {
  run bash "$SCRIPT" --register --unit test-inject.service --env "A=b
Environment=EVIL=1" --dry-run
  [ "$status" -ne 0 ]
}
