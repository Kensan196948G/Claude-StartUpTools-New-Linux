#!/usr/bin/env bats
# ============================================================
# cron-launcher-headless.bats — PR-D headless 中核の統合 + tail.sh 単体テスト
#
# 検証観点 (プラン欠落4 c):
#   [統合] CLAUDEOS_HEADLESS=1 で cron-launcher.sh を実走 (偽 claude/timeout で課金なし):
#     - claude argv に -p / --output-format stream-json / --permission-mode dontAsk が付く
#     - --dangerously-skip-permissions は付かない (headless では不要・多経路化回避)
#     - timeout 秒が DURATION 連動 (DURATION_MIN=1 → 60s)
#     - resume id 有無で --resume が切替わる
#     - 捕捉 session_id が state.execution.last_claude_session_id へ往復保存される
#   [単体] stream-json-tail.sh: session_id/cost 抽出・可読行生成・壊れ行 skip (jq 必須)
#
# 設計: 本物の claude を起動すると Agent SDK クレジットを消費するため、PATH 先頭へ
#       argv 記録 + stream-json 固定出力の偽 claude を置く。timeout も偽装し
#       `--foreground <N>s` を剥がして本来の起動経路をそのまま再現する。
# ============================================================

load '../helpers/common-setup'

CRON_LAUNCHER="" # setup で解決
SJT="" # stream-json-tail.sh 実体

setup() {
  _bats_common_setup
  CRON_LAUNCHER="$REPO_ROOT/Claude/templates/linux/cron-launcher.sh"
  SJT="$REPO_ROOT/libexec/stream-json-tail.sh"

  # 隔離: HOME を TEST_TEMP に向け、実環境の ~/.local/bin の本物 claude を拾わせない
  export HOME="$TEST_TEMP/home"; mkdir -p "$HOME"
  export CLAUDEOS_HOME="$TEST_TEMP/claudeos"
  export PROJECTS_BASE="$TEST_TEMP/projects"

  # 偽プロジェクト Demo を用意
  PROJECT_DIR="$PROJECTS_BASE/Demo"
  mkdir -p "$PROJECT_DIR/.claude"
  printf '%s\n' "# START\nデモ起動プロンプト" > "$PROJECT_DIR/.claude/START_PROMPT.md"

  # canonical libexec へ実体の stream-json-tail.sh を配置 (cron-launcher が参照するパス)
  CANON_LIBEXEC="$PROJECTS_BASE/Claude-StartUpTools-New-Linux/libexec"
  mkdir -p "$CANON_LIBEXEC"
  cp "$SJT" "$CANON_LIBEXEC/stream-json-tail.sh"

  # 偽 claude: 各 argv を 1 行ずつ記録 + 固定 stream-json を stdout へ
  #   加えて ANTHROPIC_API_KEY の「存在のみ」を CLAUDE_ENV_KEY へ記録する (値は書かない)。
  #   subscription 経路では env -u で鍵が外れ UNSET、api-key 経路では SET になる想定。
  CLAUDE_ARGV="$TEST_TEMP/claude-argv"
  CLAUDE_ENV_KEY="$TEST_TEMP/claude-env-key"
  cat > "$STUB_BIN/claude" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$CLAUDE_ARGV"
if [[ -n "\${ANTHROPIC_API_KEY+x}" ]]; then printf 'SET\n'; else printf 'UNSET\n'; fi > "$CLAUDE_ENV_KEY"
cat <<'JSON'
{"type":"system","subtype":"init","session_id":"sess-headless-xyz","model":"claude-opus-4-8"}
{"type":"assistant","message":{"content":[{"type":"text","text":"作業中"}]}}
{"type":"result","subtype":"success","total_cost_usd":0.42,"num_turns":3,"session_id":"sess-headless-xyz"}
JSON
exit 0
EOF
  chmod +x "$STUB_BIN/claude"

  # 偽 timeout: argv を記録した上で `--foreground <N>s` を剥がし、残りを本来どおり exec
  TIMEOUT_ARGV="$TEST_TEMP/timeout-argv"
  cat > "$STUB_BIN/timeout" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$TIMEOUT_ARGV"
shift 2   # --foreground と <N>s を除去
exec "\$@"
EOF
  chmod +x "$STUB_BIN/timeout"
}
teardown() { _bats_common_teardown; }

