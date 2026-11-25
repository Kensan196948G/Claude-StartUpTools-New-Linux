#!/usr/bin/env bash
# ============================================================
# release-promote.sh — リリース成果物の staging/production 昇格 (関数群)
#
# 役割: `bin/release-build.sh` が作った release dir ($CLAUDEOS_HOME/releases/<40hex>/)
#   を staging / production のカレントへ切り替える。同一 artifact を staging で
#   検証してから production へ昇格する経路だけを提供し、切替後の health 確認に
#   失敗したら自動で旧 target へ戻す (自動ロールバック)。
#
# リリース契約 (task-4 の release-build と同一。ここでは変更しない):
#   release dir : $CLAUDEOS_HOME/releases/<40hex>/
#   manifest.json:
#     {"schema_version":1,"commit","short_commit","ref","built_at",
#      "file_count","tree_sha256","files":[{"path","sha256","size"}]}
#   tree_sha256 = ソート済み `"<path>\0<sha256>\n"` 連結の sha256
#                 (本ファイルでは LC_ALL=C sort で path 昇順に並べる)
#
# 安全弁 (意図的に実装しないもの):
#   - 整合性 (manifest と実ファイル) が一致しない artifact は切り替えない。
#   - production 昇格は staging-current と同一 tree_sha256 を要求する。
#     `--force` のような迂回オプションは存在しない (実装しない)。
#
# テスト差し替え (bats 用。実 systemd / 実 HTTP を触らない):
#   CCSU_SYSTEMCTL_BIN  : systemctl 実体 (既定 systemctl)
#   CCSU_CURL_BIN       : curl 実体 (既定 curl)
#   CCSU_HEALTH_TIMEOUT : health リトライ上限秒 (既定 20)
#   CCSU_HEALTH_INTERVAL: health リトライ間隔秒 (既定 1。小数可)
#   CLAUDEOS_HOME       : releases の親 (テストは一時ディレクトリへ向ける)
#
# companion unit (コンソールと一緒に追従させる付随 unit):
#   RELEASE_PROMOTE_COMPANIONS : "unit=port,unit=port"。空文字で無効。
#     未設定時は env ごとの既定: staging = claude-startuptools-dashboard-stg.service=3743
#     / production = 空 (本番 dashboard は promote-production の drop-in 方式が担当)。
#   companion の存在は `systemctl --user show -p LoadState` で確認し、
#   not-found (または状態を判定できない) 場合はスキップして警告のみ。
#   companion の health は {"status":"ok"} で判定し、失敗はロールバック対象。
#
# 注意: このファイルは「source される」ため set -euo pipefail を設定しない。
#       厳格モードは実行エントリ (bin/release-promote.sh) で宣言する。
# ============================================================

# --- 二重 source 防止 ---
[[ -n "${_CCSU_RELEASE_PROMOTE_LOADED:-}" ]] && return 0
_CCSU_RELEASE_PROMOTE_LOADED=1

# --- 環境ごとの既定 unit / port ---
# 本番 unit 名と本番 port はここでしか定義しない (staging 実行時は使わない)。
RP_STAGING_UNIT="claudeos-web-startup-stg.service"
RP_STAGING_PORT=3742
RP_PRODUCTION_UNIT="claudeos-web-startup.service"
RP_PRODUCTION_PORT=3740

# --- companion unit (コンソールの昇格に追従させる付随 unit) ---
#   "unit=port" のカンマ区切り。RELEASE_PROMOTE_COMPANIONS で上書き可 (空で無効)。
#   staging の dashboard は staging の状態を配信するため追従させる。
#   production の既定は空: 本番 dashboard は promote-production の drop-in 方式が担当するため
#   ここからは触らない (二重管理を避ける)。
RP_STAGING_COMPANIONS_DEFAULT="claude-startuptools-dashboard-stg.service=3743"
RP_PRODUCTION_COMPANIONS_DEFAULT=""
# この昇格で restart した companion (ロールバック時に戻す対象)
RP_COMPANIONS_RESTARTED=()

# --- health リトライ (既定: 最大 20 秒) ---
RP_HEALTH_TIMEOUT="${CCSU_HEALTH_TIMEOUT:-20}"
RP_HEALTH_INTERVAL="${CCSU_HEALTH_INTERVAL:-1}"

# --- 呼び出し元が埋める状態 ---
RP_ENV=""
RP_UNIT=""
RP_PORT=""
RP_RELEASE_DIR=""
RP_COMMIT=""
RP_SHORT_COMMIT=""
RP_TREE=""
RP_CURRENT_REL=""
RP_REL_TARGET=""
RP_PREVIOUS_COMMIT=""
RP_PREVIOUS_TARGET=""
RP_RESULT=""
RP_ERR_CODE=""
RP_ERR_MSG=""

# --- フラグ (エントリが設定) ---
RP_JSON=0
RP_DRY_RUN=0
RP_NO_RESTART=0
RP_ROLLBACK=0

# ============================================================
# 基本ヘルパ
# ============================================================

# rp__home — ClaudeOS ホーム (呼び出し時点の env を尊重する)
rp__home() { printf '%s' "${CLAUDEOS_HOME:-$HOME/.claudeos}"; }

