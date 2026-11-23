#!/usr/bin/env bash
# ============================================================
# post-deploy-smoke.sh — 配備後の健全性を 1 コマンドで検証する（読み取り専用）
#
# 使い方:
#   post-deploy-smoke.sh [--env production|staging] [--json] [--public-url URL]
#     --env production|staging  対象環境（既定 production）
#     --json                    最終行に 1 行 JSON を出す
#     --public-url URL          公開 URL を上書き（既定 https://claude-startuptools.mirai-dx-platform.com/）
#     -h, --help                このヘルプ
#
# 検査項目（各 PASS / FAIL / WARN / SKIP を記録）:
#   1. health        http://127.0.0.1:<port>/api/health が 200 かつ ok:true
#                    commit が空なら WARN（health に commit を載せる変更が未マージのため FAIL にしない）
#   2. web root      GET /  が 200
#   3. dashboard     production: 3737 /api/health が 200
#                    staging   : 3743 /api/health が 200（未起動なら SKIP）
#   4. terminal      production のみ: 3741 /terminal/ が 200
#   5. public url    公開 URL が 200 か 302（Cloudflare Access は 302 を正常扱い）
#   6. promotions    $CLAUDEOS_HOME/releases/promotions.jsonl の最終行が 30 日以内
#                    （台帳なし・解釈不能・古い場合は WARN。配備の成否ではなく鮮度の助言）
#   7. systemd unit  systemctl --user show の ActiveState が active、NRestarts を報告
#                    NRestarts >= CCSU_SMOKE_MAX_RESTARTS（既定 3）は WARN
#
# 環境変数:
#   CCSU_CURL_BIN                curl 実体（既定 curl。bats スタブ差し替え用）
#   CCSU_SYSTEMCTL_BIN           systemctl 実体（既定 systemctl。bats スタブ差し替え用）
#   CLAUDEOS_HOME                ClaudeOS ホーム（既定 ~/.claudeos。promotions 台帳の読み先）
#   CCSU_SMOKE_TIMEOUT           HTTP 1 リクエストのタイムアウト秒（既定 5）
#   CCSU_SMOKE_MAX_RESTARTS      NRestarts の WARN しきい値（既定 3）
#   CCSU_SMOKE_PROMOTIONS_MAX_AGE_DAYS  台帳鮮度の許容日数（既定 30）
#
# 安全弁:
#   - **読み取りのみ**。systemd の start/stop/restart、エンドポイント変更、状態ファイルの
#     書き込みを一切行わない。本番 3740 が落ちていても FAIL として報告するだけ。
#   - 検査対象は loopback と公開 URL への GET のみ。
#
# exit: 0 FAIL 0 / 1 FAIL あり / 2 引数エラー
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/../../lib/common.sh"

SMOKE_JSON=0
SMOKE_ENV="production"
SMOKE_PUBLIC_URL="https://claude-startuptools.mirai-dx-platform.com/"
SMOKE_HTTP_TIMEOUT="${CCSU_SMOKE_TIMEOUT:-5}"
SMOKE_MAX_RESTARTS="${CCSU_SMOKE_MAX_RESTARTS:-3}"
SMOKE_PROMOTIONS_MAX_AGE_DAYS="${CCSU_SMOKE_PROMOTIONS_MAX_AGE_DAYS:-30}"

# 集計: checks = 実行した検査数（PASS + FAIL + WARN。SKIP は数えない）
SMOKE_CHECKS=0
SMOKE_FAILED=0
SMOKE_WARNINGS=0
SMOKE_FAIL_LIST=""
SMOKE_WARN_LIST=""

usage() {
  cat <<'EOF'
Usage: post-deploy-smoke.sh [--env production|staging] [--json] [--public-url URL]

  --env production|staging  対象環境 (既定: production)
  --json                    最終行に 1 行 JSON を出力
  --public-url URL          公開 URL を上書き
  -h, --help                このヘルプ

検査: health / web root / dashboard / terminal / 公開 URL / promotions 台帳 / systemd unit
exit: 0 FAIL 0 / 1 FAIL あり / 2 引数エラー

本スクリプトは読み取り専用です。unit の起動・再起動は一切行いません。
production: port 3740, unit claudeos-web-startup.service
staging   : port 3742, unit claudeos-web-startup-stg.service
EOF
}

# ------------------------------------------------------------
# 実行環境の差し替え（bats スタブ用）
# ------------------------------------------------------------
smoke__curl_bin()      { printf '%s' "${CCSU_CURL_BIN:-curl}"; }
smoke__systemctl_bin() { printf '%s' "${CCSU_SYSTEMCTL_BIN:-systemctl}"; }

