#!/usr/bin/env bash
# ============================================================
# run-ledger.sh — Durable Agent Execution 台帳 (Long-Horizon / 中断再開)
#
# 役割: 1 つの Agent 実行 (run) を「ファイル 1 件 + 追記ログ」で永続化し、
#       長時間タスクの heartbeat / checkpoint / resume / 破棄判定を提供する。
#       2026-09 の最前線技術のうち Long-Horizon Agent・Durable Agent Execution・
#       大規模改修の run 分割を、外部 DB なしで (このリポジトリ単体で) 実現する。
#
# 設計原則:
#   - 正本は run ディレクトリ配下の run.json (原子的書き込みは json.sh に委譲)
#   - 書き込みは json_set (mktemp + mv + flock) のみ。部分書き込みを残さない
#   - 状態遷移は明示。terminal = completed / failed / blocked。
#     running → (heartbeat 途絶 / PID 消滅) → stale / interrupted → resume → running
#   - resume は checkpoint が無い run では成功しない (再開不能を成功と偽らない)
#   - failed / blocked は failures.jsonl へ signature 付きで追記する
#     (Self-Improvement の Repeated Evidence 判定が読む唯一の観測源)
#
# 保存先: $CLAUDEOS_HOME/runs/<run-id>/ (既定 ~/.claudeos/runs)
#         CCSU_RUNS_DIR / CLAUDEOS_RUNS_DIR で上書き可 (テスト用)
#
# 注意: このファイルは「source される」ため set -euo pipefail を設定しない。
#       厳格モードは実行エントリ (bin/*.sh) で宣言する。
# ============================================================

[[ -n "${_CCSU_RUN_LEDGER_LOADED:-}" ]] && return 0
_CCSU_RUN_LEDGER_LOADED=1

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/json.sh"

RL_SCHEMA="claudeos.run/v1"
RL_DEFAULT_TTL="${RL_DEFAULT_TTL:-900}"

# --- 内部ユーティリティ -------------------------------------------------

rl__root() { printf '%s' "${CCSU_RUNS_DIR:-${CLAUDEOS_RUNS_DIR:-$CCSU_HOME/runs}}"; }
rl__now() { date +%s; }
rl__iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
rl__uuid() {
  if [[ -r /proc/sys/kernel/random/uuid ]]; then
    cat /proc/sys/kernel/random/uuid
  else
    printf '%s-%s-%s' "$$" "$(rl__now)" "$RANDOM"
  fi
}
rl__short_uuid() { rl__uuid | tr -d '-' | cut -c1-8; }

# rl__valid_id <id> — パストラバーサルと空を拒否
rl__valid_id() {
  [[ "$1" =~ ^run-[A-Za-z0-9T._-]+$ ]]
}

rl_run_dir() { printf '%s/%s' "$(rl__root)" "$1"; }
rl_run_file() { printf '%s/run.json' "$(rl_run_dir "$1")"; }
rl_run_events_file() { printf '%s/events.jsonl' "$(rl_run_dir "$1")"; }
rl_failures_file() { printf '%s/failures.jsonl' "$(rl__root)"; }

rl_run_exists() { [[ -f "$(rl_run_file "$1")" ]]; }

# rl_run_get <id> <jq-filter> [default] — スカラー取得
rl_run_get() {
  local id="$1" filter="$2" default="${3:-}"
  rl__valid_id "$id" || { printf '%s' "$default"; return 0; }
  json_get "$(rl_run_file "$id")" "$filter" "$default"
}

# rl_run_json <id> — run 全体を compact JSON で取得
rl_run_json() {
  local id="$1"
  rl__valid_id "$id" || return 1
  local f; f="$(rl_run_file "$id")"
  [[ -f "$f" ]] || return 1
  jq -c . "$f"
}

# rl_run_terminal <id> — completed / failed / blocked なら 0
rl_run_terminal() {
  case "$(rl_run_get "$1" '.status' '')" in
    completed|failed|blocked) return 0 ;;
    *) return 1 ;;
  esac
}

rl__event() {
  local id="$1" type="$2" payload="${3:-}"
  [[ -n "$payload" ]] || payload='{}'
  local line
  line="$(jq -cn --arg at "$(rl__iso)" --arg epoch "$(rl__now)" --arg type "$type" \
    --argjson payload "$payload" \
    '{at:$at, epoch:($epoch|tonumber), type:$type, payload:$payload}')" || return 1
  json_append_line "$(rl_run_events_file "$id")" "$line"
}

