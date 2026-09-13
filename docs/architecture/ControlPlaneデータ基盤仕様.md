# Control Plane データ基盤仕様（`claudeos_control`）

状態: v1（2026-09-13 制定、ClaudeOS v11 PR#1）
正本: 本ファイル、`db/control/migrations/*.sql`、`lib/control-db.sh`（PR#2 以降）
関連: `docs/architecture/AGENT_ORCHESTRATION.md`、`docs/architecture/PostgreSQLデータ運用仕様.md`

## 1. 目的と適用範囲

ClaudeOS には Agent Router / Supervisor / Agent Teams / Hooks / Mission Control / Local PostgreSQL 運用が既に揃っている。しかし **オーケストレーションの状態そのもの**（Task / Run / Agent / Handoff / Approval / Checkpoint / Eval / Audit / Cost / Failure / Skill 昇格）は `state.json`・JSONL・tmux 状態・hook 出力へ分散しており、横断クエリ・監査・改ざん検知ができない。

本仕様は、既存の Local PostgreSQL クラスタ上に `claudeos_control` という専用データベースを追加し、上記の状態を集約する **Control Plane** を定義する。既存機能（Agent Router、Hooks、Mission Control 等）を置き換えるものではなく、それらの外側から状態・権限・評価を管理する層である。

Neon / managed PostgreSQL は使用しない（`docs/architecture/PostgreSQLデータ運用仕様.md` §1 に準拠）。

## 2. 責務境界（既存 JSON 資産との分担）

| データ | 現状の置き場所 | 本基盤導入後 |
|---|---|---|
| Agent Router の決定 | `state.json.execution.routing_log`（最新 20 件のみ、実測で長さ 0） | `control.workflow_events` / `control.agent_assignments` へ射影。`state.json` 側は当面併存（フォールバック） |
| 監査証跡 | `.claude/claudeos/data/audit-log.jsonl`（`PostToolUse` のみ、5 キー、消費者コード無し） | `control.audit_events`（追記専用、改ざん検知付き）へ射影 |
| 推論履歴 | `.claude/claudeos/data/reasoning-bank.json` | 当面は現状維持。将来 `control.failure_patterns` 等と突き合わせる |
| 信頼スコア | `.claude/claudeos/data/trust-score.json` | 当面は現状維持。`control.trust_scores` は Agent/Skill 単位の粒度を追加するもので、プロジェクト単位の既存ファイルを置き換えない |
| Human Approval Gate | 各所の Y/N プロンプトのみ。永続記録なし | `control.approvals` / `control.approval_decisions` で記録・期限・改変検出を付与（PR#5） |

**移行方針**: 既存ファイルは直ちに廃止しない。段階的ロールアウト（§5）を経て、観測が十分に積み上がった時点でどちらを正本にするかを利用者が判断する。

## 3. 標準構成

| 項目 | 標準 |
|---|---|
| サーバ | 既存の Local PostgreSQL 16 クラスタを共用（新規クラスタは立てない） |
| データベース | `claudeos_control`（production）、`claudeos_control_dev`、`claudeos_control_test`。`_pr<N>` / `_ci` / `_recovery` は既存規約に準拠 |
| ロール | `claudeos_control_migrator`（DDL 所有）、`claudeos_control_app`（実行時 DML）、`claudeos_control_ro`（参照専用）、`claudeos_control_audit`（監査 INSERT 専用） |
| 認証 | **秘密ゼロ構造**（§4）。パスワード・接続文字列は存在しない |
| 接続 | Unix socket `/var/run/postgresql`（既存 `PGHOST` 規約と同一） |
| クライアント | `psql` CLI のみ。Node.js 側に `pg` 等のドライバは追加しない（`package.json` のゼロ依存を維持） |
| スキーマ | 単一スキーマ `control`。`schema_migrations` で世代管理 |

## 4. 秘密ゼロ構造（設計の中核）

