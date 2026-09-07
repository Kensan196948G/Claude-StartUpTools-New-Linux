# SELF_IMPROVEMENT_ARCHITECTURE — Eval-driven Self-Improvement

状態: v10（2026-09-07）。正式機能。
正本: `Claude/templates/claude/skills/improver/SKILL.md`、`tests/evals/*.json`、`scripts/*.test.js`

## 1. 構造

```text
Base Skill → Execution → Observation → Human / Machine Feedback → Evaluation
  → Improver Skill → Improvement Proposal → Regression Eval → PR → Quality Gate → Merge
```

| 段階 | 実体 |
|---|---|
| Observation | `state.json`（learning.failure_patterns / success_patterns、execution.routing_log、warnings）、`.claude/claudeos/data/reasoning-bank.json`、`audit-log.jsonl`、KPI（measure-kpi、間引き実行） |
| Feedback | PR / Issue のレビューコメント（人間）、CI 結果、outcome-grader の STABLE 判定（機械） |
| Evaluation | golden eval（`tests/evals/agent-router.golden.json`）、bats / node テスト、比較指標（quality / correctness / regression / CI pass 率 / latency / token / cost / failure 率 / repair 率） |
| Improver | `/improver` skill（Repeated Evidence ≥ 2、対象を 1 つに絞る、変更前後を計測） |
| Proposal | 作業 branch + PR（`self-improvement` ラベル、証拠 / 変更 / eval 比較 / リスク / rollback） |
| Gate | 通常の品質ゲート + 人間レビュー。自己改善結果は main へ直接反映しない（Approval PR 相当） |

## 2. 改善対象

Skill、Agent instruction、Workflow、Routing policy（`agent-router.js` の決定表）、Test strategy、Prompt（START_PROMPT / policy）、Documentation、Recurring failure handling。

## 3. 要件

- **Repeated Evidence**: 1 回の失敗だけで永久ルールを追加しない（同一パターン ≥ 2 回、または人間の明示指示）
- **Measurable Improvement**: 変更前後で eval / テスト / KPI を比較し、数値で示す
- **Regression Safety**: golden eval・既存テストが悪化する変更は採用しない。悪化時は Issue 化に留める
- **Verification-First**: Generator（改善を作る Agent）と Verifier（eval / reviewer / outcome-grader）を分離する

## 4. Eval 資産

| eval | 対象 | 実行 |
|---|---|---|
| `tests/evals/agent-router.golden.json`（14 ケース + 不変条件 3） | Routing policy | `node --test scripts/agent-router.test.js` |
| `tests/bats/unit/goal-inject.bats` | /goal テンプレの上限・整合 | bats |
| `tests/bats/unit/claude-capability.bats` | Capability Detection | bats |
| `tests/bats/unit/postgres.bats` + 実機 restore drill | DB 運用 | bats / `bin/pg-ops.sh restore-drill` |
| `scripts/hooks-settings.test.js` | hooks 配線・権限不変条件 | node --test |

新しい skill / router 変更を提案する場合は、対応する golden ケースを追加してから変更する。

## 5. 運用

- 週次: `/skill-doctor`、routing_log、failure_patterns を確認し、Improver を起動するか判断する
- Improver の提案は 1 PR 1 改善。マージ後に次回 eval のベースラインを更新する
- 旧 v9 の reasoning-bank / trust ledger / dreaming（Managed Agents research preview）は観測源として維持し、判定は eval と人間レビューに委ねる
