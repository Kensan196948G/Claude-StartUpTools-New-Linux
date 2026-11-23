#!/usr/bin/env bats
# ============================================================
# deploy-status.bats — bin/deploy-status.sh のテスト
#
# 検証観点:
#   - <env>-current symlink → 実体 release の commit / tree_sha256 (manifest.json)
#   - previous との比較 (ロールバック可否・同一 commit の扱い)
#   - health (CCSU_CURL_BIN スタブ) — 失敗しても exit 0 で継続
#   - unit 状態 (CCSU_SYSTEMCTL_BIN スタブ)
#   - promotions.jsonl の末尾 5 件
#   - state.json の deploy サマリ
#   - --json のキー契約 / --env の絞り込み
#   - 読み取り専用 (実行前後で symlink・manifest・state・台帳が変化しない)
#
# 隔離: CLAUDEOS_HOME / CCSU_STATE_FILE は $TEST_TEMP。curl と systemctl は
#       PATH スタブ。実 ~/.claudeos・実 systemd・実 HTTP には触れない。
# ============================================================

load '../helpers/common-setup'

setup() {
  _bats_common_setup

  export CLAUDEOS_HOME="$TEST_TEMP/claudeos"
  RELEASES="$CLAUDEOS_HOME/releases"
  mkdir -p "$RELEASES"
  export CCSU_STATE_FILE="$TEST_TEMP/state.json"
  SCRIPT="$REPO_ROOT/bin/deploy-status.sh"

  COMMIT_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  COMMIT_B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  TREE_A="1111111111111111111111111111111111111111111111111111111111111111"
  TREE_B="2222222222222222222222222222222222222222222222222222222222222222"
  REL_A="$RELEASES/$COMMIT_A"
  REL_B="$RELEASES/$COMMIT_B"

  export CCSU_CURL_BIN="$STUB_BIN/curl"
  export CCSU_SYSTEMCTL_BIN="$STUB_BIN/systemctl"
  _health_body '{"ok":true,"commit":"'$COMMIT_A'","version":"4.0.0-linux"}'
  printf '200\n' > "$TEST_TEMP/health.status"
  _stub_curl 0
  _stub_systemctl active 0 0

  jq -n '{deploy:{ready:false,runbook_generated:false,runbook_path:null,
                  pre_deploy_checklist_done:false,environment:null,notes:""}}' > "$CCSU_STATE_FILE"
}

teardown() { _bats_common_teardown; }

# ------------------------------------------------------------
# fixtures / stubs
# ------------------------------------------------------------

# _make_release <dir> <commit> [tree_sha256]
_make_release() {
  local dir="$1" commit="$2" tree="${3:-$TREE_A}"
  mkdir -p "$dir"
  printf 'x\n' > "$dir/a.txt"
  jq -n --arg c "$commit" --arg t "$tree" \
    '{schema_version:1,commit:$c,short_commit:($c[0:7]),ref:"test",
      built_at:"2026-01-01T00:00:00Z",file_count:1,tree_sha256:$t,
      files:[{path:"a.txt",sha256:"aa",size:2}]}' > "$dir/manifest.json"
}

_link_current() { ln -sfn -- "$1" "$RELEASES/staging-current"; }
_write_previous() { printf '%s' "$1" > "$RELEASES/staging-previous"; }

_health_body() { printf '%s\n' "$1" > "$TEST_TEMP/health.body"; }

# _stub_curl <exit code> — body と status を出して curl -w を模擬する
_stub_curl() {
  local code="${1:-0}"
  printf '#!/usr/bin/env bash\necho "$*" >> "%s/curl.calls"\ncat "%s/health.body" 2>/dev/null\ncat "%s/health.status" 2>/dev/null\nexit %s\n' \
    "$TEST_TEMP" "$TEST_TEMP" "$TEST_TEMP" "$code" > "$CCSU_CURL_BIN"
  chmod +x "$CCSU_CURL_BIN"
}

# _stub_systemctl <ActiveState> <NRestarts> <exit code>
_stub_systemctl() {
  # 空文字を「引数なし」と区別するため :- ではなく - を使う
  local state="${1-active}" restarts="${2-0}" code="${3-0}"
  cat > "$CCSU_SYSTEMCTL_BIN" <<EOF
#!/usr/bin/env bash
echo "systemctl \$*" >> "$TEST_TEMP/systemctl.calls"
echo "ActiveState=${state}"
echo "NRestarts=${restarts}"
exit $code
EOF
  chmod +x "$CCSU_SYSTEMCTL_BIN"
}

