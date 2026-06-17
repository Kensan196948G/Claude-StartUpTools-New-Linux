#!/usr/bin/env bats
# ============================================================
# supervisor.bats — lib/supervisor.sh のユニットテスト
#   ガードレール純粋関数 / 状態I/O / ループ各停止シナリオを検証。
#   cron-launcher は stub、停止は state.json/上限/フラグで誘発。
# ============================================================

load '../helpers/common-setup'

setup() {
  _bats_common_setup
  export AI_STARTUP_CONFIG_PATH="$TEST_TEMP/config.json"
  printf '{ "projects": "%s/projects" }\n' "$TEST_TEMP" > "$AI_STARTUP_CONFIG_PATH"
  export CCSU_SUP_DIR="$TEST_TEMP/sup"
  export CCSU_SUP_COOLDOWN=0
  export CCSU_SUP_CRON_LAUNCHER="$TEST_TEMP/launcher.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$CCSU_SUP_CRON_LAUNCHER"; chmod +x "$CCSU_SUP_CRON_LAUNCHER"
  # クレジット台帳を隔離 (PR-E: 実 HOME の ledger を汚さない)
  export CCSU_CREDITS_LEDGER="$TEST_TEMP/credits/ledger.jsonl"
  mkdir -p "$TEST_TEMP/projects/Demo"
  source "$REPO_ROOT/lib/supervisor.sh"
}
teardown() { _bats_common_teardown; }

# ---- 純粋ガードレール関数 ----------------------------------
@test "sup__goal_reason: deploy.ready=true" { run sup__goal_reason true development; [ "$output" = "goal-reached:deploy.ready" ]; }
@test "sup__goal_reason: phase_mode=maintenance" { run sup__goal_reason false maintenance; [ "$output" = "goal-reached:phase_mode=maintenance" ]; }
@test "sup__goal_reason: released" { run sup__goal_reason false released; [ "$output" = "goal-reached:phase_mode=released" ]; }
@test "sup__goal_reason: release-ready は goal-reached" { run sup__goal_reason false release-ready; [ "$output" = "goal-reached:phase_mode=release-ready" ]; }
@test "sup__goal_reason: development は継続(空)" { run sup__goal_reason false development; [ -z "$output" ]; }
@test "sup__abnormal_reason: security>0" { run sup__abnormal_reason 2 0; [ "$output" = "blocked:security_critical=2" ]; }
@test "sup__abnormal_reason: blocked>0" { run sup__abnormal_reason 0 3; [ "$output" = "blocked:blocked_issues=3" ]; }
@test "sup__abnormal_reason: 正常は空" { run sup__abnormal_reason 0 0; [ -z "$output" ]; }
@test "sup__abnormal_reason: 第3引数省略は halt 既定(blocked で停止・後方互換)" { run sup__abnormal_reason 0 3; [ "$output" = "blocked:blocked_issues=3" ]; }
@test "sup__abnormal_reason: halt_on_blocked=true は blocked で停止" { run sup__abnormal_reason 0 3 true; [ "$output" = "blocked:blocked_issues=3" ]; }
@test "sup__abnormal_reason: halt_on_blocked=false は blocked を無視し継続(空)" { run sup__abnormal_reason 0 3 false; [ -z "$output" ]; [ "$status" -eq 0 ]; }
@test "sup__abnormal_reason: halt_on_blocked=false でも security は常に停止(fail-safe)" { run sup__abnormal_reason 2 3 false; [ "$output" = "blocked:security_critical=2" ]; }
@test "sup__abnormal_reason: 未知の値は halt 扱い(false 厳密一致のみ opt-out)" { run sup__abnormal_reason 0 3 yes; [ "$output" = "blocked:blocked_issues=3" ]; }
@test "sup__cap_reason: minutes 到達" { run sup__cap_reason 600 600 0 6; [[ "$output" == daily-cap:minutes* ]]; }
@test "sup__cap_reason: restarts 到達" { run sup__cap_reason 0 600 6 6; [[ "$output" == daily-cap:restarts* ]]; }
@test "sup__cap_reason: 上限内は空" { run sup__cap_reason 10 600 1 6; [ -z "$output" ]; [ "$status" -eq 0 ]; }
@test "sup__crash_reason: 閾値到達" { run sup__crash_reason 3 3; [[ "$output" == crash-loop* ]]; }
@test "sup__crash_reason: 閾値未満は空" { run sup__crash_reason 1 3; [ -z "$output" ]; [ "$status" -eq 0 ]; }

