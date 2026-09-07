# GOAL_ROUTER — 統合 Goal Router 設計（ClaudeOS Execution Control Plane）

状態: v10.1（2026-09-07）
正本: `lib/goal-router.sh`（判定ロジック唯一の実装）、`libexec/goal-extract.sh`（`goal_extract__compose`）、
`state.schema.json`（`goal_router`）、`Claude/templates/claudeos/goals/*.md`、`tests/bats/unit/goal-router.bats`

## 1. Before / After

| 観点 | Before（v10.0 まで） | After |
|---|---|---|
| Goal 決定 | `state.goal_type`（既定 mvp-release）を cron-launcher だけが読む。L1/S1 直起動と T1 は START_PROMPT の万能 /goal | 全経路が `lib/goal-router.sh` で Primary/Specialized を判定し effective goal_type に収束 |
| START_PROMPT | 3,300 字の万能 /goal（MVP・Release・運用を全部要求） | 既定 /goal（Router 未注入時のみ）+ Router bootstrap 本文（約 1,900 字） |
| goals/*.md | Specialized 6 種 + mvp-release | Primary 5 分類 + Specialized 6 種（全 11、各 /goal ≤ 2,900 字、■ Use When 付き） |
| 手動 override | cron の `--goal-type` のみ | `--goal auto\|<name>`、`--intent`、CLI `libexec/goal-router.sh`、cron は one-shot 互換 |
| Flapping | なし（毎起動で goal_type を再読） | session lock（12h）+ reroute 条件、manual lock、history |
| 可視化 | なし | Mission Control v10 パネル、`goal-router.sh --json` |

## 2. データフロー

```text
start-claude.sh (L1/S1/T1)  cron-launcher.sh (cron/headless/Supervisor)  libexec/goal-router.sh (CLI)
          └──────────────┬──────────────────────┘                                │
                 goal_router__resolve <project_dir> [--goal] [--intent] [--trigger] [--one-shot]
                         │  evidence (state.json / git / CI / gh / intent)
                         │  route     (§7 優先順位 → Primary/Specialized → lock 判定)
                         │  persist   (state.goal_router、他キー不変、原子的)
                         ▼
        GOAL_ROUTER_EFFECTIVE ──▶ goal_extract__compose <effective> <goals_dir> <START_PROMPT> [header]
                                       └─ goals/<effective>.md の /goal を先頭へ、埋込 /goal を除去
```

T1 は CTO ペインにだけ `[Goal Router] …` ヘッダを付けた TEAM_START_PROMPT サイドカーを渡す（member へ別 Primary を与えない）。

## 3. Routing Rules（`goal_router__route`）

1. **explicit**: `--goal <name>`（manual lock）/ `CLAUDEOS_PRIMARY_GOAL`（one-shot）/ 前回 `mode=manual`。confidence 1.00。Security Critical は明示指定を上書きして security-emergency
2. `kpi.security_critical>0` → deep-debug / security-emergency（0.95）
3. CI failure（gh 最新 run failure、または `ci_success_rate<0.5`）→ deep-debug（0.85、maintenance/released なら + hotfix）
4. intent（§6.1 キーワード表、§7 順で解決）→ 0.80
5. `deploy.ready=true` / `execution.phase=Release` → product-assurance / production-release（0.80 / 0.75）
6. maintenance/released + Blocker → deep-debug / hotfix（0.70）
7. `stable_achieved=true`（development）→ product-assurance（0.70）
8. `phase_mode=maintenance|released` → development（0.70）
9. 旧 `goal_type` → 写像（0.60）
10. state 不在 / CI・テスト未整備 / コミット ≤ 5 → mvp-release（0.55）、それ以外 → development（0.50）

**Lock**: 前回 `session_locked=true` かつ `last_routed_at` から `CLAUDEOS_GOAL_LOCK_MINUTES`（720）以内なら維持（`transition=kept`）。
reroute 条件: Security Critical の新規発生 / CI failure の新規発生 / deploy.ready 変化 / phase_mode 変化 / intent あり / trigger ∈ {user, reroute, goal-reached} / `CLAUDEOS_GOAL_REROUTE=1` / `--goal auto`。

**Fail-safe**: Router 出力が不正 → explicit → goal_type → phase_mode → mvp-release。state.json が壊れていても起動を止めず、書き換えない。

## 4. 互換性

- `state.goal_type` は温存。Router は書き換えない（`effective_goal_type` を別途記録）
- `goal_router` ブロックのない旧 state は goal_type で動作し、初回起動で追記される（schema 適合をテスト）
- `CLAUDEOS_GOAL_TYPE_OVERRIDE`（cron 行）は one-shot の明示指定。state を lock しない
- `lib/goal-router.sh` 不在（古い配布）でも cron-launcher は従来経路で起動する
- `CLAUDEOS_GOAL_ROUTER_DISABLE=1` で完全に従来動作

## 5. 起動経路別の統合点

| 経路 | 統合点 | trigger |
|---|---|---|
| L1 直起動 / tmux | `bin/start-claude.sh` → `claude__route_goal` → `claude__compose_prompt`（サイドカー、`CCSU_PROMPT_FILE`） | foreground / user |
| S1 headless once | 同上（`direct__run_headless_once`） | background / user |
| S1 supervisor | start-claude で判定・persist → `lib/supervisor.sh` が `CLAUDEOS_GOAL_TRIGGER=supervisor-start\|resume` → cron-launcher | supervisor-* |
| T1 | start-claude で判定 → `CLAUDEOS_GOAL_HEADER` → `lib/team-runner.sh` が CTO サイドカー | team / user |
| cron / headless | `Claude/templates/linux/cron-launcher.sh`（override は one-shot） | cron |
| CLI | `libexec/goal-router.sh` | cli / user |

## 6. 4000 字制約

Router Context（`[Goal Router]` ヘッダ ≤ 500 字）と Goal 本文（goals/*.md ≤ 4000 字、実測最大 2,837 字）を分離。
`goal_extract__truncate` は最終安全装置で、通常運用では発動しない（node テストで全 goal を計数）。

## 7. Security / Human Gate

Routing 結果は権限を昇格しない。permissions / sandbox / Branch Protection / Required Checks / Rulesets / Secrets /
deploy signoff / destructive gate は Router 導入前と同一。`production-release` は deploy.ready と Runbook まで。

## 8. テスト

| 種別 | ファイル | 観点 |
|---|---|---|
| Unit | `tests/bats/unit/goal-router.bats`（50） | explicit / intent / state / CI / Security / release / fallback / malformed / compat / confidence / lock / reroute / persist |
| Integration | `cron-launcher-headless.bats`（+6）、`start-claude.bats`（+7）、`team-runner.bats`（+1）、`goal-inject.bats`（+3） | cron / headless / Supervisor resume / L1 / S1 / T1 / compose / START_PROMPT |
| Schema | `scripts/state-schema.test.js`（9） | example / template / old state / new state / enum / goals 4000 字 |
| Regression | `npm test` 全件、`npm run lint` | 既存経路の不変 |

## 9. 既知の制限

- gh Evidence は `origin` remote と認証がある場合のみ（timeout 8 秒、失敗は unknown）。Runtime Evidence（health / logs / Cloudflare）は未統合（Mission Control 側で別途）
- intent はキーワード表による分類（LLM 分類ではない）。判定不能は状態ベースへ委譲
- Goal 達成の自動検出は Supervisor の `goal-reached`（deploy.ready / phase_mode）に依存。セッション内の Goal 達成による reroute はユーザー新指示か次回起動で反映
