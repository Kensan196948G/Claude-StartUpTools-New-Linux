#!/usr/bin/env bats
# ============================================================
# post-deploy-smoke.bats — scripts/release/post-deploy-smoke.sh のテスト
#
# 方針:
#   - curl / systemctl は PATH スタブ (CCSU_CURL_BIN / CCSU_SYSTEMCTL_BIN) で差し替え、
#     実ネットワーク・実 systemd に依存しない
#   - CLAUDEOS_HOME は必ず $BATS_TEST_TMPDIR 配下へ向ける (実 ~/.claudeos を書かない)
#   - 「読み取り専用」を呼び出しログで検証する (restart/start/stop を呼ばないこと)
#   - 失敗系はスタブが即応答するので sleep しない
# ============================================================

load '../helpers/common-setup'

setup() {
  _bats_common_setup

  export CLAUDEOS_HOME="$TEST_TEMP/claudeos"
  mkdir -p "$CLAUDEOS_HOME/releases"

  export CCSU_CURL_BIN="$STUB_BIN/curl"
  export CCSU_SYSTEMCTL_BIN="$STUB_BIN/systemctl"
  export SMOKE_STUB_CURL_CALLS="$TEST_TEMP/curl.calls"
  export SMOKE_STUB_SYSTEMCTL_CALLS="$TEST_TEMP/systemctl.calls"

  # 既定: 全 URL 200 / unit active / NRestarts 0 / health と dashboard に同じ commit
  export SMOKE_CODE_DEFAULT=200
  export SMOKE_COMMIT_DEFAULT='0123456789abcdef0123456789abcdef01234567'
  export SMOKE_BODY_HEALTH='{"ok":true,"service":"claudeos-web-startup","commit":"0123456789abcdef0123456789abcdef01234567"}'
  export SMOKE_BODY_DASHBOARD='{"status":"ok","commit":"0123456789abcdef0123456789abcdef01234567"}'
  export SMOKE_BODY_DASHBOARD_STG='{"status":"ok","commit":"0123456789abcdef0123456789abcdef01234567"}'
  export SMOKE_STUB_ACTIVE=active
  export SMOKE_STUB_RESTARTS=0

  _stub_curl
  _stub_systemctl
  _make_promotions_fresh

  SCRIPT="$REPO_ROOT/scripts/release/post-deploy-smoke.sh"
}

teardown() { _bats_common_teardown; }

# ------------------------------------------------------------
# stubs / fixtures
# ------------------------------------------------------------

# _stub_curl — URL ごとに SMOKE_CODE_<KEY> のコードを返す curl スタブ
#   KEY: HEALTH(3740,3742 health) ROOT(3740,3742 /) DASHBOARD(3737) DASHBOARD_STG(3743)
#        TERMINAL(3741) PUBLIC(https) OTHER
_stub_curl() {
  cat > "$CCSU_CURL_BIN" <<'STUB'
#!/usr/bin/env bash
url=""
want_code=0
while [ $# -gt 0 ]; do
  case "$1" in
    -o)         shift 2 ;;
    -w)         want_code=1; shift 2 ;;
    --max-time) shift 2 ;;
    -s|-S|-sS|-f|-fsS|-L|-fsSL) shift ;;
    *)          url="$1"; shift ;;
  esac
done

if [ -n "${SMOKE_STUB_CURL_CALLS:-}" ]; then
  printf '%s\n' "$url" >> "$SMOKE_STUB_CURL_CALLS"
fi

key="OTHER"
case "$url" in
  *:3740/api/health) key="HEALTH" ;;
  *:3742/api/health) key="HEALTH" ;;
  *:3740/)           key="ROOT" ;;
  *:3742/)           key="ROOT" ;;
  *:3737/api/health) key="DASHBOARD" ;;
  *:3743/api/health) key="DASHBOARD_STG" ;;
  *:3741/terminal/)  key="TERMINAL" ;;
  https://*)         key="PUBLIC" ;;