# ---- 残日数 throttling ------------------------------------
@test "sup__days_remaining: 締切まで 30 日" { run sup__days_remaining 2026-07-15 2026-06-15; [ "$output" = "30" ]; }
@test "sup__days_remaining: 当日は 0" { run sup__days_remaining 2026-06-15 2026-06-15; [ "$output" = "0" ]; }
@test "sup__days_remaining: 超過は負" { run sup__days_remaining 2026-06-14 2026-06-15; [ "$output" = "-1" ]; }
@test "sup__days_remaining: deadline 空は無出力" { run sup__days_remaining "" 2026-06-15; [ -z "$output" ]; [ "$status" -eq 0 ]; }
@test "sup__days_remaining: deadline null は無出力" { run sup__days_remaining null 2026-06-15; [ -z "$output" ]; }
@test "sup__days_remaining: 不正形式は無出力" { run sup__days_remaining 2026/06/15 2026-06-15; [ -z "$output" ]; }

@test "sup__throttle_tier: 31 → normal" { run sup__throttle_tier 31; [ "$output" = "normal" ]; }
@test "sup__throttle_tier: 30 → t30" { run sup__throttle_tier 30; [ "$output" = "t30" ]; }
@test "sup__throttle_tier: 15 → t30" { run sup__throttle_tier 15; [ "$output" = "t30" ]; }
@test "sup__throttle_tier: 14 → t14" { run sup__throttle_tier 14; [ "$output" = "t14" ]; }
@test "sup__throttle_tier: 8 → t14" { run sup__throttle_tier 8; [ "$output" = "t14" ]; }
@test "sup__throttle_tier: 7 → t7" { run sup__throttle_tier 7; [ "$output" = "t7" ]; }
@test "sup__throttle_tier: 0 → t7" { run sup__throttle_tier 0; [ "$output" = "t7" ]; }
@test "sup__throttle_tier: -1 → overdue" { run sup__throttle_tier -1; [ "$output" = "overdue" ]; }
@test "sup__throttle_tier: 空(deadline 無) → normal" { run sup__throttle_tier ""; [ "$output" = "normal" ]; }

@test "sup__throttle_apply: normal は daily 据え置き・session≤300" {
  run sup__throttle_apply normal 600 300; [ "$output" = "600 300" ]
}
@test "sup__throttle_apply: normal でも session>300 は 300 に丸め" {
  run sup__throttle_apply normal 600 600; [ "$output" = "600 300" ]
}
@test "sup__throttle_apply: t30 縮退" { run sup__throttle_apply t30 600 300; [ "$output" = "480 300" ]; }
@test "sup__throttle_apply: t14 縮退" { run sup__throttle_apply t14 600 300; [ "$output" = "360 240" ]; }
@test "sup__throttle_apply: t7 縮退" { run sup__throttle_apply t7 600 300; [ "$output" = "180 180" ]; }
@test "sup__throttle_apply: overdue は t7 と同等" { run sup__throttle_apply overdue 600 300; [ "$output" = "180 180" ]; }
@test "sup__throttle_apply: 原値より小さい daily は増やさない" {
  run sup__throttle_apply t30 120 60; [ "$output" = "120 60" ]
}
@test "sup__throttle_apply: 縮退は単調 (t30≥t14≥t7 の daily)" {
  d30="$(sup__throttle_apply t30 600 300)"; d14="$(sup__throttle_apply t14 600 300)"; d7="$(sup__throttle_apply t7 600 300)"
  [ "${d30%% *}" -ge "${d14%% *}" ]; [ "${d14%% *}" -ge "${d7%% *}" ]
}

@test "sup__throttle_goal_bias: normal は空" { run sup__throttle_goal_bias normal; [ -z "$output" ]; }
@test "sup__throttle_goal_bias: t30 → verify 優先" { run sup__throttle_goal_bias t30; [ "$output" = "improvement-reduce:verify-priority" ]; }
@test "sup__throttle_goal_bias: t14 → bugfix のみ" { run sup__throttle_goal_bias t14; [ "$output" = "feature-freeze:bugfix-only" ]; }
@test "sup__throttle_goal_bias: t7 → リリース準備" { run sup__throttle_goal_bias t7; [ "$output" = "release-prep-only" ]; }
@test "sup__throttle_goal_bias: overdue → リリース準備" { run sup__throttle_goal_bias overdue; [ "$output" = "release-prep-only" ]; }

