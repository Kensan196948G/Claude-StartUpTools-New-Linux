#!/usr/bin/env bash
# ============================================================
# release-build.sh — リリース成果物ビルド CLI
#
# commit 単位の不変スナップショット ($CLAUDEOS_HOME/releases/<40hex>/) と
# manifest.json を作る。中身は `git archive <sha>` の tracked files のみ
# (作業ツリーの未コミット変更・untracked・.git を含まない)。
# 実装は lib/release-artifact.sh。
#
# 使い方:
#   bin/release-build.sh [--ref REF] [--out DIR] [--json] [--dry-run] [--force]
#
# OPTIONS:
#   --ref REF   ビルド対象の ref (既定: HEAD)。commit へ解決して使う
#   --out DIR   出力先 (既定: $CLAUDEOS_HOME/releases/<40hex>)
#   --json      最後の行に 1 行 JSON を出す (人間向けログは stderr)
#   --dry-run   書き込まずに計画のみ表示
#   --force     既存の非空ディレクトリを置換する
#   -h, --help  このヘルプ
#
# ENV:
#   CLAUDEOS_HOME  releases/ の親 (既定 ~/.claudeos)
#
# 出力 (--json):
#   成功時: {"ok":true,"commit":"<40hex>","dir":"...","tree_sha256":"<64hex>","file_count":N}
#   失敗時: {"ok":false,"error":"<CODE>","message":"..."}
#   --dry-run 時は tree_sha256 を "" とし "dry_run":true を付ける (未計算のため)
#   error CODE: INVALID_ARG / MISSING_COMMAND / INVALID_REF / INVALID_OUT /
#               OUTPUT_EXISTS / OUTPUT_NOT_DIRECTORY / GIT_ARCHIVE /
#               HASH_ERROR / MANIFEST_ERROR / SWAP_ERROR / IO_ERROR
#
# exit: 0 成功 / 1 実行エラー (ref 解決失敗・出力先衝突・git/tar 失敗等)
#       2 引数エラー (不明なオプション・値の欠落)
# ============================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
# shellcheck source=lib/release-artifact.sh
source "$SCRIPT_DIR/../lib/release-artifact.sh"

_json=0

_usage() {
  printf '%s\n' \
    "release-build.sh — リリース成果物ビルド (tracked files + manifest.json)" \
    "" \
    "USAGE:" \
    "  bin/release-build.sh [--ref REF] [--out DIR] [--json] [--dry-run] [--force]" \
    "" \
    "OPTIONS:" \
    "  --ref REF   ビルド対象の ref (既定: HEAD)" \
    "  --out DIR   出力先 (既定: \$CLAUDEOS_HOME/releases/<40hex>)" \
    "  --json      最終行に 1 行 JSON を出す (ログは stderr)" \
    "  --dry-run   書き込まずに計画のみ表示" \
    "  --force     既存の非空ディレクトリを置換する" \
    "  -h, --help  このヘルプ" \
    "" \
    "EXIT: 0 成功 / 1 実行エラー / 2 引数エラー"
}

# _emit_error <exit-code> <CODE> <message>
#   引数エラーでも --json の契約 (ok:false) を守れるよう、単一の出口に集約する
_emit_error() {
  local rc="$1" code="$2" msg="$3"
  log_error "$msg"
  if (( _json )) && has_cmd jq; then
    jq -cn --arg code "$code" --arg message "$msg" \
      '{ ok: false, error: $code, message: $message }' >&3
  fi
  exit "$rc"
}

main() {
  local ref="HEAD" out="" dry=0 force=0 json_line=""
  local a

  # --json は引数エラー時にも効かせたいので、解析前に走査しておく
  for a in "$@"; do
    [[ "$a" == "--json" ]] && _json=1
  done
  # JSON を stdout の最終行に固定する: ログは stderr へ、JSON は fd3 へ
  if (( _json )); then
    exec 3>&1 1>&2
  fi

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ref)
        [[ $# -ge 2 && -n "$2" ]] || _emit_error 2 INVALID_ARG "--ref には値が必要です"
        ref="$2"; shift 2 ;;
      --ref=*)
        ref="${1#*=}"
        [[ -n "$ref" ]] || _emit_error 2 INVALID_ARG "--ref には値が必要です"
        shift ;;
      --out)
        [[ $# -ge 2 && -n "$2" ]] || _emit_error 2 INVALID_ARG "--out には値が必要です"
        out="$2"; shift 2 ;;
      --out=*)
        out="${1#*=}"
        [[ -n "$out" ]] || _emit_error 2 INVALID_ARG "--out には値が必要です"
        shift ;;
      --json)    _json=1; shift ;;
      --dry-run) dry=1; shift ;;
      --force)   force=1; shift ;;
      -h|--help) _usage; exit 0 ;;
      --*)       _emit_error 2 INVALID_ARG "不明なオプション: $1" ;;
      *)         _emit_error 2 INVALID_ARG "不明な引数: $1" ;;
    esac
  done

  for a in git jq tar sha256sum; do
    has_cmd "$a" || _emit_error 1 MISSING_COMMAND "必須コマンドが見つかりません: $a"
  done

  if ! relart__build "$ref" "$out" "$force" "$dry"; then
    if [[ -n "${RELART_ERR_CODE:-}" ]]; then
      _emit_error 1 "$RELART_ERR_CODE" "${RELART_ERR_MESSAGE:-release ビルドに失敗しました}"
    fi
    die "release ビルドに失敗しました"
  fi

  if (( _json )); then
    if (( dry )); then
      json_line="$(jq -cn \
        --arg commit "$RELART_LAST_COMMIT" \
        --arg dir "$RELART_LAST_DIR" \
        --argjson file_count "$RELART_LAST_FILE_COUNT" \
        '{ ok: true, dry_run: true, commit: $commit, dir: $dir,
           tree_sha256: "", file_count: $file_count }')"
    else
      json_line="$(jq -cn \
        --arg commit "$RELART_LAST_COMMIT" \
        --arg dir "$RELART_LAST_DIR" \
        --arg tree_sha256 "$RELART_LAST_TREE_SHA256" \
        --argjson file_count "$RELART_LAST_FILE_COUNT" \
        '{ ok: true, commit: $commit, dir: $dir,
           tree_sha256: $tree_sha256, file_count: $file_count }')"
    fi
    printf '%s\n' "$json_line" >&3
  fi
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
