#!/usr/bin/env bash
# ============================================================
# team-runner.sh — 4役割一括起動エンジン (tmux 4分割 + 役割別 --name + worktree)
#
# 役割: メニュー T<n> (bin/start-claude.sh --team) から、1 プロジェクトを
#       CTO / Backend / Frontend / QA の 4 役割で一括起動する。
#       1 つの tmux セッション (claudeos-team-<safe>) を 4 ペインに分割し、
#       各ペインで役割別の安定セッション名 (--name claudeos-<safe>-<役割>) を
#       付与して Claude TUI を起動する (docs/claude/19 の CTO ハブ型トポロジ)。
#
# 設計判断:
#   - セッション名は claudeos-team-<safe>。claudeos-<safe>-team にすると
#     tmux has-session の前方一致で tmux__is_running が通常セッションと
#     誤照合するため、接頭辞側に team を置く (^claudeos- 監視 grep には一致)。
#   - worktree は <project>/.worktrees/<役割> に置く。グループ直下 (兄弟) に
#     置くと config_project_list / project_autoinit_scan が worktree を
#     独立プロジェクトとして誤登録するため (config.json.template の注記参照)。
#     .git/info/exclude へ .worktrees/ を追記して status 汚染も防ぐ。
#   - --dangerously-skip-permissions は付けない。skip-permissions 起動は
#     クロスセッションメッセージングの受信が全て hold になり (docs/claude/19)、
#     本機能の目的 (役割間メッセージング) と両立しないため。人間対話前提の
#     L1 direct TUI と同じ通常権限で起動する。
#   - 初期プロンプトは CTO ペインのみ .claude/TEAM_START_PROMPT.md を注入する
#     (2026-08-08 ユーザー明示依頼の方式1)。4 ペイン同時の自律実行はクレジット
#     消費が 4 倍になるため、backend/frontend/qa は CTO からの SendMessage
#     指示待ちで開始する。単独自律用 START_PROMPT.md (/goal) は注入しない。
#     opt-out: CCSU_TEAM_PROMPT=0 または TEAM_START_PROMPT.md を空にする。
#   - 名前空間: 'team-<X>' や '<X>-<役割>' という名前の通常プロジェクトとは
#     セッション名/宛先が衝突し得る (命名規則 claudeos-<key>[-<役割>] は §27
#     配布済み標準のため変更しない)。team_run が実在する衝突候補を検出して警告する。
# ============================================================

[[ -n "${_CCSU_TEAM_LOADED:-}" ]] && return 0
_CCSU_TEAM_LOADED=1

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/config-loader.sh"
# shellcheck source=lib/template-sync.sh
source "$(dirname "${BASH_SOURCE[0]}")/template-sync.sh"
# shellcheck source=lib/model-router.sh
source "$(dirname "${BASH_SOURCE[0]}")/model-router.sh"

# tmux/claude コマンド (テストでスタブ差し替え可。tmux-runner.sh と同一規則)
TMUX_BIN="${CCSU_TMUX_BIN:-tmux}"
CLAUDE_BIN="${CCSU_CLAUDE_BIN:-claude}"

# 役割一覧 (docs/claude/19 §3 の CTO ハブ型 4 役割。cto はプロジェクト本体で作業)
TEAM_ROLES=(cto backend frontend qa)

# team__session_name <project> — チームセッション名 (前方一致衝突回避のため team- 接頭辞)
team__session_name() { printf 'claudeos-team-%s' "$(ccsu_safe_name "$1")"; }

# team__is_running <project> — チームセッション起動中なら 0
team__is_running() { "$TMUX_BIN" has-session -t "$(team__session_name "$1")" 2>/dev/null; }

# team__worktree_dir <project_dir> <role> — 役割別 worktree の配置先
team__worktree_dir() { printf '%s/.worktrees/%s' "$1" "$2"; }

