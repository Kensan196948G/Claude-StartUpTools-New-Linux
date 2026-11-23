#!/usr/bin/env bash
# ============================================================
# deploy-status.sh — 「いま何が動いていて、いつ昇格したか」を 1 コマンドで表示する
#
# 表示する内容:
#   1. 各 env の <env>-current symlink → 実体 release の commit / tree_sha256
#      (manifest.json から。無ければ「成果物なし」)
#   2. <env>-current と <env>-previous の比較 (ロールバック可能か)
#   3. health (http://127.0.0.1:<port>/api/health の ok / commit / version)
#      失敗しても表示は継続する (exit は 0 のまま)
#   4. unit 状態 (systemctl --user show <unit> -p ActiveState -p NRestarts)
#   5. 直近の昇格 5 件 (<CLAUDEOS_HOME>/releases/promotions.jsonl の末尾 5 行)
#   6. state.json の deploy サマリ (ready / environment / runbook_path / checklist)
#
# **読み取り専用**: symlink・unit・state・台帳を一切変更しない。
#   systemctl は show のみ、curl は GET のみ、ファイルは読み取りのみ。
#
# 使い方:
#   deploy-status.sh [--json] [--env staging|production]
#     --json  最終行に 1 行 JSON を出す (人間向け表示は出さない)
#     --env   指定した環境だけを表示する (既定: staging と production の両方)
#
# exit: 0 表示成功 / 1 読み取り不能 (releases dir・台帳が読めない等) / 2 引数エラー
#
# テスト差し替え:
#   CCSU_CURL_BIN       curl 実体 (既定 curl)
#   CCSU_SYSTEMCTL_BIN  systemctl 実体 (既定 systemctl)
#   CLAUDEOS_HOME       releases / state の親 (テストは一時ディレクトリ)
#   CCSU_STATE_FILE     state.json を明示指定 (未指定なら $CCSU_ROOT/state.json
#                       → $CLAUDEOS_HOME/state.json の順で存在するもの)
#
# unit 名と port は lib/release-promote.sh を正本として共用する
# (staging=claudeos-web-startup-stg.service:3742 / production=claudeos-web-startup.service:3740)。
# ============================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
# shellcheck source=lib/release-promote.sh
source "$SCRIPT_DIR/../lib/release-promote.sh"

DS_JSON=0
DS_ENV=""
DS_READ_ERROR=""
DS_GENERATED_AT=""
DS_STG_JSON="{}"
DS_PROD_JSON="{}"
DS_PROMO_JSON="[]"
DS_DEPLOY_JSON="{}"

usage() {
  cat <<'EOF'
Usage: deploy-status.sh [--json] [--env staging|production]

  --json   最終行に 1 行 JSON を出力 (人間向け表示は出さない)
  --env    指定した環境だけを表示 (既定: staging と production)
  -h, --help

表示: current release (commit / tree_sha256) / previous との比較 (ロールバック可否)
      / health / unit 状態 / 直近の昇格 5 件 / state.json の deploy サマリ

読み取り専用です (symlink・unit・state・台帳を変更しません)。
exit: 0 表示成功 / 1 読み取り不能 / 2 引数エラー
EOF
}

# ------------------------------------------------------------
# 基本ヘルパ
# ------------------------------------------------------------

ds__home() { printf '%s' "${CLAUDEOS_HOME:-$HOME/.claudeos}"; }
ds__releases() { printf '%s/releases' "$(ds__home)"; }

# ds__state_file — 読む state.json を決める (読み取り専用。無ければ空)
ds__state_file() {
  local f
  if [[ -n "${CCSU_STATE_FILE:-}" ]]; then
    printf '%s' "$CCSU_STATE_FILE"
    return 0
  fi
  # deploy-prep.sh は $CCSU_ROOT/state.json を書くので同じ順で探す
  for f in "$CCSU_ROOT/state.json" "$(ds__home)/state.json"; do
    if [[ -f "$f" ]]; then
      printf '%s' "$f"
      return 0
    fi
  done
  printf ''
}

# ds__get <json> <jq-filter> <default> — JSON からスカラを取り出す
ds__get() {
  local v
  v="$(printf '%s' "$1" | jq -r "$2" 2>/dev/null || true)"
  if [[ -z "$v" || "$v" == "null" ]]; then
    printf '%s' "$3"
  else
    printf '%s' "$v"
  fi
}

