#!/usr/bin/env bats
# ============================================================
# managed-agents.bats — lib/managed-agents.sh と bin/managed-agents.sh
#
# 検証観点:
#   - Goal Router 契約 (ma__load / ma__validate / MA_MODE / MA_REASON) が副作用なしで動く
#   - Local 主系: 設定が有効でもセッション全体の execution_plane は local のまま
#   - CLI は設定なし・API キーなしで安全に停止し、秘密を出力しない (T01 / T02 / T11 / T12)
#   - ネットワークには一切出ない (mode=disabled / dry-run のみ使用)
# ============================================================

load '../helpers/common-setup'

setup() {
  _bats_common_setup
  BIN="$REPO_ROOT/bin/managed-agents.sh"
  CFG="$TEST_TEMP/managed-agents.json"
  export CLAUDEOS_MANAGED_AGENTS_CONFIG="$CFG"
  export CLAUDEOS_MA_STATE_DIR="$TEST_TEMP/state"
  unset ANTHROPIC_API_KEY CLAUDEOS_MA_GITHUB_TOKEN
  unset _CCSU_MANAGED_AGENTS_LOADED
  source "$REPO_ROOT/lib/managed-agents.sh"
}

teardown() { _bats_common_teardown; }

_write_cfg() {
  # $1=enabled $2=mode
  cat > "$CFG" <<JSON
{ "enabled": $1, "mode": "$2",
  "environmentId": "env_01BATSBATSBATS",
  "agents": { "repository-review": { "id": "agent_01BATSREVIEW", "version": 2 } },
  "budget": { "amountCents": "200", "currency": "USD" },
  "budgetPolicy": {} }
JSON
}

_field() { printf '%s\n' "$1" | sed -n "s/^$2=//p"; }

# ---------- lib: Goal Router 契約 ----------

@test "ma__load: 設定ファイルが無ければ MA_MODE=missing (副作用なし)" {
  ma__load
  [ "$MA_MODE" = "missing" ]
  [ "$MA_REASON" = "config-missing" ]
  [ ! -e "$CLAUDEOS_MA_STATE_DIR" ]
}

@test "ma__load: 配布テンプレートは disabled / not-enabled" {
  cp "$REPO_ROOT/config/managed-agents.json.template" "$CFG"
  ma__load
  [ "$MA_MODE" = "disabled" ]
  [ "$MA_ENABLED" = "false" ]
  [ "$MA_REASON" = "not-enabled" ]
  run ma__available
  [ "$status" -ne 0 ]
}

@test "ma__load: enabled=true でも mode=disabled なら利用不可" {
  _write_cfg true disabled
  ma__load
  [ "$MA_REASON" = "mode-disabled" ]
  run ma__available
  [ "$status" -ne 0 ]
}

@test "ma__load: 不正な mode / 壊れた JSON は invalid として安全側" {
  _write_cfg true turbo
  ma__load
  [ "$MA_MODE" = "invalid" ]
  printf '{ broken' > "$CFG"
  ma__load
  [ "$MA_MODE" = "invalid" ]
  [ "$MA_REASON" = "config-unreadable" ]
  run ma__available
  [ "$status" -ne 0 ]
}

@test "ma__available: enabled + dry-run / live は補完先として利用可能" {
  _write_cfg true dry-run
  ma__load
  ma__available
  [ "$MA_REASON" = "local-primary:managed-complement-dry-run" ]
  _write_cfg true live
  ma__load
  ma__available
  [ "$MA_MODE" = "live" ]
}

@test "ma__validate: Local 主系のため、設定が有効でも常に非 0 (セッション全体を Managed にしない)" {
  _write_cfg true live
  ma__load
  run ma__validate
  [ "$status" -ne 0 ]
}

