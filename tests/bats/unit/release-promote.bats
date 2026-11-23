#!/usr/bin/env bats
# ============================================================
# release-promote.bats — bin/release-promote.sh / lib/release-promote.sh のテスト
#
# 方針:
#   - release dir と manifest は fixtures で自前生成する (task-4 の release-build に依存しない)
#   - systemctl は PATH スタブ (CCSU_SYSTEMCTL_BIN) で差し替え、実 systemd を触らない
#   - health は curl スタブ (CCSU_CURL_BIN) で代替し、実 HTTP / 本番 3740 へ接続しない
#   - CLAUDEOS_HOME は必ず $BATS_TEST_TMPDIR 配下へ向ける (実 ~/.claudeos を書かない)
# ============================================================

load '../helpers/common-setup'

setup() {
  _bats_common_setup

  export CLAUDEOS_HOME="$TEST_TEMP/claudeos"
  RELEASES="$CLAUDEOS_HOME/releases"
  mkdir -p "$RELEASES"

  COMMIT_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  COMMIT_B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  REL_A="$RELEASES/$COMMIT_A"
  REL_B="$RELEASES/$COMMIT_B"
  STG_LINK="$RELEASES/staging-current"
  PROD_LINK="$RELEASES/production-current"

  export CCSU_SYSTEMCTL_BIN="$STUB_BIN/systemctl"
  export CCSU_CURL_BIN="$STUB_BIN/curl"
  _stub_systemctl 0
  _health_body '{"ok":true}'
  _stub_curl 0

  # 失敗系テストが長引かないよう、health は短く打ち切る
  # 成功経路はスタブが即応答する。失敗経路だけ 1 秒で打ち切ってテストを速く保つ
  export CCSU_HEALTH_TIMEOUT=1
  export CCSU_HEALTH_INTERVAL=0.05

  SCRIPT="$REPO_ROOT/bin/release-promote.sh"
}

teardown() { _bats_common_teardown; }

# ------------------------------------------------------------
# fixtures / stubs
# ------------------------------------------------------------

# _make_release <dir> <40hex commit> [relative paths...] — release dir + manifest.json
_make_release() {
  local dir="$1" commit="$2"
  shift 2
  mkdir -p "$dir"

  local p
  for p in "$@"; do
    mkdir -p "$dir/$(dirname -- "$p")"
    # commit を含める: 別 fixture が偶然同一 tree_sha256 にならないようにする
    printf 'content of %s @ %s\n' "$p" "$commit" > "$dir/$p"
  done

  local pair_file="$TEST_TEMP/pairs.txt"
  : > "$pair_file"
  local -a objs=()
  local f sha size
  while IFS= read -r f; do
    sha="$(sha256sum "$dir/$f" | awk '{print $1}')"
    size="$(stat -c %s "$dir/$f")"
    printf '%s\t%s\t%s\n' "$f" "$sha" "$size" >> "$pair_file"
    objs+=("$(jq -cn --arg path "$f" --arg sha "$sha" --argjson size "$size" \
      '{path:$path,sha256:$sha,size:$size}')")
  done < <(printf '%s\n' "$@" | LC_ALL=C sort)

  # tree_sha256 = ソート済み "<path>\0<sha256>\n" 連結の sha256 (契約どおり)
  local tree
  tree="$(while IFS=$'\t' read -r f sha size; do printf '%s\0%s\n' "$f" "$sha"; done < "$pair_file" \
    | sha256sum | awk '{print $1}')"

  local files_json
  files_json="$(printf '%s\n' "${objs[@]}" | jq -s '.')"
  jq -n --arg commit "$commit" --arg short "${commit:0:7}" --arg tree "$tree" \
    --argjson files "$files_json" \
    '{schema_version:1,commit:$commit,short_commit:$short,ref:"test",
      built_at:"2026-01-01T00:00:00Z",file_count:($files|length),
      tree_sha256:$tree,files:$files}' > "$dir/manifest.json"
}

# _stub_systemctl <exit code> — 引数を記録するだけの systemctl スタブ
_stub_systemctl() {
  local code="${1:-0}"
  printf '#!/usr/bin/env bash\necho "systemctl $*" >> "%s/systemctl.calls"\nexit %s\n' \
    "$TEST_TEMP" "$code" > "$CCSU_SYSTEMCTL_BIN"
  chmod +x "$CCSU_SYSTEMCTL_BIN"
}