# team__ensure_exclude <project_dir> — .worktrees/ を .git/info/exclude へ追記 (冪等)
#   tracked ファイルを変更せずに worktree 置き場を git status から除外する。
team__ensure_exclude() {
  local project_dir="$1" git_dir exclude
  git_dir="$(git -C "$project_dir" rev-parse --absolute-git-dir 2>/dev/null)" || return 0
  exclude="$git_dir/info/exclude"
  mkdir -p "$git_dir/info"
  grep -qxF '.worktrees/' "$exclude" 2>/dev/null || printf '.worktrees/\n' >> "$exclude"
}

# team__ensure_worktree <project_dir> <role> — worktree を作成/再利用し、パスを stdout へ返す
#   ブランチは claudeos/<role> (実フィーチャーブランチとの衝突を避ける名前空間)。
#   既存 worktree は再利用。stdout はパス専用のため、内部ログは stderr のみ。
team__ensure_worktree() {
  local project_dir="$1" role="$2" dir branch
  dir="$(team__worktree_dir "$project_dir" "$role")"
  branch="claudeos/$role"
  if [[ -d "$dir" ]]; then
    if git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      printf '%s' "$dir"
      return 0
    fi
    log_error "worktree 置き場が git 管理外の状態です (手動確認が必要): $dir"
    return 1
  fi
  # 過去に消されたディレクトリの残骸登録を掃除してから追加する
  git -C "$project_dir" worktree prune >/dev/null 2>&1 || true
  mkdir -p "$project_dir/.worktrees"
  if git -C "$project_dir" show-ref --verify --quiet "refs/heads/$branch"; then
    git -C "$project_dir" worktree add "$dir" "$branch" >/dev/null \
      || { log_error "git worktree add に失敗: $dir ($branch)"; return 1; }
  else
    git -C "$project_dir" worktree add -b "$branch" "$dir" >/dev/null \
      || { log_error "git worktree add -b に失敗: $dir ($branch)"; return 1; }
  fi
  printf '%s' "$dir"
}

# team__shq <value> — tmux がシェル評価するコマンド文字列へ埋め込む値のエスケープ
team__shq() { printf '%q' "$1"; }

# team__pane_cmd <workdir> <role> <project> <dur_sec> <model_args> [prompt_file]
#   1 ペイン分の起動コマンド文字列を組み立てる。
#   - 役割別 --name は claude v2.1.196+ のみ (未対応版は unknown option 防止で省略)
#   - hooks 環境変数はペインごとの作業ディレクトリを指す (env 前置で per-pane 化)
#   - timeout --foreground: 対話 TUI のシグナル/TTY 制御用。0s は無制限。
#   - 動的値 (project / workdir / CLAUDE_BIN) は printf %q でシェル語エスケープ
#     (プロジェクト名の ' や空白でコマンドが壊れないように)。model_args は
#     model_router__shell_args が組み立て済みの引数列のためそのまま連結する。
#   - prompt_file 指定時は "$(cat <path>)" を位置引数として付与する (tmux-runner.sh
#     と同型の遅延展開。ペイン内シェルが評価する時点でファイル内容が初期プロンプト
#     になる)。パス自体は %q エスケープする。
team__pane_cmd() {
  local workdir="$1" role="$2" project="$3" dur_sec="$4" model_args="$5" prompt_file="${6:-}"
  local name_args="" prompt_arg=""
  if ccsu_claude_supports_name "$CLAUDE_BIN"; then
    name_args="--name $(team__shq "$(CCSU_SESSION_ROLE="$role" ccsu_claude_session_name "$project")") "
  fi
  if [[ -n "$prompt_file" ]]; then
    prompt_arg="\"\$(cat $(team__shq "$prompt_file"))\""
  fi
  printf 'CLAUDE_PROJECT=%s CLAUDEOS_HOOKS_DIR=%s timeout --foreground %ss %s %s%s%s' \
    "$(team__shq "$project")" "$(team__shq "$workdir/.claude/claudeos/scripts/hooks")" \
    "$dur_sec" "$(team__shq "$CLAUDE_BIN")" "${model_args:+$model_args }" "$name_args" "$prompt_arg"
}

# team__attach_or_switch <session> — tmux 外なら attach、tmux 内なら switch-client
team__attach_or_switch() {
  local session="$1"
  if [[ -n "${TMUX:-}" ]]; then
    "$TMUX_BIN" switch-client -t "$session"
  else
    "$TMUX_BIN" attach -t "$session"
  fi
}

