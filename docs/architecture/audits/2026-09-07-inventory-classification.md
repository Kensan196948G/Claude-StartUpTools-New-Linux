# ClaudeOS v4.0.0-linux — Component Inventory & Classification Audit

Repository: `/home/kensan/Projects/Claude-StartUpTools-New-Linux`
Audited checkout: local `main` @ `76ba161` (+ uncommitted working-tree changes; `origin/main` is ahead at `44ba960` — see Defect D-13).
Reference runtime: Claude Code **2.1.263** (verified locally via `claude --version`; `--help` exposes `--name --effort --safe-mode --bg --worktree --permission-mode --bare --json-schema --fallback-model --restricted` and subcommands `agents attach logs stop respawn rm doctor mcp plugin ultrareview`).
Mode: READ-ONLY. No file in the audited repo was modified. No secret values are reproduced here.

Classification legend: **KEEP** (OS-level or unique value, retain), **MODERNIZE** (retain but rebuild on native primitives / thin adapter), **REPLACE_WITH_NATIVE** (a Claude Code 2.1.263 feature covers it), **DEPRECATE** (fold into another component / stop investing), **REMOVE_CANDIDATE** (dead, stale or duplicate), **EXPERIMENTAL** (depends on research-preview/experimental native feature; keep isolated).

---

## 0. Executive summary

