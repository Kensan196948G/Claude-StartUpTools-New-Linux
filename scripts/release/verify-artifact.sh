#!/usr/bin/env bash
# ============================================================
# verify-artifact.sh — リリース成果物の独立検証 (読み取り専用)
#
# `bin/release-build.sh` が作った manifest.json を「別実装」で検証する。
# 昇格 (bin/release-promote.sh) の前段監査や、配備済み artifact の健全性確認に使う。
# 成果物・state・symlink・systemd には一切触れない。
#
# 使い方:
#   verify-artifact.sh <release-dir|commit-sha> [--json] [--strict]
#     <40hex>        $CLAUDEOS_HOME/releases/<sha> を対象にする
#     ディレクトリ   そのディレクトリを対象にする
#     --json         最終行に 1 行 JSON を出す (人間向け表示は出さない)
#     --strict       manifest に無い余剰ファイルも FAIL 扱いにする (既定は WARN)
#
# 検査項目:
#   1. manifest.json の存在 / JSON 妥当性
#   2. schema_version=1 / commit が 40hex / tree_sha256 が 64hex / files[] の型
#   3. files[] の path 安全性 (絶対パス・'..' を拒否)
#   4. 各ファイルの sha256 再計算 (シンボリックリンクはリンク文字列をハッシュ)
#   5. 各ファイルの size 一致 (シンボリックリンクは lstat のサイズ)
#   6. tree_sha256 再計算一致 — 定義: 昇順の "<path>\0<sha256>\n" 連結の sha256
#      (対象は manifest 記載ファイル。余剰ファイルは tree に含めない)
#   7. manifest にあるが実在しないファイル → FAIL
#   8. manifest に無いファイル → WARN (--strict で FAIL)
#   9. file_count と files 件数の一致
#
# exit: 0 OK (FAIL なし) / 1 NG / 2 引数エラー
#
# argv 長対策: パス列は argv ではなく NUL 区切りの標準入力で sha256sum に渡す
# (xargs -0)。ファイル数が増えても ARG_MAX に当たらない。
#
# 前提: ファイル名にタブ・改行を含まない (release-build の manifest 形式と同じ前提)。
# ============================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/common.sh
source "$SCRIPT_DIR/../../lib/common.sh"

VA_JSON=0
VA_STRICT=0
VA_TARGET=""
VA_DIR=""
VA_MANIFEST=""
VA_COMMIT=""
VA_TREE_DECLARED=""
VA_TREE_COMPUTED=""
VA_DECLARED_COUNT=0
VA_ACTUAL_COUNT=0
VA_MISSING=0
VA_MISMATCHED=0
VA_SIZE_MISMATCHED=0
VA_EXTRA=0
VA_ERROR_CODE=""
VA_ERROR_MSG=""
VA_ERRORS=()
VA_WARNINGS=()

usage() {
  cat <<'EOF'
Usage: verify-artifact.sh <release-dir|commit-sha> [--json] [--strict]

  <40hex>        $CLAUDEOS_HOME/releases/<sha> を検証
  <directory>    そのディレクトリを検証
  --json         最終行に 1 行 JSON を出力
  --strict       manifest に無い余剰ファイルも FAIL 扱い (既定は WARN)
  -h, --help

検査: manifest の妥当性 / 各 sha256 再計算 / size 一致 / tree_sha256 再計算 /
      manifest にあるが実在しないファイル (FAIL) / manifest に無いファイル (WARN)

読み取り専用です。exit: 0 OK / 1 NG / 2 引数エラー
EOF
}

# ------------------------------------------------------------
# 基本ヘルパ
# ------------------------------------------------------------

va__home() { printf '%s' "${CLAUDEOS_HOME:-$HOME/.claudeos}"; }
va__releases_dir() { printf '%s/releases' "$(va__home)"; }

va__error() {
  VA_ERROR_CODE="$1"
  VA_ERROR_MSG="$2"
  VA_ERRORS+=("$2")
  log_error "$2"
}

va__warn() {
  VA_WARNINGS+=("$1")
  log_warn "$1"
}

# va__resolve_target <40hex|dir> — VA_DIR を設定 (存在しなければ 1)
va__resolve_target() {
  local arg="$1"
  if [[ "$arg" =~ ^[0-9a-f]{40}$ ]]; then
    VA_DIR="$(va__releases_dir)/$arg"
  else
    VA_DIR="$(realpath -m -- "$arg" 2>/dev/null || printf '%s' "$arg")"
  fi
  [[ -d "$VA_DIR" ]]
}

