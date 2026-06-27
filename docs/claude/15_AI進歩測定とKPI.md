# 15. AI 進歩測定と KPI

Google DeepMind 論文「From AGI to ASI」(2026-06-12) の知見を参考に、
ClaudeOS を「動いているだけ」ではなく **成果・品質・安全性・自己改善を測りながら進化させる** ための指標体系。

## 目的

シンギュラリティを「来る/来ない」の予言ではなく測定対象として扱うように、
このプロジェクトの AI 自律開発も **予言から測定へ** 移す。

## KPI カテゴリ

### 1. 開発成果（Output）

| 指標 | state.json フィールド | 目標 |
|---|---|---|
| セッションあたり完了タスク数 | `metrics.session_completed_tasks` | セッション ≥ 3 |
| セッションあたり PR 作成数 | `metrics.session_prs_created` | セッション ≥ 1 |
| Issue 完了率 | `metrics.issue_completion_rate` | 月次 ≥ 80% |

### 2. 品質（Quality）

| 指標 | state.json フィールド | 目標 |
|---|---|---|
| CI 成功率 | `metrics.ci_success_rate` | ≥ 90% |
| テスト成功率 | `metrics.test_success_rate` | ≥ 95% |
| STABLE 判定達成数 | `stable.consecutive_success` | N=3 通常 |

### 3. 安全性（Safety）

| 指標 | state.json フィールド | 目標 |
|---|---|---|
| 人間承認待ち件数 | `metrics.human_approval_pending` | 常時 ≤ 3 |
| Security Critical 残件 | `codex.blocking_issues` | 常時 0 |
| 同一エラー再発回数 | `metrics.same_error_recurrence_count` | ≤ 1 |

### 4. 自己改善（Learning）

| 指標 | state.json フィールド | 目標 |
|---|---|---|
| 改善提案採用率 | `metrics.improvement_adoption_rate` | ≥ 60% |
| 失敗パターン記録数 | `learning.dead_weight.candidates_pending_issue` | 継続蓄積 |
| Agent Scorecard 成功率 | `metrics.agent_scorecard.<name>.success_rate` | ≥ 80% |

## 測定サイクル

```text
セッション開始  → /measure でスナップショット取得
セッション中    → 各フェーズ終了時に state.json.metrics を更新
セッション終了  → /measure で最終スナップショット取得・比較表示
月次            → improvement_adoption_rate・issue_completion_rate を算出
```

## /measure コマンドの出力形式

`/measure` を実行すると以下を表示する（実装: `commands/measure.md`）。

```text
[ClaudeOS Progress Snapshot]
Goal:               <title>
Goal 進捗:          <完了 Issue 数> / <全 Issue 数>
CI 成功率:          <値>%
テスト成功率:       <値>%
直近 STABLE 回数:   <値>
人間承認待ち:       <値> 件
Security Critical:  <値> 件
同一エラー再発:     <値> 回
改善採用率:         <値>%
Agent Teams 活動:   <上位 3 Agent>
次の改善ポイント:   <1 文>
```

## state.json との対応

`state.json.example` の `metrics` ブロックが KPI の収容場所。
実 `state.json` は gitignore 対象のため、セッションごとに上書き更新してよい。

```json
"metrics": {
  "session_completed_tasks": 0,
  "session_prs_created": 0,
  "ci_success_rate": null,
  "test_success_rate": null,
  "issue_completion_rate": null,
  "improvement_adoption_rate": null,
  "human_approval_pending": 0,
  "same_error_recurrence_count": 0,
  "agent_scorecard": {},
  "last_measured_at": null
}
```

## 参照

- Google DeepMind 論文: <https://deepmind.google/research/publications/239142/>
- arXiv 本文: <https://arxiv.org/html/2606.12683v1>
- 関連設計: `docs/claude/16_AI組織設計.md` / `docs/claude/17_自己改善ガード.md`
- コマンド: `Claude/templates/claudeos/commands/measure.md`