# state.json を最小生成: <last_claude_session_id 値 (空可)>
_seed_state() {
  local sid="${1:-}"
  printf '{"execution":{"last_claude_session_id":"%s"}}\n' "$sid" \
    > "$PROJECT_DIR/state.json"
}

# =========================================================
# 統合: headless 起動の argv 検証
# =========================================================
@test "headless: claude -p / stream-json / dontAsk が付き skip-permissions は付かない" {
  _seed_state ""   # resume なし
  run env CLAUDEOS_HEADLESS=1 bash "$CRON_LAUNCHER" Demo 1
  [ "$status" -eq 0 ]
  [ -f "$CLAUDE_ARGV" ]
  run cat "$CLAUDE_ARGV"
  [[ "$output" == *"-p"* ]]
  [[ "$output" == *"--output-format"* ]]
  [[ "$output" == *"stream-json"* ]]
  [[ "$output" == *"--permission-mode"* ]]
  [[ "$output" == *"dontAsk"* ]]
  [[ "$output" == *"--verbose"* ]]
  [[ "$output" != *"--dangerously-skip-permissions"* ]]
}

@test "headless: --print + stream-json には --verbose が必須 (claude CLI 契約)" {
  # ライブスモーク回帰: --verbose 欠落だと実 claude が
  #   "When using --print, --output-format=stream-json requires --verbose"
  # で exit 1 する。偽 claude は契約を検証しないため、ここで argv 表明として固定する。
  _seed_state ""
  run env CLAUDEOS_HEADLESS=1 bash "$CRON_LAUNCHER" Demo 1
  [ "$status" -eq 0 ]
  run cat "$CLAUDE_ARGV"
  [[ "$output" == *"--verbose"* ]]
  [[ "$output" == *"--output-format"* ]]
  [[ "$output" == *"stream-json"* ]]
}

@test "headless: timeout 秒が DURATION 連動 (1分 → 60s)" {
  _seed_state ""
  run env CLAUDEOS_HEADLESS=1 bash "$CRON_LAUNCHER" Demo 1
  [ "$status" -eq 0 ]
  [ -f "$TIMEOUT_ARGV" ]
  run cat "$TIMEOUT_ARGV"
  [[ "$output" == *"--foreground"* ]]
  [[ "$output" == *"60s"* ]]
}

@test "headless: resume id があれば --resume が付く" {
  _seed_state "sess-prev-123"
  run env CLAUDEOS_HEADLESS=1 bash "$CRON_LAUNCHER" Demo 1
  [ "$status" -eq 0 ]
  run cat "$CLAUDE_ARGV"
  [[ "$output" == *"--resume"* ]]
  [[ "$output" == *"sess-prev-123"* ]]
}

@test "headless: resume id が無ければ --resume は付かない" {
  _seed_state ""
  run env CLAUDEOS_HEADLESS=1 bash "$CRON_LAUNCHER" Demo 1
  [ "$status" -eq 0 ]
  run cat "$CLAUDE_ARGV"
  [[ "$output" != *"--resume"* ]]
}

@test "headless: 捕捉 session_id が state.execution.last_claude_session_id へ保存される" {
  _seed_state ""
  run env CLAUDEOS_HEADLESS=1 bash "$CRON_LAUNCHER" Demo 1
  [ "$status" -eq 0 ]
  run python3 -c "import json;print(json.load(open('$PROJECT_DIR/state.json'))['execution']['last_claude_session_id'])"
  [ "$output" = "sess-headless-xyz" ]
}

