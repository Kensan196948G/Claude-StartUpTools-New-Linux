#!/usr/bin/env bash
# ============================================================
# promote-production.sh — 本番昇格オーケストレータ（Runbook §4 を 1 コマンド化）
#
# 「人間の Y/N」の後に、Production 昇格の手順を順序どおり実行し、
# 途中で失敗したら unit と成果物を自動で戻す。
#
#   **--yes を付けない限り何も実行しない**（計画を表示して exit 3）。
#   **実行は人間の Y を得てから**行うこと。本スクリプトは確認を代行しない。
#
# 使い方:
#   promote-production.sh --release <40hex> [--dry-run] [--yes] [--json]
#     --release <40hex>  昇格対象の release（$CLAUDEOS_HOME/releases/<40hex>）
#     --dry-run          計画だけ表示し、何も変更しない（バックアップも作らない）
#     --yes              確認済みとして実行する
#     --no-dashboard     本番 dashboard(3737) の切替を行わない（既定は行う）
#     --json             最終行に 1 行 JSON を出す（人間向けログは stderr）
#     -h, --help         このヘルプ
#
# 手順（Runbook §4 の 4-1〜4-5）:
#   (0) bin/pre-promote-check.sh --release <sha> --json が ok でなければ中止（何も変えない）
#   (1) 本番 unit を <unit>.bak-<ts> へ cp -p し、sha256 を記録
#   (2) release-promote --env production --release <sha> --no-restart（symlink 準備）
#   (3) web-startup-service --register --profile production --root <home>/releases/production-current
#         --env AI_STARTUP_CONFIG_PATH=<repo>/config/config.json（unit 差し替え + restart）
#   (3d) 本番 dashboard(3737) を systemd drop-in で成果物起動へ切り替える
#        <unit-dir>/<dashboard>.service.d/50-release.conf に WorkingDirectory と
#        ExecStart（空リセット + 再定義）だけを書く（既存 unit ファイルは変更しない）
#        → daemon-reload → restart → 3737 health が status=ok になるまで確認
#   (4) release-promote --env production --release <sha>（restart + health + 台帳 PROMOTED）
#   (5) scripts/release/post-deploy-smoke.sh --env production --json
#
# 自動復旧: (3)〜(5) のいずれかが失敗したら
#   unit をバックアップから戻す → 成果物 symlink を release-promote --rollback で戻す（previous がある場合）
#   → systemctl --user daemon-reload → restart → health(3740) 200 + ok:true を確認
#   → dashboard の drop-in を削除し restart（(3d) を実行していた場合）→ 3737 health status=ok を確認
#     （previous が無い初回昇格では release-promote --rollback が NO_PREVIOUS を返すため、
#       production-current symlink を削除して新 artifact を指したままにしない）
#   → promotions.jsonl に result=ROLLED_BACK を追記
# 中断: (1) 完了〜(5) 完了までの INT/TERM/HUP は自動復旧を実行して exit 1（復旧失敗は 4）。
#       正常終了・中止時はトラップを解除する。
# 二重実行防止: <home>/releases/.promote-production.lock を flock で排他取得できない場合は
#       exit 2 で中止する（何も変更しない）。

# exit: 0 成功 / 1 失敗（復旧済み。または復旧不要の段階で中止） / 2 引数・lock 取得失敗
#       3 確認待ち（--yes が無い） / 4 復旧も失敗（要人手）
#
# 環境変数（すべてテスト差し替え用。既定は本物）:
#   CCSU_PROMOTE_BIN_DIR   サブスクリプトを置いたディレクトリ（4 本を basename で解決）
#   CCSU_SYSTEMD_UNIT_PATH 本番 unit のパス（web-startup-service と同じ既定）
#   CCSU_SYSTEMCTL_BIN     systemctl 実体
#   CCSU_CURL_BIN          curl 実体
#   CLAUDEOS_HOME          ClaudeOS ホーム（既定 ~/.claudeos）
#   CCSU_PROMOTE_CONFIG_PATH   4-3 の AI_STARTUP_CONFIG_PATH（既定 <repo>/config/config.json）
#   CCSU_PROMOTE_STATE_FILE    4-3 の CCSU_STATE_FILE（既定: CONFIG_PATH の 2 階層上 = 実機 repo の state.json）
#                              成果物起動後に「デプロイ準備」等が成果物内へ state.json を書かないようにする
#   CCSU_PROMOTE_TS        バックアップのタイムスタンプ（テスト固定用）
#   CCSU_PROMOTE_HEALTH_TIMEOUT / CCSU_PROMOTE_HEALTH_INTERVAL  復旧後 health の待ち
#   CCSU_PROMOTE_DASHBOARD_UNIT    本番 dashboard の unit 名（既定 claude-startuptools-dashboard.service）
#   CCSU_SYSTEMD_UNIT_DIR          unit / drop-in のディレクトリ（既定 unit path の dirname）
#   CCSU_PROMOTE_NODE_BIN          drop-in の ExecStart に書く node（未指定なら現行 dashboard unit の ExecStart から抽出 → command -v node）
#   CCSU_PROMOTE_DASHBOARD_HEALTH_TIMEOUT  3737 health の待ち（既定 10 秒）
# ============================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

PP_REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PP_UNIT_NAME="claudeos-web-startup.service"
PP_PRODUCTION_PORT=3740

