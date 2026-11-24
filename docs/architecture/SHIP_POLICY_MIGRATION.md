# Ship Native と中央 GitHub ポリシーの整合（変更案・未施行）

状態: **起案済み・未発効（2026-11-24）。** 方式 B を中央リポジトリのドラフト PR [Deep-Seek-Harness-Project#185](https://github.com/Kensan196948G/Deep-Seek-Harness-Project/pull/185) として作成した（§10.2）。中央正本 main は未変更。発効はユーザーによる同 PR のマージ。
対象: 中央正本 `Kensan196948G/Deep-Seek-Harness-Project` の `GITHUB_POLICY.md` v3（本リポジトリの `GITHUB_POLICY.md` は 2026-11-23 同期のミラー）

## 1. 矛盾の内容

| 項目 | 中央ポリシー v3 | Ship Native (v5.0) の要件 |
| --- | --- | --- |
| マージ条件 | Required Checks 成功で自動 merge（§1・§4・§5 手順 8・§6 ruleset `central-auto-merge` = 承認 0） | 人間の最終承認（SHA 固定）を経た PR だけを自動 merge |
| 人間の判断 | §3 表で「merge は人間承認が必要」という Workspace 記述を中央が上書き | R0〜R4 の全 PR で人間承認が必須（指示書 §13） |
| 変更権限 | §8 「本ポリシー自体の変更」は人間承認 | 同左。AI はミラーだけを書き換えて整合したことにしない |

ミラー (`GITHUB_POLICY.md`) は書き換えていない。ローカルの `config/ship-policy.json` は `merge.centralProfileEnforced=false` とし、
この値が `true` になるまで Merge Executor は auto-merge を **登録しない**（`scripts/ship/lib/merge.js` preflight。テスト済み）。

## 2. 方式比較

| | 方式 A: 次版にプロファイル追加 | 方式 B: 本リポジトリ限定の適用除外（§10 へ追記） | 方式 C: 人間承認 Required Check を全体標準に |
| --- | --- | --- | --- |
| 内容 | v4 として「Ship Native 運用プロファイル」を新設し、選択したリポジトリが採用 | v3 §10 の先例（Mirai-Platform-Infra）と同じ形で `Claude-StartUpTools-New-Linux` を追加 | `central-auto-merge` ruleset の必須チェックに `claudeos/human-approval` を全リポジトリで追加 |
| 影響範囲 | 中央ポリシー本文・配布スクリプト・全 Workspace のミラー | 本リポジトリ 1 件のみ | 全リポジトリ（dependabot の横断自動マージも止まる） |
| メリット | 他リポジトリへ横展開しやすい | 影響最小・先例あり・可逆 | 統制が最も強い |
| デメリット | 設計・配布の作業量が大きい。採用判断が各リポジトリに必要 | 横展開時に再度承認が要る | 全 Workspace の運用が一斉に変わる。横断巡回 (`cross-repo-automerge`) と衝突 |
| ロールバック | v3 へ戻す PR | §10 の追記を削除する PR + ruleset を元に戻す | ruleset から必須チェックを外す（全リポジトリ） |
| 費用 | 0 | 0 | 0 |

**推奨: 方式 B**（影響が本リポジトリに閉じ、v3 §10 に同型の先例がある）。実績が出た後に方式 A で一般化する。

## 3. 方式 B の中央ポリシー追記案（中央リポジトリへ出す PR の本文案）

```markdown
### 10.2 適用除外（Repo限定・Ship Native 人間承認プロファイル・v3.1 案）

対象: `Kensan196948G/Claude-StartUpTools-New-Linux` **のみ**。他リポジトリへ拡大しない。

適用除外する条項:
- §5 手順 8 のうち「Required Checks PASS だけを条件に Auto-Merge 登録する」部分
- §6 ruleset `central-auto-merge` の「承認 0」を補う必須チェックの追加禁止（下記 2 context を必須チェックに加える）

代わりに適用する方式（Ship Native 人間ゲート）:
1. ローカル品質検証（Ubuntu・隔離実行）の結果を Commit Status `claudeos/local-quality` として head SHA に登録する。
2. ClaudeOS AI Quality Gate（独自機能。Anthropic 公式 Claude Approvals ではない）が PASS の PR だけを人間へ提示する。
3. 人間がパスフレーズ保護の署名鍵で head SHA・base SHA に固定した承認を発行し、Commit Status `claudeos/human-approval` を登録する。
4. ruleset の必須チェックに `claudeos/local-quality` と `claudeos/human-approval` を加え、strict（base 追随必須）を維持する。
   承認後に head が変われば新 SHA には承認ステータスが無く、GitHub がマージを拒否する。
5. 上記がそろった後にだけ `gh pr merge --auto --squash --match-head-commit <SHA>` を登録する。AI は承認を代理生成しない。

施行条件:
- ClaudeOS 側実装（`bin/ship.sh` / `bin/ship-approve.sh`）と ruleset 変更が完了した後に適用する。
- ruleset 変更と承認者鍵の登録は owner が行い、AI は readback のみ行う。
- 横断巡回 `cross-repo-automerge` の対象から本リポジトリを除外する（人間承認前のマージ防止）。

維持される統制: §8 の人間判断、main 直接 push 禁止、`--admin` 迂回禁止、force push 禁止、main 削除禁止。
```

## 4. 意図しない伝播の防止

| 経路 | 状態（2026-11-24 実測） | 対策 |
| --- | --- | --- |
| `claudeos-cross-repo-automerge.timer`（毎時 :15） | 稼働中。対象は active ruleset を持つ repo の dependabot / renovate PR | 本リポジトリを除外リストへ加える変更を **承認事項 #2** として提示。今回は変更していない（人間の PR は元々対象外のため、現時点で Ship 対象 PR を誤マージする経路は無い） |
| 中央 `bin/policy-pr.sh` による ruleset 一括配布 | 中央側の手動実行 | 方式 B の追記で本リポジトリを個別扱いにする |
| cron / systemd による設定配布 | 本変更では新規の timer / cron を **追加していない** | `bin/ship.sh monitor` は手動実行または人間が登録する |

## 5. 施行手順（人間承認後）

1. 中央リポジトリに §3 の PR を作成し、人間がレビュー・マージ（承認事項 #1）。
2. 本リポジトリのミラー `GITHUB_POLICY.md` を中央正本に再同期（通常 PR）。
3. 承認者鍵の登録（`bin/ship-approve.sh keygen` → `config/ship-policy.json` の `humanGate.approverKeys` に追加する PR を人間がマージ）。
4. （推奨）人間専用 GitHub App を作成し、ruleset で `claudeos/human-approval` の integration_id を限定（承認事項 #4）。
5. ruleset `central-auto-merge` に 2 context を追加（承認事項 #3。下の JSON）。
6. 新しい必須チェックが機能することを検証用 PR で確認（承認ステータスなしでマージ不可になること）。
7. `config/ship-policy.json` の `merge.centralProfileEnforced` を `true` にする PR（R4・人間承認）。

### ruleset 変更案（`required_status_checks` の差分）

```json
{
  "required_status_checks": [
    { "context": "Secrets scan (gitleaks)" },
    { "context": "linux-validate" },
    { "context": "claudeos/local-quality" },
    { "context": "claudeos/human-approval" }
  ],
  "strict_required_status_checks_policy": true
}
```

GitHub App 化後は `claudeos/human-approval` に `"integration_id": <App ID>` を付ける。

## 6. ロールバック

- ruleset: 追加した 2 context を外す（`gh api -X PUT repos/<repo>/rulesets/20882817` で元の JSON を戻す。元 JSON は `docs/architecture/GITHUB_ACTIONS_MIGRATION.md` §2 に記録）。
- 中央ポリシー: §10.2 を削除する PR。
- ClaudeOS: `merge.centralProfileEnforced=false` に戻すと Merge Executor は即座に登録を止める。