# _stub_curl <exit code> — 呼ばれた URL を記録し、固定 body を返す curl スタブ
_stub_curl() {
  local code="${1:-0}"
  printf '#!/usr/bin/env bash\necho "$*" >> "%s/curl.calls"\ncat "%s/health.body" 2>/dev/null\nexit %s\n' \
    "$TEST_TEMP" "$TEST_TEMP" "$code" > "$CCSU_CURL_BIN"
  chmod +x "$CCSU_CURL_BIN"
}

_health_body() { printf '%s\n' "$1" > "$TEST_TEMP/health.body"; }

# _last_json <bats output> — 最終行 (JSON) を取り出す
_last_json() { printf '%s\n' "$1" | tail -1; }

# ------------------------------------------------------------
# 整合性 (切替前のゲート)
# ------------------------------------------------------------

@test "整合性: ファイル改竄は INTEGRITY_MISMATCH で切替なし・restart なし" {
  _make_release "$REL_A" "$COMMIT_A" app/index.js app/lib/x.sh
  printf 'tampered\n' > "$REL_A/app/index.js"

  run bash "$SCRIPT" --env staging --release "$REL_A"
  [ "$status" -eq 1 ]
  [[ "$output" == *"INTEGRITY_MISMATCH"* ]]
  [ ! -L "$STG_LINK" ]
  [ ! -f "$TEST_TEMP/systemctl.calls" ]
  [ ! -e "$RELEASES/promotions.jsonl" ]
}

@test "整合性: manifest の tree_sha256 改竄も検出する" {
  _make_release "$REL_A" "$COMMIT_A" app/index.js
  jq '.tree_sha256 = "0000000000000000000000000000000000000000000000000000000000000000"' \
    "$REL_A/manifest.json" > "$TEST_TEMP/m.json"
  mv "$TEST_TEMP/m.json" "$REL_A/manifest.json"

  run bash "$SCRIPT" --env staging --release "$REL_A"
  [ "$status" -eq 1 ]
  [[ "$output" == *"INTEGRITY_MISMATCH"* ]]
  [ ! -L "$STG_LINK" ]
}

@test "整合性: manifest 不在は MANIFEST_MISSING / 不正 JSON は MANIFEST_INVALID" {
  mkdir -p "$REL_A"

  run bash "$SCRIPT" --env staging --release "$REL_A"
  [ "$status" -eq 1 ]
  [[ "$output" == *"MANIFEST_MISSING"* ]]

  printf '{ not json\n' > "$REL_A/manifest.json"
  run bash "$SCRIPT" --env staging --release "$REL_A"
  [ "$status" -eq 1 ]
  [[ "$output" == *"MANIFEST_INVALID"* ]]
  [ ! -L "$STG_LINK" ]
}

@test "整合性: files[].path の '..' は MANIFEST_INVALID で拒否" {
  _make_release "$REL_A" "$COMMIT_A" app/index.js
  jq '.files[0].path = "../evil"' "$REL_A/manifest.json" > "$TEST_TEMP/m.json"
  mv "$TEST_TEMP/m.json" "$REL_A/manifest.json"

  run bash "$SCRIPT" --env staging --release "$REL_A"
  [ "$status" -eq 1 ]
  [[ "$output" == *"MANIFEST_INVALID"* ]]
  [ ! -L "$STG_LINK" ]
}

# ------------------------------------------------------------
# staging 検証ゲート (production 昇格)
# ------------------------------------------------------------

@test "production: staging 未検証なら STAGING_NOT_VERIFIED で拒否 (切替・restart なし)" {
  _make_release "$REL_A" "$COMMIT_A" app/index.js

  run bash "$SCRIPT" --env production --release "$REL_A"
  [ "$status" -eq 1 ]
  [[ "$output" == *"STAGING_NOT_VERIFIED"* ]]
  [ ! -L "$PROD_LINK" ]
  [ ! -f "$TEST_TEMP/systemctl.calls" ]
  [ ! -f "$TEST_TEMP/curl.calls" ]
}

@test "production: staging が別 artifact を指している場合も拒否" {
  _make_release "$REL_B" "$COMMIT_B" app/index.js
  run bash "$SCRIPT" --env staging --release "$REL_B" --no-restart
  [ "$status" -eq 0 ]

  _make_release "$REL_A" "$COMMIT_A" app/index.js
  run bash "$SCRIPT" --env production --release "$REL_A"
  [ "$status" -eq 1 ]
  [[ "$output" == *"STAGING_NOT_VERIFIED"* ]]
  [ ! -L "$PROD_LINK" ]
}