# ---- project state.json 読取判定 ---------------------------
@test "sup__project_stop_reason: deploy.ready=true → goal-reached" {
  echo '{ "deploy": {"ready": true} }' > "$TEST_TEMP/p.json"
  run sup__project_stop_reason "$TEST_TEMP/p.json"
  [ "$output" = "goal-reached:deploy.ready" ]
}
@test "sup__project_stop_reason: phase_mode=maintenance → goal-reached" {
  echo '{ "project": {"phase_mode":"maintenance"} }' > "$TEST_TEMP/p.json"
  run sup__project_stop_reason "$TEST_TEMP/p.json"
  [ "$output" = "goal-reached:phase_mode=maintenance" ]
}
@test "sup__project_stop_reason: phase_mode=release-ready → goal-reached" {
  echo '{ "project": {"phase_mode":"release-ready"} }' > "$TEST_TEMP/p.json"
  run sup__project_stop_reason "$TEST_TEMP/p.json"
  [ "$output" = "goal-reached:phase_mode=release-ready" ]
}
@test "sup__project_stop_reason: status.deploy_ready=true (旧スキーマ互換) → goal-reached" {
  echo '{ "status": {"deploy_ready": true} }' > "$TEST_TEMP/p.json"
  run sup__project_stop_reason "$TEST_TEMP/p.json"
  [ "$output" = "goal-reached:deploy.ready" ]
}
@test "sup__project_stop_reason: development は空(継続)" {
  echo '{ "project": {"phase_mode":"development"}, "deploy": {"ready": false} }' > "$TEST_TEMP/p.json"
  run sup__project_stop_reason "$TEST_TEMP/p.json"
  [ -z "$output" ]
  [ "$status" -eq 0 ]
}
@test "sup__project_stop_reason: blocked_issues 非空 → blocked" {
  echo '{ "deploy": {"ready": false}, "blocked_issues": [101,102] }' > "$TEST_TEMP/p.json"
  run sup__project_stop_reason "$TEST_TEMP/p.json"
  [ "$output" = "blocked:blocked_issues=2" ]
}
@test "sup__project_stop_reason: supervisor.halt_on_blocked=false は blocked を無視し継続(空)" {
  echo '{ "deploy": {"ready": false}, "blocked_issues": [101,102], "supervisor": {"halt_on_blocked": false} }' > "$TEST_TEMP/p.json"
  run sup__project_stop_reason "$TEST_TEMP/p.json"
  [ -z "$output" ]
  [ "$status" -eq 0 ]
}
@test "sup__project_stop_reason: halt_on_blocked=false でも security_critical は停止(fail-safe)" {
  echo '{ "deploy": {"ready": false}, "blocked_issues": [101], "kpi": {"security_critical": 1}, "supervisor": {"halt_on_blocked": false} }' > "$TEST_TEMP/p.json"
  run sup__project_stop_reason "$TEST_TEMP/p.json"
  [ "$output" = "blocked:security_critical=1" ]
}
@test "sup__project_stop_reason: halt_on_blocked=true 明示も blocked で停止" {
  echo '{ "deploy": {"ready": false}, "blocked_issues": [101], "supervisor": {"halt_on_blocked": true} }' > "$TEST_TEMP/p.json"
  run sup__project_stop_reason "$TEST_TEMP/p.json"
  [ "$output" = "blocked:blocked_issues=1" ]
}

