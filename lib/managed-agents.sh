#!/usr/bin/env bash
# ============================================================
# managed-agents.sh — Claude Managed Agents 設定契約の読み取り (Linux native)
#
# 役割: Goal Router (lib/goal-router.sh goal_router__evidence) が期待する契約
#       ma__load / ma__validate / MA_MODE / MA_REASON を提供する薄い層。
#       API 呼び出し・予算判定・台帳は scripts/tools/managed-agents.js (adapter) が担い、
#       ここでは再実装しない。
#
# 設計:
#   - 副作用なし: source と ma__load はネットワーク・API キー・ファイル生成に一切触れない。
#     全起動経路 (L1 / S1 / T1 / cron / Supervisor) の evidence 収集で source されるため。
#   - Local 主系: ma__validate は「セッション全体を Managed で実行してよいか」を返す契約。
#     初期 PoC ではタスク単位の補完だけを許すので、設定が有効でも常に非 0 (= execution_plane=local)。
#     Managed が補完先として使えるかは ma__available と MA_REASON で伝える。
#     タスク単位の振り分けは Agent Router (scripts/tools/agent-router.js) の役割。
#
# 前提: jq (無ければ利用不可として扱う)。common.sh は任意 (log_* が無くても動く)。
# ============================================================

[[ -n "${_CCSU_MANAGED_AGENTS_LOADED:-}" ]] && return 0
_CCSU_MANAGED_AGENTS_LOADED=1

_ccsu_ma_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MA_MODE="missing"
MA_REASON="config-missing"
MA_ENABLED="false"
MA_CONFIG_PATH=""

# ma__config_path — 設定ファイルのパス (CLAUDEOS_MANAGED_AGENTS_CONFIG で上書き可。テスト密閉化用)
ma__config_path() {
  printf '%s' "${CLAUDEOS_MANAGED_AGENTS_CONFIG:-$_ccsu_ma_dir/../config/managed-agents.json}"
}

# ma__tool — adapter (node) のパス
ma__tool() { printf '%s' "$_ccsu_ma_dir/../scripts/tools/managed-agents.js"; }

# ------------------------------------------------------------
# ma__load
#   設定を読み MA_MODE / MA_ENABLED / MA_REASON を設定する。常に 0 を返す。
#   MA_MODE: missing | invalid | disabled | dry-run | live
# ------------------------------------------------------------
ma__load() {
  MA_CONFIG_PATH="$(ma__config_path)"
  MA_MODE="missing"; MA_ENABLED="false"; MA_REASON="config-missing"
  [[ -f "$MA_CONFIG_PATH" ]] || return 0
  if ! command -v jq >/dev/null 2>&1; then
    MA_MODE="invalid"; MA_REASON="jq-missing"; return 0
  fi
  local parsed
  parsed="$(jq -r '[(.enabled == true | tostring), (.mode // "disabled" | tostring)] | @tsv' "$MA_CONFIG_PATH" 2>/dev/null)" || {
    MA_MODE="invalid"; MA_REASON="config-unreadable"; return 0
  }
  local enabled mode
  IFS=$'\t' read -r enabled mode <<<"$parsed"
  MA_ENABLED="${enabled:-false}"
  case "$mode" in
    disabled|dry-run|live) MA_MODE="$mode" ;;
    *) MA_MODE="invalid"; MA_REASON="mode-invalid"; return 0 ;;
  esac
  if [[ "$MA_ENABLED" != "true" ]]; then
    MA_REASON="not-enabled"
  elif [[ "$MA_MODE" == "disabled" ]]; then
    MA_REASON="mode-disabled"
  else
    MA_REASON="local-primary:managed-complement-$MA_MODE"
  fi
  return 0
}

# ------------------------------------------------------------
# ma__available
#   Managed Agents をタスク単位の補完先として使える設定か (0=使える)。
#   予算・認証・重複の最終判定は adapter の route / session create が行う。
# ------------------------------------------------------------
ma__available() {
  [[ "$MA_ENABLED" == "true" ]] && [[ "$MA_MODE" == "dry-run" || "$MA_MODE" == "live" ]]
}

# ------------------------------------------------------------
# ma__validate
#   Goal Router 契約: 0 を返すと execution_plane=managed (セッション全体を Managed で実行)。
#   初期 PoC は Local 主系のため常に 1。Managed はタスク単位の補完としてのみ使う。
# ------------------------------------------------------------
ma__validate() {
  return 1
}

# ------------------------------------------------------------
# ma__cli <args...>
#   adapter を呼ぶ。API キー以外の秘密 (SMTP 等) を node プロセスへ渡さないよう、
#   必要な環境変数だけを allowlist で引き継ぐ。
# ------------------------------------------------------------
ma__cli() {
  command -v node >/dev/null 2>&1 || { printf 'node が見つかりません\n' >&2; return 127; }
  local -a pass=("PATH=${PATH:-/usr/bin:/bin}" "HOME=${HOME:-}")
  local name
  for name in ANTHROPIC_API_KEY CLAUDEOS_MANAGED_AGENTS_CONFIG CLAUDEOS_HOME LANG LC_ALL TZ; do
    [[ -n "${!name:-}" ]] && pass+=("$name=${!name}")
  done
  # adapter 専用の変数 (CLAUDEOS_MA_*: 状態ディレクトリ、GitHub トークン。config の tokenEnv もこの接頭辞に限定)
  while IFS= read -r name; do
    [[ -n "${!name:-}" ]] && pass+=("$name=${!name}")
  done < <(compgen -v CLAUDEOS_MA_)
  env -i "${pass[@]}" node "$(ma__tool)" "$@"
}