@test "ma__load: API キーが環境にあっても読まない・出力しない" {
  _write_cfg true live
  export ANTHROPIC_API_KEY="sk-ant-api03-BATSKEYBATSKEYBATSKEY00"
  run bash -c "source '$REPO_ROOT/lib/managed-agents.sh'; ma__load; declare -p MA_MODE MA_REASON MA_ENABLED MA_CONFIG_PATH"
  [ "$status" -eq 0 ]
  [[ "$output" != *"BATSKEY"* ]]
}

# ---------- Goal Router 統合 ----------

@test "Goal Router: adapter があり設定が有効でも execution_plane は local、ma_mode / ma_reason で補完可否を伝える" {
  _write_cfg true dry-run
  PROJ="$TEST_TEMP/proj"; mkdir -p "$PROJ"
  unset _CCSU_MANAGED_AGENTS_LOADED
  source "$REPO_ROOT/lib/goal-router.sh"
  out="$(goal_router__evidence "$PROJ" '')"
  [ "$(_field "$out" execution_plane)" = "local" ]
  [ "$(_field "$out" ma_mode)" = "dry-run" ]
  [ "$(_field "$out" ma_reason)" = "local-primary:managed-complement-dry-run" ]
  res="$(printf '%s\n' "$out" | goal_router__route --goal development)"
  [ "$(_field "$res" execution_plane)" = "local" ]
}

@test "Goal Router: 設定なしでは execution_plane=local / ma_mode=missing" {
  PROJ="$TEST_TEMP/proj"; mkdir -p "$PROJ"
  unset _CCSU_MANAGED_AGENTS_LOADED
  source "$REPO_ROOT/lib/goal-router.sh"
  out="$(goal_router__evidence "$PROJ" '')"
  [ "$(_field "$out" execution_plane)" = "local" ]
  [ "$(_field "$out" ma_mode)" = "missing" ]
}

# ---------- CLI ----------

@test "CLI: 引数なし / --help は使い方を表示して 0" {
  run bash "$BIN"
  [ "$status" -eq 0 ]
  [[ "$output" == *"managed-agents.sh status"* ]]
  run bash "$BIN" --help
  [ "$status" -eq 0 ]
}

@test "T01 CLI status: 設定なしでも成功し usable=false / mode=missing を返す" {
  run bash "$BIN" status
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.mode')" = "missing" ]
  [ "$(printf '%s' "$output" | jq -r '.usable')" = "false" ]
  [ "$(printf '%s' "$output" | jq -r '.agents | length')" = "3" ]
  [ "$(printf '%s' "$output" | jq -r '.budget.policy.monthlyBudgetCents')" = "2000" ]
}

@test "T02 CLI: API キー未設定の live セッション作成は終了コード 2 で安全に停止し、台帳を作らない" {
  _write_cfg true live
  run bash "$BIN" session create --task-id bats-1 --role repository-review --task-type review --prompt "check"
  [ "$status" -eq 2 ]
  [[ "$output" == *'"code":"API_KEY_MISSING"'* ]]
  [[ "$output" == *'"to":"local"'* ]]
  [ ! -f "$CLAUDEOS_MA_STATE_DIR/ledger.jsonl" ]
}

@test "T02 CLI: mode=disabled ではセッション作成を拒否 (終了コード 2)" {
  _write_cfg true disabled
  run bash "$BIN" session create --task-id bats-2 --role repository-review --task-type review --prompt "check"
  [ "$status" -eq 2 ]
  [[ "$output" == *'"code":"MANAGED_UNAVAILABLE"'* ]]
}