esac

var="SMOKE_CODE_${key}"
code="${!var:-${SMOKE_CODE_DEFAULT:-000}}"

if [ "$want_code" = 1 ]; then
  printf '%s' "$code"
  exit 0
fi

# -f 付き (本文取得) は 4xx/5xx/接続不可で失敗する (curl と同じ挙動)
case "$code" in
  200) ;;
  *) exit 22 ;;
esac
case "$key" in
  HEALTH)        printf '%s' "${SMOKE_BODY_HEALTH:-}" ;;
  DASHBOARD)     printf '%s' "${SMOKE_BODY_DASHBOARD:-}" ;;
  DASHBOARD_STG) printf '%s' "${SMOKE_BODY_DASHBOARD_STG:-}" ;;
esac
exit 0
STUB
  chmod +x "$CCSU_CURL_BIN"
}

# _stub_systemctl — show に対して ActiveState / NRestarts を返すスタブ
_stub_systemctl() {
  cat > "$CCSU_SYSTEMCTL_BIN" <<'STUB'
#!/usr/bin/env bash
if [ -n "${SMOKE_STUB_SYSTEMCTL_CALLS:-}" ]; then
  printf '%s\n' "$*" >> "$SMOKE_STUB_SYSTEMCTL_CALLS"
fi
printf 'ActiveState=%s\nNRestarts=%s\n' "${SMOKE_STUB_ACTIVE:-active}" "${SMOKE_STUB_RESTARTS:-0}"
exit 0
STUB
  chmod +x "$CCSU_SYSTEMCTL_BIN"
}

_make_promotions_fresh() {
  local at
  at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '{"at":"%s","env":"production","commit":"abc","result":"PROMOTED"}\n' "$at" \
    > "$CLAUDEOS_HOME/releases/promotions.jsonl"
}

# _json_line <output> — 出力中から 1 行 JSON を取り出す (最終行とは限らない前提で探す)
_json_line() { printf '%s\n' "$1" | grep -E '^\{"ok"' | tail -n 1; }

# _assert_json <output> <jq filter> <expected>
_assert_json() {
  local line
  line="$(_json_line "$1")"
  [ -n "$line" ] || { echo "JSON 行が見つかりません: $1"; return 1; }
  [ "$(printf '%s' "$line" | jq -r "$2")" = "$3" ] \
    || { echo "JSON $2 が $3 ではありません: $line"; return 1; }
}

# ------------------------------------------------------------
# 引数エラー (exit 2)
# ------------------------------------------------------------

@test "引数: 不正な --env は exit 2" {
  run bash "$SCRIPT" --env prod
  [ "$status" -eq 2 ]
  [[ "$output" == *"--env"* ]]
}

@test "引数: 不明なオプションは exit 2" {
  run bash "$SCRIPT" --wat
  [ "$status" -eq 2 ]
  [[ "$output" == *"不明な引数"* ]]
}

@test "引数: --public-url が URL でなければ exit 2" {
  run bash "$SCRIPT" --public-url "not-a-url"
  [ "$status" -eq 2 ]
  [[ "$output" == *"--public-url"* ]]
}

@test "引数: --help は exit 0 で使い方を出す" {
  run bash "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
}

# ------------------------------------------------------------
# 正常系
# ------------------------------------------------------------

@test "全 PASS: exit 0 で 7 checks / 0 failed" {
  run bash "$SCRIPT" --json
  [ "$status" -eq 0 ]
  [[ "$output" == *"health"* ]]
  [[ "$output" == *"dashboard"* ]]
  [[ "$output" == *"terminal"* ]]
  [[ "$output" == *"public url"* ]]
  [[ "$output" == *"promotions"* ]]
  [[ "$output" == *"systemd unit"* ]]

  _assert_json "$output" '.ok' 'true'
  _assert_json "$output" '.env' 'production'
  _assert_json "$output" '.checks' '7'
  _assert_json "$output" '.failed' '0'
  _assert_json "$output" '.warnings' '0'
}

