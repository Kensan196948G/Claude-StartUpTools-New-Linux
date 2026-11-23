#!/usr/bin/env bats
# ============================================================
# cross-repo-automerge.bats — bin/cross-repo-automerge.sh のテスト
#
# 検証観点:
#   - ruleset を持たない repo には触らない
#   - 既定除外（Codex-StartUpTools / open-design）と --exclude が効く
#   - dependabot/renovate のマイナー・パッチだけが対象（メジャー・判定不能は human）
#   - draft / 人間の PR は触らない
#   - BEHIND → update-branch / CLEAN → merge / 失敗・競合はスキップ
#   - 同一 repo 1 回 1 件、--max-merges 上限
#   - --dry-run は書き込み系 gh を一切呼ばない（呼び出しログ検査）
#   - flock で二重実行を防ぐ
#
# 隔離: gh は CCSU_GH_BIN のスタブ。実ネットワーク・実 repo に触れない。
# ============================================================

load '../helpers/common-setup'

setup() {
  _bats_common_setup
  SCRIPT="$REPO_ROOT/bin/cross-repo-automerge.sh"
  FIX="$TEST_TEMP/fix"
  STUB_LOG="$TEST_TEMP/gh-calls.log"
  mkdir -p "$FIX/rulesets" "$FIX/prs"
  : > "$STUB_LOG"
  export FIX STUB_LOG

  export CLAUDEOS_HOME="$TEST_TEMP/home"
  export CCSU_AUTOMERGE_LOCK="$TEST_TEMP/automerge.lock"
  export CCSU_AUTOMERGE_LOG_DIR="$TEST_TEMP/home/logs"

  STUB_GH="$TEST_TEMP/gh"
  cat > "$STUB_GH" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG"
fix="$FIX"
case "$1" in
  repo) cat "$fix/repos.json" ;;
  api)
    # PUT .../pulls/<n>/update-branch は更新系。失敗注入が無ければ成功
    case "$*" in
      *update-branch*)
        [ -f "$fix/fail_api_update" ] && { echo "gh: cannot update" >&2; exit 1; }
        echo '{"message":"Updating pull request branch."}'; exit 0 ;;
    esac
    rel="${2#repos/}"; rest="${rel#*/}"; repo="${rest%%/*}"
    if [ -f "$fix/rulesets/$repo.json" ]; then cat "$fix/rulesets/$repo.json"; else exit 1; fi ;;
  pr)
    sub="$2"; repo=""; prev=""
    for a in "$@"; do [ "$prev" = "-R" ] && repo="${a#*/}"; prev="$a"; done
    case "$sub" in
      list) if [ -f "$fix/prs/$repo.json" ]; then cat "$fix/prs/$repo.json"; else echo '[]'; fi ;;
      update-branch|merge)
        [ -f "$fix/failwrite" ] && { echo "gh: rejected" >&2; exit 1; }
        exit 0 ;;
      *) exit 1 ;;
    esac ;;
  *) exit 1 ;;
esac
STUB
  chmod +x "$STUB_GH"
  export CCSU_GH_BIN="$STUB_GH"
}

teardown() { _bats_common_teardown; }

# ── fixtures ──────────────────────────────────────────────
# gh repo list --json name は配列を返す（実 gh に合わせる）
repos_json() { printf '[%s]\n' "$1" > "$FIX/repos.json"; }
has_ruleset() { printf '%s\n' '[{"id":1,"name":"central-auto-merge","target":"branch","enforcement":"active"}]' > "$FIX/rulesets/$1.json"; }
no_ruleset() { printf '[]\n' > "$FIX/rulesets/$1.json"; }
prs_json() { printf '%s\n' "$2" > "$FIX/prs/$1.json"; }
last_json() { printf '%s\n' "$1" | tail -1; }

# bot PR 1 件を作る（title / createdAt 等は最小限）
bot_pr() { # $1=number $2=title $3=state $4=conclusion
  printf '{"number":%s,"title":"%s","author":{"login":"app/dependabot"},"isDraft":false,"mergeStateStatus":"%s","statusCheckRollup":[{"conclusion":"%s","status":"COMPLETED"}]}' \
    "$1" "$2" "$3" "${4:-SUCCESS}"
}

# ── 引数 ───────────────────────────────────────────────────
@test "cross-repo-automerge: --help は使い方と既定 dry-run を出す" {
  run bash "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--dry-run"* ]]
  [[ "$output" == *"--apply"* ]]
  [[ "$output" == *"依存"* || "$output" == *"dependabot"* ]]
}

