# Source of Truth Map — Claude StartUpTools New Linux

このリポジトリは Linux ローカル専用の Claude 起動・Supervisor 運用ツールです。
編集対象に迷った場合は、この分類を優先します。

## 分類

| 分類 | 意味 | 編集可否 |
|---|---|---|
| Source | 人間とCTO Claudeが編集する正本 | 編集可 |
| Deployed | Source から同期・展開される実行先コピー | 直接編集しない |
| Generated | 実行時に生成されるログ/状態/レポート | 直接編集しない |

## 正本

| パス | 分類 | 備考 |
|---|---|---|
| `README.md` | Source | Linux版の入口説明 |
| `bin/` | Source | 起動、監視、Supervisor、cron、運用メニュー |
| `lib/` | Source | 共通関数、設定、JSON、tmux、Supervisor補助 |
| `libexec/` | Source | 診断・補助実行スクリプト |
| `Claude/templates/claude/` | Source | 各プロジェクトへ適用する Claude 指示テンプレート |
| `Claude/templates/claudeos/` | Source | ClaudeOS カーネルテンプレート |
| `Claude/templates/linux/` | Source | Linux cron/systemd 用テンプレート |
| `config/config.json.template` | Source | 実機設定テンプレート |
| `config/README.md` | Source | 設定運用ガイド |
| `tests/bats/` | Source | bash 実装の検証 |
| `.github/workflows/ci.yml` | Source | Ubuntu CI |

## 配備先・生成物

| パス | 分類 | 備考 |
|---|---|---|
| `.claude/claudeos/` | Deployed | `Claude/templates/claudeos/` から同期 |
| `config/config.json` | Deployed | 実機ローカル設定。コミットしない |
| `~/.claudeos/` | Deployed/Generated | Supervisor 状態、cron launcher、ログ |
| `logs/` | Generated | 実行ログ |
| `reports/` | Generated | レポート出力 |
| `.worktrees/` | Generated | 一時 worktree |

## 編集フロー

```text
bin/lib/libexec を変更
  -> bats テストを更新
  -> npm test
  -> npm run lint

Claude テンプレートを変更
  -> Claude/templates/claude または Claude/templates/claudeos を編集
  -> 適用先との差分を確認

設定を変更
  -> config/config.json.template を編集
  -> 実機では config/config.json へコピーして調整
```

## 運用境界

- SSH 接続、リモート配布、Windows Terminal、PowerShell/Pester は本Linux版の対象外です。
- Supervisor の全プロジェクト適用は、実行直前に人間の最終選択を必要とします。
- CTO Claude は実装、検証、レビュー、PR準備まで自律実行できますが、公開、削除、課金、Secrets、merge などの最終判断は人間が行います。
