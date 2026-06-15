# Claude-StartUpTools-New-Linux

このリポジトリは Linux ローカル専用の Claude Code 起動・Supervisor 運用ツールです。

## 方針

- 日本語で対応する。
- SSH 接続、リモート配布、Windows/PowerShell 起動経路を追加しない。
  - この禁止は「本ツールへの多経路起動コードの持ち込み防止」が意図。Anthropic Managed Agents
    の利用（Console + CLI スキル経由で管理、本リポジトリにコード追加なし）は禁止対象外。
    位置づけは「ローカル cron 主・Managed Agents 補完」(`docs/claude/06_ManagedAgents調査メモ.md`)。
- `/home/kensan/Projects` 配下の Git リポジトリを登録プロジェクト候補として扱う。
  - 新規フォルダ作成にも対応: メニュー実起動時 (`bin/menu.sh` の `menu` 経路) に
    `project_autoinit_scan` が `.git` 未保有フォルダを検知し、自動で `git init` +
    `CLAUDE.md` テンプレ配置 + 初期 commit を行う。`.git` が付くことで
    `config_project_list`（L1 メニュー / cron / autonomy / docker の全 4 経路）へ
    自然に登録される。冪等・非破壊・ローカル限定（GitHub repo 作成等の外部操作はしない）。
    無効化は config の `.autoInitProjects=false`。`--render`（テスト用描画）経路では実行しない。
- 運用メニューは灰色表示を使わず、青、緑、黄、マゼンタ、赤、白を中心にする。
- 変更後は `npm test` と `npm run lint` を通す。

## CTO 自律開発境界

CTO Claude に任せる範囲:

- 調査、設計、実装、テスト、レビュー
- ドキュメント更新
- Issue/PR の下書き
- Supervisor 対象の dry-run と安全な状態確認
- ✅ **PR の自動 merge（下記「自動 merge 条件」を全て満たす場合のみ）**

人間が最終決断する範囲:

- main 直push、本番公開
- Secrets、課金、外部サービス設定
  - 一度きりのセットアップ決裁（例: Managed Agents の Console オンボーディング、
    Vault への token 登録、Permission Policy 設定）。決裁後の日常運用は CTO 自律可
- 破壊的削除、不可逆なデータ変更
- Supervisor 全プロジェクト適用の実行

## 自動 merge 条件（全プロジェクト共通・絶対遵守）

CTO は **次を全て満たす PR に限り** `gh pr merge <PR> --auto --squash` で自動 merge してよい。
`--auto` は「CI 通過後に自動 merge」を設定するもので即時 merge ではない。

- ✅ STABLE 判定成立（test / lint / build / CI すべて success、error 0、security critical 0）
- ✅ Trust Level 2 以上（trust.score ≥ 0.85）
- ✅ Codex review・CodeRabbit の Critical / High 指摘が 0
- ✅ PR 種別が通常の機能追加・バグ修正・ドキュメント更新

### 自動 merge 禁止条件（Level 2 でも人間最終決断のまま）

- 🚫 認証・認可の変更
- 🚫 DB スキーマ変更
- 🚫 本番デプロイ・本番公開
- 🚫 Security Critical 指摘が残る PR
- 🚫 main 直 push（PR を経由しない変更）

Trust Level が降格した場合（Security Critical 検知等）は即座に `gh pr merge <PR> --disable-auto` で取り消す。
詳細手順は `Claude/templates/claudeos/docs/auto-merge-protocol.md` を正本とする。

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
