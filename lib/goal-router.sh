#!/usr/bin/env bash
# ============================================================
# goal-router.sh — 統合 Goal Router (ClaudeOS Execution Control Plane)
#
# 役割: Project 状態 (state.json) + Repository / Runtime Evidence + ユーザー意図から
#       Primary Goal (5 分類) と Specialized Goal (既存 goals/*.md) を決定し、
#       既存 goal-extract が解決できる 1 つの effective goal_type へ収束させる。
#
#   Router → Primary Goal → Specialized Goal → effective_goal_type → goal-extract
#
# 設計原則:
#   - 単一モジュール: L1 / S1 / T1 / cron / headless / Supervisor はすべてここを呼ぶ
#   - 後方互換: state.goal_type は削除しない。goal_router 情報が無くても従来どおり動く
#   - Fail-safe: Router が失敗しても起動を止めない (fallback 連鎖で必ず 1 つ返す)
#   - Flapping 防止: session lock。重大状態変化・ユーザー新指示時のみ reroute
#   - 権限非昇格: Routing 結果は Goal の選択であり Human Gate / permissions を変えない
#
# 主要 API:
#   goal_router__evidence <project_dir> [intent]   → key=value 行 (stdout)
#   goal_router__route  [--goal X] [--mode M] [--trigger T]  (evidence を stdin)
#                                                  → key=value 行 (primary/specialized/effective/...)
#   goal_router__resolve <project_dir> [--goal X] [--intent T] [--mode M]
#                        [--trigger T] [--no-persist] [--one-shot]
#                                                  → effective goal (stdout) + GOAL_ROUTER_* 変数
#   goal_router__persist <state_file>              → state.goal_router を原子的に更新
#
# 環境変数 (乱立させない。state.json が正本):
#   CLAUDEOS_GOAL_MODE            auto|manual   state.goal_router.mode 不在時の既定 (既定 auto)
#   CLAUDEOS_PRIMARY_GOAL         one-shot の Primary 指定 (状態を lock しない)
#   CLAUDEOS_SPECIALIZED_GOAL     one-shot の Specialized 指定
#   CLAUDEOS_GOAL_INTENT          ユーザー要求テキスト (--intent の代替)
#   CLAUDEOS_GOAL_LOCK_MINUTES    session lock の有効時間 (既定 720)
#   CLAUDEOS_GOAL_REROUTE=1       lock を無視して再判定 (explicit reroute)
#   CLAUDEOS_GOAL_ROUTER_GH=0     gh (PR / CI) Evidence 収集を無効化
#   CLAUDEOS_GOAL_ROUTER_RUNTIME=0 Runtime Evidence (state.runtime.health_url / error_log) を無効化
#   CLAUDEOS_GOAL_ROUTER_CF=0     Cloudflare Evidence (wrangler deployments) を無効化
#   CLAUDEOS_GOAL_INTENT_LLM      auto(既定)|1|0  キーワード表で判定不能な intent を claude -p (haiku) で分類。
#                                 auto は Claude Code セッション内 (CLAUDECODE=1) では呼ばない。1 で強制、0 で無効
#   CLAUDEOS_GOAL_INTENT_LLM_MODEL / _TIMEOUT   既定 haiku / 45 秒 (課金は headless と同じ subscription 経路)
#   CLAUDEOS_GOAL_RUNTIME_ERROR_THRESHOLD       error_log の直近 500 行中のエラー件数閾値 (既定 5)
#   CLAUDEOS_GOAL_ROUTER_DISABLE=1 Router を無効化 (従来 goal_type のみで動作)
# ============================================================

[[ -n "${_CCSU_GOAL_ROUTER_LOADED:-}" ]] && return 0
_CCSU_GOAL_ROUTER_LOADED=1

GOAL_ROUTER_VERSION=1
GOAL_ROUTER_PRIMARY_GOALS=(development mvp-release assessment deep-debug product-assurance)
GOAL_ROUTER_SPECIALIZED_GOALS=(production-release hotfix security-emergency refactoring safe-auto-merge pr-babysit)

# ------------------------------------------------------------
# 分類ヘルパ
# ------------------------------------------------------------
goal_router__is_primary() {
  local g; for g in "${GOAL_ROUTER_PRIMARY_GOALS[@]}"; do [[ "$1" == "$g" ]] && return 0; done; return 1
}
goal_router__is_specialized() {
  local g; for g in "${GOAL_ROUTER_SPECIALIZED_GOALS[@]}"; do [[ "$1" == "$g" ]] && return 0; done; return 1
}
goal_router__is_goal() { goal_router__is_primary "$1" || goal_router__is_specialized "$1"; }

# goal_router__primary_for <specialized> — Specialized 単独指定時の既定 Primary (§5 推奨マッピング)
goal_router__primary_for() {
  case "$1" in
    production-release) printf 'product-assurance' ;;
    hotfix)             printf 'deep-debug' ;;
    security-emergency) printf 'deep-debug' ;;
    refactoring)        printf 'development' ;;
    safe-auto-merge)    printf 'product-assurance' ;;
    pr-babysit)         printf 'product-assurance' ;;
    *)                  printf '' ;;
  esac
}

# goal_router__allows <primary> <specialized> — Primary 配下で許可される Specialized か
goal_router__allows() {
  local p="$1" s="$2"
  [[ -z "$s" || "$s" == "null" ]] && return 0
  case "$p:$s" in
    development:refactoring|development:hotfix) return 0 ;;
    mvp-release:production-release) return 0 ;;
    assessment:security-emergency) return 0 ;;
    deep-debug:hotfix|deep-debug:security-emergency) return 0 ;;
    product-assurance:production-release|product-assurance:safe-auto-merge|product-assurance:pr-babysit) return 0 ;;
    *) return 1 ;;
  esac
}

# goal_router__legacy_map <goal_type> — 従来 goal_type → "primary specialized"
goal_router__legacy_map() {
  case "$1" in
    development|mvp-release|assessment|deep-debug|product-assurance) printf '%s ' "$1" ;;
    production-release|hotfix|security-emergency|refactoring|safe-auto-merge|pr-babysit)
      printf '%s %s' "$(goal_router__primary_for "$1")" "$1" ;;
    *) printf ' ' ;;
  esac
}

