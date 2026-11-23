#!/usr/bin/env bash
# ============================================================
# release-promote.sh — リリース成果物を staging/production へ切り替える CLI
#
# 使い方:
#   release-promote.sh --env staging|production --release <40hex|dir> [options]
#     --env staging|production  昇格先 (必須)
#     --release <40hex|dir>     release dir。40hex は $CLAUDEOS_HOME/releases/<sha> を指す
#     --dry-run                 何も書き換えず、検証結果と実行計画を表示
#     --no-restart              systemctl --user restart を行わない
#     --rollback                現在の symlink を previous target へ戻す (<--release> 不要)
#     --json                    最終行に 1 行 JSON を出す
#     --port N                  想定 port を上書き (health の宛先。既定 staging=3742 / production=3740)
#     -h, --help                このヘルプ
#
# 処理:
#   1) release dir 解決  2) manifest 検証  3) 全ファイル sha256 と tree_sha256 の再計算
#   4) $CLAUDEOS_HOME/releases/<env>-current を相対 symlink で原子的に張り替え (旧 target は previous へ)
#   5) systemctl --user restart <unit>  6) /api/health が ok:true になるまで最大 20 秒リトライ
#   7) 失敗時は symlink を旧 target へ戻して再 restart  8) promotions.jsonl へ 1 行追記
#
# 安全弁:
#   - 整合性不一致 (INTEGRITY_MISMATCH) では切り替えない。
#   - production 昇格は staging-current と同一 tree_sha256 を要求 (STAGING_NOT_VERIFIED)。
#   - `--force` のような迂回オプションは意図的に存在しない (指定しても引数エラー)。
#
# exit: 0 成功 / 1 実行エラー (自動ロールバック含む) / 2 引数エラー
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
# shellcheck source=lib/release-promote.sh
source "$SCRIPT_DIR/../lib/release-promote.sh"

usage() {
  cat <<'EOF'
Usage: release-promote.sh --env staging|production --release <40hex|dir> [options]

  --env staging|production  昇格先 (必須)
  --release <40hex|dir>     release dir (40hex は $CLAUDEOS_HOME/releases/<sha>)
  --dry-run                 何も書き換えず検証結果と計画を表示
  --no-restart              systemctl --user restart を行わない
  --rollback                現在の symlink を previous target へ戻す
  --json                    最終行に 1 行 JSON を出力
  --port N                  想定 port を上書き (health の宛先)
  -h, --help                このヘルプ

既定: staging -> claudeos-web-startup-stg.service (port 3742)
      production -> claudeos-web-startup.service (port 3740)

production 昇格は、staging-current が同一 tree_sha256 であることを要求します
(未検証は STAGING_NOT_VERIFIED で拒否)。--force は提供しません。
EOF
}

