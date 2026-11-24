# ClaudeOS v5.0 — Ship Native 開発完了報告書（開発完了候補）

作成: 2026-11-24 / ブランチ `feat/ship-native-v5` / 基点 `a35988a` / 状態: **Experimental・人間承認待ち（正式リリースではない）**

> 凡例: **[実測]** = この環境で実行して確認した値、**[推定]** = 計算・推定、**[未検証]** = 確認していない
>
> **本書は作成時点（2026-11-24、PR #228 マージ前）のスナップショット。** その後の状況（#185・#229・#228・#232 のマージ、`/ship` の実機確認、承認者鍵の登録など）は `docs/architecture/SHIP_DEVELOPMENT_STATUS.md` と `TASKS.md` が正本。数値・状態を本書から引用するときは、そちらと照合すること。

## 1. 開発目的と結論

Claude Code の新機能 Ship を開発ライフサイクルに組み込み、ローカル品質検証・独自 AI 品質判定・強制力のある人間承認・自動マージを統合する。

**結論**: エンジン・品質検証・品質判定・人間承認・マージ実行・監視・Web・DB・形式検証を実装し、全テストに合格した。
ただし公式仕様と本環境の制約により、**`/ship` 自体を ClaudeOS から起動することはできない**（人が対話セッションで入力する）。
また本環境では gh のバージョンとプロジェクトのフックにより **`/ship` の watch（修正の自動 push）が始まらない**。
自動マージは中央ポリシーと ruleset の変更（人間承認事項）が済むまで登録されない設計で、現時点では無効。

## 2. Claude Ship 実機確認 [実測]

| 項目 | 結果 |
| --- | --- |
| Claude Code | 2.1.330（`/ship` の要件 2.1.330 以上を満たす） |
| 認証・プラン | claude.ai / firstParty / Max（max_20x） |
| 組織版 Claude Ship（Code Review / PR Steward / Claude Approvals） | **契約対象外**（Team / Enterprise のみ） |
| `/ship` の headless 実行 | **不可**: `claude -p "/ship terms"` → `Nothing started. /ship starts only from a line that you type` |
| `claude --help` への表示 | なし（セッション内コマンドのため。未対応の根拠にはしていない） |
| gh | 2.45.0（要件 2.63 未満 → **watch が修正を push できない**） |
| git | 2.43.0（要件 2.38 以上を満たす） |
| 本リポジトリの `.claude/settings.json` | PreToolUse(Bash) フックあり → **公式仕様で watch が始まらない**（review は可） |
| 総合判定（`bin/ship.sh capability`） | `degraded`（review のみ可能・watch 不可） |
| 対話セッションでの `/ship` 動作 | **[未検証]**（人が行う必要がある） |

## 3. 実装した機能

| 機能 | 実体 | 要点 |
| --- | --- | --- |
| Ship Integration Engine | `bin/ship.sh`・`scripts/ship/ship.js` | capability / run 管理 / 既存 PR 再利用 / 監視 / 停止 / 監査 |
| 状態機械 | `scripts/ship/lib/state-machine.js` | 指示書の 22 状態。承認・マージ系は検証済み証跡なしに遷移不可 |
| Local Quality Engine | `scripts/ship/lib/quality.js` | 対象 SHA の独立 clone、bwrap（ネットワーク遮断・$HOME 隠蔽・clearenv・ro-root）、HMAC 封印、Commit Status |
| AI Quality Gate | `scripts/ship/lib/quality-gate.js` | PASS / CONDITIONAL / FAIL / UNKNOWN / BLOCKED。Anthropic の Claude Approvals ではない独自機能 |
| リスク分類 | `scripts/ship/lib/risk.js` | R0〜R4。判定不能は R4 |
| Human Gate | `scripts/ship/lib/human-gate.js`・`bin/ship-approve.sh` | パスフレーズ保護 Ed25519 署名、head/base 固定、期限、取り消し、nonce、信頼鍵は main 側ポリシーのみ |
| Ship 結果の署名 | `ship-approve.sh ship-attest` | `/ship` を実行した人が結果に署名（AI の自己申告を判定に使わない） |
| Merge Executor | `scripts/ship/lib/merge.js` | 全条件再照合・ruleset 確認後のみ `--auto --squash --match-head-commit`。API 再取得で MERGED 確認 |
| 起動モード | `bin/ship-mode.sh`・`bin/menu.sh` | SH1〜SH5 / QC / HG。L1/T1/S1 は無変更 |
| Web コンソール | `scripts/web/ship-api.js`・`public/ship.*` | Control Center。承認ボタンは置かない（取り消しのみ Access JWT 必須） |
| DB | `db/control/migrations/0006_ship_native.sql`・`scripts/ship/project-to-db.js` | 追加のみ。追記専用トリガ、nonce UNIQUE |
| 形式検証 | `formal/specs/ship_gate.tla` | 承認なしマージ不可・SHA 固定・nonce 1 回 |