# ------------------------------------------------------------
# 内部ユーティリティ
# ------------------------------------------------------------
_gr__sanitize() { printf '%s' "$1" | tr '\n\r\t' '   ' | cut -c1-500; }
_gr__now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
_gr__epoch_of() {   # ISO-8601 → epoch (失敗は 0)
  local v="$1"; [[ -z "$v" || "$v" == "null" ]] && { printf '0'; return 0; }
  date -d "$v" +%s 2>/dev/null || printf '0'
}
_gr__lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# ------------------------------------------------------------
# goal_router__evidence <project_dir> [intent]
#   state.json / git / CI / gh から Evidence を key=value 行で出力する。
#   収集失敗は個別に unknown/空とし、関数自体は常に 0 で返る (fail-safe)。
# ------------------------------------------------------------
goal_router__evidence() {
  local project_dir="$1" intent="${2:-${CLAUDEOS_GOAL_INTENT:-}}"
  local state_file="$project_dir/state.json"

  printf 'intent=%s\n' "$(_gr__sanitize "$intent")"

  # --- state.json (python3 優先、無ければ jq、両方無ければ state_present=0) ---
  if [[ -f "$state_file" ]] && command -v python3 >/dev/null 2>&1; then
    python3 - "$state_file" <<'PYEOF' 2>/dev/null || printf 'state_present=0\nstate_error=1\n'
import json, sys
f = sys.argv[1]
def s(v):
    if v is None: return ""
    if isinstance(v, bool): return "true" if v else "false"
    return str(v).replace("\n", " ").replace("\r", " ")[:300]
try:
    d = json.load(open(f))
    if not isinstance(d, dict): raise ValueError("state is not an object")
except Exception:
    print("state_present=0"); print("state_error=1"); sys.exit(0)
g = lambda *ks: (lambda o: [o := (o.get(k) if isinstance(o, dict) else None) for k in ks][-1])(d)
print("state_present=1")
pm = g("project", "phase_mode") or g("maintenance", "phase_mode") or ""
print("phase_mode=" + s(pm))
print("legacy_goal_type=" + s(d.get("goal_type")))
print("deploy_ready=" + s(g("deploy", "ready")))
print("exec_phase=" + s(g("execution", "phase")))
print("stable_achieved=" + s(g("stable", "stable_achieved")))
kpi = d.get("kpi") if isinstance(d.get("kpi"), dict) else {}
print("security_critical=" + s(kpi.get("security_critical")))
print("blocker_count=" + s(kpi.get("blocker_count")))
print("ci_success_rate=" + s(kpi.get("ci_success_rate")))
bi = d.get("blocked_issues"); print("blocked_issues=" + (str(len(bi)) if isinstance(bi, list) else ""))
print("last_summary=" + s(g("execution", "last_session_summary"))[:200])
print("deploy_executed=" + ("true" if g("deploy", "executed_at") else ""))
gr = d.get("goal_router") if isinstance(d.get("goal_router"), dict) else {}
for k in ("mode", "primary_goal", "specialized_goal", "locked_by_user", "session_locked", "last_routed_at", "reason"):
    print("prev_" + k + "=" + s(gr.get(k)))
snap = gr.get("evidence_snapshot") if isinstance(gr.get("evidence_snapshot"), dict) else {}
for k in ("deploy_ready", "phase_mode", "security_critical", "ci", "runtime_health"):
    print("prev_snap_" + k + "=" + s(snap.get(k)))
PYEOF
  elif [[ -f "$state_file" ]] && command -v jq >/dev/null 2>&1 && jq -e . "$state_file" >/dev/null 2>&1; then
    printf 'state_present=1\n'
    printf 'phase_mode=%s\n' "$(jq -r '(.project.phase_mode // .maintenance.phase_mode // "")' "$state_file")"
    printf 'legacy_goal_type=%s\n' "$(jq -r '.goal_type // ""' "$state_file")"
    printf 'deploy_ready=%s\n' "$(jq -r '.deploy.ready // ""' "$state_file")"
    printf 'exec_phase=%s\n' "$(jq -r '.execution.phase // ""' "$state_file")"
    printf 'stable_achieved=%s\n' "$(jq -r '.stable.stable_achieved // ""' "$state_file")"
    printf 'security_critical=%s\n' "$(jq -r '.kpi.security_critical // ""' "$state_file")"
    printf 'blocker_count=%s\n' "$(jq -r '.kpi.blocker_count // ""' "$state_file")"
    printf 'prev_mode=%s\n' "$(jq -r '.goal_router.mode // ""' "$state_file")"
    printf 'prev_primary_goal=%s\n' "$(jq -r '.goal_router.primary_goal // ""' "$state_file")"
    printf 'prev_specialized_goal=%s\n' "$(jq -r '.goal_router.specialized_goal // ""' "$state_file")"
    printf 'prev_locked_by_user=%s\n' "$(jq -r '.goal_router.locked_by_user // ""' "$state_file")"
    printf 'prev_session_locked=%s\n' "$(jq -r '.goal_router.session_locked // ""' "$state_file")"
    printf 'prev_last_routed_at=%s\n' "$(jq -r '.goal_router.last_routed_at // ""' "$state_file")"
  else
    printf 'state_present=0\n'
  fi

  # --- git (ローカル。ネットワーク不要) ---
  if [[ -d "$project_dir/.git" ]] && command -v git >/dev/null 2>&1; then
    printf 'git_repo=1\n'
    printf 'git_branch=%s\n' "$(git -C "$project_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || printf '')"
    printf 'git_dirty=%s\n' "$(git -C "$project_dir" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
    local n; n="$(git -C "$project_dir" rev-list --count --max-count=50 HEAD 2>/dev/null || printf '0')"
    printf 'git_commits=%s\n' "${n:-0}"
  else
    printf 'git_repo=0\n'
  fi
  [[ -d "$project_dir/.github/workflows" ]] && printf 'has_ci=1\n' || printf 'has_ci=0\n'
  if [[ -d "$project_dir/tests" || -d "$project_dir/test" || -d "$project_dir/__tests__" || -d "$project_dir/spec" ]]; then
    printf 'has_tests=1\n'
  else
    printf 'has_tests=0\n'
  fi

  # --- gh (任意。無効化: CLAUDEOS_GOAL_ROUTER_GH=0。timeout 付き、失敗は unknown) ---
  local ci="unknown" prs=""
  if [[ "${CLAUDEOS_GOAL_ROUTER_GH:-1}" != "0" ]] && command -v gh >/dev/null 2>&1 \
       && [[ -d "$project_dir/.git" ]] && git -C "$project_dir" remote get-url origin >/dev/null 2>&1; then
    local _t=(); command -v timeout >/dev/null 2>&1 && _t=(timeout 8)
    prs="$("${_t[@]}" gh pr list --state open --json number --jq 'length' -R "$(git -C "$project_dir" remote get-url origin 2>/dev/null)" 2>/dev/null || printf '')"
    local conc
    conc="$(cd "$project_dir" && "${_t[@]}" gh run list --limit 1 --json conclusion,status --jq '.[0] | if .status != "completed" then "running" else (.conclusion // "unknown") end' 2>/dev/null || printf '')"
    [[ -n "$conc" ]] && ci="$conc"
  fi
  printf 'pr_open=%s\n' "$prs"
  printf 'ci=%s\n' "$ci"

  # --- Runtime Evidence (state.runtime.* が設定されている Project のみ。失敗は unknown) ---
  goal_router__runtime_evidence "$state_file"

  # --- LLM intent (キーワード表で判定不能なときだけ。外部呼び出しは evidence 側に閉じ込め、route は純粋関数のまま) ---
  if [[ -n "$intent" ]] && [[ -z "$(goal_router__intent_class "$intent")" ]]; then
    printf 'intent_llm=%s\n' "$(goal_router__intent_llm "$intent")"
  else
    printf 'intent_llm=\n'
  fi
  return 0
}

