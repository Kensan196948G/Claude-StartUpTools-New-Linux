# CURRENT_ARCHITECTURE — v10 移行前の現状記録（Baseline Audit, 2026-09-07）

状態: Baseline（変更前）。監査レポート全文は `docs/architecture/audits/2026-09-07-*.md`。
対象: `Claude-StartUpTools-New-Linux` v4.0.0-linux @ `44ba960`（origin/main）

> 🆕 **v11 移行（2026-09-09 着手）**: Claude Managed Agents を Autonomous Execution Plane
> とする P0（実行基盤）を開始。監査と実施状況は
> `docs/architecture/audits/2026-09-09-managed-agents-v11-p0.md`、
> 設定契約は `config/managed-agents.json.template`（実行可能契約へ昇格済み）、
> Goal Router への実行 Plane 選択（`execution_plane=managed|local`・fail-safe local）は
> `lib/goal-router.sh` に統合済み。Thin Adapter（Session/Environment Manager）と
> Permission Policy Engine は人間判断待ち（HUMAN REVIEW・監査 §6）。

## 1. Baseline 実測

| 項目 | 結果 |
|---|---|
| `claude --version` | 2.1.263（native install, auto-update latest） |
| `claude doctor` | No installation issues。managed settings remote fetch 401（API-key auth のため org policy 未適用）。Remote Control は subscription auth が必要 |
| `npm test` | 638 tests: 636 ok / 2 not ok（`goal-inject.bats` 215/216: 未コミットの START_PROMPT.md 書換で /goal が 4000 字超・§25 不一致） |
| `npm run lint` | PASS（shellcheck -S error） |
| gitleaks | ローカル未導入（CI の `security-scan.yml` で実行） |
| PostgreSQL | server 16.14（`postgresql@16-main` online, socket）。client: psql 18 / pg_dump 17 / pg_restore 16 が PATH に混在 → `PG_BIN` 固定が必要 |
| git | local main が origin/main より 1 commit 遅れ。未コミット: CLAUDE.md ×3 の `Neon→ローカルPostgreSQL` 置換、START_PROMPT.md 全面書換、hook 出力データ |

## 2. コンポーネント分類（約 660 項目）

| 分類 | 件数 | 主な内容 |
|---|---|---|
| KEEP | ≈157 | cron / Supervisor / tmux / systemd / config-loader / release-check / github-pr-flow / heartbeat / audit-trail / pre-compact / webhook / Mission Control |
| MODERNIZE | ≈241 | model-router、team-runner、session-start/end、usage/agent trackers、templates 大半、docs |
| REPLACE_WITH_NATIVE | ≈49 | 43 agents の全件 discovery、commands（code-review / verify / refactor-clean / multi-* / orchestrate / session-info / cron-*）、verify-goal-set、suggest-compact、notify-stable(push-notify)、claudeos/rules・skills stub、statusline 設定 |
| DEPRECATE | ≈80 | 言語別 reviewer / build-resolver、framework skill 群、v9 の 5h・週次フェーズ・STABLE-N ルール |
| REMOVE_CANDIDATE | ≈102 | 66 skill stub の大半、27 command stub、evaluate-session、dreaming(hooks 配下)、`.agents/skills`、CLAUDE-back、未参照 CLAUDE.md コピー |
| EXPERIMENTAL | ≈13 | Agent Teams 連携、Managed Agents PoC、parallel-cron、v10 WIP |

## 3. OS レイヤ（Claude Code Native が代替できない境界 = KEEP）

| 能力 | 担当 | 境界 |
|---|---|---|
| 無人で新規 `claude` プロセスを起動（cron / timer / @reboot） | cron-manager, cron-schedule, cron-launcher | `/loop` `/goal` `CronCreate` はセッション内、Routines はクラウド |
| Goal 到達まで再起動（日次上限・クラッシュループ・credit guard） | lib/supervisor.sh, autonomy.sh | `claude --bg` は 1 セッションの監視のみ |
| 多プロジェクト探索・順序・ポリシー配布 | config-loader, launcher-common, queue, supervisor-manifest, onboard | Claude Code は単一プロジェクト |
| tmux 多重化・ログ捕捉 | tmux-runner, monitor-sessions | `claude agents` は端末多重化しない |
| systemd unit（プロジェクト / dashboard / DB backup） | systemd-manager, dashboard-service, pg-ops units | — |
| watchdog / heartbeat / credit ledger | cron-launcher, supervisor, credits | Native の retry/stream watchdog はプロセス内 |
| モデルの外側の gate（auto-merge gate / release-check / trust ledger） | github-pr-flow, release-check, trust-score | hook でも実装可だがモデルの届かない場所に置く |
| メール報告 | report-and-mail.py | Native channel なし |

## 4. 主要欠陥（監査で検出）

| # | 欠陥 | 対応 |
|---|---|---|
| D-A | `.claude/settings.json` が存在しない 3 hook（TeammateIdle/TaskCreated/TaskCompleted）を参照 → MODULE_NOT_FOUND ノイズ | Phase 7 で配線除去 |
| D-B | Stop hook が毎ターン同期で 5〜7 回 gh を呼ぶ（3〜10 s/turn） | Phase 7: async + 間引き |
| D-C | `claude push-notify` は存在しない | Phase 7 |
| D-D | project-level `defaultMode: auto` は無視（≥2.1.257）、`autoMode.hard_deny` は project では未適用（実測） | Phase 8 |
| D-E | allow に `bash/sh/env/curl/rm/kill/timeout` ワイルドカード → deny が迂回可能。`mcp__github__*` で merge/push/delete 可 | Phase 8 |
| D-F | L1 `--tmux` と cron TUI 退避が `--dangerously-skip-permissions`。`~/.env-claudeos`（SMTP）が claude 環境へ export | Phase 8 |
| D-G | CLAUDE.md 699 行 ×3 コピー + 旧コピー 2、/etc と 45% 重複、Neon/ローカル PG の矛盾 | Phase 4/5 |
| D-H | `.claude/agents` / `.claude/rules` 不在、66 skill に frontmatter なし → kernel が Claude Code に見えていない | Phase 5/6 |
| D-I | commands が native `/code-review` `/verify` と衝突、cron 系 command が存在しない `cron-cli.sh` を参照 | deprecated 保持（次サイクル） |
| D-J | `bin/set-statusline.sh` が存在しない `statusline.js` を参照、`init-claudeos-project.js` の STATE_TEMPLATE ソース欠落 | 残課題（次サイクル） |
| D-K | `docs/GH-Claude.txt`（未追跡）に資格情報パターン | HUMAN: 削除と rotation |
| D-L | `~/.claude.json` に Neon DSN（平文パスワード）10 件、全件タイムアウト | HUMAN: 削除 / rotation |
| D-M | Ruleset 必須チェック名の改行混入や未帰属コミットで PR が BLOCKED になる系統的リスク（Codex 側で実測） | `GitHub開発運用仕様.md` に規約化 |

## 5. Context 負荷（変更前）

静的 49.6KB / セッション（/etc 8.2KB + CLAUDE.md 41.4KB）≈ 15〜19k tokens、＋ hook 注入 1.5KB、＋ 初回プロンプト 6〜10.6KB。→ v10 目標 ≈19KB（−60%）。