@test "回帰: CLAUDEOS_HEADLESS=0 は明示 opt-out で headless パスを通らない" {
  _seed_state ""
  # PR-G で既定は headless へ反転したため、=0 は「明示的に TUI へ退避」する opt-out 経路。
  # TUI 経路は tmux 等を使うが、claude も timeout も偽装済みなので致命傷にはならない。
  # ここでは「headless の stream-json argv が記録されない」ことだけ確認する。
  run env CLAUDEOS_HEADLESS=0 bash "$CRON_LAUNCHER" Demo 1
  if [[ -f "$CLAUDE_ARGV" ]]; then
    run cat "$CLAUDE_ARGV"
    [[ "$output" != *"--output-format"* ]]
  fi
}

@test "PR-G: CLAUDEOS_HEADLESS 未設定の既定は headless パスを通る" {
  _seed_state ""
  # 既定反転 (${CLAUDEOS_HEADLESS:-1}) の表明: 未設定でも headless の stream-json argv が記録される。
  run env -u CLAUDEOS_HEADLESS bash "$CRON_LAUNCHER" Demo 1
  [ "$status" -eq 0 ]
  [ -f "$CLAUDE_ARGV" ]
  run cat "$CLAUDE_ARGV"
  [[ "$output" == *"-p"* ]]
  [[ "$output" == *"--output-format"* ]]
  [[ "$output" == *"stream-json"* ]]
  [[ "$output" != *"--dangerously-skip-permissions"* ]]
}

# =========================================================
# 統合: headless 課金経路 (CLAUDEOS_HEADLESS_AUTH)
#   subscription (既定): env -u ANTHROPIC_API_KEY で購読 OAuth ($300 枠) へ。
#   api-key:            鍵を保持し API platform ($150 固定上限) へ退避。
# =========================================================
@test "billing: 既定 (subscription) は claude 環境から ANTHROPIC_API_KEY を外す" {
  _seed_state ""
  # 実環境に鍵が在る状況を模す: 外れたことが観測できるよう SET 状態で起動する。
  run env CLAUDEOS_HEADLESS=1 ANTHROPIC_API_KEY=dummy-key-xxxx bash "$CRON_LAUNCHER" Demo 1
  [ "$status" -eq 0 ]
  [ -f "$CLAUDE_ENV_KEY" ]
  [ "$(cat "$CLAUDE_ENV_KEY")" = "UNSET" ]
}

@test "billing: subscription 明示指定でも鍵を外す" {
  _seed_state ""
  run env CLAUDEOS_HEADLESS=1 CLAUDEOS_HEADLESS_AUTH=subscription \
    ANTHROPIC_API_KEY=dummy-key-xxxx bash "$CRON_LAUNCHER" Demo 1
  [ "$status" -eq 0 ]
  [ "$(cat "$CLAUDE_ENV_KEY")" = "UNSET" ]
}

@test "billing: api-key 指定は ANTHROPIC_API_KEY を保持する (退避経路)" {
  _seed_state ""
  run env CLAUDEOS_HEADLESS=1 CLAUDEOS_HEADLESS_AUTH=api-key \
    ANTHROPIC_API_KEY=dummy-key-xxxx bash "$CRON_LAUNCHER" Demo 1
  [ "$status" -eq 0 ]
  [ "$(cat "$CLAUDE_ENV_KEY")" = "SET" ]
}

@test "billing: subscription では timeout argv に env -u プレフィックスが入る" {
  _seed_state ""
  run env CLAUDEOS_HEADLESS=1 ANTHROPIC_API_KEY=dummy-key-xxxx bash "$CRON_LAUNCHER" Demo 1
  [ "$status" -eq 0 ]
  run cat "$TIMEOUT_ARGV"
  [[ "$output" == *"env"* ]]
  [[ "$output" == *"-u"* ]]
  [[ "$output" == *"ANTHROPIC_API_KEY"* ]]
}

@test "billing: api-key では timeout argv に env -u プレフィックスが入らない" {
  _seed_state ""
  run env CLAUDEOS_HEADLESS=1 CLAUDEOS_HEADLESS_AUTH=api-key \
    ANTHROPIC_API_KEY=dummy-key-xxxx bash "$CRON_LAUNCHER" Demo 1
  [ "$status" -eq 0 ]
  run cat "$TIMEOUT_ARGV"
  [[ "$output" != *"ANTHROPIC_API_KEY"* ]]
}

