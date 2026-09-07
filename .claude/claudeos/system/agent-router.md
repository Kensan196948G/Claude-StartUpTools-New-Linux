# Agent Orchestration Router (ClaudeOS v10)

CTO の前段で実行形態を決める決定表。実装は `scripts/tools/agent-router.js`（決定論的・golden eval 付き）、手順は `.claude/skills/agent-router/SKILL.md`。

## 決定表

| 条件 | 実行形態 | 補足 |
|---|---|---|
| 大量調査 / 監査 / migration で files ≥ 50 または parallelism ≥ 4 | Dynamic Workflow | `/workflows`。相互検証を組み込む |
| Agent 間通信が必要 かつ 並列 かつ 高リスクでない | Agent Teams | 実験機能。3〜5 teammate、ファイル所有権分割 |
| Agent 間通信が必要 だが 高リスク | Main | 人間可視性を優先 |
| 独立した長時間作業 (≥30 min) が複数 (shared_files=false) | Agent View | `claude --bg` ×N を `claude agents` で監視 |
| 独立した長時間作業 (≥30 min) が 1 つ | Background Agent | `claude --bg` / `/background` |
| 小規模 (complexity=low, files ≤ 3, < 30 min) | Main | |
| 高リスク (security/database/deployment/risk ≥ high) の書込み | Main | Human Approval Gate |
| 限定された独立作業 (files ≤ 20) または read-only | Subagent | 結果だけ受け取る |
| その他 | Main | |

Worktree: 並列書込み、Background Agent の書込み、Agent View は常に git worktree 分離。

## 記録

`state.json.execution.routing_log`（最新 20 件）に `{at, execution, worktree, reasons, task_type}` を残し、Mission Control と最終報告で「なぜその Agent を使ったか」を追跡できるようにする。
