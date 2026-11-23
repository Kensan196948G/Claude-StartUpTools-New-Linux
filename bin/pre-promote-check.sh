#!/usr/bin/env bash
# ============================================================
# pre-promote-check.sh — 本番昇格の直前ゲート（読み取り専用）
#
# 「昇格してよいか」を 1 コマンドで判定する。判定のみで、バックアップ作成・
# symlink 張り替え・unit 変更・state 更新は一切行わない。
#
# 使い方:
#   bin/pre-promote-check.sh --release <40hex> [--json] [--home DIR]
#
#   --release <40hex>  昇格対象の release（$CLAUDEOS_HOME/releases/<40hex>）
#   --json             最終行に 1 行 JSON を出す（人間向けログは stderr）
#   --home DIR         ClaudeOS ホームを上書き（既定 $CLAUDEOS_HOME か ~/.claudeos）
#   -h, --help         このヘルプ
#
# 検査項目（PASS / FAIL / WARN）:
#   1. artifact         release dir / manifest / files[].sha256 / tree_sha256 を再計算照合
#                       （scripts/release/verify-artifact.sh があればそれを使う）
#   2. staging 一致     staging-current の manifest.tree_sha256 が対象と一致（未検証は FAIL）
#   3. unit バックアップ 本番 unit の .bak-* が 1 件以上（無ければ作成コマンドを表示して FAIL）
#   4. production health 3740 が 200 + ok:true（落ちていれば FAIL）
#   5. staging health    3742 が 200 + ok:true（落ちていても WARN）
#   6. disk             releases のファイルシステム空き >= 1 GiB（不足は WARN）
#   7. production-current 現状（初回昇格は previous 不在の戻し手順を表示）
#
# 環境変数:
#   CCSU_SYSTEMCTL_BIN             systemctl 実体（bats スタブ差し替え用）
#   CCSU_CURL_BIN                  curl 実体（bats スタブ差し替え用）
#   CCSU_SYSTEMD_USER_DIR          unit ディレクトリ（既定 ${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user）
#   CCSU_VERIFY_ARTIFACT_BIN       verify-artifact.sh のパス（既定: リポジトリ内の実体。テスト用）
#   CCSU_PRE_PROMOTE_TIMEOUT       HTTP タイムアウト秒（既定 5）
#   CCSU_PRE_PROMOTE_MIN_FREE_MB   ディスク空きの下限 MiB（既定 1024）
#
# exit: 0 FAIL 0 / 1 FAIL あり / 2 引数エラー
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

PRODUCTION_PORT=3740
STAGING_PORT=3742
PRODUCTION_UNIT="claudeos-web-startup.service"

PC_JSON=0
PC_HOME="${CLAUDEOS_HOME:-$HOME/.claudeos}"
PC_RELEASE_ARG=""
PC_TIMEOUT="${CCSU_PRE_PROMOTE_TIMEOUT:-5}"
PC_MIN_FREE_MB="${CCSU_PRE_PROMOTE_MIN_FREE_MB:-1024}"

PC_CHECKS=0
PC_FAILED=0
PC_WARNINGS=0
PC_TREE=""
PC_COMMIT=""

# json モードでは人間向けログを stderr へ逃がし、stdout を最終 JSON 1 行だけにする
pc__log() { if (( PC_JSON )); then printf '%s\n' "$*" >&2; else printf '%s\n' "$*"; fi; }

usage() {
  cat <<'EOF'
Usage: pre-promote-check.sh --release <40hex> [--json] [--home DIR]

  --release <40hex>  昇格対象の release（$CLAUDEOS_HOME/releases/<40hex>）
  --json             最終行に 1 行 JSON を出力（人間向けログは stderr）
  --home DIR         ClaudeOS ホームを上書き（既定 $CLAUDEOS_HOME か ~/.claudeos）
  -h, --help         このヘルプ

検査: artifact / staging 一致 / unit バックアップ / production health /
      staging health / disk / production-current
exit: 0 FAIL 0 / 1 FAIL あり / 2 引数エラー

このスクリプトは読み取り専用です。バックアップ作成・symlink・unit 変更は行いません。
EOF
}

pc__json_error() {
  local code="$1" message="$2"
  if (( PC_JSON )); then
    printf '{"ok":false,"error":"%s","message":"%s"}\n' "$code" "$message"
  fi
}

pc__arg_error() {
  pc__json_error BAD_ARGS "$1"
  printf 'pre-promote-check: %s\n' "$1" >&2
  usage >&2
  exit 2
}

