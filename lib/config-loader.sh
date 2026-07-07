#!/usr/bin/env bash
# ============================================================
# config-loader.sh — config.json アクセサ (Linux native)
#
# 役割: scripts/lib/ConfigLoader.ps1 + Config.psm1 + LauncherCommon.psm1 の
#       Import-LauncherConfig / Get-StartupConfigPath 相当。
#       config.json の各値を意味のある関数名で取り出す薄いラッパ。
#
# 設計: Linux ローカル一本化のため projectsDir(Windows: D:\) より
#       projects(/home/kensan/Projects) を優先する。
#
# 前提: json.sh (jq) を source。
# ============================================================

[[ -n "${_CCSU_CONFIG_LOADED:-}" ]] && return 0
_CCSU_CONFIG_LOADED=1

source "$(dirname "${BASH_SOURCE[0]}")/json.sh"

# --- 汎用アクセサ ---
# config_get <jq-filter> [default]
config_get()     { json_get "$CCSU_CONFIG_PATH" "$1" "${2:-}"; }
# config_get_raw <jq-filter>  (配列/オブジェクト)
config_get_raw() { json_get_raw "$CCSU_CONFIG_PATH" "$1"; }

# --- プロジェクトディレクトリ (ローカル一本化: projects 優先) ---
config_projects_dir() {
  local base
  base="$(config_get '.projects' '')"
  if [[ -n "$base" ]]; then
    printf '%s' "$base"
    return 0
  fi
  base="$(config_get '.linuxBase' '')"
  if [[ -n "$base" ]]; then printf '%s' "$base"; else config_get '.projectsDir' "$HOME/Projects"; fi
}

# --- プロジェクト列挙 (正本) ---
#   条件: config_projects_dir 直下の「ディレクトリ かつ Git リポジトリ(.git 保有)」。
#   直下が Git リポジトリでない場合は「グループフォルダ」とみなし、その 1 階層下を
#   走査して Git リポジトリを "グループ名/サブ名" 形式で列挙する (1 階層のみ再帰)。
#   worktree/submodule の .git ファイルも Git リポジトリとして扱う。
#   ファイル・非 Git ディレクトリ・隠しエントリは除外。出力は名前を 1 行 1 件 (名前順)。
#   ※ */ グロブがディレクトリのみ・隠し除外を満たすため、.md/.sh/.json 等は自然に落ちる。
config_project_excluded() {
  local name="$1" dir="$2" x
  if [[ -d "$dir" ]] && [[ "$(cd "$dir" && pwd -P)" == "$(cd "$CCSU_ROOT" && pwd -P)" ]]; then
    return 0
  fi
  while IFS= read -r x; do
    [[ "$x" == "$name" ]] && return 0
  done < <(jq -r '.localExcludes[]? // empty' "$CCSU_CONFIG_PATH" 2>/dev/null || true)
  return 1
}

config_project_list() {
  local base; base="$(config_projects_dir)"
  [[ -d "$base" ]] || return 0
  local d name
  for d in "$base"/*/; do
    [[ -d "$d" ]] || continue         # マッチ無し時の literal "*/" 対策
    name="$(basename "$d")"
    config_project_excluded "$name" "$d" && continue
    if [[ -e "${d}.git" ]]; then
      printf '%s\n' "$name"
      continue
    fi
    # 直下に .git が無いグループフォルダ → 1 階層下のみ走査
    local sd sname
    for sd in "$d"*/; do
      [[ -d "$sd" ]] || continue
      [[ -e "${sd}.git" ]] || continue
      sname="$(basename "$sd")"
      config_project_excluded "${name}/${sname}" "$sd" && continue
      printf '%s/%s\n' "$name" "$sname"
    done
  done
}

config_linux_user() { config_get '.linuxUser' "$USER"; }

# --- ツール定義 ---
config_default_tool()  { config_get '.tools.defaultTool' 'claude'; }
config_tool_command()  { config_get ".tools.$1.command" "$1"; }
# config_tool_enabled <tool> — bool (enabled==true なら 0)
config_tool_enabled()  { [[ "$(config_get ".tools.$1.enabled" 'false')" == 'true' ]]; }

# --- 通知音 (notify.sh が使用。WinMM→ffplay 置換の設定源) ---
# config_sound_enabled — bool
config_sound_enabled() { [[ "$(config_get '.notifications.soundEnabled' 'false')" == 'true' ]]; }
# config_sound_path <tool> — 音声ファイルパス (%USERPROFILE%/\ を Linux 化)
config_sound_path() {
  local p; p="$(config_get ".notifications.sounds.$1" '')"
  [[ -z "$p" ]] && return 0          # 未定義 tool は空 + exit 0 (set -e 安全)
  json_expand_path "$p"
}

# --- Recent Projects 履歴パス (%USERPROFILE% 展開) ---
config_recent_history_path() {
  local p; p="$(config_get '.recentProjects.historyFile' '')"
  if [[ -n "$p" ]]; then json_expand_path "$p"; else printf '%s' "$HOME/.ai-startup/recent-projects.json"; fi
}

