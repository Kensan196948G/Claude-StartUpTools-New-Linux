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

# launcher__select_project [mode] [group] — 対話的にプロジェクトを選ぶ。結果を stdout、案内は stderr
#   mode:  foreground (既定) | background | deploy
#   group: projectGroups 内のグループ名。指定するとグループ選択を省略し、そのグループ
#          配下のサブプロジェクト選択から直接始める (メニュー L<n> のグループ直結起動用)。
#   config.projectGroups が設定されていれば「①グループ選択 → ②配下から選択」の 2 段階、
#   未設定なら全プロジェクトをフラットに番号付き表示する (従来動作。group 指定は無視)。
launcher__select_project() {
  local -a _groups=(); mapfile -t _groups < <(config_project_groups)
  if (( ${#_groups[@]} > 0 )); then launcher__select_grouped "${1:-foreground}" "${2:-}"; else launcher__select_flat "${1:-foreground}"; fi
}

# launcher__select_mode_label <mode> — 表示用ラベル
launcher__select_mode_label() {
  case "$1" in
    background) printf 'バックグラウンド' ;;
    deploy)     printf 'デプロイ準備' ;;
    *)          printf 'フォアグラウンド' ;;
  esac
}

# launcher__print_project_row <display_num> <label> <run_status> — 1 行を stderr へ (色/アイコン付き)
launcher__print_project_row() {
  local n="$1" label="$2" st="$3"
  case "$st" in
    running)      printf '  %s[%2d]%s %s🔴 %-40s%s %s(実行中)%s\n'     "$C_RED"    "$n" "$C_RESET" "$C_RED"    "$label" "$C_RESET" "$C_WHITE"   "$C_RESET" >&2 ;;
    goal-reached) printf '  %s[%2d]%s %s🟡 %-40s%s %s(目標達成済)%s\n' "$C_YELLOW" "$n" "$C_RESET" "$C_YELLOW" "$label" "$C_RESET" "$C_DKGREEN" "$C_RESET" >&2 ;;
    crash-loop)   printf '  %s[%2d]%s %s🟡 %-40s%s %s(クラッシュ)%s\n' "$C_YELLOW" "$n" "$C_RESET" "$C_YELLOW" "$label" "$C_RESET" "$C_YELLOW"  "$C_RESET" >&2 ;;
    blocked)      printf '  %s[%2d]%s %s🟡 %-40s%s %s(ブロック中)%s\n' "$C_YELLOW" "$n" "$C_RESET" "$C_YELLOW" "$label" "$C_RESET" "$C_RED"     "$C_RESET" >&2 ;;
    *)            printf '  %s[%2d]%s %s🟢 %s%s\n'                     "$C_GREEN"  "$n" "$C_RESET" "$C_GREEN"  "$label" "$C_RESET" >&2 ;;
  esac
}

# launcher__select_grouped [mode] [preset] — projectGroups 用の 2 段階選択 (グループ → 配下)
#   戻り値 (stdout): "グループ名/サブ名"。0/q/exit で 1 つ前 (配下→グループ, グループ→終了) へ戻る。
#   グループが 1 件のみの場合はグループ選択を省略して配下一覧を直接表示し (実質 1 段階)、
#   その場合の 0/q は「戻る先のグループ選択が無い」ため空を返して終了する。
#   preset: projectGroups 内のグループ名。一致すれば単一グループ扱いでグループ選択を省略
#   (メニュー L<n> の直結起動)。不一致 (config 変更直後など) は警告して通常フローへ戻す。
launcher__select_grouped() {
  local mode="${1:-foreground}" preset="${2:-}" mode_label
  mode_label="$(launcher__select_mode_label "$mode")"
  local -a groups=(); mapfile -t groups < <(config_project_groups)
  local -a all=();    mapfile -t all    < <(launcher__project_list)
  if [[ -n "$preset" ]]; then
    local _g _hit=0
    for _g in "${groups[@]}"; do [[ "$_g" == "$preset" ]] && _hit=1; done
    if (( _hit )); then
      groups=("$preset")
    else
      printf '  %s⚠️  グループ %s は projectGroups に存在しません。通常のグループ選択へ切り替えます。%s\n' \
        "$C_YELLOW" "$preset" "$C_RESET" >&2
    fi
  fi
  local single=0; (( ${#groups[@]} == 1 )) && single=1

  while true; do
    local group p
    if (( single )); then
      group="${groups[0]}"
    else
      # Step 1: グループ選択
      printf '\n  %s📋 グループ選択 [%s起動]%s\n' "$C_CYAN" "$mode_label" "$C_RESET" >&2
      printf '     %s0・q・exit・/exit = 戻る%s\n\n' "$C_WHITE" "$C_RESET" >&2
      local gi g cnt
      for gi in "${!groups[@]}"; do
        g="${groups[$gi]}"
        cnt=0; for p in "${all[@]}"; do [[ "$p" == "${g}/"* ]] && cnt=$((cnt + 1)); done
        printf '  %s[%2d]%s 📁 %-30s %s(%s件)%s\n' "$C_CYAN" "$((gi + 1))" "$C_RESET" "$g" "$C_WHITE" "$cnt" "$C_RESET" >&2
      done
      printf '\n' >&2
      local gidx; read -rp "  グループ番号 (1-${#groups[@]}, 0=戻る): " gidx
      case "${gidx,,}" in 0|q|quit|exit|/exit|"") return 0 ;; esac
      if ! [[ "$gidx" =~ ^[0-9]+$ ]] || (( gidx < 1 || gidx > ${#groups[@]} )); then
        printf '%s  無効な入力です。%s\n' "$C_RED" "$C_RESET" >&2; continue
      fi
      group="${groups[$((gidx - 1))]}"
    fi

    # Step 2: 配下サブプロジェクト選択
    local -a subs=(); for p in "${all[@]}"; do [[ "$p" == "${group}/"* ]] && subs+=("$p"); done
    if (( ${#subs[@]} == 0 )); then
      printf '  %s(%s に .git 付きサブプロジェクトがありません)%s\n' "$C_YELLOW" "$group" "$C_RESET" >&2
      (( single )) && return 0
      continue
    fi
    printf '\n  %s📂 %s のプロジェクト [%s起動]%s\n' "$C_CYAN" "$group" "$mode_label" "$C_RESET" >&2
    if (( single )); then
      printf '     %s0・q・exit・/exit = 戻る%s\n\n' "$C_WHITE" "$C_RESET" >&2
    else
      printf '     %s0・q = グループ選択へ戻る%s\n\n' "$C_WHITE" "$C_RESET" >&2
    fi
    local si proj st
    for si in "${!subs[@]}"; do
      proj="${subs[$si]}"
      st="$(launcher__project_run_status "$proj")"
      launcher__print_project_row "$((si + 1))" "${proj#*/}" "$st"
    done
    printf '\n' >&2
    local sidx; read -rp "  番号 (1-${#subs[@]}, 0=戻る): " sidx
    case "${sidx,,}" in 0|q|quit|exit|/exit|"")
      (( single )) && return 0
      continue ;;
    esac
    if [[ "$sidx" =~ ^[0-9]+$ ]] && (( sidx >= 1 && sidx <= ${#subs[@]} )); then
      printf '%s' "${subs[$((sidx - 1))]}"; return 0
    fi
    printf '%s  無効な入力です。%s\n' "$C_RED" "$C_RESET" >&2
  done
}

# launcher__select_flat [mode] — 従来のフラット選択 (projectGroups 未設定時)
#   全プロジェクトを番号付きで表示する。running は選択後に menu 側で接続/停止へ分岐する。
launcher__select_flat() {
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
