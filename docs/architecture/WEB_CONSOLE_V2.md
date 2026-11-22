# 統合コンソール（Web コンソール v2）運用ガイド

ClaudeOS の起動・監視・運用を 1 画面に集約した Web UI。設計成果物（単一 HTML）を基に、
**全 13 画面を実 API へ接続**している。実行できない操作は「未接続」と明示し、
成功したように見せない方針。

## 1. 配信と認証

| 項目 | 内容 |
|---|---|
| 配信 | `scripts/web/startup-server.js`（systemd --user `claudeos-web-startup`、127.0.0.1:3740） |
| ルート | `/` → `public/v2.html`（統合コンソール）。旧コンソールは `/index.html` |
| 公開 | Cloudflare Tunnel → 同ホスト loopback。入口は Cloudflare Access（email 1 件 allow + catch-all deny） |
| 端末 | `/terminal` → ttyd（127.0.0.1:3741）。Access が同一 hostname を保護 |
| ファイル | `public/v2.html` は `__bundler/template` に画面＋コンポーネントを持つ単一ファイル |

## 2. 画面別ガイド

| 画面 | データ源 | できること | 制約 |
|---|---|---|---|
| **起動** | `GET /api/startup/state`（`all_folders`） | プロジェクト選択 → 計画（`POST /api/startup/plan`）→ 起動（`/launch`、`confirm:true`） | 実起動は tmux セッションを作る |
| **セッション監視** | 同上 `sessions` | 稼働状況の表示、停止（`/api/startup/stop`） | — |
| **Supervisor 全適用** | `POST /api/startup/apply-all`（confirm 無し） | **計画のみ**取得 | 実適用は画面から不可（CLI で人間が実行） |
| **Cron** | `GET /api/ops/cron` | crontab の一覧表示 | スナップショット経由。追加/削除/run-now は未接続 |
| **Systemd** | `GET /api/ops/systemd` | unit の状態・有効化状態・ExecStart 表示 | 起動/停止等は未接続（読み取り専用） |
| **Agent Teams** | `GET /api/ops/agents` | 使用状況 JSON の表示 | history/diag/migrate は未接続 |
| **SubAgent** | `GET /api/ops/agent-catalog` | カタログ KPI・一覧・統合・削除候補の表示 | 昇格/降格・Issue 化は未接続 |
| **Managed Agents** | `GET /api/ops/managed-agents` | roster/registry/台帳・当月使用量 | 設定が無ければ「未設定」。依頼送信は未接続 |
| **診断・ツール** | `GET /api/ops/diag?name=` | 診断スクリプト 9 本の実行と出力表示 | allowlist 外は不可。未対応メニューは未接続 |
| **品質ワークベンチ** | `POST/GET /api/ops/release-check` | release-check をジョブ実行し結果を反映 | 実チェックは数分。ジョブは同時 1 本 |
| **DevOps** | `GET /api/ops/devops` | git HEAD / timer 数 / DB 数 の現状値 | 配備・再起動・DB 変更は未接続 |
| **SecOps** | `GET /api/ops/secops` | ツール有無（gitleaks 等）の確認 | スキャン実行は未接続 |
| **監査ログ** | `GET /api/startup/audit` | 変更系操作の監査ログ表示 | — |

## 3. API 一覧（読み取り専用を含む）

```
GET  /api/health
GET  /api/startup/state            POST /api/startup/plan | launch | stop | apply-all
GET  /api/startup/log | /audit
GET  /api/ops/systemd | cron | agents | agent-catalog | managed-agents
GET  /api/ops/diag?name=<key>       (allowlist: all-tools, mounts, mcp-health, agent-teams,
                                     worktree, architecture, claude-compat, postgres, control-plane*)
POST /api/ops/release-check/start   GET /api/ops/release-check
GET  /api/ops/devops | secops
```

`/api/startup/state` は 20 秒 TTL のキャッシュを持つ（`STARTUP_STATE_CACHE_MS`）。
起動・停止・計画・全適用の直後に無効化する。実測 cold 3.5–10 秒 / warm 0.004 秒。

## 4. Cron スナップショット方式

