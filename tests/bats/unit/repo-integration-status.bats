#!/usr/bin/env bats
# ============================================================
# repo-integration-status.bats — bin/repo-integration-status.sh のテスト
#
# 検証観点:
#   - ruleset の「なし」と「unknown」を取り違えない（API 失敗は unknown）
#   - open PR 件数を Link ヘッダ（rel="last"）から数える
#   - CLEAN+green だけを列挙する（BLOCKED / draft / 失敗チェックは除外）
#   - --json の最終行 1 行が仕様どおりのキーと集計値を持つ
#   - 台帳サマリの取り込みと、取得できない場合の縮退（exit 0 のまま）
#   - 引数エラーは exit 2、gh 不在・repo 一覧失敗は exit 1
#
# 隔離: gh は CCSU_GH_BIN のスタブ、node もスタブ。実ネットワークに出ない。
# ============================================================

load '../helpers/common-setup'

setup() {
  _bats_common_setup

  SCRIPT="$REPO_ROOT/bin/repo-integration-status.sh"
  FIX="$TEST_TEMP/fix"
  STUB_LOG="$TEST_TEMP/gh-calls.log"
  mkdir -p "$FIX/rulesets" "$FIX/pulls" "$FIX/prs"
  : > "$STUB_LOG"
  export FIX STUB_LOG

  # 既定では台帳スクリプトを「無い」状態にして実 node/実ネットワークを避ける
  export CCSU_REGISTRY_SCRIPT="$TEST_TEMP/no-such-registry.js"

  # gh スタブ: 引数に応じて fixtures を返す。失敗は .fail マーカーで表現する。
  STUB_GH="$TEST_TEMP/gh"
  cat > "$STUB_GH" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG"
fix="$FIX"
case "$1" in
  repo) cat "$fix/repos.json" ;;
  api)
    shift
    inc=0
    if [ "${1:-}" = "--include" ]; then inc=1; shift; fi
    path="${1:-}"
    rel="${path#repos/}"; owner="${rel%%/*}"; rest="${rel#*/}"
    repo="${rest%%/*}"; tail="${rest#*/}"
    case "$tail" in
      rulesets)
        [ -f "$fix/rulesets/$repo.fail" ] && exit 1
        cat "$fix/rulesets/$repo.json" ;;
      rulesets/*)
        id="${tail##*/}"
        [ -f "$fix/rulesets/$repo.detailfail" ] && exit 1
        cat "$fix/rulesets/$repo-$id.json" ;;
      *)
        case "$path" in
          *"/pulls?state=open"*)
            [ -f "$fix/pulls/$repo.fail" ] && exit 1
            if [ "$inc" = "1" ]; then cat "$fix/pulls/$repo.headers"; else cat "$fix/pulls/$repo.body"; fi ;;
          *) exit 1 ;;
        esac ;;
    esac ;;
  pr)
    shift
    repo=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -R) repo="${2#*/}"; shift 2 ;;
        *) shift ;;
      esac
    done
    [ -f "$fix/prs/$repo.fail" ] && exit 1
    cat "$fix/prs/$repo.json" ;;
  *) exit 1 ;;
esac
STUB
  chmod +x "$STUB_GH"
  export CCSU_GH_BIN="$STUB_GH"
}

teardown() { _bats_common_teardown; }

# ── fixture ヘルパ ─────────────────────────────────────────
repos_json() { printf '[%s]\n' "$1" > "$FIX/repos.json"; }
# ruleset_ok <repo> <json>  (named reposets 用に name を埋める)
ruleset_ok() { printf '%s\n' "$2" > "$FIX/rulesets/$1.json"; }
ruleset_fail() { : > "$FIX/rulesets/$1.fail"; }
ruleset_detail() { printf '%s\n' "$3" > "$FIX/rulesets/$1-$2.json"; }
pulls_fail() { : > "$FIX/pulls/$1.fail"; }
prs_json() { printf '%s\n' "$2" > "$FIX/prs/$1.json"; }

# pulls_count <repo> <n>
pulls_count() {
  local repo="$1" n="$2"
  if [ "$n" -le 1 ]; then
    if [ "$n" -eq 1 ]; then
      printf 'HTTP/2.0 200 OK\n\n[{"number":1}]\n' > "$FIX/pulls/$repo.headers"
    else
      printf 'HTTP/2.0 200 OK\n\n[]\n' > "$FIX/pulls/$repo.headers"
    fi
  else
    printf 'HTTP/2.0 200 OK\nLink: <https://api.github.com/repositories/1/pulls?state=open&per_page=1&page=2>; rel="next", <https://api.github.com/repositories/1/pulls?state=open&per_page=1&page=%s>; rel="last"\n\n[{"number":1}]\n' "$n" \
      > "$FIX/pulls/$repo.headers"
  fi
}

