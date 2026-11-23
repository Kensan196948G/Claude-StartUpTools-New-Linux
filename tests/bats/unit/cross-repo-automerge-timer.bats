#!/usr/bin/env bats
# ============================================================
# cross-repo-automerge-timer.bats — bin/cross-repo-automerge-timer.sh のテスト
#
# 検証観点:
#   - --dry-run は unit を書かない（本文の表示のみ）
#   - --register で service/timer を生成し daemon-reload → enable --now を呼ぶ
#   - service の ExecStart が巡回ツールの --apply --json である
#   - timer が既定で毎時 15 分・Persistent=true
#   - 本番の web サービス名・ポートを unit 本文に含まない（自己検査）
#   - --on-calendar の差し替えと検証、--unregister、不正引数
#
# 隔離: systemctl / loginctl は PATH スタブ。実 systemd に触れない。
# ============================================================

load '../helpers/common-setup'

setup() {
  _bats_common_setup
  SCRIPT="$REPO_ROOT/bin/cross-repo-automerge-timer.sh"
  export CCSU_SYSTEMD_UNIT_DIR="$TEST_TEMP/units"
  export STUB_LOG="$TEST_TEMP/cmd.log"
  : > "$STUB_LOG"
  export STUB_LOG

  # systemctl / loginctl をスタブ化（実 systemd・実 linger に触れない）
  make_stub_bin systemctl 'printf "systemctl %s\n" "$*" >> "$STUB_LOG"; exit 0'
  make_stub_bin loginctl 'printf "loginctl %s\n" "$*" >> "$STUB_LOG"; exit 0'
  export CCSU_SYSTEMCTL_BIN="$STUB_BIN/systemctl"

  # unit のパスは setup 後に確定する（ファイル読み込み時点では未設定のため）
  SVC="$CCSU_SYSTEMD_UNIT_DIR/claudeos-cross-repo-automerge.service"
  TMR="$CCSU_SYSTEMD_UNIT_DIR/claudeos-cross-repo-automerge.timer"
}

teardown() { _bats_common_teardown; }

@test "cross-repo-automerge-timer: --help は使い方を出して exit 0" {
  run bash "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--register"* ]]
  [[ "$output" == *"--unregister"* ]]
  [[ "$output" == *"--status"* ]]
}

@test "cross-repo-automerge-timer: アクション未指定は exit 2" {
  run bash "$SCRIPT"
  [ "$status" -eq 2 ]
}

@test "cross-repo-automerge-timer: 不明な引数は exit 2" {
  run bash "$SCRIPT" --status --bogus
  [ "$status" -eq 2 ]
}

@test "cross-repo-automerge-timer: --dry-run は unit を書かずに本文を表示する" {
  run bash "$SCRIPT" --register --dry-run
  [ "$status" -eq 0 ]
  [ ! -f "$SVC" ]
  [ ! -f "$TMR" ]
  [[ "$output" == *"claudeos-cross-repo-automerge.service"* ]]
  [[ "$output" == *"cross-repo-automerge.sh --apply --json"* ]]
  # dry-run では systemctl を呼ばない
  ! grep -q 'systemctl' "$STUB_LOG"
}

@test "cross-repo-automerge-timer: --register で service と timer を生成する" {
  run bash "$SCRIPT" --register
  [ "$status" -eq 0 ]
  [ -f "$SVC" ]
  [ -f "$TMR" ]
  grep -q 'daemon-reload' "$STUB_LOG"
  grep -q 'enable --now claudeos-cross-repo-automerge.timer' "$STUB_LOG"
}

@test "cross-repo-automerge-timer: service の ExecStart が巡回ツールの --apply --json" {
  bash "$SCRIPT" --register
  grep -q '^Type=oneshot' "$SVC"
  grep -q 'cross-repo-automerge.sh --apply --json' "$SVC"
  grep -q '^NoNewPrivileges=yes' "$SVC"
}