# pc__record <PASS|FAIL|WARN> <label> [detail]
pc__record() {
  local status="$1" label="$2" detail="${3:-}"
  local suffix=""
  [[ -n "$detail" ]] && suffix=" — $detail"
  case "$status" in
    PASS)
      PC_CHECKS=$((PC_CHECKS + 1))
      pc__log "  [PASS] ${label}${suffix}"
      ;;
    FAIL)
      PC_CHECKS=$((PC_CHECKS + 1))
      PC_FAILED=$((PC_FAILED + 1))
      pc__log "  [FAIL] ${label}${suffix}"
      ;;
    WARN)
      PC_CHECKS=$((PC_CHECKS + 1))
      PC_WARNINGS=$((PC_WARNINGS + 1))
      pc__log "  [WARN] ${label}${suffix}"
      ;;
    *)
      printf 'internal error: bad status: %s\n' "$status" >&2
      return 1
      ;;
  esac
  return 0
}

pc__systemctl_bin() { printf '%s' "${CCSU_SYSTEMCTL_BIN:-systemctl}"; }
pc__curl_bin()      { printf '%s' "${CCSU_CURL_BIN:-curl}"; }
pc__unit_dir()      { printf '%s' "${CCSU_SYSTEMD_USER_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user}"; }
pc__releases_dir()  { printf '%s/releases' "$PC_HOME"; }

# pc__fetch <url> — "body\n<code>" を返す（接続不可は code=000）
pc__fetch() {
  local url="$1" resp=""
  resp="$("$(pc__curl_bin)" -sS --max-time "$PC_TIMEOUT" -w $'\n%{http_code}' "$url" 2>/dev/null)" || true
  if [[ -z "$resp" ]]; then
    printf '\n000'
    return 0
  fi
  printf '%s' "$resp"
}

# ------------------------------------------------------------
# 1. artifact 整合性
# ------------------------------------------------------------
# pc__manifest_value <manifest> <jq expr>
pc__manifest_value() {
  jq -r "$2" "$1" 2>/dev/null || true
}

# pc__verify_builtin <dir> — 内蔵検証。成功時 PC_COMMIT / PC_TREE を設定
pc__verify_builtin() {
  local dir="$1" m="$1/manifest.json"
  local schema commit tree declared_count actual_count
  local path declared size file actual computed
  local -a pairs=()

  [[ -f "$m" ]] || { pc__log "  manifest.json がありません: $m"; return 1; }
  jq -e . "$m" >/dev/null 2>&1 || { pc__log "  manifest.json が JSON として不正です"; return 1; }

  schema="$(pc__manifest_value "$m" '.schema_version // empty')"
  [[ "$schema" == "1" ]] || { pc__log "  schema_version が 1 ではありません (${schema:-none})"; return 1; }
  commit="$(pc__manifest_value "$m" '.commit // empty')"
  [[ "$commit" =~ ^[0-9a-f]{40}$ ]] || { pc__log "  commit が 40 桁 hex ではありません (${commit:-none})"; return 1; }
  tree="$(pc__manifest_value "$m" '.tree_sha256 // empty')"
  [[ "$tree" =~ ^[0-9a-f]{64}$ ]] || { pc__log "  tree_sha256 が 64 桁 hex ではありません (${tree:-none})"; return 1; }
  jq -e '.files | (type == "array") and (length > 0)' "$m" >/dev/null 2>&1 \
    || { pc__log "  files が空、または配列ではありません"; return 1; }
  jq -e 'all(.files[]; ((.path | type) == "string") and ((.sha256 | type) == "string") and ((.size | type) == "number"))' "$m" >/dev/null 2>&1 \
    || { pc__log "  files[] に path/sha256/size が揃っていません"; return 1; }
  jq -e 'all(.files[]; .sha256 | test("^[0-9a-f]{64}$"))' "$m" >/dev/null 2>&1 \
    || { pc__log "  files[].sha256 が 64 桁 hex ではありません"; return 1; }
  if jq -r '.files[].path' "$m" | grep -qE '^(/|.*(^|/)\.\.(/|$))'; then
    pc__log "  files[].path に絶対パスまたは '..' が含まれています"
    return 1
  fi

  declared_count="$(pc__manifest_value "$m" '.file_count // empty')"
  actual_count="$(pc__manifest_value "$m" '.files | length')"
  [[ "$declared_count" == "$actual_count" ]] \
    || { pc__log "  file_count ($declared_count) と files 件数 ($actual_count) が一致しません"; return 1; }

  while IFS=$'\t' read -r path declared size; do
    if [[ -z "$path" ]]; then continue; fi
    file="$dir/$path"
    [[ -f "$file" ]] || { pc__log "  manifest 記載ファイルが存在しません: $path"; return 1; }
    actual="$(sha256sum -- "$file" 2>/dev/null | cut -d' ' -f1)" || true
    [[ -n "$actual" ]] || { pc__log "  sha256 を計算できません: $path"; return 1; }
    [[ "$actual" == "$declared" ]] \
      || { pc__log "  sha256 不一致: $path (manifest=$declared actual=$actual)"; return 1; }
    local actual_size
    actual_size="$(stat -c %s -- "$file" 2>/dev/null)" || true
    [[ "$actual_size" == "$size" ]] \
      || { pc__log "  size 不一致: $path (manifest=$size actual=${actual_size:-?})"; return 1; }
    pairs+=("$path"$'\t'"$actual")
  done < <(jq -r '.files[] | "\(.path)\t\(.sha256)\t\(.size)"' "$m" 2>/dev/null)

  computed="$(
    printf '%s\n' "${pairs[@]}" \
      | LC_ALL=C sort -t $'\t' -k1,1 \
      | while IFS=$'\t' read -r path actual; do printf '%s\0%s\n' "$path" "$actual"; done \
      | sha256sum | awk '{print $1}'
  )" || { pc__log "  tree_sha256 を計算できません"; return 1; }
  [[ "$computed" == "$tree" ]] \
    || { pc__log "  tree_sha256 不一致 (manifest=$tree computed=$computed)"; return 1; }

  PC_COMMIT="$commit"
  PC_TREE="$tree"
  return 0
}

