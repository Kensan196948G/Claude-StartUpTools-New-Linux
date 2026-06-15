#!/usr/bin/env bash
# ============================================================
# launch-parallel-cron.sh — 複数ロール (CTO + QA 等) を claude -p headless で並列起動
#
# 使い方:
#   launch-parallel-cron.sh <ProjectName> [--roles cto,qa] [--stagger N]
#                           [--duration M] [--dry-run]
#   例: launch-parallel-cron.sh MyProject                 # cto,qa を 60s 間隔で並走
#       launch-parallel-cron.sh MyProject --roles cto      # 単一ロール
#       launch-parallel-cron.sh MyProject --stagger 0      # 同時起動 (間隔なし)
#       launch-parallel-cron.sh MyProject --dry-run        # 計画のみ (実起動なし)
#
# 設計 (PR-F / プラン欠落5):
#   - ハードコード `sleep 300` を --stagger N (既定60s) へ。
#   - roles 正本 Claude/templates/claudeos/roles/*.md を runtime へ冪等・非破壊配布
#     (cron-launcher の hooks auto-repair と同型の canonical コピーを関数化)。
#   - 各ロールを `claude -p "$(cat role)" --output-format stream-json
#     --permission-mode dontAsk` で並走させ、出力は stream-json-tail.sh 共用 (PR-D)。
#   - 純粋関数 + source ガードで bats から実 claude 非起動のまま検証可能。
#
# 安全: SSH/リモート配布なし・ローカル限定。二重起動は PID ロックで防止。
#       --dangerously-skip-permissions は付与しない (headless では dontAsk で十分)。
# ============================================================

set -euo pipefail

LP_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 既定パス (env で上書き可: テスト/カスタム配置用)
: "${LP_ROLES_SRC:=$LP_SCRIPT_DIR/../../Claude/templates/claudeos/roles}"
: "${LP_ROLES_DIR:=$HOME/.claudeos/roles}"
: "${LP_LOGS_DIR:=$HOME/.claudeos/logs}"
: "${LP_RUNTIME_DIR:=$HOME/.claudeos}"
: "${LP_PROJECTS_BASE:=$HOME/Projects}"
: "${LP_SJT:=$LP_SCRIPT_DIR/../../libexec/stream-json-tail.sh}"
: "${LP_STAGGER_DEFAULT:=60}"
: "${LP_DURATION_MIN:=300}"

# 二重起動ロックのパス (lp__main で設定)。EXIT トラップから参照するためグローバル。
LP_LOCK_FILE=""

# 色 (灰色は使わない方針: 青/緑/黄/マゼンタ/赤/白)。非 tty (cron ログ) は無色。
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_BLUE=$'\033[34m'; C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'; C_MAGENTA=$'\033[35m'; C_RED=$'\033[31m'
else
  C_RESET=''; C_BLUE=''; C_GREEN=''; C_YELLOW=''; C_MAGENTA=''; C_RED=''
fi

# ------------------------------------------------------------
# lp__role_to_file <role> — 短縮ロール名 → roles ファイル名
#   既知エイリアスはフルネームへ、未知はそのまま <role>.md (将来ロール拡張用)。
# ------------------------------------------------------------
lp__role_to_file() {
  case "$1" in
    cto) printf 'cto-build.md\n' ;;
    qa)  printf 'qa-monitor.md\n' ;;
    *)   printf '%s.md\n' "$1" ;;
  esac
}

