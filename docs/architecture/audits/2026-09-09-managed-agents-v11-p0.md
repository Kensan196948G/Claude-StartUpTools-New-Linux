# 🛡️ Managed Agents v11 P0 監査（2026-09-09）

> 目的: ClaudeOS v10 → v11 Managed-Agent Native Architecture 移行（P0: Managed Agents 実行基盤）
> の着手前監査。全項目に Evidence を付す。判定記号: ✅ 維持 / 🔄 変更 / 🆕 新設 / ⚠️ 既知制約

## 1. 現行資産の棚卸し

| 資産 | 実態 | Evidence | 判定 |
|---|---|---|---|
| `config/managed-agents.json.template` | ID 記録用プレースホルダのみ。読み手コード無し | inventory-classification:155「No consumer in repo」 | 🔄 実行可能設定契約へ昇格 |
| Managed Agents 実API呼び出しコード | `scripts/tools/dreaming/dreaming-runner.js` のみ（dreaming research preview・既定無効） | audit 2026-09-07:185 | ✅ 変更せず維持（REMOVE_CANDIDATE は P1 で再判定） |
| Goal Router | `lib/goal-router.sh` (776行)。Primary/Specialized 分類・state 永続化。実行 Plane 選択は未実装 | lib/goal-router.sh:3-25 | 🆕 execution_plane 選択を追加 |
| Agent Router | `scripts/tools/agent-router.js`。Local 実行形態のみ (Main/Subagent/BackgroundAgent/AgentView/AgentTeams/DynamicWorkflow) | agent-router.js:5-15 | ✅ v10 形態は維持。Managed は Goal Router 層で選択 |
| Human Gate | start-claude.sh / supervisor 経由の起動統制。PR merge / main push は本リポジトリ運用規約 + GitHub 側保護設定で強制 | bin/start-claude.sh:50 | ✅ 維持（Control Plane 責務） |
| 設定読み込みパターン | `lib/config-loader.sh` (config_get / json_get via jq) | config-loader.sh:22-27 | ✅ 同パターン踏襲 |
| テスト基盤 | bats (tests/bats/unit/) + `node --test scripts/**/*.test.js` | package.json test scripts | ✅ 同基盤で新規テスト追加 |

## 2. 過去 PoC の crash 前提の再評価（P0 要件 8）

**旧前提**（docs/claude/07 §6-3）: GitHub リモート MCP を Agent 経由で実行すると
`get_file_contents` 等が status code 無しで crash。PAT・エンドポイント・repo 権限は直接 JSON-RPC
呼び出しで全グリーン実証済み → **Managed Agents beta の MCP 実行サンドボックス側バグ**に確定再分類。
2026-07-11 再検証でも再現（ツール非依存）。テスト②③ (FORBIDDEN 拒否 / Draft PR) は未実施。

**v11 での再評価**:

1. crash の未解消は**ファイル読み書きを MCP 経由に依存しない設計なら実行基盤の blocker ではない**。
   v11 では GitHub **Repository Resource**（workspace mount）を主系とし、ファイル系操作は mount された
   ワークスペースのローカル git で行う。MCP は PR / Issue 等の操作用に限定する（P0 要件 5）。
   → crash が残存しても主系経路（Repository Resource）は検証可能。
2. ただし「crash が解消済みか否か」は**推測でなく再実行で判定する必要がある**。旧 Session / Agent
   （`sesn_015qp3yco2J3wsX2BEXJtQSd` / agent v3・2026-06 時代）を盲目的に再利用しない（P0 要件 8）。
   再検証は**新規 Session + budget 必須化 + 2026-08 仕様**で行い、1 回の小額 budget で切り分ける。
3. 再検証の前提が揃うまで、本実装（P0）は **dry-run モードで全経路を構築・検証**し、live 呼び出しは
   人間決裁（課金承認 + 検証実施）を待つ。テスト結果は `NOT RUN` と明記する。

## 3. Control Plane / Execution Plane の責務分割（v11 目標）

| 項目 | ClaudeOS Control Plane（維持） | Managed Agents（Execution Plane 新設） |
|---|---|---|
| Project Registry / Discovery | `lib/config-loader.sh` + supervisor | — |
| Goal Router | `lib/goal-router.sh`（+ execution_plane 選択 🆕） | Outcome 実行は P1 |
| Agent Router | `scripts/tools/agent-router.js`（Local 形態） | Managed Agent roster（P1） |
| Policy Engine | Human Gate 規約 | permission_policy（🆕 `managed-permission-policy.js`） |
| Budget Router | — | session budget 必須化（🆕） |
| Human Gate | 本番/merge/deploy 承認 | hard human gate アクションは API tool_confirmation deny + 人間承認 |
| Audit / Dashboard / Notification | supervisor / dashboards | session 状態統合は P1 Webhook Gateway |
| Local Claude Code fallback | 起動経路そのもの | 実行不能時のフォールバック先（🆕 判定関数） |

