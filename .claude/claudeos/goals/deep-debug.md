# Goal: Deep Debug（Primary Goal）

CI 失敗・Runtime Error・Regression・API/DB/認証/Build/Deployment/E2E 失敗・本番障害・原因不明の不具合の根本原因解析。
Specialized: `hotfix`（保守期の最小差分修正）/ `security-emergency`（Critical 脆弱性）。

/goal "
■ Goal
再現 → 観測 → 仮説 → 切り分け → 根本原因 → 最小修正 → 回帰テスト → 全体検証 → 証拠。症状だけを抑える修正は禁止。

■ Use When
CI Failure / Runtime Error / Regression / API・DB・認証・Build・Deployment・E2E 失敗 / 本番障害解析 / 原因不明の不具合。Router: ci=failure、intent が「直して・バグ・エラー・回帰」、Blocker あり。

■ Priority
1 Security Critical（security-emergency へ）→ 2 本番影響のある障害（hotfix）→ 3 CI 失敗 → 4 Regression → 5 その他不具合

■ Success Criteria
- 再現手順と観測結果（ログ・スタック・失敗テスト）を記録
- 根本原因を特定し、原因と修正の対応を説明できる
- 最小差分で修正し、再発防止の回帰テストを追加
- 影響範囲の回帰テスト・CI 成功、PR 作成

■ Scope
対象: 不具合の原因箇所と直接影響範囲、回帰テスト
対象外: リファクタリング、新機能、無関係な変更、スキーマ変更（必要なら別 PR + Approval）

■ Execution Strategy
Reproduce → Observe → Hypothesis → Isolate → Root Cause → Minimal Fix → Regression Test → Full Verify → Evidence
同一原因への修復を 2 回失敗したら仮説を捨てて再観測する。

■ Agent Strategy
Debugger（原因分析、read-only 並列可）/ Backend / QA / 必要時 Security。修正は 1 Agent に集約し競合を避ける。

■ Validation
失敗していたテスト・CI が成功し、追加した回帰テストが修正前に失敗・修正後に成功することを確認。

■ Evidence Output
- 再現手順 / 根本原因 / 修正コミット SHA / 回帰テスト名 / CI Run URL / 影響ファイル一覧

■ Constraints
- 症状抑制（try/catch 握り潰し・テスト skip・retry 無限化）禁止
- 同一エラー同一原因 2 回連続 → 即停止 + RCA Issue、修復試行 3 回で Blocked

■ Stop Conditions
正常終了: 根本原因修正・回帰テスト追加・CI 成功・PR 作成 → 早期終了可
異常終了: 修復上限到達 / 再現不能で追加情報が必要 / 権限不足 → Blocked + Issue（Evidence・Root Cause 候補・Attempts・Recommended Action）
- or stop after 12 turns
"
