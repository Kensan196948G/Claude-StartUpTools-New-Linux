# 承認事項 #3: ruleset に 2 つの必須チェックを加える変更案（未適用）

状態: 2026-11-24 調査・変更案のみ。**ruleset は変更していない。** 適用は owner（ユーザー）が行い、AI は確認（readback）だけを行う。

## 1. 現状（API で再取得、2026-11-24）

| 項目 | 値 |
| --- | --- |
| ruleset | `central-auto-merge`（id `20882817`、enforcement=active、対象 `refs/heads/main`、最終更新 2026-09-07） |
| 必須チェック | `Secrets scan (gitleaks)`・`linux-validate`（strict = base への追随が必須） |
| PR ルール | 承認 0、squash のみ、push で古いレビューを無効化 |
| bypass | なし（`current_user_can_bypass: never`。owner も迂回できない） |
| その他 | force push 禁止（`non_fast_forward`）、main 削除禁止 |
| リポジトリ設定 | `allow_auto_merge=true` |

保存: [`ruleset/ruleset-20882817-before.json`](ruleset/ruleset-20882817-before.json)（**ロールバック用の正本**）

## 2. 変更内容（2 段階）

### 第 1 段階: context 名で必須化（推奨・まずこれ）

`required_status_checks` に 2 件を**追加**する（既存 2 件・strict・他のルールは不変）。差分はこれだけ:

```diff
         "required_status_checks": [
           { "context": "Secrets scan (gitleaks)" },
           { "context": "linux-validate" },
+          { "context": "claudeos/local-quality" },
+          { "context": "claudeos/human-approval" }
         ],
```

全文: [`ruleset/ruleset-20882817-stage1.json`](ruleset/ruleset-20882817-stage1.json)

### 第 2 段階: 承認の付与元を人間専用 GitHub App に限定（#4 の後）

GitHub の仕様（REST の `StatusCheckConfiguration`）: `integration_id` は「この status check が由来しなければならない integration の ID」で省略可。
`claudeos/human-approval` にだけ App の ID を付ける。テンプレート: [`ruleset/ruleset-20882817-stage2.template.json`](ruleset/ruleset-20882817-stage2.template.json)（`integration_id: 0` を実際の App ID に置き換える）。

## 3. 適用すると何が変わるか（正直な評価）

| | 第 1 段階後 | 第 2 段階後 |
| --- | --- | --- |
| 承認ステータスの無い PR | **GitHub がマージを拒否**（auto-merge も、画面のマージボタンも） | 同左 |
| 承認後に 1 コミットでも push | 新しい SHA には承認ステータスが無い → **マージ不可** | 同左 |
| base が進む（strict） | update-branch で head が変わる → 再承認が必要 | 同左 |
| AI が admin token で `claudeos/human-approval=success` を付ける | **防げない**（context 名だけで判定するため） | **防げる**（App 以外が付けた同名ステータスは条件を満たさない） |
| ClaudeOS の Merge Executor | ruleset 条件は満たす。ただし `centralProfileEnforced=false` の間は登録しない | 同左 |

**第 1 段階の効果は「うっかりマージ」の防止**（watch の push・auto-merge・`/ship` の迂回経路・人の誤操作）。
**意図的な偽装の防止は第 2 段階が必要**。どちらも ClaudeOS 側の署名検証（Merge Executor）と二重になる。

### 模擬確認（ClaudeOS Merge Executor の preflight、ruleset の値だけを差し替えて実行）

| ruleset | 結果（抜粋） |
| --- | --- |
| 現行 | REFUSED: `RULESET_DOES_NOT_REQUIRE claudeos/human-approval`・`…local-quality`・`CENTRAL_POLICY_PROFILE_NOT_ENFORCED` ほか |
| 第 1 段階後 | REFUSED: `RULESET_DOES_NOT_REQUIRE` が**消える**。残りは施行フラグ・gate・品質・承認 |
| 第 1 段階後 + `centralProfileEnforced=true` | REFUSED: gate・品質・人間承認の 3 つだけ（＝本来の条件だけが残る） |

