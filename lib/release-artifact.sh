#!/usr/bin/env bash
# ============================================================
# release-artifact.sh — リリース成果物ビルドライブラリ (Linux native)
#
# 目的: 「本番が作業ツリー直実行」になっている状態 (artifact 同一性なし) を
#   解消する第一歩。commit 単位の不変スナップショットとマニフェストを作る。
#   中身は `git archive <sha>` で取り出した tracked files のみで、作業ツリーの
#   未コミット変更・untracked ファイル・.git は含まない。
#
# 配置: $CLAUDEOS_HOME/releases/<40桁commit-sha>/
#       (CLAUDEOS_HOME は環境変数で上書き可。既定 ~/.claudeos)
#     <release>/                 : tracked files の展開結果
#     <release>/manifest.json    : 成果物の同一性を表すマニフェスト
#
# manifest.json (schema_version=1):
#   {"schema_version":1,"commit":"<40hex>","short_commit":"<7hex>",
#    "ref":"<指定ref>","built_at":"<ISO8601 UTC>","file_count":N,
#    "tree_sha256":"<sha256>","files":[{"path":"...","sha256":"...","size":N}]}
#   tree_sha256 = ソート済み `"<path>\0<sha256>\n"` 連結の sha256
#   files は path 昇順 (LC_ALL=C のバイト順)。
#   manifest.json 自身は files に含めない (自己ハッシュは定義できないため)。
#
# 実装上の注意:
#   - 大規模ツリー (tracked 1000+) でも動くこと。ファイル一覧はシェル変数や
#     argv に載せず、一時ファイル + `jq --rawfile` で渡す。argv には 1 引数
#     128KB (MAX_ARG_STRLEN) の上限があり、--argjson で一覧を渡すと E2BIG
#     で manifest 生成が失敗する。
#   - 通常ファイルのハッシュは 1 回の `sha256sum` 呼び出しでまとめる
#     (ファイル数分の fork を避ける)。
#   - path に改行/タブ/バックスラッシュを含むツリーは非対応。その場合は
#     ハッシュ照合に失敗し HASH_ERROR で停止する (黙って誤った manifest を
#     作らない)。
#
# 原子的公開: <out> の親に一時ディレクトリを作り (同一ファイルシステム)、
#   展開 → manifest 作成 → rename で公開する。途中状態を外から見せない。
#   <out> に既存の非空ディレクトリがある場合は --force 相当のときだけ、
#   旧ディレクトリを退避 → rename → 退避削除の順で置換する。
#
# 公開 API:
#   relart__build <ref> <out> <force> <dry_run>
#     0=成功 / 1=失敗。結果は RELART_LAST_*(commit/short/dir/tree_sha256/file_count)、
#     失敗理由は RELART_ERR_CODE / RELART_ERR_MESSAGE に入る。
#     (<out> が空なら既定 $CLAUDEOS_HOME/releases/<sha>)
#   補助: relart__releases_dir / relart__default_out / relart__resolve_commit
#         relart__entries / relart__tree_sha256 / relart__write_manifest
#
# 注: このファイルは source されるため set -euo pipefail を設定しない。
#     git archive の失敗を握り潰さないよう、パイプラインは subshell 内で
#     pipefail を有効化して評価する。
#
# テスト用 env 上書き:
#   CCSU_ROOT       : git リポジトリのルート (既定: lib/ の 1 階層上)
#   CLAUDEOS_HOME   : releases/ の親 (既定 ~/.claudeos)
#   RELART_BUILT_AT : built_at を固定する (テストの決定化用)
# ============================================================

[[ -n "${_CCSU_RELEASE_ARTIFACT_LOADED:-}" ]] && return 0
_CCSU_RELEASE_ARTIFACT_LOADED=1

# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

RELART_SCHEMA_VERSION=1
RELART_MANIFEST_NAME='manifest.json'

# 直近の実行結果 (bin/release-build.sh が JSON を組み立てる際に読む)。
# export しているのはクロスファイル API であることを明示するため
# (関数内の再代入は export 状態を引き継ぐ)。
export RELART_ERR_CODE=''
export RELART_ERR_MESSAGE=''
export RELART_LAST_COMMIT=''
export RELART_LAST_SHORT_COMMIT=''
export RELART_LAST_DIR=''
export RELART_LAST_TREE_SHA256=''
export RELART_LAST_FILE_COUNT='0'
export RELART_LAST_DRY_RUN='0'

# ------------------------------------------------------------
# relart__fail <CODE> <message>
#   失敗理由を記録してログし 1 を返す (lib 内では exit しない)
# ------------------------------------------------------------
relart__fail() {
  RELART_ERR_CODE="$1"
  RELART_ERR_MESSAGE="$2"
  log_error "$2"
  return 1
}

