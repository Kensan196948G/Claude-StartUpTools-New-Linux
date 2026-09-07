# ClaudeOS context / hooks / commands / skills / agents / permissions audit

Target: `/home/kensan/Projects/Claude-StartUpTools-New-Linux` (HEAD `76ba161`, branch main)
Runtime: Claude Code 2.1.263 native (`claude --version`, `claude doctor` baseline). Read-only audit; no files modified; no secret values printed.
Verification legend: **VERIFIED** = confirmed against the 2.1.263 CLI (`claude --help`, `claude auto-mode`) or by running a read-only script; **UNVERIFIED** = not confirmable offline against official docs.

---

## 0. Executive summary

| Area | Key number | Headline |
|---|---|---|
| Context per session | **49,630 B static** (/etc 8,199 + root CLAUDE.md 41,431) ≈ 15–19k tokens (JP-heavy estimate) + ~1.5 KB hook-injected + 6.2–10.6 KB first-turn prompt | Root CLAUDE.md is 699 lines (3.5x the ~200-line guidance); ~55% of it restates the managed `/etc/claude-code/CLAUDE.md`; §25 alone is a 4.1 KB `/goal` prompt that is only useful once |
| Hooks | 18 scripts + package.json; 11 wired commands over 7 events; **3 wired scripts missing** (TeammateIdle/TaskCreated/TaskCompleted) | Stop hook (`session-end.js`) fires every turn and makes 5–7 `gh` network calls synchronously (est. 3–10 s/turn); `claude push-notify` does not exist in 2.1.263; `verify-goal-set.js` warns on every startup because the template no longer matches |
| Commands | 46 unique (+2 deployed copies); 27 stubs (≤3 lines); **9 REPLACE_WITH_NATIVE**; 2 native-name collisions when deployed (`/code-review`, `/verify`) | `.claude/claudeos/commands` is not loaded by Claude Code; 3 commands call a non-existent `~/.claudeos/cron-cli.sh` |
| Skills | 72 files; **63/66 claudeos skills are one identical 66-line template with no frontmatter**; 10 duplicate groups; only **3 loadable** in this repo (`.claude/skills/*`) | `.claude/claudeos/skills` is neither on a discovery path nor a registered plugin; `.agents/skills` is an untracked sed-renamed copy with broken paths |
| Agents | 43 files; **0 loadable** here (no `.claude/agents`, plugin not installed); 7 without frontmatter; 41 with UTF-8 BOM | Team mode (`lib/team-runner.sh`) never reads them; proposal: 9 first-class, 9 catalog, 18 merge, 7 remove |
| Permissions | 49 Bash allow patterns incl. `rm`, `kill`, `curl`, `bash`, `sh`, `env`, `timeout`; 6 deny rules (bypassable via `bash -c`); `mcp__github__*` wildcard (incl. `delete_repository`, `merge_pull_request`, `push_files`) | Project-level `defaultMode: auto` is ignored (v2.1.257+); project-level `autoMode.hard_deny` is **not applied** (empirically: `claude auto-mode config` from the repo shows only the shipped default); `--permission-prompts none` unused; `--dangerously-skip-permissions` still used in L1 `--tmux` and cron TUI fallback; `~/.env-claudeos` (SMTP creds) is exported into the claude process env |

---

## 1. Context load audit

### 1.1 What is loaded into every session (interactive, repo root)

| Source | Bytes | Lines | Loaded? | Notes |
|---|---|---|---|---|
| `/etc/claude-code/CLAUDE.md` (managed) | 8,199 | 165 | Yes, every session | Read-only; 8 sections; authoritative policy |
| `CLAUDE.md` (repo root) | 41,431 | 699 | Yes, every session | 27 sections; identical bytes to `Claude/CLAUDE.md` and `Claude/templates/claude/CLAUDE.md` |
| `.claude/CLAUDE.md` | — | — | Absent | (the ClaudeOS v9.0 file lives only in the sibling Codex repo) |
| `~/.claude/CLAUDE.md` | — | — | Absent | |
| `.claude/rules/*.md` | — | — | Absent (dir missing) | `.claude/claudeos/rules/**` (14 stubs, 2.0 KB total) are NOT loaded — not a standard path |
| `AGENTS.md` | 1,405 | 34 | **UNVERIFIED** (Codex convention; not a documented Claude Code memory file) | References a *different* repo's policy (`/home/kensan/Projects/Deep-Seek-Harness-Project/GITHUB_POLICY.md`) |
| Auto memory `MEMORY.md` for this project | — | — | None found under `~/.claude/projects/` for this path | |
| SessionStart hook `session-start.js` → `additionalContext` | ~1.0–1.5 KB (dynamic) | ~15 | Yes (startup/resume/clear) | Resume summary, week-phase, Agent-Teams "pattern", dashboard URL, workflows gate, ReasoningBank top-3 |
| SessionStart hook `verify-goal-set.js` → stdout | ~180 B | 2 | Yes (startup/resume/clear) | Always the warning `START_PROMPT.md に /goal "..." ブロックが見つかりません` (VERIFIED by running the script) |
| **Static total** | **≈49.6 KB** | **864** | | ≈ 15–19k tokens (mixed JP/EN estimate; JP ≈ 1 token per 1–2 chars) |

First-turn prompt injected by the launchers (consumes context every session; not a memory file):

| Launch path | Prompt content | Bytes |
|---|---|---|
| L1 direct TUI / L1 `--tmux` (`bin/start-claude.sh` → `direct__run_tui_foreground`, `lib/tmux-runner.sh`) | `Claude/templates/claude/START_PROMPT.md` (copied to `<project>/.claude/START_PROMPT.md` on every launch by `lib/template-sync.sh`) | 6,184 |
| S1 / cron headless (`Claude/templates/linux/cron-launcher.sh` L300–370) | `/goal "…"` block from `Claude/templates/claudeos/goals/<goal_type>.md` via `libexec/goal-extract.sh` (2,246 B for `mvp-release` … 4,063 B for `safe-auto-merge`) + `[Cron Session Resume] …` header (~300 B) + START_PROMPT.md (6,184 B) | ≈ 8.7–10.6 KB |
| Direct headless once (`start-claude.sh direct__run_headless_once`) | START_PROMPT.md only — **no /goal injection, no resume header** (inconsistent with cron path) | 6,184 |
| T team mode (`lib/team-runner.sh`) | `TEAM_START_PROMPT.md` into the CTO pane only (copy-if-missing) | 2,580 |

How `/goal` is injected (VERIFIED by reading the scripts):
- `START_PROMPT.md` begins with a **bare** `/goal` line followed by a blank line and 6 KB of prose. In interactive L1 the whole file is passed as the first prompt, so the entire text becomes the goal argument (≈2.3k chars; under the 4,000-char limit the cron launcher documents).
- `libexec/goal-extract.sh` extracts `/goal "…"` from `goals/<type>.md`, appends `- or stop after 20 turns` if missing, truncates to 4,000 chars, and `goal_extract__strip_block` removes any *quoted* `/goal "…"` block from START_PROMPT. The bare `/goal` line does **not** match `/goal[[:space:]]*"` and is therefore left in place → the cron prompt contains the injected `/goal "…"` **and** a second bare `/goal` line mid-prompt. Whether `claude -p` treats the second one as a directive is UNVERIFIED; flag as a crash-loop risk (the launcher comment says double `/goal` caused `got N>4000 → 0 ターン即終了`).
- `verify-goal-set.js` expects the quoted form (`/goal "`) and a keyword set from the old v9 prompt (`CTO全権委任`, `AgentTeams`, `DynamicWorkflows`, `CodeRabbit`, `5時間`…). The current START_PROMPT has neither → the hook is permanently mis-tuned and prints a warning every session.

### 1.2 Duplicate instructions