# ds__manifest_json <release dir> — manifest.json から識別子を取る
ds__manifest_json() {
  local dir="$1"
  if [[ -n "$dir" && -d "$dir" && -f "$dir/manifest.json" ]]; then
    if jq -e . "$dir/manifest.json" >/dev/null 2>&1; then
      jq -c '{commit:(.commit // ""), short_commit:(.short_commit // ""),
              tree_sha256:(.tree_sha256 // ""), file_count:(.file_count // null),
              valid:true, missing:false}' "$dir/manifest.json" 2>/dev/null \
        || jq -cn '{commit:"", short_commit:"", tree_sha256:"", file_count:null, valid:false, missing:false}'
      return 0
    fi
    jq -cn '{commit:"", short_commit:"", tree_sha256:"", file_count:null, valid:false, missing:false}'
    return 0
  fi
  jq -cn '{commit:"", short_commit:"", tree_sha256:"", file_count:null, valid:false, missing:true}'
}

# ds__health_json <port> — GET /api/health (失敗しても JSON を返す)
ds__health_json() {
  local port="$1" url out rc=0 status="" body="" err="" ok="false"
  url="http://127.0.0.1:${port}/api/health"
  out="$("$(rp__curl_bin)" -sS --max-time 3 -w $'\n%{http_code}' "$url" 2>/dev/null)" || rc=$?

  status="$(printf '%s' "$out" | tail -n 1)"
  if [[ ! "$status" =~ ^[0-9]{3}$ ]]; then
    status=""
  fi
  body="$(printf '%s' "$out" | sed '$d')"

  if (( rc != 0 )); then
    err="接続できません (curl exit $rc)"
  elif ! printf '%s' "$body" | jq -e . >/dev/null 2>&1; then
    err="応答が JSON ではありません"
  elif [[ "$(ds__get "$body" '.ok' 'false')" == "true" ]]; then
    ok="true"
  fi

  jq -cn --arg url "$url" --argjson ok "$ok" --arg status "$status" \
    --arg commit "$(ds__get "$body" '.commit' '')" \
    --arg version "$(ds__get "$body" '.version' '')" --arg err "$err" \
    '{url:$url, ok:$ok,
      http_status:(if $status == "" then null else ($status|tonumber) end),
      commit:$commit, version:$version,
      error:(if $err == "" then null else $err end)}'
}

# ds__unit_json <unit> — systemctl --user show (読み取りのみ)
ds__unit_json() {
  local unit="$1" bin out rc=0 state="" restarts="" err=""
  bin="$(rp__systemctl_bin)"
  if ! command -v -- "$bin" >/dev/null 2>&1; then
    jq -cn --arg u "$unit" '{unit:$u, ok:false, active_state:"", n_restarts:"",
                            error:"systemctl が見つかりません"}'
    return 0
  fi
  out="$("$bin" --user show "$unit" -p ActiveState -p NRestarts 2>/dev/null)" || rc=$?
  state="$(printf '%s\n' "$out" | sed -n 's/^ActiveState=//p' | head -n 1)"
  restarts="$(printf '%s\n' "$out" | sed -n 's/^NRestarts=//p' | head -n 1)"
  if (( rc != 0 )) && [[ -z "$state" ]]; then
    err="systemctl show が失敗しました (exit $rc)"
  elif [[ -z "$state" ]]; then
    err="ActiveState を取得できません"
  fi

  jq -cn --arg u "$unit" --arg s "$state" --arg r "$restarts" --arg err "$err" \
    '{unit:$u, ok:(($err == "")),
      active_state:$s, n_restarts:$r,
      error:(if $err == "" then null else $err end)}'
}

