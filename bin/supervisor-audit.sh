#!/usr/bin/env bash
# ============================================================
# supervisor-audit.sh — Supervisor ロールアウト監査 CLI (Linux native)
#
# 全登録プロジェクトの ClaudeOS 管理 manifest 配布状況を監査し、
# 書き込み前に差分をプレビューできる (非破壊優先)。
#
# 使い方:
#   supervisor-audit.sh report                    # 全プロジェクトを分類し表 + 集計表示
#   supervisor-audit.sh diff <project>            # 1 プロジェクトの差分プレビュー
#   supervisor-audit.sh apply <project> [--preview]   # manifest 適用 (--preview で試算のみ)
#   supervisor-audit.sh apply --all [--preview] [--yes]  # 全プロジェクトへ適用
#
# 安全: Foreign (他ツール管理) manifest は既定で保護。CCSU_SUPMAN_FORCE=1 で上書き可。
#       --all の実書き込みは対話確認 (非対話では --yes 必須)。
# ============================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
# shellcheck source=lib/config-loader.sh
source "$SCRIPT_DIR/../lib/config-loader.sh"
# shellcheck source=lib/supervisor-manifest.sh
source "$SCRIPT_DIR/../lib/supervisor-manifest.sh"

# sa__diff <project> — 1 プロジェクトの差分を整形表示
sa__diff() {
  local project="$1" dir
  [[ -n "$project" ]] || { log_error "diff: <project> は必須"; return 1; }
  dir="$(config_projects_dir)/$project"
  [[ -d "$dir" ]] || { log_error "プロジェクトが存在しません: $dir"; return 1; }
  local status diff_out action body
  status="$(supman__classify "$dir")"
  # diff を一度だけ捕捉し bash 文字列操作で分解 (head/tail パイプの SIGPIPE を回避)
  diff_out="$(supman__diff "$dir")"
  action="${diff_out%%$'\n'*}"; action="${action#action=}"
  printf '  %s🔍 %s%s  status=%s  action=%s\n' "$C_CYAN" "$project" "$C_RESET" "$status" "$action"
  body="${diff_out#*$'\n'}"
  [[ "$body" != "$diff_out" ]] && printf '%s\n' "$body" | while IFS='|' read -r prop cur des typ; do
    [[ -z "$prop" ]] && continue
    printf '     %s%-22s%s %s → %s (%s)\n' "$C_YELLOW" "$prop" "$C_RESET" "$cur" "$des" "$typ"
  done
  return 0
}

# sa__apply_one <project> [--preview]
sa__apply_one() {
  local project="$1" flag="${2:-}" dir
  [[ -n "$project" ]] || { log_error "apply: <project> は必須"; return 1; }
  dir="$(config_projects_dir)/$project"
  [[ -d "$dir" ]] || { log_error "プロジェクトが存在しません: $dir"; return 1; }
  supman__apply "$dir" "$flag"
}

# sa__apply_all [--preview] [--yes]
sa__apply_all() {
  local preview=0 yes=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --preview) preview=1; shift ;;
      --yes|-y)  yes=1; shift ;;
      *)         log_error "apply --all: 不明な引数: $1"; return 1 ;;
    esac
  done

  local -a projects=()
  local p
  while IFS= read -r p; do [[ -n "$p" ]] && projects+=("$p"); done < <(config_project_list)
  (( ${#projects[@]} > 0 )) || { log_warn "登録プロジェクトがありません"; return 0; }

  if (( preview )); then
    log_info "🔎 全 ${#projects[@]} 件の適用プレビュー"
    for p in "${projects[@]}"; do supman__apply "$(config_projects_dir)/$p" --preview; done
    return 0
  fi

  if (( yes == 0 )); then
    if [[ -t 0 ]]; then
      local ans
      read -rp "  ${#projects[@]} 件へ manifest を適用しますか? (Y/N): " ans || true
      [[ "${ans^^}" == "Y" ]] || { log_info "適用をキャンセルしました"; return 0; }
    else
      log_warn "非対話では --yes が必要です"
      return 1
    fi
  fi

  local ok=0
  for p in "${projects[@]}"; do
    supman__apply "$(config_projects_dir)/$p" && ok=$((ok + 1)) || true
  done
  log_ok "🎉 適用完了: $ok / ${#projects[@]} 件"
}

main() {
  require_cmd jq
  case "${1:-}" in
    report|list) supman__report ;;
    diff)  shift; sa__diff "${1:-}" ;;
    apply)
      shift
      if [[ "${1:-}" == "--all" ]]; then shift; sa__apply_all "$@"
      else sa__apply_one "${1:-}" "${2:-}"; fi
      ;;
    ""|--help|-h)
      printf 'Usage: supervisor-audit.sh report|diff|apply\n'
      printf '  report                        全プロジェクトを分類し表 + 集計表示\n'
      printf '  diff <project>                1 プロジェクトの差分プレビュー\n'
      printf '  apply <project> [--preview]   manifest 適用 (--preview で試算のみ)\n'
      printf '  apply --all [--preview] [--yes]  全プロジェクトへ適用\n'
      printf '\n  分類: 🟢Managed 🟡Missing 🟣Foreign 🔴Invalid\n'
      printf '  Foreign 保護解除: CCSU_SUPMAN_FORCE=1\n'
      ;;
    *) log_error "不明なサブコマンド: $1 (report|diff|apply)"; return 1 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