smoke__env_port() {
  case "$1" in
    production) printf '%s' "3740" ;;
    staging)    printf '%s' "3742" ;;
    *) return 1 ;;
  esac
}

smoke__env_unit() {
  case "$1" in
    production) printf '%s' "claudeos-web-startup.service" ;;
    staging)    printf '%s' "claudeos-web-startup-stg.service" ;;
    *) return 1 ;;
  esac
}

# smoke__require <cmd> [hint] — 必須コマンド。--json 契約を壊さないよう die は使わない
smoke__require() {
  local cmd="$1" hint="${2:-}"
  has_cmd "$cmd" && return 0
  log_error "必須コマンドが見つかりません: $cmd${hint:+ ($hint)}"
  SMOKE_FAILED=$((SMOKE_FAILED + 1))
  SMOKE_FAIL_LIST="${SMOKE_FAIL_LIST:+$SMOKE_FAIL_LIST,}require:$cmd"
  if (( SMOKE_JSON )); then smoke__json; fi
  return 1
}

# ------------------------------------------------------------
# 検査の記録
# ------------------------------------------------------------
smoke__record() {
  local status="$1" label="$2" detail="${3:-}"
  local suffix=""
  [[ -n "$detail" ]] && suffix=" — $detail"

  case "$status" in
    PASS)
      SMOKE_CHECKS=$((SMOKE_CHECKS + 1))
      log_ok "${label}${suffix}"
      ;;
    FAIL)
      SMOKE_CHECKS=$((SMOKE_CHECKS + 1))
      SMOKE_FAILED=$((SMOKE_FAILED + 1))
      SMOKE_FAIL_LIST="${SMOKE_FAIL_LIST:+$SMOKE_FAIL_LIST,}${label}"
      log_error "${label}${suffix}"
      ;;
    WARN)
      SMOKE_CHECKS=$((SMOKE_CHECKS + 1))
      SMOKE_WARNINGS=$((SMOKE_WARNINGS + 1))
      SMOKE_WARN_LIST="${SMOKE_WARN_LIST:+$SMOKE_WARN_LIST,}${label}"
      log_warn "${label}${suffix}"
      ;;
    SKIP)
      log_info "${label}${suffix} [SKIP]"
      ;;
    *)
      log_error "内部エラー: 不明な検査ステータス: $status"
      return 1
      ;;
  esac
  return 0
}

# ------------------------------------------------------------
# HTTP ヘルパ（curl は CCSU_CURL_BIN で差し替え可能）
# ------------------------------------------------------------
# smoke__http_code <url> — ステータスコード。接続不可は 000
smoke__http_code() {
  local url="$1" code=""
  code="$("$(smoke__curl_bin)" -sS -o /dev/null -w '%{http_code}' \
    --max-time "$SMOKE_HTTP_TIMEOUT" "$url" 2>/dev/null)" || true
  [[ -n "$code" ]] || code="000"
  printf '%s' "$code"
}

# smoke__body <url> — レスポンスボディ（失敗時は空）
smoke__body() {
  local url="$1" body=""
  body="$("$(smoke__curl_bin)" -fsS --max-time "$SMOKE_HTTP_TIMEOUT" "$url" 2>/dev/null)" || true
  printf '%s' "$body"
}

# ------------------------------------------------------------
# 1. health — 200 かつ ok:true。commit 空は WARN
# ------------------------------------------------------------
smoke__check_health() {
  local port="$1" url code body commit
  url="http://127.0.0.1:${port}/api/health"
  code="$(smoke__http_code "$url")"

  if [[ "$code" != "200" ]]; then
    smoke__record FAIL "health" "GET $url -> $code (200 期待)"
    return 0
  fi

  body="$(smoke__body "$url")"
  if ! printf '%s' "$body" | jq -e '.ok == true' >/dev/null 2>&1; then
    smoke__record FAIL "health" "HTTP 200 だが .ok != true"
    return 0
  fi

  commit="$(printf '%s' "$body" | jq -r '.commit // empty' 2>/dev/null || true)"
  if [[ -z "$commit" ]]; then
    smoke__record WARN "health" "HTTP 200, ok:true / commit が空 (health に commit を載せる変更が未反映)"
    return 0
  fi

  smoke__record PASS "health" "HTTP 200, ok:true, commit=$commit"
  return 0
}

# ------------------------------------------------------------
# 2. web root — GET / が 200
# ------------------------------------------------------------
smoke__check_root() {
  local port="$1" url code
  url="http://127.0.0.1:${port}/"
  code="$(smoke__http_code "$url")"
  if [[ "$code" == "200" ]]; then
    smoke__record PASS "web root" "GET $url -> 200"
  else
    smoke__record FAIL "web root" "GET $url -> $code (200 期待)"
  fi
  return 0
}