# rp__releases_dir — $CLAUDEOS_HOME/releases
rp__releases_dir() { printf '%s/releases' "$(rp__home)"; }

# rp__env_unit <env> — 既定 unit 名
rp__env_unit() {
  case "$1" in
    staging)    printf '%s' "$RP_STAGING_UNIT" ;;
    production) printf '%s' "$RP_PRODUCTION_UNIT" ;;
    *) return 1 ;;
  esac
}

# rp__env_port <env> — 既定 port
rp__env_port() {
  case "$1" in
    staging)    printf '%s' "$RP_STAGING_PORT" ;;
    production) printf '%s' "$RP_PRODUCTION_PORT" ;;
    *) return 1 ;;
  esac
}

# rp__systemctl_bin — systemctl 実体 (テスト差し替え)
rp__systemctl_bin() { printf '%s' "${CCSU_SYSTEMCTL_BIN:-systemctl}"; }

# rp__curl_bin — curl 実体 (テスト差し替え)
rp__curl_bin() { printf '%s' "${CCSU_CURL_BIN:-curl}"; }

# rp__set_error <code> <message> — エラー状態を記録 (終了はしない)
rp__set_error() {
  RP_ERR_CODE="$1"
  RP_ERR_MSG="$2"
}

# rp__fail <code> <message> — エラーを stderr に出して 1 を返す
rp__fail() {
  rp__set_error "$1" "$2"
  # 運用ログでも機械可読なコードが追えるよう、コードを前置する
  log_error "[$1] $2"
  return 1
}

# ============================================================
# release dir / manifest
# ============================================================

# rp__resolve_release_dir <40hex|dir> — RP_RELEASE_DIR を設定
rp__resolve_release_dir() {
  local arg="$1"
  RP_RELEASE_DIR=""
  if [[ -z "$arg" ]]; then
    rp__fail RELEASE_NOT_FOUND "release の指定が空です"
    return 1
  fi
  if [[ "$arg" =~ ^[0-9a-f]{40}$ ]]; then
    RP_RELEASE_DIR="$(rp__releases_dir)/$arg"
    return 0
  fi
  # パス指定 (相対は cwd 基準で絶対化。存在しなくても -m で正規化する)
  if ! RP_RELEASE_DIR="$(realpath -m -- "$arg")"; then
    rp__fail RELEASE_NOT_FOUND "release dir を解決できません: $arg"
    return 1
  fi
  return 0
}

# rp__validate_manifest <manifest path> — 構造検証 + RP_COMMIT/RP_TREE 設定
#   契約 (schema_version=1 / commit=40hex / tree_sha256=64hex / files[] の型) と
#   path の安全性 (絶対パス・'..' を拒否) を検証する。内容のハッシュは見ない。
rp__validate_manifest() {
  local m="$1"

  if [[ ! -f "$m" ]]; then
    rp__fail MANIFEST_MISSING "manifest.json が見つかりません: $m"
    return 1
  fi
  if ! jq -e . "$m" >/dev/null 2>&1; then
    rp__fail MANIFEST_INVALID "manifest.json が JSON として不正です: $m"
    return 1
  fi

  local sv
  sv="$(jq -r '.schema_version // empty' "$m" 2>/dev/null || true)"
  if [[ "$sv" != "1" ]]; then
    rp__fail MANIFEST_INVALID "schema_version が 1 ではありません (実際: ${sv:-none})"
    return 1
  fi

  local commit
  commit="$(jq -r '.commit // empty' "$m" 2>/dev/null || true)"
  if [[ ! "$commit" =~ ^[0-9a-f]{40}$ ]]; then
    rp__fail MANIFEST_INVALID "commit が 40 桁 hex ではありません: ${commit:-none}"
    return 1
  fi

  local tree
  tree="$(jq -r '.tree_sha256 // empty' "$m" 2>/dev/null || true)"
  if [[ ! "$tree" =~ ^[0-9a-f]{64}$ ]]; then
    rp__fail MANIFEST_INVALID "tree_sha256 が 64 桁 hex ではありません: ${tree:-none}"
    return 1
  fi

  if ! jq -e '.files | (type == "array") and (length > 0)' "$m" >/dev/null 2>&1; then
    rp__fail MANIFEST_INVALID "files が空、または配列ではありません"
    return 1
  fi
  if ! jq -e 'all(.files[]; ((.path | type) == "string") and ((.sha256 | type) == "string") and ((.size | type) == "number"))' "$m" >/dev/null 2>&1; then
    rp__fail MANIFEST_INVALID "files[] の要素に path/sha256/size が揃っていません"
    return 1
  fi
  if ! jq -e 'all(.files[]; .sha256 | test("^[0-9a-f]{64}$"))' "$m" >/dev/null 2>&1; then
    rp__fail MANIFEST_INVALID "files[].sha256 が 64 桁 hex ではありません"
    return 1
  fi

  # 危険パス (絶対パス / '..' セグメント) を拒否する
  if jq -r '.files[].path' "$m" | grep -qE '^(/|.*(^|/)\.\.(/|$))'; then
    rp__fail MANIFEST_INVALID "files[].path に絶対パスまたは '..' が含まれています"
    return 1
  fi

  local declared_count actual_count
  declared_count="$(jq -r '.file_count // empty' "$m" 2>/dev/null || true)"
  actual_count="$(jq -r '.files | length' "$m" 2>/dev/null || true)"
  if [[ "$declared_count" != "$actual_count" ]]; then
    rp__fail INTEGRITY_MISMATCH "file_count ($declared_count) と files 件数 ($actual_count) が一致しません"
    return 1
  fi

  RP_COMMIT="$commit"
  RP_SHORT_COMMIT="$(jq -r '.short_commit // empty' "$m" 2>/dev/null || true)"
  RP_TREE="$tree"
  return 0
}

