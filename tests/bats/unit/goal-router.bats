#!/usr/bin/env bats
# ============================================================
# goal-router.bats — lib/goal-router.sh (統合 Goal Router) のユニットテスト
#
# 検証観点 (指示書 §24 Unit):
#   - explicit goal routing (--goal primary / specialized / auto / 不正値)
#   - user intent routing (§6.1 キーワード表)
#   - phase_mode routing / CI failure → deep-debug / Security Critical → security-emergency
#   - release state → product-assurance / production-release
#   - no evidence fallback / malformed state fail-safe / old state backward compatibility
#   - confidence output / routing lock (flapping 防止) / reroute 条件
#   - one-shot (cron override) は lock しない / disabled は従来 goal_type
#   - persist: state.goal_router のみ更新し他キー不変、schema に適合
# ============================================================

load '../helpers/common-setup'

setup() {
  _bats_common_setup
  export CLAUDEOS_GOAL_ROUTER_GH=0     # gh へ問い合わせない (密閉)
  unset CLAUDEOS_GOAL_INTENT CLAUDEOS_PRIMARY_GOAL CLAUDEOS_SPECIALIZED_GOAL CLAUDEOS_GOAL_REROUTE \
        CLAUDEOS_GOAL_ROUTER_DISABLE CLAUDEOS_GOAL_MODE CLAUDEOS_GOAL_LOCK_MINUTES
  PROJ="$TEST_TEMP/proj"; mkdir -p "$PROJ"
  source "$REPO_ROOT/lib/goal-router.sh"
}
teardown() { _bats_common_teardown; }

# _state <json> — state.json を書く
_state() { printf '%s' "$1" > "$PROJ/state.json"; }
# _route <evidence lines...> [-- route args] — evidence を stdin で渡して route し、key を取り出す
_route() {
  local -a ev=() args=()
  local seen=0 a
  for a in "$@"; do
    if [[ "$a" == "--" ]]; then seen=1; continue; fi
    (( seen )) && args+=("$a") || ev+=("$a")
  done
  printf '%s\n' "${ev[@]}" | goal_router__route "${args[@]}"
}
_field() { printf '%s\n' "$1" | sed -n "s/^$2=//p"; }
_gr() { python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['goal_router'].get(sys.argv[2]))" "$PROJ/state.json" "$1"; }

# ---- 分類ヘルパ ---------------------------------------------
@test "分類: Primary 5 分類と Specialized 6 種を識別する" {
  for g in development mvp-release assessment deep-debug product-assurance; do goal_router__is_primary "$g"; done
  for g in production-release hotfix security-emergency refactoring safe-auto-merge pr-babysit; do goal_router__is_specialized "$g"; done
  ! goal_router__is_goal unknown-goal
}
@test "分類: Specialized 単独指定は §5 の既定 Primary へ写像する" {
  [ "$(goal_router__primary_for hotfix)" = "deep-debug" ]
  [ "$(goal_router__primary_for refactoring)" = "development" ]
  [ "$(goal_router__primary_for pr-babysit)" = "product-assurance" ]
  [ "$(goal_router__primary_for production-release)" = "product-assurance" ]
}
@test "分類: Primary 配下で許可されない Specialized は拒否する" {
  goal_router__allows development refactoring
  goal_router__allows deep-debug security-emergency
  ! goal_router__allows mvp-release hotfix
  ! goal_router__allows assessment pr-babysit
}

