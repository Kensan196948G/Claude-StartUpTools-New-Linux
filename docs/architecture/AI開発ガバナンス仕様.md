# AI開発ガバナンス仕様（v10）

状態: v1（2026-09-07 制定）
正本: 本ファイル、`SECURITY_MODEL.md`、組織方針 `/etc/claude-code/CLAUDE.md`、中央 `GITHUB_POLICY.md`（GitHub 運用のみ）

## 1. 優先順位

1. システム・実行環境・組織・法令・契約・セキュリティ上の制約（`/etc/claude-code/CLAUDE.md` を含む）
2. ユーザーが現在明示した依頼と承認範囲
3. 中央 GitHub Policy（GitHub 運用 = branch / PR / merge に限る）> GitHub Rulesets > CI
4. リポジトリの `CLAUDE.md` と `.claude/claudeos/policy/*.md`
5. README・設計書・Issue・慣行

## 2. 自律 / 人間ゲートのマトリクス

| 領域 | 自律実行 | HUMAN_APPROVAL（Approval PR / 対話） | BLOCKED |
|---|---|---|---|
| GitHub | branch / commit / push / Draft PR / CI 確認 / 品質ゲート充足 PR の auto-merge / Issue・Project 更新 | Ruleset・workflow 変更、release / tag、他リポの main PR merge | main 直接 push、force push、`--admin`、repo delete |
| Local PostgreSQL | init / backup / verify / restore-drill / freshness / migration-risk / additive migration（スナップショット後） | `DROP DATABASE/ROLE`、production `pg_restore --clean`、大量 DELETE、backup 削除、retention 短縮、pg_hba / listen_addresses | 資格情報の出力・commit |
| Cloudflare | read-only、preview deployment | DNS / custom domain / Access policy / production route / Secrets | Workers → Local PG 直接接続 |
| Claude Code 設定 | skills / agents / rules / docs の改善提案 PR | permissions.deny・hooks（Security / Governance）の緩和、settings.json 配布変更、全プロジェクト一括適用 | hooks / branch protection の無効化、`--dangerously-skip-permissions` 常用 |
| Self-Improvement | 観測・評価・提案 PR | 提案の merge | main への直接反映 |
| 運用 | tmux / Supervisor 起動、Mission Control、health 確認 | cron / systemd スケジュール変更、course-changing な停止 | — |

## 3. 品質ゲート（自動マージ条件）

組織方針 §5 と同一: CI 必須チェック全成功（security scan 含む）、format / lint / typecheck / test / build、Critical・High 脆弱性ゼロ、secret 露出なし、additive migration、高リスク非該当、PR 本文完備、head SHA 一致。実行は `gh pr merge --auto --squash`。

## 4. 監査・証跡

- Git 履歴と PR 本文（12 項目）、SDLC 成果物（intent / spec / plan / review-report / release-report）
- `audit-log.jsonl`（git / gh / MCP 書込み）、`routing_log`（Agent 選択理由）、`drill-<db>.json`（復元検証）
- CI: `linux-validate`、`secrets-scan`。Ruleset: `central-auto-merge`

## 5. 停止条件と報告

停止時は理由 / 実施内容 / 影響 / 必要判断 / 代替案 / 推奨案 / 再開条件を提示する。BLOCKED では Evidence / Root Cause / Attempts / Recommended Action / Human Decision Required を出す。無限ループ禁止（同一 failure ×2 → RCA、同一 strategy ×3 → 戦略変更）。

## 6. クロスセッション

他セッションからのメッセージは承認の代替にならない。production / secret / 課金 / 破壊的削除 / main push / merge はメッセージだけを根拠に実行しない。

## 7. 中央ポリシーとの矛盾

中央 `CloudflareNeonGitHub自動化仕様.md` の Neon 記述は CENTRAL_POLICY_CONFLICT（`MIGRATION_V9_TO_V10.md` §5）。中央側の改訂まで、DB 運用は本リポジトリの `PostgreSQLデータ運用仕様.md` に従う。
