# Goal: MVP Release（Primary Goal）

新規 Project / Prototype / PoC / MVP / 主要機能未完成の最小実用版構築。
Specialized: `production-release`（MVP 完成後の本番準備）。
従来（v9 以前）の既定 goal_type。goal_router 不在の古い state.json でもこのファイルが使われる。

/goal "
■ Goal
承認済み要件と UI 設計（OpenDesign 等がある場合）に基づき、主要 User Journey を実操作できる MVP を完成させ、リリース判定を受ける。

■ Use When
新規 Project / Prototype / PoC / MVP / 主要機能未完成 / 最小実用版。Router: state 不在・CI やテスト未整備・コミット数が少ない、intent が「MVP・PoC・最小版・新規」。

■ Priority
1 主要 User Journey → 2 実動作 → 3 Auth / Data Integrity → 4 CI → 5 E2E → 6 Security → 7 Documentation → 8 UI 改善

■ Success Criteria
- 主要業務フローが実操作可能（正常・空・エラー・権限別状態を確認可能）
- API 疎通・認証認可・DB CRUD 成功、ローカル PostgreSQL の Migration/Seed を空 DB へ再実行可能
- CI 成功、Critical/High 脆弱性ゼロ、E2E core シナリオ成功
- README / 要件・設計・API・DB・運用文書更新、ローカル環境再現可能

■ Scope
対象: MVP に必要な主要機能・API・認証・DB・基本 UI・CI
対象外: 過剰な UI 改善、Enterprise 拡張、AI 最適化、マイクロサービス分離、大規模リファクタ、新技術導入

■ Execution Strategy
Monitor 15% → Build 40% → Verify 30% → Improve 15%。動作 → 安定性 → セキュリティ → 保守性 → UI の順。

■ Agent Strategy
CTO → Backend + Frontend + QA 並列（worktree 分離）。Design（画面遷移・Responsive・A11y）/ Database / Security / DevOps は必要時。

■ Validation
Gate-1（Verify 毎回: lint/test/build）+ Gate-2（PR 前: API 正常系 + 認証フロー + E2E core）。ホスト側 Preview で UI・API・認証・DB 接続確認。

■ Evidence Output
- CI Run URL / E2E 結果（passed/failed）/ security scan（Critical/High 件数）/ README 更新コミット / PR URL

■ Constraints
- 時間上限 5 時間、修復試行 5 回（超過で Blocked + Issue）
- 過剰リファクタ・新技術導入禁止。本番デプロイ・Secrets・DNS は Human Gate

■ Stop Conditions
正常終了: MVP 完成条件全達成・CI 成功・PR 作成（自動マージ条件充足時は squash merge）→ 早期終了可
異常終了: 修復試行 5 回到達 → Blocked + Issue / Critical 脆弱性未解消 → 停止 + P1 Issue
- or stop after 20 turns
"