# ---- explicit ------------------------------------------------
@test "explicit: --goal development は confidence 1.00 で採用" {
  out="$(_route state_present=1 phase_mode=development -- --goal development)"
  [ "$(_field "$out" primary)" = "development" ]
  [ "$(_field "$out" effective)" = "development" ]
  [ "$(_field "$out" confidence)" = "1.00" ]
  [[ "$(_field "$out" reason)" == explicit:* ]]
}
@test "explicit: --goal hotfix (Specialized) は Primary=deep-debug / effective=hotfix" {
  out="$(_route state_present=1 -- --goal hotfix)"
  [ "$(_field "$out" primary)" = "deep-debug" ]
  [ "$(_field "$out" specialized)" = "hotfix" ]
  [ "$(_field "$out" effective)" = "hotfix" ]
}
@test "explicit: 未知の --goal は fail-safe で auto 判定へ降格する" {
  out="$(_route state_present=1 phase_mode=maintenance -- --goal bogus)"
  [ "$(_field "$out" primary)" = "development" ]
  [[ "$(_field "$out" evidence)" == *"explicit_unknown:bogus"* ]]
}
@test "explicit: Security Critical は明示指定より優先し security-emergency へ昇格する" {
  out="$(_route state_present=1 security_critical=3 -- --goal assessment)"
  [ "$(_field "$out" primary)" = "assessment" ]
  [ "$(_field "$out" specialized)" = "security-emergency" ]
  [ "$(_field "$out" effective)" = "security-emergency" ]
  [[ "$(_field "$out" reason)" == security-critical-override:* ]]
}
@test "explicit: Security 昇格で Primary が security-emergency を許可しなければ deep-debug へ切替" {
  out="$(_route state_present=1 security_critical=1 -- --goal development)"
  [ "$(_field "$out" primary)" = "deep-debug" ]
  [ "$(_field "$out" specialized)" = "security-emergency" ]
}
@test "explicit: CLAUDEOS_PRIMARY_GOAL は one-shot の明示指定として働く" {
  CLAUDEOS_PRIMARY_GOAL=assessment out="$(_route state_present=1)"
  [ "$(_field "$out" primary)" = "assessment" ]
  [[ "$(_field "$out" reason)" == explicit-one-shot:* ]]
}

# ---- intent --------------------------------------------------
@test "intent: 「実装して」→ development" { [ "$(goal_router__intent_class 'ログイン画面を実装して')" = "development" ]; }
@test "intent: 「MVP / PoC」→ mvp-release" { [ "$(goal_router__intent_class 'まず MVP を作りたい')" = "mvp-release" ]; }
@test "intent: 「評価して / 監査」→ assessment" { [ "$(goal_router__intent_class '全体を評価して readiness を確認')" = "assessment" ]; }
@test "intent: 「CI 失敗 / 直して」→ deep-debug" { [ "$(goal_router__intent_class 'CI が失敗しているので直して')" = "deep-debug" ]; }
@test "intent: 「総合テスト / 品質保証」→ product-assurance" { [ "$(goal_router__intent_class 'リリース前の総合テストと品質保証')" = "product-assurance" ]; }
@test "intent: 「脆弱性 + 直して」→ deep-debug/security-emergency" { [ "$(goal_router__intent_class '脆弱性が見つかったので直して')" = "deep-debug security-emergency" ]; }
@test "intent: 「リファクタ」→ development/refactoring" { [ "$(goal_router__intent_class '技術的負債をリファクタしたい')" = "development refactoring" ]; }
@test "intent: 「本番リリース準備」→ product-assurance/production-release" { [ "$(goal_router__intent_class '本番リリース準備を進めて')" = "product-assurance production-release" ]; }
@test "intent: 競合時は §7 優先順位 (deep-debug > assessment > development)" {
  [ "$(goal_router__intent_class '評価して改善もして、バグも直して')" = "deep-debug" ]
}
@test "intent: 判定不能は空 (状態ベース判定へ委譲)" { [ -z "$(goal_router__intent_class 'こんにちは')" ]; }
@test "intent: route 経由で confidence 0.80 / evidence user_intent" {
  out="$(_route state_present=1 "intent=CI が失敗しているので直して")"
  [ "$(_field "$out" primary)" = "deep-debug" ]
  [ "$(_field "$out" confidence)" = "0.80" ]
  [[ "$(_field "$out" evidence)" == *"user_intent:deep-debug"* ]]
}

