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

# ------------------------------------------------------------
# 台帳 (promotions.jsonl) のローテーション (第4バッチ #6)
#   既定: 1 MiB × 3 世代。RELEASE_PROMOTIONS_MAX_BYTES / RELEASE_PROMOTIONS_KEEP で上書き。
#   行の内容は書き換えない。回転失敗は昇格を止めない (fail-open)。
# ------------------------------------------------------------

# _append_promotion_direct <commit> [max_bytes] [keep] — lib の関数を直接呼んで 1 行追記する
#   RP_* は lib のロード時に初期化されるため、source 後に前置して渡す。
_append_promotion_direct() {
  local commit="$1" max="${2-}" keep="${3-}"
  bash -c '
    source "$1/lib/common.sh"
    source "$1/lib/release-promote.sh"
    if [ -n "$3" ]; then export RELEASE_PROMOTIONS_MAX_BYTES="$3"; fi
    if [ -n "$4" ]; then export RELEASE_PROMOTIONS_KEEP="$4"; fi
    RP_ENV=production RP_COMMIT="$2" RP_TREE=tree1 RP_UNIT=u.service RP_PORT=3740 \
      rp__append_promotion PROMOTED
  ' _ "$REPO_ROOT" "$commit" "$max" "$keep"
}

# _seed_promotions <commit...> — 台帳を指定 commit の行で初期化する
_seed_promotions() {
  : > "$RELEASES/promotions.jsonl"
  local i=0 commit
  for commit in "$@"; do
    i=$((i + 1))
    printf '{"at":"2026-01-%02dT00:00:00Z","env":"staging","commit":"%s","tree_sha256":"tree-%s","result":"PROMOTED","unit":"u","port":3742}\n' \
      "$i" "$commit" "$commit" >> "$RELEASES/promotions.jsonl"
  done
}

@test "回転: 閾値以上なら追記前に .1 へ rename し、行の内容は書き換えない" {
  local seed
  seed="$(printf '{"at":"2026-01-01T00:00:00Z","env":"staging","commit":"%s","tree_sha256":"deadbeef","result":"PROMOTED","unit":"u","port":3742}\n{"at":"2026-01-02T00:00:00Z","env":"staging","commit":"%s","tree_sha256":"beefdead","result":"PROMOTED","unit":"u","port":3742}\n' "$COMMIT_B" "$COMMIT_B")"
  printf '%s' "$seed" > "$RELEASES/promotions.jsonl"

  _make_release "$REL_A" "$COMMIT_A" app/index.js
  run env RELEASE_PROMOTIONS_MAX_BYTES=64 bash "$SCRIPT" --env staging --release "$REL_A" --no-restart
  [ "$status" -eq 0 ]

  # .1 は回転前の内容と完全一致 (行の書き換えなし)
  [ -f "$RELEASES/promotions.jsonl.1" ]
  [ "$(cat "$RELEASES/promotions.jsonl.1")" = "$seed" ]

  # 現行は新しい 1 行だけ
  [ "$(wc -l < "$RELEASES/promotions.jsonl")" -eq 1 ]
  [ "$(jq -r .commit "$RELEASES/promotions.jsonl")" = "$COMMIT_A" ]
  [ "$(jq -r .result "$RELEASES/promotions.jsonl")" = "PROMOTED" ]
}

@test "回転: 閾値未満なら回転しない (.1 を作らない・行は追記される)" {
  printf '{"at":"2026-01-01T00:00:00Z","env":"staging","commit":"%s","tree_sha256":"x","result":"PROMOTED","unit":"u","port":3742}\n' \
    "$COMMIT_B" > "$RELEASES/promotions.jsonl"

  _make_release "$REL_A" "$COMMIT_A" app/index.js
  # 既定 (1 MiB) では小さい台帳は回転しない
  run bash "$SCRIPT" --env staging --release "$REL_A" --no-restart
  [ "$status" -eq 0 ]
  [ ! -e "$RELEASES/promotions.jsonl.1" ]
  [ "$(wc -l < "$RELEASES/promotions.jsonl")" -eq 2 ]
}

