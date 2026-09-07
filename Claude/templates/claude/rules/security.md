# セキュリティ（常時ロード）

- secret / credential / token / private key / connection string を表示・保存・commit・ログ・PR・文書へ出力しない。秘密候補は値を示さず影響と rotation 方法だけを報告する。
- `.env` を Git 管理しない。`.env.example` は変数名とサンプル値のみ。
- production data、個人情報、社外秘を local / preview へ無断コピーしない。テストデータは匿名化・合成・公開情報を使う。
- security control、audit、認証、監視、hooks、Branch Protection を無断で無効化しない。
- 破壊的操作（DROP / TRUNCATE / 条件なし DELETE / rm -rf / force push / データ削除）は backup と rollback 手段を確認し、Human Approval Gate の対象なら停止する。
- 外部書込みの前に read-only で接続先・アカウント・権限・環境（preview / production）を特定する。
