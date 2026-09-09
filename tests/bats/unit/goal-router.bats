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
  git -C "$PROJ" init -q
  git -C "$PROJ" -c user.email=test@example.com -c user.name=test commit -q --allow-empty -m init   # CI には global identity がない
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

# ---- Runtime Evidence (health / logs / Cloudflare) ----------------
@test "runtime: runtime_health=down → deep-debug (0.90)、本番運用中 (deploy.executed_at) なら hotfix" {
  out="$(_route state_present=1 runtime_health=down phase_mode=development)"
  [ "$(_field "$out" primary)" = "deep-debug" ]; [ -z "$(_field "$out" specialized)" ]
  [ "$(_field "$out" confidence)" = "0.90" ]
  out="$(_route state_present=1 runtime_health=down phase_mode=development deploy_executed=true)"
  [ "$(_field "$out" effective)" = "hotfix" ]
}
@test "runtime: health down は CI 失敗より優先し、Security Critical には劣後する" {
  out="$(_route state_present=1 runtime_health=down ci=failure)"
  [[ "$(_field "$out" reason)" == runtime-incident* ]]
  out="$(_route state_present=1 runtime_health=down security_critical=1)"
  [ "$(_field "$out" effective)" = "security-emergency" ]
}
@test "runtime: cf_deploy=failure → deep-debug (cloudflare-deploy-failure)" {
  out="$(_route state_present=1 cf_deploy=failure phase_mode=development)"
  [ "$(_field "$out" primary)" = "deep-debug" ]
  [[ "$(_field "$out" reason)" == cloudflare-deploy-failure* ]]
}
@test "runtime: error_log のエラー件数が閾値以上 → deep-debug (0.75)、閾値未満は影響しない" {
  out="$(_route state_present=1 runtime_errors=7 phase_mode=development has_ci=1 has_tests=1 git_commits=50)"
  [ "$(_field "$out" primary)" = "deep-debug" ]; [ "$(_field "$out" confidence)" = "0.75" ]
  out="$(_route state_present=1 runtime_errors=2 phase_mode=development has_ci=1 has_tests=1 git_commits=50)"
  [ "$(_field "$out" primary)" = "development" ]
  CLAUDEOS_GOAL_RUNTIME_ERROR_THRESHOLD=2 out="$(_route state_present=1 runtime_errors=2 phase_mode=development has_ci=1 has_tests=1 git_commits=50)"
  [ "$(_field "$out" primary)" = "deep-debug" ]
}
@test "reroute: health が新たに down になったら lock を破る (down 継続中は維持)" {
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  out="$(_route state_present=1 runtime_health=down prev_primary_goal=development prev_session_locked=true "prev_last_routed_at=$now" prev_snap_runtime_health=ok)"
  [ "$(_field "$out" transition)" = "reroute" ]; [ "$(_field "$out" primary)" = "deep-debug" ]
  out="$(_route state_present=1 runtime_health=down prev_primary_goal=deep-debug prev_session_locked=true "prev_last_routed_at=$now" prev_snap_runtime_health=down)"
  [[ "$(_field "$out" transition)" == kept || "$(_field "$out" transition)" == unchanged ]]   # lock 維持 (reroute ではない)
  [ "$(_field "$out" primary)" = "deep-debug" ]
}
@test "evidence: state.runtime.health_url を curl で判定 (503 → down、200 → ok)" {
  export CLAUDEOS_GOAL_ROUTER_RUNTIME=1
  _state '{"runtime":{"health_url":"http://localhost:1/health"}}'
  make_stub_bin curl 'printf 503'
  out="$(goal_router__runtime_evidence "$PROJ/state.json")"
  [ "$(_field "$out" runtime_health)" = "down" ]; [ "$(_field "$out" has_runtime)" = "1" ]
  make_stub_bin curl 'printf 200'
  out="$(goal_router__runtime_evidence "$PROJ/state.json")"
  [ "$(_field "$out" runtime_health)" = "ok" ]
}
@test "evidence: state.runtime.error_log の直近エラー件数を数える" {
  export CLAUDEOS_GOAL_ROUTER_RUNTIME=1
  printf 'INFO ok\nERROR boom\nTraceback (most recent call last)\nWARN meh\nFATAL dead\n' > "$TEST_TEMP/app.log"
  _state "{\"runtime\":{\"error_log\":\"$TEST_TEMP/app.log\"}}"
  out="$(goal_router__runtime_evidence "$PROJ/state.json")"
  [ "$(_field "$out" runtime_errors)" = "3" ]
}
@test "evidence: runtime 設定なしは unknown / has_runtime=0、CLAUDEOS_GOAL_ROUTER_RUNTIME=0 で probe しない" {
  _state '{"goal_type":"mvp-release"}'
  out="$(goal_router__runtime_evidence "$PROJ/state.json")"
  [ "$(_field "$out" runtime_health)" = "unknown" ]; [ "$(_field "$out" has_runtime)" = "0" ]
  export CLAUDEOS_GOAL_ROUTER_RUNTIME=0
  _state '{"runtime":{"health_url":"http://localhost:1/health"}}'
  make_stub_bin curl 'echo CALLED >> "$TEST_TEMP/curl.log"; printf 503'
  out="$(goal_router__runtime_evidence "$PROJ/state.json")"
  [ "$(_field "$out" runtime_health)" = "unknown" ]; [ ! -f "$TEST_TEMP/curl.log" ]
}
@test "evidence: Cloudflare Pages の latest_stage.status を wrangler --json から読む (failure / success / none)" {
  export CLAUDEOS_GOAL_ROUTER_CF=1
  _state '{"runtime":{"cloudflare":{"project":"my-pages"}}}'
  make_stub_bin wrangler 'printf "%s\n" "$*" >> "$TEST_TEMP/wrangler.log"; echo "[{\"id\":\"d1\",\"latest_stage\":{\"name\":\"deploy\",\"status\":\"failure\"}}]"'
  out="$(goal_router__runtime_evidence "$PROJ/state.json")"
  [ "$(_field "$out" cf_deploy)" = "failure" ]
  grep -q -- '--project-name my-pages --environment production --json' "$TEST_TEMP/wrangler.log"
  make_stub_bin wrangler 'echo "[{\"latest_stage\":{\"status\":\"success\"}}]"'
  [ "$(_field "$(goal_router__runtime_evidence "$PROJ/state.json")" cf_deploy)" = "success" ]
  make_stub_bin wrangler 'echo "[]"'
  [ "$(_field "$(goal_router__runtime_evidence "$PROJ/state.json")" cf_deploy)" = "none" ]
}
@test "evidence: Cloudflare Worker は状態を持たないため failure/success にせず listed/none/unknown の観測のみ、CF=0 なら wrangler を呼ばない" {
  export CLAUDEOS_GOAL_ROUTER_CF=1
  _state '{"runtime":{"cloudflare":{"worker":"my-worker"}}}'
  make_stub_bin wrangler 'exit 1'
  out="$(goal_router__runtime_evidence "$PROJ/state.json")"
  [ "$(_field "$out" cf_worker)" = "unknown" ]; [ "$(_field "$out" cf_deploy)" = "unknown" ]   # 一覧取得失敗 ≠ deploy failure
  make_stub_bin wrangler 'echo "[{\"id\":\"v1\"}]"; exit 0'
  out="$(goal_router__runtime_evidence "$PROJ/state.json")"
  [ "$(_field "$out" cf_worker)" = "listed" ]; [ "$(_field "$out" cf_deploy)" = "unknown" ]
  make_stub_bin wrangler 'echo "[]"; exit 0'
  [ "$(_field "$(goal_router__runtime_evidence "$PROJ/state.json")" cf_deploy)" = "none" ]
  export CLAUDEOS_GOAL_ROUTER_CF=0
  make_stub_bin wrangler 'echo CALLED >> "$TEST_TEMP/wr.log"; echo "[]"'
  [ "$(_field "$(goal_router__runtime_evidence "$PROJ/state.json")" cf_deploy)" = "unknown" ]; [ ! -f "$TEST_TEMP/wr.log" ]
}
@test "resolve: runtime 設定つき state の persist は schema に適合し snapshot に runtime_health を持つ" {
  export CLAUDEOS_GOAL_ROUTER_RUNTIME=1
  cp "$REPO_ROOT/state.json.example" "$PROJ/state.json"
  python3 - "$PROJ/state.json" <<'PY'
import json,sys; f=sys.argv[1]; d=json.load(open(f)); d['runtime']['health_url']='http://localhost:1/health'; json.dump(d,open(f,'w'))
PY
  make_stub_bin curl 'printf 500'
  run goal_router__resolve "$PROJ"
  [ "$output" = "deep-debug" ]
  run node "$REPO_ROOT/scripts/validate-state-example.js" "$PROJ/state.json"; [ "$status" -eq 0 ]
  [ "$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['goal_router']['evidence_snapshot']['runtime_health'])" "$PROJ/state.json")" = "down" ]
}

