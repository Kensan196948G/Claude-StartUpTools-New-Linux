#!/usr/bin/env bats
# ============================================================
# cross-repo-remediate.bats — bin/cross-repo-remediate.sh のテスト
#
# 検証観点:
#   - plan 専用であること（--apply は実装されていない = exit 2）
#   - 段階1: CI なし repo を選択肢付きで出す（自動では選ばない）
#   - 段階2: required checks を直近ブランチの check-run 名から取る / 取れない repo は
#            needs_manual_check_names に隔離する（永久 pending を防ぐ）
#   - 段階3: deps のマイナー・パッチだけがマージ候補、fix・メジャー・docs・unknown は人間判断
#   - --json のキー / --out の書き出し / --input の利用
#   - 書き込み系の gh サブコマンドを一切呼ばないこと（呼び出しログで検証）
#
# 隔離: gh は CCSU_GH_BIN のスタブ。実ネットワークに出ない。
# ============================================================

load '../helpers/common-setup'

setup() {
  _bats_common_setup

  SCRIPT="$REPO_ROOT/bin/cross-repo-remediate.sh"
  FIX="$TEST_TEMP/fix"
  STUB_LOG="$TEST_TEMP/gh-calls.log"
  mkdir -p "$FIX/rulesets" "$FIX/ci" "$FIX/runs"
  : > "$STUB_LOG"
  export FIX STUB_LOG

  # 実 status ツールを呼ばせない（--input を使うテストでは特に）
  export CCSU_STATUS_BIN="$TEST_TEMP/no-such-status-tool.sh"

  STUB_GH="$TEST_TEMP/gh"
  cat > "$STUB_GH" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG"
fix="$FIX"
case "$1" in
  repo) cat "$fix/repos.json" ;;
  api)
    path="${2:-}"
    rel="${path#repos/}"; rest="${rel#*/}"
    repo="${rest%%/*}"; tail="${rest#*/}"
    case "$tail" in
      rulesets)
        [ -f "$fix/rulesets/$repo.fail" ] && exit 1
        cat "$fix/rulesets/$repo.json" ;;
      contents/.github/workflows)
        if [ -f "$fix/ci/$repo.404" ]; then echo "gh: Not Found (HTTP 404)" >&2; exit 1; fi
        if [ -f "$fix/ci/$repo.fail" ]; then echo "gh: HTTP 403" >&2; exit 1; fi
        cat "$fix/ci/$repo.json" ;;
      commits/*/check-runs*)
        [ -f "$fix/runs/$repo.fail" ] && exit 1
        cat "$fix/runs/$repo.json" ;;
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
repos_json() { printf '%s\n' "$1" > "$FIX/repos.json"; }
ruleset_of() { printf '%s\n' "$2" > "$FIX/rulesets/$1.json"; }
ci_of()      { printf '%s\n' "$2" > "$FIX/ci/$1.json"; }
runs_of()    { printf '%s\n' "$2" > "$FIX/runs/$1.json"; }
runs_fail()  { : > "$FIX/runs/$1.fail"; }
ci_404()     { : > "$FIX/ci/$1.404"; }

# 既定: R1=既存 ruleset / R2=ruleset なし+CI あり / R3=ruleset なし+CI なし
default_repos() {
  repos_json '[{"name":"R1","defaultBranchRef":{"name":"main"}},
               {"name":"R2","defaultBranchRef":{"name":"main"}},
               {"name":"R3","defaultBranchRef":{"name":"main"}}]'
  ruleset_of R1 '[{"id":1,"name":"central-auto-merge","target":"branch","enforcement":"active"}]'
  ruleset_of R2 '[]'
  ruleset_of R3 '[]'
  ci_of R2 '[{"name":"ci.yml","size":10}]'
  ci_404 R3
  runs_of R2 '{"check_runs":[{"name":"test","conclusion":"success"},
                             {"name":"lint","conclusion":"success"},
                             {"name":"skipped-one","conclusion":"skipped"}]}'
}

# make_status <prs-json> [no_ci_repos-json]
make_status() {
  local prs="${1:-[]}" noci="${2:-[]}"
  jq -cn --argjson prs "$prs" --argjson noci "$noci" '{
    ok: true, owner: "Kensan196948G", repos: 3, ruleset_missing: 2,
    open_prs: 4, clean_green: ($prs | length), unknown: 0,
    registry: {ok: true},
    pr_types: {deps: 0, docs: 0, feat: 0, fix: 0, chore: 0, unknown: 0},
    age_buckets: {"<7": 0, "7-30": 0, "30-90": 0, ">90": 0},
    prs: $prs,
    ci_presence: {with_ci: 1, no_ci: ($noci | length), unknown: 0,
                  no_ci_repos: $noci, unknown_repos: []}
  }' > "$TEST_TEMP/status.json"
  printf '%s' "$TEST_TEMP/status.json"
}

last_json() { printf '%s\n' "$1" | tail -1; }

# ── 引数・安全弁 ───────────────────────────────────────────
@test "cross-repo-remediate: --help は使い方を出して exit 0" {
  run bash "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--plan"* ]]
  [[ "$output" == *"--apply は実装していない"* ]]
}

@test "cross-repo-remediate: --plan が無ければ exit 2" {
  run bash "$SCRIPT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"--plan が必要"* ]]
}

@test "cross-repo-remediate: --apply は実装されておらず exit 2" {
  run bash "$SCRIPT" --plan --apply
  [ "$status" -eq 2 ]
  [[ "$output" == *"--apply は実装していません"* ]]
}

@test "cross-repo-remediate: 不明な引数は exit 2" {
  run bash "$SCRIPT" --plan --bogus
  [ "$status" -eq 2 ]
  [[ "$output" == *"不明な引数"* ]]
}

@test "cross-repo-remediate: --input が無いファイルなら exit 1" {
  run bash "$SCRIPT" --plan --input "$TEST_TEMP/nope.json"
  [ "$status" -eq 1 ]
}

# ── 段階1: CI なし repo ────────────────────────────────────
@test "cross-repo-remediate: CI なし repo を選択肢付きで出す(自動では選ばない)" {
  default_repos
  IN="$(make_status '[]' '["R3"]')"
  run bash "$SCRIPT" --plan --input "$IN" --json
  [ "$status" -eq 0 ]
  LAST="$(last_json "$output")"
  echo "$LAST" | jq -e '.stage1_no_ci.count == 1'
  echo "$LAST" | jq -e '.stage1_no_ci.repos[0].repo == "R3"'
  echo "$LAST" | jq -e '.stage1_no_ci.repos[0].chosen == null'
  echo "$LAST" | jq -e '.stage1_no_ci.repos[0].options == ["add_minimal_ci","exclude_from_policy"]'
}

# ── 段階2: ruleset ボディと check 名 ──────────────────────
@test "cross-repo-remediate: required checks を直近ブランチの check-run 名から取る" {
  default_repos
  IN="$(make_status '[]' '["R3"]')"
  run bash "$SCRIPT" --plan --input "$IN" --json
  [ "$status" -eq 0 ]
  LAST="$(last_json "$output")"
  echo "$LAST" | jq -e '.stage2_ruleset.ready_count == 1'
  echo "$LAST" | jq -e '.stage2_ruleset.needs_manual_check_names_count == 0'
  # skipped は除外され、success の 2 件が context になる
  echo "$LAST" | jq -e '[.stage2_ruleset.bodies[0].body.rules[]
    | select(.type=="required_status_checks")
    | .parameters.required_status_checks[].context] | sort == ["lint","test"]'
  # 既定ブランチが body の ref に入り、ポリシーの値が入っている
  echo "$LAST" | jq -e '.stage2_ruleset.bodies[0].body.conditions.ref_name.include == ["refs/heads/main"]'
  echo "$LAST" | jq -e '.stage2_ruleset.bodies[0].body.bypass_actors == []'
  echo "$LAST" | jq -e '[.stage2_ruleset.bodies[0].body.rules[]
    | select(.type=="required_status_checks")
    | .parameters.strict_required_status_checks_policy] == [true]'
  echo "$LAST" | jq -e '[.stage2_ruleset.bodies[0].body.rules[]
    | select(.type=="pull_request")
    | .parameters.allowed_merge_methods] == [["squash"]]'
}

@test "cross-repo-remediate: check 名が取れない repo は needs_manual_check_names に隔離する" {
  default_repos
  # R2 の check-run が空 → 名前を推測せず手動確認へ
  runs_of R2 '{"check_runs":[]}'
  IN="$(make_status '[]' '["R3"]')"
  run bash "$SCRIPT" --plan --input "$IN" --json
  [ "$status" -eq 0 ]
  LAST="$(last_json "$output")"
  echo "$LAST" | jq -e '.stage2_ruleset.needs_manual_check_names_count == 1'
  echo "$LAST" | jq -e '.stage2_ruleset.needs_manual_check_names == ["R2"]'
  echo "$LAST" | jq -e '.stage2_ruleset.ready_count == 0'
  # 生成できる repo が 0 なので POST ボディは 1 つも作られない
  echo "$LAST" | jq -e '(.stage2_ruleset | has("bodies")) == false'
}

@test "cross-repo-remediate: check-run API が失敗しても plan は落ちず manual に回す" {
  default_repos
  runs_fail R2
  IN="$(make_status '[]' '["R3"]')"
  run bash "$SCRIPT" --plan --input "$IN" --json
  [ "$status" -eq 0 ]
  last_json "$output" | jq -e '.stage2_ruleset.needs_manual_check_names == ["R2"]'
}

# ── 段階3: PR の振り分け ──────────────────────────────────
@test "cross-repo-remediate: deps のマイナー/パッチだけがマージ候補になる" {
  default_repos
  PRS='[
    {"repo":"R1","number":1,"title":"chore(deps): bump lodash from 4.17.0 to 4.17.21","age_days":3,"type":"deps","draft":false,"failures":0},
    {"repo":"R1","number":2,"title":"chore(deps): bump vite from 7.0.0 to 8.0.0","age_days":10,"type":"deps","draft":false,"failures":0},
    {"repo":"R3","number":3,"title":"fix(api): bug","age_days":40,"type":"fix","draft":false,"failures":0},
    {"repo":"R1","number":4,"title":"docs: readme","age_days":100,"type":"docs","draft":false,"failures":0}]'
  IN="$(make_status "$PRS" '["R3"]')"
  run bash "$SCRIPT" --plan --input "$IN" --json
  [ "$status" -eq 0 ]
  LAST="$(last_json "$output")"
  # マージ候補は #1 のみ（#2 はメジャー bump）
  echo "$LAST" | jq -e '.stage3_prs.merge_candidate_count == 1'
  echo "$LAST" | jq -e '[.stage3_prs.merge_candidates[].number] == [1]'
  # 人間判断: fix / メジャー / docs
  echo "$LAST" | jq -e '.stage3_prs.human_judgment_count == 3'
  echo "$LAST" | jq -e '[.stage3_prs.human_judgment[].number] | sort == [2,3,4]'
  echo "$LAST" | jq -e '[.stage3_prs.human_judgment[] | select(.number==2) | .major] == [true]'
}

@test "cross-repo-remediate: メジャー bump の判定は from X to Y の主要素で行う" {
  default_repos
  PRS='[
    {"repo":"R1","number":1,"title":"chore(deps): bump typescript from 5.9.3 to 7.0.2","age_days":103,"type":"deps","draft":false,"failures":0},
    {"repo":"R1","number":2,"title":"ci: bump actions/setup-node from 4.1.0 to 7.1.0","age_days":41,"type":"deps","draft":false,"failures":0},
    {"repo":"R1","number":3,"title":"chore(deps): Bump the python-minor-patch group with 3 updates","age_days":5,"type":"deps","draft":false,"failures":0}]'
  IN="$(make_status "$PRS" '["R3"]')"
  run bash "$SCRIPT" --plan --input "$IN" --json
  [ "$status" -eq 0 ]
  LAST="$(last_json "$output")"
  # 1 と 2 はメジャー → 人間判断。3 はグループ更新なのでマージ候補。
  echo "$LAST" | jq -e '[.stage3_prs.human_judgment[].number] | sort == [1,2]'
  echo "$LAST" | jq -e '[.stage3_prs.merge_candidates[].number] == [3]'
}

# ── 出力 ───────────────────────────────────────────────────
@test "cross-repo-remediate: --json が仕様のキーを持つ" {
  default_repos
  IN="$(make_status '[]' '["R3"]')"
  run bash "$SCRIPT" --plan --input "$IN" --json
  [ "$status" -eq 0 ]
  LAST="$(last_json "$output")"
  echo "$LAST" | jq -e 'has("ok") and has("plan_version") and has("apply_supported")'
  echo "$LAST" | jq -e 'has("stage1_no_ci") and has("stage2_ruleset") and has("stage3_prs") and has("stage4_controller")'
  echo "$LAST" | jq -e '.ok == true and .apply_supported == false'
  # 提案テキストはあるが実行コマンドは持たない
  echo "$LAST" | jq -e '.stage4_controller.proposal | length > 0'
}

@test "cross-repo-remediate: --out はローカルファイルに計画 JSON を書く" {
  default_repos
  IN="$(make_status '[]' '["R3"]')"
  OUT="$TEST_TEMP/plan.json"
  run bash "$SCRIPT" --plan --input "$IN" --out "$OUT" --json
  [ "$status" -eq 0 ]
  [ -f "$OUT" ]
  jq -e '.ok == true and .stage2_ruleset.ready_count == 1' "$OUT"
}

@test "cross-repo-remediate: --input を渡したら status ツールを呼ばない" {
  default_repos
  IN="$(make_status '[]' '["R3"]')"
  # 呼ばれたら失敗するスタブを status ツールとして指定
  FAIL_TOOL="$TEST_TEMP/status-tool-called.sh"
  printf '#!/usr/bin/env bash\ntouch "%s"\nexit 1\n' "$TEST_TEMP/status-called" > "$FAIL_TOOL"
  chmod +x "$FAIL_TOOL"
  export CCSU_STATUS_BIN="$FAIL_TOOL"
  run bash "$SCRIPT" --plan --input "$IN" --json
  [ "$status" -eq 0 ]
  [ ! -f "$TEST_TEMP/status-called" ]
  last_json "$output" | jq -e '.source.kind | startswith("input:")'
}

# ── 安全弁: 書き込み系 gh を呼ばない ──────────────────────
@test "cross-repo-remediate: 書き込み系の gh サブコマンドを一切呼ばない" {
  default_repos
  IN="$(make_status '[]' '["R3"]')"
  run bash "$SCRIPT" --plan --input "$IN" --json
  [ "$status" -eq 0 ]
  [ -s "$STUB_LOG" ]
  # 破壊的・書き込み系の語が呼び出しログに一度も出ないこと
  run grep -nE -- '(-X|--method|pr merge|pr create|pr close|pr edit|repo edit|repo create|repo delete|repo archive|rulesets.*(POST|PUT|PATCH|DELETE))' "$STUB_LOG"
  [ "$status" -ne 0 ]
  # 呼び出しは読み取りの 2 種類だけ（repo list / api GET）
  run grep -vcE '^(repo list|api repos/)' "$STUB_LOG"
  [ "$output" = "0" ]
}

@test "cross-repo-remediate: 書き込み系 gh は plan の文字列としてのみ存在する" {
  # '--method' の出現は「計画に載せる実行コマンド」の 1 箇所だけに限定されている
  run grep -c -- '--method' "$SCRIPT"
  [ "$output" -eq 1 ]
  run grep -n -- '--method' "$SCRIPT"
  [[ "$output" == *"execute:"* ]]
  # 実行位置（gh / "$GH_BIN" から始まる呼び出し）には書き込み系が無い
  run grep -cE '^[[:space:]]*("\$GH_BIN"|gh)[[:space:]]+api[[:space:]]+--method' "$SCRIPT"
  [ "$output" -eq 0 ]
  run grep -cE '^[[:space:]]*("\$GH_BIN"|gh)[[:space:]]+pr[[:space:]]+(merge|create|close)' "$SCRIPT"
  [ "$output" -eq 0 ]
}