@test "公開 URL: 302 (Cloudflare Access) を正常扱いして exit 0" {
  export SMOKE_CODE_PUBLIC=302
  run bash "$SCRIPT" --json
  [ "$status" -eq 0 ]
  [[ "$output" == *"public url"* ]]
  [[ "$output" == *"302"* ]]
  _assert_json "$output" '.ok' 'true'
  _assert_json "$output" '.failed' '0'
}

@test "promotions 台帳が 30 日以内なら PASS" {
  run bash "$SCRIPT" --json
  [ "$status" -eq 0 ]
  _assert_json "$output" '.warnings' '0'
}

# ------------------------------------------------------------
# 失敗系
# ------------------------------------------------------------

@test "health FAIL: 3740 が応答しなければ exit 1" {
  export SMOKE_CODE_HEALTH=000
  run bash "$SCRIPT" --json
  [ "$status" -eq 1 ]
  [[ "$output" == *"health"* ]]
  _assert_json "$output" '.ok' 'false'
  _assert_json "$output" '.failed' '1'
}

@test "health FAIL: HTTP 200 でも ok:true でなければ exit 1" {
  export SMOKE_BODY_HEALTH='{"ok":false}'
  run bash "$SCRIPT" --json
  [ "$status" -eq 1 ]
  [[ "$output" == *"ok != true"* ]]
  _assert_json "$output" '.failed' '1'
}

@test "dashboard FAIL: 3737 が 500 なら exit 1" {
  export SMOKE_CODE_DASHBOARD=500
  run bash "$SCRIPT" --json
  [ "$status" -eq 1 ]
  [[ "$output" == *"dashboard"* ]]
  _assert_json "$output" '.failed' '1'
}

@test "web root FAIL: GET / が 500 なら exit 1" {
  export SMOKE_CODE_ROOT=500
  run bash "$SCRIPT" --json
  [ "$status" -eq 1 ]
  [[ "$output" == *"web root"* ]]
  _assert_json "$output" '.failed' '1'
}

@test "public url FAIL: 404 は FAIL (302 のみ正常扱い)" {
  export SMOKE_CODE_PUBLIC=404
  run bash "$SCRIPT" --json
  [ "$status" -eq 1 ]
  _assert_json "$output" '.failed' '1'
}

@test "unit FAIL: ActiveState が active でなければ exit 1" {
  export SMOKE_STUB_ACTIVE=inactive
  run bash "$SCRIPT" --json
  [ "$status" -eq 1 ]
  [[ "$output" == *"ActiveState=inactive"* ]]
  _assert_json "$output" '.failed' '1'
}

# ------------------------------------------------------------
# WARN (FAIL にしない)
# ------------------------------------------------------------

@test "health.commit が空なら WARN で exit 0 (FAIL にしない)" {
  export SMOKE_BODY_HEALTH='{"ok":true}'
  run bash "$SCRIPT" --json
  [ "$status" -eq 0 ]
  [[ "$output" == *"commit が空"* ]]
  _assert_json "$output" '.ok' 'true'
  _assert_json "$output" '.warnings' '1'
}

@test "promotions 台帳が無ければ WARN で exit 0" {
  rm -f "$CLAUDEOS_HOME/releases/promotions.jsonl"
  run bash "$SCRIPT" --json
  [ "$status" -eq 0 ]
  [[ "$output" == *"台帳なし"* ]]
  _assert_json "$output" '.warnings' '1'
}

