# 完全自律開発対応チェックリスト

対象: ClaudeOS / Linux local Supervisor
目的: 登録プロジェクトを CTO Claude 主導で継続開発できる状態にする

## 起動前チェック

| # | 確認項目 | 確認コマンド |
|---|---|---|
| 1 | Claude CLI が使える | `claude --version` |
| 2 | 対象が Git リポジトリ | `git -C /home/kensan/Projects/<project> status --short` |
| 3 | リモート設定済み | `git -C /home/kensan/Projects/<project> remote -v` |
| 4 | Claude テンプレート配備済み | `test -f /home/kensan/Projects/<project>/CLAUDE.md` |
| 5 | START_PROMPT 配備済み | `test -f /home/kensan/Projects/<project>/.claude/START_PROMPT.md` |
| 6 | state テンプレート確認済み | `test -f state.json.example` |
| 7 | Supervisor 対象確認済み | `bash bin/autonomy.sh start --all --dry-run` |

## Supervisor 適用

個別:

```bash
bash bin/autonomy.sh start --project <project>
```

全登録プロジェクト:

```bash
bash bin/autonomy.sh start --all --dry-run
bash bin/autonomy.sh start --all --yes
```

監視メニュー:

```bash
bash bin/monitor-sessions.sh
```

`[a]` は全登録プロジェクトへの Supervisor 適用、`[n]` は数字付き個別選択です。

## 人間の最終判断

CTO Claude に任せる範囲:

- 調査、実装、テスト、レビュー
- ドキュメント更新
- Issue/PR の下書き
- 失敗時の原因分析と修正案作成

人間が決める範囲:

- 本番公開、PR merge、main 直push
- Secrets、課金、外部サービス設定
- 破壊的削除、不可逆なデータ変更
- Supervisor 全適用の最終実行

## 検証

```bash
npm test
npm run lint
bash bin/autonomy.sh start --all --dry-run
```

## 関連ファイル

| ファイル | 役割 |
|---|---|
| `bin/autonomy.sh` | Supervisor 個別/全適用 CLI |
| `bin/monitor-sessions.sh` | 監視と操作メニュー |
| `Claude/templates/claude/CLAUDE.md` | CTO Claude 方針テンプレート |
| `Claude/templates/claude/START_PROMPT.md` | 自律開発開始プロンプト |
| `Claude/templates/linux/cron-launcher.sh` | cron からのローカル起動 |
