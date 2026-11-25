# Ship Native 運用手順書

## 0. 初回セットアップ（人間が行う）

詳しい手順・注意点: [SHIP_APPROVER_KEY_SETUP.md](SHIP_APPROVER_KEY_SETUP.md)

```bash
bash bin/ship.sh capability                  # 前提条件。overall / watch_blockers を確認
bash bin/ship-approve.sh keygen --name Kensan  # パスフレーズを 2 回入力 (12 文字以上)
# 表示された {name,key_id,public_key} を config/ship-policy.json の humanGate.approverKeys へ追加する PR を作り、
# 自分で内容を確認してマージする (bootstrap)。以後の承認検証は main 上のこの値だけを信頼する。
```

任意（保留中。#7・トークン分離とセットで検討。単独では偽装を防げない — `SHIP_SECURITY_MODEL.md` §4）: 人間専用 GitHub App（権限は Commit statuses: write のみ）を作り、
`bash bin/ship-approve.sh attach-app --app-id N --installation-id N --pem app.pem` で鍵束へ暗号化格納する。PEM は格納後に削除する。

## 1. 1 件の開発（SH2）

| # | 誰が | 操作 |
| --- | --- | --- |
| 1 | 人 | `bash bin/ship-mode.sh SH2 --project ~/Projects/<repo> --intent "<開発目的>"` |
| 2 | AI | 対話セッションで要件分析 → 実装 → ローカルテスト → commit → push → PR（既存 PR は `bin/ship.sh discover-pr` で再利用） |
| 3 | 人 | 同じセッションで `/ship`（停止は `/ship stop`、状況は `/tasks`） |
| 4 | 人 | 結果を署名: `bin/ship-approve.sh ship-attest --repo O/R --pr N --head <SHA> --reviewed yes --important-open 0 --watch checks-pass-comments-answered` |
| 5 | AI | `bin/ship.sh quality --repo O/R --project DIR --head <SHA> --base <SHA> --pr N --publish` |
| 6 | AI | `bin/ship.sh gate --repo O/R --pr N --requirements met [--impact-doc F] [--rollback-doc F]` |
| 7 | 人 | `bin/ship-approve.sh show --repo O/R --pr N` → 完成報告書を読む → `approve --head <SHA>` |
| 8 | AI | `bin/ship.sh merge --repo O/R --pr N --dry-run` → `bin/ship.sh merge --repo O/R --pr N` |
| 9 | AI | `bin/ship.sh monitor --once` で MERGED 確認 → run COMPLETED |

`/ship` が使えない環境（gh < 2.63、project hook あり）では手順 3・4 を省略できるが、
gate は Ship 未実施を CONDITIONAL/UNKNOWN として扱う（承認できない・マージ不可）。

### R0・R1 の PR（文書・テストのみ）: 手順 3・4 を「人の差分確認」に置き換えられる

`humanGate.reviewKindsByRisk` で R0・R1 に `human-diff` が許可されている場合（main 上のポリシーで判定）:

| # | 誰が | 操作 |
| --- | --- | --- |
| 3' | 人 | `gh pr diff N --repo O/R` で差分を読む |
| 4' | 人 | `bin/ship-approve.sh ship-attest --kind human-diff --repo O/R --pr N --head <SHA> --important-open 0`（変更ファイルとリスクが表示される。`yes` とパスフレーズで署名） |

- リスクは gate が変更ファイルから計算する。1 ファイルでも R2 以上（エージェントの指示書 `CLAUDE.md`・`.claude/**` などを含む）なら、署名自体が拒否され、gate も認めない。
- 署名後に push して head が変わると、署名は無効になる（再署名が必要）。
- 承認（手順 7）は省略できない。

## 2. 承認の取り消し・差し戻し

```bash
bash bin/ship-approve.sh revoke --id ha_xxx --reason "再確認が必要"
bash bin/ship-approve.sh reject --repo O/R --pr N --head <SHA> --reason "要件未充足"
```
Web コンソールからの取り消しは Cloudflare Access のメール付き JWT が必要。承認は Web からはできない（設計）。

## 3. 異常時

| 症状 | 確認 | 対応 |
| --- | --- | --- |
| merge が REFUSED | 出力 `reasons` | 理由に従う。`CENTRAL_POLICY_PROFILE_NOT_ENFORCED` は中央ポリシー施行待ち（正常） |
| run が BLOCKED (CIRCUIT_OPEN) | `bin/ship.sh run-status --id` の `next_retry_at` | GitHub 障害・認証を確認後 `run-transition --to SHIP_REVALIDATING` |
| `NONCE_CONSUMED` | 承認は 1 回限り | 再承認 |
| `STALE_HEAD` | push で head が変わった | quality → gate → 再承認 |
| 監査連鎖 NG | `bin/ship.sh audit-verify` | 改ざんの疑い。`~/.claudeos/ship` を保全し、人へエスカレーション |
| Ubuntu 再起動 / tmux 消失 | run は JSON に永続化 | `bin/ship.sh monitor --once` が GitHub と照合して状態を補正（古い状態だけでマージしない） |
| Claude 利用上限 | `/ship` の watch が `no next check-in was set` で終了 | 回復後に人が `/steward` で再開。従量課金への自動切替はしない |

## 4. ロールバック

- 機能: `config/ship-policy.json` の `merge.centralProfileEnforced=false`（既定）なら Merge Executor は登録しない。
- 起動モード: SH 系は追加のみで L1/T1/S1 は無変更。
- DB: `db/control/rollback/0006_ship_native.down.sql`（pg_dump 後に手動）。
- ruleset / 中央ポリシー: `SHIP_POLICY_MIGRATION.md` §6。
