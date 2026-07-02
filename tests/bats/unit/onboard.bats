#!/usr/bin/env bats
# ============================================================
# onboard.bats — lib/onboard.sh の合成サマリを検証。
# ============================================================

load '../helpers/common-setup'

setup() {
  _bats_common_setup
  export AI_STARTUP_CONFIG_PATH="$TEST_TEMP/config.json"
  export PROJ="$TEST_TEMP/projects"
  mkdir -p "$PROJ/Web"
  printf '{ "projects": "%s" }\n' "$PROJ" > "$AI_STARTUP_CONFIG_PATH"
  # 実 git リポジトリ + 検証スクリプト + docs
  git -C "$PROJ/Web" init -q
  git -C "$PROJ/Web" config user.email t@t
  git -C "$PROJ/Web" config user.name t
  printf '{ "scripts": { "test": "true", "lint": "true", "build": "true" } }\n' > "$PROJ/Web/package.json"
  echo "# Web" > "$PROJ/Web/README.md"
  printf 'node_modules/\n' > "$PROJ/Web/.gitignore"
  git -C "$PROJ/Web" add -A; git -C "$PROJ/Web" commit -qm init
  source "$REPO_ROOT/lib/onboard.sh"
}
teardown() { _bats_common_teardown; }

@test "onboard__summary: 未適用は manifest=Missing" {
  run onboard__summary "$PROJ/Web"
  [[ "$output" == *"manifest=Missing"* ]]
}

@test "onboard__summary: 推定した検証コマンドを含む" {
  run onboard__summary "$PROJ/Web"
  [[ "$output" == *"test=npm test"* ]]
  [[ "$output" == *"lint=npm run lint"* ]]
  [[ "$output" == *"build=npm run build"* ]]
}

@test "onboard__summary: docs/git 完備なら release=PASS" {
  run onboard__summary "$PROJ/Web"
  [[ "$output" == *"release=PASS"* ]]
}

@test "onboard__summary: 適用後は manifest=Managed" {
  supman__apply "$PROJ/Web" >/dev/null
  run onboard__summary "$PROJ/Web"
  [[ "$output" == *"manifest=Managed"* ]]
}

@test "onboard__summary: 検証コマンド未定義は none" {
  rm -f "$PROJ/Web/package.json"
  run onboard__summary "$PROJ/Web"
  [[ "$output" == *"test=none"* ]]
  [[ "$output" == *"lint=none"* ]]
  [[ "$output" == *"build=none"* ]]
}

@test "onboard__summary: README 欠落は release=FAIL" {
  rm -f "$PROJ/Web/README.md"
  run onboard__summary "$PROJ/Web"
  [[ "$output" == *"release=FAIL"* ]]
}