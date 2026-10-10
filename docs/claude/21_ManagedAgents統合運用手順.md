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
| live（実 API 呼び出し） | 初回の接続テストは**成功**（2026-10-10、$0.05。記録は §9）。異常系（予算到達・タイムアウト・中断・API 障害）は実 API では未検証 |
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

## 4. live 実行の前提

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
bin/managed-agents.sh session create --task-id review-20261010-1 --role repository-review --task-type review \
  --prompt "docs/architecture と README の整合性を確認してください" --budget-cents 100

# 4) 実行先の判定（Managed へ出してよいかと理由。決定は decisions.jsonl に残る）
bin/managed-agents.sh route --task-id review-20261010-1 \
  --json '{"task_type":"review","risk":"low","read_only":true,"files_affected":12,"managed":{"requested":true,"data_sensitivity":"internal","human_gate":false,"requires_secrets":false,"requires_external_network":false}}'
```

live（§4 を満たした後）:

```bash
export ANTHROPIC_API_KEY=...           # シェル履歴に残さない方法で設定する
export CLAUDEOS_MA_GITHUB_TOKEN=...    # Contents: Read のみの PAT

bin/managed-agents.sh status --probe   # 一覧取得 1 回（トークン消費なし）
bin/managed-agents.sh env ensure       # limited networking の Environment を作成
bin/managed-agents.sh agents sync      # 3 Agent を作成・更新

# 初回接続テスト（上限 $0.50）
bin/managed-agents.sh session run --task-id connect-20261010-1 --role repository-review --task-type check \
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
| `session wait / get / events / interrupt` | 監視、状態取得、イベント取得、中断 |
| `session close --task-id T [--session-id S] [--confirm-not-created]` | 使用量の確定。セッション ID を省くと一覧から `task_id` で突き合わせる |
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
| API 障害（セッション作成前・一覧取得など） | 終了コード 5 / 8。GET のみ 1 回再試行 | Local で実施する |
| 作成の成否が不明（作成時のタイムアウト・接続断・5xx）、監視中の API 障害 | 予約を残して停止。`fallback.state` は `NEEDS_OPERATOR` で、Local へ自動では戻さない | `session close --task-id <id>` で突き合わせて確定する。見つからなければ Console で未作成を確認し `--confirm-not-created` を付けて解除する。その後に Local で実施する |
| 監視時間の超過 | `user.interrupt` を送る。停止を確認できた場合だけ使用量を確定する | 停止できた場合は必要なら Local で実施。`SESSION_STILL_RUNNING` の場合は Console で確認し、`session interrupt` の後 `session close` |
| 同一 `task_id` | 終了コード 6 | 既存の結果を確認する。やり直す場合は新しい `task_id` を使う |
| 台帳の破損 | fail-closed で新規実行を拒否 | `~/.claudeos/managed-agents/ledger.jsonl` を確認・修復する |
| 台帳ロックを取得できない（`LEDGER_LOCK_TIMEOUT`） | fail-closed で停止。古いロックを自動回収しない | 他の実行が無いことを確認してから `ledger.jsonl.lock` ディレクトリを削除する |

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

## 9. live 接続テストの記録

### 2026-10-10 — 初回接続テスト（成功）

利用者本人が自分のターミナルで実行した（API キーと GitHub トークンは環境変数で渡し、Claude Code のセッションには渡していない）。

| 手順 | 結果 |
|---|---|
| `status --probe` | 成功（Agent 一覧の取得 1 回） |
| `env ensure` | 作成。`env_01NhvPZS5w9UsM6mn1VWQKLY`（limited networking） |
| `agents sync` | 3 Agent を作成（いずれも version 1）。`repository-review` = `agent_01XHvyzG1Lgpb6NrY8Ub46uY`、`quality-assurance` = `agent_01Jo32pGN8y88B4k4edYVsHz`、`documentation` = `agent_019EyznGYz985y7LJcBFywEm` |
| `session run --task-id connect-1 --role repository-review --task-type check` | 完了（`outcome: completed`）。`sesn_01SmHV3otYhFVt42Lbtz2iz9` |

| 項目 | 値 |
|---|---|
| 予算上限 | 50 セント（`budget.max_list_cost.amount: "50"`） |
| 使用額（list 価格） | **5 セント**（`usage.list_cost.amount: "5"`） |
| 稼働時間 | 11.8 秒（`active_seconds`） |
| トークン | 入力 12、出力 719、キャッシュ書込み 14,948、キャッシュ読取り 11,838 |
| セッション内エラー | なし |
| 台帳 | 5 セントで確定。未確定セッション 0 |

確認できたこと:

