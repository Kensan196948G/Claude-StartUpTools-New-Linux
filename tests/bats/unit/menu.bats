#!/usr/bin/env bats
# ============================================================
# menu.bats — bin/menu.sh の描画テスト (--render)
# CLAUDEOS_PLAIN_OUTPUT=1 で色なし描画を検証。
# ============================================================

load '../helpers/common-setup'

setup() {
  _bats_common_setup
  export AI_STARTUP_CONFIG_PATH="$TEST_TEMP/config.json"
  cat > "$AI_STARTUP_CONFIG_PATH" <<JSON
{ "projects": "/home/kensan/Projects", "projectsDir": "/home/kensan/Projects" }
JSON
  export CCSU_STATE_FILE="$TEST_TEMP/state.json"
  export CLAUDEOS_PLAIN_OUTPUT=1
  SCRIPT="$REPO_ROOT/bin/menu.sh"
}
teardown() { _bats_common_teardown; }

@test "menu --render: ヘッダと起動項目 L1/S1" {
  echo '{ "maintenance": { "phase_mode": "development" }, "deploy": { "ready": false } }' > "$CCSU_STATE_FILE"
  run bash "$SCRIPT" --render
  [ "$status" -eq 0 ]
  [[ "$output" == *"ClaudeCode スタートアップツール"* ]]
  [[ "$output" == *"L1"* ]]
  [[ "$output" == *"S1"* ]]
  [[ "$output" == *"ローカル即起動"* ]]
  [[ "$output" == *"バックグラウンド起動"* ]]
  [[ "$output" == *"終了"* ]]
}

@test "menu --render: S1 は config.sessionMinutes 反映 (300→5h)・L1 は既定無制限" {
  export AI_STARTUP_CONFIG_PATH="$TEST_TEMP/config-dur5h.json"
  cat > "$AI_STARTUP_CONFIG_PATH" <<JSON
{ "projects": "/home/kensan/Projects", "supervisor": { "defaults": { "sessionMinutes": 300 } } }
JSON
  echo '{}' > "$CCSU_STATE_FILE"
  run bash "$SCRIPT" --render
  [ "$status" -eq 0 ]
  [[ "$output" == *"フォアグラウンド / 無制限"* ]]
  [[ "$output" == *"自律 / 5h"* ]]
}

@test "menu --render: L1 は foregroundSessionMinutes を反映 (120→2h)" {
  export AI_STARTUP_CONFIG_PATH="$TEST_TEMP/config-fg120.json"
  cat > "$AI_STARTUP_CONFIG_PATH" <<JSON
{ "projects": "/home/kensan/Projects", "supervisor": { "defaults": { "sessionMinutes": 300, "foregroundSessionMinutes": 120 } } }
JSON
  echo '{}' > "$CCSU_STATE_FILE"
  run bash "$SCRIPT" --render
  [ "$status" -eq 0 ]
  [[ "$output" == *"フォアグラウンド / 2h"* ]]
  [[ "$output" == *"自律 / 5h"* ]]
}

@test "menu --render: 起動時間ラベルは動的 (90→1h30m・ハードコード 3h でない)" {
  export AI_STARTUP_CONFIG_PATH="$TEST_TEMP/config-dur90.json"
  cat > "$AI_STARTUP_CONFIG_PATH" <<JSON
{ "projects": "/home/kensan/Projects", "supervisor": { "defaults": { "sessionMinutes": 90 } } }
JSON
  echo '{}' > "$CCSU_STATE_FILE"
  run bash "$SCRIPT" --render
  [ "$status" -eq 0 ]
  [[ "$output" == *"1h30m"* ]]
  [[ "$output" != *"3h"* ]]
}

@test "menu --render: development で DP/M 表示・I/W 非表示" {
  echo '{ "maintenance": { "phase_mode": "development" } }' > "$CCSU_STATE_FILE"
  run bash "$SCRIPT" --render
  [[ "$output" == *"デプロイ準備"* ]]
  [[ "$output" == *"保守モードへ移行"* ]]
  [[ "$output" != *"インシデント対応"* ]]
}

@test "menu --render: maintenance で I/W 表示・DP/M 非表示" {
  echo '{ "maintenance": { "phase_mode": "maintenance" } }' > "$CCSU_STATE_FILE"
  run bash "$SCRIPT" --render
  [[ "$output" == *"インシデント対応"* ]]
  [[ "$output" == *"週次 DevOps"* ]]
  [[ "$output" != *"デプロイ準備"* ]]
}