@test "cross-repo-automerge: 不正な引数は exit 2" {
  run bash "$SCRIPT" --bogus
  [ "$status" -eq 2 ]
}

@test "cross-repo-automerge: --max-merges に非数値は exit 2" {
  run bash "$SCRIPT" --max-merges abc
  [ "$status" -eq 2 ]
}

# ── 対象 repo の決め方 ────────────────────────────────────
@test "cross-repo-automerge: ruleset を持たない repo には触らない" {
  repos_json '{"name":"NoRuleset"},{"name":"WithRuleset"}'
  no_ruleset NoRuleset
  has_ruleset WithRuleset
  prs_json NoRuleset "[$(bot_pr 1 'chore(deps): bump lodash from 4.17.0 to 4.17.21' CLEAN)]"
  prs_json WithRuleset '[]'
  run bash "$SCRIPT" --json
  [ "$status" -eq 0 ]
  LAST="$(last_json "$output")"
  echo "$LAST" | jq -e '.repos_scanned == 1'
  # NoRuleset の PR 一覧は取得すらされない
  ! grep -q 'pr list -R Kensan196948G/NoRuleset' "$STUB_LOG"
}

@test "cross-repo-automerge: 既定除外の Codex-StartUpTools と open-design は触らない" {
  repos_json '{"name":"Codex-StartUpTools"},{"name":"open-design"},{"name":"Live"}'
  has_ruleset Codex-StartUpTools
  has_ruleset open-design
  has_ruleset Live
  prs_json Live '[]'
  run bash "$SCRIPT" --json
  [ "$status" -eq 0 ]
  last_json "$output" | jq -e '.repos_scanned == 1'
  ! grep -q 'pr list -R Kensan196948G/Codex-StartUpTools' "$STUB_LOG"
  ! grep -q 'pr list -R Kensan196948G/open-design' "$STUB_LOG"
}

@test "cross-repo-automerge: --exclude で追加除外できる" {
  repos_json '{"name":"A"},{"name":"B"}'
  has_ruleset A
  has_ruleset B
  prs_json B '[]'
  run bash "$SCRIPT" --exclude A --json
  [ "$status" -eq 0 ]
  last_json "$output" | jq -e '.repos_scanned == 1'
  ! grep -q 'pr list -R Kensan196948G/A' "$STUB_LOG"
}

# ── PR の選別 ──────────────────────────────────────────────
@test "cross-repo-automerge: メジャー bump は human に回す" {
  repos_json '{"name":"R"}'
  has_ruleset R
  prs_json R "[$(bot_pr 5 'chore(deps): bump vite from 7.0.0 to 8.0.0' CLEAN)]"
  run bash "$SCRIPT" --json
  [ "$status" -eq 0 ]
  LAST="$(last_json "$output")"
  echo "$LAST" | jq -e '.human | length == 1'
  echo "$LAST" | jq -e '.human[0].reason == "major_bump"'
  echo "$LAST" | jq -e '.merged | length == 0'
}

@test "cross-repo-automerge: 判定不能なタイトルは human に回す" {
  repos_json '{"name":"R"}'
  has_ruleset R
  prs_json R "[$(bot_pr 6 'chore(deps): update some dependency' CLEAN)]"
  run bash "$SCRIPT" --json
  [ "$status" -eq 0 ]
  LAST="$(last_json "$output")"
  echo "$LAST" | jq -e '.human[0].reason == "unclassified"'
  echo "$LAST" | jq -e '.merged | length == 0'
}

@test "cross-repo-automerge: draft はスキップする" {
  repos_json '{"name":"R"}'
  has_ruleset R
  prs_json R '[{"number":7,"title":"chore(deps): bump lodash from 4.17.0 to 4.17.21","author":{"login":"dependabot[bot]"},"isDraft":true,"mergeStateStatus":"CLEAN","statusCheckRollup":[{"conclusion":"SUCCESS"}]}]'
  run bash "$SCRIPT" --json
  [ "$status" -eq 0 ]
  LAST="$(last_json "$output")"
  echo "$LAST" | jq -e '.skipped[0].reason == "draft"'
  echo "$LAST" | jq -e '.merged | length == 0'
}