# =========================================================
# 統合: クレジット cost ミラー (PR-E)
# =========================================================
@test "headless: CLAUDEOS_SESSION_COST_FILE へ cost (0.42) がミラーされる" {
  _seed_state ""
  local mirror="$TEST_TEMP/session-cost"
  run env CLAUDEOS_HEADLESS=1 CLAUDEOS_SESSION_COST_FILE="$mirror" bash "$CRON_LAUNCHER" Demo 1
  [ "$status" -eq 0 ]
  [ -f "$mirror" ]
  [ "$(cat "$mirror")" = "0.42" ]
}

@test "headless: CLAUDEOS_SESSION_COST_FILE 未設定ならミラーしない (no-op)" {
  _seed_state ""
  # supervisor 経由でない直接起動を模倣: ミラー先未指定でも落ちず session_id 保存は機能する
  run env CLAUDEOS_HEADLESS=1 bash "$CRON_LAUNCHER" Demo 1
  [ "$status" -eq 0 ]
  [ ! -f "$TEST_TEMP/session-cost" ]
}

# =========================================================
# 単体: stream-json-tail.sh の純粋関数
# =========================================================
@test "sjt: jq が利用可能 (テスト前提)" {
  command -v jq >/dev/null 2>&1
}

@test "sjt__extract_session_id: .session_id を取り出す" {
  run bash -c 'source "'"$SJT"'"; sjt__extract_session_id '"'"'{"type":"system","session_id":"abc123"}'"'"
  [ "$output" = "abc123" ]
}

@test "sjt__extract_session_id: session_id 欠落は空" {
  run bash -c 'source "'"$SJT"'"; sjt__extract_session_id '"'"'{"type":"assistant"}'"'"
  [ -z "$output" ]
}

@test "sjt__extract_cost: result の total_cost_usd を取り出す" {
  run bash -c 'source "'"$SJT"'"; sjt__extract_cost '"'"'{"type":"result","total_cost_usd":0.42}'"'"
  [ "$output" = "0.42" ]
}

@test "sjt__extract_cost: result 以外は空" {
  run bash -c 'source "'"$SJT"'"; sjt__extract_cost '"'"'{"type":"assistant","total_cost_usd":9.9}'"'"
  [ -z "$output" ]
}

@test "sjt__human_line: init を可読化する" {
  run bash -c 'source "'"$SJT"'"; sjt__human_line '"'"'{"type":"system","subtype":"init","session_id":"s1","model":"opus"}'"'"
  [[ "$output" == *"🟢 init"* ]]
  [[ "$output" == *"session=s1"* ]]
}

@test "sjt__human_line: result を可読化する" {
  run bash -c 'source "'"$SJT"'"; sjt__human_line '"'"'{"type":"result","subtype":"success","total_cost_usd":0.5,"num_turns":4}'"'"
  [[ "$output" == *"🏁 result"* ]]
  [[ "$output" == *"cost=\$0.5"* ]]
}

@test "sjt__human_line: 壊れた行は空 (skip)" {
  run bash -c 'source "'"$SJT"'"; sjt__human_line "this is not json {{{"'
  [ -z "$output" ]
}

@test "sjt__run: session_id/cost をファイルへ、可読行を stdout へ、壊れ行は skip" {
  local sidf="$TEST_TEMP/run.sid" costf="$TEST_TEMP/run.cost"
  run env SJT_SESSION_ID_FILE="$sidf" SJT_COST_FILE="$costf" bash -c '
    source "'"$SJT"'"
    printf "%s\n" \
      "{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"runid-9\",\"model\":\"opus\"}" \
      "broken {{{ not json" \
      "{\"type\":\"result\",\"subtype\":\"success\",\"total_cost_usd\":1.25,\"num_turns\":2,\"session_id\":\"runid-9\"}" \
      | sjt__run
  '
  [ "$status" -eq 0 ]
  [ "$(cat "$sidf")" = "runid-9" ]
  [ "$(cat "$costf")" = "1.25" ]
  [[ "$output" == *"🟢 init"* ]]
  [[ "$output" == *"🏁 result"* ]]
}
