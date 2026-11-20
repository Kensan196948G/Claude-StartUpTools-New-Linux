#!/usr/bin/env bats
# ============================================================
# formal-check.bats — TLA+ モデル検査ランナーのテスト
# jar / java が無い環境では「検証した」と偽らずにスキップする (正直な skip)。
# ============================================================

load '../helpers/common-setup'

setup() {
  _bats_common_setup
  SCRIPT="$REPO_ROOT/scripts/tools/tla-check.sh"
  SPEC="$REPO_ROOT/formal/specs/run_ledger.tla"
  CFG="$REPO_ROOT/formal/specs/run_ledger.cfg"
  JAR="${CCSU_TLA_JAR:-$HOME/.cache/claudeos/formal/tla2tools.jar}"
}

teardown() { _bats_common_teardown; }

_tlc_available() {
  command -v java >/dev/null 2>&1 && [[ -s "$JAR" ]]
}

@test "formal: spec と config が揃っている (モジュール名はファイル名と一致)" {
  [ -f "$SPEC" ]
  [ -f "$CFG" ]
  head -1 "$SPEC" | grep -q "MODULE run_ledger"
  grep -q 'SPECIFICATION Spec' "$CFG"
  grep -q 'PROPERTY TerminalStable' "$CFG"
  grep -q 'INVARIANT ResumableRequiresCheckpoint' "$CFG"
}

@test "formal: --dry-run は実行コマンドを返す (jar 未取得でも失敗しない)" {
  run bash "$SCRIPT" run "$SPEC" --dry-run
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.dry_run')" = "true" ]
  [ "$(printf '%s' "$output" | jq -r '.spec')" = "$SPEC" ]
  [[ "$(printf '%s' "$output" | jq -r '.cmd')" == *tlc2.TLC* ]]
}

@test "formal: --no-download は jar が無ければ明示的に失敗する (検証したと偽らない)" {
  command -v java >/dev/null 2>&1 || skip "java がありません"
  [[ -s "$JAR" ]] && skip "jar が取得済みのため this path は使われない"
  run env CCSU_TLA_JAR="$TEST_TEMP/missing.jar" bash "$SCRIPT" run "$SPEC" --no-download
  [ "$status" -eq 3 ]
  [[ "$output" == *取得しません* ]]
}

@test "formal: 存在しない spec は rc=2" {
  run bash "$SCRIPT" run "$TEST_TEMP/nope.tla"
  [ "$status" -eq 2 ]
}

@test "formal: 既定 spec の検証が成功する (要 java + tla2tools.jar)" {
  _tlc_available || skip "java または tla2tools.jar が無いためスキップ (bash scripts/tools/tla-check.sh run で取得)"
  run bash "$SCRIPT" run "$SPEC" --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.result')" = "verified" ]
  [ "$(printf '%s' "$output" | jq -r '.states_generated')" -gt 0 ]
  [ "$(printf '%s' "$output" | jq -r '.distinct_states')" -gt 0 ]
}

@test "formal: 前提を緩めた仕様では反例を検出する (検出力の証明)" {
  _tlc_available || skip "java または tla2tools.jar が無いためスキップ"
  # モジュール名はファイル名と一致させる (TLA+ の制約)
  broken="$TEST_TEMP/broken/run_ledger.tla"
  mkdir -p "$TEST_TEMP/broken"
  sed 's/Resume == \/\\ status \\in NonTerminal/Resume == \/\\ status \\in Statuses/' "$SPEC" > "$broken"
  grep -q 'status \\in Statuses' "$broken"
  cp "$CFG" "$TEST_TEMP/broken/run_ledger.cfg"
  run bash "$SCRIPT" run "$broken" --json
  [ "$status" -eq 1 ]
  [ "$(printf '%s' "$output" | jq -r '.result')" = "violation" ]
}