PP_JSON=0
PP_DRY_RUN=0
PP_YES=0
PP_DASHBOARD=1
PP_DASHBOARD_UNIT="${CCSU_PROMOTE_DASHBOARD_UNIT:-claude-startuptools-dashboard.service}"
PP_DASHBOARD_PORT=3737
PP_DASHBOARD_HEALTH_TIMEOUT="${CCSU_PROMOTE_DASHBOARD_HEALTH_TIMEOUT:-10}"
PP_DROPIN=""
PP_ARTIFACT_ROLLBACK="SKIPPED"
PP_DASHBOARD_DROPIN_REMOVED="false"
PP_DASHBOARD_HEALTH_OK="false"
PP_LOCK_FD=""
PP_TRAP_ARMED=0
PP_RELEASE=""
PP_HOME=""
PP_UNIT_PATH=""
PP_BACKUP=""
PP_BACKUP_SHA=""
PP_TS=""
PP_CONFIG_PATH="${CCSU_PROMOTE_CONFIG_PATH:-$PP_REPO_ROOT/config/config.json}"
# 既定の state は実機設定と同じ checkout の state.json（<repo>/config/config.json → <repo>/state.json）
PP_STATE_FILE="${CCSU_PROMOTE_STATE_FILE:-$(dirname "$(dirname "$PP_CONFIG_PATH")")/state.json}"
PP_HEALTH_TIMEOUT="${CCSU_PROMOTE_HEALTH_TIMEOUT:-10}"
PP_HEALTH_INTERVAL="${CCSU_PROMOTE_HEALTH_INTERVAL:-1}"

PP_RESULT=""
PP_FAILED_STEP=""
PP_REASON=""
PP_ROLLED_BACK="false"
PP_BACKUP_SHA_AFTER=""
PP_STEP_NAMES=()
PP_STEPS=()

usage() {
  cat <<'EOF'
Usage: promote-production.sh --release <40hex> [--dry-run] [--yes] [--json]

  --release <40hex>  昇格対象の release（$CLAUDEOS_HOME/releases/<40hex>）
  --dry-run          計画のみ表示（何も変更しない。バックアップも作らない）
  --yes              確認済みとして実行する（付けない場合は exit 3）
  --no-dashboard     本番 dashboard(3737) を切り替えない（既定は切り替える）
  --json             最終行に 1 行 JSON を出力（人間向けログは stderr）
  -h, --help

手順: pre-promote-check → unit バックアップ → symlink 準備 → unit 差し替え →
      dashboard drop-in 切替 (3d) → release-promote（restart + health + 台帳）→ post-deploy-smoke
失敗時 (3)〜(5): unit と symlink・dashboard drop-in を戻し daemon-reload + restart + health 確認

exit: 0 成功 / 1 失敗（復旧済み・または復旧不要） / 2 引数 / 3 確認待ち / 4 復旧も失敗

二重実行防止: $CLAUDEOS_HOME/releases/.promote-production.lock を排他取得できない場合は exit 2。
中断: (1)〜(5) の間の INT/TERM/HUP は自動復旧する。
EOF
}

# ------------------------------------------------------------
# 基本ヘルパ
# ------------------------------------------------------------

pp__home() { printf '%s' "${CLAUDEOS_HOME:-$HOME/.claudeos}"; }
pp__systemctl() { printf '%s' "${CCSU_SYSTEMCTL_BIN:-systemctl}"; }
pp__curl() { printf '%s' "${CCSU_CURL_BIN:-curl}"; }

# pp__log — json モードでは stderr に逃がす（stdout は最終 JSON 1 行だけ）
pp__log() {
  if (( PP_JSON )); then
    printf '%s\n' "$*" >&2
  else
    printf '%s\n' "$*"
  fi
}

# pp__bin <basename> — サブスクリプトのパス
pp__bin() {
  local name="$1"
  if [[ -n "${CCSU_PROMOTE_BIN_DIR:-}" ]]; then
    printf '%s/%s' "$CCSU_PROMOTE_BIN_DIR" "$name"
    return 0
  fi
  case "$name" in
    post-deploy-smoke.sh) printf '%s/scripts/release/%s' "$PP_REPO_ROOT" "$name" ;;
    *) printf '%s/bin/%s' "$PP_REPO_ROOT" "$name" ;;
  esac
}

pp__unit_path() {
  printf '%s' "${CCSU_SYSTEMD_UNIT_PATH:-$HOME/.config/systemd/user/$PP_UNIT_NAME}"
}

# pp__dropin_dir — drop-in の親ディレクトリ（unit と同じ場所。CCSU_SYSTEMD_UNIT_DIR で差替可）
pp__dropin_dir() {
  if [[ -n "${CCSU_SYSTEMD_UNIT_DIR:-}" ]]; then
    printf '%s' "$CCSU_SYSTEMD_UNIT_DIR"
    return 0
  fi
  dirname -- "$PP_UNIT_PATH"
}

# pp__dropin_path — 50-release.conf のフルパス
pp__dropin_path() {
  printf '%s/%s.d/50-release.conf' "$(pp__dropin_dir)" "$PP_DASHBOARD_UNIT"
}

# pp__dashboard_unit_path — 本番 dashboard unit のファイルパス
pp__dashboard_unit_path() {
  printf '%s/%s' "$(pp__dropin_dir)" "$PP_DASHBOARD_UNIT"
}

