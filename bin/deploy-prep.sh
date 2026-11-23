#!/usr/bin/env bash
# ============================================================
# deploy-prep.sh — デプロイ準備 (メニュー項DP)
# 移植元: scripts/main/Start-DeployPrep.ps1
#
# 役割:
#   1. state.deploy.ready=true / environment を書く
#   2. deploy-runbook を **実際に生成** する (scripts/release/generate-deploy-runbook.js)
#   3. 生成結果 (実ファイルの存在) に基づいて runbook_generated / runbook_path を書く
#   --checklist-done 指定時は pre_deploy_checklist_done=true（人間の完了表明）も書く
#
#   実デプロイは人間が手動 (CTO は自動実行しない)。
#
#   --project <name> 指定時: 対象プロジェクト配下の state.json / reports/ を操作する
#     (未指定時は従来通りこのツール自身の state.json を操作 — 後方互換)
#   生成は state.json のあるディレクトリを cwd にして実行するため、--project でも
#   プロジェクト側に runbook が生成される。
# ============================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
# shellcheck source=lib/json.sh
source "$SCRIPT_DIR/../lib/json.sh"
# shellcheck source=lib/launcher-common.sh
source "$SCRIPT_DIR/../lib/launcher-common.sh"

# runbook の置き場所 (state.json からの相対パス。generate-deploy-runbook.js の既定と同一)
DEPLOY_PREP_RUNBOOK_REL="reports/deploy-runbook.md"

usage() {
  cat <<'EOF'
Usage: deploy-prep.sh [--env staging|production] [--project NAME] [--checklist-done] [--dry-run]

  --env ENV          staging | production (既定 staging)
  --project NAME     対象プロジェクト配下の state.json を操作する
  --checklist-done   Pre-Deploy チェックリスト完了を state.deploy に記録する
  --dry-run          書き込みも生成もしない (計画のみ表示)
  -h, --help         このヘルプ

実行内容:
  1. state.deploy.ready=true / environment=ENV
  2. reports/deploy-runbook.md を生成 (実生成)
  3. 生成できた場合のみ runbook_generated=true / runbook_path を書く
     生成できなければ runbook_generated=false / runbook_path=null で exit 1
EOF
}

main() {
  local env="staging"
  local dry_run=0
  local project=""
  local checklist_done=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --env)
        [[ $# -ge 2 ]] || { log_error "--env には値が必要です"; exit 1; }
        env="$2"; shift 2 ;;
      --dry-run) dry_run=1; shift ;;
      --project)
        [[ $# -ge 2 ]] || { log_error "--project には値が必要です"; exit 1; }
        project="$2"; shift 2 ;;
      --checklist-done) checklist_done=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) log_error "不明な引数: $1"; exit 1 ;;
    esac
  done
  [[ "$env" == "staging" || "$env" == "production" ]] || { log_error "env は staging|production"; exit 1; }

  require_cmd jq
  require_cmd node

  local state state_dir runbook generator
  if [[ -n "$project" ]]; then
    launcher__project_exists "$project" || { log_error "プロジェクトが見つかりません: $project"; exit 1; }
    state="$(launcher__project_dir "$project")/state.json"
    log_info "デプロイ準備 (project=$project, environment=$env)"
  else
    state="${CCSU_STATE_FILE:-$CCSU_ROOT/state.json}"
    log_info "デプロイ準備 (environment=$env)"
  fi
  state_dir="$(dirname "$state")"
  runbook="$state_dir/$DEPLOY_PREP_RUNBOOK_REL"
  generator="$CCSU_ROOT/scripts/release/generate-deploy-runbook.js"

  if [[ ! -f "$generator" ]]; then
    log_error "runbook 生成スクリプトが見つかりません: $generator"
    exit 1
  fi

  if (( dry_run )); then
    log_info "dry-run: state.deploy.ready=true / environment=$env を設定予定 ($state)"
    if (( checklist_done )); then
      log_info "dry-run: state.deploy.pre_deploy_checklist_done=true を設定予定"
    fi
    log_info "dry-run: runbook を生成予定: $runbook"
    log_info "dry-run: 書き込みは行いません"
    return 0
  fi

  # 1) ready / environment (生成側は deploy.ready を前提にしているため先に書く)
  json_set "$state" '.deploy.ready = true | .deploy.environment = $env' --arg env "$env" \
    || { log_error "state を更新できません: $state"; exit 1; }

  # 2) チェックリスト完了の表明 (人間が --checklist-done を渡したときだけ)
  if (( checklist_done )); then
    json_set "$state" '.deploy.pre_deploy_checklist_done = true' \
      || log_warn "pre_deploy_checklist_done を更新できません: $state"
  fi

  # 3) runbook を実際に生成する (state.json のあるディレクトリを cwd にする)
  log_info "runbook を生成します: $runbook"
  local gen_out="" gen_rc=0
  gen_out="$( cd "$state_dir" && node "$generator" --env "$env" 2>&1 )" || gen_rc=$?
  if [[ -n "$gen_out" ]]; then
    printf '%s\n' "$gen_out" | sed 's/^/    /'
  fi

  # 4) 実生成の結果に基づいてフラグを書く (フラグだけ立てて実体が無い状態を作らない)
  if (( gen_rc == 0 )) && [[ -s "$runbook" ]]; then
    json_set "$state" '.deploy.runbook_generated = true | .deploy.runbook_path = $rel' \
      --arg rel "$DEPLOY_PREP_RUNBOOK_REL" \
      || log_warn "runbook フラグを更新できません: $state"
    log_ok "state.deploy.ready=true / environment=$env ($state)"
    log_ok "runbook 生成: $runbook (runbook_generated=true, runbook_path=$DEPLOY_PREP_RUNBOOK_REL)"
  else
    json_set "$state" '.deploy.runbook_generated = false | .deploy.runbook_path = null' \
      || log_warn "runbook フラグを戻せません: $state"
    log_error "runbook を生成できませんでした (runbook_generated=false のまま): $runbook"
    exit 1
  fi

  log_info "Runbook を確認のうえ、デプロイは人間が手動実行してください (CTO は自動実行しません)"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
