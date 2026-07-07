# Data Architecture Protocol — Linux 非正本化 / Neon・Cloudflare 基盤

## 概要

採用スタックと役割分担を固定し、「正のデータをどこに置くか」を全プロジェクト共通で統一する。

| レイヤー | 正本 | 役割 |
|---|---|---|
| ソースコード・設計書・README | GitHub | 唯一のソースオブトゥルース |
| 検証公開基盤 | Cloudflare (Pages / Workers / Access) | Pages/Workers によるデプロイ、Access による入口制御 |
| DB | Neon (PostgreSQL) | 唯一の DB 正本。育てやすさ優先 |
| 開発作業台 | ClaudeCode on Linux | 一時作業・ビルド・動作確認のみ。正データは置かない |

## 設計思想

- Linux ローカルに正のデータを置かない
- 検証環境を増やしやすくする（使い捨て前提）
- 本番化しないプロジェクトも無駄に重くしない
- Cloudflare Access で入口制御する（検証環境の無制限公開を避ける）
- DB は PostgreSQL 系（Neon）で育てやすくする（SQLite からの移行コストを先に潰す）

## 必須ルール（全プロジェクト共通・登録済み / 今後登録するプロジェクトの両方に適用）

1. Linux に正の DB データを置かない
2. Docker volume を正本にしない
3. SQLite ファイルを正本にしない
4. `.env` は Git 管理しない
5. `.env.example` のみ Git 管理する
6. DB 接続情報は Cloudflare Secrets / GitHub Secrets で管理する
7. 検証環境は Cloudflare Access で制限する
8. Neon を標準 DB とする
9. ファイル本体が必要な案件は Cloudflare R2 追加を検討する

## CTO 判断基準

- 新規プロジェクト立ち上げ時: DB が必要なら初手から Neon を前提に設計する（SQLite からの後移行を避ける）
- 既存プロジェクトの改修時: ローカル DB ファイルや `.env` の Git 混入を検知したら、このルールへの移行を Issue 化する（即座の破壊的移行は行わない）
- 検証環境公開時: Cloudflare Access のポリシー未設定のまま Pages/Workers を公開しない
- ファイルアップロード機能を持つ案件: R2 導入要否を設計段階で検討し、ローカルファイルシステムを正本にしない

## 注意事項

- 本ルールは新規追加のみを強制する。既存の稼働中システムを無断で移行・破壊しない
- `.env` の Git 混入を発見した場合は、値を出力・転記せず `.gitignore` 追加と履歴除去の要否を人間に確認する
- Secrets の実際の設定作業（Cloudflare / GitHub 双方）は人間の決裁範囲

## 例外経路

DB を持たない静的サイトや、Neon 導入が明らかに過剰な小規模検証（使い捨てプロトタイプ等）は、
このルールの対象外とする。ただし対象外と判断した理由を README または PR に明記する。