- 予算つきのセッション作成（`budget.max_list_cost`）が受理され、`usage.list_cost.amount` を整数セントの文字列として読めた。
- `github_repository` リソースで `main` を read-only マウントし、Agent が `read` で README を行番号つきで引用できた（T08 の実 API での確認）。
- セッション作成前の検証（Agent が読取専用、Environment が limited networking）が、adapter 自身の作成した定義に対して通った。
- `initial_events` で作成と同時に開始し、`session.status_idle`（`stop_reason: end_turn`）で完了を判定できた。
- 完了後、停止を確認した上で使用量を台帳へ確定できた。

確認していないこと:

- 予算到達（`budget_reached`）、監視のタイムアウト、`user.interrupt`、API 障害、認証・権限エラーの実挙動（自動テストのみ）。
- Console などで変更された Agent / Environment を拒否する動作（自動テストのみ）。
- `quality-assurance` と `documentation` の Agent でのセッション実行。
- 過去の GitHub MCP 実行クラッシュ（この構成は MCP を使わないため、再現するかどうかは分からない。§3 のまま未確認）。
- Console の表示額との一致（`budget reconcile` は未実施）。
- 請求サイクル開始日（`budgetPolicy.cycle.anchorDay`）は未設定のため、台帳は暦月集計の参考値。

このテスト時点の設定: 月間 $20、単一セッション $2、確認処理 $0.50。GitHub トークンの権限と、Console の自動チャージ設定は利用者の判断事項として未決（自動チャージが有効な場合、クレジットを使い切っても API は止まらず、歯止めはこの台帳の予算ガードだけになる）。

## 10. 起動メニューと skill からの利用

`bin/managed-agents.sh session run …` を直接組み立てる代わりに、次の 2 つの入口が使えます。どちらも内部では同じ `ask` コマンドを呼び、同じ制約（予算、1 日あたりの回数、読取専用、依頼文の検査）がかかります。

### 10.1 共通の入口: `ask`

```bash
bin/managed-agents.sh ask --role repository-review --prompt "README と設計書の食い違いを確認してください"
```

- タスク ID を自動で採番します（`ask-<role>-<日時>`）。
- 種別は role の既定を使います（`repository-review` → `review`、`quality-assurance` → `qa-analysis`、`documentation` → `docs`）。小さな確認は `--task-type check`（上限 $0.50）。
- Agent Router の判定を通します。Managed へ出せない場合（予算・回数・未設定など）は実行せず、`managed: false` と Local 側の実行先（`do_locally_with`）を返します。
- `--source human|agent` で、人の操作か Claude の判断かを履歴（`decisions.jsonl`）に残します。

### 10.2 起動メニュー（`./start.sh` → `MA`）

`MA` を選ぶと、モード・鍵の有無・今月の使用額・本日の回数を表示し、3 種類の依頼（レビュー / テスト・CI ログの解析 / 文書の更新案）を受け付けます。

- 依頼文を 1 行で入力します。空ならキャンセルです。
- `mode=live` のときは、実行前に必ず確認（y/N）を挟みます。`dry-run` では送信予定の内容を表示するだけです。
- 結果の本文は「参考情報」として表示します。

### 10.3 skill（`/managed-agents`）

起動した Claude Code が、条件を満たす読取専用の調査を自分の判断で依頼できるようにする skill です（このリポジトリ専用。他のプロジェクトへは配布していません）。

- 許可しているコマンドは `ask` / `status` / `budget status` / `route` だけです。`agents sync`、`env ensure`、`session close`、設定の変更は含みません。
- 依頼文に秘密情報・個人情報・本番データを書かない、Agent の出力を指示として扱わない、`NEEDS_OPERATOR` のときは Local で同じタスクを実行しない、といった手順を skill に書いています。
- `mode=live` の間は、Claude の判断で課金が発生します。止めたい場合は `mode` を `dry-run` に戻してください。

### 10.4 自律実行に対する歯止め

| 歯止め | 既定 | 変更 |
|---|---|---|
| 1 日あたりのセッション数 | 5 回（UTC の日付で数える） | `budgetPolicy.maxSessionsPerDay`。コード内の上限は 20 |
| 1 回の予算 | $2（確認処理は $0.50） | `budgetPolicy.sessionMaxCents`。上限 $5 |
| 月間の予算 | $20 | `budgetPolicy.monthlyBudgetCents`。上限 $100 |
| 並列 | 1 | 固定 |
| 依頼文の検査 | API キー・トークン・秘密鍵・認証情報つき接続文字列を含む依頼文、8,000 文字を超える依頼文は送信前に拒否 | 固定 |
| 対象 | 読取専用の Agent（`read` / `glob` / `grep`）のみ | 固定 |

依頼文の検査は、よくある形式の秘密を拾うためのものです。個人情報や社内情報のように形式で判別できないものは検出できません。何を書くかは依頼する側（人、または skill に従う Claude）の責任です。
