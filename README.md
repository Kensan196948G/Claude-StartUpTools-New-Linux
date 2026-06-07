# Claude-StartUpTools-New-Linux

Linux 用の Claude Code 自律開発スタートアップツールです。`/home/kensan/Projects` 配下の Git リポジトリを起動候補として列挙し、Claude Code を tmux 上で起動・監視・自律再開します。

## 目的

- SSH 接続機能を持たない Linux ローカル専用ランチャー
- Project ルート配下のフォルダを登録プロジェクト候補として動的検出
- Supervisor による全登録プロジェクトへの安全な自律再開
- 数字付き個別選択と全適用の両方を提供
- CTO 全権委任による自律開発。ただし最終決断は人間が選択

## 基本起動

```bash
cp config/config.json.template config/config.json
./start.sh
```

メニューでは `L1` がフォアグラウンド起動、`S1` がバックグラウンド自律起動、`MO` が統合コントロールセンターです。

## コントロールセンター

```bash
bash bin/monitor-sessions.sh open
```

主な操作:

| キー | 動作 |
|---|---|
| `1`-`9` | 実行中Claudeセッションへ介入 |
| `n` | 全プロジェクトから数字付きで個別追加 |
| `a` | Supervisor全適用の計画表示と実行確認 |
| `l` | 登録済みプロジェクトを1回だけ自律起動 |
| `s` | 登録済みプロジェクトを選んでSupervisor開始 |
| `x` | Supervisor停止 |
| `d` | 登録削除 |
| `q` | コントロールセンター終了 |

## Supervisor 全適用

まず対象を確認します。

```bash
bash bin/autonomy.sh start --all --dry-run
```

確認後に開始します。

```bash
bash bin/autonomy.sh start --all --yes
```

既定では以下を安全のため skip します。

- 既にSupervisor稼働中のプロジェクト
- cron登録が残っているプロジェクト
- このランチャー自身のリポジトリ

cron登録済みも含めて開始する場合のみ、意図を理解した上で `--force` を付けます。

## 人間の最終決断

Claude/CTO は実装、検証、修正、レビュー、文書更新、PR準備を自律実行します。以下は人間の明示選択が必要です。

- 本番公開、外部公開URL切替、課金が発生する操作
- 秘密情報の登録・削除
- データ削除、履歴改変、force push
- main 直push、PR merge
- 全プロジェクトSupervisor適用の最終実行

## 検証

```bash
npm test
npm run lint
```

CI は Ubuntu 上で `bats`、Node test、`shellcheck` を実行します。