# pp__node_bin — drop-in の ExecStart に書く node の絶対パス (L3)
#   1) CCSU_PROMOTE_NODE_BIN (明示上書き)
#   2) 現行 dashboard unit の ExecStart から抽出（実機と同じ node を使う）
#   3) command -v node → /usr/bin/node
pp__node_bin() {
  if [[ -n "${CCSU_PROMOTE_NODE_BIN:-}" ]]; then
    printf '%s' "$CCSU_PROMOTE_NODE_BIN"
    return 0
  fi
  local unit_file node
  unit_file="$(pp__dashboard_unit_path)"
  if [[ -f "$unit_file" ]]; then
    node="$(awk -F= '/^ExecStart=/ { n = split($2, a, " "); for (i = 1; i <= n; i++) if (a[i] ~ /node/) { print a[i]; exit } }' "$unit_file" 2>/dev/null)"
    if [[ -n "$node" ]]; then
      printf '%s' "$node"
      return 0
    fi
  fi
  command -v node 2>/dev/null || printf '/usr/bin/node'
}

# pp__write_dropin — 既存 unit を変えず、WorkingDirectory と ExecStart だけを上書きする
pp__write_dropin() {
  local dropin dir node
  dropin="$(pp__dropin_path)"
  dir="$(dirname -- "$dropin")"
  node="$(pp__node_bin)"
  mkdir -p -- "$dir" || { log_error "drop-in ディレクトリを作成できません: $dir"; return 1; }
  cat > "$dropin" <<CONF
# Auto-generated by promote-production.sh (release ${PP_RELEASE})
# 既存 unit は変更しない。WorkingDirectory / ExecStart / HOST だけを production-current 向けに固定する。
[Service]
WorkingDirectory=${PP_HOME}/releases/production-current
ExecStart=
ExecStart=${node} ${PP_HOME}/releases/production-current/scripts/dashboards/serve-dashboard.js ${PP_DASHBOARD_PORT}
Environment=HOST=127.0.0.1
CONF
  PP_DROPIN="$dropin"
  return 0
}

# pp__dashboard_health_ok — dashboard health (200 + status=="ok") を最大 N 秒待つ
pp__dashboard_health_ok() {
  local url="http://127.0.0.1:${PP_DASHBOARD_PORT}/api/health" deadline body rc
  deadline=$(( SECONDS + PP_DASHBOARD_HEALTH_TIMEOUT ))
  while (( SECONDS < deadline )); do
    rc=0
    body="$("$(pp__curl)" -fsS --max-time 3 "$url" 2>/dev/null)" || rc=$?
    if (( rc == 0 )) && printf '%s' "$body" | jq -e '.status == "ok"' >/dev/null 2>&1; then
      return 0
    fi
    sleep "$PP_HEALTH_INTERVAL"
  done
  return 1
}

# pp__switch_dashboard — (3d): drop-in 書き込み → daemon-reload → restart → health
pp__switch_dashboard() {
  local sysctl
  sysctl="$(pp__systemctl)"
  pp__write_dropin || return 1
  "$sysctl" --user daemon-reload || { log_error "daemon-reload に失敗しました"; return 1; }
  "$sysctl" --user restart "$PP_DASHBOARD_UNIT" || { log_error "dashboard の restart に失敗しました"; return 1; }
  pp__dashboard_health_ok || { log_error "dashboard health (3737) が status=ok になりません"; return 1; }
  return 0
}

# pp__acquire_lock — 二重実行防止 (M2)。失敗で 1（呼び出し側が exit 2）
pp__acquire_lock() {
  local lock
  lock="$(pp__home)/releases/.promote-production.lock"
  mkdir -p -- "$(pp__home)/releases" 2>/dev/null || true
  exec {PP_LOCK_FD}>"$lock" || { PP_LOCK_FD=""; return 1; }
  if ! flock -n "$PP_LOCK_FD"; then
    exec {PP_LOCK_FD}>&-
    PP_LOCK_FD=""
    return 1
  fi
  PP_LOCK_FILE="$lock"
  return 0
}

# pp__release_lock — ロック解放（EXIT トラップから呼ぶ）
pp__release_lock() {
  if [[ -n "${PP_LOCK_FD:-}" ]]; then
    flock -u "$PP_LOCK_FD" 2>/dev/null || true
    exec {PP_LOCK_FD}>&- || true
    PP_LOCK_FD=""
  fi
}

# pp__disarm_trap — シグナルトラップ解除（正常終了・中止・復旧開始時）
pp__disarm_trap() {
  PP_TRAP_ARMED=0
  trap - INT TERM HUP
}

# pp__on_signal <SIG> — (1) 完了〜(5) 完了までの INT/TERM/HUP で自動復旧 (H2)
pp__on_signal() {
  local sig="$1"
  pp__disarm_trap
  PP_FAILED_STEP="signal-$sig"
  PP_REASON="シグナル $sig により中断されました"
  pp__log ""
  pp__log "!! シグナル $sig を受信しました。自動復旧を試みます"
  if pp__rollback; then
    pp__log "== 中断（自動復旧済み）: $PP_REASON =="
    if (( PP_JSON )); then pp__json_line "false" "ROLLED_BACK" "$PP_REASON"; fi
    exit 1
  fi
  pp__log "== 自動復旧に失敗しました。人手で §5 を実行してください: $PP_REASON =="
  if (( PP_JSON )); then pp__json_line "false" "ROLLBACK_FAILED" "$PP_REASON"; fi
  exit 4
}

# pp__arm_trap — バックアップ完了後から復旧可能区間でシグナルを受ける
pp__arm_trap() {
  PP_TRAP_ARMED=1
  trap 'pp__on_signal INT' INT
  trap 'pp__on_signal TERM' TERM
  trap 'pp__on_signal HUP' HUP
}

