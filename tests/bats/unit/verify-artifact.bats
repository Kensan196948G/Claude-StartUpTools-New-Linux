#!/usr/bin/env bats
# ============================================================
# verify-artifact.bats — scripts/release/verify-artifact.sh のテスト
#
# 検証観点:
#   - 正常 artifact (通常ファイル + サブディレクトリ + シンボリックリンク) は OK
#   - sha256 改ざん / ファイル欠落 / size 不一致 / tree_sha256 改ざん を検出
#   - manifest に無い余剰ファイルは既定 WARN・--strict で FAIL
#   - 40hex 指定は $CLAUDEOS_HOME/releases/<sha> を解決
#   - --json のキー契約 / 引数エラー exit 2 / 実在しない dir は exit 1
#   - 読み取り専用 (artifact を書き換えない)
#
# 隔離: artifact は $TEST_TEMP 配下に fixtures で生成する。実 ~/.claudeos は触らない。
# ============================================================

load '../helpers/common-setup'

setup() {
  _bats_common_setup
  export CLAUDEOS_HOME="$TEST_TEMP/claudeos"
  RELEASES="$CLAUDEOS_HOME/releases"
  mkdir -p "$RELEASES"
  SCRIPT="$REPO_ROOT/scripts/release/verify-artifact.sh"
  COMMIT_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  ART="$RELEASES/$COMMIT_A"
  _make_artifact "$ART"
}

teardown() { _bats_common_teardown; }

# ------------------------------------------------------------
# fixture: release-build と同じ契約で manifest を作る
#   対象: 通常ファイル + シンボリックリンク (リンク文字列をハッシュ)
#   除外: manifest.json
# ------------------------------------------------------------