# rl__update <id> <jq-filter> [jq-args...] — revision / updated_at を必ず進める
rl__update() {
  local id="$1"; shift
  local filter="$1"; shift
  rl__valid_id "$id" || { log_warn "run-ledger: 不正な run-id: $id"; return 1; }
  json_set "$(rl_run_file "$id")" \
    "($filter) | .updated_at = \$__at | .updated_epoch = \$__epoch | .revision = ((.revision // 0) + 1)" \
    --arg __at "$(rl__iso)" --argjson __epoch "$(rl__now)" "$@"
}

# rl_signature <text> — 失敗の同一性判定に使う正規化 signature。
#   可変部分 (数値・hex・タイムスタンプ・パス) を落として sha1 の先頭 16 文字。
rl_signature() {
  local norm
  norm="$(printf '%s' "${1:-}" \
    | tr 'A-Z' 'a-z' \
    | sed -E 's/[0-9]{4}-[0-9]{2}-[0-9]{2}[t ][0-9:]+//g; s/0x[0-9a-f]+//g; s/\b[0-9a-f]{7,}\b//g; s/[0-9]+//g; s#(/[a-z0-9._-]+){2,}#/<path>#g; s/[[:space:]]+/ /g')"
  printf 'sig-%s' "$(printf '%s' "$norm" | sha1sum | cut -c1-16)"
}

rl__pid_alive() {
  local pid="${1:-0}"
  [[ "$pid" =~ ^[0-9]+$ ]] && (( pid > 0 )) && kill -0 "$pid" 2>/dev/null
}

# --- 公開 API -----------------------------------------------------------

# rl_run_start --project P --task T [--kind task|child] [--owner O]
#              [--parent run-id] [--ttl seconds] [--worktree path]
#   run を running で作成し run-id を stdout へ返す。
rl_run_start() {
  local project="" task="" kind="task" owner="${USER:-unknown}" parent="" ttl="$RL_DEFAULT_TTL" worktree=""
  while (( $# )); do
    case "$1" in
      --project) project="${2:-}"; shift 2 ;;
      --task)    task="${2:-}";    shift 2 ;;
      --kind)    kind="${2:-}";    shift 2 ;;
      --owner)   owner="${2:-}";   shift 2 ;;
      --parent)  parent="${2:-}";  shift 2 ;;
      --ttl)     ttl="${2:-}";     shift 2 ;;
      --worktree) worktree="${2:-}"; shift 2 ;;
      *) log_warn "run-ledger: 不明な引数: $1"; shift ;;
    esac
  done
  [[ -n "$project" ]] || { log_error "run-ledger: --project は必須です"; return 2; }
  [[ -n "$task" ]]    || { log_error "run-ledger: --task は必須です"; return 2; }
  [[ "$kind" =~ ^(task|child)$ ]] || { log_error "run-ledger: --kind は task|child"; return 2; }
  [[ "$ttl" =~ ^[0-9]+$ ]] || { log_error "run-ledger: --ttl は秒数"; return 2; }
  if [[ -n "$parent" ]]; then
    rl_run_exists "$parent" || { log_error "run-ledger: 親 run が存在しません: $parent"; return 2; }
    rl_run_terminal "$parent" && { log_error "run-ledger: 親 run は終了済みです: $parent"; return 2; }
  fi

  local id="run-$(date -u +%Y%m%dT%H%M%S)-$(rl__short_uuid)"
  local dir; dir="$(rl_run_dir "$id")"
  mkdir -p "$dir" || { log_error "run-ledger: ディレクトリ作成失敗: $dir"; return 1; }

  local epoch; epoch="$(rl__now)"
  local at; at="$(rl__iso)"
  local parent_json=null
  [[ -n "$parent" ]] && parent_json="$(printf '"%s"' "$parent")"

  if ! json_set "$(rl_run_file "$id")" \
      '{schema:$schema, run_id:$id, project:$project, task:$task, kind:$kind, owner:$owner,
        parent_run_id:$parent, pid:$pid, worktree:$worktree, status:"running", phase:"start",
        created_at:$at, created_epoch:$epoch, updated_at:$at, updated_epoch:$epoch, revision:1,
        heartbeat_ttl_seconds:$ttl, last_heartbeat_at:$at, last_heartbeat_epoch:$epoch,
        attempts:1, checkpoints:[], stale_reason:null, last_error:null}' \
      --arg schema "$RL_SCHEMA" --arg id "$id" --arg project "$project" --arg task "$task" \
      --arg kind "$kind" --arg owner "$owner" --argjson parent "$parent_json" \
      --argjson pid "$$" --arg worktree "$worktree" --arg at "$at" --argjson epoch "$epoch" --argjson ttl "$ttl"; then
    log_error "run-ledger: run.json 作成失敗: $id"
    return 1
  fi
  rl__event "$id" "start" "$(jq -cn --arg project "$project" --arg kind "$kind" '{project:$project, kind:$kind}')"
  printf '%s\n' "$id"
}

