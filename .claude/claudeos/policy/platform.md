# ClaudeOS v10 Policy — 標準基盤（正本・Cloudflare・Local PostgreSQL・WebUI）

> 旧 CLAUDE.md（v9、27 節）から移設した正本。CLAUDE.md は要約のみを保持し、本ファイルは必要時に参照する。DB 運用の詳細は `docs/architecture/PostgreSQLデータ運用仕様.md`。

---

## 5. 標準開発基盤と正本

原則として次を標準構成とする。ただし、リポジトリの承認済み設計が異なる場合は、その設計を確認して整合させる。

| 構成要素 | 役割 |
| --- | --- |
| Claude Code on Linux | 開発、調査、ビルド、テストおよび一時作業 |
| GitHub | ソースコード、設定テンプレート、設計書、READMEおよび変更履歴の正本 |
| Cloudflare | Pages、Workers、Accessなどによるpreview、検証および公開基盤 |
| ローカルPostgreSQL | PostgreSQLデータベースの正本 |

次を厳守する。

- Linuxローカルをソースコードや業務データの唯一の正本にしない。
- Docker Volumeを業務データの正本にしない。
- SQLiteを本番業務データの正本にしない。
- `.env`をGit管理しない。
- `.env.example`には秘密値や実値を含めない。
- secret、credential、token、private key、connection stringをコード、ログ、PR、文書へ出力しない。
- production data、個人情報、社外秘情報をlocalまたはpreviewへ無断コピーしない。
- テストデータは匿名化、合成または公開情報を使用する。
- previewとproductionの資源、URL、database／role、secretおよび権限を分離する。

---

## 12. Cloudflare運用方針

Cloudflareでは、read-only調査、preview変更、production変更を明確に区別する。

確認対象：

- Pages、Workers、Access、DNS、routes、custom domains
- environment variables、Secrets、bindings
- logs、analytics、deployment history
- Wrangler設定、GitHub連携、CI/CD経路
- local、preview、staging、productionの対応関係

原則：

- 対象account、zone、projectおよびenvironmentを一意に特定する。
- preview deploymentは自律実行してよい。
- productionとpreviewでsecret、route、domainおよびデータ接続を分離する。
- secretの値を表示、保存または文書化しない。
- production変更は、通常PRまたはApproval PRに内容を明記し、マージ`Y`の範囲でのみ行う。
- 対象を一意に特定できない場合はproduction操作を行わない。
- Cloudflare（Workers、Pages Functions、Hyperdrive等）からローカルPostgreSQLへ直接接続しない。DBを持つバックエンドはLinuxホスト上のsystemdサービスとして稼働させ、公開が必要な場合はCloudflare Tunnel／Accessを経由する。

---

## 13. ローカルPostgreSQL運用方針

Linuxホスト上のローカルPostgreSQL（systemd `postgresql@<major>-main`、Unix socket）を業務データの正本として扱う。Neon等のmanaged PostgreSQLは利用しない（2026-09 移行済み。運用詳細は `docs/architecture/PostgreSQLデータ運用仕様.md`）。

確認対象：

- cluster、database、role、schema、拡張およびpg_hba設定
- connection（socket／localhost）、pooling（PgBouncerまたはアプリ側pool）、migration、indexおよびquery performance
- data integrity、容量、auditability、backup、restore drillおよびdisk使用率
- development（`<app>_dev`）、test／CI（`<app>_test`／`<app>_ci`）、preview（`<app>_pr<N>`）、production（`<app>`）の境界

原則：

- 環境ごとにdatabaseとroleを分離し、`<app>_app`（実行）、`<app>_migrator`（migration）、`<app>_ro`（read-only調査）の最小権限roleを使う。
- 接続情報（DATABASE_URL）は `~/.config/<app>/db.env`（0600）等のSecret管理とし、コード、ログ、PR、Cloudflare Secretsへ出力しない。
- migrationは開発用DBまたはPR用一時DBで先に検証し、additiveかつ後方互換を優先する。破壊的変更はexpand-and-contractへ再設計する。
- migrationはホスト側（systemdのdeploy step）から適用し、直前に `pg_dump -Fc` スナップショットを取得する。GitHubホストのCIからローカルDBへは接続しない。
- backupは `bin/pg-ops.sh backup`（pg_dump -Fc + sha256 + retention）、復元検証は `bin/pg-ops.sh restore-drill`（`<app>_recovery` へ実復元しテーブル数・行数を照合）を定期実行し、「バックアップファイルが存在する」だけでは成功扱いにしない。
- pg_dump／pg_restoreはサーバと同一majorに固定する（`PG_BIN=/usr/lib/postgresql/<major>/bin`）。
- production write、migrationまたは削除は、PRに対象、影響、backup、rollbackおよび検証方法を明記する。
- `DROP DATABASE`、`DROP ROLE`、productionへの `pg_restore --clean`、backupファイル削除、retention短縮、pg_hba／listen_addresses変更は§17のApproval PR対象とする。
- production dataをテスト用途へ無断転用しない。migration失敗時に継続実行せず、データ整合性を確認する。

---

## 14. WebUIおよびデザイン方針

standalone HTML、handoff bundle、design notes、screen map、tokens、mockおよびassetsが存在する場合は、仕様・参照物として活用する。

- 参照デザインとproduction実装を区別する。
- 情報設計、レイアウト、配色、導線および画面遷移を可能な範囲で維持する。
- desktopとmobileの両方を確認する。
- responsive behavior、keyboard操作、focus、accessibilityを確認する。
- loading、empty、error、success、disabledおよび権限不足状態を確認する。
- `production-safe`と`design-consistent`を別々に判定する。

WebUIを起動した場合は、起動コマンド、port、listen address、確認URL、必要な環境変数および停止方法を報告する。`0.0.0.0`でlistenする場合は、実際にアクセス可能なURLを明示する。

---