# ------------------------------------------------------------
# current / manifest
# ------------------------------------------------------------

@test "deploy-status: symlink を解決し manifest の commit / tree_sha256 を表示する" {
  _make_release "$REL_A" "$COMMIT_A"
  _link_current "$COMMIT_A"

  run bash "$SCRIPT" --env staging
  [ "$status" -eq 0 ]
  [[ "$output" == *"$COMMIT_A"* ]]
  [[ "$output" == *"$TREE_A"* ]]
  [[ "$output" == *"staging-current -> $COMMIT_A"* ]]
}

@test "deploy-status: manifest が無い release は「成果物なし」と表示する" {
  mkdir -p "$REL_A"
  _link_current "$COMMIT_A"

  run bash "$SCRIPT" --env staging
  [ "$status" -eq 0 ]
  [[ "$output" == *"成果物なし"* ]]
  [[ "$output" != *"$TREE_A"* ]]
}

@test "deploy-status: symlink が無い env は「成果物なし」と表示する" {
  run bash "$SCRIPT" --env production
  [ "$status" -eq 0 ]
  [[ "$output" == *"成果物なし"* ]]
  [[ "$output" == *"production-current がありません"* ]]
}

@test "deploy-status: dangling symlink でも落ちない (exit 0)" {
  ln -sfn -- "ffffffffffffffffffffffffffffffffffffffff" "$RELEASES/staging-current"

  run bash "$SCRIPT" --env staging --json
  [ "$status" -eq 0 ]
  local last; last="$(printf '%s\n' "$output" | tail -1)"
  [ "$(printf '%s' "$last" | jq -r .ok)" = "true" ]
  [ "$(printf '%s' "$last" | jq -r '.staging.current.present')" = "false" ]
  [ "$(printf '%s' "$last" | jq -r '.staging.current.symlink_present')" = "true" ]
}

# ------------------------------------------------------------
# previous / rollback
# ------------------------------------------------------------

@test "deploy-status: previous があればロールバック可、無ければ不可" {
  _make_release "$REL_A" "$COMMIT_A" "$TREE_A"
  _make_release "$REL_B" "$COMMIT_B" "$TREE_B"
  _link_current "$COMMIT_A"

  run bash "$SCRIPT" --env staging
  [ "$status" -eq 0 ]
  [[ "$output" == *"ロールバック: 不可"* ]]

  _write_previous "$COMMIT_B"
  run bash "$SCRIPT" --env staging
  [ "$status" -eq 0 ]
  [[ "$output" == *"ロールバック: 可"* ]]
  [[ "$output" == *"previous $COMMIT_B"* ]]
}

@test "deploy-status: previous が current と同一 commit なら「戻しても同じ」と表示する" {
  _make_release "$REL_A" "$COMMIT_A" "$TREE_A"
  _link_current "$COMMIT_A"
  _write_previous "$COMMIT_A"

  run bash "$SCRIPT" --env staging --json
  [ "$status" -eq 0 ]
  local last; last="$(printf '%s\n' "$output" | tail -1)"
  [ "$(printf '%s' "$last" | jq -r '.staging.rollback_available')" = "true" ]
  [ "$(printf '%s' "$last" | jq -r '.staging.same_commit_as_previous')" = "true" ]
}

@test "deploy-status: previous の実体が無い場合はロールバック不可 (理由付き)" {
  _make_release "$REL_A" "$COMMIT_A" "$TREE_A"
  _link_current "$COMMIT_A"
  _write_previous "cccccccccccccccccccccccccccccccccccccccc"

  run bash "$SCRIPT" --env staging --json
  [ "$status" -eq 0 ]
  local last; last="$(printf '%s\n' "$output" | tail -1)"
  [ "$(printf '%s' "$last" | jq -r '.staging.rollback_available')" = "false" ]
  [[ "$(printf '%s' "$last" | jq -r '.staging.rollback_reason')" == *"実体が存在しません"* ]]
}