pc__check_artifact() {
  local dir="$1" verify_bin out last
  verify_bin="${CCSU_VERIFY_ARTIFACT_BIN:-$SCRIPT_DIR/../scripts/release/verify-artifact.sh}"

  if [[ ! -d "$dir" ]]; then
    pc__record FAIL "artifact" "release dir がありません: $dir"
    return 0
  fi

  if [[ -n "$verify_bin" && -f "$verify_bin" && -x "$verify_bin" ]]; then
    if out="$("$verify_bin" "$dir" --json 2>/dev/null)"; then
      last="$(printf '%s\n' "$out" | tail -n 1)"
      if printf '%s' "$last" | jq -e '.ok == true' >/dev/null 2>&1; then
        PC_TREE="$(printf '%s' "$last" | jq -r '.tree_sha256 // empty')"
        PC_COMMIT="$(pc__manifest_value "$dir/manifest.json" '.commit // empty')"
        pc__record PASS "artifact" "verify-artifact.sh OK (commit=${PC_COMMIT:-?}, tree=${PC_TREE:-?})"
        return 0
      fi
    fi
    pc__record FAIL "artifact" "verify-artifact.sh が NG を返しました (${verify_bin})"
    return 0
  fi

  if [[ -z "$PC_TREE" ]]; then
    if pc__verify_builtin "$dir"; then
      pc__record PASS "artifact" "内蔵検証 OK (commit=$PC_COMMIT, tree=$PC_TREE)"
    else
      pc__record FAIL "artifact" "manifest / sha256 / tree_sha256 の検証に失敗しました"
    fi
  fi
  return 0
}

# ------------------------------------------------------------
# 2. staging-current と同一 artifact か
# ------------------------------------------------------------
pc__check_staging() {
  local link dir m tree
  link="$(pc__releases_dir)/staging-current"

  if [[ ! -L "$link" ]]; then
    pc__record FAIL "staging 一致" "staging-current がありません（先に staging へ昇格して検証してください）"
    return 0
  fi
  if ! dir="$(realpath -e -- "$link" 2>/dev/null)"; then
    pc__record FAIL "staging 一致" "staging-current が壊れています (dangling symlink): $link"
    return 0
  fi
  m="$dir/manifest.json"
  if [[ ! -f "$m" ]]; then
    pc__record FAIL "staging 一致" "staging-current の manifest.json がありません: $m"
    return 0
  fi
  tree="$(pc__manifest_value "$m" '.tree_sha256 // empty')"
  if [[ -z "$PC_TREE" ]]; then
    pc__record FAIL "staging 一致" "対象 artifact の tree_sha256 を確定できないため比較できません"
    return 0
  fi
  if [[ "$tree" == "$PC_TREE" ]]; then
    pc__record PASS "staging 一致" "staging-current tree=$tree"
  else
    pc__record FAIL "staging 一致" "staging=${tree:-none} / target=$PC_TREE（同一 artifact の staging 検証が必要）"
  fi
  return 0
}