main() {
  local env_arg="" release_arg="" port_arg=""
  local wants_json=0 rc=0 a

  # --json は引数検証より先に知りたい (引数エラーも JSON で返すため)
  for a in "$@"; do
    [[ "$a" == "--json" ]] && wants_json=1
  done

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --env)
        [[ $# -ge 2 ]] || { log_error "--env には値が必要です"; return 2; }
        env_arg="$2"; shift 2 ;;
      --release)
        [[ $# -ge 2 ]] || { log_error "--release には値が必要です"; return 2; }
        release_arg="$2"; shift 2 ;;
      --port)
        [[ $# -ge 2 ]] || { log_error "--port には値が必要です"; return 2; }
        port_arg="$2"; shift 2 ;;
      --dry-run)    RP_DRY_RUN=1; shift ;;
      --no-restart) RP_NO_RESTART=1; shift ;;
      --rollback)   RP_ROLLBACK=1; shift ;;
      --json)       RP_JSON=1; shift ;;
      --force)
        log_error "--force は提供しません (整合性と staging 検証を迂回できません)"
        if (( wants_json )); then
          rp__json_error "ARG_INVALID" "--force は提供しません"
        fi
        return 2 ;;
      -h|--help) usage; return 0 ;;
      --*) log_error "不明な引数: $1"; return 2 ;;
      *)
        log_error "不明な引数: $1"
        if (( wants_json )); then
          rp__json_error "ARG_INVALID" "不明な引数: $1"
        fi
        return 2 ;;
    esac
  done

  # --- env 検証 ---
  case "$env_arg" in
    staging|production) ;;
    "")
      log_error "--env staging|production は必須です"
      if (( wants_json )); then rp__json_error "ARG_INVALID" "--env staging|production は必須です"; fi
      return 2 ;;
    *)
      log_error "不正な --env: $env_arg (staging|production)"
      if (( wants_json )); then rp__json_error "ARG_INVALID" "不正な --env: $env_arg"; fi
      return 2 ;;
  esac
  RP_ENV="$env_arg"
  RP_UNIT="$(rp__env_unit "$RP_ENV")"
  RP_PORT="$(rp__env_port "$RP_ENV")"

  # --- port 検証 ---
  if [[ -n "$port_arg" ]]; then
    if [[ ! "$port_arg" =~ ^[0-9]+$ ]] || (( 10#$port_arg < 1 || 10#$port_arg > 65535 )); then
      log_error "--port は 1-65535 の数値です: $port_arg"
      if (( wants_json )); then rp__json_error "ARG_INVALID" "--port は 1-65535 の数値です: $port_arg"; fi
      return 2
    fi
    RP_PORT="$port_arg"
  fi

  # --- CLAUDEOS_HOME の安全確認 (実ホーム以外へ書かないため) ---
  local home; home="$(rp__home)"
  if [[ "$home" != /* || "$home" == "/" ]]; then
    log_error "CLAUDEOS_HOME は絶対パスで / 以外を指定してください: $home"
    if (( wants_json )); then rp__json_error "ARG_INVALID" "CLAUDEOS_HOME が不正です: $home"; fi
    return 2
  fi

  # --- 必須コマンド ---
  require_cmd jq
  require_cmd sha256sum
  require_cmd realpath
  if (( ! RP_NO_RESTART )) && (( ! RP_DRY_RUN )); then
    require_cmd "$(rp__systemctl_bin)" "systemctl を CCSU_SYSTEMCTL_BIN で差し替えできます"
  fi

  # --- release dir 解決 (--rollback は不要) ---
  if (( RP_ROLLBACK )); then
    if [[ -n "$release_arg" ]]; then
      log_error "--rollback と --release は同時に指定できません"
      if (( wants_json )); then rp__json_error "ARG_INVALID" "--rollback と --release は同時に指定できません"; fi
      return 2
    fi
  else
    if [[ -z "$release_arg" ]]; then
      log_error "--release は必須です"
      if (( wants_json )); then rp__json_error "ARG_INVALID" "--release は必須です"; fi
      return 2
    fi
    if ! rp__resolve_release_dir "$release_arg"; then
      if (( wants_json )); then rp__json_error "$RP_ERR_CODE" "$RP_ERR_MSG"; fi
      return 2
    fi
  fi

  # --- 実行 ---
  if (( RP_ROLLBACK )); then
    rp__rollback || rc=$?
  else
    rp__promote || rc=$?
  fi

  if (( rc != 0 )); then
    # 自動ロールバックした場合は「切替結果」として ok:true + result=ROLLED_BACK を返す
    # (exit 1 は失敗を表す。JSON の形は契約どおり)
    if [[ "${RP_RESULT:-}" == "ROLLED_BACK" ]]; then
      if (( RP_JSON )); then
        rp__json_success "ROLLED_BACK"
      fi
    else
      if (( RP_JSON )); then
        rp__json_error "${RP_ERR_CODE:-INTERNAL_ERROR}" "${RP_ERR_MSG:-不明なエラー}"
      fi
    fi
    return "$rc"
  fi

  if (( RP_JSON )); then
    rp__json_success "${RP_RESULT:-PROMOTED}"
  fi
  return 0
}

rc=0
main "$@" || rc=$?
exit "$rc"
