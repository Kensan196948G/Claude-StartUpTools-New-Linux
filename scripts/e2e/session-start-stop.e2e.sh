#!/usr/bin/env bash
# ============================================================
# session-start-stop.e2e.sh — 実セッション起動→停止の隔離 E2E
#
# fake claude / fake timeout を使い、実 AI セッションは起動しない。
# ただし supervisor の起動・停止・state 反映は実コードを通す。
# ============================================================
set -uo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d /tmp/ccsu-session-e2e-XXXXXX)"
PORT="${E2E_PORT:-3812}"
PROJ="e2e-demo-$(date +%s)"
FAIL=0
SERVER_PID=""

cleanup() {
  tmux kill-session -t "claudeos-${PROJ//[^A-Za-z0-9_-]/_}" 2>/dev/null || true
  if [[ -n "$SERVER_PID" ]]; then kill "$SERVER_PID" 2>/dev/null || true; fi
  case "$TMP" in
    /tmp/ccsu-session-e2e-*) rm -rf "$TMP" ;;
  esac
}
trap cleanup EXIT

log() { printf '%s  %s\n' "$1" "$2"; }
pass() { log PASS "$1"; }
fail() { log FAIL "$1"; FAIL=1; }

mkdir -p "$TMP/bin" "$TMP/home" "$TMP/projects/$PROJ"
cat > "$TMP/bin/claude" <<'FAKE'
#!/usr/bin/env bash
echo "$@" > "${E2E_ARGV_FILE:-/dev/null}"
sleep 120
FAKE
cat > "$TMP/bin/timeout" <<'FAKE'
#!/usr/bin/env bash
while [[ "${1:-}" == -* ]]; do shift; done
[[ "${1:-}" =~ ^[0-9]+$ ]] && shift
exec "$@"
FAKE
chmod +x "$TMP"/bin/*
git -C "$TMP/projects/$PROJ" init -q .
git -C "$TMP/projects/$PROJ" config user.email e2e@example.com
git -C "$TMP/projects/$PROJ" config user.name e2e
printf 'x\n' > "$TMP/projects/$PROJ/a.txt"
git -C "$TMP/projects/$PROJ" add -A >/dev/null
git -C "$TMP/projects/$PROJ" commit -qm init >/dev/null
printf '{"projects":"%s","projectGroups":[],"localExcludes":[]}\n' "$TMP/projects" > "$TMP/config.json"

export PATH="$TMP/bin:$PATH"
export HOME="$TMP/home"
export CLAUDEOS_HOME="$TMP/home"
export CCSU_HOME="$TMP/home"
export AI_STARTUP_CONFIG_PATH="$TMP/config.json"
export E2E_ARGV_FILE="$TMP/argv.txt"

( cd "$REPO" && node scripts/web/startup-server.js --port "$PORT" --host 127.0.0.1 --allow-no-auth >"$TMP/server.log" 2>&1 ) &
SERVER_PID=$!
for _ in $(seq 1 40); do
  curl -fsS "http://127.0.0.1:$PORT/api/health" >/dev/null 2>&1 && break
  sleep 0.5
done
if ! curl -fsS "http://127.0.0.1:$PORT/api/health" >/dev/null 2>&1; then
  fail "隔離サーバが起動しない"; tail -5 "$TMP/server.log"; exit 1
fi
pass "隔離サーバ起動 (port=$PORT, project=$PROJ)"

SAFE="$(printf '%s' "$PROJ" | tr -c 'A-Za-z0-9_-' '_')"
API="http://127.0.0.1:$PORT"

RESP="$(curl -s -X POST -H 'content-type: application/json' \
  -d "{\"project\":\"$PROJ\",\"mode\":\"background\",\"goal\":\"auto\",\"duration\":1,\"confirm\":true}" \
  --max-time 180 "$API/api/startup/launch")"
if [[ "$(printf '%s' "$RESP" | jq -r '.ok // false')" == "true" ]]; then pass "起動 API (ok=true)"; else fail "起動 API: $(printf '%s' "$RESP" | head -c 200)"; fi

SUP_JSON="$CCSU_HOME/supervisor/$SAFE.json"
for _ in $(seq 1 60); do [[ -f "$SUP_JSON" ]] && break; sleep 0.5; done
if [[ -f "$SUP_JSON" ]]; then pass "supervisor JSON 生成 (status=$(jq -r '.status // "?"' "$SUP_JSON"))"; else fail "supervisor JSON が無い"; fi

STATE="$(curl -s --max-time 60 "$API/api/startup/state")"
RUNNING="$(printf '%s' "$STATE" | jq -r --arg p "$PROJ" '(.state.projects // []) | map(select(.name==$p)) | .[0].running // false')"
if [[ "$RUNNING" == "true" ]]; then pass "state.projects[].running = true"; else fail "state 上 running にならない"; fi

STOP="$(curl -s -X POST -H 'content-type: application/json' \
  -d "{\"project\":\"$PROJ\",\"confirm\":true,\"force\":true}" --max-time 120 "$API/api/startup/stop")"
if [[ "$(printf '%s' "$STOP" | jq -r '.ok // false')" == "true" ]]; then pass "停止 API (ok=true)"; else fail "停止 API: $(printf '%s' "$STOP" | head -c 200)"; fi

GONE=0
for _ in $(seq 1 60); do
  if [[ -f "$SUP_JSON" ]] && [[ "$(jq -r '.status // ""' "$SUP_JSON" 2>/dev/null)" == "stopped" ]]; then GONE=1; break; fi
  tmux has-session -t "claudeos-$SAFE" 2>/dev/null || { GONE=1; break; }
  sleep 0.5
done
STATE2="$(curl -s --max-time 60 "$API/api/startup/state")"
RUNNING2="$(printf '%s' "$STATE2" | jq -r --arg p "$PROJ" '(.state.projects // []) | map(select(.name==$p)) | .[0].running // false')"
if [[ "$GONE" == "1" && "$RUNNING2" != "true" ]]; then pass "停止後 running = false"; else fail "停止後も running のまま"; fi

tmux kill-session -t "claudeos-$SAFE" 2>/dev/null || true
sleep 1
if tmux has-session -t "claudeos-$SAFE" 2>/dev/null; then fail "後片付け後も tmux セッションが残る"; else pass "後片付けでセッション消滅"; fi

echo
if [[ "$FAIL" == "0" ]]; then echo "RESULT: PASS"; else echo "RESULT: FAIL"; fi
exit "$FAIL"
