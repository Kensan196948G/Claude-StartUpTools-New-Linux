#!/usr/bin/env bats
# ============================================================
# web-startup-service.bats — bin/web-startup-service.sh のテスト
# systemctl を PATH スタブ化。unit はテスト用パスへ生成し、実 systemd を触らない。
# ============================================================

load '../helpers/common-setup'

setup() {
  _bats_common_setup
  make_stub_bin systemctl 'echo "systemctl $*"; exit 0'
  make_stub_bin loginctl 'exit 0'
  export CCSU_SYSTEMD_UNIT_PATH="$TEST_TEMP/units/claudeos-web-startup.service"
  SCRIPT="$REPO_ROOT/bin/web-startup-service.sh"
}
teardown() { _bats_common_teardown; }

@test "web-startup-service: --dry-run は unit 内容を表示しファイルを作らない" {
  run bash "$SCRIPT" --register --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"dry-run: systemd への書き込みは行いません"* ]]
  [[ "$output" == *"startup-server.js --port 3740 --host 127.0.0.1"* ]]
  [ ! -f "$CCSU_SYSTEMD_UNIT_PATH" ]
}

@test "web-startup-service: --register は loopback bind の unit を生成し enable --now する" {
  run bash "$SCRIPT" --register
  [ "$status" -eq 0 ]
  [ -f "$CCSU_SYSTEMD_UNIT_PATH" ]
  grep -q 'ExecStart=.*startup-server.js --port 3740 --host 127.0.0.1' "$CCSU_SYSTEMD_UNIT_PATH"
  grep -q 'EnvironmentFile=-' "$CCSU_SYSTEMD_UNIT_PATH"
  grep -q 'NoNewPrivileges=yes' "$CCSU_SYSTEMD_UNIT_PATH"
  # LAN へ bind する設定が混入していないこと (公開は Cloudflare Tunnel 側)
  ! grep -qE 'host (0\.0\.0\.0|192\.168)' "$CCSU_SYSTEMD_UNIT_PATH"
  [[ "$output" == *"enable --now"* ]]
  [[ "$output" == *"WEB_STARTUP_PUBLIC_ACCESS.md"* ]]
}

@test "web-startup-service: --port は unit に反映される" {
  run bash "$SCRIPT" --register --port 3901
  [ "$status" -eq 0 ]
  grep -q -- '--port 3901' "$CCSU_SYSTEMD_UNIT_PATH"
}

@test "web-startup-service: --unregister は unit を削除する" {
  run bash "$SCRIPT" --register
  [ -f "$CCSU_SYSTEMD_UNIT_PATH" ]
  run bash "$SCRIPT" --unregister
  [ "$status" -eq 0 ]
  [ ! -f "$CCSU_SYSTEMD_UNIT_PATH" ]
}

@test "web-startup-service: 不正な port はエラー" {
  run bash "$SCRIPT" --register --port abc
  [ "$status" -ne 0 ]
  [[ "$output" == *"port は数値"* ]]
}

@test "web-startup-service: 不明な引数 / 引数なしはエラー" {
  run bash "$SCRIPT" --frobnicate
  [ "$status" -ne 0 ]
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
}
