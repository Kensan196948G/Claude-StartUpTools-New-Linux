#!/usr/bin/env bats
# ============================================================
# launcher-common.bats — lib/launcher-common.sh のユニットテスト
# Linux ローカル候補列挙の検証。
# ============================================================

load '../helpers/common-setup'

setup() {
  _bats_common_setup
  export AI_STARTUP_CONFIG_PATH="$TEST_TEMP/config.json"
  cat > "$AI_STARTUP_CONFIG_PATH" <<JSON
{ "projects": "$TEST_TEMP/projects", "projectsDir": "$TEST_TEMP/projects" }
JSON
  mkdir -p "$TEST_TEMP/projects/Alpha/.git" "$TEST_TEMP/projects/Beta/.git" "$TEST_TEMP/projects/Worktree"
  printf 'gitdir: /tmp/main/.git/worktrees/Worktree\n' > "$TEST_TEMP/projects/Worktree/.git"
  mkdir -p "$TEST_TEMP/projects/NotGit"   # 非Gitディレクトリ (除外対象)
  touch "$TEST_TEMP/projects/.hidden" "$TEST_TEMP/projects/notes.md"  # 隠し/ファイル (除外対象)

  # supervisor ディレクトリをテスト用 TEST_TEMP 以下に向け、本番 JSON を参照しない
  export CLAUDEOS_HOME="$TEST_TEMP/claudeos"
  export CCSU_SUP_DIR="$TEST_TEMP/claudeos/supervisor"
  mkdir -p "$CCSU_SUP_DIR"

  source "$REPO_ROOT/lib/launcher-common.sh"
}
teardown() { _bats_common_teardown; }

# ─── launcher__project_list ───────────────────────────────────

@test "launcher__project_list: プロジェクトを列挙" {
  run launcher__project_list
  [[ "$output" == *"Alpha"* ]]
  [[ "$output" == *"Beta"* ]]
}

@test "launcher__project_list: 隠しエントリを除外" {
  run launcher__project_list
  [[ "$output" != *".hidden"* ]]
}

@test "launcher__project_list: 非Gitディレクトリとファイルを除外 (.git dir/file のみ)" {
  run launcher__project_list
  [[ "$output" != *"NotGit"* ]]
  [[ "$output" != *"notes.md"* ]]
  [[ "$output" == *"Alpha"* ]]
  [[ "$output" == *"Worktree"* ]]
}

# ─── launcher__project_dir / exists ──────────────────────────

@test "launcher__project_dir: 絶対パスを返す" {
  run launcher__project_dir Alpha
  [ "$output" = "$TEST_TEMP/projects/Alpha" ]
}

@test "launcher__project_exists: 存在すれば 0" {
  run launcher__project_exists Alpha
  [ "$status" -eq 0 ]
}

@test "launcher__project_exists: 不在なら非0" {
  run launcher__project_exists NoSuch
  [ "$status" -ne 0 ]
}

# ─── launcher__select_project (後方互換) ─────────────────────

@test "launcher__select_project: 番号1でソート先頭(Alpha)を選択" {
  run bash -c "source '$REPO_ROOT/lib/launcher-common.sh'; printf '1\n' | launcher__select_project 2>/dev/null"
  [ "$output" = "Alpha" ]
}

@test "launcher__select_project: 範囲外番号は空" {
  run bash -c "source '$REPO_ROOT/lib/launcher-common.sh'; printf '99\n' | launcher__select_project 2>/dev/null"
  [ "$output" = "" ]
}

# ─── launcher__project_run_status ────────────────────────────

_mk_sup_json() {
  # _mk_sup_json <project> <status> [pid]
  local proj="$1" status="$2" pid="${3:-0}"
  local safe; safe="$(printf '%s' "$proj" | tr -c 'A-Za-z0-9_-' '_')"
  cat >"$CCSU_SUP_DIR/${safe}.json" <<EOF
{"project":"$proj","status":"$status","pid":$pid}
EOF
}