| Area | Items | KEEP | MODERNIZE | REPLACE_WITH_NATIVE | DEPRECATE | REMOVE_CANDIDATE | EXPERIMENTAL |
|---|---|---|---|---|---|---|---|
| start.sh + bin/ (§1) | 19 | 8 | 6 | 1 | 4 | 0 | 0 |
| lib/ (§2; 20 + 1 untracked) | 21 | 12 | 5 | 3 | 0 | 0 | 1 |
| libexec/ (§3; 11 + 1 untracked) | 12 | 6 | 3 | 1 | 1 | 0 | 1 |
| scripts/** (§4) | 41 | 21 | 8 | 2 | 6 | 3 | 1 |
| config/ (§5; 11 + 1 untracked) | 12 | 5 | 1 | 0 | 1 | 3 | 2 |
| .github / security / .codex (§6) | 14 | 10 | 3 | 0 | 0 | 1 | 0 |
| `.claude/` settings, hooks (19), workflows (3), commands/skills/.agents (8), `.claude/claudeos/**` agents 43 / skills 66 / commands 46 / other dirs (§12) | ≈222 | 35 | 30 | 28 | 38 | 86 | 5 |
| `Claude/templates/**` (§13, by file) | 319 | ≈60 | ≈185 | 14 | ≈30 | 9 | 3 |
| **Total** | **≈660** | **≈157** | **≈241** | **≈49** | **≈80** | **≈102** | **≈13** |

Reading of the totals: the OS layer (bin/lib/libexec/config/CI) is ~55 % KEEP and only ~6 % REPLACE_WITH_NATIVE — it is the part native Claude Code does not cover. The in-session kernel (`.claude/claudeos`) is the opposite: ~56 % REMOVE_CANDIDATE/DEPRECATE (template stubs) plus ~13 % REPLACE_WITH_NATIVE. The template bundle is dominated by MODERNIZE because it distributes the same kernel with v8/v9 vocabulary and without native frontmatter.

The architecture is a **three-layer control plane**:

1. **OS layer (bash)** — `bin/` + `lib/` + `libexec/`: menu TUI, project discovery under `/home/kensan/Projects`, crontab, tmux, systemd, autonomy supervisor (re-launch loop), model router, credit ledger, template distribution.
2. **Runtime launcher** — `Claude/templates/linux/cron-launcher.sh` (deployed to `~/.claudeos/cron-launcher.sh` by `bin/deploy-launcher.sh`): builds the prompt (`/goal` block + resume header + START_PROMPT.md), then runs `claude -p ... --output-format stream-json --verbose --permission-mode auto --model X --effort Y --name claudeos-<proj>` (headless default) or `claude --dangerously-skip-permissions` in tmux (fallback).
3. **In-session kernel (ClaudeOS)** — `.claude/claudeos/**` (agents/skills/commands/hooks/loops/system docs) distributed to target projects via `lib/template-sync.sh` and `scripts/setup/init-claudeos-project.js`; plus the Node dashboard (`scripts/dashboards/*`).

The v10 principle *Native > thin adapter > custom* maps cleanly: layer 1 is mostly **KEEP** (OS boundary), layer 2 is a **thin adapter** that should shrink (permission/model/name flags are already native), layer 3 is where most **REPLACE_WITH_NATIVE / DEPRECATE** candidates live (custom agents not in `.claude/agents/`, commands duplicating bundled skills, custom goal/loop/compact/hook logic).

---

## 1. start.sh + bin/*.sh (18)

| Path | Purpose | Native equivalent | Class | Reason |
|---|---|---|---|---|
| `start.sh` | Entry; `exec bin/menu.sh "$@"` | — | KEEP | 10-line shim |
| `bin/menu.sh` (391) | Operations TUI: L1/S1/T<n>/DP/M/I/W/5-16/SY/PD/MC/DR/DU | `claude agents` (session view only) | MODERNIZE | Keep as OS control panel; menu items 9/10/12/13/15/16 wrap things `claude agents/logs/attach` + `/statusline` now cover |
| `bin/start-claude.sh` (553) | Launcher: foreground TUI (new terminal tab), team (tmux 4-pane), background (supervisor), safe-mode, direct headless | `claude --bg`, `claude --worktree`, `--name`, `--safe-mode`, `-p --output-format stream-json` | MODERNIZE | Already emits native flags; replace hand-rolled wrapper scripts with `claude --bg`/`claude attach` where the jobs store suffices; keep terminal-tab + timeout + template-sync glue |
| `bin/autonomy.sh` (428) | Supervisor CLI: start/stop/status/list, `--all` with queue ordering, credit summary | none (no native cross-session re-launch loop) | KEEP | OS-level watchdog/re-launch; `/loop` is session-scoped and dies with the session |
| `bin/cron-schedule.sh` (553) | crontab TUI: add/remove/run-now/launch/bulk-register/tune | Routines (`/schedule`, cloud) — not local cron | KEEP | Local cron is the only way to start a *new* Claude process unattended on this host |
| `bin/dashboard-service.sh` (117) | systemd user unit `claudeos-dashboard.service` (or `@reboot` cron) | — | MODERNIZE | Duplicates `scripts/dashboards/install-supervisor-service.sh`; consolidate to one installer |
| `bin/deploy-launcher.sh` (55) | Copy `templates/linux/{cron-launcher.sh,report-and-mail.py}` → `~/.claudeos` | — | MODERNIZE | Exists only because cron runs a *copy*; run launcher from the repo path (symlink) and delete the deploy step |
| `bin/deploy-prep.sh` (58) | Set `state.deploy.ready/runbook_generated/environment` | — | DEPRECATE | PS1-port jq wrapper; fold into one `state` sub-CLI or a skill |
| `bin/github-pr-flow.sh` (191) | `check/gate/create-draft`: gh readiness + CLAUDE.md auto-merge gate evaluation (judgement only) | none | KEEP | Policy gate outside the model; candidate for a `PreToolUse` hook on `gh pr merge` |
| `bin/incident-response.sh` (53) | P1-P3 triage → `state.maintenance.open_incidents` | — | DEPRECATE | Same as deploy-prep |
| `bin/maintenance-mode.sh` (47) | Flip `phase_mode=maintenance` | — | DEPRECATE | Same |
| `bin/monitor-sessions.sh` (156) | Cross-project list/watch/link/unlink/attach/stop via tmux link-window | `claude agents` / `claude attach` / `claude stop` | MODERNIZE | tmux link-window aggregation is unique (KEEP); list/attach/stop for headless sessions → native |
| `bin/onboard-project.sh` (123) | One-shot: manifest classify + verify-command resolution + release dry-run | — | KEEP | Multi-project discovery; no native |
| `bin/release-check.sh` (120) | Composite gate: git clean / README / .gitignore / test / lint / build | `/verify` (in-session) | MODERNIZE | Out-of-session gate is still needed for supervisor stop condition; could call `claude -p "/verify"` |
| `bin/set-statusline.sh` (49) | Write `statusLine.command` to `~/.claude/settings.json` | `/statusline` built-in | REPLACE_WITH_NATIVE | Also **broken**: points at `scripts/dashboards/statusline.js` which does not exist (D-1) |
| `bin/start-dashboard.sh` (73) | Start Node dashboard, LAN URL hint, port check | — | KEEP | |
| `bin/supervisor-audit.sh` (131) | `report/diff/apply` of `.claudeos/supervisor` manifest across projects | — | KEEP | Multi-project policy rollout |
| `bin/systemd-control.sh` (255) | Per-project *application* services (`claudeos-<proj>.service`, npm start etc.) | — | KEEP | Not Claude-related; OS service management (replaced Docker integration) |
| `bin/weekly-devops.sh` (33) | Print maintenance KPIs from state.json | dashboard | DEPRECATE | Read-only viewer |

## 2. lib/*.sh (20 tracked + 1 untracked)

| Path | Purpose | Native equivalent | Class | Reason |
|---|---|---|---|---|
| `lib/common.sh` (116) | Root/paths, colours, log, `ccsu_claude_supports_name`, `ccsu_claude_session_name` | — | KEEP | Foundation |
| `lib/config-loader.sh` (215) | `config.json` accessors; project discovery (`.git` dirs, groups, excludes); test/lint/build inference | — | KEEP | Multi-project discovery is the core OS value |
| `lib/credits.sh` (75) | Append-only cost ledger (`~/.claudeos/credits/ledger.jsonl`), monthly total, 70/85/95 % guard | `/cost`, `total_cost_usd` in stream-json result | MODERNIZE | Per-session cost is native; cross-session monthly aggregation is not → keep as thin ledger fed by native `result` event |
| `lib/cron-manager.sh` (243) | crontab read/write with `CLAUDEOS:<id>` markers, dow limits | — | KEEP | OS |
| `lib/deploy-launcher.sh` (109) | Idempotent copy + timestamped backup of launcher to `~/.claudeos` | — | MODERNIZE | Remove with bin/deploy-launcher.sh (run from repo) |
| `lib/github-pr-flow.sh` (125) | Pure functions: remote→repo, protected branch, CI rollup, gate eval | — | KEEP | Tested policy logic |
| `lib/json.sh` (118) | jq get/set/append with flock | — | KEEP | |
| `lib/launcher-common.sh` (234) | Project list/select (grouped/flat), run-status | — | KEEP | |
| `lib/model-router.sh` (259) | Task→model/effort (opus xhigh/high, sonnet max), usage-balance (disabled), selection log | `/model`, `/effort`, `settings.model`, `fallbackModel`, `CLAUDE_CODE_SUBAGENT_MODEL`, `--model/--effort` flags | REPLACE_WITH_NATIVE | Routing logic duplicates native; defaults `claude-opus-5`/`claude-sonnet-5` are unverified IDs (Fable 5.1 is current default) (D-3); balance branch is dead (`balanceEnabled=false`) |
| `lib/notify.sh` (58) | Play sound via ffplay/paplay/aplay; `notify__bell` unused | `Notification` hook / `preferredNotifChannel` | REPLACE_WITH_NATIVE | Native notification channels + hook |
| `lib/onboard.sh` (39) | Compose manifest + verify + release summary | — | KEEP | |
| `lib/project-autoinit.sh` (78) | Auto `git init` + CLAUDE.md for new folders (opt-in) | — | KEEP | Discovery helper |
| `lib/queue.sh` (89) | Priority scoring for `--all` start order (security/blocked/deadline/starvation) | — | KEEP | Scheduler logic, tested |
| `lib/release-check.sh` (158) | Gate collectors `name|status|detail` | `/verify` | MODERNIZE | See bin/release-check.sh |
| `lib/supervisor-manifest.sh` (236) | Manifest classify Managed/Missing/Foreign/Invalid, diff, apply | — | KEEP | |
| `lib/supervisor.sh` (419) | Re-launch loop: goal/abnormal/cap/crash-loop stop reasons, throttle tiers by days-remaining, credit guard, state persist | none (jobs supervisor manages *one* session; does not re-launch to a goal) | KEEP | **Core OS boundary** — see §10 |
| `lib/systemd-manager.sh` (163) | Registry + unit render for project apps | — | KEEP | OS |
| `lib/team-runner.sh` (262) | tmux 4-pane CTO/Backend/Frontend/QA, `.worktrees/<role>` + `claudeos/<role>` branches, `--name claudeos-<proj>-<role>`, TEAM_START_PROMPT injection | Agent teams `teammateMode: tmux` (experimental), `claude --worktree`, subagent `isolation: worktree`, cross-session `SendMessage` | REPLACE_WITH_NATIVE (EXPERIMENTAL) | Native covers pane split + worktree + naming; keep only if agent-teams tmux mode proves unstable |
| `lib/template-sync.sh` (131) | Per-launch: sanitize settings.json, copy START_PROMPT (always), TEAM_START_PROMPT/CLAUDE.md (if missing), selected commands/skills (if missing), .coderabbit.yaml | — | MODERNIZE | Distribution is needed, but per-launch `sanitize-settings.js` is a band-aid (D-20); skills should go to `.claude/skills/<n>/SKILL.md` (already does), commands → skills |
| `lib/tmux-runner.sh` (224) | tmux session `claudeos-<safe>`, pipe-pane log, model/name args, `--dangerously-skip-permissions` TUI, safe-mode | `claude --bg` + `claude attach/logs` | MODERNIZE | tmux remains the multiplexing boundary (KEEP), but permission posture diverges from headless path (D-11) |
| `lib/claude-capability.sh` (166, **untracked, new**) | Capability probing of `claude --help` flags/subcommands from `config/claude-code-compat.json` | — | EXPERIMENTAL | v10 work-in-progress; correct direction (probe not version) |

## 3. libexec/*.sh (11 tracked + 1 untracked)

| Path | Purpose | Native equivalent | Class | Reason |
|---|---|---|---|---|
| `diag-agent-teams.sh` (36) | Print `state.agent_teams_usage` + `agent-teams-status.js` | `claude agents --json` | MODERNIZE | Agent-teams telemetry is custom; session state is native |
| `diag-all-tools.sh` (29) | Check node/jq/tmux/gh/claude presence | `claude doctor` (partial) | KEEP | OS prerequisites |
| `diag-architecture.sh` (39) | Required-file + JSON validity check | — | KEEP | |
| `diag-mcp-health.sh` (33) | Inspect `.mcp.json` | `claude mcp list`, `/doctor` | REPLACE_WITH_NATIVE | |
| `diag-mounts.sh` (40) | df / project dir / ping | — | KEEP | OS |
| `diag-worktree.sh` (27) | `git worktree list` | `claude --worktree`, `.claude/worktrees/` | DEPRECATE | Trivial wrapper |
| `goal-extract.sh` (143) | Extract `/goal "..."` from `goals/<type>.md`, ensure `or stop after N turns`, truncate ≤ 4000, strip duplicates | `/goal` (native, works with `claude -p "/goal ..."`) | KEEP (thin adapter) | Correct adapter shape: pure function feeding native `/goal`; tested (`goal-inject.bats`) |
| `setup-terminal.sh` (389) | Install tmux/locale/clipboard, tmux.conf | — | KEEP | OS |
| `stream-json-tail.sh` (107) | Parse `stream-json`: capture `session_id` (resume) + `total_cost_usd` (ledger), human log line | `--output-format stream-json`, `--json-schema` | KEEP (thin adapter) | Native emits the stream; adapter only persists 2 fields |
| `watch-claude-log.sh` (32) | tail newest `~/.claudeos/logs` | `claude logs <id>` (for `--bg` jobs) | MODERNIZE | |
| `watch-session.sh` (444) | Interactive session list/log/stop; already calls `claude agents --json` | `claude agents`, `claude attach/stop` | MODERNIZE | Keep foreground/tmux inventory; hand headless sessions to native |
| `diag-claude-compat.sh` (54, **untracked, new**) | Menu 17: capability matrix from compat json | — | EXPERIMENTAL | v10 WIP |

## 4. scripts/** (41)

| Path | Purpose | Native equivalent | Class | Reason |
|---|---|---|---|---|
| `check-doc-versions.js` | README ⇄ CHANGELOG ⇄ agent-count consistency | — | KEEP | |
| `update-readme-stats.js` (+`.test.js`) | Inject version/agent count into README | — | KEEP | |
| `validate-state-example.js` | Validate `state.json.example` vs schema | — | KEEP | |
| `refresh-onboarding.js` (+`.test.js`) | Regenerate volatile ONBOARDING.md sections from state.json | auto memory / `.claude/rules` | KEEP | Deterministic doc gen |
| `init-claudeos-project.test.js` | Tests `mergeSettings` sanitize invariants | — | KEEP | |
| `sanitize-settings.test.js` | Tests sanitizer | — | DEPRECATE | Dies with sanitizer |
| `dashboards/serve-dashboard.js` (1666) | HTTP dashboard: `/api/{data,cron,agent-teams,supervisor/status,system-health,token,jobs,mc-data,project-ci,events,health}`; serves mission-control.html | `claude agents --json`, `~/.claude/jobs/<id>/state.json` | MODERNIZE | Should read native jobs store + `claude agents --json` instead of parsing `~/.claudeos/sessions` |
| `dashboards/mission-control.html` (2789) | SPA front-end (13 fetch endpoints) | — | MODERNIZE | Mentions `TeamCreate` and `v9.0` (stale) |
| `dashboards/supervisor-daemon.js` (327) | Process supervisor for dashboard/http procs (backoff, health) + observe session files | systemd `Restart=`/`WatchdogSec`; `claude daemon status` | DEPRECATE | Second "supervisor" (name clash with lib/supervisor.sh, D-17); systemd already restarts units |
| `dashboards/install-supervisor-service.sh` (120) | systemd user unit for supervisor-daemon.js | — | DEPRECATE | With daemon; merge into `bin/dashboard-service.sh` |
| `dashboards/watch-and-run.js` (78) | Dev file-watcher restarting the dashboard | — | REMOVE_CANDIDATE | `processes.json` has it `enabled:false`; dev-only |
| `dashboards/pm2.config.js` (28) | pm2 alternative to systemd | — | REMOVE_CANDIDATE | Two process managers; systemd is the chosen path |
| `dashboards/render.js` (217) | Fill `templates/claudeos/dashboards/*.md` → `reports/dashboards` | — | KEEP | |
| `dashboards/render-codemap.js` (240) | Mermaid architecture/deps/agent-chain docs | — | KEEP | |
| `lint/lint-and-fix.js` (187) | Lint + safe `--fix` + summary JSON | `/simplify` (not lint) | KEEP | Target-project tool |
| `release/generate-changelog.js` (170) | Conventional-commit changelog | — | KEEP | |
| `release/generate-deploy-runbook.js` (104) | Runbook from template when `deploy.ready` | — | KEEP | |
| `setup/init-claudeos-project.js` (374) | Fresh install of ClaudeOS bundle into a project (template map, settings merge) | — | MODERNIZE | Distribution mechanism (see §6); should target `.claude/agents`, `.claude/skills`, `.claude/rules` natively |
| `setup/migrate-agent-teams.js` (426) | Diff-distribute agent-teams tracker hooks to existing projects | — | DEPRECATE | References `TeamCreate` (removed v2.1.178); experimental telemetry |
| `setup/sanitize-settings.js` (118) | Strip `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE`, normalise SessionStart matchers | — | DEPRECATE | Band-aid executed on every launch; fix templates then delete |
| `setup/install-mcp.js` (107) | Build `.mcp.json` from catalog + `state.mcp.enabled` | `claude mcp add` | MODERNIZE | |
| `setup/install-review-tools.js` (160) | CodeRabbit + Codex setup check | — | MODERNIZE | Codex part is out of scope (Claude-only repo) |
| `setup/state-template.json` | Seed state.json | — | KEEP | |
| `setup/upgrade-state-json-v9.sh` (122) | One-time v9 migration; hardcoded host IP in comment | — | REMOVE_CANDIDATE | One-shot migration already applied |
| `templates/AGENTS.md` | Distributed AGENTS.md | — | KEEP | Used by init |
| `templates/claude-mcp.json` | MCP template | — | KEEP | |
| `templates/statusline.js` / `templates/claude-statusline.py` | Two statusline implementations | `/statusline` | REPLACE_WITH_NATIVE | Duplicate implementations; `.claude/statusline.py` is a third copy |
| `test/dry-run-execution-matrix.js` (201) | Dry-run matrix of launch paths | — | KEEP | Not wired into `npm test` |
| `test/test-supervisor-smoke.js` (100) | Smoke test for supervisor-daemon.js | — | DEPRECATE | Dies with daemon |
| `tools/agent-teams-status.js` (218) | CLI view of `state.agent_teams_usage` | — | EXPERIMENTAL | Agent teams telemetry |
| `tools/launch-parallel-cron.sh` (312) | Parallel `claude -p` per role (cto,qa) with stagger, roles from `templates/claudeos/roles` | `claude --bg --name`, subagents, agent teams | MODERNIZE | Role prompts → native subagents/skills; launcher stays as thin OS adapter |
| `tools/setup-parallel-cron.sh` (37) | Copy role files to `~/.claudeos/roles` | — | MODERNIZE | Merge into launch-parallel (already has `lp__distribute_roles`) |
| `tools/measure-kpi.js` (123) | gh → `state.metrics` | — | KEEP | |
| `tools/run-audit-scan.js` (223) | Audit trail report | — | KEEP | |
| `tools/run-cmdb-scan.js` (153) | CMDB diff report | — | KEEP | |
| `tools/run-ultrareview.js` (181) | Wrap native `claude ultrareview --json`, save report, add `state.warnings` | `claude ultrareview` / `/code-review ultra` | MODERNIZE | Correct thin-adapter shape; keep monthly cap logic |
| `tools/simulate-trust-score.js` (70) | Trust-score formula simulator | — | KEEP | |
| `tools/sync-github-projects.js` (186) | Projects V2 / label sync | — | KEEP | |

## 5. config/*

| Path | Purpose | Class | Reason |
|---|---|---|---|
| `config.json.template` (190) | Canonical config: projects root, groups/excludes, tools.claude (env, settings, headless), cron, supervisor.defaults, modelRouter, agentSdk, email, statusline, sessionTabs | MODERNIZE | Stale/contradictory keys: `tools.claude.headless.permissionMode: "dontAsk"` while runtime uses `--permission-mode auto` and its own comment says dontAsk is unusable (D-2); `modelRouter.models.*.id = claude-opus-5/claude-sonnet-5` (D-3); `codex`/`copilot` blocks disabled but retained; `env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` + `settings.teammateMode: auto` default-on experimental |
| `config.json` | Local instance (gitignored) | KEEP | Only `localExcludes` + `autoInitProjects` differ from template |
| `processes.json` (43) | Definitions for supervisor-daemon.js (dashboard, watch-runner disabled, session-file observer) | DEPRECATE | With daemon |
| `managed-agents.json.template` (49) | Placeholder IDs for Anthropic Managed Agents PoC; explicitly "no reader code" | EXPERIMENTAL | No consumer in repo |
| `agent-teams-backlog-rules.json` + `.json.template` | Pattern→priority/owner rules | REMOVE_CANDIDATE (one of the two) | Both tracked and identical in intent; README says "copy template" |
| `linux-projects.json` (28) | Static "reference" list of projects incl. Windows-era repos (`ClaudeCode-StartUpTools-New`, `Codex-StartUpTools`) | REMOVE_CANDIDATE | Contradicts dynamic discovery; drifts |
| `github-registry.json` (126) | 20 project → repo mappings (dashboard, bulk-register) | KEEP | |
| `docker-registry.json.lock` (0 B) | Remnant of removed Docker integration | REMOVE_CANDIDATE | |
| `backups/.gitkeep`, `README.md` | | KEEP | |
| `claude-code-compat.json` (**untracked, new**) | 20 capabilities + version policy for probing | EXPERIMENTAL | v10 WIP |

## 6. .github, security files

| Path | Purpose | Class | Reason |
|---|---|---|---|
| `.github/workflows/ci.yml` | ubuntu: bats + node tests + shellcheck | KEEP | |
| `.github/workflows/security-scan.yml` | gitleaks on push/PR/schedule | KEEP | |
| `.gitleaks.toml` | title `ClaudeCode-StartUpTools-New`; allowlists `tests/unit/ArchitectureCheck.Tests.ps1` (nonexistent) | MODERNIZE | Stale Windows-era content (D-6) |
| `.github/dependabot.yml` | github-actions weekly | KEEP | No npm deps to track |
| `SECURITY.md` | Versions v2.9.x/v3.0.0, repo URL `ClaudeCode-StartUpTools-New` | MODERNIZE | Stale (D-7) |
| `.github/mcp.json` | MCP servers using `cmd /c npx` | REMOVE_CANDIDATE | Windows leftover (D-8) |
| `.github/ISSUE_TEMPLATE/*` (5), `PULL_REQUEST_TEMPLATE.md` | | KEEP | |
| `.coderabbit.yaml` | Distributed to projects by template-sync | KEEP | |
| `.codex/{config.toml,config.toml.example,hooks.json,supervisor.json}` | Codex tool residue (manifest says managedBy Codex-StartUpTools) | MODERNIZE | Cross-tool coupling in a Claude-only repo |

## 7. Tests → component map

`npm test` = `bats tests/bats/unit/` (37 files) + `node --test scripts/**/*.test.js` (4 files, 59 tests pass on Node 22). `scripts/test/dry-run-execution-matrix.js` and `test-supervisor-smoke.js` are not in `npm test`.

| Component | Test |
|---|---|
| bin/autonomy.sh | autonomy.bats |
| bin/cron-schedule.sh | cron-schedule.bats |
| bin/start-claude.sh | start-claude.bats, session-name.bats |
| bin/start-dashboard.sh | start-dashboard.bats |
| bin/menu.sh, start.sh | menu.bats, start.bats |
| bin/{dashboard-service,deploy-prep,incident-response,maintenance-mode,set-statusline,weekly-devops}.sh | bin-ops.bats |
| bin/systemd-control.sh + lib/systemd-manager.sh | systemd-manager.bats |
| bin/github-pr-flow.sh / lib/github-pr-flow.sh | github-pr-flow.bats |
| lib/common, config-loader, json, launcher-common, credits, cron-manager, deploy-launcher, model-router, notify, onboard, project-autoinit, queue, release-check, supervisor, supervisor-manifest, team-runner, template-sync, tmux-runner | one bats each (config/json/launcher-common/credits/cron-manager/deploy-launcher/model-router/notify/onboard/project-autoinit/queue/release-check/supervisor/supervisor-manifest/team-runner/template-sync/tmux-runner) |
| libexec/goal-extract.sh | goal-inject.bats |
| libexec/stream-json-tail.sh + model-router (headless) | cron-launcher-headless.bats, launch-parallel.bats |
| libexec/watch-session.sh, diag-*.sh, setup-terminal, watch-claude-log | watch-session.bats, diag.bats |
| scripts/tools/launch-parallel-cron.sh | launch-parallel.bats |
| scripts/dashboards/install-supervisor-service.sh | install-supervisor-service.bats |
| Template hooks heartbeat-watchdog / notification-gate / stop-failure-gate / webhook-notifier (under **Claude/templates**, not `.claude`) | heartbeat-watchdog.bats, notification-gate.bats, stop-failure-gate.bats |
| scripts/setup/sanitize-settings.js, init-claudeos-project.js, refresh-onboarding.js, update-readme-stats.js | node tests |
| **Untested**: bin/monitor-sessions.sh, bin/onboard-project.sh (lib tested), bin/release-check.sh CLI, bin/supervisor-audit.sh CLI, lib/claude-capability.sh, libexec/diag-claude-compat.sh, serve-dashboard.js, mission-control.html, supervisor-daemon.js (smoke only, not in npm test), all `.claude/claudeos/scripts/hooks/*.js` except session-start.js, workflows/*.js, Claude/templates/linux/report-and-mail.py, cron-launcher.sh end-to-end (only headless flag tests) | — |

## 8. state.json / state.schema.json / state.json.example

- **Shape**: `state.json` (36 KB) top-level keys: `_note, agent_teams_usage, automation, cache, codex, compact, debug, deploy, dreaming, effort_strategy, execution, frontier, goal, improvement, kpi, learning, maintenance, mcp, message_bus, metrics, notification, onboarding, project, session, stable, supervisor, task_budget, token, warnings`. Schema `required`: `goal, kpi, execution, stable, token, effort_strategy, compact, notification`. Schema lacks `agent_teams_usage`, `dreaming`, `frontier`, `metrics`, `mcp`, `warnings` (present in live file) and defines `credits`, `goal_type` (absent in live file) → schema/instance drift (D-15).
- **Goal system**: `state.goal.title` (string) is the *project* goal; the *session* `/goal` directive is not stored in state — it is extracted at launch from `Claude/templates/claudeos/goals/<goal_type>.md` by `libexec/goal-extract.sh` (goal_type derived from state by cron-launcher `RESUME_GOAL_TYPE`), prefixed to the prompt, and evaluated natively by Claude Code's `/goal` Stop hook (Haiku). Supervisor stop = `deploy.ready=true` or `phase_mode ∈ {maintenance, released}` (goal reached), `kpi.security_critical>0` or `blocked_issues≠∅` (abnormal), daily minutes/restarts cap, crash-loop.
- **KPI**: `kpi.success_rate_target=0.9` only in live file; `metrics` block filled by `scripts/tools/measure-kpi.js` (gh CI/issue stats); `stable.consecutive_success` used by STABLE judgement (docs) and `notify-stable.js`.
- **Trust score**: not in state.json; lives in `.claude/claudeos/data/trust-score.json` (`level: 3, score: 0.9, auto_merge_enabled, history`) written by `hooks/session-end.js`; formula (CI rate 0.5 + STABLE 0.3 + streak 0.1 − blocked penalty; L2 ≥ 0.75, L3 ≥ 0.87) documented in `.claude/claudeos/docs/trust-ledger.md` and simulated by `scripts/tools/simulate-trust-score.js`. `run-ultrareview.js` gates on Trust Level ≥ 2.
- **Effort strategy**: `effort_strategy.default/current = xhigh` in state, while model-router passes `--effort high|xhigh` from config — two sources of truth for effort (D-16).
- **Readers** (45 files): all bin state editors, lib/{credits,queue,supervisor,launcher-common}, cron-launcher.sh, report-and-mail.py, 12 hooks, dashboard, measure-kpi, sync-github-projects, refresh-onboarding, init/install scripts.
- **Writers**: `bin/deploy-prep.sh`, `bin/incident-response.sh`, `bin/maintenance-mode.sh` (via `json_set`), `scripts/tools/run-ultrareview.js` (warnings/feature_flags), `scripts/tools/measure-kpi.js` (metrics), hooks `session-start.js`/`session-end.js`/`usage-tracker.js`/`agent-teams-tracker.js`/`pre-compact.js`/`notify-stable.js`/`dreaming-runner.js` (per sub-inventory), `supervisor-daemon.js` (writes its own `~/.claudeos/supervisor/state.json`, a different file). `state.warnings` has 51 entries (unbounded growth).

## 9. Subsystem summaries

| Subsystem | Components | How it works | Native overlap | Verdict |
|---|---|---|---|---|
| **Supervisor (autonomy)** | `lib/supervisor.sh`, `bin/autonomy.sh`, `lib/queue.sh`, `lib/credits.sh`, `lib/supervisor-manifest.sh`, `bin/supervisor-audit.sh` | `setsid` loop per project: check stop flag → project stop reason (state.json) → daily cap → crash-loop → run `~/.claudeos/cron-launcher.sh <proj> <min>` (blocks) → record cost → cooldown → repeat. Throttle tier by `release_deadline` days remaining. Persists `~/.claudeos/supervisor/<proj>.json` | `claude --bg` supervisor keeps *one* session alive; `/loop` is in-session; Routines are cloud | **KEEP** — OS boundary: "start a *new* process after the previous one exits, until goal" |
| **Cron** | `lib/cron-manager.sh`, `bin/cron-schedule.sh`, `scripts/tools/{launch,setup}-parallel-cron.sh`, `Claude/templates/linux/cron-launcher.sh` (deployed copy) | crontab lines tagged `CLAUDEOS:<id>` → `cron-launcher.sh` → headless `claude -p` with `/goal` injection, resume by saved `session_id`, stream-json → log + cost | `CronCreate`/`/loop` (session-scoped), Routines (cloud) | **KEEP** launcher as thin adapter; **MODERNIZE** by removing the deploy copy and shrinking prompt assembly (`--append-system-prompt-file`, `/goal` native) |
| **tmux** | `lib/tmux-runner.sh`, `lib/team-runner.sh`, `bin/monitor-sessions.sh` | `claudeos-<safe>` session, pipe-pane log; team = 4 panes + worktrees | `claude --bg/attach`, agent teams tmux mode, `--worktree` | tmux-runner **KEEP** (fallback when Agent SDK credits exhausted); team-runner **REPLACE_WITH_NATIVE** (experimental) |
| **systemd** | `lib/systemd-manager.sh`, `bin/systemd-control.sh`, `bin/dashboard-service.sh`, `scripts/dashboards/install-supervisor-service.sh` | user units for project apps and the dashboard/daemon | — | **KEEP** project/app units; consolidate dashboard installers; drop daemon |
| **Model router** | `lib/model-router.sh`, `config.modelRouter`, `docs/claude/13` | task keyword → opus(xhigh/high)|sonnet(max); logs to `~/.claudeos/model-usage.jsonl` | `--model/--effort`, `settings.model`, `/model`, `fallbackModel`, subagent `model:` frontmatter | **REPLACE_WITH_NATIVE**: keep at most a `taskEffort` map in config → `--effort` |
| **Goal** | `libexec/goal-extract.sh`, `Claude/templates/claudeos/goals/*.md`, `hooks/verify-goal-set.js` | extract/normalise `/goal` block → prompt head | `/goal` (Stop-hook evaluator) | **KEEP** adapter (native does evaluation); drop `verify-goal-set.js` if native `/goal` status suffices |
| **Mission control / dashboard** | `serve-dashboard.js`, `mission-control.html`, `render*.js`, `supervisor-daemon.js`, `processes.json`, `watch-and-run.js`, `pm2.config.js` | Node http server on :3737, polls `~/.claudeos/sessions`, crontab, supervisor JSON, GitHub CI | `claude agents --json`, `~/.claude/jobs/*/state.json`, `claude daemon status` | **MODERNIZE** server/UI to consume native stores; **DEPRECATE** daemon; **REMOVE** watch-and-run/pm2 |
| **Self-improvement** | `hooks/reasoning-bank.js`, `hooks/dreaming-runner.js`, `hooks/session-end.js`, `data/{reasoning-bank.json,trust-score.json,audit-log.jsonl}`, commands `evolve.md`/`learn.md`, `docs/trust-ledger.md` | session-end writes trust score + reasoning bank; dreaming curates memories (uses `@anthropic-ai/sdk` → extra API cost) | auto memory, `/compact` summaries, `SessionEnd`/`PostCompact` hooks, `.claude/rules` | **MODERNIZE**: keep trust ledger (gates auto-merge), move "learning" to native auto memory; dreaming-runner is **EXPERIMENTAL** (direct SDK calls outside Claude Code) |
| **Monitoring** | `bin/monitor-sessions.sh`, `libexec/watch-session.sh`, `libexec/watch-claude-log.sh`, `hooks/heartbeat-watchdog.js` (templates only), `report-and-mail.py` | tmux/foreground/headless inventory + `claude agents --json`; SMTP report after session (env `CLAUDEOS_SMTP_USER/PASS`, `CLAUDEOS_DEFAULT_FROM/TO`) | `claude agents/logs/attach/stop`, `Notification` hook | **MODERNIZE** around native session store; e-mail report **KEEP** (no native) |

## 10. OS-level capabilities Claude Code cannot replace (KEEP boundary)

| Capability | Owner | Boundary statement |
|---|---|---|
| Spawn a **new** `claude` process unattended (cron, `@reboot`, timers) | cron-manager, cron-schedule, cron-launcher | Native `/loop`, `CronCreate`, `/goal` live *inside* a session; Routines run in the cloud, not on this host |
| **Re-launch until goal** with daily caps, crash-loop and credit guards across sessions | lib/supervisor.sh, autonomy.sh | `claude --bg` supervises one session; it does not resume-to-goal after exit or enforce cross-session budgets |
| **Multi-project discovery / ordering / policy rollout** over `/home/kensan/Projects/*` | config-loader, launcher-common, queue, supervisor-manifest, onboard, project-autoinit | Claude Code is single-project per process |
| **tmux multiplexing & log capture** for interactive fallback | tmux-runner, monitor-sessions (link-window) | `claude agents` lists sessions but does not multiplex terminals |
| **systemd** units for project applications and the dashboard | systemd-manager, systemd-control, dashboard-service | Not a Claude concern |
| **Terminal/OS setup** (tmux, locale, clipboard, tool checks, mounts) | setup-terminal, diag-all-tools, diag-mounts | — |
| **Watchdog/timeout** (`timeout --foreground`, heartbeat) and **credit/budget ledger** across sessions | cron-launcher, supervisor, credits | Native retry/stream watchdog env vars are per-process |
| **Out-of-model policy gates** (GitHub auto-merge gate, release-check, trust ledger gating auto-merge) | github-pr-flow, release-check, trust-score | Should remain outside the model's reach (hook or CLI), even if implemented as `PreToolUse` hooks |
| **Post-session e-mail report** | report-and-mail.py | No native channel |

## 10b. Top 10 REPLACE_WITH_NATIVE candidates (ordered by payoff)

| # | Component | Native feature (2.1.263) | Note |
|---|---|---|---|
| 1 | `lib/model-router.sh` + `config.modelRouter` (+ `docs/claude/13`) | `--model/--effort` flags, `settings.model`, `fallbackModel`, `/model`, `/effort`, `CLAUDE_CODE_SUBAGENT_MODEL`, subagent `model:` frontmatter | 259 lines + unverified `claude-opus-5` IDs; keep at most a `taskEffort` map |
| 2 | 43 agents in `.claude/claudeos/agents/` (never discovered) → ≤10 in `.claude/agents/` | Subagents with `model/effort/permissionMode/maxTurns/isolation: worktree`; built-in Explore/Plan | `planner`→Plan, `docs-lookup`→Explore, `refactor-cleaner`→/simplify, `code-reviewer`→/code-review; 13 language stubs deleted |
| 3 | `commands/{code-review,verify,refactor-clean,build-fix,go-build,plan,orchestrate,multi-*}.md` | bundled `/code-review`, `/verify`, `/simplify`, `/debug`, Plan mode, `/workflows` + `.claude/workflows/*.js` | 14 commands |
| 4 | `claudeos/rules/**` (14) and `claudeos/skills/*` (66, no frontmatter) | `.claude/rules/*.md` with `paths:`; `.claude/skills/<n>/SKILL.md` with `name/description/when_to_use` | keep 3 real skills; `security-review`/`security-scan`/`verification-loop`/`autonomous-loops`/`skill-stocktake` → `/security-review`, `/verify`, `/loop`, `/skill-doctor` |
| 5 | `lib/team-runner.sh` (tmux 4-pane + per-role worktrees + `--name`) | agent teams `teammateMode: tmux`, `claude --worktree`, subagent `isolation: worktree`, `SendMessage` | EXPERIMENTAL dependency — keep team-runner as fallback until teams GA |
| 6 | `bin/set-statusline.sh` + `scripts/templates/{statusline.js,claude-statusline.py}` + `.claude/statusline.py` | `/statusline` | current script path is broken anyway (D-1) |
| 7 | `commands/session-info.md`, `commands/cron-*.md`, `work-time-*.md` (call non-existent `cron-cli.sh`) | `/context`, `/cost`, `/status`; `CronCreate`, `/loop`, `/schedule` (Routines) | OS crontab stays in `bin/cron-schedule.sh` |
| 8 | `lib/notify.sh`, `hooks/webhook-notifier.js`, `hooks/notify-stable.js` | `Notification` hook event, hook `type: http`, `preferredNotifChannel` | remove `claude push-notify` dependency |
| 9 | `hooks/reasoning-bank.js`, skills `continuous-learning(-v2)`, commands `learn/evolve/instinct-*`, `.claude/skills/cto-session-start` | auto memory, `.claude/rules`, `SessionStart` context injection (already in session-start.js) | keep trust ledger (auto-merge gate) |
| 10 | `libexec/diag-mcp-health.sh`, `libexec/diag-worktree.sh`, `system/progressive-disclosure.md`, `docs/agent-communication-protocol.md`, `scripts/tools/run-ultrareview.js` | `claude mcp list`/`/doctor`, `.claude/worktrees/`, native skill lazy-loading, `/list-agents` + `SendMessage`, `/code-review ultra` | run-ultrareview keeps only the monthly cap |

---

## 11. Defects found (not fixed)

| # | Severity | Finding | Evidence |
|---|---|---|---|
| D-1 | High | `bin/set-statusline.sh` default command points to `scripts/dashboards/statusline.js`, which does not exist (implementations are `scripts/templates/statusline.js`, `scripts/templates/claude-statusline.py`, `.claude/statusline.py`) | `bin/set-statusline.sh:27` |
| D-2 | High | Config/runtime contradiction on headless permission mode: `config.json.template` `tools.claude.headless.permissionMode = "dontAsk"`, but `cron-launcher.sh` and `start-claude.sh` hardcode `--permission-mode auto` and the launcher comment states dontAsk "kills Bash/MCP"; the config key is never read | `config/config.json.template`, `Claude/templates/linux/cron-launcher.sh:~395-440` |
| D-3 | High | Model IDs `claude-opus-5` / `claude-sonnet-5` hardcoded as defaults in `lib/model-router.sh`, `config.json.template`, `docs/claude/13`; Claude Code 2.1.263 default is Fable 5.1 — IDs unverified, no `fallbackModel` | `lib/model-router.sh:72,86` |
| D-4 | High | `.claude/agents/` does not exist: the 43 agent files under `.claude/claudeos/agents/` are **not** native subagents (never discovered by Claude Code); same for `.claude/rules/` (absent) | `ls .claude` |
| D-5 | Medium | Live `.claude/claudeos/scripts/hooks/` (19 files) lacks `heartbeat-watchdog.js`, `notification-gate.js`, `stop-failure-gate.js` that exist in `Claude/templates/claudeos/scripts/hooks/`; bats tests target the template copies — live tree and template tree have diverged | `tests/bats/unit/{heartbeat-watchdog,notification-gate,stop-failure-gate}.bats` |
| D-6 | Low | `.gitleaks.toml` title references `ClaudeCode-StartUpTools-New` and allowlists `tests/unit/ArchitectureCheck.Tests.ps1` (PowerShell file that does not exist here) | `.gitleaks.toml` |
| D-7 | Low | `SECURITY.md` supported versions v2.9.x / v3.0.0 and repo link to the Windows repo; package is 4.0.0-linux | `SECURITY.md` |
| D-8 | Low | `.github/mcp.json` uses `cmd /c npx` (Windows) | `.github/mcp.json` |
| D-9 | Low | `config/docker-registry.json.lock` is a 0-byte remnant of the removed Docker integration; `config/linux-projects.json` static list includes Windows-era repos and contradicts dynamic discovery; `agent-teams-backlog-rules.json` and its `.template` are both tracked | `config/` |
| D-10 | **Critical (local hygiene)** | `docs/GH-Claude.txt` (untracked; excluded only via `.git/info/exclude`) contains two credential-pattern strings (Anthropic API key and GitHub PAT formats). It is not in git history and CI gitleaks passed, but it sits in a distributable docs folder. Rotate the credentials and delete the file; add pattern to `.gitignore`. Values intentionally not reproduced. | `grep -c 'sk-ant-\|ghp_\|github_pat_'` = 2 |
| D-11 | Medium | Inconsistent permission posture across launch paths: headless uses `--permission-mode auto`; tmux TUI and cron TUI fallback use `--dangerously-skip-permissions` (bypasses `autoMode.hard_deny`, per the launcher's own comment) | `lib/tmux-runner.sh:171-173`, `cron-launcher.sh:532-596` |
| D-12 | Medium | Deployed launcher (`~/.claudeos/cron-launcher.sh`) hardcodes the live repo path `$PROJECTS_BASE/Claude-StartUpTools-New-Linux/{lib,libexec,Claude/templates}`; the "deploy copy" design creates drift (`bin/deploy-launcher.sh` exists solely to fight it) | `cron-launcher.sh:31,36,323,364,414` |
| D-13 | Medium | Local checkout drift: `origin/main` is at `44ba960` (PR #98 merged 2026-08-15) while local `main` is `76ba161`; working tree has uncommitted edits to `CLAUDE.md`, `AGENTS.md`, `Claude/templates/claude/{CLAUDE.md,START_PROMPT.md}`, `.claude/claudeos/data/*.json` and untracked v10 files (`lib/claude-capability.sh`, `libexec/diag-claude-compat.sh`, `config/claude-code-compat.json`, `Claude/CLAUDE-back.md`, `GITHUB_POLICY.md`, `docs/architecture/`) | `git status`, `git fetch --dry-run` |
| D-14 | Medium | `CLAUDE.md` is 699 lines / 41 KB and exists as **three identical copies** (`CLAUDE.md`, `Claude/CLAUDE.md`, `Claude/templates/claude/CLAUDE.md`); native guidance is < 200 lines with `.claude/rules/*.md` + `@imports` | `wc -l`, `diff -q` |
| D-15 | Low | `state.schema.json` drift: live `state.json` has `agent_teams_usage, dreaming, frontier, metrics, mcp, warnings` not in schema; schema defines `credits, goal_type` absent from live file; `warnings` has 51 entries and grows unbounded | `jq keys` |
| D-16 | Low | Two sources of truth for effort: `state.effort_strategy.default = xhigh` vs `config.modelRouter` (`high` normal / `xhigh` high-risk) passed via `--effort` | state.json, lib/model-router.sh |
| D-17 | Low | Two unrelated "supervisors": `lib/supervisor.sh` (autonomy re-launch) and `scripts/dashboards/supervisor-daemon.js` (process manager for dashboard) writing different `state.json` files (`~/.claudeos/supervisor/<proj>.json` vs `~/.claudeos/supervisor/state.json`) | headers |
| D-18 | Low | Duplicate systemd installers for the dashboard (`bin/dashboard-service.sh` → `claudeos-dashboard.service`; `scripts/dashboards/install-supervisor-service.sh` → daemon unit) plus `pm2.config.js` | |
| D-19 | Low | Mixed version strings across docs/code: `4.0.0-linux` (package/config), `v3.4.0/v3.4.2` (supervisor/launcher headers), `v8.2.x` (scripts), `v9.0` (ONBOARDING.md, mission-control.html, upgrade script), `v10` (new files); README claims "43体+44コマンド" while `.claude/claudeos/commands` holds 46 | grep |
| D-20 | Low | `sanitize-settings.js` runs on **every** launch via `template-sync.sh` to repair `settings.json` — a symptom of templates still shipping the removed `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE`/`SessionStart matcher "*"` pattern; fix at the source | `lib/template-sync.sh:48-55` |
| D-21 | Low | `mission-control.html` and `scripts/setup/migrate-agent-teams.js` reference `TeamCreate` (tool removed in v2.1.178); `config.json.template` turns on `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` and `teammateMode: auto` by default | grep |
| D-22 | Low | Dead code: `model_router__balance_*` path (disabled by default), `notify__bell` (defined, never called), `tools.codex`/`tools.copilot` config blocks (disabled), `.codex/` directory in a Claude-only repo | grep callers |
| D-23 | Low | `package.json` `test:node` masks failures (`2>/dev/null \|\| echo 'No Node test files found'` → exit 0 on error); `scripts/test/dry-run-execution-matrix.js` and `test-supervisor-smoke.js` are not part of `npm test` | package.json |
| D-24 | Low | `AGENTS.md` points to an external policy file in a sibling repo (`/home/kensan/Projects/Deep-Seek-Harness-Project/GITHUB_POLICY.md`) — cross-repo coupling by absolute path | AGENTS.md |

---

## 12. Sub-inventory A — `.claude/settings*.json`, hooks, workflows, commands/skills, `.claude/claudeos/**`

### 12.0 Totals

| Path | Files | Notes |
|---|---|---|
| `.claude/claudeos/` | 306 | 29 subdirs: agents 43, skills 66, commands 46, scripts 24 (hooks 19 = 18 js + package.json, lib 2, tools 1, project-sync.sh, package.json), snapshots 23 (gitignored), rules 14, system 10, docs 10, hooks 9, loops/goals/examples 7 each, dashboards 4, ci/contexts/data/evolution/executive/management/review-configs/tests 3 each, .claude-plugin/roles/workflows/worktree 2 each, frontier/mcp-configs 1, README.md, marketplace.json |
| `.claude/workflows/*.js` | 3 | disjoint from the 3 in `Claude/templates/claude/workflows/` |
| `.claude/commands/` | 2 | byte-identical copies of `claudeos/commands/{design-sync-check,safe-auto-merge}.md` |
| `.claude/skills/` | 3 | cto-session-start, verify-startuptools, webui-health-check |
| `.agents/skills/` | 3 | untracked; two are the **Codex** repo versions pasted in; `.agents/` is not a Claude Code discovery path |
| `.claude/settings.json`, `settings.local.json`, `statusline.py` | 3 | |

### 12.1 `.claude/settings.json` / `settings.local.json` / `.mcp.json`

| Event | Matcher | Command | Exists? |
|---|---|---|---|
| PreCompact | `*` | `node .claude/claudeos/scripts/hooks/pre-compact.js` | yes |
| SessionStart | `startup\|resume\|clear` | `session-start.js`, `verify-goal-set.js` | yes |
| Stop | `*` | `session-end.js` | yes |
| PostToolUse | `Agent` | `usage-tracker.js`, `agent-teams-tracker.js` | yes |
| PostToolUse | `SendMessage` | `agent-teams-tracker.js` | yes |
| PostToolUse | `Bash\|mcp__.*` | `audit-trail.js` | yes |
| TeammateIdle / TaskCreated / TaskCompleted | `*` | `teammate-idle-gate.js` / `task-created-gate.js` / `task-completed-gate.js` | **MISSING** in `.claude/claudeos/scripts/hooks/`; exist only under `Claude/templates/claudeos/scripts/hooks/` (grep hits: `.claude/settings.json`, `Claude/templates/claude/settings.json`, `Claude/templates/claude/CLAUDE-back.md`, the three template files). Every such event runs `node` on a non-existent path → gates never enforce |

Other keys: `permissions.defaultMode: "auto"` (**ignored in project scope since 2.1.257**); `permissions.allow` 49 entries incl. `Bash(rm *)`, `Bash(kill *)`, `Bash(curl *)`, `Bash(chmod *)`, `mcp__github__*`, `mcp__memory__*`, `WebFetch(*)`, `WebSearch(*)` (very broad); `permissions.deny` 6 (force-push / push to main|master) — KEEP; `autoMode.hard_deny` = `$defaults` + 7 rules — valid; `env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`, `ENABLE_TOOL_SEARCH`, `ENABLE_PROMPT_CACHING_1H`, `CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION` (legacy/undocumented; `promptSuggestionEnabled` also set as a real key); `teammateMode: "auto"`; `fallbackModel: ["opus","sonnet","haiku"]` (documented type is a single string); `outputStyle`, `language`, `alwaysThinkingEnabled`, `worktree.baseRef: "head"`, `terminal.mode`, `respectGitignore`, `includeCoAuthoredBy`, `autoUpdatesChannel` — valid. `teammateDefaultModel` absent (good). `requiredMinimumVersion` absent (template has `2.1.224`).

Live vs template settings: template additionally wires `PreToolUse(Bash, if: Bash(git *), continueOnBlock)` → pre-commit-gate.js, `SessionStart` → heartbeat-writer.js, `Notification(idle_prompt|permission_prompt)` → notification-gate.js, `StopFailure` → stop-failure-gate.js, PostToolUse → agent-transcript.js / auto-format.js; and does **not** wire `verify-goal-set.js`.

`settings.local.json`: `enabledMcpjsonServers: [byterover, context7, github, sequential-thinking, brv]` — `byterover`/`brv` are not defined in `.mcp.json`; `memory` is defined but not enabled. `.mcp.json` servers: `github`, `memory`, `sequential-thinking`, `context7`. (`claudeos/mcp-configs/mcp-servers.json` lists `github, supabase, vercel, railway` — unrelated to this stack.)

### 12.2 `.claude/claudeos/scripts/hooks/*.js` (19)

| File | Lines | Wired to | Purpose | Native overlap | Class | Reason |
|---|---|---|---|---|---|---|
| agent-teams-tracker.js | 184 | PostToolUse(Agent, SendMessage) | Named-Agent spawns / SendMessage → `state.agent_teams_usage` | agent teams (experimental); live `TeamCreate` branch (tool removed v2.1.178) | EXPERIMENTAL | dead TeamCreate branch |
| agent-transcript.js | 105 | none in live (template only) | Subagent prompt/result → `reports/agent-transcripts/` | SubagentStop hook, native transcripts | DEPRECATE | unwired |
| audit-trail.js | 106 | PostToolUse(Bash\|mcp__.*) | JSONL audit of gh/git/MCP writes → `data/audit-log.jsonl` | — | KEEP | governance value |
| auto-format.js | 48 | none in live (template only) | Formatter on Edit/Write | — | DEPRECATE | unwired |
| dreaming-runner.js | 339 | spawned by session-end if `state.dreaming.dreaming_enabled` | "Dreams" pattern analysis via `@anthropic-ai/sdk` (node_modules absent) | — | EXPERIMENTAL | research-preview; off by default; direct SDK cost outside Claude Code |
| evaluate-session.js | 1 | none | `console.log` stub | — | REMOVE_CANDIDATE | dead |
| notify-stable.js | 170 | required by session-end | Push notify on STABLE/Blocked via `claude push-notify` (unverified subcommand) + webhook | Notification hook | MODERNIZE | depends on unverified CLI subcommand |
| package.json | 12 | — | deps for dreaming-runner | — | EXPERIMENTAL | |
| pre-commit-gate.js | 56 | none in live (template wires PreToolUse) | lint + test:quick before `git commit` | PreToolUse `if:` | MODERNIZE | wire or drop |
| pre-compact.js | 132 | PreCompact | Snapshot state.json + evacuation; exit 2 blocks compact on failure | PreCompact/PostCompact | KEEP | correct native usage |
| quality-gate-check.js | 94 | required by session-end | lint/coverage thresholds → `state.warnings` | — | KEEP | |
| reasoning-bank.js | 374 | required by session-start/-end | Cross-session hints in `data/reasoning-bank.json` | auto memory / `.claude/rules` | MODERNIZE | overlaps native memory |
| session-end.js | 394 | Stop | Final state write, learning, trust score, webhook, notify, spawns run-cmdb-scan / run-audit-scan / sync-github-projects / generate-deploy-runbook / measure-kpi, dreaming | Stop, `/goal` evaluator | KEEP (split) | monolithic; fallback path `.claude/claudeos/scripts/tools/measure-kpi.js` missing |
| session-start.js | 266 | SessionStart | `hookSpecificOutput` (additionalContext, sessionTitle, reloadSkills) with resume hints | SessionStart | KEEP | current hook JSON contract |
| suggest-compact.js | 63 | none | Suggest `/compact` | auto-compact | REMOVE_CANDIDATE | dead |
| tdd-coverage-scan.js | 130 | required by session-end | Changed sources without tests → `state.warnings` | — | KEEP | |
| usage-tracker.js | 94 | PostToolUse(Agent) | Agent/Skill usage → `learning.usage_history` | — | MODERNIZE | header says matcher `Agent\|Skill`; settings only `Agent` → Skill usage never recorded |
| verify-goal-set.js | 133 | SessionStart | Extract `/goal` from START_PROMPT.md as reminder | `/goal` | MODERNIZE | comments cite `start.bat`/`Start-ClaudeCode.ps1`; START_PROMPT.md absent at repo root |
| webhook-notifier.js | 252 | required by session-end/notify-stable/dreaming | Teams/HTTPS/Slack webhooks (URLs via env) | hook `type: http` | MODERNIZE | native http hooks |

Dead/unwired: evaluate-session, suggest-compact (zero refs); agent-transcript, auto-format, pre-commit-gate (template-wired only); the gate trio referenced but missing.

### 12.3 `.claude/workflows/*.js` (3)

| File | Lines | Orchestrates | API | Class |
|---|---|---|---|---|
| bug-investigation.js | 97 | 5 parallel hypothesis agents → pipeline debate → converge | official (`export const meta`, `phase()`, `parallel()`, `pipeline()`, `agent()` with schema) | KEEP |
| code-review-parallel.js | 119 | security/performance/coverage reviews → adversarial verify → synthesize | official | KEEP (overlaps `/code-review ultra`) |
| feature-development.js | 93 | architect → backend/frontend/test parallel → integrate (`args.feature`) | official | KEEP |

Defect: template set (`classify-and-act.js`, `generate-and-filter.js`, `loop-until-done.js`) is disjoint — template-sync/init would replace these.

### 12.4 `.claude/commands` (2), `.claude/skills` (3), `.agents/skills` (3)

| File | Purpose | Class | Reason |
|---|---|---|---|
| `.claude/commands/design-sync-check.md` | Design-system readiness audit | DEPRECATE | byte-identical duplicate of `claudeos/commands/design-sync-check.md` |
| `.claude/commands/safe-auto-merge.md` | gh PR merge with main-branch y/N gate | DEPRECATE | byte-identical duplicate (also `goals/safe-auto-merge.md`) |
| `.claude/skills/cto-session-start/SKILL.md` | Read state.json, gh lists, pick action | REPLACE_WITH_NATIVE | session-start.js + `/goal` already do this; duplicates CLAUDE.md §25 |
| `.claude/skills/verify-startuptools/SKILL.md` | Repo verification loop (bash -n, bats, template-sync) | KEEP | proper frontmatter, repo-specific |
| `.claude/skills/webui-health-check/SKILL.md` | Mission Control health at :3737 | KEEP | |
| `.agents/skills/*` (3, untracked) | Copies; `verify-startuptools`/`webui-health-check` reference `Codex-StartUpTools-New-Linux`, `.Codex/claudeos`, `Codex/templates/Codex/AGENTS.md` | REMOVE_CANDIDATE | wrong repo, non-discovery path |

### 12.5 `.claude/claudeos/agents/` (43) — grouped

Frontmatter: 36 have `name/description/tools` (34 × `Read, Write, Edit, Bash, Grep, Glob`); **0 set `model`** (no stale model strings; `performance-reviewer.md` mentions "v8.2.5"); no `effort/permissionMode/maxTurns/skills/hooks/memory/background/isolation`. **7 have no frontmatter** (`architect, dev-api, dev-ui, ops, orchestrator, qa, tester`). **41/43 begin with a UTF-8 BOM** (only `audit-agent`, `cmdb-agent` clean). All 43 share the boilerplate section `## 停止理由出力（Agent View 可視化）`; 25 are 24–25-line stubs. None of this is discoverable anyway because `.claude/agents/` does not exist in this repo (D-4).

| Group | Agents | Overlap |
|---|---|---|
| Executive / orchestration (6) | cto, chief-of-staff, orchestrator, manager, loop-operator, release-manager | `orchestrator` ≈ lead session; `loop-operator` ≈ `/loop`; manager/chief-of-staff/release-manager overlap each other and CLAUDE.md Lead |
| Planning / design (3) | planner, architect, api-designer | `planner` ≈ built-in **Plan**; `docs-lookup` ≈ built-in **Explore** |
| Development (7) | dev-api, dev-ui, refactor-cleaner, tdd-guide, doc-updater, docs-lookup, harness-optimizer | `refactor-cleaner` ≈ `/simplify`; `tdd-guide` ≈ command tdd + skill tdd-workflow; `doc-updater` ≈ command update-docs |
| Build resolvers (7) | build-error-resolver, cpp/go/java/kotlin/rust/pytorch-build-resolver | 6 language variants of one 23-line template ≈ `/debug` |
| Reviewers (11) | code-reviewer, cpp/go/java/kotlin/python/rust/typescript-reviewer, database-reviewer, performance-reviewer, security-reviewer | ≈ `/code-review`, `/security-review`; 7 language reviewers are 24-line stubs |
| QA / test (4) | qa, tester, e2e-runner, outcome-grader | qa/tester/e2e-runner overlap; `outcome-grader` (scores `system/stable-rubric.json`) is unique |
| Ops / CI / incident (3) | ops, ci-manager, incident-triager | `ci-manager` duplicates `ci/ci-manager.md` |
| Audit / CMDB (2) | audit-agent, cmdb-agent | unique, best-formed |

Classification: KEEP 6 (cto, outcome-grader, audit-agent, cmdb-agent, security-reviewer, ci-manager); MODERNIZE 7 (no-frontmatter set); REPLACE_WITH_NATIVE 4 (planner→Plan, docs-lookup→Explore, refactor-cleaner→/simplify, code-reviewer→/code-review); DEPRECATE 13 (language reviewers + build-resolvers); REMOVE_CANDIDATE/merge 13 (orchestrator, loop-operator, chief-of-staff, manager, release-manager, tester, harness-optimizer, api-designer, database-reviewer, performance-reviewer, doc-updater, tdd-guide, incident-triager) → consolidate to ≤ 10 agents under `.claude/agents/`.

### 12.6 `.claude/claudeos/skills/` (66) — grouped

**0/66 have YAML frontmatter** → not auto-invocable; `/skill-doctor` will flag all. **62/66 are 66-line boilerplate stubs** differing only in H1 / one sentence / "相性のよい command|agents". Real content only in `performance-review`, `requirements-extractor`, `verification-loop`. Skills reference non-existent agents `qa-agent` (13×), `devops-agent` (4×), `developer-agent`, and commands `verify-app`, `verify-startuptools`.

| Group | Skills | Duplicates |
|---|---|---|
| Language / framework (17) | api-design, backend-patterns, frontend-patterns, coding-standards, cpp-coding-standards, java-coding-standards, golang-patterns, python-patterns, perl-patterns, postgres-patterns, jpa-patterns, springboot-patterns, django-patterns, laravel-patterns, swift-actor-persistence, swift-concurrency-6-2, swift-protocol-di-testing | `api-design` ≈ agent api-designer; overlap `rules/<lang>` |
| Testing / TDD / verification (14) | cpp-testing, golang-testing, python-testing, perl-testing, e2e-testing, tdd-workflow, django-tdd, laravel-tdd, springboot-tdd, django/laravel/springboot-verification, verification-loop, eval-harness | `verification-loop` ≈ **/verify**; `tdd-workflow` ≈ command tdd + agent tdd-guide; `e2e-testing` ≈ command e2e + agent e2e-runner; `eval-harness` ≈ command eval |
| Security (6) | security-review, security-scan, django/laravel/springboot-security, perl-security | `security-review` **name-clashes with bundled /security-review**; `security-scan` duplicates it |
| Infra / deploy (4) | docker-patterns, deployment-patterns, database-migrations, clickhouse-io | — |
| ClaudeOS process / meta (12) | autonomous-loops, continuous-learning, continuous-learning-v2, strategic-compact, search-first, iterative-retrieval, skill-stocktake, configure-ecc, project-guidelines-example, performance-review, requirements-extractor, plankton-code-quality | `autonomous-loops` ≈ **/loop**; `strategic-compact` ≈ auto-compact; `continuous-learning(-v2)` ≈ auto memory; `skill-stocktake` ≈ **/skill-doctor** |
| LLM engineering (4) | cost-aware-llm-pipeline, regex-vs-llm-structured-text, content-hash-cache-pattern, foundation-models-on-device | off-scope |
| Business / content (9) | article-writing, content-engine, investor-materials, investor-outreach, market-research, frontend-slides, liquid-glass-design, nutrient-document-processing, videodb | off-scope |

