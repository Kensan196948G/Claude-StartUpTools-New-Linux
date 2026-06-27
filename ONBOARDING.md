# Claude-StartUpTools-New-Linux Onboarding

> このファイルは `/team-onboarding` により自動生成されます。
> 手動編集は次回実行時に上書きされます。恒久的な記述は `CLAUDE.md` または `docs/` に配置してください。

**生成日時**: 2026-06-15（`scripts/refresh-onboarding.js` により決定論再生成 — Issue #17 対応）
**ClaudeOS バージョン**: v9.0（プロジェクトテンプレート: `Claude/CLAUDE.md`）
**Git ブランチ**: main（生成時点。実作業は feature branch で実施）
**リポジトリ**: https://github.com/Kensan196948G/Claude-StartUpTools-New-Linux

> ♻️ **再生成方式（Issue #17）**: 揮発セクションは `scripts/refresh-onboarding.js` が
> 実ソースから決定論的に再生成します（`/team-onboarding` の実体補完）。
> **§1 Goal / §2 KPI / §3 失敗 / §4 成功 / §11 再開**は `state.json` 由来 — 不在時は
> 陳腐化値を残さず **「未取得」定型**へ落ちます（現在 `state.json` は未配置）。
> **§5 Agent / §6 Command 件数**はディレクトリ実数、**§8 Git 活動**は `git log` から追従。
> STABLE 達成時の自動実行は `.claude/claudeos/hooks/hooks.json` PostToolUse に登録済み。

---

## 1. このプロジェクトの Goal

`state.json` から取得した現在値:

| 項目 | 現在値 |
|---|---|
| Goal Title | Claude-StartUpTools-New-Linux を AI 開発組織運用プラットフォームとして Release Ready へ到達させる |
| Goal Description | （説明なし） |
| 運用モード | Auto Mode + Agent Teams |
| 最大作業時間 | 300 分 |
| 現在フェーズ | Idle |

## 2. 現在の KPI 状態

| KPI | 目標値 | 現在値 |
|---|---|---|
| success_rate_target | 0.9 | 未計測 |

## 3. よくハマるポイント（実履歴からの抽出）

*未取得 — state.json.learning.failure_patterns 未記録。セッション進行で自動蓄積される*

## 4. 過去の成功パターン

*未取得 — state.json.learning.success_patterns 未記録*

## 5. 利用可能な Agent Teams

`.claude/claudeos/agents/` 直下に **43 体** の特化サブエージェントが配置されています。

| カテゴリ | Agent |
|---|---|
| 統括・管理 | `orchestrator` / `cto` / `chief-of-staff` / `manager` / `planner` / `loop-operator` |
| 設計 | `architect` / `api-designer` |
| 実装（言語別 resolver） | `build-error-resolver` / `cpp-build-resolver` / `go-build-resolver` / `java-build-resolver` / `kotlin-build-resolver` / `rust-build-resolver` / `pytorch-build-resolver` |
| レビュー（言語別・領域別） | `cpp-reviewer` / `go-reviewer` / `java-reviewer` / `kotlin-reviewer` / `python-reviewer` / `rust-reviewer` / `typescript-reviewer` / `database-reviewer` / `security-reviewer` / `code-reviewer` / `performance-reviewer` |
| 開発（領域別） | `dev-api` / `dev-ui` |
| 品質 | `qa` / `tester` / `e2e-runner` / `tdd-guide` |
| 運用・SRE | `ops` / `ci-manager` / `release-manager` / `incident-triager` / `harness-optimizer` |
| 監査・CMDB | `audit-agent` / `cmdb-agent` |
| ドキュメント | `doc-updater` / `docs-lookup` |
| 改善・評価 | `refactor-cleaner` / `outcome-grader` |

> 各 Agent の詳細な description は、該当 Agent を呼び出した際にロードされるフロントマターから取得してください。
> CLAUDE.md §6 に Agent Teams のロール対応表があります。

## 6. 利用可能なスラッシュコマンド

`.claude/claudeos/commands/` 直下に **45 個** のコマンドが配置されています。

