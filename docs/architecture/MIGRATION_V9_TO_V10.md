# MIGRATION_V9_TO_V10 — ClaudeOS v9 → v10 移行記録

状態: 2026-09-07（branch `feat/claudeos-v10`）
関連: `ARCHITECTURE_V10.md`、`CURRENT_ARCHITECTURE.md`、`CHANGELOG.md`

## 1. 移行の原則

```text
Claude Code Native機能 > Thin ClaudeOS Adapter > Custom Implementation
```

- 全面 rewrite はしない。Phase 0〜14 の順で小さく戻しやすい変更を積む
- 既存機能は理由なく削除しない。`REPLACE_WITH_NATIVE` / `DEPRECATE` は deprecated として保持し、Self-Improvement サイクルで整理する
- 公式仕様で確認できない機能は `UNVERIFIED` / `EXPERIMENTAL` として隔離する
- ユーザーの未コミット変更は保護する（本移行では、作業中に `git reset --hard` により作業ツリーが一度消失し、把握していた内容から全て復元した。再発防止として「stash が失敗したら reset しない」「作業はこまめに commit」を運用規約に追加）

## 2. Phase 別の変更

| Phase | 内容 | 状態 |
|---|---|---|
| 0 Baseline | `claude 2.1.263` / `claude doctor` 問題なし / `npm test` 636 ok 2 fail（START_PROMPT 4000 字超と §25 不一致、共に未コミット変更起因） / `npm run lint` PASS / PostgreSQL 16 稼働 | 完了 |
| 1 Capability audit | Agents / Subagents / Background / Agent View / Teams / Workflows / Worktrees / Skills / Hooks / MCP / Cross-session / Auto Mode / Permission / Context / Cache / Model を公式 docs・changelog で確認（`CLAUDE_CODE_COMPATIBILITY.md`） | 完了 |
| 2 Compatibility matrix | `config/claude-code-compat.json` + `lib/claude-capability.sh` + `libexec/diag-claude-compat.sh`（メニュー 17）。minimum 2.1.224 / recommended・tested 2.1.263。Version 判定より flag/subcommand probe を優先 | 完了 |
| 3 Neon audit | 8 ファイル・12 の中央ポリシー矛盾を分類（`scratchpad` 監査 → 本書 §5） | 完了 |
| 4 Local PostgreSQL migration | CLAUDE.md §5/§12/§13/§17/§21、START_PROMPT、data-architecture-protocol v2、docs/architecture 分割（PostgreSQL / Cloudflare / GitHub）。`lib/postgres.sh` + `bin/pg-ops.sh` + systemd テンプレート | 完了 |
| 5 Context / Skills | CLAUDE.md 662 行 → 62 行、policy 4 文書へ逐語移設、`.claude/rules` 5 本、実 skill 8 本を配布対象に | 完了 |
| 6 Native agent orchestration | Lazy Agent Catalog（first-class 9）、`scripts/tools/agent-router.js` + golden eval、`/agent-router` skill | 完了 |
| 7 Hooks modernization | 廃止 3 / 移動 1 / 新設 1 / async 化 / `${CLAUDE_PROJECT_DIR}` / if フィルタ / heavy-sync 間引き / 配線整合性テスト | 完了 |
| 8 Security / Permission | allow 縮小・deny 追加・defaultMode 削除・`--permission-mode auto --permission-prompts none`・skip-permissions 撤去・SMTP 資格情報の隔離 | 完了 |
| 9 Self-Improvement + Evals | `SELF_IMPROVEMENT_ARCHITECTURE.md`、`/improver` skill、golden eval（router）、PR ゲート | 完了 |
| 10 AI-Native SDLC | `AI_NATIVE_SDLC.md`、`sdlc/*.md` テンプレート、`/sdlc-scale` skill | 完了 |
| 11 Observability | Mission Control `/api/v10` + 🧬 v10 Platform パネル（PostgreSQL / Capability / native agents / routing / hooks） | 完了 |
| 12 Regression / Security | `npm test` / `npm run lint` / hooks-settings.test / router eval / postgres 実機 drill | 完了（結果は最終報告） |
| 13 Documentation | 本書ほか必須文書 12 本 + README / CHANGELOG / SOURCE_OF_TRUTH | 完了 |
| 14 Final review | PR（Approval PR: security policy と方針文書の変更を含む） | Y/N 待ち |

## 3. Claude Native へ移行した機能（Custom → Native）

| 旧 ClaudeOS 実装 | Native 機能 | 扱い |
|---|---|---|
| `verify-goal-set.js`（/goal テンプレ検査 hook） | `/goal`（native、`claude -p "/goal ..."`） | 削除（検査は bats へ） |
| `suggest-compact.js` | `/autocompact` / `/context` | 削除 |
| `notify-stable.js` の `claude push-notify` | native 通知（`agentPushNotifEnabled`）/ Notification hook | 呼び出し削除 |
| `agent-teams-tracker.js` の `TeamCreate` 分岐 | Agent Teams（v2.1.178 以降は named Agent spawn） | 分岐削除 |
| 43 agents の全件 auto-discovery | first-class 9 体のみ `.claude/agents`、他は catalog | Lazy load |
| 66 skill stub の全件配布 | frontmatter 付き実 skill 8 本 | stub は deprecated 保持 |
| CLAUDE.md §25 の /goal 全文複製 | START_PROMPT.md（`libexec/goal-extract.sh`） | ポインタ化 |
| `--dangerously-skip-permissions` 常用 | `--permission-mode auto --permission-prompts none` | 緊急 opt-in のみ |
| `CLAUDE.md` 27 節（41KB 常時ロード） | CLAUDE.md 要約 + `.claude/rules`（paths）+ skills + policy 参照 | Context −70% |

