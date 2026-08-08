#!/usr/bin/env bash
# ============================================================
# template-sync.sh — ClaudeOS テンプレート配布ライブラリ
#
# プロジェクト起動前に最新テンプレートを各プロジェクトへ配布する。
# あわせて settings.json の autocompact thrashing 残骸を毎起動時に自動修復する
# (sanitize-settings.js。L/S/cron/T 全経路が本関数を通るため、ここが恒久対策の要)。
# 配布対象:
#   START_PROMPT.md  : 毎回上書き (セッション開始プロンプト)
#   TEAM_START_PROMPT.md : 存在しない場合のみ配布 (チーム起動 T<n> の CTO 初期
#                      プロンプト。プロジェクト固有タスク記載を保護)
#   CLAUDE.md        : 存在しない場合のみ配布 (プロジェクト固有設定を保護)
#   selected commands : 存在しない場合のみ .claude/commands へ配布
#   selected skills   : 存在しない場合のみ .claude/skills/<name>/SKILL.md へ配布
#   .coderabbit.yaml : 差分ありのみバックアップ→上書き (リポジトリルートへ配布)
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

# template_sync__apply <project_dir> — START_PROMPT.md / CLAUDE.md / .coderabbit.yaml を配布
template_sync__apply() {
  local project_dir="$1"
  local tmpl_dir; tmpl_dir="$(_tmpsync__tmpl_dir)"

  mkdir -p "$project_dir/.claude"

  # settings.json sanitize: autocompact thrashing 残骸 (旧 env オーバーライド +
  # SessionStart matcher "*" のコンテキスト注入 hook) を毎起動時に自動修復する。
  # CLAUDE.md ガードの早期 return より前に置くこと (後段はスキップされ得る)。
  # スクリプトは CCSU_ROOT でなく lib 相対で解決する (テスト sandbox の影響を受けない)。
  local sanitize_js="$CCSU_LIB_DIR/../scripts/setup/sanitize-settings.js"
  if [[ -f "$sanitize_js" ]] && command -v node >/dev/null 2>&1; then
    node "$sanitize_js" "$project_dir/.claude/settings.json" \
      || log_warn "⚠️ settings.json sanitize 失敗 (起動は継続): $project_dir"
  fi

  # START_PROMPT.md: 常に上書き
  local src_sp="$tmpl_dir/START_PROMPT.md"
  if [[ -f "$src_sp" ]]; then
    cp "$src_sp" "$project_dir/.claude/START_PROMPT.md"
    log_info "📄 START_PROMPT.md 配布済み: $project_dir/.claude/"
  fi

  # TEAM_START_PROMPT.md: 存在しない場合のみ配布（チーム起動 T<n> の CTO ペイン用。
  # プロジェクト固有タスクを書き込む運用のため上書きしない。team-runner.sh 参照）
  local src_tp="$tmpl_dir/TEAM_START_PROMPT.md"
  if [[ -f "$src_tp" && ! -f "$project_dir/.claude/TEAM_START_PROMPT.md" ]]; then
    cp "$src_tp" "$project_dir/.claude/TEAM_START_PROMPT.md"
    log_info "📄 TEAM_START_PROMPT.md 初回配布: $project_dir/.claude/"
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

  # .coderabbit.yaml: 差分ありのみバックアップ→上書き (リポジトリルートへ配布)
  local src_cr="$tmpl_dir/.coderabbit.yaml"
  if [[ -f "$src_cr" ]]; then
    local dst_cr="$project_dir/.coderabbit.yaml"
    if [[ -f "$dst_cr" ]] && ! diff -q "$src_cr" "$dst_cr" >/dev/null 2>&1; then
      cp "$dst_cr" "${dst_cr}.bak-$(_tmpsync__date_stamp)"
      log_info "📄 .coderabbit.yaml バックアップ作成: ${dst_cr}.bak-$(_tmpsync__date_stamp)"
    fi
    if [[ ! -f "$dst_cr" ]] || ! diff -q "$src_cr" "$dst_cr" >/dev/null 2>&1; then
      cp "$src_cr" "$dst_cr"
      log_info "📄 .coderabbit.yaml 配布済み: $project_dir/"
    fi
  fi

  # ClaudeCode slash commands: 既存プロジェクトにも運用入口を補完する。
  # 既存同名コマンドはプロジェクト固有設定として保護し、上書きしない。
  local cmd src_cmd dst_cmd
  for cmd in safe-auto-merge design-sync-check; do
    src_cmd="$CCSU_ROOT/Claude/templates/claudeos/commands/${cmd}.md"
    [[ -f "$src_cmd" ]] || continue
    dst_cmd="$project_dir/.claude/commands/${cmd}.md"
    mkdir -p "$project_dir/.claude/commands"
    if [[ ! -f "$dst_cmd" ]]; then
      cp "$src_cmd" "$dst_cmd"
      log_info "📄 /${cmd} command 配布: $dst_cmd"
    fi
  done

  # ClaudeCode skills: 検証ループ skill を starter として配布する。
  # スキル自動発見の条件は <name>/SKILL.md 形式 (flat .md は認識されない)。
  # 既存同名 skill はプロジェクト側カスタマイズとして保護し、上書きしない。
  local skill src_skill dst_skill
  # shellcheck disable=SC2043  # 配布リストは今後増える前提の単一要素
  for skill in verify-app; do
    src_skill="$tmpl_dir/skills/${skill}/SKILL.md"
    [[ -f "$src_skill" ]] || continue
    dst_skill="$project_dir/.claude/skills/${skill}/SKILL.md"
    if [[ ! -f "$dst_skill" ]]; then
      mkdir -p "$project_dir/.claude/skills/${skill}"
      cp "$src_skill" "$dst_skill"
      log_info "📄 ${skill} skill 配布: $dst_skill"
    fi
  done
}
