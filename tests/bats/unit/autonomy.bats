#!/usr/bin/env bats
# ============================================================
# autonomy.bats — bin/autonomy.sh (Autonomy Supervisor CLI) のテスト
#   setsid/tmux/crontab を stub 化。__run は実行せず spawn 経路のみ検証。
# ============================================================

load '../helpers/common-setup'

setup() {
  _bats_common_setup
  export AI_STARTUP_CONFIG_PATH="$TEST_TEMP/config.json"
  printf '{ "projects": "%s/projects" }\n' "$TEST_TEMP" > "$AI_STARTUP_CONFIG_PATH"
  mkdir -p "$TEST_TEMP/projects/Demo/.git" "$TEST_TEMP/projects/Alpha/.git"
  export CCSU_SUP_DIR="$TEST_TEMP/sup"
  export CCSU_SUP_CRON_LAUNCHER="$TEST_TEMP/cron-launcher.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$CCSU_SUP_CRON_LAUNCHER"; chmod +x "$CCSU_SUP_CRON_LAUNCHER"

  export CRON_STORE="$TEST_TEMP/crontab.store"
  make_stub_bin crontab '
store="${CRON_STORE:?}"
case "${1:-}" in
  -l) [[ -f "$store" ]] && cat "$store" || exit 1 ;;
  -)  cat > "$store" ;;
  *)  exit 2 ;;
esac
'
  # setsid: spawn 引数を記録し、起動確認用に state ファイルも生成 (poll 高速化)
  make_stub_bin setsid '
echo "$@" >> "$TEST_TEMP/setsid.log"
p="${4:-}"
[[ -n "$p" ]] && { mkdir -p "$CCSU_SUP_DIR"; printf "{\"project\":\"%s\",\"status\":\"running\",\"pid\":%s}\n" "$p" "$$" > "$CCSU_SUP_DIR/$p.json"; }
exit 0
'
  make_stub_bin tmux 'echo "$@" >> "$TEST_TEMP/tmux.log"; exit 0'
  export CCSU_TMUX_BIN=tmux
  # spawn 経路テストでは配備同期を無効化 (実 ~/.claudeos へ書き込まない)。
  # 同期経路は専用テスト (下記) で CLAUDEOS_HOME をサンドボックス化して検証する。
  export CCSU_SKIP_DEPLOY_SYNC=1
  SCRIPT="$REPO_ROOT/bin/autonomy.sh"
}
teardown() { _bats_common_teardown; }

_seed_cron() {
  cat > "$CRON_STORE" <<EOF
# CLAUDEOS:abc12345 project=$1 duration=300 created=2026-01-01T00:00:00
0 21 * * 1,2,3,4,5,6 bash /x/cron-launcher.sh $1 300
EOF
}

@test "start: cron 登録ありは --force 無しで拒否 (spawn しない)" {
  _seed_cron Demo
  run bash "$SCRIPT" start Demo
  [ "$status" -ne 0 ]
  [[ "$output" == *"cron 登録が残っています"* ]]
  [ ! -f "$TEST_TEMP/setsid.log" ]
}

@test "start: cron 無し → setsid で __run 起動" {
  run bash "$SCRIPT" start Demo
  [ "$status" -eq 0 ]
  [[ "$output" == *"supervisor 起動: Demo"* ]]
  [ -f "$TEST_TEMP/setsid.log" ]
  grep -q "__run Demo" "$TEST_TEMP/setsid.log"
}

@test "start: deploy.ready=true は spawn 拒否 (goal-reached guard)" {
  printf '{"deploy":{"ready":true}}\n' > "$TEST_TEMP/projects/Demo/state.json"
  run bash "$SCRIPT" start Demo
  [ "$status" -ne 0 ]
  [[ "$output" == *"停止条件を満たしています"* ]]
  [[ "$output" == *"goal-reached:deploy.ready"* ]]
  [ ! -f "$TEST_TEMP/setsid.log" ]
}