# rp__sha256_of <file> — sha256 hex のみを出力
rp__sha256_of() {
  local out
  out="$(sha256sum -- "$1")" || return 1
  printf '%s' "${out%% *}"
}

# rp__verify_integrity <release dir> — 全 files の sha256 と tree_sha256 を再計算して照合
#   不一致は INTEGRITY_MISMATCH (切替しない)。manifest に無いファイルは警告のみ
#   (契約は「manifest 記載ファイルの一致」であり、追加ファイルの混入は警告で示す)。
rp__verify_integrity() {
  local dir="$1" m="$1/manifest.json"
  local path declared actual file
  local -a pairs=()

  while IFS=$'\t' read -r path declared _; do
    [[ -z "$path" ]] && continue
    file="$dir/$path"
    if [[ ! -f "$file" ]]; then
      rp__fail INTEGRITY_MISMATCH "manifest 記載ファイルが存在しません: $path"
      return 1
    fi
    if ! actual="$(rp__sha256_of "$file")"; then
      rp__fail INTEGRITY_MISMATCH "sha256 を計算できません: $path"
      return 1
    fi
    if [[ "$actual" != "$declared" ]]; then
      rp__fail INTEGRITY_MISMATCH "sha256 不一致: $path (manifest=$declared actual=$actual)"
      return 1
    fi
    pairs+=("$path"$'\t'"$actual")
  done < <(jq -r '.files[] | "\(.path)\t\(.sha256)\t\(.size)"' "$m" 2>/dev/null)

  # tree_sha256 = ソート済み "<path>\0<sha256>\n" 連結の sha256
  local computed
  computed="$(
    printf '%s\n' "${pairs[@]}" \
      | LC_ALL=C sort -t $'\t' -k1,1 \
      | while IFS=$'\t' read -r path actual; do printf '%s\0%s\n' "$path" "$actual"; done \
      | sha256sum | awk '{print $1}'
  )" || {
    rp__fail INTEGRITY_MISMATCH "tree_sha256 を計算できません"
    return 1
  }

  if [[ "$computed" != "$RP_TREE" ]]; then
    rp__fail INTEGRITY_MISMATCH "tree_sha256 不一致 (manifest=$RP_TREE computed=$computed)"
    return 1
  fi

  # 参考情報: manifest に載っていないファイル (起動対象の混入検知用。合否には使わない)
  local listed found extra
  listed="$(printf '%s\n' "${pairs[@]}" | cut -f1 | LC_ALL=C sort)"
  found="$(cd "$dir" && find . \( -type f -o -type l \) ! -path './manifest.json' -printf '%P\n' 2>/dev/null | LC_ALL=C sort)"
  extra="$(comm -13 <(printf '%s\n' "$listed") <(printf '%s\n' "$found") 2>/dev/null || true)"
  if [[ -n "$extra" ]]; then
    log_warn "manifest に無いファイルが release dir にあります (起動対象外): $(printf '%s' "$extra" | tr '\n' ' ')"
  fi

  return 0
}

# rp__commit_of_link <link> — リンク先 release の commit (読めなければ失敗)
rp__commit_of_link() {
  local link="$1" dir c
  dir="$(realpath -e -- "$link" 2>/dev/null)" || return 1
  [[ -f "$dir/manifest.json" ]] || return 1
  c="$(jq -r '.commit // empty' "$dir/manifest.json" 2>/dev/null || true)"
  [[ -n "$c" ]] || return 1
  printf '%s' "$c"
}

# ============================================================
# symlink / previous
# ============================================================

# rp__link_path <env> — $CLAUDEOS_HOME/releases/<env>-current
rp__link_path() { printf '%s/%s-current' "$(rp__releases_dir)" "$1"; }

# rp__previous_path <env> — $CLAUDEOS_HOME/releases/<env>-previous (相対 target を保持)
rp__previous_path() { printf '%s/%s-previous' "$(rp__releases_dir)" "$1"; }

# rp__atomic_link <link> <relative target> — tmp symlink を作って mv -T で原子的に差し替え
rp__atomic_link() {
  local link="$1" target="$2" tmp
  tmp="${link}.tmp.$$"
  if ! ln -sfn -- "$target" "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  if ! mv -Tf -- "$tmp" "$link"; then
    rm -f -- "$tmp"
    return 1
  fi
  return 0
}

# rp__read_previous <env> — previous の相対 target (無ければ 1)
rp__read_previous() {
  local p t
  p="$(rp__previous_path "$1")"
  [[ -f "$p" ]] || return 1
  t="$(cat -- "$p" 2>/dev/null)" || return 1
  [[ -n "$t" ]] || return 1
  printf '%s' "$t"
}