# ------------------------------------------------------------
# health / unit
# ------------------------------------------------------------

@test "deploy-status: health は CCSU_CURL_BIN スタブの ok/commit/version を表示する" {
  _make_release "$REL_A" "$COMMIT_A" "$TREE_A"
  _link_current "$COMMIT_A"

  run bash "$SCRIPT" --env staging
  [ "$status" -eq 0 ]
  [[ "$output" == *"health    : OK"* ]]
  [[ "$output" == *"version=4.0.0-linux"* ]]
  # staging は 3742 を見る
  grep -q '127.0.0.1:3742/api/health' "$TEST_TEMP/curl.calls"
  ! grep -q '3740' "$TEST_TEMP/curl.calls"
}

@test "deploy-status: health 失敗でも exit 0 で表示を継続する" {
  _make_release "$REL_A" "$COMMIT_A" "$TREE_A"
  _link_current "$COMMIT_A"
  : > "$TEST_TEMP/health.body"
  : > "$TEST_TEMP/health.status"
  _stub_curl 7

  run bash "$SCRIPT" --env staging
  [ "$status" -eq 0 ]
  [[ "$output" == *"health    : NG"* ]]
  [[ "$output" == *"接続できません"* ]]
  # 後続のセクションも出る
  [[ "$output" == *"直近の昇格"* ]]
  [[ "$output" == *"state.json の deploy"* ]]
}

@test "deploy-status: unit 状態を systemctl スタブから表示する" {
  _make_release "$REL_A" "$COMMIT_A" "$TREE_A"
  _link_current "$COMMIT_A"
  _stub_systemctl inactive 3 0

  run bash "$SCRIPT" --env staging
  [ "$status" -eq 0 ]
  [[ "$output" == *"unit      : inactive"* ]]
  [[ "$output" == *"NRestarts=3"* ]]
  grep -q 'claudeos-web-startup-stg.service' "$TEST_TEMP/systemctl.calls"
  ! grep -qF 'claudeos-web-startup.service' "$TEST_TEMP/systemctl.calls"
}

@test "deploy-status: systemctl が失敗しても exit 0 で「取得不可」を出す" {
  _make_release "$REL_A" "$COMMIT_A" "$TREE_A"
  _link_current "$COMMIT_A"
  _stub_systemctl "" "" 5

  run bash "$SCRIPT" --env staging
  [ "$status" -eq 0 ]
  [[ "$output" == *"取得不可"* ]]
}

# ------------------------------------------------------------
# promotions / state
# ------------------------------------------------------------

@test "deploy-status: promotions.jsonl の末尾 5 件だけを表示する" {
  local i
  for i in 1 2 3 4 5 6 7; do
    printf '{"at":"2026-01-0%dT00:00:00Z","env":"staging","commit":"%s","tree_sha256":"%s","result":"PROMOTED","unit":"claudeos-web-startup-stg.service","port":3742}\n' \
      "$i" "$COMMIT_A" "$TREE_A" >> "$RELEASES/promotions.jsonl"
  done

  run bash "$SCRIPT" --env staging --json
  [ "$status" -eq 0 ]
  local last; last="$(printf '%s\n' "$output" | tail -1)"
  [ "$(printf '%s' "$last" | jq -r '.promotions | length')" -eq 5 ]
  [ "$(printf '%s' "$last" | jq -r '.promotions[0].at')" = "2026-01-03T00:00:00Z" ]
  [ "$(printf '%s' "$last" | jq -r '.promotions[-1].at')" = "2026-01-07T00:00:00Z" ]
}

@test "deploy-status: promotions.jsonl が無い/壊れていても落ちない" {
  printf 'not json\n{"at":"2026-01-01T00:00:00Z","env":"staging"}\n' > "$RELEASES/promotions.jsonl"

  run bash "$SCRIPT" --env staging --json
  [ "$status" -eq 0 ]
  local last; last="$(printf '%s\n' "$output" | tail -1)"
  # 壊れた行は捨て、妥当な 1 行だけ残す
  [ "$(printf '%s' "$last" | jq -r '.promotions | length')" -eq 1 ]
}

