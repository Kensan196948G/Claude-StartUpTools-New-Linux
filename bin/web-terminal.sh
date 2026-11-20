#!/usr/bin/env bash
# ============================================================
# web-terminal.sh — ブラウザ (ttyd) から ClaudeCode セッションへ接続する薄いアダプタ
#
#   ttyd の子プロセスとして実行される。既存の claudeos-* tmux セッションへ attach し、
#   無ければ bin/start-claude.sh (--foreground --tmux) で新規起動してから attach する。
#   Web 層 (scripts/web) の一部だが、シェル実行エントリなので bin/ に置く。
#
#   詳細: docs/architecture/WEB_TERMINAL.md
#
# 使い方:
#   web-terminal.sh                 # 対話メニュー (稼働セッション + 起動候補)
#   web-terminal.sh --project NAME  # NAME のセッションへ接続 (無ければ起動)
#   web-terminal.sh --list          # 候補を一覧 (非対話)
#   web-terminal.sh --help
#
# 安全 (docs/architecture/WEB_TERMINAL.md §安全設計):
#   - 受ける project は projectsDir 配下に実在するフォルダのみ (「フォルダ以下すべて」が対象)。
#     パス操作・改行・先頭 '-' は拒否し、生の tmux セッション名は受け取らない
#     (セッション名は ccsu_safe_name から本スクリプトが導出する)。
#   - 実行するのは tmux attach / bin/start-claude.sh のみ。任意シェルは開かない。
# ============================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
# shellcheck source=lib/config-loader.sh
source "$SCRIPT_DIR/../lib/config-loader.sh"
# shellcheck source=lib/launcher-common.sh
source "$SCRIPT_DIR/../lib/launcher-common.sh"

TMUX_BIN="${TMUX_BIN:-tmux}"
START_CLAUDE_BIN="${CCSU_START_CLAUDE_BIN:-$SCRIPT_DIR/start-claude.sh}"
AUDIT_LOG="${CCSU_HOME}/logs/web-startup-audit.log"
WT_PROJECT=""
WT_LIST=0

wt__usage() {
  cat <<'USAGE'
web-terminal.sh — ブラウザ (ttyd) から ClaudeCode セッションへ接続する

  web-terminal.sh                 # 対話メニュー (稼働セッション + 起動候補)
  web-terminal.sh --project NAME  # NAME のセッションへ接続 (無ければ新規起動)
  web-terminal.sh --list          # 稼働セッションと登録プロジェクトを一覧
  web-terminal.sh --help
USAGE
}

wt__audit() {
  local event="$1" project="$2" session="${3:-}"
  mkdir -p "$(dirname "$AUDIT_LOG")"
  jq -cn --arg ts "$(date -Iseconds)" --arg event "$event" --arg project "$project" \
         --arg session "$session" --arg actor "web-terminal" \
         '{ts:$ts,event:$event,project:$project,session:$session,actor:$actor}' \
    >> "$AUDIT_LOG" 2>/dev/null || true
}

# wt__valid_project <name> — projectsDir 配下に実在するフォルダ名のみ許可する。
#   「フォルダ以下すべて」を起動対象にするため config 登録は要求しない。
#   ただし client 入力からパスやセッション名を作らないための拒否はここに残す。
wt__valid_project() {
  local name="${1:-}"
  [[ -n "$name" && ${#name} -le 200 ]] || return 1
  case "$name" in
    -*) return 1 ;;
    *..*) return 1 ;;
    *$'\n'*|*$'\r'*|*$'\t'*) return 1 ;;
  esac
  [[ -d "$(config_projects_dir)/$name" ]]
}

# wt__all_folders — projectsDir 直下と、その直下 (深さ2) の全フォルダ名 (1行1件)。
#   隠しフォルダと node_modules のみ除外する (libexec/startup-state.sh の _all_folders と同一規則)。
wt__all_folders() {
  local base; base="$(config_projects_dir)"
  [[ -d "$base" ]] || return 0
  local d sd name sname
  for d in "$base"/*/; do
    [[ -d "$d" ]] || continue
    name="$(basename "$d")"
    [[ "$name" == .* || "$name" == "node_modules" ]] && continue
    printf '%s\n' "$name"
    for sd in "$d"/*/; do
      [[ -d "$sd" ]] || continue
      sname="$(basename "$sd")"
      [[ "$sname" == .* || "$sname" == "node_modules" ]] && continue
      printf '%s/%s\n' "$name" "$sname"
    done
  done
}

