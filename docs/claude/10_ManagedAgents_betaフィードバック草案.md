# Managed Agents (beta) — GitHub MCP 実行 crash の beta フィードバック草案

提出先: Anthropic Managed Agents (beta) フィードバック窓口（Console / support）
作成: 2026-06-16 / 起票判断: 👤 人間（外部サービスへの送信は人間最終決断）
ステータス: 📨 提出済み（2026-06-16 / support.claude.com 技術的な問題・エラー経由 / Support 会話ID 215474722418070）
提出経路: support.claude.com → Send us a message → 技術的な問題/エラー → Product Support（人間）へエスカレーション依頼済み。英語レポート（本ファイル「English report」節）を会話へ貼付。正式 case 番号はメール返信で受領予定。

このファイルは PoC 手順書 `07_ManagedAgents_PoC手順書.md` §6-3 の診断結果を、Anthropic へ
そのまま送れる形に整えた提出ドラフトです。**秘匿値（PAT・API key・Vault token）は一切含めず**、
Anthropic が内部ログを照合するための識別子（session / agent / credential ID）のみ記載します。

---

## 🇯🇵 日本語サマリ（社内記録用）

- 事象: Managed Agents 経由で GitHub リモート MCP の `get_file_contents` を実行すると、
  承認(allow)後に `agent.mcp_tool_result` が `is_error=true`,
  `text="Tool execution was interrupted by a crash. Please retry."` を**status code 無しで毎回**返す。
- 切り分け: 同一 PAT・同一エンドポイント・同一ツール・同一 repo を**Agent ランタイム非経由で直接**
  `https://api.githubcopilot.com/mcp` へ JSON-RPC で叩くと、`initialize`=200 /
  `notifications/initialized`=202 / `tools/call get_file_contents`=200（README 本文取得成功）と**全グリーン**。
- 結論: GitHub 側（PAT・スコープ・repo・エンドポイント）はすべて健全。crash は
  **Anthropic Managed Agents (beta) の MCP 実行サンドボックス内部**に起因。資格情報ローテーションでは解決不能。
- 依頼: 当該 session/agent の内部ログ照合と、サンドボックス側 crash の原因調査・修正。

---

## 🇬🇧 English report (paste this to Anthropic)

### Summary

When a Managed Agent (beta) invokes the GitHub remote MCP tool `get_file_contents`, the tool
execution crashes **every time** after the user `allow` confirmation. The agent receives an
`agent.mcp_tool_result` event with `is_error=true` and
`text="Tool execution was interrupted by a crash. Please retry."` — **with no HTTP status code**.

The same PAT, MCP endpoint, tool, and repository work **100%** when called **directly** (bypassing
the Managed Agents runtime), which isolates the fault to the Managed Agents MCP execution sandbox.

### Environment

- API: `api.anthropic.com`, headers `anthropic-version: 2023-06-01`,
  `anthropic-beta: managed-agents-2026-04-01`
- MCP server (vault credential): GitHub remote MCP `https://api.githubcopilot.com/mcp`
  (auth type `static_bearer`, Fine-grained PAT, scopes: Contents R/W + Pull requests W, single repo)
- Target repository: `Kensan196948G/Synapse-OS`, file `README.md`
- environment networking: `unrestricted`
- Identifiers for your log lookup (NOT secrets):
  - Agent: `agent_01Nnnk8HvvTiRet86CYm7Hhp` (`synapse-os-poc-fallback`, version 3)
  - Session (post-rotation, fresh): `sesn_015qp3yco2J3wsX2BEXJtQSd`
  - Earlier session that first showed the crash: `sesn_01HVfnamF4b8kAsNZxmUU8Y5`
  - Vault credential: `vcrd_01XSYM6iEdxD6dK6JwJwjBwN`
  - The crashing `get_file_contents` tool_use events are inside the sessions above; we
    `deny`-ed the auto-retry event `sevt_01L75izFdq8i9ZGtGw64SsWG` to stop billing churn.

### Reproduction

1. Create a session pinned to the agent + vault credential above.
2. Send `user.message`: ask the agent to read `README.md` of `Kensan196948G/Synapse-OS` and summarize.
3. Agent emits `agent.mcp_tool_use` (get_file_contents) awaiting confirmation.
4. Send `user.tool_confirmation` `{tool_use_id: <event id>, result: "allow"}`.
5. **Observed:** `agent.mcp_tool_result` `is_error=true`,
   `text="Tool execution was interrupted by a crash. Please retry."` (no status code).
   All `model_request` spans are `is_error=false` (model side healthy; only MCP execution crashes).

### Differential diagnosis (proves the GitHub side is healthy)

Using the **same** Fine-grained PAT, called **directly** against `https://api.githubcopilot.com/mcp`
(no Managed Agents runtime, no billing):

| Step | Request | Result |
|---|---|---|
| 1 | `initialize` | **HTTP 200** (serverInfo: github-mcp-server, protocol 2025-06-18) |
| 2 | `notifications/initialized` | **HTTP 202** |
| 3 | `tools/call get_file_contents` (Synapse-OS README.md) | **HTTP 200**, "successfully downloaded text file" + README body |

Also verified against `api.github.com` REST: `/user`, `/repos/{repo}`, `/repos/{repo}/contents/README.md`
all **HTTP 200**. Credential resolves with `error=null` on the Anthropic side.

So all four auth layers are green (REST 200 / MCP initialize 200 / MCP tools/call 200 /
credential error=null). A previous PAT had genuinely expired (401) — that was a separate, already-fixed
issue. After rotating to a valid PAT (vault credential updated in-place via
`POST /credentials/{id}`, `auth.mcp_server_url` omitted as immutable, HTTP 200) and creating a
**new** session, the crash still reproduces — disproving any "session cached the old token" hypothesis.

### Expected vs actual

- **Expected:** `get_file_contents` returns the file contents to the agent (it does so via direct MCP).
- **Actual:** generic crash with no status code, only via the Managed Agents execution path.

### Ask

Please investigate the Managed Agents MCP execution sandbox crash for the session/agent above, and
advise whether this is a known beta limitation or a defect with an ETA. We have ruled out the
credential, scopes, repository, endpoint, and network on our side.

---

## 🔁 提出後の運用（社内）

- ✅ 2026-06-16 提出済み。Support 会話ID `215474722418070`。正式 case 番号はメール返信で受領後に追記する。
- ⏳ 次アクション: Anthropic Product Support からのメール返信（case 番号 / 調査結果 / ETA）を待つ。返信到着が受け入れテスト②③再開のトリガー。
- 受け入れテスト②③は Agent 経由 GitHub MCP に依存するため、**修正回答が来るまで PoC は保留**。
- `docs/GH-Claude.txt`（秘匿キーファイル）は②③エンドツーエンド成功まで保持（人間判断・2026-06-16）。
- 次セッションでは PAT/Vault の再検証は不要（直接 MCP で完全実証済み）。前進路はプラットフォーム側修正のみ。