# pp__artifact_rollback — 成果物 symlink を戻す。(H1) previous 不在なら symlink を削除する
#   0: 戻せた（ROLLED_BACK）または初回昇格として削除できた（NO_PREVIOUS_REMOVED）
#   1: 削除に失敗（復旧失敗として扱う）
pp__artifact_rollback() {
  local out="" rc=0 current
  out="$(bash "$(pp__bin release-promote.sh)" --env production --rollback --no-restart --json 2>&1)" || rc=$?
  if (( PP_JSON )); then
    printf '%s\n' "$out" >&2
  else
    if [[ -n "$out" ]]; then printf '%s\n' "$out" | sed 's/^/    /'; fi
  fi
  if (( rc == 0 )); then
    pp__record_step "artifact-rollback" "true"
    PP_ARTIFACT_ROLLBACK="ROLLED_BACK"
    return 0
  fi
  if [[ "$out" == *"NO_PREVIOUS"* ]]; then
    # 初回昇格: 戻し先が無い。新 artifact を指したままにせず symlink を削除する
    current="$(pp__home)/releases/production-current"
    if rm -f -- "$current"; then
      pp__record_step "production-current-remove" "true"
      PP_ARTIFACT_ROLLBACK="NO_PREVIOUS_REMOVED"
      pp__log "  previous が無いため production-current を削除しました（初回昇格の巻き戻し）: $current"
      return 0
    fi
    pp__record_step "production-current-remove" "false"
    PP_ARTIFACT_ROLLBACK="REMOVE_FAILED"
    log_error "production-current を削除できません: $current"
    return 1
  fi
  pp__record_step "artifact-rollback" "false"
  PP_ARTIFACT_ROLLBACK="FAILED"
  log_warn "成果物の切り戻しに失敗しました (previous が無い場合は正常)"
  return 0
}

pp__record_step() {
  PP_STEP_NAMES+=("$1")
  PP_STEPS+=("$2")
}

# pp__run_step <name> <cmd...> — 出力を整形して実行し、成否を記録する
pp__run_step() {
  local name="$1"
  shift
  local out="" rc=0
  out="$("$@" 2>&1)" || rc=$?
  if (( PP_JSON )); then
    printf '%s\n' "$out" >&2
  else
    if [[ -n "$out" ]]; then printf '%s\n' "$out" | sed 's/^/    /'; fi
  fi
  if (( rc == 0 )); then
    pp__record_step "$name" "true"
    return 0
  fi
  pp__record_step "$name" "false"
  PP_FAILED_STEP="$name"
  PP_REASON="step '$name' が失敗しました (exit $rc)"
  return "$rc"
}

# pp__health_ok — 復旧後の health 確認（最大 PP_HEALTH_TIMEOUT 秒）
pp__health_ok() {
  local url="http://127.0.0.1:${PP_PRODUCTION_PORT}/api/health" deadline body rc
  deadline=$(( SECONDS + PP_HEALTH_TIMEOUT ))
  while (( SECONDS < deadline )); do
    rc=0
    body="$("$(pp__curl)" -fsS --max-time 3 "$url" 2>/dev/null)" || rc=$?
    if (( rc == 0 )) && printf '%s' "$body" | jq -e '.ok == true' >/dev/null 2>&1; then
      return 0
    fi
    sleep "$PP_HEALTH_INTERVAL"
  done
  return 1
}

# pp__record_rollback — 台帳に ROLLED_BACK を追記（失敗は警告のみ）
pp__record_rollback() {
  local releases ledger line
  releases="$(pp__home)/releases"
  ledger="$releases/promotions.jsonl"
  mkdir -p -- "$releases" 2>/dev/null || {
    log_warn "台帳のディレクトリを作成できません: $releases"
    return 0
  }
  local dashboard_note="disabled"
  if (( PP_DASHBOARD )); then
    dashboard_note="dropin_removed=${PP_DASHBOARD_DROPIN_REMOVED},health_ok=${PP_DASHBOARD_HEALTH_OK}"
  fi
  line="$(jq -cn \
    --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg commit "$PP_RELEASE" \
    --arg result "ROLLED_BACK" \
    --arg unit "$PP_UNIT_NAME" \
    --arg note "promote-production: ${PP_FAILED_STEP:-unknown} が失敗。artifact=${PP_ARTIFACT_ROLLBACK}; dashboard=${dashboard_note}" \
    --arg artifact "$PP_ARTIFACT_ROLLBACK" \
    --arg dashboard_unit "$PP_DASHBOARD_UNIT" \
    --arg dropin "$PP_DROPIN" \
    --argjson dashboard_enabled "$(if (( PP_DASHBOARD )); then printf true; else printf false; fi)" \
    --argjson dashboard_dropin_removed "$(if [[ "$PP_DASHBOARD_DROPIN_REMOVED" == "true" ]]; then printf true; else printf false; fi)" \
    --argjson dashboard_health_ok "$(if [[ "$PP_DASHBOARD_HEALTH_OK" == "true" ]]; then printf true; else printf false; fi)" \
    --argjson port "$PP_PRODUCTION_PORT" \
    '{at:$at,env:"production",commit:$commit,result:$result,unit:$unit,port:$port,note:$note,
      artifact_rollback:$artifact,
      dashboard:{enabled:$dashboard_enabled,unit:$dashboard_unit,dropin:$dropin,
                 dropin_removed:$dashboard_dropin_removed,health_ok:$dashboard_health_ok}}' 2>/dev/null)" \
    || { log_warn "台帳の行を作成できません"; return 0; }
  if printf '%s\n' "$line" >> "$ledger" 2>/dev/null; then
    pp__log "  台帳に ROLLED_BACK を記録: $ledger"
  else
    log_warn "台帳に追記できません: $ledger"
  fi
}