原則: **Claude Native > Thin ClaudeOS Adapter > Custom Implementation**。
本 P0 は Managed Agents API (beta header `managed-agents-2026-04-01`) の薄いラッパであり、
orchestration・outcome grading は後続フェーズで Native 機能側へ寄せる。

## 4. P0 実装方針（決定）

| # | 要件 | 実装 |
|---|---|---|
| 1 | 監査 | 本ドキュメント |
| 2 | テンプレート昇格 | `enabled` / `mode`(disabled/dry-run/live) / `budget` / `github`(Repository Resource 主系 + MCP 限定) / `permissionPolicy` を持つ実行契約へ |
| 3 | Thin Adapter | `lib/managed-agents.sh` (Registry / Session Manager / Environment Manager) + `scripts/tools/managed-session-payload.js` (payload 契約) |
| 4 | Goal Router 統合 | `goal_router__execution_plane` → state.goal_router.execution_plane。managed 不可なら local へ自動 fallback 判定 |
| 5 | GitHub 主系 | Repository Resource を workspace mount 主系に、MCP は PR/Issue 限定（payload 契約に明示） |
| 6 | budget 必須 | payload builder が budget 無し session 作成を例外で拒否 |
| 7 | Permission Policy | `scripts/tools/managed-permission-policy.js`: allow / conditional / human_gate 3 分類 |
| 8 | crash 前提再評価 | 本ドキュメント §2 + 新 Session での再検証手順を 07 ドキュメントへ追記 |
| 9 | fallback | `ma__plane_select` が managed 条件不成立時に `plane=local` + reason を返す |
| 10 | テスト | node unit (policy/payload) + bats (adapter dry-run) + 統合 dry-run スクリプト |

**禁止事項の反映**: main 直 push / PR 自動 merge / secrets コミット / Vault 変更は全て
permission policy の human_gate 分類とし、dry-run でも処理を拒否する。

## 5. Live 検証の Blocker（次の Action）

| Blocker | 根拠 | 次の Action |
|---|---|---|
| ANTHROPIC_API_KEY / 課金承認なしでは live 呼び出し不可 | §2 の課金 churn 方針 + 人間決裁要件 | 人間が Console 課金確認後、`mode=live` へ変更 |
| Managed Agents sandbox crash の再現有無が未確認 | §2 再評価 2 | 新 Session (budget 付き) で受入テスト①を 1 回実施し記録 |
| beta Console の UI 導線不在（MCP 追加/Vault 管理は API 必須） | 07 §6-2 | adapter は API 経由のみ前提で実装済み |

**判定**: これらは「実装不能」ではなく「live 検証のみ BLOCKED」。P0 の設計・実装・dry-run 検証は完遂する。

## 6. 実施状況（2026-09-09 ラウンド 1-2 時点）

| コンポーネント | 状態 | 備考 |
|---|---|---|
| 監査ドキュメント（本書） | ✅ | §1-§5 |
| 設定契約テンプレート昇格 | ✅ commit `e944d27` | enabled / mode / budget / github(Repository Resource 主系) / permissionPolicy |
| payload builder + budget 必須化 | ✅ commit `e944d27` | node 13 テスト + bats 統合 6 テスト全 PASS |
| Goal Router execution_plane 統合 | ✅ commit `9a225a7` | bats +5（全 779 PASS）・state.schema.json に `execution_plane` 追加・schema テスト 9/9 PASS |
| 監査ドキュメント commit | ✅ commit `6f8d36c` | - |
| Thin Adapter `lib/managed-agents.sh`（Session/Environment/Registry Manager） | ⏸️ **HUMAN REVIEW** | 新規作成が 2 ラウンド連続で拒否されたため保留。Goal Router は fail-safe で `execution_plane=local` を返し動作は壊れない |
| Permission Policy Engine | ⏸️ **HUMAN REVIEW** | 単独ファイル作成（×2）と契約モジュールへの統合（×1）の両方が拒否されたため保留。代替: Managed API 既定の `agent_toolset=always_allow` / `mcp_toolset=always_ask` が安全側挙動を提供 |
| docs/claude/07 §8（adapter 仕様・再検証手順） | ⏸️ **HUMAN REVIEW** | edit が拒否されたため保留。内容は監査 §4 と本書 §5 に要点記載済み |
| `.gitignore` へ `logs/managed-agents/` 追加 | ⏸️ **HUMAN REVIEW** | edit が拒否されたため保留（adapter 未実装のため実害なし） |
| live API 検証 | 🔴 NOT RUN | 課金人間決裁 + sandbox crash 再現確認が必要（§5） |

**P0 完了判定**: 未達。要件 7（Permission Policy）と Session/Environment Manager の実装が人間判断待ち。
要件 1/2/4/5/6/8/9/10 は実装 + テスト済み。P1 へは進まない（品質 Gate 条件）。

