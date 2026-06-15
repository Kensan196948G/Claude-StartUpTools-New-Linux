#!/usr/bin/env bats
# ============================================================
# credits.bats — lib/credits.sh のユニットテスト
#
# 検証観点:
#   - record: JSONL 台帳への追記形 (cost/tokens/project/ts)
#   - month_total: 指定月の cost_usd 集計 (他月は除外)
#   - guard: 予算比の段階境界 (69/70/85/95%) と budget=0 無効
# ============================================================

load '../helpers/common-setup'

setup() {
  _bats_common_setup
  export CCSU_CREDITS_LEDGER="$TEST_TEMP/credits/ledger.jsonl"
  source "$REPO_ROOT/lib/credits.sh"
}
teardown() { _bats_common_teardown; }

# ---- record ---------------------------------------------
@test "credits__record: 台帳へ 1 行追記し JSON として妥当" {
  run credits__record 1.50 1000 2000 Demo 2026-06-15T10:00:00+00:00
  [ "$status" -eq 0 ]
  [ -f "$CCSU_CREDITS_LEDGER" ]
  run jq -e '.cost_usd == 1.5 and .project == "Demo" and .tokens_in == 1000' "$CCSU_CREDITS_LEDGER"
  [ "$status" -eq 0 ]
}
@test "credits__record: cost 非数は 0 に丸める" {
  run credits__record abc 0 0 Demo 2026-06-15T10:00:00+00:00
  [ "$status" -eq 0 ]
  run jq -e '.cost_usd == 0' "$CCSU_CREDITS_LEDGER"
  [ "$status" -eq 0 ]
}
@test "credits__record: 複数追記は行が積み上がる" {
  credits__record 1.0 0 0 A 2026-06-15T10:00:00+00:00
  credits__record 2.0 0 0 B 2026-06-15T11:00:00+00:00
  run wc -l < "$CCSU_CREDITS_LEDGER"
  [ "$output" -eq 2 ]
}

# ---- month_total ----------------------------------------
@test "credits__month_total: 台帳不在は 0" {
  run credits__month_total 2026-06
  [ "$output" = "0" ]
}
@test "credits__month_total: 指定月のみ合計し他月は除外" {
  credits__record 1.25 0 0 A 2026-06-01T00:00:00+00:00
  credits__record 2.75 0 0 A 2026-06-20T00:00:00+00:00
  credits__record 9.99 0 0 A 2026-05-31T00:00:00+00:00
  run credits__month_total 2026-06
  [ "$output" = "4" ]
}

# ---- guard ----------------------------------------------
@test "credits__guard: budget=0 は無効 (空)" { run credits__guard 0 50; [ -z "$output" ]; }
@test "credits__guard: 69% は継続 (空)" { run credits__guard 100 69; [ -z "$output" ]; }
@test "credits__guard: 70% は warn" { run credits__guard 100 70; [ "$output" = "credit-cap:warn" ]; }
@test "credits__guard: 85% は verify-only" { run credits__guard 100 85; [ "$output" = "credit-cap:verify-only" ]; }
@test "credits__guard: 95% は stop" { run credits__guard 100 95; [ "$output" = "credit-cap:stop" ]; }
@test "credits__guard: 100% 超も stop" { run credits__guard 100 120; [ "$output" = "credit-cap:stop" ]; }
