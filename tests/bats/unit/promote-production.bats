#!/usr/bin/env bats
# ============================================================
# promote-production.bats — bin/promote-production.sh のテスト
#
# 方針:
#   - **全てスタブ**。サブスクリプトは CCSU_PROMOTE_BIN_DIR、systemctl は
#     CCSU_SYSTEMCTL_BIN、curl は CCSU_CURL_BIN で差し替える。
#   - CLAUDEOS_HOME / unit パス / dashboard drop-in のディレクトリは $TEST_TEMP。
#     実 systemd・実 ~/.claudeos・本番 3740/3737 には一切触れない (実コマンドは 1 つも実行しない)。
#   - 「どのスタブがどの順で呼ばれたか」を $TEST_TEMP/order.log に記録して検証する。
# ============================================================

bats_require_minimum_version 1.5.0
load '../helpers/common-setup'

setup() {
  _bats_common_setup

  UNIT="claudeos-web-startup.service"
  export CLAUDEOS_HOME="$TEST_TEMP/claudeos"
  mkdir -p "$CLAUDEOS_HOME/releases"
  export CCSU_SYSTEMD_UNIT_PATH="$TEST_TEMP/systemd/$UNIT"
  mkdir -p "$(dirname "$CCSU_SYSTEMD_UNIT_PATH")"
  printf 'ORIGINAL UNIT\n' > "$CCSU_SYSTEMD_UNIT_PATH"

  export CCSU_PROMOTE_BIN_DIR="$TEST_TEMP/stub-bin"
  mkdir -p "$CCSU_PROMOTE_BIN_DIR"
  export ORDER="$TEST_TEMP/order.log"
  : > "$ORDER"
  export CCSU_PROMOTE_TS="20260101-000000"
  # 実機設定 (git 管理外) の代わりにテスト用の一時 config を与える ((0b) config-check 用)
  export CCSU_PROMOTE_CONFIG_PATH="$TEST_TEMP/config.json"
  printf '{"projects":"/tmp"}\n' > "$CCSU_PROMOTE_CONFIG_PATH"
  export CCSU_PROMOTE_HEALTH_TIMEOUT=1
  export CCSU_PROMOTE_HEALTH_INTERVAL=0.05

  export HEALTH_BODY="$TEST_TEMP/health.body"
  printf '{"ok":true}\n' > "$HEALTH_BODY"
  # dashboard(3737) の drop-in は systemd unit dir 配下に作られる（テストは一時ディレクトリ）
  export CCSU_SYSTEMD_UNIT_DIR="$TEST_TEMP/systemd"
  export CCSU_PROMOTE_DASHBOARD_UNIT="claude-startuptools-dashboard.service"
  export CCSU_PROMOTE_NODE_BIN="/usr/bin/node"
  export CCSU_PROMOTE_DASHBOARD_HEALTH_TIMEOUT=1
  DROPIN="$CCSU_SYSTEMD_UNIT_DIR/$CCSU_PROMOTE_DASHBOARD_UNIT.d/50-release.conf"
  export DASHBOARD_UNIT="$CCSU_PROMOTE_DASHBOARD_UNIT"
  export DASHBOARD_HEALTH_BODY="$TEST_TEMP/dashboard-health.body"
  printf '{"status":"ok","uptime":1}
' > "$DASHBOARD_HEALTH_BODY"

  export CCSU_CURL_BIN="$STUB_BIN/curl"
  export CCSU_SYSTEMCTL_BIN="$STUB_BIN/systemctl"
  _stub_curl
  _stub_systemctl
  _stub_subscripts

  SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  SCRIPT="$REPO_ROOT/bin/promote-production.sh"
  BACKUP="$CCSU_SYSTEMD_UNIT_PATH.bak-$CCSU_PROMOTE_TS"
}

teardown() { _bats_common_teardown; }

# ------------------------------------------------------------
# stubs
# ------------------------------------------------------------

_stub_curl() {
  cat > "$CCSU_CURL_BIN" <<'EOF'
#!/usr/bin/env bash
echo "curl $*" >> "${ORDER:?}"
case "$*" in
  *:3737/api/health*)
    # DASHBOARD_FAIL_TIMES (ファイル) があれば、その回数だけ失敗応答を返す
    if [[ -n "${DASHBOARD_FAIL_TIMES:-}" && -f "$DASHBOARD_FAIL_TIMES" ]]; then
      n="$(cat "$DASHBOARD_FAIL_TIMES" 2>/dev/null || echo 0)"
      if (( n > 0 )); then
        echo $((n - 1)) > "$DASHBOARD_FAIL_TIMES"
        echo '{"status":"error"}'
        exit 0
      fi
    fi
    cat "${DASHBOARD_HEALTH_BODY:?}" 2>/dev/null ;;
  *) cat "${HEALTH_BODY:?}" 2>/dev/null ;;