4 ロールは全て **NOLOGIN のグループロール**として作成し、Control Plane を操作する OS ユーザー（`kensan` および将来の systemd 実行ユーザー）へ `GRANT <role> TO <os_user>` する。クライアントは peer 認証で `postgres`／既定ロールとして接続し、`SET LOCAL ROLE claudeos_control_app` のように **明示的に権限を落として**から操作する。

この設計により:

- パスワード・接続文字列・API キーに相当するものが **一切存在しない**。`.claude/rules/security.md` の「secret を出力しない」という努力目標が、構造的に不可能（漏らそうにも漏らす秘密が無い）という状態になる。
- `pg_hba.conf` の変更が不要（peer 認証のまま）。これは `docs/architecture/PostgreSQLデータ運用仕様.md` §6 の Human Approval Gate 対象操作を回避する。
- `CREATE EXTENSION` も不要（`gen_random_uuid()` は PG13+、`sha256()` は PG11+ のコア関数）。拡張の追加削除も同 §6 の Approval Gate 対象であるため、これも回避する。

## 5. 段階的ロールアウト

射影ワーカー（PR#3 以降で実装）は環境変数 `CLAUDEOS_CONTROL_MODE` 1 つで動作モードを切り替える。

| モード | 動作 |
|---|---|
| `shadow`（既定） | JSONL / state.json を読み計算するが DB へは書かない。ファイルが引き続き正本 |
| `compare` | `shadow` に加え、DB 側と突き合わせて乖離（`only_file` / `only_db`）を 1 行 JSON で報告する |
| `dual-write` | DB へ書き込む。ただしファイル側も書き続け、ファイルを正本のまま維持する |
| `db-canonical` | Mission Control 等の読み手を DB 側へ切り替える。**本ロードマップでは実施しない**。観測が十分に積み上がった後、利用者が判断する別作業とする |

hook（`audit-trail.js` 等）は **DB を直接操作しない**。hook は fail-soft の原則を守るため追記のみを行い、DB への反映は systemd timer / cron で動く別プロセス（射影ワーカー）が担う。これにより DB 障害が Claude Code のセッションを止めることはない。

## 6. 冪等な取り込み

射影ワーカーは append-only の JSONL を繰り返し読む可能性があるため、同一イベントの再投入は無害でなければならない。

- 調停キーは `idempotency_key` の一本のみ。`sha256(source_stream || ':' || source_seq || ':' || canonical_json(payload))` の hex 文字列とする。
- `(source_stream, source_seq)` の組は**索引のみに留め UNIQUE にしない**。ログのローテーションや書き換えで行番号が振り直された場合、2 つ目の UNIQUE 制約違反で `ON CONFLICT (idempotency_key)` が機能せず再生が停止するのを避けるため。
- 再投入は `INSERT ... ON CONFLICT (idempotency_key) DO NOTHING` で完全な no-op になる。

## 7. 権限とテーブル一覧

`db/control/migrations/000{1..5}_*.sql`（本 PR でレビュー対象。適用は PR#2 以降）に完全な DDL がある。要旨:

| Migration | 主なテーブル |
|---|---|
| `0001_foundation.sql` | `schema_migrations`、語彙 lookup（`run_statuses` 等）、`projects`、`tasks`、`task_dependencies`、`runs`（lease/heartbeat 付き）、`run_steps`、`ingest_batches`、`ingest_events` |
| `0002_agents.sql` | `execution_planes`、`agents`、`agent_capabilities`、`agent_assignments`（排他 path_scope）、`handoffs`、`checkpoints` |
| `0003_approval_audit.sql` | `risk_categories`、`approver_roles`、`approvals`（改変検出付き）、`approval_decisions`（二名承認）、`audit_events`（追記専用・ハッシュ連鎖）、`policy_changes` |
| `0004_evals_usage.sql` | `eval_definitions`、`eval_results`、`model_usage`（token/cost）、`failure_events`、`workflow_events` |
| `0005_self_improvement.sql` | `improvement_targets`、`failure_patterns`、`improvement_proposals`、`skill_candidates`、`skill_versions`、`skill_evaluations`、`skill_promotions`（**promoted は承認必須**）、`canary_runs`、`trust_scores` |

