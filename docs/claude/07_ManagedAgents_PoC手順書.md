# 🧪 Managed Agents ハイブリッド PoC 手順書（Phase 0: 人間オンボーディング）

> 📅 作成: 2026-06-11
> 🎯 目的: 「ローカル cron 主・Managed Agents 補完」の並走検証を開始するための、
> 人間が一度きりで行うセットアップ手順。日常運用（Phase 1）は CTO 自律で行う。
> 📚 背景・判断経緯: `06_ManagedAgents調査メモ.md`

## 0. 前提

- ✅ 課金は人間判断で承認済み（2026-06-11）
- ✅ プロジェクト方針との整合確認済み（CLAUDE.md「方針」に明確化を追記済み）
- 🧰 必要なもの: platform.claude.com アカウント、PoC 対象プロジェクトの GitHub リポジトリ、
  最新の Claude Code CLI（`/claude-api` スキルが使えること）

## 1. PoC 対象プロジェクトの選定基準

**重要度の低いテスト用プロジェクト 1 つ**から始める。選定基準:

- 🟢 リリース期限まで余裕がある（残 30 日以内の縮退フェーズに入っていない）
- 🟢 main 保護・PR 必須が既に設定済み（誤動作の影響を PR レビューで遮断できる）
- 🟢 Secrets が GitHub token 1 つで足りる（外部 API 依存が少ない）

## 2. Phase 0 手順（👤 人間が実施・一度きり）

### 2-1. 対話的オンボーディング

ローカルの Claude Code セッションで以下を実行し、ウォークスルーに従う:

```text
/claude-api managed-agents-onboard
```

または Developer Console（https://platform.claude.com）からテンプレート選択 /
自然言語記述でエージェントを構成する。

### 2-2. Vault への Secrets 登録（最小権限）

- 🔑 GitHub Fine-grained PAT を **PoC 対象リポジトリ 1 つに限定**して発行
  - 権限: Contents (Read/Write), Pull requests (Read/Write), Issues (Read/Write)
  - ❌ 付与しない: Administration, Actions secrets, 他リポジトリへのアクセス
- 発行した PAT を Console の Vault に登録（ローカル `~/.env-claudeos` には置かない）
- 有効期限は PoC 期間に合わせ **30〜60 日**で設定（自動失効を安全弁にする)

### 2-3. Permission Policy の設定（CTO 境界の移植）

本リポジトリの CTO 自律開発境界（CLAUDE.md）をそのままポリシー化する:

| 許可 ✅ | 禁止 ❌ |
|---|---|
| 調査・設計・実装・テスト・レビュー | PR merge |
| ドキュメント更新 | main 直 push |
| Issue/PR の作成（Draft 含む） | 本番公開・デプロイ |
| | 破壊的削除・不可逆なデータ変更 |
| | Secrets の変更・追加 |

### 2-4. トリガー設定（補完運用の要）

ローカル cron の**死角だけ**を埋めるスケジュールにする（二重実行の防止）:

- 🕐 ローカル cron の稼働時間帯（月〜土・プロジェクト別スケジュール）**以外**に設定
- もしくは「ローカルセッションの欠落検知時のみ」の Webhook/API トリガーにする
- 1 セッション相当の作業上限を設け、5h ルールと同等の終了処理（commit/push/Draft PR）を
  エージェント指示に含める

### 2-5. サンドボックス選択

- まずはデフォルトの Anthropic ホストで開始（セットアップ最小）
- 機密度の高いプロジェクトへ拡大する場合のみセルフホストサンドボックス（自 VPC 内実行）を検討

## 3. Phase 1（🤖 CTO 自律・並走運用）

Phase 0 完了後、CTO が以下を日常運用する:

- 📊 監視: `bin/monitor-sessions.sh` の「⏳ 入力待ちエージェント」表示
  （`claude agents --json` の waitingFor）で managed 側のブロック状態も確認
- 📝 記録: 各セッションで managed 側が補填した実績（回数・成果 PR・トークン消費）を
  PoC 対象プロジェクトの `state.json` / Issue に記録
- 🚨 異常時: managed 側の誤動作・境界逸脱を検知したら即トリガー停止し Issue 化
  （トリガー停止は設定変更ではなく一時停止のため CTO 判断で可）

## 4. Phase 2（👤 + 🤖 判断・2〜4 週間後）

以下の実績データで本採用 / 縮小を判断する:

- 🔢 ローカルセッション欠落の補填回数（= ハイブリッドの実益）
- 💸 managed 側のコスト実績
- ⚠️ 境界逸脱・誤動作の件数（0 が本採用の条件）
- 🔁 ローカル↔managed の状態引き継ぎ（state.json / Memory）の整合性

## 5. ロールバック

PoC を中止する場合（人間判断・いつでも可）:

1. Console でトリガー停止 → エージェント削除
2. Vault の PAT を失効（GitHub 側でも revoke）
3. `06_ManagedAgents調査メモ.md` に中止理由と再評価条件を追記
