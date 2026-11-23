# Web コンソール: 変更系操作（Cron / Systemd / SubAgent）の配線設計

状態: **段階 1 を実装済み**（`POST /api/ops/plan`: `cron add` と `systemd` 5 操作の dry-run 計画のみ。実データは変更しない）。**段階 2 は `Systemd restart` のみ実装**（`POST /api/ops/systemd/restart`。Approval PR。既定は無効）。`Cron run-now` は §9 の理由で保留。段階 3 は未実装で、方式と承認の段階を決めるための設計案です。`cron run-now` は、サービスが crontab を読めず「未登録」と誤報し得るため、段階 1 から外しています（方式 B の導入後）。

## 1. 背景と目的

Web コンソールの Cron・Systemd・SubAgent 画面は、現在すべて**読み取り専用**です（`GET /api/ops/*` のみ。操作ボタンは「未接続」と表示します）。
`docs/architecture/WEB_CONSOLE_V2.md` §2 のとおり、CLI（`bin/cron-schedule.sh`・`bin/systemd-control.sh`・`bin/seed-agent-catalog.sh`）には対応する操作が既にあります。
目的は、これらの操作を**安全に**画面から実行できるようにすることです。ただし、本番ホストの実データ（crontab・systemd unit・台帳）を変更するため、
組織方針 §5 の「公開範囲・認証/認可モデル」に関わる変更として **Approval PR** の対象です。

## 2. 現状と制約（実測・コード確認済み）

| 項目 | 事実 | 影響 |
|---|---|---|
| Web サービスの sandbox | `claudeos-web-startup.service` は `NoNewPrivileges=yes`・`PrivateTmp=yes` | `crontab` は setgid 昇格が必要で、**サービスからは読み書きできない**。読み取りは、ユーザー文脈のタイマー（`claude-startuptools-cron-snapshot`）がスナップショットを書く方式で回避済み |
| `systemctl --user` | サービスから一覧取得（読み取り）は動作している | 起動・停止などの書き込みも同じ経路で可能とみられる（**未検証**。実装前に検証が必要） |
| CLI | `cron-schedule.sh add/remove/run-now`、`systemd-control.sh start/stop/restart/enable/disable/register/unregister`、`seed-agent-catalog.sh` が既にある。いずれも `--dry-run` を持つ | 新しい操作ロジックを作らず、**CLI を allowlist で呼ぶ**のが最小の変更 |
| 既存の変更系 API | `launch` / `stop` / `apply-all`。確認 2 段階（`confirm:true`）・Host 検査・監査ログ・同時 1 件（`busy`）がある（#161 で共通検査を追加） | 同じ型（plan → confirm → 実行）に揃える |
| 認証 | Basic か Cloudflare Access（JWT 検証はプロンプト送信のみ） | 変更系の認証方式は別途決める（§5） |

## 3. 方式の比較

- **A. Web サービスから CLI を直接実行する**
  - 長所: 実装が最小。`launch` / `stop` と同じ型。
  - 短所: `crontab` は `NoNewPrivileges=yes` のため**動かない**。サンドボックスを緩めると、公開サービス全体の権限が広がる（却下）。
  - 適用: `systemctl --user`（検証が通れば）と `seed-agent-catalog.sh` のように、特権昇格が要らない操作。
- **B. リクエスト・キュー + ユーザー文脈の実行器（推奨）**
  - 仕組み: Web サービスは検証済みの要求（JSON）を `~/.claudeos/ops-requests/` へ書くだけにする。ユーザー文脈の systemd path unit（`NoNewPrivileges=no`）が、
    それを読み、**allowlist の操作だけ**を CLI 経由で実行して結果を `ops-results/` へ書く。Web は結果を読む。
  - 長所: Web サービスの権限を緩めずに `crontab` を扱える。既存のスナップショット方式（ユーザー文脈で動く unit）と同じ設計思想。要求と結果が**監査可能なファイル**として残る。
  - 短所: 実行器という新しい部品が増える。結果の取得が非同期になる（画面は「処理中」を表示してポーリング）。要求ファイルの改ざん対策（所有者・権限・署名）が要る。
