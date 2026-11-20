#!/usr/bin/env bash
# ============================================================
# improver-gate.sh — Self-Improvement 昇格ゲート (fail-closed)
#
# 役割: 「実行履歴 → 改善提案 → 昇格」のうち、昇格の可否を機械的に判定する。
#       SELF_IMPROVEMENT_ARCHITECTURE.md §3 の 4 要件を実行可能なコードにする:
#
#       1. Repeated Evidence  : 同一 failure signature が min_evidence 回以上
#       2. Measurable          : 変更前後の eval 結果 (pass/fail) を必須にする
#       3. Regression Safety   : eval が pass でなければ昇格しない
#       4. Verification-First  : 昇格には改善者以外 (cto / security) の承認トークン必須
#
#       「1 回の失敗で永久ルールを追加しない」「自己改善結果を main へ直接反映しない」
#       (CLAUDE.md §5 / Approval PR) を、人間の注意力ではなくコードで守らせる。
#
# 証拠源: run-ledger の failures.jsonl (signature 単位) + 追加の --evidence-file
# 記録  : $CLAUDEOS_HOME/logs/improver-gate.jsonl / state/improver/<sig>.json
#
# 終了コード: 0 昇格可 / 1 拒否 / 2 引数エラー
#
# 注意: このファイルは「source される」ため set -euo pipefail を設定しない。
# ============================================================

[[ -n "${_CCSU_IMPROVER_GATE_LOADED:-}" ]] && return 0
_CCSU_IMPROVER_GATE_LOADED=1

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/json.sh"
source "$(dirname "${BASH_SOURCE[0]}")/run-ledger.sh"
source "$(dirname "${BASH_SOURCE[0]}")/policy-engine.sh"

IG_MIN_EVIDENCE="${CCSU_IMPROVER_MIN_EVIDENCE:-2}"
IG_EVAL_CMD="${CCSU_IMPROVER_EVAL_CMD:-npm test --silent}"
IG_EVAL_TIMEOUT="${CCSU_IMPROVER_EVAL_TIMEOUT:-900}"

ig__dir() { printf '%s' "${CCSU_IMPROVER_DIR:-$CCSU_HOME/logs/improver}"; }
ig__log_file() { printf '%s' "${CCSU_IMPROVER_LOG:-$CCSU_HOME/logs/improver-gate.jsonl}"; }
ig__state_file() { printf '%s/%s.json' "${CCSU_IMPROVER_STATE_DIR:-$CCSU_HOME/state/improver}" "$1"; }
ig__iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

ig__audit() {
  json_append_line "$(ig__log_file)" "$(printf '%s' "$1" | jq -c --arg at "$(ig__iso)" '. + {at:$at}')"
}

# ig_evidence_count <signature> [--evidence-file F]
#   run-ledger failures.jsonl + 追加証拠ファイルから同一 signature を数える。
ig_evidence_count() {
  local sig="${1:-}"; shift || true
  local extra=""
  while (( $# )); do
    case "$1" in
      --evidence-file) extra="${2:-}"; shift 2 ;;
      *) shift ;;
    esac
  done
  [[ -n "$sig" ]] || { printf '0'; return 0; }
  local total=0 f
  for f in "$(rl_failures_file)" "$extra"; do
    [[ -n "$f" && -f "$f" ]] || continue
    total=$(( total + $(jq -s --arg s "$sig" '[.[] | select(.signature==$s)] | length' "$f" 2>/dev/null || printf '0') ))
  done
  printf '%s' "$total"
}

# ig_distinct_signatures [--evidence-file F] — 証拠のある signature 一覧 (件数付き)
ig_distinct_signatures() {
  local extra=""
  while (( $# )); do
    case "$1" in
      --evidence-file) extra="${2:-}"; shift 2 ;;
      *) shift ;;
    esac
  done
  local f
  for f in "$(rl_failures_file)" "$extra"; do
    [[ -n "$f" && -f "$f" ]] || continue
    jq -s -c 'group_by(.signature) | map({signature: .[0].signature, count: length, sample_note: .[0].note, last_at: (map(.at) | max)})' "$f" 2>/dev/null || true
  done
}

