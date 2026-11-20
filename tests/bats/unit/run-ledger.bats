#!/usr/bin/env bats
# ============================================================
# run-ledger.bats — lib/run-ledger.sh + bin/run-ledger.sh のテスト
# Durable Agent Execution (heartbeat / checkpoint / resume / reconcile) を固定する。
# ============================================================

load '../helpers/common-setup'

setup() {
  _bats_common_setup
  export CLAUDEOS_HOME="$TEST_TEMP/claudeos"
  mkdir -p "$CLAUDEOS_HOME"
  export CCSU_RUNS_DIR="$CLAUDEOS_HOME/runs"
  SCRIPT="$REPO_ROOT/bin/run-ledger.sh"
}

teardown() { _bats_common_teardown; }

_start() {
  bash "$SCRIPT" start --project "$1" --task "$2" "${@:3}"
}

@test "run-ledger: start が running の run.json を作成し run-id を返す" {
  run _start Demo "大規模移行"
  [ "$status" -eq 0 ]
  id="$output"
  [[ "$id" =~ ^run-[0-9]{8}T[0-9]{6}-[0-9a-f]{8}$ ]]
  json="$CCSU_RUNS_DIR/$id/run.json"
  [ -f "$json" ]
  [ "$(jq -r '.schema' "$json")" = "claudeos.run/v1" ]
  [ "$(jq -r '.status' "$json")" = "running" ]
  [ "$(jq -r '.revision' "$json")" -eq 1 ]
  [ "$(jq -r '.attempts' "$json")" -eq 1 ]
  [ "$(jq -r '.checkpoints | length' "$json")" -eq 0 ]
  # events.jsonl に start が 1 行
  [ "$(jq -r '.type' "$CCSU_RUNS_DIR/$id/events.jsonl")" = "start" ]
}

@test "run-ledger: --project / --task は必須 (rc=2)" {
  run bash "$SCRIPT" start --project Demo
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" start --task "T"
  [ "$status" -eq 2 ]
}

@test "run-ledger: heartbeat が last_heartbeat_epoch を進める" {
  id="$(_start Demo T)"
  before="$(jq -r '.last_heartbeat_epoch' "$CCSU_RUNS_DIR/$id/run.json")"
  sleep 1
  run bash "$SCRIPT" heartbeat "$id" --note ok
  [ "$status" -eq 0 ]
  after="$(jq -r '.last_heartbeat_epoch' "$CCSU_RUNS_DIR/$id/run.json")"
  [ "$after" -gt "$before" ]
  [ "$(jq -r '.revision' "$CCSU_RUNS_DIR/$id/run.json")" -eq 2 ]
}

@test "run-ledger: checkpoint が seq / phase / state_sha256 を記録する" {
  id="$(_start Demo T)"
  printf 'work in progress\n' > "$TEST_TEMP/state.txt"
  run bash "$SCRIPT" checkpoint "$id" --phase design --state-file "$TEST_TEMP/state.txt"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
  run bash "$SCRIPT" checkpoint "$id" --phase implement
  [ "$output" = "2" ]
  json="$CCSU_RUNS_DIR/$id/run.json"
  [ "$(jq -r '.phase' "$json")" = "implement" ]
  [ "$(jq -r '.checkpoints | length' "$json")" -eq 2 ]
  [ "$(jq -r '.checkpoints[0].state_sha256' "$json")" = "$(sha256sum "$TEST_TEMP/state.txt" | cut -d' ' -f1)" ]
  [ "$(jq -r '.checkpoints[1].state_sha256' "$json")" = "null" ]
  # checkpoint 本文 (作業状態そのもの) は保存しない
  ! grep -q 'work in progress' "$json"
}

@test "run-ledger: finish completed で terminal になり list から外れる" {
  id="$(_start Demo T)"
  run bash "$SCRIPT" finish "$id" --status completed --note done
  [ "$status" -eq 0 ]
  [ "$(jq -r '.status' "$CCSU_RUNS_DIR/$id/run.json")" = "completed" ]
  [ "$(jq -r '.last_error' "$CCSU_RUNS_DIR/$id/run.json")" = "null" ]
  run bash "$SCRIPT" list
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run bash "$SCRIPT" list --all
  [[ "$output" == *"$id"* ]]
}

@test "run-ledger: 終了済み run への finish / heartbeat は rc=3" {
  id="$(_start Demo T)"
  bash "$SCRIPT" finish "$id" --status completed >/dev/null
  run bash "$SCRIPT" finish "$id" --status failed
  [ "$status" -eq 3 ]
  run bash "$SCRIPT" heartbeat "$id"
  [ "$status" -eq 3 ]
}

@test "run-ledger: heartbeat 途絶を reconcile が stale にする (冪等)" {
  id="$(_start Demo T --ttl 1)"
  sleep 2
  run bash "$SCRIPT" reconcile --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r 'length')" -eq 1 ]
  [ "$(printf '%s' "$output" | jq -r '.[0].status')" = "stale" ]
  [[ "$(printf '%s' "$output" | jq -r '.[0].reason')" == heartbeat_timeout:* ]]
  # 2 回目は対象が running ではないので何も検出しない (冪等)
  run bash "$SCRIPT" reconcile --json
  [ "$(printf '%s' "$output" | jq -r 'length')" -eq 0 ]
  [ "$(jq -r '.status' "$CCSU_RUNS_DIR/$id/run.json")" = "stale" ]
}

