# Web スタートアップコンソール (Web Startup Console)

`bin/menu.sh` の起動メニュー (L1 / T1 / S1 / Supervisor 全適用 / セッション停止) を
ブラウザから操作するための Web 層。**ClaudeOS の判定・起動ロジックは再実装せず、
既存 CLI をそのまま呼ぶ薄いアダプタ**である (CLAUDE.md「Native 機能 > Thin Adapter > Custom」)。

## 1. 構成

| 層 | 実体 | 役割 |
|---|---|---|
| UI | `scripts/web/public/{index.html,app.js,styles.css}` | プロジェクト一覧・起動フォーム・計画表示・ログ閲覧 (依存ゼロの素の JS) |
| API | `scripts/web/startup-server.js` | HTTP + 入力検証 + Human Gate + 監査ログ (Node 組み込みのみ) |
| 状態 | `libexec/startup-state.sh` | 既存 lib を使った read-only な状態スナップショット (JSON 1 件) |
| 実行 | `bin/start-claude.sh` / `bin/autonomy.sh` | 起動・停止・全適用の唯一の実行正本 (変更なし) |
| 起動 | `bin/web-startup.sh` | サーバの start / stop / status (PID ファイル + health check) |

```
ブラウザ
  │  fetch /api/startup/*
  ▼
startup-server.js ──(検証: allowlist/mode/goal/duration/intent)──┐
  │                                                              │
  ├─ GET  state  → bash libexec/startup-state.sh   (read-only)   │
  ├─ POST plan   → bash bin/start-claude.sh ... --dry-run        │
  ├─ POST launch → bash bin/start-claude.sh ...        ← confirm 必須
  ├─ POST stop   → bash bin/autonomy.sh stop <project> [--now]   │
  └─ POST apply-all → dry-run 確認 → bash bin/autonomy.sh start --all --yes
                                                                 │
                            ~/.claudeos/logs/web-startup-audit.log ┘ (監査)
```

## 2. 起動と停止

```bash
# 起動 (既定: http://127.0.0.1:3740)
bash bin/web-startup.sh --start
bash bin/web-startup.sh --status
bash bin/web-startup.sh --stop
bash bin/web-startup.sh --start --dry-run        # 実行計画のみ

# 開発時 (実起動させない読み取り/計画専用モード)
npm run start:web:dry

# メニューから: WS = 起動 / WX = 停止
./start.sh
```

LAN へ公開する場合は Basic 認証が必須 (fail-closed)。

```bash
export STARTUP_WEB_PASSWORD='<secret>'   # DASHBOARD_PASSWORD でも可
bash bin/web-startup.sh --start --lan    # 0.0.0.0:3740
```

## 3. API

| メソッド | パス | 内容 |
|---|---|---|
| GET | `/api/health` | 死活 (認証免除) |
| GET | `/api/startup/state` | プロジェクト / セッション / Goal / limits / サーバ能力 |
| GET | `/api/startup/log?project=&lines=` | `~/.claudeos` 配下のログ末尾 |
| POST | `/api/startup/plan` | 起動計画 (`--dry-run`)。**実行しない** |
| POST | `/api/startup/launch` | `confirm:true` で実起動 (未確認なら計画を返す) |
| POST | `/api/startup/stop` | 停止。`confirm:true` 必須、`force:true` で `--now` |
| POST | `/api/startup/apply-all` | 全適用。1 回目は dry-run 計画、`confirm:true` で実適用 |

## 4. 安全設計 (Human Gate の実装)

| 統制 | 実装 |
|---|---|
| 任意コマンド実行の禁止 | 実行対象は `config` から列挙した既存プロジェクトの **allowlist 完全一致のみ**。`spawn(bash, [script, ...args])` でシェルを介さない |
| 注入対策 | プロジェクト名 (`-` 始まり / `..` / 改行・ヌル禁止)、mode / goal / duration を全数検証。intent は改行・制御文字除去 + 2000 文字上限 |
| 二段階実行 | 変更系 API は `confirm:true` が無ければ実体を実行せず、CLI の `--dry-run` 出力だけを返す。`--dry-run-only` 起動時は confirm があっても実行しない |
| 全適用 | AGENTS.md のとおり **必ず `--dry-run` で対象と skip 理由を確認**した後に `--yes`。実行時も内部で dry-run を先行実行する |
| 同時実行 | 変更改系は同時 1 件 (レースによる二重起動防止)。同時セッション上限は state に表示 |
| 認証 | `STARTUP_WEB_PASSWORD` 設定時は Basic 認証 (`crypto.timingSafeEqual`)。非ループバック bind はパスワード無しなら起動拒否 |
| CSRF | 変更系リクエストは `Origin` が自ホストと一致する場合のみ許可 |
| パス保護 | ログ閲覧は `~/.claudeos` 配下限定、静的配信は `scripts/web/public` 配下限定 (percent-encoding を復号して `..` を排除) |
| 監査 | 変更系操作を `~/.claudeos/logs/web-startup-audit.log` へ JSON Lines で記録 |
| 権限境界 | 本ツールは Claude Code の権限設定を一切変更しない (`--permission-mode` 等は CLI 側の既定に従う) |

## 5. 既知の制約

- **foreground (L1) はデスクトップ端末が必要**。Web サーバは TTY を持たないため、
  `DISPLAY` / `WAYLAND_DISPLAY` が無い環境では UI が foreground を選べなくする
  (tmux を使う `team` (T1) と Supervisor を使う `background` (S1) は常に利用可)。
- セッションへの**アタッチはブラウザからは行えない**。接続は
  `tmux attach -t claudeos-<project>` または `claude` 側のセッション一覧を使う (UI がコマンドを表示)。
- Web サーバは `menu.sh` と同じ PATH / 環境で動く。cron / systemd から起動する場合は
  `~/.env-claudeos` と `ANTHROPIC_API_KEY` 等の実行環境をサーバ側にも用意すること。

## 6. 検証

```bash
npm run test:node                        # 28 ケース (検証 / 引数契約 / HTTP 統合 / 認証 / Origin)
bats tests/bats/unit/web-startup.bats    # 起動スクリプト (dry-run・fail-closed)
bats tests/bats/unit/startup-state.bats  # 状態スナップショット (read-only 保証)
npm run lint                             # shellcheck
```

統合テストは一時 fixture (`bin/` `libexec/` の stub) を `--root` で差し替え、
実 HTTP で plan → launch (Human Gate) → stop / apply-all を通し、
**CLI に渡った実引数**まで検証する。
