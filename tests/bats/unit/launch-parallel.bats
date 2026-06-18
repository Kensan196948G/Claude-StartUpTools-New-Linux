#!/usr/bin/env bats
# ============================================================
# launch-parallel.bats — PR-F 並列ロール起動 (launch-parallel-cron.sh)
#
# 検証観点 (プラン欠落5 c):
#   [単体] lp__role_to_file / lp__parse_roles / lp__distribute_roles の純粋関数
#   [統合] 偽 claude/timeout で課金なし実走:
#     - CTO/QA 双方が `-p` + `--output-format stream-json` + `--permission-mode bypassPermissions` で起動
#       (dontAsk は settings.json allow 外の tool を自動拒否するため headless 不可。2026-06-16 実証)
#     - --dangerously-skip-permissions フラグ形式は付かない (bypassPermissions で代替)
#     - stagger=0 で起動順序 (cto → qa) が保たれる
#     - role 不在 (--roles に未知ロール) で明示エラー + 非ゼロ終了
#   [dry-run] 実起動なしで計画のみ出力
#
# 設計: 本物の claude は Agent SDK クレジットを消費するため、PATH 先頭へ argv を
#       PID 別ファイルへ記録する偽 claude を置く。timeout も偽装し `--foreground <N>s`
#       を剥がして残りを exec、本来の起動経路をそのまま再現する。
# ============================================================

load '../helpers/common-setup'

LP="" # setup で解決

setup() {
  _bats_common_setup
  LP="$REPO_ROOT/scripts/tools/launch-parallel-cron.sh"

  # 隔離 HOME (実環境の ~/.local/bin の本物 claude を拾わせない)
  export HOME="$TEST_TEMP/home"; mkdir -p "$HOME"

  # ロール正本は repo テンプレートをそのまま使う (cto-build.md / qa-monitor.md)
  export LP_ROLES_SRC="$REPO_ROOT/Claude/templates/claudeos/roles"
  export LP_ROLES_DIR="$TEST_TEMP/roles"
  export LP_RUNTIME_DIR="$TEST_TEMP/runtime"
  export LP_LOGS_DIR="$TEST_TEMP/logs"
  export LP_PROJECTS_BASE="$TEST_TEMP/projects"
  export LP_SJT="$REPO_ROOT/libexec/stream-json-tail.sh"
  export CLAUDEOS_MODEL_USAGE_FILE="$TEST_TEMP/model-usage.jsonl"

  # 偽プロジェクト Demo
  PROJECT_DIR="$LP_PROJECTS_BASE/Demo"
  mkdir -p "$PROJECT_DIR/.claude"

  # 偽 claude: argv を PID 別ファイルへ記録 + 固定 stream-json を stdout へ
  #   加えて ANTHROPIC_API_KEY の「存在のみ」を env-* ファイルへ記録する (値は書かない)。
  CLAUDE_ARGV_DIR="$TEST_TEMP/claude-argv"; mkdir -p "$CLAUDE_ARGV_DIR"
  CLAUDE_ENV_DIR="$TEST_TEMP/claude-env"; mkdir -p "$CLAUDE_ENV_DIR"
  cat > "$STUB_BIN/claude" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$CLAUDE_ARGV_DIR/argv-\$\$"
if [[ -n "\${ANTHROPIC_API_KEY+x}" ]]; then printf 'PRESENT\n'; else printf 'ABSENT\n'; fi > "$CLAUDE_ENV_DIR/env-\$\$"
cat <<'JSON'
{"type":"system","subtype":"init","session_id":"sess-par-xyz","model":"claude-opus-4-8"}
{"type":"result","subtype":"success","total_cost_usd":0.10,"num_turns":1,"session_id":"sess-par-xyz"}
JSON
exit 0
EOF
  chmod +x "$STUB_BIN/claude"

  # 偽 timeout: `--foreground <N>s` を剥がして残りを exec
  cat > "$STUB_BIN/timeout" <<'EOF'
#!/usr/bin/env bash
shift 2
exec "$@"
EOF
  chmod +x "$STUB_BIN/timeout"
}
teardown() { _bats_common_teardown; }

# 全 argv ファイルを連結して返す
_all_argv() { cat "$CLAUDE_ARGV_DIR"/argv-* 2>/dev/null; }
# 全 env 記録ファイルを連結して返す (各ロールの ANTHROPIC_API_KEY 存在/不在)
_all_env() { cat "$CLAUDE_ENV_DIR"/env-* 2>/dev/null; }

# =========================================================
# 単体: 純粋関数
# =========================================================
@test "lp__role_to_file: cto/qa エイリアス + 未知ロール passthrough" {
  run bash -c 'source "'"$LP"'"; lp__role_to_file cto'
  [ "$output" = "cto-build.md" ]
  run bash -c 'source "'"$LP"'"; lp__role_to_file qa'
  [ "$output" = "qa-monitor.md" ]
  run bash -c 'source "'"$LP"'"; lp__role_to_file security'
  [ "$output" = "security.md" ]
}

@test "lp__parse_roles: 空白除去 + 空要素破棄で 1 行 1 ロール" {
  run bash -c 'source "'"$LP"'"; lp__parse_roles " cto , qa ,, "'
  [ "${lines[0]}" = "cto" ]
  [ "${lines[1]}" = "qa" ]
  [ "${#lines[@]}" -eq 2 ]
}

