#!/usr/bin/env bash
# ============================================================
# policy-engine.sh — Agent Identity / Policy Engine (deny-by-default)
#
# 役割: Agent ごとに「何をしてよいか」を宣言的に定義し、実行前に機械判定する。
#       - 判定は config/agent-policy.json の静的ポリシーのみ (確率的判断を入れない)
#       - 既定は deny。allow に載っているものだけが allow
#       - hard_deny は承認トークンがあっても拒否 (承認で破れる権限を作らない)
#       - すべての判定を JSONL (policy-audit.jsonl) へ記録する = 監査証跡
#       - 承認が必要な操作は approval_required を返し、cto/security が発行した
#         identity token を提示したときだけ allow へ昇格する
#
# 終了コード (policy_check): 0 allow / 1 deny / 3 approval_required
#
# 性能設計: 判定は 1 プロセスで多数回呼ばれる (agent × action の一括列挙)。
#   設定は policy__prefetch で「jq 1 回」だけ読み、bash 変数へ射影する。
#   以降の照合・risk 評価・順位比較はすべて bash 内で完結させ、判定 1 件あたりの
#   外部プロセス起動を jq 1 回 (結果 JSON の生成) に抑える。
#   サブシェル ($(...) / パイプ) では変数の書き戻しが消えるため、メモ化を
#   コマンド置換に依存させない (この設計はその実測から来ている)。
#
# 秘密: identity 署名鍵は ~/.claudeos/policy/identity.key (0600, 初回生成)。
#       鍵の内容は出力しない。token は agent 識別用で秘密情報を含まない。
#
# 注意: このファイルは「source される」ため set -euo pipefail を設定しない。
# ============================================================

[[ -n "${_CCSU_POLICY_ENGINE_LOADED:-}" ]] && return 0
_CCSU_POLICY_ENGINE_LOADED=1

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/json.sh"

POLICY_SCHEMA="claudeos.agent-policy/v1"
POLICY_TOKEN_SCHEMA="claudeos.agent-identity/v1"
POLICY_US=$'\x1f'   # unit separator (設定射影のフィールド区切り)
POLICY_RS=$'\x1e'   # record separator (設定射影のレコード区切り)
POLICY_GS=$'\x1d'   # group separator  (設定射影のフィールド区切り)

policy__config_path() { printf '%s' "${CLAUDEOS_AGENT_POLICY:-$CCSU_ROOT/config/agent-policy.json}"; }
policy__expand() {
  local p="$1"
  p="${p/#\~/$HOME}"
  printf '%s' "$p"
}