esac
exit 0
EOF
  chmod +x "$CCSU_CURL_BIN"
}

_stub_systemctl() {
  cat > "$CCSU_SYSTEMCTL_BIN" <<'EOF'
#!/usr/bin/env bash
echo "systemctl $*" >> "${ORDER:?}"
if [[ -n "${DASHBOARD_RESTART_FAIL_TIMES:-}" && -f "$DASHBOARD_RESTART_FAIL_TIMES" ]]; then
  case "$*" in
    *"restart ${DASHBOARD_UNIT:-__none__}"*)
      n="$(cat "$DASHBOARD_RESTART_FAIL_TIMES" 2>/dev/null || echo 0)"
      if (( n > 0 )); then
        echo $((n - 1)) > "$DASHBOARD_RESTART_FAIL_TIMES"
        exit 1
      fi ;;
  esac
fi
exit "${PP_STUB_SYSTEMCTL_RC:-0}"
EOF
  chmod +x "$CCSU_SYSTEMCTL_BIN"
}

_stub_subscripts() {
  cat > "$CCSU_PROMOTE_BIN_DIR/pre-promote-check.sh" <<'EOF'
#!/usr/bin/env bash
echo "pre-promote-check $*" >> "${ORDER:?}"
echo '{"ok":true,"release":"gate","tree_sha256":"deadbeef","checks":7,"failed":0,"warnings":0}'
exit "${PP_STUB_GATE_RC:-0}"
EOF
  cat > "$CCSU_PROMOTE_BIN_DIR/release-promote.sh" <<'EOF'
#!/usr/bin/env bash
echo "release-promote $*" >> "${ORDER:?}"
case " $* " in
  *" --rollback "*)
    if [[ "${PP_STUB_ROLLBACK_NO_PREVIOUS:-0}" == "1" ]]; then
      echo '{"ok":false,"error":"NO_PREVIOUS","message":"戻り先 (previous) がありません"}'
      exit 1
    fi
    exit "${PP_STUB_ROLLBACK_RC:-0}" ;;
  *" --no-restart "*) exit "${PP_STUB_SYMLINK_RC:-0}" ;;
  *) exit "${PP_STUB_PROMOTE_RC:-0}" ;;
esac
EOF
  cat > "$CCSU_PROMOTE_BIN_DIR/web-startup-service.sh" <<'EOF'
#!/usr/bin/env bash
echo "web-startup-service $*" >> "${ORDER:?}"
# 実際の登録は unit を書き換えるので、テストでも unit を差し替える
if [[ -n "${CCSU_SYSTEMD_UNIT_PATH:-}" ]]; then
  printf 'NEW UNIT (artifact)\n' > "$CCSU_SYSTEMD_UNIT_PATH"
fi
exit "${PP_STUB_UNIT_RC:-0}"
EOF
  cat > "$CCSU_PROMOTE_BIN_DIR/post-deploy-smoke.sh" <<'EOF'
#!/usr/bin/env bash
echo "post-deploy-smoke $*" >> "${ORDER:?}"
if [[ -n "${PP_STUB_SMOKE_SIGNAL:-}" ]]; then
  # このスタブは pp__run_step のコマンド置換 (サブシェル) から呼ばれるため、
  # その親 = promote-production.sh 本体へシグナルを送る
  gp="$(ps -o ppid= -p "$PPID" 2>/dev/null | tr -d ' ')"
  if [[ -n "$gp" ]]; then
    kill "-${PP_STUB_SMOKE_SIGNAL}" "$gp" 2>/dev/null || true
  fi
  sleep 0.5
