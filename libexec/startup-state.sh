#!/usr/bin/env bash
# ============================================================
# startup-state.sh — Web スタートアップコンソール用 状態スナップショット (read-only)
#
# 使い方: bash libexec/startup-state.sh [--json]
#
#   stdout に JSON 1 件を出力する。利用者は Web 側 (scripts/web/startup-server.js) のみ。
#   判定材料は bin/menu.sh (L1/S1/T1 の選択画面) と libexec/watch-session.sh が使う
#   ものと同一 (config_project_list / launcher__project_run_status / supervisor json /
#   foreground json / tmux / goal-router の Goal 定義) で、この script は
#   「同じ事実を機械可読にするだけ」の薄い層。判定ロジックを再実装しない。
#
# 保証: state.json も ~/.claudeos も書き換えない。プロジェクト内のファイルも読むだけ。
#       tmux / supervisor への操作は一切しない (起動・停止は startup-server.js →
#       bin/start-claude.sh / bin/autonomy.sh が行い、この script は関与しない)。
# ============================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
# shellcheck source=lib/config-loader.sh
source "$SCRIPT_DIR/../lib/config-loader.sh"
# shellcheck source=lib/launcher-common.sh
source "$SCRIPT_DIR/../lib/launcher-common.sh"
# shellcheck source=lib/model-router.sh
source "$SCRIPT_DIR/../lib/model-router.sh"
# shellcheck source=lib/goal-router.sh
source "$SCRIPT_DIR/../lib/goal-router.sh"

SUP_DIR="${CLAUDEOS_SUPERVISOR_DIR:-$CCSU_HOME/supervisor}"
FG_DIR="${CLAUDEOS_FOREGROUND_DIR:-$CCSU_HOME/foreground}"
SESS_DIR="${CLAUDEOS_SESSIONS_DIR:-$CCSU_HOME/sessions}"
TMUX_BIN="${TMUX_BIN:-tmux}"

# _pid_alive <pid> — 生存していれば 0
_pid_alive() {
  local pid="${1:-0}"
  [[ "$pid" =~ ^[0-9]+$ ]] && (( pid > 0 )) && kill -0 "$pid" 2>/dev/null
}

# _running_from_dir <dir> — status=running かつ PID 生存の project 名 (1行1件)
_running_from_dir() {
  local dir="$1" f proj pid
  [[ -d "$dir" ]] || return 0
  for f in "$dir"/*.json; do
    [[ -f "$f" ]] || continue
    [[ "$(json_get "$f" '.status' '')" == "running" ]] || continue
    proj="$(json_get "$f" '.project' '')"
    pid="$(json_get "$f" '.pid' '0')"
    [[ -n "$proj" ]] || continue
    _pid_alive "$pid" || continue
    printf '%s\n' "$proj"
  done
}

# _tmux_sessions — 実行中 claudeos-* tmux セッション名 (1行1件)
_tmux_sessions() {
  has_cmd "$TMUX_BIN" || return 0
  "$TMUX_BIN" ls 2>/dev/null | grep '^claudeos-' | cut -d: -f1 || true
}

# _project_json <name> — 1 プロジェクト分の JSON オブジェクト
_project_json() {
  local name="$1"
  local dir group run_status safe
  dir="$(launcher__project_dir "$name")"
  run_status="$(launcher__project_run_status "$name")"
  safe="$(ccsu_safe_name "$name")"
  case "$name" in
    */*) group="${name%%/*}" ;;
    *)   group="" ;;
  esac

  local sup_file="" fg_file=""
  [[ -f "$SUP_DIR/$safe.json" ]] && sup_file="$SUP_DIR/$safe.json"
  [[ -f "$FG_DIR/$safe.json" ]]  && fg_file="$FG_DIR/$safe.json"

  local sup_json="null" fg_json="null"
  if [[ -n "$sup_file" ]]; then
    local sup_status sup_pid sup_alive="false"
    sup_status="$(json_get "$sup_file" '.status' 'unknown')"
    sup_pid="$(json_get "$sup_file" '.pid' '0')"
    _pid_alive "$sup_pid" && sup_alive="true"
    sup_json="$(jq -n \
      --arg file "$sup_file" \
      --arg status "$sup_status" \
      --arg pid "$sup_pid" \
      --argjson alive "$sup_alive" \
      --arg started_at "$(json_get "$sup_file" '.started_at' '')" \
      --arg ended_at "$(json_get "$sup_file" '.ended_at' '')" \
      --arg day "$(json_get "$sup_file" '.day' '')" \
      --argjson restarts_today "$(json_get "$sup_file" '.restarts_today' '0')" \
      --argjson minutes_today "$(json_get "$sup_file" '.minutes_today' '0')" \
      --arg last_reason "$(json_get "$sup_file" '.last_reason' '')" \
      --arg cost "$(json_get "$sup_file" '.last_session_cost_usd' '0')" \
      --arg month "$(json_get "$sup_file" '.month_spent_usd' '0')" \
      '{file:$file,status:$status,pid:$pid,alive:$alive,started_at:$started_at,ended_at:$ended_at,
        day:$day,restarts_today:$restarts_today,minutes_today:$minutes_today,
        last_reason:$last_reason,last_session_cost_usd:$cost,month_spent_usd:$month}')"
  fi
  if [[ -n "$fg_file" ]]; then
    local fg_status fg_pid fg_alive="false"
    fg_status="$(json_get "$fg_file" '.status' 'unknown')"
    fg_pid="$(json_get "$fg_file" '.pid' '0')"
    _pid_alive "$fg_pid" && fg_alive="true"
    fg_json="$(jq -n \
      --arg file "$fg_file" \
      --arg status "$fg_status" \
      --arg pid "$fg_pid" \
      --argjson alive "$fg_alive" \
      --arg started_at "$(json_get "$fg_file" '.started_at' '')" \
      --arg mode "$(json_get "$fg_file" '.mode' '')" \
      '{file:$file,status:$status,pid:$pid,alive:$alive,started_at:$started_at,mode:$mode}')"
  fi

  local tmux_name="claudeos-$safe" tmux_hit="false"
  if _tmux_sessions | grep -Fxq "$tmux_name"; then tmux_hit="true"; fi

  local log_file="$SUP_DIR/$safe.log"
  [[ -f "$log_file" ]] || log_file="$CCSU_HOME/logs/${safe}.log"

  jq -n \
    --arg name "$name" --arg dir "$dir" --arg group "$group" \
    --arg run_status "$run_status" \
    --arg exists "$([[ -d "$dir" ]] && printf true || printf false)" \
    --argjson supervisor "$sup_json" --argjson foreground "$fg_json" \
    --arg tmux_name "$tmux_name" --argjson tmux "$tmux_hit" \
    --arg log_file "$([[ -f "$log_file" ]] && printf '%s' "$log_file" || printf '')" \
    '{name:$name,dir:$dir,group:$group,run_status:$run_status,exists:($exists=="true"),
      running:($run_status=="running"),
      supervisor:$supervisor,foreground:$foreground,
      tmux:{name:$tmux_name,active:$tmux},log_file:$log_file}'
}