# ------------------------------------------------------------
# goal_router__runtime_evidence <state_file>
#   state.runtime.health_url  → runtime_health=ok|down|unknown   (curl、timeout 5s)
#   state.runtime.error_log   → runtime_errors=<直近 500 行のエラー件数>
#   state.runtime.cloudflare.{project|worker} → cf_deploy=success|failure|none|unknown (wrangler --json、timeout 15s)
#   設定が無ければ unknown / 空。CLAUDEOS_GOAL_ROUTER_RUNTIME=0 / _CF=0 で無効化。常に 0。
# ------------------------------------------------------------
goal_router__runtime_evidence() {
  local state_file="$1" url="" elog="" cfp="" cfw="" health="unknown" errors="" cf="unknown"
  if [[ -f "$state_file" ]] && command -v python3 >/dev/null 2>&1; then
    local line k v
    while IFS= read -r line; do
      k="${line%%=*}"; v="${line#*=}"
      case "$k" in
        rt_health_url) url="$v" ;; rt_error_log) elog="$v" ;; rt_cf_project) cfp="$v" ;; rt_cf_worker) cfw="$v" ;;
      esac
    done < <(python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1])); rt = d.get("runtime") or {}
    if not isinstance(rt, dict): rt = {}
    cf = rt.get("cloudflare") if isinstance(rt.get("cloudflare"), dict) else {}
    for k, v in (("rt_health_url", rt.get("health_url")), ("rt_error_log", rt.get("error_log")),
                 ("rt_cf_project", cf.get("project")), ("rt_cf_worker", cf.get("worker"))):
        print(f"{k}={chr(39)[:0] if v is None else str(v).strip()}")
