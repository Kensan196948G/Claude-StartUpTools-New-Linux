#!/usr/bin/env bats
# ============================================================
# queue.bats — lib/queue.sh のユニットテスト
#
# 検証観点:
#   - priority: security_critical / blocked_issues / throttle tier / starvation 加点
#   - order: スコア降順 → 名前昇順の安定整列 (config_project_list 出力を並べ替え)
# ============================================================

load '../helpers/common-setup'

setup() {
  _bats_common_setup
  export AI_STARTUP_CONFIG_PATH="$TEST_TEMP/config.json"
  printf '{ "projects": "%s/projects" }\n' "$TEST_TEMP" > "$AI_STARTUP_CONFIG_PATH"
  export CCSU_SUP_TODAY=2026-06-15
  BASE="$TEST_TEMP/projects"; mkdir -p "$BASE"
  source "$REPO_ROOT/lib/queue.sh"
}
teardown() { _bats_common_teardown; }

# pstate 生成ヘルパ: <name> <json>
_mkproj() { mkdir -p "$BASE/$1"; printf '%s\n' "$2" > "$BASE/$1/state.json"; }

# ---- priority -------------------------------------------
@test "queue__project_priority: ファイル不在は 0" {
  run queue__project_priority "$BASE/none/state.json"
  [ "$output" = "0" ]
}
@test "queue__project_priority: 正常 (緊急要素なし) は 0" {
  _mkproj Calm '{ "kpi": {"security_critical": 0}, "blocked_issues": [] }'
  run queue__project_priority "$BASE/Calm/state.json" 2026-06-15
  [ "$output" = "0" ]
}
@test "queue__project_priority: security_critical>0 は最優先級 (>=1000)" {
  _mkproj Sec '{ "kpi": {"security_critical": 1}, "blocked_issues": [] }'
  run queue__project_priority "$BASE/Sec/state.json" 2026-06-15
  [ "$output" -ge 1000 ]
}
@test "queue__project_priority: blocked_issues 非空は加点 (>=500)" {
  _mkproj Blk '{ "kpi": {"security_critical": 0}, "blocked_issues": ["#1","#2"] }'
  run queue__project_priority "$BASE/Blk/state.json" 2026-06-15
  [ "$output" -ge 500 ]
}
@test "queue__project_priority: 残7 tier は throttle 加点 (t7=200)" {
  _mkproj Near '{ "kpi": {"security_critical": 0}, "blocked_issues": [], "project": {"release_deadline": "2026-06-20"} }'
  run queue__project_priority "$BASE/Near/state.json" 2026-06-15
  [ "$output" = "200" ]
}
@test "queue__project_priority: 24h 超未起動は starvation 加点" {
  _mkproj Old '{ "kpi": {"security_critical": 0}, "blocked_issues": [], "execution": {"last_session_at": "2026-06-10T00:00:00+00:00"} }'
  now="$(date -d 2026-06-15T00:00:00+00:00 +%s)"
  run queue__project_priority "$BASE/Old/state.json" 2026-06-15 "$now"
  [ "$output" = "50" ]
}
@test "queue__project_priority: now 未指定なら starvation 加点しない" {
  _mkproj Old2 '{ "blocked_issues": [], "execution": {"last_session_at": "2026-06-10T00:00:00+00:00"} }'
  run queue__project_priority "$BASE/Old2/state.json" 2026-06-15
  [ "$output" = "0" ]
}

# ---- order ----------------------------------------------
@test "queue__order: スコア降順・同点は名前昇順で整列" {
  _mkproj Alpha '{ "kpi": {"security_critical": 0}, "blocked_issues": [] }'
  _mkproj Bravo '{ "kpi": {"security_critical": 1}, "blocked_issues": [] }'
  _mkproj Cobra '{ "kpi": {"security_critical": 0}, "blocked_issues": ["#1"] }'
  run bash -c "printf 'Alpha\nBravo\nCobra\n' | { source '$REPO_ROOT/lib/queue.sh'; queue__order '$BASE' 2026-06-15; }"
  [ "${lines[0]}" = "Bravo" ]   # security=1000
  [ "${lines[1]}" = "Cobra" ]   # blocked=500
  [ "${lines[2]}" = "Alpha" ]   # 0
}
@test "queue__order: 完全同点は名前昇順で安定" {
  _mkproj Zeta  '{ "blocked_issues": [] }'
  _mkproj Apple '{ "blocked_issues": [] }'
  run bash -c "printf 'Zeta\nApple\n' | { source '$REPO_ROOT/lib/queue.sh'; queue__order '$BASE' 2026-06-15; }"
  [ "${lines[0]}" = "Apple" ]
  [ "${lines[1]}" = "Zeta" ]
}
