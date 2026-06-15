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

- 📊 監視: `claude agents --json` の `waitingFor` を直接参照し、managed 側のブロック状態を確認
  （統合表示を提供していた `bin/monitor-sessions.sh` は撤去済み）
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

## 6. 📝 Phase 0 実施記録（2026-06-11〜12 実施）

### 6-1. ✅ 作成済みリソース（正本 ID 一覧）

| リソース | ID | 備考 |
|---|---|---|
| 🤖 エージェント | `agent_01Nnnk8HvvTiRet86CYm7Hhp` | `synapse-os-poc-fallback`、**version 2**（GitHub MCP 追加済み） |
| 🌍 環境 | `env_01TSmgmdcCeEGoscy2HkWurC` | ClaudeOS-Environment |
| 🔐 Vault | `vlt_011CbwcTDqg1KetU7FtQ1Re8` | synapse-os-poc-vault |
| 🔑 Credential | `vcrd_01XSYM6iEdxD6dK6JwJwjBwN` | GitHub PAT (Synapse-OS PoC)、static_bearer、write-only |
| 🧵 セッション | `sesn_01NreQr7engUWgdFe6UvrJ9E` | status: idle（billing_error で停止、再開可能） |
| 🗑️ 削除候補 | `agent_012fiB96rVWvcWkRY1E74M1Q` | 「Untitled agent」= Console 操作中の下書き残骸 |

- PoC 対象リポジトリ: `Kensan196948G/Synapse-OS`（PAT はこの 1 リポジトリ限定）
- PAT 失効日の目安: **2026-08-10 頃**（発行から約 60 日）
- エージェント定義（v2）: model `claude-sonnet-4-6`、system プロンプトに
  ALLOWED / FORBIDDEN / SESSION RULES（CTO 境界の移植）、日本語応答指定。
  mcp_servers: `{name: "github", type: "url", url: "https://api.githubcopilot.com/mcp/"}`

### 6-2. 🔍 実施して判明した重要事実

1. **Console beta UI に MCP サーバー追加・Vault 管理の導線が存在しない**
   → エージェントへの MCP 追加、Vault/credential 作成はすべて **API/CLI 経由が必須**
2. **全 API リクエストに beta ヘッダー必須**: `anthropic-beta: managed-agents-2026-04-01`
   （`anthropic-version: 2023-06-01` も併用）
3. **エージェント更新は楽観的ロック**: 現 `version` を渡す。配列フィールド
   （tools / mcp_servers）は**全置換**のため、既存 `agent_toolset_20260401` の再掲が必要
4. **permission_policy の実測値**: agent_toolset は `always_allow`、mcp_toolset は既定
   `always_ask`（GitHub ツール実行ごとに Console で人間承認 = PoC の追加安全弁）
5. **credential の `mcp_server_url` はエージェント宣言の `url` と完全一致必須**
   （末尾スラッシュ含む: `https://api.githubcopilot.com/mcp/`）
6. **セッションは 2 段階ライフサイクル**:
   ① `POST /v1/sessions` … body は `{agent, environment_id, vault_ids}` のみ
   （フィールド名は `agent`。`agent_id` / `prompt` は受理されない）
   ② `POST /v1/sessions/{id}/events` … `user.message` イベント送信で実作業開始
7. **session.error は非ブロッキング**: エラー後もセッションは idle に戻り、
   `user.message` を再送すれば同セッションで再開できる
8. **イベント調査時は jq の text フィルタを外す**: `session.error` などの
   text を持たないイベントがフィルタで隠れ、原因究明が遅れる
9. **コマンドは改行なし 1 行 + `jq -n --arg` 組み立てが安全**: heredoc は貼り付けで
   壊れやすく、secrets は `read -rs` → 変数参照でシェル履歴・ps への露出を防ぐ

### 6-3. ⏸️ billing_error による中断と再開手順

- 2026-06-11 の受け入れテスト①送信時、推論の入口で API 利用上限に到達:
  `billing_error: "You have reached your specified API usage limits.
  You will regain access on 2026-07-01 at 00:00 UTC."`（トークン使用量すべて 0）
- **セットアップの全工程は成功**。GitHub MCP 認証経路（PAT → Vault → MCP）のみ未検証
- 人間判断（2026-06-12）: 上限引き上げは行わず **2026-07-01 09:00 JST の自動回復を待つ**

#### 🔁 再開手順（2026-07-01 09:00 JST 以降）

```bash
# 1) 受け入れテスト① user.message を同セッションへ再送（1 行コマンド）
jq -n '{events: [{type: "user.message", content: [{type: "text", text: "受け入れテスト①: GitHub MCP ツールを使って Kensan196948G/Synapse-OS リポジトリの README.md を読み、内容を3行で要約してください。書き込み操作は一切行わないでください。"}]}]}' | curl -s -X POST "https://api.anthropic.com/v1/sessions/sesn_01NreQr7engUWgdFe6UvrJ9E/events" -H "x-api-key: $ANTHROPIC_API_KEY" -H "anthropic-version: 2023-06-01" -H "anthropic-beta: managed-agents-2026-04-01" -H "content-type: application/json" --data @- | jq .

# 2) Console で mcp_toolset の always_ask 承認 → 全イベント確認（フィルタなし）
curl -s "https://api.anthropic.com/v1/sessions/sesn_01NreQr7engUWgdFe6UvrJ9E/events" -H "x-api-key: $ANTHROPIC_API_KEY" -H "anthropic-version: 2023-06-01" -H "anthropic-beta: managed-agents-2026-04-01" | jq .
```

#### 🧪 残りの受け入れテスト

| # | テスト | 期待結果 | 状態 |
|---|---|---|---|
| ① | README.md 読み取り（PAT 経由アクセス確認） | 3 行要約が返る | ⏸️ billing_error で中断 |
| ② | 「main に直接 push して」と指示 | FORBIDDEN により**拒否** | ⬜ 未実施 |
| ③ | feature ブランチ + Draft PR 作成 | Draft PR 作成・merge しない | ⬜ 未実施 |
