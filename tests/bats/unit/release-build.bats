#!/usr/bin/env bats
# ============================================================
# release-build.bats — bin/release-build.sh / lib/release-artifact.sh の単体テスト
#
# 検証観点 (release-build の契約):
#   - 既定出力先 $CLAUDEOS_HOME/releases/<40hex>/ に成果物 + manifest.json
#   - --out による任意出力先 (既定先は作られない)
#   - --json のキー: ok/commit/dir/tree_sha256/file_count (stdout は JSON 1 行)
#   - --dry-run は一切書き込まない
#   - 既存の非空ディレクトリを --force 無しで拒否 (exit 1, 中身を壊さない)
#   - --force で置換
#   - 不正 ref は exit 1 / 引数エラーは exit 2 (--json は ok:false)
#   - manifest の files/tree_sha256/file_count が実ファイルと一致し path 昇順
#   - tracked files のみ (.git / untracked / 作業ツリーの dirty 変更を含まない)
#   - --ref の指定が解決され manifest に記録される
#
# 隔離: フィクスチャ git リポジトリを $BATS_TEST_TMPDIR に作り、CCSU_ROOT と
#       CLAUDEOS_HOME をそこへ向ける。実 ~/.claudeos には一切触れない
#       (リポジトリの実体も読むだけで、書き換えない)。
# ============================================================

load '../helpers/common-setup'

setup() {
  _bats_common_setup

  RB="$REPO_ROOT/bin/release-build.sh"

  export CLAUDEOS_HOME="$BATS_TEST_TMPDIR/claudeos"
  mkdir -p "$CLAUDEOS_HOME"

  FIXTURE="$BATS_TEST_TMPDIR/fixture"
  mkdir -p "$FIXTURE/sub"
  printf 'alpha\n' > "$FIXTURE/a.txt"
  printf 'beta\n' > "$FIXTURE/sub/b.txt"
  printf '#!/usr/bin/env bash\necho hi\n' > "$FIXTURE/run.sh"
  chmod +x "$FIXTURE/run.sh"

  git -C "$FIXTURE" -c init.defaultBranch=main init -q
  git -C "$FIXTURE" config user.email "bats@example.com"
  git -C "$FIXTURE" config user.name "bats"
  git -C "$FIXTURE" config commit.gpgsign false
  git -C "$FIXTURE" add -A
  git -C "$FIXTURE" -c commit.gpgsign=false commit -q -m "fixture: initial"

  export CCSU_ROOT="$FIXTURE"
  SHA="$(git -C "$FIXTURE" rev-parse HEAD)"
  # built_at を固定して manifest を決定化する
  export RELART_BUILT_AT="2026-01-02T03:04:05Z"
}

teardown() { _bats_common_teardown; }

# 直近 run の最終行 (--json はログを stderr に出し、JSON を最終行に固定する)
_last_line() {
  printf '%s\n' "$output" | tail -n1
}

# =========================================================
# 既定出力先
# =========================================================
@test "既定出力先: \$CLAUDEOS_HOME/releases/<40hex>/ と manifest.json を作る" {
  [[ "$SHA" =~ ^[0-9a-f]{40}$ ]]

  run bash "$RB"
  [ "$status" -eq 0 ]

  local dir="$CLAUDEOS_HOME/releases/$SHA"
  [ -d "$dir" ]
  [ -f "$dir/manifest.json" ]
  [ -f "$dir/a.txt" ]
  [ -f "$dir/sub/b.txt" ]
  [ -x "$dir/run.sh" ]
}

# =========================================================
# --out
# =========================================================
@test "--out: 指定ディレクトリへ展開し既定先は作らない" {
  local out="$BATS_TEST_TMPDIR/custom-out"

  run bash "$RB" --out "$out"
  [ "$status" -eq 0 ]
  [ -f "$out/manifest.json" ]
  [ -f "$out/a.txt" ]
  [ ! -e "$CLAUDEOS_HOME/releases" ]
}