# ------------------------------------------------------------
# 3. 本番 unit のバックアップ
# ------------------------------------------------------------
pc__check_unit_backup() {
  local unit_dir unit backups=() newest cmd
  unit_dir="$(pc__unit_dir)"
  unit="$unit_dir/$PRODUCTION_UNIT"
  shopt -s nullglob
  backups=("$unit_dir/$PRODUCTION_UNIT".bak-*)
  shopt -u nullglob

  cmd="cp -a \"$unit\" \"$unit.bak-\$(date +%Y%m%d-%H%M%S)\""

  if (( ${#backups[@]} > 0 )); then
    newest="$(printf '%s\n' "${backups[@]}" | LC_ALL=C sort | tail -n 1)"
    pc__record PASS "unit バックアップ" "found $(basename "$newest")"
    return 0
  fi

  if [[ ! -f "$unit" ]]; then
    pc__record FAIL "unit バックアップ" "本番 unit が見つかりません: $unit（作成: $cmd）"
    return 0
  fi
  pc__record FAIL "unit バックアップ" "バックアップがありません。作成: $cmd"
  return 0
}

# ------------------------------------------------------------
# 4/5. health
# ------------------------------------------------------------
pc__check_health() {
  local env_name="$1" port="$2" required="$3" url resp code body
  url="http://127.0.0.1:${port}/api/health"
  resp="$(pc__fetch "$url")"
  code="${resp##*$'\n'}"
  body="${resp%$'\n'*}"

  if [[ "$code" != "200" ]]; then
    if [[ "$required" == "FAIL" ]]; then
      pc__record FAIL "$env_name health" "GET $url -> ${code:-000} (200 期待)"
    else
      pc__record WARN "$env_name health" "GET $url -> ${code:-000} (200 期待 / 昇格自体はブロックしない)"
    fi
    return 0
  fi
  if ! printf '%s' "$body" | jq -e '.ok == true' >/dev/null 2>&1; then
    if [[ "$required" == "FAIL" ]]; then
      pc__record FAIL "$env_name health" "HTTP 200 だが .ok != true"
    else
      pc__record WARN "$env_name health" "HTTP 200 だが .ok != true"
    fi
    return 0
  fi
  pc__record PASS "$env_name health" "HTTP 200, ok:true"
  return 0
}

# ------------------------------------------------------------
# 6. disk
# ------------------------------------------------------------
pc__check_disk() {
  local dir avail_kb avail_mb
  dir="$(pc__releases_dir)"
  [[ -d "$dir" ]] || dir="$PC_HOME"
  [[ -d "$dir" ]] || dir="/"

  avail_kb="$(df -Pk -- "$dir" 2>/dev/null | awk 'NR==2 {print $4}')" || true
  if [[ ! "$avail_kb" =~ ^[0-9]+$ ]]; then
    pc__record WARN "disk" "空き容量を取得できません: $dir"
    return 0
  fi
  avail_mb=$((avail_kb / 1024))
  if (( avail_mb >= PC_MIN_FREE_MB )); then
    pc__record PASS "disk" "${dir}: 空き ${avail_mb} MiB (>= ${PC_MIN_FREE_MB} MiB)"
  else
    pc__record WARN "disk" "${dir}: 空き ${avail_mb} MiB (< ${PC_MIN_FREE_MB} MiB)"
  fi
  return 0
}

# ------------------------------------------------------------
# 7. production-current / 初回昇格
# ------------------------------------------------------------
pc__check_production_current() {
  local link dir m tree commit prev_file prev unit_state
  local releases
  releases="$(pc__releases_dir)"
  link="$releases/production-current"
  prev_file="$releases/production-previous"

  unit_state="$("$(pc__systemctl_bin)" --user show "$PRODUCTION_UNIT" -p ActiveState 2>/dev/null | head -n 1 || true)"

  if [[ ! -L "$link" ]]; then
    prev="$(cat -- "$prev_file" 2>/dev/null || true)"
    pc__record PASS "production-current" "初回昇格（production-current なし / previous=${prev:-なし}）"
    pc__log "  初回昇格の戻し手順（previous が無いため symlink では戻せません）:"
    pc__log "    1) systemctl --user stop $PRODUCTION_UNIT"
    pc__log "    2) unit バックアップを復元: cp -a <unit.bak-*> \$HOME/.config/systemd/user/$PRODUCTION_UNIT"
    pc__log "    3) systemctl --user daemon-reload && systemctl --user start $PRODUCTION_UNIT"
    pc__log "    4) production-current を作成した場合は削除する（初回は旧 target が無い）"
    return 0
  fi
  if ! dir="$(realpath -e -- "$link" 2>/dev/null)"; then
    pc__record WARN "production-current" "dangling symlink: $link"
    return 0
  fi
  m="$dir/manifest.json"
  if [[ ! -f "$m" ]]; then
    pc__record WARN "production-current" "symlink はあるが manifest.json がありません: $m"
    return 0
  fi
  commit="$(pc__manifest_value "$m" '.commit // empty')"
  tree="$(pc__manifest_value "$m" '.tree_sha256 // empty')"
  if [[ -f "$prev_file" ]]; then
    pc__record PASS "production-current" "current=${commit:-?} tree=${tree:-?} (previous あり: $(cat -- "$prev_file" 2>/dev/null || true) / unit=${unit_state:-unknown})"
  else
    pc__record PASS "production-current" "current=${commit:-?} tree=${tree:-?} (previous なし / unit=${unit_state:-unknown})"
    pc__log "  注意: previous が無いため失敗時に symlink で戻せません。unit バックアップから復元してください。"
  fi
  return 0
}

# ------------------------------------------------------------
# main
# ------------------------------------------------------------
main() {
  for arg in "$@"; do
    if [[ "$arg" == "--json" ]]; then
      PC_JSON=1
    fi
  done

  while (( $# > 0 )); do
    case "$1" in
      --release)
        (( $# >= 2 )) || pc__arg_error "--release には値が必要です"
        PC_RELEASE_ARG="$2"; shift 2 ;;
      --release=*)
        PC_RELEASE_ARG="${1#--release=}"; shift ;;
      --home)
        (( $# >= 2 )) || pc__arg_error "--home には値が必要です"
        PC_HOME="$2"; shift 2 ;;
      --home=*)
        PC_HOME="${1#--home=}"; shift ;;
      --json)
        shift ;;
      -h|--help)
        usage; exit 0 ;;
      *)
        pc__arg_error "未知のオプションです: $1" ;;
    esac
  done

  [[ -n "$PC_RELEASE_ARG" ]] || pc__arg_error "--release <40hex> は必須です"
  [[ "$PC_RELEASE_ARG" =~ ^[0-9a-f]{40}$ ]] \
    || pc__arg_error "--release は 40 桁 hex で指定してください: $PC_RELEASE_ARG"

  export CLAUDEOS_HOME="$PC_HOME"
  local release_dir
  release_dir="$(pc__releases_dir)/$PC_RELEASE_ARG"

  pc__log "== pre-promote-check =="
  pc__log "  release: $PC_RELEASE_ARG"
  pc__log "  home:    $PC_HOME"
  pc__log ""

  for dep in jq sha256sum curl df realpath; do
    if ! has_cmd "$dep"; then
      pc__record FAIL "require:$dep" "必須コマンドが見つかりません"
    fi
  done
  if (( PC_FAILED > 0 )); then
    pc__finish
  fi

  pc__check_artifact "$release_dir"
  pc__check_staging
  pc__check_unit_backup
  pc__check_health "production" "$PRODUCTION_PORT" FAIL
  pc__check_health "staging" "$STAGING_PORT" WARN
  pc__check_disk
  pc__check_production_current

  pc__finish
}

pc__finish() {
  local ok="false"
  if (( PC_FAILED == 0 )); then ok="true"; fi

  pc__log ""
  pc__log "== 結果: ${ok} (checks=$PC_CHECKS, failed=$PC_FAILED, warnings=$PC_WARNINGS) =="

  if (( PC_JSON )); then
    printf '{"ok":%s,"release":"%s","tree_sha256":"%s","checks":%d,"failed":%d,"warnings":%d}\n' \
      "$ok" "$PC_RELEASE_ARG" "$PC_TREE" "$PC_CHECKS" "$PC_FAILED" "$PC_WARNINGS"
  fi

  if (( PC_FAILED == 0 )); then
    exit 0
  fi
  exit 1
}

main "$@"
