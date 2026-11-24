# Ship Native v5.0 変更影響分析（R4 / R3 対応）

本 PR は `config/ship-policy.json`（R4: 品質判定・承認基盤）、`scripts/web/startup-server.js`・`db/**`（R3）を含むため、
リスク分類は **R4**。影響分析とロールバック手順を以下に記す。

## 1. 既存機能への影響

| 対象 | 変更 | 影響 | 回帰確認 |
| --- | --- | --- | --- |
| `bin/menu.sh` | Ship Native セクション（SH / QC / HG）を追加 | 既存の L1/T1/S1・番号入力は不変。新キー SH/QC/HG は既存キーと重複しない | `menu.bats` 全件 + `ship.bats` 共存テスト |
| `scripts/web/startup-server.js` | `/api/ship/*` 経路を 1 か所追加（遅延 require） | 既存エンドポイントの前後関係は不変。ship-api 読込失敗時は 503 のみ | `node --test scripts/web/*.test.js` 全件 |
| `scripts/web/public/index.html` | ship.html へのリンク 1 行 | 表示のみ | E2E（一時サーバ）|
| `config/claude-code-compat.json` | ship 系 capability 3 件追加、tested/recommended を 2.1.330 へ | `diag-claude-compat.sh` の表示行が増える。version policy は supported のまま | `claude-capability.bats` |
| `package.json` | `test:node` の find から node_modules を除外、`ship*` スクリプト追加 | 既存スクリプトの意味は不変 | `npm test` |
| `db/control/migrations/0006` | 追加のみ（ALTER/DROP なし） | 既存テーブルの列・制約は不変。未適用のまま（本番 DB へは未適用） | 使い捨て DB で 0001→0006 適用・再適用・ロールバック・再適用 |
| GitHub 設定 | **変更なし** | ruleset・Actions・中央ポリシーは未変更 | API 再取得で確認 |
| systemd / cron | **追加なし** | 既存 timer に影響なし | `systemctl --user list-timers` |
| Goal Router / `/goal` | 変更なし | 後方互換 | `goal-router.bats` |

## 2. 運用への影響

- Merge Executor は `merge.centralProfileEnforced=false`（既定）のため、**本 PR をマージしても自動マージは一切登録されない**。
- `bin/ship.sh` はユーザーが明示的に実行したときだけ動く（常駐・定期実行の登録はしていない）。
- `~/.claudeos/ship/` 以下に状態と証跡を作る（0700/0600）。

## 3. ロールバック

1. 本 PR を `git revert` する（追加ファイルが中心で、既存ファイルへの変更は上表の 5 件のみ）。
2. `~/.claudeos/ship/` は削除せず保全する（監査証跡）。
3. DB に 0006 を適用していた場合のみ `db/control/rollback/0006_ship_native.down.sql`（事前に pg_dump）。