except Exception:
    pass' "$state_file" 2>/dev/null || true)
  fi
  if [[ "${CLAUDEOS_GOAL_ROUTER_RUNTIME:-1}" != "0" ]]; then
    if [[ -n "$url" && "$url" =~ ^https?:// ]] && command -v curl >/dev/null 2>&1; then
      local code
      code="$(curl -s -o /dev/null -w '%{http_code}' -m "${CLAUDEOS_GOAL_HEALTH_TIMEOUT:-5}" "$url" 2>/dev/null || printf '000')"
      if [[ "$code" =~ ^[23][0-9][0-9]$ ]]; then health="ok"; else health="down"; fi
    fi
    if [[ -n "$elog" ]]; then
      elog="${elog/#\~/$HOME}"
      if [[ -f "$elog" ]]; then
        errors="$(tail -n 500 "$elog" 2>/dev/null | grep -cE 'ERROR|FATAL|Traceback|panic:|Unhandled|CRITICAL' || true)"
        [[ "$errors" =~ ^[0-9]+$ ]] || errors=0
      fi
    fi
  fi
  if [[ "${CLAUDEOS_GOAL_ROUTER_CF:-1}" != "0" ]] && command -v wrangler >/dev/null 2>&1 && [[ -n "$cfp" || -n "$cfw" ]]; then
    local -a _t=(); command -v timeout >/dev/null 2>&1 && _t=(timeout 15)
    if [[ -n "$cfp" ]]; then
      # Cloudflare Pages: 直近の production deployment の latest_stage.status (wrangler 4.x: --project-name / --environment / --json を実機 help で確認)
      cf="$("${_t[@]}" wrangler pages deployment list --project-name "$cfp" --environment production --json 2>/dev/null \
            | python3 -c '
import json, sys
try:
    arr = json.load(sys.stdin)
    if not isinstance(arr, list) or not arr: print("none"); sys.exit(0)
    st = str(((arr[0].get("latest_stage") or {}).get("status") or "")).lower()
    print(st if st in ("success", "failure") else ("failure" if "fail" in st else (st or "unknown")))
except Exception:
    print("unknown")' 2>/dev/null || printf 'unknown')"
      [[ -n "$cf" ]] || cf="unknown"
    else
      # Cloudflare Workers: deployments を列挙できれば success (一覧に status フィールドが無いため存在確認のみ)
      if "${_t[@]}" wrangler deployments list --name "$cfw" --json >/dev/null 2>&1; then cf="success"; else cf="failure"; fi
    fi
  fi
  local has=0; [[ -n "$url" || -n "$elog" || -n "$cfp" || -n "$cfw" ]] && has=1
  printf 'runtime_health=%s\n' "$health"
  printf 'runtime_errors=%s\n' "$errors"
  printf 'cf_deploy=%s\n' "$cf"
  printf 'has_runtime=%s\n' "$has"
  return 0
}

# ------------------------------------------------------------
# goal_router__intent_llm <intent>  → "primary [specialized]" (判定不能・無効・失敗は空)
#   claude -p (haiku、--output-format json、--bare) でラベル 1 語を得る。キーワード表の補完用。
#   - CLAUDEOS_GOAL_INTENT_LLM=0 で無効、1 で強制、auto (既定) は Claude Code セッション内では呼ばない
#     (ネスト起動を避ける)。timeout 付き、出力はホワイトリストで検証し不正値は捨てる (fail-safe)。
#   - 課金経路は headless と同じ: 既定 subscription (env -u ANTHROPIC_API_KEY)。CLAUDEOS_HEADLESS_AUTH=api-key で鍵を保持。
# ------------------------------------------------------------
goal_router__intent_llm() {
  local intent="$1" mode="${CLAUDEOS_GOAL_INTENT_LLM:-auto}"
  [[ -n "$intent" ]] || return 0
  [[ "$mode" == "0" ]] && return 0
  [[ "$mode" == "auto" && -n "${CLAUDECODE:-}" ]] && return 0
  command -v claude >/dev/null 2>&1 || return 0
  local help; help="$(claude --help 2>/dev/null || true)"
  local prompt
  prompt="You are the ClaudeOS Goal Router. Classify the user's request into exactly one label.
Primary labels: development (feature/improvement of an existing product), mvp-release (new project / prototype / PoC / MVP),
assessment (evaluate / review / audit / compare / readiness), deep-debug (bug / CI failure / error / regression / outage root cause),
product-assurance (release readiness QA: golden tests, contract, recovery, security, performance, accessibility).
Optional specialized suffix after a slash: hotfix, security-emergency, refactoring, production-release, safe-auto-merge, pr-babysit.
Reply with the label only (e.g. deep-debug/hotfix or development). If unclear reply: none.

Request: $(_gr__sanitize "$intent")"
  local -a cmd=( claude -p "$prompt" --model "${CLAUDEOS_GOAL_INTENT_LLM_MODEL:-haiku}" --output-format json )
  [[ "$help" == *"--bare"* ]] && cmd+=( --bare )
  [[ "$help" == *"--no-session-persistence"* ]] && cmd+=( --no-session-persistence )
  local -a pre=( env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT )
  [[ "${CLAUDEOS_HEADLESS_AUTH:-subscription}" != "api-key" ]] && pre+=( -u ANTHROPIC_API_KEY )
  local -a _t=(); command -v timeout >/dev/null 2>&1 && _t=( timeout "${CLAUDEOS_GOAL_INTENT_LLM_TIMEOUT:-45}" )
  local raw label
  raw="$("${_t[@]}" "${pre[@]}" "${cmd[@]}" 2>/dev/null || printf '')"
  [[ -n "$raw" ]] || return 0
  label="$(printf '%s' "$raw" | python3 -c '
import json, sys, re
raw = sys.stdin.read(); txt = ""
try:
    d = json.loads(raw)
    if isinstance(d, dict): txt = str(d.get("result") or "")
    elif isinstance(d, list):
        for it in d:
            if isinstance(it, dict) and it.get("type") == "result": txt = str(it.get("result") or "")
except Exception:
    txt = raw
m = re.findall(r"[a-z][a-z-]+(?:/[a-z][a-z-]+)?", txt.strip().lower())
print(m[-1] if m else "")' 2>/dev/null || printf '')"
  [[ -n "$label" && "$label" != "none" ]] || return 0
  local p="${label%%/*}" s=""; [[ "$label" == */* ]] && s="${label#*/}"
  if goal_router__is_primary "$p"; then
    if [[ -n "$s" ]] && goal_router__is_specialized "$s" && goal_router__allows "$p" "$s"; then printf '%s %s' "$p" "$s"; else printf '%s' "$p"; fi
  elif goal_router__is_specialized "$p"; then
    printf '%s %s' "$(goal_router__primary_for "$p")" "$p"
  fi
  return 0
}

# ------------------------------------------------------------
# goal_router__intent_class <intent>  → primary [specialized] (空=判定不能)
#   §6.1 のキーワード表。複数一致時は §7 優先順位で決める。
# ------------------------------------------------------------
goal_router__intent_class() {
  local t; t="$(_gr__lc "$1")"
  [[ -z "$t" ]] && return 0
  local sec=0 dbg=0 pa=0 asm=0 mvp=0 dev=0 hot=0 ref=0 rel=0 mrg=0 baby=0
  [[ "$t" =~ (脆弱|セキュリティ|security|cve|漏洩|exploit|侵害) ]] && sec=1
  [[ "$t" =~ (直して|直す|修正|バグ|bug|ci ?失敗|ci ?failure|failing|failure|error|エラー|regression|回帰|障害|debug|デバッグ|動かない|落ちる|不具合|500|crash) ]] && dbg=1
  [[ "$t" =~ (hotfix|ホットフィックス|緊急修正|緊急対応|本番障害) ]] && hot=1
  [[ "$t" =~ (総合テスト|品質保証|リリース判定|release ?判定|assurance|受入テスト|golden|fail-?safe|contract ?test|recovery ?test|chaos) ]] && pa=1
  [[ "$t" =~ (評価|全体確認|レビュー|review|監査|audit|比較|readiness|gap ?分析|技術的負債の?評価|assess) ]] && asm=1
  [[ "$t" =~ (mvp|poc|prototype|プロトタイプ|最小版|最小限|新規プロジェクト|新規開発|0 ?から|ゼロから|立ち上げ) ]] && mvp=1
  [[ "$t" =~ (作って|作成|実装|改善|機能追加|追加して|開発|develop|feature|enhance|ui/ux|api ?改善|運用改善) ]] && dev=1
  [[ "$t" =~ (リファクタ|refactor|技術的負債|技術負債|tech ?debt|cleanup) ]] && ref=1
  [[ "$t" =~ (本番リリース|production ?release|デプロイ準備|release ?candidate|リリース準備|署名|signoff|deploy\.ready) ]] && rel=1
  [[ "$t" =~ (auto-?merge|自動マージ|マージして|merge) ]] && mrg=1
  [[ "$t" =~ (babysit|番人|pr ?監視|ci ?の?面倒) ]] && baby=1

  # §7 優先順位: security-emergency > deep-debug > hotfix > product-assurance > production-release > assessment > mvp-release > development
  if (( sec && (dbg || hot || asm) )); then printf 'deep-debug security-emergency'; return 0; fi
  if (( sec )); then printf 'assessment security-emergency'; return 0; fi
  if (( hot )); then printf 'deep-debug hotfix'; return 0; fi
  if (( dbg )); then printf 'deep-debug'; return 0; fi
  if (( baby )); then printf 'product-assurance pr-babysit'; return 0; fi
  if (( mrg )); then printf 'product-assurance safe-auto-merge'; return 0; fi
  if (( pa )); then printf 'product-assurance'; return 0; fi
  if (( rel )); then printf 'product-assurance production-release'; return 0; fi
  if (( asm )); then printf 'assessment'; return 0; fi
  if (( ref )); then printf 'development refactoring'; return 0; fi
  if (( mvp )); then printf 'mvp-release'; return 0; fi
  if (( dev )); then printf 'development'; return 0; fi
  return 0
}

# ------------------------------------------------------------
# goal_router__route [--goal X] [--mode auto|manual] [--trigger T] [--lock-minutes N]
#   Evidence (key=value 行) を stdin から読み、判定結果を key=value 行で出力する。
#   純粋関数 (副作用なし)。常に 0 を返す。
#   出力: primary / specialized / effective / confidence / reason / evidence / transition /
#         mode / locked_by_user / session_locked / fallback
# ------------------------------------------------------------
goal_router__route() {
  local explicit="" mode="" trigger="auto" lock_min="${CLAUDEOS_GOAL_LOCK_MINUTES:-720}"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --goal) explicit="${2:-}"; shift 2 ;;
      --mode) mode="${2:-}"; shift 2 ;;
      --trigger) trigger="${2:-auto}"; shift 2 ;;
      --lock-minutes) lock_min="${2:-720}"; shift 2 ;;
      *) shift ;;
    esac
  done
  [[ "$lock_min" =~ ^[0-9]+$ ]] || lock_min=720

  # Evidence を連想配列へ
  local -A ev=()
  local line k v
  while IFS= read -r line; do
    [[ "$line" == *=* ]] || continue
    k="${line%%=*}"; v="${line#*=}"
    [[ "$k" =~ ^[A-Za-z0-9_]+$ ]] || continue
    ev["$k"]="$v"
  done

  local primary="" specialized="" confidence="0.50" reason="" transition="new" fallback=0
  local -a used=()
  local sec="${ev[security_critical]:-}"; [[ "$sec" =~ ^[0-9]+$ ]] || sec=0
  local ci="${ev[ci]:-unknown}" pm="${ev[phase_mode]:-}" intent="${ev[intent]:-}"
  local blocked="${ev[blocked_issues]:-}"; [[ "$blocked" =~ ^[0-9]+$ ]] || blocked=0
  local blockers="${ev[blocker_count]:-}"; [[ "$blockers" =~ ^[0-9]+$ ]] || blockers=0
  local rate="${ev[ci_success_rate]:-}"
  local rt_health="${ev[runtime_health]:-unknown}" cf="${ev[cf_deploy]:-unknown}"
  local rt_errors="${ev[runtime_errors]:-}"; [[ "$rt_errors" =~ ^[0-9]+$ ]] || rt_errors=0
  local rt_threshold="${CLAUDEOS_GOAL_RUNTIME_ERROR_THRESHOLD:-5}"; [[ "$rt_threshold" =~ ^[0-9]+$ ]] || rt_threshold=5
  local in_prod=0; [[ "$pm" == "maintenance" || "$pm" == "released" || "${ev[deploy_executed]:-}" == "true" ]] && in_prod=1
  local ci_bad=0
  [[ "$ci" == "failure" ]] && ci_bad=1
  if [[ "$ci" == "unknown" && "$rate" =~ ^0?\.[0-9]+$ ]] && awk "BEGIN{exit (${rate} < 0.5) ? 0 : 1}" 2>/dev/null; then ci_bad=1; fi

  # モード決定: 引数 > 前回 state > 環境 > auto
  [[ -z "$mode" ]] && mode="${ev[prev_mode]:-}"
  [[ -z "$mode" || "$mode" == "null" ]] && mode="${CLAUDEOS_GOAL_MODE:-auto}"
  [[ "$mode" == "auto" || "$mode" == "manual" ]] || mode="auto"

  local locked_by_user="${ev[prev_locked_by_user]:-false}"
  [[ "$locked_by_user" == "true" ]] || locked_by_user=false

  # ---- 1) explicit (引数 / one-shot env / manual lock) ----
  local one_shot=0 unlock=0
  if [[ -z "$explicit" && -n "${CLAUDEOS_PRIMARY_GOAL:-}" ]]; then
    explicit="$CLAUDEOS_PRIMARY_GOAL"; one_shot=1
  fi
  if [[ "$explicit" == "auto" ]]; then
    # --goal auto: manual lock / session lock を解除して Evidence から再判定 (explicit reroute)
    mode="auto"; locked_by_user=false; explicit=""; transition="unlocked"; unlock=1
  fi
  if [[ -z "$explicit" && "$mode" == "manual" && -n "${ev[prev_primary_goal]:-}" ]]; then
    explicit="${ev[prev_primary_goal]}"; locked_by_user=true
    [[ -n "${ev[prev_specialized_goal]:-}" && "${ev[prev_specialized_goal]}" != "null" ]] && specialized="${ev[prev_specialized_goal]}"
  fi

  if [[ -n "$explicit" ]]; then
    if goal_router__is_primary "$explicit"; then
      primary="$explicit"
    elif goal_router__is_specialized "$explicit"; then
      specialized="$explicit"; primary="$(goal_router__primary_for "$explicit")"
    else
      # 未知名: fail-safe で auto へ降格 (起動は止めない)
      used+=("explicit_unknown:$explicit"); explicit=""
    fi
  fi
  if [[ -n "$explicit" ]]; then
    local sp="${CLAUDEOS_SPECIALIZED_GOAL:-}"
    if [[ -n "$sp" ]] && goal_router__is_specialized "$sp" && goal_router__allows "$primary" "$sp"; then specialized="$sp"; fi
    confidence="1.00"; reason="explicit:$explicit"; used+=("explicit:$explicit")
    (( one_shot )) && reason="explicit-one-shot:$explicit"
    [[ "$locked_by_user" == "true" && "$trigger" != "user" ]] && reason="manual-lock:$explicit"
    # Security Critical は明示指定より優先 (§7)
    if (( sec > 0 )) && [[ "$specialized" != "security-emergency" ]]; then
      if goal_router__allows "$primary" security-emergency; then :; else primary="deep-debug"; fi
      specialized="security-emergency"; reason="security-critical-override:$explicit"; confidence="0.95"
      used+=("security_critical:$sec")
    fi
  else
    # ---- 2) auto routing (§7 優先順位) ----
    if (( sec > 0 )); then
      primary="deep-debug"; specialized="security-emergency"; confidence="0.95"
      reason="security-critical"; used+=("security_critical:$sec")
    elif [[ "$rt_health" == "down" ]]; then
      # Runtime incident (health check 失敗) は CI 失敗より優先。本番運用中なら hotfix で範囲を狭める
      primary="deep-debug"; confidence="0.90"; reason="runtime-incident (health check down)"; used+=("runtime_health:down")
      (( in_prod )) && { specialized="hotfix"; used+=("in_production:true"); }
    elif (( ci_bad )); then
      primary="deep-debug"; confidence="0.85"; reason="ci-failure"; used+=("ci:$ci")
      [[ "$pm" == "maintenance" || "$pm" == "released" ]] && { specialized="hotfix"; used+=("phase_mode:$pm"); }
    elif [[ "$cf" == "failure" ]]; then
      primary="deep-debug"; confidence="0.80"; reason="cloudflare-deploy-failure"; used+=("cf_deploy:failure")
    else
      local ic; ic="$(goal_router__intent_class "$intent")"
      local il="${ev[intent_llm]:-}"
      if [[ -n "$ic" ]]; then
        primary="${ic%% *}"; specialized="${ic#* }"; [[ "$specialized" == "$primary" ]] && specialized=""
        confidence="0.80"; reason="user-intent:$primary${specialized:+/$specialized}"; used+=("user_intent:$primary")
      elif [[ -n "$il" ]] && goal_router__is_primary "${il%% *}"; then
        primary="${il%% *}"; specialized="${il#* }"; [[ "$specialized" == "$primary" ]] && specialized=""
        confidence="0.70"; reason="user-intent-llm:$primary${specialized:+/$specialized}"; used+=("user_intent_llm:$primary")
      elif (( rt_errors >= rt_threshold )); then
        primary="deep-debug"; confidence="0.75"; reason="runtime errors in log ($rt_errors >= $rt_threshold)"; used+=("runtime_errors:$rt_errors")
        (( in_prod )) && specialized="hotfix"
      elif [[ "${ev[deploy_ready]:-}" == "true" ]]; then
        primary="product-assurance"; specialized="production-release"; confidence="0.80"
        reason="deploy.ready=true (human signoff wait)"; used+=("deploy_ready:true")
      elif [[ "${ev[exec_phase]:-}" == "Release" ]]; then
        primary="product-assurance"; specialized="production-release"; confidence="0.75"
        reason="execution.phase=Release"; used+=("exec_phase:Release")
      elif (( blocked > 0 || blockers > 0 )) && [[ "$pm" == "maintenance" || "$pm" == "released" ]]; then
        primary="deep-debug"; specialized="hotfix"; confidence="0.70"
        reason="blocker in maintenance"; used+=("blocked_issues:$blocked" "phase_mode:$pm")
      elif [[ "${ev[stable_achieved]:-}" == "true" && "$pm" == "development" ]]; then
        primary="product-assurance"; confidence="0.70"; reason="stable achieved → release assurance"
        used+=("stable_achieved:true" "phase_mode:development")
      elif [[ "$pm" == "maintenance" || "$pm" == "released" ]]; then
        primary="development"; confidence="0.70"; reason="phase_mode=$pm (continuous improvement)"; used+=("phase_mode:$pm")
      elif [[ -n "${ev[legacy_goal_type]:-}" ]] && goal_router__is_goal "${ev[legacy_goal_type]}"; then
        local lm; lm="$(goal_router__legacy_map "${ev[legacy_goal_type]}")"
        primary="${lm%% *}"; specialized="${lm#* }"; [[ "$specialized" == "$primary" ]] && specialized=""
        confidence="0.60"; reason="legacy goal_type=${ev[legacy_goal_type]}"; used+=("legacy_goal_type:${ev[legacy_goal_type]}")
      elif [[ "${ev[state_present]:-0}" == "0" ]] || [[ "${ev[has_ci]:-0}" == "0" && "${ev[has_tests]:-0}" == "0" ]] \
             || { [[ "${ev[git_commits]:-0}" =~ ^[0-9]+$ ]] && (( ${ev[git_commits]:-0} <= 5 )); }; then
        primary="mvp-release"; confidence="0.55"; reason="new/early project (no state, ci, tests or few commits)"
        used+=("has_ci:${ev[has_ci]:-0}" "has_tests:${ev[has_tests]:-0}" "git_commits:${ev[git_commits]:-0}")
      else
        primary="development"; confidence="0.50"; reason="default (existing project, no stronger evidence)"
        used+=("phase_mode:${pm:-unknown}" "ci:$ci")
      fi
    fi
    [[ "$ci" == "success" ]] && used+=("ci:success")
  fi

  # ---- 3) Flapping 防止: session lock ----
  local prev_p="${ev[prev_primary_goal]:-}" prev_s="${ev[prev_specialized_goal]:-}"
  [[ "$prev_s" == "null" ]] && prev_s=""
  local session_locked=true
  if [[ -z "$explicit" && -n "$prev_p" ]] && goal_router__is_primary "$prev_p" && (( ! unlock )) \
       && [[ "${ev[prev_session_locked]:-}" == "true" ]] && [[ "${CLAUDEOS_GOAL_REROUTE:-0}" != "1" ]]; then
    local prev_epoch now_epoch age_min critical=0
    prev_epoch="$(_gr__epoch_of "${ev[prev_last_routed_at]:-}")"; now_epoch="$(date +%s)"
    age_min=$(( (now_epoch - prev_epoch) / 60 )); (( prev_epoch == 0 )) && age_min=$(( lock_min + 1 ))
    # 重大変化 = reroute 条件 (§17): Security / major CI failure / deploy.ready / phase_mode 変化 / 新指示 / 明示 reroute
    (( sec > 0 )) && [[ "${ev[prev_snap_security_critical]:-0}" == "0" || -z "${ev[prev_snap_security_critical]:-}" ]] && critical=1
    (( ci_bad )) && [[ "${ev[prev_snap_ci]:-}" != "failure" ]] && critical=1
    [[ "$rt_health" == "down" && "${ev[prev_snap_runtime_health]:-}" != "down" ]] && critical=1
    [[ -n "${ev[prev_snap_deploy_ready]:-}" && "${ev[prev_snap_deploy_ready]}" != "${ev[deploy_ready]:-}" ]] && critical=1
    [[ -n "${ev[prev_snap_phase_mode]:-}" && "${ev[prev_snap_phase_mode]}" != "$pm" ]] && critical=1
    [[ -n "$intent" ]] && critical=1
    [[ "$trigger" == "user" || "$trigger" == "reroute" || "$trigger" == "goal-reached" ]] && critical=1
    if (( ! critical )) && (( age_min <= lock_min )); then
      if [[ "$prev_p" != "$primary" || "$prev_s" != "$specialized" ]]; then
        reason="locked:kept $prev_p${prev_s:+/$prev_s} (candidate $primary${specialized:+/$specialized}: $reason)"
        primary="$prev_p"; specialized="$prev_s"; confidence="${confidence}"
        used+=("session_lock:${age_min}m")
      fi
      transition="kept"
    elif (( critical )); then
      transition="reroute"
    else
      transition="lock-expired"
    fi
  fi
  [[ "$transition" == "new" && -n "$prev_p" ]] && transition="routed"
  [[ -n "$prev_p" && "$prev_p" == "$primary" && "$prev_s" == "$specialized" && "$transition" != "kept" && "$transition" != "unlocked" ]] && transition="unchanged"

  # ---- 4) 整合性 / fail-safe ----
  if ! goal_router__is_primary "$primary"; then
    fallback=1
    if [[ -n "${ev[legacy_goal_type]:-}" ]] && goal_router__is_goal "${ev[legacy_goal_type]}"; then
      local lm2; lm2="$(goal_router__legacy_map "${ev[legacy_goal_type]}")"; primary="${lm2%% *}"; specialized="${lm2#* }"
    elif [[ "$pm" == "maintenance" || "$pm" == "released" ]]; then primary="development"; specialized=""
    else primary="mvp-release"; specialized=""; fi
    [[ "$specialized" == "$primary" ]] && specialized=""
    reason="fallback:${reason:-router-error}"; confidence="0.30"
  fi
  if [[ -n "$specialized" ]] && ! goal_router__allows "$primary" "$specialized"; then
    used+=("specialized_rejected:$specialized"); specialized=""
  fi
  local effective="${specialized:-$primary}"
  local evidence_csv; evidence_csv="$(IFS=,; printf '%s' "${used[*]}")"

  printf 'primary=%s\n' "$primary"
  printf 'specialized=%s\n' "$specialized"
  printf 'effective=%s\n' "$effective"
  printf 'confidence=%s\n' "$confidence"
  printf 'reason=%s\n' "$reason"
  printf 'evidence=%s\n' "$evidence_csv"
  printf 'transition=%s\n' "$transition"
  printf 'mode=%s\n' "$mode"
  printf 'locked_by_user=%s\n' "$locked_by_user"
  printf 'session_locked=%s\n' "$session_locked"
  printf 'fallback=%s\n' "$fallback"
  printf 'snap_deploy_ready=%s\n' "${ev[deploy_ready]:-}"
  printf 'snap_phase_mode=%s\n' "$pm"
  printf 'snap_security_critical=%s\n' "$sec"
  printf 'snap_ci=%s\n' "$ci"
  printf 'snap_runtime_health=%s\n' "$rt_health"
  return 0
}