@test "deploy-status: state.json の deploy サマリを表示する" {
  _make_release "$REL_A" "$COMMIT_A" "$TREE_A"
  _link_current "$COMMIT_A"
  jq -n '{deploy:{ready:true,runbook_generated:true,runbook_path:"reports/deploy-runbook.md",
                  pre_deploy_checklist_done:true,environment:"staging",notes:""}}' > "$CCSU_STATE_FILE"

  run bash "$SCRIPT" --env staging
  [ "$status" -eq 0 ]
  [[ "$output" == *"ready=true"* ]]
  [[ "$output" == *"environment=staging"* ]]
  [[ "$output" == *"reports/deploy-runbook.md"* ]]
  [[ "$output" == *"checklist_done=true"* ]]
}

@test "deploy-status: state.json が読めなくても exit 0 で「state.json なし」" {
  rm -f "$CCSU_STATE_FILE"

  run bash "$SCRIPT" --env staging
  [ "$status" -eq 0 ]
  [[ "$output" == *"state.json なし"* ]]

  run bash "$SCRIPT" --env staging --json
  [ "$status" -eq 0 ]
  local last; last="$(printf '%s\n' "$output" | tail -1)"
  [ "$(printf '%s' "$last" | jq -r '.deploy.present')" = "false" ]
}

# ------------------------------------------------------------
# JSON / 引数 / 読み取り専用
# ------------------------------------------------------------

@test "deploy-status: --json のキーが契約どおり (最終行 1 行)" {
  _make_release "$REL_A" "$COMMIT_A" "$TREE_A"
  _link_current "$COMMIT_A"
  _write_previous "$COMMIT_B"

  run bash "$SCRIPT" --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l)" -eq 1 ]
  local last; last="$(printf '%s\n' "$output" | tail -1)"
  printf '%s' "$last" | jq -e '.ok == true' >/dev/null
  for key in staging production promotions deploy; do
    [ "$(printf '%s' "$last" | jq -r "has(\"$key\")")" = "true" ]
  done
  # env 配下のキー
  for key in env selected port unit current previous rollback_available health; do
    [ "$(printf '%s' "$last" | jq -r ".staging | has(\"$key\")")" = "true" ]
  done
  [ "$(printf '%s' "$last" | jq -r '.staging.current.manifest.commit')" = "$COMMIT_A" ]
  [ "$(printf '%s' "$last" | jq -r '.staging.current.manifest.tree_sha256')" = "$TREE_A" ]
}

@test "deploy-status: --env で片方だけ表示し JSON は selected で示す" {
  _make_release "$REL_A" "$COMMIT_A" "$TREE_A"
  _link_current "$COMMIT_A"

  run bash "$SCRIPT" --env staging
  [ "$status" -eq 0 ]
  [[ "$output" == *"[staging]"* ]]
  [[ "$output" != *"[production]"* ]]

  run bash "$SCRIPT" --env staging --json
  [ "$status" -eq 0 ]
  local last; last="$(printf '%s\n' "$output" | tail -1)"
  [ "$(printf '%s' "$last" | jq -r '.staging.selected')" = "true" ]
  [ "$(printf '%s' "$last" | jq -r '.production.selected')" = "false" ]
}

@test "deploy-status: 引数エラーは exit 2 (--json では ok:false を出す)" {
  run bash "$SCRIPT" --frobnicate
  [ "$status" -eq 2 ]

  run bash "$SCRIPT" --env prod
  [ "$status" -eq 2 ]

  run bash "$SCRIPT" --env
  [ "$status" -eq 2 ]

  run bash "$SCRIPT" --env prod --json
  [ "$status" -eq 2 ]
  local last; last="$(printf '%s\n' "$output" | tail -1)"
  [ "$(printf '%s' "$last" | jq -r .ok)" = "false" ]
  [ "$(printf '%s' "$last" | jq -r .error)" = "ARG_INVALID" ]
}

@test "deploy-status: 読み取り専用 (symlink / manifest / state / 台帳を変えない)" {
  _make_release "$REL_A" "$COMMIT_A" "$TREE_A"
  _link_current "$COMMIT_A"
  _write_previous "$COMMIT_B"
  printf '{"at":"2026-01-01T00:00:00Z","env":"staging","commit":"%s","result":"PROMOTED","unit":"u","port":3742}\n' \
    "$COMMIT_A" >> "$RELEASES/promotions.jsonl"

  local before after
  before="$(ls -l "$RELEASES"; sha256sum "$REL_A/manifest.json" "$CCSU_STATE_FILE" "$RELEASES/promotions.jsonl" "$RELEASES/staging-previous"; readlink "$RELEASES/staging-current")"
  run bash "$SCRIPT" --json
  [ "$status" -eq 0 ]
  after="$(ls -l "$RELEASES"; sha256sum "$REL_A/manifest.json" "$CCSU_STATE_FILE" "$RELEASES/promotions.jsonl" "$RELEASES/staging-previous"; readlink "$RELEASES/staging-current")"

  [ "$before" = "$after" ]
  # releases 配下に新規ファイルを作っていない (ロックファイル等も作らない)
  [ "$(ls -A "$RELEASES" | wc -l)" -eq 4 ]
}

# ------------------------------------------------------------
# dashboard（本体とは別 unit / 別 port）
#   production = claude-startuptools-dashboard.service (3737)
#   staging    = claude-startuptools-dashboard-stg.service (3743)
#   serving_from は WorkingDirectory から判定する (release / worktree / unknown)
# ------------------------------------------------------------

# _stub_systemctl_rich <dash_state> <dash_restarts> <dash_wd> <dash_dropins> [main_state] [main_restarts] [main_wd]
#   dashboard の unit と本体 unit で別の応答を返すスタブ
_stub_systemctl_rich() {
  local ds="${1-active}" dr="${2-0}" dwd="${3-}" ddrop="${4-}" ms="${5-active}" mr="${6-0}" mwd="${7-}"
  cat > "$CCSU_SYSTEMCTL_BIN" <<EOF
#!/usr/bin/env bash
echo "systemctl \$*" >> "$TEST_TEMP/systemctl.calls"
case "\$*" in
  *dashboard*)
    echo "ActiveState=${ds}"
    echo "NRestarts=${dr}"
    echo "WorkingDirectory=${dwd}"
    echo "DropInPaths=${ddrop}"
    ;;
  *)
    echo "ActiveState=${ms}"
    echo "NRestarts=${mr}"
    echo "WorkingDirectory=${mwd}"
    ;;
