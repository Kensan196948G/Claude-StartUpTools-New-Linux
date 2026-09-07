# Cloudflare公開基盤仕様（任意基盤）

状態: v1（2026-09-07 制定、ClaudeOS v10）
正本: 本ファイル
旧仕様: `CloudflareNeonGitHub自動化仕様.md` §2 を分離・更新したもの。

## 1. 位置づけ

Cloudflare は必須基盤ではない。次の用途が必要な場合にのみ採用する。

| 用途 | サービス | 備考 |
|---|---|---|
| 静的配信 | Pages | フロントエンドのみ。API は持たせない |
| 入口制御 | Access | 検証環境・社内向け公開の認証 |
| 内部サービス公開 | Tunnel | ホスト側 systemd サービスを公開 DNS へ露出させずに公開 |
| DNS / Edge | DNS、WAF、Cache | 公開 DNS 変更は Approval PR |
| Preview | Pages Preview | UI と Access の確認まで。DB 接続確認はホスト側 preview で行う |

## 2. Local PostgreSQL との分離

- Workers / Pages Functions / Hyperdrive から Local PostgreSQL へ直接接続しない
- DB を持つバックエンドは Linux ホストの systemd サービスとして稼働させ、必要なら Tunnel + Access を経由して公開する
- DB 接続情報を Cloudflare Secrets に置かない（`~/.config/<app>/db.env` 0600）
- Cloudflare 側の障害・設定変更が DB 正本に影響しない構成を維持する

## 3. MCP 構成（変更なし）

| MCP 名 | 実体 | 用途 |
|---|---|---|
| `cloudflare` | Cloudflare API MCP（Code Mode、`https://mcp.cloudflare.com/mcp`） | 一覧・取得・設定変更・デプロイ |
| `cloudflare-docs` | Cloudflare Documentation MCP | 最新仕様の調査 |

認証は OAuth または `CLOUDFLARE_API_TOKEN` / `CLOUDFLARE_ACCOUNT_ID`（ホスト環境変数）。値を出力・保存しない。

## 4. 利用ルール

1. 調査は `cloudflare-docs` MCP で最新仕様を確認する（事前知識だけで API を呼ばない）
2. 参照系（list / get / status）は即時実行してよい
3. 変更系（create / update / delete / deploy）は対象と内容を明示し、実行後に read-back する
4. 公開 DNS、custom domain、Access policy、production route、Secrets の変更は Approval PR（人間 Y/N）
5. preview deployment は自律実行してよい。production 変更は PR に明記した範囲でのみ行う
6. 不明点があるまま操作しない（fail closed）

## 5. 判断フロー

```text
公開が必要か？ ── いいえ → Cloudflare を使わない（ホスト内 / 社内 LAN）
     │ はい
     ▼
静的 UI のみか？ ── はい → Pages（+ Access）
     │ いいえ（API / DB あり）
     ▼
ホスト systemd で稼働 → Tunnel + Access で公開（DNS 変更は Approval PR）
```
