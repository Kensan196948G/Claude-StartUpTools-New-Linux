# 🤖 SubAgents 定義 見直しレビュー — 2026-06

**作成日**: 2026-06-15
**対象**: `Claude/templates/claudeos/agents/`（正本テンプレート）+ `.claude/claudeos/agents/`（本リポジトリ稼働コピー）
**契機**: Claude Code docs `subagents` 適合判断 →「定義を見直す」採択
**前提文書**: [`agents-skills-inventory-2026Q2.md`](./agents-skills-inventory-2026Q2.md)（2026-04-15, Issue #105）
**方針**: 🚧 破壊的削除は人間最終決断（CLAUDE.md）。本レビューは **観察 + Issue 化推奨** に留め、ファイル削除は実行しない。

---

## 📊 現状の数値（2026-06-15 実測）

| 区分 | 場所 | 件数 | 備考 |
|---|---|---|---|
| 正本 active | `Claude/templates/claudeos/agents/*.md` | **33** | 配布対象 |
| 正本 archived | `Claude/templates/claudeos/agents/_archived/*.md` | **11** | 言語固有agentを退避済み |
| 稼働コピー | `.claude/claudeos/agents/*.md` | **44** | 本リポジトリ自身のClaudeOS |

> 💡 稼働44 = 正本active33 + 言語固有11。**正本では `_archived/` 退避済みの11件が、稼働側では未追随で残存**している。

---

## 🔍 見直しで判明した不整合（3点）

### ① 🔁 インベントリ判定と正本実装が逆向き（最重要）

Q2インベントリは言語固有 reviewer/build-resolver 11件を **カテゴリB＝「保持推奨」** と判定。
ところが正本テンプレートは **その11件すべてを `_archived/` へ退避** している（＝実質「非配布＝外す」判断）。

| agent群 | Q2インベントリ判定 | 正本テンプレートの実態 |
|---|---|---|
| cpp/rust/go/java/kotlin/pytorch `-reviewer`・`-build-resolver`（11件） | 🟢 B 保持推奨 | 🗄️ `_archived/` 退避（非配布） |

**評価**: 退避自体は妥当（Linux専用ツールの起動/Supervisor運用に多言語reviewerは過剰）。
ただし**文書(インベントリ)が実態を反映していない**ため、判断根拠が追跡不能になっている。
→ インベントリの当該行を「B保持 → archived(配布対象外)」へ更新すべき。

### ② 🗑️ `security` 廃止スタブが三者未収束

| 場所 | 状態 |
|---|---|
| Q2インベントリ | 🔴 D削除候補・「security-reviewerへ統合推奨」と明記 |
| 正本テンプレート | ⚠️ 廃止スタブとして残存（`description: 廃止済み`） |
| 稼働コピー | ⚠️ 残存 |

参照は **ゼロ**（`grep` で被参照なし、`security-reviewer.md` が後継）。
→ 削除候補として最有力だが **削除実行は人間ゲート**。Issue化して決裁を仰ぐ。

### ③ 📉 稼働コピーが正本の統廃合に未追随

正本が `_archived/` 退避した11件が `.claude/claudeos/agents/` にそのまま残る。
本リポジトリ自身のClaudeOSは Linux 起動ツール開発が主務であり、多言語reviewerは不要。
→ 稼働コピーを正本active(33)へ同期するのが筋。ただしこれも削除を伴うため人間ゲート。

---

## 🧩 重複が疑われる active agent 群（Q2踏襲・要観察）

Q2でA/D（削除候補）判定済みのうち、正本activeに残るもの。**即削除せず**、運用での実利用を見て次回棚卸しで再評価する。

| agent | Q2判定 | 重複先・代替 |
|---|---|---|
| `security` | D | `security-reviewer`（②で個別対応） |
| `dev-api` | D | `api-designer` |
| `dev-ui` | D | ドメイン固有性低 |
| `refactor-cleaner` | D | モデル内包 |
| `ops` | D | DevOps ロール |
| `release-manager` | D | ReleaseManager ロール |
| `incident-triager` | D | 汎用トリアージ |
| `harness-optimizer` | D | 汎用最適化 |
| `code-reviewer` / `architect` / `planner` / `orchestrator` / `chief-of-staff` / `loop-operator` / `doc-updater` / `tdd-guide` / `tester` / `qa` / `api-designer` / `docs-lookup` | A | モデル内包・他スキルで代替 |

> 🛑 A/D判定は「Opus内包で代替可」という**理論値**。本リポジトリは cron 自律実行で実際に役割名でAgent Teamsを起動するため、`cto`/`orchestrator`/`manager` 等の**役割アンカーとしての価値**は別途残る。一律削除はしない。

---

## 🪜 新能力メモ — SubAgent 5段ネスト（changelog 2.1.172+）

Claude Code は SubAgent のネスト（agent が agent を起動）を **最大5段** までサポート。

- 🎯 適用: Pattern A/B/C の Agent Teams で、各 teammate が更に専門 SubAgent を呼ぶ深い分業が可能。
- 🛡️ ガードレール: 段数増は token とリードタイムを増幅。**3段超は Verify大規模監査など明確な必要時のみ**。
  常用は `04-agent-teams.md` の token<70% / 残≥60分 ガードと併せて抑制する。
- 🔗 関連: ultracode 運用ルール（`core/04-agent-teams.md`）と同じ「条件付き許可・既定化しない」原則を適用。

---

## ✅ 推奨アクション（すべて Issue 化・削除は人間決裁）

| # | アクション | 種別 | ゲート |
|---|---|---|---|
| 1 | `security` 廃止スタブを正本・稼働から削除（参照ゼロ確認済み） | 🗑️ 削除 | 👤 人間決裁 |
| 2 | 稼働 `.claude/claudeos/agents/` を正本active(33)へ同期（言語11件退避） | 🔁 同期削除 | 👤 人間決裁 |
| 3 | Q2インベントリの言語agent行を「B → archived」に更新（実態反映） | 📝 文書 | 🤖 CTO自律可 |
| 4 | D判定12件の運用実利用ログを次回棚卸しまで収集（Frontier-Test連携） | 📈 観察 | 🤖 CTO自律可 |
| 5 | 5段ネスト・ultracode運用を Agent Teams 教材へ反映済み（本セッション完了分） | ✔️ 完了 | — |

> ⚠️ `update-readme-stats.js` は `.claude/claudeos/agents/*.md` を数えるため、アクション1・2を実施すると
> README の agents 件数が変動する。削除実施時は同スクリプト再実行＋README更新を同一PRで行うこと。

---

## 📜 変更履歴

| 日付 | 変更内容 |
|---|---|
| 2026-06-15 | 初版 — subagents「定義を見直す」採択に伴う補遺レビュー。Q2インベントリとの不整合3点・5段ネスト能力を記録 |