# pp__rollback — (3)〜(5) 失敗時の自動復旧。成功で 0、失敗（要人手）で 1
pp__rollback() {
  pp__disarm_trap
  local rc=0 sysctl
  sysctl="$(pp__systemctl)"
  pp__log ""
  pp__log "== 自動復旧を開始 =="

  # 1) unit をバックアップから戻す
  if [[ -n "$PP_BACKUP" && -f "$PP_BACKUP" ]]; then
    if pp__run_step "unit-restore" cp -p -- "$PP_BACKUP" "$PP_UNIT_PATH"; then
      PP_BACKUP_SHA_AFTER="$(sha256sum -- "$PP_UNIT_PATH" | awk '{print $1}')"
      if [[ "$PP_BACKUP_SHA_AFTER" == "$PP_BACKUP_SHA" ]]; then
        pp__log "  unit をバックアップから復元しました (sha256=${PP_BACKUP_SHA:0:12}…)"
      else
        # 失敗 step の記録を上書きしないよう、検証結果だけを記録する
        pp__record_step "unit-restore-verify" "false"
        PP_RESULT="ROLLBACK_FAILED"
        PP_REASON="復元後の unit の sha256 がバックアップと一致しません"
        return 1
      fi
    else
      PP_RESULT="ROLLBACK_FAILED"
      PP_REASON="unit をバックアップから復元できませんでした"
      return 1
    fi
  else
    PP_RESULT="ROLLBACK_FAILED"
    PP_REASON="unit のバックアップがありません"
    return 1
  fi

  # 2) 成果物 symlink を戻す。previous が無い初回昇格では symlink を削除する (H1)
  if ! pp__artifact_rollback; then
    PP_RESULT="ROLLBACK_FAILED"
    PP_REASON="production-current の削除に失敗しました"
    return 1
  fi

  # 2.5) dashboard の drop-in を削除（(3d) を実行した場合のみ）
  if (( PP_DASHBOARD )); then
    local dropin
    dropin="$(pp__dropin_path)"
    if [[ -e "$dropin" ]]; then
      if ! pp__run_step "dashboard-dropin-remove" rm -f -- "$dropin"; then
        PP_RESULT="ROLLBACK_FAILED"
        PP_REASON="dashboard の drop-in を削除できませんでした: $dropin"
        return 1
      fi
      PP_DASHBOARD_DROPIN_REMOVED="true"
    else
      pp__record_step "dashboard-dropin-remove" "true"
      PP_DASHBOARD_DROPIN_REMOVED="true"
    fi
  fi

  # 3) daemon-reload + restart
  if ! pp__run_step "daemon-reload" "$sysctl" --user daemon-reload; then
    PP_RESULT="ROLLBACK_FAILED"
    PP_REASON="daemon-reload に失敗しました"
    return 1
  fi
  if ! pp__run_step "restart" "$sysctl" --user restart "$PP_UNIT_NAME"; then
    PP_RESULT="ROLLBACK_FAILED"
    PP_REASON="unit の restart に失敗しました"
    return 1
  fi

  # 4) health 確認
  local body=""
  if pp__health_ok; then
    pp__record_step "health" "true"
    pp__log "  health: OK (127.0.0.1:${PP_PRODUCTION_PORT}/api/health ok:true)"
  else
    pp__record_step "health" "false"
    PP_RESULT="ROLLBACK_FAILED"
    PP_REASON="復旧後の health が ok:true になりませんでした"
    return 1
  fi

  # 5) dashboard を元の unit 定義で restart し、3737 の health を確認
  if (( PP_DASHBOARD )); then
    if ! pp__run_step "dashboard-restart" "$(pp__systemctl)" --user restart "$PP_DASHBOARD_UNIT"; then
      PP_RESULT="ROLLBACK_FAILED"
      PP_REASON="dashboard の restart に失敗しました"
      return 1
    fi
    if pp__dashboard_health_ok; then
      pp__record_step "dashboard-health" "true"
      PP_DASHBOARD_HEALTH_OK="true"
      pp__log "  dashboard health: OK (127.0.0.1:${PP_DASHBOARD_PORT}/api/health status=ok)"
    else
      pp__record_step "dashboard-health" "false"
      PP_RESULT="ROLLBACK_FAILED"
      PP_REASON="復旧後の dashboard health (3737) が status=ok になりませんでした"
      return 1
    fi
  fi

  PP_ROLLED_BACK="true"
  pp__record_rollback
  pp__log "== 自動復旧が完了しました（本番は元の状態で稼働中）=="
  return 0
}

# ------------------------------------------------------------
# 計画表示
# ------------------------------------------------------------

