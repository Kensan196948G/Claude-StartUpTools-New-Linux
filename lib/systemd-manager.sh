#!/usr/bin/env bash
# ============================================================
# systemd-manager.sh — 登録プロジェクトの systemd (user) 起動管理 (Linux native)
#
# 役割: 廃止した Docker 統合 (docker-manager.sh) の代替。登録プロジェクトごとに
#       systemd --user unit (claudeos-<project>.service) を生成し、enable/start/
#       stop・状態確認する。検出/台帳/unit 生成の実体。CLI 表層は bin/systemd-control.sh。
#
# 設計: dashboard-service.sh と同じ「user 単位 (systemctl --user /
#       ~/.config/systemd/user)」慣習に揃える。root 権限を要求しない。
#       ExecStart は「設定ファースト + 推定フォールバック」で解決する:
#         1. 台帳 (systemd-registry.json) の command
#         2. config.json の .service.<project>.command
#         3. プロジェクト内容から推定 (npm start / node / python / cargo / go)
#
# テスト差し替え (bats): CCSU_SYSTEMCTL_BIN (systemctl 実体), CCSU_SYSTEMD_USER_DIR
#                        (unit 配置 dir), CCSU_SYSTEMD_REGISTRY (台帳パス)
#
# 前提: common.sh + json.sh + config-loader.sh が source 済み。
# ============================================================

[[ -n "${_CCSU_SYSTEMD_MANAGER_LOADED:-}" ]] && return 0
_CCSU_SYSTEMD_MANAGER_LOADED=1

# --- パス/コマンド (テスト時は環境変数で差し替え) ---
SYSTEMD_REGISTRY_PATH="${CCSU_SYSTEMD_REGISTRY:-$CCSU_ROOT/config/systemd-registry.json}"
SYSTEMD_USER_DIR="${CCSU_SYSTEMD_USER_DIR:-$HOME/.config/systemd/user}"
SYSTEMCTL="${CCSU_SYSTEMCTL_BIN:-systemctl}"

# systemd (systemctl --user) が使えるか。第1語 (パス/コマンド名) の存在で判定。
sysd_available() { has_cmd "${SYSTEMCTL%% *}"; }

# unit 名: claudeos-<safe>.service ("/" 等は "_" へ正規化)
sysd_unit_name() { printf 'claudeos-%s.service' "$(ccsu_safe_name "$1")"; }

# unit ファイルの絶対パス
sysd_unit_path() { printf '%s/%s' "$SYSTEMD_USER_DIR" "$(sysd_unit_name "$1")"; }

# プロジェクトの絶対パス
sysd_project_dir() { printf '%s/%s' "$(config_projects_dir)" "$1"; }

# ExecStart 用の起動コマンド推定 (無ければ空 + exit 0)。config_infer_* と同型の「設定ファースト」。
sysd_infer_command() {
  local dir="$1"
  if   [[ -f "$dir/package.json" ]] && grep -Eq '"start"[[:space:]]*:' "$dir/package.json"; then printf 'npm start'
  elif [[ -f "$dir/server.js" ]];  then printf 'node server.js'
  elif [[ -f "$dir/app.js" ]];     then printf 'node app.js'
  elif [[ -f "$dir/index.js" ]];   then printf 'node index.js'
  elif [[ -f "$dir/main.py" ]];    then printf 'python3 main.py'
  elif [[ -f "$dir/app.py" ]];     then printf 'python3 app.py'
  elif [[ -f "$dir/Cargo.toml" ]]; then printf 'cargo run --release'
  elif [[ -f "$dir/go.mod" ]];     then printf 'go run .'
  fi
}

# command 解決: 台帳 → config .service.<project>.command → 推定。名前は jq --arg で安全渡し。
sysd_resolve_command() {
  local project="$1" dir cmd
  cmd="$(sysd_registry_get "$project" command)"
  [[ -n "$cmd" ]] && { printf '%s' "$cmd"; return 0; }
  cmd="$(jq -r --arg p "$project" '.service[$p].command // empty' "$CCSU_CONFIG_PATH" 2>/dev/null || true)"
  [[ -n "$cmd" ]] && { printf '%s' "$cmd"; return 0; }
  dir="$(sysd_project_dir "$project")"
  sysd_infer_command "$dir"
}

