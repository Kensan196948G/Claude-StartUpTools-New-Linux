#!/usr/bin/env bash
# ============================================================
# launcher-common.sh — ランチャー共通関数 (Linux native)
#
# 移植元: scripts/lib/LauncherCommon.psm1 の「ローカル部分のみ」
#   廃止: Resolve-SshProjectsDir / Find-AvailableDriveLetter /
#         Get-SmbMapping / New-PSDrive / Invoke-LauncherSshScript /
#         Get-LauncherShell (pwsh 探索) — Linux ローカル実行では全て不要
#
# 提供: プロジェクト一覧/選択/パス解決 (ローカル ls ベース)
# ============================================================

[[ -n "${_CCSU_LAUNCHER_LOADED:-}" ]] && return 0
_CCSU_LAUNCHER_LOADED=1

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/config-loader.sh"

# launcher__project_list — プロジェクト列挙 (config_project_list: dir かつ Git リポジトリのみ)
launcher__project_list() { config_project_list; }

# launcher__project_dir <project> — プロジェクトの絶対パス
launcher__project_dir() { printf '%s/%s' "$(config_projects_dir)" "$1"; }

# launcher__project_exists <project> — ディレクトリが存在すれば 0
launcher__project_exists() { [[ -d "$(launcher__project_dir "$1")" ]]; }

# launcher__project_run_status <project> — supervisor 状態を返す
# stdout: ok | running | goal-reached | crash-loop | blocked
launcher__project_run_status() {
  local project="$1"
  local sup_dir="${CCSU_SUP_DIR:-${CCSU_HOME}/supervisor}"
  local safe; safe="$(ccsu_safe_name "$project")"
  local sup_json="$sup_dir/${safe}.json"

  if [[ ! -f "$sup_json" ]]; then printf 'ok'; return; fi

  local status pid
  status="$(json_get "$sup_json" '.status' 'stopped')"
  pid="$(json_get "$sup_json" '.pid' '0')"

  if [[ "$status" == "running" ]] && [[ "$pid" != "0" ]] && kill -0 "$pid" 2>/dev/null; then
    printf 'running'; return
  fi

  case "$status" in
    goal-reached) printf 'goal-reached'; return ;;
    crash-loop)   printf 'crash-loop';   return ;;
    blocked)
      local state_json halt
      state_json="$(config_projects_dir)/$project/state.json"
      halt="$(json_get "$state_json" '.supervisor.halt_on_blocked' 'true')"
      [[ "$halt" != "false" ]] && { printf 'blocked'; return; }
      ;;
  esac
  printf 'ok'
}

# launcher__select_project [mode] — 対話的にプロジェクトを選ぶ。結果を stdout、案内は stderr
#   mode: foreground (既定) | background | deploy
#   全プロジェクトを番号付きで表示する。running は選択後に menu 側で接続/停止へ分岐する。
launcher__select_project() {
  local mode="${1:-foreground}"
  local mode_label
  case "$mode" in
    background) mode_label="バックグラウンド" ;;
    deploy)     mode_label="デプロイ準備" ;;
    *)          mode_label="フォアグラウンド" ;;
  esac

  local -a projs; mapfile -t projs < <(launcher__project_list)
  if (( ${#projs[@]} == 0 )); then
    local name; read -rp "  プロジェクト名: " name; printf '%s' "$name"; return 0
  fi

  local -a selectable_idxs=()
  local display_num=0

  printf '\n  %s📋 プロジェクト一覧 [%s起動]%s\n' "$C_CYAN" "$mode_label" "$C_RESET" >&2
  printf '     %s番号付き = 選択可 / 0・q・exit・/exit = 戻る%s\n\n' "$C_WHITE" "$C_RESET" >&2

  local i proj run_status
  for i in "${!projs[@]}"; do
    proj="${projs[$i]}"
    run_status="$(launcher__project_run_status "$proj")"

    display_num=$(( display_num + 1 ))
    selectable_idxs+=("$i")
    case "$run_status" in
      running)
        printf '  %s[%2d]%s %s🔴 %-40s%s %s(実行中)%s\n' \
          "$C_RED" "$display_num" "$C_RESET" "$C_RED" "$proj" "$C_RESET" \
          "$C_WHITE" "$C_RESET" >&2 ;;
      goal-reached)
        printf '  %s[%2d]%s %s🟡 %-40s%s %s(目標達成済)%s\n' \
          "$C_YELLOW" "$display_num" "$C_RESET" "$C_YELLOW" "$proj" "$C_RESET" \
          "$C_DKGREEN" "$C_RESET" >&2 ;;
      crash-loop)
        printf '  %s[%2d]%s %s🟡 %-40s%s %s(クラッシュ)%s\n' \
          "$C_YELLOW" "$display_num" "$C_RESET" "$C_YELLOW" "$proj" "$C_RESET" \
          "$C_YELLOW" "$C_RESET" >&2 ;;
      blocked)
        printf '  %s[%2d]%s %s🟡 %-40s%s %s(ブロック中)%s\n' \
          "$C_YELLOW" "$display_num" "$C_RESET" "$C_YELLOW" "$proj" "$C_RESET" \
          "$C_RED" "$C_RESET" >&2 ;;
      *)
        printf '  %s[%2d]%s %s🟢 %s%s\n' \
          "$C_GREEN" "$display_num" "$C_RESET" "$C_GREEN" "$proj" "$C_RESET" >&2 ;;
    esac
  done

  printf '\n' >&2

  local idx
  read -rp "  番号 (1-${display_num}, 0=戻る): " idx
  case "${idx,,}" in
    0|q|quit|exit|/exit|"") return 0 ;;
  esac
  if [[ "$idx" =~ ^[0-9]+$ ]] && (( idx >= 1 && idx <= ${#selectable_idxs[@]} )); then
    printf '%s' "${projs[${selectable_idxs[$((idx - 1))]}]}"
  fi
  return 0
}