# ---- LLM intent (claude -p 補完) ----------------------------------
@test "intent_llm: CLAUDEOS_GOAL_INTENT_LLM=0 は claude を呼ばず空" {
  make_stub_bin claude 'echo CALLED >> "$TEST_TEMP/claude.log"; echo "{\"result\":\"development\"}"'
  [ -z "$(goal_router__intent_llm 'なにかして')" ]; [ ! -f "$TEST_TEMP/claude.log" ]
}
@test "intent_llm: auto は Claude Code セッション内 (CLAUDECODE=1) では呼ばない、1 なら呼ぶ" {
  make_stub_bin claude 'if [[ "$1" == "--help" ]]; then echo "--bare --no-session-persistence"; exit 0; fi; printf "%s\n" "$*" >> "$TEST_TEMP/claude.log"; echo "{\"type\":\"result\",\"result\":\"deep-debug/hotfix\"}"'
  CLAUDECODE=1 CLAUDEOS_GOAL_INTENT_LLM=auto run goal_router__intent_llm 'ログインが落ちる'
  [ -z "$output" ]; [ ! -f "$TEST_TEMP/claude.log" ]
  CLAUDECODE=1 CLAUDEOS_GOAL_INTENT_LLM=1 run goal_router__intent_llm 'ログインが落ちる'
  [ "$output" = "deep-debug hotfix" ]
  grep -q -- '--model haiku' "$TEST_TEMP/claude.log"
  grep -q -- '--output-format json' "$TEST_TEMP/claude.log"
  grep -q -- '--bare' "$TEST_TEMP/claude.log"
}
@test "intent_llm: 不正ラベル / none / 空出力は捨てる (fail-safe)、Specialized 単独は Primary を補う" {
  export CLAUDEOS_GOAL_INTENT_LLM=1
  make_stub_bin claude 'echo "{\"result\":\"banana\"}"'; [ -z "$(goal_router__intent_llm 'x')" ]
  make_stub_bin claude 'echo "{\"result\":\"none\"}"'; [ -z "$(goal_router__intent_llm 'x')" ]
  make_stub_bin claude 'exit 1'; [ -z "$(goal_router__intent_llm 'x')" ]
  make_stub_bin claude 'echo "{\"result\":\"Label: refactoring\"}"'; [ "$(goal_router__intent_llm 'x')" = "development refactoring" ]
  make_stub_bin claude 'echo "{\"result\":\"mvp-release/hotfix\"}"'; [ "$(goal_router__intent_llm 'x')" = "mvp-release" ]   # 不許可の組合せは Specialized を落とす
}
@test "intent_llm: evidence はキーワード判定不能のときだけ LLM を使い、route は user-intent-llm (0.70) で採用" {
  export CLAUDEOS_GOAL_INTENT_LLM=1
  make_stub_bin claude 'printf "%s\n" "$*" >> "$TEST_TEMP/claude.log"; echo "{\"result\":\"assessment\"}"'
  _state '{"goal_type":"mvp-release","project":{"phase_mode":"development"}}'
  out="$(goal_router__evidence "$PROJ" 'このプロダクトの現状はどう？')"
  [ "$(_field "$out" intent_llm)" = "assessment" ]
  res="$(printf '%s\n' "$out" | goal_router__route)"
  [ "$(_field "$res" primary)" = "assessment" ]; [ "$(_field "$res" confidence)" = "0.70" ]
  [[ "$(_field "$res" evidence)" == *"user_intent_llm:assessment"* ]]
  rm -f "$TEST_TEMP/claude.log"
  out="$(goal_router__evidence "$PROJ" 'CI が失敗しているので直して')"   # キーワードで判定できる → LLM 不使用
  [ -z "$(_field "$out" intent_llm)" ]; [ ! -f "$TEST_TEMP/claude.log" ]
}
@test "evidence: Pages と Worker の両方を設定すると独立に照会し、routing 用の cf_deploy は Pages の status からのみ確定する" {
  export CLAUDEOS_GOAL_ROUTER_CF=1
  _state '{"runtime":{"cloudflare":{"project":"my-pages","worker":"my-worker"}}}'
  make_stub_bin wrangler 'printf "%s\n" "$*" >> "$TEST_TEMP/wrangler.log"; if [[ "$1" == "pages" ]]; then echo "[{\"latest_stage\":{\"status\":\"failure\"}}]"; else exit 1; fi'
  out="$(goal_router__runtime_evidence "$PROJ/state.json")"
  [ "$(_field "$out" cf_pages)" = "failure" ]; [ "$(_field "$out" cf_worker)" = "unknown" ]; [ "$(_field "$out" cf_deploy)" = "failure" ]
  grep -q -- 'pages deployment list --project-name my-pages' "$TEST_TEMP/wrangler.log"
  grep -q -- 'deployments list --name my-worker' "$TEST_TEMP/wrangler.log"
}