esac
exit 0
EOF
  chmod +x "$CCSU_SYSTEMCTL_BIN"
}

# _stub_curl_by_url <env_status> <dash_status> <dash_body_json>
#   本体 (3740/3742) と dashboard (3737/3743) で別の応答を返す curl スタブ
_stub_curl_by_url() {
  local es="${1-200}" ds="${2-200}" db="${3-}"
  printf '%s\n' "$db" > "$TEST_TEMP/dash.body"
  cat > "$CCSU_CURL_BIN" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$TEST_TEMP/curl.calls"
case "\$*" in
  *:3737/api/health|*:3743/api/health) cat "$TEST_TEMP/dash.body" 2>/dev/null; echo $ds ;;
  *) cat "$TEST_TEMP/health.body" 2>/dev/null; echo $es ;;
esac
exit 0
EOF
  chmod +x "$CCSU_CURL_BIN"
}

@test "dashboard: production は dashboard unit と 3737 を JSON に出す" {
  _make_release "$REL_A" "$COMMIT_A" "$TREE_A"
  _link_current "$COMMIT_A"
  _stub_systemctl_rich active 0 "/home/kensan/Projects/Claude-StartUpTools-New-Linux" ""
  _stub_curl_by_url 200 200 '{"status":"ok"}'

  run bash "$SCRIPT" --env production --json
  [ "$status" -eq 0 ]

  local last
  last="$(printf '%s\n' "$output" | tail -1)"
  [ "$(printf '%s' "$last" | jq -r '.production.dashboard.unit')" = "claude-startuptools-dashboard.service" ]
  [ "$(printf '%s' "$last" | jq -r '.production.dashboard.port')" = "3737" ]
  [ "$(printf '%s' "$last" | jq -r '.production.dashboard.active_state')" = "active" ]
  [ "$(printf '%s' "$last" | jq -r '.production.dashboard.n_restarts')" = "0" ]
  [ "$(printf '%s' "$last" | jq -r '.production.dashboard.health_http')" = "200" ]
  [ "$(printf '%s' "$last" | jq -r '.production.dashboard.dropin_present')" = "false" ]
  [ "$(printf '%s' "$last" | jq -r '.production.dashboard.serving_from')" = "worktree" ]

  grep -q 'claude-startuptools-dashboard.service' "$TEST_TEMP/systemctl.calls"
  grep -q '127.0.0.1:3737/api/health' "$TEST_TEMP/curl.calls"
}

