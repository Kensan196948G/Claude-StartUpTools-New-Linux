#!/usr/bin/env bats
# ============================================================
# systemd-manager.bats — lib/systemd-manager.sh + bin/systemd-control.sh のユニットテスト
#
# 実マシンの systemd を触らないよう密閉化:
#   - CCSU_SYSTEMCTL_BIN : 引数をエコーするだけの systemctl スタブ
#   - CCSU_SYSTEMD_USER_DIR : unit 配置先 (一時 dir)
#   - CCSU_SYSTEMD_REGISTRY : 台帳 (一時ファイル)
#   これらは systemd-manager.sh を source する「前」に export する。
# ============================================================

load '../helpers/common-setup'

setup() {
  _bats_common_setup
  PROJECTS="$TEST_TEMP/Projects"
  mkdir -p "$PROJECTS"
  export AI_STARTUP_CONFIG_PATH="$TEST_TEMP/config.json"
  printf '{ "projects": "%s" }\n' "$PROJECTS" > "$AI_STARTUP_CONFIG_PATH"

  export CCSU_SYSTEMD_REGISTRY="$TEST_TEMP/systemd-registry.json"
  export CCSU_SYSTEMD_USER_DIR="$TEST_TEMP/systemd-user"
  export CCSU_SYSTEMCTL_BIN="$TEST_TEMP/bin/systemctl"
  mkdir -p "$TEST_TEMP/bin"
  printf '#!/usr/bin/env bash\necho "SYSTEMCTL $*"\nexit 0\n' > "$CCSU_SYSTEMCTL_BIN"
  chmod +x "$CCSU_SYSTEMCTL_BIN"

  source "$REPO_ROOT/lib/config-loader.sh"   # → json.sh → common.sh (CCSU_CONFIG_PATH 設定)
  source "$REPO_ROOT/lib/systemd-manager.sh"
}
teardown() { _bats_common_teardown; }

# --- ヘルパ: プロジェクトを作る ---
_mk_project() {   # <name> [files...]
  local name="$1"; shift
  local d="$PROJECTS/$name"
  mkdir -p "$d/.git"
  local f
  for f in "$@"; do
    mkdir -p "$(dirname "$d/$f")"
    printf '{}' > "$d/$f"
  done
  printf '%s' "$d"
}

# --- unit 名の正規化 ---
@test "sysd_unit_name: 通常名は claudeos-<name>.service" {
  run sysd_unit_name "Alpha"
  [ "$output" = "claudeos-Alpha.service" ]
}

@test "sysd_unit_name: グループ/サブ複合名は / を _ へ正規化" {
  run sysd_unit_name "Group/Sub"
  [ "$output" = "claudeos-Group_Sub.service" ]
}

# --- 起動コマンド推定 ---
@test "sysd_infer_command: package.json の start → npm start" {
  local d="$TEST_TEMP/p1"; mkdir -p "$d"
  printf '{ "scripts": { "start": "node ." } }\n' > "$d/package.json"
  run sysd_infer_command "$d"
  [ "$output" = "npm start" ]
}

@test "sysd_infer_command: server.js → node server.js" {
  local d="$TEST_TEMP/p2"; mkdir -p "$d"; touch "$d/server.js"
  run sysd_infer_command "$d"
  [ "$output" = "node server.js" ]
}

@test "sysd_infer_command: main.py → python3 / Cargo.toml → cargo / go.mod → go" {
  local a="$TEST_TEMP/py"; mkdir -p "$a"; touch "$a/main.py"
  run sysd_infer_command "$a"; [ "$output" = "python3 main.py" ]
  local b="$TEST_TEMP/rs"; mkdir -p "$b"; touch "$b/Cargo.toml"
  run sysd_infer_command "$b"; [ "$output" = "cargo run --release" ]
  local c="$TEST_TEMP/go"; mkdir -p "$c"; touch "$c/go.mod"
  run sysd_infer_command "$c"; [ "$output" = "go run ." ]
}

@test "sysd_infer_command: 推定不能なら空" {
  local d="$TEST_TEMP/none"; mkdir -p "$d"
  run sysd_infer_command "$d"
  [ -z "$output" ]
}

# --- 台帳 CRUD ---
@test "sysd_registry: put → get / has / list / enabled_list / set_enabled / remove" {
  _mk_project Demo >/dev/null
  sysd_registry_put "Demo" "npm start" "$PROJECTS/Demo" false "2026-01-01T00:00:00Z"
  run sysd_registry_get "Demo" command;    [ "$output" = "npm start" ]
  run sysd_registry_get "Demo" workingDir; [ "$output" = "$PROJECTS/Demo" ]
  run sysd_registry_has "Demo";            [ "$status" -eq 0 ]
  run sysd_registry_has "Nope";            [ "$status" -ne 0 ]
  run sysd_registry_list;                  [[ "$output" == *"Demo"* ]]

  # 既定 enabled=false は enabled_list に出ない
  run sysd_registry_enabled_list;          [[ "$output" != *"Demo"* ]]
  sysd_registry_set_enabled "Demo" true
  run sysd_registry_enabled_list;          [[ "$output" == *"Demo"* ]]

  sysd_registry_remove "Demo"
  run sysd_registry_has "Demo";            [ "$status" -ne 0 ]
}

