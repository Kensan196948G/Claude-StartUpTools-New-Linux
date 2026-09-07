#!/usr/bin/env bats
# ============================================================
# claude-capability.bats — lib/claude-capability.sh のユニットテスト
#
# 検証観点:
#   - version 取得 / semver 比較
#   - --help ベースの flag / subcommand probe (偽 claude で密閉)
#   - capability 判定 (flag / subcommand / env / unverified=unknown)
#   - version policy (supported / below-minimum / newer-than-tested)
#   - --help キャッシュ (version 別ファイル)
# ============================================================

load '../helpers/common-setup'

setup() {
  _bats_common_setup
  export CCSU_HOME="$TEST_TEMP/home"
  export CCSU_CLAUDE_CAP_CACHE_DIR="$TEST_TEMP/cache"
  export CCSU_CLAUDE_COMPAT_FILE="$TEST_TEMP/compat.json"
  cat > "$CCSU_CLAUDE_COMPAT_FILE" <<'JSON'
{
  "versions": { "minimumSupported": "2.1.224", "recommended": "2.1.263", "tested": "2.1.263" },
  "capabilities": [
    { "id": "session-name",       "status": "GA",      "probe": { "type": "flag", "value": "--name" } },
    { "id": "background-session", "status": "preview", "probe": { "type": "flag", "value": "--bg" } },
    { "id": "agents-subcommand",  "status": "preview", "probe": { "type": "subcommand", "value": "agents" } },
    { "id": "stop-subcommand",    "status": "preview", "probe": { "type": "subcommand", "value": "stop" } },
    { "id": "channels",           "status": "preview", "probe": { "type": "flag", "value": "--channels" } },
    { "id": "agent-teams",        "status": "exp",     "probe": { "type": "env", "value": "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS" } },
    { "id": "goal-command",       "status": "GA",      "probe": { "type": "unverified" } },
    { "id": "ver-gate",           "status": "GA",      "probe": { "type": "version", "value": "2.1.250" } }
  ]
}
JSON
  make_stub_bin claude '
case "$1" in
  --version) echo "2.1.263 (Claude Code)";;
  --help) cat <<EOF
Usage: claude [options] [command] [prompt]

Options:
  --bg, --background                    Start the session in the background
  -n, --name <name>                     Set a display name for this session
  --permission-mode <mode>              Permission mode to use for the session
  --namespace-x                         not the --name flag

Commands:
  agents [options]                      Manage background agents
  stop|kill <id>                        Stop a background session
  doctor                                Check the health

EOF
  ;;
esac'
  source "$REPO_ROOT/lib/common.sh"
  source "$REPO_ROOT/lib/claude-capability.sh"
}
teardown() { _bats_common_teardown; }

# ---- version ---------------------------------------------
@test "ccsu_claude_version: --version から X.Y.Z を抽出" {
  run ccsu_claude_version; [ "$status" -eq 0 ]; [ "$output" = "2.1.263" ]
}
@test "ccsu_version_ge: 等しい / 大きい / 小さい" {
  ccsu_version_ge 2.1.263 2.1.263
  ccsu_version_ge 2.1.263 2.1.99
  ccsu_version_ge 2.10.0 2.9.9
  ! ccsu_version_ge 2.1.224 2.1.225
}

# ---- flag / subcommand probe -----------------------------
@test "ccsu_claude_has_flag: 存在する flag は 0" { ccsu_claude_has_flag --name; ccsu_claude_has_flag --bg; }
@test "ccsu_claude_has_flag: 部分一致 (--namespace-x) では --names を誤検出しない" { ! ccsu_claude_has_flag --names; }
@test "ccsu_claude_has_flag: 存在しない flag は 1" { ! ccsu_claude_has_flag --channels; }
@test "ccsu_claude_has_subcommand: Commands 節の subcommand を検出 (alias 形式 stop|kill も)" {
  ccsu_claude_has_subcommand agents
  ccsu_claude_has_subcommand stop
  ccsu_claude_has_subcommand kill
  ! ccsu_claude_has_subcommand attach
}

# ---- capability ------------------------------------------
@test "ccsu_claude_capability: flag/subcommand probe が available" {
  run ccsu_claude_cap_status session-name;       [ "$output" = "available" ]
  run ccsu_claude_cap_status agents-subcommand;  [ "$output" = "available" ]
}
@test "ccsu_claude_capability: 未搭載 flag は missing" {
  run ccsu_claude_cap_status channels; [ "$output" = "missing" ]
  run ccsu_claude_capability channels; [ "$status" -eq 1 ]
}
@test "ccsu_claude_capability: unverified は unknown (rc=2)" {
  run ccsu_claude_capability goal-command; [ "$status" -eq 2 ]
  run ccsu_claude_cap_status goal-command; [ "$output" = "unknown" ]
}
@test "ccsu_claude_capability: env probe は環境変数で判定" {
  unset CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS
  run ccsu_claude_cap_status agent-teams; [ "$output" = "missing" ]
  CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 run ccsu_claude_cap_status agent-teams; [ "$output" = "available" ]
}
@test "ccsu_claude_capability: version probe は installed >= value" {
  run ccsu_claude_cap_status ver-gate; [ "$output" = "available" ]
}
@test "ccsu_claude_capability: 未定義 id は unknown" {
  run ccsu_claude_capability no-such-cap; [ "$status" -eq 2 ]
}

# ---- version policy --------------------------------------
@test "ccsu_claude_version_policy: tested と同一は supported" {
  run ccsu_claude_version_policy; [ "$output" = "supported" ]
}
@test "ccsu_claude_version_policy: minimum 未満は below-minimum (rc=1)" {
  make_stub_bin claude 'case "$1" in --version) echo "2.1.200";; --help) echo "Options:";; esac'
  run ccsu_claude_version_policy; [ "$status" -eq 1 ]; [ "$output" = "below-minimum" ]
}
@test "ccsu_claude_version_policy: tested より新しい版は newer-than-tested (rc=0)" {
  make_stub_bin claude 'case "$1" in --version) echo "2.2.0";; --help) echo "Options:";; esac'
  run ccsu_claude_version_policy; [ "$status" -eq 0 ]; [ "$output" = "newer-than-tested" ]
}

# ---- matrix / json / cache -------------------------------
@test "ccsu_claude_compat_matrix: TSV 4列で全 capability を列挙" {
  run ccsu_claude_compat_matrix
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l)" -eq 8 ]
  [[ "$output" == *$'session-name\tGA\tflag:--name\tavailable'* ]]
}
@test "ccsu_claude_compat_json: 妥当な JSON で version/policy/capabilities を持つ" {
  run ccsu_claude_compat_json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.version == "2.1.263" and .policy == "supported" and .capabilities["session-name"] == "available" and .capabilities["goal-command"] == "unknown"'
}
@test "ccsu_claude_help: version 別キャッシュファイルを作成し 2 回目は再 probe しない" {
  ccsu_claude_help >/dev/null
  [ -s "$CCSU_CLAUDE_CAP_CACHE_DIR/claude-help-2.1.263.txt" ]
  make_stub_bin claude 'case "$1" in --version) echo "2.1.263";; --help) echo "BROKEN";; esac'
  unset _CCSU_CLAUDE_HELP_CACHE; _CCSU_CLAUDE_HELP_CACHE=""
  run ccsu_claude_has_flag --name; [ "$status" -eq 0 ]
}
@test "diag-claude-compat.sh --json: 実行できて JSON を返す" {
  run bash "$REPO_ROOT/libexec/diag-claude-compat.sh" --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.policy == "supported"'
}