# ------------------------------------------------------------
# goal_router__persist <state_file>
#   GOAL_ROUTER_* を state.goal_router へ原子的に書き込む (他キーは不変)。
#   state.json 不在 / 壊れ / python3 不在は何もしない (fail-safe、常に 0)。
# ------------------------------------------------------------
goal_router__persist() {
  local state_file="$1"
  [[ -f "$state_file" ]] || return 0
  command -v python3 >/dev/null 2>&1 || return 0
  GR_PRIMARY="${GOAL_ROUTER_PRIMARY:-}" GR_SPECIALIZED="${GOAL_ROUTER_SPECIALIZED:-}" \
  GR_EFFECTIVE="${GOAL_ROUTER_EFFECTIVE:-}" GR_CONFIDENCE="${GOAL_ROUTER_CONFIDENCE:-0}" \
  GR_REASON="${GOAL_ROUTER_REASON:-}" GR_EVIDENCE="${GOAL_ROUTER_EVIDENCE:-}" \
  GR_MODE="${GOAL_ROUTER_MODE:-auto}" GR_LOCKED="${GOAL_ROUTER_LOCKED_BY_USER:-false}" \
  GR_SESSION_LOCKED="${GOAL_ROUTER_SESSION_LOCKED:-true}" GR_TRANSITION="${GOAL_ROUTER_TRANSITION:-}" \
  GR_TRIGGER="${GOAL_ROUTER_TRIGGER:-auto}" GR_VERSION="$GOAL_ROUTER_VERSION" GR_NOW="$(_gr__now_iso)" \
  GR_SNAP_DR="${GOAL_ROUTER_SNAP_DEPLOY_READY:-}" GR_SNAP_PM="${GOAL_ROUTER_SNAP_PHASE_MODE:-}" \
  GR_SNAP_SEC="${GOAL_ROUTER_SNAP_SECURITY_CRITICAL:-0}" GR_SNAP_CI="${GOAL_ROUTER_SNAP_CI:-unknown}" \
  GR_SNAP_RT="${GOAL_ROUTER_SNAP_RUNTIME_HEALTH:-unknown}" \
  python3 - "$state_file" <<'PYEOF' 2>/dev/null || true
import json, os, sys
f = sys.argv[1]; e = os.environ
try:
    with open(f) as fp: d = json.load(fp)
    if not isinstance(d, dict): sys.exit(0)
except Exception:
    sys.exit(0)
gr = d.get("goal_router") if isinstance(d.get("goal_router"), dict) else {}
prev_p = gr.get("primary_goal"); prev_s = gr.get("specialized_goal")
hist = gr.get("history") if isinstance(gr.get("history"), list) else []
if prev_p and (prev_p != e["GR_PRIMARY"] or (prev_s or None) != (e["GR_SPECIALIZED"] or None)):
    hist.append({"at": e["GR_NOW"], "from": f"{prev_p}{'/' + prev_s if prev_s else ''}",
                 "to": f"{e['GR_PRIMARY']}{'/' + e['GR_SPECIALIZED'] if e['GR_SPECIALIZED'] else ''}",
                 "reason": e["GR_REASON"][:200], "trigger": e["GR_TRIGGER"]})
    hist = hist[-10:]
try: conf = float(e["GR_CONFIDENCE"])
except ValueError: conf = 0.0
gr.update({
    "mode": e["GR_MODE"], "primary_goal": e["GR_PRIMARY"],
    "specialized_goal": e["GR_SPECIALIZED"] or None, "effective_goal_type": e["GR_EFFECTIVE"],
    "confidence": round(conf, 2), "reason": e["GR_REASON"][:300],
    "evidence": [x for x in e["GR_EVIDENCE"].split(",") if x][:20],
    "locked_by_user": e["GR_LOCKED"] == "true", "session_locked": e["GR_SESSION_LOCKED"] == "true",
    "route_version": int(e["GR_VERSION"]), "last_routed_at": e["GR_NOW"],
    "last_transition_reason": f"{e['GR_TRANSITION']}:{e['GR_TRIGGER']}",
    "evidence_snapshot": {"deploy_ready": e["GR_SNAP_DR"], "phase_mode": e["GR_SNAP_PM"],
                          "security_critical": e["GR_SNAP_SEC"], "ci": e["GR_SNAP_CI"],
                          "runtime_health": e["GR_SNAP_RT"]},
    "history": hist,
})
d["goal_router"] = gr
tmp = f + ".tmp.goalrouter"
with open(tmp, "w") as fp: json.dump(d, fp, ensure_ascii=False, indent=2)
os.replace(tmp, f)
PYEOF
  return 0
}

