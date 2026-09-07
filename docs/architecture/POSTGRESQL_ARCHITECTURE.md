# POSTGRESQL_ARCHITECTURE — Local PostgreSQL 標準（要約）

状態: v10（2026-09-07）。詳細正本は `PostgreSQLデータ運用仕様.md`。

## 1. 位置づけ

Local PostgreSQL（`postgresql@<major>-main`、現行 16、systemd、`listen_addresses=localhost`、Unix socket `/var/run/postgresql`）を業務データの唯一の正本とする。Neon 等の managed PostgreSQL は利用しない。Cloudflare とは疎結合（Workers / Pages Functions / Hyperdrive から直接接続しない）。

## 2. 環境モデル

| 環境 | DB | 備考 |
|---|---|---|
| Development | `<app>_dev` | Local PostgreSQL |
| Test | `<app>_test` | 隔離、seed 再実行可 |
| CI | GitHub Actions service container | 同 major、空 DB へ migration / seed |
| Preview | `<app>_pr<N>` | `CREATE DATABASE … TEMPLATE <app>_dev`、PR close で削除 |
| Production | `<app>` | Local PostgreSQL。Human Gate 対象操作あり |

## 3. Role / 権限

`<app>_app`（LOGIN、実行）、`<app>_migrator`（DDL）、`<app>_ro`（read-only 調査）。全て NOSUPERUSER / NOCREATEDB / NOCREATEROLE。`REVOKE CREATE ON SCHEMA public FROM PUBLIC`。`bin/pg-ops.sh init <project>` が作成する。

## 4. 接続・Secrets

`DATABASE_URL=postgresql://<role>:<pw>@localhost/<db>?host=/var/run/postgresql` を `~/.config/<app>/db.env`（0600）に置き、systemd `EnvironmentFile=` で読む。Git / Cloudflare Secrets / ログへ出さない。`.env.example` はサンプルのみ。

## 5. Migration

additive / 後方互換を優先。`bin/pg-ops.sh migration-risk <path>` で `DROP` / `TRUNCATE` / 条件なし `DELETE` / `ALTER … DROP|TYPE` を検出し HUMAN_APPROVAL。適用はホスト側 deploy step から、直前に `pg_dump -Fc`。

## 6. Client tool

`PG_BIN=/usr/lib/postgresql/<server major>/bin` を固定（`pg__bin_dir` が `pg_lsclusters` から解決）。PATH 上の psql 18 / pg_dump 17 は使わない。

## 7. Health / Logging / Disk

`pg-ops.sh health`（pg_isready + disk ≥90% 警告）、`libexec/diag-postgres.sh --json`、Mission Control `/api/v10`。PostgreSQL ログは `/var/log/postgresql/`。