@test "dashboard: staging は -stg unit と 3743 を使い、本番 3737 は叩かない" {
  _make_release "$REL_A" "$COMMIT_A" "$TREE_A"
  _link_current "$COMMIT_A"
  _stub_systemctl_rich active 0 "/tmp/stg-worktree" ""
  _stub_curl_by_url 200 200 '{"status":"ok"}'

  run bash "$SCRIPT" --env staging --json
  [ "$status" -eq 0 ]

  local last
  last="$(printf '%s\n' "$output" | tail -1)"
  [ "$(printf '%s' "$last" | jq -r '.staging.dashboard.unit')" = "claude-startuptools-dashboard-stg.service" ]
  [ "$(printf '%s' "$last" | jq -r '.staging.dashboard.port')" = "3743" ]

  grep -q 'claude-startuptools-dashboard-stg.service' "$TEST_TEMP/systemctl.calls"
  grep -q '127.0.0.1:3743/api/health' "$TEST_TEMP/curl.calls"
  ! grep -q '3737' "$TEST_TEMP/curl.calls"
}

@test "dashboard: serving_from=release (WorkingDirectory が releases/<sha> 配下) を表示する" {
  _make_release "$REL_A" "$COMMIT_A" "$TREE_A"
  _link_current "$COMMIT_A"
  _stub_systemctl_rich active 1 "$CLAUDEOS_HOME/releases/$COMMIT_A" ""
  _stub_curl_by_url 200 200 '{"status":"ok"}'

  run bash "$SCRIPT" --env production
  [ "$status" -eq 0 ]
  # コンソールにも serving_from を出す
  [[ "$output" == *"成果物起動"* ]]
  [[ "$output" == *"release"* ]]
  [[ "$output" == *"WorkingDirectory=$CLAUDEOS_HOME/releases/$COMMIT_A"* ]]

  run bash "$SCRIPT" --env production --json
  [ "$(printf '%s\n' "$output" | tail -1 | jq -r '.production.dashboard.serving_from')" = "release" ]
}

@test "dashboard: serving_from=worktree (作業ツリー直実行) を表示する" {
  _make_release "$REL_A" "$COMMIT_A" "$TREE_A"
  _link_current "$COMMIT_A"
  _stub_systemctl_rich active 0 "/home/kensan/Projects/Claude-StartUpTools-New-Linux" ""
  _stub_curl_by_url 200 200 '{"status":"ok"}'

  run bash "$SCRIPT" --env production
  [ "$status" -eq 0 ]
  [[ "$output" == *"worktree"* ]]
}

@test "dashboard: drop-in があれば dropin_present=true / 表示は「あり」" {
  _make_release "$REL_A" "$COMMIT_A" "$TREE_A"
  _link_current "$COMMIT_A"
  _stub_systemctl_rich active 0 "/srv/app" \
    "/home/k/.config/systemd/user/claude-startuptools-dashboard.service.d/10-env.conf"
  _stub_curl_by_url 200 200 '{"status":"ok"}'

  run bash "$SCRIPT" --env production --json
  local last
  last="$(printf '%s\n' "$output" | tail -1)"
  [ "$(printf '%s' "$last" | jq -r '.production.dashboard.dropin_present')" = "true" ]

  run bash "$SCRIPT" --env production
  [[ "$output" == *"drop-in=あり"* ]]
}

@test "dashboard: unit 未登録なら error を出し serving_from=unknown（release と誤表示しない）" {
  _make_release "$REL_A" "$COMMIT_A" "$TREE_A"
  _link_current "$COMMIT_A"
  _stub_systemctl_rich "" "" "" ""
  _stub_curl_by_url 200 200 '{"status":"ok"}'

  run bash "$SCRIPT" --env production --json
  [ "$status" -eq 0 ]

  local last
  last="$(printf '%s\n' "$output" | tail -1)"
  [ "$(printf '%s' "$last" | jq -r '.production.dashboard.active_state')" = "" ]
  [ "$(printf '%s' "$last" | jq -r '.production.dashboard.serving_from')" = "unknown" ]
  [ "$(printf '%s' "$last" | jq -r '.production.dashboard.error != null')" = "true" ]

  run bash "$SCRIPT" --env production
  [[ "$output" == *"取得不可"* ]]
  [[ "$output" == *"unknown"* ]]
}

