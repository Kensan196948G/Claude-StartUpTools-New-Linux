# AGENT_ORCHESTRATION — Lazy Agent Architecture と Agent Router

状態: v10（2026-09-07）
正本: `config/agent-catalog.json`、`scripts/tools/agent-router.js`、`tests/evals/agent-router.golden.json`、`Claude/templates/claudeos/system/agent-router.md`

## 1. 原則

```text
必要な Agent だけ / 必要な時だけ / 必要な Context だけ
```

- `.claude/agents` に置くのは first-class 9 体だけ（description が常時 context に載るため）。残りは Catalog として保持し、Read で本文を読んで Agent tool の prompt に渡す
- 既存 43 agents は削除しない。merge / remove-candidate は deprecated として保持し Self-Improvement で整理する
- Agent Teams は「Agent 間の相互通信が本当に必要」な場合に限定。同一ファイルを複数 Agent へ同時割当しない

## 2. Router（CTO の前段）

入力: task_type / complexity / risk / files_affected / expected_duration_min / parallelism / security_impact / database_impact / deployment_impact / needs_inter_agent_communication / shared_files / read_only

出力: execution ∈ {Main, Subagent, BackgroundAgent, AgentView, AgentTeams, DynamicWorkflow}, worktree, reasons[], guardrails[]

決定表は `system/agent-router.md`。決定は `state.json.execution.routing_log`（最新 20）に記録し、Mission Control の v10 パネルと最終報告で「なぜその Agent を使ったか」を追跡する。golden eval 14 ケース + 不変条件（高リスクで Agent Teams を選ばない、並列書込みは worktree 必須）を `node --test scripts/agent-router.test.js` で検証する。

## 3. Native 実行形態との対応

| execution | Claude Code Native | 使い方 |
|---|---|---|
| Main | 現セッション | 小規模・高リスク（人間可視） |
| Subagent | Agent tool（Explore / general-purpose / first-class agent） | 独立した限定作業、結果だけ受け取る |
| BackgroundAgent | `claude --bg --name <task> [--worktree]` / `/background` | 独立した長時間作業 |
| AgentView | 複数の `claude --bg` + `claude agents` | 複数の独立長時間作業の監視 |
| AgentTeams | `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`（in-process / tmux） | 相互通信が必要な協調作業。3〜5 teammate、plan 承認 |
| DynamicWorkflow | `/workflows`, `ultracode`, `.claude/workflows/*.js` | 大量調査・大規模監査・相互検証 |
| worktree | `--worktree`, `isolation: worktree`, `.worktreeinclude` | 並列コード編集の分離 |

## 4. First-class Agents（`.claude/agents`）

| agent | 責務 | 補足 |
|---|---|---|
| cto | 統括・優先順位・Phase Gate・リリース判定 | team モードの CTO ペイン |
| manager | Issue 生成 / Projects 遷移 | |
| code-reviewer | 汎用レビュー | 言語 rubric は skills で付与 |
| security-reviewer | 独立セキュリティレビュー | Verify / Release ゲート |
| ci-manager | CI 失敗の原因分析と最小修復 | |
| outcome-grader | STABLE rubric による独立判定 | `haiku`、Write/Edit 不可（Verifier 分離） |
| e2e-runner | E2E 実行 | |
| audit-agent | 変更証跡・規格準拠 | Verify 末尾 / Release 前 |
| cmdb-agent | 構成・依存・影響分析 | Monitor 末尾 |

Catalog（必要時ロード）: api-designer / architect / build-error-resolver / database-reviewer / doc-updater / performance-reviewer / qa / release-manager / tdd-guide。

## 5. Generator / Verifier 分離

Implementation Agent が自分の変更だけを根拠に成功判定しない。独立 QA → security-reviewer → regression（`npm test` / evals）→ adversarial review（`/code-review` 対抗）→ outcome-grader → 品質ゲート。

## 6. 失敗制御

同一 failure ×2 → Root Cause Analysis、同一 strategy ×3 失敗 → Strategy Change、回復不能 → BLOCKED（Evidence / Root Cause / Attempts / Recommended Action / Human Decision Required）。無限ループ禁止。
