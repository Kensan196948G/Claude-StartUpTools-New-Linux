# MANAGED_AGENTS_INTEGRATION — ClaudeOS × Claude Managed Agents 統合設計

状態: 初期 PoC（read-only）／2026-10-10
正本: `scripts/tools/managed-agents.js`、`scripts/tools/managed-budget.js`、`scripts/tools/agent-router.js`、`config/managed-agents.json.template`、`config/managed-agents-roster.json`
運用手順・現行 API との差分・再検証手順: `docs/claude/21_ManagedAgents統合運用手順.md`

## 1. 方針

Local Claude Code が主系で、Claude Managed Agents は**低リスク・読取専用タスクのクラウド補完先**である。既存の ClaudeOS（Supervisor / Goal Router / Agent Router / cron / tmux / GitHub Actions / Local PostgreSQL）は作り直さず、Managed Agents を Agent Router から選べる実行先の 1 つとして追加する。Agent ループと sandbox は Anthropic 側が持つため、ClaudeOS 側に新しいオーケストレーターは置かない。

配布時の既定は `enabled=false` / `mode=disabled` で、この状態では既存の動作は一切変わらない。

## 2. 構成

```text
User / Mission Control
        │
ClaudeOS Control Plane ── tmux / Supervisor / cron / systemd
        │
Goal Router        lib/goal-router.sh        セッション全体の Goal と execution_plane（常に local）
        │
Agent Router       scripts/tools/agent-router.js   作業単位の実行先（純関数）
        │               ▲ 証拠（可用性・予算状態・重複）を渡す
Budget / Policy    scripts/tools/managed-agents.js route ＋ managed-budget.js
        │
   ┌────┴─────────────────────────────┐
Local Claude Code（主系）        Claude Managed Agents（補完）
Main / Subagent / Background …   read / glob / grep のみ・MCP なし・limited networking
   └────┬─────────────────────────────┘
Independent QA / Security Review（Local 側。Managed の出力は提案として扱う）
        │
GitHub PR / CI / Audit（既存の GitHub ポリシーのまま）
```

### 役割分担

| 実行先 | 担当 | 触れないもの |
|---|---|---|
| Local Claude Code | ソースコードの実装・検証、tmux / Supervisor / cron、Local PostgreSQL 連携、長時間の継続開発、PR 作成とマージ判定 | — |
| Managed Agents | リポジトリ調査、変更差分の品質分析、テスト・CI ログの解析、Issue 分類、ドキュメント更新案の作成 | Local PostgreSQL、Linux ホストの管理コマンド、Secret、本番環境、GitHub への書込み |

### 2 つの Router の関係

- **Goal Router** はセッション全体の Goal を決める。`lib/managed-agents.sh` の `ma__validate` は「セッション全体を Managed で実行してよいか」の契約で、PoC では常に非 0 を返すため `execution_plane` は `local` のままになる。Managed が補完先として使えるかは `ma_mode` / `ma_reason`（例: `local-primary:managed-complement-dry-run`）で伝える。
- **Agent Router** は作業単位の実行先を決める。入力に `managed` ブロックがある場合だけ Managed Agents を評価する。ブロックが無い場合の出力は従来と完全に同一で、配布先プロジェクトへ影響しない。

## 3. コンポーネント

| ファイル | 役割 |
|---|---|
| `scripts/tools/managed-agents.js` | REST adapter と CLI。設定検証、Agent 定義の同期、Environment 作成、予算付きセッション作成、状態・イベント取得、中断、完了判定、エラー分類、状態確認、Router への証拠供給 |
| `scripts/tools/managed-budget.js` | 整数セントの Budget Guard と追記専用台帳。事前予約、段階制御、重複防止、Console との照合 |
| `scripts/tools/managed-session-payload.js` | `POST /v1/sessions` の body 契約。予算なし・上限超過の payload は生成しない |
| `scripts/tools/agent-router.js` | `managed` ブロックによる opt-in 判定（`managedEligibility`） |
| `lib/managed-agents.sh` | Goal Router が期待する `ma__load` / `ma__validate` 契約。source と `ma__load` は副作用なし |
| `bin/managed-agents.sh` | CLI 入口。必要な環境変数だけを allowlist で node へ渡す |
| `config/managed-agents.json.template` | 実行設定契約（git 管理外の `config/managed-agents.json` へコピーして使う） |
| `config/managed-agents-roster.json` | Agent 定義と Environment 定義の正本（秘密を含まない） |