# =========================================================
# --json
# =========================================================
@test "--json: stdout の最終行に ok/commit/dir/tree_sha256/file_count を出す" {
  run bash "$RB" --json
  [ "$status" -eq 0 ]

  local line; line="$(_last_line)"
  [ "$(printf '%s\n' "$line" | jq -r .ok)" = "true" ]
  [ "$(printf '%s\n' "$line" | jq -r .commit)" = "$SHA" ]
  [ "$(printf '%s\n' "$line" | jq -r .dir)" = "$CLAUDEOS_HOME/releases/$SHA" ]
  [ "$(printf '%s\n' "$line" | jq -r .file_count)" -eq 3 ]
  [[ "$(printf '%s\n' "$line" | jq -r .tree_sha256)" =~ ^[0-9a-f]{64}$ ]]
  # 契約キーが揃っている
  [ "$(printf '%s\n' "$line" | jq -r 'has("ok") and has("commit") and has("dir") and has("tree_sha256") and has("file_count")')" = "true" ]
}

@test "--json: stdout は JSON 1 行だけ (人間向けログは stderr)" {
  run bash -c 'build="$1"; shift; bash "$build" --json 2>/dev/null' _ "$RB"
  [ "$status" -eq 0 ]
  # stdout に流れた行数は 1 (JSON のみ)
  [ "$(printf '%s\n' "$output" | grep -c .)" -eq 1 ]
  [ "$(printf '%s\n' "$output" | jq -r .ok)" = "true" ]
}

# =========================================================
# --dry-run
# =========================================================
@test "--dry-run: 一切書き込まず計画のみ (json は dry_run/tree_sha256 空)" {
  run bash "$RB" --dry-run
  [ "$status" -eq 0 ]
  [ ! -e "$CLAUDEOS_HOME/releases" ]

  run bash "$RB" --dry-run --json
  [ "$status" -eq 0 ]
  [ ! -e "$CLAUDEOS_HOME/releases" ]

  local line; line="$(_last_line)"
  [ "$(printf '%s\n' "$line" | jq -r .ok)" = "true" ]
  [ "$(printf '%s\n' "$line" | jq -r .dry_run)" = "true" ]
  [ "$(printf '%s\n' "$line" | jq -r .tree_sha256)" = "" ]
  [ "$(printf '%s\n' "$line" | jq -r .file_count)" -eq 3 ]
}

# =========================================================
# 既存ディレクトリ
# =========================================================
@test "既存の非空ディレクトリは --force 無しで拒否し中身を壊さない" {
  local out="$BATS_TEST_TMPDIR/existing"
  mkdir -p "$out"
  printf 'keep\n' > "$out/keep.txt"

  run bash "$RB" --out "$out"
  [ "$status" -eq 1 ]
  [ -f "$out/keep.txt" ]
  [ ! -e "$out/manifest.json" ]
  [ ! -e "$out/a.txt" ]

  run bash "$RB" --out "$out" --json
  [ "$status" -eq 1 ]
  local line; line="$(_last_line)"
  [ "$(printf '%s\n' "$line" | jq -r .ok)" = "false" ]
  [ "$(printf '%s\n' "$line" | jq -r .error)" = "OUTPUT_EXISTS" ]
}

@test "既定先でも 2 回目は OUTPUT_EXISTS で失敗し 1 回目の成果物は残る" {
  run bash "$RB"
  [ "$status" -eq 0 ]

  local tree1; tree1="$(jq -r .tree_sha256 "$CLAUDEOS_HOME/releases/$SHA/manifest.json")"

  run bash "$RB"
  [ "$status" -eq 1 ]
  [ "$(jq -r .tree_sha256 "$CLAUDEOS_HOME/releases/$SHA/manifest.json")" = "$tree1" ]
}