pp__print_plan() {
  local rel="$1"
  printf 'Production promote plan\n'
  printf '  release      : %s\n' "$rel"
  printf '  home         : %s\n' "$PP_HOME"
  printf '  unit         : %s\n' "$PP_UNIT_PATH"
  printf '  unit backup  : %s.bak-%s\n' "$PP_UNIT_PATH" "${PP_TS:-<ts>}"
  if (( PP_DASHBOARD )); then
    printf '  dashboard    : %s (3737) / drop-in: %s\n' "$PP_DASHBOARD_UNIT" "$(pp__dropin_path)"
  else
    printf '  dashboard    : 無効 (--no-dashboard)\n'
  fi
  printf '  systemctl    : %s\n' "$(pp__systemctl)"
  printf '  state file   : %s\n' "$PP_STATE_FILE"
  if [[ -f "$PP_CONFIG_PATH" ]]; then
    printf '  config       : %s\n' "$PP_CONFIG_PATH"
  else
    printf '  config       : %s  ← 存在しません（実行時は (0b) で中止。CCSU_PROMOTE_CONFIG_PATH を指定）\n' "$PP_CONFIG_PATH"
  fi
  printf '  steps:\n'
  printf '    (0) %s --release %s --json\n' "$(pp__bin pre-promote-check.sh)" "$rel"
  printf '    (1) cp -p %s %s.bak-%s (+ sha256 記録)\n' "$PP_UNIT_PATH" "$PP_UNIT_PATH" "${PP_TS:-<ts>}"
  printf '    (2) %s --env production --release %s --no-restart --json\n' "$(pp__bin release-promote.sh)" "$rel"
  printf '    (3) %s --register --profile production --root %s/releases/production-current --env AI_STARTUP_CONFIG_PATH=%s --state-file %s\n' \
    "$(pp__bin web-startup-service.sh)" "$PP_HOME" "$PP_CONFIG_PATH" "$PP_STATE_FILE"
  if (( PP_DASHBOARD )); then
    printf '    (3d) drop-in: %s → WorkingDirectory/ExecStart を production-current へ → daemon-reload → restart %s → 3737 health (status=ok)\n' \
      "$(pp__dropin_path)" "$PP_DASHBOARD_UNIT"
  fi
  printf '    (4) %s --env production --release %s --json\n' "$(pp__bin release-promote.sh)" "$rel"
  printf '    (5) %s --env production --json\n' "$(pp__bin post-deploy-smoke.sh)"
  printf '  失敗時 (3)〜(5): unit をバックアップへ戻す → symlink を --rollback → dashboard drop-in を削除 → daemon-reload → restart → health 確認\n'
  printf '  exit: 0 成功 / 1 失敗（復旧済み） / 2 引数 / 3 確認待ち / 4 復旧も失敗\n'
}

# ------------------------------------------------------------
# JSON
# ------------------------------------------------------------

pp__steps_json() {
  local i out="["
  for i in "${!PP_STEP_NAMES[@]}"; do
    [[ $i -gt 0 ]] && out+=","
    out+="$(jq -cn --arg n "${PP_STEP_NAMES[$i]}" --argjson ok "${PP_STEPS[$i]}" '{name:$n,ok:$ok}')"
  done
  out+="]"
  printf '%s' "$out"
}

pp__json_line() {
  local ok="$1" result="$2" reason="$3"
  local ok_json steps_json failed_json
  if [[ "$ok" == "true" ]]; then ok_json='true'; else ok_json='false'; fi
  steps_json="$(pp__steps_json)"
  if [[ -n "$PP_FAILED_STEP" ]]; then
    failed_json="$(jq -cn --arg n "$PP_FAILED_STEP" '$n')"
  else
    failed_json='null'
  fi
  local rb_json
  if [[ "$PP_ROLLED_BACK" == "true" ]]; then rb_json='true'; else rb_json='false'; fi

  jq -cn \
    --argjson ok "$ok_json" --arg release "$PP_RELEASE" \
    --argjson steps "$steps_json" --argjson rolled_back "$rb_json" \
    --arg backup "$PP_BACKUP" --arg result "$result" \
    --arg reason "$reason" --argjson failed_step "$failed_json" \
    --arg unit "$PP_UNIT_PATH" --arg home "$PP_HOME" \
    --argjson port "$PP_PRODUCTION_PORT" \
    --argjson dashboard_enabled "$(if (( PP_DASHBOARD )); then printf true; else printf false; fi)" \
    --arg dashboard_unit "$PP_DASHBOARD_UNIT" \
    --arg artifact_rollback "$PP_ARTIFACT_ROLLBACK" \
    --arg dropin "$PP_DROPIN" \
    --argjson dashboard_port "$PP_DASHBOARD_PORT" \
    '{ok:$ok, release:$release, steps:$steps, rolled_back:$rolled_back,
      backup:$backup, result:$result, failed_step:$failed_step,
      reason:(if $reason == "" then null else $reason end),
      unit:$unit, home:$home, port:$port,
      artifact_rollback:$artifact_rollback,
      dashboard:{enabled:$dashboard_enabled, unit:$dashboard_unit, dropin:$dropin, port:$dashboard_port}}'
}

# ------------------------------------------------------------
# main
# ------------------------------------------------------------