@test "production: staging 検証済みなら本番 unit と本番 port で昇格する" {
  _make_release "$REL_A" "$COMMIT_A" app/index.js
  run bash "$SCRIPT" --env staging --release "$REL_A"
  [ "$status" -eq 0 ]

  : > "$TEST_TEMP/systemctl.calls"
  : > "$TEST_TEMP/curl.calls"
  run bash "$SCRIPT" --env production --release "$REL_A" --json
  [ "$status" -eq 0 ]
  [ -L "$PROD_LINK" ]
  [ "$(readlink "$PROD_LINK")" = "$COMMIT_A" ]
  grep -qF 'restart claudeos-web-startup.service' "$TEST_TEMP/systemctl.calls"
  grep -q '127.0.0.1:3740/api/health' "$TEST_TEMP/curl.calls"
  [ "$(_last_json "$output" | jq -r .env)" = "production" ]
  [ "$(_last_json "$output" | jq -r .port)" = "3740" ]
}

# ------------------------------------------------------------
# symlink / previous
# ------------------------------------------------------------

@test "staging: symlink が張り替わり previous に旧 target が記録される" {
  _make_release "$REL_B" "$COMMIT_B" app/index.js
  run bash "$SCRIPT" --env staging --release "$REL_B" --no-restart
  [ "$status" -eq 0 ]
  [ "$(readlink "$STG_LINK")" = "$COMMIT_B" ]
  [ ! -f "$RELEASES/staging-previous" ]

  _make_release "$REL_A" "$COMMIT_A" app/index.js
  run bash "$SCRIPT" --env staging --release "$REL_A" --no-restart
  [ "$status" -eq 0 ]
  [ "$(readlink "$STG_LINK")" = "$COMMIT_A" ]
  [ "$(cat "$RELEASES/staging-previous")" = "$COMMIT_B" ]
}

@test "staging: 同一 target への再昇格では previous を壊さない (rollback 先を保つ)" {
  _make_release "$REL_B" "$COMMIT_B" app/index.js
  run bash "$SCRIPT" --env staging --release "$REL_B" --no-restart
  [ "$status" -eq 0 ]

  _make_release "$REL_A" "$COMMIT_A" app/index.js
  run bash "$SCRIPT" --env staging --release "$REL_A" --no-restart
  [ "$status" -eq 0 ]
  [ "$(cat "$RELEASES/staging-previous")" = "$COMMIT_B" ]

  # 同じ A を再昇格しても previous は B のまま (rollback 先が消えない)
  run bash "$SCRIPT" --env staging --release "$REL_A" --no-restart
  [ "$status" -eq 0 ]
  [ "$(readlink "$STG_LINK")" = "$COMMIT_A" ]
  [ "$(cat "$RELEASES/staging-previous")" = "$COMMIT_B" ]

  run bash "$SCRIPT" --env staging --rollback --no-restart
  [ "$status" -eq 0 ]
  [ "$(readlink "$STG_LINK")" = "$COMMIT_B" ]
}

@test "staging: 40hex 指定は \$CLAUDEOS_HOME/releases/<sha> を解決する" {
  _make_release "$REL_A" "$COMMIT_A" app/index.js
  run bash "$SCRIPT" --env staging --release "$COMMIT_A" --no-restart
  [ "$status" -eq 0 ]
  [ "$(readlink "$STG_LINK")" = "$COMMIT_A" ]
}

@test "staging: 本番 unit (claudeos-web-startup.service) と本番 port 3740 を使わない" {
  _make_release "$REL_A" "$COMMIT_A" app/index.js
  run bash "$SCRIPT" --env staging --release "$REL_A"
  [ "$status" -eq 0 ]

  grep -qF 'restart claudeos-web-startup-stg.service' "$TEST_TEMP/systemctl.calls"
  ! grep -qF 'claudeos-web-startup.service' "$TEST_TEMP/systemctl.calls"
  grep -q '127.0.0.1:3742/api/health' "$TEST_TEMP/curl.calls"
  ! grep -q '3740' "$TEST_TEMP/curl.calls"
  [[ "$output" != *"3740"* ]]
}

@test "staging: --no-restart は systemctl を呼ばない" {
  _make_release "$REL_A" "$COMMIT_A" app/index.js
  run bash "$SCRIPT" --env staging --release "$REL_A" --no-restart
  [ "$status" -eq 0 ]
  [ ! -f "$TEST_TEMP/systemctl.calls" ]
}

