# ClaudeOS v10 Policy — Git / PR / 品質ゲート / Approval PR / rollback / 禁止事項 / Phase 1〜3 / 停止条件

> 旧 CLAUDE.md（v9、27 節）から移設した正本。CLAUDE.md は要約のみを保持し、本ファイルは必要時に参照する。GitHub 運用の正本は中央 `GITHUB_POLICY.md` と `docs/architecture/GitHub開発運用仕様.md`。

---

## 7. ユーザー変更とGit作業の保護

既存の未コミット変更、未追跡ファイルおよび所有者不明の変更は、ユーザーの作業として保護する。

- 無断で破棄、上書き、stash、reset、checkout、revertまたは削除しない。
- unrelated changesを修正対象へ含めない。
- 変更が重なる場合は、可能な範囲で対象ファイルや作業branchを分離する。
- 安全に分離できない場合のみ、影響と選択肢を提示して停止する。
- `main`または`master`へ直接commitしない。
- force push、履歴改変およびbranch protection回避を行わない。
- commitは意味のある小さな単位へ分割する。
- commit messageから目的が分かるようにする。
- secret、credential、PIIまたは不要な生成物をcommitしない。

---

## 15. GitHubおよびPull Request方針

- `main`または`master`への直接作業を避け、目的が分かる作業branchを使用する。
- commitはレビュー、検証およびrollbackが可能な単位に分ける。
- push、PR作成、および§16の品質ゲートを満たすPRの自動マージまで自律実行してよい。
- PR本文は実装と検証の進行に合わせて更新する。
- CI失敗時は原因分析と修正へ戻る。
- head SHAが変化した場合は、影響する検証を再実行する。
- `gh pr merge --admin`、保護規則の迂回および無断force pushを禁止する。

PR本文には最低限、次を含める。

1. 目的と背景
2. 変更内容
3. 対象外
4. 影響範囲
5. テストおよびCI結果
6. セキュリティ確認結果
7. migrationおよびデータ影響
8. deployment方法
9. rollback方法
10. preview確認方法
11. 残課題および残存リスク
12. production-safe判定

---

## 16. 品質ゲート条件付き自動マージ

通常のPRは、次の品質ゲートを全て満たした場合、ユーザーへの`Y / N`確認なしで自動マージしてよい（2026-08-06 ユーザー包括委譲指示に基づく事前承認）。実行は`gh pr merge --auto --squash`等の正規手順とし、保護規則および必須チェックを迂回しない。

### 品質ゲート（全て必須）

1. CI必須チェックが全てsuccess（security scan含む）
2. format、lint、typecheck、必要なtest、buildがPASS
3. criticalおよびhigh severityの未解決脆弱性がゼロ
4. secret、credential、PIIおよびconnection stringの露出がない
5. migrationはadditiveかつ後方互換のみ（破壊的migrationは§17のApproval PRへ分離）
6. §17の高リスク変更に該当しない
7. PR本文が§15の12項目を満たし、`production-safe`判定がPASS
8. マージ対象のhead SHAが検証済みcommitと一致

### 自動マージの承認範囲

自動マージは、対象PRに記載された正確な範囲について、次を一括して事前承認されたものとして実行する。

- 対象PRのmerge
- mergeに連動する既存CI/CDの実行
- PRへ明記された通常のproduction deployment
- 事前検証済みの非破壊的migration
- production smoke test
- read-onlyのログ、監視およびhealth check
- 定義済み条件を満たした場合の、事前検証済みrollback
- リリース結果、IssueおよびProjectの更新

この事前承認を、PRに記載されていない操作や別環境への承認として拡張してはならない。マージ後は§21のPhase 2（本番リリース）とPhase 3（安定化）へ追加承認なしで連続実行する。

### 品質ゲート未達時

自動マージせず、原因を分析して修正・再検証を反復する。自律的に解消できない場合のみ、未達項目、原因、影響、修正計画を提示したうえで次の形式で判断を求める。

```text
マージ判定：Y / N
```

- `Y`：対象PRに記載された正確な範囲の一括承認（上記「自動マージの承認範囲」と同一）
- `N`：mergeしない。理由が提示されていれば分析・修正・再検証し、再度品質ゲートを判定する

---

## 17. 高リスク変更とApproval PR

高リスク変更は、通常機能のPRへ混在させず、原則として専用のApproval PRへ分離する。Approval PRは§16の自動マージ対象外であり、引き続きユーザーの明示的な`Y / N`承認を必要とする。

対象例：

- 公開DNS、custom domainまたはproduction route変更
- production secretの追加、変更、削除またはrotation
- Cloudflare Access policy変更
- authentication methodまたは主要authorization model変更
- destructive migrationまたはproduction data削除
- billing plan、契約または費用構造に影響する変更
- 大規模rollbackまたは復旧操作
- 外部公開範囲、データ保持期間または監査方式の重大変更
- ローカルPostgreSQLの`DROP DATABASE`／`DROP ROLE`、productionへの`pg_restore --clean`、backupファイル削除、retention短縮、pg_hba／listen_addresses変更

Approval PRには次を明記する。

1. 変更目的と必要性
2. 対象account、project、environmentおよびresource
3. 変更前後の状態
4. 実行予定コマンドまたは操作
5. 影響範囲と停止時間
6. securityおよびdata risk
7. backupまたは退避方法
8. rollback方法
9. 成功条件
10. 自動停止条件
11. 実行後の検証方法
12. 担当と監査記録

Approval PRに対する`Y`は、そのPRに記載された正確な範囲だけを承認したものとする。

実行環境がPRのmergeと外部操作の承認を技術的に分離している場合は、必要な権限確認に従う。プロンプトによりシステム権限を迂回してはならない。

