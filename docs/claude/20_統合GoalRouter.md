# 20. 統合 Goal Router（Auto Goal Routing）運用ガイド

対象: ClaudeOS v10.1 以降。設計は `docs/architecture/GOAL_ROUTER.md`、Goal 定義は `.claude/claudeos/core/00-goal-system.md`。

## 1. Auto Goal Routing とは

Project を選んで起動すると、ClaudeOS が **state.json の状態・リポジトリの Evidence（git / CI / テスト / open PR）・ユーザー要求** から
最適な Goal を 1 つ決め、その Goal の `/goal`（`goals/<type>.md`）だけを起動プロンプトへ注入します。
Claude は「何でも調査し何でも実装する」のではなく、決まった Goal の Success Criteria / Scope / Stop Conditions に従って動きます。

```text
Project を選ぶ → 状態を読む → Goal を自動決定 → 必要な Agent / Skill / MCP だけ使う → 実装・評価・Debug・品質保証 → Evidence → Supervisor 継続 → Release 準備 → Human Gate
```

## 2. Primary Goal と Specialized Goal の違い

| 種別 | 役割 | 一覧 |
|---|---|---|
| Primary | セッションの目的（何を達成するか） | development / mvp-release / assessment / deep-debug / product-assurance |
| Specialized | Primary の実行モードを狭める追加制約 | production-release / hotfix / security-emergency / refactoring / safe-auto-merge / pr-babysit |

注入される /goal は `effective_goal_type = specialized_goal ?? primary_goal` のものです。
例: CI 失敗 + 保守期 → Primary `deep-debug`、Specialized `hotfix`、注入は `goals/hotfix.md`。

## 3. 判定の優先順位

1. Security Critical（`kpi.security_critical>0`）→ security-emergency（明示指定より優先）
2. Runtime incident（`state.runtime.health_url` の health check が down）→ deep-debug（本番運用中は + hotfix）
3. CI 失敗（最新 run failure / `ci_success_rate<0.5`）→ deep-debug（保守期は + hotfix）
4. Cloudflare deploy failure（`state.runtime.cloudflare.project|worker` の wrangler 判定）→ deep-debug
5. ユーザー要求（`--intent`）のキーワード: 作って・実装 → development、MVP・PoC → mvp-release、評価・監査 → assessment、直して・バグ → deep-debug、総合テスト・リリース判定 → product-assurance。キーワードで判定不能なら LLM 分類（§3.1）
6. error_log の直近エラー件数が閾値以上（既定 5、`CLAUDEOS_GOAL_RUNTIME_ERROR_THRESHOLD`）→ deep-debug
7. `deploy.ready=true` / `execution.phase=Release` → product-assurance + production-release
5. `stable_achieved=true` → product-assurance、`phase_mode=maintenance|released` → development
8. `stable_achieved=true` → product-assurance、`phase_mode=maintenance|released` → development
9. 旧 `goal_type` → そのまま写像（後方互換）
10. state 不在・CI / テスト未整備・コミット ≤ 5 → mvp-release、それ以外 → development

### 3.1 LLM ベースの intent 分類（キーワード表の補完）

キーワード表で判定できない要求（例:「このプロダクトの現状はどう？」）は、`claude -p --model haiku --output-format json --bare` でラベル 1 語（Primary または Primary/Specialized）を得て confidence 0.70 で採用します。

| 設定 | 値 |
|---|---|
| `CLAUDEOS_GOAL_INTENT_LLM` | `auto`（既定: Claude Code セッション内では呼ばない）/ `1`（強制）/ `0`（無効） |
| `CLAUDEOS_GOAL_INTENT_LLM_MODEL` / `_TIMEOUT` | 既定 `haiku` / 45 秒 |
| 課金 | headless と同じ subscription 経路（`env -u ANTHROPIC_API_KEY`）。`CLAUDEOS_HEADLESS_AUTH=api-key` で API キー |
| fail-safe | timeout・認証失敗・不正ラベル・`none` は捨てて状態ベース判定へ。ラベルはホワイトリスト検証 |

※ 2026-09-08 時点の実機検証は Claude Code セッション内からのため subscription ログイン不在で `Not logged in` となり、LLM 分類の**ライブ動作は UNVERIFIED**（単体テストは stub で網羅）。cron / メニューなど通常の起動環境で `libexec/goal-router.sh <project> --intent "…" --dry-run --explain` を実行して `intent_llm=` を確認してください。

### 3.2 Runtime Evidence（state.json の `runtime` ブロック）

```json
"runtime": {
  "health_url": "http://localhost:8080/health",
  "error_log": "~/apps/<app>/logs/error.log",
  "cloudflare": { "project": "<pages-project>", "worker": null }
}
```

| 項目 | 判定 | 影響 |
|---|---|---|
| `health_url` | curl（5 秒）、2xx/3xx = ok、それ以外 = down | down → deep-debug（+hotfix）。down への遷移は lock を破る |
| `error_log` | 直近 500 行の ERROR / FATAL / Traceback / panic / Unhandled / CRITICAL 件数 | 閾値以上 → deep-debug |
| `cloudflare.project` | `wrangler pages deployment list --project-name … --environment production --json` の `latest_stage.status` | failure → deep-debug |
| `cloudflare.worker` | `wrangler deployments list --name … --json` の一覧（listed / none / unknown） | 観測のみ。Worker の一覧には status が無いため routing には使わない |