REST を直接呼ぶ理由: 本リポジトリは依存ゼロ（`package.json` の `dependencies` が空、CI は `npm install --package-lock-only`）の bash + Node.js 構成で、公式 SDK を追加すると既存の検証経路が変わるため。

## 4. 実行モードと停止条件

| mode | ネットワーク | 用途 |
|---|---|---|
| `disabled`（既定） | 出ない | Managed Agents を使わない |
| `dry-run` | 出ない | 送信予定の request を秘密なしで表示し、判定と payload を確認する。台帳へも書かない |
| `live` | `api.anthropic.com` のみ | Console で残高・利用権限を確認し、人間が課金を承認した場合だけ設定する |

adapter は次の場合に API を呼ばずに停止する: 設定契約の不成立、API キー未設定、設定ファイル内の秘密らしき値、`apiBaseUrl` が `api.anthropic.com`（とテスト用 loopback）以外、予算ガードの拒否、同一 `task_id` の重複、読取専用ポリシー違反。

## 5. 予算制御

### 5.1 運用モデル

Claude Max 5x の月額 $100 クレジットのうち、Managed Agents PoC に割り当てる枠を `budgetPolicy` で定める。実際に使える金額は Console の残高・有効期限・請求周期が正本であり、この設定は予防的な上限である。

| 項目 | 既定値 | 設定キー |
|---|---|---|
| 月間 PoC 予算 | $20 | `budgetPolicy.monthlyBudgetCents: 2000` |
| 単一セッション上限 | $2 | `sessionMaxCents: 200` |
| 初回接続テスト・確認処理の上限 | $0.50 | `connectionTestMaxCents: 50` |
| 日次ソフト予算 | $3 | `dailySoftCents: 300` |
| 並列実行数 | 1 | `maxConcurrentSessions: 1` |
| API 失敗時の自動再試行 | 最大 1 回（冪等な GET のみ） | `maxApiRetries: 1` |

`config.json` の `agentSdk.monthlyBudgetUsd`（Claude Code / Agent SDK 用）とは別管理で、互いに読み書きしない。台帳も別ファイルのため、同じ利用分が二重に数えられることはない。

### 5.2 段階ガード

`lib/credits.sh` の段階思想と語彙を再利用し、Managed 用に 100% を追加する。比率は整数演算（`spent * 100 >= pct * budget`）で判定する。

| 消費率 | stage | 動作 |
|---|---|---|
| 70% 以上 | `credit-cap:warn` | 警告つきで許可 |
| 85% 以上 | `credit-cap:verify-only` | 通常タスクを停止。低コストの確認処理（`--class check`、上限 $0.50）だけ許可 |
| 95% 以上 | `credit-cap:stop` | 新規セッション停止 |
| 100% 以上 | `credit-cap:exhausted` | 実行禁止 |

### 5.3 事前予約

Managed Agents のセッション予算は「次のモデルリクエストの前」に判定されるため、上限を跨いだリクエストは完走する。実績だけで判定すると 1 セッション分の超過を許すので、作成前に**上限額**を予約して判定する。

- 予約後の月間合計が月間予算を超える要求は拒否する。
- 予約後の日次合計が日次ソフト予算を超える要求は既定で拒否し、`--ack-daily-soft` で明示許可する。
- 未確定のセッションは `max(予約額, 実績)`、確定済みは実績、作成失敗で解除したものは 0 として数える。
- `session.usage` の `list_cost` は累積値なので、台帳は合算せずタスクごとの最大値を採用する。
- 重複防止・ガード・予約の追記は 1 つのロック内で行う。台帳に解釈できない行があれば fail-closed で拒否する。

