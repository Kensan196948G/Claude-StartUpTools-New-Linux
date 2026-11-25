# 影響分析とロールバック: unit の Documentation URI 化と昇格台帳の二重記録の解消（PR #241、R3）

状態: 2026-11-26。PR #241 の R3 要件（変更影響分析・ロールバック手順）を満たすための文書。変更の目的と対象外は PR 本文を参照する。

## 1. 変更内容

- `bin/web-startup-service.sh`・`bin/staging-smoke-timer.sh`: 生成する systemd unit の `Documentation=` を `file:/絶対パス` 形式にする（従来はパスのままで、systemd が `Invalid URL, ignoring` を警告していた）。
- `bin/promote-production.sh`・`lib/release-promote.sh`: 昇格台帳 `promotions.jsonl` の `PROMOTED` 二重記録を解消する。手順 (2)（symlink の事前準備）だけが内部の環境変数 `CCSU_PROMOTE_SKIP_PROMOTED_LEDGER=1` で記録を省き、手順 (4) の本実行が 1 行だけ残す。オーケストレータの冒頭で変数を `unset` するため、外部から設定しても手順 (4) へは継承されない。
- 対応する bats の更新・追加（4 ファイル）。

## 2. 影響分析

| 観点 | 影響 | 根拠 |
| --- | --- | --- |
| 稼働中の本番 | なし。コード変更のみで、既存の unit ファイルは書き換えない | 次回の `--register` から新形式になる |
| 次回の本番昇格 | 台帳の `PROMOTED` が 2 行から 1 行になる。`Documentation=` の警告が出なくなる | `release-promote.bats`・`promote-production.bats` |
| 失敗して復旧する昇格 | 従来の「`PROMOTED` → `ROLLED_BACK`」の 2 行が `ROLLED_BACK` のみになる。昇格は確定していないため記録として妥当 | PR 本文「仕様の変更」 |
| 台帳の読み手 | `post-deploy-smoke.sh` は最終行の時刻のみ、`deploy-status.sh` は末尾 5 件の表示のみで影響なし | 両スクリプトの参照箇所を確認済み |
| 環境変数の継承 | 外部で `CCSU_PROMOTE_SKIP_PROMOTED_LEDGER=1` を設定しても、`unset` により手順 (4) は常に 1 行を残す（回帰テストあり） | 独立レビューの important 1 件を修正済み |
| `ROLLED_BACK` の記録 | 変更なし（常に記録） | |
| セキュリティ | secret・権限・公開範囲の変更なし。判定・検証には影響せず、記録の省略のみ | |
| データ・migration | なし | |

既知の限界（PR 本文の残課題）: 台帳の `previous_commit` が手順 (4) の記録では対象 commit と同じになる（`production-previous` ファイルは正しい）。`Documentation=` のパスに空白・`%` を含む場合は従来と同じ。

## 3. ロールバック手順

1. `git revert <マージコミット>` で PR 全体を戻し、通常の手順で成果物を作成して昇格する。
2. 台帳の形式は変わらない（行が 1 行減るだけ）ため、戻した後に台帳の移行は不要。既に残った 1 行の記録はそのままでよい。
3. 既に `--register` 済みの unit は `Documentation=` が新形式のまま残るが、動作に影響しない（旧形式は警告が出るだけ）。必要なら `--register` を再実行して旧形式へ戻す。
