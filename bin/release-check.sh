#!/usr/bin/env bash
# ============================================================
# release-check.sh — 統合プレリリースチェック CLI (Linux native)
#
# 1 プロジェクトの「リリース準備完了」を複合ゲートで判定し PASS/FAIL を返す。
#   git 清潔性 / README / .gitignore 衛生 / test / lint / build を束ねる。
#
# 使い方:
#   release-check.sh [project] [options]
#     project 省略時はこのリポジトリ自身を対象とする。
#   options:
#     --allow-dirty   未コミット変更を許容 (git worktree を PASS 扱い)
#     --skip-tests    test 実行を省略
#     --skip-lint     lint 実行を省略
#     --skip-build    build 実行を省略
#     --dry-run       test/lint/build を実行せず解決コマンドの表示のみ
#     --json          JSON でレポート出力
#
# exit: 全チェック合格で 0、NG が 1 件でもあれば 1。
# ============================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
# shellcheck source=lib/config-loader.sh
source "$SCRIPT_DIR/../lib/config-loader.sh"
# shellcheck source=lib/release-check.sh
source "$SCRIPT_DIR/../lib/release-check.sh"

# rc__resolve_dir <project> — project 名 → ディレクトリ (省略時は本リポジトリ)
rc__resolve_dir() {
  local project="$1"
  if [[ -z "$project" ]]; then printf '%s' "$CCSU_ROOT"; return 0; fi
  printf '%s/%s' "$(config_projects_dir)" "$project"
}

main() {
  require_cmd jq
  require_cmd git

  local project="" json=0 dry_run=0
  local -a passthru=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json)        json=1; shift ;;
      --dry-run)     dry_run=1; shift ;;
      --allow-dirty|--skip-tests|--skip-lint|--skip-build) passthru+=("$1"); shift ;;
      -h|--help)
        printf 'Usage: release-check.sh [project] [--allow-dirty] [--skip-tests|--skip-lint|--skip-build] [--dry-run] [--json]\n'
        return 0 ;;
      --*) log_error "不明な引数: $1"; return 1 ;;
      *)   project="$1"; shift ;;
    esac
  done

  local dir; dir="$(rc__resolve_dir "$project")"
  [[ -d "$dir" ]] || { log_error "プロジェクトが存在しません: $dir"; return 1; }
  local label; label="$(basename "$dir")"

  (( dry_run )) && export CCSU_RELCHK_DRYRUN=1

  local results
  results="$(relchk__collect "$dir" "${passthru[@]+"${passthru[@]}"}")"

  local total failed skipped
  total="$(grep -c . <<<"$results" || true)"
  failed="$(grep -c '|NG|' <<<"$results" || true)"
  skipped="$(grep -c '|SKIP|' <<<"$results" || true)"
  local passed="false"
  relchk__passed "$results" && passed="true"

  if (( json )); then
    # results (name|status|detail) を JSON 配列へ整形
    local checks_json
    checks_json="$(printf '%s\n' "$results" | jq -R -s '
      split("\n") | map(select(length>0)) | map(
        split("|") | { name: .[0], status: .[1], detail: (.[2] // "") }
      )')"
    jq -n \
      --arg project "$label" \
      --argjson passed "$passed" \
      --argjson total "$total" \
      --argjson failed "$failed" \
      --argjson skipped "$skipped" \
      --argjson checks "$checks_json" \
      '{ project: $project, passed: $passed, total: $total, failed: $failed, skipped: $skipped, checks: $checks }'
    [[ "$passed" == "true" ]] && return 0 || return 1
  fi

  # 人間向けレポート
  printf '\n  %s🚦 Release Readiness Check%s\n' "$C_CYAN" "$C_RESET"
  printf '  📦 Project : %s\n' "$label"
  if [[ "$passed" == "true" ]]; then
    printf '  %s✅ Result  : PASS%s  (%s checks / %s failed / %s skipped)\n' "$C_GREEN" "$C_RESET" "$total" "$failed" "$skipped"
    (( skipped > 0 )) && printf '  %s⚠️ 注意: %s 項目が SKIP (未検証)。PASS は実行された検査に限る%s\n' "$C_YELLOW" "$skipped" "$C_RESET"
    printf '\n'
  else
    printf '  %s❌ Result  : FAIL%s  (%s checks / %s failed / %s skipped)\n\n' "$C_RED" "$C_RESET" "$total" "$failed" "$skipped"
  fi

  local name status detail color mark
  while IFS='|' read -r name status detail; do
    [[ -z "$name" ]] && continue
    case "$status" in
      OK)   color="$C_GREEN";  mark="✅" ;;
      NG)   color="$C_RED";    mark="❌" ;;
      SKIP) color="$C_YELLOW"; mark="⏭️" ;;
      *)    color="$C_WHITE";  mark="•" ;;
    esac
    printf '  %s%s %-20s%s %s\n' "$color" "$mark" "$name" "$C_RESET" "$detail"
  done <<<"$results"
  printf '\n'

  [[ "$passed" == "true" ]] && return 0 || return 1
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
