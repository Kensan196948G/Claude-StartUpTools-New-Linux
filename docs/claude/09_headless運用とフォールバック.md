# 09. Headless 運用と退避フォールバック (PR-G)

このドキュメントは、cron 起動を `claude -p` **ヘッドレス既定**へ反転した PR-G 以降の正本運用手順です。
tmux は標準経路ではなく、`--tmux` または `CLAUDEOS_TMUX=1` 明示時だけ使う退避フォールバックです。

## 1. 既定の挙動（PR-G 以降）

| 状態 | 経路 | 説明 |
|---|---|---|
| `CLAUDEOS_HEADLESS` 未設定 | 🟦 **headless 既定** | `claude -p --output-format stream-json --permission-mode auto` で起動。resume・cost 捕捉対応 |
| `CLAUDEOS_HEADLESS=1` | 🟦 headless | 上と同じ（明示指定） |
| `CLAUDEOS_HEADLESS=0` | 🟨 **TUI 退避** | tmux なしの TTY なし直実行へ opt-out。課金枯渇・障害時の退避経路 |
| `CLAUDEOS_HEADLESS=0 CLAUDEOS_TMUX=1` | 🟧 tmux fallback | 従来の tmux 対話 TUI 経路。デバッグ・目視 attach 用 |

- 正本フラグ: `config.json` の `cron.headlessDefault: true`（`tools.claude.headless.enabled: true` と整合）。
- 実装: `Claude/templates/linux/cron-launcher.sh` の `${CLAUDEOS_HEADLESS:-1}` 分岐（既定 = headless）。

`★ ポイント` headless 既定化は **Agent SDK 月次クレジット**（対話枠とは別枠、2026-06-15 課金変更）を消費します。
消費は `lib/credits.sh` が ledger 追記 → `agentSdk` ブロックの warn/verifyOnly/stop 閾値で段階ガードします。
標準運用では、既定セッション長を 300 分（5 時間）とし、Supervisor の全体デフォルトは
`dailyMaxMinutes=600` / `maxRestartsPerDay=1` / `sessionMinutes=300` にします。
cron 登録は 1 日 2 プロジェクトまで、1 セッション 300 分までを上限にします。
省クレジット退避が必要な場合は `run-now --duration 60` 等の単発短縮実行へ落とします。

### 無人セッションの堅牢化（v2.1.186 / v2.1.196 対応）

| 対策 | 実装 | 効果 |
|---|---|---|
| 🔁 retry watchdog | cron-launcher が `CLAUDE_CODE_RETRY_WATCHDOG=1` を export | 一時 API エラーのリトライ上限を無人運用向けに拡大（既定 300 回）。overload での 300 分セッション空振りを防ぐ |
| ⏱ stream watchdog | 同 `CLAUDE_ENABLE_STREAM_WATCHDOG=1`（既定有効を明示固定） | ストリーム 5 分無イベントで abort+retry |
| 🧬 fallbackModel | settings.json `"fallbackModel": ["opus", "sonnet", "haiku"]`（最大 3 段） | プライマリモデル過負荷・利用不可時に自動フォールバック |
| 🚨 waitingFor 監視 | `watch-session.sh` が `claude agents --json` の `waitingFor == "permission prompt"` を検出して警告 | headless で自力前進できない permission 待ちスタックを可視化（対処: 手動介入 or `permissions.allow` 追加） |

## 2. TUI 退避への切替（課金枯渇・障害時）

headless が使えない/使いたくない場合は **明示的に TUI へ退避**します。tmux はさらに明示した場合だけ使います。

```bash
# 単発セッションを tmux なしで起動
CLAUDEOS_HEADLESS=0 bash bin/start-claude.sh

# tmux が必要なデバッグ時だけ明示
bash bin/start-claude.sh --tmux
CLAUDEOS_HEADLESS=0 CLAUDEOS_TMUX=1 bash bin/cron-schedule.sh run-now --project <name> --tmux

# cron 経路全体を TUI 既定へ戻す（恒久退避）
# config.json: "cron": { "headlessDefault": false }
```