# ---- state / evidence ----------------------------------------
@test "state: security_critical>0 → deep-debug/security-emergency (0.95)" {
  out="$(_route state_present=1 security_critical=2 phase_mode=development)"
  [ "$(_field "$out" effective)" = "security-emergency" ]
  [ "$(_field "$out" confidence)" = "0.95" ]
}
@test "state: ci=failure → deep-debug (0.85)、maintenance では hotfix を付与" {
  out="$(_route state_present=1 ci=failure phase_mode=development)"
  [ "$(_field "$out" primary)" = "deep-debug" ]; [ -z "$(_field "$out" specialized)" ]
  out="$(_route state_present=1 ci=failure phase_mode=maintenance)"
  [ "$(_field "$out" effective)" = "hotfix" ]
}
@test "state: ci_success_rate<0.5 (ci unknown) は CI 失敗扱い" {
  out="$(_route state_present=1 ci=unknown ci_success_rate=0.2)"
  [ "$(_field "$out" primary)" = "deep-debug" ]
}
@test "state: deploy.ready=true → product-assurance/production-release" {
  out="$(_route state_present=1 deploy_ready=true phase_mode=development)"
  [ "$(_field "$out" effective)" = "production-release" ]
  [ "$(_field "$out" primary)" = "product-assurance" ]
}
@test "state: execution.phase=Release → production-release" {
  out="$(_route state_present=1 exec_phase=Release phase_mode=development)"
  [ "$(_field "$out" effective)" = "production-release" ]
}
@test "state: stable_achieved=true (development) → product-assurance" {
  out="$(_route state_present=1 stable_achieved=true phase_mode=development)"
  [ "$(_field "$out" primary)" = "product-assurance" ]; [ -z "$(_field "$out" specialized)" ]
}
@test "state: phase_mode=maintenance (障害なし) → development" {
  out="$(_route state_present=1 phase_mode=maintenance)"
  [ "$(_field "$out" primary)" = "development" ]
}
@test "state: maintenance + blocked_issues → deep-debug/hotfix" {
  out="$(_route state_present=1 phase_mode=released blocked_issues=2)"
  [ "$(_field "$out" effective)" = "hotfix" ]
}
@test "compat: 旧 state の goal_type=refactoring は development/refactoring へ写像 (0.60)" {
  out="$(_route state_present=1 phase_mode=development legacy_goal_type=refactoring)"
  [ "$(_field "$out" primary)" = "development" ]
  [ "$(_field "$out" effective)" = "refactoring" ]
  [ "$(_field "$out" confidence)" = "0.60" ]
  [[ "$(_field "$out" evidence)" == *"legacy_goal_type:refactoring"* ]]
}
@test "compat: 旧 state の goal_type=mvp-release は従来どおり mvp-release" {
  out="$(_route state_present=1 phase_mode=development legacy_goal_type=mvp-release)"
  [ "$(_field "$out" effective)" = "mvp-release" ]
}
@test "fallback: Evidence なし (state 不在) → mvp-release (0.55)" {
  out="$(_route state_present=0 has_ci=0 has_tests=0 git_commits=0)"
  [ "$(_field "$out" primary)" = "mvp-release" ]
  [ "$(_field "$out" confidence)" = "0.55" ]
}
@test "fallback: 既存プロジェクト (CI/テストあり・状態シグナルなし) → development (0.50)" {
  out="$(_route state_present=1 phase_mode=development has_ci=1 has_tests=1 git_commits=50 ci=success)"
  [ "$(_field "$out" primary)" = "development" ]
  [ "$(_field "$out" confidence)" = "0.50" ]
  [[ "$(_field "$out" evidence)" == *"ci:success"* ]]
}
@test "fail-safe: Evidence が空でも必ず Primary を返す" {
  out="$(printf '' | goal_router__route)"
  goal_router__is_primary "$(_field "$out" primary)"
}