@test "世代上限: keep=3 で .1〜.3 に収まり .4 は残らない" {
  _seed_promotions "$COMMIT_B"

  local i
  for i in 1 2 3 4 5; do
    _append_promotion_direct "c$i" 1 3
  done

  [ -f "$RELEASES/promotions.jsonl.1" ]
  [ -f "$RELEASES/promotions.jsonl.2" ]
  [ -f "$RELEASES/promotions.jsonl.3" ]
  [ ! -e "$RELEASES/promotions.jsonl.4" ]
  # 現行 + 3 世代 = 4 ファイル
  [ "$(ls -1 "$RELEASES"/promotions.jsonl* | wc -l)" -eq 4 ]

  # 最新は現行、1 つ前は .1 に入る (時系列が保たれる)
  [ "$(jq -r .commit "$RELEASES/promotions.jsonl")" = "c5" ]
  [ "$(jq -r .commit "$RELEASES/promotions.jsonl.1")" = "c4" ]
}

@test "世代上限: keep=0 は履歴を残さず truncate する" {
  _seed_promotions "$COMMIT_B"

  _append_promotion_direct "c1" 1 0

  [ ! -e "$RELEASES/promotions.jsonl.1" ]
  [ "$(wc -l < "$RELEASES/promotions.jsonl")" -eq 1 ]
  [ "$(jq -r .commit "$RELEASES/promotions.jsonl")" = "c1" ]
}

@test "回転失敗でも追記は続行する (fail-open・stderr 1 行)" {
  printf '{"at":"2026-01-01T00:00:00Z","env":"staging","commit":"%s","tree_sha256":"x","result":"PROMOTED","unit":"u","port":3742}\n' \
    "$COMMIT_B" > "$RELEASES/promotions.jsonl"
  # 最古世代 (.3) を非空ディレクトリにして rm -f を失敗させる
  mkdir -p "$RELEASES/promotions.jsonl.3/blocker"

  _make_release "$REL_A" "$COMMIT_A" app/index.js
  run env RELEASE_PROMOTIONS_MAX_BYTES=10 bash "$SCRIPT" --env staging --release "$REL_A" --no-restart

  # 回転は失敗しても昇格自体は成功し、行は追記される
  [ "$status" -eq 0 ]
  [[ "$output" == *"ローテーションに失敗"* ]]
  [ "$(wc -l < "$RELEASES/promotions.jsonl")" -eq 2 ]
  # 既存行 (seed) の後ろに新しい昇格が追記されている
  [ "$(jq -r .commit "$RELEASES/promotions.jsonl" | head -1)" = "$COMMIT_B" ]
  [ "$(jq -r .commit "$RELEASES/promotions.jsonl" | tail -1)" = "$COMMIT_A" ]
  # 回転は中断しているので .1 は作られない
  [ ! -e "$RELEASES/promotions.jsonl.1" ]
  [ -d "$RELEASES/promotions.jsonl.3" ]
}