---

## 18. 自動rollback方針

§16の自動マージまたは`Y`承認によるリリース後、次の条件を満たし、事前検証済みの安全なrollbackがある場合は、その範囲でrollbackしてよい。

- health check失敗
- 主要API停止
- authenticationまたは主要authorization不能
- migration失敗
- critical security issueの新規発見
- data integrity異常
- error rate、latencyまたはavailabilityが定義済み閾値を超過

rollback後は、自動的な再デプロイを無制限に繰り返さない。原因、影響、rollback結果、現在の稼働状態および再開条件を報告する。

rollbackがデータ損失、追加停止または承認範囲外の変更を伴う場合は実行しない。

---

## 19. 絶対禁止事項

次は自律実行しない。

- secret、credential、token、private keyまたはconnection stringの表示、保存、commit
- `gh pr merge --admin`その他の保護規則回避
- 対象account、project、environmentまたはresourceが不明なproduction操作
- backup、rollbackまたは検証手段のない破壊的変更
- ユーザーの既存変更、データまたは履歴の無断破棄
- security control、audit、認証または監視の無断無効化
- PRで提示した範囲外への変更または承認の拡張解釈
- production dataの無断取得、複製、匿名化されていない利用
- 法令、契約、ライセンスまたは組織ポリシーに反する操作
- 失敗したテスト、脆弱性または未確認事項の隠蔽

必要な場合は、危険操作を避ける方式へ再設計する。

---

## 20. Phase 1：マージ直前までの完了条件

Phase 1は、次を満たした時点で完了とし、§16の品質ゲート成立時はそのまま自動マージとPhase 2へ進む。

- 必須機能が実装済み
- format、lint、typecheck、必要なtestおよびbuildが成功
- criticalおよびhigh severityの未解決脆弱性なし
- secret、credential、PIIおよびconnection string露出なし
- localまたはpreviewで主要WebUIとAPIを確認可能
- migration、backup、restoreおよびrollback手順が必要範囲で検証・文書化済み
- README、設計書、ADR、runbook、FAQおよびrelease文書が実装と整合
- IssueおよびProjectが実態と一致
- CI成功
- PRが作成・更新済みで、残存リスクが明示済み
- `production-safe`判定済み
- §16の品質ゲート判定が完了した状態

未達項目は、理由、影響、代替確認および残作業を記録する。

---

## 21. Phase 2・3：本番リリースと安定化

§16の品質ゲート成立による自動マージ後（Approval PRの場合は`Y`後）は同じGoalを継続し、再承認を求めず、PRに明記された範囲で次を実行する。

### Phase 2：本番リリース

1. マージ時点のPR番号、head SHA、対象branchおよびproduction資源を再確認
2. head SHA変更時は影響する検証を再実行し、承認範囲外なら停止
3. PR merge、merge commitおよび必須CI/CD結果確認
4. 既存規則に従うtagおよびGitHub Release作成
5. 検証済みの非破壊的migration実行
6. ホスト側systemdサービスのproduction deployment（必要な場合のみCloudflare Pages／Tunnel／Access／DNSの更新）
7. deployment ID、commit SHA、migration結果および時刻の記録

Webサービスの本番基盤は、DBを持つバックエンドをLinuxホスト上のsystemdサービスとして稼働させ、ローカルPostgreSQLを正本DBとする。Cloudflareは必要な場合のみPages（静的配信）、Access、Tunnel、DNSに用い、Workers／Pages FunctionsからローカルPostgreSQLへ直接接続しない。custom domainまたはサブドメインが必要な場合は、その時点でユーザーへドメイン名の入力または選択を求める。既定URL（`*.pages.dev`）や社内向けURLでの先行リリースは自律実行してよく、公開DNS・custom domainの変更自体は§17のApproval PR対象とする。

実行順は、後方互換性とrollback可能性を維持する。対象host、cluster、database、role、environmentおよびdomainを一意に特定できなければ停止する。

### Phase 3：リリース後安定化

1. production health check
2. 主要画面、APIおよび業務フローのsmoke test
3. authentication、authorization、DB接続およびdata integrity確認
4. logs、alerts、monitoring、error rateおよびlatency確認
5. 軽微で安全な不具合の修正、回帰テストおよび承認済みCI/CD経路での再反映
6. 定義済み条件該当時の事前検証済みrollback
7. rollback後の再確認と無制限な再デプロイの禁止
8. Issue、Project、release note、runbookおよび既知の問題の更新
9. 最終報告

production dataを変更するテストは、PRへ明記された範囲に限定する。

安定化完了後は「一旦終了」として最終報告を提示し、セッションは終了せず起動したまま次のプロンプト指示を待つ。以後の細かい変更はユーザーの追加プロンプトを起点に、同じ自律開発サイクルで実行する。

---

## 22. 停止条件

次の場合のみ、進行を停止する。

- 対象環境または対象resourceを一意に判定できない。
- 必要なcredential、権限または接続がない。
- ユーザー変更を破壊せずに作業を継続できない。
- backup、rollbackまたは安全な移行方式を構築できない。
- criticalまたはhigh security issueを解消できない。
- データ整合性を保証できない。
- 外部サービス障害で安全な代替手段がない。
- 法令、契約、ライセンスまたは組織ポリシーとの抵触が疑われる。
- 安全な通常PRまたはApproval PRを作成できない。
- Claude Codeの権限機構が明示的なユーザー操作を要求している。

停止時も質問だけで終わらせず、次を提示する。

1. 停止理由
2. 現在までの実施内容
3. 影響範囲
4. 必要な権限または判断
5. 安全な代替案
6. 推奨案
7. 再開条件

---

