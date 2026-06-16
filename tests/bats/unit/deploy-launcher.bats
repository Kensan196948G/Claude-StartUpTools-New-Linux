#!/usr/bin/env bats
# ============================================================
# deploy-launcher.bats — lib/deploy-launcher.sh 配備ロジックの単体テスト
#
# 検証観点 (恒久ドリフト対策):
#   - 冪等性: テンプレと配備先が同一なら no-op (バックアップを作らない)
#   - 差分時: 既存を .bak-<stamp> へ退避してから上書き (非破壊)
#   - 未配備: 配備先が無ければ新規配置 (バックアップ無し)
#   - dry-run: 一切書き込まない (判定のみ)
#   - pending: 差分/未配備の件数を純粋クエリで返す
#   - 対象限定: cron-launcher.sh / report-and-mail.py のみ配備
#   - テンプレ不在: warn して継続 (致命傷にしない)
#
# 隔離: CCSU_ROOT (テンプレ元) と CLAUDEOS_HOME (配備先) を temp へ向け、
#       実 ~/.claudeos / 実テンプレートに一切触れない。
# ============================================================

load '../helpers/common-setup'

LIB="" # setup で解決

setup() {
  _bats_common_setup

  # 隔離した「リポジトリルート」と「配備先」を temp に作る
  export CCSU_ROOT="$TEST_TEMP/repo"
  export CLAUDEOS_HOME="$TEST_TEMP/claudeos"
  export CCSU_DEPLOY_DATE="20260616-000000"   # backup 名を決定化

  TMPL_DIR="$CCSU_ROOT/Claude/templates/linux"
  mkdir -p "$TMPL_DIR" "$CLAUDEOS_HOME"

  # テンプレート正本 (新内容)
  printf '%s\n' '#!/usr/bin/env bash' 'echo NEW-LAUNCHER' > "$TMPL_DIR/cron-launcher.sh"
  printf '%s\n' '# NEW report-and-mail' > "$TMPL_DIR/report-and-mail.py"

  LIB="$REPO_ROOT/lib/deploy-launcher.sh"
}
teardown() { _bats_common_teardown; }

# lib を隔離 env でロードして関数を呼ぶヘルパ
_run_apply() {
  run bash -c 'source "'"$LIB"'"; deploy_launcher__apply "$@"' _ "$@"
}
_run_pending() {
  run bash -c 'source "'"$LIB"'"; deploy_launcher__pending'
}

# =========================================================
# 冪等性
# =========================================================
@test "冪等: テンプレと配備先が同一なら no-op (バックアップを作らない)" {
  cp "$TMPL_DIR/cron-launcher.sh"   "$CLAUDEOS_HOME/cron-launcher.sh"
  cp "$TMPL_DIR/report-and-mail.py" "$CLAUDEOS_HOME/report-and-mail.py"
  _run_apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"差分なし"* ]]
  run bash -c 'ls "'"$CLAUDEOS_HOME"'"/*.bak-* 2>/dev/null'
  [ "$status" -ne 0 ]   # .bak-* は存在しない
}

# =========================================================
# 差分時: backup → 上書き
# =========================================================
@test "差分: 既存を .bak-<stamp> へ退避してから上書き" {
  printf '%s\n' 'OLD-LAUNCHER' > "$CLAUDEOS_HOME/cron-launcher.sh"
  printf '%s\n' 'OLD-report'   > "$CLAUDEOS_HOME/report-and-mail.py"
  _run_apply
  [ "$status" -eq 0 ]
  # 上書き後はテンプレ内容
  [[ "$(cat "$CLAUDEOS_HOME/cron-launcher.sh")" == *"NEW-LAUNCHER"* ]]
  # backup に旧内容が残る
  [ -f "$CLAUDEOS_HOME/cron-launcher.sh.bak-20260616-000000" ]
  [[ "$(cat "$CLAUDEOS_HOME/cron-launcher.sh.bak-20260616-000000")" == *"OLD-LAUNCHER"* ]]
  [ -f "$CLAUDEOS_HOME/report-and-mail.py.bak-20260616-000000" ]
}

@test "差分: .sh は実行ビットが付く" {
  printf '%s\n' 'OLD' > "$CLAUDEOS_HOME/cron-launcher.sh"
  _run_apply
  [ "$status" -eq 0 ]
  [ -x "$CLAUDEOS_HOME/cron-launcher.sh" ]
}

# =========================================================
# 未配備: 新規配置 (バックアップ無し)
# =========================================================
@test "未配備: 配備先が無ければ新規配置しバックアップは作らない" {
  _run_apply
  [ "$status" -eq 0 ]
  [ -f "$CLAUDEOS_HOME/cron-launcher.sh" ]
  [ -f "$CLAUDEOS_HOME/report-and-mail.py" ]
  run bash -c 'ls "'"$CLAUDEOS_HOME"'"/*.bak-* 2>/dev/null'
  [ "$status" -ne 0 ]
}

# =========================================================
# dry-run: 書き込まない
# =========================================================
@test "dry-run: 配備対象を表示するが書き込まない" {
  _run_apply --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"dry-run"* ]]
  [ ! -f "$CLAUDEOS_HOME/cron-launcher.sh" ]
  [ ! -f "$CLAUDEOS_HOME/report-and-mail.py" ]
}

# =========================================================
# pending: 純粋クエリ
# =========================================================
@test "pending: 未配備 2 件を数える (書き込まない)" {
  _run_pending
  [ "$status" -eq 0 ]
  [ "$output" = "2" ]
  [ ! -f "$CLAUDEOS_HOME/cron-launcher.sh" ]
}

@test "pending: 同期済みなら 0" {
  cp "$TMPL_DIR/cron-launcher.sh"   "$CLAUDEOS_HOME/cron-launcher.sh"
  cp "$TMPL_DIR/report-and-mail.py" "$CLAUDEOS_HOME/report-and-mail.py"
  _run_pending
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

# =========================================================
# テンプレ不在: warn して継続
# =========================================================
@test "テンプレ不在: 片方が欠けても warn して残りを配備" {
  rm -f "$TMPL_DIR/report-and-mail.py"
  _run_apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"テンプレート不在"* ]]
  [ -f "$CLAUDEOS_HOME/cron-launcher.sh" ]
  [ ! -f "$CLAUDEOS_HOME/report-and-mail.py" ]
}
