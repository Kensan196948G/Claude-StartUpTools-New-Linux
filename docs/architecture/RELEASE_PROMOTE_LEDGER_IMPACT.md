# 影響分析とロールバック: unit の Documentation URI 化と昇格台帳の二重記録の解消（PR #241、R3）

状態: 2026-11-26。PR #241 の R3 要件（変更影響分析・ロールバック手順）を満たすための文書。変更の目的と対象外は PR 本文を参照する。

注: 本書は PR #241 時点の記録。自動復旧の経路は後に `PROMOTE_ROLLBACK_TARGET_IMPACT.md` の変更で置き換えた（`release-promote --rollback` は呼ばない）。

## 1. 変更内容

- `bin/web-startup-service.sh`・`bin/staging-smoke-timer.sh`: 生成する systemd unit の `Documentation=` を `file:/絶対パス` 形式にする（従来はパスのままで、systemd が `Invalid URL, ignoring` を警告していた）。
- `bin/promote-production.sh`・`lib/release-promote.sh`: 昇格台帳 `promotions.jsonl` の `PROMOTED` 二重記録を解消する。手順 (2)（symlink の事前準備）だけが内部の環境変数 `CCSU_PROMOTE_SKIP_PROMOTED_LEDGER=1` で記録を省き、手順 (4) の本実行が 1 行だけ残す。オーケストレータの冒頭で変数を `unset` するため、外部から設定しても手順 (4) へは継承されない。
- 対応する bats の更新・追加（4 ファイル）。

## 2. 影響分析

| 観点 | 影響 | 根拠 |
| --- | --- | --- |
| 稼働中の本番 | なし。コード変更のみで、既存の unit ファイルは書き換えない | 次回の `--register` から新形式になる |
| 次回の本番昇格 | 台帳の `PROMOTED` が 2 行から 1 行になる。`Documentation=` の警告が出なくなる | `release-promote.bats`・`promote-production.bats` |
| 手順 (3)・(3d) の失敗・中断 | 手順 (2) の `PROMOTED` は残らず、`ROLLED_BACK` が記録される（`release-promote --rollback` とオーケストレータの 2 経路のため複数行になり得る） | コードの読解 |
| 手順 (4) の失敗 | 切り戻し先が同じ版の場合、手順 (4) は台帳へ書かない（#249）。外側の復旧が 1 行追記する | `release-promote.bats` |
| 手順 (5) の失敗 | 手順 (4) が書いた `PROMOTED` は残り、その後に `ROLLED_BACK` が追記される | コードの読解 |
| 自動復旧も失敗 | `ROLLBACK_FAILED` を 1 行追記し、試行が台帳から消えないようにする（本 PR で追加） | `promote-production.bats` |
| 台帳の読み手 | `post-deploy-smoke.sh` は最終行の時刻のみ、`deploy-status.sh` は末尾 5 件の表示のみで影響なし | 両スクリプトの参照箇所を確認済み |
| 環境変数の継承 | `promote-production.sh` は起動時に `unset` する。`release-promote.sh` を直接実行して変数が残っていても、省略は `--no-restart` に限るため通常の昇格は記録される（回帰テストあり） | 独立レビューの important 1 件を修正済み |
| `ROLLED_BACK` の記録 | 変更なし（常に記録） | |
| セキュリティ | secret・権限・公開範囲の変更なし。判定・検証には影響せず、記録の省略のみ | |
| データ・migration | なし | |

既知の限界: 台帳の行に `previous_commit` 項目はない（`--json` の標準出力にだけあり、手順 (4) では対象 commit と同じ値になる。`production-previous` ファイルは正しい）。`Documentation=` のパスに空白・`%` を含む場合は従来と同じ。手順 (4) の health 失敗時の切り戻し先が新版自身になり得る既存の不具合は、本 PR の対象外として別 Issue で扱う。

## 3. ロールバック手順

1. `git revert <マージコミット>` で PR 全体を戻し、通常の手順で成果物を作成して昇格する。
2. 台帳の項目の形式は変わらない（`PROMOTED` が 1 行になり、`result=ROLLBACK_FAILED` の行が増え得る）ため、戻した後に台帳の移行は不要。記録済みの行はそのままでよい。
3. 既に `--register` 済みの unit は `Documentation=` が新形式のまま残るが、動作に影響しないため書き戻さなくてよい。**引数なしの `--register` は実行しない**（本番 unit が作業ツリー直実行に変わり、`--env`・`--state-file` も消える）。書き戻す場合は `STAGING_PRODUCTION_RUNBOOK.md` の本番 unit 差し替え手順にある引数をすべて指定する。

## 4. 残る限界

- SIGKILL・ホスト再起動では、symlink が新版のまま台帳に行が残らないことがある（手順 (2) の `PROMOTED` を省いたため）。実状態は `production-current` の指す先で確認する。
- `post-deploy-smoke.sh` の `promotions` 項目は最終行の `at` だけを見るため、`ROLLBACK_FAILED` の直後でも PASS になる（判定ロジックは本 PR 以前から）。
- 復旧経路の既存の不具合は Issue #244 などで扱う。