# ---- 状態 I/O ----------------------------------------------
@test "sup__persist + sup__get: 往復し妥当な JSON" {
  SUP_STATUS=running SUP_PID=$$ SUP_RESTARTS=2 SUP_MINUTES=42 sup__persist Demo
  [ "$(sup__get Demo status '')" = "running" ]
  [ "$(sup__get Demo restarts_today 0)" = "2" ]
  [ "$(sup__get Demo minutes_today 0)" = "42" ]
  jq -e . "$CCSU_SUP_DIR/Demo.json" >/dev/null
}
@test "sup__is_running: 生存pid+running なら 0" {
  SUP_STATUS=running SUP_PID=$$ sup__persist Demo
  run sup__is_running Demo; [ "$status" -eq 0 ]
}
@test "sup__is_running: 死pid なら非0" {
  SUP_STATUS=running SUP_PID=999999 sup__persist Demo
  run sup__is_running Demo; [ "$status" -ne 0 ]
}
@test "sup__is_running: status!=running なら非0" {
  SUP_STATUS=stopped SUP_PID=$$ sup__persist Demo
  run sup__is_running Demo; [ "$status" -ne 0 ]
}
@test "sup__request_stop: stop フラグを作成" {
  sup__request_stop Demo
  [ -f "$CCSU_SUP_DIR/Demo.stop" ]
}

# ---- ループ各停止シナリオ ----------------------------------
@test "sup__loop: deploy.ready=true で goal-reached 即停止 (restarts=0)" {
  echo '{ "deploy": {"ready": true} }' > "$TEST_TEMP/projects/Demo/state.json"
  run sup__loop Demo 5
  [ "$status" -eq 0 ]
  [ "$(sup__get Demo status '')" = "goal-reached" ]
  [ "$(sup__get Demo restarts_today 0)" = "0" ]
}
@test "sup__loop: max_restarts=1 で 1セッション後 daily-cap" {
  echo '{ "deploy": {"ready": false}, "supervisor": {"max_restarts_per_day": 1, "crash_loop_min_seconds": 0} }' > "$TEST_TEMP/projects/Demo/state.json"
  run sup__loop Demo 5
  [ "$(sup__get Demo status '')" = "daily-cap" ]
  [ "$(sup__get Demo restarts_today 0)" = "1" ]
}
@test "sup__loop: 短命連続で crash-loop 停止" {
  echo '{ "deploy": {"ready": false}, "supervisor": {"crash_loop_threshold": 2, "crash_loop_min_seconds": 999999, "max_restarts_per_day": 100} }' > "$TEST_TEMP/projects/Demo/state.json"
  run sup__loop Demo 5
  [ "$(sup__get Demo status '')" = "crash-loop" ]
}
@test "sup__loop: コスト≥\$0.02 の短命セッションは crash-short にカウントしない" {
  # 短命でも実コスト ($0.18) があるセッションは「実作業の証拠」→ crash-loop を回避
  cat > "$CCSU_SUP_CRON_LAUNCHER" <<'EOF'
#!/usr/bin/env bash
echo 0.18 > "$CLAUDEOS_SESSION_COST_FILE"
exit 0
EOF
  chmod +x "$CCSU_SUP_CRON_LAUNCHER"
  echo '{ "deploy": {"ready": false}, "supervisor": {"crash_loop_threshold": 2, "crash_loop_min_seconds": 999999, "max_restarts_per_day": 2} }' > "$TEST_TEMP/projects/Demo/state.json"
  run sup__loop Demo 5
  # crash-loop ではなく daily-cap で停止 (consecutive_short がリセットされ続ける)
  [ "$(sup__get Demo status '')" = "daily-cap" ]
  [ "$(sup__get Demo consecutive_short 99)" = "0" ]
}
@test "sup__loop: コスト\$0.00 の短命セッションは crash-short にカウントする" {
  # コスト未発生 (API エラー想定) の短命は従来どおり crash-short カウント
  cat > "$CCSU_SUP_CRON_LAUNCHER" <<'EOF'
#!/usr/bin/env bash
echo 0.00 > "$CLAUDEOS_SESSION_COST_FILE"
exit 0
EOF
  chmod +x "$CCSU_SUP_CRON_LAUNCHER"
  echo '{ "deploy": {"ready": false}, "supervisor": {"crash_loop_threshold": 2, "crash_loop_min_seconds": 999999, "max_restarts_per_day": 100} }' > "$TEST_TEMP/projects/Demo/state.json"
  run sup__loop Demo 5
  [ "$(sup__get Demo status '')" = "crash-loop" ]
}
@test "sup__loop: 起動前 stop フラグで manual 停止 (restarts=0)" {
  echo '{ "deploy": {"ready": false} }' > "$TEST_TEMP/projects/Demo/state.json"
  mkdir -p "$CCSU_SUP_DIR"; : > "$CCSU_SUP_DIR/Demo.stop"
  run sup__loop Demo 5
  [ "$(sup__get Demo status '')" = "stopped" ]
  [ "$(sup__get Demo restarts_today 0)" = "0" ]
}
@test "sup__loop: launcher 不在で停止 (暴走しない)" {
  echo '{ "deploy": {"ready": false} }' > "$TEST_TEMP/projects/Demo/state.json"
  SUP_CRON_LAUNCHER="$TEST_TEMP/does-not-exist.sh"
  run sup__loop Demo 5
  [ "$(sup__get Demo status '')" = "stopped" ]
  [ "$(sup__get Demo restarts_today 0)" = "0" ]
}

