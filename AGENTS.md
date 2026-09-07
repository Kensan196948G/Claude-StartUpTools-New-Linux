# AGENTS.md

## 目的

このリポジトリでは Claude を CTO として扱い、Linux ローカルの起動・Supervisor・検証を自律的に進めます。

## 標準ロール

| ロール | 責務 |
|---|---|
| CTO | 優先順位、設計判断、最終提案 |
| Developer | 実装、リファクタリング |
| QA | `npm test`、`npm run lint`、回帰確認 |
| Ops | Supervisor、cron、tmux、CI確認 |
| Security | Secrets、権限、破壊的操作の確認 |

## 運用ルール

- 実装と検証は自律的に進める。
- 人間の最終判断が必要な操作は実行前に止める。
- SSH/Windows/PowerShell 起動経路を復活させない。
- 全プロジェクト適用は必ず `--dry-run` で対象を確認してから行う。
- 失敗時は原因、再現手順、次の修正案を短く残す。

<!-- central-github-policy -->
## GitHub運用ポリシー（中央配布）

GitHub運用はこのWorkspaceの記述ではなく、中央ポリシーに従います。

- 正本: /home/kensan/Projects/Deep-Seek-Harness-Project/GITHUB_POLICY.md
- 詳細（GitHub 運用）: /home/kensan/Projects/Deep-Seek-Harness-Project/docs/architecture/CloudflareNeonGitHub自動化仕様.md
- DB 運用は中央仕様の Neon 記述ではなく、本リポジトリの `docs/architecture/PostgreSQLデータ運用仕様.md`（Local PostgreSQL 正本、ClaudeOS v10）に従う。中央仕様との差異は CENTRAL_POLICY_CONFLICT として `docs/architecture/MIGRATION_V9_TO_V10.md` に記録する
- 優先順位: 中央GitHub Policy > GitHub Rulesets > GitHub Actions/CI > Workspace AGENTS.md / CLAUDE.md / README
- main直接push禁止、Required Checks PASS後のSquash Merge、merge後branch削除