# ---- lock / flapping ----------------------------------------
@test "lock: session_locked の前回 Goal は同一 Evidence で維持される (transition=kept)" {
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  out="$(_route state_present=1 phase_mode=development legacy_goal_type=mvp-release \
        prev_primary_goal=development prev_session_locked=true "prev_last_routed_at=$now" prev_snap_phase_mode=development prev_snap_security_critical=0)"
  [ "$(_field "$out" primary)" = "development" ]
  [ "$(_field "$out" transition)" = "kept" ]
  [[ "$(_field "$out" reason)" == locked:* ]]
}
@test "lock: 期限切れ (CLAUDEOS_GOAL_LOCK_MINUTES 超過) は再判定する" {
  old="2020-01-01T00:00:00Z"
  out="$(_route state_present=1 phase_mode=development legacy_goal_type=mvp-release \
        prev_primary_goal=development prev_session_locked=true "prev_last_routed_at=$old" -- --lock-minutes 10)"
  [ "$(_field "$out" primary)" = "mvp-release" ]
  [ "$(_field "$out" transition)" = "lock-expired" ]
}
@test "reroute: Security Critical 発生は lock を破る" {
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  out="$(_route state_present=1 security_critical=1 prev_primary_goal=development prev_session_locked=true "prev_last_routed_at=$now" prev_snap_security_critical=0)"
  [ "$(_field "$out" effective)" = "security-emergency" ]
  [ "$(_field "$out" transition)" = "reroute" ]
}
@test "reroute: 新しい CI 失敗は lock を破る" {
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  out="$(_route state_present=1 ci=failure prev_primary_goal=development prev_session_locked=true "prev_last_routed_at=$now" prev_snap_ci=success)"
  [ "$(_field "$out" primary)" = "deep-debug" ]
  [ "$(_field "$out" transition)" = "reroute" ]
}
@test "reroute: deploy.ready の変化は lock を破る" {
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  out="$(_route state_present=1 deploy_ready=true prev_primary_goal=development prev_session_locked=true "prev_last_routed_at=$now" prev_snap_deploy_ready=false)"
  [ "$(_field "$out" effective)" = "production-release" ]
  [ "$(_field "$out" transition)" = "reroute" ]
}
@test "reroute: ユーザーの新指示 (intent) は lock を破る" {
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  out="$(_route state_present=1 "intent=全体を評価して" prev_primary_goal=development prev_session_locked=true "prev_last_routed_at=$now" prev_snap_phase_mode= )"
  [ "$(_field "$out" primary)" = "assessment" ]
  [ "$(_field "$out" transition)" = "reroute" ]
}
@test "reroute: CLAUDEOS_GOAL_REROUTE=1 は lock を無視する" {
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  CLAUDEOS_GOAL_REROUTE=1 out="$(_route state_present=1 phase_mode=maintenance prev_primary_goal=mvp-release prev_session_locked=true "prev_last_routed_at=$now")"
  [ "$(_field "$out" primary)" = "development" ]
}
@test "manual: mode=manual の前回 Goal は Evidence に関わらず維持 (manual-lock)" {
  out="$(_route state_present=1 ci=failure prev_mode=manual prev_primary_goal=assessment prev_locked_by_user=true)"
  [ "$(_field "$out" primary)" = "assessment" ]
  [[ "$(_field "$out" reason)" == manual-lock:* ]]
  [ "$(_field "$out" locked_by_user)" = "true" ]
}
@test "manual: --goal auto は manual lock と session lock を解除して再判定する" {
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  out="$(_route state_present=1 phase_mode=maintenance prev_mode=manual prev_primary_goal=assessment prev_locked_by_user=true prev_session_locked=true "prev_last_routed_at=$now" -- --goal auto)"
  [ "$(_field "$out" primary)" = "development" ]
  [ "$(_field "$out" mode)" = "auto" ]
  [ "$(_field "$out" locked_by_user)" = "false" ]
}