wt__candidates() {
  local safe; safe="$(ccsu_safe_name "$1")"
  printf 'claudeos-%s\n' "$safe"
  printf 'claudeos-team-%s\n' "$safe"
}

wt__running_session() {
  local c
  while IFS= read -r c; do
    if "$TMUX_BIN" has-session -t "$c" 2>/dev/null; then printf '%s' "$c"; return 0; fi
  done < <(wt__candidates "$1")
  return 0
}

wt__attach_or_start() {
  local project="$1" session
  session="$(wt__running_session "$project")"
  if [[ -n "$session" ]]; then
    log_info "既存セッションへ接続: $session"
    wt__audit "terminal_attach" "$project" "$session"
    "$TMUX_BIN" attach -t "$session"
    return 0
  fi
  log_info "セッションが無いため新規起動します: $project (foreground + tmux)"
  wt__audit "terminal_start" "$project" "claudeos-$(ccsu_safe_name "$project")"
  "$START_CLAUDE_BIN" --project "$project" --foreground --tmux
}

# wt__menu — 稼働セッションと起動候補を番号付きで提示し、選択に従って接続する。
#   戻り値: 0 = q で終了、1 = 選択後に再度メニューへ戻る。
wt__menu() {
  local -a sessions=() names=() opts=()
  local s p
  while IFS= read -r s; do
    [[ -n "$s" ]] || continue
    sessions+=("$s")
  done < <("$TMUX_BIN" ls 2>/dev/null | sed -n 's/:.*//p' | grep '^claudeos-' || true)
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    names+=("$p")
  done < <(wt__all_folders || true)

  echo "=============================================="
  echo " ClaudeOS Web ターミナル — 接続先を選択"
  echo "=============================================="
  local i=1
  for s in "${sessions[@]}"; do
    printf '  %2d) [接続] %s\n' "$i" "$s"; opts+=("attach:$s"); i=$((i + 1))
  done
  for p in "${names[@]}"; do
    printf '  %2d) [起動] %s\n' "$i" "$p"; opts+=("start:$p"); i=$((i + 1))
  done
  echo "   q) 終了"
  echo

  local sel
  read -r -p "番号を入力 (q=終了): " sel || return 0
  case "$sel" in
    q|Q) return 0 ;;
  esac
  if ! [[ "$sel" =~ ^[0-9]+$ ]] || (( sel < 1 || sel > ${#opts[@]} )); then
    log_warn "1〜${#opts[@]} の番号、または q を入力してください"
    return 1
  fi
  local chosen="${opts[$((sel - 1))]}"
  case "$chosen" in
    attach:*)
      wt__audit "terminal_attach" "${chosen#attach:}" "${chosen#attach:}"
      "$TMUX_BIN" attach -t "${chosen#attach:}" || true
      ;;
    start:*)
      wt__audit "terminal_start" "${chosen#start:}"
      "$START_CLAUDE_BIN" --project "${chosen#start:}" --foreground --tmux || true
      ;;
  esac
  return 1
}

main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --project)  WT_PROJECT="${2:-}"; shift 2 ;;
      --list)     WT_LIST=1; shift ;;
      --help|-h)  wt__usage; return 0 ;;
      *) log_error "不明な引数: $1"; exit 1 ;;
    esac
  done

  has_cmd "$TMUX_BIN" || die "tmux が見つかりません: $TMUX_BIN"

  if (( WT_LIST )); then
    echo "# 稼働中セッション"
    "$TMUX_BIN" ls 2>/dev/null | sed -n 's/:.*//p' | grep '^claudeos-' || true
    echo "# projectsDir 配下のフォルダ"
    wt__all_folders || true
    return 0
  fi

  if [[ -n "$WT_PROJECT" ]]; then
    if ! wt__valid_project "$WT_PROJECT"; then
      log_error "存在しない project です (projectsDir 配下のフォルダのみ許可): $WT_PROJECT"
      return 2
    fi
    wt__attach_or_start "$WT_PROJECT"
    return 0
  fi

  local rc=1
  while (( rc != 0 )); do
    rc=0
    wt__menu || rc=1
  done
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