# ------------------------------------------------------------
# 3. dashboard — production: 3737。staging: 3743 があれば検査、無ければ SKIP
# ------------------------------------------------------------
smoke__check_dashboard() {
  local env_arg="$1" url code
  if [[ "$env_arg" == "production" ]]; then
    url="http://127.0.0.1:3737/api/health"
    code="$(smoke__http_code "$url")"
    if [[ "$code" == "200" ]]; then
      smoke__record PASS "dashboard" "GET $url -> 200"
    else
      smoke__record FAIL "dashboard" "GET $url -> $code (200 期待)"
    fi
    return 0
  fi

  url="http://127.0.0.1:3743/api/health"
  code="$(smoke__http_code "$url")"
  if [[ "$code" == "000" ]]; then
    smoke__record SKIP "dashboard" "staging dashboard (3743) が未起動"
  elif [[ "$code" == "200" ]]; then
    smoke__record PASS "dashboard" "GET $url -> 200"
  else
    smoke__record FAIL "dashboard" "GET $url -> $code (200 期待)"
  fi
  return 0
}

# ------------------------------------------------------------
# 4. terminal — production のみ 3741/terminal/ が 200
# ------------------------------------------------------------
smoke__check_terminal() {
  local env_arg="$1" url code
  if [[ "$env_arg" != "production" ]]; then
    smoke__record SKIP "terminal" "production のみ対象"
    return 0
  fi

  url="http://127.0.0.1:3741/terminal/"
  code="$(smoke__http_code "$url")"
  if [[ "$code" == "200" ]]; then
    smoke__record PASS "terminal" "GET $url -> 200"
  else
    smoke__record FAIL "terminal" "GET $url -> $code (200 期待)"
  fi
  return 0
}

# ------------------------------------------------------------
# 5. public url — 200 か 302（Cloudflare Access）
# ------------------------------------------------------------
smoke__check_public_url() {
  local code
  code="$(smoke__http_code "$SMOKE_PUBLIC_URL")"
  case "$code" in
    200|302)
      smoke__record PASS "public url" "GET $SMOKE_PUBLIC_URL -> $code"
      ;;
    *)
      smoke__record FAIL "public url" "GET $SMOKE_PUBLIC_URL -> $code (200/302 期待)"
      ;;
  esac
  return 0
}

# ------------------------------------------------------------
# 6. promotions 台帳 — 最終行の at が 30 日以内（無ければ WARN）
# ------------------------------------------------------------
smoke__check_promotions() {
  local file last at epoch now age_days
  file="$CCSU_HOME/releases/promotions.jsonl"

  if [[ ! -f "$file" ]]; then
    smoke__record WARN "promotions" "台帳なし: $file (release-promote 未実行の可能性)"
    return 0
  fi

  last="$(tail -n 1 "$file" 2>/dev/null || true)"
  if [[ -z "$last" ]]; then
    smoke__record WARN "promotions" "台帳が空: $file"
    return 0
  fi

  at="$(printf '%s' "$last" | jq -r '.at // empty' 2>/dev/null || true)"
  if [[ -z "$at" ]]; then
    smoke__record WARN "promotions" "最終行に at が無い: $file"
    return 0
  fi

  if ! epoch="$(date -d "$at" +%s 2>/dev/null)"; then
    smoke__record WARN "promotions" "at を日時として解釈できない: $at"
    return 0
  fi

  now="$(date +%s)"
  age_days=$(( (now - epoch) / 86400 ))
  if (( age_days <= SMOKE_PROMOTIONS_MAX_AGE_DAYS )); then
    smoke__record PASS "promotions" "最終昇格 ${at} (${age_days} 日前)"
  else
    smoke__record WARN "promotions" "最終昇格が ${age_days} 日前 (> ${SMOKE_PROMOTIONS_MAX_AGE_DAYS} 日): $at"
  fi
  return 0
}