Classification: KEEP 3 (performance-review, requirements-extractor, verification-loop — after adding frontmatter); REPLACE_WITH_NATIVE 5 (security-review, security-scan, verification-loop-as-/verify, autonomous-loops, skill-stocktake); DEPRECATE 4 (strategic-compact, continuous-learning, continuous-learning-v2, tdd-workflow); REMOVE_CANDIDATE 54.

### 12.7 `.claude/claudeos/commands/` (46) — grouped; duplicates of bundled skills/native

Plain markdown, no frontmatter/`$ARGUMENTS`/`allowed-tools`; **26 are 3-line stubs**; only 9 exceed 20 lines.

| Group | Commands | Native duplicate → Class |
|---|---|---|
| Review / verify / quality (12) | code-review, verify, eval, tdd, test-coverage, e2e, refactor-clean, build-fix, go-build, go-review, go-test, python-review | **`code-review.md` vs /code-review → REPLACE_WITH_NATIVE**; **`verify.md` (3 l) vs /verify → REPLACE_WITH_NATIVE**; `refactor-clean` vs /simplify → REPLACE_WITH_NATIVE; `build-fix`/`go-build` vs /debug → REPLACE_WITH_NATIVE; **`tdd.md`** vs skill tdd-workflow/agent tdd-guide → DEPRECATE (keep one); **`eval.md`** (3 l) vs skill eval-harness/outcome-grader → DEPRECATE; test-coverage, e2e, go-review, go-test, python-review (3 l) → REMOVE_CANDIDATE |
| Planning / multi-agent (7) | plan, orchestrate, multi-plan, multi-execute, multi-backend, multi-frontend, multi-workflow | **`plan.md`** vs Plan agent / plan mode → REPLACE_WITH_NATIVE; orchestrate/multi-* (3 l) vs `/workflows` + `.claude/workflows/*.js` → REPLACE_WITH_NATIVE |
| Learning / instincts (8) | learn, learn-eval, instinct-status, instinct-export, instinct-import, evolve, prune, skill-create | 3–9 l stubs ≈ auto memory / reasoning-bank → DEPRECATE (skill-create → REMOVE_CANDIDATE) |
| Session / time / cron (8) | checkpoint, sessions, session-info, work-time-set, work-time-reset, cron-register, cron-list, cron-cancel | **`session-info.md`** vs /context /cost /status → REPLACE_WITH_NATIVE (mentions "Windows 側の state/sessions"); **`cron-*`/`work-time-*`** call `/home/kensan/.claudeos/cron-cli.sh` which **does not exist** → MODERNIZE or REPLACE_WITH_NATIVE (CronCreate / /loop / /schedule); checkpoint, sessions (3 l) → REMOVE_CANDIDATE |
| Docs / project ops (9) | update-docs, update-codemaps, changelog, extract-tasks, team-onboarding, measure, mcp-memory-check, setup-pm, pm2 | `team-onboarding` (239 l) references non-existent `.claude/CLAUDE.md`, `.claude/claudeos/CLAUDE.md` → MODERNIZE; measure/changelog/extract-tasks/mcp-memory-check reference real `scripts/*` → KEEP; update-docs, update-codemaps, setup-pm, pm2 (3 l) → REMOVE_CANDIDATE |
| Git / design (2) | safe-auto-merge, design-sync-check | KEEP (delete the `.claude/commands/` duplicates) |

