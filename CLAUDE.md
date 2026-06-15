# Claude-StartUpTools-New-Linux

このリポジトリは Linux ローカル専用の Claude Code 起動・Supervisor 運用ツールです。

## 方針

- 日本語で対応する。
- SSH 接続、リモート配布、Windows/PowerShell 起動経路を追加しない。
  - この禁止は「本ツールへの多経路起動コードの持ち込み防止」が意図。Anthropic Managed Agents
    の利用（Console + CLI スキル経由で管理、本リポジトリにコード追加なし）は禁止対象外。
    位置づけは「ローカル cron 主・Managed Agents 補完」(`docs/claude/06_ManagedAgents調査メモ.md`)。
- `/home/kensan/Projects` 配下の Git リポジトリを登録プロジェクト候補として扱う。
- 運用メニューは灰色表示を使わず、青、緑、黄、マゼンタ、赤、白を中心にする。
- 変更後は `npm test` と `npm run lint` を通す。

## CTO 自律開発境界

CTO Claude に任せる範囲:

- 調査、設計、実装、テスト、レビュー
- ドキュメント更新
- Issue/PR の下書き
- Supervisor 対象の dry-run と安全な状態確認

人間が最終決断する範囲:

- PR merge、main 直push、本番公開
- Secrets、課金、外部サービス設定
  - 一度きりのセットアップ決裁（例: Managed Agents の Console オンボーディング、
    Vault への token 登録、Permission Policy 設定）。決裁後の日常運用は CTO 自律可
- 破壊的削除、不可逆なデータ変更
- Supervisor 全プロジェクト適用の実行

## 主要コマンド

```bash
./start.sh
bash bin/start-claude.sh
bash libexec/watch-session.sh
bash bin/autonomy.sh start --all --dry-run
npm test
npm run lint
```

## 正本

- 起動/運用: `bin/`, `lib/`, `libexec/`
- Claude テンプレート: `Claude/templates/claude/`, `Claude/templates/claudeos/`
- Linux 実行テンプレート: `Claude/templates/linux/`
- 設定: `config/config.json.template`, `config/README.md`
- テスト: `tests/bats/`
