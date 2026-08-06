# Claude モデルルーティング

## 目的

既定モデルは **Opus 5（`claude-opus-5`・Recommended）** です（2026-08-06 ユーザー指示）。
全タスクが Opus 5 ルートへ入り、タスクの高リスク度に応じて effort だけを 2 階層で
自動調整します。Sonnet 5 は明示 opt-in のみで使用します。

| 用途 | モデル | effort |
|---|---|---|
| 高リスク: 設計判断、アーキテクチャ、Security、Release/Deploy、重大バグ、PR最終レビュー | `claude-opus-5` | `xhigh` |
| 通常: 実装、テスト修正、リファクタ、ドキュメント（既定） | `claude-opus-5` | `high`（Opus 5 の recommended 既定） |
| 明示 opt-in（task に `sonnet` を含める / `CLAUDEOS_MODEL_KEY=sonnet`） | `claude-sonnet-5` | `max` |

Opus 5 の有効 effort は `low / medium / high / xhigh`（既定 `high`）。
Sonnet 5 は `max` まで対応（1M context・2026-08-31 まで $2/$10 per Mtok のプロモ価格）。

## 高リスクタスク判定

task 文字列（小文字化後）に次のいずれかが含まれる場合、effort は `xhigh` になります。

`security` / `architect` / `design` / `release` / `deploy` / `critical` /
`incident` / `hotfix` / `pr-review` / `final-review` / `cto` / `plan` / `opusplan`

判定ロジックは `lib/model-router.sh` の `model_router__task_is_high_risk()` です。

## 利用量バランス機構（既定 OFF・opt-in）

旧方式（Opus/Sonnet の利用比率差が閾値を超えたら低利用モデルへ切替）は
**既定で無効**です。有効化すると約半数のセッションが Sonnet へ流れ、
「既定 = Opus 5」の方針と両立しないためです。

従来動作へ戻す場合のみ、次のいずれかで有効化します。

- 環境変数 `CLAUDEOS_MODEL_BALANCE=1`
- config `modelRouter.balanceEnabled: true`

有効時は `~/.claudeos/model-usage.jsonl` の select 記録を集計し、利用比率差が
`balanceThresholdPct`（既定 5%）以上なら次回起動で低利用モデルを選びます。

## 設定

`config/config.json` の `modelRouter` が既定です。

```json
{
  "modelRouter": {
    "enabled": true,
    "balanceEnabled": false,
    "balanceThresholdPct": 5,
    "usageFile": "~/.claudeos/model-usage.jsonl",
    "models": {
      "opus": { "id": "claude-opus-5" },
      "sonnet": { "id": "claude-sonnet-5", "effort": "max" }
    },
    "taskEffort": {}
  }
}
```

`models.opus.effort` は未設定（推奨）なら高リスク=`xhigh` / 通常=`high` の 2 階層を
自動適用します。明示すると全 opus タスクでその値に固定されます。

### フェーズ別 effort（`taskEffort`・opt-in）

`modelRouter.taskEffort` にキー（task 部分一致）→ effort のマップを書くと、該当タスクだけ
effort を上書きできます。**空 `{}`（既定）なら既定階層**（高リスク `xhigh` / 通常 `high` /
sonnet opt-in 時 `max`）を維持します。effort は「思考時間」だけでなく読むファイル数・
検証量・チェックイン頻度を制御するため、軽量フェーズだけ下げる使い方を想定しています。

```json
"taskEffort": { "monitor": "medium" }
```

- 上例では Monitor フェーズのみ `medium` へ軽量化し、他フェーズは既定階層を維持
- 値は `low|medium|high|xhigh|max` のみ有効（不正値は無視 = 起動失敗を予防）
- 適用時は選択ログの `reason` に `+effort:task(<キー>)` が付く

環境変数で一時上書きできます。

| 環境変数 | 内容 |
|---|---|
| `CLAUDEOS_MODEL_ROUTER=0` | 自動モデル指定を無効化 |
| `CLAUDEOS_MODEL_KEY=opus` / `sonnet` | 強制モデル指定 |
| `CLAUDEOS_MODEL_TASK=security` | タスク分類を明示 |
| `CLAUDEOS_MODEL_EFFORT=high` | effort を強制上書き（taskEffort より優先・`reason` に `+effort:forced`） |
| `CLAUDEOS_MODEL_BALANCE=1` | 利用量バランス機構を有効化（既定 OFF） |
| `CLAUDEOS_MODEL_BALANCE_THRESHOLD_PCT=5` | バランス切替閾値（バランス有効時のみ） |
| `CLAUDEOS_MODEL_USAGE_FILE=/path/file.jsonl` | 利用台帳パス |
| `CLAUDEOS_OPUS_MODEL` / `CLAUDEOS_OPUS_EFFORT` | Opus 側上書き（effort 指定で 2 階層を固定値化） |
| `CLAUDEOS_SONNET_MODEL` / `CLAUDEOS_SONNET_EFFORT` | Sonnet 側上書き |

## 確認

dry-run で次回選択を確認できます。

```bash
bash bin/start-claude.sh --project <ProjectName> --background --duration 1 --dry-run
bash bin/autonomy.sh start <ProjectName> --duration 1 --dry-run
bash scripts/tools/launch-parallel-cron.sh <ProjectName> --roles cto,qa --dry-run
```

出力に `model` / `effort` / `model_reason` が表示されます。

## 変更履歴

- 2026-08-06: 既定を Sonnet 5 (max) + 5% バランスから **Opus 5 全タスク既定 +
  effort 2 階層（高リスク xhigh / 通常 high）** へ変更。バランス機構は
  `balanceEnabled`（既定 false）の opt-in へ降格。
- 2026-07-11: フェーズ別 effort（`taskEffort`）を追加（PR #85）。
- 2026-07-03: 既定モデルを Sonnet 5 (Max Effort) へ更新（PR #83）。
