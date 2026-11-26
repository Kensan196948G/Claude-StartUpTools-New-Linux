# 影響分析とロールバック: 昇格の自動復旧を昇格前の状態へ戻す（Issue #244・#245、R3）

状態: 2026-11-26。

## 1. 原因と変更

`promote-production.sh` の自動復旧は `release-promote.sh --rollback --no-restart` に依存していた。この経路は、手順 (2) が書き換えた後の `production-previous` と、稼働中プロセスの health を信じるため、次の誤りが起きた（テストのスタブ上で再現し、修正前に失敗することを確認。実機では未確認）。

- 手順 (4) の失敗で、昇格前の版へ戻らないことがある（#244）
- symlink を変える前の中断や、同じ版の再昇格の失敗で、本番が 1 つ前の版へ後退する（#245）

変更:

- `bin/promote-production.sh`: 手順 (2) の前に `production-current`・`production-previous`・dashboard の drop-in を控え、復旧ではその状態へ直接戻す。`--rollback` は呼ばない。控えが取れなければ何も変えずに中止する。手順 (2) の失敗でも控えた状態へ戻す。
- `lib/release-promote.sh`: `--rollback --no-restart` は health を確認しない（restart しないため、戻し先を測れない）。

## 2. 影響分析

| 場面 | 変更後 | `artifact_rollback` |
| --- | --- | --- |
| 通常の失敗（symlink を変えた後） | 昇格前の版と previous へ戻す | `ROLLED_BACK` |
| symlink を変える前の中断・同じ版の再昇格 | symlink は変えない。unit の復元と restart は行う（短い停止がある） | `UNCHANGED`（新しい値） |
| 昇格前に symlink が無い初回昇格 | symlink を削除する（従来と同じ） | `NO_PREVIOUS_REMOVED` |
| 2 回目以降の昇格の失敗 | 昇格前からある drop-in は削除せず同じ内容へ戻し、dashboard を restart する | — |
| 手順 (2) の失敗 | `production-current` と previous を控えた状態へ戻して `ABORTED`。戻せなければ `ROLLBACK_FAILED` | — |
| drop-in を戻せない | 残りの復旧（daemon-reload・restart・health）は続け、`ROLLBACK_FAILED`・exit 4 | — |
| symlink を戻せない | unit・dashboard の復旧は続け、`ROLLBACK_FAILED`・exit 4（従来は警告のみで `ROLLED_BACK` 扱い） | `FAILED` |

- 台帳の復旧行に `pre_promotion_target`（昇格前の `production-current`）と、実際に戻っている場合だけ値が入る `restored_target` を記録する（#249）。
- drop-in の控え（`50-release.conf.bak-<時刻>`）は残る。`.conf` で終わらないため systemd は読まない。
- 台帳: 復旧で `release-promote --rollback` を呼ばないため、その経路の `ROLLED_BACK` 行は増えない。オーケストレータの 1 行は従来どおり残る。
- 判定は「どの手順まで進んだか」ではなく実際の symlink と控えの比較で行う（中断は手順の途中で起こり得る）。
- 手動の `--rollback`（restart あり）の挙動は変わらない。`--rollback --no-restart` は health を確認しなくなるので、呼び出し側が restart と health を確認する。
- 通常の昇格（成功経路）は、控えを取る読み取り以外に変化がない。
- secret・DB・migration・公開範囲の変更はない。

残る限界: SIGKILL・再起動では復旧が走らない（復旧中の INT/TERM/HUP は #249 の対応で無視する）。昇格の順方向（`--release ... --no-restart`）の health 確認は変えていないため、本番が不健全だと修正版を昇格できない（RUNBOOK §6）。

## 3. ロールバック手順

`git revert <マージコミット>` の PR を作り、通常の手順でマージする。台帳と symlink の形式は変わらないため移行は不要。戻すと上記 2 件の不具合も戻る。
