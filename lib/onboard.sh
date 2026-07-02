#!/usr/bin/env bash
# ============================================================
# onboard.sh — プロジェクト オンボーディング合成ロジック (Linux native)
#
# 役割: 既に構築済みの部品を束ね、1 プロジェクトの「ClaudeOS 管理準備状況」を
#       一括で把握する。新規部品は作らず、既存 lib を合成する (束ねスクリプトの中核)。
#     - supervisor manifest 分類 (supervisor-manifest.sh / Task 供給)
#     - test/lint/build 検証コマンド解決 (config-loader.sh)
#     - リリース準備の dry-run スナップショット (release-check.sh)
#
# 移植元思想: Codex-StartUpTools/bin/auto_setup.sh のワンショット
#   (推定→設定→検証) を Codex 非依存で再構成。schedule/env 書き込みや
#   Codex 起動は持ち込まず、Claude/Bash の既存経路 (cron-schedule.sh /
#   autonomy.sh) へ委ねる。ここは「準備状況の可視化と manifest 適用」に限定。
# ============================================================

[[ -n "${_CCSU_ONBOARD_LOADED:-}" ]] && return 0
_CCSU_ONBOARD_LOADED=1

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/config-loader.sh"
source "$(dirname "${BASH_SOURCE[0]}")/supervisor-manifest.sh"
source "$(dirname "${BASH_SOURCE[0]}")/release-check.sh"

# onboard__summary <dir> — 1 行サマリを stdout
#   "manifest=<status> test=<cmd|none> lint=<cmd|none> build=<cmd|none> release=<PASS|FAIL>"
#   release は dry-run + --allow-dirty のスナップショット (test/lint/build は実行しない)。
onboard__summary() {
  local dir="$1"
  local manifest test lint build results relok
  manifest="$(supman__classify "$dir")"
  test="$(config_verify_command test "$dir")"
  lint="$(config_verify_command lint "$dir")"
  build="$(config_verify_command build "$dir")"
  results="$(CCSU_RELCHK_DRYRUN=1 relchk__collect "$dir" --allow-dirty)"
  relok="PASS"; relchk__passed "$results" || relok="FAIL"
  printf 'manifest=%s test=%s lint=%s build=%s release=%s\n' \
    "$manifest" "${test:-none}" "${lint:-none}" "${build:-none}" "$relok"
}
