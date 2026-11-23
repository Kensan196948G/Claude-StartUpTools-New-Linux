#!/usr/bin/env bats
# ============================================================
# audit-log.bats — bin/audit-log.sh のテスト
# fixtures は $TEST_TEMP に作る (実ログ・実 ~/.claudeos は読まない)。
# jq は実体を使う (CI の linux-validate は jq をインストール済み)。
# ============================================================

bats_require_minimum_version 1.5.0
load '../helpers/common-setup'

setup() {
  _bats_common_setup
  SCRIPT="$REPO_ROOT/bin/audit-log.sh"
  HOME_DIR="$TEST_TEMP/home"
  LOG_DIR="$HOME_DIR/logs"
  LOG="$LOG_DIR/web-startup-audit.log"
  mkdir -p "$LOG_DIR"
}
teardown() { _bats_common_teardown; }

# write_rec <file> <ts> <action>
write_rec() {
  printf '{"ts":"%s","action":"%s","mode":"dry-run","project":"Demo","goal":"g","remote":"127.0.0.1","exit":0}\n' \
    "$2" "$3" >> "$1"
}

# seed_generations — .3(最古) .2 .1 無印(最新) の 5 レコード
seed_generations() {
  write_rec "$LOG.3" "2026-01-01T00:00:01.000Z" "plan"
  write_rec "$LOG.2" "2026-01-02T00:00:02.000Z" "launch"
  write_rec "$LOG.1" "2026-01-03T00:00:03.000Z" "ops-restart"
  write_rec "$LOG"   "2026-01-04T00:00:04.000Z" "ops-plan-rejected"
  write_rec "$LOG"   "2026-01-05T00:00:05.000Z" "apply-all-plan"
}

# actions <text> — 出力行の action をカンマ区切りで返す
actions() { printf '%s\n' "$1" | jq -r '.action' | paste -sd, -; }

@test "audit-log: 世代を古い順 (.3 → .2 → .1 → 無印) に連結する" {
  seed_generations
  run bash "$SCRIPT" --home "$HOME_DIR" --tail 100
  [ "$status" -eq 0 ]
  [ "$(actions "$output")" = "plan,launch,ops-restart,ops-plan-rejected,apply-all-plan" ]
}

@test "audit-log: --tail N は連結後の末尾 N 行を出す" {
  seed_generations
  run bash "$SCRIPT" --home "$HOME_DIR" --tail 2
  [ "$status" -eq 0 ]
  [ "$(actions "$output")" = "ops-plan-rejected,apply-all-plan" ]
  # 既定は 20 行 (5 行しか無いので全部)
  run bash "$SCRIPT" --home "$HOME_DIR"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 5 ]
}

@test "audit-log: --action は完全一致 (部分一致しない)" {
  seed_generations
  run bash "$SCRIPT" --home "$HOME_DIR" --action plan
  [ "$status" -eq 0 ]
  [ "$(actions "$output")" = "plan" ]

  # "apply-all-plan" は "plan" に部分一致するが、完全一致ではないので出ない
  run bash "$SCRIPT" --home "$HOME_DIR" --action apply-all-plan
  [ "$status" -eq 0 ]
  [ "$(actions "$output")" = "apply-all-plan" ]

  run bash "$SCRIPT" --home "$HOME_DIR" --action no-such-action
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "audit-log: --since は日付 / ISO8601 の両方で ts を絞る" {
  seed_generations
  run bash "$SCRIPT" --home "$HOME_DIR" --since 2026-01-03
  [ "$status" -eq 0 ]
  [ "$(actions "$output")" = "ops-restart,ops-plan-rejected,apply-all-plan" ]

  run bash "$SCRIPT" --home "$HOME_DIR" --since 2026-01-02T12:00:00Z
  [ "$status" -eq 0 ]
  [ "$(actions "$output")" = "ops-restart,ops-plan-rejected,apply-all-plan" ]

  run bash "$SCRIPT" --home "$HOME_DIR" --since 2026-01-05T00:00:06Z
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "audit-log: 壊れた行はスキップして件数を stderr に出す (落ちない)" {
  seed_generations
  printf 'not-json\n{"unterminated":\n' >> "$LOG"
  run --separate-stderr bash "$SCRIPT" --home "$HOME_DIR" --tail 100 --json
  [ "$status" -eq 0 ]
  # 有効行 5 / 壊れた行 2
  [ "$(printf '%s\n' "$output" | tail -1 | jq -r '.lines')" -eq 5 ]
  [ "$(printf '%s\n' "$output" | tail -1 | jq -r '.skipped')" -eq 2 ]
  [[ "$stderr" == *"スキップ"* ]]
  # 有効な 5 行は rown として出る
  [ "$(printf '%s\n' "$output" | grep -c '"action"')" -eq 5 ]
}

@test "audit-log: ログが無ければ exit 1" {
  run --separate-stderr bash "$SCRIPT" --home "$TEST_TEMP/empty"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"見つかりません"* ]]
}