@test "promotions が 30 日より古ければ WARN で exit 0" {
  local old
  old="$(date -u -d '60 days ago' +%Y-%m-%dT%H:%M:%SZ)"
  printf '{"at":"%s","env":"production","result":"PROMOTED"}\n' "$old" \
    > "$CLAUDEOS_HOME/releases/promotions.jsonl"
  run bash "$SCRIPT" --json
  [ "$status" -eq 0 ]
  [[ "$output" == *"> 30 日"* ]]
  _assert_json "$output" '.warnings' '1'
}

@test "NRestarts がしきい値以上なら WARN で exit 0" {
  export SMOKE_STUB_RESTARTS=3
  run bash "$SCRIPT" --json
  [ "$status" -eq 0 ]
  [[ "$output" == *"NRestarts=3"* ]]
  _assert_json "$output" '.warnings' '1'
}

# ------------------------------------------------------------
# staging の分離（本番ポートを触らない）
# ------------------------------------------------------------

@test "staging: 3742 を使い、本番 3737/3741 を叩かない" {
  export SMOKE_CODE_DASHBOARD_STG=000

  run bash "$SCRIPT" --env staging --json
  # run grep で $output が上書きされるため、先に控える
  local smoke_status="$status" smoke_out="$output"
  [ "$smoke_status" -eq 0 ]

  # 本番系ポートへリクエストしていないこと
  run grep -E ':3740|:3737|:3741' "$SMOKE_STUB_CURL_CALLS"
  [ "$status" -ne 0 ]

  # staging の port と unit を使っていること
  grep -q ':3742/' "$SMOKE_STUB_CURL_CALLS"
  grep -q 'claudeos-web-startup-stg.service' "$SMOKE_STUB_SYSTEMCTL_CALLS"

  # staging dashboard が無いので SKIP
  [[ "$smoke_out" == *"SKIP"* ]]
  _assert_json "$smoke_out" '.env' 'staging'
}

# ------------------------------------------------------------
# 読み取り専用（再起動しない）
# ------------------------------------------------------------

@test "読み取り専用: systemctl は show のみで restart/start/stop を呼ばない" {
  export SMOKE_CODE_HEALTH=000
  run bash "$SCRIPT" --json
  [ "$status" -eq 1 ]

  # systemctl は呼ばれている（show）が、変更系サブコマンドは無い
  [ -f "$SMOKE_STUB_SYSTEMCTL_CALLS" ]
  grep -q -- '--user show' "$SMOKE_STUB_SYSTEMCTL_CALLS"
  ! grep -qE '(^| )(restart|start|stop|reload|try-restart|enable|disable)( |$)' "$SMOKE_STUB_SYSTEMCTL_CALLS"
}

@test "読み取り専用: 本番が落ちていても exit 1 で報告するだけ (再起動しない)" {
  export SMOKE_CODE_HEALTH=000
  export SMOKE_CODE_DASHBOARD=000
  run bash "$SCRIPT" --json
  [ "$status" -eq 1 ]
  _assert_json "$output" '.failed' '2'
  ! grep -qE '(^| )(restart|start|stop)' "$SMOKE_STUB_SYSTEMCTL_CALLS"
}

# ------------------------------------------------------------
# dashboard の commit 一致（コンソールと同一成果物か）
# ------------------------------------------------------------

@test "dashboard: health の commit がコンソールと一致すれば PASS" {
  run bash "$SCRIPT" --json
  [ "$status" -eq 0 ]
  [[ "$output" == *"commit=0123456789abcdef0123456789abcdef01234567"* ]]
  [[ "$output" == *"console と一致"* ]]
  _assert_json "$output" '.warnings' '0'
}

@test "dashboard: commit がコンソールと不一致なら FAIL" {
  export SMOKE_BODY_DASHBOARD='{"status":"ok","commit":"fedcba9876543210fedcba9876543210fedcba98"}'
  run bash "$SCRIPT" --json
  [ "$status" -eq 1 ]
  [[ "$output" == *"commit 不一致"* ]]
  [[ "$output" == *"console=0123456789abcdef0123456789abcdef01234567"* ]]
  _assert_json "$output" '.failed' '1'
}