退避が必要になる典型状況:

1. 🔴 **Agent SDK クレジット枯渇** — supervisor が `credit-cap:stop` で正常停止後、対話枠で継続したいとき。
2. 🟨 **stream-json parse 不調** — `jq` 不在や壊れた出力でログが読めないとき（TUI なら目視可能）。
3. 🟦 **セッションを目視 attach したいとき** — `--tmux` を明示したデバッグ・初期セットアップ時。

## 3. tmux 代替（headless 中の可視化）

headless では tmux 対話画面が無いため、可視化は次の3手段で代替します。

| 手段 | コマンド | 用途 |
|---|---|---|
| 🟦 可読ログ | `tail -f ~/.claudeos/logs/<project>-*.log` | stream-json を `stream-json-tail.sh` が人間可読へ整形済み |
| 🟩 セッション再開 | `claude --resume <session_id>` | `state.execution.last_claude_session_id` の id で対話接続 |
| 🟨 任意 tmux fallback | `--tmux` / `CLAUDEOS_TMUX=1` | 従来の tmux セッションを明示的に使う |

session_id は state ファイルから取得できます:

```bash
jq -r '.execution.last_claude_session_id' ~/.claudeos/sessions/<project>/state.json
# → 取得した id で対話継続
claude --resume <session_id>
```

## 4. クレジット枯渇フォールバックの全体方針

`lib/credits.sh` の段階ガード（`agentSdk` 閾値）と退避経路の対応:

| 消費率 | ガード | 自動挙動 | 推奨手当て |
|---|---|---|---|
| 70% (`warnPct`) | 🟨 warn | 通知のみ・継続 | 残作業の優先度を確認 |
| 85% (`verifyOnlyPct`) | 🟨 verify-only | 新規開発抑制・Verify 優先 | リリース準備へ寄せる |
| 95% (`stopPct`) | 🔴 stop | supervisor が `credit-cap:stop` で**正常停止** | 下記いずれかへ退避 |

枯渇時の退避先（優先順）:

1. 🟨 **新規 headless 起動を止める** — cron 登録を増やさず、`launch --all` は使わない。
2. 🟨 **登録済みプロジェクトを単発・短時間だけ実行** — `bash bin/cron-schedule.sh run-now --project <name> --duration 60` のように対象と時間を明示する。
3. 🟨 **並列ロール本数を 1 へ縮退** — `bin/autonomy.sh start --roles cto`（QA 等を外す）。
4. 🟨 **TUI 対話枠へ手動切替** — `CLAUDEOS_HEADLESS=0` または `--tmux`（本書 §2）。対話枠は Agent SDK 枠と別計上。
5. 🟦 **Anthropic Managed Agents で補完** — `docs/claude/07_ManagedAgents_PoC手順書.md` 参照。
   本リポジトリへのコード追加は禁止（Console + CLI スキル経由の管理のみ）。位置づけは
   「ローカル cron 主・Managed Agents 補完」(`docs/claude/06_ManagedAgents調査メモ.md`)。

`★ 設計原則` supervisor は枯渇を **crash 扱いにせず正常停止** します（誤った全停止連鎖を避ける）。
月次境界は実課金サイクルと厳密一致しない概算であり、あくまで**予防ガード**として機能します。
Claude Web の利用クレジット画面が正本であり、ローカル ledger が少なく見える場合は画面側を優先して
手動で起動を止めてください。

## 5. 関連ファイル

- 起動分岐: `Claude/templates/linux/cron-launcher.sh`（`${CLAUDEOS_HEADLESS:-1}`）
- ログ整形/cost 捕捉: `libexec/stream-json-tail.sh`
- クレジット記録/ガード: `lib/credits.sh` + `config.json` の `agentSdk` ブロック
- 並列ロール: `scripts/tools/launch-parallel-cron.sh` / `bin/autonomy.sh --roles`
- 設定正本: `config/config.json.template`（`cron.headlessDefault` / `tools.claude.headless`）