@test "T03 CLI dry-run: 送信予定の request に budget.max_list_cost が入り、API キーは値ではなく参照で表示される" {
  _write_cfg true dry-run
  export ANTHROPIC_API_KEY="sk-ant-api03-BATSKEYBATSKEYBATSKEY00"
  run bash "$BIN" session create --task-id bats-3 --role repository-review --task-type review --prompt "README を確認" --budget-cents 150
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.executed')" = "false" ]
  [ "$(printf '%s' "$output" | jq -r '.request.body.budget.max_list_cost.amount')" = "150" ]
  [ "$(printf '%s' "$output" | jq -r '.request.body.budget.max_list_cost.currency')" = "USD" ]
  [ "$(printf '%s' "$output" | jq -r '.request.headers["x-api-key"]')" = "<env:ANTHROPIC_API_KEY>" ]
  [[ "$output" != *"BATSKEY"* ]]
  [ ! -f "$CLAUDEOS_MA_STATE_DIR/ledger.jsonl" ]
}

@test "T03 CLI: セッション上限 (2 USD) を超える予算は終了コード 3 で拒否" {
  _write_cfg true dry-run
  run bash "$BIN" session create --task-id bats-4 --role repository-review --task-type review --prompt "x" --budget-cents 500
  [ "$status" -eq 3 ]
  [[ "$output" == *'"code":"BUDGET_SESSION_CAP_EXCEEDED"'* ]]
}

@test "T11 CLI: ma__cli は allowlist 以外の環境変数 (SMTP 等の秘密) を node へ渡さない" {
  export SMTP_PASSWORD="smtp-secret-value" GITHUB_TOKEN="ghp_shouldnotleak0000000000"
  make_stub_bin node 'env'
  run ma__cli status
  [ "$status" -eq 0 ]
  [[ "$output" != *"smtp-secret-value"* ]]
  [[ "$output" != *"ghp_shouldnotleak"* ]]
  [[ "$output" == *"CLAUDEOS_MANAGED_AGENTS_CONFIG="* ]]
}

@test "T12 CLI route: 設定なしでも Local の実行先を返し、Managed は選ばれない" {
  run bash "$BIN" route --json '{"task_type":"review","risk":"low","read_only":true,"files_affected":10,"managed":{"requested":true,"data_sensitivity":"internal","human_gate":false,"requires_secrets":false,"requires_external_network":false}}'
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.execution')" = "Subagent" ]
  [ "$(printf '%s' "$output" | jq -r '.managed.selected')" = "false" ]
  [ "$(printf '%s' "$output" | jq -r '.managed.policy_denied')" = "false" ]
}

@test "T10 CLI route: dry-run で有効でも本番影響のあるタスクは Managed にしない" {
  _write_cfg true dry-run
  run bash "$BIN" route --json '{"task_type":"review","risk":"low","read_only":true,"deployment_impact":"high","managed":{"requested":true,"local_available":false,"data_sensitivity":"internal","human_gate":false,"requires_secrets":false,"requires_external_network":false}}'
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.execution')" != "ManagedAgent" ]
  [ "$(printf '%s' "$output" | jq -r '.managed.policy_denied')" = "true" ]
}

@test "CLI route: dry-run + 明示要求の低リスク読取専用タスクは ManagedAgent になり、決定が記録される" {
  _write_cfg true dry-run
  run bash "$BIN" route --task-id bats-route-1 --json '{"task_type":"docs","risk":"low","read_only":true,"files_affected":12,"managed":{"requested":true,"data_sensitivity":"internal","human_gate":false,"requires_secrets":false,"requires_external_network":false}}'
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.execution')" = "ManagedAgent" ]
  [ "$(jq -r '.task_id' "$CLAUDEOS_MA_STATE_DIR/decisions.jsonl")" = "bats-route-1" ]
}

@test "CLI budget status: 台帳が無くても集計を返し、Agent SDK 台帳とは別であることを示す" {
  run bash "$BIN" budget status
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.stage')" = "ok" ]
  [ "$(printf '%s' "$output" | jq -r '.committed_month_cents')" = "0" ]
  [[ "$(printf '%s' "$output" | jq -r '.ledger_path')" == "$CLAUDEOS_MA_STATE_DIR/ledger.jsonl" ]]
}