# ------------------------------------------------------------
# 自動ロールバック
# ------------------------------------------------------------

@test "自動ロールバック: health 失敗で旧 target へ戻し再 restart して ROLLED_BACK" {
  _make_release "$REL_B" "$COMMIT_B" app/index.js
  run bash "$SCRIPT" --env staging --release "$REL_B"
  [ "$status" -eq 0 ]

  _make_release "$REL_A" "$COMMIT_A" app/index.js
  : > "$TEST_TEMP/systemctl.calls"
  _health_body '{"ok":false}'
  _stub_curl 0

  run bash "$SCRIPT" --env staging --release "$REL_A" --json
  [ "$status" -eq 1 ]
  [ "$(readlink "$STG_LINK")" = "$COMMIT_B" ]
  [ "$(grep -c 'restart' "$TEST_TEMP/systemctl.calls")" -eq 2 ]
  [ "$(_last_json "$output" | jq -r .result)" = "ROLLED_BACK" ]
  [ "$(_last_json "$output" | jq -r .ok)" = "true" ]
  [ "$(tail -1 "$RELEASES/promotions.jsonl" | jq -r .result)" = "ROLLED_BACK" ]
}

@test "自動ロールバック: restart 失敗でも旧 target へ戻して ROLLED_BACK" {
  _make_release "$REL_B" "$COMMIT_B" app/index.js
  run bash "$SCRIPT" --env staging --release "$REL_B" --no-restart
  [ "$status" -eq 0 ]

  _stub_systemctl 5
  _make_release "$REL_A" "$COMMIT_A" app/index.js
  run bash "$SCRIPT" --env staging --release "$REL_A" --json
  [ "$status" -eq 1 ]
  [ "$(readlink "$STG_LINK")" = "$COMMIT_B" ]
  [ "$(_last_json "$output" | jq -r .result)" = "ROLLED_BACK" ]
}

# ------------------------------------------------------------
# --rollback
# ------------------------------------------------------------

@test "--rollback: previous へ戻す / previous が無ければ exit 1" {
  _make_release "$REL_B" "$COMMIT_B" app/index.js
  run bash "$SCRIPT" --env staging --release "$REL_B" --no-restart
  [ "$status" -eq 0 ]

  _make_release "$REL_A" "$COMMIT_A" app/index.js
  run bash "$SCRIPT" --env staging --release "$REL_A" --no-restart
  [ "$status" -eq 0 ]
  [ "$(readlink "$STG_LINK")" = "$COMMIT_A" ]

  run bash "$SCRIPT" --env staging --rollback --no-restart
  [ "$status" -eq 0 ]
  [ "$(readlink "$STG_LINK")" = "$COMMIT_B" ]

  rm -f "$RELEASES/staging-previous"
  run bash "$SCRIPT" --env staging --rollback --no-restart
  [ "$status" -eq 1 ]
  [[ "$output" == *"NO_PREVIOUS"* ]]
}

# ------------------------------------------------------------
# --dry-run
# ------------------------------------------------------------

@test "--dry-run: 何も書き換えない (symlink/previous/台帳/restart/health)" {
  _make_release "$REL_A" "$COMMIT_A" app/index.js

  run bash "$SCRIPT" --env staging --release "$REL_A" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"dry-run"* ]]
  [ ! -L "$STG_LINK" ]
  [ ! -f "$RELEASES/staging-previous" ]
  [ ! -e "$RELEASES/promotions.jsonl" ]
  [ ! -f "$TEST_TEMP/systemctl.calls" ]
  [ ! -f "$TEST_TEMP/curl.calls" ]

  # 既存リンクがあっても動かさない
  _make_release "$REL_B" "$COMMIT_B" app/index.js
  run bash "$SCRIPT" --env staging --release "$REL_B" --no-restart
  [ "$status" -eq 0 ]
  run bash "$SCRIPT" --env staging --release "$REL_A" --dry-run
  [ "$status" -eq 0 ]
  [ "$(readlink "$STG_LINK")" = "$COMMIT_B" ]
  [ ! -f "$RELEASES/staging-previous" ]
}

# ------------------------------------------------------------
# 台帳 / JSON
# ------------------------------------------------------------

