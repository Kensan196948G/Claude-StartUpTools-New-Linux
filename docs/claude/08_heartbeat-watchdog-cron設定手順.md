# heartbeat-watchdog cron 設定手順

## 概要

`heartbeat-watchdog.js` は **沈黙 type3**（SIGKILL / OOM Kill / サーバー再起動による Claude Code プロセス消滅）を検知する外部監視スクリプトです。
外部 cron から定期実行することで、Claude Code が無音で死んでいる状態を検出して Webhook 通知を送ります。

### 沈黙 3 類型と担当フック

| 種別 | 発生原因 | 担当フック | 通知イベント |
|------|---------|-----------|------------|
| type1 | API エラー・ツール失敗 | `stop-failure-gate.js` | `api_failure` |
| type2 | 入力待ち沈黙（ツール許可 / 次プロンプト） | `notification-gate.js` | `input_waiting` |
| **type3** | **プロセス消滅（SIGKILL / OOM / 再起動）** | **`heartbeat-watchdog.js`** | **`api_failure`** |

Claude Code が SIGKILL で死ぬとフックが発火しないため、type3 だけは **外部 cron** で監視する必要があります。

---

## 仕組み（3 ファイル構成）

```
SessionStart
  └─ heartbeat-writer.js (SessionStart フック)
       └─ detached spawn
            └─ heartbeat-daemon.js (常駐デーモン)
                  │
                  │ 60 秒ごとに更新
                  ▼
             heartbeat.json
                  │
            (cron で 5 分ごとに確認)
                  ▼
         heartbeat-watchdog.js (外部 cron)
                  │
                  │ last_beat が閾値以上古ければ
                  ▼
         webhook-notifier.js → Teams / HTTPS / Slack
```

| ファイル | 場所 | 役割 |
|---------|------|------|
| `heartbeat-writer.js` | `.claude/claudeos/scripts/hooks/` | SessionStart フック。daemon を起動 |
| `heartbeat-daemon.js` | `.claude/claudeos/scripts/hooks/` | 常駐デーモン。60s ごとに `heartbeat.json` を更新 |
| `heartbeat-watchdog.js` | `.claude/claudeos/scripts/hooks/` | 外部 cron から実行。更新停止を検知して通知 |
| `heartbeat.json` | プロジェクトルート | daemon が書く状態ファイル |

---

## step 1: state.json の webhook 設定

プロジェクトルートの `state.json` に `webhook` セクションを追加します。

```json
{
  "webhook": {
    "enabled": true,
    "events": {
      "stable_achieved": true,
      "session_end": true,
      "ci_blocked": true,
      "api_failure": true,
      "input_waiting": true
    }
  }
}
```

> **注意**: `events.api_failure` が `true` でないと heartbeat watchdog の通知は送信されません（二重ゲート設計）。

---

## step 2: 環境変数の設定

通知先 URL は **環境変数のみ** で管理します。`state.json` や Git には絶対に書かないでください。

### Teams Incoming Webhook

```bash
# ~/.bashrc または ~/.zshrc に追加
export TEAMS_WEBHOOK_URL="https://xxxxx.webhook.office.com/webhookb2/..."
```

### 汎用 HTTPS エンドポイント

```bash
export HTTPS_WEBHOOK_URL="https://your-endpoint.example.com/webhook"
export HTTPS_WEBHOOK_SECRET="your-hmac-secret"  # 任意
```

### Slack（将来対応）

```bash
export SLACK_WEBHOOK_URL="https://hooks.slack.com/services/..."
```

| 環境変数 | 必須 | 説明 |
|---------|------|------|
| `TEAMS_WEBHOOK_URL` | ⬜ | Teams Incoming Webhook URL |
| `HTTPS_WEBHOOK_URL` | ⬜ | 汎用 HTTPS エンドポイント URL |
| `HTTPS_WEBHOOK_SECRET` | ⬜ | HMAC-256 署名シークレット（任意） |
| `HEARTBEAT_STALE_SEC` | ⬜ | 失活判定秒数（デフォルト: **300** = 5 分） |

---

## step 3: cron 登録

### 推奨設定（5 分ごとに実行）

```bash
crontab -e
```