@test "cross-repo-automerge: 人間の PR は記録もしない（触らない）" {
  repos_json '{"name":"R"}'
  has_ruleset R
  prs_json R '[{"number":8,"title":"chore(deps): bump lodash from 4.17.0 to 4.17.21","author":{"login":"Kensan196948G"},"isDraft":false,"mergeStateStatus":"CLEAN","statusCheckRollup":[{"conclusion":"SUCCESS"}]}]'
  run bash "$SCRIPT" --json
  [ "$status" -eq 0 ]
  LAST="$(last_json "$output")"
  echo "$LAST" | jq -e '.merged | length == 0'
  echo "$LAST" | jq -e '.skipped | length == 0'
  echo "$LAST" | jq -e '.human | length == 0'
}

# ── 動作の振り分け ────────────────────────────────────────
@test "cross-repo-automerge: CLEAN で失敗0・保留0 なら merge 対象（dry-run では実行しない）" {
  repos_json '{"name":"R"}'
  has_ruleset R
  prs_json R "[$(bot_pr 10 'chore(deps): bump lodash from 4.17.0 to 4.17.21' CLEAN SUCCESS)]"
  run bash "$SCRIPT" --json
  [ "$status" -eq 0 ]
  LAST="$(last_json "$output")"
  echo "$LAST" | jq -e '.merged | length == 1'
  echo "$LAST" | jq -e '.merged[0].pr == 10'
  # dry-run なので merge は呼ばれない
  ! grep -q 'pr merge' "$STUB_LOG"
}

@test "cross-repo-automerge: BEHIND は update 対象（dry-run では実行しない）" {
  repos_json '{"name":"R"}'
  has_ruleset R
  prs_json R "[$(bot_pr 11 'chore(deps): bump lodash from 4.17.0 to 4.17.21' BEHIND SUCCESS)]"
  run bash "$SCRIPT" --json
  [ "$status" -eq 0 ]
  LAST="$(last_json "$output")"
  echo "$LAST" | jq -e '.updated | length == 1'
  echo "$LAST" | jq -e '.updated[0].pr == 11'
  # dry-run では更新系 API を呼ばない（gh 2.45 に `pr update-branch` は無いため REST を使う）
  ! grep -q 'update-branch' "$STUB_LOG"
}

@test "cross-repo-automerge: 失敗チェックがある PR はスキップする" {
  repos_json '{"name":"R"}'
  has_ruleset R
  prs_json R "[$(bot_pr 12 'chore(deps): bump lodash from 4.17.0 to 4.17.21' CLEAN FAILURE)]"
  run bash "$SCRIPT" --json
  [ "$status" -eq 0 ]
  last_json "$output" | jq -e '.skipped[0].reason == "checks_failed"'
}

@test "cross-repo-automerge: 競合(DIRTY)はスキップする" {
  repos_json '{"name":"R"}'
  has_ruleset R
  prs_json R "[$(bot_pr 13 'chore(deps): bump lodash from 4.17.0 to 4.17.21' DIRTY SUCCESS)]"
  run bash "$SCRIPT" --json
  [ "$status" -eq 0 ]
  last_json "$output" | jq -e '.skipped[0].reason == "conflict"'
}

@test "cross-repo-automerge: 保留中のチェックがある BLOCKED はスキップする" {
  repos_json '{"name":"R"}'
  has_ruleset R
  prs_json R '[{"number":14,"title":"chore(deps): bump lodash from 4.17.0 to 4.17.21","author":{"login":"renovate[bot]"},"isDraft":false,"mergeStateStatus":"BLOCKED","statusCheckRollup":[{"conclusion":"","status":"IN_PROGRESS"}]}]'
  run bash "$SCRIPT" --json
  [ "$status" -eq 0 ]
  last_json "$output" | jq -e '.skipped[0].reason == "checks_pending"'
}

# ── 上限 ───────────────────────────────────────────────────
@test "cross-repo-automerge: 同一 repo では 1 回に 1 件だけ merge する" {
  repos_json '{"name":"R"}'
  has_ruleset R
  prs_json R "[$(bot_pr 20 'chore(deps): bump a from 1.0.0 to 1.0.1' CLEAN),$(bot_pr 21 'chore(deps): bump b from 2.0.0 to 2.0.1' CLEAN)]"
  run bash "$SCRIPT" --json
  [ "$status" -eq 0 ]
  LAST="$(last_json "$output")"
  echo "$LAST" | jq -e '.merged | length == 1'
  echo "$LAST" | jq -e '[.skipped[].reason] | index("repo_limit_reached") != null'
}

