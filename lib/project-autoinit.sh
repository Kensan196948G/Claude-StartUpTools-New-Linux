#!/usr/bin/env bash
# ============================================================
# project-autoinit.sh — 新規フォルダの自動 Git 登録 (Linux native)
#
# 役割: config_projects_dir 直下に作成された「.git 未保有フォルダ」を検知し、
#       自動で git init + CLAUDE.md テンプレート配置 + 初期 commit を実行する。
#       .git が付くことで config_project_list が拾い、L1 メニュー / cron /
#       autonomy / docker の全 4 経路へ「登録プロジェクト」として自然に載る。
#
# 設計:
#   - 冪等: .git 保有フォルダは skip。再実行で副作用なし。
#   - 非破壊: 既存 CLAUDE.md は上書きしない (copy-if-missing)。
#   - ローカル限定: git init / commit のみ。GitHub repo 作成等の外部操作はしない
#     (外部サービス操作は人間最終決断のため、ここでは触れない)。
#   - 除外: リポジトリ自身 / config.localExcludes は config_project_excluded で skip。
#   - kill switch: config の .autoInitProjects=false で無効化。
#
# 前提: common.sh + config-loader.sh が source 済み。
# ============================================================

[[ -n "${_CCSU_PROJECT_AUTOINIT_LOADED:-}" ]] && return 0
_CCSU_PROJECT_AUTOINIT_LOADED=1

# project_autoinit_scan — 非 Git フォルダを自動初期化して登録対象へ昇格する。
#   set -e 環境でもループを止めないよう、各 git 操作は失敗許容で扱う。
project_autoinit_scan() {
  [[ "$(config_get '.autoInitProjects' 'true')" == 'true' ]] || return 0

  local base; base="$(config_projects_dir)"
  [[ -d "$base" ]] || return 0

  local template="$CCSU_ROOT/Claude/templates/claude/CLAUDE.md"
  local d name count=0

  for d in "$base"/*/; do
    [[ -d "$d" ]] || continue          # マッチ無し時の literal "*/" 対策
    [[ -d "${d}.git" ]] && continue    # 既に Git → skip (冪等)
    name="$(basename "$d")"
    config_project_excluded "$name" "$d" && continue   # リポジトリ自身 / localExcludes

    if ! git init -q "$d" 2>/dev/null; then
      log_warn "🆕 自動登録: git init 失敗のため skip → $name"
      continue
    fi

    if [[ -f "$template" && ! -f "${d}CLAUDE.md" ]]; then
      cp "$template" "${d}CLAUDE.md" 2>/dev/null || true
    fi

    if git -C "$d" add -A 2>/dev/null \
       && git -C "$d" commit -q -m "chore: ClaudeOS 登録初期化 (auto-init)" 2>/dev/null; then
      log_ok "🆕 自動登録: $name を初期化しました (git init + CLAUDE.md + 初期commit)"
    else
      # commit 失敗 (git identity 未設定など) でも .git は残るため登録自体は成立。
      log_warn "🆕 自動登録: $name を git init 済み (初期 commit は未完 — git identity を確認)"
    fi
    count=$((count + 1))
  done

  (( count > 0 )) && log_info "🆕 自動登録: $count 件の新規フォルダを登録プロジェクト化しました"
  return 0
}
