# POSTGRESQL_BACKUP_RECOVERY — Backup / Disaster Recovery

状態: v10（2026-09-07）。実装: `lib/postgres.sh`、`bin/pg-ops.sh`、`Claude/templates/linux/pg-*.tmpl`。

## 1. 要件

| 要件 | 実装 |
|---|---|
| pg_dump | `pg-ops.sh backup <db>`: `pg_dump -Fc --no-owner --no-privileges` → `<db>-<UTC>.dump` + `.sha256`、`latest.dump` symlink、作成直後に `pg_restore --list` 検証 |
| pg_restore | `pg-ops.sh restore-drill <db>`: `<db>_recovery` へ実復元（復元先は `*_recovery` 限定） |
| Scheduled Backup | systemd timer 日次 03:15（`claudeos-<project>-pg-backup.timer`） |
| Retention | 14 日（`--retention-days`）、prune は backup 成功後 |
| Backup Integrity | sha256 一致 + TOC 読取。「存在するだけ」は失敗扱い |
| Restore Test | 週次 日曜 04:30（`claudeos-<project>-pg-restore-drill.timer`）。テーブル数と全テーブル行数を元 DB と照合。結果は `~/.claudeos/pg/drill-<db>.json` |
| Migration Rollback | 適用直前の `pg_dump -Fc` スナップショットから `pg_restore`（本番は Approval PR） |
| Disk Capacity Monitoring | `pg__disk`（df）、90% 以上で警告。Mission Control 表示 |
| DB Health Check | `pg_isready`、`pg-ops.sh status --json` |

## 2. 実機検証（2026-09-07）

| 手順 | 結果 |
|---|---|
| `pg-ops.sh init claudeos-drill-test` | role / database 作成、public CREATE revoke |
| seed 250 + 3 行 → `backup` | dump + sha256 + latest、verify PASS（TOC 14） |
| `restore-drill` | PASS（tables 2/2、row_mismatch 0） |
| 元 DB に 1 行追加後 `restore-drill` | FAIL（row_mismatch 1: public.tags src=4 rec=3）→ 改竄・欠落を検知できることを確認 |
| `migration-risk`（additive / DROP+DELETE） | none（rc 0）/ HUMAN_APPROVAL（rc 1） |
| `units`（生成のみ） | 4 unit / timer を `~/.claudeos/units` に生成、`PG_BIN=/usr/lib/postgresql/16/bin` |
| 後始末 | test DB / role を削除 |

## 3. RPO / RTO

- RPO = 24h（日次 dump）。短縮が必要なプロジェクトは WAL アーカイブ（pgBackRest 等）を個別設計
- RTO = 手動復元（数分〜。`pg_restore --no-owner -d <db> latest.dump`）
- 単一ホストのため off-host 暗号化コピー（既存ホストの `*-backup-export` パターン）を推奨

## 4. 復元手順（本番）

1. Approval PR で範囲・影響・停止時間を承認（Y）
2. 現行 DB を `pg-ops.sh backup` で退避
3. `pg_restore --clean --if-exists --no-owner -d <db> <backup>`（`PG_BIN` を固定）
4. 整合性確認（`restore-drill` と同じ件数照合、アプリ smoke）
5. 記録（release-report.md）

## 5. 失敗時

backup 失敗 → `OnFailure=` 通知（既存ホストパターンに合わせて追加可）、disk / socket / 権限を確認。drill FAIL → 世代を遡って検証、原因（欠損 / 版不一致 / 破損）を特定してから本番 DB へ手を触れない。
