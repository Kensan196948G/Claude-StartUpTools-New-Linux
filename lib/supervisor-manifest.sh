#!/usr/bin/env bash
# ============================================================
# supervisor-manifest.sh — Supervisor ロールアウト監査 (Linux native)
#
# 役割: 全登録プロジェクトに「ClaudeOS 管理ポリシー宣言 (manifest)」が
#       配布済みかを監査し、Managed/Missing/Foreign/Invalid に分類する。
#       書き込み前に desired との差分をプレビューできる (非破壊優先)。
#
# 移植元: Codex-StartUpTools-New-Linux/scripts/lib/SupervisorManager.psm1
#   の分類 (Managed/Missing/Foreign/Invalid) + diff/preview (Create/Update/
#   ReplaceInvalid/RefreshTimestamp) の概念のみ。Codex 固有 (.codex/、codexOnly、
#   PowerShell) は持ち込まず Claude/Bash 向けに書き直し。
#
# 注意: ランタイム supervisor 状態 (~/.claudeos/supervisor/*.json, lib/supervisor.sh)
#       とは別概念。こちらは「プロジェクト repo 内に置く静的なポリシー宣言」であり、
#       名前空間を supman__ で分離する。
# ============================================================

[[ -n "${_CCSU_SUPMAN_LOADED:-}" ]] && return 0
_CCSU_SUPMAN_LOADED=1

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/config-loader.sh"

# 管理主体名 (Managed 分類の照合キー)。このリポジトリ名を正本とする。
SUPMAN_MANAGED_BY="${CCSU_SUPMAN_MANAGED_BY:-Claude-StartUpTools-New-Linux}"

# 差分対象のポリシーキー (appliedAt は毎回変わるため意図的に除外 → RefreshTimestamp で扱う)
SUPMAN_POLICY_KEYS=(schemaVersion project managedBy mode agentLoop sshEnabled humanDecisionRequired)

# supman__manifest_path <project_dir> — manifest の絶対パス
supman__manifest_path() { printf '%s/.claude/claudeos/supervisor-manifest.json' "$1"; }

# supman__mode — config supervisor.mode (既定 cto-autonomous)
supman__mode() { config_get '.supervisor.mode' 'cto-autonomous'; }

# supman__human_decision_json — config supervisor.humanDecisionRequired (既定 CLAUDE.md 準拠)
#   config に配列があればそれを、無ければ本リポジトリ CLAUDE.md の人間最終決断範囲を返す。
supman__human_decision_json() {
  local raw
  raw="$(config_get_raw '.supervisor.humanDecisionRequired')"
  if [[ -n "$raw" && "$raw" != "null" ]]; then
    printf '%s' "$raw"
  else
    printf '%s' '["main-direct-push","production-release","secrets","destructive-delete","all-supervisor-apply"]'
  fi
}

# supman__desired <project_name> [with_timestamp] — desired manifest JSON を stdout
#   with_timestamp=1 のときのみ appliedAt を付与 (書き込み用)。既定は比較用で付与しない。
supman__desired() {
  local name="$1" with_ts="${2:-0}" mode hdr
  mode="$(supman__mode)"
  hdr="$(supman__human_decision_json)"
  local ts_filter='.'
  if (( with_ts )); then
    ts_filter='. + {supervisorAppliedAt: $ts}'
  fi
  jq -n \
    --arg project "$name" \
    --arg managedBy "$SUPMAN_MANAGED_BY" \
    --arg mode "$mode" \
    --arg ts "$(date -Iseconds)" \
    --argjson agentLoop '["monitor","build","verify","improve"]' \
    --argjson hdr "$hdr" \
    '{
       schemaVersion: "1.0.0",
       project: $project,
       managedBy: $managedBy,
       mode: $mode,
       agentLoop: $agentLoop,
       sshEnabled: false,
       humanDecisionRequired: $hdr
     } | '"$ts_filter"
}

# supman__classify <project_dir> — stdout: Managed|Missing|Foreign|Invalid
supman__classify() {
  local dir="$1" path; path="$(supman__manifest_path "$dir")"
  [[ -f "$path" ]] || { printf 'Missing'; return 0; }
  jq empty "$path" >/dev/null 2>&1 || { printf 'Invalid'; return 0; }
  local managed_by ssh_enabled
  managed_by="$(jq -r '.managedBy // ""' "$path" 2>/dev/null || true)"
  ssh_enabled="$(jq -r '.sshEnabled // false' "$path" 2>/dev/null || true)"
  if [[ "$managed_by" == "$SUPMAN_MANAGED_BY" && "$ssh_enabled" == "false" ]]; then
    printf 'Managed'
  else
    printf 'Foreign'
  fi
}

# supman__keytext <file> <key> — 指定キーを比較用テキストへ正規化
#   配列→カンマ結合 / bool→小文字 / null→(missing) / それ以外→文字列
supman__keytext() {
  jq -r --arg k "$2" '
    .[$k] as $v |
    if $v == null then "(missing)"
    elif ($v|type) == "array" then ($v|map(tostring)|join(","))
    elif ($v|type) == "boolean" then ($v|tostring)
    else ($v|tostring) end' "$1" 2>/dev/null || printf '(missing)'
}

