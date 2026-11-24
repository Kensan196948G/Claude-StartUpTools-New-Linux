#!/usr/bin/env bash
# ============================================================
# install-githooks.sh — リポジトリの .githooks を git に登録する
#
# 使い方: bash scripts/setup/install-githooks.sh [--check] [--repo DIR]
#   既定        : git config core.hooksPath .githooks を設定 (冪等)
#   --check     : 設定状態を表示するだけ (変更しない)。未設定なら exit 1
#
# 既に別の core.hooksPath が設定されている場合は上書きしない (exit 2)。
# ============================================================
set -euo pipefail

repo="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
check=0
while (( $# )); do
  case "$1" in
    --check) check=1; shift ;;
    --repo)  repo="${2:?--repo には値が必要です}"; shift 2 ;;
    -h|--help) sed -n '2,11p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "install-githooks: 不明な引数: $1" >&2; exit 2 ;;
  esac
done

[[ -x "$repo/.githooks/pre-commit" ]] || { echo "install-githooks: $repo/.githooks/pre-commit がありません" >&2; exit 2; }
current="$(git -C "$repo" config --get core.hooksPath || true)"

if (( check )); then
  if [[ "$current" == ".githooks" ]]; then echo "core.hooksPath=.githooks (有効)"; exit 0; fi
  echo "core.hooksPath=${current:-未設定} (無効)"; exit 1
fi

case "$current" in
  .githooks) echo "既に有効です (core.hooksPath=.githooks)"; exit 0 ;;
  "") git -C "$repo" config core.hooksPath .githooks; echo "有効化しました (core.hooksPath=.githooks)" ;;
  *) echo "install-githooks: 既に core.hooksPath=$current が設定されています。上書きしません" >&2; exit 2 ;;
esac
