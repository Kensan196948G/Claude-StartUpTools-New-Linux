#!/usr/bin/env bats
# ============================================================
# private-ai.bats — ローカル隔離推論のテスト
# 「loopback 限定」「allowlist 限定」「環境変数を子へ継承しない」を固定する。
# ============================================================

load '../helpers/common-setup'

setup() {
  _bats_common_setup
  export CLAUDEOS_HOME="$TEST_TEMP/claudeos"
  export CLAUDEOS_PRIVATE_AI_LOG="$TEST_TEMP/logs/private-ai.jsonl"
  mkdir -p "$CLAUDEOS_HOME/logs" "$TEST_TEMP/logs"
  # 本番 config をコピーしてテスト用に調整 (host は差し替え可能にする)
  PA_CFG="$TEST_TEMP/private-ai.json"
  jq --arg log "$CLAUDEOS_PRIVATE_AI_LOG" '.log_file = $log' "$REPO_ROOT/config/private-ai.json" > "$PA_CFG"
  export CLAUDEOS_PRIVATE_AI_CONFIG="$PA_CFG"
  SCRIPT="$REPO_ROOT/bin/private-ai.sh"

  # ollama のスタブ: list は 1 モデルを返し、run は受け取った環境と入力を表示する
  make_stub_bin ollama 'if [[ "$1" == "list" ]]; then echo "NAME ID SIZE"; echo "qwen2.5:0.5b abc 400MB"; exit 0; fi
if [[ "$1" == "run" ]]; then echo "MODEL=$2"; echo "HOST=${OLLAMA_HOST:-<none>}"; echo "LEAKED=${OPENROUTER_API_KEY:-<none>}"; echo "PROXY=${HTTP_PROXY:-<none>}"; cat; exit 0; fi
exit 1'

  printf 'ローカルだけで処理したい内容\n' > "$TEST_TEMP/prompt.txt"
}

teardown() { _bats_common_teardown; }

@test "private-ai: check は導入状況を報告する (loopback allowlist を確認)" {
  run bash "$SCRIPT" check
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.host')" = "127.0.0.1:11434" ]
  [ "$(printf '%s' "$output" | jq -r '.host_is_loopback_allowlisted')" = "true" ]
  [ "$(printf '%s' "$output" | jq -r '.runnable')" = "true" ]
  [ "$(printf '%s' "$output" | jq -r '.installed_models[0]')" = "qwen2.5:0.5b" ]
}

@test "private-ai: run は最小環境で実行し、クラウドのトークンを子へ渡さない" {
  run env OPENROUTER_API_KEY=must-not-leak HTTP_PROXY=http://proxy.example bash "$SCRIPT" run --model qwen2.5:0.5b --prompt-file "$TEST_TEMP/prompt.txt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"MODEL=qwen2.5:0.5b"* ]]
  [[ "$output" == *"HOST=127.0.0.1:11434"* ]]
  [[ "$output" == *"LEAKED=<none>"* ]]
  [[ "$output" == *"PROXY=<none>"* ]]
  [[ "$output" == *"ローカルだけで処理したい内容"* ]]
}

@test "private-ai: allowlist 外のモデルは拒否する (rc=3)" {
  run bash "$SCRIPT" run --model llama3.1:70b --prompt-file "$TEST_TEMP/prompt.txt"
  [ "$status" -eq 3 ]
  [[ "$output" == *allowlist* ]]
}

@test "private-ai: loopback 以外のホストは拒否する (rc=3)" {
  jq '.host = "api.openai.com:443"' "$PA_CFG" > "$PA_CFG.tmp" && mv "$PA_CFG.tmp" "$PA_CFG"
  run bash "$SCRIPT" check
  [ "$status" -ne 0 ]
  [ "$(printf '%s' "$output" | jq -r '.host_is_loopback_allowlisted')" = "false" ]
  run bash "$SCRIPT" run --model qwen2.5:0.5b --prompt-file "$TEST_TEMP/prompt.txt"
  [ "$status" -eq 3 ]
  [[ "$output" == *"許可されていないホスト"* ]]
}

@test "private-ai: ollama が無ければ実行せず rc=3" {
  # スタブも実体も見つからない PATH にする (実体の有無に依存しないテスト)
  mkdir -p "$TEST_TEMP/emptybin"
  run env PATH="$TEST_TEMP/emptybin:/usr/bin:/bin" bash "$SCRIPT" run --model qwen2.5:0.5b --prompt-file "$TEST_TEMP/prompt.txt"
  [ "$status" -eq 3 ]
  run env PATH="$TEST_TEMP/emptybin:/usr/bin:/bin" bash "$SCRIPT" check
  [ "$status" -ne 0 ]
  [ "$(printf '%s' "$output" | jq -r '.runnable')" = "false" ]
  [ "$(printf '%s' "$output" | jq -r '.ollama_present')" = "false" ]
}

@test "private-ai: 過大なプロンプトは拒否する (rc=2)" {
  head -c 40000 /dev/zero | tr '\0' 'a' > "$TEST_TEMP/big.txt"
  run bash "$SCRIPT" run --model qwen2.5:0.5b --prompt-file "$TEST_TEMP/big.txt"
  [ "$status" -eq 2 ]
  [[ "$output" == *大きすぎます* ]]
}

@test "private-ai: 実行を JSONL で記録する (何をどのモデルへ出したか)" {
  bash "$SCRIPT" run --model qwen2.5:0.5b --prompt-file "$TEST_TEMP/prompt.txt" >/dev/null
  run bash "$SCRIPT" usage
  [ "$status" -eq 0 ]
  line="$(printf '%s' "$output" | tail -n1)"
  [ "$(printf '%s' "$line" | jq -r '.event')" = "local_inference" ]
  [ "$(printf '%s' "$line" | jq -r '.model')" = "qwen2.5:0.5b" ]
  [ "$(printf '%s' "$line" | jq -r '.status')" = "ok" ]
  [ "$(printf '%s' "$line" | jq -r '.exit_code')" -eq 0 ]
}

@test "private-ai: --json は出力本文とメタ情報を返す" {
  run bash "$SCRIPT" run --model qwen2.5:0.5b --prompt-file "$TEST_TEMP/prompt.txt" --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.schema')" = "claudeos.private-ai-result/v1" ]
  [[ "$(printf '%s' "$output" | jq -r '.output')" == *"MODEL=qwen2.5:0.5b"* ]]
}