- **C. 読み取り専用を維持し、「実行コマンドのコピー」だけ提供する**
  - 長所: 新しい攻撃面がゼロ。
  - 短所: 画面から実行できない（目的を満たさない）。ただし、**第 1 段階の安全な暫定策**として有効（コマンド生成と dry-run 結果の表示までは Web で行う）。

**推奨**: 操作ごとに分ける。`crontab` の変更は B、特権昇格が不要な操作は A（検証後）。いずれも先に **C の段階（dry-run の計画表示）を出す**。

## 4. 操作ごとのリスクと扱い

| 画面 | 操作 | 変更の対象 | 可逆性 | 推奨方式 | 段階 |
|---|---|---|---|---|---|
| Cron | 一覧・計画（dry-run） | なし | — | 既存 GET + 計画表示 | 1 |
| Cron | 今すぐ実行（run-now） | 登録済みの cron 行を即時 1 回起動 | 起動した作業は停止可能 | B（`cron-schedule.sh run-now`） | 2 |
| Cron | 有効 / 無効（コメント化） | crontab の 1 行 | 可逆（再有効化） | B | 2 |
| Cron | 新規登録 / 削除 | crontab の追加・削除 | 削除は**バックアップから復元**のみ | B + 事前に crontab 全体をバックアップ | 3 |
| Systemd | 状態・ログ表示 | なし | — | 既存 GET | 1 |
| Systemd | start / stop / restart | 登録プロジェクトの unit | 可逆 | A（要・事前検証） | 2 |
| Systemd | enable / disable / register / unregister | unit ファイルと台帳 | `unregister` は unit を削除（再生成可能） | A または B | 3 |
| SubAgent | seed（カタログ生成） | `config/agent-catalog.json` | Git で復元可能 | A | 2 |
| SubAgent | 昇格・降格・Issue 化 | 台帳 / GitHub Issue | Issue は外部公開 | B + 別承認 | 3 |

段階の意味: **1** = 読み取り + dry-run 計画の表示（実データ変更なし）／ **2** = 可逆で影響の小さい操作 ／ **3** = 削除・登録・外部公開を伴う操作。

## 5. 共通のガード要件（全操作）

1. **plan → confirm の 2 段階**（既存と同じ。`confirm:true` が無ければ計画だけを返す）。計画は CLI の `--dry-run` の出力をそのまま表示する。
2. **allowlist**: 操作名と引数を固定の定義から検証する。シェル文字列は組み立てない（`execFile` + 引数配列）。プロジェクト名は登録済みの allowlist（既存の `validateProject`）。
3. **認証と Host 検査**: #161 の `checkMutationRequest`（Host 許可リスト・JSON のみ・Sec-Fetch-Site）を必須にする。変更系は **Cloudflare Access の JWT 検証も必須**にする案を推奨（プロンプト送信と同等）。
4. **同時 1 件**（`busy`）と**日次の上限**（プロンプト送信と同じ考え方。`crontab` の変更は 1 日 N 回まで）。
5. **事前バックアップと復旧手順**: `crontab` は変更前に全体を `~/.claudeos/backups/crontab-<時刻>` へ保存し、結果に復元コマンドを含める。
6. **監査ログ**: 要求の主体・操作・対象・引数のハッシュ・結果を記録する（秘密は記録しない）。
7. **Web 会話・自律実行との排他**: 対象プロジェクトで Web 会話が動いている間は、起動系の操作を拒否する（`launch` と同じ）。
8. **既定は無効**: 操作ごとの環境変数（例: `STARTUP_WEB_OPS_ENABLE=cron-run-now,systemd-restart`）で**明示した操作だけ**を有効にする。未設定なら今までどおり読み取り専用。

## 6. 方式 B の詳細（案）