# ---- ループ統合: 残日数 throttling 配線 (PR-C) ----------
# 観測戦略: cron-launcher stub に session_min ($2) を記録させ、ループ内で
#   sup__throttle_apply による縮退が実効値へ反映されることを外側から検証する。
#   duration 引数を渡さない (session_min_base=既定300) ことで縮退幅が観測可能。
@test "sup__loop: t7 (締切3日) で session_min=180 へ縮退し last_throttle_tier 永続" {
  cat > "$CCSU_SUP_CRON_LAUNCHER" <<EOF
#!/usr/bin/env bash
echo "\$2" > "$TEST_TEMP/sessmin"
exit 0
EOF
  chmod +x "$CCSU_SUP_CRON_LAUNCHER"
  export CCSU_SUP_TODAY=2026-06-15
  echo '{ "deploy": {"ready": false}, "project": {"release_deadline":"2026-06-18"}, "supervisor": {"max_restarts_per_day": 1, "crash_loop_min_seconds": 0} }' > "$TEST_TEMP/projects/Demo/state.json"
  run sup__loop Demo
  [ "$(sup__get Demo last_throttle_tier '')" = "t7" ]
  [ "$(cat "$TEST_TEMP/sessmin")" = "180" ]
}
@test "sup__loop: deadline 無しは normal・session_min 据え置き(300)" {
  cat > "$CCSU_SUP_CRON_LAUNCHER" <<EOF
#!/usr/bin/env bash
echo "\$2" > "$TEST_TEMP/sessmin"
exit 0
EOF
  chmod +x "$CCSU_SUP_CRON_LAUNCHER"
  export CCSU_SUP_TODAY=2026-06-15
  echo '{ "deploy": {"ready": false}, "supervisor": {"max_restarts_per_day": 1, "crash_loop_min_seconds": 0} }' > "$TEST_TEMP/projects/Demo/state.json"
  run sup__loop Demo
  [ "$(sup__get Demo last_throttle_tier '')" = "normal" ]
  [ "$(cat "$TEST_TEMP/sessmin")" = "300" ]
}
@test "sup__loop: t30 (締切20日) で tier=t30 を永続・session_min=300 維持" {
  cat > "$CCSU_SUP_CRON_LAUNCHER" <<EOF
#!/usr/bin/env bash
echo "\$2" > "$TEST_TEMP/sessmin"
exit 0
EOF
  chmod +x "$CCSU_SUP_CRON_LAUNCHER"
  export CCSU_SUP_TODAY=2026-06-15
  echo '{ "deploy": {"ready": false}, "project": {"release_deadline":"2026-07-05"}, "supervisor": {"max_restarts_per_day": 1, "crash_loop_min_seconds": 0} }' > "$TEST_TEMP/projects/Demo/state.json"
  run sup__loop Demo
  [ "$(sup__get Demo last_throttle_tier '')" = "t30" ]   # t30 は session 据え置き (daily のみ縮退)
  [ "$(cat "$TEST_TEMP/sessmin")" = "300" ]
}