@test "cross-repo-automerge: --max-merges で全体の上限を掛ける" {
  repos_json '{"name":"A"},{"name":"B"}'
  has_ruleset A
  has_ruleset B
  prs_json A "[$(bot_pr 30 'chore(deps): bump a from 1.0.0 to 1.0.1' CLEAN)]"
  prs_json B "[$(bot_pr 31 'chore(deps): bump b from 2.0.0 to 2.0.1' CLEAN)]"
  run bash "$SCRIPT" --max-merges 1 --json
  [ "$status" -eq 0 ]
  LAST="$(last_json "$output")"
  echo "$LAST" | jq -e '.merged | length == 1'
  echo "$LAST" | jq -e '[.skipped[].reason] | index("max_merges_reached") != null'
}

# ── 安全弁 ─────────────────────────────────────────────────
@test "cross-repo-automerge: --json が仕様のキーを持つ" {
  repos_json '{"name":"R"}'
  has_ruleset R
  prs_json R '[]'
  run bash "$SCRIPT" --json
  [ "$status" -eq 0 ]
  LAST="$(last_json "$output")"
  echo "$LAST" | jq -e 'has("ok") and has("mode") and has("repos_scanned")'
  echo "$LAST" | jq -e 'has("merged") and has("updated") and has("skipped") and has("human")'
  echo "$LAST" | jq -e '.ok == true and .mode == "dry-run"'
}

@test "cross-repo-automerge: dry-run は書き込み系の gh を一切呼ばない" {
  repos_json '{"name":"R"}'
  has_ruleset R
  prs_json R "[$(bot_pr 40 'chore(deps): bump a from 1.0.0 to 1.0.1' CLEAN),$(bot_pr 41 'chore(deps): bump b from 2.0.0 to 2.0.1' BEHIND)]"
  run bash "$SCRIPT" --json
  [ "$status" -eq 0 ]
  [ -s "$STUB_LOG" ]
  # 書き込み系（merge / update-branch / 再実行 / ruleset 変更 / --admin）は一度も出ない
  ! grep -qE 'pr (merge|update-branch|edit|close|reopen)|run rerun|--admin|-X (POST|PUT|PATCH|DELETE)|--method' "$STUB_LOG"
}

@test "cross-repo-automerge: --apply のときだけ merge / update-branch を呼ぶ" {
  repos_json '{"name":"R"}'
  has_ruleset R
  prs_json R "[$(bot_pr 50 'chore(deps): bump a from 1.0.0 to 1.0.1' CLEAN)]"
  run bash "$SCRIPT" --apply --json
  [ "$status" -eq 0 ]
  LAST="$(last_json "$output")"
  echo "$LAST" | jq -e '.mode == "apply"'
  echo "$LAST" | jq -e '.merged | length == 1'
  grep -q 'pr merge 50' "$STUB_LOG"
  grep -q -- '--squash' "$STUB_LOG"
  # --admin による迂回はしない
  ! grep -q -- '--admin' "$STUB_LOG"
}

@test "cross-repo-automerge: flock で二重実行を拒否する" {
  repos_json '{"name":"R"}'
  has_ruleset R
  prs_json R '[]'
  ( exec 9>"$CCSU_AUTOMERGE_LOCK"; flock -n 9; sleep 3 ) &
  holder=$!
  sleep 1
  run bash "$SCRIPT" --json
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  [ "$status" -eq 1 ]
  last_json "$output" | jq -e '.ok == false and .error == "LOCKED"'
}

@test "cross-repo-automerge: jsonl ログを 1 実行 1 行追記する" {
  repos_json '{"name":"R"}'
  has_ruleset R
  prs_json R '[]'
  run bash "$SCRIPT" --json
  [ "$status" -eq 0 ]
  LOG="$CCSU_AUTOMERGE_LOG_DIR/cross-repo-automerge.jsonl"
  [ -f "$LOG" ]
  [ "$(wc -l < "$LOG" | tr -d ' ')" -eq 1 ]
  jq -e '.mode == "dry-run" and .ok == true' "$LOG"
}

@test "cross-repo-automerge: --apply の BEHIND 更新は REST API を使う（gh 2.45 に pr update-branch は無い）" {
  repos_json '{"name":"R"}'
  has_ruleset R
  prs_json R "[$(bot_pr 31 'chore(deps): bump lodash from 4.17.0 to 4.17.21' BEHIND SUCCESS)]"
  run bash "$SCRIPT" --apply --json
  [ "$status" -eq 0 ]
  # REST の PUT が呼ばれている
  grep -q 'api --method PUT repos/Kensan196948G/R/pulls/31/update-branch' "$STUB_LOG"
  # 存在しないサブコマンドは呼ばれていない
  ! grep -q 'pr update-branch' "$STUB_LOG"
}