@test "launcher__project_run_status: supervisor JSON なし → ok" {
  run bash -c "
    export AI_STARTUP_CONFIG_PATH='$AI_STARTUP_CONFIG_PATH'
    export CCSU_SUP_DIR='$CCSU_SUP_DIR'
    source '$REPO_ROOT/lib/launcher-common.sh'
    launcher__project_run_status 'Alpha'
  "
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "launcher__project_run_status: status=goal-reached → goal-reached" {
  _mk_sup_json "Alpha" "goal-reached" "0"
  run bash -c "
    export AI_STARTUP_CONFIG_PATH='$AI_STARTUP_CONFIG_PATH'
    export CCSU_SUP_DIR='$CCSU_SUP_DIR'
    source '$REPO_ROOT/lib/launcher-common.sh'
    launcher__project_run_status 'Alpha'
  "
  [ "$status" -eq 0 ]
  [ "$output" = "goal-reached" ]
}

@test "launcher__project_run_status: status=crash-loop → crash-loop" {
  _mk_sup_json "Alpha" "crash-loop" "0"
  run bash -c "
    export AI_STARTUP_CONFIG_PATH='$AI_STARTUP_CONFIG_PATH'
    export CCSU_SUP_DIR='$CCSU_SUP_DIR'
    source '$REPO_ROOT/lib/launcher-common.sh'
    launcher__project_run_status 'Alpha'
  "
  [ "$status" -eq 0 ]
  [ "$output" = "crash-loop" ]
}

@test "launcher__project_run_status: status=running PID存在 → running" {
  _mk_sup_json "Alpha" "running" "$$"   # $$ = bats PID (生存確実)
  run bash -c "
    export AI_STARTUP_CONFIG_PATH='$AI_STARTUP_CONFIG_PATH'
    export CCSU_SUP_DIR='$CCSU_SUP_DIR'
    source '$REPO_ROOT/lib/launcher-common.sh'
    launcher__project_run_status 'Alpha'
  "
  [ "$status" -eq 0 ]
  [ "$output" = "running" ]
}

@test "launcher__project_run_status: status=running PID不在 → ok" {
  _mk_sup_json "Alpha" "running" "999999999"   # 存在しない PID
  run bash -c "
    export AI_STARTUP_CONFIG_PATH='$AI_STARTUP_CONFIG_PATH'
    export CCSU_SUP_DIR='$CCSU_SUP_DIR'
    source '$REPO_ROOT/lib/launcher-common.sh'
    launcher__project_run_status 'Alpha'
  "
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "launcher__project_run_status: status=blocked halt=true → blocked" {
  _mk_sup_json "Alpha" "blocked" "0"
  # state.json に halt_on_blocked=true を設定
  mkdir -p "$TEST_TEMP/projects/Alpha"
  cat >"$TEST_TEMP/projects/Alpha/state.json" <<'EOF'
{"supervisor":{"halt_on_blocked":true}}
EOF
  run bash -c "
    export AI_STARTUP_CONFIG_PATH='$AI_STARTUP_CONFIG_PATH'
    export CCSU_SUP_DIR='$CCSU_SUP_DIR'
    source '$REPO_ROOT/lib/launcher-common.sh'
    launcher__project_run_status 'Alpha'
  "
  [ "$status" -eq 0 ]
  [ "$output" = "blocked" ]
}

@test "launcher__project_run_status: status=blocked halt=false → ok" {
  _mk_sup_json "Alpha" "blocked" "0"
  mkdir -p "$TEST_TEMP/projects/Alpha"
  cat >"$TEST_TEMP/projects/Alpha/state.json" <<'EOF'
{"supervisor":{"halt_on_blocked":false}}
EOF
  run bash -c "
    export AI_STARTUP_CONFIG_PATH='$AI_STARTUP_CONFIG_PATH'
    export CCSU_SUP_DIR='$CCSU_SUP_DIR'
    source '$REPO_ROOT/lib/launcher-common.sh'
    launcher__project_run_status 'Alpha'
  "
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

# ─── launcher__select_project: mode ──────────────────────────

@test "launcher__select_project: running プロジェクトも foreground で選択可" {
  _mk_sup_json "Alpha" "running" "$$"   # Alpha = running (PID 生存)
  run bash -c "
    export AI_STARTUP_CONFIG_PATH='$AI_STARTUP_CONFIG_PATH'
    export CCSU_SUP_DIR='$CCSU_SUP_DIR'
    source '$REPO_ROOT/lib/launcher-common.sh'
    printf '1\n' | launcher__select_project foreground 2>/dev/null
  "
  [ "$status" -eq 0 ]
  [ "$output" = "Alpha" ]
}

@test "launcher__select_project: goal-reached は foreground で選択可 (番号付き)" {
  _mk_sup_json "Alpha" "goal-reached" "0"
  # Alpha=goal-reached, Beta=ok → 両方選択可。'1'=Alpha
  run bash -c "
    export AI_STARTUP_CONFIG_PATH='$AI_STARTUP_CONFIG_PATH'
    export CCSU_SUP_DIR='$CCSU_SUP_DIR'
    source '$REPO_ROOT/lib/launcher-common.sh'
    printf '1\n' | launcher__select_project foreground 2>/dev/null
  "
  [ "$status" -eq 0 ]
  [ "$output" = "Alpha" ]
}

@test "launcher__select_project: goal-reached は background でも選択可" {
  _mk_sup_json "Alpha" "goal-reached" "0"
  # Alpha=goal-reached(選択可), Beta=ok(選択可) → 1番=Alpha
  run bash -c "
    export AI_STARTUP_CONFIG_PATH='$AI_STARTUP_CONFIG_PATH'
    export CCSU_SUP_DIR='$CCSU_SUP_DIR'
    source '$REPO_ROOT/lib/launcher-common.sh'
    printf '1\n' | launcher__select_project background 2>/dev/null
  "
  [ "$status" -eq 0 ]
  [ "$output" = "Alpha" ]
}

@test "launcher__select_project: blocked(halt=true) は background でも選択可" {
  _mk_sup_json "Alpha" "blocked" "0"
  mkdir -p "$TEST_TEMP/projects/Alpha"
  printf '{"supervisor":{"halt_on_blocked":true}}' >"$TEST_TEMP/projects/Alpha/state.json"
  # Alpha=blocked(選択可), Beta=ok(選択可) → 1番=Alpha
  run bash -c "
    export AI_STARTUP_CONFIG_PATH='$AI_STARTUP_CONFIG_PATH'
    export CCSU_SUP_DIR='$CCSU_SUP_DIR'
    source '$REPO_ROOT/lib/launcher-common.sh'
    printf '1\n' | launcher__select_project background 2>/dev/null
  "
  [ "$status" -eq 0 ]
  [ "$output" = "Alpha" ]
}

@test "launcher__select_project: /exit は空を返して戻る" {
  _mk_sup_json "Alpha" "running" "$$"
  _mk_sup_json "Beta"  "running" "$$"
  _mk_sup_json "Worktree" "running" "$$"
  run bash -c "
    export AI_STARTUP_CONFIG_PATH='$AI_STARTUP_CONFIG_PATH'
    export CCSU_SUP_DIR='$CCSU_SUP_DIR'
    source '$REPO_ROOT/lib/launcher-common.sh'
    printf '/exit\n' | launcher__select_project foreground 2>/dev/null
  "
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

# ─── launcher__select_project: 2段階 (projectGroups) ─────────

_setup_groups() {
  local base="$TEST_TEMP/gprojects"
  mkdir -p "$base/GroupA/App1/.git" "$base/GroupA/App2/.git" "$base/GroupB/App3/.git"
  mkdir -p "$base/Loose/.git"   # スコープ外の単独リポジトリ
  cat > "$TEST_TEMP/gconfig.json" <<JSON
{ "projects": "$base", "projectGroups": ["GroupA","GroupB"] }
JSON
}

@test "select(grouped): グループ1→サブ2 で GroupA/App2 を返す" {
  _setup_groups
  run bash -c "
    export AI_STARTUP_CONFIG_PATH='$TEST_TEMP/gconfig.json'
    export CCSU_SUP_DIR='$CCSU_SUP_DIR'
    source '$REPO_ROOT/lib/launcher-common.sh'
    printf '1\n2\n' | launcher__select_project foreground 2>/dev/null
  "
  [ "$output" = "GroupA/App2" ]
}

@test "select(grouped): グループ2→サブ1 で GroupB/App3 を返す" {
  _setup_groups
  run bash -c "
    export AI_STARTUP_CONFIG_PATH='$TEST_TEMP/gconfig.json'
    export CCSU_SUP_DIR='$CCSU_SUP_DIR'
    source '$REPO_ROOT/lib/launcher-common.sh'
    printf '2\n1\n' | launcher__select_project foreground 2>/dev/null
  "
  [ "$output" = "GroupB/App3" ]
}

@test "select(grouped): スコープ外 (Loose) は候補に出ない" {
  _setup_groups
  run bash -c "
    export AI_STARTUP_CONFIG_PATH='$TEST_TEMP/gconfig.json'
    export CCSU_SUP_DIR='$CCSU_SUP_DIR'
    source '$REPO_ROOT/lib/launcher-common.sh'
    printf '1\n1\n' | launcher__select_project foreground
  " 2>&1
  [[ "$output" != *"Loose"* ]]
}

@test "select(grouped): グループ選択で 0 は空を返して戻る" {
  _setup_groups
  run bash -c "
    export AI_STARTUP_CONFIG_PATH='$TEST_TEMP/gconfig.json'
    export CCSU_SUP_DIR='$CCSU_SUP_DIR'
    source '$REPO_ROOT/lib/launcher-common.sh'
    printf '0\n' | launcher__select_project foreground 2>/dev/null
  "
  [ "$output" = "" ]
}

@test "select(grouped): サブ選択で 0 はグループ選択へ戻り再選択できる" {
  _setup_groups
  # グループ1 → サブ 0(戻る) → グループ2 → サブ1 = GroupB/App3
  run bash -c "
    export AI_STARTUP_CONFIG_PATH='$TEST_TEMP/gconfig.json'
    export CCSU_SUP_DIR='$CCSU_SUP_DIR'
    source '$REPO_ROOT/lib/launcher-common.sh'
    printf '1\n0\n2\n1\n' | launcher__select_project foreground 2>/dev/null
  "
  [ "$output" = "GroupB/App3" ]
}

# ─── launcher__select_project: 単一グループ (グループ選択スキップ) ─

_setup_single_group() {
  local base="$TEST_TEMP/sgprojects"
  mkdir -p "$base/GroupA/App1/.git" "$base/GroupA/App2/.git"
  cat > "$TEST_TEMP/sgconfig.json" <<JSON
{ "projects": "$base", "projectGroups": ["GroupA"] }
JSON
}

@test "select(single-group): グループ選択を省略し番号1回で GroupA/App1 を返す" {
  _setup_single_group
  run bash -c "
    export AI_STARTUP_CONFIG_PATH='$TEST_TEMP/sgconfig.json'
    export CCSU_SUP_DIR='$CCSU_SUP_DIR'
    source '$REPO_ROOT/lib/launcher-common.sh'
    printf '1\n' | launcher__select_project foreground 2>/dev/null
  "
  [ "$output" = "GroupA/App1" ]
}

@test "select(single-group): グループ選択画面を表示しない" {
  _setup_single_group
  run bash -c "
    export AI_STARTUP_CONFIG_PATH='$TEST_TEMP/sgconfig.json'
    export CCSU_SUP_DIR='$CCSU_SUP_DIR'
    source '$REPO_ROOT/lib/launcher-common.sh'
    printf '1\n' | launcher__select_project foreground
  " 2>&1
  [[ "$output" != *"グループ選択 ["* ]]
  [[ "$output" == *"GroupA のプロジェクト"* ]]
}

@test "select(single-group): 0 は空を返して終了する (無限ループしない)" {
  _setup_single_group
  run bash -c "
    export AI_STARTUP_CONFIG_PATH='$TEST_TEMP/sgconfig.json'
    export CCSU_SUP_DIR='$CCSU_SUP_DIR'
    source '$REPO_ROOT/lib/launcher-common.sh'
    printf '0\n' | launcher__select_project foreground 2>/dev/null
  "
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "select(single-group): サブが 0 件なら空を返して終了する" {
  local base="$TEST_TEMP/sgempty"
  mkdir -p "$base/GroupA"
  cat > "$TEST_TEMP/sgempty.json" <<JSON
{ "projects": "$base", "projectGroups": ["GroupA"] }
JSON
  run bash -c "
    export AI_STARTUP_CONFIG_PATH='$TEST_TEMP/sgempty.json'
    export CCSU_SUP_DIR='$CCSU_SUP_DIR'
    source '$REPO_ROOT/lib/launcher-common.sh'
    launcher__select_project foreground </dev/null 2>/dev/null
  "
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}
