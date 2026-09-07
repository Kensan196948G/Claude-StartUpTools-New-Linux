# PostgreSQLデータ運用仕様（Local PostgreSQL 正本）

状態: v1（2026-09-07 制定、ClaudeOS v10）
正本: 本ファイル、`Claude/templates/claudeos/docs/data-architecture-protocol.md`（v2）、`lib/postgres.sh`
旧仕様: `CloudflareNeonGitHub自動化仕様.md` §3（Neon）は Deprecated。末尾の付録に要旨を保持する。

## 1. 目的と適用範囲

Linux ホスト上の Local PostgreSQL を業務データの唯一の正本として運用するための標準を定める。対象は ClaudeOS が管理する全登録プロジェクトと ClaudeOS 自身。Neon / managed PostgreSQL は利用しない。

## 2. 標準構成

| 項目 | 標準 |
|---|---|
| サーバ | `postgresql@<major>-main`（systemd、現行 16）。`listen_addresses='localhost'`、接続は Unix socket `/var/run/postgresql` |
| 環境分離 | 同一 cluster 内で database + role を分ける。`<app>`（prod）、`<app>_dev`、`<app>_test`／`<app>_ci`、`<app>_pr<N>`（preview、TEMPLATE clone）、`<app>_recovery`（restore drill 専用） |
| role | `<app>_app`（LOGIN、実行）、`<app>_migrator`（DDL）、`<app>_ro`（read-only 調査）。全て NOSUPERUSER / NOCREATEDB / NOCREATEROLE |
| 接続情報 | `DATABASE_URL=postgresql://<role>:<pw>@localhost/<db>?host=/var/run/postgresql` を `~/.config/<app>/db.env`（0600）に置き、systemd `EnvironmentFile=` で読む。Git / Cloudflare Secrets / ログへ出さない |
| pooling | 必要な場合のみ PgBouncer（transaction）またはアプリ側 pool。pg_dump / migration は直接接続 |
| client tool | サーバと同一 major を固定（`PG_BIN=/usr/lib/postgresql/<major>/bin`）。PATH 上の psql 18 / pg_dump 17 は使わない |
| 公開 | Cloudflare Workers / Pages Functions / Hyperdrive から直接接続しない。バックエンドはホスト systemd で稼働し、公開は Tunnel + Access 経由 |

## 3. 操作 CLI（`bin/pg-ops.sh`）

| コマンド | 内容 | 自律実行 |
|---|---|---|
| `health [db]` | `pg_isready` + ディスク使用率（90% 以上で警告） | 可 |
| `init <project> [--role r] [--db d] [--password-file f]` | 専用 role / database 作成、`REVOKE CREATE ON SCHEMA public` | 可（新規作成のみ、既存は不変更） |
| `backup <db> [dir] [--retention-days N]` | `pg_dump -Fc` + sha256 + `latest.dump` + retention prune。作成直後に `pg_restore --list` で検証 | 可 |
| `verify <file>` | sha256 照合 + TOC 読取（存在するだけでは PASS にしない） | 可 |
| `restore-drill <db> [file] [--keep]` | `<db>_recovery` へ実復元し、テーブル数と全テーブル行数を照合。結果を `~/.claudeos/pg/drill-<db>.json` へ記録 | 可（復元先は `*_recovery` 限定） |
| `freshness <db> [dir] [hours]` | 最新バックアップの鮮度（既定 26h）と検証 | 可 |
| `migration-risk <path>` | `DROP` / `TRUNCATE` / 条件なし `DELETE` / `ALTER … DROP|TYPE` を検出し HUMAN_APPROVAL | 可（検出時は停止） |
| `status <db> [--json]` | Mission Control 向け JSON（health / size / backup 鮮度 / 直近 drill） | 可 |
| `units <project> <db> [--install]` | systemd backup / restore-drill unit と timer を生成（`--install` で配置・有効化） | 生成は可、`--install` は運用者判断 |

## 4. Backup / Disaster Recovery

- 日次 backup（03:15 + ランダム遅延）と週次 restore drill（日曜 04:30）を systemd timer で実行する（`Claude/templates/linux/pg-*.tmpl`）
- retention 14 日。backup ディレクトリは `/var/backups/claudeos/<db>`（0700、所有者は実行ユーザー）
- 成功条件は「restore drill が PASS」であること。`drill-<db>.json` の `result` が FAIL のときは Mission Control とレポートで警告する
- RPO = 24h（日次 dump）、RTO = 手動復元（`pg_restore --no-owner -d <db> latest.dump`）。より短い RPO が必要なプロジェクトは WAL アーカイブ（pgBackRest 等）を個別に設計する
- 単一ホストのため、off-host 暗号化コピー（既存ホストの `cwwd-db-backup-export` パターン）を推奨する
- 復元手順（本番）: 1) 影響範囲と承認（Approval PR） 2) 現行 DB の `pg_dump` 退避 3) `pg_restore --clean --if-exists` 4) 整合性確認 5) 記録

## 5. Migration ポリシー

- additive / 後方互換を優先し、破壊的変更は expand-and-contract に分割する
- 適用順: `migration-risk` 判定 → `<app>_dev` または `<app>_pr<N>` で検証 → 直前 `pg_dump -Fc` スナップショット → ホスト側 deploy step で本番適用 → 事後確認
- GitHub-hosted CI から Local PostgreSQL へは接続しない。CI は service container の一時 PostgreSQL（同 major）で migration / seed を空 DB へ再実行する
- 失敗時は継続せず、スナップショットからの復旧可否を確認してから報告する

## 6. Human Approval Gate（Approval PR）

- `DROP DATABASE` / `DROP ROLE`（`_pr<N>` / `_ci` / `_recovery` を除く）
- production への `pg_restore --clean`、大量 `DELETE`、`TRUNCATE`、不可逆な型変更
- backup ファイル削除、retention 短縮、backup unit の無効化
- `pg_hba.conf` / `listen_addresses` / 拡張の追加削除
- production data の複製・匿名化なしの利用

## 7. 監視（Mission Control）

`libexec/diag-postgres.sh --json` と `bin/pg-ops.sh status <db> --json` を Mission Control の `/api/postgres` が集約し、health / size / backup 鮮度 / drill 結果 / ディスク使用率を表示する。閾値: backup age > 26h、drill FAIL、disk >= 90% を警告。

## 8. 環境モデル

| 環境 | DB | 用途 |
|---|---|---|
| Development | `<app>_dev`（Local PostgreSQL） | 実装・検証 |
| Test | `<app>_test`（隔離、seed 再実行可） | 自動テスト |
| CI | GitHub Actions service container の一時 PostgreSQL | migration / seed / テスト |
| Preview | `<app>_pr<N>`（`CREATE DATABASE … TEMPLATE <app>_dev`） | PR 検証。PR close で削除 |
| Production | `<app>`（Local PostgreSQL） | 本番 |

## 9. 付録（Deprecated）— Neon 運用の要旨（2026-09 移行済み）

旧仕様では Neon（`mcp.neon.tech`、`NEON_API_KEY`、project / branch モデル、`mcp__neon__*` ツール）を共通基盤としていた。v10 では上記のとおり Local PostgreSQL へ移行し、branch 概念は database 分離へ、Neon MCP は `psql` / migration ツール / `pg_stat_statements` / `EXPLAIN` へ、`NEON_API_KEY` は `~/.config/<app>/db.env` へ置換した。中央ポリシー（Deep-Seek-Harness-Project）側の Neon 記述は CENTRAL_POLICY_CONFLICT として `MIGRATION_V9_TO_V10.md` に記録し、本リポジトリからは編集しない。