# rl_run_heartbeat <run-id> [--note N] — 生存通知。terminal への通知は拒否。
rl_run_heartbeat() {
  local id="${1:-}"; shift || true
  local note=""
  while (( $# )); do
    case "$1" in
      --note) note="${2:-}"; shift 2 ;;
      *) shift ;;
    esac
  done
  rl__valid_id "$id" || { log_error "run-ledger: 不正な run-id: $id"; return 2; }
  rl_run_exists "$id" || { log_error "run-ledger: run が存在しません: $id"; return 2; }
  rl_run_terminal "$id" && { log_error "run-ledger: 終了済み run へ heartbeat は送れません: $id"; return 3; }
  rl__update "$id" '.status = "running" | .last_heartbeat_at = $__at | .last_heartbeat_epoch = $__epoch' || return 1
  rl__event "$id" "heartbeat" "$(jq -cn --arg note "$note" '{note:$note}')"
}

# rl_run_checkpoint <run-id> --phase PH [--note N] [--state-file F]
#   state-file は任意の作業状態 (何でもよい)。中身の sha256 だけを記録し本文は保存しない。
rl_run_checkpoint() {
  local id="${1:-}"; shift || true
  local phase="" note="" state_file=""
  while (( $# )); do
    case "$1" in
      --phase)      phase="${2:-}";      shift 2 ;;
      --note)       note="${2:-}";       shift 2 ;;
      --state-file) state_file="${2:-}"; shift 2 ;;
      *) shift ;;
    esac
  done
  rl__valid_id "$id" || { log_error "run-ledger: 不正な run-id: $id"; return 2; }
  rl_run_exists "$id" || { log_error "run-ledger: run が存在しません: $id"; return 2; }
  rl_run_terminal "$id" && { log_error "run-ledger: 終了済み run に checkpoint は積めません: $id"; return 3; }
  [[ -n "$phase" ]] || { log_error "run-ledger: --phase は必須です"; return 2; }

  local sha=""
  if [[ -n "$state_file" ]]; then
    [[ -f "$state_file" ]] || { log_error "run-ledger: state-file がありません: $state_file"; return 2; }
    sha="$(sha256sum "$state_file" | cut -d' ' -f1)"
  fi

  local seq
  seq="$(( $(rl_run_get "$id" '.checkpoints | length' '0') + 1 ))"
  local at; at="$(rl__iso)"; local epoch; epoch="$(rl__now)"
  rl__update "$id" \
    '.phase = $phase | .checkpoints += [{seq:$seq, phase:$phase, note:$note, state_sha256:(if $sha=="" then null else $sha end), created_at:$__at, created_epoch:$__epoch}]' \
    --arg phase "$phase" --arg note "$note" --arg sha "$sha" --argjson seq "$seq" || return 1
  rl__event "$id" "checkpoint" "$(jq -cn --arg phase "$phase" --argjson seq "$seq" '{phase:$phase, seq:$seq}')"
  printf '%s\n' "$seq"
}

# rl_run_finish <run-id> --status completed|failed|blocked [--note N]
#   failed / blocked は failures.jsonl へ signature 付きで記録する。
rl_run_finish() {
  local id="${1:-}"; shift || true
  local status="" note=""
  while (( $# )); do
    case "$1" in
      --status) status="${2:-}"; shift 2 ;;
      --note)   note="${2:-}";   shift 2 ;;
      *) shift ;;
    esac
  done
  rl__valid_id "$id" || { log_error "run-ledger: 不正な run-id: $id"; return 2; }
  rl_run_exists "$id" || { log_error "run-ledger: run が存在しません: $id"; return 2; }
  [[ "$status" =~ ^(completed|failed|blocked)$ ]] || { log_error "run-ledger: --status は completed|failed|blocked"; return 2; }
  rl_run_terminal "$id" && { log_error "run-ledger: 既に終了済みです: $id"; return 3; }

  rl__update "$id" '.status = $status | .phase = "end" | .last_error = (if $status=="completed" then null else $note end)' \
    --arg status "$status" --arg note "$note" || return 1
  rl__event "$id" "finish" "$(jq -cn --arg status "$status" --arg note "$note" '{status:$status, note:$note}')"

  if [[ "$status" != "completed" ]]; then
    local sig; sig="$(rl_signature "$note")"
    local line
    line="$(jq -cn --arg at "$(rl__iso)" --arg epoch "$(rl__now)" --arg run_id "$id" \
      --arg project "$(rl_run_get "$id" '.project' '')" --arg status "$status" \
      --arg signature "$sig" --arg note "$note" \
      '{at:$at, epoch:($epoch|tonumber), run_id:$run_id, project:$project, status:$status, signature:$signature, note:$note}')"
    json_append_line "$(rl_failures_file)" "$line"
  fi
}