`claudeos-web-startup.service` は `NoNewPrivileges=yes` のため `crontab` の setgid 昇格ができず、
サービス文脈の `crontab -l` は失敗する。硬化を弱めずに実データを出すため、
**ユーザー文脈のタイマーがスナップショットを書き、API がそれを読む**。

| 要素 | 役割 |
|---|---|
| `bin/cron-snapshot.sh` | `crontab -l` を解析 → `$CLAUDEOS_HOME/cron-snapshot.json` |
| `config/systemd/user/claude-startuptools-cron-snapshot.{service,timer}` | 5 分ごとに更新（この unit のみ `NoNewPrivileges=no`、`PrivateTmp` 不可） |

> **注意**: スナップショット unit に `PrivateTmp=yes` を付けると `crontab -l` が**無言で 0 行**を返す
> （サービスは成功扱い）。実測で切り分け済み。

有効化:
```bash
cp config/systemd/user/claude-startuptools-cron-snapshot.* ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now claude-startuptools-cron-snapshot.timer
```

## 5. 自動検証（Playwright）

```
npm run test:e2e:console          # 既定 http://127.0.0.1:3740
CONSOLE_URL=<url> node scripts/e2e/console.e2e.js
```

- 画面ごとに **API の実値と DOM を突き合わせる**（件数・unit・KPI・台帳件数・計画の契約）
- 取得前は「取得中…」を表示し、実データが届くと件数へ切り替わる（設計サンプルの名前は表示しない）。E2E は **API 件数と一致するまで待つ**
- スクリーンショットと `result.json` を `reports/e2e/<timestamp>/` に保存（git 管理外）
- 14 項目。CI では `e2e-console` ジョブが同じ検査を実行する（`E2E_ALLOW_EMPTY=1`）

## 6. 既知の制約・未達

| 項目 | 状態 |
|---|---|
| 品質チェックの実行 | ジョブ化済み。実チェックは数分かかる |
| DevOps / SecOps の実行系 | 未接続（有無・現状値のみ） |
| Cron の追加・削除・run-now | 未接続（読み取り専用）。配線の設計案: `WEB_MUTATING_OPS_DESIGN.md` |
| state の cold 短縮 | **未達**。主コストは 190 プロジェクト分の `_project_json`（1 件あたり十数回の jq）。1 秒台には一括化が必要 |
| `_all_folders` の `find` 化 | 撤回。symlink 配下の欠落・隠しディレクトリ配下の混入で一覧の意味が変わる |
| 実セッションの起動・停止 E2E | 未実施（計画 = dry-run までを検証） |

## ログアウト（2026-11-21 追加）

ヘッダー右上（テーマ切替の隣）に「ログアウト」ボタンがある。Cloudflare Access の
セッションを終了させる。

- 遷移先: `<アプリ側ドメイン>/cdn-cgi/access/logout?returnTo=<絶対 URL を URL エンコード>`
- **チームドメイン（`*.cloudflareaccess.com`）ではなくアプリ側ドメインを使う**。
  チームドメインだとブラウザにそのドメインの Cookie が無く `No Access cookie found` になる。
- `returnTo` は**絶対 URL** をエンコードして渡す。相対（`/`）だと実測で **400**、絶対だと **302**。
- ループバック（127.0.0.1 / localhost）では Access を使っていないため遷移せず、
  「ログアウトは不要」と通知する（存在しないパスへ飛ばさない）。

実測: `GET /cdn-cgi/access/logout?returnTo=%2F` → 400、
`?returnTo=https%3A%2F%2F<host>%2F` → 302。

## 総合 E2E（16 項目）と、実セッション E2E の未達理由

`npm run test:e2e:console` は 16 項目を検査する（品質ワークベンチを含む）。
ライブ `http://127.0.0.1:3740` で **16/16 PASS**。

### 実セッション起動→停止の E2E は未達（調査結果）

隔離環境（一時 projectsDir / config / HOME / fake claude）で通しの検証を試みたが、次の 2 点で成立しなかった。

1. **background（supervisor）モードが隔離環境で起動しない**
   `start-claude.sh` は `cron-launcher.sh` を `$CCSU_HOME` へ配備するが、参照は `$HOME/.claudeos/cron-launcher.sh`。
   両者が一致しないと `cron-launcher.sh が見つかりません` で supervisor 起動に失敗する。
