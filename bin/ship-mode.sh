#!/usr/bin/env bash
# ============================================================
# ship-mode.sh — Ship Native 起動モード (SH1〜SH5 / QC / HG) のディスパッチ
#
# 使い方:
#   ship-mode.sh status                         各モードの利用可否 (Available / Experimental / Unavailable)
#   ship-mode.sh SH1 --project DIR [--pr N]     Ship 品質検証: 対話セッションの起動手順を示す (/ship は人が入力)
#   ship-mode.sh SH2 --project DIR --intent T   Ship Native 自律開発: run を作り、対話セッションを起動する
#   ship-mode.sh SH3 --project DIR --intent T   Agent Teams (T1) で開発 → 統合後に SH1 の手順
#   ship-mode.sh SH4 --project DIR --pr N       既存 PR 改善: /steward 手順 + 品質判定
#   ship-mode.sh SH5                            Multi-Project Ship Monitor (monitor --once + 一覧)
#   ship-mode.sh QC  --project DIR [--head SHA] Ubuntu ローカル品質検証のみ
#   ship-mode.sh HG                             Human Gate (承認待ち一覧 + ship-approve.sh の案内)
#   共通: --dry-run (何も起動しない)
#
# 重要: /ship・/steward は公式仕様で「人が対話セッションに入力した行」からのみ起動する。
#       このスクリプトは tmux send-keys 等で入力を代行しない。人が入力する文字列を表示するだけ。
# 既存の L1 / T1 / S1 は bin/start-claude.sh のまま変更しない (後方互換)。
# ============================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

SHIP="${CCSU_SHIP_CLI:-$SCRIPT_DIR/ship.sh}"
START="${CCSU_START_CLAUDE:-$SCRIPT_DIR/start-claude.sh}"

usage() { sed -n '2,19p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

mode="${1:-}"; shift || true
project=""; intent=""; pr=""; head=""; dry_run=0
while (( $# )); do
  case "$1" in
    --project) project="${2:-}"; shift 2 ;;
    --intent)  intent="${2:-}"; shift 2 ;;
    --pr)      pr="${2:-}"; shift 2 ;;
    --head)    head="${2:-}"; shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) log_error "不明な引数: $1"; exit 2 ;;
  esac
done

repo_of() {
  local url; url="$(git -C "$1" remote get-url origin 2>/dev/null || true)"
  [[ "$url" =~ github\.com[:/]([^/]+/[^/]+)$ ]] || return 1
  printf '%s' "${BASH_REMATCH[1]%.git}"
}
need_project() {
  [[ -n "$project" && -d "$project/.git" ]] || { log_error "--project に Git リポジトリを指定してください"; exit 2; }
  project="$(cd "$project" && pwd)"
}

# capability (キャッシュ) から overall を得る。無ければ判定する
cap_overall() {
  local f="${CLAUDEOS_SHIP_HOME:-${CCSU_HOME}/ship}/capability.json"
  if [[ ! -s "$f" ]]; then bash "$SHIP" capability ${project:+--project "$project"} --json >/dev/null 2>&1 || true; fi
  jq -r '.overall // "unknown"' "$f" 2>/dev/null || printf 'unknown'
}

print_ship_steps() {
  local p="$1" n="${2:-}"
  printf '\n%s━━ 人が行う手順 (Ship は対話セッション内コマンド) ━━%s\n' "$C_CYAN" "$C_RESET"
  printf '  1. 対話型 Claude Code を %s で開く (permission mode = auto 推奨。bypassPermissions では watch しない)\n' "$p"
  if [[ -n "$n" ]]; then
    printf '  2. プロンプトで次を入力:  %s/steward %s%s   (レビュー済みなら) / %s/ship %s%s\n' "$C_GREEN" "$n" "$C_RESET" "$C_GREEN" "$n" "$C_RESET"
  else
    printf '  2. プロンプトで次を入力:  %s/ship%s\n' "$C_GREEN" "$C_RESET"
  fi
  printf '  3. 停止するときはそのセッションで  %s/ship stop%s  (状況確認は /tasks)\n' "$C_YELLOW" "$C_RESET"
  printf '  4. 完了後、見た結果を署名して残す:\n     bin/ship-approve.sh ship-attest --repo <owner/repo> --pr <N> --head <SHA> --workdir <この作業フォルダ> --reviewed yes --important-open <重大な指摘の件数> --watch checks-pass-comments-answered\n     (作業フォルダに /ship の修正が残っていると署名できない。重大な指摘の件数は端末で入力し直す)\n'
  printf '  5. ClaudeOS 側:  bin/ship.sh quality ... → bin/ship.sh gate ... → (人) bin/ship-approve.sh approve ... → bin/ship.sh merge ...\n'
  printf '  ⚠ watch 中は Claude が gh/git をあなたの権限で使います。auto-merge を有効にした PR では watch の push がマージに至り得ます。\n\n'
}

