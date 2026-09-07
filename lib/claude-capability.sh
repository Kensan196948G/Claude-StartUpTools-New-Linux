#!/usr/bin/env bash
# ============================================================
# claude-capability.sh — Claude Code Capability Detection (ClaudeOS v10)
#
# 方針: 「version >= X だから機能あり」ではなく「CLI に flag / subcommand が実際に
#       存在するか」を probe して判定する。バージョン判定は補助 (policy 表示) に留める。
#       定義は config/claude-code-compat.json (CCSU_CLAUDE_COMPAT_FILE で上書き可)。
#
# 主な関数:
#   ccsu_claude_version [bin]            → "2.1.263" (取得不能なら空 / 非0)
#   ccsu_version_ge <a> <b>              → a >= b なら 0
#   ccsu_claude_help [bin]               → --help 全文 (version 別にキャッシュ)
#   ccsu_claude_has_flag <flag> [bin]    → 0/1
#   ccsu_claude_has_subcommand <n> [bin] → 0/1
#   ccsu_claude_capability <id> [bin]    → 0=available / 1=missing / 2=unknown(unverified)
#   ccsu_claude_cap_status <id> [bin]    → "available" | "missing" | "unknown" を出力
#   ccsu_claude_version_policy [bin]     → "supported|below-minimum|newer-than-tested|unknown" を出力
#   ccsu_claude_compat_matrix [bin]      → 人間向け表 (TSV: id, status, probe, result)
#   ccsu_claude_compat_json [bin]        → 機械向け JSON
#
# 環境変数:
#   CCSU_CLAUDE_COMPAT_FILE   定義 JSON (既定: $CCSU_ROOT/config/claude-code-compat.json)
#   CCSU_CLAUDE_CAP_CACHE_DIR --help キャッシュ置き場 (既定: $CCSU_HOME/cache)。空文字でキャッシュ無効
#   CCSU_CLAUDE_BIN           claude 実行ファイル (既定: claude)
#
# 依存: jq (無い場合は capability 判定を unknown(2) とし、flag/subcommand 直接 probe のみ動作)
# ============================================================

[[ -n "${_CCSU_CLAUDE_CAP_LOADED:-}" ]] && return 0
_CCSU_CLAUDE_CAP_LOADED=1

_cap__root() { printf '%s' "${CCSU_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"; }
_cap__compat_file() { printf '%s' "${CCSU_CLAUDE_COMPAT_FILE:-$(_cap__root)/config/claude-code-compat.json}"; }
_cap__bin() { printf '%s' "${1:-${CCSU_CLAUDE_BIN:-claude}}"; }
_cap__cache_dir() { printf '%s' "${CCSU_CLAUDE_CAP_CACHE_DIR-${CCSU_HOME:-$HOME/.claudeos}/cache}"; }

# ccsu_claude_version [bin] — "X.Y.Z" を出力。取得不能なら空文字 + 非0。
_CCSU_CLAUDE_VERSION_CACHE=""
ccsu_claude_version() {
  local bin; bin="$(_cap__bin "${1:-}")"
  if [[ -z "$_CCSU_CLAUDE_VERSION_CACHE" ]]; then
    local raw
    raw="$("$bin" --version 2>/dev/null | head -1 || true)"
    _CCSU_CLAUDE_VERSION_CACHE="$(printf '%s' "$raw" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
  fi
  [[ -n "$_CCSU_CLAUDE_VERSION_CACHE" ]] || return 1
  printf '%s' "$_CCSU_CLAUDE_VERSION_CACHE"
}

# ccsu_version_ge <a> <b> — セマンティックバージョン比較 (a >= b で 0)
ccsu_version_ge() {
  local a="$1" b="$2"
  [[ -n "$a" && -n "$b" ]] || return 1
  [[ "$(printf '%s\n%s\n' "$b" "$a" | sort -V | head -1)" == "$b" ]]
}

# ccsu_claude_help [bin] — --help 全文。version 単位でファイルキャッシュ (同一 version なら再 probe しない)。
_CCSU_CLAUDE_HELP_CACHE=""
ccsu_claude_help() {
  local bin; bin="$(_cap__bin "${1:-}")"
  if [[ -n "$_CCSU_CLAUDE_HELP_CACHE" ]]; then printf '%s\n' "$_CCSU_CLAUDE_HELP_CACHE"; return 0; fi
  local ver cache_dir cache_file=""
  ver="$(ccsu_claude_version "$bin" 2>/dev/null || true)"
  cache_dir="$(_cap__cache_dir)"
  if [[ -n "$cache_dir" && -n "$ver" ]]; then
    cache_file="$cache_dir/claude-help-${ver}.txt"
    if [[ -s "$cache_file" ]]; then
      _CCSU_CLAUDE_HELP_CACHE="$(cat "$cache_file")"
      printf '%s\n' "$_CCSU_CLAUDE_HELP_CACHE"; return 0
    fi
  fi
  _CCSU_CLAUDE_HELP_CACHE="$("$bin" --help 2>/dev/null || true)"
  [[ -n "$_CCSU_CLAUDE_HELP_CACHE" ]] || return 1
  if [[ -n "$cache_file" ]]; then
    mkdir -p "$cache_dir" 2>/dev/null && printf '%s\n' "$_CCSU_CLAUDE_HELP_CACHE" > "$cache_file" 2>/dev/null || true
  fi
  printf '%s\n' "$_CCSU_CLAUDE_HELP_CACHE"
}

