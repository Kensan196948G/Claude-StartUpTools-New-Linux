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
- 初期描画は設計サンプル（22 件）のことがあるため、**API 件数と一致するまで待つ**
- スクリーンショットと `result.json` を `reports/e2e/<timestamp>/` に保存（git 管理外）
- 14 項目。CI では `e2e-console` ジョブが同じ検査を実行する（`E2E_ALLOW_EMPTY=1`）

## 6. 既知の制約・未達

| 項目 | 状態 |
|---|---|
| 品質チェックの実行 | ジョブ化済み。実チェックは数分かかる |
| DevOps / SecOps の実行系 | 未接続（有無・現状値のみ） |
| Cron の追加・削除・run-now | 未接続（読み取り専用） |
| state の cold 短縮 | **未達**。主コストは 190 プロジェクト分の `_project_json`（1 件あたり十数回の jq）。1 秒台には一括化が必要 |
| `_all_folders` の `find` 化 | 撤回。symlink 配下の欠落・隠しディレクトリ配下の混入で一覧の意味が変わる |
| 実セッションの起動・停止 E2E | 未実施（計画 = dry-run までを検証） |