# ------------------------------------------------------------
# goal_router__resolve <project_dir> [--goal X] [--intent T] [--mode M] [--trigger T]
#                      [--no-persist] [--one-shot]
#   Evidence 収集 → 判定 → (persist) → effective goal を stdout。GOAL_ROUTER_* を設定。
#   --one-shot: cron 行の CLAUDEOS_GOAL_TYPE_OVERRIDE 等、そのセッション限りの指定。
#               state.goal_router へは記録するが session lock / user lock を立てない。
#   CLAUDEOS_GOAL_ROUTER_DISABLE=1: 従来 goal_type (不在は mvp-release) をそのまま返す。
#   常に 0 を返す (fail-safe)。
# ------------------------------------------------------------
goal_router__resolve() {
  local project_dir="$1"; shift
  local explicit="" intent="${CLAUDEOS_GOAL_INTENT:-}" mode="" trigger="auto" persist=1 one_shot=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --goal) explicit="${2:-}"; shift 2 ;;
      --intent) intent="${2:-}"; shift 2 ;;
      --mode) mode="${2:-}"; shift 2 ;;
      --trigger) trigger="${2:-auto}"; shift 2 ;;
      --no-persist) persist=0; shift ;;
      --one-shot) one_shot=1; shift ;;
      *) shift ;;
    esac
  done
  local state_file="$project_dir/state.json"

  if [[ "${CLAUDEOS_GOAL_ROUTER_DISABLE:-0}" == "1" ]]; then
    local legacy="mvp-release"
    if [[ -f "$state_file" ]] && command -v python3 >/dev/null 2>&1; then
      legacy="$(python3 -c "import json,sys