@test "audit-log: --files は存在する世代とサイズを一覧する" {
  seed_generations
  run bash "$SCRIPT" --home "$HOME_DIR" --files
  [ "$status" -eq 0 ]
  [[ "$output" == *"BYTES"* ]]
  for n in web-startup-audit.log web-startup-audit.log.1 web-startup-audit.log.2 web-startup-audit.log.3; do
    [[ "$output" == *"$n"* ]]
  done
  # ヘッダ + 4 世代
  [ "$(printf '%s\n' "$output" | grep -c 'web-startup-audit\.log')" -eq 4 ]
}

@test "audit-log: --files --json は件数とサイズを 1 行で返す" {
  seed_generations
  run bash "$SCRIPT" --home "$HOME_DIR" --files --json
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | tail -1 | jq -e \
    '.ok == true and .files == 4 and (.generations | length) == 4 and (.total_bytes > 0)' >/dev/null
}

@test "audit-log: --json は最終行に必要なキーを持つ 1 行サマリを出す" {
  seed_generations
  run bash "$SCRIPT" --home "$HOME_DIR" --json --tail 100
  [ "$status" -eq 0 ]
  local summary last_line
  last_line="$(printf '%s\n' "$output" | tail -1)"
  summary="$last_line"
  printf '%s' "$summary" | jq -e \
    '.ok == true and .lines == 5 and .files == 4 and .matched == 5 and .shown == 5
     and (.first | type) == "string" and (.last | type) == "string"
     and .first == "2026-01-01T00:00:01.000Z" and .last == "2026-01-05T00:00:05.000Z"' >/dev/null

  # --action と組み合わせると matched が絞られる
  run bash "$SCRIPT" --home "$HOME_DIR" --json --action ops-restart
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | tail -1 | jq -e '.matched == 1 and .shown == 1' >/dev/null
}

@test "audit-log: 引数エラーは exit 2" {
  run bash "$SCRIPT" --tail abc
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" --tail 0
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" --tail
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" --bogus
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" --since garbage
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" --action
  [ "$status" -eq 2 ]
}

@test "audit-log: jq が無ければ exit 1 (必須依存)" {
  seed_generations
  run --separate-stderr env CCSU_JQ_BIN=/nonexistent/jq bash "$SCRIPT" --home "$HOME_DIR"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"jq"* ]]
}

@test "audit-log: 読み取り専用 (実行前後でログの内容が変わらない)" {
  seed_generations
  printf 'not-json\n' >> "$LOG"
  local before after
  before="$(find "$LOG_DIR" -type f -exec sha256sum {} + | sort | sha256sum)"
  run bash "$SCRIPT" --home "$HOME_DIR" --json --tail 100
  [ "$status" -eq 0 ]
  run bash "$SCRIPT" --home "$HOME_DIR" --files
  [ "$status" -eq 0 ]
  after="$(find "$LOG_DIR" -type f -exec sha256sum {} + | sort | sha256sum)"
  [ "$before" = "$after" ]
}
