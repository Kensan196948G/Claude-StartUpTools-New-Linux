#!/usr/bin/env bats
# ============================================================
# pre-promote-check.bats — bin/pre-promote-check.sh の判定テスト
#
# release fixture / unit backup / health / disk をすべてテスト内で作り、
# curl と systemctl はスタブ化する（実ネットワーク・実 systemd に依存しない）。
# ============================================================

load '../helpers/common-setup'

SHA="1111111111111111111111111111111111111111"
STG="2222222222222222222222222222222222222222"

# mk_release <dir> <commit> — 2 ファイル + 正しい manifest を作り、tree_sha256 を返す
mk_release() {
  local dir="$1" commit="$2" ha hb tree
  mkdir -p "$dir"
  printf 'hello\n' > "$dir/a.txt"
  printf 'world\n' > "$dir/b.txt"
  ha="$(sha256sum "$dir/a.txt" | cut -d' ' -f1)"
  hb="$(sha256sum "$dir/b.txt" | cut -d' ' -f1)"
  tree="$(printf 'a.txt\0%s\nb.txt\0%s\n' "$ha" "$hb" | sha256sum | cut -d' ' -f1)"
  jq -n --arg c "$commit" --arg t "$tree" --arg ha "$ha" --arg hb "$hb" \
    '{schema_version:1,commit:$c,short_commit:($c[0:7]),ref:"HEAD",built_at:"2026-01-01T00:00:00Z",
      file_count:2,tree_sha256:$t,
      files:[{path:"a.txt",sha256:$ha,size:6},{path:"b.txt",sha256:$hb,size:6}]}' > "$dir/manifest.json"
  printf '%s' "$tree"
}