@test "既存設定を上書きしない: config.json.template の agentSdk.monthlyBudgetUsd は Managed 用予算と独立" {
  [ "$(jq -r '.agentSdk.monthlyBudgetUsd' "$REPO_ROOT/config/config.json.template")" = "300" ]
  [ "$(jq -r '.budgetPolicy.monthlyBudgetCents' "$REPO_ROOT/config/managed-agents.json.template")" = "2000" ]
  # adapter・予算ガード・lib のどれも agentSdk 設定と Agent SDK 台帳 (credits) を参照しない
  #   (コメント行は説明のため除外し、実行されるコード行だけを見る)
  local f
  for f in scripts/tools/managed-agents.js scripts/tools/managed-budget.js lib/managed-agents.sh bin/managed-agents.sh; do
    run bash -c "grep -v -E '^[[:space:]]*(//|#)' '$REPO_ROOT/$f' | grep -E 'agentSdk|credits/ledger|credits__'"
    [ "$status" -ne 0 ]
  done
}

@test "CLI: 値の無いオプション・不明なオプションは終了コード 2 (既定値で実行しない)" {
  _write_cfg true dry-run
  run bash "$BIN" session create --task-id bats-5 --role repository-review --task-type review --prompt x --budget-cents
  [ "$status" -eq 2 ]
  [[ "$output" == *'"code":"OPTION_VALUE_REQUIRED"'* ]]
  run bash "$BIN" status --no-such-option
  [ "$status" -eq 2 ]
}

@test "T09 CLI: 対象外のタスク種別・種別なしのセッション作成は終了コード 7 (ポリシー拒否)" {
  _write_cfg true dry-run
  run bash "$BIN" session create --task-id bats-6 --role repository-review --task-type deploy --prompt x
  [ "$status" -eq 7 ]
  [[ "$output" == *'"code":"TASK_TYPE_NOT_ALLOWED"'* ]]
  run bash "$BIN" session create --task-id bats-7 --role repository-review --prompt x
  [ "$status" -eq 7 ]
}

@test "T10 CLI route: 安全条件を明示しない要求・不明値は Managed にしない (fail-closed)" {
  _write_cfg true dry-run
  run bash "$BIN" route --json '{"task_type":"review","risk":"low","read_only":true,"managed":{"requested":true}}'
  [ "$(printf '%s' "$output" | jq -r '.execution')" != "ManagedAgent" ]
  run bash "$BIN" route --json '{"task_type":"review","risk":"low","read_only":true,"security_impact":"severe","managed":{"requested":true,"data_sensitivity":"internal","human_gate":false,"requires_secrets":false,"requires_external_network":false}}'
  [ "$(printf '%s' "$output" | jq -r '.execution')" != "ManagedAgent" ]
  [ "$(printf '%s' "$output" | jq -r '.managed.policy_denied')" = "true" ]
}

@test "T11 設定の tokenEnv は CLAUDEOS_MA_ 接頭辞のみ。ma__cli はその接頭辞の変数を node へ渡す" {
  export CLAUDEOS_MA_CUSTOM_PAT="custom-token-value"
  make_stub_bin node 'env'
  run ma__cli status
  [[ "$output" == *"CLAUDEOS_MA_CUSTOM_PAT=custom-token-value"* ]]
}

@test "ma__cli: set -u かつ HOME 未設定でも落ちない" {
  make_stub_bin node 'echo ok'
  run bash -c "set -u; unset HOME; source '$REPO_ROOT/lib/managed-agents.sh'; ma__cli status"
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "Linux 専用: adapter / lib / bin に SSH・PowerShell・Windows 起動経路が無い" {
  run grep -n -i -E 'powershell|pwsh|\.ps1|ssh [a-z]|cmd\.exe' "$REPO_ROOT/scripts/tools/managed-agents.js" "$REPO_ROOT/scripts/tools/managed-budget.js" "$REPO_ROOT/lib/managed-agents.sh" "$REPO_ROOT/bin/managed-agents.sh"
  [ "$status" -ne 0 ]
}