全 migration に共通する設計規約:

1. **追加のみ（additive）**。`ALTER TABLE` を使用しない。語彙の拡張は lookup テーブルへの `INSERT` で行う（`pg__migration_risk` の `ALTER TABLE ... (DROP|TYPE)` 検出、および `DROP` / `TRUNCATE` / 条件なし `DELETE FROM` 検出に、コメント文言も含めて一切抵触しないことを実機で確認済み）。
2. **拡張機能ゼロ**。`CREATE EXTENSION` は使用しない。
3. **秘密不保持**。自由記述列は `control.safe_text` ドメインとし、接続文字列・トークン・PEM 秘密鍵パターンを `CHECK` 制約で拒否する。`jsonb` 列にも同等のガードを個別 `CHECK` で付与する。
4. 全テーブルに `created_at timestamptz NOT NULL DEFAULT now()`。
5. 開放的データは `jsonb`、検索軸は実列。
6. ロール未作成でも migration が失敗しないよう、`GRANT` は `control.grant_if_role()` でガードする（`kensan` のようなロールが作成される PR#2 まで、DB は稼働できる）。

## 8. 運用（Backup / Restore Drill）

`bin/pg-ops.sh` を `claudeos_control` にもそのまま適用する（新しい運用ツールを作らない）。

- `bash bin/pg-ops.sh backup claudeos_control` → `verify` → `restore-drill claudeos_control` を PR#4（DB 作成後）で実証する。
- 日次 backup・週次 restore drill の systemd timer は既存の `Claude/templates/linux/pg-*.tmpl` パターンを踏襲し、PR#3 で追加する。
- retention・RPO/RTO は `docs/architecture/PostgreSQLデータ運用仕様.md` §4 に準拠（14 日保持、RPO=24h）。

## 9. Human Approval Gate との対応

`control.risk_categories` は組織方針 §5「高リスク変更」の分類をそのままテーブル化したものである。`control.approvals.required_approvals` と `control.approval_decisions` により二名承認・役割別承認を表現し、`tamper_detected` 生成列で承認後の対象改変を機械的に検知する。

`control.skill_promotions.to_status = 'promoted'` は `approval_id` を `NOT NULL` 相当（`CHECK` 制約）で要求する。これは「自己改善結果（skills / agents / workflow / routing / prompt）の main 反映」が Approval PR 対象であるという CLAUDE.md §5 の規約を、DB 制約として裏書きするものである。

## 10. Mission Control との接続点（実装は PR#7）

`libexec/diag-control-plane.sh --json` を追加し、`scripts/dashboards/serve-dashboard.js` の `handleV10()` へ既存の `v10RunJson()` 呼び出しパターンで 1 行追加する。表示内容は run 状況・stale run 数・承認待ち件数・直近 eval 結果・モデルコスト集計を想定する。

## 11. 既知のリスクと限界

- **`execution.routing_log` は実測で長さ 0**。記録経路（`agent-router.js` の `--record`）が実運用でほぼ呼ばれていないため、射影ワーカーを実装しても当面は空に近いデータしか集まらない。PR#3 で emission（発火点）の強化を合わせて行う。
- **CI に PostgreSQL サーバーは存在しない**（`.github/workflows/ci.yml` は ubuntu-latest + bats/shellcheck/gitleaks のみ）。DDL 本体は CI で実行検証されないため、本 PR ではローカルの一時 `_ci` サフィックス DB へ実際に適用し、構文・冪等性・制約（append-only、秘密拒否、idempotency）を実証したうえでレビューに供する。継続的な検証が必要であれば、PostgreSQL の service container を使う optional job を別途提案する。
- `Claude/templates/claudeos/**` と `.claude/claudeos/**` は既に乖離があり、parity を強制するテストが無い。本仕様書と DDL は正本である `Claude/templates/claudeos/` 側にも同一内容を配置し、本リポジトリ自身が使う `.claude/claudeos/` 側は導入 PR（#2 以降）でミラーする。