# ---- resolve / persist (state.json 往復) ---------------------
@test "resolve: state.json 不在でも effective goal を返し起動を止めない" {
  run goal_router__resolve "$PROJ"
  [ "$status" -eq 0 ]
  [ "$output" = "mvp-release" ]
}
@test "resolve: 壊れた state.json は fail-safe (mvp-release) で新規作成しない" {
  _state '{broken json'
  run goal_router__resolve "$PROJ"
  [ "$status" -eq 0 ]
  [ "$output" = "mvp-release" ]
  run cat "$PROJ/state.json"; [ "$output" = "{broken json" ]
}
@test "resolve: 旧 state (goal_router なし) は goal_type で動作し、goal_router を追記する。他キーは不変" {
  _state '{"goal_type":"hotfix","project":{"phase_mode":"development"},"kpi":{"security_critical":0},"custom":{"keep":1}}'
  run goal_router__resolve "$PROJ"
  [ "$output" = "hotfix" ]
  [ "$(_gr primary_goal)" = "deep-debug" ]
  [ "$(_gr specialized_goal)" = "hotfix" ]
  [ "$(_gr effective_goal_type)" = "hotfix" ]
  python3 -c "import json,sys; d=json.load(open(sys.argv[1])); assert d['goal_type']=='hotfix' and d['custom']['keep']==1" "$PROJ/state.json"
}
@test "resolve: persist 結果は state.schema.json に適合する (enum / type)" {
  cp "$REPO_ROOT/state.json.example" "$PROJ/state.json"   # schema 適合済みの正本を起点にする
  goal_router__resolve "$PROJ" --intent "全体を評価して" >/dev/null
  run node "$REPO_ROOT/scripts/validate-state-example.js" "$PROJ/state.json"
  [ "$status" -eq 0 ]
  [ "$(_gr primary_goal)" = "assessment" ]
}
@test "resolve: --goal <name> は manual lock を永続化し、次回 auto 起動でも維持される" {
  _state '{"goal_type":"mvp-release","project":{"phase_mode":"development"}}'
  goal_router__resolve "$PROJ" --goal assessment --trigger user >/dev/null
  [ "$(_gr mode)" = "manual" ]; [ "$(_gr locked_by_user)" = "True" ]
  run goal_router__resolve "$PROJ" --trigger cron
  [ "$output" = "assessment" ]
}
@test "resolve: --goal auto は manual lock を解除する" {
  _state '{"goal_type":"mvp-release","project":{"phase_mode":"development"},"goal_router":{"mode":"manual","primary_goal":"assessment","locked_by_user":true}}'
  run goal_router__resolve "$PROJ" --goal auto --trigger user
  [ "$output" = "mvp-release" ]
  [ "$(_gr mode)" = "auto" ]; [ "$(_gr locked_by_user)" = "False" ]
}
@test "resolve: --one-shot (cron override) は effective を返すが session lock を立てない" {
  _state '{"goal_type":"mvp-release","project":{"phase_mode":"development"}}'
  run goal_router__resolve "$PROJ" --goal pr-babysit --one-shot --trigger cron
  [ "$output" = "pr-babysit" ]
  [ "$(_gr session_locked)" = "False" ]; [ "$(_gr locked_by_user)" = "False" ]
  run goal_router__resolve "$PROJ" --trigger cron
  [ "$output" = "mvp-release" ]
}
@test "resolve: 同一状態の連続起動は Goal を変えない (flapping なし) / history は遷移時のみ" {
  _state '{"goal_type":"mvp-release","project":{"phase_mode":"development"}}'
  goal_router__resolve "$PROJ" >/dev/null; goal_router__resolve "$PROJ" >/dev/null; goal_router__resolve "$PROJ" >/dev/null
  [ "$(_gr primary_goal)" = "mvp-release" ]
  [ "$(python3 -c "import json,sys; print(len(json.load(open(sys.argv[1]))['goal_router']['history']))" "$PROJ/state.json")" = "0" ]
  goal_router__resolve "$PROJ" --intent "CI が失敗しているので直して" --trigger user >/dev/null
  [ "$(_gr primary_goal)" = "deep-debug" ]
  [ "$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['goal_router']['history'][-1]['to'])" "$PROJ/state.json")" = "deep-debug" ]
}
@test "resolve: --no-persist は state.json を更新しない" {
  _state '{"goal_type":"mvp-release"}'
  goal_router__resolve "$PROJ" --no-persist >/dev/null
  run grep -c goal_router "$PROJ/state.json"; [ "$output" = "0" ]
}
@test "disabled: CLAUDEOS_GOAL_ROUTER_DISABLE=1 は従来 goal_type をそのまま返す" {
  _state '{"goal_type":"refactoring","kpi":{"security_critical":5}}'
  CLAUDEOS_GOAL_ROUTER_DISABLE=1 run goal_router__resolve "$PROJ"
  [ "$output" = "refactoring" ]
  run grep -c goal_router "$PROJ/state.json"; [ "$output" = "0" ]
}
@test "evidence: git / CI / tests の有無を収集し gh 無効時は ci=unknown" {
  git -C "$PROJ" init -q; git -C "$PROJ" commit -q --allow-empty -m init
  mkdir -p "$PROJ/.github/workflows" "$PROJ/tests"
  out="$(goal_router__evidence "$PROJ" 'hello')"
  [ "$(_field "$out" git_repo)" = "1" ]; [ "$(_field "$out" has_ci)" = "1" ]; [ "$(_field "$out" has_tests)" = "1" ]
  [ "$(_field "$out" ci)" = "unknown" ]; [ "$(_field "$out" intent)" = "hello" ]
}
@test "header/summary: RESUME_HEADER 用の 1 行が effective goal を含む" {
  _state '{"goal_type":"mvp-release"}'
  goal_router__resolve "$PROJ" >/dev/null
  [[ "$(goal_router__header)" == "[Goal Router] primary=mvp-release specialized=none effective_goal_type=mvp-release"* ]]
  [[ "$(goal_router__summary)" == *"effective=mvp-release"* ]]
}
