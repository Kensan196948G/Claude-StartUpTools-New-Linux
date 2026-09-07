# Goal: Development（Primary Goal）

既存 Project の通常開発・継続改善。Goal Router の Primary Goal 5 分類の 1 つ。
Specialized: `refactoring`（技術的負債）/ `hotfix`（保守期の緊急修正）。

/goal "
■ Goal
既存プロダクトの価値と品質を両立して前進させる。P0/P1 を最優先し、価値の高い P2 を実装して検証済み PR まで到達する。

■ Use When
機能追加 / 継続改善 / UI・UX 改善 / API・DB 改善 / 運用改善 / 技術的負債解消 / 既存サービスの価値向上。Router: intent が「作って・実装・改善」、または phase_mode=maintenance|released で重大障害なし。

■ Priority
CTO 優先順位: 1 Security Critical → 2 CI 失敗 → 3 Blocker → 4 Goal 直結 Issue(P0/P1) → 5 品質不足 → 6 改善(P2)

■ Success Criteria
- 対象 Issue/要求の受入条件を満たし、既存機能に回帰なし
- lint / 型検査 / 単体・統合テスト / build 成功、必要なら E2E 成功
- 変更したモジュールにテストを追加、docs（README / API / 運用）を同一 PR で更新
- PR 本文（目的・変更・影響・テスト・セキュリティ・rollback）完備、CI 全成功

■ Scope
対象: 選定した P0/P1/P2 の実装、関連テスト・文書、小規模リファクタ
対象外: 大規模アーキテクチャ変更、新技術導入、認証方式・課金・公開範囲の変更（Approval PR）

■ Execution Strategy
Monitor → Assessment → Gap Discovery → Prioritization → Development → Verify → Review → Improvement → Re-assessment
1 Round = 1 論理単位。前 Round の差分・テスト・Issue を引き継ぎ、同じ調査を繰り返さない。

■ Agent Strategy
既定: Architect（設計判断）/ Backend / Frontend / QA / Reviewer。必要時のみ DB / Security / DevOps。
並列書込みは worktree 分離。同一ファイル・migration・lockfile への同時書込み禁止。

■ Validation
Gate-1: 各 Verify で lint/test/build。Gate-2: PR 前に独立 QA + code-review。DB 変更は空 DB へ migration 再実行。

■ Evidence Output
- CI Run URL / テスト件数 / 変更ファイル一覧（git diff --stat）/ PR URL / 残課題 Issue

■ Constraints
- 同一エラー同一原因 2 回連続 → RCA、同一戦略 3 回失敗 → 戦略変更
- 修復試行 5 回で Blocked + Issue 化。main 直接 push / force push / --no-verify 禁止

■ Stop Conditions
正常終了: 選定タスクが受入条件を満たし CI 成功・PR 作成（自動マージ条件充足時は squash merge）→ 早期終了可
異常終了: Security Critical 検出（security-emergency へ）/ 修復上限到達 / 認証・権限不足 → Blocked と Issue 化
- or stop after 20 turns
"