_make_artifact() {
  local dir="$1"
  mkdir -p "$dir/dir"
  printf 'hello\n' > "$dir/a.txt"
  printf '#!/bin/sh\necho b\n' > "$dir/dir/b.sh"
  ln -sfn a.txt "$dir/link.txt"

  # 1) 一覧 (path + size) を 1 回の find で取る
  local -a paths=()
  local -A sizes=()
  local e p size
  while IFS= read -r -d '' e; do
    p="${e%%$'\t'*}"
    size="${e#*$'\t'}"
    [[ "$p" == "manifest.json" ]] && continue
    paths+=("$p")
    sizes["$p"]="$size"
  done < <(find "$dir" \( -type f -o -type l \) -printf '%P\t%s\0' | LC_ALL=C sort -z)

  # 2) 通常ファイルは 1 回の sha256sum、symlink はリンク文字列をハッシュ
  local -A hashes=()
  local -a regular=() regular_abs=()
  for p in "${paths[@]}"; do
    if [[ -L "$dir/$p" ]]; then
      hashes["$p"]="$(readlink -- "$dir/$p" | sha256sum | awk '{print $1}')"
    else
      regular+=("$p")
      regular_abs+=("$dir/$p")
    fi
  done
  if (( ${#regular_abs[@]} > 0 )); then
    local line hash rel
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      hash="${line%% *}"
      rel="${line#*  }"
      rel="${rel#"$dir"/}"
      hashes["$rel"]="$hash"
    done < <(printf '%s\0' "${regular_abs[@]}" | xargs -0 -r sha256sum -- 2>/dev/null)
  fi

  # 3) entries (path<TAB>sha<TAB>size) と tree_sha256
  local entries="" tree
  for p in "${paths[@]}"; do
    entries+="$p"$'\t'"${hashes[$p]}"$'\t'"${sizes[$p]}"$'\n'
  done
  tree="$(printf '%s' "$entries" \
    | while IFS=$'\t' read -r p hash size; do
        [[ -n "$p" ]] && printf '%s\0%s\n' "$p" "$hash"
      done | sha256sum | awk '{print $1}')"

  # 4) manifest.json (一覧は stdin から渡す = 1 引数 128KB 上限の回避)
  printf '%s' "$entries" | jq -Rs --arg c "$COMMIT_A" --arg t "$tree" '
    split("\n") | map(select(length > 0) | split("\t")
      | {path: .[0], sha256: .[1], size: (.[2] | tonumber)}) as $f
    | {schema_version: 1, commit: $c, short_commit: ($c[0:7]), ref: "test",
       built_at: "2026-01-01T00:00:00Z", file_count: ($f | length),
       tree_sha256: $t, files: $f}' > "$dir/manifest.json"
}

# ------------------------------------------------------------
# 正常系
# ------------------------------------------------------------

@test "verify-artifact: 正常な artifact は OK (exit 0)" {
  run bash "$SCRIPT" "$ART"
  [ "$status" -eq 0 ]
  [[ "$output" == *"結果: OK"* ]]
  [[ "$output" == *"sha256   : OK"* ]]
  [[ "$output" == *"tree照合 : OK"* ]]
  [[ "$output" == *"余剰     : 0 件"* ]]
}

@test "verify-artifact: 40hex 指定は \$CLAUDEOS_HOME/releases/<sha> を解決する" {
  run bash "$SCRIPT" "$COMMIT_A" --json
  [ "$status" -eq 0 ]
  local last; last="$(printf '%s\n' "$output" | tail -1)"
  [ "$(printf '%s' "$last" | jq -r .ok)" = "true" ]
  [ "$(printf '%s' "$last" | jq -r .commit)" = "$COMMIT_A" ]
  [ "$(printf '%s' "$last" | jq -r .dir)" = "$ART" ]
}

@test "verify-artifact: --json のキーが契約どおり (最終行 1 行)" {
  run bash "$SCRIPT" "$ART" --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l)" -eq 1 ]
  local last; last="$(printf '%s\n' "$output" | tail -1)"
  for key in ok commit tree_sha256 files missing mismatched extra; do
    [ "$(printf '%s' "$last" | jq -r "has(\"$key\")")" = "true" ]
  done
  [ "$(printf '%s' "$last" | jq -r '.files')" -eq 3 ]
  [ "$(printf '%s' "$last" | jq -r '.missing')" -eq 0 ]
  [ "$(printf '%s' "$last" | jq -r '.mismatched')" -eq 0 ]
  [ "$(printf '%s' "$last" | jq -r '.extra')" -eq 0 ]
}

# ------------------------------------------------------------
# 改ざん・欠落の検出
# ------------------------------------------------------------

@test "verify-artifact: ファイル内容の改ざんを検出する (sha256 不一致)" {
  printf 'tampered\n' > "$ART/a.txt"

  run bash "$SCRIPT" "$ART" --json
  [ "$status" -eq 1 ]
  local last; last="$(printf '%s\n' "$output" | tail -1)"
  [ "$(printf '%s' "$last" | jq -r .ok)" = "false" ]
  [ "$(printf '%s' "$last" | jq -r .mismatched)" -eq 1 ]
  [[ "$(printf '%s' "$last" | jq -r '.errors | join(" ")')" == *"sha256 不一致: a.txt"* ]]
}

@test "verify-artifact: ファイル欠落を検出する" {
  rm -f "$ART/dir/b.sh"

  run bash "$SCRIPT" "$ART" --json
  [ "$status" -eq 1 ]
  local last; last="$(printf '%s\n' "$output" | tail -1)"
  [ "$(printf '%s' "$last" | jq -r .missing)" -eq 1 ]
  [[ "$(printf '%s' "$last" | jq -r '.errors | join(" ")')" == *"欠落: dir/b.sh"* ]]
}

@test "verify-artifact: size 不一致を検出する (sha256 は一致)" {
  jq '.files = (.files | map(if .path == "a.txt" then .size = (.size + 5) else . end))' \
    "$ART/manifest.json" > "$TEST_TEMP/m.json" && mv "$TEST_TEMP/m.json" "$ART/manifest.json"

  run bash "$SCRIPT" "$ART" --json
  [ "$status" -eq 1 ]
  local last; last="$(printf '%s\n' "$output" | tail -1)"
  [ "$(printf '%s' "$last" | jq -r .mismatched)" -eq 0 ]
  [ "$(printf '%s' "$last" | jq -r .size_mismatched)" -eq 1 ]
  [[ "$(printf '%s' "$last" | jq -r '.errors | join(" ")')" == *"size 不一致: a.txt"* ]]
}

@test "verify-artifact: tree_sha256 の改ざんを検出する" {
  jq '.tree_sha256 = "0000000000000000000000000000000000000000000000000000000000000000"' \
    "$ART/manifest.json" > "$TEST_TEMP/m.json" && mv "$TEST_TEMP/m.json" "$ART/manifest.json"

  run bash "$SCRIPT" "$ART" --json
  [ "$status" -eq 1 ]
  local last; last="$(printf '%s\n' "$output" | tail -1)"
  [ "$(printf '%s' "$last" | jq -r .ok)" = "false" ]
  [[ "$(printf '%s' "$last" | jq -r '.errors | join(" ")')" == *"tree_sha256 不一致"* ]]
}

@test "verify-artifact: file_count の不一致を検出する" {
  jq '.file_count = 99' "$ART/manifest.json" > "$TEST_TEMP/m.json" && mv "$TEST_TEMP/m.json" "$ART/manifest.json"

  run bash "$SCRIPT" "$ART" --json
  [ "$status" -eq 1 ]
  local last; last="$(printf '%s\n' "$output" | tail -1)"
  [[ "$(printf '%s' "$last" | jq -r '.errors | join(" ")')" == *"file_count 不一致"* ]]
}

@test "verify-artifact: manifest の path に '..' があれば拒否する" {
  jq '.files[0].path = "../evil"' "$ART/manifest.json" > "$TEST_TEMP/m.json" && mv "$TEST_TEMP/m.json" "$ART/manifest.json"

  run bash "$SCRIPT" "$ART"
  [ "$status" -eq 1 ]
  [[ "$output" == *"絶対パスまたは '..'"* ]]
}

# ------------------------------------------------------------
# 余剰ファイル (既定 WARN / --strict FAIL)
# ------------------------------------------------------------

@test "verify-artifact: manifest に無いファイルは既定 WARN (exit 0)" {
  printf 'extra\n' > "$ART/extra.txt"

  run bash "$SCRIPT" "$ART" --json
  [ "$status" -eq 0 ]
  local last; last="$(printf '%s\n' "$output" | tail -1)"
  [ "$(printf '%s' "$last" | jq -r .ok)" = "true" ]
  [ "$(printf '%s' "$last" | jq -r .extra)" -eq 1 ]
  [[ "$(printf '%s' "$last" | jq -r '.warnings | join(" ")')" == *"余剰: extra.txt"* ]]
}

@test "verify-artifact: --strict では余剰ファイルも FAIL (exit 1)" {
  printf 'extra\n' > "$ART/extra.txt"

  run bash "$SCRIPT" "$ART" --strict --json
  [ "$status" -eq 1 ]
  local last; last="$(printf '%s\n' "$output" | tail -1)"
  [ "$(printf '%s' "$last" | jq -r .ok)" = "false" ]
  [ "$(printf '%s' "$last" | jq -r .extra)" -eq 1 ]
  [ "$(printf '%s' "$last" | jq -r .strict)" = "true" ]
  [[ "$(printf '%s' "$last" | jq -r '.errors | join(" ")')" == *"--strict のため FAIL"* ]]
}

@test "verify-artifact: manifest.json 自身は余剰扱いしない" {
  run bash "$SCRIPT" "$ART" --strict --json
  [ "$status" -eq 0 ]
  local last; last="$(printf '%s\n' "$output" | tail -1)"
  [ "$(printf '%s' "$last" | jq -r .extra)" -eq 0 ]
}

# ------------------------------------------------------------
# エラー / 読み取り専用
# ------------------------------------------------------------

@test "verify-artifact: manifest 不在は exit 1" {
  rm -f "$ART/manifest.json"

  run bash "$SCRIPT" "$ART" --json
  [ "$status" -eq 1 ]
  local last; last="$(printf '%s\n' "$output" | tail -1)"
  [ "$(printf '%s' "$last" | jq -r .ok)" = "false" ]
  [[ "$(printf '%s' "$last" | jq -r '.errors | join(" ")')" == *"manifest.json がありません"* ]]
}

@test "verify-artifact: 実在しない release は exit 1 (ARTIFACT_NOT_FOUND)" {
  run bash "$SCRIPT" "$RELEASES/ffffffffffffffffffffffffffffffffffffffff" --json
  [ "$status" -eq 1 ]
  local last; last="$(printf '%s\n' "$output" | tail -1)"
  [ "$(printf '%s' "$last" | jq -r .error)" = "ARTIFACT_NOT_FOUND" ]
}

@test "verify-artifact: 引数エラーは exit 2" {
  run bash "$SCRIPT"
  [ "$status" -eq 2 ]

  run bash "$SCRIPT" "$ART" --frobnicate
  [ "$status" -eq 2 ]

  run bash "$SCRIPT" "$ART" "$ART"
  [ "$status" -eq 2 ]

  run bash "$SCRIPT" "$ART" --bogus --json
  [ "$status" -eq 2 ]
  local last; last="$(printf '%s\n' "$output" | tail -1)"
  [ "$(printf '%s' "$last" | jq -r .ok)" = "false" ]
  [ "$(printf '%s' "$last" | jq -r .error)" = "ARG_INVALID" ]
}

@test "verify-artifact: 読み取り専用 (artifact を書き換えない)" {
  local before after
  before="$(find "$ART" -printf '%P\t%s\t%T@\n' | LC_ALL=C sort; sha256sum "$ART/manifest.json" "$ART/a.txt" "$ART/dir/b.sh")"
  run bash "$SCRIPT" "$ART" --json
  [ "$status" -eq 0 ]
  after="$(find "$ART" -printf '%P\t%s\t%T@\n' | LC_ALL=C sort; sha256sum "$ART/manifest.json" "$ART/a.txt" "$ART/dir/b.sh")"

  [ "$before" = "$after" ]
  # 新規ファイルも作っていない
  [ "$(find "$ART" -mindepth 1 | wc -l)" -eq 5 ]
}

@test "verify-artifact: 大量ファイルでも argv 上限に当たらない (3000 件)" {
  # 3000 ファイルと manifest を 1 プロセスで作る。
  # (bats の DEBUG トラップ下ではシェルループ 3000 回が非常に遅くなるため)
  node -e '
const fs = require("fs"), path = require("path"), crypto = require("crypto");
const dir = process.argv[1], commit = process.argv[2], n = Number(process.argv[3]);
fs.mkdirSync(path.join(dir, "dir"), { recursive: true });
for (let i = 1; i <= n; i++) {
  fs.writeFileSync(path.join(dir, "dir", "f" + String(i).padStart(4, "0") + ".txt"), "x" + i + "\n");
}
const files = [];
(function walk(d) {
  for (const e of fs.readdirSync(d, { withFileTypes: true })) {
    const p = path.join(d, e.name);
    if (e.isDirectory()) { walk(p); continue; }
    const rel = path.relative(dir, p);
    if (rel === "manifest.json") continue;
    const st = fs.lstatSync(p);
    const h = crypto.createHash("sha256");
    // release-build と同じ契約: symlink はリンク文字列 + 改行、通常ファイルは中身
    if (e.isSymbolicLink()) h.update(fs.readlinkSync(p) + "\n");
    else h.update(fs.readFileSync(p));
    files.push({ path: rel, sha256: h.digest("hex"), size: st.size });
  }
})(dir);
files.sort((a, b) => (a.path < b.path ? -1 : a.path > b.path ? 1 : 0));
const tree = crypto.createHash("sha256")
  .update(files.map((f) => f.path + "\0" + f.sha256 + "\n").join("")).digest("hex");
fs.writeFileSync(path.join(dir, "manifest.json"), JSON.stringify({
  schema_version: 1, commit, short_commit: commit.slice(0, 7), ref: "test",
  built_at: "2026-01-01T00:00:00Z", file_count: files.length,
  tree_sha256: tree, files,
}, null, 2));
' "$ART" "$COMMIT_A" 3000

  run bash "$SCRIPT" "$ART" --json
  [ "$status" -eq 0 ]
  local last; last="$(printf '%s\n' "$output" | tail -1)"
  [ "$(printf '%s' "$last" | jq -r .ok)" = "true" ]
  [ "$(printf '%s' "$last" | jq -r '.files')" -ge 3003 ]
  [ "$(printf '%s' "$last" | jq -r .missing)" -eq 0 ]
  [ "$(printf '%s' "$last" | jq -r .mismatched)" -eq 0 ]
}
