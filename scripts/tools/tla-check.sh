#!/usr/bin/env bash
# ============================================================
# tla-check.sh — TLA+ モデル検査 (TLC) ランナー
#
# 役割: formal/specs/*.tla を TLC で機械検証する。jar はキャッシュし、
#       ネットワークが無い環境では --no-download で明示的に失敗させる
#       (取得できていないのに「検証した」と言わないため)。
#
# 使い方:
#   tla-check.sh run [path/to/spec.tla] [--config FILE] [--no-download] [--dry-run] [--json]
#   tla-check.sh check                              # 前提 (java / jar) の確認だけ
#
# 既定 spec: formal/specs/run_ledger.tla (config は同名 .cfg)
# jar: ${CCSU_FORMAL_CACHE:-~/.cache/claudeos/formal}/tla2tools.jar
#      CCSU_TLA_JAR / TLA_JAR で上書き可。CCSU_TLA_JAR_SHA256 があれば検証する
#
# 終了コード: 0 検証成功 / 1 反例あり (検証失敗) / 2 引数・前提エラー / 3 jar 取得不可
# ============================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/../../lib/common.sh"
# shellcheck source=lib/json.sh
source "$SCRIPT_DIR/../../lib/json.sh"

require_cmd jq

TLA_JAR_URL="https://github.com/tlaplus/tlaplus/releases/latest/download/tla2tools.jar"

usage() { sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

tlc__cache_dir() { printf '%s' "${CCSU_FORMAL_CACHE:-$HOME/.cache/claudeos/formal}"; }
tlc__jar() {
  local forced="${CCSU_TLA_JAR:-${TLA_JAR:-}}"
  if [[ -n "$forced" ]]; then printf '%s' "$forced"; return 0; fi
  printf '%s/tla2tools.jar' "$(tlc__cache_dir)"
}

tlc__ensure_java() {
  has_cmd java || { log_error "java がありません (TLC の実行に必要)"; return 2; }
  return 0
}

tlc__ensure_jar() {
  local download="$1" jar; jar="$(tlc__jar)"
  [[ -s "$jar" ]] && return 0
  if [[ "$download" != "1" ]]; then
    log_error "tla2tools.jar がありません: $jar (--no-download 指定のため取得しません)"
    return 3
  fi
  has_cmd curl || { log_error "curl がありません (jar 取得に必要)"; return 3; }
  mkdir -p "$(dirname "$jar")"
  log_info "tla2tools.jar を取得します: $TLA_JAR_URL" >&2
  if ! curl -fsSL --max-time 120 -o "$jar.tmp" "$TLA_JAR_URL"; then
    rm -f "$jar.tmp"; log_error "tla2tools.jar の取得に失敗しました (ネットワーク不可?)"; return 3
  fi
  mv -f "$jar.tmp" "$jar"
  if [[ -n "${CCSU_TLA_JAR_SHA256:-}" ]]; then
    local got; got="$(sha256sum "$jar" | cut -d' ' -f1)"
    if [[ "$got" != "$CCSU_TLA_JAR_SHA256" ]]; then
      log_error "tla2tools.jar の sha256 が一致しません (取得物を破棄します)"
      rm -f "$jar"; return 3
    fi
  fi
  log_ok "取得しました: $jar" >&2
  return 0
}

cmd_check() {
  local jar; jar="$(tlc__jar)"
  jq -cn --arg jar "$jar" --argjson java "$(has_cmd java && printf true || printf false)" \
    --argjson jar_present "$( [[ -s "$jar" ]] && printf true || printf false )" \
    --arg java_version "$(java -version 2>&1 | head -1 || true)" \
    '{jar:$jar, jar_present:$jar_present, java:$java, java_version:$java_version}'
  has_cmd java
}

cmd_run() {
  local spec="" config="" download=1 dry=0 as_json=0
  while (( $# )); do
    case "$1" in
      --config)      config="${2:-}"; shift 2 ;;
      --no-download) download=0; shift ;;
      --dry-run)     dry=1; shift ;;
      --json)        as_json=1; shift ;;
      -*)            log_error "不明なオプション: $1"; return 2 ;;
      *)             spec="$1"; shift ;;
    esac
  done
  [[ -n "$spec" ]] || spec="$CCSU_ROOT/formal/specs/run_ledger.tla"
  [[ -f "$spec" ]] || { log_error "spec がありません: $spec"; return 2; }
  [[ -n "$config" ]] || config="${spec%.tla}.cfg"
  [[ -f "$config" ]] || { log_error "config がありません: $config"; return 2; }

  tlc__ensure_java || return $?
  if (( dry )); then
    jq -cn --arg jar "$(tlc__jar)" --arg spec "$spec" --arg config "$config" \
      --arg cmd "java -cp $(tlc__jar) tlc2.TLC -config $config -workers auto $spec" \
      '{dry_run:true, jar:$jar, spec:$spec, config:$config, cmd:$cmd}'
    return 0
  fi
  tlc__ensure_jar "$download" || return $?

  local jar workdir rc=0
  jar="$(tlc__jar)"
  workdir="$(dirname "$(realpath "$spec")")"
  local log_file; log_file="$(mktemp "${TMPDIR:-/tmp}/tlc.XXXXXX.log")"
  local started; started="$(date +%s)"
  ( cd "$workdir" && java -cp "$jar" tlc2.TLC -config "$(basename "$config")" -workers auto -deadlock "$(basename "$spec")" ) \
    > "$log_file" 2>&1 || rc=$?
  local dur=$(( $(date +%s) - started ))

  local states distinct result
  states="$(grep -oE '[0-9,]+ states generated' "$log_file" | head -1 | sed 's/ states generated//' | tr -d ',' || true)"
  distinct="$(grep -oE '[0-9,]+ distinct states found' "$log_file" | head -1 | sed 's/ distinct states found//' | tr -d ',' || true)"
  # 3 値で判定する。解析失敗を「反例あり」と混同しない (どちらも成功と偽らない)
  if grep -qE 'Parsing or semantic analysis failed|AbortException|Error: Parsing' "$log_file"; then
    result="error"
  elif grep -qE 'is violated|violates the temporal property|Error: Invariant|Error: The following behavior' "$log_file"; then
    result="violation"
  elif grep -qE 'No error has been found|Model checking completed' "$log_file"; then
    result="verified"
  else
    result="error"
  fi
  case "$result" in
    verified) rc=0 ;;
    violation) rc=1 ;;
    *) rc=2 ;;
  esac

  if (( as_json )); then
    jq -cn --arg spec "$spec" --arg config "$config" --arg result "$result" \
      --argjson states "${states:-0}" --argjson distinct "${distinct:-0}" --argjson duration_s "$dur" \
      --arg log "$log_file" --rawfile tail "$log_file" \
      '{schema:"claudeos.formal-check/v1", spec:$spec, config:$config, result:$result,
        states_generated:$states, distinct_states:$distinct, duration_s:$duration_s, log:$log,
        tail:($tail | split("\n") | .[-12:] | join("\n"))}'
  else
    printf '%s\n' "$(tail -3 "$log_file")"
    log_info "spec=$spec result=$result states=${states:-?} distinct=${distinct:-?} (${dur}s, log: $log_file)" >&2
  fi
  return $rc
}

case "${1:-}" in
  run)   shift; cmd_run "$@" ;;
  check) cmd_check ;;
  ""|-h|--help|help) usage ;;
  *) log_error "不明なサブコマンド: ${1:-}"; usage; exit 2 ;;
esac
