#!/usr/bin/env bats
# ============================================================
# watch-session.bats — watch-session.sh のユニットテスト
#
# 対象: libexec/watch-session.sh
# 戦略: CLAUDEOS_HOME を TEST_TEMP 以下に向け、supervisor/*.json と
#       sessions/*.json を任意生成して --once 出力を観測する (ヘルメチック)。
#       tmux はスタブで存在を制御する。
# ============================================================

load '../helpers/common-setup'

WATCH_SH=

setup() {
  _bats_common_setup
  WATCH_SH="$REPO_ROOT/libexec/watch-session.sh"

  # ホームディレクトリを TEST_TEMP に向ける
  export CLAUDEOS_HOME="$TEST_TEMP/claudeos"
  export CCSU_SESSIONS_DIR="$TEST_TEMP/claudeos/sessions"
  export CCSU_SUP_DIR="$TEST_TEMP/claudeos/supervisor"
  # tmux は既定でスタブ (存在しない) にしておく
  export CCSU_TMUX_BIN="$STUB_BIN/tmux"

  mkdir -p "$CCSU_SESSIONS_DIR" "$CCSU_SUP_DIR"
}
teardown() { _bats_common_teardown; }

# ─── ヘルパ ───────────────────────────────────────────────────

_mk_session() {
  # _mk_session <project> <status> [start_time]
  local proj="$1" status="$2" ts="${3:-2026-06-17T10:00:00+09:00}"
  local safe; safe="$(printf '%s' "$proj" | tr -c 'A-Za-z0-9_-' '_')"
  local id="${safe}_$(date +%s%N 2>/dev/null || echo 0)"
  cat >"$CCSU_SESSIONS_DIR/${id}.json" <<EOF
{"sessionId":"$id","project":"$proj","status":"$status","start_time":"$ts","trigger":"cron"}
EOF
}

_mk_supervisor() {
  # _mk_supervisor <project> <status> <pid>
  local proj="$1" status="$2" pid="$3"
  local safe; safe="$(printf '%s' "$proj" | tr -c 'A-Za-z0-9_-' '_')"
  cat >"$CCSU_SUP_DIR/${safe}.json" <<EOF
{"project":"$proj","status":"$status","pid":$pid,"started_at":"2026-06-17T19:25:21+09:00","month_spent_usd":65.254}
EOF
}

_stub_tmux() {
  # tmux スタブ: ls で何も返さない (headless 環境を再現)
  cat >"$STUB_BIN/tmux" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$STUB_BIN/tmux"
}

# ─── sessions ディレクトリなし ──────────────────────────────

@test "sessions ディレクトリ不在でも exit 0 (fail-soft)" {
  rmdir "$CCSU_SESSIONS_DIR"
  run bash "$WATCH_SH" --once
  [ "$status" -eq 0 ]
  [[ "$output" == *"セッションディレクトリがありません"* ]]
}

# ─── headless セッション表示 ────────────────────────────────

@test "supervisor running + PID 生存 → headless 表示に現れる" {
  _mk_session "TestProject" "completed"
  _mk_supervisor "TestProject" "running" "$$"   # $$ は現在の bats PID (生存確実)
  _stub_tmux
  run bash "$WATCH_SH" --once
  [ "$status" -eq 0 ]
  [[ "$output" == *"🤖 TestProject"* ]]
}

@test "supervisor status=stopped → headless 表示に現れない" {
  _mk_session "StoppedProject" "completed"
  _mk_supervisor "StoppedProject" "stopped" "$$"
  _stub_tmux
  run bash "$WATCH_SH" --once
  [ "$status" -eq 0 ]
  [[ "$output" != *"🤖 StoppedProject"* ]]
}

@test "supervisor running だが PID 不在 → headless 表示に現れない" {
  _mk_session "DeadProject" "completed"
  _mk_supervisor "DeadProject" "running" "999999999"   # 存在しない PID
  _stub_tmux
  run bash "$WATCH_SH" --once
  [ "$status" -eq 0 ]
  [[ "$output" != *"🤖 DeadProject"* ]]
}

# ─── supervisor なし (純 tmux 環境) ────────────────────────

@test "supervisor JSON なし → headless 実行中なし と表示" {
  _mk_session "SomeProject" "completed"
  _stub_tmux
  run bash "$WATCH_SH" --once
  [ "$status" -eq 0 ]
  [[ "$output" == *"(実行中なし)"* ]]
}

# ─── セッション履歴表示 ─────────────────────────────────────

@test "sessions/*.json が1件あれば履歴に表示される" {
  _mk_session "HistoryProject" "completed"
  _stub_tmux
  run bash "$WATCH_SH" --once
  [ "$status" -eq 0 ]
  [[ "$output" == *"HistoryProject"* ]]
  [[ "$output" == *"completed"* ]]
}

@test "sessions/*.json が0件なら '記録なし' を表示" {
  _stub_tmux
  run bash "$WATCH_SH" --once
  [ "$status" -eq 0 ]
  [[ "$output" == *"(記録なし)"* ]]
}

# ─── tmux と headless の混在 ───────────────────────────────

@test "tmux セッションも headless セッションも同時に表示" {
  _mk_session "HeadlessProj" "completed"
  _mk_supervisor "HeadlessProj" "running" "$$"

  # tmux スタブ: ls で claudeos-tmuxproj を返す
  cat >"$STUB_BIN/tmux" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "ls" ]]; then
  echo "claudeos-tmuxproj: 1 windows"
fi
exit 0
EOF
  chmod +x "$STUB_BIN/tmux"

  run bash "$WATCH_SH" --once
  [ "$status" -eq 0 ]
  [[ "$output" == *"🤖 HeadlessProj"* ]]
  [[ "$output" == *"🖥"* ]]
}