status_cmd() {
  local overall; overall="$(cap_overall)"
  local sh_state="Unavailable"
  case "$overall" in
    available) sh_state="Experimental" ;;   # 実機の対話セッション検証が済むまで Experimental
    degraded)  sh_state="Experimental (review のみ。watch 不可)" ;;
  esac
  printf '%-4s %-46s %s\n' "MODE" "内容" "状態"
  printf '%-4s %-46s %s\n' "L1" "対話型開発 (既存)" "Available"
  printf '%-4s %-46s %s\n' "T1" "Agent Teams 開発 (既存)" "Available"
  printf '%-4s %-46s %s\n' "S1" "バックグラウンド自律開発 (既存)" "Available"
  printf '%-4s %-46s %s\n' "SH1" "Ship 品質検証" "$sh_state"
  printf '%-4s %-46s %s\n' "SH2" "Ship Native 自律開発 (既定化は実機検証後)" "$sh_state"
  printf '%-4s %-46s %s\n' "SH3" "Agent Teams + Ship" "$sh_state"
  printf '%-4s %-46s %s\n' "SH4" "既存 PR 改善 (/steward)" "$sh_state"
  printf '%-4s %-46s %s\n' "SH5" "Multi-Project Ship Monitor" "Available (読み取り)"
  printf '%-4s %-46s %s\n' "QC" "Ubuntu ローカル品質検証" "$(command -v bwrap >/dev/null && echo Available || echo 'Unavailable (bwrap なし)')"
  printf '%-4s %-46s %s\n' "HG" "Human Gate" "Available (承認は人の端末から)"
  printf '\nShip capability: %s  (詳細: bin/ship.sh capability)\n' "$overall"
}

case "$mode" in
  status|"") status_cmd ;;
  SH1)
    need_project
    print_ship_steps "$project" "$pr" ;;
  SH2|SH3)
    need_project
    [[ -n "$intent" ]] || { log_error "--intent (開発目的) が必要です"; exit 2; }
    repo="$(repo_of "$project")" || { log_error "GitHub リモートが見つかりません"; exit 3; }
    if (( dry_run )); then
      printf 'DRY-RUN: ship run-start --repo %s --mode %s; start-claude --project %s --%s\n' "$repo" "$mode" "$(basename "$project")" "$([[ $mode == SH3 ]] && echo team || echo foreground)"
      exit 0
    fi
    bash "$SHIP" run-start --project "$project" --repo "$repo" --mode "$mode" --intent "$intent" --json
    print_ship_steps "$project" ""
    if [[ "$mode" == "SH3" ]]; then
      exec bash "$START" --project "$(basename "$project")" --team --intent "$intent"
    else
      exec bash "$START" --project "$(basename "$project")" --foreground --intent "$intent"
    fi ;;
  SH4)
    need_project
    [[ -n "$pr" ]] || { log_error "--pr が必要です"; exit 2; }
    print_ship_steps "$project" "$pr" ;;
  SH5)
    bash "$SHIP" monitor --once
    bash "$SHIP" run-status ;;
  QC)
    need_project
    repo="$(repo_of "$project")" || { log_error "GitHub リモートが見つかりません"; exit 3; }
    [[ -n "$head" ]] || head="$(git -C "$project" rev-parse HEAD)"
    (( dry_run )) && { printf 'DRY-RUN: ship quality --repo %s --head %s\n' "$repo" "$head"; exit 0; }
    exec bash "$SHIP" quality --repo "$repo" --project "$project" --head "$head" ${pr:+--pr "$pr"} ;;
  HG)
    bash "$SHIP" run-status
    printf '\n承認は人の端末から: bin/ship-approve.sh show --repo <owner/repo> --pr <N>  →  approve --head <SHA>\n' ;;
  -h|--help) usage ;;
  *) log_error "不明なモード: $mode"; usage >&2; exit 2 ;;
esac
