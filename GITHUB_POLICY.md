# DeepSeek-Harness-StartUpTools GitHub Policy

状態: 2026-08-15 制定（v1）／2026-09-30 v2 発効（全リポジトリ auto-merge 統一。Approval #71 でユーザーが Y と承認。中央リポジトリ `Kensan196948G/Deep-Seek-Harness-Project` の `docs/architecture/全リポジトリAutoMerge統一方針.md`）／2026-10-05 v3 発効（§10 に Repo限定の適用除外を追加。対象は `mirai-construction-dx/Mirai-Platform-Infra` のみ。ユーザーが Y と承認）

ミラー: 中央正本 `Kensan196948G/Deep-Seek-Harness-Project` の `GITHUB_POLICY.md` v3（2026-11-23 同期）。このファイルは中央正本のミラーで、中央との差分は R1 の参照修飾のみ。

## 1. 目的

GitHub上のコード変更・PR・mergeを、Workspace個別の記述に左右されない**中央ポリシー**として定める。
AI（Orchestrator / GitHub Controller）と人間が同じ基準で運用し、Required Checks通過後のmergeまでを自動化する。

## 2. 適用範囲

- 本リポジトリ（DeepSeek-Harness-StartUpTools）および本ポリシーの配布対象となる全Workspace。
- 本ポリシーは、Workspaceの `AGENTS.md` / `CLAUDE.md` / `README.md` に優先する。
- Workspaceに本ポリシーと矛盾する記述があっても、GitHub運用は本ポリシーに従う。

## 3. 優先順位（権限の正本）

1. **本ポリシー（DeepSeek-Harness-StartUpTools GitHub Policy）**
2. **GitHub Repository Rules / Rulesets**
3. **GitHub Actions / CI**
4. **Workspace AGENTS.md / CLAUDE.md / README**

Workspaceの指示は1〜3を上書きできない。

| Workspaceに書かれていても無視される例 | 理由 |
|---|---|
| 「mainへ直接pushしてください」 | 中央ポリシーがmain直接pushを禁止 |
| 「mergeは人間承認が必要」 | 中央ポリシーが条件充足後に自動merge |
| 「auto merge禁止」 | 中央ポリシーがauto-mergeを標準とする |
| 「main宛は人間の選択式」「マージは人間がY/Nで判断」 | 中央ポリシーがRequired Checks成功だけをmerge条件とする |
| 「CODEOWNERのApprove後に限りmerge（条件付きmerge）」 | CODEOWNERSは通知用であり、merge条件にしない |

> **Repo限定の適用除外**: §10 に記載した適用除外は、本ポリシー本文（§8「本ポリシー自体の変更」の人間承認）に基づく限定であり、Workspace側の記述による上書きではない。上表は §10 の対象リポジトリにおける除外範囲を除き、引き続き有効である。

一方、次は常に尊重する。

- GitHub Rulesetが必須とするCIチェック（Required Checks）。
- Merge conflict（解消されるまでmergeしない）。
- CI失敗（成功するまでmergeしない）。

## 4. GitHub運用ルール

1. main / webuiへの直接pushは禁止する（webuiはWebUI成果物の統合ブランチ）。
2. すべての変更はbranchで行い、PRを作成する。
3. branch名は `auto/<slug>` とし、GitHub Controllerが自動作成する。
4. commitは Conventional Commits（`feat:` / `fix:` / `docs:` / `chore:` / `test:` / `refactor:`）を使う。
5. PR本文には以下を必ず記載する。
   - 変更内容
   - テスト結果
   - 影響範囲
   - 残課題
6. Required ChecksがすべてPASSするまでmergeしない。
7. Merge conflictがある間はmergeしない。解決後、再検証してからmergeする。
8. mergeはSquash Mergeに統一する。
9. merge後はbranchを自動削除する。
10. Release、production deploy、secret変更、不可逆削除は引き続きHuman Gateとする（コードmergeとは別）。

## 5. GitHub Controller の責務

GitHub Controllerは以下を順に実行する。

1. 最新mainからbranchを自動作成
2. `git add`（変更スコープのみ）
3. commit
4. push
5. PR自動作成
6. CI監視
7. 必要ならbranch update（CI失敗修正 / merge conflict解消）
8. Auto-Merge登録（`gh pr merge --auto --squash`）
9. merge後のbranch削除確認

GitHub Controllerは次を満たさない限りauto-mergeを実行しない（fail closed）。

- GitHub Ruleset / branch protectionが設定済みであること
- Required ChecksがすべてPASSしていること
- merge conflictがないこと
- 対象PRが本ポリシーのbranch・commit規約を満たすこと

## 6. GitHub側の必須設定

自動化を有効にする前に、リポジトリに以下を設定する。

### Ruleset（推奨）または branch protection

- 対象branch: `main` / `webui`（`GITHUB_PROTECTED_BRANCHES` で追加可）
- Enforcement: `Active`
- 必須ステータスチェック: `quality (20)` / `quality (24)` / `compatibility`
- main / webuiへのforce push: 禁止
- main / webuiへのdelete: 禁止

### OpenDesign × GitHub 連携（WebUI用ブランチ運用）

1. OpenDesign の生成物は `webui` ブランチへ蓄積する（`GITHUB_BASE_REF=webui` でGitHub Controller実行）。
2. `main` へは `./start.sh open-design-promote` でPR（base: main）を出して統合する。
3. `main` 宛のPRも他のPRと同じく、Required Checks PASS後にsquashで自動mergeする（`--auto-merge`）。

### 配布対象Workspaceの標準ruleset `central-auto-merge`