# ------------------------------------------------------------
# policy__prefetch — 設定を 1 回の jq で読み、bash 変数へ射影する
#   POL_VERSION / POL_SCHEMA / POL_ORDER / POL_HARD / POL_APPROVERS / POL_TTL
#   POL_KEYFILE / POL_AUDITFILE
#   POL_AGENTS : "agent<US>max_risk<US>allow<US>approval_required<US>deny" の行
#   POL_RISK   : "pattern<US>risk" の行
# ------------------------------------------------------------
POLICY_PREFETCHED=""
policy__prefetch() {
  [[ -n "$POLICY_PREFETCHED" ]] && return 0
  local cfg; cfg="$(policy__config_path)"
  POLICY_PREFETCHED=1
  if [[ ! -f "$cfg" ]]; then
    log_warn "policy: 設定を読めません: $cfg"
    POL_VERSION="unknown"; POL_SCHEMA=""; POL_ORDER="low medium high critical"
    POL_HARD=""; POL_APPROVERS=""; POL_TTL="900"; POL_KEYFILE=""; POL_AUDITFILE=""
    POL_AGENTS=""; POL_RISK=""
    return 1
  fi
  local us="$POLICY_US" rs="$POLICY_RS" gs="$POLICY_GS"
  local dump
  dump="$(jq -r --arg us "$us" --arg rs "$rs" --arg gs "$gs" '
    . as $c |
    [
      ($c.version // "unknown"),
      ($c.schema // ""),
      (($c.risk_order // ["low","medium","high","critical"]) | join(" ")),
      (($c.hard_deny // []) | join(" ")),
      (($c.approver_agents // []) | join(" ")),
      (($c.token_ttl_seconds // 900) | tostring),
      ($c.identity_key_file // ""),
      ($c.audit_file // ""),
      (($c.agents // {}) | to_entries | map(.key + $us + (.value.max_risk // "low") + $us
         + ((.value.allow // []) | join(" ")) + $us
         + ((.value.approval_required // []) | join(" ")) + $us
         + ((.value.deny // []) | join(" "))) | join($rs)),
      (($c.action_risk // {}) | to_entries | map(.key + $us + (.value | tostring)) | join($rs))
    ] | join($gs)' "$cfg" 2>/dev/null)" || dump=""

  if [[ -z "$dump" ]]; then
    log_warn "policy: 設定の解析に失敗しました: $cfg"
    POL_VERSION="unknown"; POL_SCHEMA=""; POL_ORDER="low medium high critical"
    POL_HARD=""; POL_APPROVERS=""; POL_TTL="900"; POL_KEYFILE=""; POL_AUDITFILE=""
    POL_AGENTS=""; POL_RISK=""
    return 1
  fi

  local -a F=() part
  while IFS= read -r -d "$gs" part; do F+=("$part"); done < <(printf '%s%s' "$dump" "$gs")
  POL_VERSION="${F[0]:-unknown}"
  POL_SCHEMA="${F[1]:-}"
  POL_ORDER="${F[2]:-low medium high critical}"
  POL_HARD="${F[3]:-}"
  POL_APPROVERS="${F[4]:-}"
  POL_TTL="${F[5]:-900}"
  POL_KEYFILE="${F[6]:-}"
  POL_AUDITFILE="${F[7]:-}"
  POL_AGENTS="$(printf '%s' "${F[8]:-}" | tr "$rs" '\n')"
  POL_RISK="$(printf '%s' "${F[9]:-}" | tr "$rs" '\n')"
  return 0
}

# ------------------------------------------------------------
# パターン照合
# ------------------------------------------------------------

# policy__match <glob-pattern> <value> — * と ? のみのパターン照合 (正規表現は使わない)
policy__match() {
  local pat="$1" val="$2"
  # shellcheck disable=SC2254  # 意図的に glob 展開させる
  case "$val" in $pat) return 0 ;; *) return 1 ;; esac
}

# policy__word_match <"a b c"> <value> — 空白区切りのパターン群に対する照合
policy__word_match() {
  local words="$1" val="$2" w
  for w in $words; do
    policy__match "$w" "$val" && return 0
  done
  return 1
}

# policy__list_match <json-array> <value> — 互換 API (配列 JSON をその場で照合)
policy__list_match() {
  local arr="$1" val="$2" pat
  while IFS= read -r pat; do
    [[ -n "$pat" ]] || continue
    policy__match "$pat" "$val" && return 0
  done <<<"$(printf '%s' "$arr" | jq -r '.[]?' 2>/dev/null || true)"
  return 1
}

# ------------------------------------------------------------
# 設定値の参照
# ------------------------------------------------------------
policy__cfg() { json_get "$(policy__config_path)" "$1" "${2:-}"; }
policy__cfg_json() {
  local f; f="$(policy__config_path)"
  [[ -f "$f" ]] || { printf 'null'; return 0; }
  jq -c "$1" "$f" 2>/dev/null || printf 'null'
}

# policy__agent_field <agent> — 結果を POLICY_LAST / POLICY_MAX_RISK /
#   POLICY_ALLOW / POLICY_APPROVAL / POLICY_DENY に置く。未知 agent は rc=1。
policy__agent_field() {
  local agent="$1" line rest
  POLICY_LAST=""
  POLICY_MAX_RISK=""; POLICY_ALLOW=""; POLICY_APPROVAL=""; POLICY_DENY=""
  policy__prefetch
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    [[ "$line" == "$agent"$'\x1f'* ]] || continue
    rest="${line#"$agent"$'\x1f'}"
    POLICY_MAX_RISK="${rest%%$'\x1f'*}"; rest="${rest#*$'\x1f'}"
    POLICY_ALLOW="${rest%%$'\x1f'*}";     rest="${rest#*$'\x1f'}"
    POLICY_APPROVAL="${rest%%$'\x1f'*}"
    POLICY_DENY="${rest#*$'\x1f'}"
    POLICY_LAST="$POLICY_MAX_RISK"
    return 0
  done <<<"$POL_AGENTS"
  return 1
}

policy__agent_exists() { policy__agent_field "$1"; }

# policy__risk_lookup <action> — リスク区分を POLICY_LAST に置く (未知は "unknown")
#   完全一致を先に、次に glob 一致 (action_risk の並び順に依存しない)。
policy__risk_lookup() {
  local action="$1" line pat
  POLICY_LAST="unknown"
  policy__prefetch
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    pat="${line%%$'\x1f'*}"
    [[ "$pat" == "$action" ]] || continue
    POLICY_LAST="${line#*$'\x1f'}"
    return 0
  done <<<"$POL_RISK"
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    pat="${line%%$'\x1f'*}"
    if policy__match "$pat" "$action"; then POLICY_LAST="${line#*$'\x1f'}"; return 0; fi
  done <<<"$POL_RISK"
  return 0
}

# policy__risk <action> — 互換 API (値を stdout へ)
policy__risk() { policy__risk_lookup "$1"; printf '%s' "$POLICY_LAST"; }

# policy__rank <risk> — risk_order 上の順位 (未定義は 99 = 最危険)
policy__rank() {
  local risk="$1" i=0 r
  policy__prefetch
  for r in $POL_ORDER; do
    if [[ "$r" == "$risk" ]]; then printf '%s' "$i"; return 0; fi
    i=$(( i + 1 ))
  done
  printf '%s' "99"
}

# policy__rank_le <risk> <max_risk> — rank(risk) <= rank(max) なら 0 (サブシェル不要)
policy__rank_le() {
  local risk="$1" maxr="$2" r i=0 rr=99 rm=99
  policy__prefetch
  for r in $POL_ORDER; do
    [[ "$r" == "$risk" ]] && rr=$i
    [[ "$r" == "$maxr" ]] && rm=$i
    i=$(( i + 1 ))
  done
  (( rr <= rm ))
}

# ------------------------------------------------------------
# 判定の中核 (bash のみ。結果は POLICY_DEC_* を介して返す)
#   policy__decide_core <action>
#     前提: policy__agent_field <agent> 済み (POLICY_MAX_RISK/ALLOW/APPROVAL/DENY)
#     結果: POLICY_DEC_LABEL  = allow | deny | approval_required
#           POLICY_DEC_REASON = allow_listed|default_deny|unclassified_action|hard_deny|
#                               agent_deny|approval_required|risk_exceeds
#           POLICY_DEC_ARG    = 理由に埋める値 (action または "risk>max")
# ------------------------------------------------------------
policy__decide_core() {
  local action="$1"
  POLICY_DEC_LABEL="deny"; POLICY_DEC_REASON="default_deny"; POLICY_DEC_ARG=""
  if [[ -z "$action" ]]; then
    POLICY_DEC_REASON="unclassified_action"
    return 0
  fi
  policy__risk_lookup "$action"
  local risk="$POLICY_LAST"
  if [[ "$risk" == "unknown" ]]; then
    POLICY_DEC_REASON="unclassified_action"
  elif policy__word_match "$POL_HARD" "$action"; then
    POLICY_DEC_REASON="hard_deny"
  elif policy__word_match "$POLICY_DENY" "$action"; then
    POLICY_DEC_REASON="agent_deny"; POLICY_DEC_ARG="$action"
  elif policy__word_match "$POLICY_APPROVAL" "$action"; then
    # 承認必須の明示列挙は risk 上限より優先する (人間が確実に介在するため)。
    # allow へ昇格できるのは approver_agents (cto/security) の token 提示時のみ。
    POLICY_DEC_LABEL="approval_required"; POLICY_DEC_REASON="approval_required"; POLICY_DEC_ARG="$action"
  elif ! policy__rank_le "$risk" "$POLICY_MAX_RISK"; then
    POLICY_DEC_REASON="risk_exceeds"; POLICY_DEC_ARG="${risk}>${POLICY_MAX_RISK}"
  elif policy__word_match "$POLICY_ALLOW" "$action"; then
    POLICY_DEC_LABEL="allow"; POLICY_DEC_REASON="allow_listed"
  fi
  return 0
}

# policy__reasons_json — POLICY_DEC_REASON から reasons 配列 JSON を作る
policy__reasons_json() {
  case "$POLICY_DEC_REASON" in
    allow_listed)        printf '%s' '["allow_listed"]' ;;
    default_deny)        printf '%s' '["default_deny"]' ;;
    unclassified_action) printf '%s' '["unclassified_action"]' ;;
    hard_deny)           printf '%s' '["hard_deny:承認でも解除しない"]' ;;
    unknown_agent)       printf '%s' '["unknown_agent"]' ;;
    schema_mismatch)     printf '%s' '["policy_schema_mismatch"]' ;;
    missing_args)        printf '%s' '["missing_agent_or_action"]' ;;
    *)
      jq -cn --arg k "$POLICY_DEC_REASON" --arg a "$POLICY_DEC_ARG" \
        'if $k=="agent_deny" then ["agent_deny:\($a)"]
         elif $k=="approval_required" then ["approval_required:\($a)"]
         else ["risk_exceeds_agent_max:\($a)"] end' ;;
  esac
}

# ------------------------------------------------------------
# 監査 / 署名 / トークン
# ------------------------------------------------------------
policy__key_file() { policy__prefetch; policy__expand "${POL_KEYFILE:-$CCSU_HOME/policy/identity.key}"; }
policy__audit_file() { policy__prefetch; policy__expand "${POL_AUDITFILE:-$CCSU_HOME/logs/policy-audit.jsonl}"; }
policy__iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
policy__now() { date +%s; }
policy__uuid() {
  if [[ -r /proc/sys/kernel/random/uuid ]]; then cat /proc/sys/kernel/random/uuid; else printf '%s-%s' "$$" "$RANDOM"; fi
}

policy__audit_append() { json_append_line "$(policy__audit_file)" "$1"; }

# policy__ct_eq <a> <b> — 定数時間比較 (長さ差でも早期 return しない)
policy__ct_eq() {
  local a="$1" b="$2" rc=0 i
  (( ${#a} == ${#b} )) || rc=1
  for (( i = 0; i < ${#a} && i < ${#b}; i++ )); do
    [[ "${a:i:1}" == "${b:i:1}" ]] || rc=1
  done
  return $rc
}

policy__b64u_encode() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
policy__b64u_decode() {
  local d pad
  d="$(printf '%s' "$1" | tr '_-' '/+')"
  pad=$(( (4 - ${#d} % 4) % 4 ))
  case "$pad" in
    1) d="${d}=" ;;
    2) d="${d}==" ;;
    3) d="${d}===" ;;
  esac
  printf '%s' "$d" | openssl base64 -d -A 2>/dev/null
}

policy__ensure_key() {
  local f; f="$(policy__key_file)"
  if [[ ! -f "$f" ]]; then
    mkdir -p "$(dirname "$f")" || return 1
    chmod 700 "$(dirname "$f")" 2>/dev/null || true
    openssl rand -base64 48 > "$f" || return 1
    chmod 600 "$f" || return 1
  fi
  chmod 600 "$f" 2>/dev/null || true
  [[ -s "$f" ]]
}

policy__hmac() {
  local data="$1" key
  policy__ensure_key || return 1
  key="$(cat "$(policy__key_file)")"
  printf '%s' "$data" | openssl dgst -sha256 -hmac "$key" -r | awk '{print $1}'
}

# ------------------------------------------------------------
# 公開 API
# ------------------------------------------------------------

# policy_decision <agent> <action> [--resource R] [--mode M] [--token T] [--json]
#   判定 JSON 1 件を stdout へ返す。理由は reasons[] に残す。
policy_decision() {
  local agent="${1:-}" action="${2:-}"; shift 2 || true
  local resource="" mode="normal" token=""
  while (( $# )); do
    case "$1" in
      --resource) resource="${2:-}"; shift 2 ;;
      --mode)     mode="${2:-}";     shift 2 ;;
      --token)    token="${2:-}";    shift 2 ;;
      --json)     shift ;;
      *) shift ;;
    esac
  done

  policy__prefetch
  local version="$POL_VERSION"
  local decision="deny" risk="unknown" max_risk="none" approver=""
  POLICY_DEC_LABEL="deny"; POLICY_DEC_REASON="default_deny"; POLICY_DEC_ARG=""

  if [[ -z "$agent" || -z "$action" ]]; then
    POLICY_DEC_REASON="missing_args"
  elif [[ "$POL_SCHEMA" != "$POLICY_SCHEMA" ]]; then
    POLICY_DEC_REASON="schema_mismatch"
  elif ! policy__agent_field "$agent"; then
    POLICY_DEC_REASON="unknown_agent"
  else
    max_risk="$POLICY_MAX_RISK"
    policy__decide_core "$action"
    decision="$POLICY_DEC_LABEL"
    policy__risk_lookup "$action"; risk="$POLICY_LAST"

    # 承認トークン提示: approval_required のみを allow へ昇格できる
    if [[ "$decision" == "approval_required" && -n "$token" ]]; then
      local v; v="$(policy_token_verify "$token" --quiet || true)"
      if [[ "$(printf '%s' "$v" | jq -r 'if has("valid") then (.valid|tostring) else "false" end')" == "true" ]]; then
        local issuer; issuer="$(printf '%s' "$v" | jq -r '.agent // ""')"
        if policy__word_match "$POL_APPROVERS" "$issuer"; then
          decision="allow"; approver="$issuer"
          POLICY_DEC_REASON="token_accepted"; POLICY_DEC_ARG="$issuer"
        else
          POLICY_DEC_REASON="token_non_approver"
        fi
      else
        POLICY_DEC_REASON="token_invalid"
      fi
    fi
  fi

  local reasons
  case "$POLICY_DEC_REASON" in
    token_accepted)     reasons="$(jq -cn --arg i "$POLICY_DEC_ARG" '["approval_token_accepted:\($i)"]')" ;;
    token_non_approver) reasons='["approval_token_from_non_approver"]' ;;
    token_invalid)      reasons='["approval_token_invalid"]' ;;
    *)                  reasons="$(policy__reasons_json)" ;;
  esac

  local out
  out="$(jq -cn --arg version "$version" --arg agent "$agent" --arg action "$action" \
    --arg resource "$resource" --arg mode "$mode" --arg decision "$decision" --arg risk "$risk" \
    --arg max_risk "$max_risk" --arg approver "$approver" --argjson reasons "$reasons" \
    --arg at "$(policy__iso)" --argjson epoch "$(policy__now)" --arg run_id "${CLAUDEOS_RUN_ID:-}" \
    --arg schema "$POLICY_SCHEMA" \
    '{schema:$schema, policy_version:$version, agent:$agent, action:$action, resource:$resource, mode:$mode,
      decision:$decision, risk:$risk, agent_max_risk:$max_risk, approver:$approver, reasons:$reasons,
      at:$at, epoch:$epoch, run_id:(if $run_id=="" then null else $run_id end)}')"

  # matrix (一括列挙) では監査を書かない。実行時の判断 (check) は必ず記録する。
  if [[ "${POLICY_NO_AUDIT:-0}" != "1" ]]; then
    policy__audit_append "$(printf '%s' "$out" | jq -c --arg pid "$$" '. + {pid:($pid|tonumber), event:"decision"}')"
  fi
  printf '%s\n' "$out"
}

# policy_check <agent> <action> [...] — 判定して終了コードを返す
#   0 allow / 1 deny / 3 approval_required
policy_check() {
  local out rc
  out="$(policy_decision "$@")" || return 1
  printf '%s\n' "$out"
  case "$(printf '%s' "$out" | jq -r '.decision')" in
    allow) rc=0 ;;
    approval_required) rc=3 ;;
    *) rc=1 ;;
  esac
  return $rc
}

# policy_token_issue <agent> [--ttl N] — 署名付き identity token を stdout へ返す
policy_token_issue() {
  local agent="${1:-}"; shift || true
  policy__prefetch
  local ttl="$POL_TTL"
  while (( $# )); do
    case "$1" in
      --ttl) ttl="${2:-900}"; shift 2 ;;
      *) shift ;;
    esac
  done
  policy__agent_exists "$agent" || { log_error "policy: 未知の agent: $agent"; return 1; }
  [[ "$ttl" =~ ^[0-9]+$ ]] || { log_error "policy: --ttl は秒数"; return 2; }

  local now expires payload b64 sig
  now="$(policy__now)"; expires=$(( now + ttl ))
  payload="$(jq -cn --arg schema "$POLICY_TOKEN_SCHEMA" --arg agent "$agent" \
    --argjson issued "$now" --argjson expires "$expires" --arg nonce "$(policy__uuid)" \
    '{schema:$schema, agent:$agent, issued:$issued, expires:$expires, nonce:$nonce}')"
  b64="$(printf '%s' "$payload" | policy__b64u_encode)"
  sig="$(policy__hmac "$b64")" || { log_error "policy: 署名鍵の準備に失敗"; return 1; }

  policy__audit_append "$(jq -cn --arg at "$(policy__iso)" --arg agent "$agent" --argjson expires "$expires" \
    '{at:$at, event:"identity_issue", agent:$agent, expires:$expires}')"
  printf '%s.%s\n' "$b64" "$sig"
}

# policy_token_verify <token> [--quiet] — {valid, agent, expires, reasons[]} を返す
policy_token_verify() {
  local token="${1:-}"; shift || true
  local quiet=0
  while (( $# )); do
    case "$1" in --quiet) quiet=1; shift ;; *) shift ;; esac
  done
  policy__prefetch
  local valid="false" agent="" expires=0 reasons='[]'
  if [[ -z "$token" || "$token" != *.* ]]; then
    reasons='["malformed_token"]'
  else
    local b64="${token%%.*}" sig="${token##*.}"
    local expect; expect="$(policy__hmac "$b64" || true)"
    if [[ -z "$expect" ]]; then
      reasons='["key_unavailable"]'
    elif ! policy__ct_eq "$expect" "$sig"; then
      reasons='["signature_mismatch"]'
    else
      local payload; payload="$(policy__b64u_decode "$b64" || true)"
      if [[ -z "$payload" ]] || ! printf '%s' "$payload" | jq -e . >/dev/null 2>&1; then
        reasons='["payload_unreadable"]'
      else
        agent="$(printf '%s' "$payload" | jq -r '.agent // ""')"
        expires="$(printf '%s' "$payload" | jq -r '.expires // 0')"
        local schema; schema="$(printf '%s' "$payload" | jq -r '.schema // ""')"
        local now; now="$(policy__now)"
        if [[ "$schema" != "$POLICY_TOKEN_SCHEMA" ]]; then
          reasons='["schema_mismatch"]'
        elif ! policy__agent_exists "$agent"; then
          reasons='["unknown_agent"]'
        elif (( expires <= now )); then
          reasons='["expired"]'
        else
          valid="true"; reasons='["ok"]'
        fi
      fi
    fi
  fi

  local out
  out="$(jq -cn --argjson valid "$valid" --arg agent "$agent" --argjson expires "$expires" --argjson reasons "$reasons" \
    '{valid:$valid, agent:$agent, expires:$expires, reasons:$reasons}')"
  if (( ! quiet )); then
    policy__audit_append "$(jq -c --arg at "$(policy__iso)" '. + {at:$at, event:"identity_verify"}' <<<"$out")"
  fi
  printf '%s\n' "$out"
  [[ "$valid" == "true" ]]
}

# policy_matrix [--json] — 全 agent × 主要 action の判定表 (承認トークン無しの素の判定)
policy_matrix() {
  local json_out=0
  while (( $# )); do
    case "$1" in --json) json_out=1; shift ;; *) shift ;; esac
  done
  local actions="read:file inspect:logs plan:task test:run edit:src pr:create pr:merge deploy:prod db:migrate systemd:restart cloudflare:tunnel secret:print secret:read main:push db:drop network:egress model:pull screen:capture"
  policy__prefetch
  local rows="" agent action line
  local saved_no_audit="${POLICY_NO_AUDIT:-0}"
  POLICY_NO_AUDIT=1
  while IFS= read -r line; do
    agent="${line%%$'\x1f'*}"
    [[ -n "$agent" ]] || continue
    policy__agent_field "$agent" || continue
    for action in $actions; do
      policy__decide_core "$action"
      rows="${rows}${agent}"$'\t'"${action}"$'\t'"${POLICY_DEC_LABEL}"$'\n'
    done
  done <<<"$POL_AGENTS"
  POLICY_NO_AUDIT="$saved_no_audit"

  if (( json_out )); then
    printf '%s' "$rows" | jq -R -s -c 'split("\n") | map(select(. != "") | split("\t") | {agent:.[0], action:.[1], decision:.[2]})'
  else
    printf '%s' "$rows"
  fi
}
