/goal "【言語】
全工程を日本語で対応・解説してください。初動分析、計画、進捗、判断理由、SubAgent報告、検証結果、blocker、PR・リリース結果、最終報告も日本語を基本とします。コード、コマンド、API名、製品固有名、原文エラーは英語のままで構いませんが、意味・原因・対応を日本語で説明してください。英語だけの進捗・完了報告は禁止します。

【Goal】
本プロジェクトを、Claude Code、GitHub、ローカルPostgreSQL、Linuxホスト（systemd）、必要時のみCloudflare、OpenDesignを中核として、承認済み要件とOpenDesignの画面設計に基づき、主要業務フローを実操作できるMVPまで自律開発してください。調査・計画だけで終了せず、実装、検証、改善、PR、自動マージ、本番デプロイ、リリース後確認まで完了条件達成まで継続してください。

【正本・調査】
GitHubをソース、Issue、PR、CI/CD、設計・運用文書の正本、OpenDesignをUI/UX仕様、ローカルPostgreSQL（postgresql@16-main、Unix socket）をDB正本／Migration／Seed／検証DB、Linuxホストのsystemdをバックエンド実行基盤、Cloudflareを必要時のみPages／Access／Tunnel／DNSとして扱います。Workers／Pages FunctionsからローカルPostgreSQLへ直接接続しないでください。
CLAUDE.md、AGENTS.md等の指示、README、要件・設計・運用文書、ソース、設定、DB、API、テスト、CI/CD、Git履歴、Issue、PR、ライセンスを精査し、既存設計・技術スタック・デザインシステム・ユーザー変更を優先してください。

【Autonomous Engineering Loop】
以下を1 Roundとして、完了条件達成まで自律反復してください。
Monitor → Assessment → Gap/Feature Discovery → Prioritization → Design Analysis → Plan → Development → Integration → Verify → Visual/Functional/Accessibility Review → Improvement → Re-assessment → Completion Gate
各Roundで「対象課題、変更、検証方法、結果、証拠、残存課題、次Round」を日本語で整理してください。同じ失敗・調査を理由なく反復せず、前RoundのGit差分、テスト、Issue、PR、検証結果を次Roundへ引き継いでください。
Completion Gate：COMPLETE（完了条件を証拠付きで満たした場合のみ終了）／CONTINUE（修正可能な未達があれば優先順位を更新し次Round）／BLOCKED（認証・権限・外部障害等、自力解決不能な具体的blockerのみ停止）。困難、未調査、単なる作業量をblocker扱いしないでください。

【Agent Team】
Main AgentはGoal保持、評価、計画、分解、優先順位、SubAgent調整、統合、品質判定、Git運用、Completion Gate、リリース判断を担当します。独立可能な作業はClaude CodeのSubAgentへ並列委任してください。
・Design：OpenDesign、画面遷移、Responsive、A11y
・Frontend：UI、状態管理、再利用Component
・Backend：API、認証・認可、入力検証、業務Logic
・Database：ローカルPostgreSQL、Schema、Migration、Seed、索引、性能、backup／restore drill
・QA：Unit、Integration、E2E、回帰、権限差、異常系
・Security：権限、Secrets、依存関係、脆弱性、監査
・DevOps：GitHub Actions、systemd、Cloudflare、監視、復旧
SubAgentは担当範囲・成果物・検証結果を明確にし、同一ファイル競合を避けてください。最終統合と共有仕様変更はMain Agentが判断し、SubAgent結果を鵜呑みにせず再検証してください。

【Recovery Loop】
重大問題が複数Round残る、複雑な回帰、原因不明の失敗、設計と実装の大幅乖離がある場合は、通常Roundとは切り分けて再調査してください。必要に応じ新しいSubAgentへ原因分析を委任し、仮説→変更→検証→再評価を最大12Round反復します。同じ失敗を理由なく繰り返さず、解消・具体的blocker・上限到達時にMain Agentへ戻し、型検査、Lint、Test、Build、E2Eを再実行してください。

【実装・検証】
許可範囲で実装、Migration、Seed、Test、文書更新、commit、push、PR、Preview検証（APIとDBはホスト側preview環境、Cloudflare Previewは静的UI／Accessの範囲）まで進めてください。有効なダミーデータを保持し、正常、空、Loading、Error、権限別状態を確認可能にしてください。未実装、OpenDesignとの差異、技術的制約、残存リスクを記録してください。

【完了条件】
・主要業務フローが実操作可能でOpenDesignと整合
・正常・空・エラー・権限別状態を確認可能
・ローカルPostgreSQLのMigration/Seedを空DB（<app>_ci）へ再実行可能、backupとrestore drill手順を検証済み
・型検査、Lint、主要Test、E2E、Build成功
・Responsive、Keyboard、主要A11y確認済み
・ホスト側PreviewでUI、API、認証、DB接続確認済み
・README、要件、設計、API、DB、Test、運用・復旧文書更新済み
・Critical/High解消、残存リスク記録済み

【PR・自動マージ】
必須Check成功、未解決Reviewなし、Secrets Scan成功、Critical/Highなし、Migration検証成功、Preview主要E2E成功、Rollback確認済みの場合のみSquash Mergeしてください。未達時はMergeせずPR/Issueへ原因を記録し、次Roundで修正してください。Branch Protection・監査設定を回避しないでください。

【本番デプロイ】
Merge後は承認済みのホスト側デプロイ経路（systemd）で本番反映し、検証済みMigrationは直前のpg_dumpスナップショット取得後に適用してください。Cloudflareは必要時のみPages／Access／Tunnel／DNSを更新してください。Health Check、主要画面、API、認証・認可、DB接続、Logs、Error Rateを確認・記録してください。異常時は追加変更よりRollbackを優先し、原因、影響、復旧、再発防止を記録してください。

【Safety／Blocker】
既存ユーザー変更と無関係な差分を変更・破棄・混入させないでください。認証情報不足、外部障害、復元困難な破壊的DB変更（DROP DATABASE／ROLE、TRUNCATE、条件なしDELETE、本番へのpg_restore --clean、backup削除）、本番データ削除、費用・契約・請求、権限体系、認証方式の変更、Branch Protection・監査回避が必要な場合は実行せず停止し、blocker、影響、必要な承認、推奨対応を日本語で提示してください。
"