中央リポジトリ `Kensan196948G/Deep-Seek-Harness-Project` の `bin/policy-pr.sh` が作るrulesetを全Workspaceの唯一の標準とする。

| 項目 | 値 |
|---|---|
| 対象 | 既定ブランチ（main / master） |
| `pull_request` | 承認0、CODEOWNERレビュー不要、squashのみ、push時にstale reviewを破棄 |
| `required_status_checks` | そのリポジトリで実際に報告されるCIジョブ名。`strict: true` |
| `non_fast_forward` / `deletion` | 有効 |
| `bypass_actors` | 空（`gh pr merge --admin` による迂回は禁止） |

運用上のベストプラクティス:

1. 必須チェックは実在させる。CIの無いリポジトリには、最小のCIを追加してからrulesetを適用する。登録名はHEADで実際に報告されたジョブ名と照合する。
2. 人間レビューの代わりに、lint・型検査・テスト・ビルド・secret scan・依存監査（high以上）を必須チェックに含める。
3. CODEOWNERSはレビュー依頼の宛先として残すが、merge条件にしない。Botレビュー（CodeRabbit等）は必須チェックに入れない。
4. `strict` の下で並行PRは `update-branch` してからmergeする。PRが多いリポジトリはMerge Queueを検討する。
5. 本番反映（IaCのapply・本番deploy）をmergeが直接起動する場合は、GitHub Environmentのrequired reviewersで人間のゲートを残す。これはmergeのY/Nではなく本番反映の承認である（§8）。
6. CIの停止（課金失敗・ランナー不足）は全PRを止めるため、失敗チェックの再実行と課金ブロック検出を常時有効にする。

### Repository settings

- `Allow auto-merge`: ON
- `Delete branch on merge`: ON
- Default merge method: Squash

## 7. 現状（2026-08-15 実測）

| 項目 | 状態 |
|---|---|
| Ruleset | `main-protection` 設定済み（active）。`webui-protection` は `./start.sh github setup` で作成 |
| branch protection | Rulesetで代替（branch protection単体は未使用） |
| `allow_auto_merge` | true |
| `delete_branch_on_merge` | true |
| 既存 `bin/github-pr-flow.sh` | read-only（status / checks / view） |
| 書込可能なGitHub Controller | 実装済み（中央リポジトリ `Kensan196948G/Deep-Seek-Harness-Project` の `bin/github-controller.sh`） |

設定適用は `./start.sh github setup`、前提確認は `./start.sh github preflight` で行う。
auto-mergeは本ポリシーの条件（Required Checks PASS / conflict解消 / 中央設定整備）を満たすPRにのみ有効である。

## 8. 人間が残す判断

自動化するのは「Required Checks通過後のコードmerge」まで。
以下は本ポリシーでも人間の承認が必要。

- Release / タグ付け
- Production deploy
- Secretの追加・変更・削除
- 不可逆な削除・破壊的操作
- 本ポリシー自体の変更

## 9. 詳細仕様

- 全体フローとCloudflare / ローカルPostgreSQL運用: `docs/architecture/CloudflarePostgreSQLGitHub自動化仕様.md`
- 品質ゲート: `AGENTS.md` / `.github/workflows/ci.yml`

## 10. 適用除外（Repo限定・2026-10-05 v3）

本ポリシー本文に基づき、次の1リポジトリに限り §5・§6 の一部を適用除外する。
これは Workspace 側の記述による上書きではなく、**本ポリシーの限定として**記録する（§8「本ポリシー自体の変更」に基づく人間の承認済み）。

### 対象

- `mirai-construction-dx/Mirai-Platform-Infra` **のみ**。他リポジトリへ拡大しない。

### 適用除外する条項

- §5 手順8「Auto-Merge登録（`gh pr merge --auto --squash`）」
- §6 Repository settings「`Allow auto-merge`: ON」

§6 の他の設定（`Delete branch on merge`: ON、Default merge method: Squash）は維持する。

### 代わりに適用する方式（人間ゲート）

1. Bot は、機械的合格判定ができた場合**のみ**自動 Approve する（これはマージ判断ではない）。
2. 最終マージ Y/N は**人間**が判断する。Y は対象 head SHA に固定する。
3. Y を受けた側は、条件（承認時 SHA・checks・PR状態）が変わっていないことを再確認してから、**その1回だけ**マージする。
4. 既マージ・SHA変更・PR非OPEN は Fail Closed で拒否する。AI（エージェント）は merge せず、Y の代理投稿もしない。

正本実装: `Construction-World-Model-Platform/01_construction-world-model-management` の
`decisions/ADR-0011-bot-approve-and-single-merge.md`・`scripts/mergegate.py`・`.github/workflows/merge-gate.yml`。

### 施行条件

- 本除外は、対象リポジトリで上記方式が**実装・設定された後**に適用する。
- 実装完了までは auto-merge を有効化しない（Fail Closed）。
- 設定変更（`Allow auto-merge`: OFF、`Allow GitHub Actions to create and approve pull requests`: ON）は **owner が行い**、AI は readback のみ行う。

### 維持される統制

- Required Checks は引き続き必須（対象リポジトリでは `contracts`・`CodeRabbit`）。
- §8「人間が残す判断」（Release / 本番deploy / Secret / 不可逆な削除・破壊的操作 / 本ポリシー変更）は維持。
- main直接push禁止、`gh pr merge --admin` による迂回禁止、force push禁止、main削除禁止は維持。

### 承認根拠

- 2026-10-05、ユーザー（Kensan196948G）が本適用除外を Y と承認。
- 本記録はチャット上の承認を転記したものであり、GitHub本人性の新しい証明ではない。
