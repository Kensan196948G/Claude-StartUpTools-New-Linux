# /ship の実機確認手順（人が行う）

目的: 対話型 Claude Code セッションで `/ship` が使えることを、**何も変更せずに**確かめる。
`/ship` は公式仕様で「人が入力した行」からしか起動しないため、AI は代行できない（`claude -p` では `Nothing started`）。

## 1. 安全な確認（何も変更しない）— まずこれだけ

`/ship terms` は「watch 中に Claude がしてよいこと・制限」を表示するだけで、コミット・push・PR 作成をしない。

```bash
cd ~/Projects/Claude-StartUpTools-New-Linux
claude
```

起動したプロンプトで、次の順に入力する（毎回 Enter）:

| # | 入力 | 確認すること |
| --- | --- | --- |
| 1 | `/` | 候補一覧に `/ship` と `/steward` が出る |
| 2 | `/ship terms` | watch の制限（merge / approve / auto-merge 有効化 / force-push を止める等）の説明が表示される |
| 3 | `/tasks` | watch は動いていない（一覧に `/steward --tend` が無い） |
| 4 | `/exit` | 終了 |

結果の見方:

| 表示 | 意味 |
| --- | --- |
| 制限の説明が出る | **成功**。`/ship` はこの環境で使える |
| `Unknown command: /ship`、または `/code-review` が始まる | 未配信。`claude update` 後に 2 回起動し直す（公式の手順） |
| `Skill "ship-local" is disabled via skillOverrides` | 設定で無効化されている |
| `/ship is turned off right now` | `/login` をやり直す |

## 2. やってはいけないこと（この確認の範囲外）

- **引数なしの `/ship` を main で実行しない。** `/ship` は確認なしで、未コミットの変更をコミットし、新しいブランチを push し、PR を開く。
  このフォルダには ClaudeOS の学習データ（`.claude/claudeos/data/*.json`）の未コミット変更が常にあり、それが PR に含まれてしまう。
- 本リポジトリは **auto-merge が有効**で、ruleset は人間承認をまだ要求していない（承認事項 #3 が未）。
  公式 docs の警告どおり、auto-merge が登録された PR では watch の push がそのままマージに至り得る。

## 3. 実際に /ship を使うとき（次の段階）

本当の PR で試すときは、次を満たしてから行う:

1. 専用の作業ブランチと、**別の clone**（未コミットの学習データが無いところ）で行う
2. 先にドラフト PR を自分で作る（`/ship` は既存 PR があればそれを使い、未コミットの変更はコミットしない）
3. その PR に auto-merge を登録しない
4. 終わったら `/ship stop` で watch を止め、結果を署名で残す（`bin/ship-approve.sh ship-attest`）

## 4. 結果の記録

確認できたら、結果（成功 / 表示されたメッセージ）を伝えてもらえれば、AI が `docs/architecture/SHIP_DEVELOPMENT_STATUS.md`
と `config/claude-code-compat.json` の該当項目（`ship-command` / `steward-command`）を「実機確認済み」に更新する PR を作る。
