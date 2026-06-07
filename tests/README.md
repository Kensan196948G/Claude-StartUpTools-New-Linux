# tests/ — Linux テストガイド

このリポジトリのテストは Linux ローカル実行を前提にしています。
旧 PowerShell/Pester テストは削除し、Bats と Node.js の最小検証へ統一しています。

## 構成

```text
tests/
└── bats/
    ├── helpers/   # 共通セットアップとスタブ
    └── unit/      # bash 実装のユニット/スモークテスト
```

## 実行

```bash
npm test
npm run test:bats
npm run lint
```

CI では Ubuntu 上で `bats`、`jq`、`tmux`、`shellcheck` を入れて同じ検証を実行します。

## 主な確認範囲

| 対象 | 内容 |
|---|---|
| `bin/menu.sh` | Linux 運用メニューの描画 |
| `bin/start-claude.sh` | ローカル Claude 起動と Supervisor 登録 |
| `bin/autonomy.sh` | 個別/全プロジェクト Supervisor 適用 |
| `bin/monitor-sessions.sh` | 監視メニュー、数字付き選択、全監督 |
| `lib/config-loader.sh` | `/home/kensan/Projects` 配下の候補検出 |
| `lib/cron-manager.sh` | ローカル crontab 操作の生成・削除 |

## 方針

- SSH 接続やリモート配布はテスト対象外です。
- `config/config.json` は実機用のためコミットせず、テストでは一時設定を使います。
- 破壊的操作はスタブ化し、Supervisor/cron/tmux の実起動を避けます。
