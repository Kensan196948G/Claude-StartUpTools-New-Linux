# ClaudeOS運用仕様（v10）

状態: v1（2026-09-07 制定）
正本: 本ファイル、`OPERATIONS_MODEL.md`、`docs/SOURCE_OF_TRUTH.md`

## 1. 適用範囲

`/home/kensan/Projects/Mirai-Project`・`Mirai-DX-Project` 配下の登録プロジェクトと ClaudeOS 自身。ClaudeOS は Claude Code を安全・長時間・複数プロジェクトで運用する Control Plane であり、AI 機能を再実装しない。

## 2. テンプレート配布マップ

| 元 | 先 | 方式 |
|---|---|---|
| `Claude/templates/claude/START_PROMPT.md` | `<proj>/.claude/START_PROMPT.md` | 毎回上書き（template-sync） |
| `Claude/templates/claude/CLAUDE.md` | `<proj>/.claude/CLAUDE.md`（sync）/ `<proj>/CLAUDE.md`（init） | copy-if-missing |
| `Claude/templates/claude/TEAM_START_PROMPT.md` | `<proj>/.claude/TEAM_START_PROMPT.md` | 初回のみ |
| `Claude/templates/claude/rules/*.md` | `<proj>/.claude/rules/` | copy-if-missing（sync / init） |
| `Claude/templates/claude/skills/<name>/SKILL.md`（verify-app, agent-router, release-flow, approval-pr, final-report, improver, sdlc-scale, pg-ops） | `<proj>/.claude/skills/<name>/` | copy-if-missing（sync / init） |
| `Claude/templates/claudeos/commands/{safe-auto-merge,design-sync-check}.md` | `<proj>/.claude/commands/` | copy-if-missing |
| `Claude/templates/claudeos/**` | `<proj>/.claude/claudeos/` | copy-if-missing（init） |
| `Claude/templates/claudeos/agents`（first-class のみ、`config/agent-catalog.json`） | `<proj>/.claude/agents/` | copy-if-missing（init） |
| `Claude/templates/claude/workflows/*.js` | `<proj>/.claude/workflows/` | copy-if-missing（init） |
| `Claude/templates/claudeos/scripts/tools` | `<proj>/scripts/tools` | copy-if-missing（init） |
| `Claude/templates/claude/settings.json` | `<proj>/.claude/settings.json` | deep-merge + sanitize |

CLAUDE.md の正本は `Claude/templates/claude/CLAUDE.md`。ルート `CLAUDE.md`、`Claude/CLAUDE.md`、`Claude/templates/claudeos/examples/CLAUDE.md` は同一内容のコピー。

## 3. 起動経路

| 経路 | コマンド形 | 権限 | プロンプト |
|---|---|---|---|
| L1 対話 | `claude [--model --effort] [--name] "$(cat .claude/START_PROMPT.md)"` | 対話既定（auto は user settings） | START_PROMPT |
| L1 `--tmux` | `env -u SMTP… claude … --permission-mode auto "$(cat START_PROMPT)"` | auto | START_PROMPT |
| T team | 4× `claude --name claudeos-<p>-<role>` + worktree | 対話既定 | TEAM_START_PROMPT（CTO） |
| S1 / cron headless | `env -u ANTHROPIC_API_KEY -u SMTP… claude -p … --permission-mode auto --permission-prompts none` | auto、fail-closed | /goal + resume header + START_PROMPT |
| cron TUI 退避 | `claude … --permission-mode auto` | auto | 同上 |
| 緊急 | `CCSU_TMUX_SKIP_PERMS=1` / `CLAUDEOS_TUI_SKIP_PERMS=1` / `CLAUDEOS_HEADLESS_SKIP_PERMS=1` | bypass | 記録して標準にしない |

## 4. state.json

`goal / execution（phase, routing_log, last_stop_at）/ kpi / stable / token / message_bus / learning / warnings` を ClaudeOS と hooks が共有する。書込みは atomic（tmp + rename）。`state.json` は Git 管理外。

## 5. DB / Cloudflare 仕様への参加

DB を持つプロジェクトは `bin/pg-ops.sh init` → `.env.example` → `pg-ops.sh units`（運用者が `--install`）→ Mission Control で監視。公開が必要なら `Cloudflare公開基盤仕様.md` の判断フローに従う。

## 6. 文書索引

`docs/claude/01〜19`（利用手順）、`docs/architecture/*.md`（v10 仕様）、`.claude/claudeos/policy/*.md`（詳細方針）、`docs/architecture/audits/`（監査記録）。
