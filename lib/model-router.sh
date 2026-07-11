#!/usr/bin/env bash
# ============================================================
# model-router.sh — Opus 4.8 / Sonnet 5 自動選択
#
# 方針:
#   - 高リスク/設計/Release/PR最終レビューは Opus 4.8 + xhigh
#   - 通常実装/テスト/docs/軽微リファクタは Sonnet 5 + max (既定)
#   - 利用比率差が閾値(既定5%)以上なら、低利用モデルへ寄せる
#   - 記録単位は session start。実 token/cost は stream-json から別途捕捉可能。
# ============================================================

[[ -n "${_CCSU_MODEL_ROUTER_LOADED:-}" ]] && return 0
_CCSU_MODEL_ROUTER_LOADED=1

model_router__config_get() {
  local filter="$1" default="${2:-}" cfg="${CCSU_CONFIG_PATH:-${AI_STARTUP_CONFIG_PATH:-}}"
  if [[ -n "$cfg" && -f "$cfg" ]] && command -v jq >/dev/null 2>&1; then
    local v
    v="$(jq -r "$filter // empty" "$cfg" 2>/dev/null || true)"
    [[ -n "$v" && "$v" != "null" ]] && { printf '%s' "$v"; return 0; }
  fi
  printf '%s' "$default"
}

model_router__expand_path() {
  local p="$1"
  p="${p/#\~/$HOME}"
  printf '%s' "$p"
}

model_router__usage_file() {
  local configured
  configured="$(model_router__config_get '.modelRouter.usageFile' '')"
  if [[ -n "${CLAUDEOS_MODEL_USAGE_FILE:-}" ]]; then
    printf '%s' "$CLAUDEOS_MODEL_USAGE_FILE"
  elif [[ -n "$configured" ]]; then
    model_router__expand_path "$configured"
  else
    printf '%s' "${CCSU_HOME:-${CLAUDEOS_HOME:-$HOME/.claudeos}}/model-usage.jsonl"
  fi
}

model_router__threshold_pct() {
  local v="${CLAUDEOS_MODEL_BALANCE_THRESHOLD_PCT:-$(model_router__config_get '.modelRouter.balanceThresholdPct' '5')}"
  [[ "$v" =~ ^[0-9]+([.][0-9]+)?$ ]] || v=5
  printf '%s' "$v"
}

model_router__model_for_key() {
  case "$1" in
    opus)
      MODEL_ROUTER_MODEL="${CLAUDEOS_OPUS_MODEL:-$(model_router__config_get '.modelRouter.models.opus.id' 'claude-opus-4-8')}"
      MODEL_ROUTER_EFFORT="${CLAUDEOS_OPUS_EFFORT:-$(model_router__config_get '.modelRouter.models.opus.effort' 'xhigh')}"
      ;;
    sonnet)
      MODEL_ROUTER_MODEL="${CLAUDEOS_SONNET_MODEL:-$(model_router__config_get '.modelRouter.models.sonnet.id' 'claude-sonnet-5')}"
      MODEL_ROUTER_EFFORT="${CLAUDEOS_SONNET_EFFORT:-$(model_router__config_get '.modelRouter.models.sonnet.effort' 'max')}"
      ;;
    *)
      return 1
      ;;
  esac
}

# taskEffort: config の .modelRouter.taskEffort (キー→effort のマップ) を部分一致で引く。
#   キーが task 文字列に含まれれば対応 effort を返す (opt-in・未設定なら空 = モデル既定を維持)。
#   effort 値は low|medium|high|xhigh|max のみ受理し、不正値は無視する (--effort 起動失敗の予防)。
model_router__task_effort() {
  local task="$1" cfg="${CCSU_CONFIG_PATH:-${AI_STARTUP_CONFIG_PATH:-}}"
  [[ -n "$cfg" && -f "$cfg" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  local k v
  while IFS=$'\t' read -r k v; do
    [[ -n "$k" && "$task" == *"$k"* ]] || continue
    [[ "$v" =~ ^(low|medium|high|xhigh|max)$ ]] || continue
    printf '%s\t%s' "$k" "$v"
    return 0
  done < <(jq -r '.modelRouter.taskEffort // {} | to_entries[] | "\(.key)\t\(.value)"' "$cfg" 2>/dev/null || true)
  return 0
}

model_router__task_default() {
  local task="${1:-${CLAUDEOS_MODEL_TASK:-normal}}"
  task="$(printf '%s' "$task" | tr '[:upper:]' '[:lower:]')"
  case "$task" in
    *security*|*architect*|*architecture*|*design*|*release*|*deploy*|*critical*|*incident*|*hotfix*|*pr-review*|*final-review*|cto|plan|opusplan)
      printf 'opus'
      ;;
    *implement*|*developer*|*test*|*qa*|*doc*|*refactor*|*lint*|*format*|normal|sonnet)
      printf 'sonnet'
      ;;
    *)
      printf 'sonnet'
      ;;
  esac
}

model_router__count_key() {
  local key="$1" file
  file="$(model_router__usage_file)"
  [[ -f "$file" ]] || { printf '0'; return 0; }
  grep -c "\"event\":\"select\".*\"model_key\":\"$key\"" "$file" 2>/dev/null || true
}

