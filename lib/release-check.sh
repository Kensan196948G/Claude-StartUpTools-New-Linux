#!/usr/bin/env bash
# ============================================================
# release-check.sh — 統合プレリリースチェック (Linux native)
#
# 役割: 1 プロジェクトの「リリース準備完了」を複合ゲートで判定する。
#   git 清潔性 / README / .gitignore 衛生 / test / lint / build を束ね、
#   PASS/FAIL レポートを生成する。test/lint/build の解決は config-loader.sh の
#   config_verify_command に委譲する (解決と実行の責務分離)。
#
# 移植元: Codex-StartUpTools-New-Linux/scripts/lib/ReleaseCheck.psm1
#   の複合ゲート概念 (git state / gitignore / README / config / test / dry-run /
#   architecture)。Codex/PowerShell 固有 (Pester, Start-Codex dry-run,
#   ArchitectureCheck) は汎用 verify コマンド実行へ書き直し。
#
# 結果プロトコル: 各チェックは 1 行 "name|status|detail" を返す (status: OK|NG|SKIP)。
#   ハードフェイル = NG が 1 件以上。SKIP は不合格にしない。
# ============================================================

[[ -n "${_CCSU_RELCHK_LOADED:-}" ]] && return 0
_CCSU_RELCHK_LOADED=1

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/config-loader.sh"

# relchk__git_state <dir> <allow_dirty> — git worktree の清潔性
relchk__git_state() {
  local dir="$1" allow_dirty="${2:-0}"
  if ! git -C "$dir" rev-parse --show-toplevel >/dev/null 2>&1; then
    printf 'Git repository|NG|git リポジトリが検出できません\n'; return 0
  fi
  # git status の終了コードを検査し、失敗 (index 破損・権限等) を clean と誤報しない。
  local porcelain rc count
  porcelain="$(git -C "$dir" status --porcelain 2>/dev/null)" && rc=0 || rc=$?
  if (( rc != 0 )); then
    printf 'Git worktree|NG|git status 失敗 (rc=%s: リポジトリ破損/権限の可能性)\n' "$rc"; return 0
  fi
  count="$(printf '%s' "$porcelain" | grep -c . || true)"
  if [[ "$count" -eq 0 ]]; then
    printf 'Git worktree|OK|clean\n'
  elif [[ "$allow_dirty" == "1" ]]; then
    printf 'Git worktree|OK|dirty %s 件 (--allow-dirty で許容)\n' "$count"
  else
    printf 'Git worktree|NG|dirty %s 件 (未コミット変更)\n' "$count"
  fi
}

