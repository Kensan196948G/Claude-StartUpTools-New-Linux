# AI_NATIVE_SDLC — 標準開発フローと規模別縮退

状態: v10（2026-09-07）
正本: `Claude/templates/claudeos/sdlc/*.md`、`Claude/templates/claude/skills/sdlc-scale/SKILL.md`

## 1. フロー

```text
Intent → Specification → Plan → Implementation → Tests → Evals → Review → PR → CI/CD → Monitoring → Feedback → Improvement → Next Intent
```

| 段階 | 成果物 | 担当 / Native 機能 | 計測 |
|---|---|---|---|
| Intent | `intent.md` | Product owner / CTO。`/sdlc-scale` で規模判定 | conversation → committed intent の時間 |
| Specification | `spec.md` | CTO + architect（catalog）。security / compliance 制約を書きながら適用 | intent → spec の時間、build 後の要件手戻り |
| Plan | `plan.md` | plan mode（読み取り専用）、`/agent-router` で実行形態 | first-pass merge 率 |
| Implementation | code | Main / Subagent / Background / Worktree | rework 回数 |
| Tests | `test-plan.md` | `/verify`、bats / node、migration の空 DB 再実行 | first-pass CI 成功率 |
| Evals | `eval-plan.md` | golden eval（router / skills） | eval pass 率 |
| Review | `review-report.md` | `/code-review`、security-reviewer、adversarial、outcome-grader | review 時間 / PR |
| PR / CI/CD | PR 本文 12 項目、Required Checks、Squash merge | `/release-flow`、GitHub Actions | 時間 to first review、merge 前検出率 |
| Monitoring | Mission Control（v10 パネル）、health / backup / drill | ClaudeOS | breach → intent の時間 |
| Feedback / Improvement | `/improver`、reasoning-bank | Self-Improvement | 再発率 |

## 2. 規模別の縮退・拡張

| 成果物 | S（≤3 files, <30min, 挙動変更なし） | M（≤20 files, additive DB） | L（architecture / DB / auth / deploy / security 影響） |
|---|---|---|---|
| intent.md | PR 本文で代替 | ○ | ○ |
| spec.md | 不要 | 受入条件のみ | ○ |
| plan.md | 不要 | ○ | ○（plan mode） |
| architecture.md | 不要 | 不要 | ○（ADR） |
| test-plan.md | 既存テスト実行 | ○ | ○ |
| eval-plan.md | 不要 | skill / router 変更時 | ○ |
| review-report.md | /code-review | + security-reviewer | 独立 QA + security + adversarial + outcome-grader |
| release-report.md | PR 本文 | ○ | ○ + rollback 演習 |

L で成果物が欠ける PR は品質ゲート未達。S に全成果物を強制しない。

## 3. ガバナンスとの接続

- 成果物連鎖（intent → spec → plan → PR → release-report）が監査証跡。Git 履歴が「誰が何を求め、何が作られ、誰が承認したか」を記録する
- 高リスク変更は `/approval-pr`。Human Approval Gate は `AI開発ガバナンス仕様.md`
- 本番 DB の破壊操作は `pg-ops.sh migration-risk` で機械的に検出し、SDLC の Plan 段階で Approval PR に分離する

## 4. 置き場

各プロジェクトでは `docs/sdlc/<slug>/` に成果物を置く。テンプレートは `.claude/claudeos/sdlc/`（init で配布）。