@test "deploy-status: 回転後も直近 5 件を古い順に読める" {
  # .1 に 3 行 (c1〜c3)、現行に 2 行 (c4, c5)
  {
    printf '{"at":"2026-01-01T00:00:00Z","env":"staging","commit":"c1","tree_sha256":"t1","result":"PROMOTED","unit":"u","port":3742}\n'
    printf '{"at":"2026-01-02T00:00:00Z","env":"staging","commit":"c2","tree_sha256":"t2","result":"PROMOTED","unit":"u","port":3742}\n'
    printf '{"at":"2026-01-03T00:00:00Z","env":"staging","commit":"c3","tree_sha256":"t3","result":"PROMOTED","unit":"u","port":3742}\n'
  } > "$RELEASES/promotions.jsonl.1"
  {
    printf '{"at":"2026-01-04T00:00:00Z","env":"staging","commit":"c4","tree_sha256":"t4","result":"PROMOTED","unit":"u","port":3742}\n'
    printf '{"at":"2026-01-05T00:00:00Z","env":"staging","commit":"c5","tree_sha256":"t5","result":"PROMOTED","unit":"u","port":3742}\n'
  } > "$RELEASES/promotions.jsonl"

  run bash "$REPO_ROOT/bin/deploy-status.sh" --json
  [ "$status" -eq 0 ]

  local last
  last="$(_last_json "$output")"
  [ "$(printf '%s' "$last" | jq -r '.promotions | length')" = "5" ]
  [ "$(printf '%s' "$last" | jq -r '[.promotions[].commit] | join(",")')" = "c1,c2,c3,c4,c5" ]
  [ "$(printf '%s' "$last" | jq -r '.promotions[4].commit')" = "c5" ]
}

@test "--dry-run: 閾値超過でも台帳を回転させない" {
  local seed
  seed="$(printf '{"at":"2026-01-01T00:00:00Z","env":"staging","commit":"%s","tree_sha256":"x","result":"PROMOTED","unit":"u","port":3742}\n' "$COMMIT_B")"
  printf '%s' "$seed" > "$RELEASES/promotions.jsonl"

  _make_release "$REL_A" "$COMMIT_A" app/index.js
  run env RELEASE_PROMOTIONS_MAX_BYTES=10 bash "$SCRIPT" --env staging --release "$REL_A" --dry-run
  [ "$status" -eq 0 ]
  [ ! -e "$RELEASES/promotions.jsonl.1" ]
  [ "$(cat "$RELEASES/promotions.jsonl")" = "$seed" ]
}

# ============================================================
# companion unit (staging の dashboard-stg 追従)
# ============================================================

# _stub_systemctl_companion [notfound_unit]
#   --user show -p LoadState <unit> : LoadState=loaded / (指定 unit なら) not-found
#   --user restart <unit>           : 呼び出しを記録して成功
_stub_systemctl_companion() {
  local notfound="${1:-}"
  cat > "$CCSU_SYSTEMCTL_BIN" <<EOF
#!/usr/bin/env bash
echo "systemctl \$*" >> "$TEST_TEMP/systemctl.calls"
if [[ "\$1" == "--user" && "\$2" == "show" ]]; then
  unit="\${@: -1}"
  if [[ -n "$notfound" && "\$unit" == "$notfound" ]]; then
    echo "LoadState=not-found"
  else
    echo "LoadState=loaded"
  fi
  exit 0
fi
exit 0
EOF
  chmod +x "$CCSU_SYSTEMCTL_BIN"
}

# _stub_curl_ports — URL の port を見て $TEST_TEMP/health-<port>.body を返す curl スタブ
_stub_curl_ports() {
  cat > "$CCSU_CURL_BIN" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$TEST_TEMP/curl.calls"
if [[ "\$*" =~ :([0-9]+)/api/health ]]; then
  cat "$TEST_TEMP/health-\${BASH_REMATCH[1]}.body" 2>/dev/null
fi
exit 0
EOF
  chmod +x "$CCSU_CURL_BIN"
}

# _health_body_port <port> <body>
_health_body_port() { printf '%s\n' "$2" > "$TEST_TEMP/health-$1.body"; }

# _healthy_companion — コンソール (3742) と companion (3743) が健全なスタブ
_healthy_companion() {
  _stub_systemctl_companion
  _stub_curl_ports
  _health_body_port 3742 '{"ok":true}'
  _health_body_port 3743 '{"status":"ok"}'
}

# _line_no <pattern> <file> — 最初に一致した行番号
_line_no() { grep -n -- "$1" "$2" | head -1 | cut -d: -f1; }

