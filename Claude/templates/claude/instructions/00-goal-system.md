# 🎯 ClaudeOS Goal System v10（統合 Goal Router）

## 目的

ClaudeOS における `/goal` を一元管理する。全 Agent・CTO・CIManager・Codex・CodeRabbit は
本ファイルと `goals/<type>.md` の定義を唯一の正本として扱う。

v10 では「巨大な万能 /goal」をやめ、**Router → Primary Goal → Specialized Goal → Agent/Skill/MCP** の
段階構造にした。Goal の本文は `Claude/templates/claudeos/goals/<type>.md`（各 4000 字以内）にだけ書く。

---

# 🧠 Goal-Driven Development 原則

- 固定ループではなく Goal Driven。`/goal` を最上位命令として扱う
- Goal 未達なら継続、達成なら終了。暴走禁止。Security は常に最優先
- Goal は **起動時に 1 つに確定** し、毎ターン切り替えない（flapping 禁止）

---

# 🧭 Unified Goal Router（実行基盤側: `lib/goal-router.sh`）

```text
User Request ─┐
Project State ├─▶ Evidence ─▶ Router ─▶ Primary Goal ─▶ Specialized Goal ─▶ effective_goal_type
Runtime/Repo ─┘                                                                   │
                                                          goals/<effective>.md の /goal を注入 ◀┘
```

| 入力 | 例 |
|---|---|
| User Intent | 「作って / 実装して」→ development、「MVP / PoC」→ mvp-release、「評価 / 監査」→ assessment、「直して / CI 失敗」→ deep-debug、「総合テスト / リリース判定」→ product-assurance |
| Project State | `phase_mode` / `goal_type` / `deploy.ready` / `execution.phase` / `stable.stable_achieved` / `kpi.security_critical` / `blocked_issues` |
| Repository | git（コミット数・dirty）、CI ワークフローとテストの有無、open PR、最新 CI 結果（gh、任意） |

優先順位（競合時）: security-emergency > deep-debug > hotfix > product-assurance > production-release > assessment > mvp-release > development。
ユーザーの明示指定（`--goal <name>`）は Security Critical がない限り尊重する。

## Primary Goal（5 分類）

| Primary | 用途 | Specialized（配下） |
|---|---|---|
| `development` | 既存 Project の通常開発・継続改善 | refactoring / hotfix |
| `mvp-release` | 新規 / Prototype / PoC / MVP | production-release |
| `assessment` | 評価・Readiness・Architecture / Security Review・Gap 分析（改善実装まで） | security-emergency |
| `deep-debug` | CI 失敗・Runtime Error・Regression・障害の根本原因解析 | hotfix / security-emergency |
| `product-assurance` | Release 前の総合品質保証（DB 復旧・Security・Contract・E2E・性能・A11y・監査） | production-release / safe-auto-merge / pr-babysit |

Specialized Goal は Primary を置き換えず、**実行モードを狭める追加制約**。
`effective_goal_type = specialized_goal ?? primary_goal` が従来の `goal_type` と同じ意味で goal-extract に渡る。

## 状態（state.json）

```json
"goal_router": {
  "mode": "auto", "primary_goal": "development", "specialized_goal": null,
  "effective_goal_type": "development", "confidence": 0.5, "reason": "...",
  "evidence": ["phase_mode:development", "ci:success"],
  "locked_by_user": false, "session_locked": true, "route_version": 1,
  "last_routed_at": "ISO-8601", "last_transition_reason": "kept:cron"
}
```

- 旧 `goal_type` は削除しない（Router 不在・無効時のフォールバック、cron の `--goal-type` 互換）
- `session_locked`: 同一セッション期間（既定 12 時間）は Goal を維持。reroute は Security Critical / 重大 CI 失敗 / deploy.ready・phase_mode 変化 / ユーザー新指示 / Goal 達成 / 明示 reroute のみ
- `locked_by_user`: `--goal <name>` で manual lock、`--goal auto` で解除

## 手動 override

| 経路 | 方法 |
|---|---|
| L1 / S1 / T1 | `start-claude.sh --project P --foreground --goal auto\|<name> [--intent "<要求>"]` |
| cron | `cron-schedule.sh add … --goal-type <name>`（one-shot、state を lock しない） |
| CLI | `libexec/goal-router.sh <project> [--goal …] [--intent …] [--dry-run] [--json]` |
| 無効化 | `CLAUDEOS_GOAL_ROUTER_DISABLE=1`（従来 goal_type のみ） |

## Fallback（Router 失敗時）

1. explicit user goal → 2. `state.goal_type` → 3. `phase_mode`（maintenance/released → development）→ 4. mvp-release。
Security Critical が既知なら常に security-emergency。Router の失敗は Project 起動を止めない。

---

# 🤖 Agent / Skill / MCP 選択

Router は Goal だけを決める。Agent 選択は Goal 決定後、各 `goals/<type>.md` の「■ Agent Strategy」と `/agent-router` に従う。
全 Agent 常時起動は禁止。書込みは同一ファイル・migration・schema・lockfile・共有設定への同時書込みを禁止（worktree 分離）。

| Primary | 既定 Agent | 必要時 |
|---|---|---|
| development | Architect / Backend / Frontend / QA / Reviewer | DB / Security / DevOps |
| mvp-release | CTO → Backend + Frontend + QA | Design / DB / Security / DevOps |
| assessment | Architect / Research / Reviewer / Security / Devil's Advocate | Developer（改善実装） |
| deep-debug | Debugger / Backend / QA | Security |
| product-assurance | QA / Security / ReleaseManager / Audit / DevOps | — |

---

# 🚦 CTO 優先順位

| 優先度 | 状態 | 行動 |
|---|---|---|
| 1 | Security Critical | 即時対応（security-emergency） |
| 2 | CI 失敗 | 修復（deep-debug） |
| 3 | Blocker | 解除 |
| 4 | /goal 直結 Issue | 実装 |
| 5 | 品質不足 | Verify |
| 6 | 改善 | 余裕時のみ |

# 🚨 Global Stop Conditions

同一原因エラー 2 回 → RCA + Issue 化 / 修復 3 回失敗 → Blocked / 同一戦略 3 回失敗 → 戦略変更 /
セッション上限到達 → 終了 / Token 枯渇・Context 圧迫 → 安全終了 / Security Critical → security-emergency へ。

# 🔒 Human Gate（Router は権限を昇格しない）

main 直接 push / main merge 最終判断（品質ゲート未達・高リスク）/ Production Deploy / Secrets / 課金 / 破壊的削除 /
rollback 不能な DB 操作 / Branch Protection・Ruleset 回避 / Security Gate 回避。
`production-release` は `deploy.ready=true` と Runbook までが自律範囲。

# 📋 全ファイル共通ルール

他 md ファイルでは `/goal` を再定義しない。記載する場合は「詳細は 00-goal-system.md と goals/<type>.md を参照」のみ。
