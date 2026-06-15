# 🔍 Claude Managed Agents 調査メモ（再評価版: ハイブリッド PoC 準備）

> 📅 初回調査: 2026-06-11 / 再評価: 2026-06-11
> 📚 出典: https://claude.com/blog/building-with-claude-managed-agents
> ✅ 再評価結論: **「ローカル cron 主・Managed Agents 補完」のハイブリッド PoC を準備する**。
> Console オンボーディング・Vault 登録・Permission Policy 設定は人間が一度きりで実施し、
> 以降の日常運用は CTO 自律に乗せる。手順は `07_ManagedAgents_PoC手順書.md` を参照。

## 1. Managed Agents とは

Anthropic がホストするマネージド実行環境上で Claude エージェントを常駐・運用する仕組み。

- 🖥️ 実行環境: デフォルトは Anthropic ホストのクラウドコンテナ（推論と実行を分離した
  「脳と手の分離」アーキテクチャ）。**セルフホストサンドボックス**を選べばコード実行を
  自ネットワーク内に留められる
- 🔐 Vault: 認証情報は暗号化封筒方式で実行サンドボックスから隔離。署名付きリクエスト
  トークンで取得を検証（プロンプトインジェクションによる token 漏洩をアーキテクチャで防止）
- 📡 MCP トンネル: プライベートネットワーク内の MCP サーバーへの到達を制御可能
- 🛂 Permission Policy: エージェントの権限を宣言的に制御
- 🧭 セットアップ: Developer Console（platform.claude.com）+ `/claude-api managed-agents-onboard`

## 2. 本プロジェクト（Linux ローカル Supervisor）との対応関係

| 機能 | Managed Agents | 本プロジェクトの現行実装 |
|---|---|---|
| 常駐実行 | Anthropic ホスト | tmux + cron (`cron-launcher.sh`) |
| スケジュール起動 | マネージドトリガー | Linux cron（月〜土・プロジェクト別） |
| セッション制限 | プラットフォーム管理 | `timeout ${dur_sec}s`（5h 厳守） |
| 状態永続化 | マネージド | `state.json` + Memory + Stop hook |
| 監視 | ダッシュボード提供 | `libexec/watch-session.sh` + `claude agents --json`（waitingFor 直接参照） |
| 通知 | プラットフォーム通知 | `notify-stable.js` + report-and-mail.py |
| Secrets | Vault（暗号化封筒・隔離） | `~/.env-claudeos`（平文ファイル） |

## 3. 還元済みの設計パターン（ローカル実装へ反映完了）

1. ⚠️ **waitingFor の可視化** — `claude agents --json` の `waitingFor` を
   `bin/monitor-sessions.sh` の `mon__agents_waiting()` へ統合していたが、同ファイル撤去に伴い消失。
   現在は `claude agents --json` を直接参照する（2026-06-15 撤去）
2. ✅ **Stop 時のコンテキスト引き継ぎ** — `hookSpecificOutput.additionalContext`（2.1.163+）を
   `session-end.js` に実装
3. ✅ **フォールバックモデル** — `fallbackModel` 配列（2.1.166+）を
   `Claude/templates/claude/settings.json` に適用
4. ✅ **ヘルスチェック起動** — `--safe-mode`（2.1.169+）を `bin/start-claude.sh --safe-mode` として実装

## 4. 再評価（2026-06-11）: 当初の見送り理由の見直し

| 当初の見送り理由 | 再評価 |
|---|---|
| 💰 課金 | **除外**（人間判断により問題なしと確定） |
| 🔐 Secrets・外部サービス設定 = 人間決裁 | **継続ブロッカーではない**。Console デプロイ・Vault 登録・Permission Policy は「一度きりのセットアップ決裁」であり、cron 登録を最初に人間が行う現行運用と同型。以降の日常運用は CTO 自律可能。Vault はローカル平文 `~/.env-claudeos` より安全側 |
| 🏠 ローカル専用方針との不整合 | **方針の意図と衝突しない**。禁止事項「SSH 接続・リモート配布・Windows 起動経路を追加しない」の意図は本ツールへの多経路起動コードの持ち込み防止。Managed Agents は本リポジトリにコードを追加せず（Console + CLI スキル経由で管理）、セルフホストサンドボックスで実行場所も制御可能 |

### ローカル専用のままで実害になり得る点（PoC の動機）

- 🖥️ **単一障害点**: 6 ヶ月リリース期限つきプロジェクトが 1 台の Linux マシンの稼働に依存。
  マシン障害・停電・スリープでセッションが欠落しても自動補填されない
- ⏱️ **cron 時間帯の固定**: マシンが起きている時間しか走れない
- 🔔 **異常終了時の終了処理欠落**: tmux ごと落ちると 5h 終了処理（commit/push/PR）が飛ぶ

## 5. ハイブリッド PoC 計画（ローカル cron 主・Managed Agents 補完）

| Phase | 実施者 | 内容 |
|---|---|---|
| Phase 0 | 👤 人間（一度きり） | テスト用プロジェクト 1 つで Console オンボーディング、Vault に最小権限 token 登録、Permission Policy に CTO 境界（PR merge / main 直 push / 破壊的削除の禁止）を設定。手順: `07_ManagedAgents_PoC手順書.md` |
| Phase 1 | 🤖 CTO 自律 | ローカル cron はそのまま主系。マシン停止帯・セッション欠落時のフォールバックとして managed 側を並走。監視は `claude agents --json` の `waitingFor` を直接参照 |
| Phase 2 | 👤 + 🤖 | 2〜4 週間の並走実績（欠落補填回数・コスト・誤動作）で本採用 / 縮小を判断 |

## 6. 関連実装（本リポジトリ内の対応物）

- `claude agents --json` の `waitingFor` — managed エージェントのブロック状態を直接参照
  （統合表示を提供していた `bin/monitor-sessions.sh` / `mon__agents_waiting()` は 2026-06-15 撤去）
- `Claude/templates/claudeos/scripts/hooks/session-end.js` — additionalContext 出力
- `Claude/templates/claude/settings.json` — `fallbackModel` / `requiredMinimumVersion`
- `bin/start-claude.sh` / `lib/tmux-runner.sh` — `--safe-mode` 診断起動
- `docs/claude/07_ManagedAgents_PoC手順書.md` — Phase 0 オンボーディング手順
