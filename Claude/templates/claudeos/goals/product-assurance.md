# Goal: Product Assurance（Primary Goal）

Release 前の総合品質保証。E2E 成功だけを「完了」と扱わず、Web/API/DB/Auth/AI/Infra/Operation を横断して保証する。
Specialized: `production-release`（deploy.ready 到達）/ `safe-auto-merge` / `pr-babysit`。

/goal "
■ Goal
プロダクト全体の品質を多面的に検証し、欠陥を修正し、Release 判定に必要な証拠を揃える。

■ Use When
Release 前総合品質保証 / Golden Dataset / AI Evaluation / Fail-Safe / Contract Test / Migration Test / Recovery Test / Security Test / Accessibility / Performance / Backup・Restore / Chaos・Fault Injection / Auditability。Router: stable_achieved=true、execution.phase=Release、intent が「総合テスト・品質保証・リリース判定」。

■ Priority
1 データ整合性・復旧（Migration / Backup / Restore）→ 2 Security → 3 認証認可・Contract → 4 E2E・回帰 → 5 Performance → 6 Accessibility → 7 Auditability

■ Success Criteria
- 検証マトリクス（領域 × 手段 × 結果）を作成し、各項目に証拠を紐付け
- Migration の空 DB 再実行、backup → restore drill の PASS
- Security scan Critical/High ゼロ、認証認可の権限差テスト成功
- E2E 主要シナリオ・回帰・Contract テスト成功、性能・A11y の基準値記録
- 発見した欠陥は修正 PR または P1 Issue 化。Release 判定（GO / CONDITIONAL GO / NO-GO）を提示

■ Scope
対象: テスト追加、Fail-Safe・回復手順、検証スクリプト、欠陥修正、品質文書
対象外: 新機能、大規模リファクタ、本番デプロイ実行、Secrets 変更

■ Execution Strategy
検証計画（test-plan / eval-plan）→ 領域別検証 → 欠陥修正 → 再検証 → Release 判定 → 証拠整理
読み取り・検証は SubAgent 並列化。修正は競合を避けて逐次。

■ Agent Strategy
QA / Security / ReleaseManager / Audit / DevOps。Verifier（outcome-grader）は Generator と分離。

■ Validation
各検証を再現可能なコマンド・スクリプトにし CI へ組み込む。「backup が存在する」は成功ではなく restore 成功が成功。

■ Evidence Output
- 検証マトリクス / CI Run URL / restore drill 結果 / security scan 結果 / 性能・A11y 計測値 / Release 判定と残リスク

■ Constraints
- Human Gate: 本番デプロイ・Secrets・DNS・破壊的 DB 操作は実行せず deploy.ready と Runbook まで
- 検証を省略して判定しない。未実施は UNVERIFIED と明記

■ Stop Conditions
正常終了: 検証マトリクス完了・欠陥修正済み・Release 判定提示（GO なら production-release へ引継ぎ）→ 早期終了可
異常終了: Security Critical → security-emergency / 修復上限・権限不足 → Blocked + Issue
- or stop after 15 turns
"