- **要求**: `~/.claudeos/ops-requests/<id>.json`（所有者のみ読み書き `0600`、ディレクトリ `0700`）。内容は `{ id, op, args, requestedBy, requestedAt, planHash }`。
- **実行器**: ユーザー文脈の systemd path unit が `ops-requests/` を監視し、`bin/ops-executor.sh`（新規）を起動する。実行器は次を行う。
  1. 要求を **allowlist と再検証**する（Web 側の検証を信用しない）。
  2. 要求の `planHash` が、実行器で再計算した dry-run の結果と一致するか確認する（確認画面で見せた計画と**実際に実行する内容が同じ**であることの保証）。
  3. CLI を実行し、結果（終了コード・出力の先頭・復元コマンド）を `ops-results/<id>.json` に書く。要求ファイルは `ops-done/` へ移す。
  4. 古い要求（例: 5 分超）は実行せずに破棄する（再生攻撃・古い確認の実行を避ける）。
- **Web**: 結果ファイルを読み、画面は「処理中 → 完了 / 失敗」を表示する。

## 7. テスト計画

- 単体（node --test）: 操作 allowlist の検証、引数の検証、plan/confirm の分岐、無効時の拒否、認証・Host 検査、日次上限。
- 結合（bats）: `ops-executor.sh` が **隔離した `CCSU_HOME` と偽の crontab コマンド**で、allowlist 外・古い要求・planHash 不一致を拒否すること。
- 実機（隔離環境のみ）: 偽の crontab / 一時ユーザー unit で、要求 → 実行 → 結果の往復。**本番の crontab・unit は、承認後の段階 2 以降まで触らない。**

## 8. 段階的な導入と承認

1. **段階 1（通常 PR）**: Cron / Systemd / SubAgent の **dry-run 計画の表示**を画面に追加（`POST /api/ops/<x>/plan`。実データ変更なし）。「実行は未接続」の表示は維持。
2. **段階 2（Approval PR）**: 可逆な操作（Cron の run-now / 有効無効、Systemd の start / stop / restart、SubAgent の seed）。方式 B の実行器を導入。
3. **段階 3（Approval PR）**: 削除・登録・外部公開を伴う操作。**crontab の事前バックアップと復元手順の実証**を受け入れ条件にする。

## 9. 決定事項（2026-11-23、ユーザーの番号選択による）

| 項目 | 決定 |
| --- | --- |
| 変更系の認証 | **Cloudflare Access の JWT 必須**（プロンプト送信と同じ強さ。Basic のみでは実行しない） |
| 段階 2 の対象 | **`Cron run-now` と `Systemd restart` の 2 つに絞って始める**（他は段階 3 以降） |
| 日次上限の既定値 | **1 日 20 件**（環境変数で変更可。超過は翌日まで拒否） |
| `systemctl --user` の書き込み | 下記の事前検証で**認可される**ことを確認 |

### 事前検証: `systemctl --user` の書き込み権限（サービスと同じ制限下）

サービス unit と同じ `NoNewPrivileges=yes` / `PrivateTmp=yes` を付けた一時 unit（`systemd-run --user`）から、存在しない unit への `stop` を実行した。結果は `Unit ... not loaded`（exit 5）で、`Access denied` ではない。ユーザーバスへの書き込み系の要求は、この制限下でも認可される。実在する unit の変更は行っていない。

- 含意: `Systemd restart` は、方式 B の実行器（user 文脈）を経由しなくても、サービスから直接実行できる見込み。ただし実在 unit での確認は、段階 2 の実装 PR（Approval PR）の受け入れ条件として別途行う。
- `crontab` は setgid のため引き続き使えない。

### `Cron run-now` の保留（実装前調査の結果）

