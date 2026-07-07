#!/usr/bin/env bash
# ============================================================
# deploy-prep.sh — デプロイ準備 (メニュー項DP)
# 移植元: scripts/main/Start-DeployPrep.ps1
#   state.deploy.ready=true / runbook_generated=true / environment 設定
#   実デプロイは人間が手動 (CTO は自動実行しない)
#
#   --project <name> 指定時: 対象プロジェクト配下の state.json を操作する
#     (未指定時は従来通りこのツール自身の state.json を操作 — 後方互換)
# ============================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
# shellcheck source=lib/json.sh
source "$SCRIPT_DIR/../lib/json.sh"
# shellcheck source=lib/launcher-common.sh
source "$SCRIPT_DIR/../lib/launcher-common.sh"

main() {
  local env="staging"
  local dry_run=0
  local project=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --env) env="$2"; shift 2 ;;
      --dry-run) dry_run=1; shift ;;
      --project) project="$2"; shift 2 ;;
      *) log_error "不明な引数: $1"; exit 1 ;;
    esac
  done
  [[ "$env" == "staging" || "$env" == "production" ]] || { log_error "env は staging|production"; exit 1; }

  local state project_dir
  if [[ -n "$project" ]]; then
    launcher__project_exists "$project" || { log_error "プロジェクトが見つかりません: $project"; exit 1; }
    project_dir="$(launcher__project_dir "$project")"
    state="$project_dir/state.json"
    log_info "デプロイ準備 (project=$project, environment=$env)"
  else
    state="${CCSU_STATE_FILE:-$CCSU_ROOT/state.json}"
    log_info "デプロイ準備 (environment=$env)"
  fi

  if (( dry_run )); then
    log_info "dry-run: state.deploy.ready=true / runbook_generated=true / environment=$env を設定予定"
    log_info "dry-run: 書き込みは行いません: $state"
    return 0
  fi
  json_set "$state" '.deploy.ready = true | .deploy.runbook_generated = true | .deploy.environment = $env' --arg env "$env"
  log_ok "state.deploy.ready=true / environment=$env ($state)"
  log_info "Runbook を確認のうえ、デプロイは人間が手動実行してください (CTO は自動実行しません)"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