# ig_evaluate <signature> [--min-evidence N] [--evidence-file F]
#   昇格に必要な条件のうち「証拠」だけを判定する (eval / 承認は promote 時に検証)。
ig_evaluate() {
  local sig="${1:-}"; shift || true
  local min="$IG_MIN_EVIDENCE" extra=""
  while (( $# )); do
    case "$1" in
      --min-evidence) min="${2:-$IG_MIN_EVIDENCE}"; shift 2 ;;
      --evidence-file) extra="${2:-}"; shift 2 ;;
      *) shift ;;
    esac
  done
  [[ -n "$sig" ]] || { log_error "improver-gate: signature が必要です"; return 2; }
  [[ "$min" =~ ^[0-9]+$ ]] || { log_error "improver-gate: --min-evidence は数値"; return 2; }

  local count; count="$(ig_evidence_count "$sig" --evidence-file "$extra")"
  local eligible="false" reasons='[]'
  if (( count >= min )); then
    eligible="true"
    reasons="$(jq -cn --argjson c "$count" --argjson m "$min" '["repeated_evidence:\($c)>=\($m)"]')"
  else
    reasons="$(jq -cn --argjson c "$count" --argjson m "$min" '["insufficient_evidence:\($c)<\($m)"]')"
  fi
  jq -cn --arg signature "$sig" --argjson evidence_count "$count" --argjson min_evidence "$min" \
    --argjson eligible "$eligible" --argjson reasons "$reasons" \
    --argjson required '["regression_eval_pass","approver_token(cto|security)"]' \
    '{signature:$signature, evidence_count:$evidence_count, min_evidence:$min_evidence,
      eligible:$eligible, reasons:$reasons, required_for_promotion:$required}'
  [[ "$eligible" == "true" ]]
}

# ig_run_eval [--cmd CMD] [--timeout S] — 回帰 eval を実行し結果ファイルを返す
ig_run_eval() {
  local cmd="$IG_EVAL_CMD" timeout_s="$IG_EVAL_TIMEOUT"
  while (( $# )); do
    case "$1" in
      --cmd) cmd="${2:-$IG_EVAL_CMD}"; shift 2 ;;
      --timeout) timeout_s="${2:-$IG_EVAL_TIMEOUT}"; shift 2 ;;
      *) shift ;;
    esac
  done
  mkdir -p "$(ig__dir)" || return 1
  local out; out="$(ig__dir)/eval-$(date -u +%Y%m%dT%H%M%SZ).json"
  local start; start="$(date +%s)"
  local rc=0
  local log; log="$(ig__dir)/eval-last.log"
  ( cd "$CCSU_ROOT" && timeout "$timeout_s" bash -lc "$cmd" ) > "$log" 2>&1 || rc=$?
  local dur=$(( $(date +%s) - start ))
  local status="fail"
  (( rc == 0 )) && status="pass"
  jq -cn --arg cmd "$cmd" --argjson exit_code "$rc" --argjson duration "$dur" --arg status "$status" \
    --arg log "$log" --arg at "$(ig__iso)" \
    '{status:$status, cmd:$cmd, exit_code:$exit_code, duration_s:$duration, log:$log, at:$at}' > "$out"
  printf '%s\n' "$out"
  [[ "$status" == "pass" ]]
}

