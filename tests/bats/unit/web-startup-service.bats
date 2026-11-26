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

# sandbox_home — 新しいテスト用の HOME。unit の既定パスを $HOME 配下で検査するため。
# CCSU_SYSTEMD_UNIT_PATH は外して「~/.config/systemd/user/<unit>」の解決を検証する。
sandbox_home() {
  unset CCSU_SYSTEMD_UNIT_PATH
  export HOME="$TEST_TEMP/home"
  mkdir -p "$HOME"
}

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

# ------------------------------------------------------------
# 複数インスタンス対応 (--unit / --root / --env-file / --claudeos-home / --profile staging)
# ------------------------------------------------------------

@test "web-startup-service: --profile staging は stg unit / 3742 / stg env-file / stg CLAUDEOS_HOME を出す" {
  sandbox_home
  run bash "$SCRIPT" --register --dry-run --profile staging
  [ "$status" -eq 0 ]
  [[ "$output" == *"unit=$HOME/.config/systemd/user/claudeos-web-startup-stg.service"* ]]
  [[ "$output" == *"--port 3742 --host 127.0.0.1"* ]]
  [[ "$output" == *"claudeos-web-startup-stg.env"* ]]
  [[ "$output" == *"Environment=CLAUDEOS_HOME=$HOME/.claudeos-stg"* ]]
  # 本番の port / unit が混入していないこと
  [[ "$output" != *"--port 3740"* ]]
  [[ "$output" != *"systemd/user/claudeos-web-startup.service"* ]]
}

@test "web-startup-service: --profile staging --register は本番 unit を書かず stg unit だけ作る" {
  sandbox_home
  run bash "$SCRIPT" --register --profile staging
  [ "$status" -eq 0 ]
  local stg="$HOME/.config/systemd/user/claudeos-web-startup-stg.service"
  local prod="$HOME/.config/systemd/user/claudeos-web-startup.service"
  [ -f "$stg" ]
  [ ! -e "$prod" ]
  grep -q -- '--port 3742 --host 127.0.0.1' "$stg"
  grep -q "Environment=CLAUDEOS_HOME=$HOME/.claudeos-stg" "$stg"
  ! grep -q '3740' "$stg"
  [[ "$output" == *"enable --now claudeos-web-startup-stg.service"* ]]
}

@test "web-startup-service: --unit で任意の unit 名を登録でき --status も同じ unit を使う" {
  sandbox_home
  run bash "$SCRIPT" --register --unit claudeos-web-startup-dev.service --port 3801
  [ "$status" -eq 0 ]
  local unit="$HOME/.config/systemd/user/claudeos-web-startup-dev.service"
  [ -f "$unit" ]
  grep -q -- '--port 3801 --host 127.0.0.1' "$unit"
  [[ "$output" == *"enable --now claudeos-web-startup-dev.service"* ]]

  run bash "$SCRIPT" --status --unit claudeos-web-startup-dev.service
  [ "$status" -eq 0 ]
  [[ "$output" == *"systemctl --user status claudeos-web-startup-dev.service"* ]]
}

@test "web-startup-service: 不正な unit 名 (/ や空白) は exit 2 で拒否する" {
  sandbox_home
  run bash "$SCRIPT" --register --unit 'bad/name.service'
  [ "$status" -eq 2 ]
  [[ "$output" == *"unit 名"* ]]

  run bash "$SCRIPT" --register --unit 'bad name.service'
  [ "$status" -eq 2 ]
  [[ "$output" == *"unit 名"* ]]

  # 検証で落ちるので unit ディレクトリ自体が作られない
  [ ! -d "$HOME/.config/systemd/user" ]
}

@test "web-startup-service: Environment=CLAUDEOS_HOME は --claudeos-home 指定時のみ入る" {
  sandbox_home
  run bash "$SCRIPT" --register --unit claudeos-no-home.service
  [ "$status" -eq 0 ]
  local no_home="$HOME/.config/systemd/user/claudeos-no-home.service"
  grep -q 'EnvironmentFile=-' "$no_home"
  ! grep -q 'Environment=CLAUDEOS_HOME=' "$no_home"

  run bash "$SCRIPT" --register --unit claudeos-with-home.service --claudeos-home "$TEST_TEMP/alt-home"
  [ "$status" -eq 0 ]
  local with_home="$HOME/.config/systemd/user/claudeos-with-home.service"
  grep -q "Environment=CLAUDEOS_HOME=$TEST_TEMP/alt-home" "$with_home"
}

@test "web-startup-service: 既定実行の unit 内容が従来と同一 (回帰)" {
  sandbox_home
  run bash "$SCRIPT" --register
  [ "$status" -eq 0 ]
  local unit="$HOME/.config/systemd/user/claudeos-web-startup.service"
  [ -f "$unit" ]

  cat > "$TEST_TEMP/expected.unit" <<EOF
[Unit]
Description=ClaudeOS Web Startup Console (bin/menu.sh の Web 版)
Documentation=file:$REPO_ROOT/docs/architecture/WEB_STARTUP_TOOL.md
After=network.target

[Service]
Type=simple
WorkingDirectory=$REPO_ROOT
# STARTUP_WEB_PASSWORD / STARTUP_WEB_USER を置く場合のみ (0600)。'-' = 無くても起動する
# (loopback bind + Cloudflare Access が入口制御の主体。Basic は多層防御)
EnvironmentFile=-$HOME/.config/claudeos-web-startup.env
ExecStart=<NODE> $REPO_ROOT/scripts/web/startup-server.js --port 3740 --host 127.0.0.1
Restart=on-failure
RestartSec=3
# 実行に必要な範囲だけ許可する (Claude 起動のため bash/claude/tmux/git を呼ぶので
# ProtectHome / ProtectSystem は付けない。付けるとプロジェクトと ~/.claudeos を読めない)
NoNewPrivileges=yes
PrivateTmp=yes

[Install]
WantedBy=default.target
EOF
  # node の絶対パスだけは環境依存なので <NODE> に正規化して比較する
  sed -E 's|^ExecStart=[^ ]+ |ExecStart=<NODE> |' "$unit" > "$TEST_TEMP/actual.unit"
  diff -u "$TEST_TEMP/expected.unit" "$TEST_TEMP/actual.unit"
}

@test "web-startup-service: --profile staging は本番 unit 名の明示指定も拒否する" {
  sandbox_home
  run bash "$SCRIPT" --register --profile staging --unit claudeos-web-startup.service
  [ "$status" -eq 2 ]
  [[ "$output" == *"本番 unit"* ]]
  [ ! -e "$HOME/.config/systemd/user/claudeos-web-startup.service" ]

  # --profile production は既定と同意 (本番 unit / 3740 のまま)
  run bash "$SCRIPT" --register --dry-run --profile production
  [ "$status" -eq 0 ]
  [[ "$output" == *"unit=$HOME/.config/systemd/user/claudeos-web-startup.service"* ]]
  [[ "$output" == *"--port 3740 --host 127.0.0.1"* ]]
}

@test "web-startup-service: --lan / --host は拒否される (bind は loopback 固定)" {
  sandbox_home
  run bash "$SCRIPT" --register --lan
  [ "$status" -eq 2 ]
  [[ "$output" == *"127.0.0.1 固定"* ]]

  run bash "$SCRIPT" --register --host 0.0.0.0
  [ "$status" -eq 2 ]
  [[ "$output" == *"127.0.0.1 固定"* ]]
  [ ! -d "$HOME/.config/systemd/user" ]
}
