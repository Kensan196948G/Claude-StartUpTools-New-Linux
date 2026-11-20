#!/usr/bin/env bash
# ============================================================
# private-ai.sh — ローカル隔離推論 (Private / Confidential AI のうちローカル隔離部分)
#
# 役割: 機密性の高い入力に対して「外部 API へ出さない推論経路」を用意する。
#       - 推論は loopback の Ollama のみ。外部ホストは拒否
#       - 子プロセスへ渡す環境変数を明示的な最小集合にする (env -i)。
#         クラウドのトークンや proxy 設定がローカルモデルへ漏れない
#       - モデルは allowlist のものだけ (思わぬ巨大モデルの取得・実行を防ぐ)
#       - 呼び出しは JSONL で記録する (何をどのモデルへ出したかの証跡)
#
# 使い方:
#   private-ai.sh check                       # 実行可能性 (ollama / loopback / allowlist)
#   private-ai.sh models                      # 導入済みモデル (ollama list)
#   private-ai.sh run --model M --prompt-file F [--timeout S] [--json]
#   private-ai.sh usage [--tail N]            # 実行記録
#
# 終了コード: 0 成功 / 1 実行エラー / 2 引数エラー / 3 利用不可 (未導入・allowlist 外・非 loopback)
#
# 制約 (正直な範囲): 完全なネットワーク遮断ではない。netns/unshare なしでは
#   カーネルレベルの egress 制御はできない。ここで保証するのは
#   「宛先は loopback に限定」「環境変数を継承しない」の 2 点。
# ============================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
# shellcheck source=lib/json.sh
source "$SCRIPT_DIR/../lib/json.sh"

require_cmd jq

PA_CFG="${CLAUDEOS_PRIVATE_AI_CONFIG:-$CCSU_ROOT/config/private-ai.json}"
OLLAMA_BIN="${OLLAMA_BIN:-ollama}"

pa__cfg() { json_get "$PA_CFG" "$1" "${2:-}"; }
pa__cfg_json() { jq -c "$1" "$PA_CFG" 2>/dev/null || printf 'null'; }
pa__iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
pa__log() {
  local f; f="${CLAUDEOS_PRIVATE_AI_LOG:-$(pa__cfg '.log_file' "$CCSU_HOME/logs/private-ai.jsonl")}"
  f="${f/#\~/$HOME}"
  json_append_line "$f" "$1"
}

