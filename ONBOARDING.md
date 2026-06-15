# Claude-StartUpTools-New-Linux Onboarding

> このファイルは `/team-onboarding` により自動生成されます。
> 手動編集は次回実行時に上書きされます。恒久的な記述は `CLAUDE.md` または `docs/` に配置してください。

**生成日時**: 2026-06-15（Agent/Command/Git 各セクションを実ソースから手動再生成 — Issue #13 対応）
**ClaudeOS バージョン**: v9.0（プロジェクトテンプレート: `Claude/CLAUDE.md`）
**Git ブランチ**: main（生成時点。実作業は feature branch で実施）
**リポジトリ**: https://github.com/Kensan196948G/Claude-StartUpTools-New-Linux

> ⚠️ **再生成範囲メモ（Issue #13）**: 本リビジョンでは実ソースから検証できる
> **§5 Agent / §6 Command / §8 Git 活動** とヘッダーの事実誤認のみを手動更新しました。
> **§1・§2・§4・§11 は `state.json` 由来**ですが、現在 `state.json` が未配置のため
> 旧リポジトリ（v3.2.23 系）の陳腐化した値が残っています。これらの自動追従は
> **Issue #100（Verify 連動 自動再生成フック）** で解消予定です。

---

## 1. このプロジェクトの Goal

`state.json` から取得した現在値:

| 項目 | 現在値 |
|---|---|
| Goal Title | ClaudeOS v8 自律開発最適化 |
| Goal Description | ClaudeOS v8 による完全無人運用の確立と Claude Code 中心の開発体験向上 |
| 運用モード | Auto Mode + Agent Teams |
| 最大作業時間 | 300 分（5 時間） |
| 現在フェーズ | Monitor |

## 2. 現在の KPI 状態

| KPI | 目標値 | 現在値 |
|---|---|---|
| success_rate_target | 0.9 | 0.9（state.json より） |

## 3. よくハマるポイント（実履歴からの抽出）

`state.json.learning.failure_patterns` は現セッションでは未記録（セッション進行で自動蓄積）。

Git ログから直近の修復系コミット（fix/hotfix 系）を参照:

| 傾向 | 詳細 |
|---|---|
| tmux + timeout SIGTTOU 停止 | GNU `timeout` が `setpgid(0,0)` で Claude を新 PGID へ移動 → `tcsetattr()` で SIGTTOU 受信し `Tl` 停止。`timeout --foreground` で解消 (v3.2.23) |
| tmux pipe-pane による TUI 破壊 | `pipe-pane` が PTY を横断し DA クエリ応答を破壊 → TUI 初期化失敗。pipe-pane 削除で解消 (v3.2.23) |
| CodeRabbit Critical 指摘 | injection 系 / SSH コマンド構築 — v3.2.19 で解消 |
| README バージョンドリフト | CHANGELOG 更新時に README quote/テーブルを同一 commit で更新しないと CI 失敗 |
| PSScriptAnalyzer 警告蓄積 | v3.2.6〜v3.2.14 で段階的に全カテゴリ解消済み |

## 4. 過去の成功パターン

`state.json.learning.success_patterns` は現セッションでは未記録。
直近 STABLE 達成実績: consecutive_success=10 継続中（v3.2.23 時点）。

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

`.claude/claudeos/commands/` 直下に **42 個** のコマンドが配置されています。

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

直近 12 コミット:

| Hash | 概要 |
|---|---|
| fa82dec | feat(subagents): 言語別 reviewer/build-resolver 11体を正本テンプレートへ昇格 (#12) |
| fd889cb | refactor: 廃止済み security サブエージェントスタブを削除 (#11) |
| dfcff5a | feat: Claude Code docs 4件の適合適用と運用整備 (#10) |
| e08ac94 | docs: Add heartbeat-watchdog cron setup guide and README watchdog section (Closes #8) (#9) |
| 7ccdedf | Add heartbeat watchdog for silent type3 detection (SIGKILL/OOM/restart) (#7) |
| 1901947 | Merge pull request #1 — changelog-features-managed-agents-poc |
| 35e939a | Merge pull request #5 — notification-conditional-hooks |
| 184a576 | Merge pull request #3 — stop-failure-hook |
| 9eeadcc | Add Notification hook to detect input-waiting silence (沈黙type2) |
| 84a0be4 | Make CCSU_ROOT env-overridable to stop test-induced template corruption |
| d7a6e8e | Add Phase 0 実施記録 to Managed Agents PoC 手順書 |
| b8a7652 | Apply Claude Code changelog features and prepare Managed Agents hybrid PoC |

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

`state.json.execution` より:

| 項目 | 値 |
|---|---|
| 前回停止 | 2026-04-18T00:18:47Z |
| 前回要約 | v3.2.23 (PR #175) squash merge 完了 (4b6e22f)。cron-launcher.sh SIGTTOU 停止バグ修正。STABLE N=10 継続。 |
| 現在フェーズ | Improvement |

main ブランチで STABLE 継続中。open Issue なし。Monitor フェーズから再開し、GitHub Projects / Issues / CI の状態を確認して次のアクションを決定してください。

---

## 付録: このファイルの生成元

- **コマンド定義**: `.claude/claudeos/commands/team-onboarding.md`
- **データソース**:
  - `./CLAUDE.md`（運用規約）
  - `./state.json`（存在 — goal/kpi/execution/frontier 等記録済み）
  - `./README.md`
  - `.claude/claudeos/agents/**/*.md`（Agent 定義）
  - `.claude/claudeos/commands/*.md`（Command 定義）
  - `git log --oneline -20`（直近コミット）

## 付録: Verify 連動自動更新

STABLE 達成時に本ファイルを自動再生成するフックは **Issue #100** として起票済みです。
実装完了後、`.claude/claudeos/hooks/hooks.json` の PostToolUse にフックが登録され、
Verify ループで STABLE が成立するたびに本ファイルが最新化されます。