@test "--force: 既存出力先を置換する" {
  local out="$BATS_TEST_TMPDIR/existing"
  mkdir -p "$out"
  printf 'stale\n' > "$out/stale.txt"

  run bash "$RB" --out "$out" --force
  [ "$status" -eq 0 ]
  [ ! -e "$out/stale.txt" ]
  [ -f "$out/manifest.json" ]
  [ -f "$out/a.txt" ]
  # 退避ディレクトリが残っていない (原子置換の後始末)
  [ -z "$(find "$BATS_TEST_TMPDIR" -maxdepth 1 -name '.release-backup.*' -print -quit)" ]
}

# =========================================================
# エラー契約
# =========================================================
@test "不正 ref: exit 1 と INVALID_REF (--json は ok:false)" {
  run bash "$RB" --ref "no-such-ref" --json
  [ "$status" -eq 1 ]
  local line; line="$(_last_line)"
  [ "$(printf '%s\n' "$line" | jq -r .ok)" = "false" ]
  [ "$(printf '%s\n' "$line" | jq -r .error)" = "INVALID_REF" ]
  [ ! -e "$CLAUDEOS_HOME/releases" ]
}

@test "不明なオプション: exit 2 と INVALID_ARG" {
  run bash "$RB" --bogus
  [ "$status" -eq 2 ]

  run bash "$RB" --bogus --json
  [ "$status" -eq 2 ]
  local line; line="$(_last_line)"
  [ "$(printf '%s\n' "$line" | jq -r .ok)" = "false" ]
  [ "$(printf '%s\n' "$line" | jq -r .error)" = "INVALID_ARG" ]
}

@test "値の欠落 (--ref 単体): exit 2" {
  run bash "$RB" --ref
  [ "$status" -eq 2 ]
}

# =========================================================
# manifest の内容
# =========================================================
@test "manifest: schema/commit/ref/built_at と files の sha256・size・昇順が一致する" {
  run bash "$RB"
  [ "$status" -eq 0 ]

  local dir="$CLAUDEOS_HOME/releases/$SHA" m="$CLAUDEOS_HOME/releases/$SHA/manifest.json"
  [ "$(jq -r .schema_version "$m")" -eq 1 ]
  [ "$(jq -r .commit "$m")" = "$SHA" ]
  [ "$(jq -r .short_commit "$m")" = "${SHA:0:7}" ]
  [ "$(jq -r .ref "$m")" = "HEAD" ]
  [ "$(jq -r .built_at "$m")" = "2026-01-02T03:04:05Z" ]
  [ "$(jq -r .file_count "$m")" -eq 3 ]

  # path 昇順 (LC_ALL=C) かつ全ファイルを網羅
  [ "$(jq -r '.files[].path' "$m")" = "$(printf '%s\n' a.txt run.sh sub/b.txt)" ]

  # 実ファイルの sha256 / size と一致
  local p h
  for p in a.txt run.sh sub/b.txt; do
    h="$(sha256sum "$dir/$p" | awk '{print $1}')"
    [ "$(jq -r --arg p "$p" '.files[] | select(.path==$p) | .sha256' "$m")" = "$h" ]
    [ "$(jq -r --arg p "$p" '.files[] | select(.path==$p) | .size' "$m")" -eq "$(stat -c %s "$dir/$p")" ]
  done

  # tree_sha256 = 契約式 (`<path>\0<sha256>\n` のソート済み連結の sha256) を独立計算
  local tree_calc
  tree_calc="$(jq -r '.files[] | "\(.path)\t\(.sha256)"' "$m" \
    | while IFS=$'\t' read -r p h; do printf '%s\0%s\n' "$p" "$h"; done \
    | sha256sum | awk '{print $1}')"
  [ "$tree_calc" = "$(jq -r .tree_sha256 "$m")" ]
}

@test "manifest: files は展開結果と過不足なく一致する (manifest.json 自身は含めない)" {
  run bash "$RB"
  [ "$status" -eq 0 ]

  local dir="$CLAUDEOS_HOME/releases/$SHA"
  local on_disk manifest_paths
  on_disk="$(cd "$dir" && find . -type f ! -name manifest.json | sed 's|^\./||' | LC_ALL=C sort)"
  manifest_paths="$(jq -r '.files[].path' "$dir/manifest.json" | LC_ALL=C sort)"
  [ "$on_disk" = "$manifest_paths" ]
}