# supman__diff <project_dir> — 差分を stdout
#   1行目: action=Create|ReplaceInvalid|Update|RefreshTimestamp
#   以降 : property|current|desired|type  (Update 時のみ、変更キー分)
supman__diff() {
  local dir="$1" name; name="$(basename "$dir")"
  local status; status="$(supman__classify "$dir")"

  case "$status" in
    Missing) printf 'action=Create\n';         return 0 ;;
    Invalid) printf 'action=ReplaceInvalid\n';  return 0 ;;
  esac

  # Managed/Foreign: desired と現行のポリシーキーを比較
  local cur; cur="$(supman__manifest_path "$dir")"
  local desired_tmp; desired_tmp="$(mktemp)"
  supman__desired "$name" 0 > "$desired_tmp"

  local -a change_lines=()
  local key ctext dtext ctype
  for key in "${SUPMAN_POLICY_KEYS[@]}"; do
    ctext="$(supman__keytext "$cur" "$key")"
    dtext="$(supman__keytext "$desired_tmp" "$key")"
    if [[ "$ctext" != "$dtext" ]]; then
      if   [[ "$ctext" == "(missing)" ]]; then ctype="Added"
      elif [[ "$dtext" == "(missing)" ]]; then ctype="Removed"
      else ctype="Changed"; fi
      change_lines+=("$key|$ctext|$dtext|$ctype")
    fi
  done
  rm -f "$desired_tmp"

  if (( ${#change_lines[@]} > 0 )); then
    printf 'action=Update\n'
    printf '%s\n' "${change_lines[@]}"
  else
    printf 'action=RefreshTimestamp\n'
  fi
}

# supman__apply <project_dir> [--preview] — manifest を書き込む (--preview は差分表示のみ)
#   Foreign は既定で保護 (上書きしない)。CCSU_SUPMAN_FORCE=1 で強制上書き可。
supman__apply() {
  local dir="$1" preview=0
  [[ "${2:-}" == "--preview" ]] && preview=1
  [[ -d "$dir" ]] || { log_error "プロジェクトディレクトリが存在しません: $dir"; return 1; }

  local name status path
  name="$(basename "$dir")"
  status="$(supman__classify "$dir")"
  path="$(supman__manifest_path "$dir")"

  # Foreign 保護: 他ツール管理の manifest は明示強制がない限り触らない
  if [[ "$status" == "Foreign" && "${CCSU_SUPMAN_FORCE:-0}" != "1" ]]; then
    log_warn "Foreign manifest を保護 (未変更): $name ($path)"
    log_info "  上書きするには CCSU_SUPMAN_FORCE=1 を指定してください"
    return 0
  fi

  # diff を一度だけ捕捉し bash 文字列操作で分解 (head/tail パイプの SIGPIPE を回避)
  local diff_out action body
  diff_out="$(supman__diff "$dir")"
  action="${diff_out%%$'\n'*}"; action="${action#action=}"

  if (( preview )); then
    printf '  %s📋 %-28s%s action=%s\n' "$C_CYAN" "$name" "$C_RESET" "$action"
    body="${diff_out#*$'\n'}"
    [[ "$body" != "$diff_out" ]] && printf '%s\n' "$body" | while IFS='|' read -r prop cur des typ; do
      [[ -z "$prop" ]] && continue
      printf '     %s%-22s%s %s → %s (%s)\n' "$C_YELLOW" "$prop" "$C_RESET" "$cur" "$des" "$typ"
    done
    return 0
  fi

  mkdir -p "$(dirname "$path")"
  local tmp; tmp="$(mktemp)"
  supman__desired "$name" 1 > "$tmp"
  mv "$tmp" "$path"
  log_ok "✍️  manifest 適用: $name (action=$action)"
}

# supman__report — 全登録プロジェクトを分類し表 + 集計を表示
supman__report() {
  local base; base="$(config_projects_dir)"
  printf '  %s🛡️  Supervisor ロールアウト監査%s\n' "$C_CYAN" "$C_RESET"
  printf '  %-28s %-10s %s\n' "PROJECT" "STATUS" "MANIFEST"

  local total=0 managed=0 missing=0 foreign=0 invalid=0
  local p dir status color icon
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    dir="$base/$p"
    status="$(supman__classify "$dir")"
    total=$((total + 1))
    case "$status" in
      Managed) color="$C_GREEN";  icon="🟢"; managed=$((managed + 1)) ;;
      Missing) color="$C_YELLOW"; icon="🟡"; missing=$((missing + 1)) ;;
      Foreign) color="$C_MAGENTA";icon="🟣"; foreign=$((foreign + 1)) ;;
      Invalid) color="$C_RED";    icon="🔴"; invalid=$((invalid + 1)) ;;
      *)       color="$C_WHITE";  icon="⚪" ;;
    esac
    printf '  %s%-28s%s %s%-8s%s %s\n' "$color" "$p" "$C_RESET" "$icon" "$status" "$C_RESET" "$(supman__manifest_path "$dir")"
  done < <(config_project_list)

  printf '\n  %s📊 集計%s total=%d  🟢Managed=%d  🟡Missing=%d  🟣Foreign=%d  🔴Invalid=%d\n' \
    "$C_CYAN" "$C_RESET" "$total" "$managed" "$missing" "$foreign" "$invalid"
}
