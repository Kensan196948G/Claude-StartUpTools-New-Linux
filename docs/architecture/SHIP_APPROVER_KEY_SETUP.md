# 承認者鍵の作成と登録（承認事項 #10）

対象: 人間の承認者本人。**AI はこの手順を代行しない**（パスフレーズは端末からの対話入力のみ受け付ける）。
検証: 2026-11-24、使い捨ての場所で `keygen` を疑似端末から実行し、下記の動作を確認した（その鍵は削除済み。本番の鍵束は未作成）。

## 0. 前提と順序

| # | 条件 | 理由 |
| --- | --- | --- |
| 1 | PR #228 が main にマージ済み | 承認の検証は **main 上の** `config/ship-policy.json` の `humanGate.approverKeys` だけを信頼する。main にこのファイルが無い間は鍵を登録できない |
| 2 | 端末（TTY）で操作する | AI の Bash ツールや `ssh` の非対話実行、パイプからは入力できない（`NO_TTY` で拒否） |
| 3 | パスフレーズを決めておく | **12 文字以上**、6 種類以上の文字を含む。パスワード管理ツールに保存し、AI が読める場所（チャット、ファイル、環境変数）には書かない |

## 1. 鍵を作る（約 10 秒）

```bash
cd ~/Projects/Claude-StartUpTools-New-Linux
bash bin/ship-approve.sh keygen --name Kensan
```

- `新しい承認パスフレーズ (12 文字以上):` → 入力（画面には表示されない）
- `もう一度:` → 同じものを入力
- 鍵束が `~/.config/claudeos-approver/key.json`（権限 600）に保存される。秘密鍵は scrypt（N=131072）+ AES-256-GCM で暗号化されており、ファイルに平文の秘密鍵は含まれない
- 最後に 1 行の JSON が表示される（例）:

```json
{"name":"Kensan","key_id":"sha256:…","public_key":"…"}
```

この 1 行は**公開情報**（公開鍵と fingerprint）なので、PR に載せてよい。

### よくある表示

| 表示 | 意味 / 対処 |
| --- | --- |
| `PASSPHRASE_TOO_SHORT (>= 12)` | 12 文字以上にする |
| `PASSPHRASE_TOO_SIMPLE` | 同じ文字の繰り返しなど。文字の種類を増やす |
| `PASSPHRASE_MISMATCH` | 2 回の入力が違う。やり直す |
| `KEY_EXISTS` | 既に鍵束がある。作り直す場合だけ `--force`（古い鍵による承認は使えなくなる） |
| `NO_TTY` | 端末から実行していない |

## 2. 公開鍵を登録する（R4 の PR。あなたがレビューしてマージ）

1. 作業ブランチで `config/ship-policy.json` の `humanGate.approverKeys` に、手順 1 で表示された 1 行を追加する:
   ```json
   "approverKeys": [ {"name":"Kensan","key_id":"sha256:…","public_key":"…"} ],
   ```
2. PR を作る。変更は `config/ship-policy.json` の 1 か所だけであることを自分の目で確認してマージする。
   この PR は R4（承認基盤）に分類される。**この最初の 1 件だけは、まだ承認の仕組みが無いため、通常のレビューでマージする（bootstrap）。**
3. AI にこの PR を作らせてもよいが、その場合も `key_id` が手順 1 の表示と一致することを**あなたが**確認する（AI が別の鍵にすり替える攻撃を防ぐため）。

## 3. 確認

```bash
bash bin/ship-approve.sh show --repo Kensan196948G/Claude-StartUpTools-New-Linux --pr <番号>
```

承認できる PR が無くても、`KEY_NOT_TRUSTED` が出なければ登録は有効。

## 4. 動作確認で確かめた性質（使い捨て鍵、2026-11-24）

| 確認 | 結果 |
| --- | --- |
| keygen の所要時間 | 約 8 秒（入力待ちを含む） |
| 正しいパスフレーズでの復号 | 成功（約 0.6 秒） |
| 誤ったパスフレーズ | `BAD_PASSPHRASE` で失敗（総当たりは 1 回あたり約 0.6 秒） |
| 12 文字未満 | `PASSPHRASE_TOO_SHORT` で拒否 |
| 既存の鍵束 | `KEY_EXISTS` で上書きしない |
| 鍵束ファイル | 権限 600、平文の秘密鍵を含まない |

## 5. 失くしたとき / 漏れたとき

- **パスフレーズを忘れた**: 復元できない。`keygen --force` で作り直し、手順 2 で `approverKeys` を新しい鍵に差し替える（R4 の PR）。古い鍵による未使用の承認は自動で無効になる。
- **パスフレーズや鍵束が漏れた疑い**: 直ちに `approverKeys` から該当の `key_id` を外す PR をマージする（以後その鍵の承認はすべて無効）。発行済みの承認は `bin/ship-approve.sh revoke --id <承認ID>` でも個別に取り消せる。

## 6. 任意（保留中）: 人間専用 GitHub App（承認事項 #4）

> **2026-11-24 訂正**: GitHub App と `integration_id` の限定だけでは、意図的な偽装は防げない。AI が使う gh トークンはリポジトリ所有者本人のもので admin 権限（`repo` スコープ）を持ち、ruleset 自体を書き換えて `integration_id` の条件を外せる（`bypass_actors: []` はマージ時の迂回を禁じるだけで、ruleset の編集は止めない）。App が意味を持つのは、AI のトークンから admin 権限を外した後（承認事項 #7・トークン分離）である。そのため #4（App）は単独では行わず、#7・トークン分離とセットで後日検討する。

鍵束に GitHub App の秘密鍵も暗号化して入れると、承認ステータスを App として付けられる。ruleset で
`claudeos/human-approval` の `integration_id` をその App に限定できる（ただし上の訂正のとおり、AI の token が admin 権限を持つ間は ruleset ごと書き換えられる）。

```bash
bash bin/ship-approve.sh attach-app --app-id <App ID> --installation-id <ID> --pem <app.pem>
```

App の作成（権限は Commit statuses: write のみ）と ruleset の変更は承認事項 #4・#3。
