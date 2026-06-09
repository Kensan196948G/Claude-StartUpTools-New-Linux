#!/usr/bin/env bash
# ============================================================
# template-sync.sh — ClaudeOS テンプレート配布ライブラリ
#
# プロジェクト起動前に最新テンプレートを各プロジェクトへ配布する。
# 配布対象:
#   START_PROMPT.md : 毎回上書き (セッション開始プロンプト)
#   CLAUDE.md       : 差分ありのみバックアップ→上書き (プロジェクト固有設定)
#
# テスト用 env 上書き:
#   CCSU_TEMPLATE_SYNC_DATE : バックアップファイル名の日付部分 (既定: date +%Y%m%d-%H%M%S)
# ============================================================

[[ -n "${_CCSU_TEMPLATE_SYNC_LOADED:-}" ]] && return 0
_CCSU_TEMPLATE_SYNC_LOADED=1

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# _tmpsync__tmpl_dir — テンプレートディレクトリのパスを返す
_tmpsync__tmpl_dir() {
  printf '%s/Claude/templates/claude' "$CCSU_ROOT"
}

# _tmpsync__date_stamp — バックアップ用日付スタンプ
_tmpsync__date_stamp() {
  printf '%s' "${CCSU_TEMPLATE_SYNC_DATE:-$(date +%Y%m%d-%H%M%S)}"
}

# template_sync__apply <project_dir> — START_PROMPT.md と CLAUDE.md を配布
template_sync__apply() {
  local project_dir="$1"
  local tmpl_dir; tmpl_dir="$(_tmpsync__tmpl_dir)"

  mkdir -p "$project_dir/.claude"

  # START_PROMPT.md: 常に上書き
  local src_sp="$tmpl_dir/START_PROMPT.md"
  if [[ -f "$src_sp" ]]; then
    cp "$src_sp" "$project_dir/.claude/START_PROMPT.md"
    log_info "📄 START_PROMPT.md 配布済み: $project_dir/.claude/"
  fi

  # CLAUDE.md: 存在しない場合のみ配布（プロジェクト固有設定を保護）
  local src_cm="$tmpl_dir/CLAUDE.md"
  if [[ -f "$src_cm" ]]; then
    local tmpl_size; tmpl_size=$(stat -c%s "$src_cm" 2>/dev/null || echo 0)
    if [[ "$tmpl_size" -lt 100 ]]; then
      log_warn "⚠️ CLAUDE.md テンプレートが小さすぎます(${tmpl_size} bytes) — 配布スキップ"
      return 0
    fi
    local dst_cm="$project_dir/.claude/CLAUDE.md"
    if [[ ! -f "$dst_cm" ]]; then
      cp "$src_cm" "$dst_cm"
      log_info "📄 CLAUDE.md 初回配布: $dst_cm"
    fi
  fi
}