- ~~スナップショットが台帳印を捨てる~~ → **解消済み**: `bin/cron-snapshot.sh` は、台帳印（`# CLAUDEOS:<id> project=… duration=…`）の直後の cron 行に `claudeos: {id, project, duration, created, goal}` を付ける。印が効くのは直後の 1 行だけ（`cron__list` と同じ対応）で、他用途の行・他の接頭辞（`OPENCODE` 等）・project/duration が読めない印には付けない。スナップショットは 5 分ごとに更新されるため、実行側は `generated_at` が約 10 分（2 周期）より古ければ拒否する。
- 現在の crontab に ClaudeOS 管理のエントリは 0 件（他用途の生コマンドのみ）。実機で確認できる対象がない。
- **crontab の生コマンドは実行しない**（`rm` など ClaudeOS 管理外のコマンドを含み得る）。実装するなら、スナップショットに ClaudeOS の印・プロジェクト名・実行時間を残す拡張（通常 PR）を先に行い、台帳印のあるエントリだけを対象とし、実行は既存の BG 起動経路を再利用する。スナップショットの鮮度（`generated_at`）も検査する。
- 認証が弱かった既存の `POST /api/startup/launch`（と `apply-all`）は、`STARTUP_WEB_LAUNCH_REQUIRE_JWT=1` で実起動に Access JWT を要求できるようにした（既定は無効。運用者が有効化するまで従来どおり）。詳細は `WEB_SESSION_PROMPT.md` の環境変数表。

### 段階 2（`Systemd restart`）の実装内容

| 項目 | 内容 |
| --- | --- |
| API | `POST /api/ops/systemd/restart`（`{ project, confirm: true }`） |
| 有効化 | `STARTUP_WEB_OPS_RESTART_ENABLE=1`（既定は無効。外して再起動すれば読み取り専用に戻る） |
| 認証 | **Cloudflare Access の JWT のみ**（`CF_ACCESS_TEAM_DOMAIN` / `CF_ACCESS_AUD`）。Basic では実行しない。未設定は `OPS_AUTH_NOT_CONFIGURED` で拒否 |
| 要求検査 | プロンプト送信と同じ強さ（Host 許可リスト・JSON のみ・Origin 必須かつ Host 一致・Sec-Fetch-Site） |
| 対象 | 許可リストのプロジェクト → `claudeos-<project>.service` のみ。`web-startup` / `cloudflared` / `tunnel` を含む名前は固定で拒否（自己ロックアウト防止） |
| 日次上限 | `STARTUP_WEB_OPS_DAILY_MAX`（既定 20）。専用の使用量ファイル `~/.claudeos/web-ops/usage-YYYY-MM-DD.json`（プロンプト送信と別。実行前に確保し、失敗も使用済み。破損は拒否） |
| 同時実行 | 1 件（`OPS_IN_PROGRESS` = 409） |
| 成否 | `systemd-control.sh restart` の終了コード（失敗は `RESTART_FAILED`。同スクリプトは失敗時に非 0 を返すよう修正） |
| 監査 | `ops-restart` / `ops-exec-rejected`（操作・対象・結果・JWT のメール） |
| UI | 「再起動」ボタン: 1 回目は計画を表示、30 秒以内の 2 回目（同じ unit）で実行。他の操作は計画のみ |

### 段階 2 に残る確認事項

- 認証・認可モデルの変更に当たるため、**Approval PR** で出す（head SHA 一致で明示の Y/N）。
- 実在する unit での `restart` の実機確認（検証用 unit を一時登録して行い、終了後に登録解除する）。

### 残存リスク（独立レビューで確認。いずれも Critical / High ではない）

- 実行は `bash systemd-control.sh` の子プロセスで、環境変数は絞って渡す（`opsChildEnv`）。タイムアウト時に kill されるのは bash のみで、孫の systemctl が残り得る（既存の `runScript` の制約。ロックは解放される）。
- 保護対象は名前の部分一致（`web-startup` / `cloudflared` / `tunnel`）のため、`tunnel` を含む正当な名前も拒否する（安全側の誤検知）。
- `ccsu_safe_name` が `/` 等を `_` にするため、別フォルダが同じ unit 名に写り得る（保護対象の回避にはならない）。
- 失敗時の stderr（最大 4000 文字）は認証済みの利用者へ返す。実行前の監査行は無い（実行後に結果を記録）。
- 監査ログに、操作・対象・結果・認証主体を残す。

## 10. ロールバック

各段階は PR 単位で revert できます。操作ごとの環境変数を外せば、再起動だけで読み取り専用に戻ります。方式 B の実行器は、path unit を無効化すれば停止します
（`systemctl --user disable --now <unit>`。`ops-requests/` の残骸は無害）。