No `goal*/model*/effort*/simplify/debug/doctor/memory/compact` commands exist — those are already left to native.

### 12.8 Other `.claude/claudeos` subdirs

| Dir / file | Purpose | Staleness | Class |
|---|---|---|---|
| `system/{boot,orchestrator,loop-guard,token-budget,project-switch}.md` | Kernel narrative (boot order, 5 h timer, loop guard, token zones, Mon–Sat rota) | `project-switch.md` hardcodes ServiceGrid/ITSM rota; `orchestrator.md` duplicates agent | MODERNIZE (loop-guard, token-budget) / DEPRECATE (project-switch, boot) |
| `system/agent-teams-light-mode.md` | 12-role Agent Teams "light" variant | "v7.4 / v8.0-β", `v8-delta.md` missing | DEPRECATE |
| `system/message-bus-design.md` | Draft design (Issue #127) | PowerShell TODO | DEPRECATE |
| `system/role-contracts.md`, `progressive-disclosure.md` | Orchestrator contracts; lazy skill loading | duplicates native skill lazy-loading | REPLACE_WITH_NATIVE |
| `system/stable-rubric.json` | STABLE scoring used by outcome-grader | — | KEEP |
| `loops/{monitor,build,verify,improve,architecture-check}-loop.md` | Phase checklists | — | KEEP (merge into one doc) |
| `loops/maintenance-loop.md` | Post-release loop | cites `Start-MaintenanceMode.ps1` | MODERNIZE |
| `loops/frontier-test-loop.md`, `frontier/benchmark-tasks.md` | Monthly "is this harness still needed" benchmark via `/loop frontier-test` | live-only | EXPERIMENTAL |
| `data/audit-log.jsonl` (59 KB, 141 records, untracked) | audit trail | no secret-like patterns | KEEP |
| `data/reasoning-bank.json`, `data/trust-score.json` | learned hints; trust L3 (score 0.9, 22/22 CI, 103 sessions) | **tracked runtime state** (committed) | MODERNIZE (untrack) |
| `snapshots/` (21 state snapshots + evacuation, 808 KB, gitignored) | pre-compact snapshots | no pruning | KEEP (add pruning) |
| `docs/INSTALLATION.md`, `OPERATIONS.md` | "everything-claude-code" plugin install/ops | wrong install path | DEPRECATE |
| `docs/dreaming-setup.md` | Managed Agents Dreaming | research preview, v8.3 | EXPERIMENTAL |
| `docs/webhook-setup.md` | webhook env setup | Windows section | MODERNIZE |
| `docs/auto-merge-protocol.md`, `trust-ledger.md` | merge gates, trust levels | — | KEEP |
| `docs/agent-communication-protocol.md`, `parallel-cron-experiment.md` | Issue-based message bus; 2-session experiment | messaging now native (`/list-agents`, SendMessage) | REPLACE_WITH_NATIVE |
| `docs/deploy-runbook-template.md`, `webui-full-verification-checklist.md` | templates | checklist has Windows rows | KEEP |
| `hooks/hooks.json` + 5 md "prompt hooks" (agent-risk-check, capture-result, memory-mcp-evacuation, onboarding-refresh-on-stable, usage-history-recorder) | declarative specs where md = prompt | **not wired**; not Claude Code hook schema; `agent-risk-check` would fit a native `type: agent` PreToolUse hook | MODERNIZE (agent-risk-check, memory-mcp-evacuation) / REMOVE_CANDIDATE (rest) |
| `ci/` (3), `executive/` (3), `management/` (3), `worktree/` (2), `roles/` (2), `goals/` (7) | policies; goals are `/goal` presets (hotfix, mvp, pr-babysit, production-release, refactoring, safe-auto-merge, security-emergency) | ci-manager duplicates agent; roles duplicate agents | KEEP goals/; DEPRECATE ci/executive/management/roles/worktree (fold into CLAUDE.md) |
| `evolution/` (3), `examples/` (7), `dashboards/` (3 of 4), `rules/**` (14), `contexts/` (3), `tests/` (3), `scripts/lib/` (2) | 3–12-line placeholder stubs; tests assert `true`; examples mention Supabase/Stripe; plugin.json says "30体" | ≤ 300 B each | REMOVE_CANDIDATE (rules → migrate real content to `.claude/rules/*.md` with `paths:`) |
| `review-configs/` | CodeRabbit yaml, Codex toml, README | Windows pwsh notes | MODERNIZE |
| `workflows/*.yml` (2) | GitHub Actions (blocked-events-update, trust-score-update) | not in `.github/workflows/` | KEEP as templates |
| `.claude-plugin/plugin.json`, `marketplace.json` (×2) | "everything-claude-code" manifest, author "OpenAI Codex x …", `hooksPath: ./hooks` (non-Claude format), 30 agents claimed | marketplace path `./everything-claude-code` missing | DEPRECATE |
| `mcp-configs/mcp-servers.json` | github/supabase/vercel/railway | irrelevant to stack | REMOVE_CANDIDATE |
| `scripts/tools/run-ultrareview.js` | wrapper for `claude ultrareview --json` | bundled `/code-review ultra` | REPLACE_WITH_NATIVE |
| `scripts/project-sync.sh` | GitHub Projects V2 status | live-only | KEEP |
| `README.md` | "read-only deploy of templates", "30 体", `New-CronSchedule.ps1` | Windows | MODERNIZE |

Stale-token counts inside `.claude/claudeos` (excl. data/snapshots): `TeamCreate` 5/1 file; `Managed Agents` 10/5; `Dreaming` 45/7; Windows/`.ps1`/PowerShell 16/12; `v8.x` 22/19; `v9.x` 18/6; `claude agents`/"Agent View" 50/45; `Opus 4.8`, `Neon`, `teammateDefaultModel`, `/schedule`, `Fable`: 0.

### 12.9 `.claude`-specific defects

| # | Finding |
|---|---|
| C-1 | `settings.json` → `teammate-idle-gate.js`, `task-created-gate.js`, `task-completed-gate.js` missing from `.claude/claudeos/scripts/hooks/` (template-only) |
| C-2 | `commands/{cron-register,cron-cancel,work-time-reset}.md` → `/home/kensan/.claudeos/cron-cli.sh` does not exist |
| C-3 | `commands/team-onboarding.md` → `.claude/CLAUDE.md`, `.claude/claudeos/CLAUDE.md` do not exist; `commands/extract-tasks.md` → `docs/meeting-2026-05-11.md` missing |
| C-4 | `session-end.js` fallback `.claude/claudeos/scripts/tools/measure-kpi.js` missing (only repo-root and template copies) |
| C-5 | 62 skills reference agents `qa-agent`/`devops-agent`/`developer-agent` and commands `verify-app`/`verify-startuptools` that do not exist in claudeos |
| C-6 | `system/agent-teams-light-mode.md` → `v8-delta.md` missing; `hooks/agent-risk-check.md` → deleted `safety-check` |
| C-7 | `verify-goal-set.js` → `START_PROMPT.md` absent in this repo (only under `Claude/templates/claude/`) |
| C-8 | `.claude-plugin/marketplace.json` → `./everything-claude-code` missing |
| C-9 | Dead: `evaluate-session.js`, `suggest-compact.js`; unwired: `agent-transcript.js`, `auto-format.js`, `pre-commit-gate.js`, `hooks/hooks.json` + 5 md hooks, `tests/` (assert true), `.agents/skills/` |
| C-10 | `claudeos/README.md` + `docs/SOURCE_OF_TRUTH.md` declare `.claude/claudeos/` a read-only deploy of templates, but 64 files differ, 16 live-only, 11 template-only; `.claude/workflows` (3 vs 3) and `.claude/skills` (3 vs 1) are disjoint from templates |
| C-11 | Root `CLAUDE.md` never mentions `.claude/claudeos`, hooks, state.json or the 43 agents; its §9 10-role team matches neither the 43 agents nor the 12-role `agent-teams-light-mode.md` |
| C-12 | `usage-tracker.js` documents matcher `Agent\|Skill`; settings use `Agent` only |
| C-13 | `settings.local.json` enables `byterover`/`brv` not in `.mcp.json`; `.mcp.json` `memory` not enabled |
| C-14 | `.agents/skills/verify-startuptools` describes the **Codex** repo inside the Claude repo |
| C-15 | `.claude/commands/*` byte-identical to `claudeos/commands/*` (double registration) |
| C-16 | `data/reasoning-bank.json`, `data/trust-score.json` committed runtime state (and currently modified) while state.json/snapshots are gitignored |
| C-17 | 41/43 agent files carry a UTF-8 BOM before frontmatter (live and template) |

### 12.10 Classification counts (sub-inventory A, ~222 items)

| Class | Hooks (19) | Workflows (3) | .claude cmd/skills/.agents (8) | Agents (43) | Skills (66) | Commands (46) | Other groups (≈35) | Total |
|---|---|---|---|---|---|---|---|---|
| KEEP | 6 | 3 | 2 | 6 | 3 | 6 | 9 | **35** |
| MODERNIZE | 6 | 0 | 0 | 7 | 0 | 8 | 9 | **30** |
| REPLACE_WITH_NATIVE | 0 | 0 | 1 | 4 | 5 | 14 | 4 | **28** |
| DEPRECATE | 2 | 0 | 2 | 13 | 4 | 9 | 8 | **38** |
| REMOVE_CANDIDATE | 2 | 0 | 3 | 13 | 54 | 9 | 5 | **86** |
| EXPERIMENTAL | 3 | 0 | 0 | 0 | 0 | 0 | 2 | **5** |

Load-bearing core of the in-session kernel: `session-start.js`, `session-end.js` (+ quality-gate-check, tdd-coverage-scan, notify-stable, webhook-notifier), `pre-compact.js`, `audit-trail.js`, `system/stable-rubric.json`, `goals/*.md`, the 3 dynamic workflows, and 6 well-formed agents (cto, outcome-grader, audit-agent, cmdb-agent, security-reviewer, ci-manager).

## 13. Sub-inventory B — `Claude/templates/**` and distribution mechanism

### 13.1 Structure (319 files)

| Top-level tree | Files | Purpose |
|---|---|---|
| `Claude/templates/claude/` | 40 | Per-project bootstrap: `CLAUDE.md`, `settings.json`, `START_PROMPT.md`, `TEAM_START_PROMPT.md`, `.coderabbit.yaml`, legacy v9.0 numbered docs (`claude/claudeos/**`, 24), `instructions/00-goal-system.md`, `skills/verify-app`, `workflows/*.js` (3), `BackUp/` (4, git-ignored) |
| `Claude/templates/claudeos/` | 277 | The "ClaudeOS kernel" bundle copied wholesale to `<project>/.claude/claudeos/`: agents 43, commands 45, skills 66, scripts 31 (hooks 26, lib 2, tools 2, setup-package-manager.js), rules 14, docs 12, goals 7, examples 7, loops 6, dashboards 4, hooks 4, system 7, ci/evolution/executive/contexts 3 each, management 3, review-configs 3, roles 2, worktree 2, tests 3, workflows (2 GitHub Actions yml), mcp-configs 1, `.claude-plugin` 2, README |
| `Claude/templates/linux/` | 2 | `cron-launcher.sh`, `report-and-mail.py` deployed to `~/.claudeos/` |

### 13.2 Distribution mechanism (all plain `cp`/`copyFileSync`; no symlink/rsync, no manifest/hash, no template version stamp)

| Path | Trigger | Source → Destination | Semantics |
|---|---|---|---|
| `lib/template-sync.sh::template_sync__apply` | Every launch (L/S/cron/T) | `claude/START_PROMPT.md` → `<proj>/.claude/START_PROMPT.md` | always overwrite |
| | | `claude/TEAM_START_PROMPT.md`, `claude/CLAUDE.md` → `<proj>/.claude/` | copy-if-missing (CLAUDE.md skipped if template < 100 B; note destination is `.claude/CLAUDE.md` while `init` uses `<proj>/CLAUDE.md`) |
| | | `claude/.coderabbit.yaml` → `<proj>/.coderabbit.yaml` | overwrite on diff with `.bak-<stamp>` |
| | | `claudeos/commands/{safe-auto-merge,design-sync-check}.md` → `<proj>/.claude/commands/` | copy-if-missing (2 of 45) |
| | | `claude/skills/verify-app/SKILL.md` → `<proj>/.claude/skills/verify-app/` | copy-if-missing |
| | | runs `scripts/setup/sanitize-settings.js` on `<proj>/.claude/settings.json` | in-place mutate every launch |
| `lib/project-autoinit.sh` | opt-in | `claude/CLAUDE.md` → `<newdir>/CLAUDE.md` after `git init` | copy-if-missing + initial commit |
| `scripts/setup/init-claudeos-project.js` | manual `--target/--project/--all --apply` | whole `claudeos/` → `.claude/claudeos/`; **plus duplicate copies** agents→`.claude/agents/`, commands→`.claude/commands/`, skills→`.claude/skills/`, hooks→`.claude/hooks/`, `claude/workflows`→`.claude/workflows/`, `claudeos/scripts/tools`→`scripts/tools/`, `claude/CLAUDE.md`→`CLAUDE.md`, `scripts/templates/claude-mcp.json`→`.mcp.json`, `scripts/templates/claude-statusline.py`→`.claude/statusline.py`, `claude/settings.json`→`.claude/settings.json` (deep-merge, `.bak-init`), `claude/claudeos/templates/state.json`→`state.json` (**source missing**) | copy-if-missing recursive; dry-run on empty dir = 444 files |
| `scripts/setup/migrate-agent-teams.js` | manual, existing ClaudeOS projects only | 5 files (agent-teams-tracker, session-start, session-end, audit-trail, measure-kpi) + settings PostToolUse patch | overwrite on byte diff, `.bak-agent-teams`, `--rollback` |
| `lib/deploy-launcher.sh` | `bin/deploy-launcher.sh` | `linux/{cron-launcher.sh,report-and-mail.py}` → `~/.claudeos/` | overwrite on diff with backup |
| `scripts/refresh-onboarding.js`, `bin/onboard-project.sh` | — | not template distributors (ONBOARDING.md regeneration; supervisor-manifest.json write) | — |

Never distributed by any path: `claude/claudeos/**` (24 v9.0 docs), `claude/instructions/`, `claude/CLAUDE-back.md`, `claude/BackUp/`.

**Live `.claude/claudeos` (306 files) vs `Claude/templates/claudeos` (277) — `diff -rq`:** 202 identical; **64 differ** (README, 9 agents, ci-manager, 7 commands, 3 dashboards, 4 docs, 2 evolution, 6 examples, executive/architecture-board, goals/mvp-release, hooks/hooks.json, 5 loops, 2 management, mcp-servers.json, 13 hook scripts, 6 system files, tests/run-all.js); **11 only in templates** (`scripts/hooks/{heartbeat-daemon,heartbeat-watchdog,heartbeat-writer,notification-gate,stop-failure-gate,task-completed-gate,task-created-gate,teammate-idle-gate}.js`, `scripts/tools/measure-kpi.js`, `docs/{data-architecture-protocol,jit-approval-protocol}.md`); **16 only in live** (`data/`, `frontier/`, `snapshots/`, `commands/team-onboarding.md`, 5 `hooks/*.md`, `loops/frontier-test-loop.md`, `marketplace.json`, `scripts/hooks/verify-goal-set.js`, `scripts/project-sync.sh`, `system/{agent-teams-light-mode,message-bus-design,progressive-disclosure}.md`). `templates/claudeos/README.md` still says sync is done with Windows `xcopy`.

### 13.3 Per-area classification

| Area | Count | Purpose | Native equivalent | Class | Reason |
|---|---|---|---|---|---|
| `claude/CLAUDE.md` | 1 | Project CTO policy (699 lines) | `CLAUDE.md` + `.claude/rules` | MODERNIZE | Identical to control-plane root; > 200 lines; uncommitted edits pending |
| `claude/CLAUDE-back.md` | 1 | Old v9.0 CLAUDE.md (890 lines) | — | REMOVE_CANDIDATE | Untracked; Opus 4.8/Haiku 4.5, `/loop`, Neon, ultracode |
| `claude/claudeos/CLAUDE.md` + `claudeos/examples/CLAUDE.md` | 2 | Third CLAUDE.md variant (685 lines) | — | DEPRECATE | Byte-identical pair; both **carry Neon**; only `examples/` copy is distributed |
| `claude/claudeos/{core,execution,quality,governance,ai-review,templates}/*` | 23 | Numbered v9.0 kernel docs | `.claude/rules/*.md` | DEPRECATE | Not distributed; Agent View/ultracode/`TemplateSyncManager.ps1` vocabulary |
| `claude/instructions/00-goal-system.md` | 1 | `/goal` doc | `/goal` | REMOVE_CANDIDATE | Byte-duplicate of `core/00-goal-system.md`; no consumer |
| `claude/settings.json` | 1 | Project settings + 15 hooks | `.claude/settings.json` | MODERNIZE | `permissions.defaultMode:"auto"` ignored since 2.1.257; `requiredMinimumVersion:"2.1.224"` stale; `fallbackModel:["opus","sonnet","haiku"]` pre-Fable; `MultiEdit` matcher; `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` |
| `claude/START_PROMPT.md` | 1 | Session kick-off (`/goal` + loop) | `/goal` | KEEP | Overwritten each launch; says local PostgreSQL, not Neon |
| `claude/TEAM_START_PROMPT.md` | 1 | CTO hub prompt (SendMessage to backend/frontend/qa) | `SendMessage`/`--name` | KEEP | Uses native messaging |
| `claude/.coderabbit.yaml` | 1 | CodeRabbit config | — | KEEP | |
| `claude/BackUp/*` | 4 | START_PROMPT snapshots (one future-dated `_20270718`) | — | REMOVE_CANDIDATE | Git-ignored; 2 carry Neon |
| `claude/skills/verify-app/SKILL.md` (+README) | 2 | Verification-loop skill | `.claude/skills/<n>/SKILL.md` | KEEP | Only skill with proper frontmatter |
| `claude/workflows/*.js` | 3 | classify-and-act, generate-and-filter, loop-until-done | `.claude/workflows/*.js` | KEEP | Use official `export const meta` + `agent()/parallel()/pipeline()/phase()` |
| `claudeos/agents/*.md` | 43 | Subagent definitions (name/description/tools; no `model:`) | `.claude/agents/*.md` | MODERNIZE | 41/43 have UTF-8 BOM; 9 diverge from live; copied to two locations in targets |
| `claudeos/commands/*.md` | 45 | Slash commands | skills / bundled skills | MODERNIZE | Only 6 have frontmatter; ~10 reference scripts absent from distributed tree; 7 diverge from live |
| `claudeos/skills/*/SKILL.md` | 66 | ECC-derived language/framework skill library | `.claude/skills` | MODERNIZE | **0/66 have YAML frontmatter** → not discoverable; mostly generic (django/laravel/springboot/swift/perl…) |
| `claudeos/scripts/hooks/*.js` (+package.json) | 26 | Hook implementations | settings.json hooks | KEEP / MODERNIZE | All 15 referenced by template settings exist; `agent-teams-tracker.js` keeps a live `TeamCreate` branch; 13 diverge from live; 8 exist only in templates |
| `claudeos/scripts/{lib,tools}`, `setup-package-manager.js` | 5 | utils, package-manager, measure-kpi, run-ultrareview | — | KEEP | |
| `claudeos/hooks/{hooks.json,README…}` | 4 | Descriptive registry (`{name, description}`) | settings.json `hooks` / plugin `hooks/hooks.json` | DEPRECATE | Not the Claude Code hook schema; copied to `.claude/hooks/` where nothing reads it |
| `claudeos/rules/**` | 14 | Coding rules (common + 5 languages) | `.claude/rules/*.md` with `paths:` | REPLACE_WITH_NATIVE | No `paths:` frontmatter; installed under `.claude/claudeos/rules/` so never auto-loaded |
| `claudeos/docs/*.md` | 12 | Protocols (auto-merge, JIT approval, data-architecture, webhooks, dreaming, INSTALLATION, OPERATIONS) | — | MODERNIZE | `data-architecture-protocol.md` **carries Neon**; INSTALLATION/OPERATIONS describe "everything-claude-code"; PowerShell snippets in webhook-setup / agent-communication-protocol |
| `claudeos/workflows/*.yml` | 2 | GitHub Actions (blocked-events, trust-score) | `.github/workflows` | MODERNIZE | Misplaced under `workflows/` (name collides with dynamic workflows) |
| `claude/claudeos/execution/github-actions-ci-manager.yml` | 1 | CI workflow | `.github/workflows` | DEPRECATE | Not distributed |
| `claudeos/goals/*.md` | 7 | `/goal` presets (mvp-release, hotfix, pr-babysit…) | `/goal` | KEEP | Consumed by `libexec/goal-extract.sh` |
| `claudeos/roles/*.md` | 2 | cto-build / qa-monitor prompts | subagents | KEEP | Consumed by parallel-cron |
| `claudeos/dashboards/*.md` | 4 | `{{placeholder}}` templates | — | KEEP | Consumed by `render.js` |
| `claudeos/{loops,system,ci,executive,evolution,management,worktree,contexts}` | 31 | Kernel prose (Monitor/Build/Verify/Improve, orchestrator, token budget, loop guard) | CLAUDE.md / rules | MODERNIZE | 57 template files still say "Agent View"; `maintenance-loop.md` cites `Start-MaintenanceMode.ps1` |
| `claudeos/review-configs/*` | 3 | CodeRabbit yaml + Codex toml + README | — | MODERNIZE | Windows PowerShell install text; "v8.2.5+" |
| `claudeos/mcp-configs/mcp-servers.json` | 1 | MCP catalogue (env placeholders only) | `.mcp.json` / `claude mcp add` | EXPERIMENTAL | `init` installs `scripts/templates/claude-mcp.json` instead |
| `claudeos/.claude-plugin/{plugin.json,marketplace.json}` | 2 | Plugin manifest "everything-claude-code" | Claude Code plugins | EXPERIMENTAL | `marketplace.json` points to non-existent `./everything-claude-code`; author "OpenAI Codex x …" |
| `claudeos/tests/*` | 3 | Hook unit tests; `run-all.js` is one `console.log` | — | REMOVE_CANDIDATE | Stub |
| `claudeos/examples/*-CLAUDE.md` (6 non-Neon) | 6 | Stack-specific CLAUDE.md samples | — | KEEP | All 6 diverge from live copies |
| `claudeos/README.md` | 1 | "Template Source" README | — | MODERNIZE | Windows `xcopy` sync instruction |
| `linux/cron-launcher.sh` | 1 | Cron/headless launcher | local cron + `claude -p` | KEEP / MODERNIZE | Header "v3.4.2"; see §9 |
| `linux/report-and-mail.py` | 1 | HTML session report via SMTP | — | KEEP | Header "v3.2.0" |

### 13.4 Obsolete / stale terms in templates (grep; file counts)

| Term | Files | Where | Assessment |
|---|---|---|---|
| `TeamCreate` / `TeamDelete` | 2 | `claudeos/scripts/hooks/agent-teams-tracker.js` (live branch "for old CLI"), `claude/claudeos/core/04-agent-teams.md` | tool removed v2.1.178 |
| `teammateDefaultModel` | 0 | — | clean |
| "Agent View" / `claude agents` | 57 / 8 | core/00–04, ai-cto.md, session-start.js, CLAUDE-back | v9.0 monitoring vocabulary |
| `Opus 4.8` / `Haiku 4.5` | 1 | `claude/CLAUDE-back.md` | legacy only |
| `Fable` | 0 | — | no template references the current default model |
| `Neon` | 6 | `claudeos/docs/data-architecture-protocol.md`, `claudeos/examples/CLAUDE.md`, `claude/claudeos/CLAUDE.md`, `claude/CLAUDE-back.md`, `claude/BackUp/START_PROMPT20260718.md`, `claude/BackUp/START_PROMPT-BackUp20260822.md` | distributed ones: `examples/CLAUDE.md`, `data-architecture-protocol.md` |
| `defaultMode` | 1 | `claude/settings.json` (`"auto"`) | ignored in project scope since 2.1.257 |
| `bypassPermissions` | 1 | `linux/cron-launcher.sh` comment only | OK |
| `/loop` | 3 | CLAUDE-back (real usage), role-contracts (path), loop-until-done.js (name) | |
| `.ps1` / `powershell` / `Windows` | 5 / 4 / 8 | reasoning-bank.js, review-configs/README+toml, maintenance-loop.md, agent-communication-protocol.md, 04-agent-teams.md, webhook-setup.md, claudeos/README.md, session-info.md | Windows residue |
| `v8.` / `v9.0` | 21 / 27 | session-start.js (8× v9.0), 04-agent-teams.md, 05-operations.md, review-configs | version stamps vs `4.0.0-linux` |
| `v2.1.1xx` | 7 | CLAUDE-back, session-start.js (v2.1.152/154), cron-launcher (v2.1.186/196), agent-teams-tracker (v2.1.178), notify-stable (v2.1.110) | historical notes |
| `requiredMinimumVersion` | 1 | `claude/settings.json` = `2.1.224` | stale floor |
| `ultracode` | 3 | 04-agent-teams.md (11), CLAUDE-back, 05-operations.md | |
| `/goal` | 34 | valid native usage | |
| `EnterWorktree`, `C:\\`, `Sonnet 4.6` | 0 | — | clean |

### 13.5 Template `settings.json` hooks (`Claude/templates/claude/settings.json`; the only settings template)

| Event | Matcher | Script | Exists in templates? |
|---|---|---|---|
| PreToolUse | `Bash` (`if: Bash(git *)`, `continueOnBlock`) | `pre-commit-gate.js` | yes |
| PreCompact | `*` | `pre-compact.js` | yes |
| SessionStart | `startup\|resume\|clear` | `session-start.js` | yes |
| SessionStart | `*` | `heartbeat-writer.js` | yes (templates only; absent from live tree) |
| Notification | `idle_prompt`, `permission_prompt` | `notification-gate.js` | yes (templates only) |
| Stop | `*` | `session-end.js` | yes |
| StopFailure | `*` | `stop-failure-gate.js` | yes (templates only) |
| PostToolUse | `Agent\|Skill` / `Agent` / `Edit\|Write\|MultiEdit` / `SendMessage` / `Bash\|mcp__.*` | `usage-tracker.js`, `agent-transcript.js`, `agent-teams-tracker.js`, `auto-format.js`, `audit-trail.js` | yes |
| TeammateIdle / TaskCreated / TaskCompleted | `*` | `teammate-idle-gate.js`, `task-created-gate.js`, `task-completed-gate.js` | yes (templates only; **missing in live `.claude/claudeos/scripts/hooks/` although live `.claude/settings.json` references them**) |

Obsolete/questionable keys: `permissions.defaultMode: "auto"` (ignored in project settings ≥ 2.1.257), `requiredMinimumVersion: "2.1.224"`, `fallbackModel: ["opus","sonnet","haiku"]` (aliases, no Fable), `env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS: "1"`, `MultiEdit` matcher (verify tool still exists). Live control-plane `.claude/settings.json` lacks PreToolUse/Notification/StopFailure/usage-tracker/agent-transcript/auto-format entries and `requiredMinimumVersion`, but adds `verify-goal-set.js` and `SessionStart` matcher `*` variants.

### 13.6 Template-specific defects

| # | Finding | Files |
|---|---|---|
| T-1 | `STATE_TEMPLATE = Claude/templates/claude/claudeos/templates/state.json` does not exist; `init --dry-run` prints `SOURCE MISSING`; no project gets a seeded `state.json` from init | `scripts/setup/init-claudeos-project.js:52` |
| T-2 | ~10 distributed commands reference scripts that exist only in the control-plane repo (`scripts/dashboards/render-codemap.js` ×5, `scripts/release/generate-changelog.js` ×4, `scripts/setup/install-mcp.js` ×2, `.claude/claudeos/data/audit-log.js`, `migrate-agent-teams.js`, `lint-and-fix.js`, `render.js`, `serve-dashboard.js`, `reasoning-bank.js`, `./state.js`) — only `scripts/tools/` is distributed | `claudeos/commands/{update-codemaps,changelog,measure,…}.md` |
| T-3 | Live `.claude/settings.json` registers `teammate-idle-gate.js` / `task-created-gate.js` / `task-completed-gate.js`, present only in templates → hooks fail in the control plane itself | |
| T-4 | 64 divergent + 11/16 one-sided files between live `.claude/claudeos` and templates; no enforced direction of truth; README says Windows `xcopy` | |
| T-5 | Duplicates: `claude/instructions/00-goal-system.md` == `core/00-goal-system.md`; `claude/claudeos/CLAUDE.md` == `claudeos/examples/CLAUDE.md`; agents/commands/skills copied to two locations per target | |
| T-6 | Three CLAUDE.md variants (699 / 685-Neon / 890-v9.0) and two install locations (`<proj>/.claude/CLAUDE.md` via template-sync vs `<proj>/CLAUDE.md` via init/autoinit) | |
| T-7 | `claudeos/hooks/hooks.json` is not the Claude Code hook schema; copied to `.claude/hooks/`, unread | |
| T-8 | 0/66 skills have frontmatter (`claude/skills/README.md` itself says it is required) | `claudeos/skills/**` |
| T-9 | `claudeos/rules/**` lack `paths:` and land outside `.claude/rules/` | |
| T-10 | `.claude-plugin/marketplace.json` source `./everything-claude-code` does not exist; plugin name ≠ dir; author "OpenAI Codex x …" | |
| T-11 | Version stamps: cron-launcher "v3.4.2", report-and-mail "v3.2.0", coderabbit "v8.2.5+", 25 files "v9.0", 21 files "v8.x" | |
| T-12 | Windows residue in 8 files (xcopy, `Start-MaintenanceMode.ps1`, `Start-ClaudeCode.ps1`, `TemplateSyncManager.ps1`, "Windows 側の state/sessions", pwsh install) | |
| T-13 | Contradictory docs: README claims `.claude/claudeos` is a synced runtime copy; INSTALLATION/OPERATIONS describe plugin install while the real path is `init-claudeos-project.js`; `04-agent-teams.md` still requires `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` and Agent View | |
| T-14 | Orphaned: `claude/claudeos/**` (24), `claude/instructions/` (1), `CLAUDE-back.md`, `BackUp/` (4); `github-actions-ci-manager.yml` and `claudeos/workflows/*.yml` need manual move to `.github/workflows` | 32 files |
| T-15 | 41 agent files start with a UTF-8 BOM | `claudeos/agents/*` |
| T-16 | Uncommitted edits to `claude/CLAUDE.md`, `claude/START_PROMPT.md`; `CLAUDE-back.md` untracked | |
| T-17 | `claudeos/tests/run-all.js` is a one-line stub | |

No literal secrets found in templates (`mcp-servers.json` uses `${ENV}` placeholders only).

### 13.7 Totals (templates, by file, 319)

| Class | Files | Contributors |
|---|---|---|
| KEEP | ~60 | START_PROMPT, TEAM_START_PROMPT, .coderabbit.yaml, verify-app skill (2), workflows js (3), hook scripts (26), scripts/lib+tools (5), goals (7), roles (2), dashboards (4), examples non-Neon (6), linux (2) |
| MODERNIZE | ~185 | CLAUDE.md, settings.json, agents (43), commands (45), skills (66), docs (12), kernel prose (~28), review-configs (3), GitHub yml (2), README |
| REPLACE_WITH_NATIVE | 14 | `claudeos/rules/**` |
| DEPRECATE | ~30 | `claude/claudeos/**` docs (23) + its CLAUDE.md + examples/CLAUDE.md (Neon), hooks registry (4), github-actions-ci-manager.yml |
| REMOVE_CANDIDATE | 9 | CLAUDE-back.md, BackUp (4), instructions/00-goal-system.md, tests (3) |
| EXPERIMENTAL | 3 | `.claude-plugin/*` (2), `mcp-servers.json` |