# va__hash_regular_files — 通常ファイルの sha256 を 1 回の sha256sum で計算
#   引数: 絶対パス配列 (名前参照) / globals: VA_HASH (連想配列, rel→sha)
va__hash_regular_files() {
  local -n _abs="$1"
  (( ${#_abs[@]} > 0 )) || return 0
  local line hash path
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    hash="${line%% *}"
    path="${line#*  }"
    path="${path#"$VA_DIR"/}"
    VA_HASH["$path"]="$hash"
  done < <(printf '%s\0' "${_abs[@]}" | xargs -0 -r sha256sum -- 2>/dev/null)
}

# va__verify — 検査本体。FAIL があれば VA_ERROR_CODE を立てて 1 を返す
va__verify() {
  VA_MANIFEST="$VA_DIR/manifest.json"
  VA_ERROR_CODE=""
  VA_ERROR_MSG=""
  VA_ERRORS=()
  VA_WARNINGS=()

  # --- 1. manifest の存在 / JSON 妥当性 ---
  if [[ ! -f "$VA_MANIFEST" ]]; then
    va__error MANIFEST_MISSING "manifest.json がありません: $VA_MANIFEST"
    return 1
  fi
  if ! jq -e . "$VA_MANIFEST" >/dev/null 2>&1; then
    va__error MANIFEST_INVALID "manifest.json が JSON として不正です: $VA_MANIFEST"
    return 1
  fi

  # --- 2. 構造検証 ---
  local schema_version
  schema_version="$(jq -r '.schema_version // empty' "$VA_MANIFEST" 2>/dev/null || true)"
  if [[ "$schema_version" != "1" ]]; then
    va__error MANIFEST_INVALID "schema_version が 1 ではありません (実際: ${schema_version:-none})"
    return 1
  fi
  VA_COMMIT="$(jq -r '.commit // empty' "$VA_MANIFEST" 2>/dev/null || true)"
  if [[ ! "$VA_COMMIT" =~ ^[0-9a-f]{40}$ ]]; then
    va__error MANIFEST_INVALID "commit が 40 桁 hex ではありません: ${VA_COMMIT:-none}"
    return 1
  fi
  VA_TREE_DECLARED="$(jq -r '.tree_sha256 // empty' "$VA_MANIFEST" 2>/dev/null || true)"
  if [[ ! "$VA_TREE_DECLARED" =~ ^[0-9a-f]{64}$ ]]; then
    va__error MANIFEST_INVALID "tree_sha256 が 64 桁 hex ではありません: ${VA_TREE_DECLARED:-none}"
    return 1
  fi
  if ! jq -e '.files | type == "array"' "$VA_MANIFEST" >/dev/null 2>&1; then
    va__error MANIFEST_INVALID "files が配列ではありません"
    return 1
  fi
  if ! jq -e 'all(.files[]; ((.path|type)=="string") and ((.sha256|type)=="string") and ((.size|type)=="number"))' \
    "$VA_MANIFEST" >/dev/null 2>&1; then
    va__error MANIFEST_INVALID "files[] の要素に path/sha256/size が揃っていません"
    return 1
  fi
  if ! jq -e 'all(.files[]; .sha256 | test("^[0-9a-f]{64}$"))' "$VA_MANIFEST" >/dev/null 2>&1; then
    va__error MANIFEST_INVALID "files[].sha256 が 64 桁 hex ではありません"
    return 1
  fi
  if jq -r '.files[].path' "$VA_MANIFEST" | grep -qE '^(/|.*(^|/)\.\.(/|$))'; then
    va__error MANIFEST_INVALID "files[].path に絶対パスまたは '..' が含まれています"
    return 1
  fi

  # --- 3. 実際のファイル一覧 (1 回の find。size は lstat のサイズ) ---
  declare -gA VA_SIZE=() VA_HASH=()
  local -a actual_paths=()
  local entry rel size
  while IFS= read -r -d '' entry; do
    rel="${entry%%$'\t'*}"
    size="${entry#*$'\t'}"
    [[ "$rel" == "manifest.json" ]] && continue
    actual_paths+=("$rel")
    VA_SIZE["$rel"]="$size"
  done < <(find "$VA_DIR" \( -type f -o -type l \) -printf '%P\t%s\0' | LC_ALL=C sort -z)
  VA_ACTUAL_COUNT="${#actual_paths[@]}"

  # --- 4. manifest 記載エントリの読み込み ---
  local -a m_paths=() m_shas=() m_sizes=()
  local m_path m_sha m_size
  while IFS=$'\t' read -r m_path m_sha m_size; do
    [[ -n "$m_path" ]] || continue
    m_paths+=("$m_path")
    m_shas+=("$m_sha")
    m_sizes+=("$m_size")
  done < <(jq -r '.files[] | [.path, .sha256, (.size|tostring)] | @tsv' "$VA_MANIFEST" 2>/dev/null)
  VA_DECLARED_COUNT="${#m_paths[@]}"

  # --- 5. 通常ファイルをまとめてハッシュ化 (argv 上限を避ける) ---
  local -a regular_abs=()
  local i p
  for i in "${!m_paths[@]}"; do
    p="${m_paths[$i]}"
    if [[ -f "$VA_DIR/$p" && ! -L "$VA_DIR/$p" ]]; then
      regular_abs+=("$VA_DIR/$p")
    fi
  done
  va__hash_regular_files regular_abs

  # --- 6. 各エントリの照合 (欠落 / sha256 / size) ---
  local actual_sha declared_size
  local -a declared_pairs=()
  for i in "${!m_paths[@]}"; do
    p="${m_paths[$i]}"
    declared_size="${m_sizes[$i]}"

    if [[ ! -e "$VA_DIR/$p" && ! -L "$VA_DIR/$p" ]]; then
      VA_MISSING=$((VA_MISSING + 1))
      VA_ERRORS+=("欠落: $p (manifest にあるが実在しない)")
      continue
    fi

    if [[ -L "$VA_DIR/$p" ]]; then
      actual_sha="$(readlink -- "$VA_DIR/$p" | sha256sum | awk '{print $1}')" || actual_sha=""
    else
      actual_sha="${VA_HASH[$p]:-}"
    fi
    if [[ -z "$actual_sha" ]]; then
      VA_MISSING=$((VA_MISSING + 1))
      VA_ERRORS+=("ハッシュを計算できません: $p")
      continue
    fi

    if [[ "$actual_sha" != "${m_shas[$i]}" ]]; then
      VA_MISMATCHED=$((VA_MISMATCHED + 1))
      VA_ERRORS+=("sha256 不一致: $p (manifest=${m_shas[$i]} actual=$actual_sha)")
    fi
    if [[ "${VA_SIZE[$p]:-}" != "$declared_size" ]]; then
      VA_SIZE_MISMATCHED=$((VA_SIZE_MISMATCHED + 1))
      VA_ERRORS+=("size 不一致: $p (manifest=$declared_size actual=${VA_SIZE[$p]:-none})")
    fi

    declared_pairs+=("$p"$'\t'"$actual_sha")
  done

  # --- 7. tree_sha256 再計算 (manifest 記載分。昇順 path で定義どおり) ---
  if (( ${#declared_pairs[@]} > 0 )); then
    VA_TREE_COMPUTED="$(
      printf '%s\n' "${declared_pairs[@]}" \
        | LC_ALL=C sort -t $'\t' -k1,1 \
        | while IFS=$'\t' read -r p actual_sha; do printf '%s\0%s\n' "$p" "$actual_sha"; done \
        | sha256sum | awk '{print $1}'
    )" || VA_TREE_COMPUTED=""
  else
    VA_TREE_COMPUTED="$(printf '' | sha256sum | awk '{print $1}')"
  fi
  if [[ -z "$VA_TREE_COMPUTED" ]]; then
    VA_ERRORS+=("tree_sha256 を計算できませんでした")
    VA_TREE_COMPUTED=""
  elif [[ "$VA_TREE_COMPUTED" != "$VA_TREE_DECLARED" ]]; then
    VA_ERRORS+=("tree_sha256 不一致 (manifest=$VA_TREE_DECLARED actual=$VA_TREE_COMPUTED)")
  fi

  # --- 8. 余剰ファイル (manifest に無い) ---
  local -A declared_set=()
  for i in "${!m_paths[@]}"; do
    declared_set["${m_paths[$i]}"]=1
  done
  for i in "${!actual_paths[@]}"; do
    p="${actual_paths[$i]}"
    if [[ -z "${declared_set[$p]:-}" ]]; then
      VA_EXTRA=$((VA_EXTRA + 1))
      if (( VA_STRICT )); then
        VA_ERRORS+=("余剰: $p (manifest に無い。--strict のため FAIL)")
      else
        VA_WARNINGS+=("余剰: $p (manifest に無い)")
      fi
    fi
  done

  # --- 9. file_count の自己整合 ---
  local declared_file_count
  declared_file_count="$(jq -r '.file_count // empty' "$VA_MANIFEST" 2>/dev/null || true)"
  if [[ -n "$declared_file_count" && "$declared_file_count" != "$VA_DECLARED_COUNT" ]]; then
    VA_ERRORS+=("file_count 不一致 (manifest=$declared_file_count files[]=$VA_DECLARED_COUNT)")
  fi

  # --- 判定 ---
  if (( ${#VA_ERRORS[@]} > 0 )); then
    if [[ -z "$VA_ERROR_CODE" ]]; then
      VA_ERROR_CODE="VERIFY_FAILED"
      VA_ERROR_MSG="成果物の検証に失敗しました"
    fi
    return 1
  fi
  return 0
}

# ------------------------------------------------------------
# 出力
# ------------------------------------------------------------

va__json_line() {
  local ok="$1" i
  local -a errors_json=() warnings_json=()
  for i in "${!VA_ERRORS[@]}"; do errors_json+=("${VA_ERRORS[$i]}"); done
  for i in "${!VA_WARNINGS[@]}"; do warnings_json+=("${VA_WARNINGS[$i]}"); done

  # 配列は jq に JSON として渡す (引数長・エスケープ対策)
  local errors_arg warnings_arg ok_json strict_json
  if (( ${#errors_json[@]} > 0 )); then
    errors_arg="$(printf '%s\n' "${errors_json[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))')"
  else
    errors_arg='[]'
  fi
  if (( ${#warnings_json[@]} > 0 )); then
    warnings_arg="$(printf '%s\n' "${warnings_json[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))')"
  else
    warnings_arg='[]'
  fi
  if [[ "$ok" == "true" ]]; then ok_json='true'; else ok_json='false'; fi
  if (( VA_STRICT )); then strict_json='true'; else strict_json='false'; fi

  jq -cn \
    --argjson ok "$ok_json" \
    --arg dir "$VA_DIR" --arg commit "$VA_COMMIT" \
    --arg tree "$VA_TREE_DECLARED" --arg computed "$VA_TREE_COMPUTED" \
    --argjson files "$VA_DECLARED_COUNT" --argjson actual "$VA_ACTUAL_COUNT" \
    --argjson missing "$VA_MISSING" --argjson mismatched "$VA_MISMATCHED" \
    --argjson size_mismatched "$VA_SIZE_MISMATCHED" --argjson extra "$VA_EXTRA" \
    --argjson strict "$strict_json" \
    --argjson errors "$errors_arg" --argjson warnings "$warnings_arg" \
    '{ok:$ok, dir:$dir, commit:$commit, tree_sha256:$tree,
      tree_sha256_computed:$computed, files:$files, actual:$actual,
      missing:$missing, mismatched:$mismatched, size_mismatched:$size_mismatched,
      extra:$extra, strict:$strict, warnings:$warnings, errors:$errors}'
}

va__render_human() {
  local ok="$1" i
  printf '%sartifact verify%s  %s\n' "$C_CYAN" "$C_RESET" "$VA_DIR"
  printf '  manifest : %s (schema_version=1, commit=%s)\n' "$VA_MANIFEST" "${VA_COMMIT:-?}"
  printf '  tree     : %s\n' "${VA_TREE_DECLARED:-?}"
  printf '  files    : manifest=%s / actual=%s\n' "$VA_DECLARED_COUNT" "$VA_ACTUAL_COUNT"

  if (( VA_MISSING == 0 && VA_MISMATCHED == 0 && VA_SIZE_MISMATCHED == 0 )); then
    printf '  sha256   : %sOK%s (全 %s 件)\n' "$C_GREEN" "$C_RESET" "$VA_DECLARED_COUNT"
  else
    printf '  sha256   : %sNG%s (欠落=%s / sha不一致=%s / size不一致=%s)\n' \
      "$C_RED" "$C_RESET" "$VA_MISSING" "$VA_MISMATCHED" "$VA_SIZE_MISMATCHED"
  fi

  if [[ -n "$VA_TREE_COMPUTED" && "$VA_TREE_COMPUTED" == "$VA_TREE_DECLARED" ]]; then
    printf '  tree照合 : %sOK%s\n' "$C_GREEN" "$C_RESET"
  else
    printf '  tree照合 : %sNG%s (actual=%s)\n' "$C_RED" "$C_RESET" "${VA_TREE_COMPUTED:-計算失敗}"
  fi

  if (( VA_EXTRA > 0 )); then
    if (( VA_STRICT )); then
      printf '  余剰     : %s%s 件 (--strict のため FAIL)%s\n' "$C_RED" "$VA_EXTRA" "$C_RESET"
    else
      printf '  余剰     : %s%s 件 (WARN: manifest に無い)%s\n' "$C_YELLOW" "$VA_EXTRA" "$C_RESET"
    fi
  else
    printf '  余剰     : 0 件\n'
  fi

  if (( ${#VA_WARNINGS[@]} > 0 )); then
    printf '\n%sWARN%s\n' "$C_YELLOW" "$C_RESET"
    for i in "${!VA_WARNINGS[@]}"; do
      printf '  - %s\n' "${VA_WARNINGS[$i]}"
    done
  fi
  if (( ${#VA_ERRORS[@]} > 0 )); then
    printf '\n%sFAIL%s\n' "$C_RED" "$C_RESET"
    for i in "${!VA_ERRORS[@]}"; do
      printf '  - %s\n' "${VA_ERRORS[$i]}"
    done
  fi

  if [[ "$ok" == "true" ]]; then
    printf '\n%s結果: OK%s (%s)\n' "$C_GREEN" "$C_RESET" "$VA_DIR"
  else
    printf '\n%s結果: NG%s (%s 件の失敗)\n' "$C_RED" "$C_RESET" "${#VA_ERRORS[@]}"
  fi
}

# ------------------------------------------------------------
# main
# ------------------------------------------------------------

main() {
  local wants_json=0 a
  for a in "$@"; do
    if [[ "$a" == "--json" ]]; then
      wants_json=1
    fi
  done

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json) VA_JSON=1; shift ;;
      --strict) VA_STRICT=1; shift ;;
      -h|--help) usage; return 0 ;;
      --*)
        log_error "不明な引数: $1"
        if (( wants_json )); then
          jq -cn --arg m "不明な引数: $1" '{ok:false,error:"ARG_INVALID",message:$m}'
        fi
        return 2 ;;
      *)
        if [[ -n "$VA_TARGET" ]]; then
          log_error "対象は 1 つだけ指定してください: $1"
          if (( wants_json )); then
            jq -cn --arg m "対象は 1 つだけ指定してください: $1" '{ok:false,error:"ARG_INVALID",message:$m}'
          fi
          return 2
        fi
        VA_TARGET="$1"; shift ;;
    esac
  done

  if [[ -z "$VA_TARGET" ]]; then
    log_error "対象 (release dir または 40hex commit) を指定してください"
    if (( wants_json )); then
      jq -cn --arg m "対象 (release dir または 40hex commit) を指定してください" \
        '{ok:false,error:"ARG_INVALID",message:$m}'
    fi
    return 2
  fi

  require_cmd jq
  require_cmd sha256sum
  require_cmd xargs

  if ! va__resolve_target "$VA_TARGET"; then
    VA_ERROR_CODE="ARTIFACT_NOT_FOUND"
    VA_ERROR_MSG="release dir が見つかりません: $VA_DIR"
    log_error "$VA_ERROR_MSG"
    if (( VA_JSON )); then
      jq -cn --arg m "$VA_ERROR_MSG" '{ok:false,error:"ARTIFACT_NOT_FOUND",message:$m}'
    fi
    return 1
  fi

  local rc=0
  va__verify || rc=$?

  local ok="true"
  if (( rc != 0 )); then ok="false"; fi

  if (( VA_JSON )); then
    va__json_line "$ok"
  else
    va__render_human "$ok"
  fi

  if (( rc != 0 )); then
    return 1
  fi
  return 0
}

rc=0
main "$@" || rc=$?
exit "$rc"