main() {
  local wants_json=0 a
  for a in "$@"; do
    if [[ "$a" == "--json" ]]; then wants_json=1; fi
  done

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --release)
        if [[ $# -lt 2 ]]; then
          log_error "--release には値が必要です"
          if (( wants_json )); then printf '{"ok":false,"error":"ARG_INVALID","message":"--release には値が必要です"}\n'; fi
          return 2
        fi
        PP_RELEASE="$2"; shift 2 ;;
      --dry-run) PP_DRY_RUN=1; shift ;;
      --no-dashboard) PP_DASHBOARD=0; shift ;;
      --yes) PP_YES=1; shift ;;
      --json) PP_JSON=1; shift ;;
      -h|--help) usage; return 0 ;;
      *)
        log_error "不明な引数: $1"
        if (( wants_json )); then
          jq -cn --arg m "不明な引数: $1" '{ok:false,error:"ARG_INVALID",message:$m}'
        fi
        return 2 ;;
    esac
  done

  if [[ -z "$PP_RELEASE" ]]; then
    log_error "--release <40hex> は必須です"
    if (( wants_json )); then
      jq -cn --arg m "--release <40hex> は必須です" '{ok:false,error:"ARG_INVALID",message:$m}'
    fi
    return 2
  fi
  if [[ ! "$PP_RELEASE" =~ ^[0-9a-f]{40}$ ]]; then
    log_error "--release は 40 桁 hex で指定してください: $PP_RELEASE"
    if (( wants_json )); then
      jq -cn --arg m "--release は 40 桁 hex で指定してください: $PP_RELEASE" '{ok:false,error:"ARG_INVALID",message:$m}'
    fi
    return 2
  fi

  PP_HOME="$(pp__home)"
  if [[ "$PP_HOME" != /* || "$PP_HOME" == "/" ]]; then
    log_error "CLAUDEOS_HOME は絶対パスで / 以外を指定してください: $PP_HOME"
    if (( wants_json )); then
      jq -cn --arg m "CLAUDEOS_HOME が不正です: $PP_HOME" '{ok:false,error:"ARG_INVALID",message:$m}'
    fi
    return 2
  fi
  export CLAUDEOS_HOME="$PP_HOME"

  PP_UNIT_PATH="$(pp__unit_path)"

  # drop-in パス（dashboard 切替が有効なときだけ意味を持つ）
  if (( PP_DASHBOARD )); then
    PP_DROPIN="$(pp__dropin_path)"
  fi
  PP_TS="${CCSU_PROMOTE_TS:-$(date +%Y%m%d-%H%M%S)}"

  # 計画を出す (--yes が無い / --dry-run)
  if (( ! PP_YES )) || (( PP_DRY_RUN )); then
    pp__print_plan "$PP_RELEASE"
    if (( PP_DRY_RUN )); then
      pp__log ""
      pp__log "dry-run: 何も変更していません（バックアップも作成しません）"
      if (( PP_JSON )); then pp__json_line "true" "DRY_RUN" ""; fi
      return 0
    fi
    pp__log ""
    pp__log "確認待ち: 実行するには --yes を付けて再実行してください（何も変更していません）"
    if (( PP_JSON )); then pp__json_line "false" "AWAITING_CONFIRMATION" ""; fi
    return 3
  fi

  require_cmd jq
  require_cmd sha256sum
  require_cmd flock

  # 二重実行防止 (M2): releases/.promote-production.lock を排他取得できなければ中止
  if ! pp__acquire_lock; then
    log_error "他の promote-production が実行中です（lock: $(pp__home)/releases/.promote-production.lock）。中止します"
    if (( PP_JSON )); then
      jq -cn --arg m "他の promote-production が実行中です (lock 取得失敗)" '{ok:false,error:"LOCKED",message:$m}'
    fi
    return 2
  fi
  # ロックは終了時に必ず解放する
  trap 'pp__release_lock' EXIT

  pp__log "== Production 昇格を開始: $PP_RELEASE =="

  # (0) ゲート
  local gate_out="" gate_rc=0 gate_ok="false"
  gate_out="$(bash "$(pp__bin pre-promote-check.sh)" --release "$PP_RELEASE" --json --home "$PP_HOME" 2>&1)" || gate_rc=$?
  if (( PP_JSON )); then
    printf '%s\n' "$gate_out" >&2
  else
    printf '%s\n' "$gate_out" | sed 's/^/    /'
  fi
  if (( gate_rc == 0 )); then
    gate_ok="$(printf '%s' "$gate_out" | tail -n 1 | jq -r '.ok // false' 2>/dev/null || printf 'false')"
  fi
  if [[ "$gate_ok" != "true" ]]; then
    pp__record_step "pre-promote-check" "false"
    PP_FAILED_STEP="pre-promote-check"
    PP_RESULT="ABORTED"
    PP_REASON="pre-promote-check が ok ではありません (exit $gate_rc)"
    pp__log "中止: $PP_REASON（成果物・unit・symlink は変更していません）"
    if (( PP_JSON )); then pp__json_line "false" "ABORTED" "$PP_REASON"; fi
    return 1
  fi
  pp__record_step "pre-promote-check" "true"
  pp__log "  (0) pre-promote-check: OK"

  # (0b) 実機設定 (git 管理外) の存在確認。
  #   worktree や成果物から実行すると <repo>/config/config.json が無く、unit 差し替え後に
  #   本番が設定を読めなくなる。差し替え前に必ず止める（何も変更しない）。
  if [[ ! -f "$PP_CONFIG_PATH" || ! -r "$PP_CONFIG_PATH" ]] || ! jq -e 'type == "object"' "$PP_CONFIG_PATH" >/dev/null 2>&1; then
    pp__record_step "config-check" "false"
    PP_FAILED_STEP="config-check"
    PP_RESULT="ABORTED"
    PP_REASON="AI_STARTUP_CONFIG_PATH が読めない/JSON でない: $PP_CONFIG_PATH（CCSU_PROMOTE_CONFIG_PATH で実機設定を指定してください。何も変更していません）"
    pp__log "中止: $PP_REASON"
    if (( PP_JSON )); then pp__json_line "false" "ABORTED" "$PP_REASON"; fi
    return 1
  fi
  # state file: 絶対パスで、置き場所 (ディレクトリ) が存在すること。ファイル自体は未作成でもよい
  case "$PP_STATE_FILE" in
    /*) ;;
    *) PP_STATE_FILE="" ;;
  esac
  if [[ -z "$PP_STATE_FILE" || ! -d "$(dirname "$PP_STATE_FILE")" ]]; then
    pp__record_step "config-check" "false"
    PP_FAILED_STEP="config-check"
    PP_RESULT="ABORTED"
    PP_REASON="CCSU_STATE_FILE の置き場所が無い/絶対パスでない: ${PP_STATE_FILE:-<empty>}（CCSU_PROMOTE_STATE_FILE で指定してください。何も変更していません）"
    pp__log "中止: $PP_REASON"
    if (( PP_JSON )); then pp__json_line "false" "ABORTED" "$PP_REASON"; fi
    return 1
  fi
  pp__record_step "config-check" "true"
  pp__log "  (0b) config: $PP_CONFIG_PATH / state: $PP_STATE_FILE"

  # (1) unit バックアップ
  if [[ ! -f "$PP_UNIT_PATH" ]]; then
    pp__record_step "unit-backup" "false"
    PP_FAILED_STEP="unit-backup"
    PP_RESULT="ABORTED"
    PP_REASON="本番 unit が見つかりません: $PP_UNIT_PATH（何も変更していません）"
    pp__log "中止: $PP_REASON"
    if (( PP_JSON )); then pp__json_line "false" "ABORTED" "$PP_REASON"; fi
    return 1
  fi
  PP_BACKUP="$PP_UNIT_PATH.bak-$PP_TS"
  if ! pp__run_step "unit-backup" cp -p -- "$PP_UNIT_PATH" "$PP_BACKUP"; then
    PP_RESULT="ABORTED"
    PP_REASON="unit のバックアップに失敗しました（何も変更していません）"
    pp__log "中止: $PP_REASON"
    if (( PP_JSON )); then pp__json_line "false" "ABORTED" "$PP_REASON"; fi
    return 1
  fi
  PP_BACKUP_SHA="$(sha256sum -- "$PP_BACKUP" | awk '{print $1}')"
  pp__log "  (1) unit バックアップ: $PP_BACKUP (sha256=${PP_BACKUP_SHA:0:12}…)"

  # ここから (5) 完了までは、中断されても必ず自動復旧する (H2)
  pp__arm_trap

  # (2) symlink 準備 (--no-restart)
  # 台帳の PROMOTED は手順 (4) の本実行が 1 行だけ残す (二重記録の防止)
  if ! pp__run_step "symlink-prep" \
    env CCSU_PROMOTE_SKIP_PROMOTED_LEDGER=1 \
    bash "$(pp__bin release-promote.sh)" --env production --release "$PP_RELEASE" --no-restart --json; then
    pp__disarm_trap
    PP_RESULT="ABORTED"
    PP_REASON="symlink 準備に失敗しました（unit は未変更）"
    pp__log "中止: $PP_REASON"
    if (( PP_JSON )); then pp__json_line "false" "ABORTED" "$PP_REASON"; fi
    return 1
  fi
  pp__log "  (2) symlink 準備: OK"

  # (3) unit 差し替え (restart 込み)
  local failed_phase=""
  if ! pp__run_step "unit-swap" \
    bash "$(pp__bin web-startup-service.sh)" --register --profile production \
      --root "$PP_HOME/releases/production-current" \
      --env "AI_STARTUP_CONFIG_PATH=$PP_CONFIG_PATH" \
      --state-file "$PP_STATE_FILE"; then
    failed_phase="unit-swap"
  fi

  # (3d) dashboard を drop-in で成果物起動へ切り替える（既存 unit は変更しない）
  if [[ -z "$failed_phase" ]] && (( PP_DASHBOARD )); then
    if ! pp__run_step "dashboard-switch" pp__switch_dashboard; then
      failed_phase="dashboard-switch"
    fi
  fi

  # (4) 昇格確定 (restart + health + 台帳)
  if [[ -z "$failed_phase" ]]; then
    if ! pp__run_step "promote" \
      bash "$(pp__bin release-promote.sh)" --env production --release "$PP_RELEASE" --json; then
      failed_phase="promote"
    fi
  fi

  # (5) 配備後スモーク
  if [[ -z "$failed_phase" ]]; then
    if ! pp__run_step "post-deploy-smoke" \
      bash "$(pp__bin post-deploy-smoke.sh)" --env production --json; then
      failed_phase="post-deploy-smoke"
    fi
  fi

  # 成功
  if [[ -z "$failed_phase" ]]; then
    pp__disarm_trap
    PP_RESULT="PROMOTED"
    pp__log ""
    pp__log "== 昇格完了: $PP_RELEASE (unit=$PP_UNIT_NAME) =="
    if (( PP_JSON )); then pp__json_line "true" "PROMOTED" ""; fi
    return 0
  fi

  # (3)〜(5) の失敗 → 自動復旧
  pp__log ""
  pp__log "!! step '$failed_phase' が失敗しました。自動復旧を試みます"
  if pp__rollback; then
    pp__log "== 昇格失敗（自動復旧済み）: $PP_REASON =="
    if (( PP_JSON )); then pp__json_line "false" "ROLLED_BACK" "$PP_REASON"; fi
    return 1
  fi

  pp__log "== 自動復旧に失敗しました。人手で §5 を実行してください: $PP_REASON =="
  if (( PP_JSON )); then pp__json_line "false" "ROLLBACK_FAILED" "$PP_REASON"; fi
  return 4
}

rc=0
main "$@" || rc=$?
exit "$rc"
