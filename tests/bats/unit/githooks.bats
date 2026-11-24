#!/usr/bin/env bats
# ============================================================
# githooks.bats — .githooks/pre-commit と install-githooks.sh のテスト
#
# 検証観点:
#   - 構文エラー / shellcheck error の .sh はコミットをブロックする
#   - 正常な .sh と、.sh を含まないコミットは通す
#   - watch と同じ形 (core.hooksPath=/dev/null) ではフックを通らない (公式仕様の確認)
#   - install-githooks.sh は冪等で、既存の別 hooksPath を上書きしない
#   - .claude/settings.json に Bash の PreToolUse フックが無い (/ship の watch を止めない)
# ============================================================

load '../helpers/common-setup'

setup() {
  _bats_common_setup
  R="$TEST_TEMP/repo"
  mkdir -p "$R/.githooks" "$R/scripts/setup"
  cp "$REPO_ROOT/.githooks/pre-commit" "$R/.githooks/pre-commit"
  cp "$REPO_ROOT/scripts/setup/install-githooks.sh" "$R/scripts/setup/"
  git -C "$R" init -q
  git -C "$R" config user.email t@t
  git -C "$R" config user.name t
  bash "$R/scripts/setup/install-githooks.sh" --repo "$R" >/dev/null
}
teardown() { _bats_common_teardown; }

commit() { git -C "$R" add -A && git -C "$R" commit -q -m "$1"; }

@test "pre-commit: 正常な .sh はコミットできる" {
  printf '#!/usr/bin/env bash\necho ok\n' > "$R/good.sh"
  run commit good
  [ "$status" -eq 0 ]
}

@test "pre-commit: 構文エラーの .sh はブロックする" {
  printf '#!/usr/bin/env bash\nif [ 1 ; then\n' > "$R/bad.sh"
  run commit bad
  [ "$status" -ne 0 ]
  [[ "$output" == *"bash -n failed"* ]]
}

@test "pre-commit: shellcheck の error はブロックする" {
  command -v shellcheck >/dev/null || skip "shellcheck が無い"
  printf '#!/usr/bin/env bash\necho $((1+))\n' > "$R/sc.sh"
  run commit sc
  [ "$status" -ne 0 ]
}

@test "pre-commit: .sh を含まないコミットは検査なしで通す" {
  echo hi > "$R/a.md"
  run commit md
  [ "$status" -eq 0 ]
}

@test "pre-commit: 削除だけのコミットは検査対象にしない" {
  printf '#!/usr/bin/env bash\necho ok\n' > "$R/x.sh"; commit add
  git -C "$R" rm -q x.sh
  run git -C "$R" commit -q -m del
  [ "$status" -eq 0 ]
}

@test "watch と同じ形 (core.hooksPath=/dev/null) ではフックを通らない" {
  printf '#!/usr/bin/env bash\nif [ 1 ; then\n' > "$R/bad.sh"
  git -C "$R" add -A
  run git -C "$R" -c core.hooksPath=/dev/null commit -q -m watch
  [ "$status" -eq 0 ]
}

@test "install-githooks: 冪等 / --check / 既存の別 hooksPath は上書きしない" {
  run bash "$R/scripts/setup/install-githooks.sh" --repo "$R"
  [ "$status" -eq 0 ]
  [[ "$output" == *"既に有効"* ]]
  run bash "$R/scripts/setup/install-githooks.sh" --repo "$R" --check
  [ "$status" -eq 0 ]
  git -C "$R" config core.hooksPath .husky
  run bash "$R/scripts/setup/install-githooks.sh" --repo "$R"
  [ "$status" -eq 2 ]
  [ "$(git -C "$R" config core.hooksPath)" = ".husky" ]
  run bash "$R/scripts/setup/install-githooks.sh" --repo "$R" --check
  [ "$status" -eq 1 ]
}

@test "settings.json: /ship の watch を止める Bash の PreToolUse / PermissionRequest フックが無い" {
  run jq -e '[(.hooks.PreToolUse // []), (.hooks.PermissionRequest // [])] | add
             | map(select((.matcher // "*") | test("^(\\*|\\.\\*|)$|(^|\\|)Bash(\\||$)"))) | length == 0' \
    "$REPO_ROOT/.claude/settings.json"
  [ "$status" -eq 0 ]
}

@test "リポジトリの追跡 .sh は全件フックの検査を通る (導入しても既存ファイルで誤検知しない)" {
  command -v shellcheck >/dev/null || skip "shellcheck が無い"
  mapfile -t all < <(git -C "$REPO_ROOT" ls-files '*.sh')
  for f in "${all[@]}"; do bash -n "$REPO_ROOT/$f"; done
  run bash -c 'cd "$1" && shift && shellcheck -S error "$@"' _ "$REPO_ROOT" "${all[@]}"
  [ "$status" -eq 0 ]
}
