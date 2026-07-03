# Loop Guard
## Role
無限ループ防止と強制停止。全システムに対して最優先で適用される。

## Monitoring（プロジェクトごとに独立管理）
- セッション開始時刻・経過時間
- retry回数（PR単位）
- 同一エラーの連続発生回数
- CI失敗数（PR単位）
- Blockedステータス継続時間

## Stop Conditions
- 5時間到達：セッション開始からの経過時間
- same error 連続3回：直前3回のループで同一エラー文字列が一致
- CI retry 同一PR 5回：同一PRへのActions再実行が5回到達
- security issue：severity critical / high の検知（件数不問）
- Blocked継続30分：Blockedステータスが30分以上継続

## Actions（実行順序厳守）
1. 新規ループ発火の禁止
2. 実行中SubAgentへの停止通知（完了待ち）
3. git commit（WIPラベル付き）
4. .loop-stop-report.md 出力
5. GitHub Projects Status を実態に合わせて更新
6. CTO通知（GitHub Issue コメント）

## Output
`.loop-stop-report.md`（プロジェクトルートに配置、フォーマット固定）

## Priority
Loop Guard > 全システム（CTO・Architect・Developerの判断より優先）

## ループ4分類（トリガー / 停止条件 / 適するタスク）

| ループ型 | トリガー | 停止条件 | 適するタスク |
|---|---|---|---|
| ターンベース | ユーザープロンプト / cron 起動 | タスク完了 / context 枯渇 | 短期・非定期の単発作業 |
| ゴールベース（/goal） | /goal 設定 | 成功基準達成 or stop after N turns | 測定可能な達成条件がある開発 |
| 時間ベース（間隔実行） | 一定間隔 | 明示停止・対象消滅 | PR 追跡・CI 監視などの定期確認 |
| プロアクティブ | スケジュール / イベント | 対象キューが空 | バグ分類・依存更新などの無人定型作業 |

### ループ選定原則

- 小タスクに 5 時間セッションやマルチエージェントを使わない（1 ターンで済む作業は Sub-agent）
- 実行頻度は対象の実際の変化周期に合わせる（変化しない対象を高頻度でポーリングしない）
- 成功基準は決定論的（テスト件数・スコア閾値・エラー 0）に書き、早期終了を可能にする
