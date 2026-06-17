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