2. **foreground + fake claude では tmux セッションが残らない**
   起動前に `claude --help` によるケイパビリティ探索が走り、fake claude では
   「起動した」表示の直後にセッションが消える。実バイナリを要する。

→ 実セッションの通し E2E には、(a) 上記パス不整合の修正、または
(b) `$HOME/.claudeos` を隔離できる仕組み（`CLAUDEOS_HOME` の完全統一）が必要。
停止 API は `state.projects[].running`（supervisor 由来）を要求するため、
background が動かない限り停止の通し検証もできない。

## 隔離セッション E2E と、パス統一の修正（2026-11-21 追加）

### 修正した実装不整合

`start-claude.sh` は `cron-launcher.sh` を **`$CCSU_HOME`** へ配備するが、参照側は
**`$HOME/.claudeos` 固定**だった。隔離環境（`CCSU_HOME` を変える）では
「配備したのに見つからない」となり supervisor 起動が失敗していた。

参照を `${CCSU_HOME:-$HOME/.claudeos}/cron-launcher.sh` に統一した（3 箇所）:

| ファイル | 変数 |
|---|---|
| `lib/supervisor.sh` | `SUP_CRON_LAUNCHER` |
| `bin/cron-schedule.sh` | `CRON_LAUNCHER` |
| `lib/cron-manager.sh` | `CRON_LAUNCHER_PATH` |

これにより**隔離環境でも background（supervisor）起動が成立**するようになった（実測）。

### 残る不具合: 停止 API が supervisor セッションを止められない

`scripts/e2e/session-start-stop.e2e.sh` で通し検証すると、起動は成功し
supervisor JSON も `status=running` になるが、次の 2 点で停止できない。

- `state.projects[].running` は `launcher__project_run_status` の結果で、
  **supervisor の pid が生きていること**を要求する。tmux セッションが生きていても
  supervisor プロセスが抜けていると `running=false` になる。
- 停止 API は `running=true` を前提にしているため、この状態では **409 NOT_RUNNING** を返す。

→ 修正の第 1 段として次を入れた:
- `state.projects[].running` を「supervisor status が running」**または「tmux セッションが実在」**で true にした
- `autonomy.sh stop` は supervisor が無くても tmux セッションがあれば停止する

ただし隔離環境（fake claude / headless）では tmux セッションが作られないため、
`session-start-stop.e2e.sh` は依然 `running` の検査で FAIL する。
残る論点は「supervisor が status=running を書いた直後に pid が生存していない」ケースで、
supervisor のプロセスモデル側の調査が必要。テストは検出器として残している。

## supervisor のプロジェクト解決（調査結果 2026-11-21）

隔離環境で `autonomy.sh start <p>` を実行すると、supervisor は起動するが
セッションが即終了し、`running` が false になる。実測ログ:

```
ℹ️ [supervisor] 🚀 start: p1 @ ...
❌ プロジェクトディレクトリが存在しません: /tmp/p1d/home/Projects/p1
   (実際のプロジェクトは /tmp/p1d/projects/p1、config の .projects で指定)
```

| 観点 | 実測 |
|---|---|
| supervisor JSON | `status=running` / `pid=$$`（setsid 本体。値は正しい） |
| pid 生存 | 起動直後は生存、数秒後に消える |
| 原因 | supervisor 経由のプロジェクト解決が **`$HOME/Projects` へフォールバック**し、`config` の `.projects` を使っていない |
| 結果 | ディレクトリ不在 → セッション 0 秒終了 → supervisor が再試行/終了 → `running=false` |

つまり「状態管理（state / 停止 API）」ではなく **supervisor 側のパス解決**の問題で、
`AI_STARTUP_CONFIG_PATH` で config を差し替えた環境では supervisor が正しいプロジェクトを見つけられない。

→ 修正方針: supervisor（`sup__loop` / `start-claude.sh` / `supman__apply` の呼び出し連鎖）が
`launcher__project_dir` ではなく `$HOME/Projects` 既定値で解決している箇所を特定し、
`config_projects_dir` に統一する。既定環境（`$HOME/Projects` が実在）では表面化しない。