@test "start --force: deploy.ready=true でも警告して spawn する" {
  printf '{"deploy":{"ready":true}}\n' > "$TEST_TEMP/projects/Demo/state.json"
  run bash "$SCRIPT" start Demo --force
  [ "$status" -eq 0 ]
  [[ "$output" == *"停止条件を満たしています"* ]]
  [[ "$output" == *"--force"* ]]
  grep -q "__run Demo" "$TEST_TEMP/setsid.log"
}

@test "start --all: deploy.ready=true プロジェクトを SKIP に分類" {
  printf '{"deploy":{"ready":true}}\n' > "$TEST_TEMP/projects/Demo/state.json"
  run bash "$SCRIPT" start --all --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"SKIP"* ]]
  [[ "$output" == *"Demo:goal-reached:deploy.ready"* ]]
}

@test "start: --force で cron ありでも続行" {
  _seed_cron Demo
  run bash "$SCRIPT" start Demo --force
  [ "$status" -eq 0 ]
  [[ "$output" == *"--force"* ]]
  grep -q "__run Demo" "$TEST_TEMP/setsid.log"
}

@test "start --all --dry-run: 候補を表示し spawn しない" {
  run bash "$SCRIPT" start --all --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"全適用 計画"* ]]
  [[ "$output" == *"Demo"* ]]
  [[ "$output" == *"Alpha"* ]]
  [ ! -f "$TEST_TEMP/setsid.log" ]
}

@test "start --all --yes: 全候補を supervisor 起動する" {
  run bash "$SCRIPT" start --all --yes
  [ "$status" -eq 0 ]
  grep -q "__run Demo" "$TEST_TEMP/setsid.log"
  grep -q "__run Alpha" "$TEST_TEMP/setsid.log"
}

@test "start --all --dry-run: 優先度キューで security_critical を先頭へ並べ替え (PR-C)" {
  # Alpha は名前順で Demo より先。security_critical を Demo に与え priority で逆転させる。
  printf '{ "kpi": {"security_critical": 1} }\n' > "$TEST_TEMP/projects/Demo/state.json"
  printf '{ "deploy": {"ready": false} }\n' > "$TEST_TEMP/projects/Alpha/state.json"
  run bash "$SCRIPT" start --all --dry-run
  [ "$status" -eq 0 ]
  local d a
  d="$(printf '%s\n' "$output" | grep -n 'Demo' | head -1 | cut -d: -f1)"
  a="$(printf '%s\n' "$output" | grep -n 'Alpha' | head -1 | cut -d: -f1)"
  # Demo (score 1000) が Alpha (score 0) より上の行に出る = 起動順が priority 化
  [ "$d" -lt "$a" ]
}

@test "start --all --dry-run: 同点 (state 無し) は名前昇順で安定 (Alpha→Demo)" {
  run bash "$SCRIPT" start --all --dry-run
  [ "$status" -eq 0 ]
  local d a
  d="$(printf '%s\n' "$output" | grep -n 'Demo' | head -1 | cut -d: -f1)"
  a="$(printf '%s\n' "$output" | grep -n 'Alpha' | head -1 | cut -d: -f1)"
  [ "$a" -lt "$d" ]
}

@test "start --all: cron 登録ありは --force 無しで skip" {
  _seed_cron Demo
  run bash "$SCRIPT" start --all --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"SKIP"* ]]
  [[ "$output" == *"Demo:cron登録あり"* ]]
}

