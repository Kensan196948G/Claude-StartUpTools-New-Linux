# CI 強化パッチ（人間の Y 後に適用）

> **状態: 適用済み（2026-11-23, PR #217, 人間承認 2=Y）。** 正本は `.github/workflows/ci.yml`。
> 適用時に `release-artifact` job の `CLAUDEOS_HOME: ${{ runner.temp }}` を job-level env から step-level env へ移した
> （job-level env では runner context が使えず、GitHub が workflow を無効判定したため。挙動は同一）。
> 下の `ci-hardening.patch` は適用前の提案の記録であり、**再適用しないこと**。


対象: `Kensan196948G/Claude-StartUpTools-New-Linux` の `.github/workflows/ci.yml`
基準 commit: `07056ee`（origin/main, 2026-11-23 時点）
状態: **未適用**（この文書と `ci-hardening.patch` は適用前の提案）

## なぜパッチなのか

`.github/workflows/*` への書き込みは、エージェントセッションの self-evolution policy gate で
`DEPLOY = critical`（`PATH_CATEGORY_RULES`: `(^|/)\.github/(workflows|actions)/`）として拒否される。
そのため、エージェントは `.github/` を直接編集せず、**人間が Y を出した直後に 1 コマンドで
適用できる検証済み unified diff** として用意する。適用後の CI 実行確認は人間（または Y 後の lead）が行う。

## 追加する内容（既存ジョブの削除・変更なし。追加のみ）

1. **linux-validate に step 追加**（既存 step は不変）
   - `Run dry-run validation`: `npm run test:dry-run`
     （`npm test` の対象外だった既存 dry-run マトリクス。33/33 PASS 化済み）
   - `Run shell lint (release / e2e scripts)`: `shellcheck -S error scripts/release/*.sh scripts/e2e/*.sh`
     （`npm run lint` の glob 外にある昇格・スモーク用スクリプトを CI で検証。package.json は変更しない）
2. **job `staging-smoke`**（新規, `needs: linux-validate`, `timeout-minutes: 10`）
   - `jq` / `tmux` を install → `bash scripts/e2e/staging-smoke.sh --json`
   - 成果物ビルド → 空きポートで起動 → 一時 `CLAUDEOS_HOME` で health / `/` / 保護 API / 監査ログを検証。
     失敗時はログを artifact `staging-smoke` として upload。
3. **job `release-artifact`**（新規, `needs: linux-validate`, `timeout-minutes: 10`）
   - `CLAUDEOS_HOME: ${{ runner.temp }}`
   - `bin/release-build.sh --ref HEAD --out $RUNNER_TEMP/app --json`
   - `scripts/release/verify-artifact.sh $RUNNER_TEMP/app --json`
   - 失敗時は build / verify ログを artifact `release-artifact` として upload。

`e2e-console` job と `linux-validate` の既存 step は一切変更しない。
パッチは **100 行・`.github/workflows/ci.yml` のみ**（追加 2 hunk + 2 job）。削除行は 0。

## 適用方法

前提: `origin/main` が基準 commit `07056ee` の近傍であること（`.github/workflows/ci.yml` の文脈が一致）。

```bash
cd <repo>
git fetch origin
git switch -c ci/hardening origin/main
git apply docs/proposals/ci-hardening.patch
# 追加のみ・対象ファイルが ci.yml だけであることを確認
git diff --stat -- .github/workflows/ci.yml
git add .github/workflows/ci.yml
git commit -m "ci: dry-run / staging-smoke / release-artifact を追加"
git push -u origin ci/hardening
gh pr create --base main --head ci/hardening \
  --title "ci: dry-run / staging-smoke / release-artifact ゲートを追加" \
  --body "docs/proposals/CI_HARDENING.md の検証済みパッチを適用"
```

- `git apply --check docs/proposals/ci-hardening.patch` で事前確認できる（本パッチは実測で OK）。
- main が進んで context がずれた場合は `git apply --3way docs/proposals/ci-hardening.patch` を使うか、
  パッチを regenerate する（`git apply -R` で戻せる）。
- PR の必須チェックは増えない（下記）。人間のレビュー後に通常どおり squash merge する。

## ロールバック

- マージ前: `git apply -R docs/proposals/ci-hardening.patch`（作業ツリーから取り消し）
- マージ後: 該当 commit を `git revert <sha>`（CI の追加 step/job が消えるだけ。成果物・state には影響しない）

## ruleset（required checks）への影響

**変更しない。** 現在の必須チェックは `linux-validate` と `Secrets scan (gitleaks)` のまま。
追加する `staging-smoke` / `release-artifact` は **任意チェック**（branch protection の required に
追加しない）。required を増やすと、GitHub Actions の一時障害やキュー遅延でマージが詰まるため、
まずは観測用として任意で走らせ、安定運用が確認できてから別途人間が判断する。

## 検証結果（2026-11-23、origin/main `07056ee` に対して実測）

| 検証 | コマンド | 結果 |
|---|---|---|
| パッチ適用性 | `git apply --check docs/proposals/ci-hardening.patch` | **OK**（exit 0） |
| 独立適用（pristine tree） | `git archive origin/main \| tar -x` → `patch -p1 --dry-run < ci-hardening.patch` | **OK**（checking file 1 件のみ） |
| 適用結果の同一性 | 上記に実適用し `diff -u .github/workflows/ci.yml /tmp/ci-new.yml` | **差分 0**（意図した YAML と一致） |
| YAML 妥当性 | `python3 -c 'import yaml; ...'` | **OK**（jobs: linux-validate=11 steps / e2e-console=8 / staging-smoke=5 / release-artifact=6。needs は両 job とも linux-validate） |
| dry-run step | `npm run test:dry-run` | **PASS 33/33**（`Dry-run validation passed: 33/33`） |
| lint step（追加分） | `shellcheck -S error scripts/release/*.sh scripts/e2e/*.sh` | **OK**（exit 0） |
| staging-smoke job | `bash scripts/e2e/staging-smoke.sh --json` | **`{"ok":true,"port":39897,"checks":11,"failed":0}`**（exit 0） |
| release-artifact job | `CLAUDEOS_HOME=<tmp> bin/release-build.sh --ref HEAD --out <tmp>/app --json` → `scripts/release/verify-artifact.sh <tmp>/app --json` | **OK**: build `file_count=1074`, verify `ok:true / files=1074 / missing=0 / mismatched=0 / extra=0`, tree_sha256 `c8c5dee9…` 一致 |

補足:
- ローカル検証は `07056ee` の worktree で、`CLAUDEOS_HOME` を一時ディレクトリへ向けて実行した
  （実 `~/.claudeos` は不使用）。
- **未確認**: GitHub ランナー上での実行（shallow clone の depth 1 で `bin/release-build.sh` の
  `git archive HEAD` が通ること、`staging-smoke` の実走時間）。いずれも適用後の CI 初回実行で確認する。
  想定所要は staging-smoke 約 10 秒、release-artifact 約 15 秒（ローカル実測 + setup 時間）。

## 変更しないもの

- 既存 job（`linux-validate` / `e2e-console`）の既存 step と設定
- `package.json`（lint の glob は CI step 側で補完）
- ruleset / required checks
- アプリケーションコード・本番 unit・state