# ------------------------------------------------------------
# 7. systemd unit — ActiveState=active、NRestarts を報告
# ------------------------------------------------------------
smoke__check_unit() {
  local unit="$1" bin out active restarts
  bin="$(smoke__systemctl_bin)"

  if ! has_cmd "$bin"; then
    smoke__record FAIL "systemd unit" "systemctl が見つかりません: $bin (CCSU_SYSTEMCTL_BIN で差し替え可)"
    return 0
  fi

  out="$("$bin" --user show "$unit" --property=ActiveState,NRestarts 2>/dev/null)" || out=""
  active="$(printf '%s\n' "$out" | sed -n 's/^ActiveState=//p' | head -n 1)"
  restarts="$(printf '%s\n' "$out" | sed -n 's/^NRestarts=//p' | head -n 1)"

  if [[ -z "$active" ]]; then
    smoke__record FAIL "systemd unit" "$unit の状態を取得できません (未登録か systemctl 失敗)"
    return 0
  fi

  if [[ "$active" != "active" ]]; then
    smoke__record FAIL "systemd unit" "$unit ActiveState=$active (active 期待)"
    return 0
  fi

  if [[ -z "$restarts" ]]; then
    smoke__record WARN "systemd unit" "$unit active だが NRestarts を取得できません"
    return 0
  fi

  if [[ ! "$restarts" =~ ^[0-9]+$ ]]; then
    smoke__record WARN "systemd unit" "$unit active, NRestarts が数値でない: $restarts"
  elif (( restarts >= SMOKE_MAX_RESTARTS )); then
    smoke__record WARN "systemd unit" "$unit active, NRestarts=$restarts (>= $SMOKE_MAX_RESTARTS; 再起動が繰り返されている)"
  else
    smoke__record PASS "systemd unit" "$unit active, NRestarts=$restarts"
  fi
  return 0
}

# ------------------------------------------------------------
# 出力
# ------------------------------------------------------------
smoke__json() {
  local ok="false"
  (( SMOKE_FAILED == 0 )) && ok="true"
  printf '{"ok":%s,"env":"%s","checks":%d,"failed":%d,"warnings":%d}\n' \
    "$ok" "$SMOKE_ENV" "$SMOKE_CHECKS" "$SMOKE_FAILED" "$SMOKE_WARNINGS"
}

main() {
  local a port unit

  # --json は引数検証より先に知りたい
  for a in "$@"; do
    [[ "$a" == "--json" ]] && SMOKE_JSON=1
  done

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --env)
        [[ $# -ge 2 ]] || { log_error "--env には値が必要です"; return 2; }
        SMOKE_ENV="$2"; shift 2 ;;
      --public-url)
        [[ $# -ge 2 ]] || { log_error "--public-url には値が必要です"; return 2; }
        SMOKE_PUBLIC_URL="$2"; shift 2 ;;
      --json)
        SMOKE_JSON=1; shift ;;
      -h|--help)
        usage; return 0 ;;
      --*)
        log_error "不明な引数: $1"; return 2 ;;
      *)
        log_error "不明な引数: $1"; return 2 ;;
    esac
  done

  case "$SMOKE_ENV" in
    production|staging) ;;
    *)
      log_error "不正な --env: $SMOKE_ENV (production|staging)"
      return 2 ;;
  esac

  case "$SMOKE_PUBLIC_URL" in
    http://*|https://*) ;;
    *)
      log_error "--public-url は http(s):// で始まる URL を指定してください: $SMOKE_PUBLIC_URL"
      return 2 ;;
  esac

  if [[ ! "$SMOKE_HTTP_TIMEOUT" =~ ^[0-9]+$ ]] || (( SMOKE_HTTP_TIMEOUT < 1 )); then
    log_error "CCSU_SMOKE_TIMEOUT は 1 以上の整数です: $SMOKE_HTTP_TIMEOUT"
    return 2
  fi

  smoke__require jq || return 1
  smoke__require "$(smoke__curl_bin)" "CCSU_CURL_BIN で差し替え可能" || return 1

  port="$(smoke__env_port "$SMOKE_ENV")"
  unit="$(smoke__env_unit "$SMOKE_ENV")"

  log_info "post-deploy smoke: env=$SMOKE_ENV port=$port unit=$unit (読み取りのみ / 再起動しません)"

  smoke__check_health "$port"
  smoke__check_root "$port"
  smoke__check_dashboard "$SMOKE_ENV"
  smoke__check_terminal "$SMOKE_ENV"
  smoke__check_public_url
  smoke__check_promotions
  smoke__check_unit "$unit"

  if (( SMOKE_FAILED > 0 )); then
    log_error "結果: ${SMOKE_CHECKS} checks / ${SMOKE_FAILED} failed / ${SMOKE_WARNINGS} warnings — FAIL: ${SMOKE_FAIL_LIST}"
    if (( SMOKE_JSON )); then smoke__json; fi
    return 1
  fi

  log_ok "結果: ${SMOKE_CHECKS} checks / 0 failed / ${SMOKE_WARNINGS} warnings${SMOKE_WARN_LIST:+ — WARN: $SMOKE_WARN_LIST}"
  if (( SMOKE_JSON )); then smoke__json; fi
  return 0
}

rc=0
main "$@" || rc=$?
exit "$rc"