@test "promotions.jsonl: 昇格を 1 行追記し、既存行を壊さない" {
  printf '{"at":"2026-01-01T00:00:00Z","env":"staging","commit":"%s","tree_sha256":"deadbeef","result":"PROMOTED","unit":"u","port":3742}\n' \
    "$COMMIT_B" > "$RELEASES/promotions.jsonl"

  _make_release "$REL_A" "$COMMIT_A" app/index.js
  run bash "$SCRIPT" --env staging --release "$REL_A" --no-restart
  [ "$status" -eq 0 ]

  [ "$(wc -l < "$RELEASES/promotions.jsonl")" -eq 2 ]
  grep -qF "\"commit\":\"$COMMIT_B\"" "$RELEASES/promotions.jsonl"

  local last
  last="$(tail -1 "$RELEASES/promotions.jsonl")"
  [ "$(printf '%s' "$last" | jq -r .env)" = "staging" ]
  [ "$(printf '%s' "$last" | jq -r .commit)" = "$COMMIT_A" ]
  [ "$(printf '%s' "$last" | jq -r .result)" = "PROMOTED" ]
  [ "$(printf '%s' "$last" | jq -r .unit)" = "claudeos-web-startup-stg.service" ]
  [ "$(printf '%s' "$last" | jq -r .port)" = "3742" ]
  [ -n "$(printf '%s' "$last" | jq -r .at)" ]
  [ -n "$(printf '%s' "$last" | jq -r .tree_sha256)" ]
}

@test "--json: 成功時のキーが契約どおり (previous_commit 含む)" {
  _make_release "$REL_B" "$COMMIT_B" app/index.js
  run bash "$SCRIPT" --env staging --release "$REL_B" --no-restart --json
  [ "$status" -eq 0 ]
  [ "$(_last_json "$output" | jq -r .previous_commit)" = "" ]

  _make_release "$REL_A" "$COMMIT_A" app/index.js
  run bash "$SCRIPT" --env staging --release "$REL_A" --no-restart --json
  [ "$status" -eq 0 ]

  local last
  last="$(_last_json "$output")"
  printf '%s' "$last" | jq -e '.ok == true' >/dev/null
  [ "$(printf '%s' "$last" | jq -r .env)" = "staging" ]
  [ "$(printf '%s' "$last" | jq -r .commit)" = "$COMMIT_A" ]
  [ "$(printf '%s' "$last" | jq -r .previous_commit)" = "$COMMIT_B" ]
  [ "$(printf '%s' "$last" | jq -r .unit)" = "claudeos-web-startup-stg.service" ]
  [ "$(printf '%s' "$last" | jq -r .port)" = "3742" ]
  [ "$(printf '%s' "$last" | jq -r .result)" = "PROMOTED" ]
  [ "$(printf '%s' "$last" | jq -r 'has("tree_sha256")')" = "true" ]
}

@test "--json: エラー時は {ok:false,error,message}" {
  run bash "$SCRIPT" --env staging --release "$RELEASES/$COMMIT_A" --json
  [ "$status" -eq 1 ]

  local last
  last="$(_last_json "$output")"
  [ "$(printf '%s' "$last" | jq -r .ok)" = "false" ]
  [ "$(printf '%s' "$last" | jq -r .error)" = "RELEASE_NOT_FOUND" ]
  [ -n "$(printf '%s' "$last" | jq -r .message)" ]
}

# ------------------------------------------------------------
# 安全弁 / 引数
# ------------------------------------------------------------

@test "安全弁: --force は存在せず引数エラー (staging 検証を迂回できない)" {
  _make_release "$REL_A" "$COMMIT_A" app/index.js

  run bash "$SCRIPT" --env production --release "$REL_A" --force
  [ "$status" -eq 2 ]
  [[ "$output" == *"--force は提供しません"* ]]
  [ ! -L "$PROD_LINK" ]
}

@test "引数: --env 不正 / --release 欠落 / --port 非数値 / 不明引数 は exit 2" {
  run bash "$SCRIPT" --env prod --release /tmp/x
  [ "$status" -eq 2 ]

  run bash "$SCRIPT" --env staging
  [ "$status" -eq 2 ]

  _make_release "$REL_A" "$COMMIT_A" app/index.js
  run bash "$SCRIPT" --env staging --release "$REL_A" --port abc
  [ "$status" -eq 2 ]

  run bash "$SCRIPT" --env staging --release "$REL_A" --bogus
  [ "$status" -eq 2 ]

  # --rollback と --release は併用不可
  run bash "$SCRIPT" --env staging --release "$REL_A" --rollback
  [ "$status" -eq 2 ]
}