model_router__balance_key() {
  local default_key="$1" threshold opus_count sonnet_count total diff less_key
  MODEL_ROUTER_BALANCE_KEY="$default_key"
  MODEL_ROUTER_BALANCED=0
  threshold="$(model_router__threshold_pct)"
  opus_count="$(model_router__count_key opus)"
  sonnet_count="$(model_router__count_key sonnet)"
  total=$((opus_count + sonnet_count))

  MODEL_ROUTER_OPUS_COUNT="$opus_count"
  MODEL_ROUTER_SONNET_COUNT="$sonnet_count"
  MODEL_ROUTER_TOTAL_COUNT="$total"
  MODEL_ROUTER_DIFF_PCT="0"

  (( total == 0 )) && return 0

  if (( opus_count > sonnet_count )); then
    less_key="sonnet"
    diff="$(awk -v a="$opus_count" -v b="$sonnet_count" -v t="$total" 'BEGIN { printf "%.4f", ((a-b) / t) * 100 }')"
  else
    less_key="opus"
    diff="$(awk -v a="$opus_count" -v b="$sonnet_count" -v t="$total" 'BEGIN { printf "%.4f", ((b-a) / t) * 100 }')"
  fi
  MODEL_ROUTER_DIFF_PCT="$diff"

  if awk -v d="$diff" -v th="$threshold" 'BEGIN { exit !(d >= th) }'; then
    MODEL_ROUTER_BALANCE_KEY="$less_key"
    MODEL_ROUTER_BALANCED=1
  fi
}

model_router__select() {
  local task="${1:-${CLAUDEOS_MODEL_TASK:-normal}}" default_key key forced

  MODEL_ROUTER_ENABLED=1
  MODEL_ROUTER_KEY=""
  MODEL_ROUTER_MODEL=""
  MODEL_ROUTER_EFFORT=""
  MODEL_ROUTER_REASON=""
  MODEL_ROUTER_TASK="$task"

  local enabled="${CLAUDEOS_MODEL_ROUTER:-$(model_router__config_get '.modelRouter.enabled' 'true')}"
  if [[ "$enabled" == "0" || "$enabled" == "false" ]]; then
    MODEL_ROUTER_ENABLED=0
    MODEL_ROUTER_REASON="disabled"
    return 0
  fi

  forced="${CLAUDEOS_MODEL_KEY:-}"
  if [[ -n "$forced" ]]; then
    forced="$(printf '%s' "$forced" | tr '[:upper:]' '[:lower:]')"
    [[ "$forced" == "opus" || "$forced" == "sonnet" ]] || return 1
    key="$forced"
    MODEL_ROUTER_REASON="forced:$forced"
  else
    default_key="$(model_router__task_default "$task")"
    model_router__balance_key "$default_key"
    key="$MODEL_ROUTER_BALANCE_KEY"
    if [[ "${MODEL_ROUTER_BALANCED:-0}" == "1" ]]; then
      MODEL_ROUTER_REASON="balance:${MODEL_ROUTER_DIFF_PCT}%>=${CLAUDEOS_MODEL_BALANCE_THRESHOLD_PCT:-5}%"
    else
      MODEL_ROUTER_REASON="task:$task"
    fi
  fi

  MODEL_ROUTER_KEY="$key"
  model_router__model_for_key "$key"

  # effort 上書き: CLAUDEOS_MODEL_EFFORT (強制) > taskEffort (config opt-in) > モデル既定
  if [[ -n "${CLAUDEOS_MODEL_EFFORT:-}" ]]; then
    if [[ "${CLAUDEOS_MODEL_EFFORT}" =~ ^(low|medium|high|xhigh|max)$ ]]; then
      MODEL_ROUTER_EFFORT="$CLAUDEOS_MODEL_EFFORT"
      MODEL_ROUTER_REASON="${MODEL_ROUTER_REASON}+effort:forced"
    fi
  else
    local te_key te_val te
    te="$(model_router__task_effort "$task")"
    if [[ -n "$te" ]]; then
      te_key="${te%%$'\t'*}"; te_val="${te#*$'\t'}"
      MODEL_ROUTER_EFFORT="$te_val"
      MODEL_ROUTER_REASON="${MODEL_ROUTER_REASON}+effort:task(${te_key})"
    fi
  fi
}

model_router__json_escape() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import json,sys; print(json.dumps(sys.stdin.read())[1:-1])'
  else
    sed 's/\\/\\\\/g; s/"/\\"/g'
  fi
}

model_router__record_selection() {
  [[ "${MODEL_ROUTER_ENABLED:-1}" == "1" ]] || return 0
  [[ -n "${MODEL_ROUTER_KEY:-}" ]] || return 0
  local project="${1:-}" source="${2:-unknown}" task="${3:-${MODEL_ROUTER_TASK:-normal}}" file now
  file="$(model_router__usage_file)"
  now="$(date -Iseconds)"
  mkdir -p "$(dirname "$file")" 2>/dev/null || true
  printf '{"event":"select","at":"%s","source":"%s","project":"%s","task":"%s","model_key":"%s","model":"%s","effort":"%s","reason":"%s"}\n' \
    "$(printf '%s' "$now" | model_router__json_escape)" \
    "$(printf '%s' "$source" | model_router__json_escape)" \
    "$(printf '%s' "$project" | model_router__json_escape)" \
    "$(printf '%s' "$task" | model_router__json_escape)" \
    "$(printf '%s' "$MODEL_ROUTER_KEY" | model_router__json_escape)" \
    "$(printf '%s' "$MODEL_ROUTER_MODEL" | model_router__json_escape)" \
    "$(printf '%s' "$MODEL_ROUTER_EFFORT" | model_router__json_escape)" \
    "$(printf '%s' "$MODEL_ROUTER_REASON" | model_router__json_escape)" \
    >> "$file"
}

model_router__shell_args() {
  [[ "${MODEL_ROUTER_ENABLED:-1}" == "1" && -n "${MODEL_ROUTER_MODEL:-}" ]] || return 0
  printf -- '--model %q --effort %q' "$MODEL_ROUTER_MODEL" "$MODEL_ROUTER_EFFORT"
}