| カテゴリ | Command |
|---|---|
| オンボーディング | `/team-onboarding` |
| 計画・オーケストレーション | `/plan` / `/orchestrate` / `/multi-plan` / `/multi-workflow` / `/multi-execute` / `/extract-tasks` |
| レビュー | `/code-review` / `/go-review` / `/python-review` |
| ビルド・テスト | `/build-fix` / `/go-build` / `/go-test` / `/verify` / `/test-coverage` |
| マルチスタック | `/multi-backend` / `/multi-frontend` |
| TDD・E2E | `/tdd` / `/e2e` |
| セッション管理 | `/checkpoint` / `/sessions` / `/session-info` / `/prune` |
| 作業時間管理 | `/work-time-set` / `/work-time-reset` |
| cron 管理 | `/cron-register` / `/cron-list` / `/cron-cancel` |
| 学習・進化 | `/learn` / `/learn-eval` / `/evolve` / `/eval` |
| Instinct（直感記録） | `/instinct-export` / `/instinct-import` / `/instinct-status` |
| ドキュメント | `/update-docs` / `/update-codemaps` / `/changelog` |
| 改善 | `/refactor-clean` |
| プロジェクト管理 | `/pm2` / `/setup-pm` |
| スキル作成 | `/skill-create` |

## 7. 禁止事項（CLAUDE.md §18 の全項目を動的ミラー）

CLAUDE.md §18 から抽出した **全 8 項目**:

1. Issue なし作業
2. main 直接 push
3. CI 未通過 merge
4. 無限修復（Auto Repair 制御に従う）
5. 未検証 merge
6. 原因不明修正
7. Token 超過のまま深掘り継続
8. 時間不足時の大規模変更

> この一覧は CLAUDE.md §18 の動的ミラーです。§18 を更新すれば次回 `/team-onboarding` 実行時に自動追従します。

## 8. 直近の Git 活動

（直近 12 件 / active 判定）

| Hash | 概要 |
|---|---|
| 775d96f | docs: AI組織設計・進歩測定・自己改善ガードを追加し /measure コマンドを新設 (#58) |
| eeda6fb | Merge pull request #57 from Kensan196948G/codex/automation-safety-design-dryrun-model-routing |
| d59df27 | Add automation safety dry-run and model routing |
| c74a4f5 | feat(launcher): improve terminal launch and start prompt handling |
| 88756ca | Merge pull request #55 from Kensan196948G/codex/headless-fallback-cron-limits |
| bb7c157 | feat(launcher): default to headless cron limits |
| e68ec92 | chore(ops): reduce claudeos background usage (#54) |
| 6f2a6c6 | feat(launcher): L1/S1 実行状態カラー表示と cron [7] ライブ監視接続 (#53) |
| c700754 | fix(supervisor): コスト有り短命セッションを crash-loop から除外 (#52) |
| 9c09150 | fix(supervisor): release-ready フェーズを goal-reached として正しく検出 (#51) |
| c9b0d0a | fix(watch-session): headless セッションの接続・停止をサポート (#50) |
| 0a64a8f | feat(start-claude): foreground 追尾ログを tmux 別窓へ逃がしメニュー端末を即解放 (#49) |

## 9. 未解決の Codex 指摘

`state.json.codex` ブロックは現セッション未実行のため空。

> 次回 Verify フェーズで `/codex:review --base main` を実行すれば、結果が state.json.codex に記録されます。

## 10. セッション開始手順

自律実行は Linux cron（月〜土・プロジェクト別・300分）が担う。
`/loop` によるループ登録は不要。セッション開始時は以下のみ実行:

配分目安: Monitor 10% / Development 35% / Verify 25% / Improvement 15% / Debug 10% / Release 5%。

続いて Codex セットアップ:

```text
/codex:setup
/codex:status
```

リリース直前のみ: `/codex:setup --enable-review-gate`

## 11. 再開ポイント（前回セッション未完了時）

*未取得 — state.json 未配置 or 進行中セッションなし。Monitor フェーズから新規開始する*

---

## 付録: このファイルの生成元

- **コマンド定義**: `.claude/claudeos/commands/team-onboarding.md`
- **データソース**:
  - `./CLAUDE.md`（運用規約）
  - `./state.json`（不在時は §1〜§4・§11 を「未取得」定型へ。`.gitignore` 対象のため通常不在）
  - `./README.md`
  - `.claude/claudeos/agents/**/*.md`（Agent 定義）
  - `.claude/claudeos/commands/*.md`（Command 定義）
  - `git log --oneline`（直近コミット）
- **決定論再生成器**: `scripts/refresh-onboarding.js`（純粋関数 + `node --test`）

## 付録: Verify 連動自動更新

STABLE 達成時に本ファイルを自動再生成するフックは **Issue #17** で実装済みです。
`.claude/claudeos/hooks/hooks.json` の PostToolUse に `onboarding-refresh-on-stable` が登録され、
Verify ループで STABLE が成立するたびに `scripts/refresh-onboarding.js` 相当の再生成が走り、
本ファイルの揮発セクションが最新化されます（state.json 不在時は「未取得」へフォールバック）。
