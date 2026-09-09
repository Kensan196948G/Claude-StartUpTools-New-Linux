#!/usr/bin/env bats
# ============================================================
# managed-session-payload.bats — Managed Agents P0 統合 (CLI) テスト
#
# 検証観点 (v11 P0 要件 6/10):
#   - payload builder CLI が budget 必須化を強制する (BUDGET_REQUIRED → exit 3)
#   - 契約不成立 config は payload 生成を拒否する (exit 2)
#   - dry-run 契約 config から公式形式の POST /v1/sessions body を生成する
#   - 2 段階ライフサイクル ② (user.message) / tool_confirmation イベントの構築
#   - 副作用なし (ネットワーク呼び出しなし = dry-run の定義)
# ============================================================

load '../helpers/common-setup'

setup() {
  _bats_common_setup
  PAYLOAD="$REPO_ROOT/scripts/tools/managed-session-payload.js"
  CFG="$TEST_TEMP/managed-agents.json"
  # fixture: 契約充足 (dry-run) config
  cat > "$CFG" <<'JSON'
{
  "enabled": true,
  "mode": "dry-run",
  "environmentId": "env_01TESTTESTTESTTEST",
  "orchestratorId": "agent_01ORCHORCHORCHORCH",
  "vaultIds": ["vlt_01VAULTVAULTVAULT"],
  "budget": { "amountCents": "500", "currency": "USD" },
  "inferenceGeo": "global",
  "github": {
    "workspace": { "type": "repository_resource", "resource": "repo:org/repo", "mountPath": "/workspace/repo" },
    "mcp": { "url": "https://api.githubcopilot.com/mcp",
             "allowedTools": ["create_pull_request"],
             "blockedTools": ["get_file_contents", "delete_file"] }
  },
  "permissionPolicy": { "extraAllow": [], "extraHumanGate": [] }
}
JSON
}

teardown() { _bats_common_teardown; }

@test "integration: dry-run 契約 config から budget 付き payload を生成する" {
  run node "$PAYLOAD" session-create --config "$CFG"
  [ "$status" -eq 0 ]
  local p; p="$(printf '%s' "$output" | jq -c '.payload')"
  [ "$(printf '%s' "$p" | jq -r '.agent')" = "agent_01ORCHORCHORCHORCH" ]
  [ "$(printf '%s' "$p" | jq -r '.environment_id')" = "env_01TESTTESTTESTTEST" ]
  [ "$(printf '%s' "$p" | jq -r '.budget.type')" = "limit" ]
  [ "$(printf '%s' "$p" | jq -r '.budget.max_list_cost.amount')" = "500" ]
  [ "$(printf '%s' "$p" | jq -r '.budget.max_list_cost.currency')" = "USD" ]
  [ "$(printf '%s' "$output" | jq -r '.meta.github_primary')" = "repository_resource" ]
  [ "$(printf '%s' "$output" | jq -r '.meta.mcp_blocked_tools[0]')" = "get_file_contents" ]
}

@test "integration: budget 無し config は BUDGET_REQUIRED (exit 3) で拒否する" {
  local f="$TEST_TEMP/no-budget.json"
  jq 'del(.budget)' "$CFG" > "$f"
  run node "$PAYLOAD" session-create --config "$f"
  [ "$status" -eq 3 ]
  [[ "$output" == *'"error":"BUDGET_REQUIRED"'* ]]
}

@test "integration: budget 上書き (--budget-cents 250) は config より優先する" {
  run node "$PAYLOAD" session-create --config "$CFG" --budget-cents 250
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.payload.budget.max_list_cost.amount')" = "250" ]
}

@test "integration: enabled=false / mode=disabled / プレースホルダ ID は exit 2 で拒否する" {
  local f
  f="$TEST_TEMP/disabled.json"; jq '.enabled = false' "$CFG" > "$f"
  run node "$PAYLOAD" session-create --config "$f"; [ "$status" -eq 2 ]
  f="$TEST_TEMP/mode-disabled.json"; jq '.mode = "disabled"' "$CFG" > "$f"
  run node "$PAYLOAD" session-create --config "$f"; [ "$status" -eq 2 ]
  f="$TEST_TEMP/placeholder.json"; jq '.orchestratorId = "agent_xxxxxxxxxxxxxxxxxxxxxxxx"' "$CFG" > "$f"
  run node "$PAYLOAD" session-create --config "$f"; [ "$status" -eq 2 ]
  f="$TEST_TEMP/placeholder-env.json"; jq '.environmentId = "env_xxxxxxxxxxxxxxxxxxxxxxxx"' "$CFG" > "$f"
  run node "$PAYLOAD" session-create --config "$f"; [ "$status" -eq 2 ]
}

@test "integration: 配布テンプレート (既定値) は payload 生成不可 (disabled のため local フォールバック対象)" {
  run node "$PAYLOAD" session-create --config "$REPO_ROOT/config/managed-agents.json.template"
  [ "$status" -eq 2 ]
  [[ "$output" == *'"error":"MODE_DISABLED"'* ]]
}

@test "integration: user.message / tool_confirmation イベントを公式形式で構築する" {
  run node "$PAYLOAD" message-event --text '受け入れテスト①: README.md を読んで 3 行で要約'
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.events[0].type')" = "user.message" ]
  [ "$(printf '%s' "$output" | jq -r '.events[0].content[0].type')" = "text" ]

  run node "$PAYLOAD" tool-confirmation --tool-use-id sevt_01X --result allow
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.events[0].type')" = "user.tool_confirmation" ]
  [ "$(printf '%s' "$output" | jq -r '.events[0].result')" = "allow" ]

  run node "$PAYLOAD" tool-confirmation --tool-use-id sevt_01X --result maybe
  [ "$status" -eq 2 ]
  [[ "$output" == *'"error":"CONFIRMATION_RESULT_INVALID"'* ]]
}
