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

@test "taskEffort: config の部分一致キーで effort を上書きし reason に痕跡を残す" {
  printf '{ "modelRouter": { "taskEffort": { "monitor": "high" } } }\n' > "$TEST_TEMP/te.json"
  run env AI_STARTUP_CONFIG_PATH="$TEST_TEMP/te.json" bash -c 'source "'"$ROUTER"'"; model_router__select monitor; printf "%s|%s|%s" "$MODEL_ROUTER_MODEL" "$MODEL_ROUTER_EFFORT" "$MODEL_ROUTER_REASON"'
  [ "$status" -eq 0 ]
  [[ "$output" == "claude-sonnet-5|high|"*"+effort:task(monitor)" ]]
}

@test "taskEffort: 未設定なら既定 effort (max) を維持する" {
  printf '{ "modelRouter": { "taskEffort": {} } }\n' > "$TEST_TEMP/te-empty.json"
  run env AI_STARTUP_CONFIG_PATH="$TEST_TEMP/te-empty.json" bash -c 'source "'"$ROUTER"'"; model_router__select monitor; printf "%s|%s" "$MODEL_ROUTER_EFFORT" "$MODEL_ROUTER_REASON"'
  [ "$status" -eq 0 ]
  [[ "$output" == "max|task:monitor" ]]
}

@test "taskEffort: 不正な effort 値は無視して既定を維持する" {
  printf '{ "modelRouter": { "taskEffort": { "monitor": "turbo" } } }\n' > "$TEST_TEMP/te-bad.json"
  run env AI_STARTUP_CONFIG_PATH="$TEST_TEMP/te-bad.json" bash -c 'source "'"$ROUTER"'"; model_router__select monitor; printf "%s" "$MODEL_ROUTER_EFFORT"'
  [ "$status" -eq 0 ]
  [ "$output" = "max" ]
}

@test "taskEffort: opus ルートのタスクにも部分一致で適用される" {
  printf '{ "modelRouter": { "taskEffort": { "release": "high" } } }\n' > "$TEST_TEMP/te-opus.json"
  run env AI_STARTUP_CONFIG_PATH="$TEST_TEMP/te-opus.json" bash -c 'source "'"$ROUTER"'"; model_router__select mvp-release; printf "%s|%s" "$MODEL_ROUTER_MODEL" "$MODEL_ROUTER_EFFORT"'
  [ "$status" -eq 0 ]
  [ "$output" = "claude-opus-4-8|high" ]
}

@test "CLAUDEOS_MODEL_EFFORT: taskEffort より優先して強制上書きする" {
  printf '{ "modelRouter": { "taskEffort": { "monitor": "high" } } }\n' > "$TEST_TEMP/te-force.json"
  run env AI_STARTUP_CONFIG_PATH="$TEST_TEMP/te-force.json" CLAUDEOS_MODEL_EFFORT=low bash -c 'source "'"$ROUTER"'"; model_router__select monitor; printf "%s|%s" "$MODEL_ROUTER_EFFORT" "$MODEL_ROUTER_REASON"'
  [ "$status" -eq 0 ]
  [[ "$output" == "low|"*"+effort:forced" ]]
}

@test "CLAUDEOS_MODEL_EFFORT: 不正値は無視して既定を維持する" {
  run env CLAUDEOS_MODEL_EFFORT=turbo bash -c 'source "'"$ROUTER"'"; model_router__select normal; printf "%s" "$MODEL_ROUTER_EFFORT"'
  [ "$status" -eq 0 ]
  [ "$output" = "max" ]
}

@test "CLAUDEOS_MODEL_EFFORT: 不正値は未設定扱いで taskEffort へフォールバックする" {
  printf '{ "modelRouter": { "taskEffort": { "monitor": "high" } } }\n' > "$TEST_TEMP/te-fallback.json"
  run env AI_STARTUP_CONFIG_PATH="$TEST_TEMP/te-fallback.json" CLAUDEOS_MODEL_EFFORT=turbo bash -c 'source "'"$ROUTER"'"; model_router__select monitor; printf "%s|%s" "$MODEL_ROUTER_EFFORT" "$MODEL_ROUTER_REASON"'
  [ "$status" -eq 0 ]
  [[ "$output" == "high|"*"+effort:task(monitor)" ]]
}

@test "taskEffort: 大文字混じり task (Monitor) にも case-insensitive で一致する" {
  printf '{ "modelRouter": { "taskEffort": { "monitor": "high" } } }\n' > "$TEST_TEMP/te-case.json"
  run env AI_STARTUP_CONFIG_PATH="$TEST_TEMP/te-case.json" bash -c 'source "'"$ROUTER"'"; model_router__select Monitor; printf "%s|%s" "$MODEL_ROUTER_EFFORT" "$MODEL_ROUTER_REASON"'
  [ "$status" -eq 0 ]
  [[ "$output" == "high|"*"+effort:task(monitor)" ]]
}

@test "taskEffort: 大文字の effort 値 (High) も小文字正規化して受理する" {
  printf '{ "modelRouter": { "taskEffort": { "monitor": "High" } } }\n' > "$TEST_TEMP/te-vcase.json"
  run env AI_STARTUP_CONFIG_PATH="$TEST_TEMP/te-vcase.json" bash -c 'source "'"$ROUTER"'"; model_router__select monitor; printf "%s" "$MODEL_ROUTER_EFFORT"'
  [ "$status" -eq 0 ]
  [ "$output" = "high" ]
}

@test "CLAUDEOS_MODEL_EFFORT: 大文字値 (HIGH) も小文字正規化して受理する" {
  run env CLAUDEOS_MODEL_EFFORT=HIGH bash -c 'source "'"$ROUTER"'"; model_router__select normal; printf "%s|%s" "$MODEL_ROUTER_EFFORT" "$MODEL_ROUTER_REASON"'
  [ "$status" -eq 0 ]
  [[ "$output" == "high|"*"+effort:forced" ]]
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
