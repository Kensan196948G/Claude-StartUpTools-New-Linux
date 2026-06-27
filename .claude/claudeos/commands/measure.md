# /measure

現在のプロジェクト状態を測定し、Goal 進捗・品質・安全性・AI 組織活動の KPI スナップショットを出力するコマンドです。

## KPI 収集スクリプト

```bash
node scripts/tools/measure-kpi.js
```

`state.json.metrics` を GitHub CLI (`gh`) 経由で自動更新します。  
SessionStart / SessionStop フックから自動呼び出しされます。

## 出力形式

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

## 使い方

```
/measure
```

- セッション開始直後にスナップショットを取得する
- フェーズ終了時・PR マージ後に再実行すると変化量が把握できる
- `state.json.metrics.last_measured_at` に最終更新時刻が記録される

## KPI 4 軸

| 軸 | 主要指標 | 目標 |
|---|---|---|
| Output (開発成果) | `session_completed_tasks` / `session_prs_created` | tasks ≥ 3, PRs ≥ 1 |
| Quality (品質) | `ci_success_rate` / `test_success_rate` | CI ≥ 90%, test ≥ 95% |
| Safety (安全性) | `human_approval_pending` / Security Critical | pending ≤ 3, critical = 0 |
| Learning (自己改善) | `improvement_adoption_rate` / Agent Scorecard | adoption ≥ 60% |

## 参照

- KPI 定義: `docs/claude/15_AI進歩測定とKPI.md`
- AI 組織設計: `docs/claude/16_AI組織設計.md`
- 自己改善ガード: `docs/claude/17_自己改善ガード.md`
