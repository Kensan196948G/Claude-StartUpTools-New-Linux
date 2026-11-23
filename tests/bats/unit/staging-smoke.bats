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

# --- --release モード (既存の成果物を検証して起動する) ---

@test "staging-smoke: --release に存在しないディレクトリは exit 2" {
  run bash "$FAKE_REPO/scripts/e2e/staging-smoke.sh" --release "$TEST_TEMP/nope" --json
  [ "$status" -eq 2 ]
  [[ "$output" == *"BAD_ARGS"* ]]
}

@test "staging-smoke: --release に manifest.json が無ければ exit 2" {
  mkdir -p "$TEST_TEMP/rel"
  run bash "$FAKE_REPO/scripts/e2e/staging-smoke.sh" --release "$TEST_TEMP/rel" --json
  [ "$status" -eq 2 ]
  [[ "$output" == *"manifest.json"* ]]
}

@test "staging-smoke: --release は release-build が無くても SKIP しない (成果物を検証する)" {
  REL="$TEST_TEMP/rel"
  mkdir -p "$REL/scripts/release"
  printf '{"schema_version":1,"commit":"%s","short_commit":"abcdef0","tree_sha256":"%s","files":[]}\n' \
    "$(printf 'a%.0s' {1..40})" "$(printf 'b%.0s' {1..64})" > "$REL/manifest.json"
  # verify-artifact を失敗させ、検証で止まる (サーバを起動しない) ことを確かめる
  printf '#!/usr/bin/env bash\necho "{\\"ok\\":false}"\nexit 1\n' > "$REL/scripts/release/verify-artifact.sh"
  run bash "$FAKE_REPO/scripts/e2e/staging-smoke.sh" --release "$REL" --json
  [ "$status" -eq 1 ]
  json="$(_json_line)"
  [ "$(printf '%s' "$json" | jq -r '.ok')" = "false" ]
  [[ "$json" == *"verify-artifact"* ]]
  [[ "$output" != *"SKIP"* ]]
  [ ! -d "$HOME/.claudeos" ]
}

@test "staging-smoke: --release は成果物ディレクトリに書き込まない" {
  REL="$TEST_TEMP/rel"
  mkdir -p "$REL/scripts/release"
  printf '{"schema_version":1,"commit":"%s","short_commit":"abcdef0","tree_sha256":"%s","files":[]}\n' \
    "$(printf 'a%.0s' {1..40})" "$(printf 'b%.0s' {1..64})" > "$REL/manifest.json"
  printf '#!/usr/bin/env bash\necho "{\\"ok\\":false}"\nexit 1\n' > "$REL/scripts/release/verify-artifact.sh"
  before="$(find "$REL" -printf '%p %s %T@\n' | sort | sha256sum)"
  run bash "$FAKE_REPO/scripts/e2e/staging-smoke.sh" --release "$REL" --json
  after="$(find "$REL" -printf '%p %s %T@\n' | sort | sha256sum)"
  [ "$before" = "$after" ]
}

@test "staging-smoke: git 管理外で manifest があれば自身を成果物として扱う (auto-detect)" {
  printf '{"schema_version":1,"commit":"%s","short_commit":"abcdef0","tree_sha256":"%s","files":[]}\n' \
    "$(printf 'a%.0s' {1..40})" "$(printf 'b%.0s' {1..64})" > "$FAKE_REPO/manifest.json"
  mkdir -p "$FAKE_REPO/scripts/release"
  printf '#!/usr/bin/env bash\necho "{\\"ok\\":false}"\nexit 1\n' > "$FAKE_REPO/scripts/release/verify-artifact.sh"
  run bash "$FAKE_REPO/scripts/e2e/staging-smoke.sh" --json
  [ "$status" -eq 1 ]
  [[ "$output" == *"既存のリリース成果物を検証"* ]]
  [[ "$output" != *"SKIP"* ]]
}