setup() {
  _bats_common_setup

  SCRIPT="$REPO_ROOT/bin/pre-promote-check.sh"
  TEST_HOME="$TEST_TEMP/home"
  RELEASES="$TEST_HOME/releases"
  UNIT_DIR="$TEST_TEMP/systemd-user"
  mkdir -p "$RELEASES" "$UNIT_DIR"

  TREE="$(mk_release "$RELEASES/$SHA" "$SHA")"
  mk_release "$RELEASES/$STG" "$STG" >/dev/null
  ln -s "$STG" "$RELEASES/staging-current"

  printf 'unit\n' > "$UNIT_DIR/claudeos-web-startup.service"
  printf 'unit\n' > "$UNIT_DIR/claudeos-web-startup.service.bak-20260101-000000"

  # curl スタブ: URL のポートで status/body を切り替える（既定 200 / ok:true）
  cat > "$STUB_BIN/fake-curl" <<'STUB'
#!/usr/bin/env bash
url=""
for a in "$@"; do case "$a" in http*) url="$a" ;; esac; done
code="${FAKE_CURL_CODE:-200}"
case "$url" in
  *:3740/*) [ -n "${FAKE_PROD_CODE:-}" ] && code="$FAKE_PROD_CODE" ;;
  *:3742/*) [ -n "${FAKE_STG_CODE:-}" ] && code="$FAKE_STG_CODE" ;;
esac
body="${FAKE_CURL_BODY:-}"
if [ -z "$body" ]; then body='{"ok":true}'; fi
printf '%s\n%s' "$body" "$code"
STUB
  chmod +x "$STUB_BIN/fake-curl"

  cat > "$STUB_BIN/fake-systemctl" <<'STUB'
#!/usr/bin/env bash
echo "ActiveState=active"
STUB
  chmod +x "$STUB_BIN/fake-systemctl"

  export CCSU_SYSTEMD_USER_DIR="$UNIT_DIR"
  export CCSU_CURL_BIN="$STUB_BIN/fake-curl"
  export CCSU_SYSTEMCTL_BIN="$STUB_BIN/fake-systemctl"
  export CCSU_VERIFY_ARTIFACT_BIN="$TEST_TEMP/no-verify-artifact.sh"
  export CCSU_PRE_PROMOTE_MIN_FREE_MB=1024
}
teardown() { _bats_common_teardown; }

json_line() { printf '%s\n' "${lines[@]}" | grep -E '^\{' | tail -n 1; }

snapshot() {
  {
    find "$RELEASES" "$UNIT_DIR" -type f -printf '%p %s %T@\n' 2>/dev/null
    find "$RELEASES" -type l -printf '%p -> %l\n' 2>/dev/null
  } | LC_ALL=C sort
}

@test "pre-promote-check: 全 PASS で exit 0 / --json の集計が正しい" {
  run bash "$SCRIPT" --release "$SHA" --json --home "$TEST_HOME"
  [ "$status" -eq 0 ]
  json="$(json_line)"
  [ "$(printf '%s' "$json" | jq -r .ok)" = "true" ]
  [ "$(printf '%s' "$json" | jq -r .release)" = "$SHA" ]
  [ "$(printf '%s' "$json" | jq -r .tree_sha256)" = "$TREE" ]
  [ "$(printf '%s' "$json" | jq -r .checks)" -eq 7 ]
  [ "$(printf '%s' "$json" | jq -r .failed)" -eq 0 ]
  [ "$(printf '%s' "$json" | jq -r .warnings)" -eq 0 ]
}

@test "pre-promote-check: --json の stdout は結果 JSON 1 行だけ（ログは stderr）" {
  run bash -c "bash '$SCRIPT' --release '$SHA' --json --home '$TEST_HOME' 2>/dev/null"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  printf '%s' "${lines[0]}" | jq -e '.ok == true' >/dev/null
}

@test "pre-promote-check: staging の tree_sha256 不一致は FAIL" {
  jq '.tree_sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' \
    "$RELEASES/$STG/manifest.json" > "$TEST_TEMP/m.tmp" && mv "$TEST_TEMP/m.tmp" "$RELEASES/$STG/manifest.json"
  run bash "$SCRIPT" --release "$SHA" --json --home "$TEST_HOME"
  [ "$status" -eq 1 ]
  [[ "$output" == *"[FAIL] staging 一致"* ]]
  [ "$(json_line | jq -r .failed)" -ge 1 ]
}

@test "pre-promote-check: unit バックアップ無しは FAIL し作成コマンドを表示" {
  rm -f "$UNIT_DIR"/claudeos-web-startup.service.bak-*
  run bash "$SCRIPT" --release "$SHA" --json --home "$TEST_HOME"
  [ "$status" -eq 1 ]
  [[ "$output" == *"[FAIL] unit バックアップ"* ]]
  [[ "$output" == *"cp -a"* ]]
}

@test "pre-promote-check: 本番 health が落ちていれば FAIL" {
  run env FAKE_PROD_CODE=500 bash "$SCRIPT" --release "$SHA" --json --home "$TEST_HOME"
  [ "$status" -eq 1 ]
  [[ "$output" == *"[FAIL] production health"* ]]
}

@test "pre-promote-check: staging health が落ちていても WARN で exit 0" {
  run env FAKE_STG_CODE=500 bash "$SCRIPT" --release "$SHA" --json --home "$TEST_HOME"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[WARN] staging health"* ]]
  [ "$(json_line | jq -r .failed)" -eq 0 ]
  [ "$(json_line | jq -r .warnings)" -ge 1 ]
}

@test "pre-promote-check: artifact 改ざん（sha256 不一致）は FAIL" {
  printf 'tampered\n' >> "$RELEASES/$SHA/a.txt"
  run bash "$SCRIPT" --release "$SHA" --json --home "$TEST_HOME"
  [ "$status" -eq 1 ]
  [[ "$output" == *"[FAIL] artifact"* ]]
}

@test "pre-promote-check: manifest の tree_sha256 改ざんは FAIL" {
  jq '.tree_sha256 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"' \
    "$RELEASES/$SHA/manifest.json" > "$TEST_TEMP/m.tmp" && mv "$TEST_TEMP/m.tmp" "$RELEASES/$SHA/manifest.json"
  run bash "$SCRIPT" --release "$SHA" --json --home "$TEST_HOME"
  [ "$status" -eq 1 ]
  [[ "$output" == *"[FAIL] artifact"* ]]
}

@test "pre-promote-check: staging-current が無ければ FAIL" {
  rm -f "$RELEASES/staging-current"
  run bash "$SCRIPT" --release "$SHA" --json --home "$TEST_HOME"
  [ "$status" -eq 1 ]
  [[ "$output" == *"[FAIL] staging 一致"* ]]
}

@test "pre-promote-check: ディスク空き不足は WARN で exit 0" {
  run env CCSU_PRE_PROMOTE_MIN_FREE_MB=999999999 bash "$SCRIPT" --release "$SHA" --json --home "$TEST_HOME"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[WARN] disk"* ]]
  [ "$(json_line | jq -r .warnings)" -ge 1 ]
}

@test "pre-promote-check: production-current 不在は初回昇格として戻し手順を表示" {
  run bash "$SCRIPT" --release "$SHA" --home "$TEST_HOME"
  [ "$status" -eq 0 ]
  [[ "$output" == *"初回昇格"* ]]
  [[ "$output" == *"戻し手順"* ]]
  [[ "$output" == *"systemctl --user stop claudeos-web-startup.service"* ]]
}

@test "pre-promote-check: production-current ありは previous の有無を表示" {
  mk_release "$RELEASES/7777777777777777777777777777777777777777" "7777777777777777777777777777777777777777" >/dev/null
  ln -s "7777777777777777777777777777777777777777" "$RELEASES/production-current"
  printf '%s' "6666666666666666666666666666666666666666" > "$RELEASES/production-previous"
  run bash "$SCRIPT" --release "$SHA" --home "$TEST_HOME"
  [ "$status" -eq 0 ]
  [[ "$output" == *"previous あり"* ]]
  [[ "$output" == *"ActiveState=active"* ]]
}

@test "pre-promote-check: verify-artifact.sh があれば検証を委譲する" {
  # 改ざんされていても、委譲先が ok と言えば artifact は PASS（委譲の実証）
  printf 'tampered\n' >> "$RELEASES/$SHA/a.txt"
  cat > "$TEST_TEMP/fake-verify-artifact.sh" <<STUB
#!/usr/bin/env bash
printf '{"ok":true,"tree_sha256":"$TREE"}\n'
STUB
  chmod +x "$TEST_TEMP/fake-verify-artifact.sh"
  run env CCSU_VERIFY_ARTIFACT_BIN="$TEST_TEMP/fake-verify-artifact.sh" \
    bash "$SCRIPT" --release "$SHA" --json --home "$TEST_HOME"
  [ "$status" -eq 0 ]
  [[ "$output" == *"verify-artifact.sh OK"* ]]
}

@test "pre-promote-check: 読み取り専用（前後で release / unit の mtime・sha・symlink が不変）" {
  before="$(snapshot)"
  run bash "$SCRIPT" --release "$SHA" --json --home "$TEST_HOME"
  [ "$status" -eq 0 ]
  after="$(snapshot)"
  [ "$before" = "$after" ]
  [ "$(ls -1 "$UNIT_DIR"/claudeos-web-startup.service.bak-* | wc -l)" -eq 1 ]
}

@test "pre-promote-check: 引数エラーは exit 2（--release 必須 / 不正 sha / 未知オプション）" {
  run bash "$SCRIPT" --json --home "$TEST_HOME"
  [ "$status" -eq 2 ]
  [ "$(json_line | jq -r .error)" = "BAD_ARGS" ]

  run bash "$SCRIPT" --release deadbeef --json --home "$TEST_HOME"
  [ "$status" -eq 2 ]

  run bash "$SCRIPT" --release "$SHA" --bogus
  [ "$status" -eq 2 ]
}
