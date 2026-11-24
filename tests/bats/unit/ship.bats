#!/usr/bin/env bats
# ============================================================
# ship.bats — bin/ship.sh / bin/ship-mode.sh / bin/ship-approve.sh の CLI テスト
#
# 検証観点:
#   - ヘルプ・引数エラー (exit 2)
#   - run-start → 二重 run の拒否 (同一 repo+branch で複数エージェントが同時修正しない)
#   - 承認・マージ系の状態へは run-transition で直接遷移できない
#   - QC モードは bwrap で隔離実行し、証跡を残す (dry-run)
#   - ship-approve.sh は TTY が無いと承認できない (AI の Bash tool から承認できない)
#   - ship-mode status は Ship 系を実機検証前に Available と偽装しない
#   - 監査ログ連鎖検証
# ============================================================

load '../helpers/common-setup'

setup() {
  _bats_common_setup
  export CLAUDEOS_SHIP_HOME="$TEST_TEMP/ship"
  export CLAUDEOS_HOME="$TEST_TEMP/home"
  export CCSU_HOME="$TEST_TEMP/home"
  PROJ="$TEST_TEMP/proj"
  mkdir -p "$PROJ"
  git -C "$PROJ" init -q -b main
  git -C "$PROJ" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  git -C "$PROJ" remote add origin https://github.com/acme/widget.git
  # 実機の gh / claude を呼ばない
  make_stub_bin gh 'echo "gh stub $*" >&2; exit 1'
  make_stub_bin claude 'case "$1" in --version) echo "2.1.330 (Claude Code)";; auth) echo "{\"loggedIn\":true,\"apiProvider\":\"firstParty\",\"subscriptionType\":\"max\"}";; *) exit 0;; esac'
}
teardown() { _bats_common_teardown; }

@test "ship.sh: --help は使い方を表示し exit 0" {
  run bash "$REPO_ROOT/bin/ship.sh" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"run-start"* ]]
  [[ "$output" == *"headless"* || "$output" == *"代行せず"* ]]
}

@test "ship.sh: 必須引数が無ければ exit 2" {
  run bash "$REPO_ROOT/bin/ship.sh" run-start --repo acme/widget
  [ "$status" -eq 2 ]
  [[ "$output" == *"MISSING --project"* ]]
}

@test "ship.sh: 不正な repo / mode は拒否" {
  run bash "$REPO_ROOT/bin/ship.sh" run-start --project "$PROJ" --repo '../etc' --mode SH2
  [ "$status" -ne 0 ]
  run bash "$REPO_ROOT/bin/ship.sh" run-start --project "$PROJ" --repo acme/widget --mode ZZ
  [ "$status" -eq 2 ]
}

@test "ship.sh: run-start は DISCOVERY で始まり、同じ repo+branch の 2 つ目を拒否する" {
  run bash "$REPO_ROOT/bin/ship.sh" run-start --project "$PROJ" --repo acme/widget --mode SH2 --intent "x" --json
  [ "$status" -eq 0 ]
  [[ "$(printf '%s' "$output" | jq -r .state)" == "DISCOVERY" ]]
  run bash "$REPO_ROOT/bin/ship.sh" run-start --project "$PROJ" --repo acme/widget --mode SH2 --intent "y" --json
  [ "$status" -eq 1 ]
  [[ "$output" == *"ACTIVE_RUN_EXISTS"* ]]
}

@test "ship.sh: HUMAN_APPROVED / MERGED へは run-transition で直接遷移できない" {
  id="$(bash "$REPO_ROOT/bin/ship.sh" run-start --project "$PROJ" --repo acme/widget --mode SH2 --json | jq -r .run_id)"
  for to in HUMAN_APPROVED MERGE_QUEUED MERGING MERGED; do
    run bash "$REPO_ROOT/bin/ship.sh" run-transition --id "$id" --to "$to"
    [ "$status" -eq 1 ]
    [[ "$output" == *"RESTRICTED_TRANSITION"* ]]
  done
  run bash "$REPO_ROOT/bin/ship.sh" run-transition --id "$id" --to IMPLEMENTING
  [ "$status" -eq 1 ]
  [[ "$output" == *"ILLEGAL_TRANSITION"* ]]
  run bash "$REPO_ROOT/bin/ship.sh" run-transition --id "$id" --to PLANNING --json
  [ "$status" -eq 0 ]
}

@test "ship.sh: gate 未 PASS では HUMAN_APPROVAL_REQUIRED へ進めない" {
  id="$(bash "$REPO_ROOT/bin/ship.sh" run-start --project "$PROJ" --repo acme/widget --mode SH2 --json | jq -r .run_id)"
  for s in PLANNING IMPLEMENTING LOCAL_TESTING QUALITY_EVALUATING; do bash "$REPO_ROOT/bin/ship.sh" run-transition --id "$id" --to "$s" >/dev/null; done
  run bash "$REPO_ROOT/bin/ship.sh" run-transition --id "$id" --to HUMAN_APPROVAL_REQUIRED
  [ "$status" -eq 1 ]
  [[ "$output" == *"QUALITY_GATE_NOT_PASS"* ]]
}

