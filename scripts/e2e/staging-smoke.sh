#!/usr/bin/env bash
# ============================================================
# staging-smoke.sh — リリース成果物の起動スモーク (staging 相当)
#
# 目的: 「リリース成果物 ($RELEASE/app) から起動 → 完全に分離した
#       CLAUDEOS_HOME で health / 主要 API が動く」ことを毎回証明する。
#
# 使い方:
#   bash scripts/e2e/staging-smoke.sh [--port N] [--json] [--keep] [--release DIR]
#
#   --port N   待ち受けポート (既定: 空きポートを自動選択)
#              本番ポート 3740 / 3737 / 3741 は明示的に拒否する。
#   --json     最終行に結果 JSON を 1 行だけ出す (途中のログは stderr)
#   --keep     一時ディレクトリを残す (調査用)
#
# 終了コード: 0 成功 / SKIP, 1 検査失敗, 2 引数エラー
#
# 安全性:
#   - CLAUDEOS_HOME は必ず一時ディレクトリ。実 ~/.claudeos は読まない・書かない。
#   - 本番 3740/3737/3741 は起動も停止もせず、バインドもしない。
#   - 本番 3740 の /api/health を起動前後で比較し、変化したら失敗にする。
#   - bin/release-build.sh が無い checkout では SKIP (exit 0) して CI を赤にしない。
# ============================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${CCSU_STAGING_SMOKE_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
RELEASE_BUILD="$REPO_ROOT/bin/release-build.sh"

# --json が後方に書かれていても引数エラーを JSON で返せるよう先に走査する
JSON=0
KEEP=0
for _arg in "$@"; do
  [[ "$_arg" == "--json" ]] && JSON=1
done
unset _arg

PORT=""
RELEASE_DIR=""
CHECKS=0
FAILURES=()
TMP=""
SERVER_PID=""

# ---------------------------------------------------------------------------
# 出力
# ---------------------------------------------------------------------------

usage() {
  cat <<'USAGE'
staging-smoke.sh [--port N] [--json] [--keep]

  リリース成果物 (bin/release-build.sh --out) から起動し、
  一時 CLAUDEOS_HOME へ分離した状態で health と主要 API を検査する。

  --port N   待ち受けポート (既定: 空きポート)
  --json     最終行に結果 JSON を 1 行だけ出力する
  --keep     一時ディレクトリを残す
  --release DIR
             ビルドせず、既存のリリース成果物 DIR を検証して起動する
             (.git の無い release ディレクトリから定期実行する場合に使う。
              未指定かつ git 管理外のときは REPO_ROOT 自身を成果物として扱う)
  -h, --help このヘルプ

  exit: 0 成功/SKIP, 1 検査失敗, 2 引数エラー
USAGE
}

# JSON モードではログを stderr に逃がし、stdout の最終行を結果 JSON だけにする
log() { if (( JSON )); then printf '%s\n' "$*" >&2; else printf '%s\n' "$*"; fi; }

check_pass() {
  CHECKS=$((CHECKS + 1))
  log "  [PASS] $1"
}

check_fail() {
  CHECKS=$((CHECKS + 1))
  FAILURES+=("$1${2:+: $2}")
  log "  [FAIL] $1${2:+: $2}"
}

arg_error() {
  if (( JSON )); then
    printf '{"ok":false,"error":"BAD_ARGS","message":"%s"}\n' "$1"
  fi
  printf 'staging-smoke: %s\n' "$1" >&2
  usage >&2
  exit 2
}

