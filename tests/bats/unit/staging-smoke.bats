#!/usr/bin/env bats
# ============================================================
# staging-smoke.bats — scripts/e2e/staging-smoke.sh の安全側契約
#
# 実サーバは起動しない。成果物ビルドは fake repo 上のスタブで代替し、
# 引数検証 / SKIP / 失敗時の JSON 形式 / 実 ~/.claudeos 非作成を検査する。
# ============================================================

load '../helpers/common-setup'

setup() {
  _bats_common_setup
  SCRIPT="$REPO_ROOT/scripts/e2e/staging-smoke.sh"
  export HOME="$TEST_TEMP/home"
  mkdir -p "$HOME"

  # スクリプトを単体で置いた fake repo (release-build の有無を制御する)
  FAKE_REPO="$TEST_TEMP/fake-repo"
  mkdir -p "$FAKE_REPO/scripts/e2e" "$FAKE_REPO/bin"
  cp "$SCRIPT" "$FAKE_REPO/scripts/e2e/staging-smoke.sh"
  chmod +x "$FAKE_REPO/scripts/e2e/staging-smoke.sh"
}
teardown() { _bats_common_teardown; }

# stdout/stderr 混在の output から JSON 行だけを取り出す
_json_line() {
  printf '%s\n' "${lines[@]}" | grep -E '^\{' | tail -n 1
}

@test "staging-smoke: スクリプトは実行可能で --help が使い方を出す" {
  [ -x "$SCRIPT" ]
  run bash "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"staging-smoke.sh [--port N] [--json] [--keep]"* ]]
  [[ "$output" == *"--keep"* ]]
  [[ "$output" == *"exit: 0 成功/SKIP, 1 検査失敗, 2 引数エラー"* ]]
}

@test "staging-smoke: 未知のオプションは exit 2" {
  run bash "$SCRIPT" --bogus
  [ "$status" -eq 2 ]
  [[ "$output" == *"未知のオプション"* ]]
}

@test "staging-smoke: --port の非数値は exit 2" {
  run bash "$SCRIPT" --port abc
  [ "$status" -eq 2 ]
  [[ "$output" == *"--port は整数"* ]]
}

@test "staging-smoke: 本番ポート 3740 は明示拒否 (exit 2)" {
  run bash "$SCRIPT" --port 3740
  [ "$status" -eq 2 ]
  [[ "$output" == *"本番ポート 3740 は使用できません"* ]]
}

@test "staging-smoke: --json 付き引数エラーは stdout に BAD_ARGS JSON" {
  run bash -c "bash '$SCRIPT' --json --port abc 2>/dev/null"
  [ "$status" -eq 2 ]
  [ "$(printf '%s' "$output" | jq -r .error)" = "BAD_ARGS" ]
  [ "$(printf '%s' "$output" | jq -r .ok)" = "false" ]
}

@test "staging-smoke: release-build が無い checkout は SKIP (exit 0)" {
  run env CCSU_STAGING_SMOKE_ROOT="$FAKE_REPO" bash "$SCRIPT" --json
  [ "$status" -eq 0 ]
  json="$(_json_line)"
  [ "$(printf '%s' "$json" | jq -r .ok)" = "true" ]
  [ "$(printf '%s' "$json" | jq -r .skipped)" = "true" ]
  [ "$(printf '%s' "$json" | jq -r .reason)" = "release-build not available" ]
}

@test "staging-smoke: SKIP 経路は実 ~/.claudeos を作らない" {
  run env CCSU_STAGING_SMOKE_ROOT="$FAKE_REPO" bash "$SCRIPT" --json
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/.claudeos" ]
}

@test "staging-smoke: release-build 失敗は exit 1 + 失敗 JSON" {
  cat > "$FAKE_REPO/bin/release-build.sh" <<'STUB'
#!/usr/bin/env bash
echo '{"ok":false,"error":"BOOM","message":"stub failure"}'
exit 1
STUB
  chmod +x "$FAKE_REPO/bin/release-build.sh"

  run env CCSU_STAGING_SMOKE_ROOT="$FAKE_REPO" bash "$SCRIPT" --json
  [ "$status" -eq 1 ]
  json="$(_json_line)"
  [ "$(printf '%s' "$json" | jq -r .ok)" = "false" ]
  [ "$(printf '%s' "$json" | jq -r .failed)" -ge 1 ]
  [ "$(printf '%s' "$json" | jq -r '.failures | length')" -ge 1 ]
  [[ "$(printf '%s' "$json" | jq -r '.failures[0]')" == *"release-build"* ]]
}

@test "staging-smoke: 成果物に startup-server.js が無ければ exit 1 (サーバは起動しない)" {
  cat > "$FAKE_REPO/bin/release-build.sh" <<'STUB'
#!/usr/bin/env bash
out=""; prev=""
for a in "$@"; do [ "$prev" = "--out" ] && out="$a"; prev="$a"; done
mkdir -p "$out"
echo '{"ok":true,"commit":"0123456789012345678901234567890123456789","short_commit":"0123456","tree_sha256":"deadbeef","file_count":0}'
STUB
  chmod +x "$FAKE_REPO/bin/release-build.sh"

  run env CCSU_STAGING_SMOKE_ROOT="$FAKE_REPO" bash "$SCRIPT" --json
  [ "$status" -eq 1 ]
  json="$(_json_line)"
  [ "$(printf '%s' "$json" | jq -r .ok)" = "false" ]
  [[ "$(printf '%s' "$json" | jq -r '.failures[0]')" == *"startup-server.js"* ]]
}