try: print(json.load(open(sys.argv[1])).get('goal_type') or 'mvp-release')
except Exception: print('mvp-release')" "$state_file" 2>/dev/null || printf 'mvp-release')"
    fi
    [[ -n "$explicit" && "$explicit" != "auto" ]] && legacy="$explicit"
    GOAL_ROUTER_PRIMARY="" GOAL_ROUTER_SPECIALIZED="" GOAL_ROUTER_EFFECTIVE="$legacy"
    GOAL_ROUTER_CONFIDENCE="0" GOAL_ROUTER_REASON="router-disabled" GOAL_ROUTER_MODE="disabled"
    printf '%s\n' "$legacy"; return 0
  fi

  local out
  out="$(goal_router__evidence "$project_dir" "$intent" | goal_router__route ${explicit:+--goal "$explicit"} ${mode:+--mode "$mode"} --trigger "$trigger" 2>/dev/null)" || out=""
  local line k v
  GOAL_ROUTER_PRIMARY="" GOAL_ROUTER_SPECIALIZED="" GOAL_ROUTER_EFFECTIVE="" GOAL_ROUTER_CONFIDENCE="0"
  GOAL_ROUTER_REASON="" GOAL_ROUTER_EVIDENCE="" GOAL_ROUTER_TRANSITION="" GOAL_ROUTER_MODE="auto"
  GOAL_ROUTER_LOCKED_BY_USER="false" GOAL_ROUTER_SESSION_LOCKED="true" GOAL_ROUTER_FALLBACK="0"
  GOAL_ROUTER_SNAP_DEPLOY_READY="" GOAL_ROUTER_SNAP_PHASE_MODE="" GOAL_ROUTER_SNAP_SECURITY_CRITICAL="0" GOAL_ROUTER_SNAP_CI="unknown"
  GOAL_ROUTER_SNAP_RUNTIME_HEALTH="unknown"
  while IFS= read -r line; do
    k="${line%%=*}"; v="${line#*=}"
    case "$k" in
      primary) GOAL_ROUTER_PRIMARY="$v" ;;
      specialized) GOAL_ROUTER_SPECIALIZED="$v" ;;
      effective) GOAL_ROUTER_EFFECTIVE="$v" ;;
      confidence) GOAL_ROUTER_CONFIDENCE="$v" ;;
      reason) GOAL_ROUTER_REASON="$v" ;;
      evidence) GOAL_ROUTER_EVIDENCE="$v" ;;
      transition) GOAL_ROUTER_TRANSITION="$v" ;;
      mode) GOAL_ROUTER_MODE="$v" ;;
      locked_by_user) GOAL_ROUTER_LOCKED_BY_USER="$v" ;;
      session_locked) GOAL_ROUTER_SESSION_LOCKED="$v" ;;
      fallback) GOAL_ROUTER_FALLBACK="$v" ;;
      snap_deploy_ready) GOAL_ROUTER_SNAP_DEPLOY_READY="$v" ;;
      snap_phase_mode) GOAL_ROUTER_SNAP_PHASE_MODE="$v" ;;
      snap_security_critical) GOAL_ROUTER_SNAP_SECURITY_CRITICAL="$v" ;;
      snap_ci) GOAL_ROUTER_SNAP_CI="$v" ;;
      snap_runtime_health) GOAL_ROUTER_SNAP_RUNTIME_HEALTH="$v" ;;
    esac
  done <<< "$out"

  # Router 自体の失敗 (出力なし) → fallback 連鎖 (§20)
  if ! goal_router__is_primary "$GOAL_ROUTER_PRIMARY"; then
    GOAL_ROUTER_FALLBACK=1; GOAL_ROUTER_CONFIDENCE="0.30"; GOAL_ROUTER_REASON="fallback:router-unavailable"
    if [[ -n "$explicit" ]] && goal_router__is_goal "$explicit"; then
      local lm; lm="$(goal_router__legacy_map "$explicit")"; GOAL_ROUTER_PRIMARY="${lm%% *}"; GOAL_ROUTER_SPECIALIZED="${lm#* }"
    else
      GOAL_ROUTER_PRIMARY="mvp-release"; GOAL_ROUTER_SPECIALIZED=""
    fi
    [[ "$GOAL_ROUTER_SPECIALIZED" == "$GOAL_ROUTER_PRIMARY" ]] && GOAL_ROUTER_SPECIALIZED=""
    GOAL_ROUTER_EFFECTIVE="${GOAL_ROUTER_SPECIALIZED:-$GOAL_ROUTER_PRIMARY}"
  fi

  # --goal (ユーザー明示) は manual lock、--one-shot は lock しない
  if [[ -n "$explicit" && "$explicit" != "auto" && "$one_shot" == "0" ]]; then
    GOAL_ROUTER_MODE="manual"; GOAL_ROUTER_LOCKED_BY_USER="true"
  elif (( one_shot )); then
    GOAL_ROUTER_SESSION_LOCKED="false"; GOAL_ROUTER_LOCKED_BY_USER="false"
  fi
  GOAL_ROUTER_TRIGGER="$trigger"
  export GOAL_ROUTER_PRIMARY GOAL_ROUTER_SPECIALIZED GOAL_ROUTER_EFFECTIVE GOAL_ROUTER_CONFIDENCE \
         GOAL_ROUTER_REASON GOAL_ROUTER_EVIDENCE GOAL_ROUTER_TRANSITION GOAL_ROUTER_MODE \
         GOAL_ROUTER_LOCKED_BY_USER GOAL_ROUTER_SESSION_LOCKED GOAL_ROUTER_FALLBACK GOAL_ROUTER_TRIGGER

  (( persist )) && goal_router__persist "$state_file"
  printf '%s\n' "$GOAL_ROUTER_EFFECTIVE"
  return 0
}