fi
exit "${PP_STUB_SMOKE_RC:-0}"
EOF
  chmod +x "$CCSU_PROMOTE_BIN_DIR"/*.sh
}

# _names — order.log に記録されたコマンド名を順に返す
_names() { awk '{print $1}' "$ORDER"; }

# _script_names — サブスクリプト（systemctl/curl 以外）の呼び出し順
_script_names() { awk '{print $1}' "$ORDER" | grep -v -E '^(systemctl|curl)$' | tr '\n' ','; }

# _last_json <output>
_last_json() { printf '%s\n' "$1" | tail -1; }

# ------------------------------------------------------------
# 確認待ち / dry-run
# ------------------------------------------------------------

@test "promote-production: --yes 無しは計画を出して exit 3（何も変更しない）" {
  run bash "$SCRIPT" --release "$SHA"
  [ "$status" -eq 3 ]
  [[ "$output" == *"確認待ち"* ]]
  [[ "$output" == *"Production promote plan"* ]]
  [[ "$output" == *"--no-restart"* ]]

  # どのスタブも呼ばれていない / unit も変えていない / バックアップも無い
  [ ! -s "$ORDER" ]
  [ "$(cat "$CCSU_SYSTEMD_UNIT_PATH")" = "ORIGINAL UNIT" ]
  [ ! -f "$BACKUP" ]
  [ ! -f "$CLAUDEOS_HOME/releases/promotions.jsonl" ]
}

@test "promote-production: --dry-run は何も書かない（exit 0 / result=DRY_RUN）" {
  run bash "$SCRIPT" --release "$SHA" --dry-run --json
  [ "$status" -eq 0 ]
  local last; last="$(_last_json "$output")"
  [ "$(printf '%s' "$last" | jq -r .ok)" = "true" ]
  [ "$(printf '%s' "$last" | jq -r .result)" = "DRY_RUN" ]
  [ "$(printf '%s' "$last" | jq -r .backup)" = "" ]

  [ ! -s "$ORDER" ]
  [ ! -f "$BACKUP" ]
  [ "$(cat "$CCSU_SYSTEMD_UNIT_PATH")" = "ORIGINAL UNIT" ]
}

@test "promote-production: --dry-run は --yes と併用しても実行しない" {
  run bash "$SCRIPT" --release "$SHA" --yes --dry-run
  [ "$status" -eq 0 ]
  [ ! -s "$ORDER" ]
  [ ! -f "$BACKUP" ]
}

# ------------------------------------------------------------
# ゲート / 事前条件
# ------------------------------------------------------------

@test "promote-production: ゲート FAIL なら中止し、何も変更しない（exit 1）" {
  export PP_STUB_GATE_RC=1
  run bash "$SCRIPT" --release "$SHA" --yes --json
  [ "$status" -eq 1 ]
  local last; last="$(_last_json "$output")"
  [ "$(printf '%s' "$last" | jq -r .ok)" = "false" ]
  [ "$(printf '%s' "$last" | jq -r .result)" = "ABORTED" ]
  [ "$(printf '%s' "$last" | jq -r '.steps[0].name')" = "pre-promote-check" ]
  [ "$(printf '%s' "$last" | jq -r '.steps[0].ok')" = "false" ]

  # ゲート以外は呼ばれない / unit 不変 / バックアップ無し
  [ "$(_names | tr '\n' ',')" = "pre-promote-check," ]
  [ "$(cat "$CCSU_SYSTEMD_UNIT_PATH")" = "ORIGINAL UNIT" ]
  [ ! -f "$BACKUP" ]
  [ ! -f "$CLAUDEOS_HOME/releases/promotions.jsonl" ]
}

@test "promote-production: ゲートには --release と --home が渡る" {
  export PP_STUB_GATE_RC=1
  run bash "$SCRIPT" --release "$SHA" --yes
  [ "$status" -eq 1 ]
  grep -q "pre-promote-check --release $SHA --json --home $CLAUDEOS_HOME" "$ORDER"
}

@test "promote-production: unit が無ければ何もせず中止（exit 1）" {
  rm -f "$CCSU_SYSTEMD_UNIT_PATH"

  run bash "$SCRIPT" --release "$SHA" --yes
  [ "$status" -eq 1 ]
  [[ "$output" == *"本番 unit が見つかりません"* ]]
  # ゲートだけ通って、バックアップ以降は実行しない
  [ "$(_names | tr '\n' ',')" = "pre-promote-check," ]
  [ ! -f "$BACKUP" ]
}

# ------------------------------------------------------------
# 正常系
# ------------------------------------------------------------

@test "promote-production: 正常系は手順順序どおり実行して exit 0" {
  run bash "$SCRIPT" --release "$SHA" --yes --json
  [ "$status" -eq 0 ]

  local last; last="$(_last_json "$output")"
  [ "$(printf '%s' "$last" | jq -r .ok)" = "true" ]
  [ "$(printf '%s' "$last" | jq -r .result)" = "PROMOTED" ]
  [ "$(printf '%s' "$last" | jq -r .rolled_back)" = "false" ]
  [ "$(printf '%s' "$last" | jq -r .release)" = "$SHA" ]
  [ "$(printf '%s' "$last" | jq -r .backup)" = "$BACKUP" ]

  # 手順順序: gate → symlink 準備 → unit 差し替え → 昇格確定 → スモーク
  [ "$(_script_names)" = "pre-promote-check,release-promote,web-startup-service,release-promote,post-deploy-smoke," ]

  # 各呼び出しの引数
  grep -q "release-promote --env production --release $SHA --no-restart --json" "$ORDER"
  grep -q "release-promote --env production --release $SHA --json" "$ORDER"
  grep -q "web-startup-service --register --profile production --root $CLAUDEOS_HOME/releases/production-current" "$ORDER"
  grep -qF "AI_STARTUP_CONFIG_PATH=$CCSU_PROMOTE_CONFIG_PATH" "$ORDER"
  grep -q "post-deploy-smoke --env production --json" "$ORDER"

  # unit は差し替わり、バックアップは元の内容を保持
  [ "$(cat "$CCSU_SYSTEMD_UNIT_PATH")" = "NEW UNIT (artifact)" ]
  [ "$(cat "$BACKUP")" = "ORIGINAL UNIT" ]

  # steps は 7 件すべて ok (config-check を含む)
  [ "$(printf '%s' "$last" | jq -r '.steps | length')" -eq 8 ]
  [ "$(printf '%s' "$last" | jq -r '[.steps[].name] | index("dashboard-switch")')" -eq 5 ]
  [ "$(printf '%s' "$last" | jq -r '.dashboard.enabled')" = "true" ]
  [ "$(printf '%s' "$last" | jq -r '.dashboard.dropin')" = "$DROPIN" ]
  [ "$(printf '%s' "$last" | jq -r '[.steps[] | select(.ok == false)] | length')" -eq 0 ]
}

# ------------------------------------------------------------
# (3)〜(5) 失敗時の自動復旧
# ------------------------------------------------------------

@test "promote-production: (3) unit 差し替え失敗で自動復旧し exit 1（unit がバックアップと一致）" {
  export PP_STUB_UNIT_RC=1
  run bash "$SCRIPT" --release "$SHA" --yes --json
  [ "$status" -eq 1 ]

  local last; last="$(_last_json "$output")"
  [ "$(printf '%s' "$last" | jq -r .ok)" = "false" ]
  [ "$(printf '%s' "$last" | jq -r .rolled_back)" = "true" ]
  [ "$(printf '%s' "$last" | jq -r .result)" = "ROLLED_BACK" ]
  [ "$(printf '%s' "$last" | jq -r .failed_step)" = "unit-swap" ]

  # unit がバックアップと完全一致
  [ "$(sha256sum "$CCSU_SYSTEMD_UNIT_PATH" | awk '{print $1}')" = "$(sha256sum "$BACKUP" | awk '{print $1}')" ]
  [ "$(cat "$CCSU_SYSTEMD_UNIT_PATH")" = "ORIGINAL UNIT" ]

  # daemon-reload と restart が呼ばれ、health も確認される
  grep -q "systemctl --user daemon-reload" "$ORDER"
  grep -q "systemctl --user restart $UNIT" "$ORDER"
  grep -q "127.0.0.1:3740/api/health" "$ORDER"

  # 台帳に ROLLED_BACK が記録される
  local ledger="$CLAUDEOS_HOME/releases/promotions.jsonl"
  [ -f "$ledger" ]
  [ "$(tail -1 "$ledger" | jq -r .result)" = "ROLLED_BACK" ]
  [ "$(tail -1 "$ledger" | jq -r .commit)" = "$SHA" ]
}

@test "promote-production: (4) 昇格確定の失敗で自動復旧し exit 1" {
  export PP_STUB_PROMOTE_RC=1
  run bash "$SCRIPT" --release "$SHA" --yes --json
  [ "$status" -eq 1 ]
  local last; last="$(_last_json "$output")"
  [ "$(printf '%s' "$last" | jq -r .rolled_back)" = "true" ]
  [ "$(printf '%s' "$last" | jq -r .failed_step)" = "promote" ]
  [ "$(cat "$CCSU_SYSTEMD_UNIT_PATH")" = "ORIGINAL UNIT" ]
}

@test "promote-production: (5) スモーク失敗で自動復旧し exit 1" {
  export PP_STUB_SMOKE_RC=1
  run bash "$SCRIPT" --release "$SHA" --yes --json
  [ "$status" -eq 1 ]
  local last; last="$(_last_json "$output")"
  [ "$(printf '%s' "$last" | jq -r .rolled_back)" = "true" ]
  [ "$(printf '%s' "$last" | jq -r .failed_step)" = "post-deploy-smoke" ]
  [ "$(sha256sum "$CCSU_SYSTEMD_UNIT_PATH" | awk '{print $1}')" = "$(sha256sum "$BACKUP" | awk '{print $1}')" ]
}

@test "promote-production: 復旧時に成果物の rollback も実行する" {
  export PP_STUB_SMOKE_RC=1
  run bash "$SCRIPT" --release "$SHA" --yes
  [ "$status" -eq 1 ]
  grep -q "release-promote --env production --rollback --no-restart --json" "$ORDER"
}

@test "promote-production: 成果物 rollback が失敗しても unit 復旧は続行する" {
  export PP_STUB_SMOKE_RC=1 PP_STUB_ROLLBACK_RC=1
  run bash "$SCRIPT" --release "$SHA" --yes --json
  [ "$status" -eq 1 ]
  local last; last="$(_last_json "$output")"
  [ "$(printf '%s' "$last" | jq -r .rolled_back)" = "true" ]
  [ "$(cat "$CCSU_SYSTEMD_UNIT_PATH")" = "ORIGINAL UNIT" ]
}

@test "promote-production: 復旧後の health が NG なら exit 4（要人手）" {
  export PP_STUB_SMOKE_RC=1
  printf '{"ok":false}\n' > "$HEALTH_BODY"

  run bash "$SCRIPT" --release "$SHA" --yes --json
  [ "$status" -eq 4 ]
  local last; last="$(_last_json "$output")"
  [ "$(printf '%s' "$last" | jq -r .ok)" = "false" ]
  [ "$(printf '%s' "$last" | jq -r .rolled_back)" = "false" ]
  [ "$(printf '%s' "$last" | jq -r .result)" = "ROLLBACK_FAILED" ]
  [ "$(printf '%s' "$last" | jq -r .failed_step)" = "post-deploy-smoke" ]
}

@test "promote-production: restart が失敗したら復旧失敗として exit 4" {
  export PP_STUB_SMOKE_RC=1 PP_STUB_SYSTEMCTL_RC=1
  run bash "$SCRIPT" --release "$SHA" --yes --json
  [ "$status" -eq 4 ]
  local last; last="$(_last_json "$output")"
  [ "$(printf '%s' "$last" | jq -r .result)" = "ROLLBACK_FAILED" ]
}

# ------------------------------------------------------------
# JSON / 引数
# ------------------------------------------------------------

@test "promote-production: --json のキーが契約どおり（stdout は 1 行だけ）" {
  # stdout は最終 JSON 1 行のみ。人間向けログは stderr へ出る
  run --separate-stderr bash "$SCRIPT" --release "$SHA" --yes --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l)" -eq 1 ]
  [[ "$stderr" == *"Production 昇格を開始"* ]]
  local last; last="$(_last_json "$output")"
  for key in ok release steps rolled_back backup; do
    [ "$(printf '%s' "$last" | jq -r "has(\"$key\")")" = "true" ]
  done
  [ "$(printf '%s' "$last" | jq -r '.steps[0] | has("name")')" = "true" ]
  [ "$(printf '%s' "$last" | jq -r '.steps[0] | has("ok")')" = "true" ]
}

@test "promote-production: 引数エラーは exit 2（--json では ok:false）" {
  run bash "$SCRIPT"
  [ "$status" -eq 2 ]

  run bash "$SCRIPT" --release not-a-sha
  [ "$status" -eq 2 ]

  run bash "$SCRIPT" --release "$SHA" --bogus
  [ "$status" -eq 2 ]

  run bash "$SCRIPT" --release "$SHA" --bogus --json
  [ "$status" -eq 2 ]
  local last; last="$(_last_json "$output")"
  [ "$(printf '%s' "$last" | jq -r .ok)" = "false" ]
  [ "$(printf '%s' "$last" | jq -r .error)" = "ARG_INVALID" ]

  # 引数エラーでは何も実行しない
  [ ! -s "$ORDER" ]
  [ ! -f "$BACKUP" ]
}

@test "promote-production: --help は使い方を出して exit 0" {
  run bash "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--dry-run"* ]]
  [[ "$output" == *"exit: 0 成功"* ]]
}

@test "promote-production: 実機設定が無ければ (0b) で中止し何も変えない" {
  rm -f "$CCSU_PROMOTE_CONFIG_PATH"
  before="$(sha256sum "$CCSU_SYSTEMD_UNIT_PATH" | cut -d' ' -f1)"
  run bash "$SCRIPT" --release "$SHA" --yes --json
  [ "$status" -eq 1 ]
  last="$(printf '%s\n' "${lines[@]}" | grep -E '^\{' | tail -n 1)"
  [ "$(printf '%s' "$last" | jq -r .result)" = "ABORTED" ]
  [[ "$(printf '%s' "$last" | jq -r .reason)" == *"AI_STARTUP_CONFIG_PATH"* ]]
  [ "$(sha256sum "$CCSU_SYSTEMD_UNIT_PATH" | cut -d' ' -f1)" = "$before" ]
  ! ls "$CCSU_SYSTEMD_UNIT_PATH".bak-* >/dev/null 2>&1
  ! grep -q "web-startup-service" "$ORDER" 2>/dev/null
}

@test "promote-production: dry-run は config 不在を警告表示する" {
  rm -f "$CCSU_PROMOTE_CONFIG_PATH"
  run bash "$SCRIPT" --release "$SHA" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"存在しません"* ]]
}

# ------------------------------------------------------------
# dashboard(3737) の drop-in 切替
# ------------------------------------------------------------

@test "promote-production: 正常系で dashboard の drop-in が正しく、既存 unit は変わらない" {
  run bash "$SCRIPT" --release "$SHA" --yes --json
  [ "$status" -eq 0 ]

  # drop-in が作られ、内容は WorkingDirectory と ExecStart の再定義だけ
  [ -f "$DROPIN" ]
  grep -qx "WorkingDirectory=$CLAUDEOS_HOME/releases/production-current" "$DROPIN"
  grep -qx "ExecStart=" "$DROPIN"
  grep -qx "ExecStart=/usr/bin/node $CLAUDEOS_HOME/releases/production-current/scripts/dashboards/serve-dashboard.js 3737" "$DROPIN"
  # M5: unit の Environment に依存せず HOST を明示する
  grep -qx "Environment=HOST=127.0.0.1" "$DROPIN"
  # 既存 unit ファイルは変更しない（バックアップと同一）
  [ "$(cat "$CCSU_SYSTEMD_UNIT_PATH")" = "NEW UNIT (artifact)" ]
  [ "$(cat "$BACKUP")" = "ORIGINAL UNIT" ]

  # unit 名で restart し、3737 の health を確認している
  grep -q "systemctl --user restart $DASHBOARD_UNIT" "$ORDER"
  grep -q "127.0.0.1:3737/api/health" "$ORDER"

  local last; last="$(_last_json "$output")"
  [ "$(printf '%s' "$last" | jq -r '.steps[] | select(.name=="dashboard-switch") | .ok')" = "true" ]
  [ "$(printf '%s' "$last" | jq -r .dashboard.enabled)" = "true" ]
  [ "$(printf '%s' "$last" | jq -r .dashboard.unit)" = "$DASHBOARD_UNIT" ]
  [ "$(printf '%s' "$last" | jq -r .dashboard.dropin)" = "$DROPIN" ]
}

@test "promote-production: (3d) 失敗でコンソールと dashboard の両方を復旧する（exit 1）" {
  # dashboard の restart を 1 回だけ失敗させる → (3d) が失敗し、復旧時の restart は通る
  export DASHBOARD_RESTART_FAIL_TIMES="$TEST_TEMP/dashboard-restart-fails"
  echo 1 > "$DASHBOARD_RESTART_FAIL_TIMES"

  run bash "$SCRIPT" --release "$SHA" --yes --json
  [ "$status" -eq 1 ]

  local last; last="$(_last_json "$output")"
  [ "$(printf '%s' "$last" | jq -r .result)" = "ROLLED_BACK" ]
  [ "$(printf '%s' "$last" | jq -r .failed_step)" = "dashboard-switch" ]
  [ "$(printf '%s' "$last" | jq -r .rolled_back)" = "true" ]

  # コンソール: unit がバックアップと一致
  [ "$(sha256sum "$CCSU_SYSTEMD_UNIT_PATH" | awk '{print $1}')" = "$(sha256sum "$BACKUP" | awk '{print $1}')" ]
  # dashboard: drop-in が消え、restart され、health を確認している
  [ ! -e "$DROPIN" ]
  grep -q "systemctl --user restart $DASHBOARD_UNIT" "$ORDER"
  # (3d) は restart で失敗したため health は復旧時に 1 回だけ確認される
  [ "$(grep -c '127.0.0.1:3737/api/health' "$ORDER")" -ge 1 ]

  local ledger="$CLAUDEOS_HOME/releases/promotions.jsonl"
  [ "$(tail -1 "$ledger" | jq -r .result)" = "ROLLED_BACK" ]
}

@test "promote-production: (5) スモーク失敗でも drop-in を削除して dashboard を戻す" {
  export PP_STUB_SMOKE_RC=1
  run bash "$SCRIPT" --release "$SHA" --yes --json
  [ "$status" -eq 1 ]

  [ ! -e "$DROPIN" ]
  grep -q "systemctl --user restart $DASHBOARD_UNIT" "$ORDER"
  [ "$(printf '%s' "$(_last_json "$output")" | jq -r .rolled_back)" = "true" ]

  # L1: 台帳に dashboard の復旧結果が入る
  local ledger="$CLAUDEOS_HOME/releases/promotions.jsonl"
  [ "$(tail -1 "$ledger" | jq -r .artifact_rollback)" = "ROLLED_BACK" ]
  [ "$(tail -1 "$ledger" | jq -r '.dashboard.enabled')" = "true" ]
  [ "$(tail -1 "$ledger" | jq -r '.dashboard.dropin_removed')" = "true" ]
  [ "$(tail -1 "$ledger" | jq -r '.dashboard.health_ok')" = "true" ]
  [[ "$(tail -1 "$ledger" | jq -r .note)" == *"dashboard="* ]]
}

@test "promote-production: dashboard の復旧 health が NG なら exit 4" {
  export PP_STUB_SMOKE_RC=1
  export DASHBOARD_FAIL_TIMES="$TEST_TEMP/dashboard-fails"
  echo 99 > "$DASHBOARD_FAIL_TIMES"

  run bash "$SCRIPT" --release "$SHA" --yes --json
  [ "$status" -eq 4 ]
  local last; last="$(_last_json "$output")"
  [ "$(printf '%s' "$last" | jq -r .result)" = "ROLLBACK_FAILED" ]
  [ "$(printf '%s' "$last" | jq -r '.steps[] | select(.name=="dashboard-health") | .ok')" = "false" ]
}

@test "promote-production: --no-dashboard は drop-in を書かず dashboard を触らない" {
  run bash "$SCRIPT" --release "$SHA" --yes --json --no-dashboard
  [ "$status" -eq 0 ]

  [ ! -e "$DROPIN" ]
  ! grep -q "restart $DASHBOARD_UNIT" "$ORDER"
  ! grep -q "127.0.0.1:3737/api/health" "$ORDER"

  local last; last="$(_last_json "$output")"
  [ "$(printf '%s' "$last" | jq -r .dashboard.enabled)" = "false" ]
  [ "$(printf '%s' "$last" | jq -r '[.steps[].name] | index("dashboard-switch")')" = "null" ]
  [ "$(printf '%s' "$last" | jq -r .ok)" = "true" ]
}

@test "promote-production: dry-run は (3d) を表示し drop-in を書かない" {
  run bash "$SCRIPT" --release "$SHA" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"(3d)"* ]]
  [[ "$output" == *"50-release.conf"* ]]
  [ ! -e "$DROPIN" ]
  [ ! -d "$CCSU_SYSTEMD_UNIT_DIR/$DASHBOARD_UNIT.d" ]
  [ ! -s "$ORDER" ]

  # --no-dashboard の dry-run では (3d) を出さない
  run bash "$SCRIPT" --release "$SHA" --dry-run --no-dashboard
  [ "$status" -eq 0 ]
  [[ "$output" != *"(3d)"* ]]
  [[ "$output" == *"無効 (--no-dashboard)"* ]]
}

# ------------------------------------------------------------
# 追加要件 (H1 / H2 / M2 / L3)
# ------------------------------------------------------------

@test "promote-production: H1 初回昇格 (previous 不在) の復旧で production-current を削除する" {
  # (2) が作るはずの symlink を用意しておく
  ln -sfn "$SHA" "$CLAUDEOS_HOME/releases/production-current"
  export PP_STUB_SMOKE_RC=1
  export PP_STUB_ROLLBACK_NO_PREVIOUS=1

  run bash "$SCRIPT" --release "$SHA" --yes --json
  [ "$status" -eq 1 ]

  # 新 artifact を指したままにしない
  [ ! -L "$CLAUDEOS_HOME/releases/production-current" ]

  local last; last="$(_last_json "$output")"
  [ "$(printf '%s' "$last" | jq -r .rolled_back)" = "true" ]
  [ "$(printf '%s' "$last" | jq -r .artifact_rollback)" = "NO_PREVIOUS_REMOVED" ]

  # 台帳にもその旨が残る
  local ledger="$CLAUDEOS_HOME/releases/promotions.jsonl"
  [ "$(tail -1 "$ledger" | jq -r .artifact_rollback)" = "NO_PREVIOUS_REMOVED" ]
  [[ "$(tail -1 "$ledger" | jq -r .note)" == *"artifact=NO_PREVIOUS_REMOVED"* ]]
}

@test "promote-production: H2 実行中の SIGTERM で自動復旧して exit 1" {
  export PP_STUB_SMOKE_SIGNAL=TERM

  run bash "$SCRIPT" --release "$SHA" --yes --json
  [ "$status" -eq 1 ]

  local last; last="$(_last_json "$output")"
  [ "$(printf '%s' "$last" | jq -r .result)" = "ROLLED_BACK" ]
  [ "$(printf '%s' "$last" | jq -r .failed_step)" = "signal-TERM" ]
  [ "$(printf '%s' "$last" | jq -r .rolled_back)" = "true" ]

  # unit がバックアップと一致し、dashboard の drop-in も消えている
  [ "$(sha256sum "$CCSU_SYSTEMD_UNIT_PATH" | awk '{print $1}')" = "$(sha256sum "$BACKUP" | awk '{print $1}')" ]
  [ ! -e "$DROPIN" ]
  grep -q "systemctl --user restart $DASHBOARD_UNIT" "$ORDER"
}

@test "promote-production: H2 シグナル後の復旧に失敗したら exit 4" {
  export PP_STUB_SMOKE_SIGNAL=TERM
  export PP_STUB_SYSTEMCTL_RC=1

  run bash "$SCRIPT" --release "$SHA" --yes --json
  [ "$status" -eq 4 ]
  [ "$(_last_json "$output" | jq -r .result)" = "ROLLBACK_FAILED" ]
}

@test "promote-production: M2 二重実行は lock 取得失敗で exit 2 (何も変えない)" {
  local lockfile="$CLAUDEOS_HOME/releases/.promote-production.lock"
  (
    exec 9>"$lockfile"
    flock -n 9 || exit 0
    sleep 5
  ) &
  local holder=$!
  sleep 0.3

  run bash "$SCRIPT" --release "$SHA" --yes --json
  [ "$status" -eq 2 ]
  local last; last="$(_last_json "$output")"
  [ "$(printf '%s' "$last" | jq -r .ok)" = "false" ]
  [ "$(printf '%s' "$last" | jq -r .error)" = "LOCKED" ]

  # 何も実行していない
  [ ! -s "$ORDER" ]
  [ ! -f "$BACKUP" ]
  [ "$(cat "$CCSU_SYSTEMD_UNIT_PATH")" = "ORIGINAL UNIT" ]

  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
}

@test "promote-production: L3 drop-in の node は現行 unit の ExecStart から抽出する" {
  unset CCSU_PROMOTE_NODE_BIN
  cat > "$CCSU_SYSTEMD_UNIT_DIR/$DASHBOARD_UNIT" <<'UNIT'
[Service]
WorkingDirectory=/somewhere
Environment=HOST=127.0.0.1
ExecStart=/opt/weird/node-v99/bin/node scripts/dashboards/serve-dashboard.js 3737
UNIT

  run bash "$SCRIPT" --release "$SHA" --yes --json
  [ "$status" -eq 0 ]
  grep -qx "ExecStart=/opt/weird/node-v99/bin/node $CLAUDEOS_HOME/releases/production-current/scripts/dashboards/serve-dashboard.js 3737" "$DROPIN"
}

@test "promote-production: --no-dashboard の復旧では台帳の dashboard.enabled が false" {
  export PP_STUB_SMOKE_RC=1
  run bash "$SCRIPT" --release "$SHA" --yes --json --no-dashboard
  [ "$status" -eq 1 ]

  local ledger="$CLAUDEOS_HOME/releases/promotions.jsonl"
  [ "$(tail -1 "$ledger" | jq -r '.dashboard.enabled')" = "false" ]
  [ "$(tail -1 "$ledger" | jq -r '.dashboard.dropin_removed')" = "false" ]
}
