#!/usr/bin/env bash
# ============================================================
# diag-claude-compat.sh — Claude Code 互換性 / Capability 診断 (メニュー項17)
#
# config/claude-code-compat.json の定義に基づき、インストール済み claude の
# version policy (minimum / recommended / tested) と各 capability の
# 実在 (flag / subcommand probe) を表示する。
#   --json   機械向け JSON を出力 (Mission Control / release-check 用)
# ============================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
# shellcheck source=lib/claude-capability.sh
source "$SCRIPT_DIR/../lib/claude-capability.sh"

main() {
  local json=0
  [[ "${1:-}" == "--json" ]] && json=1
  local bin="${CCSU_CLAUDE_BIN:-claude}"
  if ! has_cmd "$bin"; then
    if (( json )); then printf '{"version":"","policy":"unknown","capabilities":{}}\n'; else log_error "claude CLI が見つかりません"; fi
    return 1
  fi
  if (( json )); then ccsu_claude_compat_json "$bin"; return 0; fi

  local file; file="${CCSU_CLAUDE_COMPAT_FILE:-$CCSU_ROOT/config/claude-code-compat.json}"
  local v pol min rec tested
  v="$(ccsu_claude_version "$bin" 2>/dev/null || printf 'unknown')"
  pol="$(ccsu_claude_version_policy "$bin" 2>/dev/null || true)"
  min="$(jq -r '.versions.minimumSupported' "$file")"; rec="$(jq -r '.versions.recommended' "$file")"; tested="$(jq -r '.versions.tested' "$file")"

  log_info "Claude Code 互換性診断 (ClaudeOS v10 Capability Detection)"
  printf '\n  installed : %s\n  minimum   : %s\n  recommended: %s\n  tested    : %s\n  policy    : ' "$v" "$min" "$rec" "$tested"
  case "$pol" in
    supported)         printf '%s%s%s\n' "$C_GREEN"  "supported" "$C_RESET" ;;
    below-minimum)     printf '%s%s%s  ← claude update を推奨\n' "$C_RED" "below-minimum" "$C_RESET" ;;
    newer-than-tested) printf '%s%s%s  ← 動作は capability probe で判定 (要: tested 更新)\n' "$C_YELLOW" "newer-than-tested" "$C_RESET" ;;
    *)                 printf '%s\n' "unknown" ;;
  esac
  printf '\n  %-22s %-26s %-28s %s\n' "capability" "status" "probe" "result"
  printf '  %s\n' "$(printf '%.0s-' {1..90})"
  local id st pr res color
  while IFS=$'\t' read -r id st pr res; do
    case "$res" in available) color="$C_GREEN" ;; missing) color="$C_RED" ;; *) color="$C_YELLOW" ;; esac
    printf '  %-22s %-26s %-28s %s%s%s\n' "$id" "$st" "$pr" "$color" "$res" "$C_RESET"
  done < <(ccsu_claude_compat_matrix "$bin")
  printf '\n  unknown = CLI から確認不能 (セッション内機能 / preview)。docs で確認済みでも probe 不能なものは UNVERIFIED 扱い。\n\n'
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
