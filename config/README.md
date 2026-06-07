# 設定ファイル運用

このリポジトリは Linux 上で Claude Code を起動・監視・自律再開するための設定を持ちます。設定の正本は `config/config.json.template`、実機固有の値は `config/config.json` です。

## 基本ルール

- `config/config.json.template`: リポジトリで共有する Linux 基準設定
- `config/config.json`: 各端末で使う実設定。`.gitignore` 対象
- `projects`: Claude 起動候補を探すルート。既定は `/home/kensan/Projects`
- `localExcludes`: 起動候補から除外するプロジェクト名
- 新しい設定キーを追加したら、先に template を更新する

## 初期作成

```bash
cp config/config.json.template config/config.json
cp config/agent-teams-backlog-rules.json.template config/agent-teams-backlog-rules.json
```

## 主要セクション

| セクション | 用途 |
|---|---|
| `projects` / `projectsDir` | `/home/kensan/Projects` 配下の Git リポジトリを起動候補として列挙 |
| `tools.claude` | Claude Code のコマンド、引数、環境変数 |
| `cron` | Linux crontab と `cron-launcher.sh` の動作 |
| `sessionTabs` | tmux / `monitor-sessions.sh` によるセッション情報表示 |
| `statusline` | Linux 上の `~/.claude/settings.json` へ statusLine を適用 |
| `notifications` | Linux の音声通知。既定は無効 |

## Supervisor 全適用

全プロジェクトへ Supervisor を適用する場合は、まず計画を確認します。

```bash
bash bin/autonomy.sh start --all --dry-run
```

問題なければ明示承認付きで開始します。

```bash
bash bin/autonomy.sh start --all --yes
```

`cron` 登録済みのプロジェクトは既定で skip されます。競合を理解した上で許可する場合だけ `--force` を付けます。

```bash
bash bin/autonomy.sh start --all --yes --force
```

運用メニューからは `MO` を開き、`[a]` で全適用、`[n]` で数字付き個別選択ができます。