last_json() { printf '%s\n' "$1" | tail -1; }

# ── 引数まわり ─────────────────────────────────────────────
@test "repo-integration-status: --help は使い方を出して exit 0" {
  run bash "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"repo-integration-status.sh [--json] [--limit N] [--owner OWNER]"* ]]
}

@test "repo-integration-status: 不明な引数は exit 2" {
  run bash "$SCRIPT" --bogus
  [ "$status" -eq 2 ]
  [[ "$output" == *"不明な引数"* ]]
}

@test "repo-integration-status: --limit 0 は exit 2" {
  run bash "$SCRIPT" --limit 0
  [ "$status" -eq 2 ]
}

@test "repo-integration-status: 不正な --owner は exit 2" {
  run bash "$SCRIPT" --owner 'bad owner'
  [ "$status" -eq 2 ]
}

# ── 失敗経路 ───────────────────────────────────────────────
@test "repo-integration-status: repo 一覧が空なら exit 1" {
  repos_json ""
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
}

@test "repo-integration-status: gh が見つからなければ exit 1" {
  export CCSU_GH_BIN="$TEST_TEMP/definitely-not-gh"
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"gh CLI が見つかりません"* ]]
}

# ── ruleset 判定 ───────────────────────────────────────────
@test "repo-integration-status: central-auto-merge と必須チェック名を表示する" {
  repos_json '{"name":"RepoA"}'
  ruleset_ok RepoA '[{"id":101,"name":"central-auto-merge","target":"branch","enforcement":"active"}]'
  ruleset_detail RepoA 101 '{"rules":[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"linux-validate"},{"context":"Secrets scan (gitleaks)"}]}}]}'
  pulls_count RepoA 0
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"central-auto-merge 1 / 別名 0 / なし 0 / unknown 0"* ]]
}

@test "repo-integration-status: ruleset なしは ruleset_missing に数え unknown にしない" {
  repos_json '{"name":"RepoA"}'
  ruleset_ok RepoA '[]'
  pulls_count RepoA 0
  run bash "$SCRIPT" --json
  [ "$status" -eq 0 ]
  LAST="$(last_json "$output")"
  echo "$LAST" | jq -e '.ruleset_missing == 1 and .unknown == 0'
}

@test "repo-integration-status: ruleset API 失敗は unknown にし なし と混同しない" {
  repos_json '{"name":"RepoA"}'
  ruleset_fail RepoA
  pulls_count RepoA 0
  run bash "$SCRIPT" --json
  [ "$status" -eq 0 ]
  LAST="$(last_json "$output")"
  echo "$LAST" | jq -e '.unknown == 1 and .ruleset_missing == 0'
  [[ "$LAST" == *'"unknown":1'* ]]
}

@test "repo-integration-status: 別名 ruleset は other として区別する" {
  repos_json '{"name":"RepoA"}'
  ruleset_ok RepoA '[{"id":7,"name":"main-protection","target":"branch","enforcement":"active"}]'
  ruleset_detail RepoA 7 '{"rules":[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"quality"}]}}]}'
  pulls_count RepoA 0
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"central-auto-merge 0 / 別名 1 / なし 0 / unknown 0"* ]]
  [[ "$output" == *"main-protection"* ]]
}

# ── open PR 件数 ───────────────────────────────────────────
@test "repo-integration-status: open PR 件数を Link ヘッダの last から数える" {
  repos_json '{"name":"RepoA"}'
  ruleset_ok RepoA '[]'
  pulls_count RepoA 7
  prs_json RepoA '[]'
  run bash "$SCRIPT" --json
  [ "$status" -eq 0 ]
  last_json "$output" | jq -e '.open_prs == 7'
}

@test "repo-integration-status: Link ヘッダが無く 1 件なら 1 と数える" {
  repos_json '{"name":"RepoA"}'
  ruleset_ok RepoA '[]'
  pulls_count RepoA 1
  prs_json RepoA '[]'
  run bash "$SCRIPT" --json
  [ "$status" -eq 0 ]
  last_json "$output" | jq -e '.open_prs == 1'
}

