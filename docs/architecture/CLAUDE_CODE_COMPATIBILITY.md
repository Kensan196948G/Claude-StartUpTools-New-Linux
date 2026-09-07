# CLAUDE_CODE_COMPATIBILITY — Claude Code 互換性ポリシーと機能マトリクス

状態: 2026-09-07（changelog 2.1.263 まで確認）
正本: `config/claude-code-compat.json`（機械可読）、`lib/claude-capability.sh`、`libexec/diag-claude-compat.sh`（メニュー 17）

## 1. バージョン方針

| 区分 | 値 | 意味 |
|---|---|---|
| minimumSupportedVersion | 2.1.224 | cross-session messaging（SendMessage/ListAgents）が入った版。これ未満は `claude update` を促す |
| recommendedVersion | 2.1.263 | 推奨導入版（tested と同一を原則） |
| testedVersion | 2.1.263 | bats / node テストと実機起動を確認した版 |

`requiredMinimumVersion` は managed settings 用のキーであり、`Claude/templates/claude/settings.json` に置いた値は project settings では効力が未確認（UNVERIFIED、シグナルとして保持）。起動時の判定は `ccsu_claude_version_policy` が `supported / below-minimum / newer-than-tested` を返す。

## 2. Capability Detection（Version 判定より優先）

「version ≥ X だから機能あり」ではなく、`claude --help` の flag / Commands を probe して判定する（結果は version 別にキャッシュ）。

| 種別 | 判定 | 例 |
|---|---|---|
| flag | `--help` に flag が存在 | `--name`, `--bg`, `--worktree`, `--permission-prompts`, `--restricted`, `--bare`, `--json-schema` |
| subcommand | Commands 節に存在 | `agents`, `attach`, `ultrareview`, `doctor` |
| env | 有効化環境変数 | `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` |
| unverified | セッション内機能で CLI から確認不能 | `/goal`, `/workflows`, SendMessage |

利用側: `ccsu_claude_capability <id>`（0 available / 1 missing / 2 unknown）。launcher は missing なら flag を付けず、unknown なら docs 準拠の既定を使う。

## 3. 機能マトリクス（2.1.263 実測）

| 機能 | 状態 | 版 | probe | v10 での扱い |
|---|---|---|---|---|
| Subagents（`.claude/agents`, frontmatter 拡張、fork、nesting） | GA | — | unverified | first-class 9 体を配布 |
| Background sessions / Agent View（`--bg`, `claude agents`, attach/logs/stop/respawn/rm, daemon） | research preview | 2.1.212+ | flag/subcommand: available | router が AgentView/BackgroundAgent を選択。Mission Control が `claude agents --json` を表示 |
| Agent Teams（in-process 既定、tmux/iTerm2、TeammateIdle/Task* hooks） | experimental | 2.1.178+ | env | 通信が必要な場合のみ。gate hooks は配線しない |
| Dynamic Workflows（`/workflows`, `ultracode`, `.claude/workflows/*.js`） | GA（有料プラン） | 2.1.154+ | unverified | 大量調査/監査で使用。`workflowSizeGuideline` |
| Worktrees（`--worktree`, `.worktreeinclude`, `worktree.baseRef`, WorktreeCreate/Remove hooks） | GA | — | flag: available | 並列編集の分離を必須化 |
| Skills（frontmatter、bundled `/code-review` `/verify` `/batch` `/loop` `/doctor` `/skill-doctor`） | GA | — | — | 実 skill 8 本、stub は不配布 |
| Hooks（33 イベント、command/http/mcp_tool/prompt/agent、async/if/once） | GA | — | — | Phase 7 で近代化 |
| MCP（2026-07-28 spec、`managedMcpServers`, `--strict-mcp-config`） | GA | 2.1.259+ | — | `.mcp.json` 維持、Neon MCP なし |
| Cross-session messaging（`/list-agents`, SendMessage, `crossSessionInbound`, `isolatePeerMachines`） | GA（同一マシン全プロバイダ 2.1.248+） | 2.1.224+ | `--name` で間接 | team-runner が使用 |
| Auto mode / permissions（`--permission-mode auto`, `--permission-prompts none`, `--restricted`, deny/allow/ask） | GA | 2.1.259+ (`--permission-prompts`) | flag: available | 無人実行の標準 |
| `/goal`（Stop hook ベース、Haiku 判定、`claude -p "/goal"`、4000 字） | GA | 2.1.139+ | unverified | START_PROMPT から注入 |
| `/loop` + `.claude/loop.md`、CronCreate、Routines（`/schedule`、cloud） | GA / research preview | — | unverified | cron は ClaudeOS が担当。Routines は claude.ai 認証が前提のため保留 |
| Channels（Telegram/Discord/iMessage） | research preview | — | flag: missing（preview 中は help に出ない） | 対象外 |
| Context: `.claude/rules`（paths）、auto memory、`/doctor` trim、`claudeMdExcludes`、`bashOutputMaxChars` | GA | 2.1.261 | — | Phase 5 |
| Prompt cache（`/cost` prompt_cache、1h TTL、`subagentPromptCacheTtl`、`experimental.cacheTtl`） | GA | 2.1.248+ | — | `/model` `/effort` はセッション冒頭で固定 |
| Model（Fable 5.1 既定、Opus 5、`fallbackModel`、`/advisor`、PreModelSwitch/PostModelSwitch hooks） | GA | 2.1.257 | — | model-router は `--model/--effort` 経由（Native へ寄せる候補） |
| Self-hosted environments、managed Code Review、Compliance API | Team/Enterprise | — | — | 対象外 |

## 4. 更新手順

1. `claude update` 後に `bash libexec/diag-claude-compat.sh` を実行し、`missing` になった capability がないか確認する
2. `config/claude-code-compat.json` の `tested` / `recommended` / `lastVerifiedAt` を更新し、新 capability は probe 付きで追加する
3. `bats tests/bats/unit/claude-capability.bats` と `npm test` を通す
4. changelog で廃止された機能（例: TeamCreate、teammateDefaultModel、push-notify）は hooks / docs から除去し、`UNVERIFIED` は隔離する
