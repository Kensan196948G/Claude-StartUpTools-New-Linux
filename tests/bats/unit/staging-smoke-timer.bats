#!/usr/bin/env bats
# ============================================================
# staging-smoke-timer.bats — bin/staging-smoke-timer.sh のテスト
#
# 検証観点:
#   - --dry-run は unit 本文を表示するだけで、ファイルも systemctl 呼び出しも作らない
#   - --register が service/timer を生成し、daemon-reload → enable --now <timer> を呼ぶ
#   - unit 本文が Staging 専用（staging-smoke.sh を実行、本番 unit 名・本番ポートを含まない、
#     CLAUDEOS_HOME を渡さない = 一時ディレクトリ前提）
#   - OnCalendar の既定/指定、--interval（24h/1d のみ）、--interval と --on-calendar の排他
#   - 改行注入の拒否 / 不明引数・アクション未指定は exit 2 / systemctl 失敗は exit 1
#   - --unregister（disable --now + unit 削除）と --dry-run
#   - --status が list-timers / show を呼ぶ
#
# 隔離: systemctl / loginctl は PATH スタブ、unit 出力先は $TEST_TEMP。
#       実 systemd・実 ~/.config/systemd/user には触れない。
# ============================================================

load '../helpers/common-setup'

setup() {
  _bats_common_setup
  CALLS="$TEST_TEMP/systemctl.calls"
  : > "$CALLS"
  make_stub_bin systemctl "printf '%s\n' \"systemctl \$*\" >> '$CALLS'"
  make_stub_bin loginctl 'exit 0'
  export CCSU_SYSTEMCTL_BIN="$STUB_BIN/systemctl"
  export CCSU_SYSTEMD_UNIT_DIR="$TEST_TEMP/units"
  SCRIPT="$REPO_ROOT/bin/staging-smoke-timer.sh"
  SVC="$CCSU_SYSTEMD_UNIT_DIR/claudeos-staging-smoke.service"
  TMR="$CCSU_SYSTEMD_UNIT_DIR/claudeos-staging-smoke.timer"
}
teardown() { _bats_common_teardown; }

# =========================================================
# dry-run
# =========================================================
@test "dry-run: unit 本文を表示し、ファイルも systemctl 呼び出しも作らない" {
  run bash "$SCRIPT" --register --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"dry-run: systemd への書き込みは行いません"* ]]
  [[ "$output" == *"scripts/e2e/staging-smoke.sh --json"* ]]
  [[ "$output" == *"OnCalendar=*-*-* 05:30:00"* ]]
  [[ "$output" == *"Persistent=true"* ]]
  [ ! -e "$CCSU_SYSTEMD_UNIT_DIR" ]
  [ ! -s "$CALLS" ]
}

@test "dry-run: --on-calendar を指定しても何も書かない" {
  run bash "$SCRIPT" --register --dry-run --on-calendar '*-*-* 06:15:00'
  [ "$status" -eq 0 ]
  [[ "$output" == *"OnCalendar=*-*-* 06:15:00"* ]]
  [ ! -e "$CCSU_SYSTEMD_UNIT_DIR" ]
}

# =========================================================
# register
# =========================================================
@test "--register: service/timer を生成し daemon-reload → enable --now timer を呼ぶ" {
  run bash "$SCRIPT" --register
  [ "$status" -eq 0 ]
  [ -f "$SVC" ]
  [ -f "$TMR" ]
  grep -q 'daemon-reload' "$CALLS"
  grep -q 'enable --now claudeos-staging-smoke.timer' "$CALLS"
  [[ "$output" == *"登録しました"* ]]
}

@test "unit 本文: staging-smoke.sh を oneshot で実行し、既定 OnCalendar/Persistent を持つ" {
  run bash "$SCRIPT" --register
  [ "$status" -eq 0 ]
  grep -q '^Type=oneshot$' "$SVC"
  grep -qF 'ExecStart=' "$SVC"
  grep -qF '/scripts/e2e/staging-smoke.sh --json' "$SVC"
  grep -qF "WorkingDirectory=$REPO_ROOT" "$SVC"
  grep -qF 'OnCalendar=*-*-* 05:30:00' "$TMR"
  grep -q '^Persistent=true$' "$TMR"
  grep -q '^Unit=claudeos-staging-smoke.service$' "$TMR"
  grep -q '^WantedBy=timers.target$' "$TMR"
}

