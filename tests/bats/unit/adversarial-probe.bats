#!/usr/bin/env bats
# ============================================================
# adversarial-probe.bats — 攻撃耐性テストハーネス自体の検証
# ハーネスが「本番状態を汚さず」「FAIL を実際に検出できる」ことを固定する。
# ============================================================

load '../helpers/common-setup'

setup() {
  _bats_common_setup
  export CLAUDEOS_HOME="$TEST_TEMP/claudeos"
  mkdir -p "$CLAUDEOS_HOME/logs"
  export CCSU_ADV_WORKDIR="$TEST_TEMP/adv"
  SCRIPT="$REPO_ROOT/bin/adversarial-probe.sh"
  CORPUS="$REPO_ROOT/tests/adversarial/corpus.json"
}

teardown() { _bats_common_teardown; }

@test "adversarial-probe: コーパス全件が PASS する" {
  run bash "$SCRIPT" run
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS"* ]]
  run bash "$SCRIPT" run --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.result')" = "PASS" ]
  [ "$(printf '%s' "$output" | jq -r '.failed')" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.total')" -ge 18 ]
  [ "$(printf '%s' "$output" | jq -r '.passed')" -eq "$(printf '%s' "$output" | jq -r '.total')" ]
}

@test "adversarial-probe: 本番状態を汚さずサンドボックス内で実行する" {
  bash "$SCRIPT" run >/dev/null
  # 本番 (CLAUDEOS_HOME) には監査ログも鍵も作られない
  [ ! -f "$CLAUDEOS_HOME/logs/policy-audit.jsonl" ]
  [ ! -f "$CLAUDEOS_HOME/policy/identity.key" ]
  # サンドボックス側には作られる
  [ -f "$CCSU_ADV_WORKDIR/logs/policy-audit.jsonl" ]
  [ -f "$CCSU_ADV_WORKDIR/policy/identity.key" ]
  [ "$(stat -c %a "$CCSU_ADV_WORKDIR/policy/identity.key")" = "600" ]
}

@test "adversarial-probe: 全ケースに id / class / expect / why が揃い id は一意" {
  [ "$(jq -r '.schema' "$CORPUS")" = "claudeos.adversarial-corpus/v1" ]
  [ "$(jq '[.cases[].id] | length' "$CORPUS")" -eq "$(jq '[.cases[].id] | unique | length' "$CORPUS")" ]
  [ "$(jq '[.cases[] | select((.expect|length)==0)] | length' "$CORPUS")" -eq 0 ]
  [ "$(jq '[.cases[] | select(.why == null or .why == "")] | length' "$CORPUS")" -eq 0 ]
  [ "$(jq '[.cases[].class] | unique | length' "$CORPUS")" -ge 6 ]
}

@test "adversarial-probe: --case / --class で絞り込める" {
  run bash "$SCRIPT" run --case policy-bypass-002 --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.total')" -eq 1 ]
  [ "$(printf '%s' "$output" | jq -r '.cases[0].id')" = "policy-bypass-002" ]
  run bash "$SCRIPT" run --class token_forgery --json
  [ "$(printf '%s' "$output" | jq -r '.total')" -eq 3 ]
  [ "$(printf '%s' "$output" | jq -r '[.cases[].class] | unique | length')" -eq 1 ]
}

@test "adversarial-probe: list がケース一覧を返す" {
  run bash "$SCRIPT" list
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | grep -c .)" -ge 18 ]
  [[ "$output" == *"policy-bypass-001"* ]]
}

@test "adversarial-probe: 期待値が壊れた corpus では FAIL を検出する (検出力の証明)" {
  broken="$TEST_TEMP/broken-corpus.json"
  jq '.cases = [.cases[] | select(.id=="policy-bypass-001") | .expect = {"decision":"allow","rc":0}]' \
    "$CORPUS" > "$broken"
  run env CCSU_ADVERSARIAL_CORPUS="$broken" bash "$SCRIPT" run
  [ "$status" -eq 1 ]
  [[ "$output" == *FAIL* ]]
  run env CCSU_ADVERSARIAL_CORPUS="$broken" bash "$SCRIPT" run --json
  # FAIL 時のログは stderr に出るため、JSON は最終行から取る
  json_line="$(printf '%s' "$output" | tail -n1)"
  [ "$(printf '%s' "$json_line" | jq -r '.failed')" -eq 1 ]
  [ "$(printf '%s' "$json_line" | jq -r '.cases[0].actual.decision')" = "deny" ]
}

@test "adversarial-probe: レポートをファイルへ残せる" {
  out="$TEST_TEMP/adv-report.json"
  bash "$SCRIPT" run --out "$out" >/dev/null
  [ -f "$out" ]
  [ "$(jq -r '.schema' "$out")" = "claudeos.adversarial-report/v1" ]
  [ "$(jq -r '.failed' "$out")" -eq 0 ]
  [ "$(jq -r '[.cases[] | select(.result=="PASS")] | length' "$out")" -eq "$(jq -r '.total' "$out")" ]
  # 実行ごとに新しいレポートが生成される (上書きで履歴を失わない設計は呼び出し側の責務)
  [ "$(jq -r '.generated_at' "$out")" != "" ]
}