# ds__env_json <env> <selected:0|1> — 1 環境ぶんの状態を JSON で返す
ds__env_json() {
  local env="$1" selected="$2"
  local port unit link target resolved cur prev_file prev_target prev_dir prev
  local rollback=0 rb_reason="" same="false" sel="false"
  local cur_commit prev_commit health unitjson

  port="$(rp__env_port "$env")"
  unit="$(rp__env_unit "$env")"
  if (( selected )); then sel="true"; fi

  # current symlink (相対 target をそのまま残し、実体は realpath -e で解決)
  link="$(ds__releases)/${env}-current"
  target=""
  resolved=""
  if [[ -L "$link" ]]; then
    target="$(readlink -- "$link")"
    resolved="$(realpath -e -- "$link" 2>/dev/null || true)"
  fi
  cur="$(ds__manifest_json "$resolved")"
  local symlink_present="false"
  if [[ -L "$link" ]]; then symlink_present="true"; fi

  # previous (release-promote は相対 target を 1 行書く。symlink でも読める)
  prev_file="$(ds__releases)/${env}-previous"
  prev_target=""
  prev_dir=""
  if [[ -L "$prev_file" ]]; then
    prev_target="$(readlink -- "$prev_file" 2>/dev/null || true)"
  elif [[ -f "$prev_file" ]]; then
    prev_target="$(head -n 1 -- "$prev_file" 2>/dev/null || true)"
  fi
  if [[ -n "$prev_target" ]]; then
    if [[ "$prev_target" == /* ]]; then
      prev_dir="$(realpath -m -- "$prev_target" 2>/dev/null || true)"
    else
      prev_dir="$(realpath -m -- "$(ds__releases)/$prev_target" 2>/dev/null || true)"
    fi
  fi
  prev="$(ds__manifest_json "$prev_dir")"

  cur_commit="$(ds__get "$cur" '.commit' '')"
  prev_commit="$(ds__get "$prev" '.commit' '')"

  if [[ -n "$prev_target" && -n "$prev_dir" && -d "$prev_dir" ]]; then
    rollback=1
    rb_reason="previous が存在します"
    if [[ -n "$cur_commit" && "$cur_commit" == "$prev_commit" ]]; then
      same="true"
      rb_reason="previous は current と同一 commit です (戻しても同じ)"
    fi
  elif [[ -n "$prev_target" ]]; then
    rb_reason="previous の実体が存在しません: $prev_target"
  else
    rb_reason="previous が無いためロールバックできません"
  fi

  health="$(ds__health_json "$port")"
  unitjson="$(ds__unit_json "$unit")"

  jq -cn \
    --arg env "$env" --argjson selected "$sel" --argjson port "$port" --arg unit "$unit" \
    --arg link "$link" --arg target "$target" --arg path "$resolved" \
    --argjson current "$cur" \
    --arg prev_file "$prev_file" --arg prev_target "$prev_target" --arg prev_path "$prev_dir" \
    --argjson previous "$prev" \
    --argjson rollback "$rollback" --arg rb_reason "$rb_reason" \
    --argjson same "$same" --argjson health "$health" --argjson unit_info "$unitjson" \
    --argjson symlink_present "$symlink_present" \
    '{env:$env, selected:$selected, port:$port, unit:$unit,
      current:{symlink:$link, target:$target, path:$path,
               symlink_present:$symlink_present,
               present:(($path != "") and ($current.valid == true)), manifest:$current},
      previous:{file:$prev_file, target:$prev_target, path:$prev_path,
                present:(($prev_path != "") and ($previous.valid == true)), manifest:$previous},
      rollback_available:($rollback == 1), rollback_reason:$rb_reason,
      same_commit_as_previous:$same,
      health:$health, unit:$unit_info}'
}

# ds__promotions_json — 台帳の末尾 5 行 (JSON として妥当な行のみ)
ds__promotions_json() {
  local file line parsed
  local -a objs=()
  file="$(ds__releases)/promotions.jsonl"
  if [[ -f "$file" ]]; then
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      if parsed="$(printf '%s' "$line" | jq -c \
        '{at:(.at // ""), env:(.env // ""), commit:(.commit // ""),
          short_commit:((.commit // "")[0:7]), tree_sha256:(.tree_sha256 // ""),
          result:(.result // ""), unit:(.unit // ""), port:(.port // null)}' 2>/dev/null)"; then
        objs+=("$parsed")
      fi
    done < <(tail -n 5 -- "$file" 2>/dev/null || true)
  fi
  if (( ${#objs[@]} == 0 )); then
    printf '[]'
    return 0
  fi
  printf '%s\n' "${objs[@]}" | jq -cs '.' 2>/dev/null || printf '[]'
}

# ds__deploy_json — state.json の deploy サマリ
ds__deploy_json() {
  local file
  file="$(ds__state_file)"
  if [[ -z "$file" || ! -f "$file" ]]; then
    jq -cn --arg p "$file" \
      '{path:$p, present:false, valid:false, ready:false, environment:null,
        runbook_generated:false, runbook_path:null, runbook_path_present:false,
        pre_deploy_checklist_done:false, notes:""}'
    return 0
  fi
  if ! jq -e . "$file" >/dev/null 2>&1; then
    jq -cn --arg p "$file" \
      '{path:$p, present:true, valid:false, ready:false, environment:null,
        runbook_generated:false, runbook_path:null, runbook_path_present:false,
        pre_deploy_checklist_done:false, notes:""}'
    return 0
  fi
  jq -c --arg p "$file" \
    '{path:$p, present:true, valid:true,
      ready:(.deploy.ready // false),
      environment:(.deploy.environment // null),
      runbook_generated:(.deploy.runbook_generated // false),
      runbook_path:(.deploy.runbook_path // null),
      runbook_path_present:((((.deploy.runbook_path // "") | tostring) | length) > 0),
      pre_deploy_checklist_done:(.deploy.pre_deploy_checklist_done // false),
      notes:(.deploy.notes // "")}' "$file" 2>/dev/null \
    || jq -cn --arg p "$file" \
      '{path:$p, present:true, valid:false, ready:false, environment:null,
        runbook_generated:false, runbook_path:null, runbook_path_present:false,
        pre_deploy_checklist_done:false, notes:""}'
}

# ------------------------------------------------------------
# 出力
# ------------------------------------------------------------

ds__json_line() {
  jq -cn --arg generated_at "$DS_GENERATED_AT" \
    --arg home "$(ds__home)" --arg releases "$(ds__releases)" \
    --argjson staging "$DS_STG_JSON" --argjson production "$DS_PROD_JSON" \
    --argjson promotions "$DS_PROMO_JSON" --argjson deploy "$DS_DEPLOY_JSON" \
    '{ok:true, generated_at:$generated_at, claudeos_home:$home, releases_dir:$releases,
      staging:$staging, production:$production, promotions:$promotions, deploy:$deploy}'
}

# ds__render_env <env json> — 人間向け 1 環境ぶんの表示
ds__render_env() {
  local j="$1"
  local env port unit link target path commit short tree fcount
  local rollback reason same
  local h_ok h_status h_commit h_version h_err
  local u_ok u_state u_restarts u_err

  env="$(ds__get "$j" '.env' '')"
  port="$(ds__get "$j" '.port' '')"
  unit="$(ds__get "$j" '.unit.unit' '')"
  link="$(ds__get "$j" '.current.symlink' '')"
  target="$(ds__get "$j" '.current.target' '')"
  path="$(ds__get "$j" '.current.path' '')"
  commit="$(ds__get "$j" '.current.manifest.commit' '')"
  short="$(ds__get "$j" '.current.manifest.short_commit' '')"
  tree="$(ds__get "$j" '.current.manifest.tree_sha256' '')"
  fcount="$(ds__get "$j" '.current.manifest.file_count' '')"
  rollback="$(ds__get "$j" '.rollback_available' 'false')"
  reason="$(ds__get "$j" '.rollback_reason' '')"
  same="$(ds__get "$j" '.same_commit_as_previous' 'false')"
  h_ok="$(ds__get "$j" '.health.ok' 'false')"
  h_status="$(ds__get "$j" '.health.http_status' '')"
  h_commit="$(ds__get "$j" '.health.commit' '')"
  h_version="$(ds__get "$j" '.health.version' '')"
  h_err="$(ds__get "$j" '.health.error' '')"
  u_ok="$(ds__get "$j" '.unit.ok' 'false')"
  u_state="$(ds__get "$j" '.unit.active_state' '')"
  u_restarts="$(ds__get "$j" '.unit.n_restarts' '')"
  u_err="$(ds__get "$j" '.unit.error' '')"

  printf '\n%s[%s]%s\n' "$C_CYAN" "$env" "$C_RESET"

  # 1. current release
  if [[ "$(ds__get "$j" '.current.present' 'false')" == "true" ]]; then
    printf '  成果物    : %s (short %s / tree %s / files %s)\n' \
      "${commit:-(commit 不明)}" "${short:-?}" "${tree:-?}" "${fcount:-?}"
    printf '  current   : %s -> %s\n' "$link" "$target"
  elif [[ "$(ds__get "$j" '.current.symlink_present' 'false')" == "true" ]]; then
    printf '  成果物    : %s成果物なし%s（symlink はあるが manifest/実体が無い: %s）\n' \
      "$C_YELLOW" "$C_RESET" "$target"
    printf '  current   : %s -> %s\n' "$link" "$target"
  else
    printf '  成果物    : 成果物なし（%s がありません）\n' "$link"
  fi

  # 2. previous / rollback
  if [[ "$rollback" == "true" ]]; then
    if [[ "$same" == "true" ]]; then
      printf '  ロールバック: %s可%s (%s)\n' "$C_YELLOW" "$C_RESET" "$reason"
    else
      printf '  ロールバック: %s可%s (%s -> previous %s)\n' "$C_GREEN" "$C_RESET" "$reason" \
        "$(ds__get "$j" '.previous.manifest.commit' '?')"
    fi
  else
    printf '  ロールバック: %s不可%s (%s)\n' "$C_WHITE" "$C_RESET" "$reason"
  fi

  # 3. health
  if [[ "$h_ok" == "true" ]]; then
    printf '  health    : %sOK%s http=%s commit=%s version=%s (%s:%s)\n' \
      "$C_GREEN" "$C_RESET" "${h_status:-?}" "${h_commit:-(なし)}" "${h_version:-(なし)}" "127.0.0.1" "$port"
  else
    printf '  health    : %sNG%s http=%s %s (127.0.0.1:%s)\n' \
      "$C_RED" "$C_RESET" "${h_status:-?}" "${h_err:-ok:false}" "$port"
  fi

  # 4. unit
  if [[ "$u_ok" == "true" ]]; then
    printf '  unit      : %s%s%s / NRestarts=%s (%s)\n' \
      "$C_GREEN" "${u_state:-?}" "$C_RESET" "${u_restarts:-?}" "$unit"
  else
    printf '  unit      : %s取得不可%s %s (%s)\n' "$C_YELLOW" "$C_RESET" "${u_err:-不明}" "$unit"
  fi
}

ds__render_promotions() {
  local j="$1" count
  count="$(ds__get "$j" 'length' '0')"
  printf '\n%s直近の昇格（最大5件）%s\n' "$C_CYAN" "$C_RESET"
  if [[ "$count" == "0" ]]; then
    printf '  （履歴なし）\n'
    return 0
  fi
  printf '%s' "$j" | jq -r '.[] |
    "  " + (.at // "?") + "  " + (if .env == "" then "-" else .env end) +
    "  " + (if .result == "" then "-" else .result end) +
    "  " + ((.commit // "")[0:12]) +
    "  tree=" + ((.tree_sha256 // "")[0:12]) +
    "  " + (if .unit == "" then "-" else .unit end) +
    ":" + (if .port == null then "-" else (.port | tostring) end)'
}

ds__render_deploy() {
  local j="$1" path present valid ready env rb_generated rb_path rb_present checklist
  path="$(ds__get "$j" '.path' '')"
  present="$(ds__get "$j" '.present' 'false')"
  valid="$(ds__get "$j" '.valid' 'false')"
  ready="$(ds__get "$j" '.ready' 'false')"
  env="$(ds__get "$j" '.environment' '')"
  rb_generated="$(ds__get "$j" '.runbook_generated' 'false')"
  rb_path="$(ds__get "$j" '.runbook_path' '')"
  rb_present="$(ds__get "$j" '.runbook_path_present' 'false')"
  checklist="$(ds__get "$j" '.pre_deploy_checklist_done' 'false')"

  printf '\n%sstate.json の deploy%s\n' "$C_CYAN" "$C_RESET"
  if [[ "$present" != "true" ]]; then
    printf '  （state.json なし）\n'
    return 0
  fi
  if [[ "$valid" != "true" ]]; then
    printf '  %s（JSON として読めません）%s %s\n' "$C_YELLOW" "$C_RESET" "$path"
    return 0
  fi
  printf '  path      : %s\n' "$path"
  local runbook_label
  if [[ "$rb_present" == "true" ]]; then
    runbook_label="${C_GREEN}有${C_RESET}(${rb_path})"
  else
    runbook_label="${C_WHITE}無${C_RESET}"
  fi
  printf '  ready=%s environment=%s runbook_generated=%s runbook_path=%s checklist_done=%s\n' \
    "$ready" "${env:-(未設定)}" "$rb_generated" "$runbook_label" "$checklist"
}

ds__render_human() {
  printf '%sClaudeOS deploy status%s  %s\n' "$C_CYAN" "$C_RESET" "$DS_GENERATED_AT"
  printf 'CLAUDEOS_HOME : %s\n' "$(ds__home)"
  printf 'releases      : %s\n' "$(ds__releases)"

  if [[ -z "$DS_ENV" || "$DS_ENV" == "staging" ]]; then
    ds__render_env "$DS_STG_JSON"
  fi
  if [[ -z "$DS_ENV" || "$DS_ENV" == "production" ]]; then
    ds__render_env "$DS_PROD_JSON"
  fi

  ds__render_promotions "$DS_PROMO_JSON"
  ds__render_deploy "$DS_DEPLOY_JSON"
  printf '\n'
}

# ------------------------------------------------------------
# main
# ------------------------------------------------------------

main() {
  local wants_json=0 a

  # 引数エラーも JSON で返せるよう、--json を先に知る
  for a in "$@"; do
    if [[ "$a" == "--json" ]]; then
      wants_json=1
    fi
  done

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json) DS_JSON=1; shift ;;
      --env)
        if [[ $# -lt 2 ]]; then
          log_error "--env には値が必要です"
          if (( wants_json )); then printf '{"ok":false,"error":"ARG_INVALID","message":"--env には値が必要です"}\n'; fi
          return 2
        fi
        DS_ENV="$2"; shift 2 ;;
      -h|--help) usage; return 0 ;;
      *)
        log_error "不明な引数: $1"
        if (( wants_json )); then
          jq -cn --arg m "不明な引数: $1" '{ok:false,error:"ARG_INVALID",message:$m}'
        fi
        return 2 ;;
    esac
  done

  if [[ -n "$DS_ENV" && "$DS_ENV" != "staging" && "$DS_ENV" != "production" ]]; then
    log_error "env は staging|production のいずれかです: $DS_ENV"
    if (( wants_json )); then
      jq -cn --arg m "env は staging|production のいずれかです: $DS_ENV" '{ok:false,error:"ARG_INVALID",message:$m}'
    fi
    return 2
  fi

  require_cmd jq
  require_cmd realpath

  DS_GENERATED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # 読み取り不能の検出 (存在するのに読めないものだけをエラーにする)
  if [[ -e "$(ds__releases)" && ! -r "$(ds__releases)" ]]; then
    DS_READ_ERROR="releases ディレクトリを読めません: $(ds__releases)"
  elif [[ -f "$(ds__releases)/promotions.jsonl" && ! -r "$(ds__releases)/promotions.jsonl" ]]; then
    DS_READ_ERROR="promotions.jsonl を読めません: $(ds__releases)/promotions.jsonl"
  fi
  if [[ -n "$DS_READ_ERROR" ]]; then
    log_error "$DS_READ_ERROR"
    if (( wants_json )); then
      jq -cn --arg m "$DS_READ_ERROR" '{ok:false,error:"READ_FAILED",message:$m}'
    fi
    return 1
  fi

  # --env 未指定なら両 env を評価する。指定時はその env だけを評価し、
  # 非選択 env は {"env":..,"selected":false} の最小表現にする
  # (無関係な env の health/unit へ問い合わせない = 読み取り最小化)
  if [[ "$DS_ENV" == "staging" ]]; then
    DS_STG_JSON="$(ds__env_json staging 1)"
    DS_PROD_JSON='{"env":"production","selected":false}'
  elif [[ "$DS_ENV" == "production" ]]; then
    DS_STG_JSON='{"env":"staging","selected":false}'
    DS_PROD_JSON="$(ds__env_json production 1)"
  else
    DS_STG_JSON="$(ds__env_json staging 1)"
    DS_PROD_JSON="$(ds__env_json production 1)"
  fi
  DS_PROMO_JSON="$(ds__promotions_json)"
  DS_DEPLOY_JSON="$(ds__deploy_json)"

  if (( DS_JSON )); then
    ds__json_line
    return 0
  fi

  ds__render_human
  return 0
}

rc=0
main "$@" || rc=$?
exit "$rc"