@test "lp__distribute_roles: 冪等・非破壊で canonical を配布" {
  local dest="$TEST_TEMP/dist"
  run bash -c 'source "'"$LP"'"; lp__distribute_roles "'"$LP_ROLES_SRC"'" "'"$dest"'"'
  [ "$status" -eq 0 ]
  [ -f "$dest/cto-build.md" ]
  [ -f "$dest/qa-monitor.md" ]
  # 非破壊: dest 側のユーザー編集は src が新しくない限り保持される
  printf 'USER EDIT\n' > "$dest/cto-build.md"
  run bash -c 'source "'"$LP"'"; lp__distribute_roles "'"$LP_ROLES_SRC"'" "'"$dest"'"'
  [ "$status" -eq 0 ]
  [ "$(cat "$dest/cto-build.md")" = "USER EDIT" ]
}

@test "lp__distribute_roles: src 不在は明示エラー" {
  run bash -c 'source "'"$LP"'"; lp__distribute_roles "'"$TEST_TEMP"'/nope" "'"$TEST_TEMP"'/d"'
  [ "$status" -ne 0 ]
  [[ "$output" == *"roles テンプレート不在"* ]]
}

# =========================================================
# 統合: 並列起動 argv 検証
# =========================================================
@test "並列: CTO/QA 双方が -p / stream-json / permission-mode auto で起動し skip-permissions は付かない" {
  run bash "$LP" Demo --roles cto,qa --stagger 0 --duration 1
  [ "$status" -eq 0 ]
  # 2 ロール分の argv ファイルが生成される
  run bash -c 'ls "'"$CLAUDE_ARGV_DIR"'"/argv-* | wc -l'
  [ "$output" -eq 2 ]
  # 全 argv に必須フラグが含まれる
  run _all_argv
  [[ "$output" == *"-p"* ]]
  [[ "$output" == *"--output-format"* ]]
  [[ "$output" == *"stream-json"* ]]
  [[ "$output" == *"--permission-mode"* ]]
  [[ "$output" == *"auto"* ]]
  [[ "$output" == *"--model"* ]]
  [[ "$output" == *"--effort"* ]]
  [[ "$output" != *"bypassPermissions"* ]]
  [[ "$output" != *"dontAsk"* ]]
  # --print + stream-json は --verbose 必須 (claude CLI 契約・ライブスモーク回帰)
  [[ "$output" == *"--verbose"* ]]
  [[ "$output" != *"--dangerously-skip-permissions"* ]]
}

@test "並列: stagger=0 で起動順序 (cto → qa) が保たれる" {
  run bash "$LP" Demo --roles cto,qa --stagger 0 --duration 1
  [ "$status" -eq 0 ]
  # 親が stdout へ出す 🚀 マーカーの順序を確認
  local cto_line qa_line
  cto_line="$(printf '%s\n' "$output" | grep -n '🚀 \[1\] cto' | head -1 | cut -d: -f1)"
  qa_line="$(printf '%s\n'  "$output" | grep -n '🚀 \[2\] qa'  | head -1 | cut -d: -f1)"
  [ -n "$cto_line" ]
  [ -n "$qa_line" ]
  [ "$cto_line" -lt "$qa_line" ]
}

@test "並列: role 不在は起動前に明示エラー + 非ゼロ終了" {
  run bash "$LP" Demo --roles cto,bogus --stagger 0 --duration 1
  [ "$status" -ne 0 ]
  [[ "$output" == *"ロールファイル不在"* ]]
  # 起動前に弾くため claude は呼ばれない
  run bash -c 'ls "'"$CLAUDE_ARGV_DIR"'"/argv-* 2>/dev/null | wc -l'
  [ "$output" -eq 0 ]
}

# =========================================================
# 統合: headless 課金経路 (CLAUDEOS_HEADLESS_AUTH)
# =========================================================
@test "billing: 既定 (subscription) は両ロールの claude 環境から鍵を外す" {
  run env ANTHROPIC_API_KEY=dummy-key-xxxx \
    bash "$LP" Demo --roles cto,qa --stagger 0 --duration 1
  [ "$status" -eq 0 ]
  run _all_env
  # 2 ロールとも ABSENT、PRESENT は 1 件も無い
  [[ "$output" != *"PRESENT"* ]]
  [[ "$output" == *"ABSENT"* ]]
}

@test "billing: api-key 指定は両ロールが ANTHROPIC_API_KEY を保持する" {
  run env CLAUDEOS_HEADLESS_AUTH=api-key ANTHROPIC_API_KEY=dummy-key-xxxx \
    bash "$LP" Demo --roles cto,qa --stagger 0 --duration 1
  [ "$status" -eq 0 ]
  run _all_env
  [[ "$output" != *"ABSENT"* ]]
  [[ "$output" == *"PRESENT"* ]]
}

@test "billing/dry-run: subscription は env -u プレフィックスを表示する" {
  run env ANTHROPIC_API_KEY=dummy-key-xxxx bash "$LP" Demo --roles cto --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"env -u ANTHROPIC_API_KEY"* ]]
}

@test "billing/dry-run: api-key は env -u プレフィックスを表示しない" {
  run env CLAUDEOS_HEADLESS_AUTH=api-key bash "$LP" Demo --roles cto --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" != *"ANTHROPIC_API_KEY"* ]]
}

# =========================================================
# dry-run: 実起動なし
# =========================================================
@test "dry-run: 計画のみ出力し claude を起動しない" {
  run bash "$LP" Demo --roles cto,qa --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY-RUN 完了"* ]]
  run bash -c 'ls "'"$CLAUDE_ARGV_DIR"'"/argv-* 2>/dev/null | wc -l'
  [ "$output" -eq 0 ]
}

@test "引数検証: --stagger に非整数で明示エラー" {
  run bash "$LP" Demo --roles cto --stagger abc
  [ "$status" -ne 0 ]
  [[ "$output" == *"--stagger は非負整数"* ]]
}