@test "ship.sh: run-stop は STOPPED にし /ship stop の案内を出す。監査ログ連鎖は OK" {
  id="$(bash "$REPO_ROOT/bin/ship.sh" run-start --project "$PROJ" --repo acme/widget --mode SH1 --json | jq -r .run_id)"
  run bash "$REPO_ROOT/bin/ship.sh" run-stop --id "$id" --reason test
  [ "$status" -eq 0 ]
  [[ "$output" == *"/ship stop"* ]]
  run bash "$REPO_ROOT/bin/ship.sh" audit-verify --json
  [ "$status" -eq 0 ]
  [[ "$(printf '%s' "$output" | jq -r .ok)" == "true" ]]
}

@test "ship.sh: gh が使えないとき gate は BLOCKED (exit 3) で推測しない" {
  export CLAUDEOS_SHIP_TRUSTED_POLICY="$REPO_ROOT/config/ship-policy.json"
  run bash "$REPO_ROOT/bin/ship.sh" gate --repo acme/widget --pr 3 --json
  [ "$status" -eq 3 ]
  [[ "$output" == *"BLOCKED"* ]]
}

@test "ship.sh: merge は gh 不可なら REFUSED (auto-merge を登録しない)" {
  export CLAUDEOS_SHIP_TRUSTED_POLICY="$REPO_ROOT/config/ship-policy.json"
  run bash "$REPO_ROOT/bin/ship.sh" merge --repo acme/widget --pr 3 --json
  [ "$status" -eq 1 ]
  [[ "$output" == *"REFUSED"* ]]
}

@test "ship.sh: 日次上限で run-start を止める" {
  pol="$TEST_TEMP/pol.json"
  jq '.limits.dailyRunCap = 1' "$REPO_ROOT/config/ship-policy.json" > "$pol"
  export CLAUDEOS_SHIP_POLICY="$pol"
  bash "$REPO_ROOT/bin/ship.sh" run-start --project "$PROJ" --repo acme/widget --mode SH1 >/dev/null
  git -C "$PROJ" switch -q -c other
  run bash "$REPO_ROOT/bin/ship.sh" run-start --project "$PROJ" --repo acme/widget --mode SH1
  [ "$status" -eq 1 ]
  [[ "$output" == *"DAILY_CAP_REACHED"* ]]
}

@test "ship-approve.sh: TTY が無ければ承認できない (AI の Bash tool から承認不可)" {
  export CLAUDEOS_APPROVER_KEY="$TEST_TEMP/nokey.json"
  run bash "$REPO_ROOT/bin/ship-approve.sh" approve --repo acme/widget --pr 3 --head "$(printf 'a%.0s' {1..40})" < /dev/null
  [ "$status" -ne 0 ]
  run setsid -w bash "$REPO_ROOT/bin/ship-approve.sh" keygen --name tester < /dev/null
  [ "$status" -ne 0 ]
  [[ "$output" == *"NO_TTY"* ]]
}

@test "ship-mode.sh: status は Ship 系を Available と偽装しない" {
  mkdir -p "$CLAUDEOS_SHIP_HOME"
  echo '{"overall":"degraded"}' > "$CLAUDEOS_SHIP_HOME/capability.json"
  run bash "$REPO_ROOT/bin/ship-mode.sh" status
  [ "$status" -eq 0 ]
  [[ "$output" == *"L1"*"Available"* ]]
  line="$(printf '%s\n' "$output" | grep '^SH2')"
  [[ "$line" == *"Experimental"* ]]
  [[ "$line" != *" Available"* ]]
  echo '{"overall":"unavailable"}' > "$CLAUDEOS_SHIP_HOME/capability.json"
  run bash "$REPO_ROOT/bin/ship-mode.sh" status
  [[ "$(printf '%s\n' "$output" | grep '^SH1')" == *"Unavailable"* ]]
}

@test "ship-mode.sh: SH1 は /ship を人が入力する手順を表示する (入力を代行しない)" {
  make_stub_bin tmux 'echo "TMUX CALLED $*" >> "$TEST_TEMP/tmux.log"'
  run bash "$REPO_ROOT/bin/ship-mode.sh" SH1 --project "$PROJ"
  [ "$status" -eq 0 ]
  [[ "$output" == *"/ship"* ]]
  [[ "$output" == *"/ship stop"* ]]
  [ ! -f "$TEST_TEMP/tmux.log" ]
}

@test "ship-mode.sh: SH2 は --intent 必須、dry-run は何も起動しない" {
  run bash "$REPO_ROOT/bin/ship-mode.sh" SH2 --project "$PROJ"
  [ "$status" -eq 2 ]
  run bash "$REPO_ROOT/bin/ship-mode.sh" SH2 --project "$PROJ" --intent "機能 X" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY-RUN"*"acme/widget"* ]]
  [ ! -d "$CLAUDEOS_SHIP_HOME/runs" ]
}

@test "ship-mode.sh: QC dry-run は対象 SHA を表示" {
  run bash "$REPO_ROOT/bin/ship-mode.sh" QC --project "$PROJ" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" =~ head\ [0-9a-f]{40} ]]
}

@test "menu --render: Ship Native セクションと既存 L1/T1/S1 が共存する" {
  run bash "$REPO_ROOT/bin/menu.sh" --render
  [ "$status" -eq 0 ]
  [[ "$output" == *"L1"* && "$output" == *"T1"* && "$output" == *"S1"* ]]
  [[ "$output" == *"Ship Native"* && "$output" == *" QC "* && "$output" == *" HG "* ]]
}
