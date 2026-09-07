# ARCHITECTURE_V10 — ClaudeOS v10 Native-Agentic Development OS

状態: v10（2026-09-07）
正本: 本書、`CLAUDE.md`（要約）、`.claude/claudeos/policy/*.md`、`docs/architecture/*.md`

## 1. 目標構造

```text
┌──────────────────────────────────────────┐
│               Human Governance           │  Approval PR (Y/N) / Security / Production / Risk
└────────────────────┬─────────────────────┘
┌────────────────────▼─────────────────────┐
│              ClaudeOS v10 CTO            │  Planning / Routing (agent-router) / Governance
└───────┬────────┬────────┬───────────────┘
        ▼        ▼        ▼
     Main     Subagent   Dynamic Workflow      ← Claude Code Native
     Agent    Background Agent / Agent View
                 │  (Agent Teams: 通信が必要な時だけ)
             Worktrees（並列編集の分離）
┌────────────────▼─────────────────────────┐
│             Verification Layer           │  independent QA / security-reviewer / evals / adversarial / outcome-grader
└────────────────┬─────────────────────────┘
┌────────────────▼─────────────────────────┐
│             Self-Improvement             │  Observe → Evaluate → Improver → PR (main へ直接反映しない)
└────────────────┬─────────────────────────┘
┌────────────────▼─────────────────────────┐
│              AI-Native SDLC              │  Intent → Spec → Plan → Build → Tests → Evals → Review → PR → CI/CD → Monitor → Feedback
└────────────────┬─────────────────────────┘
┌────────────────▼─────────────────────────┐
│              Platform Layer              │  Linux / Local PostgreSQL / GitHub / Cloudflare (必要時)
└──────────────────────────────────────────┘
```

原則: **Claude Code Native > Thin ClaudeOS Adapter > Custom Implementation**。ClaudeOS は AI 機能を再実装せず、Claude Code を安全・長時間・複数プロジェクトで運用する Control Plane に徹する。

## 2. レイヤと担当

| レイヤ | 実体 | Native / Adapter / Custom |
|---|---|---|
| Claude Code Native | subagents (`.claude/agents`, first-class 9) / `claude --bg` + `claude agents` / `--worktree` / `/workflows` / skills (`.claude/skills`) / hooks / MCP / `/goal` / `/loop` / cross-session messaging / auto mode | Native |
| ClaudeOS Orchestration | `scripts/tools/agent-router.js`（決定表 + golden eval）、`config/agent-catalog.json`（Lazy Agent Catalog）、`policy/*.md`、`.claude/rules`、SDLC テンプレート | Thin adapter |
| Governance / Verification | 品質ゲート付き自動マージ（組織方針 §5）、Approval PR、`permissions.allow/deny`、hooks（audit-trail / pre-commit-gate / stop-failure）、Generator/Verifier 分離、`bin/release-check.sh`、`pg-ops.sh migration-risk` | Adapter + Custom（モデルの外側） |
| Self-Improvement | `/improver` skill、reasoning-bank（観測）、`tests/evals/*.json` + `scripts/*.test.js`（回帰 eval）、PR ゲート | Adapter |
| Linux Operations | cron / Supervisor / tmux / systemd / heartbeat / Mission Control / pg-ops / release-check / メール報告 | Custom（KEEP 境界） |

## 3. Platform

| 項目 | 標準 |
|---|---|
| OS | Linux（Ubuntu 24.04、systemd） |
| AI Runtime | Claude Code（tested 2.1.263、minimum 2.1.224。Capability Detection で機能可否判定） |
| Database | Local PostgreSQL（`postgresql@16-main`、Unix socket、環境別 database/role、`bin/pg-ops.sh`） |
| Source of Truth | GitHub（Ruleset + Required Checks + Squash Merge） |
| Hosting | ホスト systemd（DB を持つ backend）。Cloudflare は Pages / Access / Tunnel / DNS が必要な場合のみ |
| Automation | GitHub Actions（CI / Security Scan）、Claude Code（`-p` / `--bg` / `/goal`）、ClaudeOS（cron / Supervisor） |
| Observability | Mission Control（`/api/v10`: PostgreSQL / Capability / native agents / routing log / hooks） |
| Improvement | Eval-driven Self-Improvement |

## 4. Context Engineering

| 層 | 役割 | ロード |
|---|---|---|
| `/etc/claude-code/CLAUDE.md` | 組織方針 | 常時 |
| `CLAUDE.md`（62 行） | 全作業共通ルールの要約とポインタ | 常時 |
| `.claude/rules/*.md` | git-workflow / security（常時）、launchers / hooks / templates（paths 一致時） | 条件付き |
| `.claude/skills/*` | 手順（agent-router / release-flow / approval-pr / final-report / improver / sdlc-scale / pg-ops / verify-*） | 必要時 |
| `.claude/agents/*` | first-class 9 体の責務 | 委任時 |
| `.claude/claudeos/policy/*.md`、`docs/architecture/*.md` | 詳細方針・仕様 | 参照時 |
| `state.json` / reasoning-bank / routing_log | 経験・実行履歴 | hooks が要約注入 |

## 5. Agent Architecture

`AGENT_ORCHESTRATION.md` を参照。要点: 必要な Agent だけ・必要な時だけ・必要な Context だけ。Router が Main / Subagent / Background / Agent View / Teams / Workflow / Worktree を決定し理由を記録する。Agent Teams は通信が本当に必要な場合のみ。同一ファイルを複数 Agent へ同時割当しない。

## 6. Verification-First

Implementation Agent → independent QA → security-reviewer → regression（`npm test`, evals）→ adversarial review（`/code-review` 対抗レビュー）→ outcome-grader（STABLE rubric、Write/Edit 不可）→ 品質ゲート。改善前より悪化する変更は採用しない。

## 7. 主要ファイル

| 領域 | パス |
|---|---|
| Capability | `config/claude-code-compat.json`, `lib/claude-capability.sh`, `libexec/diag-claude-compat.sh` |
| PostgreSQL | `lib/postgres.sh`, `bin/pg-ops.sh`, `libexec/diag-postgres.sh`, `Claude/templates/linux/pg-*.tmpl`, `.env.example` |
| Router / Agents | `scripts/tools/agent-router.js`, `config/agent-catalog.json`, `.claude/agents/`, `Claude/templates/claudeos/agents/CATALOG.md` |
| Context | `CLAUDE.md`, `.claude/rules/`, `Claude/templates/claudeos/policy/`, `Claude/templates/claude/skills/` |
| Hooks | `Claude/templates/claudeos/scripts/hooks/`（正本）, `.claude/settings.json`, `scripts/hooks-settings.test.js` |
| SDLC / Evals | `Claude/templates/claudeos/sdlc/`, `tests/evals/`, `scripts/agent-router.test.js` |
| Observability | `scripts/dashboards/serve-dashboard.js` (`/api/v10`), `mission-control.html` |
