#!/usr/bin/env bash
# ============================================================
# onboard-project.sh — ワンショット オンボーディング CLI (Linux native)
#
# 登録プロジェクトを 1 コマンドで ClaudeOS 管理準備状態へ整える束ねツール。
#   1) supervisor manifest 分類 + 差分プレビュー (--apply で適用)
#   2) test/lint/build 検証コマンドの自動解決結果を提示
#   3) リリース準備の dry-run スナップショット
#
# 使い方 (既定は非破壊のプレビュー):
#   onboard-project.sh <project> [--apply]      # 1 プロジェクトを点検 (--apply で manifest 書込)
#   onboard-project.sh --all [--apply] [--yes]  # 全登録プロジェクトを一括点検/適用
#
# 安全: 既定は読み取りのみ。--apply 指定時だけ manifest を書き込む。
#       cron 登録・supervisor 起動・PR 作成は行わない (各専用コマンドの領域)。
# ============================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
# shellcheck source=lib/config-loader.sh
source "$SCRIPT_DIR/../lib/config-loader.sh"
# shellcheck source=lib/onboard.sh
source "$SCRIPT_DIR/../lib/onboard.sh"

# ob__inspect <dir> [apply] — 1 プロジェクトを点検表示 (apply=1 で manifest 書込)
ob__inspect() {
  local dir="$1" apply="${2:-0}" name; name="$(basename "$dir")"
  printf '\n  %s🚀 Onboard: %s%s\n' "$C_CYAN" "$name" "$C_RESET"

  # 1) manifest 分類 + 差分プレビュー
  local status; status="$(supman__classify "$dir")"
  printf '  %s①%s manifest: %s\n' "$C_BLUE" "$C_RESET" "$status"
  supman__apply "$dir" --preview

  # 2) 検証コマンド解決
  local t l b
  t="$(config_verify_command test "$dir")"
  l="$(config_verify_command lint "$dir")"
  b="$(config_verify_command build "$dir")"
  printf '  %s②%s 検証コマンド: test=%s / lint=%s / build=%s\n' \
    "$C_BLUE" "$C_RESET" "${t:-（なし）}" "${l:-（なし）}" "${b:-（なし）}"

  # 3) リリース準備 dry-run スナップショット
  local results relok
  results="$(CCSU_RELCHK_DRYRUN=1 relchk__collect "$dir" --allow-dirty)"
  relok="PASS"; relchk__passed "$results" || relok="FAIL"
  if [[ "$relok" == "PASS" ]]; then
    printf '  %s③%s リリース準備 (dry-run): %s✅ %s%s\n' "$C_BLUE" "$C_RESET" "$C_GREEN" "$relok" "$C_RESET"
  else
    printf '  %s③%s リリース準備 (dry-run): %s❌ %s%s\n' "$C_BLUE" "$C_RESET" "$C_RED" "$relok" "$C_RESET"
    while IFS='|' read -r n s d; do
      if [[ "$s" == "NG" ]]; then printf '        %s• %s: %s%s\n' "$C_YELLOW" "$n" "$d" "$C_RESET"; fi
    done <<<"$results"
  fi

  # --apply: manifest を実書き込み
  if (( apply )); then
    supman__apply "$dir"
  else
    printf '  %sℹ️  プレビューのみ (書込は --apply)%s\n' "$C_WHITE" "$C_RESET"
  fi
}

ob__one() {
  local project="$1" apply="$2" dir
  [[ -n "$project" ]] || { log_error "<project> は必須"; return 1; }
  dir="$(config_projects_dir)/$project"
  [[ -d "$dir" ]] || { log_error "プロジェクトが存在しません: $dir"; return 1; }
  ob__inspect "$dir" "$apply"
}

ob__all() {
  local apply="$1" yes="$2"
  local -a projects=()
  local p
  while IFS= read -r p; do [[ -n "$p" ]] && projects+=("$p"); done < <(config_project_list)
  (( ${#projects[@]} > 0 )) || { log_warn "登録プロジェクトがありません"; return 0; }

  if (( apply && ! yes )); then
    if [[ -t 0 ]]; then
      local ans
      read -rp "  ${#projects[@]} 件へ manifest を適用しますか? (Y/N): " ans || true
      [[ "${ans^^}" == "Y" ]] || { log_info "適用をキャンセルしました (プレビューのみ実行)"; apply=0; }
    else
      log_warn "非対話 --apply には --yes が必要です (プレビューのみ実行)"; apply=0
    fi
  fi

  local base; base="$(config_projects_dir)"
  for p in "${projects[@]}"; do ob__inspect "$base/$p" "$apply"; done
  printf '\n  %s🎉 全 %d 件のオンボード点検完了%s\n' "$C_GREEN" "${#projects[@]}" "$C_RESET"
}

main() {
  require_cmd jq
  require_cmd git

  local all=0 apply=0 yes=0 project=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --all)   all=1; shift ;;
      --apply) apply=1; shift ;;
      --yes|-y) yes=1; shift ;;
      -h|--help)
        printf 'Usage: onboard-project.sh <project>|--all [--apply] [--yes]\n'
        printf '  <project>         1 プロジェクトを点検 (既定プレビュー)\n'
        printf '  --all             全登録プロジェクトを一括点検\n'
        printf '  --apply           supervisor manifest を実際に書き込む\n'
        printf '  --yes             --all --apply の確認を省略 (非対話)\n'
        return 0 ;;
      --*) log_error "不明な引数: $1"; return 1 ;;
      *)   project="$1"; shift ;;
    esac
  done

  if (( all )); then ob__all "$apply" "$yes"; else ob__one "$project" "$apply"; fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
