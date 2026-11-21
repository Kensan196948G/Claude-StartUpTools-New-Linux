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

## 画面の実データ接続（2026-11-21 追加）

`/api/ops/*` を使い、未接続だった 2 画面を実データへ繋いだ。

| 画面 | 接続内容 |
|---|---|
| Systemd 起動管理 | `GET /api/ops/systemd` の実 unit（name / active / enabled / ExecStart）で台帳を描画。15 秒ごとに更新 |
| Agent Teams 管理 | 「使用状況を表示」の実行で `GET /api/ops/agents` を叩き、返った JSON をそのまま出力欄に表示 |

### Systemd 画面は読み取り専用

設計には起動/停止・自動起動切替・登録解除・一括起動のボタンがあるが、これらは
**API 化していない**（実機の `systemctl` を操作する書き込み経路を持たない）。
そのため押しても状態を変えず、次の通知を出して「何も変更していない」ことを明示する。

> この画面は読み取り専用です。実機の systemctl 操作は未接続のため、何も変更していません。

### Agent Teams 画面の未接続項目

`history` / `diag` / `migrate` の 3 操作は API 化していないため、実行すると
「この操作は未接続です（CLI 出力を API 化していません）」と表示する。
`status` のみ実 API に接続している。

## state 取得のキャッシュ（2026-11-21 追加）

`libexec/startup-state.sh` は projectsDir 配下の全フォルダを走査するため、
370 件規模で**実測 12 秒**かかり、出力は約 120KB だった。UI は 15 秒ごとに取得するため、
そのままでは常時 CPU を使い続ける。

`startup-server.js` に短命キャッシュを入れた。

| 項目 | 値 |
|---|---|
| 既定 TTL | **20 秒**（`STARTUP_STATE_CACHE_MS` で変更可） |
| 無効化 | 起動・停止・計画・全適用の実行直後に `invalidateState()` |
| 実測 | 1 回目 11.9 秒 / 2 回目以降 **0.005 秒** |

TTL を 8 秒にすると走査（12 秒）より短くヒットしないため、20 秒にしてある。

## Cron 画面の実データ（2026-11-21 追加）

`claudeos-web-startup.service` は `NoNewPrivileges=yes` で動くため、`crontab` が spool を読むための
setgid 昇格ができず `crontab -l` が失敗する。硬化を弱めずに実データを出すため、
**ユーザー文脈のタイマーがスナップショットを書き、API がそれを読む**方式にした。

| 要素 | 役割 |
|---|---|
| `bin/cron-snapshot.sh` | `crontab -l` を解析し `$CLAUDEOS_HOME/cron-snapshot.json` へ書く（5 フィールド + コマンド + 無効フラグ） |
| `config/systemd/user/claude-startuptools-cron-snapshot.{service,timer}` | 5 分ごとにスナップショットを更新（`NoNewPrivileges=no` が必要） |
| `GET /api/ops/cron` | スナップショットを優先。無ければ直接 `crontab -l` を試す。`source` でどちらかを返す |

UI は crontab の各エントリを表示する。crontab はプロジェクト単位ではないため、
「プロジェクト」列には**コマンド末尾の basename**（例 `backup.sh`）を出し、無効行は `（無効）` を付ける。
追加・削除・run-now・一括起動は API 未実装のため**読み取り専用の通知**。

実測（このホスト）: 56 件（有効 8 / 無効 48）、`source=snapshot`。

## Playwright による自動検証（2026-11-21 追加）

`npm run test:e2e:console` で、統合コンソールの全画面を実ブラウザで検証する。

```
CONSOLE_URL=http://127.0.0.1:3740 node scripts/e2e/console.e2e.js
```

- 画面ごとに API の実値と DOM の表示を突き合わせる（例: プロジェクト件数が `all_folders` と一致するか、
  SubAgent の KPI が `agent-catalog` の `counts` と一致するか）。
- 初期描画は設計サンプル（22 件）のことがあるため、**API の件数と一致するまで待つ**。
- スクリーンショットと `result.json` を `reports/e2e/<timestamp>/` に残す（git 管理外）。
- 外部フォント等の想定内のエラーは除外し、それ以外の console error が 0 であることを確認する。

実測: 9/9 PASS（起動 370/370・Systemd 5 unit・SubAgent 9/9/6・Managed ledger 3・Cron 56 件・監査・console error 0）。

## 診断 / DevOps / SecOps の接続（2026-11-21 追加）

「実行して結果を出す」画面のため、**許可したコマンドだけを実行する allowlist 方式**にした。
任意コマンドは受け付けない。

| API | 内容 | 実測 |
|---|---|---|
| `GET /api/ops/diag?name=<key>` | `libexec/diag-*.sh` の 9 本から 1 本を実行（60 秒上限） | `all-tools` が exit 0 |
| `GET /api/ops/release-check` | `bin/release-check.sh --dry-run` のみ | FAIL（worktree が dirty のため。実測どおり） |
| `GET /api/ops/devops` | git HEAD / user timer 数 / DB 数 / node 版 | head=9c715e1, timers=84, DB=408 |
| `GET /api/ops/secops` | ツールの有無とレポート数（**実行はしない**） | gitleaks=なし |

- 診断画面: メニュー番号を API のキーへ対応付け、**実出力**を表示する。未対応の項目は「未接続」と明示。
- SecOps: スキャンは実行せず**有無の確認のみ**（gitleaks 未導入のため）。
- DevOps: 配備・再起動・DB 変更は行わず**現状値のみ**。

## 品質ワークベンチ（未接続・理由）

この画面は `bin/release-check.sh` の実行結果を検査項目ごとに表示する作りだが、
本 PR では**接続していない**。理由は、実チェック（test/lint/build）の実行が数分かかり、
同期 HTTP で返すには長すぎるため。API 側は `--dry-run` のみ対応済み。
実接続にはバックグラウンドジョブ化（開始 → 進捗取得）が必要で、別 PR の範囲とする。
現状は設計どおり「サンプルの失敗結果」を表示し、画面にもその旨が出る。

## 品質ワークベンチの接続（バックグラウンドジョブ、2026-11-21 追加）

`bin/release-check.sh` の実チェック（test/lint/build）は数分かかり、同期 HTTP では返せない。
そこで**ジョブ方式**にした。

| API | 内容 |
|---|---|
| `POST /api/ops/release-check/start` `{dry:true|false}` | ジョブを開始（同時 1 ジョブ。実行中なら既存を返す） |
| `GET /api/ops/release-check` | 現在のジョブ状態（`status` / `exitCode` / `output` / `checks`） |

- 出力行を QC のキーへ対応付ける（`❌`=NG / `✅`=OK / `⏭️`=SKIP）:
  `git_state`←Git worktree, `readme`←README, `gitignore`←gitignore, `test`/`lint`/`build`←同名。
- UI は開始後に **1.5 秒間隔でポーリング**し、結果を検査行へ反映する。
- 出力に該当行が無い項目は `SKIP` + 「出力に該当行が見つかりません」と表示（推測で埋めない）。

実測（worktree）: `--dry-run` で `git_state=NG`（未コミット変更）、`readme=OK`、`gitignore=OK`、
`test/lint/build=SKIP`（dry-run のため）。画面にも同じ内容が表示された。
