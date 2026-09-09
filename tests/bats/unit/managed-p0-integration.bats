#!/usr/bin/env bats
# ============================================================
# managed-p0-integration.bats — ClaudeOS v11 P0 統合 dry-run チェーン
#
# 検証観点 (品質 Gate: fallback 動作確認 + 設定 schema 検証の統合):
#   Goal Router evidence → route (execution_plane) → payload builder → budget 必須
#   の P0 ワイヤリングを 1 本のチェーンで確認する。
#   Thin Adapter (lib/managed-agents.sh) が存在する場合は契約充足時の
#   managed 判定も確認し、不在時は fail-safe local を確認する。
# ============================================================

load '../helpers/common-setup'

setup() {
  _bats_common_setup
  PAYLOAD="$REPO_ROOT/scripts/tools/managed-session-payload.js"
  PROJ="$TEST_TEMP/proj"; mkdir -p "$PROJ"
  unset CLAUDEOS_MANAGED_AGENTS_CONFIG CLAUDEOS_EXECUTION_PLANE
  source "$REPO_ROOT/lib/goal-router.sh"
}

teardown() { _bats_common_teardown; }

_field() { printf '%s\n' "$1" | sed -n "s/^$2=//p"; }

@test "P0 chain: adapter が無くても evidence→route は fail-safe local を出す" {
  out="$(goal_router__evidence "$PROJ" '')"
  [ "$(_field "$out" execution_plane)" = "local" ]
  res="$(printf '%s\n' "$out" | goal_router__route --goal development)"
  [ "$(_field "$res" execution_plane)" = "local" ]
  [ "$(_field "$res" fallback)" = "0" ]
}

@test "P0 chain: 設定契約 + payload builder は budget 必須を強制する (dry-run でも)" {
  cat > "$TEST_TEMP/contract.json" <<'JSON'
{ "enabled": true, "mode": "dry-run",
  "environmentId": "env_01ITITITITITIT", "orchestratorId": "agent_01ITORCHORCH",
  "budget": { "amountCents": "500", "currency": "USD" } }
JSON
  # budget 付き → payload 生成成功
  run node "$PAYLOAD" session-create --config "$TEST_TEMP/contract.json"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.payload.budget.max_list_cost.amount')" = "500" ]
  # budget 無し → BUDGET_REQUIRED で拒否 (後付け不可)
  jq 'del(.budget)' "$TEST_TEMP/contract.json" > "$TEST_TEMP/nobudget.json"
  run node "$PAYLOAD" session-create --config "$TEST_TEMP/nobudget.json"
  [ "$status" -eq 3 ]
  [[ "$output" == *'"error":"BUDGET_REQUIRED"'* ]]
}

@test "P0 chain: 配布テンプレート既定値は local フォールバック対象 (mode=disabled)" {
  [ "$(python3 -c "import json;print(json.load(open('$REPO_ROOT/config/managed-agents.json.template'))['mode'])")" = "disabled" ]
  [ "$(python3 -c "import json;print(json.load(open('$REPO_ROOT/config/managed-agents.json.template'))['enabled'])")" = "False" ]
  run node "$PAYLOAD" session-create --config "$REPO_ROOT/config/managed-agents.json.template"
  [ "$status" -eq 2 ]   # payload 生成不可 = Goal Router が local へ落とす契約
}

@test "P0 chain: managed 契約を満たす evidence は route 出力で managed になる" {
  res="$(printf 'execution_plane=managed\nma_mode=dry-run\nma_reason=managed-ok\n' | goal_router__route --goal development)"
  [ "$(_field "$res" execution_plane)" = "managed" ]
  [ "$(_field "$res" ma_mode)" = "dry-run" ]
  # persist まで含めて state への記録を確認
  printf '{"project":{"phase_mode":"development"}}' > "$PROJ/state.json"
  GOAL_ROUTER_PRIMARY=development GOAL_ROUTER_EFFECTIVE=development GOAL_ROUTER_CONFIDENCE=1 \
  GOAL_ROUTER_EXECUTION_PLANE=managed goal_router__persist "$PROJ/state.json"
  [ "$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['goal_router']['execution_plane'])" "$PROJ/state.json")" = "managed" ]
}