# ---- ループ統合: set -e 下の即死回帰 (throttle read EOF) ----------
# 背景: 本番の supervisor は autonomy.sh __run (set -euo pipefail) 下で sup__loop を回す。
#   throttle 行 `read -r < <(sup__throttle_apply ...)` は出力が改行終端でないと EOF 直撃で
#   read が status 1 を返し、set -e が supervisor を「🚀 start」直後・cron-launcher 到達前に
#   即死させていた (json は running のまま凍結)。bats の `run` は set -e を伝播しないため
#   既存の結合テストでは検出できなかった。本テストは明示的に set -euo pipefail 下で実走する。
@test "sup__loop: set -euo pipefail 下でも throttle read で即死しない (PR-C 回帰)" {
  cat > "$CCSU_SUP_CRON_LAUNCHER" <<EOF
#!/usr/bin/env bash
echo "\$2" > "$TEST_TEMP/sessmin"
exit 0
EOF
  chmod +x "$CCSU_SUP_CRON_LAUNCHER"
  export CCSU_SUP_TODAY=2026-06-15
  echo '{ "deploy": {"ready": false}, "supervisor": {"max_restarts_per_day": 1, "crash_loop_min_seconds": 0} }' > "$TEST_TEMP/projects/Demo/state.json"
  # 本番 __run と同一環境 (set -euo pipefail) で sup__loop を実走させる。
  run bash -c 'set -euo pipefail; source "$1"; sup__loop Demo' _ "$REPO_ROOT/lib/supervisor.sh"
  [ "$status" -eq 0 ]
  # cron-launcher まで到達した決定的証拠 (read で死んでいれば sessmin は生成されない)
  [ -f "$TEST_TEMP/sessmin" ]
  # 終端処理に到達し terminal status が書かれている (running 凍結でない)
  [ "$(sup__get Demo status '')" = "daily-cap" ]
}

# ---- ループ統合: クレジット上限ガード配線 (PR-E) ----------
# 観測戦略: cron-launcher stub が当該セッションの cost を $CLAUDEOS_SESSION_COST_FILE へ
#   書き出す (= cron-launcher が SJT_COST_FILE を鏡写しする挙動の代替)。supervisor が
#   それを ledger 追記 → 当月合計 → credits__guard で credit-cap 判定する経路を外側から検証。
@test "sup__loop: 予算到達で credit-cap 停止 (restarts=0・ledger 追記)" {
  cat > "$CCSU_SUP_CRON_LAUNCHER" <<'EOF'
#!/usr/bin/env bash
echo 100 > "$CLAUDEOS_SESSION_COST_FILE"
exit 0
EOF
  chmod +x "$CCSU_SUP_CRON_LAUNCHER"
  echo '{ "deploy": {"ready": false}, "supervisor": {"credit_monthly_budget_usd": 100, "max_restarts_per_day": 100, "crash_loop_min_seconds": 0} }' > "$TEST_TEMP/projects/Demo/state.json"
  run sup__loop Demo 5
  [ "$(sup__get Demo status '')" = "credit-cap" ]
  # 予算超過セッションは完了再起動として数えない (break が step-7 加算より前)
  [ "$(sup__get Demo restarts_today 0)" = "0" ]
  # ledger に当該セッションの cost が追記されている
  [ -s "$CCSU_CREDITS_LEDGER" ]
  [ "$(jq -r '.cost_usd' "$CCSU_CREDITS_LEDGER" | head -1)" = "100" ]
  # 月次消費が state へ可視化されている
  [ "$(sup__get Demo month_spent_usd 0)" = "100" ]
}
@test "sup__loop: 予算 0 (無制限) は credit-cap 評価せず通常停止" {
  cat > "$CCSU_SUP_CRON_LAUNCHER" <<'EOF'
#!/usr/bin/env bash
echo 100 > "$CLAUDEOS_SESSION_COST_FILE"
exit 0
EOF
  chmod +x "$CCSU_SUP_CRON_LAUNCHER"
  echo '{ "deploy": {"ready": false}, "supervisor": {"credit_monthly_budget_usd": 0, "max_restarts_per_day": 1, "crash_loop_min_seconds": 0} }' > "$TEST_TEMP/projects/Demo/state.json"
  run sup__loop Demo 5
  # budget=0 はガード無効 → daily-cap で停止 (credit-cap にならない)
  [ "$(sup__get Demo status '')" = "daily-cap" ]
  [ "$(sup__get Demo restarts_today 0)" = "1" ]
}

