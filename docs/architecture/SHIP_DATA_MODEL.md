# SHIP_DATA_MODEL — Ship Native の DB 射影（`claudeos_control` migration 0006）

状態: v5.0「Ship Native」（2026-11-24）
正本: ファイルストア `scripts/ship/lib/store.js`（`$CLAUDEOS_HOME/ship/**`）
射影: [`0006_ship_native.sql`](../../db/control/migrations/0006_ship_native.sql)、[`project-to-db.js`](../../scripts/ship/project-to-db.js)
手動ロールバック: [`0006_ship_native.down.sql`](../../db/control/rollback/0006_ship_native.down.sql)
関連: [`ControlPlaneデータ基盤仕様.md`](ControlPlaneデータ基盤仕様.md)、[`POSTGRESQL_ARCHITECTURE.md`](POSTGRESQL_ARCHITECTURE.md)

## 1. 位置づけ（正本は DB ではない）

Ship Native の判定（品質証跡の HMAC 封印、署名付き Human Approval の検証、nonce の使用済み化、マージ確認）は**すべてファイルストアと署名検証で行う**。DB は横断検索・ダッシュボード・監査のための**射影**であり、マージ可否の根拠に使ってはならない。

- DB が止まっても Ship Native は動く（射影は後から流し直せば追いつく）。
- 射影は ControlPlane 仕様 §5 の `dual-write` 相当（ファイルが正本のまま、DB へも書く）。`db-canonical` は本版では行わない。
- 書き込みは `scripts/ship/project-to-db.js`（独立プロセス）のみ。hook や Ship 本体は DB を直接触らない。

## 2. 既存テーブルの再利用と新規テーブル

| ストアのレコード | 射影先 | 再利用 / 新規 | 理由 |
|---|---|---|---|
| repo（`owner/repo`） | `control.projects` | **再利用** | `remote_slug` で突合。無ければ `project_key = gh.<owner>__<repo>` で作る。既存 project があればそれを使う |
| `audit.jsonl` の各行 | `control.audit_events` | **再利用** | 追記専用・行ダイジェスト付きの監査表がそのまま使える。`action = 'ship.<event>'`、`subject_kind = 'ship'`、元の行全体（`hash`/`prev_hash` を含む）を `detail` に保持。`idempotency_key = sha256('ship/audit.jsonl:' || 行番号 || ':' || canonical_json)`（0001 §冪等性の規約どおり） |
| モデル利用量 | `control.model_usage` + `control.ship_session_usage` | **再利用** + 紐付け表 | 数量・金額は既存表が正。重複集計を避けるため紐付けだけ追加 |
| run（`runs/<id>.json`） | `control.ship_sessions` | 新規 | 状態語彙（22 状態、`state-machine.js`）が `control.run_statuses` と合わない。lease/heartbeat も不要。既存 `control.runs` とは任意列 `control_run_id` で紐付け可能 |
| `run.history[]` | `control.ship_state_transitions` | 新規 | 遷移履歴（追記専用） |
| PR | `control.pull_requests` | 新規 | `(repo, pr_number)` の同一性。各表の FK 先 |
| quality（Local Quality Engine） | `control.quality_evaluations` | 新規 | 1 実行 = 1 行（= local test run）。`eval_id` UNIQUE。HMAC 値は保存しない |
| `quality.checks[]` | `control.test_results` | 新規 | チェック単位。`PASS ⇒ exit 0 かつ failed 0` を CHECK |
| gate（AI Quality Gate） | `control.gate_evaluations` | 新規 | リスク R0..R4 は**列** `risk_level`（判定と同時に確定するため別表にしない） |
| ship-evidence（/ship 結果の人間署名） | `control.ship_review_attestations` | 新規 | nonce UNIQUE、署名・key_id を型付き列で保持 |
| approval（署名済み Human Gate） | `control.human_approvals` | 新規 | 下記 §3 |
| revocation | `control.approval_revocations` | 新規 | 1 承認 1 取り消し |
| `consumed/<nonce>` | `control.approval_consumptions` | 新規 | `(approval_id, nonce)` 複合 FK で承認と nonce の一致を強制、両列 UNIQUE |
| merge | `control.merge_events` | 新規 | 観測ごとの追記。`confirmed ⇒ merge_commit_sha あり かつ MERGED 系` |
| `policyVersion` | `control.policy_versions` | 新規 | `config/ship-policy.json` の版。`--policy-file` 指定時のみ `content_sha256` を 1 回だけ埋める |
| （将来）レビュー指摘 | `control.review_findings` | 新規 | v5.0 の store にはまだ書き手が無い。状態が変わるため可変、`(pull_request_id, fingerprint)` UNIQUE |
| （将来）修正ラウンド | `control.remediation_events` | 新規 | 追記専用。書き手は後続 PR |
| （将来）復旧 | `control.recovery_events` | 新規 | stale lock 回収、head 変更による承認失効、gate 外マージ検出など。追記専用 |