## 4. 維持した Custom 機能（Linux Operations Layer）

cron / Supervisor（re-launch-to-goal、日次上限、credit guard）/ tmux 多重化 / systemd / watchdog・heartbeat / 多プロジェクト探索と Supervisor 配布 / Mission Control / メール報告 / release-check / GitHub PR flow。Claude Code Native では代替できない OS レベル機能として KEEP（`OPERATIONS_MODEL.md`）。

## 5. Neon → Local PostgreSQL

| 対象 | 変更 |
|---|---|
| CLAUDE.md §5/§8.3/§12/§13/§17/§21（4 コピー同一） | DB branch → database/role、preview DB、Cloudflare→PG 直接接続禁止、§13 全面再設計、DB 破壊操作を Approval PR 対象化、本番基盤をホスト systemd へ |
| `Claude/templates/claude/START_PROMPT.md` | 到達不能な完了条件（Cloudflare Preview で DB 接続 / CI から Migration）をホスト側へ。4000 字以内・引用符付き |
| `Claude/templates/claudeos/docs/data-architecture-protocol.md` | v2（Local PostgreSQL 正本）。v1 は Deprecated 付録 |
| `docs/architecture/CloudflareNeonGitHub自動化仕様.md` | Deprecated バナーを付与し履歴保持。`GitHub開発運用仕様.md` / `PostgreSQLデータ運用仕様.md` / `Cloudflare公開基盤仕様.md` へ責務分離 |
| `Claude/templates/claude/claudeos/CLAUDE.md` | 未参照の旧コピー（Neon）を削除 |
| `CHANGELOG.md:160`、`Claude/templates/claude/CLAUDE-back.md` §8.6 | 履歴として保持（Deprecated） |

**CENTRAL_POLICY_CONFLICT（本リポジトリからは編集しない。Deep-Seek-Harness-Project 側で対応が必要）**

| # | 中央ファイル | 内容 |
|---|---|---|
| CP1 | `GITHUB_POLICY.md:126` | 「Cloudflare / Neon 運用: CloudflareNeonGitHub自動化仕様.md」を参照 |
| CP2〜CP12 | `docs/architecture/CloudflareNeonGitHub自動化仕様.md` :1, :11, :14, :72–79, :83–85, :88–93, :195, :226 | Neon を共通基盤・`NEON_API_KEY` 必須・`mcp__neon__*`・project/branch モデル・「Neon は既存設定をそのまま利用」 |

対応案: 中央側で §3 を「PostgreSQL（Local 正本）」へ改訂し、Neon を Deprecated 付録へ。本リポジトリは `AGENTS.md` の中央参照に DB 注記を追加済み。

**ホスト側の残存 Neon 依存（HUMAN_APPROVAL）**: `~/.claude.json` のユーザースコープ MCP サーバー 10 件（`postgres-*-production` 等）が Neon の接続文字列（平文パスワード込み）を保持し、全件が接続タイムアウトしている。削除または localhost へ再設定し、Neon 側パスワードを rotation することを推奨（値は本書に記載しない）。

## 6. Rollback

- 本 PR 全体: `git revert` で v9 の CLAUDE.md（27 節）、hooks 配線、permissions に戻る。policy 文書は逐語移設のため内容の損失はない
- Local PostgreSQL 基盤: 新規ファイルのみ（既存 DB へは変更なし）。systemd unit は `--install` を実行しない限り配置されない
- 権限: `.claude/settings.json` を v9 に戻すと `defaultMode: auto`（無視される）と広い allow が復活する。旧設定は git 履歴で参照可
- 起動フラグ: `CCSU_TMUX_SKIP_PERMS=1` / `CLAUDEOS_TUI_SKIP_PERMS=1` / `CLAUDEOS_HEADLESS_SKIP_PERMS=1` で旧挙動を一時再現可能（緊急用）

## 7. 既知の残課題

- runtime `.claude/claudeos/scripts/hooks` と template の間に v10 以前からの drift（agent-transcript / auto-format / quality-gate-check / reasoning-bank / tdd-coverage-scan / webhook-notifier）。次サイクルで template を正本として再同期する
- `Claude/templates/claudeos/skills` の 63 stub と `.claude/claudeos/commands` の native 衝突（`code-review.md` / `verify.md`）は deprecated として保持中。整理は Self-Improvement サイクルへ
- `docs/GH-Claude.txt`（未追跡、`.git/info/exclude`）に資格情報パターンの文字列がある。値は確認せず、削除と rotation を推奨
- `.agents/skills`（未追跡、Codex 向け sed コピー）は参照されていない。削除候補
- 中央ポリシーの Neon 記述（CENTRAL_POLICY_CONFLICT）
