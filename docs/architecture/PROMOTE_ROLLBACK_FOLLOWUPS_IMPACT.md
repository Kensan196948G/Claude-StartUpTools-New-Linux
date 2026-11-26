# 影響分析とロールバック: 昇格の自動復旧の残り（Issue #249、R3）

状態: 2026-11-26。

## 1. 変更と影響

| 場面 | 変更前 | 変更後 |
| --- | --- | --- |
| 昇格前の状態の記録 | 台帳から人が推測 | 手順 (2) の前に `releases/production-pre-promotion.json` へ残す（次の昇格まで保持。書けなければ何も変えずに中止） |
| 初回昇格で unit を戻せない | symlink を削除 | `production-current` を残す（`artifact_rollback=KEPT`）。残る unit が参照するため |
| unit を戻せない | そこで復旧を終了し、成果物・drop-in も戻らない | 成果物・previous・drop-in・dashboard は戻す。コンソールは restart も health 確認もしない（定義が不明、または削除した成果物を指す unit を起動して停止させないため）。`ROLLBACK_FAILED`・exit 4 |
| 復旧の daemon-reload の失敗 | そこで終了 | コンソールも dashboard も restart しない（読み込み済みの定義が昇格後のままのため）。`ROLLBACK_FAILED` |
| 復旧中の他の失敗（restart・health） | そこで終了、または後の失敗が理由を上書き | 残りを続け、すべて `rollback_errors` に残す。`reason` は最初の失敗 |
| `restored_target` | 戻せなくても昇格前の版が入る | 実際に戻っている場合だけ。昇格前の版は常に `pre_promotion_target` |
| previous が変わっていない | 必ず書き直し、書けないと `ROLLBACK_FAILED` | 変化がある場合だけ書く |
| 復旧中の INT/TERM/HUP | 復旧が中断される | 無視して完了する（子プロセスも引き継ぐ）。止めるには SIGKILL |
| `release-promote` の昇格で、切り戻し先が同じ版の health 失敗 | 「切り戻しました」と表示し、restart して `ROLLED_BACK` を記録 | 何も戻さず `HEALTH_CHECK_FAILED`。台帳へ書かず、restart しない |

- `restored_target` は成果物の symlink と previous が戻ったことを表し、稼働中の版を保証しない（unit を戻せず restart しない場合は、新版が稼働を続ける。手動対応が必要）。
- 切り戻し先が同じ版の分岐は、手順 (4) と手動 4-4 の health 失敗では常に通る。手動 4-4 の失敗は台帳に行が残らない（直前の行が末尾に残る）。
- `failed_step` は従来どおり最後に失敗した step を指し、`reason`（最初の失敗）と異なる場合がある。`rollback_errors`・`pre_promotion_target` は追加の項目で、他に利用しているスクリプトはない（`scripts`・`bin`・`lib` を検索）。
- 手動の Runbook 手順で同じ版の health が失敗した場合も、上の最終行の動作になる。
- 成功する昇格の経路は変わらない。secret・DB・migration・公開範囲の変更はない。
- 確認はテストのスタブ上で行った。実機の systemd では未確認。

残る限界: SIGKILL・再起動では復旧が走らない。health や systemctl が長く応答しない場合、Ctrl-C では止まらない。RUNBOOK §6 の順方向の health の制約は本変更の対象外。

## 2. ロールバック手順

`git revert <マージコミット>` の PR を作り、通常の手順でマージする。台帳は項目が増えるだけなので移行は不要。