`control.risk_classifications` と `control.local_test_runs` は作らない（それぞれ `gate_evaluations.risk_level` と `quality_evaluations` が同じ役割を持つ）。`control.usage_records` も作らない（`model_usage` を再利用）。

## 3. `control.approvals` を再利用しない理由

既存 `control.approvals`（0003）は「申請 → 決裁 → 消費」を 1 行の `status` 遷移（`UPDATE`）で表す**可変表**で、二名承認は `approval_decisions` に分かれている。Ship Native の承認は「人間が秘密鍵で署名した 1 枚の不変な文書」であり、次の点で合わない。

1. **nonce / 署名 / key_id / base_sha / R0..R4 を型付き列で持てない**。`context jsonb` に入れると UNIQUE（リプレイ防止）も CHECK も張れない。列を足すには `ALTER TABLE` が要り、0001 の規約（ALTER 不使用）に反する。
2. **追記専用にできない**。`approvals` には `touch_updated_at` トリガがあり、app ロールに `UPDATE` が付与済み。署名済み文書を書き換え可能な表に置くと、DB 上の記録が署名と食い違いうる。
3. `approved_object_sha256` が 64 桁 hex 必須で、git の 40 桁 SHA（head/base）と意味が異なる。

そこで `control.human_approvals` を新設し、`approval_id`・`nonce`・`(approval_id, nonce)` をそれぞれ UNIQUE、`decision = 'approve' ⇒ gate_verdict = 'PASS'`、`expires_at > issued_at` を CHECK で強制した。署名は公開検証値（Ed25519 の base64）なので text で保存してよい。秘密鍵・passphrase・HMAC 鍵の列は存在しない。

## 4. 制約の要点

- **SHA**: `control.git_sha40` ドメイン（`^[0-9a-f]{40}$`）。短縮 SHA・大文字は拒否。
- **repo / ID**: `control.ship_repo`（`store.js` の `REPO_RE` と同一 + `..` 禁止）、`control.ship_record_id`（`ID_RE` と同一）。
- **判定語彙**: gate `PASS|CONDITIONAL|FAIL|UNKNOWN|BLOCKED`、quality `PASS|FAIL|UNKNOWN`、test `PASS|FAIL|ERROR|NOT_RUN`、risk `R0..R4`。run 状態は lookup 表 `ship_run_states` への FK（語彙追加を INSERT だけで完結させる 0001 の方針）。
- **秘密混入ガード**: 自由記述は既存 `control.safe_text`、jsonb は `control.jsonb_free_of_credentials()`（0001/0003 と同じ規則）。
- **リプレイ防止（DB 側）**: `human_approvals.nonce` UNIQUE、`approval_consumptions` の `approval_id` / `nonce` UNIQUE と複合 FK。ストアに同一 nonce の別承認があると、射影は `uq_human_approvals_nonce` 違反で**全体ロールバック**する（`ON CONFLICT (approval_id)` のみを指定し、nonce 衝突を握りつぶさない）。

## 5. 追記専用（append-only）

| 区分 | 表 | 書き換え |
|---|---|---|
| 追記専用 | `ship_state_transitions`、`quality_evaluations`、`test_results`、`gate_evaluations`、`ship_review_attestations`、`human_approvals`、`approval_revocations`、`approval_consumptions`、`merge_events`、`remediation_events`、`recovery_events` | `BEFORE UPDATE OR DELETE` トリガ `control.ship_block_mutation()` で**全ロール（所有者含む）**の行の書き換えを拒否。加えて `claudeos_control_app` には `SELECT, INSERT` のみ付与し `UPDATE` を revoke |
| 追記のみ（トリガ無し） | `pull_requests`、`ship_session_usage` | app は `SELECT, INSERT` のみ |
| 可変 | `ship_sessions`（最新スナップショット）、`policy_versions`（`content_sha256` を NULL→値）、`review_findings`（状態遷移） | app に `SELECT, INSERT, UPDATE` |

テーブル全体を一括で空にする種類の文は、0003 と同じくテーブル所有権と権限付与の不在で防ぐ（該当キーワードを migration に書くと `pg__migration_risk` が HUMAN_APPROVAL を要求するため、文レベルのトリガは置かない）。訂正は取り消し・再評価の新しい行で表す。

## 6. 射影スクリプト

```bash
node scripts/ship/project-to-db.js                       # dry-run (既定): 件数・除外理由・監査連鎖の検証結果を JSON で出す
node scripts/ship/project-to-db.js --sql                 # SQL を stdout へ (適用しない)
node scripts/ship/project-to-db.js --apply --db claudeos_control [--role claudeos_control_app|none] \
     [--policy-file config/ship-policy.json] [--strict]
```