### 5.4 API への反映

セッション予算は必ず `budget: {type: "limit", max_list_cost: {amount: "<セント整数の文字列>", currency: "USD"}}` として送る。金額は整数セントで保持し、USD 文字列からの変換も浮動小数を経由しない。予算到達（`stop_reason: budget_reached`）で止まったセッションの再開、上限の引き上げ、予算の削除は実装していない。

### 5.5 請求サイクルと照合

`budgetPolicy.cycle.anchorDay`（Console の請求サイクル開始日・UTC）を設定すると請求サイクルで集計する。未設定の間は暦月集計を「参考値」として扱い、判定結果に `period-is-calendar-month-reference` の警告を付ける。`cycle.creditsExpireAt` を過ぎると新規実行を止める。

台帳は list 価格ベースの予測値で、Console の実績とは `managed-agents.sh budget reconcile --console-usd <額>` で照合する。クレジット残高そのものを返す API は公式ドキュメント上で確認できていないため、残高の確認は人間が Console で行う。

## 6. Agent Router 統合

`managed` ブロックつきの入力に対し、次をすべて満たす場合だけ `execution: "ManagedAgent"` を返す。

| 区分 | 条件 |
|---|---|
| 安全条件（policy） | `read_only=true`、risk / security / database / deployment が low、Secret 不要、外部通信不要、データ機密性が public / internal、Agent 間通信なし、人間承認待ちでない、task_type が許可リスト内、所要時間が上限内 |
| 容量条件（capacity） | 設定と認証が有効、予算状態が ok / warn（verify-only は `check` のみ）、同一 `task_id` が未実行 |
| 選択条件 | 明示要求（`managed.requested=true`）がある、または Local が使えない（`managed.local_available=false`） |

Local が稼働中というだけでは Managed Agents を並列起動しない。Local 側の決定は `managed.fallback_execution` に常に残り、判定は `~/.claudeos/managed-agents/decisions.jsonl` に記録する。

## 7. エラー分類とフォールバック

| 分類 | 例 | 終了コード | 戻り先 |
|---|---|---|---|
| `CONFIG` / `KEY_MISSING` | 設定不成立、API キー未設定 | 2 | Local（経路に影響なし） |
| `BUDGET` / `BILLING` | 予算ガード拒否、クレジット不足（402 / `billing_error`） | 3 | Local。新規 Managed 実行は停止 |
| `SESSION_BUDGET` | セッション予算に到達 | 3 | なし（再開・引き上げは人間の判断） |
| `AUTH` / `PERMISSION` | 401 / 403 | 4 | なし（BLOCKED） |
| `RATE_LIMIT` / `SERVICE` / `NETWORK` | 429 / 5xx / 529 / 接続断 | 5 | Local |
| `INVALID_REQUEST` / `NOT_FOUND` / `CONFLICT` | 400 / 404 / 409 | 5 | なし（調査が必要） |
| `DUPLICATE` | 同一 `task_id` | 6 | なし（既に実行済み） |
| `POLICY` | 読取専用ポリシー違反 | 7 | なし（BLOCKED） |
| `TIMEOUT` | 応答なし、監視時間超過 | 8 | Local |

Local へ戻すのは予算不足・API 障害・未設定の場合だけである。認証・権限・ポリシーの拒否と人間承認待ちは BLOCKED とし、別経路で回避しない。Router が `policy_denied=true` を返したタスクは、Managed が使えない場合でも「Managed へ出さない」だけで、Local 側の Human Approval Gate はそのまま適用される。

セッション作成（POST）は自動再試行しない。タイムアウトや接続断で作成の成否が分からない場合は予約を残し、人間が Console で確認してから `session close` で確定する。

## 8. 初期 Agent

