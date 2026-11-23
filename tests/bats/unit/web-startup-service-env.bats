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

# ------------------------------------------------------------
# --state-file (Environment=CCSU_STATE_FILE)
#   成果物起動では子プロセスの CCSU_ROOT が成果物を指すため、state.json の
#   置き場を unit で明示する。既定では何も増やさない (バイト一致)。
# ------------------------------------------------------------

@test "state-file: --state-file で Environment=CCSU_STATE_FILE が 1 行だけ入る" {
  run bash "$SCRIPT" --register --unit test-state.service \
    --state-file /repo/state.json --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"state-file=/repo/state.json"* ]]
  [[ "$output" == *"Environment=CCSU_STATE_FILE=/repo/state.json"* ]]
  local n
  n="$(printf '%s\n' "$output" | grep -c 'CCSU_STATE_FILE=' || true)"
  [ "$n" -eq 1 ]
  [ ! -e "$CCSU_SYSTEMD_UNIT_PATH" ]
}

@test "state-file: 既定の unit 本文は従来と同一（差分は CCSU_STATE_FILE の 1 行のみ）" {
  bash "$SCRIPT" --register --unit a-default.service --dry-run \
    | sed -n 's/^    //p' > "$TEST_TEMP/default.unit"
  bash "$SCRIPT" --register --unit a-state.service --state-file /repo/state.json --dry-run \
    | sed -n 's/^    //p' > "$TEST_TEMP/state.unit"
  # 既定には CCSU_STATE_FILE が現れない
  ! grep -q 'CCSU_STATE_FILE' "$TEST_TEMP/default.unit"
  # 追加されるのは Environment=CCSU_STATE_FILE の 1 行だけ
  run diff -u "$TEST_TEMP/default.unit" "$TEST_TEMP/state.unit"
  [ "$status" -ne 0 ]
  [ "$(printf '%s\n' "$output" | grep -c '^+Environment=CCSU_STATE_FILE=/repo/state.json$')" -eq 1 ]
  [ "$(printf '%s\n' "$output" | grep -c '^+[^+]' || true)" -eq 1 ]
}

@test "state-file: 値に改行があると unit への行注入として exit 2 で拒否する" {
  run bash "$SCRIPT" --register --unit test-inject-state.service \
    --state-file "A=/x
Environment=EVIL=1" --dry-run
  [ "$status" -eq 2 ]
  [[ "$output" == *"--state-file"* ]]
  [ ! -e "$CCSU_SYSTEMD_UNIT_PATH" ]
}

@test "state-file: 成果物 root (リポジトリ外) で未指定なら警告し、指定すれば警告しない" {
  local artifact="$TEST_TEMP/releases/production-current"
  mkdir -p "$artifact"

  run bash "$SCRIPT" --register --profile production --root "$artifact" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARN"* ]]
  [[ "$output" == *"--state-file"* ]]
  [[ "$output" == *"成果物"* ]]

  run bash "$SCRIPT" --register --profile production --root "$artifact" \
    --state-file "$TEST_TEMP/repo-state.json" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" != *"WARN"* ]]
  [[ "$output" == *"Environment=CCSU_STATE_FILE=$TEST_TEMP/repo-state.json"* ]]
}

@test "state-file: --root がリポジトリ自身なら --profile production でも警告しない" {
  run bash "$SCRIPT" --register --profile production --root "$REPO_ROOT" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" != *"WARN"* ]]
  [[ "$output" != *"CCSU_STATE_FILE"* ]]
}
