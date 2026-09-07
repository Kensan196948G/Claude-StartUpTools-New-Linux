# CONTEXT_ENGINEERING — 必要時取得型 Context 設計

状態: v10（2026-09-07）

## 1. 役割分担

| 層 | 内容 | ロード |
|---|---|---|
| `/etc/claude-code/CLAUDE.md` | 組織方針（自動マージ、Approval PR、停止条件、秘密） | 常時（管理外） |
| `CLAUDE.md` | 全作業共通ルールの要約 + ポインタ（62 行、約 10KB） | 常時 |
| `AGENTS.md` | Codex / 他エージェント向け運用ルール（Claude Code は読まない） | — |
| `.claude/rules/*.md` | git-workflow / security（常時）、claudeos-launchers / hooks / templates（`paths` 一致時） | 条件付き |
| `.claude/skills/*/SKILL.md` | 専門知識・手順（frontmatter 付き） | 必要時 |
| `.claude/agents/*.md` | Agent 固有責務（first-class 9） | 委任時 |
| `.claude/workflows/*.js` | Deterministic orchestration | 実行時 |
| `state.json` / reasoning-bank / routing_log | 経験・実行履歴（hooks が要約注入） | SessionStart / compact 後 |
| `.claude/claudeos/policy/*.md`、`docs/**` | 詳細方針・仕様 | 参照時 |

## 2. Before / After

| 指標 | v9 | v10 |
|---|---|---|
| 常時ロード（静的） | 49.6KB（/etc 8.2KB + CLAUDE.md 41.4KB, 699 行） | ≈20KB（/etc 8.2KB + CLAUDE.md ≈10KB + rules ≈2KB） |
| CLAUDE.md コピー | 3 同一 + 1 旧 Neon 版 + 1 stale | 4 同一（examples 含む）、旧コピー削除 |
| /goal 本文 | CLAUDE.md §25 に 4.1KB 複製 | START_PROMPT.md のみ（ポインタ化、bats で検証） |
| 重複 | /etc と ≈45% 重複 | 重複節は policy/*.md へ逐語移設し CLAUDE.md からは削除 |
| skills | 66 stub（frontmatter なし、非ロード） | 実 skill 8 本（frontmatter、allowed-tools） |
| agents | 43（非ロード） | first-class 9 を auto-discovery、catalog は必要時 |
| hooks 注入 | session-start が dashboard / Agent Teams パターン / 週次フェーズを毎回注入 | resume 要旨のみ + compact 後は ≤12 行の退避要旨 |

## 3. 検出した問題（監査）と対処

| 問題 | 対処 |
|---|---|
| duplicate instruction（§2/§5/§8/§16/§17/§19/§21/§22/§24 が /etc と重複） | policy へ移設、CLAUDE.md は要約 |
| obsolete instruction（TeamCreate、push-notify、5h ルール、週次フェーズ、project-switch ローテ） | hooks から除去、system docs は参照専用 |
| unused skill（63 stub、`.agents/skills`） | 配布停止（deprecated）、`.agents/skills` は削除候補 |
| oversized prompt（§25、START_PROMPT 6KB） | START_PROMPT を 3,338 字へ、§25 ポインタ化 |
| unnecessary context（session-start の dashboard URL 等） | 除去 |
| contradictory policy（/etc Neon vs root ローカル PG、§5 vs §13、優先順位の三重主張） | Local PostgreSQL に統一、優先順位は「組織方針 > 中央 GitHub Policy（GitHub 運用のみ） > CLAUDE.md」と明記。/etc の Neon 記述は CENTRAL_POLICY_CONFLICT |

## 4. 運用ルール

- CLAUDE.md へは「毎セッション必要な事実」だけを書く。手順は skill、パス固有の規約は `.claude/rules`（`paths`）、詳細は docs へ
- `/doctor` の trim 提案と `/skill-doctor` の未使用 skill 報告を週次で確認する
- `/model` `/effort` はセッション冒頭で固定し prompt cache を壊さない。長い出力はサブエージェントに隔離する
- 圧縮後の継続は `post-compact-reinject.js` の要旨と `state.json` を再確認してから行う