| Agent | role | モデル | 内容 |
|---|---|---|---|
| A: Repository Review | `repository-review` | `claude-sonnet-5-5`（effort medium） | README・設計資料・変更差分と既存アーキテクチャの整合性評価 |
| B: Quality Assurance | `quality-assurance` | `claude-haiku-5-5` | Bats / Node.js テスト / ShellCheck / CI 結果の解析と修正案 |
| C: Documentation | `documentation` | `claude-haiku-5-5` | README・運用手順・設計書の更新案 |

- 3 つとも `read` / `glob` / `grep` だけを有効にした `agent_toolset_20260401` を使い、`bash` / `write` / `edit` / Web ツール / MCP は持たない。`assertReadOnlyAgent` が同期前に構造を検証し、違反する定義は送信しない。
- Agent C は PoC では更新案を返すだけで、実ファイルの更新は Local が作業ブランチ上で行う。
- モデルは Managed 側の独立した設定で、Local Claude Code の既定（`config.modelRouter`）には影響しない。

## 9. セキュリティ

| 観点 | 対策 |
|---|---|
| API キー | 環境変数 `ANTHROPIC_API_KEY` からのみ読む。設定・台帳・出力に保存しない。送信先は `api.anthropic.com` に固定 |
| GitHub トークン | `github.workspace.tokenEnv` が指す環境変数から読み、`github_repository` リソースの `authorization_token` として渡す。Anthropic 側の git proxy が注入するため sandbox 内からは読めない。Contents: Read のみの fine-grained PAT を使う |
| 設定ファイル | 秘密らしきキーに値があると利用不可と判定する |
| 出力 | すべての標準出力・エラー出力を伏字処理に通す。dry-run では秘密の代わりに `<env:NAME>` を表示する |
| 環境変数の受け渡し | `bin/managed-agents.sh` は allowlist の変数だけを node へ渡す |
| ネットワーク | Environment は `limited` networking（deny-by-default、MCP・パッケージマネージャ不許可） |
| 書込み経路 | Agent に書込み・実行ツールと MCP が無いため、main への push や PR 作成の手段が無い |
| 外部データ | リポジトリ内の指示文は参考データとして扱うよう各 Agent の system に明記 |
| 既知の障害 | 過去の GitHub MCP 実行クラッシュは MCP を宣言しない構成で回避（修正状況は未確認） |

## 10. 受け入れテスト

| # | 内容 | 自動テスト |
|---|---|---|
| T01 | 設定の読み込み | `managed-agents.test.js` T01、`managed-agents.bats` |
| T02 | API キー未設定時の安全な停止 | 同 T02 |
| T03 | 予算未指定セッション作成の拒否 | `managed-budget.test.js` T03、`managed-agents.test.js` T03 |
| T04 | セント単位の金額変換 | `managed-budget.test.js` T04 |
| T05 | 予算 70% / 85% / 95% / 100% の段階制御 | 同 T05 |
| T06 | 重複セッション起動の防止 | 両テストの T06 |
| T07 | API タイムアウト時の安全な停止 | `managed-agents.test.js` T07 |
| T08 | GitHub への読取専用アクセス | 同 T08（定義の構造検証。実 API では未検証） |
| T09 | main への直接 push 拒否 | 同 T09（書込み手段が無いことの構造検証） |
| T10 | 本番環境への無承認アクセス拒否 | 同 T10、`agent-router.test.js` |
| T11 | Secret・Credential の非表示 | 同 T11、`managed-agents.bats` |
| T12 | Local Claude Code への安全な切替 | 同 T12 |
| T13 | 既存テスト・CI の回帰検証 | `npm test` / `npm run lint` / `bin/release-check.sh` |
| T14 | ロールバック手順の検証 | `docs/claude/21` §7 |

すべてモックで実行し、実 API は呼ばない。実クレジットを使う接続テストの手順と前提は `docs/claude/21` §4。

## 11. 対象外（今後の判断）

- Managed Agents からの書込み（ブランチ作成・PR 作成）と GitHub MCP の利用
- Webhook による状態通知、scheduled deployments、multiagent、outcomes
- Control Plane DB（`control.model_usage`）への使用量の射影
- Usage / Cost Admin API による自動照合（Admin キーが必要）