# rl_run_resume <run-id> [--note N] — stale / interrupted / running を running へ戻す。
#   checkpoint が 1 件も無い run は再開不能として拒否する (成功と偽らない)。
rl_run_resume() {
  local id="${1:-}"; shift || true
  local note=""
  while (( $# )); do
    case "$1" in
      --note) note="${2:-}"; shift 2 ;;
      *) shift ;;
    esac
  done
  rl__valid_id "$id" || { log_error "run-ledger: 不正な run-id: $id"; return 2; }
  rl_run_exists "$id" || { log_error "run-ledger: run が存在しません: $id"; return 2; }
  rl_run_terminal "$id" && { log_error "run-ledger: 終了済み run は再開できません: $id"; return 3; }

  local cps; cps="$(rl_run_get "$id" '.checkpoints | length' '0')"
  if (( cps < 1 )); then
    log_error "run-ledger: checkpoint が無い run は再開できません (再実行してください): $id"
    return 4
  fi

  rl__update "$id" \
    '.status = "running" | .phase = (.checkpoints[-1].phase) | .attempts = ((.attempts // 1) + 1) | .stale_reason = null' || return 1
  rl__event "$id" "resume" "$(jq -cn --arg note "$note" --argjson attempts "$(rl_run_get "$id" '.attempts' '1')" '{note:$note, attempts:$attempts}')"
  jq -cn --arg run_id "$id" --arg phase "$(rl_run_get "$id" '.phase' '')" \
    --argjson attempts "$(rl_run_get "$id" '.attempts' '1')" \
    --argjson checkpoints "$cps" \
    '{run_id:$run_id, status:"running", next_phase:$phase, attempts:$attempts, checkpoints:$checkpoints}'
}

# rl_run_reconcile [--stale-seconds N] [--json]
#   status=running の run だけを対象に、heartbeat 途絶 → stale、PID 消滅 → interrupted。
#   既に stale / interrupted の run は触らない (冪等)。
rl_run_reconcile() {
  local stale_seconds=0 json_out=0
  while (( $# )); do
    case "$1" in
      --stale-seconds) stale_seconds="${2:-0}"; shift 2 ;;
      --json) json_out=1; shift ;;
      *) shift ;;
    esac
  done
  local root; root="$(rl__root)"
  local now; now="$(rl__now)"
  local acc='[]'
  [[ -d "$root" ]] || { (( json_out )) && printf '[]\n'; return 0; }

  local d id status ttl hb pid reason new_status
  for d in "$root"/run-*/; do
    [[ -d "$d" ]] || continue
    id="$(basename "$d")"
    rl__valid_id "$id" || continue
    status="$(rl_run_get "$id" '.status' '')"
    [[ "$status" == "running" ]] || continue
    ttl="$(rl_run_get "$id" '.heartbeat_ttl_seconds' "$RL_DEFAULT_TTL")"
    [[ "$ttl" =~ ^[0-9]+$ ]] || ttl="$RL_DEFAULT_TTL"
    (( stale_seconds > 0 )) && ttl="$stale_seconds"
    hb="$(rl_run_get "$id" '.last_heartbeat_epoch' '0')"
    [[ "$hb" =~ ^[0-9]+$ ]] || hb=0
    pid="$(rl_run_get "$id" '.pid' '0')"

    reason=""; new_status=""
    if (( hb > 0 )) && (( now - hb > ttl )); then
      reason="heartbeat_timeout:${now}-${hb}>${ttl}"
      new_status="stale"
    elif ! rl__pid_alive "$pid"; then
      reason="process_gone:pid=${pid}"
      new_status="interrupted"
    fi
    [[ -n "$new_status" ]] || continue

    rl__update "$id" '.status = $status | .stale_reason = $reason' --arg status "$new_status" --arg reason "$reason" || continue
    rl__event "$id" "reconcile" "$(jq -cn --arg status "$new_status" --arg reason "$reason" '{status:$status, reason:$reason}')"
    acc="$(jq -cn --argjson acc "$acc" --arg run_id "$id" --arg status "$new_status" --arg reason "$reason" \
      '$acc + [{run_id:$run_id, status:$status, reason:$reason}]')"
  done

  if (( json_out )); then
    printf '%s\n' "$acc"
  else
    printf '%s\n' "$acc" | jq -r '.[] | "\(.run_id)\t\(.status)\t\(.reason)"'
  fi
}