@test "companion: staging はコンソール → companion の順に restart し health(status=ok) を確認する" {
  _make_release "$REL_A" "$COMMIT_A" app/index.js
  _healthy_companion

  run bash "$SCRIPT" --env staging --release "$REL_A"
  [ "$status" -eq 0 ]

  # 順序: コンソール restart → companion の存在確認 → companion restart
  local l_console l_show l_comp
  l_console="$(_line_no 'restart claudeos-web-startup-stg.service' "$TEST_TEMP/systemctl.calls")"
  l_show="$(_line_no 'show -p LoadState claude-startuptools-dashboard-stg.service' "$TEST_TEMP/systemctl.calls")"
  l_comp="$(_line_no 'restart claude-startuptools-dashboard-stg.service' "$TEST_TEMP/systemctl.calls")"
  [ -n "$l_console" ] && [ -n "$l_show" ] && [ -n "$l_comp" ]
  [ "$l_console" -lt "$l_show" ]
  [ "$l_show" -lt "$l_comp" ]

  # health は コンソール (3742) → companion (3743) の順
  local h_console h_comp
  h_console="$(_line_no ':3742/api/health' "$TEST_TEMP/curl.calls")"
  h_comp="$(_line_no ':3743/api/health' "$TEST_TEMP/curl.calls")"
  [ -n "$h_console" ] && [ -n "$h_comp" ]
  [ "$h_console" -lt "$h_comp" ]

  [ "$(readlink "$STG_LINK")" = "$COMMIT_A" ]
  [ "$(tail -1 "$RELEASES/promotions.jsonl" | jq -r .result)" = "PROMOTED" ]
  [[ "$output" == *"dashboard-stg.service"* ]]
}

@test "companion: unit が not-found ならスキップして警告のみ (昇格は成功)" {
  _make_release "$REL_A" "$COMMIT_A" app/index.js
  _stub_systemctl_companion "claude-startuptools-dashboard-stg.service"
  _stub_curl_ports
  _health_body_port 3742 '{"ok":true}'

  run bash "$SCRIPT" --env staging --release "$REL_A"
  [ "$status" -eq 0 ]
  ! grep -qF 'restart claude-startuptools-dashboard-stg.service' "$TEST_TEMP/systemctl.calls"
  # companion の health は確認しない
  [ ! -f "$TEST_TEMP/curl.calls" ] || ! grep -q ':3743/' "$TEST_TEMP/curl.calls"
  [[ "$output" == *"存在しません"* ]]
  [ "$(readlink "$STG_LINK")" = "$COMMIT_A" ]
  [ "$(tail -1 "$RELEASES/promotions.jsonl" | jq -r .result)" = "PROMOTED" ]
}

@test "companion: health が status=ok でないと ROLLED_BACK (symlink を戻し両方 restart)" {
  _make_release "$REL_B" "$COMMIT_B" app/index.js
  _healthy_companion
  run bash "$SCRIPT" --env staging --release "$REL_B"
  [ "$status" -eq 0 ]

  _make_release "$REL_A" "$COMMIT_A" app/index.js
  : > "$TEST_TEMP/systemctl.calls"
  : > "$TEST_TEMP/curl.calls"
  # companion は ok:true を返すが status が無い → status=ok ではないので失敗と判定する
  _health_body_port 3743 '{"ok":true}'

  run bash "$SCRIPT" --env staging --release "$REL_A" --json
  [ "$status" -eq 1 ]
  [ "$(readlink "$STG_LINK")" = "$COMMIT_B" ]
  [ "$(_last_json "$output" | jq -r .result)" = "ROLLED_BACK" ]
  [[ "$output" == *"COMPANION_HEALTH_FAILED"* ]]
  # 昇格時 1 回 + ロールバック時 1 回 = 各 2 回
  [ "$(grep -cF 'restart claudeos-web-startup-stg.service' "$TEST_TEMP/systemctl.calls")" -eq 2 ]
  [ "$(grep -cF 'restart claude-startuptools-dashboard-stg.service' "$TEST_TEMP/systemctl.calls")" -eq 2 ]
  [ "$(tail -1 "$RELEASES/promotions.jsonl" | jq -r .result)" = "ROLLED_BACK" ]
}

