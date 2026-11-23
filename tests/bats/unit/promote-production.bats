#!/usr/bin/env bats
# ============================================================
# promote-production.bats — bin/promote-production.sh のテスト
#
# 方針:
#   - **全てスタブ**。サブスクリプトは CCSU_PROMOTE_BIN_DIR、systemctl は
#     CCSU_SYSTEMCTL_BIN、curl は CCSU_CURL_BIN で差し替える。
#   - CLAUDEOS_HOME / unit パスは $TEST_TEMP。実 systemd・実 ~/.claudeos・
#     本番 3740 には一切触れない (実コマンドは 1 つも実行しない)。
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
  export CCSU_PROMOTE_HEALTH_TIMEOUT=1
  export CCSU_PROMOTE_HEALTH_INTERVAL=0.05

  export HEALTH_BODY="$TEST_TEMP/health.body"
  printf '{"ok":true}\n' > "$HEALTH_BODY"
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
cat "${HEALTH_BODY:?}" 2>/dev/null
exit 0
EOF
  chmod +x "$CCSU_CURL_BIN"
}

_stub_systemctl() {
  cat > "$CCSU_SYSTEMCTL_BIN" <<'EOF'
#!/usr/bin/env bash
echo "systemctl $*" >> "${ORDER:?}"
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
  *" --rollback "*) exit "${PP_STUB_ROLLBACK_RC:-0}" ;;
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
exit "${PP_STUB_SMOKE_RC:-0}"
EOF
  chmod +x "$CCSU_PROMOTE_BIN_DIR"/*.sh
}

# _names — order.log に記録されたコマンド名を順に返す
_names() { awk '{print $1}' "$ORDER"; }

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
  [ "$(_names | tr '\n' ',')" = "pre-promote-check,release-promote,web-startup-service,release-promote,post-deploy-smoke," ]

  # 各呼び出しの引数
  grep -q "release-promote --env production --release $SHA --no-restart --json" "$ORDER"
  grep -q "release-promote --env production --release $SHA --json" "$ORDER"
  grep -q "web-startup-service --register --profile production --root $CLAUDEOS_HOME/releases/production-current" "$ORDER"
  grep -q "AI_STARTUP_CONFIG_PATH=.*config/config.json" "$ORDER"
  grep -q "post-deploy-smoke --env production --json" "$ORDER"

  # unit は差し替わり、バックアップは元の内容を保持
  [ "$(cat "$CCSU_SYSTEMD_UNIT_PATH")" = "NEW UNIT (artifact)" ]
  [ "$(cat "$BACKUP")" = "ORIGINAL UNIT" ]

  # steps は 6 件すべて ok
  [ "$(printf '%s' "$last" | jq -r '.steps | length')" -eq 6 ]
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
