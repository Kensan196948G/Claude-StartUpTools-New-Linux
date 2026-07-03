# Goal: PR Babysit（PR 番人マイクロループ）

短時間（15〜30 分）の cron ジョブ用。open PR の CI 失敗・レビュー指摘対応だけを行い、
新規開発は一切しない。5 時間メガセッションの間に PR を放置しないための番人。

/goal "
■ Goal
open PR の CI 失敗とレビュー指摘を解消し、マージ可能状態へ前進させる（新規開発はしない）。

■ Priority
CTO優先順位テーブル (CLAUDE.md §5.1) の優先度2: CI 失敗中の原因分析 + 最小差分修復

■ Success Criteria
- open PR が 0 件、または全 open PR が「CI green かつ未対応 Critical/High 指摘 0」

■ Scope
対象: open PR の CI 修復・レビュー指摘対応・conflict 解消・auto-merge 条件確認
対象外: 新機能実装・リファクタリング・新規 Issue 着手・依存更新・大規模ドキュメント更新
許可操作: 最小差分の修正 commit/push・PR コメント返信・Issue 起票

■ Execution Strategy
1. gh pr list --state open で対象確認（0 件なら直ちに終了処理へ）
2. 各 PR: CI 失敗 → 最小差分で修復 push / Critical・High 指摘 → 修正 push / conflict → Update branch
3. 修正が大規模化する場合は Issue 起票して当該 PR は skip（深追い禁止）

■ Forbidden Changes
- 新機能・リファクタリング・依存更新
- main への直接 push・人間最終決断領域の操作（main 宛 merge は auto-merge-protocol.md に従う）

■ Constraints
- 時間上限: cron の duration（15〜30 分）以内
- 同一 PR への修復: 最大 2 回（超過時は Issue 起票して skip）

■ Stop Conditions
正常終了:
- Success Criteria 達成、または対応可能な PR が残っていない
- 上記の測定可能基準を満たした時点で、残り時間・残ターンがあっても直ちに終了処理へ進んでよい（早期終了）
異常終了（Failure）:
- 同一 PR への修復 2 回失敗 → Issue 起票して skip
- or stop after 8 turns
"