# ------------------------------------------------------------
# lp__parse_roles <csv> — "cto, qa" → 1 行 1 ロール (空要素/前後空白除去)
# ------------------------------------------------------------
lp__parse_roles() {
  local csv="$1" r
  local -a parts=()
  IFS=',' read -ra parts <<< "$csv"
  for r in "${parts[@]}"; do
    r="${r#"${r%%[![:space:]]*}"}"   # 先頭空白除去
    r="${r%"${r##*[![:space:]]}"}"   # 末尾空白除去
    [[ -n "$r" ]] && printf '%s\n' "$r"
  done
}

# ------------------------------------------------------------
# lp__distribute_roles <src_dir> <dest_dir> — canonical roles を配布 (冪等・非破壊)
#   cron-launcher の hooks auto-repair と同型: dest に無いか古い *.md のみコピー。
#   ユーザーが dest 側で編集したロールは保持する (src が新しい時のみ上書き)。
# ------------------------------------------------------------
lp__distribute_roles() {
  local src="$1" dest="$2" f base
  [[ -d "$src" ]] || { printf 'roles テンプレート不在: %s\n' "$src" >&2; return 1; }
  mkdir -p "$dest"
  for f in "$src"/*.md; do
    [[ -f "$f" ]] || continue
    base="$(basename "$f")"
    if [[ ! -f "$dest/$base" ]] || [[ "$f" -nt "$dest/$base" ]]; then
      cp -f "$f" "$dest/$base"
    fi
  done
}

# ------------------------------------------------------------
# lp__resolve_role_file <roles_dir> <role> — 配布済みロールファイルの絶対パス
#   不在なら stderr へ明示エラー + return 1 (起動前に検出させる)。
# ------------------------------------------------------------
lp__resolve_role_file() {
  local dir="$1" role="$2" file
  file="$dir/$(lp__role_to_file "$role")"
  [[ -f "$file" ]] || { printf 'ロールファイル不在: %s (role=%s)\n' "$file" "$role" >&2; return 1; }
  printf '%s\n' "$file"
}

# ------------------------------------------------------------
# lp__launch_role <project> <role> <role_file> <log_file> <duration_sec>
#   1 ロールを headless 起動 (背景)。argv は PR-D cron-launcher と同型:
#     timeout --foreground <sec>s claude -p "$(cat role)"
#       --output-format stream-json --permission-mode dontAsk
#   出力は stream-json-tail.sh 経由で可読ログ + session_id/cost 捕捉 (共用)。
#   起動した背景プロセスの PID を stdout へ。
# ------------------------------------------------------------
lp__launch_role() {
  local project="$1" role="$2" role_file="$3" log="$4" dur_sec="$5"
  local prompt sid_file cost_file proj_dir
  prompt="$(cat "$role_file")"
  proj_dir="$LP_PROJECTS_BASE/$project"
  sid_file="$LP_RUNTIME_DIR/sessions/${project}-${role}.claude-session"
  cost_file="$LP_RUNTIME_DIR/sessions/${project}-${role}.cost"
  mkdir -p "$LP_RUNTIME_DIR/sessions"

  if [[ -f "$LP_SJT" ]]; then
    (
      cd "$proj_dir" || exit 1
      export SJT_SESSION_ID_FILE="$sid_file" SJT_COST_FILE="$cost_file"
      timeout --foreground "${dur_sec}s" claude -p "$prompt" \
        --output-format stream-json --permission-mode dontAsk 2>&1 \
        | bash "$LP_SJT"
    ) > "$log" 2>&1 &
  else
    (
      cd "$proj_dir" || exit 1
      timeout --foreground "${dur_sec}s" claude -p "$prompt" \
        --output-format stream-json --permission-mode dontAsk
    ) > "$log" 2>&1 &
  fi
  printf '%s\n' "$!"
}

# ------------------------------------------------------------
# lp__acquire_lock <lock_file> — 二重起動防止 (PID + kill -0)。取得で 0、占有中は 1。
# ------------------------------------------------------------
lp__acquire_lock() {
  local lock="$1" prev
  if [[ -f "$lock" ]]; then
    prev="$(cat "$lock" 2>/dev/null || echo '')"
    if [[ -n "$prev" ]] && kill -0 "$prev" 2>/dev/null; then
      return 1
    fi
  fi
  echo "$$" > "$lock"
  return 0
}

# ------------------------------------------------------------
# lp__main — 引数解釈 → ロール配布/解決 → 並列起動 → 完了待機
# ------------------------------------------------------------
lp__main() {
  local project="" roles_csv="cto,qa" stagger="$LP_STAGGER_DEFAULT"
  local duration_min="$LP_DURATION_MIN" dry_run=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --roles)    roles_csv="$2"; shift 2 ;;
      --stagger)  stagger="$2"; shift 2 ;;
      --duration) duration_min="$2"; shift 2 ;;
      --dry-run)  dry_run=1; shift ;;
      --*)        printf '%sERROR: 不明な引数: %s%s\n' "$C_RED" "$1" "$C_RESET" >&2; return 1 ;;
      *)
        if [[ -z "$project" ]]; then project="$1"; shift
        else printf '%sERROR: 余分な引数: %s%s\n' "$C_RED" "$1" "$C_RESET" >&2; return 1; fi ;;
    esac
  done

  if [[ -z "$project" ]]; then
    printf 'Usage: %s <ProjectName> [--roles cto,qa] [--stagger N] [--duration M] [--dry-run]\n' \
      "$(basename "$0")" >&2
    return 1
  fi
  [[ "$stagger" =~ ^[0-9]+$ ]]      || { printf '%sERROR: --stagger は非負整数: %s%s\n'  "$C_RED" "$stagger" "$C_RESET" >&2; return 1; }
  [[ "$duration_min" =~ ^[0-9]+$ ]] || { printf '%sERROR: --duration は非負整数: %s%s\n' "$C_RED" "$duration_min" "$C_RESET" >&2; return 1; }

  # ロール配布 (canonical → runtime, 冪等・非破壊)
  lp__distribute_roles "$LP_ROLES_SRC" "$LP_ROLES_DIR" || return 1

  # ロール解決 (1 つでも不在なら起動前に明示エラー)
  local -a roles=() files=()
  local r f
  while IFS= read -r r; do [[ -n "$r" ]] && roles+=("$r"); done < <(lp__parse_roles "$roles_csv")
  (( ${#roles[@]} > 0 )) || { printf '%sERROR: --roles が空です%s\n' "$C_RED" "$C_RESET" >&2; return 1; }
  for r in "${roles[@]}"; do
    f="$(lp__resolve_role_file "$LP_ROLES_DIR" "$r")" || return 1
    files+=("$f")
  done

  printf '%s🤖 [ParallelCron] 並列ロール起動%s project=%s roles=%s stagger=%ss duration=%sm\n' \
    "$C_BLUE" "$C_RESET" "$project" "${roles[*]}" "$stagger" "$duration_min"

  # dry-run: 計画のみ (実起動なし)
  if (( dry_run )); then
    local idx
    for idx in "${!roles[@]}"; do
      printf '  %s▶ [%d] %s%s : claude -p "$(cat %s)" --output-format stream-json --permission-mode dontAsk &\n' \
        "$C_GREEN" "$((idx + 1))" "${roles[$idx]}" "$C_RESET" "${files[$idx]}"
    done
    printf '  %s⏳ ロール間隔: %ss (--stagger)%s\n' "$C_YELLOW" "$stagger" "$C_RESET"
    printf '%s✅ DRY-RUN 完了 — セットアップに問題はありません (実起動なし)%s\n' "$C_GREEN" "$C_RESET"
    return 0
  fi

  # プロジェクトディレクトリ確認 (実起動時のみ)
  [[ -d "$LP_PROJECTS_BASE/$project" ]] \
    || { printf '%sERROR: プロジェクト不在: %s%s\n' "$C_RED" "$LP_PROJECTS_BASE/$project" "$C_RESET" >&2; return 1; }

  # 二重起動防止 (lock パスはモジュールグローバルへ: EXIT トラップは
  # 関数 return 後=グローバルスコープで発火するため、local 変数は参照不可)
  mkdir -p "$LP_RUNTIME_DIR" "$LP_LOGS_DIR"
  LP_LOCK_FILE="$LP_RUNTIME_DIR/${project}-parallel.lock"
  if ! lp__acquire_lock "$LP_LOCK_FILE"; then
    printf '%s[ParallelCron] 既に起動中です (PID=%s)。終了します。%s\n' \
      "$C_YELLOW" "$(cat "$LP_LOCK_FILE" 2>/dev/null)" "$C_RESET" >&2
    return 1
  fi
  trap 'rm -f "${LP_LOCK_FILE:-}"' EXIT

  local dur_sec=$(( duration_min * 60 ))
  local stamp; stamp="$(date +%Y%m%d-%H%M%S)"
  local -a pids=()
  local idx pid log
  for idx in "${!roles[@]}"; do
    r="${roles[$idx]}"; f="${files[$idx]}"
    log="$LP_LOGS_DIR/${project}-${r}-${stamp}.log"
    # 先行ロールが状態を確立してから後続を起動 (stagger=0 で同時)
    if (( idx > 0 && stagger > 0 )); then
      printf '  %s⏳ %ss 待機後に %s を起動...%s\n' "$C_YELLOW" "$stagger" "$r" "$C_RESET"
      sleep "$stagger"
    fi
    printf '  %s🚀 [%d] %s 起動%s → %s\n' "$C_BLUE" "$((idx + 1))" "$r" "$C_RESET" "$log"
    pid="$(lp__launch_role "$project" "$r" "$f" "$log" "$dur_sec")"
    pids+=("$pid")
    printf '     %sPID=%s%s\n' "$C_GREEN" "$pid" "$C_RESET"
  done

  printf '%s⌛ 全ロールの完了を待機中 (各最大 %sm)...%s\n' "$C_GREEN" "$duration_min" "$C_RESET"
  local p
  for p in "${pids[@]}"; do wait "$p" 2>/dev/null || true; done
  printf '%s🎉 [ParallelCron] 全ロール完了 project=%s%s\n' "$C_GREEN" "$project" "$C_RESET"
}

# source ガード: 直接実行時のみ main を呼ぶ (bats は関数 source のみ)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  lp__main "$@"
fi
