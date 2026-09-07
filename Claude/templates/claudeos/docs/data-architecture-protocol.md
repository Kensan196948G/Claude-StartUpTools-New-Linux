# Data Architecture Protocol v2 — Local PostgreSQL 正本 / GitHub 正本 / Cloudflare 任意

状態: v2（2026-09、ClaudeOS v10）。v1（Neon 正本・Linux 非正本化）は末尾の Deprecated 付録として履歴保持。

## 概要

採用スタックと役割分担を固定し、「正のデータをどこに置くか」を全プロジェクト共通で統一する。

| レイヤー | 正本 | 役割 |
|---|---|---|
| ソースコード・設計書・README | GitHub | 唯一のソースオブトゥルース |
| DB | Local PostgreSQL（`postgresql@<major>-main`、Unix socket） | 唯一の DB 正本。環境ごとに database / role を分離 |
| バックエンド実行 | Linux ホスト systemd（`<app>.service`） | API・業務処理・migration 適用。DB と同一ホスト |
| 公開・入口制御 | Cloudflare（必要時のみ Pages / Access / Tunnel / DNS） | 静的配信・アクセス制御・公開。DB へ直接接続しない |
| 開発作業台 | Claude Code on Linux | 実装・ビルド・検証。正データは DB と GitHub にのみ置く |

## 設計思想

- Local PostgreSQL を正本にし、managed DB（Neon 等）へ依存しない
- 環境（dev / test・ci / preview / prod）は同一 cluster 内の database + role で分離する
- バックアップは「存在する」ではなく「復元できる」を定期的に証明する（restore drill）
- Cloudflare は任意基盤。Workers / Pages Functions / Hyperdrive から Local PostgreSQL へ直接接続しない
- 使い捨て検証は `<app>_pr<N>` データベース（TEMPLATE clone）で軽量に作り、PR close で削除する

## 必須ルール（全プロジェクト共通）

1. DB の正本は Local PostgreSQL。SQLite / Docker volume / ファイルを正本にしない
2. `.env` は Git 管理しない。`.env.example` のみ Git 管理する（値はサンプル）
3. DB 接続情報は `~/.config/<app>/db.env`（0600）に置き、systemd `EnvironmentFile=` で読む。Cloudflare Secrets / GitHub Secrets に DB 資格情報を置かない
4. role は `<app>_app`（実行）、`<app>_migrator`（migration）、`<app>_ro`（read-only 調査）に分け、最小権限とする
5. migration はホスト側 deploy step から適用し、直前に `pg_dump -Fc` スナップショットを取る。GitHub-hosted CI から Local PostgreSQL へは接続しない（CI は service container の一時 PostgreSQL を使う）
6. backup は `bin/pg-ops.sh backup`（pg_dump -Fc + sha256 + retention 14d）、復元検証は `bin/pg-ops.sh restore-drill`（`<app>_recovery` へ実復元・件数照合）を systemd timer で定期実行する
7. pg_dump / pg_restore はサーバと同一 major を固定する（`PG_BIN=/usr/lib/postgresql/<major>/bin`）
8. 検証環境を公開する場合は Cloudflare Access または Tunnel で入口制御する
9. ファイル本体が必要な案件はホスト側ストレージ + backup 対象化、または Cloudflare R2 を検討する（DB に BLOB を溜めない）
10. `DROP DATABASE` / `DROP ROLE` / production への `pg_restore --clean` / backup 削除 / retention 短縮 / `pg_hba.conf`・`listen_addresses` 変更は Human Approval（Approval PR）

## CTO 判断基準

- 新規プロジェクト立ち上げ時: `bin/pg-ops.sh init <app>` で database / role を作り、`.env.example` と backup unit（`bin/pg-ops.sh units <app> <db>`）を初手で用意する
- 既存プロジェクトの改修時: Neon / managed DB 参照、`.env` の Git 混入、直接 DSN 埋め込みを検知したら Issue 化して段階移行する（即座の破壊的移行は行わない）
- preview 公開時: ホスト側 preview（`<app>-preview@<pr>.service` 等）で API・DB を動かし、Cloudflare は UI / Access のみ
- 単一ホスト前提のリスク（RPO=24h、RTO=手動復元）を README / 運用文書に明記し、必要なら off-host 暗号化コピーを追加する

## 注意事項

- 本ルールは新規追加と改修時の指針であり、稼働中システムを無断で移行・破壊しない
- `.env` や DSN の Git 混入を発見した場合は、値を出力・転記せず `.gitignore` 追加と履歴除去の要否、資格情報 rotation を人間に確認する
- Secrets の実配置（`~/.config/<app>/db.env`、Cloudflare / GitHub 側）は人間の決裁範囲

## 例外経路

DB を持たない静的サイトや使い捨てプロトタイプは本ルールの対象外とする。ただし対象外と判断した理由を README または PR に明記する。

---

## Deprecated 付録 — v1（Neon 正本 / Linux 非正本化、2026-09 に Local PostgreSQL へ移行）

> 履歴保持のため v1 の要旨を残す。現行ルールとして参照しない。

- v1 は Neon (PostgreSQL) を唯一の DB 正本とし、「Linux に正の DB データを置かない」「DB 接続情報は Cloudflare Secrets / GitHub Secrets で管理」「Neon を標準 DB とする」を必須ルールとしていた
- v2 では DB 正本を Local PostgreSQL へ移行し、接続情報の置き場をホスト側 `EnvironmentFile`（0600）へ変更、Cloudflare を任意基盤へ格下げした
- 移行理由と手順: `docs/architecture/PostgreSQLデータ運用仕様.md`、`docs/architecture/MIGRATION_V9_TO_V10.md`