# rp__write_previous <env> <relative target> — 原子的に書く
rp__write_previous() {
  local p tmp
  p="$(rp__previous_path "$1")"
  tmp="${p}.tmp.$$"
  if ! printf '%s' "$2" > "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  if ! mv -Tf -- "$tmp" "$p"; then
    rm -f -- "$tmp"
    return 1
  fi
  return 0
}

# rp__restore_link <link> <old relative target> — 切替を取り消す (空なら削除)
rp__restore_link() {
  local link="$1" old="$2"
  if [[ -n "$old" ]]; then
    rp__atomic_link "$link" "$old" || return 1
    log_warn "symlink を切り戻しました: $link -> $old"
  else
    rm -f -- "$link" || return 1
    log_warn "symlink を削除しました (旧 target なし): $link"
  fi
  return 0
}

# ============================================================
# staging 検証ゲート
# ============================================================

# rp__staging_tree_matches <expected tree_sha256>
#   production 昇格の前提: staging-current が同一 artifact を指していること。
rp__staging_tree_matches() {
  local expected="$1"
  local link dir m tree
  link="$(rp__link_path staging)"

  if [[ ! -L "$link" ]]; then
    rp__fail STAGING_NOT_VERIFIED "staging-current がありません。先に staging へ昇格して検証してください ($link)"
    return 1
  fi
  if ! dir="$(realpath -e -- "$link" 2>/dev/null)"; then
    rp__fail STAGING_NOT_VERIFIED "staging-current が壊れています (dangling symlink): $link"
    return 1
  fi
  m="$dir/manifest.json"
  if [[ ! -f "$m" ]]; then
    rp__fail STAGING_NOT_VERIFIED "staging-current の manifest.json がありません: $m"
    return 1
  fi
  tree="$(jq -r '.tree_sha256 // empty' "$m" 2>/dev/null || true)"
  if [[ "$tree" != "$expected" ]]; then
    rp__fail STAGING_NOT_VERIFIED "production 昇格には同一 artifact の staging 検証が必要です (staging=${tree:-none} target=$expected)"
    return 1
  fi
  return 0
}

# ============================================================
# systemd / health
# ============================================================

# rp__restart_unit — systemctl --user restart <unit>
rp__restart_unit() {
  rp__restart_named_unit "$RP_UNIT"
}

# rp__restart_named_unit <unit> — systemctl --user restart <unit>
rp__restart_named_unit() {
  local unit="$1" bin
  bin="$(rp__systemctl_bin)"
  if ! command -v "$bin" >/dev/null 2>&1; then
    log_error "systemctl が見つかりません: $bin"
    return 1
  fi
  "$bin" --user restart "$unit"
}

# rp__health_matches <port> <jq filter> — /api/health が filter を満たせば 0
#   コンソールは {"ok":true}、companion (dashboard) は {"status":"ok"} を返す。
rp__health_matches() {
  local port="$1" filter="$2" body
  body="$("$(rp__curl_bin)" -fsS --max-time 2 "http://127.0.0.1:${port}/api/health" 2>/dev/null)" || return 1
  printf '%s' "$body" | jq -e "$filter" >/dev/null 2>&1
}

# rp__health_once <port> — /api/health が ok:true なら 0 (コンソール)
rp__health_once() {
  rp__health_matches "$1" '.ok == true'
}

# rp__wait_health_until <port> <jq filter> — 最大 RP_HEALTH_TIMEOUT 秒リトライ
rp__wait_health_until() {
  local port="$1" filter="$2" deadline
  deadline=$(( SECONDS + RP_HEALTH_TIMEOUT ))
  while (( SECONDS < deadline )); do
    if rp__health_matches "$port" "$filter"; then
      return 0
    fi
    sleep "$RP_HEALTH_INTERVAL"
  done
  rp__health_matches "$port" "$filter"
}

# rp__wait_health <port> — 最大 RP_HEALTH_TIMEOUT 秒リトライ (コンソール)
rp__wait_health() {
  rp__wait_health_until "$1" '.ok == true'
}

# rp__wait_companion_health <port> — companion は status=="ok" で判定する
rp__wait_companion_health() {
  rp__wait_health_until "$1" '.status == "ok"'
}

# ============================================================
# companion unit
# ============================================================

# rp__companions_raw — companion 設定文字列 (未設定なら env 既定)
#   RELEASE_PROMOTE_COMPANIONS は「設定された」こと自体を尊重する (空文字 = 無効)。
rp__companions_raw() {
  if [[ -n "${RELEASE_PROMOTE_COMPANIONS+x}" ]]; then
    printf '%s' "$RELEASE_PROMOTE_COMPANIONS"
    return 0
  fi
  case "$RP_ENV" in
    staging)    printf '%s' "$RP_STAGING_COMPANIONS_DEFAULT" ;;
    production) printf '%s' "$RP_PRODUCTION_COMPANIONS_DEFAULT" ;;
    *)          printf '' ;;
  esac
}

