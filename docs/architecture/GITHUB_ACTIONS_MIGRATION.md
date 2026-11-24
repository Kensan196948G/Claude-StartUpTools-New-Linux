# GitHub Actions 段階的廃止計画

状態: 2026-11-24 棚卸し・代替経路実装済み。**ワークフローの無効化・削除・ruleset 変更は未実施（人間承認待ち）。**

## 1. 棚卸し（`.github/workflows/`）

| ワークフロー / job | 目的 | Required Check | ローカル代替（`config/ship-policy.json` profile `claudeos-self`） | 判定 |
| --- | --- | --- | --- | --- |
| `ci.yml` / `linux-validate` | bats + node test、dry-run マトリクス、shellcheck（2 系統）、adversarial probe、policy matrix、TLA+ | **必須** (`linux-validate`) | `npm-test` / `dry-run-matrix` / `shell-lint` / `shell-lint-extra` / `adversarial` / `policy-matrix` | 代替可。TLA+ は下記注記 |
| `ci.yml` / `e2e-console` | Playwright でコンソール検証 | 任意 | `scripts/e2e/console.e2e.js` / `ship-console.e2e.js`（Playwright はローカル導入済み） | 代替可（profile 未登録: ブラウザが bwrap の ro-root で動くか未検証 → 未検証として記録） |
| `ci.yml` / `staging-smoke` | 成果物から起動したスモーク | 任意 | `scripts/e2e/staging-smoke.sh`（`claudeos-staging-smoke.timer` で毎日実行中） | 代替済み（既存 timer） |
| `ci.yml` / `release-artifact` | 成果物ビルドと独立検証 | 任意 | `bin/release-build.sh` + `scripts/release/verify-artifact.sh` | 代替可（profile 未登録） |
| `security-scan.yml` / `Secrets scan (gitleaks)` | シークレット検出（全履歴） | **必須** | `secrets-scan`（trivy offline。作業ツリー + base..head の差分パッチ） | 代替可。ただし検出エンジンが異なる（下記） |
| `security-scan.yml` schedule（週 1） | 定期全履歴スキャン | - | 未実装 | 人間判断（承認事項 #5） |

AI レビュー系ワークフロー（Copilot / Codex / CodeRabbit を呼ぶもの）は **存在しない**（2026-11-24 確認）。
`scripts/setup/install-review-tools.js`（CodeRabbit / Codex の導入確認ツール）は標準経路から外れた任意ツールとして残す（README に非推奨と明記）。

## 2. 現行 ruleset（2026-11-24 API 再取得）

```json
{"name":"central-auto-merge","enforcement":"active","conditions":{"ref_name":{"include":["refs/heads/main"]}},
 "rules":[{"type":"pull_request","parameters":{"allowed_merge_methods":["squash"],"dismiss_stale_reviews_on_push":true,"required_approving_review_count":0,"require_extra_approval_for_unattributed_changes":true}},
 {"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"Secrets scan (gitleaks)"},{"context":"linux-validate"}],"strict_required_status_checks_policy":true}},
 {"type":"non_fast_forward"},{"type":"deletion"}],"bypass_actors":[]}
```

## 3. 同名チェックで置き換えない理由

`linux-validate` / `Secrets scan (gitleaks)` を ローカルから同名 Commit Status で登録すれば Actions を止められるが、
**検証主体を区別できない**（admin token を持つ AI でも同名の success を付けられる）。そのため:

- ローカル結果は別名 `claudeos/local-quality` で登録し、description に eval_id を入れる（証跡ファイルと突合可能）。
- 証跡は evidence_hash + HMAC で封印し、改ざんされた証跡は品質判定の入力から除外する（テスト済み）。
- 可能になり次第、品質プロセス専用の GitHub App / token（`CLAUDEOS_QA_TOKEN_FILE`）で登録し、ruleset で integration_id を限定する。

## 4. 同等性の比較（実測）

| 観点 | GitHub Actions | ローカル (Local Quality Engine) |
| --- | --- | --- |
| 実行対象 | PR の merge commit (refs/pull/N/merge) | PR の **head SHA**（独立 clone・detach。HEAD 一致を前後で確認） |
| 隔離 | GitHub-hosted VM | bwrap: ネットワーク無し / $HOME を tmpfs で隠す / clearenv / ro-root |
| Node | 24 | ホストの v22（engines >=18） |
| TLA+ | 毎回 jar を取得 | ネットワーク遮断下ではキャッシュ jar が必要（未キャッシュなら `formal` チェックは profile 外 → **未検証として記録**） |
| シークレット | gitleaks 全履歴 | trivy: ツリー + base..head の差分。全履歴の定期走査は未実装 |

実測結果は `docs/architecture/SHIP_DEVELOPMENT_STATUS.md` を参照。

## 5. 移行手順（各段階に人間承認）

1. ✅ 棚卸し・分類・Required Checks 依存の確認（本書）
2. ✅ ローカル実行経路（`bin/ship.sh quality` / `bin/ship-mode.sh QC`）
3. ✅ Commit Status 登録（`--publish`）
4. ⏳ 並走期間: Actions とローカルを両方走らせ、結果の一致を記録（最低 10 PR）
5. ⏳ ruleset 変更案の承認（`SHIP_POLICY_MIGRATION.md` §5）— **承認事項 #3**
6. ⏳ ruleset へ `claudeos/local-quality` を追加し、機能確認
7. ⏳ `linux-validate` / `Secrets scan (gitleaks)` を必須から外す — **承認事項 #6**（ここで初めて Actions 停止が品質を損なわない）
8. ⏳ `ci.yml` の `on: pull_request` を `workflow_dispatch` のみへ（削除はしない。ロールバック容易）
9. ⏳ ロールバック手順の検証: 必須チェックを元の 2 つへ戻す JSON（§2）を適用して確認

## 6. コスト見込み

GitHub Actions の分数・課金額は `gh run list` から取得できない（個人アカウントの billing API は別スコープ）。
`bin/ship.sh actions --repo <r>` は実行回数のみ実測する。公開リポジトリの GitHub-hosted runner は現行料金体系で無料枠の対象となるため、
**本リポジトリ単体の金額削減は 0 円の可能性がある（推定。未検証）**。削減効果は private リポジトリへ横展開したときに生じる。