# --- command 解決の優先順位: 台帳 > config.service > 推定 ---
@test "sysd_resolve_command: 台帳 > config.service > 推定 の優先順位" {
  _mk_project Demo "package.json" >/dev/null
  # package.json は start 無し (推定は空) → server.js を置いて推定=node server.js
  touch "$PROJECTS/Demo/server.js"
  run sysd_resolve_command "Demo"; [ "$output" = "node server.js" ]   # 3. 推定

  printf '{ "projects": "%s", "service": { "Demo": { "command": "node custom.js" } } }\n' "$PROJECTS" > "$AI_STARTUP_CONFIG_PATH"
  run sysd_resolve_command "Demo"; [ "$output" = "node custom.js" ]   # 2. config.service

  sysd_registry_put "Demo" "npm run serve" "$PROJECTS/Demo"
  run sysd_resolve_command "Demo"; [ "$output" = "npm run serve" ]    # 1. 台帳
}

# --- unit 生成 ---
@test "sysd_render_unit: ExecStart / WorkingDirectory / WantedBy を含む" {
  run sysd_render_unit "Demo" "npm start" "/home/x/Projects/Demo"
  [[ "$output" == *"ExecStart=/bin/bash -lc 'npm start'"* ]]
  [[ "$output" == *"WorkingDirectory=/home/x/Projects/Demo"* ]]
  [[ "$output" == *"WantedBy=default.target"* ]]
  [[ "$output" == *"Description=ClaudeOS service: Demo"* ]]
}

@test "sysd_write_unit / sysd_remove_unit: ファイル生成と削除" {
  sysd_write_unit "Demo" "npm start" "$PROJECTS/Demo"
  local path="$CCSU_SYSTEMD_USER_DIR/claudeos-Demo.service"
  [ -f "$path" ]
  grep -q "ExecStart=/bin/bash -lc 'npm start'" "$path"
  sysd_remove_unit "Demo"
  [ ! -f "$path" ]
}

# --- systemctl 可用性 ---
@test "sysd_available: stub present → 0 / absent → 非0" {
  SYSTEMCTL="$CCSU_SYSTEMCTL_BIN"
  run sysd_available; [ "$status" -eq 0 ]
  SYSTEMCTL="/nonexistent/definitely/systemctl"
  run sysd_available; [ "$status" -ne 0 ]
}

# ============================================================
# bin/systemd-control.sh (CLI 表層)
# ============================================================

@test "systemd-control: help は使い方を表示し exit 0" {
  run bash "$REPO_ROOT/bin/systemd-control.sh" help
  [ "$status" -eq 0 ]
  [[ "$output" == *"systemd-control.sh"* ]]
  [[ "$output" == *"start-all"* ]]
}

@test "systemd-control: scan は推定コマンド付きでプロジェクトを列挙" {
  _mk_project Demo >/dev/null; touch "$PROJECTS/Demo/server.js"
  run bash "$REPO_ROOT/bin/systemd-control.sh" scan
  [ "$status" -eq 0 ]
  [[ "$output" == *"Demo"* ]]
  [[ "$output" == *"node server.js"* ]]
}

@test "systemd-control: register → list に載る / generate → unit 生成" {
  _mk_project Demo >/dev/null; touch "$PROJECTS/Demo/server.js"
  run bash "$REPO_ROOT/bin/systemd-control.sh" register Demo
  [ "$status" -eq 0 ]
  run bash "$REPO_ROOT/bin/systemd-control.sh" list
  [[ "$output" == *"Demo"* ]]
  [[ "$output" == *"node server.js"* ]]

  run bash "$REPO_ROOT/bin/systemd-control.sh" generate Demo
  [ "$status" -eq 0 ]
  [ -f "$CCSU_SYSTEMD_USER_DIR/claudeos-Demo.service" ]
}

@test "systemd-control: register --command で明示指定が推定より優先" {
  _mk_project Demo "package.json" >/dev/null
  run bash "$REPO_ROOT/bin/systemd-control.sh" register Demo --command "node dist/main.js"
  [ "$status" -eq 0 ]
  run sysd_registry_get "Demo" command
  [ "$output" = "node dist/main.js" ]
}

@test "systemd-control: --dry-run は台帳・unit を作らない" {
  _mk_project Demo >/dev/null; touch "$PROJECTS/Demo/server.js"
  run bash "$REPO_ROOT/bin/systemd-control.sh" register Demo --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"dry-run"* ]]
  [ ! -f "$CCSU_SYSTEMD_REGISTRY" ]
  run bash "$REPO_ROOT/bin/systemd-control.sh" generate Demo --dry-run
  [ "$status" -eq 0 ]
  [ ! -f "$CCSU_SYSTEMD_USER_DIR/claudeos-Demo.service" ]
}

@test "systemd-control: 存在しないプロジェクトの register は失敗" {
  run bash "$REPO_ROOT/bin/systemd-control.sh" register NoSuchProject
  [ "$status" -ne 0 ]
}

@test "systemd-control: 不明サブコマンドは exit 1" {
  run bash "$REPO_ROOT/bin/systemd-control.sh" frobnicate
  [ "$status" -eq 1 ]
}