@test "dashboard: dashboard が落ちていても exit 0 / health_http は null（000 を HTTP 扱いしない）" {
  _make_release "$REL_A" "$COMMIT_A" "$TREE_A"
  _link_current "$COMMIT_A"
  _stub_systemctl_rich active 0 "/srv/app" ""
  _stub_curl_by_url 200 000 ''

  run bash "$SCRIPT" --env production --json
  [ "$status" -eq 0 ]

  local last
  last="$(printf '%s\n' "$output" | tail -1)"
  # 本体 (health.ok) は別途 200 で通る
  [ "$(printf '%s' "$last" | jq -r '.production.health.http_status')" = "200" ]
  # dashboard は接続不可 → null
  [ "$(printf '%s' "$last" | jq -r '.production.dashboard.health_http')" = "null" ]

  run bash "$SCRIPT" --env production
  [ "$status" -eq 0 ]
}

# ------------------------------------------------------------
# コンソール本体 unit の serving_from（本番コンソールが成果物起動へ切り替わったか）
# ------------------------------------------------------------

@test "console: 本体 unit の WorkingDirectory が releases 配下なら serving_from=release" {
  _make_release "$REL_A" "$COMMIT_A" "$TREE_A"
  _link_current "$COMMIT_A"
  _stub_systemctl_rich active 0 "/repo" "" active 0 "$CLAUDEOS_HOME/releases/production-current"
  _stub_curl_by_url 200 200 '{"status":"ok"}'
  run bash "$SCRIPT" --env production --json
  [ "$status" -eq 0 ]
  json="$(printf '%s\n' "$output" | tail -n 1)"
  [ "$(printf '%s' "$json" | jq -r '.production.unit.serving_from')" = "release" ]
  [ "$(printf '%s' "$json" | jq -r '.production.unit.working_directory')" = "$CLAUDEOS_HOME/releases/production-current" ]
  [ "$(printf '%s' "$json" | jq -r '.production.dashboard.serving_from')" = "worktree" ]
}

@test "console: 本体 unit が作業ツリーなら serving_from=worktree" {
  _make_release "$REL_A" "$COMMIT_A" "$TREE_A"
  _link_current "$COMMIT_A"
  _stub_systemctl_rich active 0 "/repo" "" active 0 "/home/u/Projects/repo"
  _stub_curl_by_url 200 200 '{"status":"ok"}'
  run bash "$SCRIPT" --env production --json
  [ "$status" -eq 0 ]
  json="$(printf '%s\n' "$output" | tail -n 1)"
  [ "$(printf '%s' "$json" | jq -r '.production.unit.serving_from')" = "worktree" ]
}

@test "console: WorkingDirectory が取れなければ serving_from=unknown（release と誤表示しない）" {
  _make_release "$REL_A" "$COMMIT_A" "$TREE_A"
  _link_current "$COMMIT_A"
  _stub_systemctl_rich active 0 "/repo" "" active 0 ""
  _stub_curl_by_url 200 200 '{"status":"ok"}'
  run bash "$SCRIPT" --env production --json
  [ "$status" -eq 0 ]
  json="$(printf '%s\n' "$output" | tail -n 1)"
  [ "$(printf '%s' "$json" | jq -r '.production.unit.serving_from')" = "unknown" ]
  [ "$(printf '%s' "$json" | jq -r '.production.unit.working_directory')" = "null" ]
}

@test "console: 人間向け出力の unit 行の直後に成果物起動を表示する" {
  _make_release "$REL_A" "$COMMIT_A" "$TREE_A"
  _link_current "$COMMIT_A"
  _stub_systemctl_rich active 0 "/repo" "" active 0 "$CLAUDEOS_HOME/releases/production-current"
  _stub_curl_by_url 200 200 '{"status":"ok"}'
  run bash "$SCRIPT" --env production
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -A1 "unit      :" | grep -q "成果物起動 : .*release"
}
