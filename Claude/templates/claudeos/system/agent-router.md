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

## Managed Agents（クラウド補完・opt-in）

入力に `managed` ブロックを付けた場合だけ評価する。ブロックが無ければ上の決定表の出力は一切変わらない。Local Claude Code が主系で、Managed Agents は次を**すべて**満たすタスクの補完先に限る。

| 区分 | 条件 |
|---|---|
| 安全条件（policy） | `read_only=true`、`risk=low`（省略不可）、security / database / deployment が low、`managed.human_gate=false`・`managed.requires_secrets=false`・`managed.requires_external_network=false` と `managed.data_sensitivity`（public / internal）を**明示**、Agent 間通信なし、task_type が許可リスト内（review / code-review / diff-analysis / qa-analysis / test-generation / triage / docs / research / check）、所要時間が 30 分以内 |
| 容量条件（capacity） | Managed Agents が利用可能（設定・認証）、予算状態が ok / warn（verify-only は `check` のみ）、同一タスク ID が未実行 |
| 選択条件 | 明示要求（`managed.requested=true`）がある、または Local が利用できない（`managed.local_available=false`）。**Local が稼働中というだけでは並列起動しない** |

- 安全条件は fail-closed。省略された確認項目、真偽値でない値（`"yes"` など）、未知のレベル文字列（`"severe"` など）は拒否に倒す。呼び出し側は許可リストと時間上限を狭められるが、広げられない。
- 条件を満たして選択された場合のみ `execution: "ManagedAgent"`。それ以外は上の決定表の結果のまま。
- `managed.fallback_execution` に Local 側の決定を常に保持する（API 障害・予算不足時の戻り先）。
- `managed.policy_denied=true` は安全上の拒否。フォールバックや別経路で承認・拒否を回避しない。
- Router は純関数。可用性・予算・重複の証拠は `scripts/tools/managed-agents.js route` が集めて渡し、決定を `~/.claudeos/managed-agents/decisions.jsonl` に記録する。

## 記録

`state.json.execution.routing_log`（最新 20 件）に `{at, execution, worktree, reasons, task_type}` を残し、Mission Control と最終報告で「なぜその Agent を使ったか」を追跡できるようにする。