# --- 検証コマンド自動推定 (test/lint/build) ---
#   移植元: Codex-StartUpTools/bin/auto_setup.sh の infer_{test,lint,build}_command
#   Codex 依存 (CODEX_* / nightly_codex.sh) は持ち込まず、推定ロジックのみを移植。
#   設計方針 (Claude 向け書き直し): config.json の .verify.<kind>Command を最優先の
#   明示上書きとし、未指定時のみリポジトリ内容から推定する「設定ファースト」。
#   推定不能・上書き空文字なら空文字 + exit 0 を返す (set -e 安全)。
#   release-check.sh / onboarding CLI 等がプロジェクトの検証手段を得るための共通 API。

# config__has_make_target <dir> <target> — Makefile に target: 定義があれば 0
config__has_make_target() {
  local dir="$1" target="$2"
  [[ -f "$dir/Makefile" ]] && grep -Eq "^${target}:" "$dir/Makefile"
}

# config__package_has_script <dir> <script> — package.json に "script": があれば 0
config__package_has_script() {
  local dir="$1" script="$2"
  [[ -f "$dir/package.json" ]] && grep -Eq "\"${script}\"[[:space:]]*:" "$dir/package.json"
}

# config_infer_test_command <dir> — テストコマンドを推定 (無ければ空)
config_infer_test_command() {
  local dir="$1"
  if   config__has_make_target "$dir" test;      then printf 'make test'
  elif config__package_has_script "$dir" test;   then printf 'npm test'
  elif [[ -f "$dir/pyproject.toml" || -f "$dir/pytest.ini" || -d "$dir/tests" ]]; then printf 'pytest'
  elif [[ -f "$dir/Cargo.toml" ]];               then printf 'cargo test'
  elif [[ -f "$dir/go.mod" ]];                   then printf 'go test ./...'
  fi
}

# config_infer_lint_command <dir> — lint コマンドを推定 (無ければ空)
config_infer_lint_command() {
  local dir="$1"
  if   config__has_make_target "$dir" lint;      then printf 'make lint'
  elif config__package_has_script "$dir" lint;   then printf 'npm run lint'
  elif [[ -f "$dir/pyproject.toml" ]] && grep -Eq 'ruff|flake8' "$dir/pyproject.toml"; then printf 'ruff check .'
  elif [[ -f "$dir/Cargo.toml" ]];               then printf 'cargo clippy'
  elif [[ -f "$dir/go.mod" ]];                   then printf 'go vet ./...'
  fi
}

# config_infer_build_command <dir> — build コマンドを推定 (無ければ空)
config_infer_build_command() {
  local dir="$1"
  if   config__has_make_target "$dir" build;     then printf 'make build'
  elif config__package_has_script "$dir" build;  then printf 'npm run build'
  elif [[ -f "$dir/Cargo.toml" ]];               then printf 'cargo build'
  elif [[ -f "$dir/go.mod" ]];                   then printf 'go build ./...'
  fi
}

# config_verify_command <kind> <dir> — 検証コマンドを解決 (kind: test|lint|build)
#   .verify.<kind>Command が config.json に「存在すれば」その値を優先する
#   (空文字なら "その検証を明示的に無効化" とみなし空を返す)。キー不在時のみ推定する。
#   json_get は空文字と未定義を区別できないため、キー存在は jq has() で直接判定する。
config_verify_command() {
  local kind="$1" dir="$2" key="${1}Command"
  if [[ -f "$CCSU_CONFIG_PATH" ]]; then
    # config が壊れた JSON / .verify が非オブジェクトだと has() が失敗し推定へ落ちる。
    # 明示上書きが無言で捨てられるのを防ぐため、その場合は警告を出す (握り潰さない)。
    if ! json_valid "$CCSU_CONFIG_PATH"; then
      log_warn "config が不正 JSON のため .verify 上書きを無視し推定にフォールバック: $CCSU_CONFIG_PATH"
    elif jq -e --arg k "$key" '(.verify // {}) | has($k)' "$CCSU_CONFIG_PATH" >/dev/null 2>&1; then
      jq -r --arg k "$key" '.verify[$k] // ""' "$CCSU_CONFIG_PATH" 2>/dev/null || true
      return 0
    elif jq -e 'has("verify") and (.verify | type != "object")' "$CCSU_CONFIG_PATH" >/dev/null 2>&1; then
      log_warn ".verify がオブジェクトでないため上書きを無視し推定にフォールバック: $CCSU_CONFIG_PATH"
    fi
  fi
  case "$kind" in
    test)  config_infer_test_command  "$dir" ;;
    lint)  config_infer_lint_command  "$dir" ;;
    build) config_infer_build_command "$dir" ;;
    *)     return 0 ;;
  esac
}

# --- config 妥当性確認 (実行エントリ用。不在/不正 JSON で終了) ---
config_require() {
  [[ -f "$CCSU_CONFIG_PATH" ]] || die "config が見つかりません: $CCSU_CONFIG_PATH"
  json_valid "$CCSU_CONFIG_PATH" || die "config が不正な JSON です: $CCSU_CONFIG_PATH"
}