# rp__companions — "unit port" を 1 行ずつ出力する
#   書式不正の項目は警告して飛ばす (設定ミスで昇格全体を止めない)。
rp__companions() {
  local raw entry unit port
  local -a entries=()
  raw="$(rp__companions_raw)"
  [[ -z "${raw//[[:space:]]/}" ]] && return 0
  IFS=',' read -r -a entries <<< "$raw"
  for entry in "${entries[@]}"; do
    # 前後の空白を落とす
    entry="${entry#"${entry%%[![:space:]]*}"}"
    entry="${entry%"${entry##*[![:space:]]}"}"
    [[ -z "$entry" ]] && continue
    if [[ "$entry" =~ ^([^=[:space:]]+)=([0-9]+)$ ]]; then
      unit="${BASH_REMATCH[1]}"
      port="${BASH_REMATCH[2]}"
      printf '%s %s\n' "$unit" "$port"
    else
      log_warn "companion の書式が不正です (unit=port): $entry"
    fi
  done
  return 0
}

# rp__companions_plan — --dry-run 表示用の "unit=port, ..." (無ければ "(なし)")
rp__companions_plan() {
  local c_unit c_port out=""
  while read -r c_unit c_port; do
    [[ -z "$c_unit" ]] && continue
    out+="${out:+, }${c_unit}=${c_port}"
  done < <(rp__companions)
  printf '%s' "${out:-(なし)}"
}

# rp__companion_load_state <unit> — LoadState を出力 (loaded / not-found / ...)。
#   取得できない (systemctl 不在・想定外出力) 場合は 1 を返す。
#   `systemctl show` は存在しない unit でも exit 0 + "LoadState=not-found" を返す。
rp__companion_load_state() {
  local unit="$1" bin out state
  bin="$(rp__systemctl_bin)"
  command -v "$bin" >/dev/null 2>&1 || return 1
  out="$("$bin" --user show -p LoadState "$unit" 2>/dev/null || true)"
  [[ "$out" == *LoadState=* ]] || return 1
  state="${out##*LoadState=}"
  state="${state%%$'\n'*}"
  state="${state//[[:space:]]/}"
  [[ -n "$state" ]] || return 1
  printf '%s' "$state"
}

# rp__rollback_after_failure <link> <rel> — symlink を戻し、restart 済み unit を再起動
#   コンソール unit と、この昇格で restart した companion の両方を戻す。
#   --no-restart では restart しない (呼び出し側も通常この関数を使わない)。
rp__rollback_after_failure() {
  local link="$1" rel="$2" unit
  rp__restore_link "$link" "$rel" || log_error "symlink の切り戻しに失敗: $link"
  if (( ! RP_NO_RESTART )); then
    rp__restart_unit || log_error "切り戻し後の restart に失敗: $RP_UNIT"
    if (( ${#RP_COMPANIONS_RESTARTED[@]} > 0 )); then
      for unit in "${RP_COMPANIONS_RESTARTED[@]}"; do
        rp__restart_named_unit "$unit" || log_error "切り戻し後の companion restart に失敗: $unit"
      done
    fi
  fi
}

# ============================================================
# 台帳 (promotions.jsonl)
# ============================================================

# 回転の既定値: 1 MiB × 3 世代 (.1〜.3)
#   環境変数で上書き可 (RELEASE_PROMOTIONS_MAX_BYTES / RELEASE_PROMOTIONS_KEEP)。
ROTATE_MAX_BYTES_DEFAULT=$((1024 * 1024))
ROTATE_KEEP_DEFAULT=3
# 設定ミス (1e9 等) で世代シフトが暴走しないための上限
ROTATE_KEEP_MAX=100

# rp__rotate_max_bytes — 回転閾値 (バイト)。不正値は既定へ
rp__rotate_max_bytes() {
  local v="${RELEASE_PROMOTIONS_MAX_BYTES:-}"
  if [[ "$v" =~ ^[0-9]+$ ]] && (( 10#$v > 0 )); then
    printf '%s' "$(( 10#$v ))"
    return 0
  fi
  printf '%s' "$ROTATE_MAX_BYTES_DEFAULT"
}

# rp__rotate_keep — 保持世代数。不正値は既定、上限で丸める
rp__rotate_keep() {
  local v="${RELEASE_PROMOTIONS_KEEP:-}" n
  if [[ "$v" =~ ^[0-9]+$ ]]; then
    n=$(( 10#$v ))
    (( n > ROTATE_KEEP_MAX )) && n="$ROTATE_KEEP_MAX"
    printf '%s' "$n"
    return 0
  fi
  printf '%s' "$ROTATE_KEEP_DEFAULT"
}

# rp__rotate_promotions <file>
#   追記前に呼ぶ。閾値以上なら世代シフトする (行の内容は書き換えない)。
#     古い世代から順に: .N は捨て、.N-1 → .N、…、.1 → .2、無印 → .1
#   返り値: 0=回転した / 1=不要 (対象なし・閾値未満) / 2=失敗
#   失敗しても呼び出し側は追記を続行する (fail-open)。
rp__rotate_promotions() {
  local file="$1" size max_bytes keep i from to dir base p n
  max_bytes="$(rp__rotate_max_bytes)"
  keep="$(rp__rotate_keep)"

  [[ -e "$file" ]] || return 1
  size="$(stat -c %s -- "$file" 2>/dev/null)" || return 2
  [[ "$size" =~ ^[0-9]+$ ]] || return 2
  (( size < max_bytes )) && return 1

  # keep=0 は履歴を残さない (truncate)
  if (( keep == 0 )); then
    : > "$file" 2>/dev/null || return 2
    return 0
  fi

  for (( i = keep; i >= 1; i-- )); do
    if (( i == 1 )); then from="$file"; else from="$file.$((i - 1))"; fi
    to="$file.$i"
    # 最古の世代は捨てる
    if (( i == keep )); then
      rm -f -- "$to" 2>/dev/null || return 2
    fi
    if [[ -e "$from" ]]; then
      mv -f -- "$from" "$to" 2>/dev/null || return 2
    fi
  done

  # 設定変更で keep を減らしたときの余剰世代 (.keep+1 以降) を掃除する。
  #   回転時にしか走らないので通常経路のコストは増えない。
  dir="$(dirname -- "$file")"
  base="$(basename -- "$file")"
  for p in "$dir/$base".*; do
    [[ -e "$p" ]] || continue
    n="${p##*/}"
    n="${n#"$base".}"
    [[ "$n" =~ ^[0-9]+$ ]] || continue
    if (( 10#$n > keep )); then
      rm -f -- "$p" 2>/dev/null || true
    fi
  done

  return 0
}

# rp__append_promotion <result>
#   $CLAUDEOS_HOME/releases/promotions.jsonl に 1 行追記する。
#   追記前に閾値判定して回転する (回転失敗は昇格を止めない: fail-open)。
#   1 行 < 4KB の追記は Linux 上で原子的 (O_APPEND)。
rp__append_promotion() {
  local result="$1" line file rot_rc=0
  # promote-production.sh の手順 (2) は symlink の事前準備で、同じ昇格を手順 (4) が記録する。
  # 二重に PROMOTED を残さないため、手順 (2) だけが内部の環境変数で省く。ROLLED_BACK は常に記録する。
  if [[ "$result" == "PROMOTED" && "${CCSU_PROMOTE_SKIP_PROMOTED_LEDGER:-}" == "1" ]]; then
    return 0
  fi
  file="$(rp__releases_dir)/promotions.jsonl"
  mkdir -p -- "$(rp__releases_dir)" || return 1

  # 行は回転より先に組み立てる (組み立てに失敗しても台帳を回転させない)
  line="$(jq -cn \
    --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg env "$RP_ENV" \
    --arg commit "$RP_COMMIT" \
    --arg tree "$RP_TREE" \
    --arg result "$result" \
    --arg unit "$RP_UNIT" \
    --argjson port "$RP_PORT" \
    '{at:$at,env:$env,commit:$commit,tree_sha256:$tree,result:$result,unit:$unit,port:$port}' 2>/dev/null)" || return 1

  # 回転は best-effort。失敗時は stderr に 1 行だけ出し、追記はそのまま続行する。
  rp__rotate_promotions "$file" || rot_rc=$?
  if (( rot_rc == 2 )); then
    log_warn "promotions 台帳のローテーションに失敗しました (追記は続行): $file"
  fi

  printf '%s\n' "$line" >> "$file"
}

# ============================================================
# JSON / 計画表示
# ============================================================

# rp__json_success <result> — 契約どおりの成功 JSON を 1 行で出す
rp__json_success() {
  jq -cn \
    --arg env "$RP_ENV" \
    --arg commit "$RP_COMMIT" \
    --arg tree "$RP_TREE" \
    --arg prev "${RP_PREVIOUS_COMMIT:-}" \
    --arg unit "$RP_UNIT" \
    --argjson port "$RP_PORT" \
    --arg result "$1" \
    '{ok:true,env:$env,commit:$commit,tree_sha256:$tree,previous_commit:$prev,unit:$unit,port:$port,result:$result}'
}

# rp__json_error <code> <message> — 契約どおりの失敗 JSON を 1 行で出す
rp__json_error() {
  jq -cn --arg e "$1" --arg m "$2" '{ok:false,error:$e,message:$m}'
}

# rp__print_plan — --dry-run の計画表示 (何も書き換えない)
rp__print_plan() {
  local link
  link="$(rp__link_path "$RP_ENV")"
  printf 'dry-run: 何も書き換えません\n'
  printf '  env            : %s\n' "$RP_ENV"
  printf '  release dir    : %s\n' "$RP_RELEASE_DIR"
  printf '  commit         : %s\n' "$RP_COMMIT"
  printf '  tree_sha256    : %s\n' "$RP_TREE"
  printf '  unit           : %s\n' "$RP_UNIT"
  printf '  port           : %s\n' "$RP_PORT"
  printf '  current symlink: %s -> %s\n' "$link" "${RP_CURRENT_REL:-(なし)}"
  printf '  planned symlink: %s -> %s\n' "$link" "$RP_REL_TARGET"
  printf '  restart        : %s\n' "$( (( RP_NO_RESTART )) && printf 'no (--no-restart)' || printf 'yes')"
  printf '  companions     : %s\n' "$(rp__companions_plan)"
  printf '  previous 記録  : %s\n' "${RP_CURRENT_REL:-(なし)}"
}

# ============================================================
# 昇格 / ロールバック
# ============================================================

# rp__promote — staging/production 昇格の本体
#   0: 成功 (RP_RESULT=PROMOTED / --dry-run は DRY_RUN)
#   1: 失敗 (RP_ERR_CODE。自動ロールバック時は RP_RESULT=ROLLED_BACK)
rp__promote() {
  local releases link rel_target c_unit c_port c_state

  # 前回呼び出しの状態を持ち越さない (companion のロールバック対象を毎回初期化)
  RP_COMPANIONS_RESTARTED=()

  if [[ ! -d "$RP_RELEASE_DIR" ]]; then
    rp__fail RELEASE_NOT_FOUND "release dir が存在しません: $RP_RELEASE_DIR"
    return 1
  fi

  # (2) manifest 存在 + JSON 妥当性 / (3) 整合性 (不一致なら切替しない)
  rp__validate_manifest "$RP_RELEASE_DIR/manifest.json" || return 1
  rp__verify_integrity "$RP_RELEASE_DIR" || return 1

  # production は「staging で同一 artifact を検証済み」が前提 (--force は無い)
  if [[ "$RP_ENV" == "production" ]]; then
    rp__staging_tree_matches "$RP_TREE" || return 1
  fi

  releases="$(rp__releases_dir)"
  link="$(rp__link_path "$RP_ENV")"
  rel_target="$(realpath -m --relative-to="$releases" -- "$RP_RELEASE_DIR")"

  RP_CURRENT_REL=""
  if [[ -L "$link" ]]; then
    RP_CURRENT_REL="$(readlink -- "$link")"
  fi
  RP_REL_TARGET="$rel_target"
  RP_PREVIOUS_TARGET="$RP_CURRENT_REL"
  RP_PREVIOUS_COMMIT=""
  if [[ -n "$RP_CURRENT_REL" ]]; then
    RP_PREVIOUS_COMMIT="$(rp__commit_of_link "$link" 2>/dev/null || true)"
  fi

  # --dry-run: 検証結果と計画だけ出す
  if (( RP_DRY_RUN )); then
    RP_RESULT="DRY_RUN"
    rp__print_plan
    return 0
  fi

  mkdir -p -- "$releases" || {
    rp__fail HOME_NOT_WRITABLE "releases ディレクトリを作成できません: $releases"
    return 1
  }

  # 旧 target を previous に保持 (同一 target への再昇格では previous を壊さない)
  if [[ -n "$RP_CURRENT_REL" && "$RP_CURRENT_REL" != "$rel_target" ]]; then
    if ! rp__write_previous "$RP_ENV" "$RP_CURRENT_REL"; then
      rp__fail PREVIOUS_WRITE_FAILED "previous ($(rp__previous_path "$RP_ENV")) を書けません"
      return 1
    fi
  fi

  # (4) symlink を原子的に張り替え
  if ! rp__atomic_link "$link" "$rel_target"; then
    rp__fail LINK_FAILED "symlink を張り替えられません: $link -> $rel_target"
    return 1
  fi
  log_ok "symlink 張り替え: $link -> $rel_target"

  # (5) restart (--no-restart で省略)
  if (( ! RP_NO_RESTART )); then
    if ! rp__restart_unit; then
      RP_RESULT="ROLLED_BACK"
      rp__restore_link "$link" "$RP_CURRENT_REL" || log_error "symlink の切り戻しに失敗: $link"
      rp__set_error RESTART_FAILED "systemctl --user restart $RP_UNIT が失敗しました。旧 target へ切り戻しました"
      log_error "[$RP_ERR_CODE] $RP_ERR_MSG"
      rp__append_promotion "ROLLED_BACK" || log_warn "promotions.jsonl への追記に失敗"
      return 1
    fi
  fi

  # (6) /api/health が ok:true になるまで最大 RP_HEALTH_TIMEOUT 秒
  if ! rp__wait_health "$RP_PORT"; then
    # (7) 自動ロールバック: symlink を戻して再 restart
    RP_RESULT="ROLLED_BACK"
    rp__rollback_after_failure "$link" "$RP_CURRENT_REL"
    rp__set_error HEALTH_CHECK_FAILED \
      "health (http://127.0.0.1:$RP_PORT/api/health) が ok:true になりませんでした。旧 target へ切り戻しました"
    log_error "[$RP_ERR_CODE] $RP_ERR_MSG"
    rp__append_promotion "ROLLED_BACK" || log_warn "promotions.jsonl への追記に失敗"
    return 1
  fi

  # (7b) companion unit も追従させる (staging 既定: dashboard-stg / 3743)
  #      --no-restart では触らない (再起動も health 確認もしない)。
  #      not-found / 状態不明はスキップして警告のみ (昇格は止めない)。
  #      companion の restart / health 失敗はコンソールと同じくロールバック対象。
  if (( ! RP_NO_RESTART )); then
    while read -r c_unit c_port; do
      [[ -z "$c_unit" ]] && continue
      c_state="$(rp__companion_load_state "$c_unit" || true)"
      if [[ -z "$c_state" ]]; then
        log_warn "companion の状態を取得できません (スキップ): $c_unit"
        continue
      fi
      if [[ "$c_state" == "not-found" ]]; then
        log_warn "companion unit が存在しません (スキップ): $c_unit"
        continue
      fi

      if ! rp__restart_named_unit "$c_unit"; then
        RP_RESULT="ROLLED_BACK"
        rp__rollback_after_failure "$link" "$RP_CURRENT_REL"
        rp__set_error COMPANION_RESTART_FAILED \
          "systemctl --user restart $c_unit が失敗しました。旧 target へ切り戻しました"
        log_error "[$RP_ERR_CODE] $RP_ERR_MSG"
        rp__append_promotion "ROLLED_BACK" || log_warn "promotions.jsonl への追記に失敗"
        return 1
      fi
      RP_COMPANIONS_RESTARTED+=("$c_unit")
      log_info "companion restart: $c_unit"

      if ! rp__wait_companion_health "$c_port"; then
        RP_RESULT="ROLLED_BACK"
        rp__rollback_after_failure "$link" "$RP_CURRENT_REL"
        rp__set_error COMPANION_HEALTH_FAILED \
          "companion health (http://127.0.0.1:$c_port/api/health) が status=ok になりませんでした。旧 target へ切り戻しました"
        log_error "[$RP_ERR_CODE] $RP_ERR_MSG"
        rp__append_promotion "ROLLED_BACK" || log_warn "promotions.jsonl への追記に失敗"
        return 1
      fi
    done < <(rp__companions)
  fi

  # (8) 台帳へ追記
  rp__append_promotion "PROMOTED" || log_warn "promotions.jsonl への追記に失敗"
  RP_RESULT="PROMOTED"
  log_ok "promoted: env=$RP_ENV commit=$RP_COMMIT unit=$RP_UNIT port=$RP_PORT"
  if (( ${#RP_COMPANIONS_RESTARTED[@]} > 0 )); then
    log_info "companions restarted: ${RP_COMPANIONS_RESTARTED[*]}"
  fi
  return 0
}

# rp__rollback — 現在の symlink を previous target へ戻す
#   previous が無ければ NO_PREVIOUS で 1。
#   緊急経路のため、previous の内容は manifest 構造のみ検証し、全ハッシュ再計算はしない
#   (artifact が壊れていても「戻す」手段を失わないため)。
rp__rollback() {
  local releases link prev prev_dir cur_rel cur_commit

  releases="$(rp__releases_dir)"
  link="$(rp__link_path "$RP_ENV")"

  if ! prev="$(rp__read_previous "$RP_ENV")"; then
    rp__fail NO_PREVIOUS "戻り先 (previous) がありません: $(rp__previous_path "$RP_ENV")"
    return 1
  fi

  prev_dir="$(realpath -m -- "$releases/$prev")"
  if [[ ! -d "$prev_dir" ]]; then
    rp__fail ROLLBACK_TARGET_MISSING "previous target が存在しません: $prev_dir"
    return 1
  fi
  rp__validate_manifest "$prev_dir/manifest.json" || return 1

  cur_rel=""
  cur_commit=""
  if [[ -L "$link" ]]; then
    cur_rel="$(readlink -- "$link")"
    cur_commit="$(rp__commit_of_link "$link" 2>/dev/null || true)"
  fi

  RP_RELEASE_DIR="$prev_dir"
  RP_REL_TARGET="$prev"
  RP_CURRENT_REL="$cur_rel"
  RP_PREVIOUS_TARGET="$prev"
  RP_PREVIOUS_COMMIT="$cur_commit"

  if (( RP_DRY_RUN )); then
    RP_RESULT="DRY_RUN"
    rp__print_plan
    return 0
  fi

  if ! rp__atomic_link "$link" "$prev"; then
    rp__fail LINK_FAILED "symlink を張り替えられません: $link -> $prev"
    return 1
  fi
  log_ok "rollback: $link -> $prev"

  # previous を入れ替える (連続 rollback で行き来できるようにする)
  if [[ -n "$cur_rel" ]]; then
    rp__write_previous "$RP_ENV" "$cur_rel" || log_warn "previous の更新に失敗"
  else
    rm -f -- "$(rp__previous_path "$RP_ENV")" || log_warn "previous の削除に失敗"
  fi

  if (( ! RP_NO_RESTART )); then
    if ! rp__restart_unit; then
      rp__restore_link "$link" "$cur_rel" || log_error "symlink の切り戻しに失敗: $link"
      rp__fail ROLLBACK_RESTART_FAILED "systemctl --user restart $RP_UNIT が失敗しました。rollback 前の状態へ切り戻しました"
      return 1
    fi
  fi

  if ! rp__wait_health "$RP_PORT"; then
    # rollback 先も健全でない → rollback 前の状態へ戻す (壊れたまま放置しない)
    rp__restore_link "$link" "$cur_rel" || log_error "symlink の切り戻しに失敗: $link"
    if (( ! RP_NO_RESTART )); then
      rp__restart_unit || log_error "切り戻し後の restart に失敗: $RP_UNIT"
    fi
    if [[ -n "$cur_rel" ]]; then
      rp__write_previous "$RP_ENV" "$prev" || log_warn "previous の更新に失敗"
    fi
    rp__fail ROLLBACK_HEALTH_FAILED \
      "rollback 先の health (http://127.0.0.1:$RP_PORT/api/health) が ok:true になりませんでした。rollback 前の状態へ戻しました"
    return 1
  fi

  rp__append_promotion "ROLLED_BACK" || log_warn "promotions.jsonl への追記に失敗"
  RP_RESULT="ROLLED_BACK"
  log_ok "rolled back: env=$RP_ENV commit=$RP_COMMIT unit=$RP_UNIT port=$RP_PORT"
  return 0
}
