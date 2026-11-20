# Web コンソール v2（統合コンソール）

`scripts/web/public/v2.html` は、ClaudeOS の統合コンソール（13 画面）を 1 ファイルに
まとめた UI である。元は Anthropic design-component 形式の設計成果物で、次の構造を持つ。

| 要素 | 中身 |
|---|---|
| `<script type="__bundler/template">` | 画面マークアップ + `class Component extends DCLogic`（状態と操作） |
| `<script type="__bundler/manifest">` | React / dc-runtime / フォント（gzip + base64） |
| ローダ | manifest を展開して template を描画する |

配信は既存の `startup-server.js` の静的配信にそのまま乗る（同一オリジン）。

```
http://127.0.0.1:3740/v2.html
```

同一オリジンなので `/api/startup/*` を CORS なしで直接叩ける。

## 実データに接続している範囲

設計成果物は状態がすべてサンプル値で、起動も「実起動しません」と表示するプロトタイプだった。
`__bundler/template` のデータ層だけを実 API に差し替えてある（manifest・ローダは無変更）。

| 機能 | 接続先 | 状態 |
|---|---|---|
| プロジェクト一覧 | `GET /api/startup/state` の `all_folders` | 実データ |
| セッション（稼働） | 同上 `sessions` | 実データ |
| 監査ログ | `GET /api/startup/audit?lines=200` | 実データ |
| 計画（--dry-run） | `POST /api/startup/plan` | 実実行 |
| 起動 | `POST /api/startup/launch`（`confirm: true`） | 実実行 |
| 停止 | `POST /api/startup/stop` | 実実行 |
| 状態の自動更新 | 15 秒間隔で state + audit を再取得 | 実データ |

実装上の要点:

- `refreshLive()` が state と audit を取得して `realProjects` / `sessions` / `audit` を更新する。
- `projectNames()` は `realProjects` があればそれを使い、無ければ従来のサンプルへフォールバックする。
- 計画・起動・停止は `livePost()` で実 API を叩き、結果を通知と監査欄へ反映して再取得する。
- 失敗時は API の `error` / `stderr` をそのまま通知に出す（成功に見せない）。
- ヘッダのバッジは「起動・停止・監査は実データ / 一部画面は未接続」に変更した。

## まだ接続していない範囲（設計は 100% 描画される）

Cron スケジュール、Systemd 起動管理、Agent Teams 管理、SubAgent 管理、Managed Agents、
診断・ツール、品質ワークベンチ、DevOps、SecOps は、**画面は設計どおり描画されるが
データは設計成果物のサンプル値のまま**である。これらは対応する API がまだ無いため、
実データへ繋ぐには次のいずれかが必要になる。

1. `startup-server.js` に読み取り専用 API を追加する（cron: `crontab`、systemd: `systemctl --user`、
   agents: `scripts/tools/agent-teams-status.js`、managed: `scripts/tools/managed-agents.js`、品質: dsh-qa のデータ）
2. 実データが無いものは「未取得」と明示してサンプル値を出さない

現状は 1 が未実装のため、当該画面はサンプル値で描画される。**実データと誤認しないよう
バッジで区別している**が、画面単位の表示は今後「未取得」へ寄せる必要がある（バックログ）。

## 検証

- `scripts/web/console-v2.test.js`: template が JSON として読めること、実 API への参照、
  偽装タイマーの不在、サンプル表記の不在を固定する（5 テスト）。
- ブラウザ実測: `http://127.0.0.1:3740/v2.html` で 369 プロジェクト・監査 35 件を表示、
  計画実行で `POST /api/startup/plan` が 200 / `exitCode 0`、実 dry-run 出力を画面表示。

## 読み取り専用の運用情報 API（2026-11-21 追加）

`startup-server.js` に、書き込みを行わない運用情報の取得 API を追加した。
いずれも `spawn(cmd, args)` を配列引数で呼び、シェル解釈を介さない。

| API | 取得元 | 返すもの |
|---|---|---|
| `GET /api/ops/systemd` | `systemctl --user list-units --type=service` | `claude*` unit の name / load / active / sub / description |
| `GET /api/ops/cron` | `crontab -l` | 5 フィールドのスケジュール・コマンド・無効化フラグ |
| `GET /api/ops/agents` | `scripts/tools/agent-teams-status.js --json` | Agent Teams 使用状況（state.json 由来） |

設計方針: **取得できなければ `available: false` と理由 (`note` / `stderr`) を返し、
空配列を「0 件」と偽らない**。取得できない環境（CI・権限なし）でも HTTP 200 と `ok: true` を保ち、
UI 側が「未取得」と「0 件」を区別できるようにする。

### 既知の制約: cron が取得できない理由

このホストでは `claudeos-web-startup.service` が `NoNewPrivileges=yes` で動いており、
`crontab` が spool (`/var/spool/cron/crontabs/<user>`, `drwx-wx--T root:crontab`) を読むための
setgid 昇格が阻害される。そのためサービス文脈では `crontab -l` が
`crontabs/<user>/: fopen: Permission denied` で失敗し、API は `available: false` を返す。

対応方針（いずれも未実施）:

1. `NoNewPrivileges` を外す — 硬化を弱めるため非推奨
2. プロジェクト側の cron 管理（`bin/cron-schedule.sh`）が保持する定義を取得元にする
3. 特権ヘルパー（root 側で crontab を読む小さな unit）を用意し、その出力を読む

現状は 2 が最短。UI の Cron 画面はサンプル値のままなので、2 を実装してから接続する。