# --- 台帳 (systemd-registry.json) CRUD ---
sysd_registry_ensure() {
  [[ -f "$SYSTEMD_REGISTRY_PATH" ]] && return 0
  json_set "$SYSTEMD_REGISTRY_PATH" '{ _comment: $c, projects: {} }' \
    --arg c "ClaudeOS systemd (user) 管理台帳。systemd-control.sh が読み書きする。projects.<name> = { command, workingDir, enabled, registeredAt }。"
}

# sysd_registry_get <project> <field> — 台帳フィールド取得 (無ければ空)
sysd_registry_get() {
  local project="$1" field="$2"
  [[ -f "$SYSTEMD_REGISTRY_PATH" ]] || { printf ''; return 0; }
  jq -r --arg p "$project" --arg f "$field" '.projects[$p][$f] // empty' "$SYSTEMD_REGISTRY_PATH" 2>/dev/null || true
}

# sysd_registry_put <project> <command> <workingDir> [enabled] [registeredAt]
sysd_registry_put() {
  local project="$1" command="$2" wd="$3" enabled="${4:-false}" ts="${5:-}"
  sysd_registry_ensure
  json_set "$SYSTEMD_REGISTRY_PATH" \
    '.projects[$p] = { command: $c, workingDir: $w, enabled: ($e=="true"), registeredAt: $t }' \
    --arg p "$project" --arg c "$command" --arg w "$wd" --arg e "$enabled" --arg t "$ts"
}

# sysd_registry_set_enabled <project> <true|false>
sysd_registry_set_enabled() {
  local project="$1" enabled="$2"
  [[ -f "$SYSTEMD_REGISTRY_PATH" ]] || return 0
  json_set "$SYSTEMD_REGISTRY_PATH" '.projects[$p].enabled = ($e=="true")' --arg p "$project" --arg e "$enabled"
}

# sysd_registry_remove <project>
sysd_registry_remove() {
  local project="$1"
  [[ -f "$SYSTEMD_REGISTRY_PATH" ]] || return 0
  json_set "$SYSTEMD_REGISTRY_PATH" 'del(.projects[$p])' --arg p "$project"
}

# sysd_registry_has <project> — 台帳に居れば 0
sysd_registry_has() {
  local project="$1"
  [[ -f "$SYSTEMD_REGISTRY_PATH" ]] || return 1
  [[ "$(jq -r --arg p "$project" '.projects | has($p)' "$SYSTEMD_REGISTRY_PATH" 2>/dev/null)" == "true" ]]
}

# sysd_registry_list — 台帳の project 名を 1 行 1 件 (名前順)
sysd_registry_list() {
  [[ -f "$SYSTEMD_REGISTRY_PATH" ]] || return 0
  jq -r '.projects | keys[]?' "$SYSTEMD_REGISTRY_PATH" 2>/dev/null || true
}

# sysd_registry_enabled_list — enabled=true の project 名
sysd_registry_enabled_list() {
  [[ -f "$SYSTEMD_REGISTRY_PATH" ]] || return 0
  jq -r '.projects | to_entries[] | select(.value.enabled==true) | .key' "$SYSTEMD_REGISTRY_PATH" 2>/dev/null || true
}

# --- unit ファイル生成 ---
# sysd_render_unit <project> <command> <workingDir> — unit テキストを stdout へ
sysd_render_unit() {
  local project="$1" command="$2" wd="$3"
  cat <<UNIT
[Unit]
Description=ClaudeOS service: ${project}
After=network.target

[Service]
Type=simple
WorkingDirectory=${wd}
ExecStart=/bin/bash -lc '${command}'
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
UNIT
}

# sysd_write_unit <project> <command> <workingDir> — unit を SYSTEMD_USER_DIR へ書き出す
sysd_write_unit() {
  local project="$1" command="$2" wd="$3" path
  path="$(sysd_unit_path "$project")"
  mkdir -p "$SYSTEMD_USER_DIR"
  sysd_render_unit "$project" "$command" "$wd" > "$path"
}

# sysd_remove_unit <project>
sysd_remove_unit() {
  local path; path="$(sysd_unit_path "$1")"
  [[ -f "$path" ]] && rm -f "$path"
  return 0
}

# sysd_daemon_reload — systemctl --user daemon-reload (systemd 不在時は no-op)
sysd_daemon_reload() {
  sysd_available || return 0
  "$SYSTEMCTL" --user daemon-reload 2>/dev/null || true
}