未設定なら unknown（判定に影響しない）。`CLAUDEOS_GOAL_ROUTER_RUNTIME=0` / `CLAUDEOS_GOAL_ROUTER_CF=0` で無効化できます。

## 4. Manual Override

| やりたいこと | コマンド |
|---|---|
| メニュー（L1 / T1 / S1） | Yes 確認の後に「🎯 Goal [自動]」と「📝 要求」を聞く。Enter で自動判定、名前で固定、`auto` で固定解除。cron / stdin 閉塞時は問い合わせない |
| Goal を固定して起動（manual lock） | `bin/start-claude.sh --project P --foreground --goal deep-debug` |
| 固定を解除して自動判定に戻す | `bin/start-claude.sh --project P --foreground --goal auto` |
| 要求を伝えて判定させる | `bin/start-claude.sh --project P --background --intent "全体を評価して改善案を出して"` |
| cron ジョブだけ別 Goal（one-shot） | `bin/cron-schedule.sh add --project P --time 12:00 --dow 1-5 --duration 20 --goal-type pr-babysit` |
| 起動せずに判定だけ見る | `bash libexec/goal-router.sh P --dry-run --explain` / `--json` |
| lock を無視して再判定 | `bash libexec/goal-router.sh P --reroute` または `CLAUDEOS_GOAL_REROUTE=1` |
| Router を使わない | `CLAUDEOS_GOAL_ROUTER_DISABLE=1`（従来の `state.goal_type`） |

`--goal <name>` は state.json の `goal_router.mode=manual` / `locked_by_user=true` として永続化され、cron / Supervisor の次回起動でも維持されます。
cron の `--goal-type` は従来どおりそのジョブ限りで、state を lock しません。

## 5. Goal lock / reroute（flapping 防止）

- 一度決めた Goal は `session_locked=true` として 12 時間（`CLAUDEOS_GOAL_LOCK_MINUTES`）維持されます
- 再判定（reroute）は次の場合だけ: Security Critical の新規発生、CI 失敗の新規発生、`deploy.ready` / `phase_mode` の変化、ユーザーの新指示（`--goal` / `--intent`）、Goal 達成後の再起動、明示 `--reroute`
- Supervisor の通常再開は `transition=kept`（前回 Goal を維持）。`state.goal_router.history` に遷移（from → to → reason）が最大 10 件残ります

## 6. 起動経路ごとの挙動

| 経路 | 判定 | 注入 |
|---|---|---|
| L1（端末タブ / 現在端末 / `--tmux`） | start-claude が判定・記録 | START_PROMPT に /goal を合成したサイドカー（`~/.claudeos/logs/manual-*.prompt`） |
| S1 headless once | 同上 | 同上 |
| S1 supervisor / cron / headless | cron-launcher が判定（Supervisor 再開は lock 維持） | `/goal` + `[Cron Session Resume … goal_router=[…]]` + START_PROMPT |
| T1（4 分割チーム） | start-claude が判定 | CTO ペインだけ `[Goal Router] …` ヘッダ付き TEAM_START_PROMPT（member には Primary を与えず Role task に分解） |
| safe-mode | 判定しない | なし（診断起動） |

## 7. Human Gate（変わらないこと）

Router は Goal を選ぶだけで、権限を広げません。main 直接 push、main merge の最終判断（品質ゲート未達・高リスク）、本番デプロイ、Secrets、課金、破壊的削除、rollback 不能な DB 操作、Branch Protection / Ruleset / Security Gate 回避は引き続き人間の承認が必要です。`production-release` は `deploy.ready=true` と Runbook までが自律範囲です。

## 8. Fallback とトラブルシューティング

| 症状 | 確認 | 対処 |
|---|---|---|
| 期待と違う Goal になる | `libexec/goal-router.sh P --dry-run --explain` で Evidence と reason を見る | `--goal <name>` で固定、または state.json の `kpi.security_critical` / `phase_mode` / `deploy.ready` を修正 |
| Goal が切り替わらない | `goal_router.session_locked` と `last_routed_at` | `--goal auto` か `--reroute`。manual なら `--goal auto` |
| `goal_router` が state.json に無い | 旧 state（後方互換）。次回起動で追記される | `node scripts/validate-state-example.js state.json` で schema 確認 |
| cron ログに「goal-router.sh 不在」 | 配布元 `Claude-StartUpTools-New-Linux/lib/goal-router.sh` が無い | 配布元を更新。従来 `goal_type` で起動は継続する |
| /goal が 4000 字超 | `node --test scripts/state-schema.test.js` | goals/*.md を短縮（詳細は core docs / Skill へ） |
| gh が遅い / 認証なし | `ci=unknown` として判定 | `CLAUDEOS_GOAL_ROUTER_GH=0` で無効化可 |

## 9. state.json の項目

`goal_router.{mode, primary_goal, specialized_goal, effective_goal_type, confidence, reason, evidence[], locked_by_user, session_locked, route_version, last_routed_at, last_transition_reason, evidence_snapshot{}, history[]}`。
`goal_type` は互換のため残り、Router は書き換えません。schema は `state.schema.json`。