## 4. テスト結果 [実測]

| 対象 | 結果 |
| --- | --- |
| `npm test`（bats 1,447 件 + node 636 件） | **全件 PASS**（失敗 0・skip 0） |
| `npm run lint` / `test:dry-run` / adversarial probe / doc-version check | PASS |
| Ship 追加: node（core 25・human-gate 30・quality 10・lifecycle 5・github 6・ship-api 15・project-to-db 16） | 107 / 107 PASS |
| Ship 追加: bats（ship 16・control-db-0006 9） | 25 / 25 PASS |
| TLA+ `ship_gate`（163,181 状態） | verified。承認の head 照合を外した変異モデルでは反例を検出 |
| 実リポジトリ origin/main `a35988a` の隔離品質検証 | **PASS**（7 チェック、npm-test 1,953 pass / 0 fail / 4 skip） |
| 使い捨て PostgreSQL で 0001→0006・射影・制約・ロールバック | PASS（DB は削除済み、既存 DB には未適用） |
| Web E2E（一時サーバ・実データ） | 10 / 10 PASS |

### 開発中に発見・修正した不具合（根本原因を修正）

1. GitHub が merged を返すがマージコミットが無い場合に `MERGED` と記録していた → `MERGED_UNCONFIRMED` に修正（テストで検出）。
2. 隔離実行で 27 件が `USER: unbound variable` → sandbox が `USER` 等の非機密基本変数を渡していなかった。追加して再実測 PASS。
3. シークレット検出ログの位置が絶対パス化して誤表示 → 相対化を修正。
4. DB の署名長 CHECK が PostgreSQL の正規表現上限 255 を超えて実行時エラー → `length()` 制約に変更（DB 担当）。

## 5. Ship レビュー / 自動修正 / AI 品質判定

| 項目 | 結果 |
| --- | --- |
| 本 PR への `/ship` 適用 | **未実施**（headless 不可・watch 不可。人が対話セッションで実行する必要がある） |
| Ship 自動修正 | 未実施（同上） |
| AI Quality Gate（本 PR） | FAIL（Draft・Ship 証跡なし。§9） |

## 6. GitHub Actions 削減

| 項目 | 状態 |
| --- | --- |
| 棚卸し・代替経路 | 完了（`docs/architecture/GITHUB_ACTIONS_MIGRATION.md`） |
| 必須チェック `linux-validate` の代替 | ローカルで同等チェックを隔離実行し PASS [実測]。同名登録はしない（検証主体を区別できないため） |
| `Secrets scan (gitleaks)` の代替 | trivy（ツリー＋差分パッチ）。エンジンが異なり、全履歴の定期走査は未実装 |
| ワークフロー無効化・ruleset 変更 | **未実施**（人間承認事項） |
| コスト削減額 | 本リポジトリは PUBLIC のため **0 円の可能性** [推定・未検証]。効果は private リポジトリへの展開時 |
| Copilot / Codex レビューのワークフロー | もともと存在しない [実測]。導入確認ツールは任意として残置 |

## 7. 残存リスク・未実装・未検証

