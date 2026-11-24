# 中央 PR #185（GITHUB_POLICY v3.1 案 §10.2）マージ判断材料

状態: 2026-11-24 調査のみ。**AI はマージしない。** PR: https://github.com/Kensan196948G/Deep-Seek-Harness-Project/pull/185

## 1. 現状（実測）

| 項目 | 値 |
| --- | --- |
| 状態 | OPEN / **Draft** / auto-merge 未登録 |
| マージ可否（GitHub） | mergeable=MERGEABLE、mergeStateStatus=CLEAN（競合なし） |
| head / base | `43805701f664…` / `e296e32eeffa…`（中央の既定ブランチ最新） |
| 必須チェック（中央 ruleset） | quality (20)・quality (24)・compatibility・db・profile-audit — **5 件すべて pass** |
| 変更ファイル | `GITHUB_POLICY.md` のみ（+69 / −3） |
| 削除行 3 行の中身 | 状態行・§3 の相互参照文・§10 見出し（§10.2 追加に伴う文言更新。**既存 §10 の本文と統制は変更なし**） |
| レビュー / コメント | なし |
| ローカル検証 | 中央のポリシー関連テスト 29/29 pass |

## 2. マージすると起きること / 起きないこと

| | 内容 |
| --- | --- |
| 起きる | 中央正本に §10.2 が載り、方式 B の適用除外が**ポリシーとして発効**する |
| 起きない | 中央・本リポジトリの ruleset 変更、Actions 停止、承認鍵登録、横断巡回の除外（すべて別の承認事項） |
| 起きない | 他 Workspace への自動配布（`bin/distribute-policy.sh` は手動実行のみ。timer / cron が無いことを確認） |
| 起きない | 本リポジトリの自動マージ有効化。Merge Executor は `config/ship-policy.json` の `merge.centralProfileEnforced=false` の間は登録しない。このファイルは PR #228 が未マージのため既定ブランチにまだ存在しない |

**#185 のマージは「方針として認める」だけで、実際の挙動は何も変わらない（Fail Closed のまま）。**

## 3. マージ前に確認してほしい点

1. §10.2「既知の限界」の 2 点（GitHub App 化までは承認ステータスを偽装できる / 同一 OS ユーザーの問題）を受け入れたうえで発効させてよいか。
2. 横断巡回の除外（承認事項 #2）は §10.2 の施行条件に「別途 owner 承認」と書いた。#185 と同時に進めるか、後にするか。
3. §10.2 は v3 §10 と同じく「チャット上の指示の転記であり、GitHub 本人性の証明ではない」と明記している。

## 4. 推奨順序

1. PR #228（本リポジトリ）はドラフトのまま置く
2. #185 をマージ（ユーザー）→ 方針発効
3. 承認鍵の作成・登録（#10）→ ruleset 変更（#3）→ 検証用 PR で「承認なしではマージ不可」を確認
4. `centralProfileEnforced=true` にする PR（R4・人間承認）