@test "dashboard: commit が無ければ WARN で exit 0 (FAIL にしない)" {
  export SMOKE_BODY_DASHBOARD='{"status":"ok"}'
  run bash "$SCRIPT" --json
  [ "$status" -eq 0 ]
  [[ "$output" == *"commit が無い"* ]]
  _assert_json "$output" '.ok' 'true'
  _assert_json "$output" '.warnings' '1'
}

@test "dashboard: コンソール側 commit が空なら一致比較をスキップし health の WARN のみ" {
  export SMOKE_BODY_HEALTH='{"ok":true,"service":"claudeos-web-startup"}'
  run bash "$SCRIPT" --json
  [ "$status" -eq 0 ]
  [[ "$output" == *"一致比較はスキップ"* ]]
  _assert_json "$output" '.warnings' '1'
}

@test "dashboard: staging (3743) でも commit 不一致は FAIL" {
  export SMOKE_CODE_DASHBOARD_STG=200
  export SMOKE_BODY_DASHBOARD_STG='{"status":"ok","commit":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}'
  run bash "$SCRIPT" --env staging --json
  [ "$status" -eq 1 ]
  [[ "$output" == *"commit 不一致"* ]]
  _assert_json "$output" '.failed' '1'
}

@test "dashboard: staging (3743) で commit 一致なら PASS" {
  export SMOKE_CODE_DASHBOARD_STG=200
  run bash "$SCRIPT" --env staging --json
  [ "$status" -eq 0 ]
  [[ "$output" == *"console と一致"* ]]
  _assert_json "$output" '.warnings' '0'
}

# ------------------------------------------------------------
# --expect-commit（配備した commit との照合）
# ------------------------------------------------------------

@test "expect-commit: console / dashboard とも一致すれば PASS" {
  run bash "$SCRIPT" --json --expect-commit 0123456789abcdef0123456789abcdef01234567
  [ "$status" -eq 0 ]
  [[ "$output" == *"(expect と一致)"* ]]
  _assert_json "$output" '.warnings' '0'
}

@test "expect-commit: --expect-commit=<sha> 形式も受理する" {
  run bash "$SCRIPT" --json --expect-commit=0123456789abcdef0123456789abcdef01234567
  [ "$status" -eq 0 ]
  _assert_json "$output" '.ok' 'true'
}

@test "expect-commit: console の commit が一致しなければ FAIL" {
  run bash "$SCRIPT" --json --expect-commit 9999999999999999999999999999999999999999
  [ "$status" -eq 1 ]
  [[ "$output" == *"expect=9999999999999999999999999999999999999999"* ]]
  _assert_json "$output" '.failed' '2'   # console と dashboard の両方が不一致
}

@test "expect-commit: dashboard の commit だけ不一致でも FAIL" {
  export SMOKE_BODY_DASHBOARD='{"status":"ok","commit":"fedcba9876543210fedcba9876543210fedcba98"}'
  run bash "$SCRIPT" --json --expect-commit 0123456789abcdef0123456789abcdef01234567
  [ "$status" -eq 1 ]
  [[ "$output" == *"dashboard"*"commit 不一致"* ]]
  _assert_json "$output" '.failed' '1'
}

@test "expect-commit: dashboard に commit が無ければ WARN（FAIL にしない）" {
  export SMOKE_BODY_DASHBOARD='{"status":"ok"}'
  run bash "$SCRIPT" --json --expect-commit 0123456789abcdef0123456789abcdef01234567
  [ "$status" -eq 0 ]
  [[ "$output" == *"commit が無い"* ]]
  _assert_json "$output" '.warnings' '1'
}

@test "expect-commit: 40 桁 hex でなければ exit 2" {
  run bash "$SCRIPT" --expect-commit deadbeef
  [ "$status" -eq 2 ]
  [[ "$output" == *"--expect-commit"* ]]
}
