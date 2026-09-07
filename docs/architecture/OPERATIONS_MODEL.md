# OPERATIONS_MODEL — Linux Operations Layer（Control Plane）

状態: v10（2026-09-07）

ClaudeOS は「AI 機能を再実装する OS」ではなく、Claude Code を安全・長時間・複数プロジェクトで運用する Control Plane。Native と重複する部分は Native へ寄せ、OS レベルの機能だけを保持する。

## 1. 保持する OS レベル機能（KEEP）

| 機能 | 実体 | Native との境界 |
|---|---|---|
| tmux 多重化・ログ捕捉 | `lib/tmux-runner.sh`, `bin/monitor-sessions.sh`, `libexec/watch-session.sh` | `claude agents` は端末を多重化しない |
| Supervisor（Goal 到達まで再起動、日次上限、クラッシュループ・credit guard） | `lib/supervisor.sh`, `bin/autonomy.sh`, `lib/credits.sh` | `claude --bg` は 1 セッション |
| cron | `lib/cron-manager.sh`, `bin/cron-schedule.sh`, `Claude/templates/linux/cron-launcher.sh` | `/loop` `/goal` `CronCreate` はセッション内、Routines はクラウド |
| systemd | `lib/systemd-manager.sh`, `bin/systemd-control.sh`, `bin/dashboard-service.sh`, `pg-ops.sh units` | — |
| Watchdog / Process recovery / Session recovery | heartbeat-{writer,daemon,watchdog}.js, `timeout --foreground`, `--resume` | Native watchdog はプロセス内 |
| Local Project discovery | `lib/config-loader.sh`, `lib/onboard.sh`, `lib/project-autoinit.sh` | Claude Code は単一プロジェクト |
| Long-running execution | cron-launcher + Supervisor + heartbeat | — |
| OS resource monitoring | Mission Control `/api/system-health`, `pg__disk` | — |
| メール報告 | `Claude/templates/linux/report-and-mail.py` | Native channel なし |

## 2. Native へ寄せた／重複を整理した機能

| 旧 | 現在 |
|---|---|
| verify-goal-set hook | native `/goal` + bats |
| suggest-compact hook | `/autocompact` |
| notify-stable（push-notify） | native 通知 + Notification hook + webhook |
| agent-teams-tracker の TeamCreate | named Agent spawn / SendMessage のみ |
| 43 agents 全件 discovery、66 skill stub | Lazy Agent Catalog、実 skill 8 本 |
| CLAUDE.md への /goal 複製、41KB 常時ロード | START_PROMPT ポインタ、CLAUDE.md 要約 + rules + policy |
| `--dangerously-skip-permissions` | `--permission-mode auto --permission-prompts none` |
| Statusline 設定、MCP health、worktree 一覧（ClaudeOS custom） | `/statusline`, `claude mcp list`, `git worktree list` / `.claude/worktrees`（custom は薄い adapter として保持） |

## 3. 日常運用

| 頻度 | 作業 | 手段 |
|---|---|---|
| 起動時 | template 配布・settings sanitize・Capability 判定 | `start.sh` → `lib/template-sync.sh` / `lib/claude-capability.sh` |
| 毎日 | PostgreSQL backup（03:15）、cron セッション、heartbeat | systemd timer / cron |
| 毎週 | restore drill（日 04:30）、`/skill-doctor`、routing_log 確認、Improver 判断 | systemd timer / Claude Code |
| 更新時 | `claude update` → `libexec/diag-claude-compat.sh` → compat json 更新 | メニュー 17 |
| 障害時 | `bin/incident-response.sh`、Mission Control、`pg-ops.sh status` | メニュー I / MC / 18 |

## 4. メニュー（v10 追加）

| 番号 | 内容 |
|---|---|
| 17 | 🧪 Claude Code 互換性 / Capability 診断 |
| 18 | 🐘 Local PostgreSQL 運用診断（health / backup / drill） |
| MC | 🎛️ Mission Control（🧬 v10 Platform パネル: PostgreSQL / Capability / native agents / routing / hooks） |

## 5. Mission Control 追跡項目

Agent status（native `claude agents --json`）、Agent Teams、Workflow / Task（state.json）、Worktree、CI / PR / Merge（GitHub）、Token / Cost / Prompt Cache（`/cost` 手動、KPI）、Tool failure / Retry（audit-log、StopFailure）、Context compaction（pre-compact snapshots）、Agent spawn / completion（usage-tracker / agent-teams-tracker）、Model switch（PreModelSwitch hook 候補）、Skill usage（usage-tracker）、Eval pass 率（CI）、Self-Improvement proposal（PR ラベル）、PostgreSQL health / backup / drill / disk、Supervisor / tmux / cron。
