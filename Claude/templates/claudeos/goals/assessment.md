# Goal: Assessment（Primary Goal）

評価・全体確認・Readiness / Architecture / Security Review・Gap 分析。調査だけで終わらず、選定した改善を実装して Before/After を示す。
Specialized: `security-emergency`（評価中に Critical を発見した場合）。

/goal "
■ Goal
現状を証拠付きで採点し（Before Score）、Gap を優先順位付けし、評価目的の範囲で実装可能な改善を実施して After Score を示す。

■ Use When
「評価して」「全体確認」「レビュー」「監査」「比較」、Production Readiness 評価、Architecture / Security Review、Feature Gap 分析、競合比較、技術的負債評価、追加機能企画。

■ Priority
評価軸: 動作 → 安定性 → セキュリティ → 保守性 → 運用性 → UX。Security Critical を見つけたら評価を中断し security-emergency へ切替。

■ Success Criteria
- Before Score（軸別 0-5 と根拠）と Evidence（コマンド出力・CI・テスト・ファイル参照）
- Gap 一覧を P0/P1/P2 で優先順位付けし Issue 化
- P0/P1 のうち評価範囲内で実装可能な改善を実装・検証（テスト・CI 成功）
- After Score と残課題、推奨ロードマップ

■ Scope
対象: リポジトリ・設計・CI・テスト・セキュリティ・運用文書の評価、小〜中規模改善
対象外: 評価目的を逸脱する大規模開発、アーキテクチャ全面変更、新技術導入

■ Execution Strategy
Before Score → Evidence Collection → Gap Analysis → Prioritization → 選定改善の実装 → Verify → After Score
読み取り中心の調査は SubAgent 並列化可。書込みは Main が統合。

■ Agent Strategy
Architect / Research / Reviewer / Security / Devil's Advocate（結論への反証）。実装は必要最小の Developer。

■ Validation
評価結果は根拠ファイル・行番号・コマンド出力で再現可能にする。改善は lint/test/build/CI で検証。

■ Evidence Output
- assessment レポート（docs/sdlc/<slug>/review-report.md 相当）/ Issue 一覧 / 改善 PR URL / Before・After Score

■ Constraints
- 推測で採点しない（未確認は UNVERIFIED と明記）
- 破壊的変更・Secrets・本番操作は行わない

■ Stop Conditions
正常終了: Before/After Score と改善 PR（または改善不要の根拠）を提示 → 早期終了可
異常終了: Security Critical 検出 → security-emergency / 認証・権限不足 → Blocked
- or stop after 15 turns
"