```cron
# heartbeat watchdog — 5 分ごとに Claude Code プロセス消滅を検知
*/5 * * * * cd /home/kensan/Projects/YOUR_PROJECT && \
  TEAMS_WEBHOOK_URL="$TEAMS_WEBHOOK_URL" \
  node .claude/claudeos/scripts/hooks/heartbeat-watchdog.js \
  >> ~/.claudeos/logs/heartbeat-watchdog-YOUR_PROJECT.log 2>&1
```

> **cron 間隔の目安**:
> - daemon は 60 秒ごとに更新するため、5 分（300s）間隔が妥当
> - `HEARTBEAT_STALE_SEC` デフォルト（300s）と cron 間隔を揃えることで、1 回の見逃しがアラートになる
> - 厳密にしたい場合は `HEARTBEAT_STALE_SEC=180` + cron `*/3` に変更

### ログディレクトリの作成

```bash
mkdir -p ~/.claudeos/logs
```

---

## step 4: 動作確認（CLI テスト）

### 4-1. 正常動作確認（新鮮なハートビート）

```bash
cd /home/kensan/Projects/YOUR_PROJECT

# daemon を手動起動してハートビートを書かせる
node .claude/claudeos/scripts/hooks/heartbeat-writer.js < /dev/null

# heartbeat.json が作成されていることを確認
cat heartbeat.json
# → { "session_id": null, "daemon_pid": <PID>, "last_beat": "<now>", ... }

# watchdog を手動実行 → "fresh" と出ればOK
node .claude/claudeos/scripts/hooks/heartbeat-watchdog.js
# → [HeartbeatWatchdog] heartbeat fresh (elapsed=Xs threshold=300s)
```

### 4-2. 失活検知確認（ヘルメチックテスト）

実ネットワークに出さずに通知経路だけ確認する方法:

```bash
cd /tmp/hb-test && mkdir -p .
echo '{"last_beat":"2000-01-01T00:00:00.000Z","session_id":"test"}' > heartbeat.json
echo '{"webhook":{"enabled":true,"events":{"api_failure":true}}}' > state.json

HEARTBEAT_STALE_SEC=1 \
HTTPS_WEBHOOK_URL="https://127.0.0.1:1/x" \
node /home/kensan/Projects/YOUR_PROJECT/.claude/claudeos/scripts/hooks/heartbeat-watchdog.js

# 期待出力:
# [HeartbeatWatchdog] heartbeat STALE (elapsed=Xs ...) — notifying
# [Webhook] 送信エラー: HTTPS: connect ECONNREFUSED 127.0.0.1:1
```

`ECONNREFUSED` が出れば「通知経路まで到達しているが実エンドポイントがない」= 正常動作。

### 4-3. 自動テスト

```bash
npx bats tests/bats/unit/heartbeat-watchdog.bats
# 9/9 pass を確認
```

---

## 通知ペイロード例

api_failure イベントとして以下が送信されます:

```json
{
  "event": "api_failure",
  "source": "claudeos-v9",
  "data": {
    "reason": "heartbeat_stale",
    "elapsed_sec": 720,
    "threshold_sec": 300,
    "session_id": "abc123",
    "daemon_pid": 12345,
    "last_beat": "2026-06-13T10:00:00.000Z",
    "beat_count": 42
  }
}
```

---

## トラブルシューティング

| 症状 | 原因 | 対処 |
|------|------|------|
| `heartbeat.json not found` | Claude Code が一度も起動していない | `heartbeat-writer.js` を手動実行して確認 |
| 通知が来ない（STALE にならない） | `HEARTBEAT_STALE_SEC` が大きすぎる | 値を小さくして再テスト |
| 通知が来ない（STALE になっている） | `state.json` の `api_failure` が `false` | `events.api_failure: true` を確認 |
| ECONNREFUSED 以外のエラー | 通知 URL が無効 | 環境変数の URL を確認 |
| daemon が起動しない | `heartbeat-writer.js` がフック登録されていない | `settings.json` の SessionStart を確認 |

---

## 参照

- 実装: `Claude/templates/claudeos/scripts/hooks/heartbeat-{daemon,writer,watchdog}.js`
- テスト: `tests/bats/unit/heartbeat-watchdog.bats`
- 関連フック: `stop-failure-gate.js`（type1）/ `notification-gate.js`（type2）
- GitHub Issue: #6 (要件定義) / #8 (このドキュメント)
