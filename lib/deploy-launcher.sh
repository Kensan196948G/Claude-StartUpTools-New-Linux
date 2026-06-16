#!/usr/bin/env bash
# ============================================================
# deploy-launcher.sh — cron-launcher 配備ライブラリ (恒久ドリフト対策)
#
# 目的: cron が実走するのはリポジトリ内テンプレートではなく、配備済みの
#   ~/.claudeos/cron-launcher.sh である。PR を merge しても再配備しない限り
#   runtime は古いまま (headless 既定化等が反映されない)。本ライブラリは
#   Claude/templates/linux/ の正本を $CCSU_HOME (~/.claudeos) へ
#   冪等・非破壊・ローカル限定で同期する。
#
# 配備対象 (templates/linux 内の 2 ファイルのみ):
#   cron-launcher.sh   : cron 実行エントリ (headless 分岐の本体)
#   report-and-mail.py : セッション後レポート/メール送出
#   ※ libexec/*.sh は launcher が live repo から読むため配備不要。
#
# 冪等性: diff 一致なら no-op。差分時のみ既存をタイムスタンプ backup → 上書き。
# 非破壊: 既存ファイルは .bak-<stamp> へ退避してから置換 (外部操作はしない)。
#
# テスト用 env 上書き:
#   CCSU_ROOT         : リポジトリルート (template の探索元)
#   CLAUDEOS_HOME     : 配備先 (= CCSU_HOME)。実 ~/.claudeos を汚さないため
#   CCSU_DEPLOY_DATE  : backup ファイル名の日付部分 (既定: date +%Y%m%d-%H%M%S)
# ============================================================

[[ -n "${_CCSU_DEPLOY_LAUNCHER_LOADED:-}" ]] && return 0
_CCSU_DEPLOY_LAUNCHER_LOADED=1

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# 配備対象ファイル (templates/linux 直下の相対名)
_CCSU_DEPLOY_TARGETS=(cron-launcher.sh report-and-mail.py)

# _deploy__tmpl_dir — テンプレートディレクトリのパスを返す
_deploy__tmpl_dir() {
  printf '%s/Claude/templates/linux' "$CCSU_ROOT"
}

# _deploy__date_stamp — backup 用日付スタンプ
_deploy__date_stamp() {
  printf '%s' "${CCSU_DEPLOY_DATE:-$(date +%Y%m%d-%H%M%S)}"
}

# deploy_launcher__pending — 配備が必要な (差分 or 未配備) ファイル数を stdout へ
#   純粋クエリ: 一切書き込まない。0 = 同期済み。
deploy_launcher__pending() {
  local tmpl_dir dest_dir f src dst n=0
  tmpl_dir="$(_deploy__tmpl_dir)"
  dest_dir="$CCSU_HOME"
  for f in "${_CCSU_DEPLOY_TARGETS[@]}"; do
    src="$tmpl_dir/$f"; dst="$dest_dir/$f"
    [[ -f "$src" ]] || continue
    if [[ ! -f "$dst" ]] || ! diff -q "$src" "$dst" >/dev/null 2>&1; then
      n=$((n+1))
    fi
  done
  printf '%s' "$n"
}

# deploy_launcher__apply [--dry-run] — テンプレートを $CCSU_HOME へ同期
#   差分時のみ backup→上書き。--dry-run は判定とログのみで書き込まない。
#   戻り値: 常に 0 (個々のファイル欠落は warn して継続)。
deploy_launcher__apply() {
  local dry_run=0
  [[ "${1:-}" == "--dry-run" ]] && dry_run=1

  local tmpl_dir dest_dir stamp f src dst changed=0
  tmpl_dir="$(_deploy__tmpl_dir)"
  dest_dir="$CCSU_HOME"
  stamp="$(_deploy__date_stamp)"

  for f in "${_CCSU_DEPLOY_TARGETS[@]}"; do
    src="$tmpl_dir/$f"; dst="$dest_dir/$f"
    if [[ ! -f "$src" ]]; then
      log_warn "⚠️ テンプレート不在のため skip: $src"
      continue
    fi
    # 既存と同一なら no-op (冪等性)
    if [[ -f "$dst" ]] && diff -q "$src" "$dst" >/dev/null 2>&1; then
      continue
    fi
    if (( dry_run )); then
      if [[ -f "$dst" ]]; then
        log_info "🔍 [dry-run] 差分あり → 配備対象: $f → $dst"
      else
        log_info "🔍 [dry-run] 未配備 → 配備対象: $f → $dst"
      fi
      changed=$((changed+1))
      continue
    fi
    mkdir -p "$dest_dir"
    if [[ -f "$dst" ]]; then
      cp "$dst" "${dst}.bak-$stamp"
      log_info "🗂️ バックアップ作成: ${dst}.bak-$stamp"
    fi
    cp "$src" "$dst"
    [[ "$f" == *.sh ]] && chmod +x "$dst"
    log_ok "🚀 配備完了: $f → $dst"
    changed=$((changed+1))
  done

  if (( changed == 0 )); then
    log_ok "✅ 配備済み (差分なし): $dest_dir"
  elif (( dry_run )); then
    log_info "🔍 [dry-run] $changed 件が配備対象です (実行は --dry-run 無しで)"
  else
    log_ok "🚀 $changed 件を配備しました: $dest_dir"
  fi
  return 0
}