# ccsu_claude_has_flag <flag> [bin] — --help に flag が存在するか (単語境界で判定)
ccsu_claude_has_flag() {
  local flag="$1" bin; bin="$(_cap__bin "${2:-}")"
  [[ -n "$flag" ]] || return 1
  ccsu_claude_help "$bin" | grep -qE "(^|[[:space:],])${flag}([[:space:],<\[]|$)"
}

# ccsu_claude_has_subcommand <name> [bin] — Commands: セクションに subcommand が存在するか
ccsu_claude_has_subcommand() {
  local name="$1" bin; bin="$(_cap__bin "${2:-}")"
  [[ -n "$name" ]] || return 1
  ccsu_claude_help "$bin" | sed -n '/^Commands:/,/^$/p' | grep -qE "^[[:space:]]+(${name}|[a-z|-]*\|${name})([|[:space:]]|$)"
}

# _cap__def <id> <jq-filter> — 定義 JSON から属性取得 (jq 必須。無ければ空)
_cap__def() {
  local id="$1" filter="$2" file; file="$(_cap__compat_file)"
  command -v jq >/dev/null 2>&1 || return 1
  [[ -f "$file" ]] || return 1
  jq -r --arg id "$id" ".capabilities[] | select(.id == \$id) | ${filter} // empty" "$file" 2>/dev/null
}

# ccsu_claude_capability <id> [bin] — 0=available / 1=missing / 2=unknown
ccsu_claude_capability() {
  local id="$1" bin; bin="$(_cap__bin "${2:-}")"
  local ptype pval
  ptype="$(_cap__def "$id" '.probe.type')" || { return 2; }
  [[ -n "$ptype" ]] || return 2
  pval="$(_cap__def "$id" '.probe.value')"
  case "$ptype" in
    flag)       ccsu_claude_has_flag "$pval" "$bin" ;;
    subcommand) ccsu_claude_has_subcommand "$pval" "$bin" ;;
    env)        [[ "${!pval:-}" == "1" || "${!pval:-}" == "true" ]] ;;
    version)    local v; v="$(ccsu_claude_version "$bin" 2>/dev/null || true)"; [[ -n "$v" ]] || return 2; ccsu_version_ge "$v" "$pval" ;;
    unverified) return 2 ;;
    *)          return 2 ;;
  esac
}

# ccsu_claude_cap_status <id> [bin] — available | missing | unknown
ccsu_claude_cap_status() {
  local rc=0
  ccsu_claude_capability "$1" "${2:-}" || rc=$?
  case "$rc" in 0) printf 'available' ;; 1) printf 'missing' ;; *) printf 'unknown' ;; esac
}

# ccsu_claude_version_policy [bin] — installed を minimum/recommended/tested と比較
ccsu_claude_version_policy() {
  local bin; bin="$(_cap__bin "${1:-}")"
  local file; file="$(_cap__compat_file)"
  local v min tested
  v="$(ccsu_claude_version "$bin" 2>/dev/null || true)"
  [[ -n "$v" ]] || { printf 'unknown'; return 2; }
  if command -v jq >/dev/null 2>&1 && [[ -f "$file" ]]; then
    min="$(jq -r '.versions.minimumSupported // empty' "$file")"
    tested="$(jq -r '.versions.tested // empty' "$file")"
  fi
  if [[ -n "$min" ]] && ! ccsu_version_ge "$v" "$min"; then printf 'below-minimum'; return 1; fi
  if [[ -n "$tested" ]] && ! ccsu_version_ge "$tested" "$v"; then printf 'newer-than-tested'; return 0; fi
  printf 'supported'
}

# ccsu_claude_compat_matrix [bin] — TSV: id <TAB> status(GA/preview/…) <TAB> probe <TAB> result
ccsu_claude_compat_matrix() {
  local bin; bin="$(_cap__bin "${1:-}")"
  local file; file="$(_cap__compat_file)"
  command -v jq >/dev/null 2>&1 || { log_warn "jq がないため互換マトリクスを表示できません"; return 1; }
  [[ -f "$file" ]] || { log_warn "互換定義がありません: $file"; return 1; }
  local id st pt pv res
  while IFS=$'\t' read -r id st pt pv; do
    res="$(ccsu_claude_cap_status "$id" "$bin")"
    printf '%s\t%s\t%s\t%s\n' "$id" "$st" "${pt}${pv:+:$pv}" "$res"
  done < <(jq -r '.capabilities[] | [.id, (.status // "-"), .probe.type, (.probe.value // "")] | @tsv' "$file")
}

# ccsu_claude_compat_json [bin] — {version, policy, capabilities:{id:result}}
ccsu_claude_compat_json() {
  local bin; bin="$(_cap__bin "${1:-}")"
  local v pol
  v="$(ccsu_claude_version "$bin" 2>/dev/null || true)"
  pol="$(ccsu_claude_version_policy "$bin" 2>/dev/null || true)"
  local pairs="" id res
  while IFS=$'\t' read -r id _ _ res; do
    pairs+="\"$id\":\"$res\","
  done < <(ccsu_claude_compat_matrix "$bin" 2>/dev/null || true)
  printf '{"version":"%s","policy":"%s","capabilities":{%s}}\n' "$v" "$pol" "${pairs%,}"
}