| A | B | Overlap | Note |
|---|---|---|---|
| root `CLAUDE.md` §16 品質ゲート (8 items) | `/etc` §5 品質ゲート (8 items) | ~95% verbatim | Both say `gh pr merge --auto --squash`, same 2026-08-06 delegation |
| root §17 Approval PR list | `/etc` §5 高リスク変更 list | ~90% | root adds Cloudflare Access / 大規模rollback |
| root §22 停止条件 | `/etc` §6 | ~80% | |
| root §5 + §19 secrets | `/etc` §7 | ~80% | |
| root §8 自律実行 (51 lines) | `/etc` §3 | ~70% | root is a superset |
| root §21 Phase 2/3 + Cloudflare/DB platform | `/etc` §4 | ~70% | **Contradiction**: `/etc` = "Cloudflare + **Neon** PostgreSQL"; root = "Cloudflare + **ローカルPostgreSQL**" |
| root §24 最終報告 / §25 GO・CONDITIONAL GO・NO-GO | `/etc` §8 | ~60% | |
| root §2 役割 | `/etc` §2 | ~60% | |
| root §9 Agent roles table | `START_PROMPT.md` 【Agent Team】 | same 7 roles, different names (Lead/Explore/Architecture… vs Design/Frontend/Backend…) | Two role vocabularies |
| root §10 cycle (Monitor→…→Improvement) | `START_PROMPT.md` 【Autonomous Engineering Loop】 (13-step) and `/etc` §2 (6-step) | three different loop definitions | |
| root §25 embedded `/goal` (4,138 B) | `START_PROMPT.md` (6,184 B) and `Claude/templates/claudeos/goals/*.md` (7 files, 17.8 KB) | three "canonical" goal prompts | §25 is loaded every session but only useful once |
| root §27 cross-session rules | `docs/claude/19_クロスセッションメッセージング.md` + `TEAM_START_PROMPT.md` 遵守事項 | ~100% | |
| root `CLAUDE.md` | `Claude/templates/claude/claudeos/CLAUDE.md` (39,696 B) | identical except §13 heading still says "Neon PostgreSQL" and §27 is missing | stale near-copy; plus 2 byte-identical copies (`Claude/CLAUDE.md`, `Claude/templates/claude/CLAUDE.md`) and 2 backups (`Claude/CLAUDE-back.md` 6.7 KB, `Claude/templates/claude/CLAUDE-back.md` 36.8 KB = the old v9 format) |
| `.claude/claudeos/system/orchestrator.md` | itself | file contains **three** concatenated "Orchestrator" documents | `token-budget.md` and `project-switch.md` likewise contain two copies each with "（既存でOK）" placeholders |
| `Claude/templates/claude/instructions/00-goal-system.md` | `Claude/templates/claude/claudeos/core/00-goal-system.md` | byte-identical | |
| `.claude/claudeos/**` | `Claude/templates/claudeos/**` | 91 diff lines: 16 files only in runtime, 11 only in template, rest content drift (hooks: 12 differ) | `docs/SOURCE_OF_TRUTH.md` says templates are the source; runtime copy has regressed in places (agents lost frontmatter, `update-codemaps.md` degraded) |

Measured: of root CLAUDE.md's 41.4 KB, sections §2/§5/§8/§16/§17/§19/§21/§22/§24 (≈8.6 KB) restate `/etc`; §25 (4.1 KB) is a one-shot prompt; §6/§10/§11/§12/§13/§14/§15/§20/§23 (≈5.6 KB) are procedural checklists better served as skills/reference docs. Roughly **18 KB of 41 KB (≈45%) is either duplicated policy or procedure**, and another ~10 KB is checklist prose that Claude does not need on every turn.

### 1.3 Obsolete / contradictory / oversized

