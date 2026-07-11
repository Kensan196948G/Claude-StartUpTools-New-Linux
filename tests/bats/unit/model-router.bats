#!/usr/bin/env bats
# model-router.bats — Opus/Sonnet 自動ルーティング

load '../helpers/common-setup'

setup() {
  _bats_common_setup
  export CLAUDEOS_HOME="$TEST_TEMP/claudeos"
  export CLAUDEOS_MODEL_USAGE_FILE="$TEST_TEMP/model-usage.jsonl"
  ROUTER="$REPO_ROOT/lib/model-router.sh"
}
teardown() { _bats_common_teardown; }

@test "task default: security/design/release は Opus 4.8 xhigh" {
  run bash -c 'source "'"$ROUTER"'"; model_router__select security; printf "%s|%s|%s" "$MODEL_ROUTER_KEY" "$MODEL_ROUTER_MODEL" "$MODEL_ROUTER_EFFORT"'
  [ "$status" -eq 0 ]
  [ "$output" = "opus|claude-opus-4-8|xhigh" ]
}

@test "task default: implementation/test/docs は Sonnet 5 max" {
  run bash -c 'source "'"$ROUTER"'"; model_router__select implementation; printf "%s|%s|%s" "$MODEL_ROUTER_KEY" "$MODEL_ROUTER_MODEL" "$MODEL_ROUTER_EFFORT"'
  [ "$status" -eq 0 ]
  [ "$output" = "sonnet|claude-sonnet-5|max" ]
}

@test "balance: 利用差が5%以上なら少ない Opus へ切り替える" {
  cat > "$CLAUDEOS_MODEL_USAGE_FILE" <<'JSONL'
{"event":"select","model_key":"sonnet"}
{"event":"select","model_key":"sonnet"}
{"event":"select","model_key":"sonnet"}
{"event":"select","model_key":"sonnet"}
{"event":"select","model_key":"sonnet"}
{"event":"select","model_key":"opus"}
{"event":"select","model_key":"opus"}
{"event":"select","model_key":"opus"}
{"event":"select","model_key":"opus"}
JSONL
  run bash -c 'source "'"$ROUTER"'"; model_router__select implementation; printf "%s|%s" "$MODEL_ROUTER_KEY" "$MODEL_ROUTER_REASON"'
  [ "$status" -eq 0 ]
  [[ "$output" == opus\|balance:* ]]
}

@test "force: CLAUDEOS_MODEL_KEY は balance より優先される" {
  cat > "$CLAUDEOS_MODEL_USAGE_FILE" <<'JSONL'
{"event":"select","model_key":"opus"}
{"event":"select","model_key":"opus"}
{"event":"select","model_key":"opus"}
JSONL
  run env CLAUDEOS_MODEL_KEY=opus bash -c 'source "'"$ROUTER"'"; model_router__select implementation; printf "%s|%s" "$MODEL_ROUTER_KEY" "$MODEL_ROUTER_REASON"'
  [ "$status" -eq 0 ]
  [ "$output" = "opus|forced:opus" ]
}

@test "record: 選択結果を model-usage.jsonl に追記する" {
  run bash -c 'source "'"$ROUTER"'"; model_router__select docs; model_router__record_selection Demo test docs'
  [ "$status" -eq 0 ]
  [ -f "$CLAUDEOS_MODEL_USAGE_FILE" ]
  run cat "$CLAUDEOS_MODEL_USAGE_FILE"
  [[ "$output" == *'"event":"select"'* ]]
  [[ "$output" == *'"project":"Demo"'* ]]
  [[ "$output" == *'"model_key":"sonnet"'* ]]
  [[ "$output" == *'"effort":"max"'* ]]
}
