# 🧭 Managed Agents 統合運用手順（read-only PoC）

> 📅 2026-10-10
> 設計: `docs/architecture/MANAGED_AGENTS_INTEGRATION.md`
> 過去の PoC 記録: `docs/claude/07_ManagedAgents_PoC手順書.md`（2026-06〜08 時点の記録。現行仕様との差分は本書 §2）

Local Claude Code が主系で、Managed Agents は低リスク・読取専用タスクの補完先です。配布時は `enabled=false` / `mode=disabled` で、設定しない限り既存の動作は変わりません。

## 1. 現在の状態

| 項目 | 状態 |
|---|---|
| adapter・Budget Guard・台帳・Router 統合 | 実装済み。モックによる自動テストで検証 |
| dry-run（request の生成と判定） | 利用可能。ネットワークへ出ない |
| live（実 API 呼び出し） | **BLOCKED** — Console の残高・利用権限の確認と、課金の人間承認が前提（§4） |
| 過去の GitHub MCP 実行クラッシュ | 修正状況は**未確認**。PoC は MCP を使わない構成で回避（§3） |

## 2. 既存 PoC と現行 API 仕様の差分

公式ドキュメント（platform.claude.com/docs/en/managed-agents/*、2026-10-10 参照）と突き合わせた結果です。実 API での確認は行っていません。

| 項目 | 過去の PoC・P0 実装の前提 | 現行仕様 | 対応 |
|---|---|---|---|
| `inference_geo` | セッション作成 body の最上位に指定（07 §7-2、P0 payload builder） | agent の `model` オブジェクト内（`{id, inference_geo}`）にのみ指定できる。セッションの最上位には置けない | payload builder から最上位の `inference_geo` を除去。必要なら roster の `model` に書く |
| advisor | roster に `{type: "advisor_20260301", name, model}` を追加（07 §7-4） | `multiagent` ブロック内で指定する形に変わっている（形式は資料により表記差があり要再確認） | PoC では advisor を使わない |
| セッション予算 | `budget.max_list_cost.amount` はセント整数の文字列 | 同じ。加えて「先頭ゼロなし・0 より大きい」が明記。作成時のみ付与でき、後から変更・削除はできるが追加はできない | `"0"` や `"0500"` を拒否するよう検証を強化 |
| 予算到達の通知 | `session.status_idle` の `stop_reason.type` が `budget_reached` | 同じ。直前に `session.usage` イベントが出る。到達後は `user.message` が 400 になる | 完了判定で `budget_reached` を区別し、再開・引き上げは行わない |
| セッション開始 | 作成後に `user.message` を別送 | `initial_events` で作成と同時に開始できる（作成直後から `running`） | `initial_events` を使い 1 回の POST にまとめる |
| agent の指定 | ID 文字列（最新版） | ID 文字列、`{type: "agent", id, version}`（固定）、`agent_with_overrides` の 3 形式 | version を固定して参照 |
| GitHub リポジトリ | Repository Resource を主系にする方針（P0 監査） | `resources` の `github_repository`（`url` / `authorization_token` / `mount_path` / `checkout`）。トークンは git proxy が注入し sandbox から読めない | この形式で read-only マウント |
| permission policy | `always_allow` / `always_ask` | `auto`（サーバー側評価）が追加 | PoC は読取専用ツールのみのため `always_allow` |
| networking | `unrestricted`（07 §6-1 の環境） | `limited` は deny-by-default。**省略時の既定は `unrestricted`** | `limited` を必ず明示し、MCP・パッケージマネージャも不許可 |
| Console の UI 導線 | MCP 追加・Vault 管理は API 必須（07 §6-2） | 未確認（現行 Console を確認していない） | adapter は API 経由のみを前提 |
| 409 の `error.type` | — | 資料により `invalid_request_error` と `conflict_error` の表記差あり | HTTP ステータスで判定 |
| クレジット不足時の HTTP コード | 推論の入口で `billing_error`（07 §6-3） | 402 `billing_error` が定義されているが、Managed Agents での実際のコードは未確認 | 402・`billing_error`・メッセージ文言の 3 通りで分類 |
| クレジット残高の取得 | — | 残高を返す API は確認できない。Usage / Cost Admin API は Admin キーが必要 | 残高確認は人間が Console で行い、`budget reconcile` で照合 |

## 3. 過去の GitHub MCP 実行クラッシュ

### 記録されている不具合（2026-06-16、2026-07-11）

- Managed Agents のセッション内で GitHub リモート MCP（`https://api.githubcopilot.com/mcp`）のツールを承認して実行すると、`agent.mcp_tool_result` が `is_error=true`、本文 `Tool execution was interrupted by a crash. Please retry.` で返る。HTTP ステータスを伴わない。
- `get_file_contents` と `search_repositories` の両方で再現し、ツールに依存しない。
- 同じ PAT で MCP エンドポイントを直接呼ぶと `initialize` / `tools/call` とも成功するため、認証・GitHub 側・ネットワークの問題ではなく、Managed Agents の MCP 実行経路の問題と分類した。
- 詳細: `docs/claude/07` §6-3、フィードバック草案: `docs/claude/10`。

### 現在の状態

| 観点 | 判定 |
|---|---|
| 修正済みか | **未確認**。公式リリースノート（2026-04-08〜2026-10-09）に、この不具合や修正への言及は見つからなかった |
| 仕様上の関連変更 | MCP の接続・認証失敗は `session.error`（`mcp_connection_failed_error` / `mcp_authentication_failed_error`）として通知されると文書化されている。過去の事象がこれに当たるかは不明 |
| フィードバックの回答 | 未受領（2026-07 時点の記録のまま） |

2026-07 の調査結果は当時の状態であり、現在も再現するとは限りません。再現するかどうかは実行しないと分かりません。

### 安全な代替経路（PoC で採用）

読取専用の PoC は MCP を必要としません。リポジトリは `github_repository` リソースとして sandbox に clone され、Agent は `read` / `glob` / `grep` で読みます。Agent 定義に `mcp_servers` を宣言しないため、クラッシュした経路を通りません。

GitHub への書込み（PR 作成など）は MCP が必要になるため、PoC の対象外です。必要になった時点で下記の再検証を行います。

### 再検証の手順（実施する場合）

前提: §4 の条件を満たしていること。**同じ結果が出たら同じ手順を繰り返さない**（1 回で打ち切る）。

1. 専用の検証用 Agent を別途定義する（read-only PoC の roster には混ぜない）。`mcp_servers` に GitHub MCP、`mcp_toolset` は `always_ask` のまま。
2. Environment は `limited` + `allow_mcp_servers: true`。
3. 新しいセッションを予算 **$0.50**（`--class check` 相当）で作成する。過去のセッションや Agent version は再利用しない。
4. `get_file_contents` で README を 1 回読ませ、`agent.mcp_tool_use` を API で 1 回だけ承認する。
5. `agent.mcp_tool_result` と `session.error` の内容、`request_id`、使用額を記録する。
6. 成功しても失敗してもセッションを中断して終了し、結果を本書と `docs/claude/07` に追記する。

費用上限: 1 回 $0.50、再検証全体で $1.00。超える場合は中止します。

## 4. live 実行の前提（現在は BLOCKED）

実クレジットを使う操作は、次をすべて人間が確認した後に限ります。

1. Anthropic Console で、API クレジットの残高・有効期限・請求サイクルを確認する。
2. 使用する API キーが有効で、Managed Agents（beta）を利用できる workspace のものであることを確認する。
3. `config/managed-agents.json` の `budgetPolicy.cycle` に、請求サイクル開始日（`anchorDay`）・失効日時（`creditsExpireAt`）・確認日時（`consoleVerifiedAt`）を記入する。
4. 読取専用の fine-grained PAT（対象リポジトリのみ、Contents: Read）を発行し、`CLAUDEOS_MA_GITHUB_TOKEN` で渡す。
5. `mode` を `live` に変更する（この変更が課金の承認にあたる）。

追加購入・自動チャージ・課金上限の引き上げは、この手順に含まれません。

## 5. セットアップと日常操作

```bash
# 1) 設定を作る（git 管理外）
cp config/managed-agents.json.template config/managed-agents.json
#    enabled: true / mode: "dry-run"、github.workspace.repository を設定

# 2) 状態確認（ネットワークなし）
bin/managed-agents.sh status

# 3) 同期計画と request の確認（ネットワークなし）
bin/managed-agents.sh agents plan
bin/managed-agents.sh env plan
bin/managed-agents.sh session create --task-id review-20261010-1 --role repository-review \
  --prompt "docs/architecture と README の整合性を確認してください" --budget-cents 100

# 4) 実行先の判定（Managed へ出してよいかと理由。決定は decisions.jsonl に残る）
bin/managed-agents.sh route --task-id review-20261010-1 \
  --json '{"task_type":"review","risk":"low","read_only":true,"files_affected":12,"managed":{"requested":true}}'
```

live（§4 を満たした後）:

```bash
export ANTHROPIC_API_KEY=...           # シェル履歴に残さない方法で設定する
export CLAUDEOS_MA_GITHUB_TOKEN=...    # Contents: Read のみの PAT

bin/managed-agents.sh status --probe   # 一覧取得 1 回（トークン消費なし）
bin/managed-agents.sh env ensure       # limited networking の Environment を作成
bin/managed-agents.sh agents sync      # 3 Agent を作成・更新

# 初回接続テスト（上限 $0.50）
bin/managed-agents.sh session run --task-id connect-20261010-1 --role repository-review --class check \
  --budget-cents 50 --prompt "README.md を読み、3 行で要約してください。"

bin/managed-agents.sh budget status
bin/managed-agents.sh budget reconcile --console-usd 0.12 --note "Console 確認 2026-10-10"
```

| コマンド | 内容 |
|---|---|
| `status [--probe]` | 設定・予算・Agent 定義の状態。`--probe` は live のときだけ一覧取得を 1 回行う |
| `agents list / plan / sync` | 設定済み Agent の一覧、同期計画、同期 |
| `env plan / ensure` | Environment の計画、作成 |
| `route --json '<task>'` | Agent Router による実行先の判定と記録 |
| `session create / run` | 予算付きセッションの作成、作成から完了までの監視 |
| `session wait / get / events / interrupt / close` | 監視、状態取得、イベント取得、中断、使用量の確定 |
| `budget status / reconcile` | 台帳の集計、Console との照合 |

`task_id` は重複実行防止のキーです。同じ `task_id` では 2 回実行できません。

## 6. 異常時の対応

| 状況 | adapter の動作 | 人間の対応 |
|---|---|---|
| API キー未設定 | 終了コード 2。API を呼ばない | 設定する。Local 側の作業は影響を受けない |
| 予算ガードの拒否 | 終了コード 3。API を呼ばない | `budget status` で段階を確認。Local で実施するか、次の請求期間を待つ |
| セッション予算に到達 | 終了コード 3。再開・引き上げをしない | 結果が途中まで出ている。続きが必要なら Local で実施する |
| クレジット不足（`billing_error`） | 終了コード 3 | Console で残高を確認する。追加購入は別途承認が必要 |
| 認証・権限エラー（401 / 403） | 終了コード 4（BLOCKED）。再試行しない | API キーと workspace の権限を確認する |
| API 障害・タイムアウト | 終了コード 5 / 8。GET のみ 1 回再試行 | Local で実施する。作成の成否が不明な場合は Console でセッションを確認し `session close` で確定する |
| 監視時間の超過 | `user.interrupt` を送って停止 | 必要なら Local で実施する |
| 同一 `task_id` | 終了コード 6 | 既存の結果を確認する。やり直す場合は新しい `task_id` を使う |
| 台帳の破損 | fail-closed で新規実行を拒否 | `~/.claudeos/managed-agents/ledger.jsonl` を確認・修復する |

## 7. ロールバック

| 段階 | 方法 | 影響 |
|---|---|---|
| 即時停止 | `config/managed-agents.json` の `mode` を `disabled` にする（またはファイルを削除する） | Managed Agents への経路が閉じる。Local の動作は変わらない |
| 実行中セッションの停止 | `bin/managed-agents.sh session interrupt --session-id <id>` の後 `session close` | 以後の課金が止まる |
| コードの取り消し | 統合 PR の squash commit を `git revert` する | adapter・Router 拡張・文書が元に戻る。`managed` ブロックを使う呼び出し元は本リポジトリ内に無い |
| Anthropic 側リソース | Agent / Environment は残しても課金されない。archive は取り消せないため、不要と確定してから行う | — |
| ローカル状態 | `~/.claudeos/managed-agents/`（台帳・registry・決定履歴）は監査記録として残す | 削除しても Local の動作に影響しない |

データベースの migration、公開設定、Secret の変更は含まれないため、取り消しに伴うデータ移行はありません。

## 8. ファイルの場所

| 種類 | パス | git |
|---|---|---|
| 設定 | `config/managed-agents.json` | 管理外 |
| 設定テンプレート | `config/managed-agents.json.template` | 管理 |
| Agent 定義 | `config/managed-agents-roster.json` | 管理 |
| 台帳 | `~/.claudeos/managed-agents/ledger.jsonl` | 管理外 |
| Agent・Environment の ID 対応 | `~/.claudeos/managed-agents/registry.json` | 管理外 |
| 判定・実行の履歴 | `~/.claudeos/managed-agents/decisions.jsonl` | 管理外 |

状態ディレクトリは `CLAUDEOS_MA_STATE_DIR`、設定パスは `CLAUDEOS_MANAGED_AGENTS_CONFIG` で変更できます。
