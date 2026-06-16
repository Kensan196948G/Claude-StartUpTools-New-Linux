#!/usr/bin/env bats
# ============================================================
# launch-parallel.bats — PR-F 並列ロール起動 (launch-parallel-cron.sh)
#
# 検証観点 (プラン欠落5 c):
#   [単体] lp__role_to_file / lp__parse_roles / lp__distribute_roles の純粋関数
#   [統合] 偽 claude/timeout で課金なし実走:
#     - CTO/QA 双方が `-p` + `--output-format stream-json` + `--permission-mode dontAsk` で起動
#     - --dangerously-skip-permissions は付かない (headless では不要)
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

  # 偽プロジェクト Demo
  PROJECT_DIR="$LP_PROJECTS_BASE/Demo"
  mkdir -p "$PROJECT_DIR/.claude"

  # 偽 claude: argv を PID 別ファイルへ記録 + 固定 stream-json を stdout へ
  CLAUDE_ARGV_DIR="$TEST_TEMP/claude-argv"; mkdir -p "$CLAUDE_ARGV_DIR"
  cat > "$STUB_BIN/claude" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$CLAUDE_ARGV_DIR/argv-\$\$"
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
@test "並列: CTO/QA 双方が -p / stream-json / dontAsk で起動し skip-permissions は付かない" {
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
  [[ "$output" == *"dontAsk"* ]]
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