@test "companion: production では既定で companion を触らない (本番 dashboard は drop-in 側)" {
  _make_release "$REL_A" "$COMMIT_A" app/index.js
  run bash "$SCRIPT" --env staging --release "$REL_A" --no-restart
  [ "$status" -eq 0 ]

  _healthy_companion
  _health_body_port 3740 '{"ok":true}'
  : > "$TEST_TEMP/systemctl.calls"
  : > "$TEST_TEMP/curl.calls"

  run bash "$SCRIPT" --env production --release "$REL_A" --json
  [ "$status" -eq 0 ]
  grep -qF 'restart claudeos-web-startup.service' "$TEST_TEMP/systemctl.calls"
  ! grep -qF 'dashboard-stg.service' "$TEST_TEMP/systemctl.calls"
  grep -q ':3740/api/health' "$TEST_TEMP/curl.calls"
  ! grep -q ':3743/' "$TEST_TEMP/curl.calls"
}

@test "companion: --no-restart では companion も restart も health 確認もしない" {
  _make_release "$REL_A" "$COMMIT_A" app/index.js
  _healthy_companion

  run bash "$SCRIPT" --env staging --release "$REL_A" --no-restart
  [ "$status" -eq 0 ]
  [ ! -f "$TEST_TEMP/systemctl.calls" ]
  [ ! -f "$TEST_TEMP/curl.calls" ] || ! grep -q ':3743/' "$TEST_TEMP/curl.calls"
  [ "$(readlink "$STG_LINK")" = "$COMMIT_A" ]
}

@test "companion: RELEASE_PROMOTE_COMPANIONS を空にすると無効になる" {
  _make_release "$REL_A" "$COMMIT_A" app/index.js
  _healthy_companion
  export RELEASE_PROMOTE_COMPANIONS=""

  run bash "$SCRIPT" --env staging --release "$REL_A"
  [ "$status" -eq 0 ]
  ! grep -qF 'dashboard-stg.service' "$TEST_TEMP/systemctl.calls"
  [ ! -f "$TEST_TEMP/curl.calls" ] || ! grep -q ':3743/' "$TEST_TEMP/curl.calls"
  [ "$(tail -1 "$RELEASES/promotions.jsonl" | jq -r .result)" = "PROMOTED" ]
}

@test "companion: RELEASE_PROMOTE_COMPANIONS で任意の unit=port を指定できる" {
  _make_release "$REL_A" "$COMMIT_A" app/index.js
  _stub_systemctl_companion
  _stub_curl_ports
  _health_body_port 3742 '{"ok":true}'
  _health_body_port 3999 '{"status":"ok"}'
  export RELEASE_PROMOTE_COMPANIONS="my-dashboard-stg.service=3999"

  run bash "$SCRIPT" --env staging --release "$REL_A"
  [ "$status" -eq 0 ]
  grep -qF 'restart my-dashboard-stg.service' "$TEST_TEMP/systemctl.calls"
  grep -q ':3999/api/health' "$TEST_TEMP/curl.calls"
  ! grep -qF 'claude-startuptools-dashboard-stg.service' "$TEST_TEMP/systemctl.calls"
}

@test "companion: 書式不正な指定は警告してスキップ (昇格は成功)" {
  _make_release "$REL_A" "$COMMIT_A" app/index.js
  _healthy_companion
  export RELEASE_PROMOTE_COMPANIONS="broken-entry"

  run bash "$SCRIPT" --env staging --release "$REL_A"
  [ "$status" -eq 0 ]
  [[ "$output" == *"書式が不正"* ]]
  [ "$(readlink "$STG_LINK")" = "$COMMIT_A" ]
}