@test "menu --render: 診断ツール項目 (Linux転用の6/7含む)" {
  echo '{}' > "$CCSU_STATE_FILE"
  run bash "$SCRIPT" --render
  [[ "$output" == *"ツール確認・診断"* ]]
  [[ "$output" == *"マウント / ネットワーク疎通診断"* ]]
  [[ "$output" == *"端末 / tmux fallback セットアップ"* ]]
  [[ "$output" == *"MCP ヘルスチェック"* ]]
  [[ "$output" == *"Worktree Manager"* ]]
  [[ "$output" == *"Mission Control"* ]]
}

@test "menu --render: deploy.ready=true で完了バッジ" {
  echo '{ "maintenance": { "phase_mode": "development" }, "deploy": { "ready": true } }' > "$CCSU_STATE_FILE"
  run bash "$SCRIPT" --render
  [[ "$output" == *"デプロイ準備完了"* ]]
}

@test "menu --render: Cron 項目 14/15" {
  echo '{}' > "$CCSU_STATE_FILE"
  run bash "$SCRIPT" --render
  [[ "$output" == *"Cron スケジュール"* ]]
  [[ "$output" == *"セッション状態監視"* ]]
}

@test "menu --render: Systemd 起動管理 (SY) 項目" {
  echo '{}' > "$CCSU_STATE_FILE"
  run bash "$SCRIPT" --render
  [ "$status" -eq 0 ]
  [[ "$output" == *"Systemd 起動管理"* ]]
  [[ "$output" == *"SY"* ]]
}

@test "menu --render: projectGroups 設定時は番号付き見出しとグループ別 L1/L2 直結行を表示" {
  export AI_STARTUP_CONFIG_PATH="$TEST_TEMP/config-groups.json"
  cat > "$AI_STARTUP_CONFIG_PATH" <<JSON
{ "projects": "/home/kensan/Projects", "projectGroups": ["Mirai-DX-Project","Mirai-Project"] }
JSON
  echo '{}' > "$CCSU_STATE_FILE"
  run bash "$SCRIPT" --render
  [ "$status" -eq 0 ]
  # ヘッダー: 1 グループ 1 行の番号付き見出し (旧: カンマ結合 1 行)
  [[ "$output" == *"実行グループ (1): Mirai-DX-Project"* ]]
  [[ "$output" == *"実行グループ (2): Mirai-Project"* ]]
  [[ "$output" != *"Mirai-DX-Project, Mirai-Project"* ]]
  # 起動: グループごとの L 行 (フルパス付き)
  [[ "$output" == *"ローカル即起動 (フォアグラウンド / 無制限) /home/kensan/Projects/Mirai-DX-Project"* ]]
  [[ "$output" == *"ローカル即起動 (フォアグラウンド / 無制限) /home/kensan/Projects/Mirai-Project"* ]]
  [[ "$output" == *"L1"* ]]
  [[ "$output" == *"L2"* ]]
}

@test "menu --render: projectGroups 未設定時は L1 単独で L2 行は無い" {
  echo '{}' > "$CCSU_STATE_FILE"
  run bash "$SCRIPT" --render
  [ "$status" -eq 0 ]
  [[ "$output" == *"L1"* ]]
  [[ "$output" != *"L2"* ]]
  [[ "$output" != *"実行グループ"* ]]
}

@test "menu: 不明引数でエラー" {
  run bash "$SCRIPT" --frobnicate
  [ "$status" -ne 0 ]
}

@test "confirm_yes_no: CCSU_ASSUME_YES=1 は対話なしで Yes" {
  run bash -c '
    source "'"$SCRIPT"'"
    export CCSU_ASSUME_YES=1
    confirm_yes_no "実行?" </dev/null && echo OK_YES
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK_YES"* ]]
}

@test "confirm_yes_no: y / yes は真、空入力や n は偽" {
  run bash -c '
    source "'"$SCRIPT"'"
    printf "y\n"   | confirm_yes_no "?" && echo Y_OK
    printf "yes\n" | confirm_yes_no "?" && echo YES_OK
    printf "n\n"   | confirm_yes_no "?" || echo N_NG
    printf "\n"    | confirm_yes_no "?" || echo EMPTY_NG
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"Y_OK"* ]]
  [[ "$output" == *"YES_OK"* ]]
  [[ "$output" == *"N_NG"* ]]
  [[ "$output" == *"EMPTY_NG"* ]]
}