@test "start: 配備ドリフトを起動前に自動同期する (CCSU_SKIP_DEPLOY_SYNC 無効時)" {
  # CLAUDEOS_HOME をサンドボックス化し、template と差分のある古い launcher を置く。
  local fakehome="$TEST_TEMP/claudeos-home"; mkdir -p "$fakehome"
  printf '#!/usr/bin/env bash\n# STALE LAUNCHER (drift)\nexit 0\n' > "$fakehome/cron-launcher.sh"
  run env CLAUDEOS_HOME="$fakehome" CCSU_SKIP_DEPLOY_SYNC=0 \
    bash "$SCRIPT" start Demo
  [ "$status" -eq 0 ]
  [[ "$output" == *"配備ドリフト検出"* ]]
  # template の正本へ追従していること (STALE マーカーが消える)
  ! grep -q "STALE LAUNCHER" "$fakehome/cron-launcher.sh"
  # backup が作成されている
  ls "$fakehome"/cron-launcher.sh.bak-* >/dev/null 2>&1
}

@test "start: 配備差分なしなら同期ログを出さない (冪等 no-op)" {
  # template をそのままコピー = 差分ゼロ
  local fakehome="$TEST_TEMP/claudeos-home2"; mkdir -p "$fakehome"
  cp "$REPO_ROOT/Claude/templates/linux/cron-launcher.sh" "$fakehome/cron-launcher.sh"
  cp "$REPO_ROOT/Claude/templates/linux/report-and-mail.py" "$fakehome/report-and-mail.py"
  run env CLAUDEOS_HOME="$fakehome" CCSU_SKIP_DEPLOY_SYNC=0 \
    bash "$SCRIPT" start Demo
  [ "$status" -eq 0 ]
  [[ "$output" != *"配備ドリフト検出"* ]]
}

@test "start: 存在しないプロジェクトでエラー" {
  run bash "$SCRIPT" start NoSuch
  [ "$status" -ne 0 ]
}

@test "start: 既に稼働中なら再起動しない" {
  mkdir -p "$CCSU_SUP_DIR"
  printf '{ "project":"Demo","status":"running","pid": %s }\n' "$$" > "$CCSU_SUP_DIR/Demo.json"
  run bash "$SCRIPT" start Demo
  [ "$status" -eq 0 ]
  [[ "$output" == *"既に supervisor 稼働中"* ]]
  [ ! -f "$TEST_TEMP/setsid.log" ]
}

@test "stop: graceful で stop フラグ作成 (kill しない)" {
  mkdir -p "$CCSU_SUP_DIR"
  printf '{ "project":"Demo","status":"running","pid": %s }\n' "$$" > "$CCSU_SUP_DIR/Demo.json"
  run bash "$SCRIPT" stop Demo
  [ "$status" -eq 0 ]
  [ -f "$CCSU_SUP_DIR/Demo.stop" ]
}

@test "stop: 未稼働は警告" {
  run bash "$SCRIPT" stop Demo
  [ "$status" -eq 0 ]
  [[ "$output" == *"稼働していません"* ]]
}

@test "stop --now: 死pidでも安全に tmux kill-session を試行" {
  mkdir -p "$CCSU_SUP_DIR"
  printf '{ "project":"Demo","status":"running","pid": 999999 }\n' > "$CCSU_SUP_DIR/Demo.json"
  run bash "$SCRIPT" stop Demo --now
  [ "$status" -eq 0 ]
  [ -f "$CCSU_SUP_DIR/Demo.stop" ]
  grep -q "kill-session" "$TEST_TEMP/tmux.log"
}

@test "list: supervisor なしのメッセージ" {
  run bash "$SCRIPT" list
  [ "$status" -eq 0 ]
  [[ "$output" == *"supervisor なし"* ]]
}

@test "status <project>: 状態を表示" {
  mkdir -p "$CCSU_SUP_DIR"
  printf '{ "project":"Demo","status":"goal-reached","pid":0,"restarts_today":3,"minutes_today":120,"last_reason":"goal-reached:deploy.ready" }\n' > "$CCSU_SUP_DIR/Demo.json"
  run bash "$SCRIPT" status Demo
  [ "$status" -eq 0 ]
  [[ "$output" == *"Demo"* ]]
  [[ "$output" == *"goal-reached"* ]]
}

@test "不明サブコマンドでエラー" {
  run bash "$SCRIPT" frobnicate
  [ "$status" -ne 0 ]
}