# ------------------------------------------------------------
# relart__discard <tmp-dir> [entries-file] — 途中生成物の後始末
# ------------------------------------------------------------
relart__discard() {
  local tmp="${1:-}" ef="${2:-}"
  [[ -n "$tmp" ]] && rm -rf -- "$tmp"
  [[ -n "$ef" ]] && rm -f -- "$ef"
  return 0
}

# ------------------------------------------------------------
# パス解決
# ------------------------------------------------------------
# relart__home — ClaudeOS ホーム (呼び出し時点の env を見る)
relart__home() {
  printf '%s' "${CLAUDEOS_HOME:-${CCSU_HOME:-$HOME/.claudeos}}"
}

# relart__releases_dir — リリース親ディレクトリ
relart__releases_dir() {
  printf '%s/releases' "$(relart__home)"
}

# relart__default_out <sha> — 既定の出力先
relart__default_out() {
  printf '%s/%s' "$(relart__releases_dir)" "$1"
}

# relart__built_at — ISO8601 UTC (テストは RELART_BUILT_AT で固定可)
relart__built_at() {
  printf '%s' "${RELART_BUILT_AT:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
}

# relart__abspath <path> — 相対パスを $PWD 基準の絶対パスへ
#   シンボリックリンクは解決しない (入力したパスをそのまま結果に使う)
relart__abspath() {
  local p="${1:-}"
  if [[ "$p" != /* ]]; then
    p="$PWD/$p"
  fi
  printf '%s' "$p"
}

# ------------------------------------------------------------
# relart__resolve_commit <ref> — ref を 40 桁 commit SHA へ解決
#   解決できない / commit でない場合は 1 を返し stdout は空
# ------------------------------------------------------------
relart__resolve_commit() {
  local ref="${1:-}" sha
  [[ -n "$ref" ]] || return 1
  has_cmd git || return 1
  sha="$(git -C "$CCSU_ROOT" rev-parse --verify --quiet "${ref}^{commit}" 2>/dev/null)" || return 1
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || return 1
  printf '%s' "$sha"
}

# ------------------------------------------------------------
# relart__entries <dir> — 展開済みディレクトリの内容を列挙
#   出力: "path<TAB>sha256<TAB>size" を path 昇順 (LC_ALL=C) で 1 行ずつ
#   対象: 通常ファイル + シンボリックリンク (リンクは参照先文字列をハッシュ)
#   除外: manifest.json (成果物自身のマニフェスト)
# ------------------------------------------------------------
relart__entries() {
  local dir="${1:-}" base rel h hash
  [[ -d "$dir" ]] || return 1
  base="${dir%/}"

  # 1 回の find で path 昇順 + size を取る (-printf は GNU 拡張)
  local -a paths=()
  local -A sizes=()
  while IFS= read -r -d '' h; do
    rel="${h%%$'\t'*}"
    rel="${rel#"$base"/}"
    [[ "$rel" == "$RELART_MANIFEST_NAME" ]] && continue
    paths+=("$rel")
    sizes["$rel"]="${h#*$'\t'}"
  done < <(find "$base" \( -type f -o -type l \) -printf '%p\t%s\0' | LC_ALL=C sort -z)

  # 通常ファイルは 1 回の sha256sum でまとめて計算する
  local -a regular=()
  for rel in "${paths[@]}"; do
    [[ -L "$base/$rel" ]] || regular+=("$rel")
  done
  local -A hashes=()
  if (( ${#regular[@]} > 0 )); then
    local -a regular_abs=()
    for rel in "${regular[@]}"; do
      regular_abs+=("$base/$rel")
    done
    while IFS= read -r h; do
      [[ -n "$h" ]] || continue
      hash="${h%% *}"
      rel="${h#*  }"
      rel="${rel#"$base"/}"
      hashes["$rel"]="$hash"
    done < <(printf '%s\0' "${regular_abs[@]}" | xargs -0 -r sha256sum -- 2>/dev/null)
  fi

  # シンボリックリンクはリンク文字列 (git blob の中身) をハッシュする
  for rel in "${paths[@]}"; do
    if [[ -L "$base/$rel" ]]; then
      hash="$(readlink -- "$base/$rel" | sha256sum | awk '{print $1}')" || return 1
      hashes["$rel"]="$hash"
    fi
  done

  for rel in "${paths[@]}"; do
    hash="${hashes[$rel]:-}"
    if [[ -z "$hash" ]]; then
      log_error "ハッシュを計算できませんでした: $rel"
      return 1
    fi
    printf '%s\t%s\t%s\n' "$rel" "$hash" "${sizes[$rel]}"
  done
}

# ------------------------------------------------------------
# relart__tree_sha256 — stdin の entries から tree_sha256 を計算
#   定義: ソート済み `"<path>\0<sha256>\n"` 連結の sha256
#   入力は relart__entries の出力 (path 昇順) をそのまま渡す
#   空入力は空文字列の sha256 (e3b0c442...) になる
# ------------------------------------------------------------
relart__tree_sha256() {
  local path hash size
  while IFS=$'\t' read -r path hash size; do
    [[ -n "$path" || -n "$hash" ]] || continue
    printf '%s\0%s\n' "$path" "$hash"
  done | sha256sum | awk '{print $1}'
}

# ------------------------------------------------------------
# relart__write_manifest <commit> <ref> <built_at> <entries_file> <tree>
#   manifest.json の中身を stdout へ書き出す (書き込みは呼び出し側)
#   一覧は argv ではなく --rawfile で渡す (argv 長上限の回避)。
#   file_count は files 配列の長さから決める (単一の真実)。
# ------------------------------------------------------------
relart__write_manifest() {
  local commit="$1" ref="$2" built_at="$3" entries_file="$4" tree="$5"
  jq -n \
    --argjson schema_version "$RELART_SCHEMA_VERSION" \
    --arg commit "$commit" \
    --arg short_commit "${commit:0:7}" \
    --arg ref "$ref" \
    --arg built_at "$built_at" \
    --arg tree_sha256 "$tree" \
    --rawfile entries "$entries_file" \
    '([ $entries | split("\n")[] | select(length > 0) | split("\t")
        | { path: .[0], sha256: .[1], size: (.[2] | tonumber) } ]) as $files
     | { schema_version: $schema_version, commit: $commit,
         short_commit: $short_commit, ref: $ref, built_at: $built_at,
         file_count: ($files | length), tree_sha256: $tree_sha256,
         files: $files }'
}

# ------------------------------------------------------------
# relart__dir_nonempty <dir> — ディレクトリが存在し中身を持つとき 0
# ------------------------------------------------------------
relart__dir_nonempty() {
  local dir="${1:-}"
  [[ -d "$dir" ]] || return 1
  [[ -n "$(find "$dir" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]
}

# ------------------------------------------------------------
# relart__archive_count <commit> — git archive に含まれるファイル数
#   (ディレクトリエントリを除く。--dry-run の計画表示に使う)
# ------------------------------------------------------------
relart__archive_count() {
  local commit="$1" list
  list="$( ( set -o pipefail; git -C "$CCSU_ROOT" archive --format=tar "$commit" | tar -tf - ) )" || return 1
  if [[ -z "$list" ]]; then
    printf '0'
    return 0
  fi
  printf '%s\n' "$list" | grep -vc '/$' || true
}

# ------------------------------------------------------------
# relart__build <ref> <out> <force> <dry_run>
#   ref を解決 → 事前条件確認 → (dry_run なら計画のみ) →
#   一時ディレクトリへ展開 → manifest 作成 → 原子的 rename
# ------------------------------------------------------------
relart__build() {
  local ref="${1:-HEAD}" out="${2:-}" force="${3:-0}" dry="${4:-0}"
  local commit short dir parent tmp backup entries_file count tree built

  RELART_ERR_CODE=''
  RELART_ERR_MESSAGE=''
  RELART_LAST_COMMIT=''
  RELART_LAST_SHORT_COMMIT=''
  RELART_LAST_DIR=''
  RELART_LAST_TREE_SHA256=''
  RELART_LAST_FILE_COUNT='0'
  RELART_LAST_DRY_RUN="$dry"

  commit="$(relart__resolve_commit "$ref")" \
    || { relart__fail INVALID_REF "ref を commit に解決できません: ${ref}"; return 1; }
  short="${commit:0:7}"

  if [[ -n "$out" ]]; then
    dir="$out"
  else
    dir="$(relart__default_out "$commit")"
  fi
  dir="${dir%/}"
  [[ -n "$dir" ]] || { relart__fail INVALID_OUT "出力先が空です"; return 1; }
  dir="$(relart__abspath "$dir")"

  if [[ -e "$dir" && ! -d "$dir" ]]; then
    relart__fail OUTPUT_NOT_DIRECTORY "出力先がディレクトリではありません: $dir"
    return 1
  fi
  # dry-run でも同じ事前条件で判定する (実行したら失敗する計画を成功扱いしない)
  if relart__dir_nonempty "$dir" && [[ "$force" != "1" ]]; then
    relart__fail OUTPUT_EXISTS "出力先が既に存在し空ではありません: $dir (置換するには --force)"
    return 1
  fi

  built="$(relart__built_at)"

  # --- 計画のみ (一切書き込まない) ---
  if [[ "$dry" == "1" ]]; then
    count="$(relart__archive_count "$commit")" \
      || { relart__fail GIT_ARCHIVE "git archive の列挙に失敗しました: $commit"; return 1; }
    RELART_LAST_COMMIT="$commit"
    RELART_LAST_SHORT_COMMIT="$short"
    RELART_LAST_DIR="$dir"
    RELART_LAST_FILE_COUNT="$count"
    RELART_LAST_TREE_SHA256=''
    log_info "🧪 dry-run: 書き込みません (計画のみ)"
    log_info "  commit      : $commit ($short)"
    log_info "  ref         : $ref"
    log_info "  output      : $dir"
    log_info "  files       : $count (計画)"
    log_info "  tree_sha256 : 実行時に計算"
    return 0
  fi

  parent="$(dirname -- "$dir")"
  mkdir -p -- "$parent" \
    || { relart__fail IO_ERROR "出力先の親ディレクトリを作成できません: $parent"; return 1; }
  # 同一ファイルシステム内に作る (rename を原子的にするため)
  tmp="$(mktemp -d "${parent%/}/.release-build.XXXXXX")" \
    || { relart__fail IO_ERROR "一時ディレクトリを作成できません: $parent"; return 1; }

  if ! ( set -o pipefail; git -C "$CCSU_ROOT" archive --format=tar "$commit" | tar -x -C "$tmp" ); then
    relart__discard "$tmp"
    relart__fail GIT_ARCHIVE "git archive の展開に失敗しました: $commit"
    return 1
  fi

  # 一覧は一時ファイル経由 (argv/シェル変数に大量データを載せない)
  entries_file="$(mktemp "${TMPDIR:-/tmp}/release-build-entries.XXXXXX")" \
    || { relart__discard "$tmp"; relart__fail IO_ERROR "一時ファイルを作成できません"; return 1; }
  if ! relart__entries "$tmp" > "$entries_file"; then
    relart__discard "$tmp" "$entries_file"
    relart__fail HASH_ERROR "展開結果のハッシュ計算に失敗しました"
    return 1
  fi

  count="$(grep -c . "$entries_file" || true)"
  [[ -n "$count" ]] || count=0
  tree="$(relart__tree_sha256 < "$entries_file")"
  if [[ -z "$tree" ]]; then
    relart__discard "$tmp" "$entries_file"
    relart__fail HASH_ERROR "tree_sha256 を計算できませんでした"
    return 1
  fi

  if ! relart__write_manifest "$commit" "$ref" "$built" "$entries_file" "$tree" \
      > "$tmp/$RELART_MANIFEST_NAME"; then
    relart__discard "$tmp" "$entries_file"
    relart__fail MANIFEST_ERROR "manifest.json の生成に失敗しました"
    return 1
  fi
  rm -f -- "$entries_file"

  # manifest を唯一の真実として file_count を読み戻す
  count="$(jq -r '.file_count' "$tmp/$RELART_MANIFEST_NAME" 2>/dev/null || true)"
  if [[ ! "$count" =~ ^[0-9]+$ ]]; then
    relart__discard "$tmp"
    relart__fail MANIFEST_ERROR "manifest.json の検証に失敗しました"
    return 1
  fi

  # --- 原子的公開 (同一 fs 内 rename) ---
  if [[ -e "$dir" ]]; then
    backup="${parent%/}/.release-backup.$$"
    rm -rf -- "$backup"
    if ! mv -- "$dir" "$backup"; then
      relart__discard "$tmp"
      relart__fail SWAP_ERROR "既存の出力先を退避できません: $dir"
      return 1
    fi
    if ! mv -- "$tmp" "$dir"; then
      mv -- "$backup" "$dir" 2>/dev/null || true
      relart__discard "$tmp"
      relart__fail SWAP_ERROR "新しい成果物を公開できません: $dir"
      return 1
    fi
    rm -rf -- "$backup"
  else
    if ! mv -- "$tmp" "$dir"; then
      relart__discard "$tmp"
      relart__fail SWAP_ERROR "成果物を公開できません: $dir"
      return 1
    fi
  fi

  RELART_LAST_COMMIT="$commit"
  RELART_LAST_SHORT_COMMIT="$short"
  RELART_LAST_DIR="$dir"
  RELART_LAST_TREE_SHA256="$tree"
  RELART_LAST_FILE_COUNT="$count"

  log_ok "release を作成しました: $dir"
  log_info "  commit      : $commit"
  log_info "  ref         : $ref"
  log_info "  files       : $count"
  log_info "  tree_sha256 : $tree"
  return 0
}