# ── CLEAN+green ────────────────────────────────────────────
@test "repo-integration-status: CLEAN+green のみ列挙し BLOCKED/draft/失敗 を除外する" {
  repos_json '{"name":"RepoA"}'
  ruleset_ok RepoA '[]'
  pulls_count RepoA 4
  prs_json RepoA '[{"number":11,"title":"good","mergeStateStatus":"CLEAN","isDraft":false,"statusCheckRollup":[{"conclusion":"SUCCESS"}]},
                  {"number":12,"title":"blocked","mergeStateStatus":"BLOCKED","isDraft":false,"statusCheckRollup":[{"conclusion":"SUCCESS"}]},
                  {"number":13,"title":"draft","mergeStateStatus":"CLEAN","isDraft":true,"statusCheckRollup":[{"conclusion":"SUCCESS"}]},
                  {"number":14,"title":"red","mergeStateStatus":"CLEAN","isDraft":false,"statusCheckRollup":[{"conclusion":"FAILURE"}]}]'
  run bash "$SCRIPT" --json
  [ "$status" -eq 0 ]
  LAST="$(last_json "$output")"
  echo "$LAST" | jq -e '.clean_green == 1'
  [[ "$output" == *"#11"* ]]
  [[ "$output" != *"#12"* ]]
  [[ "$output" != *"#13"* ]]
  [[ "$output" != *"#14"* ]]
}

@test "repo-integration-status: PR 一覧の取得に失敗した repo は unknown に数える" {
  repos_json '{"name":"RepoA"}'
  ruleset_ok RepoA '[]'
  pulls_fail RepoA
  run bash "$SCRIPT" --json
  [ "$status" -eq 0 ]
  last_json "$output" | jq -e '.unknown == 1'
}

# ── --json の形 ────────────────────────────────────────────
@test "repo-integration-status: --json 最終行が仕様のキーと集計値を持つ" {
  repos_json '{"name":"RepoA"},{"name":"RepoB"}'
  ruleset_ok RepoA '[{"id":1,"name":"central-auto-merge","target":"branch","enforcement":"active"}]'
  ruleset_detail RepoA 1 '{"rules":[]}'
  pulls_count RepoA 3
  prs_json RepoA '[{"number":1,"title":"x","mergeStateStatus":"CLEAN","isDraft":false,"statusCheckRollup":[{"conclusion":"SUCCESS"}]}]'
  ruleset_ok RepoB '[]'
  pulls_count RepoB 0
  run bash "$SCRIPT" --json --owner OtherOwner --limit 5
  [ "$status" -eq 0 ]
  LAST="$(last_json "$output")"
  echo "$LAST" | jq -e 'has("ok") and has("owner") and has("repos") and has("ruleset_missing") and has("open_prs") and has("clean_green") and has("registry") and has("unknown")'
  echo "$LAST" | jq -e '.ok == true and .owner == "OtherOwner" and .repos == 2 and .ruleset_missing == 1 and .open_prs == 3 and .clean_green == 1 and .unknown == 0'
}

@test "repo-integration-status: --limit/--owner が gh repo list へ渡る" {
  repos_json '{"name":"RepoA"}'
  ruleset_ok RepoA '[]'
  pulls_count RepoA 0
  run bash "$SCRIPT" --owner AnotherOwner --limit 5
  [ "$status" -eq 0 ]
  grep -q 'repo list AnotherOwner --limit 5 --json name' "$STUB_LOG"
}

# ── 台帳サマリ ─────────────────────────────────────────────
@test "repo-integration-status: 台帳スクリプトが無ければ registry.ok=false でも exit 0" {
  repos_json '{"name":"RepoA"}'
  ruleset_ok RepoA '[]'
  pulls_count RepoA 0
  run bash "$SCRIPT" --json
  [ "$status" -eq 0 ]
  last_json "$output" | jq -e '.registry.ok == false'
}

@test "repo-integration-status: 台帳サマリを JSON に取り込む" {
  repos_json '{"name":"RepoA"}'
  ruleset_ok RepoA '[]'
  pulls_count RepoA 0
  : > "$TEST_TEMP/registry.js"
  make_stub_bin node 'printf "%s\n" "{\"ok\":true,\"linux\":{\"registered\":9,\"missing\":[]},\"github\":{\"total\":7,\"missing\":[]}}"'
  export CCSU_REGISTRY_SCRIPT="$TEST_TEMP/registry.js"
  export CCSU_NODE_BIN="$STUB_BIN/node"
  run bash "$SCRIPT" --json
  [ "$status" -eq 0 ]
  last_json "$output" | jq -e '.registry.ok == true and .registry.linux.registered == 9 and .registry.github.total == 7'
}

@test "repo-integration-status: 台帳の JSON が壊れていても落ちない" {
  repos_json '{"name":"RepoA"}'
  ruleset_ok RepoA '[]'
  pulls_count RepoA 0
  : > "$TEST_TEMP/registry.js"
  make_stub_bin node 'printf "%s\n" "not-json"'
  export CCSU_REGISTRY_SCRIPT="$TEST_TEMP/registry.js"
  export CCSU_NODE_BIN="$STUB_BIN/node"
  run bash "$SCRIPT" --json
  [ "$status" -eq 0 ]
  last_json "$output" | jq -e '.registry.ok == false'
}