# rl_run_list [--status S] [--all] [--json]
#   既定は terminal 以外 (進行中) のみ。
rl_run_list() {
  local status_filter="" all=0 json_out=0
  while (( $# )); do
    case "$1" in
      --status) status_filter="${2:-}"; shift 2 ;;
      --all) all=1; shift ;;
      --json) json_out=1; shift ;;
      *) shift ;;
    esac
  done
  local root; root="$(rl__root)"
  local acc='[]' d id st
  if [[ -d "$root" ]]; then
    for d in "$root"/run-*/; do
      [[ -d "$d" ]] || continue
      id="$(basename "$d")"
      rl__valid_id "$id" || continue
      st="$(rl_run_get "$id" '.status' '')"
      [[ -n "$status_filter" && "$st" != "$status_filter" ]] && continue
      if (( ! all )) && [[ -z "$status_filter" ]]; then
        case "$st" in completed|failed|blocked) continue ;; esac
      fi
      acc="$(jq -cn --argjson acc "$acc" --argjson run "$(rl_run_json "$id")" '$acc + [$run]')"
    done
  fi
  if (( json_out )); then
    printf '%s\n' "$acc"
  else
    printf '%s\n' "$acc" | jq -r '.[] | "\(.run_id)\t\(.status)\t\(.project)\t\(.phase)\t\(.attempts // 1)"'
  fi
}

# rl_run_tree [--parent run-id] [--json] — run 階層 (大規模改修の分割実行を可視化)
rl_run_tree() {
  local parent="" json_out=0
  while (( $# )); do
    case "$1" in
      --parent) parent="${2:-}"; shift 2 ;;
      --json) json_out=1; shift ;;
      *) shift ;;
    esac
  done
  local all; all="$(rl_run_list --all --json)"
  local rows
  if [[ -n "$parent" ]]; then
    rows="$(printf '%s\n' "$all" | jq -c --arg p "$parent" '[.[] | select(.run_id==$p or .parent_run_id==$p)]')"
  else
    rows="$all"
  fi
  if (( json_out )); then
    printf '%s\n' "$rows"
  else
    printf '%s\n' "$rows" | jq -r '.[] | "\(if .parent_run_id then "  └─ " else "" end)\(.run_id)\t\(.status)\t\(.task)"'
  fi
}

# rl_run_stats [--json] — 進行中 / 滞留 / 失敗 signature の集計 (Self-Improvement の入力)
rl_run_stats() {
  local json_out=0
  while (( $# )); do
    case "$1" in --json) json_out=1; shift ;; *) shift ;; esac
  done
  local root; root="$(rl__root)"
  local active=0 stale=0 terminal=0
  if [[ -d "$root" ]]; then
    local d id st
    for d in "$root"/run-*/; do
      [[ -d "$d" ]] || continue
      id="$(basename "$d")"
      rl__valid_id "$id" || continue
      st="$(rl_run_get "$id" '.status' '')"
      case "$st" in
        running) active=$(( active + 1 )) ;;
        stale|interrupted) stale=$(( stale + 1 )) ;;
        *) terminal=$(( terminal + 1 )) ;;
      esac
    done
  fi
  local fails=0
  [[ -f "$(rl_failures_file)" ]] && fails="$(wc -l < "$(rl_failures_file)" | tr -d ' ')"
  if (( json_out )); then
    jq -cn --argjson active "$active" --argjson stale "$stale" --argjson terminal "$terminal" --argjson failures "$fails" \
      '{active:$active, stale:$stale, terminal:$terminal, failure_records:$failures}'
  else
    printf 'active=%s stale=%s terminal=%s failure_records=%s\n' "$active" "$stale" "$terminal" "$fails"
  fi
}