@test "cross-repo-automerge: --apply で更新 API が失敗したら update_branch_failed でスキップする" {
  repos_json '{"name":"R"}'
  has_ruleset R
  prs_json R "[$(bot_pr 32 'chore(deps): bump lodash from 4.17.0 to 4.17.21' BEHIND SUCCESS)]"
  : > "$FIX/fail_api_update"
  run bash "$SCRIPT" --apply --json
  [ "$status" -eq 0 ]
  last_json "$output" | jq -e '.skipped | map(.reason) | index("update_branch_failed") != null'
  last_json "$output" | jq -e '.updated | length == 0'
}

@test "cross-repo-automerge: repo 一覧の取得は一過性失敗を再試行する（3 回目で成功）" {
  : > "$FIX/repos_attempts"
  # 1 回目・2 回目は失敗、3 回目は成功する gh スタブに差し替える
  cat > "$STUB_GH" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG"
n=$(cat "$FIX/repos_attempts"); n=$((n+1)); printf '%s' "$n" > "$FIX/repos_attempts"
case "$1" in
  repo) [ "$n" -ge 3 ] && cat "$FIX/repos.json" || exit 1 ;;
  api)  rel="${2#repos/}"; rest="${rel#*/}"; repo="${rest%%/*}"
        if [ -f "$FIX/rulesets/$repo.json" ]; then cat "$FIX/rulesets/$repo.json"; else exit 1; fi ;;
  *) exit 1 ;;
esac
STUB
  chmod +x "$STUB_GH"
  export CCSU_GH_BIN="$STUB_GH"
  repos_json '{"name":"R"}'
  run bash "$SCRIPT" --json
  [ "$status" -eq 0 ]
  [ "$(cat "$FIX/repos_attempts")" -ge 3 ]
  last_json "$output" | jq -e '.ok == true'
}

@test "cross-repo-automerge: repo 一覧が 3 回とも失敗したら exit 1" {
  cat > "$STUB_GH" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG"
exit 1
STUB
  chmod +x "$STUB_GH"
  export CCSU_GH_BIN="$STUB_GH"
  run bash "$SCRIPT" --json
  [ "$status" -eq 1 ]
}

@test "cross-repo-automerge: 無効な GITHUB_TOKEN を既定で無視する（gh 401 回避）" {
  repos_json '{"name":"R"}'
  has_ruleset R
  prs_json R "[]"
  cat > "$STUB_GH" <<STUB
#!/usr/bin/env bash
printf 'GITHUB_TOKEN=%s\n' "\${GITHUB_TOKEN-<unset>}" >> "$STUB_LOG"
case "\$1" in
  repo) cat "$FIX/repos.json" ;;
  api)  rel="\${2#repos/}"; rest="\${rel#*/}"; repo="\${rest%%/*}"
        if [ -f "\$FIX/rulesets/\$repo.json" ]; then cat "\$FIX/rulesets/\$repo.json"; else exit 1; fi ;;
  *) exit 1 ;;
esac
STUB
  chmod +x "$STUB_GH"
  export CCSU_GH_BIN="$STUB_GH"
  export GITHUB_TOKEN="invalid-token-should-be-ignored"
  run bash "$SCRIPT" --json
  [ "$status" -eq 0 ]
  grep -q '^GITHUB_TOKEN=<unset>$' "$STUB_LOG"
}

@test "cross-repo-automerge: CCSU_AUTOMERGE_KEEP_ENV_TOKEN=1 なら環境の token をそのまま渡す" {
  repos_json '{"name":"R"}'
  has_ruleset R
  prs_json R "[]"
  cat > "$STUB_GH" <<STUB
#!/usr/bin/env bash
printf 'GITHUB_TOKEN=%s\n' "\${GITHUB_TOKEN-<unset>}" >> "$STUB_LOG"
case "\$1" in
  repo) cat "$FIX/repos.json" ;;
  api)  rel="\${2#repos/}"; rest="\${rel#*/}"; repo="\${rest%%/*}"
        if [ -f "\$FIX/rulesets/\$repo.json" ]; then cat "\$FIX/rulesets/\$repo.json"; else exit 1; fi ;;
  *) exit 1 ;;
esac
STUB
  chmod +x "$STUB_GH"
  export CCSU_GH_BIN="$STUB_GH"
  export GITHUB_TOKEN="my-explicit-token" CCSU_AUTOMERGE_KEEP_ENV_TOKEN=1
  run bash "$SCRIPT" --json
  [ "$status" -eq 0 ]
  grep -q '^GITHUB_TOKEN=my-explicit-token$' "$STUB_LOG"
}