@test "launch_claude: No 選択で start-claude.sh を実行しない" {
  run bash -c '
    source "'"$SCRIPT"'"
    launcher__select_project() { printf "Alpha\n"; }
    run_menu_script() { echo "RUN_MENU_SCRIPT_CALLED $*"; }
    confirm_yes_no() { return 1; }   # No 相当
    launch_claude foreground
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"キャンセル"* ]]
  [[ "$output" != *"RUN_MENU_SCRIPT_CALLED"* ]]
}

@test "launch_claude: Yes 選択で start-claude.sh を mode 付きで実行" {
  run bash -c '
    source "'"$SCRIPT"'"
    launcher__select_project() { printf "Alpha\n"; }
    run_menu_script() { echo "RUN_MENU_SCRIPT_CALLED $*"; }
    confirm_yes_no() { return 0; }   # Yes 相当
    launch_claude background
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"RUN_MENU_SCRIPT_CALLED"* ]]
  [[ "$output" == *"--project Alpha --background"* ]]
}

@test "launch_claude: 第2引数 group を launcher__select_project へ透過する" {
  run bash -c '
    source "'"$SCRIPT"'"
    launcher__select_project() { echo "SELECT mode=$1 group=${2:-}" >&2; printf "GroupB/App3\n"; }
    run_menu_script() { echo "RUN_MENU_SCRIPT_CALLED $*"; }
    confirm_yes_no() { return 0; }
    launch_claude foreground GroupB
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"SELECT mode=foreground group=GroupB"* ]]
  [[ "$output" == *"--project GroupB/App3 --foreground"* ]]
}

@test "menu_loop: L2 は第2グループを引数に launch_claude foreground を呼ぶ (小文字 l2 も同様)" {
  export AI_STARTUP_CONFIG_PATH="$TEST_TEMP/config-groups.json"
  cat > "$AI_STARTUP_CONFIG_PATH" <<JSON
{ "projects": "/home/kensan/Projects", "projectGroups": ["Mirai-DX-Project","Mirai-Project"] }
JSON
  echo '{}' > "$CCSU_STATE_FILE"
  run bash -c '
    source "'"$SCRIPT"'"
    launch_claude() { echo "LAUNCH mode=$1 group=${2:-none}"; exit 0; }
    printf "L2\n" | menu_loop
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"LAUNCH mode=foreground group=Mirai-Project"* ]]
  run bash -c '
    source "'"$SCRIPT"'"
    launch_claude() { echo "LAUNCH mode=$1 group=${2:-none}"; exit 0; }
    printf "l1\n" | menu_loop
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"LAUNCH mode=foreground group=Mirai-DX-Project"* ]]
}

@test "menu_loop: 範囲外 L9 は無効入力扱いで launch_claude を呼ばない" {
  export AI_STARTUP_CONFIG_PATH="$TEST_TEMP/config-groups.json"
  cat > "$AI_STARTUP_CONFIG_PATH" <<JSON
{ "projects": "/home/kensan/Projects", "projectGroups": ["Mirai-DX-Project","Mirai-Project"] }
JSON
  echo '{}' > "$CCSU_STATE_FILE"
  run bash -c '
    source "'"$SCRIPT"'"
    launch_claude() { echo "LAUNCH_CALLED"; exit 0; }
    printf "L9\n0\n" | menu_loop
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"無効な入力"* ]]
  [[ "$output" != *"LAUNCH_CALLED"* ]]
}

@test "menu_loop: projectGroups 未設定時は L1 がフラット起動 (group なし)・L2 は無効" {
  echo '{}' > "$CCSU_STATE_FILE"
  run bash -c '
    source "'"$SCRIPT"'"
    launch_claude() { echo "LAUNCH mode=$1 group=${2:-none}"; exit 0; }
    printf "L1\n" | menu_loop
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"LAUNCH mode=foreground group=none"* ]]
  run bash -c '
    source "'"$SCRIPT"'"
    launch_claude() { echo "LAUNCH_CALLED"; exit 0; }
    printf "L2\n0\n" | menu_loop
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"無効な入力"* ]]
  [[ "$output" != *"LAUNCH_CALLED"* ]]
}