# ---- 実行 Plane (v11 P0 要件 4/9: managed|local 選択 + 安全側フォールバック) ----
@test "plane: evidence に execution_plane=managed があれば route 出力は managed" {
  res="$(printf 'execution_plane=managed\nma_mode=dry-run\n' | goal_router__route --goal development)"
  [ "$(_field "$res" execution_plane)" = "managed" ]
  [ "$(_field "$res" ma_mode)" = "dry-run" ]
}
@test "plane: evidence 不在時は安全側 local" {
  res="$(printf 'primary=development\n' | goal_router__route --goal development)"
  [ "$(_field "$res" execution_plane)" = "local" ]
}
@test "plane: execution_plane の不正値は local に降格" {
  res="$(printf 'execution_plane=sandbox\n' | goal_router__route --goal development)"
  [ "$(_field "$res" execution_plane)" = "local" ]
}
@test "plane: adapter 不在の evidence は execution_plane=local で fail-safe" {
  out="$(goal_router__evidence "$PROJ" '')"
  [ "$(_field "$out" execution_plane)" = "local" ]
  [ "$(_field "$out" ma_reason)" = "adapter-missing" ] || [ "$(_field "$out" ma_reason)" = "config-missing-or-invalid" ]
}
@test "plane: persist は state.goal_router.execution_plane を記録する" {
  _state '{"project":{"phase_mode":"development"}}'
  GOAL_ROUTER_PRIMARY=development GOAL_ROUTER_EFFECTIVE=development GOAL_ROUTER_CONFIDENCE=1 \
  GOAL_ROUTER_EXECUTION_PLANE=managed goal_router__persist "$PROJ/state.json"
  [ "$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['goal_router']['execution_plane'])" "$PROJ/state.json")" = "managed" ]
  GOAL_ROUTER_PRIMARY=development GOAL_ROUTER_EFFECTIVE=development GOAL_ROUTER_CONFIDENCE=1 \
  GOAL_ROUTER_EXECUTION_PLANE=weird goal_router__persist "$PROJ/state.json"
  [ "$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['goal_router']['execution_plane'])" "$PROJ/state.json")" = "local" ]
}