# goal_router__summary — 1 行サマリ (ログ / RESUME_HEADER 用)
goal_router__summary() {
  printf 'primary=%s specialized=%s effective=%s confidence=%s mode=%s transition=%s reason=%s' \
    "${GOAL_ROUTER_PRIMARY:-}" "${GOAL_ROUTER_SPECIALIZED:-none}" "${GOAL_ROUTER_EFFECTIVE:-}" \
    "${GOAL_ROUTER_CONFIDENCE:-0}" "${GOAL_ROUTER_MODE:-auto}" "${GOAL_ROUTER_TRANSITION:-}" "${GOAL_ROUTER_REASON:-}"
}

# goal_router__header — プロンプト先頭へ置く Router コンテキスト (500 字以内)
goal_router__header() {
  printf '[Goal Router] primary=%s specialized=%s effective_goal_type=%s confidence=%s mode=%s reason=%s\n' \
    "${GOAL_ROUTER_PRIMARY:-}" "${GOAL_ROUTER_SPECIALIZED:-none}" "${GOAL_ROUTER_EFFECTIVE:-}" \
    "${GOAL_ROUTER_CONFIDENCE:-0}" "${GOAL_ROUTER_MODE:-auto}" "$(_gr__sanitize "${GOAL_ROUTER_REASON:-}" | cut -c1-200)"
}