@test "unit 本文: 本番 unit 名・本番ポート・本番 CLAUDEOS_HOME を含まない (Staging 専用)" {
  run bash "$SCRIPT" --register
  [ "$status" -eq 0 ]
  local f tok
  for f in "$SVC" "$TMR"; do
    for tok in claudeos-web-startup 3740 3737 3741; do
      ! grep -q -- "$tok" "$f"
    done
    # スモークは一時 CLAUDEOS_HOME を作るので unit からは渡さない
    ! grep -q '^Environment=CLAUDEOS_HOME=' "$f"
  done
}

@test "--on-calendar: 式が timer に反映される" {
  run bash "$SCRIPT" --register --on-calendar '*-*-* 06:15:00'
  [ "$status" -eq 0 ]
  grep -qF 'OnCalendar=*-*-* 06:15:00' "$TMR"
}

@test "--interval: 24h / 1d は日次として受け付け、それ以外は exit 2" {
  run bash "$SCRIPT" --register --interval 24h
  [ "$status" -eq 0 ]
  grep -qF 'OnCalendar=*-*-* 05:30:00' "$TMR"

  run bash "$SCRIPT" --register --interval 1d
  [ "$status" -eq 0 ]

  run bash "$SCRIPT" --register --interval 12h
  [ "$status" -eq 2 ]
  [[ "$output" == *"--on-calendar"* ]]

  run bash "$SCRIPT" --register --interval abc
  [ "$status" -eq 2 ]
}

@test "--interval と --on-calendar の同時指定は exit 2 (順序に依らない)" {
  run bash "$SCRIPT" --register --interval 24h --on-calendar 'daily'
  [ "$status" -eq 2 ]
  [[ "$output" == *"同時に指定できません"* ]]

  run bash "$SCRIPT" --register --on-calendar 'daily' --interval 24h
  [ "$status" -eq 2 ]
  [[ "$output" == *"同時に指定できません"* ]]
}

@test "--on-calendar の改行注入は exit 2 で拒否し、何も書かない" {
  run bash "$SCRIPT" --register --on-calendar $'daily\nExecStart=/bin/false'
  [ "$status" -eq 2 ]
  [[ "$output" == *"改行"* ]]
  [ ! -e "$CCSU_SYSTEMD_UNIT_DIR" ]
}

@test "systemctl が失敗したら exit 1 (登録済みと偽らない)" {
  make_stub_bin systemctl 'echo "systemctl failed (stub)" >&2; exit 1'
  run bash "$SCRIPT" --register
  [ "$status" -eq 1 ]
}

# =========================================================
# unregister
# =========================================================
@test "--unregister: disable --now して unit を削除する" {
  run bash "$SCRIPT" --register
  [ -f "$SVC" ]
  [ -f "$TMR" ]
  : > "$CALLS"

  run bash "$SCRIPT" --unregister
  [ "$status" -eq 0 ]
  [ ! -f "$SVC" ]
  [ ! -f "$TMR" ]
  grep -q 'disable --now claudeos-staging-smoke.timer' "$CALLS"
  grep -q 'daemon-reload' "$CALLS"
}

@test "--unregister --dry-run: unit も systemd も変更しない" {
  run bash "$SCRIPT" --register
  : > "$CALLS"

  run bash "$SCRIPT" --unregister --dry-run
  [ "$status" -eq 0 ]
  [ -f "$SVC" ]
  [ -f "$TMR" ]
  [ ! -s "$CALLS" ]
}

# =========================================================
# status / 引数
# =========================================================
@test "--status: list-timers と systemctl show の結果を表示する" {
  run bash "$SCRIPT" --register
  : > "$CALLS"

  run bash "$SCRIPT" --status
  [ "$status" -eq 0 ]
  [[ "$output" == *"claudeos-staging-smoke.timer"* ]]
  grep -q 'list-timers' "$CALLS"
  grep -q 'show claudeos-staging-smoke.timer' "$CALLS"
  grep -q 'show claudeos-staging-smoke.service' "$CALLS"
}

@test "--status: 未登録でも exit 0 で「未登録」を表示する (読み取りのみ)" {
  run bash "$SCRIPT" --status
  [ "$status" -eq 0 ]
  [[ "$output" == *"未登録"* ]]
}

@test "不明な引数・アクション未指定は exit 2、--help は 0" {
  run bash "$SCRIPT" --bogus
  [ "$status" -eq 2 ]

  run bash "$SCRIPT"
  [ "$status" -eq 2 ]

  run bash "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--register"* ]]
}

@test "値を伴うオプションの欠落は exit 2" {
  run bash "$SCRIPT" --register --on-calendar
  [ "$status" -eq 2 ]

  run bash "$SCRIPT" --register --interval
  [ "$status" -eq 2 ]
}