finalize() {
  local failed=${#FAILURES[@]}
  if (( failed == 0 )); then
    log ""
    log "== staging-smoke: PASS ($CHECKS checks, port=$PORT) =="
    if (( JSON )); then
      printf '{"ok":true,"port":%s,"checks":%d,"failed":0}\n' "$PORT" "$CHECKS"
    fi
    exit 0
  fi
  log ""
  log "== staging-smoke: FAIL ($failed/$CHECKS checks) =="
  local f
  for f in "${FAILURES[@]}"; do log "  - $f"; done
  if (( JSON )); then
    local arr
    arr="$(printf '%s\n' "${FAILURES[@]}" | jq -R . | jq -s -c .)"
    printf '{"ok":false,"failed":%d,"failures":%s}\n' "$failed" "$arr"
  fi
  exit 1
}

# ---------------------------------------------------------------------------
# 後始末 (プロセス kill / 一時ディレクトリ削除)
# ---------------------------------------------------------------------------

cleanup() {
  local rc=$?
  if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null || true
    for _ in $(seq 1 50); do
      kill -0 "$SERVER_PID" 2>/dev/null || break
      sleep 0.1
    done
    kill -9 "$SERVER_PID" 2>/dev/null || true
  fi
  if [[ -n "$TMP" && -d "$TMP" ]]; then
    if (( KEEP )); then
      printf 'staging-smoke: 一時ディレクトリを残しました: %s\n' "$TMP" >&2
    else
      rm -rf "$TMP"
    fi
  fi
  return "$rc"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# 引数
# ---------------------------------------------------------------------------

while (( $# > 0 )); do
  case "$1" in
    --port)
      (( $# >= 2 )) || arg_error "--port には値が必要です"
      PORT="$2"
      shift 2
      ;;
    --port=*)
      PORT="${1#--port=}"
      shift
      ;;
    --json)
      shift
      ;;
    --keep)
      KEEP=1
      shift
      ;;
    --release)
      (( $# >= 2 )) || arg_error "--release には値が必要です"
      RELEASE_DIR="$2"
      shift 2
      ;;
    --release=*)
      RELEASE_DIR="${1#--release=}"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      arg_error "未知のオプションです: $1"
      ;;
  esac
done

if [[ -n "$PORT" ]]; then
  [[ "$PORT" =~ ^[0-9]+$ ]] || arg_error "--port は整数で指定してください: $PORT"
  PORT=$((10#$PORT))
  if (( PORT < 1024 || PORT > 65535 )); then
    arg_error "--port は 1024-65535 の範囲で指定してください: $PORT"
  fi
  case "$PORT" in
    3740|3737|3741)
      arg_error "本番ポート $PORT は使用できません (本番サービスを汚さないため)"
      ;;
  esac
fi

# git 管理外 (release 成果物から実行) で manifest があれば、その成果物自身を検証対象にする
if [[ -z "$RELEASE_DIR" ]] && ! git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1 \
   && [[ -f "$REPO_ROOT/manifest.json" ]]; then
  RELEASE_DIR="$REPO_ROOT"
fi
if [[ -n "$RELEASE_DIR" ]]; then
  [[ -d "$RELEASE_DIR" ]] || arg_error "--release のディレクトリがありません: $RELEASE_DIR"
  RELEASE_DIR="$(cd "$RELEASE_DIR" && pwd -P)"
  [[ -f "$RELEASE_DIR/manifest.json" ]] || arg_error "--release に manifest.json がありません: $RELEASE_DIR"
fi

# ---------------------------------------------------------------------------
# SKIP: リリースビルドが無い checkout (task-4 未マージ) では CI を赤にしない
# ---------------------------------------------------------------------------

if [[ -z "$RELEASE_DIR" && ! -f "$RELEASE_BUILD" ]]; then
  log "SKIP: bin/release-build.sh が無いため成果物スモークを実行しません ($RELEASE_BUILD)"
  if (( JSON )); then
    printf '{"ok":true,"skipped":true,"reason":"release-build not available"}\n'
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
# 依存
# ---------------------------------------------------------------------------

for dep in node curl jq; do
  if ! command -v "$dep" >/dev/null 2>&1; then
    if (( JSON )); then
      printf '{"ok":false,"failed":1,"failures":["missing dependency: %s"]}\n' "$dep"
    fi
    log "staging-smoke: 必須コマンドがありません: $dep"
    exit 1
  fi
done

# 127.0.0.1 の検査を企業プロキシ環境でも直結させる (外部通信はしない)
no_proxy="127.0.0.1,localhost${no_proxy:+,$no_proxy}"
NO_PROXY="$no_proxy"
export no_proxy NO_PROXY

# ---------------------------------------------------------------------------
# 一時ディレクトリ (実 ~/.claudeos は絶対に使わない)
# ---------------------------------------------------------------------------

TMP="$(mktemp -d "${TMPDIR:-/tmp}/ccsu-staging-smoke-XXXXXX")" || {
  if (( JSON )); then
    printf '{"ok":false,"failed":1,"failures":["mktemp failed"]}\n'
  fi
  log "staging-smoke: 一時ディレクトリを作成できません"
  exit 1
}
CLAUDEOS_HOME="$TMP/home"
RELEASE="$TMP/release"
mkdir -p "$CLAUDEOS_HOME" "$RELEASE" "$TMP/tmp"

log "== staging-smoke 開始 =="
log "  repo:          $REPO_ROOT"
log "  CLAUDEOS_HOME: $CLAUDEOS_HOME (一時ディレクトリ)"
log "  RELEASE:       $RELEASE (一時ディレクトリ)"

# 本番 3740 の health 指紋 (起動前)
prod_health() {
  curl -sS -m 2 -w '|%{http_code}' "http://127.0.0.1:3740/api/health" 2>/dev/null || true
}
PROD_BEFORE="$(prod_health)"

# ---------------------------------------------------------------------------
# 1. リリース成果物のビルド
# ---------------------------------------------------------------------------

if [[ -n "$RELEASE_DIR" ]]; then
  log ""
  log "== 1. 既存のリリース成果物を検証 ($RELEASE_DIR) =="
  # 成果物は読み取り専用で扱う: 起動は symlink 経由の一時パスから行い、成果物自身へは書き込まない
  ln -s "$RELEASE_DIR" "$RELEASE/app"
  BUILD_JSON="$(jq -c '{ok:true, commit:.commit, short_commit:.short_commit, tree_sha256:.tree_sha256}' \
    "$RELEASE_DIR/manifest.json" 2>/dev/null || true)"
  if [[ "$(printf '%s' "$BUILD_JSON" | jq -r '.ok // false' 2>/dev/null)" != "true" ]]; then
    check_fail "manifest.json を読めない" "$RELEASE_DIR/manifest.json"
    finalize
  fi
  VERIFY="$RELEASE_DIR/scripts/release/verify-artifact.sh"
  if [[ -f "$VERIFY" ]]; then
    V_OUT="$(env CLAUDEOS_HOME="$CLAUDEOS_HOME" bash "$VERIFY" "$RELEASE_DIR" --json 2>/dev/null | tail -n 1)"
    if [[ "$(printf '%s' "$V_OUT" | jq -r '.ok // false' 2>/dev/null)" == "true" ]]; then
      check_pass "成果物の整合 (verify-artifact: files=$(printf '%s' "$V_OUT" | jq -r '.files'))"
    else
      check_fail "成果物の整合が取れない (verify-artifact)" "$(printf '%s' "$V_OUT" | head -c 300)"
      finalize
    fi
  fi
  BUILD_COMMIT="$(printf '%s' "$BUILD_JSON" | jq -r '.short_commit // .commit // "?"')"
  check_pass "既存成果物を使用 (commit=$BUILD_COMMIT)"
else
log ""
log "== 1. リリース成果物をビルド (bin/release-build.sh --ref HEAD) =="

BUILD_OUTPUT="$(env CLAUDEOS_HOME="$CLAUDEOS_HOME" TMPDIR="$TMP/tmp" \
  "$RELEASE_BUILD" --ref HEAD --out "$RELEASE/app" --json 2>"$TMP/release-build.err")"
BUILD_RC=$?
BUILD_JSON="$(printf '%s\n' "$BUILD_OUTPUT" | tail -n 1)"

if (( BUILD_RC != 0 )) || [[ "$(printf '%s' "$BUILD_JSON" | jq -r '.ok // false' 2>/dev/null)" != "true" ]]; then
  BUILD_ERR="$(tail -n 3 "$TMP/release-build.err" 2>/dev/null | tr '\n' ' ')"
  check_fail "release-build が成功しない (exit=$BUILD_RC)" "${BUILD_ERR:-$(printf '%s' "$BUILD_JSON" | head -c 200)}"
  finalize
fi

BUILD_COMMIT="$(printf '%s' "$BUILD_JSON" | jq -r '.short_commit // .commit // "?"')"
check_pass "release-build 成功 (commit=$BUILD_COMMIT)"
fi

SERVER_JS="$RELEASE/app/scripts/web/startup-server.js"
if [[ -f "$SERVER_JS" ]]; then
  check_pass "成果物に scripts/web/startup-server.js が含まれる"
else
  check_fail "成果物に scripts/web/startup-server.js が無い" "$SERVER_JS"
  finalize
fi

MANIFEST="$RELEASE/app/manifest.json"
if [[ -f "$MANIFEST" ]] && jq -e 'type == "object"' "$MANIFEST" >/dev/null 2>&1; then
  m_commit="$(jq -r '.commit // ""' "$MANIFEST")"
  m_tree="$(jq -r '.tree_sha256 // ""' "$MANIFEST")"
  b_commit="$(printf '%s' "$BUILD_JSON" | jq -r '.commit // ""')"
  b_tree="$(printf '%s' "$BUILD_JSON" | jq -r '.tree_sha256 // ""')"
  m_server="$(jq -r '[.files[]? | select(.path == "scripts/web/startup-server.js")] | length' "$MANIFEST")"
  if [[ -n "$m_commit" && "$m_commit" == "$b_commit" && "$m_tree" == "$b_tree" && "$m_server" -ge 1 ]]; then
    check_pass "manifest.json と build 結果が同一 (commit=$m_commit)"
  else
    check_fail "manifest.json と build 結果が不一致" \
      "commit=${m_commit:-?}/${b_commit:-?} tree=${m_tree:0:12}/${b_tree:0:12} server-entry=$m_server"
  fi
else
  check_fail "成果物ルートに manifest.json が無い (release-build 契約)" "$MANIFEST"
fi

# ---------------------------------------------------------------------------
# 2. 分離サーバの起動
# ---------------------------------------------------------------------------

find_free_port() {
  node -e '
    const net = require("net");
    const s = net.createServer();
    s.on("error", () => process.exit(1));
    s.listen(0, "127.0.0.1", () => {
      const p = s.address().port;
      s.close(() => process.stdout.write(String(p)));
    });
  ' 2>/dev/null
}

if [[ -z "$PORT" ]]; then
  PORT="$(find_free_port)"
  [[ "$PORT" =~ ^[0-9]+$ ]] || {
    check_fail "空きポートを取得できない"
    finalize
  }
fi

BASE="http://127.0.0.1:$PORT"
SERVER_LOG="$TMP/server.log"

log ""
log "== 2. 分離サーバを起動 (port=$PORT, host=127.0.0.1) =="

(
  cd "$RELEASE/app" || exit 1
  # 認証系 env を落とし、HOME も一時ディレクトリへ寄せて実環境へ書かせない
  exec env -u STARTUP_WEB_PASSWORD -u DASHBOARD_PASSWORD \
    CLAUDEOS_HOME="$CLAUDEOS_HOME" HOME="$CLAUDEOS_HOME" TMPDIR="$TMP/tmp" \
    node "$SERVER_JS" --port "$PORT" --host 127.0.0.1 --allow-no-auth --root "$RELEASE/app"
) >"$SERVER_LOG" 2>&1 &
SERVER_PID=$!

log "  pid=$SERVER_PID log=$SERVER_LOG"

# ---------------------------------------------------------------------------
# 3. health (最大 20 秒)
# ---------------------------------------------------------------------------

deadline=$((SECONDS + 20))
health_code=""
while (( SECONDS < deadline )); do
  health_code="$(curl -sS -m 2 -o "$TMP/health.json" -w '%{http_code}' "$BASE/api/health" 2>/dev/null || true)"
  [[ "$health_code" == "200" ]] && break
  kill -0 "$SERVER_PID" 2>/dev/null || break
  sleep 0.25
done

log ""
log "== 3. health / 主要 API の検査 =="

if [[ "$health_code" != "200" ]]; then
  check_fail "GET /api/health が 20 秒以内に 200 にならない (code=${health_code:-none})" \
    "$(tail -n 3 "$SERVER_LOG" 2>/dev/null | tr '\n' ' ')"
  finalize
fi
check_pass "GET /api/health = 200 (20 秒以内)"

if [[ "$(jq -r '.ok // false' "$TMP/health.json" 2>/dev/null)" == "true" ]]; then
  check_pass "/api/health の ok=true"
else
  check_fail "/api/health の ok が true でない" "$(head -c 200 "$TMP/health.json" 2>/dev/null | tr '\n' ' ')"
fi

SERVICE_NAME="$(jq -r '.service // ""' "$TMP/health.json" 2>/dev/null)"
if [[ "$SERVICE_NAME" == "claudeos-web-startup" ]]; then
  check_pass "/api/health の service=claudeos-web-startup"
else
  check_fail "/api/health の service 名が想定外" "service=${SERVICE_NAME:-none}"
fi

ROOT_CODE="$(curl -sS -m 5 -o "$TMP/root.html" -w '%{http_code}' "$BASE/" 2>/dev/null || true)"
if [[ "$ROOT_CODE" == "200" && -s "$TMP/root.html" ]]; then
  check_pass "GET / = 200 (成果物の静的 UI を配信)"
else
  check_fail "GET / が 200 + 非空でない" "code=${ROOT_CODE:-none}"
fi

# 保護対象 API: 起動時にパスワード env を外しているので「許可 (2xx)」が期待値。
# 認証を有効にした環境では 401/403 が期待値になる (どちらも受容する)。
PROT_CODE="$(curl -sS -m 5 -o "$TMP/protected.json" -w '%{http_code}' \
  "$BASE/api/startup/audit?lines=1" 2>/dev/null || true)"
case "$PROT_CODE" in
  2??|401|403)
    check_pass "保護 API は認証設定どおりに応答 (code=$PROT_CODE)"
    ;;
  *)
    check_fail "保護 API の応答が想定外 (code=${PROT_CODE:-none})" \
      "$(head -c 200 "$TMP/protected.json" 2>/dev/null | tr '\n' ' ')"
    ;;
esac

# 不正な変更系 (text/plain + 認証なし) はハンドラ前に拒否され、監査ログだけが残る。
# 副作用は無い (起動計画にも到達しない)。
MUT_CODE="$(curl -sS -m 5 -o "$TMP/mutation.json" -w '%{http_code}' \
  -X POST -H 'Content-Type: text/plain' --data 'staging-smoke' \
  "$BASE/api/startup/plan" 2>/dev/null || true)"
if [[ "$MUT_CODE" == "415" || "$MUT_CODE" == "403" || "$MUT_CODE" == "401" ]]; then
  check_pass "不正な変更系リクエストを拒否 (code=$MUT_CODE)"
else
  check_fail "不正な変更系リクエストが拒否されない (code=${MUT_CODE:-none})" \
    "$(head -c 200 "$TMP/mutation.json" 2>/dev/null | tr '\n' ' ')"
fi

AUDIT_LOG="$CLAUDEOS_HOME/logs/web-startup-audit.log"
if [[ -f "$AUDIT_LOG" ]] && grep -q '"action":"mutation-rejected"' "$AUDIT_LOG"; then
  check_pass "監査ログが分離 CLAUDEOS_HOME 配下に作られる ($CLAUDEOS_HOME/logs/)"
else
  check_fail "監査ログが分離 CLAUDEOS_HOME 配下に作られない" "$AUDIT_LOG"
fi

# ---------------------------------------------------------------------------
# 4. 本番ポート 3740 の不汚染
# ---------------------------------------------------------------------------

PROD_AFTER="$(prod_health)"
if [[ "$PROD_BEFORE" == "$PROD_AFTER" ]]; then
  check_pass "本番 3740 の health は起動前後で不変 (${PROD_BEFORE:-unreachable})"
else
  check_fail "本番 3740 の health が変化した" \
    "before=${PROD_BEFORE:-unreachable} after=${PROD_AFTER:-unreachable}"
fi

finalize