@test "run-ledger: PID 消滅を reconcile が interrupted にする" {
  id="$(_start Demo T)"
  jq '.pid = 999999' "$CCSU_RUNS_DIR/$id/run.json" > "$TEST_TEMP/tmp.json"
  mv "$TEST_TEMP/tmp.json" "$CCSU_RUNS_DIR/$id/run.json"
  run bash "$SCRIPT" reconcile --json
  [ "$(printf '%s' "$output" | jq -r '.[0].status')" = "interrupted" ]
  [[ "$(printf '%s' "$output" | jq -r '.[0].reason')" == process_gone:pid=999999 ]]
}

@test "run-ledger: resume は checkpoint から再開し attempts を増やす" {
  id="$(_start Demo T)"
  bash "$SCRIPT" checkpoint "$id" --phase analyze >/dev/null
  sleep 2
  jq '.last_heartbeat_epoch = (.last_heartbeat_epoch - 100000)' "$CCSU_RUNS_DIR/$id/run.json" > "$TEST_TEMP/t.json"
  mv "$TEST_TEMP/t.json" "$CCSU_RUNS_DIR/$id/run.json"
  bash "$SCRIPT" reconcile >/dev/null
  [ "$(jq -r '.status' "$CCSU_RUNS_DIR/$id/run.json")" = "stale" ]
  run bash "$SCRIPT" resume "$id" --note "再開"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.next_phase')" = "analyze" ]
  [ "$(printf '%s' "$output" | jq -r '.attempts')" -eq 2 ]
  json="$CCSU_RUNS_DIR/$id/run.json"
  [ "$(jq -r '.status' "$json")" = "running" ]
  [ "$(jq -r '.stale_reason' "$json")" = "null" ]
  [ "$(jq -r '.checkpoints | length' "$json")" -eq 1 ]
}

@test "run-ledger: checkpoint の無い run の resume は rc=4 (再開不能を成功と偽らない)" {
  id="$(_start Demo T)"
  run bash "$SCRIPT" resume "$id"
  [ "$status" -eq 4 ]
  [ "$(jq -r '.status' "$CCSU_RUNS_DIR/$id/run.json")" = "running" ]
}

@test "run-ledger: failed は failures.jsonl へ signature 付きで記録される" {
  id="$(_start Demo T)"
  run bash "$SCRIPT" finish "$id" --status failed --note "test failed at 2026-09-25T09:53:05Z: exit code 137 in /tmp/a/b/main.log"
  [ "$status" -eq 0 ]
  f="$CCSU_RUNS_DIR/failures.jsonl"
  [ -f "$f" ]
  [ "$(jq -r '.status' "$f")" = "failed" ]
  [ "$(jq -r '.run_id' "$f")" = "$id" ]
  sig="$(jq -r '.signature' "$f")"
  [[ "$sig" =~ ^sig-[0-9a-f]{16}$ ]]
  run bash "$SCRIPT" failures --count --signature "$sig"
  [ "$output" -eq 1 ]
  run bash "$SCRIPT" stats --json
  [ "$(printf '%s' "$output" | jq -r '.failure_records')" -eq 1 ]
}

@test "run-ledger: signature は可変部分 (数値・パス・日時) の差を吸収する" {
  a="$(bash "$SCRIPT" signature "build failed at 2026-09-25T09:53:05Z: exit code 137 in /tmp/a/b/main.log")"
  b="$(bash "$SCRIPT" signature "build failed at 2027-01-02T11:00:00Z: exit code 1 in /home/x/y/z.txt")"
  c="$(bash "$SCRIPT" signature "build failed at 2027-01-02T11:00:00Z: exit code 1 in /home/x/y/z.txt")"
  [ "$a" = "$b" ]
  [ "$b" = "$c" ]
  d="$(bash "$SCRIPT" signature "network timeout while fetching registry")"
  [ "$a" != "$d" ]
}

@test "run-ledger: 不正な run-id を拒否する (パストラバーサル防止)" {
  run bash "$SCRIPT" get "../../../etc/passwd"
  [ "$status" -ne 0 ]
  run bash "$SCRIPT" heartbeat "run-../../x"
  [ "$status" -ne 0 ]
  run bash "$SCRIPT" get "run-does-not-exist"
  [ "$status" -ne 0 ]
}

@test "run-ledger: child run は親の状態に従う (階層で分割実行を追跡)" {
  parent="$(_start Demo "大規模改修")"
  run bash "$SCRIPT" start --project Demo --task "子タスク" --kind child --parent "$parent"
  [ "$status" -eq 0 ]
  child="$output"
  [ "$(jq -r '.parent_run_id' "$CCSU_RUNS_DIR/$child/run.json")" = "$parent" ]
  run bash "$SCRIPT" tree --json
  [ "$(printf '%s' "$output" | jq -r --arg p "$parent" '[.[] | select(.parent_run_id==$p)] | length')" -eq 1 ]
  # 親が終了したら新規 child は作れない
  bash "$SCRIPT" finish "$parent" --status completed >/dev/null
  run bash "$SCRIPT" start --project Demo --task "孫" --kind child --parent "$parent"
  [ "$status" -eq 2 ]
}

@test "run-ledger: run ディレクトリ外のファイルを書き換えない" {
  id="$(_start Demo T)"
  touch "$TEST_TEMP/sentinel"
  before="$(md5sum "$TEST_TEMP/sentinel" | cut -d' ' -f1)"
  bash "$SCRIPT" heartbeat "$id" >/dev/null
  bash "$SCRIPT" list --all >/dev/null
  bash "$SCRIPT" stats >/dev/null
  [ "$(md5sum "$TEST_TEMP/sentinel" | cut -d' ' -f1)" = "$before" ]
  [ "$(find "$CCSU_RUNS_DIR" -maxdepth 1 -type d -name 'run-*' | wc -l)" -eq 1 ]
}