# _goal_label <goal> — 表示ラベル。lib 側に日本語ラベル関数があれば使い、無ければ goal id。
# (lib/goal-router.sh の関数追加は未コミット WIP と同居しうるため、存在確認してから呼ぶ。
#  CI はコミット済みコードのみで動くので、無条件呼び出しは command not found →
#  stderr 汚染 → bats の JSON 検証が壊れる)
_goal_label() {
  local g="$1"
  if declare -F goal_router__label_ja >/dev/null 2>&1; then
    goal_router__label_ja "$g"
  else
    printf '%s' "$g"
  fi
}

# _history_json [limit] — 最近のセッション履歴 (既定 15 件)
_history_json() {
  local limit="${1:-15}" f out="[]"
  [[ -d "$SESS_DIR" ]] || { printf '[]'; return 0; }
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    out="$(jq -cn --argjson acc "$out" --arg file "$f" \
      --arg project "$(json_get "$f" '.project' '?')" \
      --arg status "$(json_get "$f" '.status' '?')" \
      --arg start "$(json_get "$f" '.start_time' '?')" \
      '$acc + [{file:$file,project:$project,status:$status,start_time:$start}]')"
  done < <(ls -t "$SESS_DIR"/*.json 2>/dev/null | head -"$limit" || true)
  printf '%s' "$out"
}

main() {
  local projects_json="[]" p
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    projects_json="$(jq -cn --argjson acc "$projects_json" --argjson item "$(_project_json "$p")" '$acc + [$item]')"
  done < <(config_project_list || true)

  local -a primary=() specialized=()
  primary=("${GOAL_ROUTER_PRIMARY_GOALS[@]}")
  specialized=("${GOAL_ROUTER_SPECIALIZED_GOALS[@]}")
  local goals_json pj="[]" sj="[]" g
  for g in "${primary[@]}"; do
    pj="$(jq -cn --argjson acc "$pj" --arg name "$g" --arg ja "$(_goal_label "$g")" '$acc + [{name:$name,label_ja:$ja}]')"
  done
  for g in "${specialized[@]}"; do
    sj="$(jq -cn --argjson acc "$sj" --arg name "$g" --arg ja "$(_goal_label "$g")" '$acc + [{name:$name,label_ja:$ja}]')"
  done
  goals_json="$(jq -n --argjson primary "$pj" --argjson specialized "$sj" '{primary:$primary,specialized:$specialized}')"

  local groups_json; groups_json="$(config_project_groups | jq -R . | jq -s .)"
  local tmux_json headless_json fg_json
  tmux_json="$(_tmux_sessions | jq -R . | jq -s .)"
  headless_json="$(_running_from_dir "$SUP_DIR" | jq -R . | jq -s .)"
  fg_json="$(_running_from_dir "$FG_DIR" | jq -R . | jq -s .)"

  jq -n \
    --arg generated_at "$(date -Is)" \
    --arg projects_dir "$(config_projects_dir)" \
    --arg config_path "$CCSU_CONFIG_PATH" \
    --arg host "$(hostname)" \
    --argjson groups "$groups_json" \
    --argjson projects "$projects_json" \
    --argjson goals "$goals_json" \
    --argjson tmux "$tmux_json" \
    --argjson headless "$headless_json" \
    --argjson foreground "$fg_json" \
    --argjson history "$(_history_json 15)" \
    --argjson max_sessions "${CCSU_MAX_SESSIONS:-4}" \
    --argjson max_session_minutes "${CCSU_MAX_SESSION_MINUTES:-300}" \
    --argjson default_session_minutes "$(config_get '.supervisor.defaults.sessionMinutes' "$(config_get '.cron.defaultDurationMinutes' '300')")" \
    --argjson foreground_minutes "$(config_get '.supervisor.defaults.foregroundSessionMinutes' '0')" \
    '{generated_at:$generated_at,host:$host,projects_dir:$projects_dir,config_path:$config_path,
      groups:$groups,projects:$projects,goals:$goals,
      sessions:{tmux:$tmux,headless:$headless,foreground:$foreground,history:$history,
                count:(($tmux|length)+($headless|length)+($foreground|length))},
      limits:{max_sessions:$max_sessions,max_session_minutes:$max_session_minutes,
              default_session_minutes:$default_session_minutes,foreground_minutes:$foreground_minutes}}'
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