## 4. 重大な副作用 — 適用前に必ず読む

1. **承認できる状態になるまで、main へのマージが全面的に止まる。**
   - 第 1 段階を適用した瞬間から、すべての PR に `claudeos/human-approval` が必要になる。
   - 承認ステータスを付けるには、承認者鍵が main に登録されていること（#10、まだ 0 件）と、`bin/ship-approve.sh approve` が動くことが必要。
   - 過去 30 日のマージは 108 件（すべて本人）。**#10 より先に #3 を適用すると、この流れが止まる**。
   - 現在 OPEN の #230・#231 も、適用後はこの手順でしか入らない。
2. **dependabot / renovate の PR も止まる**（横断巡回 `cross-repo-automerge` の対象から実質外れる）。承認事項 #2 は事実上これで解決するが、依存更新も人が承認する運用になる。
3. **ローカル品質の登録が必要になる。** `claudeos/local-quality` は `bin/ship.sh quality --publish` で付く（GitHub Actions では付かない）。実測で 1 回 約 12 分（npm-test が大半）。
4. 中央の ruleset 配布（`bin/policy-pr.sh`）は、必須チェックを持つ ruleset が既にあれば**作り直さない**（`ruleset_exists` を確認済み）。配布で上書きされる心配は無い。

## 5. 推奨する順序

| # | 作業 | 担当 |
| --- | --- | --- |
| 1 | 承認者鍵を作り（`keygen`）、公開鍵を登録する PR をマージ（#10） | 人 |
| 2 | 練習用の PR 1 件で `quality --publish` → `gate` → `approve` を通し、2 つのステータスが付くことを確認（ruleset 変更前なので何も止まらない） | AI + 人 |
| 3 | **第 1 段階**を適用（下記 §6） | 人 |
| 4 | 検証（§7） | AI（読み取り）+ 人 |
| 5 | 人間専用 GitHub App を作成（#4）→ **第 2 段階**を適用 | 人 |
| 6 | `centralProfileEnforced=true` にする PR（R4）→ 初めて ClaudeOS の自動マージが有効になる | 人の承認 |

## 6. 適用手順（owner が実行）

```bash
cd ~/Projects/Claude-StartUpTools-New-Linux
# 1) 適用直前に現状を再取得し、保存した before と同じことを確認する（違えば中止して相談）
gh api repos/Kensan196948G/Claude-StartUpTools-New-Linux/rulesets/20882817 \
  | jq -S '{name,target,enforcement,conditions,bypass_actors,rules}' > /tmp/rs-now.json
diff <(jq -S . docs/architecture/ruleset/ruleset-20882817-before.json) /tmp/rs-now.json && echo "一致"

# 2) 第 1 段階を適用
gh api -X PUT repos/Kensan196948G/Claude-StartUpTools-New-Linux/rulesets/20882817 \
  --input docs/architecture/ruleset/ruleset-20882817-stage1.json
```

GitHub の画面で行う場合: Settings → Rules → Rulesets → `central-auto-merge` → Require status checks to pass →
「Add checks」で `claudeos/local-quality` と `claudeos/human-approval` を追加（第 1 段階は「Any source」のまま）。

## 7. 適用後の確認（AI が読み取りで行える）

1. `gh api repos/<repo>/rules/branches/main` の必須チェックが 4 件であること
2. `bash bin/ship.sh merge --repo <repo> --pr <N> --dry-run` の理由から `RULESET_DOES_NOT_REQUIRE` が消えること
3. 承認ステータスの無いテスト PR で `mergeStateStatus=BLOCKED` になり、画面のマージボタンが押せないこと
4. 承認後に空コミットを push すると、再び BLOCKED になること（SHA 固定の確認）

## 8. 元に戻す手順

```bash
gh api -X PUT repos/Kensan196948G/Claude-StartUpTools-New-Linux/rulesets/20882817 \
  --input docs/architecture/ruleset/ruleset-20882817-before.json
```

画面で行う場合は、追加した 2 件を削除する。即時に元の状態（必須チェック 2 件）へ戻る。