usage() { sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

# pa__host_allowed <host:port> — allowlist にある loopback のみ許可
pa__host_allowed() {
  local host="$1"
  [[ -n "$host" ]] || return 1
  local a
  while IFS= read -r a; do
    [[ -n "$a" ]] || continue
    [[ "$a" == "$host" ]] && return 0
  done < <(pa__cfg_json '.allowed_hosts' | jq -r '.[]?' 2>/dev/null || true)
  return 1
}

# pa__model_allowed <model>
pa__model_allowed() {
  local model="$1" m
  while IFS= read -r m; do
    [[ -n "$m" ]] || continue
    [[ "$m" == "$model" ]] && return 0
  done < <(pa__cfg_json '.models' | jq -r '.[]?' 2>/dev/null || true)
  return 1
}

# pa__child_env <host> — 子プロセスへ渡す環境変数 (最小集合)。printf で 1 行 1 つ。
#   PATH には ollama 実体のあるディレクトリ + 既定パスのみを含める
#   (親の PATH をそのまま渡すと、想定外のラッパー経由で外部宛の設定が入り込む)。
pa__child_env() {
  local host="$1"
  local ollama_dir=""
  if has_cmd "$OLLAMA_BIN"; then ollama_dir="$(dirname "$(command -v "$OLLAMA_BIN")")"; fi
  printf 'PATH=%s\n' "${PA_CHILD_PATH:-${ollama_dir:+$ollama_dir:}/usr/local/bin:/usr/bin:/bin}"
  printf 'HOME=%s\n' "${HOME:-/tmp}"
  printf 'LANG=C.UTF-8\n'
  printf 'TMPDIR=%s\n' "${TMPDIR:-/tmp}"
  printf 'OLLAMA_HOST=%s\n' "$host"
  [[ -n "${OLLAMA_MODELS:-}" ]] && printf 'OLLAMA_MODELS=%s\n' "$OLLAMA_MODELS"
  # 明示的に許可した場合のみ追加 (既定は空 = クラウドのトークン等を渡さない)
  if [[ -n "${CCSU_PRIVATE_AI_EXTRA_ENV:-}" ]]; then
    local k
    for k in ${CCSU_PRIVATE_AI_EXTRA_ENV//,/ }; do
      [[ -n "${!k:-}" ]] && printf '%s=%s\n' "$k" "${!k}"
    done
  fi
  return 0
}

pa__host() { pa__cfg '.host' '127.0.0.1:11434'; }

pa__ready() {
  has_cmd "$OLLAMA_BIN" || return 1
  local host; host="$(pa__host)"
  pa__host_allowed "$host" || return 1
  "$OLLAMA_BIN" list >/dev/null 2>&1 || return 1
  return 0
}

cmd_check() {
  local host; host="$(pa__host)"
  local ollama_present=false host_ok=false serve_ok=false
  has_cmd "$OLLAMA_BIN" && ollama_present=true
  pa__host_allowed "$host" && host_ok=true
  if $ollama_present; then "$OLLAMA_BIN" list >/dev/null 2>&1 && serve_ok=true; fi
  local models='[]'
  if $serve_ok; then models="$("$OLLAMA_BIN" list 2>/dev/null | tail -n +2 | awk '{print $1}' | jq -R -s -c 'split("\n") | map(select(. != ""))')"; fi
  jq -cn --arg schema "claudeos.private-ai-check/v1" \
    --arg host "$host" --argjson ollama "$ollama_present" --argjson host_ok "$host_ok" \
    --argjson serving "$serve_ok" --argjson models "$models" \
    --argjson allowlist "$(pa__cfg_json '.models')" \
    '{schema:$schema, host:$host, ollama_present:$ollama, host_is_loopback_allowlisted:$host_ok,
      serving:$serving, installed_models:$models, allowed_models:$allowlist,
      runnable:($ollama and $host_ok and $serving),
      next: (if ($ollama and $host_ok and $serving) then "ready" else "ollama serve を起動し、allowlist のモデルを取得してください" end)}'
  $ollama_present && $host_ok && $serve_ok
}

cmd_models() {
  has_cmd "$OLLAMA_BIN" || { log_error "ollama がありません (実行不可)"; return 3; }
  OLLAMA_HOST="$(pa__host)" "$OLLAMA_BIN" list
}

cmd_run() {
  local model="" prompt_file="" timeout_s="" as_json=0
  while (( $# )); do
    case "$1" in
      --model)       model="${2:-}"; shift 2 ;;
      --prompt-file) prompt_file="${2:-}"; shift 2 ;;
      --timeout)     timeout_s="${2:-}"; shift 2 ;;
      --json)        as_json=1; shift ;;
      *) shift ;;
    esac
  done

  [[ -n "$model" ]] || { log_error "private-ai: --model は必須です"; return 2; }
  [[ -n "$prompt_file" && -f "$prompt_file" ]] || { log_error "private-ai: --prompt-file が必要です"; return 2; }
  local host; host="$(pa__host)"
  [[ -n "$timeout_s" ]] || timeout_s="$(pa__cfg '.timeout_seconds' '120')"

  # 1. 宛先は loopback のみ
  if ! pa__host_allowed "$host"; then
    log_error "private-ai: 許可されていないホストです (loopback のみ): $host"
    return 3
  fi
  # 2. モデルは allowlist のみ
  if ! pa__model_allowed "$model"; then
    log_error "private-ai: allowlist 外のモデルです: $model (config/private-ai.json の models を更新してください)"
    return 3
  fi
  # 3. 実行環境
  if ! pa__ready; then
    log_error "private-ai: 実行できません (ollama 未導入 or 未起動)。private-ai.sh check で確認してください"
    return 3
  fi
  # 4. 入力長
  local max_bytes prompt_bytes
  max_bytes="$(pa__cfg '.max_prompt_bytes' '32768')"
  prompt_bytes="$(wc -c < "$prompt_file" | tr -d ' ')"
  if (( prompt_bytes > max_bytes )); then
    log_error "private-ai: プロンプトが大きすぎます (${prompt_bytes} > ${max_bytes} bytes)"
    return 2
  fi

  # 5. 最小環境で実行 (外部ホストの設定・トークンを子へ渡さない)
  local out_file rc=0
  out_file="$(mktemp "${TMPDIR:-/tmp}/private-ai-out.XXXXXX")"
  local env_args=()
  while IFS= read -r kv; do [[ -n "$kv" ]] && env_args+=("$kv"); done < <(pa__child_env "$host")

  local started; started="$(date +%s)"
  env -i "${env_args[@]}" timeout "$timeout_s" "$OLLAMA_BIN" run "$model" < "$prompt_file" > "$out_file" 2>&1 || rc=$?
  local dur=$(( $(date +%s) - started ))

  local status="ok"; (( rc == 0 )) || status="error"
  pa__log "$(jq -cn --arg at "$(pa__iso)" --arg model "$model" --arg host "$host" \
    --argjson prompt_bytes "$prompt_bytes" --argjson exit_code "$rc" --argjson duration_s "$dur" \
    --arg status "$status" --arg prompt_file "$prompt_file" \
    '{at:$at, event:"local_inference", model:$model, host:$host, prompt_bytes:$prompt_bytes,
      exit_code:$exit_code, duration_s:$duration_s, status:$status, prompt_file:$prompt_file}')"

  if (( rc != 0 )); then
    log_error "private-ai: 推論に失敗しました (rc=$rc)"; return 1
  fi
  if (( as_json )); then
    jq -cn --arg model "$model" --argjson duration_s "$dur" --argjson prompt_bytes "$prompt_bytes" \
      --rawfile output "$out_file" --arg host "$host" \
      '{schema:"claudeos.private-ai-result/v1", model:$model, host:$host, prompt_bytes:$prompt_bytes,
        duration_s:$duration_s, output:$output}'
  else
    cat "$out_file"
  fi
  rm -f "$out_file"
}

cmd_usage() {
  local tail_n=0
  while (( $# )); do
    case "$1" in --tail) tail_n="${2:-0}"; shift 2 ;; *) shift ;; esac
  done
  local f; f="${CLAUDEOS_PRIVATE_AI_LOG:-$(pa__cfg '.log_file' "$CCSU_HOME/logs/private-ai.jsonl")}"
  f="${f/#\~/$HOME}"
  [[ -f "$f" ]] || { log_info "実行記録はまだありません: $f"; return 0; }
  if (( tail_n > 0 )); then tail -n "$tail_n" "$f"; else cat "$f"; fi
}

case "${1:-}" in
  check)  cmd_check ;;
  models) cmd_models ;;
  run)    shift; cmd_run "$@" ;;
  usage)  shift; cmd_usage "$@" ;;
  ""|-h|--help|help) usage ;;
  *) log_error "不明なサブコマンド: ${1:-}"; usage; exit 2 ;;
esac