@test "cross-repo-automerge-timer: timer は既定で毎時 15 分・Persistent=true" {
  bash "$SCRIPT" --register
  grep -q '^OnCalendar=\*-\*-\* \*:15:00' "$TMR"
  grep -q '^Persistent=true' "$TMR"
  grep -q '^Unit=claudeos-cross-repo-automerge.service' "$TMR"
  grep -q '^WantedBy=timers.target' "$TMR"
}

@test "cross-repo-automerge-timer: unit 本文に本番の web サービス名・ポートを含まない" {
  bash "$SCRIPT" --register
  for tok in claudeos-web-startup 3740 3737 3741; do
    ! grep -q -- "$tok" "$SVC"
    ! grep -q -- "$tok" "$TMR"
  done
}

@test "cross-repo-automerge-timer: --on-calendar で周期を差し替えられる" {
  run bash "$SCRIPT" --register --on-calendar "*-*-* 02:30:00"
  [ "$status" -eq 0 ]
  grep -q '^OnCalendar=\*-\*-\* 02:30:00' "$TMR"
}

@test "cross-repo-automerge-timer: 不正な --on-calendar は exit 2" {
  run bash "$SCRIPT" --register --on-calendar "invalid; rm -rf /"
  [ "$status" -eq 2 ]
  [ ! -f "$TMR" ]
}

@test "cross-repo-automerge-timer: --unregister で unit を削除する" {
  bash "$SCRIPT" --register
  [ -f "$SVC" ]
  run bash "$SCRIPT" --unregister
  [ "$status" -eq 0 ]
  [ ! -f "$SVC" ]
  [ ! -f "$TMR" ]
  grep -q 'disable --now claudeos-cross-repo-automerge.timer' "$STUB_LOG"
}

@test "cross-repo-automerge-timer: --status は登録状態と timer 設定を表示する" {
  bash "$SCRIPT" --register
  run bash "$SCRIPT" --status
  [ "$status" -eq 0 ]
  [[ "$output" == *"登録済み"* ]]
  [[ "$output" == *"OnCalendar"* ]]
}

# ── proxy 環境変数の焼き込み（systemd --user は対話シェルの env を継承しない）──

@test "timer: 登録時に見えている proxy 設定を unit に焼き込む" {
  export https_proxy="http://127.0.0.1:9" no_proxy="127.0.0.1,localhost"
  run bash "$SCRIPT" --register
  [ "$status" -eq 0 ]
  grep -q '^Environment=https_proxy=http://127.0.0.1:9$' "$SVC"
  grep -q '^Environment=no_proxy=127.0.0.1,localhost$' "$SVC"
  # 焼き込んだ行の直後に NoNewPrivileges が独立行で来る（改行が壊れていない）
  grep -q '^NoNewPrivileges=yes$' "$SVC"
  ! grep -qE 'Environment=.*NoNewPrivileges' "$SVC"
}

@test "timer: CCSU_TIMER_INHERIT_PROXY=0 なら proxy 行を入れない" {
  export https_proxy="http://127.0.0.1:9" CCSU_TIMER_INHERIT_PROXY=0
  run bash "$SCRIPT" --register
  [ "$status" -eq 0 ]
  ! grep -q '^Environment=.*proxy' "$SVC"
  grep -q '^ExecStart=.*cross-repo-automerge.sh --apply --json$' "$SVC"
}

@test "timer: proxy が未設定なら Environment 行を足さない（既定の unit 本文を変えない）" {
  for v in https_proxy HTTPS_PROXY http_proxy HTTP_PROXY no_proxy NO_PROXY all_proxy ALL_PROXY; do unset "$v"; done
  run bash "$SCRIPT" --register
  [ "$status" -eq 0 ]
  ! grep -q '^Environment=' "$SVC"
}

@test "timer: proxy 値に改行があれば拒否する（unit への行注入防止）" {
  export https_proxy=$'http://a\nExecStart=/bin/evil'
  run bash "$SCRIPT" --register
  [ "$status" -ne 0 ]
}
