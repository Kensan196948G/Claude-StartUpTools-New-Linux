# Monitor Loop

## Role
システム状態と品質の監視。

---

## 過去判断の参照（Monitor 冒頭・必須）

実装計画を立てる前に、過去に却下された案・失敗パターンを検索して突合する:

- `.claude/claudeos/data/reasoning-bank.json` の failure / success パターン
- Memory MCP の当該プロジェクト記録
- `state.json` の `learning.failure_patterns` / `blocked_issues`

却下済み・失敗済みの案は再提案しない。突合結果に反する計画を立てる場合は、
その理由を Session Report の Risks に 1 行で記録する。

---

## Checks

- CI status
- test results
- lint
- typecheck
- security warnings
- token usage
- retry count

---

## Trigger

- ループ開始時
- 各フェーズ終了後
- CI実行後

---

## Actions

- 状態収集
- 異常検知
- リスク判定

---

## Output

`reports/.loop-monitor-report.md`

> 配布先プロジェクトで `reports/` ディレクトリが未作成の場合、本レポートの
> 書き出し前に `New-Item -ItemType Directory reports -Force` で作成すること。

---

## Next

- 異常あり → Verify Loop
- 正常 → Build Loop

---

## 5h Rule

- 状態ログを必ず保存