# ------------------------------------------------------------
# team_run <project> [duration-min]
#   4役割一括起動の本体。duration 0 (既定) = 無制限。
#   ペイン配置 (tiled): 0=cto (プロジェクト本体) / 1=backend / 2=frontend / 3=qa
# ------------------------------------------------------------
team_run() {
  local project="$1" duration_min="${2:-0}"
  require_cmd "$TMUX_BIN"
  require_cmd "$CLAUDE_BIN"
  require_cmd git

  local safe session dur_sec base project_dir stamp
  safe="$(ccsu_safe_name "$project")"
  session="$(team__session_name "$project")"
  dur_sec=$((duration_min * 60))
  base="$(config_projects_dir)"
  project_dir="$base/$project"
  [[ -d "$project_dir" ]] || { log_error "プロジェクトディレクトリが存在しません: $project_dir"; return 1; }
  git -C "$project_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || { log_error "Git リポジトリではないため役割別 worktree を作成できません: $project_dir"; return 1; }

  # 名前空間衝突の検出 (CodeRabbit PR#95 指摘の緩和):
  # 命名規則 claudeos-<key>[-<役割>] は §27 配布済み標準のため変更しない。
  # 代わりに、実在する衝突候補プロジェクトを起動前に検出して警告する。
  #   - team-<project> という通常プロジェクト → tmux セッション名が同一になる
  #   - <project>-<役割> という通常プロジェクト → クロスセッション宛先が同一になる
  if [[ -d "$base/team-$project" ]]; then
    log_warn "⚠️ 通常プロジェクト 'team-$project' が存在します。tmux セッション名 $session が衝突するため、どちらか一方のみ起動してください"
  fi
  local _r
  for _r in "${TEAM_ROLES[@]}"; do
    if [[ -d "$base/$project-$_r" ]]; then
      log_warn "⚠️ 通常プロジェクト '$project-$_r' が存在します。クロスセッション宛先 claudeos-${safe}-${_r} が衝突し誤配送の恐れがあります"
    fi
  done

  # 既に起動中なら再作成せず接続のみ
  if "$TMUX_BIN" has-session -t "$session" 2>/dev/null; then
    log_warn "既に起動中です: $session (接続します)"
    team__attach_or_switch "$session"
    return 0
  fi

  # 役割別 worktree を準備 (cto はプロジェクト本体で作業)
  team__ensure_exclude "$project_dir"
  local role dir
  local -A role_dirs=()
  role_dirs[cto]="$project_dir"
  for role in backend frontend qa; do
    dir="$(team__ensure_worktree "$project_dir" "$role")" || return 1
    role_dirs[$role]="$dir"
    log_info "🌿 worktree[$role]: $dir (branch claudeos/$role)"
  done

  # テンプレート (CLAUDE.md / TEAM_START_PROMPT.md / hooks) を各作業ディレクトリへ配布。
  # 単独自律用 START_PROMPT.md (/goal) は配布されても起動プロンプトとしては注入しない。
  for role in "${TEAM_ROLES[@]}"; do
    template_sync__apply "${role_dirs[$role]}" || true
  done

  # CTO ペインの初期プロンプト: プロジェクト本体の .claude/TEAM_START_PROMPT.md を
  # 起動時に注入する (ヘッダ設計判断参照)。空ファイルまたは CCSU_TEAM_PROMPT=0 で無効。
  local cto_prompt=""
  if [[ "${CCSU_TEAM_PROMPT:-1}" == "1" && -s "$project_dir/.claude/TEAM_START_PROMPT.md" ]]; then
    cto_prompt="$project_dir/.claude/TEAM_START_PROMPT.md"
    log_info "📨 CTO ペインへ TEAM_START_PROMPT.md を初期プロンプトとして注入します"
  else
    log_info "📨 TEAM_START_PROMPT.md 注入なし — CTO ペインは指示待ちで起動します"
  fi

  # モデル選択 (tmux-runner.sh と同一パターン)
  local model_args=""
  if model_router__select "${CLAUDEOS_MODEL_TASK:-normal}"; then
    if [[ "${MODEL_ROUTER_ENABLED:-1}" == "1" && -n "${MODEL_ROUTER_MODEL:-}" ]]; then
      model_args="$(model_router__shell_args)"
      model_router__record_selection "$project" team-runner "${CLAUDEOS_MODEL_TASK:-normal}" || true
      log_info "🧠 model=$MODEL_ROUTER_MODEL effort=$MODEL_ROUTER_EFFORT reason=$MODEL_ROUTER_REASON"
    fi
  fi

  if ! ccsu_claude_supports_name "$CLAUDE_BIN"; then
    log_warn "claude CLI が --name 未対応のため役割別アドレスなしで起動します (v2.1.196+ かつ CCSU_SESSION_NAME=1 で有効)"
  fi

  mkdir -p "$CCSU_HOME/logs"
  stamp="$(date +%Y%m%d-%H%M%S)"

  # ペイン作成: cto を起点に 3 回 split し、最後に tiled で 2x2 へ整形。
  # split-window はウィンドウ指定だと直前に作られたアクティブペインを割るため、
  # ペイン index は作成順 (0=cto,1=backend,2=frontend,3=qa) で安定する。
  "$TMUX_BIN" new-session -d -s "$session" -n team -c "${role_dirs[cto]}" -x 220 -y 50 \
    "$(team__pane_cmd "${role_dirs[cto]}" cto "$project" "$dur_sec" "$model_args" "$cto_prompt")" \
    || { log_error "tmux セッション作成に失敗しました: $session"; return 1; }
  for role in backend frontend qa; do
    # 部分起動を成功扱いしない: 1 ペインでも失敗したら作成済みセッションを畳んで中断
    "$TMUX_BIN" split-window -t "$session:0" -c "${role_dirs[$role]}" \
      "$(team__pane_cmd "${role_dirs[$role]}" "$role" "$project" "$dur_sec" "$model_args")" \
      || {
        log_error "役割ペインの作成に失敗しました: $role (セッションを停止します)"
        "$TMUX_BIN" kill-session -t "$session" 2>/dev/null || true
        return 1
      }
  done
  "$TMUX_BIN" select-layout -t "$session:0" tiled 2>/dev/null || true

  # セッション監視用メタデータ + ペインタイトル (best-effort。tmux-runner.sh と同一規則)
  "$TMUX_BIN" set-option -w -t "$session:0" automatic-rename off 2>/dev/null || true
  "$TMUX_BIN" set-option -w -t "$session:0" @ccsu_project "$project" 2>/dev/null || true
  "$TMUX_BIN" set-option -w -t "$session:0" @ccsu_duration_min "$duration_min" 2>/dev/null || true
  "$TMUX_BIN" set-option -w -t "$session:0" pane-border-status top 2>/dev/null || true
  local i=0
  for role in "${TEAM_ROLES[@]}"; do
    "$TMUX_BIN" select-pane -t "$session:0.$i" -T "$role" 2>/dev/null || true
    # pipe-pane: TUI 制御シーケンスを除去して役割別ログへ (cron/manual と同一 sed)
    "$TMUX_BIN" pipe-pane -t "$session:0.$i" -o \
      "sed 's/.*\r//; s/\x1b\][^\x07]*\x07//g; s/\x1b\[[0-9;?]*[a-zA-Z]//g; s/\x1b.//g' >> '$CCSU_HOME/logs/team-${stamp}-${safe}-${role}.log'" 2>/dev/null || true
    i=$((i + 1))
  done
  "$TMUX_BIN" select-pane -t "$session:0.0" 2>/dev/null || true

  log_ok "👥 4役割一括起動: $session (cto / backend / frontend / qa)"
  if ccsu_claude_supports_name "$CLAUDE_BIN"; then
    log_info "  宛先: claudeos-${safe}-cto / -backend / -frontend / -qa (/list-agents で確認)"
  fi
  log_info "  停止: tmux kill-session -t $session"
  log_info "  ログ: $CCSU_HOME/logs/team-${stamp}-${safe}-<役割>.log"
  team__attach_or_switch "$session"
}