# relchk__readme <dir> — README.md 存在 + 非空 (+ 必須テキスト任意)
relchk__readme() {
  local dir="$1" readme="$1/README.md"
  if [[ ! -f "$readme" ]]; then
    printf 'README|NG|README.md が存在しません\n'; return 0
  fi
  if [[ ! -s "$readme" ]]; then
    printf 'README|NG|README.md が空です\n'; return 0
  fi
  # 必須テキスト (config .releaseCheck.readmeRequires[]) があれば包含確認
  local -a missing=()
  local t content
  content="$(cat "$readme")"
  while IFS= read -r t; do
    [[ -z "$t" ]] && continue
    [[ "$content" == *"$t"* ]] || missing+=("$t")
  done < <(jq -r '.releaseCheck.readmeRequires[]? // empty' "$CCSU_CONFIG_PATH" 2>/dev/null || true)
  if (( ${#missing[@]} > 0 )); then
    printf 'README|NG|必須テキスト欠落: %s\n' "$(IFS=,; printf '%s' "${missing[*]}")"
  else
    printf 'README|OK|present\n'
  fi
}

# relchk__gitignore <dir> — .gitignore 存在 + 必須パターン包含 (ランタイム/秘密の除外衛生)
relchk__gitignore() {
  local dir="$1" gi="$1/.gitignore"
  if [[ ! -f "$gi" ]]; then
    printf 'Runtime gitignore|NG|.gitignore が存在しません\n'; return 0
  fi
  local -a lines=() missing=()
  local l p
  while IFS= read -r l; do
    l="${l#"${l%%[![:space:]]*}"}"; l="${l%"${l##*[![:space:]]}"}"  # trim
    [[ -z "$l" || "$l" == \#* ]] && continue
    lines+=("$l")
  done < "$gi"
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    local found=0 x
    for x in "${lines[@]}"; do [[ "$x" == "$p" ]] && { found=1; break; }; done
    (( found )) || missing+=("$p")
  done < <(jq -r '.releaseCheck.gitignoreRequires[]? // empty' "$CCSU_CONFIG_PATH" 2>/dev/null || true)
  if (( ${#missing[@]} > 0 )); then
    printf 'Runtime gitignore|NG|除外欠落: %s\n' "$(IFS=,; printf '%s' "${missing[*]}")"
  else
    printf 'Runtime gitignore|OK|present\n'
  fi
}

# relchk__verify <dir> <kind> — test|lint|build を解決し実行 (SKIP: 未定義, dry-run)
#   実行コマンドは config_verify_command で解決。CCSU_RELCHK_DRYRUN=1 で実行せず表示のみ。
#
#   ⚠️ 信頼境界: cmd は「解決コマンド」を bash -c で実行する。値の出所は
#     (1) config.json の .verify.<kind>Command = 運用者所有の設定ファイル、
#     (2) 推定 = リポジトリ内容から選ぶ固定リテラル ("npm test" 等。ファイル内容を
#         コマンド文字列へ差し込まない)。
#   いずれも「信頼された運用者の設定/コード」であり、package.json scripts や Makefile を
#   実行するのと同じ信頼レベル (タスクランナーは本質的に任意コード実行)。"npm run lint" や
#   "a && b" のような正当なシェル構文を許すため bash -c を用いる。信頼できない第三者由来の
#   config を読ませない運用が前提 (config は release-check の実行者が管理する)。
relchk__verify() {
  local dir="$1" kind="$2" cmd label
  case "$kind" in
    test)  label="Test"  ;;
    lint)  label="Lint"  ;;
    build) label="Build" ;;
    *)     label="$kind" ;;
  esac
  cmd="$(config_verify_command "$kind" "$dir")"
  if [[ -z "$cmd" ]]; then
    printf '%s|SKIP|コマンド未定義\n' "$label"; return 0
  fi
  if [[ "${CCSU_RELCHK_DRYRUN:-0}" == "1" ]]; then
    printf '%s|SKIP|dry-run: %s\n' "$label" "$cmd"; return 0
  fi
  local out rc
  out="$( (cd "$dir" && bash -c "$cmd") 2>&1 )" && rc=0 || rc=$?
  if (( rc == 0 )); then
    printf '%s|OK|%s\n' "$label" "$cmd"
  else
    local last; last="$(printf '%s' "$out" | tail -1)"
    printf '%s|NG|%s (exit=%s) %s\n' "$label" "$cmd" "$rc" "$last"
  fi
}

# relchk__collect <dir> [--allow-dirty] [--skip-tests] [--skip-lint] [--skip-build]
#   全チェックを実行し "name|status|detail" 行を stdout へ列挙する (レポート整形は呼び出し側)。
relchk__collect() {
  local dir="$1"; shift
  local allow_dirty=0 skip_test=0 skip_lint=0 skip_build=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --allow-dirty) allow_dirty=1; shift ;;
      --skip-tests)  skip_test=1;  shift ;;
      --skip-lint)   skip_lint=1;  shift ;;
      --skip-build)  skip_build=1; shift ;;
      *) shift ;;
    esac
  done
  relchk__git_state "$dir" "$allow_dirty"
  relchk__readme "$dir"
  relchk__gitignore "$dir"
  (( skip_test ))  || relchk__verify "$dir" test
  (( skip_lint ))  || relchk__verify "$dir" lint
  (( skip_build )) || relchk__verify "$dir" build
}

# relchk__passed <results> — NG が無ければ 0 (results は collect の出力)
relchk__passed() {
  ! grep -q '|NG|' <<<"$1"
}