| Item | Location | Problem | Status |
|---|---|---|---|
| `claude push-notify` | `.claude/claudeos/scripts/hooks/notify-stable.js:31-36` | Not a subcommand in 2.1.263 (`claude --help` Commands list has no `push-notify`) → always falls back to `console.log`; launches the claude binary uselessly when an event fires | **VERIFIED obsolete** |
| `TeamCreate` branch + `team_name` fallback | `agent-teams-tracker.js:130-152` | Tool removed v2.1.178; dead code (file header already says so) | VERIFIED obsolete |
| Week-phase table (Build/Quality/Stabilize/Release by week), Agent-Teams pattern A/B/C, "5 時間" rules | `session-start.js`, `notify-stable.js`, `system/*.md`, `loops/*.md`, `roles/*.md` | These implement the **ClaudeOS v9.0 CLAUDE.md** that is no longer this repo's root CLAUDE.md (root is the 27-section policy with no 5h/STABLE-N/token-zone rules). Hooks inject rules the policy does not state | Contradiction (policy vs. hook behaviour) |
| `system/project-switch.md` Mon–Sun schedule (ServiceGrid/ITSM/HelpdeskAI/…) | `.claude/claudeos/system/project-switch.md` | Hard-coded project rota unrelated to `config/config.json` projects | Obsolete |
| `.claude/claudeos/README.md` | L27 `New-CronSchedule.ps1 でスケジュール登録・管理（メニュー 14）`, "30 体の専門サブエージェント" (43 exist) | Windows leftovers | Obsolete |
| "ローカルPostgreSQL PostgreSQL" | root `CLAUDE.md` §13 heading and body, §21, §25 | sed artifact from "Neon PostgreSQL" → "ローカルPostgreSQL"; §8.3/§13 still speak of "developmentまたはpreview **branch**", "DB branch" (Neon branching concept) | Contradictory wording |
| §5 "Linuxローカルをソースコードや業務データの唯一の正本にしない" vs §13 "ローカルPostgreSQL PostgreSQLを業務データの正本として扱う" | root `CLAUDE.md` | Internal contradiction | Contradiction |
| Production DB platform | `/etc` §4 (Neon) vs root §21 (ローカルPostgreSQL) vs template claudeos/CLAUDE.md §13 (Neon) | Three files disagree | Contradiction |
| Precedence claims | `/etc` §1 ("最上位"), root §3 (own order: system > user > more-specific CLAUDE.md > this file), `GITHUB_POLICY.md` §2 ("本ポリシーは CLAUDE.md に優先する"), `AGENTS.md` (points to another repo's GITHUB_POLICY) | Three documents each claim to be the top; GITHUB_POLICY is a DeepSeek-harness artefact leaked in | Contradiction / cross-repo leakage |
| `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` | `.claude/settings.json env` | In-process teams are default now; whether the flag still gates anything is UNVERIFIED | Likely no-op |
| `sessionTitle`, `reloadSkills` in `hookSpecificOutput` | `session-start.js:246-262` | Claimed from ChangeLog v2.1.152; not in the verified hookSpecificOutput field list (permissionDecision/additionalContext/updatedInput/systemMessage) | UNVERIFIED |
| `requiredMinimumVersion: "2.1.224"` | `Claude/templates/claude/settings.json:11` (deep-merged into project settings by `scripts/setup/init-claudeos-project.js`) | Managed/enterprise setting; effect in a project settings file UNVERIFIED — `docs/claude/19` itself says "現状はテンプレート値によるシグナルのみ" and enforcement would need `/etc/claude-code/managed-settings.json`, which does not exist | UNVERIFIED (treat as inert) |
| `.claude/claudeos/system/progressive-disclosure.md` "64 スキル … state.json.session.context_load_tier" | system doc | Describes a tiered loading protocol for skills that are not loadable at all in this repo | Dead protocol |

### 1.4 Target layout proposal

```
CLAUDE.md  (root, target ≤ 180 lines / ≈ 9 KB)          — only what /etc policy does NOT say
  1. Precedence: "/etc/claude-code/CLAUDE.md is authoritative; this file adds repo specifics" (do not restate §3–§8 of /etc)
  2. What this repo is: ClaudeOS control plane for Claude Code on Linux; bin/lib/libexec/scripts map; `npm test` (bats+node), `npm run lint` (shellcheck)
  3. Source-of-truth rule: edit Claude/templates/**, never .claude/claudeos/** (link docs/SOURCE_OF_TRUTH.md); run verify-startuptools before commit/PR
  4. Platform facts (resolve the Neon-vs-local contradiction explicitly; one sentence each for Cloudflare / PostgreSQL / GitHub)
  5. Agent teams & cross-session messaging: 6 bullets (from §9 + §27)
  6. Pointers: skills to invoke (verify-startuptools, webui-health-check, cto-session-start), docs/claude/*, goals templates

.claude/rules/                                            — path-scoped, small
  git-workflow.md         (no paths)     §7/§15 condensed (≤ 12 lines)
  security.md             (no paths)     §5/§19 secrets + prod-data rules (≤ 10 lines)
  launchers.md            paths: bin/**, lib/**, libexec/**, Claude/templates/linux/**   — shellcheck/bats, no SSH/Windows revival, --dry-run before all-projects apply (from AGENTS.md)
  hooks.md                paths: .claude/claudeos/scripts/hooks/**, Claude/templates/claudeos/scripts/hooks/**  — fail-soft, atomic state writes, exit 2 = block, template is source, add tests
  templates.md            paths: Claude/templates/**      — sync check, copy-if-missing semantics, BOM-free, frontmatter required for agents/skills
  cross-session.md        (no paths)     §27 (or keep in CLAUDE.md §5)

.claude/skills/                                           — procedures, loaded on demand
  verify-startuptools, webui-health-check, cto-session-start (exist)
  release-flow       ← §15 PR-body 12 items + §16 gate + §20/§21 Phase 1–3 checklist
  approval-pr        ← §17 12-item Approval PR template (user-invocable, disable-model-invocation)
  final-report       ← §24 17-item report template
  incident-rollback  ← §18 rollback conditions

docs/ (reference, NOT loaded)
  docs/policy/goal-prompt.md          ← CLAUDE.md §25 (4.1 KB); canonical /goal text belongs in Claude/templates/claudeos/goals/*.md anyway
  docs/policy/autonomous-cycle.md     ← §6 read-only checklist, §10 cycle, §11 quality list, §12/§13/§14 platform checklists
  docs/claudeos-reference/            ← .claude/claudeos/system/*.md, executive/, management/, loops/ (nothing loads them today either)
  delete: Claude/CLAUDE.md, Claude/templates/claude/claudeos/CLAUDE.md (stale copy), Claude/*-back.md, Claude/templates/claude/BackUp/*
```

Expected effect: static per-session context 49.6 KB → ≈ 8.2 KB (/etc) + ≈ 9 KB (root) + ≈ 2 KB (always-on rules) ≈ **19 KB (−60%)**; `/doctor` trim proposals should then be near-empty.

---

## 2. Hooks audit

### 2.1 Wiring (`.claude/settings.json`, project-level)

| Event | Matcher | Script | Exists in runtime dir? |
|---|---|---|---|
| PreCompact | `*` | pre-compact.js | yes |
| SessionStart | `startup\|resume\|clear` | session-start.js, verify-goal-set.js | yes, yes |
| Stop | `*` | session-end.js | yes |
| PostToolUse | `Agent` | usage-tracker.js | yes |
| PostToolUse | `Agent` | agent-teams-tracker.js | yes |
| PostToolUse | `SendMessage` | agent-teams-tracker.js | yes |
| PostToolUse | `Bash\|mcp__.*` | audit-trail.js | yes |
| TeammateIdle | `*` | teammate-idle-gate.js | **MISSING** (only in `Claude/templates/claudeos/scripts/hooks/`) |
| TaskCreated | `*` | task-created-gate.js | **MISSING** (template only) |
| TaskCompleted | `*` | task-completed-gate.js | **MISSING** (template only) |

Consequences of the 3 missing scripts: every TaskCreated/TaskCompleted event (i.e. every task-list create/complete, common in normal sessions) spawns `node` → `MODULE_NOT_FOUND` → exit 1 → non-blocking hook error noise each time. Fix by either copying the three files from the template or deleting the three entries.

Notes on the wiring itself:
- All commands use **relative** paths (`node .claude/claudeos/scripts/hooks/…`) instead of `${CLAUDE_PROJECT_DIR}`. In team mode roles run in `<project>/.worktrees/<role>`; `template_sync__apply` copies only START_PROMPT/CLAUDE.md/commands/one skill there, not hooks → hooks fail in worktrees. `CLAUDEOS_HOOKS_DIR` is exported by the launchers but never used by settings.json.
- `.claude/settings.json` has 10 entries; the **template** `Claude/templates/claude/settings.json` has 20 (adds PreToolUse `pre-commit-gate` with `if: "Bash(git *)"` + `continueOnBlock`, SessionStart `*` `heartbeat-writer`, Notification `idle_prompt`/`permission_prompt` `notification-gate`, StopFailure `stop-failure-gate`, PostToolUse `Agent|Skill` usage-tracker, `Agent` agent-transcript, `Edit|Write|MultiEdit` auto-format). The template is deep-merged into downstream projects by `init-claudeos-project.js` and then sanitised at every launch by `scripts/setup/sanitize-settings.js` (which forces SessionStart matcher of context-injecting hooks to `startup|resume|clear` — the "autocompact thrashing" fix, PR #97).
- `.codex/hooks.json` (Codex CLI) wires the same scripts with SessionStart matcher `*` — the very pattern sanitize-settings removes for Claude. Out of scope but worth aligning.
- Hook file drift: 12 of 18 scripts differ between runtime and template; 7 template-only (`heartbeat-{daemon,watchdog,writer}`, `notification-gate`, `stop-failure-gate`, `task-{created,completed}-gate`, `teammate-idle-gate`); 1 runtime-only (`verify-goal-set.js`).
- `scripts/hooks/package.json` declares `"@anthropic-ai/sdk": "latest"` (unpinned) solely for `dreaming-runner.js`; no `node_modules` present anywhere → dreaming cannot run, and an unpinned dependency inside the hooks tree is a supply-chain foot-gun.

### 2.2 Per-turn cost model (VERIFIED by reading the scripts; timings estimated)

- Every **Stop** (end of each assistant turn) runs `session-end.js` synchronously: reads/writes `state.json` (37 KB, 3–6 atomic rewrites), `quality-gate-check` (2 file reads), `tdd-coverage-scan` (`git diff HEAD~5..HEAD` + fs walk), `reasoning-bank` load/save (20 KB) + global bank in `~/.claude/data/`, trust-score write, then **`measure-kpi.js` synchronously with 5 `gh` network calls** (`gh run list` ×2, `gh issue list --limit 200` ×2, `gh pr list`; 15 s timeout each, 30 s cap), **`sync-github-projects.js`** (`gh api graphql` ×2 + `gh issue edit` per completed/blocked issue; 30 s cap), `run-cmdb-scan.js` when phase is Monitor/empty (20 s cap; current phase `Idle` → skipped), `run-audit-scan.js` in Verify (30 s), detached webhook spawn, `notify-stable` (spawns `claude push-notify` when an event fires). Estimate **3–10 s wall-clock per turn**, dominated by 5–7 `gh` calls; a 300-minute cron session with ~150 turns ⇒ 7–25 min of hook time and ~1,000 GitHub API calls.
- Every **Bash / MCP** tool call spawns `node audit-trail.js` (~40–80 ms process start; regex; append). Every **Agent** call spawns two node processes (`usage-tracker`, `agent-teams-tracker`) that **both rewrite `state.json`** on the same event → write race (atomic rename, last writer wins, updates lost).
- **SessionStart** (once per startup/resume/clear): `session-start.js` (~100–300 ms) + detached `measure-kpi.js --background` (5 more `gh` calls) + `verify-goal-set.js` (~50 ms).
- **PreCompact**: `pre-compact.js` copies state.json to `.claude/claudeos/snapshots/` (currently 808 KB, keeps 20) and writes `evacuation-latest.json`; exit 2 on failure blocks compaction. Nothing re-injects the evacuation summary after compaction (SessionStart deliberately excludes `compact`; no PostCompact hook).

### 2.3 Per-script table

Categories: Sec = Security, Gov = Governance, Aud = Audit, QG = Quality Gate, Obs = Observability, FC = Feedback Capture, CR = Context Reload.

| # | Script | Event wired | What it does | Dependencies | Native replacement? | Per-turn cost | Recommendation | Category |
|---|---|---|---|---|---|---|---|---|
| 1 | session-start.js (12.2 KB) | SessionStart startup/resume/clear | Reads state.json; injects resume summary, KPI, blocked issues, week-phase, Agent-Teams pattern A/B/C, dashboard URL, workflows gate, ReasoningBank top-3; writes `current_session_start_at`, `last_trigger`; spawns measure-kpi (bg); emits `sessionTitle`/`reloadSkills` (UNVERIFIED fields) | state.json (execution/stable/token/compact/kpi/metrics/blocked_issues/project/agent_teams_usage), reasoning-bank.js, `~/.claude/data/global-reasoning-bank.json`, `.claude/claudeos/.skills-dirty`, scripts/tools/measure-kpi.js (gh) | Agent View titles native (`claude agents`); `/reload-skills` native | once/session, ~0.3 s + bg gh | **MODERNIZE**: drop v9 week-phase/pattern/dashboard/workflows hints; keep resume + ReasoningBank; add `statusMessage`; remove unverified output fields | CR |
| 2 | verify-goal-set.js (4.8 KB) | SessionStart | Extracts `/goal "…"` from START_PROMPT; checks 11 v9-era keywords; prints copy-paste reminder | Claude/templates/claude/START_PROMPT.md | **`/goal`** (native status/clear) | ~50 ms; always emits a warning (template mismatch, VERIFIED) | **REPLACE_WITH_NATIVE**: delete; move template-consistency check into `verify-startuptools` skill / a bats test | QG (template lint) |
| 3 | session-end.js (19.3 KB) | Stop `*` | Misnamed "session end": Verify-subagent presence check (`qa`/`security-reviewer`/`e2e-runner` — agents not loadable here), quality-gate warnings, deploy-runbook gen, CMDB/audit scans, GitHub Projects label sync, TDD scan, learning patterns, negative patterns, KPI (sync gh), trust ledger, webhook, notify-stable, dreaming spawn | state.json; quality-gate-check, tdd-coverage-scan, reasoning-bank, notify-stable, webhook-notifier, dreaming-runner; scripts/tools/{measure-kpi,sync-github-projects,run-cmdb-scan,run-audit-scan}.js; scripts/release/generate-deploy-runbook.js; `.claude/claudeos/data/trust-score.json`; **gh CLI + network** | `SessionEnd` event (verified list) is the right place for session-final bookkeeping; `/cost`/`/usage` for token KPIs | **3–10 s every turn** | **MODERNIZE**: split — Stop → `async: true`, only `last_stop_at` + warnings; SessionEnd → KPI, ledger, reasoning-bank, projects sync (once); delete `verify_subagent_missing` (phantom agents); pin phase-gated scans to the verify skill | Obs (+Aud, +FC) |
| 4 | usage-tracker.js (3.6 KB) | PostToolUse Agent (template: Agent\|Skill) | Counts Agent/Skill calls into `state.learning.usage_history` | state.json | no direct native (`/skill-doctor` = health, not usage); low value | ~60 ms per Agent call + state rewrite (races with #5) | **MODERNIZE**: merge into one `tool-usage-tracker.js` with #5 (single write), or REMOVE | Obs |
| 5 | agent-teams-tracker.js (7.5 KB) | PostToolUse Agent, SendMessage | Records named `Agent` spawns / SendMessage into `state.agent_teams_usage`; dead `TeamCreate` branch | state.json; consumers: scripts/tools/agent-teams-status.js, scripts/dashboards/serve-dashboard.js | `SubagentStart`/`SubagentStop` events (verified) are the native signal for spawn tracking | ~60 ms per Agent/SendMessage + state rewrite | **MODERNIZE**: remove TeamCreate/team_name code; move to SubagentStart/Stop; merge with #4 | Obs |
| 6 | audit-trail.js (4.1 KB) | PostToolUse Bash\|mcp__.* | Appends JSONL for git/gh write commands and MCP write tools to `.claude/claudeos/data/audit-log.jsonl` (1 MB rotate; 59 KB now) | none external | none (native has no local audit log) | ~50 ms per Bash/MCP call | **KEEP / MODERNIZE**: use `if: "Bash(git *)"` and `if: "Bash(gh *)"` entries so node is not spawned for `ls`/`cat`; narrow MCP matcher to `mcp__github__.*`; consider `async: true` | Aud |
| 7 | pre-compact.js (4.4 KB) | PreCompact `*` | Snapshots state.json (keep 20), writes `evacuation-latest.json`, records timestamp; exit 2 blocks `/compact` on failure | state.json, snapshots dir | `/autocompact` native; PostCompact event exists | once per compaction | **KEEP / MODERNIZE**: add a `PostCompact` hook that re-injects the 10-line evacuation summary as `additionalContext` (today nothing restores context after compaction); prune snapshots dir (808 KB) | CR |
| 8 | notify-stable.js (5.0 KB) | required by #3 | Sends STABLE/Blocked/5h/critical-review events via `claude push-notify`; falls back to console; spawns webhook | state.notification/stable/codex/execution; `claude` binary | **`claude push-notify` does not exist in 2.1.263 (VERIFIED)**; user settings already have `agentPushNotifEnabled: true`, `preferredNotifChannel: auto`; `Notification`/`Stop` hooks can post | 0.5–1 s when an event fires (spawns claude CLI to fail) | **REPLACE_WITH_NATIVE**: delete; keep webhook path; rely on native notifications / `type: http` hook | Obs |
| 9 | webhook-notifier.js (8.4 KB) | spawned by #3/#8/#16, template stop-failure/notification gates | HTTPS POST (Teams/generic/Slack), HMAC signing, 8 s timeout, only if `state.webhook.enabled` + env URLs | env `TEAMS_WEBHOOK_URL`/`HTTPS_WEBHOOK_URL`/`HTTPS_WEBHOOK_SECRET`/`SLACK_WEBHOOK_URL`; network | `type: "http"` hook (verified type) covers plain POST; HMAC needs a script | 0 (state.webhook absent → no-op) | **KEEP** (opt-in); consider `http` hook for non-signed endpoints | Obs |
| 10 | reasoning-bank.js (15.5 KB) | library (#1, #3) | Jaccard-dedup pattern bank with confidence/SONA decay; local + global (`~/.claude/data`) banks | `.claude/claudeos/data/reasoning-bank.json` (20 KB), `~/.claude/data/global-reasoning-bank.json` | Auto memory (`MEMORY.md`) + `/memory` natively persist cross-session learnings | part of #3 each turn | **MODERNIZE**: run from SessionEnd only; evaluate replacing with native auto-memory; keep top-3 injection cap | FC |
| 11 | quality-gate-check.js (3.2 KB) | library (#3) + CLI | Compares `reports/lint-summary.json` / `coverage-summary.json` with thresholds; appends `quality_gate_breach` warnings | reports/*.json, state.quality_gates | `/verify` native for running checks; thresholds stay custom | negligible | **KEEP** (call from verify skill / SessionEnd, not every Stop) | QG |
| 12 | tdd-coverage-scan.js (5.0 KB) | library (#3) | Finds changed source files (HEAD~5..HEAD) lacking a test file; warns `tdd_required` | git | none | `git diff` + fs walk each turn | **MODERNIZE**: run on `PreToolUse` `if: "Bash(git commit*)"` or SessionEnd | QG |
| 13 | pre-commit-gate.js (2.7 KB) | **not wired in runtime** (template: PreToolUse Bash, `if: Bash(git *)`, `continueOnBlock`) | On `git commit`: runs `scripts/lint/lint-and-fix.js --no-fix` and `npm run test:quick` (script absent here); **exits 1 on failure — exit 1 does not block (exit 2 does)** | scripts/lint/lint-and-fix.js, reports/lint-summary.json, package.json | git-native pre-commit hook (husky/lefthook) is tool-agnostic | 0 now; 90–210 s when wired | **MODERNIZE**: fix exit code to 2, narrow `if` to `Bash(git commit*)`, or move to a real git pre-commit hook | QG |
| 14 | auto-format.js (2.9 KB) | not wired (template: PostToolUse Edit\|Write\|MultiEdit) | `npx -y prettier --write` per edited file (network on first use, 30 s timeout); ruff/black/gofmt/rustfmt | npx/prettier (not in package.json), external formatters; `MultiEdit` tool existence UNVERIFIED | none | 0.3–30 s per edit when wired | **REMOVE_CANDIDATE** for this repo (bash/markdown, no prettier dep); if kept, `async: true` + project-local prettier only | QG |
| 15 | agent-transcript.js (4.3 KB) | not wired (template: PostToolUse Agent) | Appends subagent prompt/result to `reports/agent-transcripts/<date>.md` (200 KB cap) | state.json | Agent View / `claude agents` / task output files show subagent transcripts natively | ~60 ms per Agent call when wired | **REMOVE_CANDIDATE** (keep opt-in via env at most) | Aud |
| 16 | dreaming-runner.js (12.7 KB) | spawned by #3 if `state.dreaming.dreaming_enabled` (false) | Managed-Agents "Dreams" research-preview client (`@anthropic-ai/sdk`, beta headers `managed-agents-2026-04-01,dreaming-2026-04-21`, 20-min poll) | `ANTHROPIC_API_KEY`, unpinned SDK, network | n/a (preview feature) | 0 (disabled) | **REMOVE_CANDIDATE** from hooks tree → `scripts/tools/` or docs; delete `hooks/package.json` or pin the dep | FC |
| 17 | suggest-compact.js (1.8 KB) | not wired anywhere (0 refs) | Prints `/compact` recommendation from state.token/debug/execution | state.json | **`/autocompact`** + native context warnings | 0 | **REPLACE_WITH_NATIVE**: delete | CR |
| 18 | evaluate-session.js (104 B) | not wired (0 refs) | one `console.log` stub | — | — | 0 | **REMOVE_CANDIDATE** | — |
| — | package.json | — | `@anthropic-ai/sdk: latest` for #16 only | — | — | — | REMOVE (or pin) | — |
| T1 | teammate-idle-gate.js (template only; wired in runtime settings) | TeammateIdle | Keeps a teammate working (exit 2) when its last message matches phrases like "i'll leave", "feel free to" | — | none | per idle event | **Resolve wiring**: brittle phrase heuristic can loop teammates; recommend deleting the entry unless in-process teams are actually used | Gov |
| T2 | task-created-gate.js (template only; wired) | TaskCreated | Rejects tasks with title < 5 chars / vague | — | none | per task create | Resolve wiring: low value → delete entry | Gov |
| T3 | task-completed-gate.js (template only; wired) | TaskCompleted | Blocks completion of code tasks without test evidence in notes | — | none | per task complete | Resolve wiring: keep only if teams are used (copy file + tests); else delete entry | QG |
| T4 | stop-failure-gate.js (template only) | StopFailure | Webhook `api_failure` on rate_limit/overloaded/billing… | webhook-notifier | none native for unattended alerting | rare | **KEEP** (wire it here too; valuable for cron) | Obs |
| T5 | notification-gate.js (template only) | Notification idle_prompt/permission_prompt | Webhook `input_waiting` | webhook-notifier | `--permission-prompts none` (v2.1.259) makes headless never wait; native notif channels | rare | MODERNIZE: keep for `permission_prompt` only once headless uses `--permission-prompts none` | Obs |
| T6 | heartbeat-writer/daemon/watchdog (template only) | SessionStart `*` (+ external cron) | 60 s heartbeat file for silent-death detection | — | `claude agents` shows session state; `CLAUDE_CODE_RETRY_WATCHDOG` covers API silence | daemon per session; matcher `*` includes `compact` → possible duplicate daemons (UNVERIFIED) | KEEP for cron supervision; narrow matcher to `startup\|resume` | Obs |

**Hook recommendation totals (18 runtime scripts):** KEEP 4 (audit-trail, pre-compact, webhook-notifier, quality-gate-check) · MODERNIZE 7 (session-start, session-end, usage-tracker, agent-teams-tracker, reasoning-bank, tdd-coverage-scan, pre-commit-gate) · REPLACE_WITH_NATIVE 3 (verify-goal-set, notify-stable, suggest-compact) · REMOVE_CANDIDATE 4 (evaluate-session, dreaming-runner, agent-transcript, auto-format). Settings entries to fix: 3 missing scripts (TeammateIdle/TaskCreated/TaskCompleted) → delete or copy; add StopFailure gate.

**Surviving hooks by class:** Security — none (permission policy is in settings, no PreToolUse guard exists; recommend one `PreToolUse` `if:`-filtered script for BLOCKED commands, see §6) · Governance — task-completed-gate (optional) · Audit — audit-trail · Quality Gate — quality-gate-check, tdd-coverage-scan (moved), pre-commit-gate (fixed) · Observability — session-end (slimmed, async), tool-usage tracker (merged), webhook-notifier, stop-failure-gate, heartbeat · Feedback Capture — reasoning-bank (SessionEnd) · Context Reload — session-start (slimmed), pre-compact + new PostCompact re-injection.

---

## 3. Commands vs bundled skills

Scope: `.claude/claudeos/commands` (46), `.claude/commands` (2: `design-sync-check`, `safe-auto-merge`), template `Claude/templates/claudeos/commands` (45). Full per-command table is in the sub-audit; condensed here.

Loading reality: `.claude/claudeos/commands` is **not** loaded by Claude Code (not a standard path; the `everything-claude-code` plugin manifest in `.claude/claudeos/.claude-plugin/plugin.json` is neither installed nor enabled, and both `marketplace.json` files point to a non-existent `./everything-claude-code` path). Only `.claude/commands/{design-sync-check,safe-auto-merge}.md` are live here (distributed copy-if-missing by `lib/template-sync.sh:102-113`). Downstream projects get **all 45 template commands** via `scripts/setup/init-claudeos-project.js:34` → `<project>/.claude/commands`, which then **collide with native `/code-review` and `/verify`** (precedence UNVERIFIED). **No command file has YAML frontmatter** in the runtime dirs (template has `description:` on 6).

| Metric | Value |
|---|---|
| Unique commands | 46 (45 template + `team-onboarding`); 48 files incl. 2 deployed copies |
| Stubs (≤ 3-line body) | 27 |
| REPLACE_WITH_NATIVE | **9**: code-review→`/code-review`, verify→`/verify`, refactor-clean→`/simplify`, go-review/python-review→`/code-review`, multi-execute/multi-plan/multi-workflow/orchestrate→`/workflows` |
| MERGE (into skill/other cmd) | 10 (build-fix, checkpoint, cron-list, evolve, instinct-export/import/status, learn-eval, learn, prune, test-coverage) |
| CONVERT_TO_SKILL | 4 (e2e→e2e-testing, eval→eval-harness, go-test→golang-testing, tdd→tdd-workflow) |
| REMOVE_CANDIDATE | 12 (cron-cancel, cron-register, work-time-reset, work-time-set, session-info, sessions, go-build, multi-backend, multi-frontend, pm2, skill-create, …) |
| KEEP | 11 (changelog, design-sync-check, extract-tasks, mcp-memory-check, measure, plan, safe-auto-merge, setup-pm, team-onboarding, update-codemaps [resync from template — runtime copy is a 3-line stub], update-docs) |
| Reference removed features (TeamCreate/teammateDefaultModel/team_name/`/codex:*`/`/coderabbit:*`/push-notify) | **0** |
| Reference non-existent scripts/paths | 3 → `~/.claudeos/cron-cli.sh` (cron-register, cron-cancel, work-time-reset); session-info & work-time-set use `~/.claudeos/sessions/${CLAUDE_SESSION_ID}.json` but the Linux launchers never export `CLAUDE_SESSION_ID` and real files are `<ts>-<project>.json`; cron-register cites missing `docs/common/16_…` |
| Windows-era wording | session-info ("Windows 側の state/sessions"), team-onboarding (§9 `state.json.codex.blocking_issues`, §10 "4 ループ登録コマンド") |
| Native name collisions when deployed | 2 (`code-review.md`, `verify.md`) |

Duplicate families: 3-way identical copies (design-sync-check, safe-auto-merge in template / claudeos / .claude); review (code-review, go-review, python-review); verify/test (verify, e2e, test-coverage, build-fix); multi-agent stubs ×6; cron ×3 (real implementation is `bin/cron-schedule.sh add|list|remove` + `lib/cron-manager.sh`); session/time ×5; learning ×8 (learn, learn-eval, instinct-*, evolve, prune, skill-create); Go ×3. Command↔skill duplicates: tdd↔tdd-workflow, verify↔verification-loop, code-review↔security-review/performance-review, e2e↔e2e-testing, eval↔eval-harness, learn*↔continuous-learning(-v2), multi-*↔autonomous-loops.

Authoritative copy: `Claude/templates/claudeos/commands/*.md` (only source read by `template-sync.sh` and `init-claudeos-project.js`); `.claude/commands/` is the deployed live copy; `.claude/claudeos/commands/` is inert and hand-synced (drifted: `update-codemaps.md` degraded to a stub; 6 files lost their `description` frontmatter).

---

## 4. Skills

Scope: `.claude/claudeos/skills` (66), `.claude/skills` (3), `.agents/skills` (3) = 72 SKILL.md files.

| Metric | Value |
|---|---|
| Identical-template stubs | **63 / 66** in claudeos (66 lines, ~2.2–2.4 KB, same JP skeleton; only description + "相性のよい command/agents" slots vary). Bespoke: `performance-review`, `requirements-extractor`, `verification-loop` |
| Frontmatter | **0 / 66** claudeos skills have any frontmatter (no `name`, no `description` → no auto-invocation possible even if discoverable). `.claude/skills/*` have `name`+`description` only. No file anywhere uses `when_to_use`, `argument-hint`, `disable-model-invocation`, `user-invocable`, `allowed-tools`, `disallowed-tools`, `model`, `effort`, `context`, `agent`, `background`, `paths`, `hooks`, `shell` |
| Categories (C+S) | Core 9 · Development 21 · QA 18 · Security 6 · Database 3 · GitHub 0 · Infrastructure 2 · Domain 8 · Improvement 2 |
| Duplicate groups | **10** (+3 minor merge sets) |
| Zero references | 3 in claudeos (`perl-security`, `perl-testing`, `python-testing`) + 3 in `.agents/skills` = 6; 60/66 referenced only by the inventory doc `docs/agents-skills-inventory-2026Q2.md` |
| Functionally wired | 3 claudeos (`performance-review` ← agent, `requirements-extractor` ← `/extract-tasks`, `verification-loop` ← docs/claude/18) + 3 `.claude/skills` |
| Missing ≥ 3 of 7 sections (Purpose/Trigger/Inputs/Procedure/Validation/Failure Handling/Output) | 1 unique (`cto-session-start`, missing 4; appears twice); `webui-health-check` misses 2; every template stub misses Failure Handling |
| Verdicts (claudeos) | KEEP 5 · MERGE 38 · REMOVE_CANDIDATE 20 · MOVE_TO_DOCS 3 |
| Loadable by Claude Code in this repo | **3** (`.claude/skills/cto-session-start`, `verify-startuptools`, `webui-health-check`) |

Duplicate groups and what to keep:
1. `continuous-learning` vs `-v2` — identical template, 4 differing lines → keep one (or fold both into `/learn` + `/learn-eval`).
2. `security-review` vs `security-scan` — same template; `security-review` also **shadows the native `/security-review` skill** → merge into `security-audit`, delete `security-review`.
3–5. django-/laravel-/springboot-{patterns,security,tdd,verification} (+ `java-coding-standards`, `jpa-patterns`) → one skill per framework, only if real content is written.
6–7. perl-×3, python-×2, golang-×2, cpp-×2 → one per language or fold into the matching reviewer agent.
8. swift-×3 + `foundation-models-on-device` + `liquid-glass-design` → at most one `swift` skill (nothing in this Linux repo targets Apple platforms).
9. `verification-loop` (meta-guide) vs `verify-app` (distributed starter, `Claude/templates/claude/skills`) vs `verify-startuptools` (repo-local) — three layers, not duplicates; but the `/verify` command shadows native `/verify` → rename/remove the command.
10. `autonomous-loops` vs `.claude/claudeos/loops/*.md` → remove skill (inventory already says "replaced by native /loop").
Also: `strategic-compact` → native `/autocompact`; `tdd-workflow` + 3 `*-tdd` → `/tdd`; `deployment-patterns`+`docker-patterns` → `deploy-patterns`; `database-migrations`+`postgres-patterns`+`clickhouse-io` → `database-patterns`.

Loading / sync facts (VERIFIED):
- `.claude/claudeos/skills` ≡ `Claude/templates/claudeos/skills` (0 differing files). No automated sync; `verify-startuptools` step 4 tells the operator to `diff -rq` by hand.
- `lib/template-sync.sh:116-129` distributes exactly one skill (`Claude/templates/claude/skills/verify-app`) copy-if-missing.
- `scripts/setup/init-claudeos-project.js:35` copies all 66 template skills into `<project>/.claude/skills` (copy-if-missing) and touches `.claude/claudeos/.skills-dirty` so `session-start.js` emits `reloadSkills: true` (field UNVERIFIED). Downstream projects therefore get 66 discoverable-by-dirname skills with no description.
- Template slots reference 4 agents that do not exist (`developer-agent`, `qa-agent` ×13 skills, `devops-agent`, `product-manager`), and `/verify-app`, `/verify-startuptools`, `/cto-session-start`, `/webui-health-check` are cited as commands though they are skills.
- `.agents/skills` (untracked, created 2026-07-25) = sed copy of `.claude/skills` with `Claude→Codex`, `.claude→.Codex` producing non-existent paths; 0 references. Whether Claude Code 2.1.263 loads `.agents/skills` is **UNVERIFIED** — treat as a stray Codex-port artefact and remove.
- Only removed-feature reference across all 72 files: `performance-review/SKILL.md` last line `/codex:adversarial-review`.

`.claude/skills/*` detail: `verify-startuptools` (78 lines; 6/7 sections; best-formed; suggest `allowed-tools: Bash(bash -n:*), Bash(npm run test:*), Bash(node:*), Bash(diff:*)`); `cto-session-start` (duplicates the sibling-repo `.claude/CLAUDE.md §0` startup ritual; uses native `/goal`; add `when_to_use`, Inputs/Output, consider `disable-model-invocation`); `webui-health-check` (hard-coded port 3737; add Trigger/Inputs).

---

## 5. Agents

Scope: `.claude/claudeos/agents` (43). `.claude/agents` and `~/.claude/agents` do not exist.

| Metric | Value |
|---|---|
| Loadable by Claude Code here | **0** (not a standard path; plugin not installed/enabled; no symlink; `lib/template-sync.sh` distributes no agents) |
| Frontmatter fields used | `name`, `description`, `tools` only; **0 unsupported fields**; 0 set `model`/`effort`/`skills`/`isolation`/`maxTurns`/`permissionMode` |
| Without any frontmatter | **7** (`architect`, `dev-api`, `dev-ui`, `ops`, `orchestrator`, `qa`, `tester`) — template copies have it; runtime regressed |
| UTF-8 BOM before `---` | **41 / 43** (only `audit-agent`, `cmdb-agent` clean) — BOM tolerance of the frontmatter parser UNVERIFIED; strip before promotion |
| Tools | 41 share `Read, Write, Edit, Bash, Grep, Glob`; `outcome-grader` = Read/Bash/Grep/Glob; `performance-reviewer` adds WebFetch |
| Reference removed features | 0 |
| Runtime vs template drift | 9 files differ (7 lost frontmatter; `security-reviewer` template adds 制約/5h/連携先; `outcome-grader` path) |
| Phantom agent names referenced by skills/commands/system | `qa-agent` (13 files), `devops-agent` (4), `product-manager` (2), `devops` (5); `core/04-agent-teams.md` names 14 roles, files exist for 8 |
| Downstream distribution | only `scripts/setup/init-claudeos-project.js:33` (`Claude/templates/claudeos/agents` → `<project>/.claude/agents`, copy-if-missing, manual `--apply`); README stats script is the only runtime reader |

How "Agent Teams" actually spawn roles (VERIFIED from `lib/team-runner.sh`, `TEAM_START_PROMPT.md`): one tmux session `claudeos-team-<key>` split into 4 panes (`cto backend frontend qa`), each `claude --name claudeos-<key>-<role>` in its own worktree `<project>/.worktrees/<role>` (branch `claudeos/<role>`), CTO pane gets `TEAM_START_PROMPT.md`, coordination via `/list-agents` + `SendMessage`, no `--dangerously-skip-permissions` (documented: skip-permissions sessions hold inbound messages). This is cross-session messaging, **not** in-process teams and **not** these agent files. A second, in-process mechanism is assumed by `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` + Task/Teammate gate hooks + `agent-teams-tracker.js` (named `Agent` spawns). A third, cron-era GitHub-Issue message bus (`roles/cto-build.md`, `qa-monitor.md`) is independent of both. None depends on removed features (`agent-teams-tracker.js` keeps a dead `TeamCreate` compat branch).

### Lazy Agent Catalog proposal

First-class `.claude/agents/*.md` (9): `cto` (lead/decision anchor, team CTO pane), `manager` (Issue Factory / Projects transitions), `code-reviewer` (single parametrized reviewer; use `skills:` frontmatter for language rubrics), `security-reviewer` (Verify/Release gate; take the template body with 制約), `ci-manager` (repair loop owner), `outcome-grader` (bound by `system/stable-rubric.json:113`, `loops/verify-loop.md:50`; restricted tools — add `disallowedTools: Write, Edit`), `e2e-runner`, `audit-agent`, `cmdb-agent` (Verify-end / Monitor-end chain members). Promotion checklist: strip BOM, add `model` (and `haiku` for outcome-grader if acceptable), `effort`, `maxTurns`, `isolation: worktree` for reviewers.

Catalog entries (9; one `catalog.md` index `name | purpose | path | when to load | model`, loaded via Read on demand): `api-designer` (absorbs dev-api), `architect` (restore frontmatter), `build-error-resolver` (parametrized; absorbs 6 language resolvers), `database-reviewer`, `doc-updater`, `performance-reviewer`, `qa` (restore frontmatter; absorbs tester), `release-manager` (absorbs ops), `tdd-guide`.

Merge (18): 7 language reviewers (cpp/go/java/kotlin/python/rust/typescript) → `code-reviewer`; 6 build resolvers (cpp/go/java/kotlin/pytorch/rust) → `build-error-resolver`; `dev-api`→api-designer, `tester`→qa, `ops`→release-manager, `loop-operator`→cto, `orchestrator`→cto + `system/orchestrator.md`.
Remove (7): `planner` (native Plan), `docs-lookup` (native Explore / claude-code-guide), `refactor-cleaner` (`/simplify`), `chief-of-staff`, `dev-ui`, `harness-optimizer`, `incident-triager`.
Stale doc: `docs/subagents-review-2026-06.md` still says 11 language agents are archived; commit `fa82dec` (#12) re-promoted them.

---

## 6. Permission / security audit

### 6.1 Settings files

**`.claude/settings.json` (project, live here):**
- `permissions.defaultMode: "auto"` — **ignored at project level since v2.1.257** (reference fact). Auto mode is effective only where the launchers pass `--permission-mode auto` explicitly.
- `permissions.allow` (49 Bash patterns + 4 non-Bash): includes `Bash(rm *)`, `Bash(kill *)`, `Bash(curl *)`, `Bash(chmod *)`, `Bash(mv *)`, `Bash(pip3 *)`, and the universal wrappers `Bash(bash *)`, `Bash(sh *)`, `Bash(node *)`, `Bash(python3 *)`, `Bash(env *)`, `Bash(timeout *)`, `Bash(flock *)`, `Bash(tee *)`. Because deny rules match the Bash command prefix, `bash -c 'git push --force …'`, `env git push …`, `timeout 30 git push …` all sidestep the 6 deny rules → **the deny list is cosmetic under this allow list**. `Bash(git *)` also permits `git push origin HEAD:main` and `git push origin +main` (not matched by `Bash(git push * main)`), `git reset --hard`, `git clean -fdx`, `git branch -D`. `Bash(curl *)` + `Bash(env *)` is an exfiltration path (see §6.3 on the env file). `Bash(kill *)` can kill the supervisor / other sessions.
- `mcp__github__*` wildcard allows **`delete_repository`, `merge_pull_request`, `push_files`, `create_or_update_file`, `delete_file`** — i.e. direct writes/merges to `main` via MCP that bypass every `git push` deny rule. `mcp__memory__*` is allowed but the `memory` server is **not enabled** (`settings.local.json` `enabledMcpjsonServers` = byterover, context7, github, sequential-thinking, brv; `.mcp.json` defines github, memory, sequential-thinking, context7 → `byterover`/`brv` stale, `memory` disabled).
- `permissions.deny` (6): force-push variants and `git push * main|master` only.
- `autoMode.hard_deny` (8 entries incl. `"$defaults"` + 7 Japanese rules): the key **exists** in the auto-mode config schema (`claude auto-mode defaults` prints `allow`, `soft_deny`, `hard_deny`, `environment` — VERIFIED), but `claude auto-mode config` run **from this repo** returns only the shipped defaults (`hard_deny` = 1 rule, none of the 7 JP rules, no `$defaults` literal) and `claude auto-mode reset` help says the section lives in "your **user** settings file" → **project-level `autoMode` is not applied** (empirical; official-doc statement UNVERIFIED). The `$defaults` sentinel is UNVERIFIED.
- Other keys: `teammateMode: "auto"` (plausible agent-teams setting; UNVERIFIED), `fallbackModel` as an **array** (documented form is a string; UNVERIFIED), `terminal.mode`, `outputStyle`, `language`, `spinnerTipsEnabled`, `alwaysThinkingEnabled`, `promptSuggestionEnabled`, `prefersReducedMotion`, `autoUpdatesChannel`, `worktree.baseRef: head`, env `ENABLE_TOOL_SEARCH`, `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS`, `CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION`, `ENABLE_PROMPT_CACHING_1H`.
- Hooks: see §2 (3 missing scripts; relative paths).

**`Claude/templates/claude/settings.json` (deep-merged into downstream projects by `init-claudeos-project.js`, sanitised each launch):** same allow/deny/autoMode plus `Bash(docker *)` and `requiredMinimumVersion: "2.1.224"` (managed-only setting; project-level effect UNVERIFIED — see §1.3), plus the 10 extra hook entries listed in §2.1.

**`~/.claude/settings.json` (user):** no `permissions` block (so user default mode is the interactive default), `skipDangerousModePermissionPrompt: true` (removes the confirmation for `--dangerously-skip-permissions`), `agentPushNotifEnabled: true`, `preferredNotifChannel: auto`, model `claude-fable-5-1[1m]`, plugins: eli5 only. `/etc/claude-code/managed-settings.json` does not exist (doctor: remote managed settings fetch 401 — no policy applied).

### 6.2 Launch paths and flags (VERIFIED from bin/lib/templates)

| Path | Command shape | Permission mode | Prompt | Notes |
|---|---|---|---|---|
| L1 direct TUI (`start-claude.sh --foreground`) | `claude [--model --effort] [--name] "$(cat .claude/START_PROMPT.md)"` | none → interactive default (project `auto` ignored) | START_PROMPT | human present; prompts appear |
| L1 `--tmux` (`lib/tmux-runner.sh:171-173`) | `claude … --dangerously-skip-permissions "$(cat START_PROMPT.md)"` | **bypass all** | START_PROMPT | in tmux; all hooks/permissions bypassed |
| T team (`lib/team-runner.sh`) | 4× `claude --name claudeos-<p>-<role>` | interactive default (deliberately no skip) | TEAM_START_PROMPT (CTO only) | worktrees lack hooks (relative paths) |
| S1 / cron headless (`cron-launcher.sh:431-478`, default `CLAUDEOS_HEADLESS=1`) | `env -u ANTHROPIC_API_KEY claude -p "$PROMPT" --output-format stream-json --verbose --permission-mode auto [--model --effort] [--name] [--resume <id>]` | **auto (flag honored)**; `CLAUDEOS_HEADLESS_SKIP_PERMS=1` → `--dangerously-skip-permissions` | /goal + resume header + START_PROMPT | `--permission-prompts` **not set** → default `host`; with no `--permission-prompt-tool` the behaviour of an unresolvable prompt is UNVERIFIED (likely denied or hang). `--permission-prompts none` (v2.1.259) is available and unused |
| cron TUI fallback (`CLAUDEOS_HEADLESS=0`, `cron-launcher.sh:532-535,596`) | `claude … --dangerously-skip-permissions "$PROMPT"` | **bypass all**, unattended | same | highest-risk path still present |
| direct headless once (`start-claude.sh:302-321`) | `claude -p "$prompt" --output-format stream-json --verbose --permission-mode auto` | auto | START_PROMPT only (no /goal, no resume header) | inconsistent with cron |
| `scripts/tools/launch-parallel-cron.sh` (experiment) | `--permission-mode auto` or `--dangerously-skip-permissions` (opt-in) | auto / bypass | | comments mention `bypassPermissions` and `dontAsk` (rejected because allow-list-less tools die) |
| safe-mode | `claude --safe-mode` | n/a (hooks/MCP off) | none | diagnostics |
| `config/config.json` `claude.args` | comment says `--dangerously-skip-permissions` was removed in PR-G and "権限は settings/auto-mode と headless の --permission-mode **dontAsk** へ委譲" | — | — | comment is stale (launcher uses `auto`, not `dontAsk`) |

`grep` results: `--dangerously-skip-permissions` occurs in `lib/tmux-runner.sh` (2 live), `Claude/templates/linux/cron-launcher.sh` (3 live + opt-in), `scripts/tools/launch-parallel-cron.sh` (opt-in); `--allowedTools` unused; `--permission-prompts` unused; `bypassPermissions` only in comments.

Environment exported into the claude process: `CLAUDE_SESSION_ID`, `CLAUDE_PROJECT`, `CLAUDEOS_HOOKS_DIR`, `CLAUDEOS_GOAL_TYPE`, `CLAUDE_RESUME_PHASE`, `CLAUDE_RESUME_CONSECUTIVE`, `CLAUDEOS_SELECTED_MODEL/EFFORT/MODEL_KEY/MODEL_REASON`, `CLAUDEOS_THROTTLE_TIER/BIAS`, `CLAUDEOS_SESSION_COST_FILE`, `CLAUDE_CODE_RETRY_WATCHDOG=1`, `CLAUDE_ENABLE_STREAM_WATCHDOG=1`, `LANG/LC_ALL=C.UTF-8`, PATH additions — **and the full contents of `~/.env-claudeos`** (`bin/start-claude.sh:377-379` uses `set -a; source ~/.env-claudeos; set +a`; `cron-launcher.sh:48` sources it without `set -a`, so only variables the file itself exports leak). That file holds SMTP credentials per the comments; with `Bash(env *)` and `Bash(curl *)` allowed, every Bash tool call can read and ship them. `env -u ANTHROPIC_API_KEY` in the cron path removes only the API key.

### 6.3 Proposed classification for headless runs

Implement as: `permissions.allow`/`deny` at **user or managed** level (project-level defaultMode/autoMode are ignored), `--permission-mode auto --permission-prompts none` on every `-p` launch, one `PreToolUse` `command` hook (exit 2) for BLOCKED patterns that deny-prefix matching cannot express, and Approval PRs for HUMAN_APPROVAL items.

**ALLOW (narrowed):**
- `Bash(git status*)`, `Bash(git diff*)`, `Bash(git log*)`, `Bash(git add *)`, `Bash(git commit *)`, `Bash(git checkout -b *)`, `Bash(git switch -c *)`, `Bash(git fetch*)`, `Bash(git pull*)`, `Bash(git push -u origin *)` (feature branches; keep deny rules for main/force)
- `Bash(gh pr view*)`, `Bash(gh pr list*)`, `Bash(gh pr create *)`, `Bash(gh pr checks*)`, `Bash(gh pr merge --auto --squash *)`, `Bash(gh run *)`, `Bash(gh issue list*)`, `Bash(gh issue view*)`, `Bash(gh issue create *)`, `Bash(gh api -X GET *)`
- `Bash(npm test*)`, `Bash(npm run lint*)`, `Bash(npm run test:*)`, `Bash(bats *)`, `Bash(shellcheck *)`, `Bash(node scripts/*)`, `Bash(node .claude/claudeos/scripts/*)`, `Bash(jq *)`, `Bash(python3 scripts/*)`
- read-only fs: `cat ls find grep head tail wc sort uniq diff stat date printf which`; in-repo writes: `mkdir touch cp mv` (project scope), `Bash(rm -f reports/*)`-style scoped removes only
- `WebFetch(domain:docs.anthropic.com)`, `WebFetch(domain:code.claude.com)`, `WebFetch(domain:developers.cloudflare.com)`, `WebFetch(domain:github.com)`; `WebSearch`
- `mcp__github__get_*`, `mcp__github__list_*`, `mcp__github__search_*`, `mcp__github__pull_request_read`, `mcp__github__issue_read`, `mcp__github__create_pull_request`, `mcp__github__create_branch`, `mcp__github__add_issue_comment`

**DENY (permissions.deny):**
- wrappers: `Bash(bash -c *)`, `Bash(sh -c *)`, `Bash(eval *)`, `Bash(env *)`, `Bash(printenv*)`, `Bash(timeout * git push*)`, `Bash(xargs *)`, `Bash(python3 -c *)`, `Bash(node -e *)`
- destructive: `Bash(rm -rf *)`, `Bash(rm -r *)`, `Bash(kill *)`, `Bash(pkill *)`, `Bash(killall *)`, `Bash(sudo *)`, `Bash(chmod 777 *)`, `Bash(git reset --hard *)`, `Bash(git clean -f*)`, `Bash(git branch -D *)`, `Bash(git push --force*)`, `Bash(git push -f *)`, `Bash(git push * --force*)`, `Bash(git push * main*)`, `Bash(git push * master*)`, `Bash(git push * HEAD:main*)`, `Bash(git push * +main*)`
- network/exfil: `Bash(curl *)`, `Bash(wget *)`, `Bash(nc *)`, `Bash(ssh *)`, `Bash(scp *)`
- GitHub admin: `Bash(gh pr merge --admin*)`, `Bash(gh repo delete*)`, `Bash(gh secret *)`, `Bash(gh auth token*)`, `Bash(gh api -X DELETE*)`, `Bash(gh api -X PUT *)`, `mcp__github__delete_repository`, `mcp__github__merge_pull_request`, `mcp__github__push_files`, `mcp__github__create_or_update_file`, `mcp__github__delete_file`, `mcp__github__fork_repository`
- control plane: `Bash(crontab *)`, `Bash(systemctl *)`, `Bash(claude auto-mode reset*)`, `Edit(.claude/settings.json)`, `Edit(.claude/settings.local.json)`, `Edit(CLAUDE.md)`, `Write(.claude/claudeos/scripts/hooks/*)`
- secrets: `Read(~/.env*)`, `Read(.env*)`, `Read(~/.claude/settings.json)`, `Bash(cat ~/.env*)`, `Bash(cat .env*)`

**HUMAN_APPROVAL (Approval PR or interactive session only; headless = deny):** production deploy (`wrangler deploy --env production`, `gh release create`), DNS/custom-domain/Access changes, secret set/rotate (`wrangler secret put`, `gh secret set`), destructive/non-additive migrations, any push or merge into `main`, `gh pr merge` on default-branch PRs of other repos (`safe-auto-merge` already gates), cron/systemd schedule changes (`bin/cron-schedule.sh`, `bin/systemd-control.sh`), editing `.claude/settings*.json` / hooks / `CLAUDE.md` / templates that are auto-distributed, adding dependencies with install scripts, `npm publish`, all-projects template apply (`init-claudeos-project.js --all --apply`).

**BLOCKED (never; enforce via deny + PreToolUse exit 2 + env hygiene):** printing or committing secrets; `--dangerously-skip-permissions` in unattended runs (remove from cron TUI fallback and L1 `--tmux`; keep `CLAUDEOS_HEADLESS_SKIP_PERMS` only as a documented emergency flag); disabling hooks/branch protection; force push; repository deletion; `gh auth token`; sourcing `~/.env-claudeos` into the claude environment (pass SMTP creds only to the mail script's own subprocess).

### 6.4 Other security observations
- `.gitignore` excludes `state.json`, `reports/agent-transcripts/`, `reports/lint-summary.json`; `.claude/claudeos/data/audit-log.jsonl` (59 KB) and `reasoning-bank.json` are **tracked/committed** — audit log entries include full Bash command lines (300-char cap) and could capture tokens typed into commands.
- `pre-commit-gate.js` exits 1 on lint/test failure — not a block (exit 2 is).
- `audit-trail.js` does not log `Edit`/`Write` to sensitive paths, nor MCP tools outside the write-name regex.
- No `PreToolUse` guard exists at all in the runtime settings; the template's `agent-risk-check` (`type: agent`, `.claude/claudeos/hooks/hooks.json`) is a description-only manifest, not wired.

---

## 7. Prioritised action list

1. **Stop the per-turn network cost**: move `measure-kpi` / `sync-github-projects` / trust ledger / reasoning-bank out of `Stop` into a `SessionEnd` hook; mark the remaining Stop hook `async: true`. (Est. −3…10 s per turn, −~1,000 gh calls per cron session.)
2. **Fix the 3 dangling hook entries** (TeammateIdle/TaskCreated/TaskCompleted) — delete or copy from template; use `${CLAUDE_PROJECT_DIR}` in all hook commands.
3. **Delete obsolete hooks**: `verify-goal-set.js` (warns every startup; `/goal` is native), `notify-stable.js` (`claude push-notify` does not exist), `suggest-compact.js`, `evaluate-session.js`; move `dreaming-runner.js` + its `package.json` out of the hooks tree.
4. **Permissions**: move allow/deny to user (or managed) settings; remove `bash/sh/env/timeout/curl/rm/kill` wildcards; deny `mcp__github__{delete_repository,merge_pull_request,push_files,create_or_update_file,delete_file}`; add `--permission-prompts none` to every `-p` launch; remove `--dangerously-skip-permissions` from the cron TUI fallback and L1 `--tmux`; stop `set -a`-sourcing `~/.env-claudeos` before `claude`.
5. **Shrink CLAUDE.md** to ≤180 lines per §1.4; delete the 4 duplicate/stale copies; resolve Neon-vs-local-PostgreSQL and the three-way precedence claims; move §25 to `docs/`.
6. **Commands**: remove `code-review.md` / `verify.md` from the template (native collisions), fix or drop the 5 cron/session commands, add `description` frontmatter to survivors, and make `Claude/templates/claudeos/commands` the only copy.
7. **Skills**: collapse 63 template stubs into ≤12 real skills with frontmatter (`name`, `description`, `when_to_use`, `allowed-tools`); delete `.agents/skills`; rename `security-review` (shadows native).
8. **Agents**: create `.claude/agents/` with the 9 first-class agents (BOM-stripped, `model`/`maxTurns` set), a `catalog.md` for 9 more, merge 18, remove 7; update `docs/subagents-review-2026-06.md`.
9. Add a `PostCompact` hook that re-injects `evacuation-latest.json` (10 lines) — the only cheap way to restore continuity after `/autocompact`.
10. Align `.codex/hooks.json` SessionStart matcher with the sanitize rule, and fix the `config.json` comment that still claims `dontAsk`.
