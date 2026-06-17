# 09. Headless 運用と退避フォールバック (PR-G)

このドキュメントは、cron 起動を `claude -p` **ヘッドレス既定**へ反転した PR-G 以降の正本運用手順です。
TUI（tmux 対話）経路は「退避フォールバック」として残してあり、本書はその切替手順とクレジット枯渇時の対応を定義します。

## 1. 既定の挙動（PR-G 以降）

| 状態 | 経路 | 説明 |
|---|---|---|
| `CLAUDEOS_HEADLESS` 未設定 | 🟦 **headless 既定** | `claude -p --output-format stream-json --permission-mode dontAsk` で起動。resume・cost 捕捉対応 |
| `CLAUDEOS_HEADLESS=1` | 🟦 headless | 上と同じ（明示指定） |
| `CLAUDEOS_HEADLESS=0` | 🟨 **TUI 退避** | 従来の tmux 対話 TUI 非対話運用へ opt-out。課金枯渇・障害時の手動退避経路 |

- 正本フラグ: `config.json` の `cron.headlessDefault: true`（`tools.claude.headless.enabled: true` と整合）。
- 実装: `Claude/templates/linux/cron-launcher.sh` の `${CLAUDEOS_HEADLESS:-1}` 分岐（既定 = headless）。

`★ ポイント` headless 既定化は **Agent SDK 月次クレジット**（対話枠とは別枠、2026-06-15 課金変更）を消費します。
消費は `lib/credits.sh` が ledger 追記 → `agentSdk` ブロックの warn/verifyOnly/stop 閾値で段階ガードします。
省クレジット運用では、既定セッション長を 180 分にし、Supervisor の全体デフォルトも
`dailyMaxMinutes=180` / `maxRestartsPerDay=1` / `sessionMinutes=180` に絞ります。

## 2. TUI 退避への切替（課金枯渇・障害時）

headless が使えない/使いたくない場合は **明示的に TUI へ退避**します。

```bash
# 単発セッションを TUI で起動
CLAUDEOS_HEADLESS=0 bash bin/start-claude.sh

# cron 経路全体を TUI 既定へ戻す（恒久退避）
# config.json: "cron": { "headlessDefault": false }
```

退避が必要になる典型状況:

1. 🔴 **Agent SDK クレジット枯渇** — supervisor が `credit-cap:stop` で正常停止後、対話枠で継続したいとき。
2. 🟨 **stream-json parse 不調** — `jq` 不在や壊れた出力でログが読めないとき（TUI なら目視可能）。
3. 🟦 **セッションを目視 attach したいとき** — デバッグ・初期セットアップ時。

## 3. tmux 代替（headless 中の可視化）

headless では tmux 対話画面が無いため、可視化は次の3手段で代替します。

| 手段 | コマンド | 用途 |
|---|---|---|
| 🟦 可読ログ | `tail -f ~/.claudeos/logs/<project>-*.log` | stream-json を `stream-json-tail.sh` が人間可読へ整形済み |
| 🟩 セッション再開 | `claude --resume <session_id>` | `state.execution.last_claude_session_id` の id で対話接続 |
| 🟨 任意 tmux tee | `CLAUDEOS_TMUX=1` | headless 出力を tmux ペインへ同時 tee（オプション） |

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
2. 🟨 **単発・短時間だけ実行** — `bash bin/cron-schedule.sh run-now --project <name> --duration 60` のように対象と時間を明示する。
3. 🟨 **並列ロール本数を 1 へ縮退** — `bin/autonomy.sh start --roles cto`（QA 等を外す）。
4. 🟨 **TUI 対話枠へ手動切替** — `CLAUDEOS_HEADLESS=0`（本書 §2）。対話枠は Agent SDK 枠と別計上。
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