- root 権限を持つ悪意あるエージェントは人間の承認入力を盗み得る（対策: AI を sudo 無しの別ユーザーで実行 = 承認事項 #7）。
- AI のトークン分離（admin 権限の除去）と GitHub App 化の前は、admin token を持つ AI が承認ステータスを偽装し `gh pr merge` を直接実行し得る（ClaudeOS 経由では署名検証で防止）。
- 証跡の改ざんは検出できるが防止はできない（OS ユーザー分離が必要）。
- `/ship` の対話セッション実機検証、Playwright の隔離実行、Actions との並走比較（10 PR）は [未検証]。
- `review_findings` / `remediation_events` / `recovery_events` は DB 表のみで書き手が未実装。
- SH2 を既定モードにはしていない（実機検証後）。

## 8. ロールバック

`git revert`（既存ファイルの変更は menu.sh / startup-server.js / index.html / compat.json / package.json / README / CHANGELOG / TASKS のみ）。
GitHub 設定・中央ポリシー・systemd・cron・本番 DB は変更していないため戻す必要がない。詳細: `docs/architecture/SHIP_IMPACT_ANALYSIS.md`。

## 9. PR と本 PR 自身の判定 [実測]

- PR: https://github.com/Kensan196948G/Claude-StartUpTools-New-Linux/pull/228 （Draft）
- 判定対象 head: `aa71de398ff63d461986a403005d36f162820027` / base: `a35988a7c5eb253854f2696d8889689d66c5def6`
  （この後に追加するコミットは報告書の更新のみ。head が変わるため、承認前に quality → gate の再実行が必要）

| 工程 | 結果 |
| --- | --- |
| Local Quality（隔離・8 チェック） | **PASS**（npm-test 2,086 pass / 0 fail / 3 skip、TLA+ を含む。eval `qe_mwu7hmls_879108fef940`）→ `claudeos/local-quality=success` を GitHub に登録 |
| GitHub Actions（参考・並走） | linux-validate / gitleaks / e2e-console / staging-smoke / release-artifact すべて pass |
| AI Quality Gate | **FAIL**（R4）: Draft のため FAIL、Ship レビュー証跡なし（UNKNOWN）、要件一部未充足（CONDITIONAL） |
| Merge Executor（dry-run） | **REFUSED**: Draft、中央ポリシー未施行、ruleset が 2 チェックを未要求、gate 非 PASS、人間承認なし |

**この PR は現時点で自動マージ不可（設計どおり）。** 不合格・拒否はエンジンが正しく働いている証拠であり、不具合ではない。

### ドッグフーディングで発見・修正した不具合

5. gh 2.45 の `pr view --json` に `baseRefOid` が無く、PR 取得全体が失敗して gate が BLOCKED になっていた（偽 gh のテストでは検出できなかった）。
   → base を GraphQL から取得し、2 回の取得間の head 変化（HEAD_RACE）と base 取得不能は失敗として扱うよう修正。偽 gh を実機準拠に修正し、回帰テスト 6 件を追加。

## 10. 承認が必要な事項（番号は TASKS.md と共通）

| # | 事項 | 区分 |
| --- | --- | --- |
| 1 | 中央 GITHUB_POLICY への Ship Native 適用除外（方式 B 推奨） | 中央ポリシー改定 |
| 2 | 横断自動マージ巡回から本リポジトリを除外 | 横断設定 |
| 3 | ruleset に 2 つの必須チェックを追加 | GitHub 設定 |
| 4 | 人間専用 GitHub App の作成・integration_id 限定（**保留**: #7・トークン分離とセットで後日。2026-11-24 判断） | GitHub 設定・認証 |
| 5 | 週次全履歴シークレット走査の方式 | 運用 |
| 6 | 並走比較後に Actions の必須チェックを外す | GitHub 設定 |
| 7 | AI を sudo 無しの別 OS ユーザーで実行 | OS 権限 |
| 8 | PreToolUse(Bash) フックの扱い | 品質ゲート |
| 9 | gh を 2.63 以上へ更新 | 環境 |
| 10 | 承認者鍵の作成・登録 | 認証情報 |
| 11 | 本 PR のマージ | 最終マージ承認 |
