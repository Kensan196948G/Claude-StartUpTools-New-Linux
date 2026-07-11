# Claude モデルルーティング

## 目的

Opus 4.8 と Sonnet 5 を、品質優先のタスク分類と利用量バランスで自動的に使い分けます。
既定モデルは **Sonnet 5 + effort `max`**（通常タスクの既定ルート。利用量差が閾値を超えた場合は
5% バランス機構により低利用モデルへ切り替わることがあります）。

| 用途 | モデル | effort |
|---|---|---|
| 設計判断、アーキテクチャ、重大バグ、Security、PR最終レビュー | `claude-opus-4-8` | `xhigh` |
| 通常実装、テスト修正、軽微なリファクタ、ドキュメント（既定） | `claude-sonnet-5` | `max` |

Sonnet 5 は 1M context 対応（2026-08-31 まで $2/$10 per Mtok のプロモ価格）。

## 5% バランス

`~/.claudeos/model-usage.jsonl` にセッション開始時の選択結果を追記します。

利用比率差が `5%` 以上になった場合、次回起動では利用が少ないモデルを選びます。

例:

- Opus 52.5% / Sonnet 47.5% 以上の差 → Sonnet へ寄せる
- Sonnet 52.5% / Opus 47.5% 以上の差 → Opus へ寄せる

高リスクタスクは品質優先で Opus を既定にしますが、明示指定がある場合はそちらを優先します。

## 設定

`config/config.json` の `modelRouter` が既定です。

```json
{
  "modelRouter": {
    "enabled": true,
    "balanceThresholdPct": 5,
    "usageFile": "~/.claudeos/model-usage.jsonl",
    "models": {
      "opus": { "id": "claude-opus-4-8", "effort": "xhigh" },
      "sonnet": { "id": "claude-sonnet-5", "effort": "max" }
    }
  }
}
```

環境変数で一時上書きできます。

| 環境変数 | 内容 |
|---|---|
| `CLAUDEOS_MODEL_ROUTER=0` | 自動モデル指定を無効化 |
| `CLAUDEOS_MODEL_KEY=opus` / `sonnet` | 強制モデル指定 |
| `CLAUDEOS_MODEL_TASK=security` | タスク分類を明示 |
| `CLAUDEOS_MODEL_BALANCE_THRESHOLD_PCT=5` | 切替閾値 |
| `CLAUDEOS_MODEL_USAGE_FILE=/path/file.jsonl` | 利用台帳パス |
| `CLAUDEOS_OPUS_MODEL` / `CLAUDEOS_OPUS_EFFORT` | Opus 側上書き |
| `CLAUDEOS_SONNET_MODEL` / `CLAUDEOS_SONNET_EFFORT` | Sonnet 側上書き |

## 確認

dry-run で次回選択を確認できます。

```bash
bash bin/start-claude.sh --project <ProjectName> --background --duration 1 --dry-run
bash bin/autonomy.sh start <ProjectName> --duration 1 --dry-run
bash scripts/tools/launch-parallel-cron.sh <ProjectName> --roles cto,qa --dry-run
```

出力に `model` / `effort` / `model_reason` が表示されます。