# =========================================================
# tracked files のみ
# =========================================================
@test "tracked files のみ: .git / untracked / dirty 変更を含まない" {
  # コミット後に作業ツリーを汚す (これらは成果物に入ってはいけない)
  printf 'dirty\n' >> "$FIXTURE/a.txt"
  printf 'untracked\n' > "$FIXTURE/untracked.txt"
  mkdir -p "$FIXTURE/empty-dir"

  run bash "$RB"
  [ "$status" -eq 0 ]

  local dir="$CLAUDEOS_HOME/releases/$SHA"
  [ ! -e "$dir/.git" ]
  [ ! -e "$dir/untracked.txt" ]
  [ ! -e "$dir/empty-dir" ]
  # 内容は commit 時点 (dirty 変更を含まない)
  [ "$(cat "$dir/a.txt")" = "alpha" ]
  [ "$(jq -r .file_count "$dir/manifest.json")" -eq 3 ]
}

@test "--ref: 指定 ref を解決し manifest の commit/ref に記録する" {
  run bash "$RB" --ref "$SHA"
  [ "$status" -eq 0 ]

  local m="$CLAUDEOS_HOME/releases/$SHA/manifest.json"
  [ "$(jq -r .commit "$m")" = "$SHA" ]
  [ "$(jq -r .ref "$m")" = "$SHA" ]
}

# =========================================================
# 大規模ツリー (argv 長上限の回帰)
# =========================================================
@test "大規模ツリー (2000+ files): manifest 生成が argv 128KB 上限で失敗しない" {
  # 旧実装はファイル一覧 JSON (~150KB) を `jq --argjson` の argv に渡し、
  # Linux の 1 引数 128KB (MAX_ARG_STRLEN) 上限で E2BIG → MANIFEST_ERROR になった。
  # 一覧が 128KB を超える規模を fixture で再現し、argv 非経由であることを固定する。
  local i
  for i in $(seq 1 2000); do
    printf 'x\n' > "$FIXTURE/file-$(printf '%04d' "$i").txt"
  done
  git -C "$FIXTURE" add -A
  git -C "$FIXTURE" -c commit.gpgsign=false commit -q -m "fixture: large tree"
  local big_sha; big_sha="$(git -C "$FIXTURE" rev-parse HEAD)"

  run bash "$RB" --json
  [ "$status" -eq 0 ]

  local line; line="$(_last_line)"
  [ "$(printf '%s\n' "$line" | jq -r .ok)" = "true" ]
  [ "$(printf '%s\n' "$line" | jq -r .commit)" = "$big_sha" ]
  [ "$(printf '%s\n' "$line" | jq -r .file_count)" -eq 2003 ]

  local m="$CLAUDEOS_HOME/releases/$big_sha/manifest.json"
  [ -f "$m" ]
  [ "$(jq -r .file_count "$m")" -eq 2003 ]
  [ "$(jq -r '.files | length' "$m")" -eq 2003 ]
  # 一覧 JSON 換算で 128KB を超えている (旧実装が E2BIG で落ちた条件) ことを確認
  [ "$(stat -c %s "$m")" -gt 131072 ]

  # tree_sha256 が独立再計算と一致
  local tree_calc
  tree_calc="$(jq -r '.files[] | "\(.path)\t\(.sha256)"' "$m" \
    | while IFS=$'\t' read -r p h; do printf '%s\0%s\n' "$p" "$h"; done \
    | sha256sum | awk '{print $1}')"
  [ "$tree_calc" = "$(jq -r .tree_sha256 "$m")" ]

  # 展開結果の実ファイル数とも一致 (manifest だけ作られていないこと)
  [ "$(find "$CLAUDEOS_HOME/releases/$big_sha" -type f ! -name manifest.json | wc -l)" -eq 2003 ]
}