- **冪等**: 追記専用表は `INSERT ... ON CONFLICT (<自然キー>) DO NOTHING`、`ship_sessions` は `source_updated_at` が新しい場合だけ上書き。同じストアからは同じ SQL が出る。全体を 1 トランザクションにまとめ、1 件でも DB 制約に反したら何も書かない。
- **事前検証**: DB の CHECK と同じ規則を JS 側でも当て、違反レコードは理由付きで除外（`--strict` なら exit 3 で何もしない）。品質証跡は `evidence_hash` を再計算して改ざんを除外する（HMAC は鍵が要るので検証しない。HMAC 値は射影しない）。
- **SQL 生成**: 値は `sqlLiteral()`（単一引用符の二重化、`SET LOCAL standard_conforming_strings = on` を強制、NUL バイト・孤立サロゲートは拒否）。psql は `spawnSync(引数配列)` で起動し SQL は stdin で渡す（シェル文字列を組み立てない）。
- **接続**: `PGHOST`（既定 `/var/run/postgresql`）の Unix socket + peer 認証のみ。子プロセスへ `DATABASE_URL` を渡さない。psql は `PG_BIN` → `pg_lsclusters` の 5432 クラスタ版 → PATH の順に解決（`lib/postgres.sh` の `pg__bin_dir` と同じ方針）。`--role` 既定は `claudeos_control_app`（`SET LOCAL ROLE`）。

## 7. ダッシュボード

`control.v_ship_pr_latest`: PR ごとの最新 gate（verdict / risk）、同一 head の最新品質評価、有効な承認数（期限内・未取り消し・未使用・head/base 一致）、最新マージ観測。**参考表示用**であり判定には使わない。主な索引: `gate_evaluations (pull_request_id, evaluated_at DESC)`、`(verdict, …)`、`(risk_level, …)`、`quality_evaluations (repo, head_sha, finished_at DESC)`、`ship_sessions (project_id, source_updated_at DESC)` / `(state, …)`。

## 8. ロールバック（手動のみ）

[`0006_ship_native.down.sql`](../../db/control/rollback/0006_ship_native.down.sql) は `db/control/migrations/` の外にあり、`ctl__migrate` は読まない。`destructive_data` の Human Approval Gate 対象。手順はファイル冒頭に記載: (1) `bin/pg-ops.sh backup claudeos_control` → `verify`、(2) 射影停止、(3) migrator 権限で適用、(4) 台帳確認。0006 で作った表・ビュー・関数・ドメイン・`idx_projects_remote_slug_lower` と台帳の `0006` 行だけを除去し、射影が `control.projects` / `control.audit_events` に書いた行は残す（audit_events は追記専用）。正本はファイルなので、再適用後に射影を流し直せば DB 側は復元できる。

## 9. 検証（2026-11-24 実施）

使い捨て DB `claudeos_ship_mig_test_<8 hex>`（`createdb` で作成、検証後 `dropdb`。既存 DB には一切適用していない）で以下を確認した。

- 0001〜0006 を `psql -v ON_ERROR_STOP=1 -v checksum=<sha256>` で順に適用、0006 の再適用も成功（冪等）。
- フィクスチャ（全種別 1 件ずつ）の射影を 3 回適用（`--role claudeos_control_app` ×2、`--role none` ×1）し、行数不変（2 回目以降 no-op）。`v_audit_integrity_violations = 0`。
- 古い run スナップショットは上書きされず、新しいものは上書きされる。
- 拒否されることを確認: 短縮 SHA / 大文字 SHA（`git_sha40_format`）、nonce 重複（`uq_human_approvals_nonce`、射影経由でも全体ロールバック）、gate FAIL への approve、verdict / risk 語彙外、`eval_id` 重複、使用記録の nonce 不一致（複合 FK）、同一承認の 2 回目の使用、merge commit 無しの confirmed、`safe_text` / jsonb への秘密混入、追記専用表の UPDATE / DELETE（所有者でも）、app ロールの追記専用表への UPDATE（permission denied）。
- `pg__migration_risk` は 0006 を additive と判定。
- `pg_dump -Fc` のあとロールバックを適用し、0006 の物が 0 件・台帳が 0001〜0005・既存 projects / audit_events の行が残ること、さらに 0006 を再適用できることを確認。

単体テスト: `node --test scripts/ship/project-to-db.test.js`、`bats tests/bats/unit/control-db-0006.bats`。CI には PostgreSQL サーバーが無いため（ControlPlane 仕様 §11）、実機検証はローカルの使い捨て DB で行う。

## 10. 既知の限界

- `review_findings` / `remediation_events` / `recovery_events` は表のみで、v5.0 の store には書き手がまだ無い（射影対象外）。
- `merges/<slug>/pr-N.json` は最新の観測で上書きされるため、射影できるのは射影時点で残っている観測だけ（過去の観測は `audit.jsonl` の `merge_observed` から追える）。
- `consumed/<nonce>` の `consumed_at` はファイルの mtime を使う（ファイル本体は approval_id のみ）。
- DB の追記専用トリガはスーパーユーザーによる `ALTER TABLE ... DISABLE TRIGGER` までは防げない。改ざん検出の最終根拠はファイル側の署名・HMAC・監査ハッシュ連鎖である。