@test "sup__loop: project 個別予算が無い場合は config agentSdk.monthlyBudgetUsd を使う" {
  cat > "$AI_STARTUP_CONFIG_PATH" <<JSON
{ "projects": "$TEST_TEMP/projects", "agentSdk": { "monthlyBudgetUsd": 100 } }
JSON
  cat > "$CCSU_SUP_CRON_LAUNCHER" <<'EOF'
#!/usr/bin/env bash
echo 100 > "$CLAUDEOS_SESSION_COST_FILE"
exit 0
EOF
  chmod +x "$CCSU_SUP_CRON_LAUNCHER"
  echo '{ "deploy": {"ready": false}, "supervisor": {"max_restarts_per_day": 100, "crash_loop_min_seconds": 0} }' > "$TEST_TEMP/projects/Demo/state.json"
  run sup__loop Demo 5
  [ "$(sup__get Demo status '')" = "credit-cap" ]
  [ "$(sup__get Demo month_spent_usd 0)" = "100" ]
}

# プラン検証項目5 忠実版: 「ledger に閾値超を事前投入」した状態で、当月既存累積に
#   小さなセッション消費が積み増さって 95% を踏み越え credit-cap:stop する経路を検証。
#   単発 100% ではなく「前月までの累積 + 小セッション = 閾値超」という現実的枯渇形。
@test "sup__loop: 既存累積 ledger + 小セッションで 95% 超え credit-cap 停止 (月境界隔離)" {
  export CCSU_SUP_TODAY=2026-06-16
  # 事前投入: 当月(2026-06)に既存累積 90、別月(2026-05)に 500 (集計対象外であるべき)
  mkdir -p "$(dirname "$CCSU_CREDITS_LEDGER")"
  cat > "$CCSU_CREDITS_LEDGER" <<'JSONL'
{"ts":"2026-05-20T10:00:00+00:00","project":"Demo","cost_usd":500,"tokens_in":0,"tokens_out":0}
{"ts":"2026-06-05T10:00:00+00:00","project":"Demo","cost_usd":90,"tokens_in":0,"tokens_out":0}
JSONL
  # 当該セッションは僅か 8 (単体では 8% で無害) → 既存 90 と合算 98% で初めて閾値超
  cat > "$CCSU_SUP_CRON_LAUNCHER" <<'EOF'
#!/usr/bin/env bash
echo 8 > "$CLAUDEOS_SESSION_COST_FILE"
exit 0
EOF
  chmod +x "$CCSU_SUP_CRON_LAUNCHER"
  echo '{ "deploy": {"ready": false}, "supervisor": {"credit_monthly_budget_usd": 100, "max_restarts_per_day": 100, "crash_loop_min_seconds": 0} }' > "$TEST_TEMP/projects/Demo/state.json"
  run sup__loop Demo 5
  [ "$(sup__get Demo status '')" = "credit-cap" ]
  [ "$(sup__get Demo restarts_today 0)" = "0" ]
  # 当月のみ集計 (90 + 8 = 98)。別月 500 は混入しない
  [ "$(sup__get Demo month_spent_usd 0)" = "98" ]
  # セッション消費 8 が ledger 末尾へ追記されている (既存 2 行 + 1 = 3 行)
  [ "$(wc -l < "$CCSU_CREDITS_LEDGER")" -eq 3 ]
  [ "$(jq -rs '.[-1].cost_usd' "$CCSU_CREDITS_LEDGER")" = "8" ]
}

@test "sup__loop: 再起動ループ中に deploy.ready 反転で goal-reached (E2E)" {
  # cron-launcher stub: 2回目の呼び出しで project state.json の deploy.ready を true に
  cat > "$CCSU_SUP_CRON_LAUNCHER" <<EOF
#!/usr/bin/env bash
c="$TEST_TEMP/count"; n=\$(( \$(cat "\$c" 2>/dev/null || echo 0) + 1 )); echo "\$n" > "\$c"
if (( n >= 2 )); then echo '{ "deploy": {"ready": true} }' > "$TEST_TEMP/projects/Demo/state.json"; fi
exit 0
EOF
  chmod +x "$CCSU_SUP_CRON_LAUNCHER"
  echo '{ "deploy": {"ready": false}, "supervisor": {"crash_loop_min_seconds": 0, "max_restarts_per_day": 100} }' > "$TEST_TEMP/projects/Demo/state.json"
  run sup__loop Demo 5
  # 2 セッション走って 2 回目後に goal 検出 → 停止
  [ "$(sup__get Demo status '')" = "goal-reached" ]
  [ "$(sup__get Demo restarts_today 0)" = "2" ]
}