# ig_promote <signature> --proposal F [--min-evidence N] [--evidence-file F]
#             [--eval-result-file F | --run-eval [--eval-cmd C]] [--token T] [--dry-run]
#   4 要件すべてが満たされたときだけ昇格記録と PR 用ハンドオフを生成する。
#   1 つでも欠ければ DB/ファイルへ書き込まず rc=1 で拒否する (fail-closed)。
ig_promote() {
  local sig="${1:-}"; shift || true
  local min="$IG_MIN_EVIDENCE" extra="" eval_file="" token="" proposal="" run_eval=0 eval_cmd="$IG_EVAL_CMD" dry=0
  while (( $# )); do
    case "$1" in
      --min-evidence)    min="${2:-$IG_MIN_EVIDENCE}"; shift 2 ;;
      --evidence-file)   extra="${2:-}"; shift 2 ;;
      --eval-result-file) eval_file="${2:-}"; shift 2 ;;
      --run-eval)        run_eval=1; shift ;;
      --eval-cmd)        eval_cmd="${2:-$IG_EVAL_CMD}"; shift 2 ;;
      --token)           token="${2:-}"; shift 2 ;;
      --proposal)        proposal="${2:-}"; shift 2 ;;
      --dry-run)         dry=1; shift ;;
      *) shift ;;
    esac
  done
  [[ -n "$sig" ]] || { log_error "improver-gate: signature が必要です"; return 2; }
  [[ -n "$proposal" ]] || { log_error "improver-gate: --proposal (提案内容のファイル) が必須です"; return 2; }

  local reasons='[]' decision="rejected" count eval_status="missing" approver=""

  # 1. Repeated Evidence
  count="$(ig_evidence_count "$sig" --evidence-file "$extra")"
  if (( count < min )); then
    reasons="$(jq -cn --argjson a "$reasons" --argjson c "$count" --argjson m "$min" '$a + ["insufficient_evidence:\($c)<\($m)"]')"
  fi

  # 2/3. Measurable + Regression Safety
  if (( run_eval )); then
    if ! eval_file="$(ig_run_eval --cmd "$eval_cmd")"; then :; fi
  fi
  if [[ -z "$eval_file" || ! -f "$eval_file" ]]; then
    reasons="$(jq -cn --argjson a "$reasons" '$a + ["regression_eval_missing"]')"
  else
    eval_status="$(json_get "$eval_file" '.status' 'missing')"
    if [[ "$eval_status" != "pass" ]]; then
      reasons="$(jq -cn --argjson a "$reasons" --arg s "$eval_status" '$a + ["regression_eval_not_pass:\($s)"]')"
    fi
  fi

  # 4. Verification-First (改善者以外の承認)
  if [[ -z "$token" ]]; then
    reasons="$(jq -cn --argjson a "$reasons" '$a + ["approver_token_missing"]')"
  else
    local dec
    dec="$(policy_decision improver pr:create --token "$token" --json)"
    if [[ "$(printf '%s' "$dec" | jq -r '.decision')" == "allow" ]]; then
      approver="$(printf '%s' "$dec" | jq -r '.approver // ""')"
    else
      local why; why="$(printf '%s' "$dec" | jq -r '.reasons | join(",")')"
      reasons="$(jq -cn --argjson a "$reasons" --arg w "$why" '$a + ["approval_rejected:\($w)"]')"
    fi
  fi

  if [[ "$(printf '%s' "$reasons" | jq 'length')" -eq 0 ]]; then decision="accepted"; fi

  if (( dry )) || [[ "$decision" != "accepted" ]]; then
    jq -cn --arg signature "$sig" --arg decision "$decision" --argjson evidence_count "$count" \
      --argjson min_evidence "$min" --arg eval_status "$eval_status" --arg approver "$approver" \
      --argjson reasons "$reasons" --argjson dry_run "$(( dry ))" \
      '{signature:$signature, decision:$decision, evidence_count:$evidence_count, min_evidence:$min_evidence,
        regression_eval:$eval_status, approver:$approver, reasons:$reasons, dry_run:($dry_run==1), written:false}'
    ig__audit "$(jq -cn --arg signature "$sig" --arg decision "$decision" --argjson reasons "$reasons" \
      '{event:"promotion_attempt", signature:$signature, decision:$decision, reasons:$reasons}')"
    [[ "$decision" == "accepted" ]] && return 0 || return 1
  fi

  # 昇格記録 + PR ハンドオフ (Skill 本文は保存しない。所在と sha256 のみ)
  mkdir -p "$(dirname "$(ig__state_file "$sig")")" "$(ig__dir)"
  local prop_sha; prop_sha="$(sha256sum "$proposal" | cut -d' ' -f1)"
  local record
  record="$(jq -cn --arg schema "claudeos.improvement-promotion/v1" --arg signature "$sig" \
    --argjson evidence_count "$count" --arg eval_status "$eval_status" --arg approver "$approver" \
    --arg proposal "$proposal" --arg proposal_sha256 "$prop_sha" --arg at "$(ig__iso)" \
    '{schema:$schema, signature:$signature, status:"promoted", evidence_count:$evidence_count,
      regression_eval:$eval_status, approved_by:$approver, proposal:$proposal,
      proposal_sha256:$proposal_sha256, at:$at,
      obligations:["Approval PR 経由で main へ反映","PR 本文に証拠/変更/eval 比較/リスク/rollback を記載","マージ後に eval ベースラインを更新"]}')"
  printf '%s\n' "$record" | jq . > "$(ig__state_file "$sig")" || return 1
  ig__audit "$(printf '%s' "$record" | jq -c '. + {event:"promotion_accepted"}')"
  printf '%s\n' "$record"
  return 0
}

# ig_status [--json] — 昇格済み / 証拠待ちの一覧
ig_status() {
  local json_out=0
  while (( $# )); do
    case "$1" in --json) json_out=1; shift ;; *) shift ;; esac
  done
  local dir; dir="$(dirname "$(ig__state_file x)")"
  local acc='[]'
  if [[ -d "$dir" ]]; then
    local f sig
    while IFS= read -r f; do
      [[ -f "$f" ]] || continue
      sig="$(basename "$f" .json)"
      acc="$(jq -cn --argjson acc "$acc" --argjson r "$(jq -c . "$f")" '$acc + [$r]')"
    done < <(find "$dir" -maxdepth 1 -name '*.json' 2>/dev/null || true)
  fi
  if (( json_out )); then
    printf '%s\n' "$acc"
  else
    printf '%s\n' "$acc" | jq -r '.[] | "\(.signature)\t\(.status)\t\(.evidence_count)件\t\(.regression_eval)\t\(.approved_by)"'
  fi
}
