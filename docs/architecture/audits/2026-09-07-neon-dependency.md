# Neon / managed-Postgres dependency audit — Claude-StartUpTools-New-Linux (ClaudeOS)

Date: 2026-09-07  Mode: READ-ONLY (no repo files modified). Secrets masked throughout.
Repo: /home/kensan/Projects/Claude-StartUpTools-New-Linux  (branch main @ 76ba161, dirty working tree)
Target state: ClaudeOS v10 — PostgreSQL source of truth = Local PostgreSQL (`postgresql@16-main`, active);
Cloudflare optional and NOT coupled to local PG (no Worker → local PG). History preserved, annotated only.

Host tool versions (verified): psql 18.4, pg_dump 17.10, pg_restore 16.14, server 16 (bins in /usr/lib/postgresql/{16,17,18}).
WARNING: pg_dump 17 archives are NOT guaranteed readable by pg_restore 16. All backup/restore scripts must pin
`PG_BIN=/usr/lib/postgresql/16/bin` (the mirai-web-cad-mvp restore-drill unit already does this).

---

## 0. Summary counts

| Classification | Count (hit groups) |
|---|---|
| ACTIVE_DEPENDENCY | 1 (host-level, outside repo: ~/.claude.json Neon MCP servers) |
| ACTIVE_DOCUMENTATION | 2 (docs/architecture/CloudflareNeonGitHub自動化仕様.md, AGENTS.md central-policy block) |
| TEMPLATE | 5 (templates/claude/CLAUDE.md, START_PROMPT.md, claudeos/docs/data-architecture-protocol.md, claudeos/examples/CLAUDE.md, claude/claudeos/CLAUDE.md) |
| POLICY | 3 (CLAUDE.md, Claude/CLAUDE.md, GITHUB_POLICY.md repo copy) |
| HISTORICAL | 2 (CHANGELOG.md:160, Claude/templates/claude/CLAUDE-back.md §8.6) |
| UNUSED / generic (Keep) | 9 (postgres-patterns skill ×2, database-migrations skill ×2, database-reviewer ×2, quality/12, reasoning-bank.js ×2, examples/*-api-CLAUDE.md, config backups, .gitignore) |
| REMOVE_CANDIDATE | 3 (Claude/CLAUDE-back.md, Claude/templates/claude/CLAUDE-back.md [untracked backups], Claude/templates/claude/claudeos/CLAUDE.md [unmapped stale copy]) |
| CENTRAL_POLICY_CONFLICT | 12 statements in 2 central files (report-only) |

No hits for: `DATABASE_URL`, `neondb` (in repo), `mcp__neon` (except the spec doc), `serverless postgres`, `managed postgres`, `.env.example` (only as policy text in CLAUDE.md §5).
No in-repo PostgreSQL backup/restore/migration executable assets exist (all "backup" hits are config-file backups).

---

## 1. Review of the UNCOMMITTED diff (`git diff`)

Files: CLAUDE.md, Claude/CLAUDE.md, Claude/templates/claude/CLAUDE.md (three byte-identical substitution diffs, 12 lines each),
Claude/templates/claude/START_PROMPT.md (FULL REWRITE, not a substitution), AGENTS.md (+central policy block),
.claude/claudeos/data/reasoning-bank.json + trust-score.json (runtime data, unrelated — should not ride in this change).

### 1.1 Wrong / awkward results (each occurs in all 3 CLAUDE.md copies unless noted)

| # | Line (CLAUDE.md) | Result of replace | Problem | Required action |
|---|---|---|---|---|
| D1 | 310 `## 13. ローカルPostgreSQL PostgreSQL運用方針` | duplicated word | "PostgreSQL PostgreSQL" | Retitle `## 13. ローカルPostgreSQL運用方針` AND rewrite body (see D5) |
| D2 | 312 `ローカルPostgreSQL PostgreSQLを業務データの正本として扱う。` | duplicated word | same | rewrite |
| D3 | 526 `Cloudflare（Pages／Workers）とローカルPostgreSQL PostgreSQLを本番基盤とする` | duplicated word + ARCHITECTURE CONFLICT | Cloudflare Workers/Pages cannot reach a local PG; §21 now prescribes a coupled stack the v10 target forbids | Redesign §21 Phase 2: backend runs on Linux host (systemd); Cloudflare optional (Pages static / Access / Tunnel / DNS); explicit "Workers → local PG direct connection is prohibited" |
| D4 | 668 same sentence in §25 統合/goal | duplicated word + same conflict | | same as D3 |
| D5 | 528 `対象account、project、environment、domain、ローカルPostgreSQL branchまたはdatabase` | "ローカルPostgreSQL branch" | No branch concept locally | `対象host、cluster、database、roleおよびenvironment` |
| D6 | 158 `ローカルPostgreSQL developmentまたはpreview branch上でのmigration検証` | "preview branch" | No branch concept | `<app>_dev / <app>_preview_<n> データベース上でのmigration検証（TEMPLATE clone or pg_restore）` |
| D7 | 316–324 §13 body UNCHANGED: `project、branch、database、schemaおよびrole`, `connection、pooling`, `developmentまたはpreview branchでmigrationとrollbackを先に検証する` | Neon concepts survived because they don't contain the word "Neon" | Must be rewritten (cluster/database/role/schema; pooling = PgBouncer or app pool; env DBs) |
| D8 | 84 §5 `previewとproductionの資源、URL、DB branch、secretおよび権限を分離する` | untouched "DB branch" | | `DB（database／role）` |
| D9 | 72 §5 table `ローカルPostgreSQL | PostgreSQLデータベースの正本` | OK wording, but now CONTRADICTS `Claude/templates/claudeos/docs/data-architecture-protocol.md` ("Linux に正の DB データを置かない", rule 1/8) which was not touched | Rewrite the protocol doc; it is distributed by init to every new project |
| D10 | 101/138/193/615 `Cloudflare、ローカルPostgreSQL、CI/CD…` | grammatically fine | 138 "read-only確認" needs a defined mechanism (read-only role / psql) — Neon MCP gave this for free | Define `<app>_ro` role + psql/MCP(local) read path |
| D11 | 645 `全MCPを形式的に呼ばず、GitHub、Cloudflare、ローカルPostgreSQL、監視…専用機能を漏れなく選定` | implies a "ローカルPostgreSQL MCP/専用機能" exists | None is configured in the repo; the only postgres MCP servers (user-scope ~/.claude.json) point at neon.tech and time out | Decide: local postgres MCP with ro role, or psql-only; then word it |
| D12 | §12 (287–308) Cloudflare運用方針 untouched | | Needs an added rule: Cloudflare must not be coupled to local PG (no Worker/Pages Functions/Hyperdrive bridge to host DB) | add |
| D13 | §17 Approval PR / §18 rollback | "destructive migration" fine | add local-specific human gates: `DROP DATABASE`, `DROP ROLE`, `pg_restore --clean` into prod, deleting backups | add |

### 1.2 START_PROMPT.md rewrite (Claude/templates/claude/START_PROMPT.md) — overwritten into EVERY project on EVERY launch

template-sync.sh: `START_PROMPT.md : 毎回上書き` → `<project>/.claude/START_PROMPT.md` (29 downstream files today; 15 still contain "Neon").
Blast radius is the highest of any file in this audit. Findings:

| # | New text | Problem |
|---|---|---|
| S1 | `ローカルPostgreSQLをPostgreSQL/Migration/Seed/検証DBとして扱います` | awkward ("ローカルPostgreSQLをPostgreSQL…として") — say `ローカルPostgreSQL（postgresql@16-main）をDB正本／Migration／Seed／検証DBとして扱います` |
| S2 | `Cloudflare PreviewでUI、API、認証、DB接続確認済み` (完了条件) | Cloudflare Preview cannot connect to local PG → unattainable / encourages coupling. Preview API must run on host (systemd `<app>-preview@<pr>`) or preview = frontend with mocks |
| S3 | `Merge後は承認済みCI/CD経路のみからCloudflareへDeployし、検証済みMigrationを適用` | GitHub-hosted CI cannot reach local PG. Migration must be applied from the host (deploy script / self-hosted runner), with pre-migration pg_dump snapshot |
| S4 | `DevOps：GitHub Actions、Cloudflare、監視、復旧` | no owner for PostgreSQL backup/restore-drill/disk monitoring — add to Database or DevOps role |
| S5 | `ローカルPostgreSQL Migration/Seedを空DBへ再実行可能` | acceptable; specify `createdb <app>_ci && migrate && seed` |
| S6 | Whole-file rewrite | The diff also drops the Plugins/Skills/MCP section, 評価・企画・優先順位, 停止・完了・報告, and introduces "OpenDesign" as a core system — these are unrelated scope changes bundled with the Neon migration. Recommend splitting into its own PR (policy says protect unrelated changes / no blanket rewrites). Previous version is preserved under `Claude/templates/claude/BackUp/START_PROMPT-BackUp20260822.md` (contains no Neon). |

### 1.3 AGENTS.md (+11 lines)
Adds a `<!-- central-github-policy -->` block pointing to the CENTRAL `CloudflareNeonGitHub自動化仕様.md` (Neon-era). Keep the GitHub part; annotate the Neon reference as "DB運用は本リポジトリの PostgreSQLデータ運用仕様.md（Local PostgreSQL）に従う". Note AGENTS.md is Codex-facing, out of ClaudeOS scope but in-repo.

### 1.4 Copies NOT touched by the diff (inconsistency)
- `Claude/templates/claudeos/examples/CLAUDE.md` and `Claude/templates/claude/claudeos/CLAUDE.md` still say Neon (13 hits each) and are stale (lack §27). CHANGELOG calls these "計 5 コピー" — the diff updated only 3 of 5.
- `Claude/templates/claudeos/docs/data-architecture-protocol.md` (Neon = sole DB, "Linux に正の DB データを置かない") — unchanged, now inverted by §5.
- `docs/architecture/CloudflareNeonGitHub自動化仕様.md` (untracked, byte-identical to central) — unchanged.

---

## 2. Hit inventory with classification

Legend for "Distributed": TS = lib/template-sync.sh (on every launch via tmux-runner.sh / team-runner.sh);
INIT = scripts/setup/init-claudeos-project.js (copy-if-missing, new projects / `--all --apply`).
Mapping (verified):
- TS: `Claude/templates/claude/START_PROMPT.md` → `<proj>/.claude/START_PROMPT.md` (ALWAYS overwrite)
- TS: `Claude/templates/claude/CLAUDE.md` → `<proj>/.claude/CLAUDE.md` (if missing); TEAM_START_PROMPT.md (if missing);
  `Claude/templates/claudeos/commands/{safe-auto-merge,design-sync-check}.md`; `Claude/templates/claude/skills/verify-app/SKILL.md`
- INIT: `Claude/templates/claudeos/**` → `<proj>/.claude/claudeos/` (incl. docs/data-architecture-protocol.md, examples/CLAUDE.md, skills, agents);
  `Claude/templates/claude/CLAUDE.md` → `<proj>/CLAUDE.md`; `Claude/templates/claude/claudeos/templates/state.json` → `<proj>/state.json`
- NOT mapped anywhere: `Claude/templates/claude/claudeos/CLAUDE.md`, `Claude/CLAUDE.md`, `Claude/templates/claude/CLAUDE-back.md`, `Claude/CLAUDE-back.md`

Downstream state (registered roots /home/kensan/Projects/Mirai-Project, Mirai-DX-Project):
CLAUDE.md with "Neon": 12/15 + 18/25; .claude/CLAUDE.md: 2/4 + 15/23; .claude/START_PROMPT.md: 2/3 + 13/26;
already "ローカルPostgreSQL": 1 (Mirai-DX-Project/Civil-Open-Data-Intelligence-Platform/CLAUDE.md).

| # | File:line | Quote (short) | Class | Action | Distributed |
|---|---|---|---|---|---|
| H1 | CLAUDE.md:72,101,138,158,193,310,312,526,528,615,645,668 (+§5:84, §13:316–324 untouched) | see §1.1 | POLICY | Redesign §5/§12/§13/§17/§21/§25 for Local PG (not rename) | project root only |
| H2 | Claude/CLAUDE.md (same 12 lines) | identical | POLICY ("正本" copy per CHANGELOG) | keep in sync with H1; consider making it a symlink/pointer to avoid 5-way drift | no code path |
| H3 | Claude/templates/claude/CLAUDE.md (same 12 lines) | identical | TEMPLATE | same redesign as H1 | TS (.claude/CLAUDE.md if missing), INIT (CLAUDE.md) |
| H4 | Claude/templates/claude/START_PROMPT.md (new: 4× ローカルPostgreSQL; old HEAD: `GitHub、Cloudflare、Neon…` + `Neon PostgreSQLを本番基盤`) | see §1.2 | TEMPLATE | Redesign wording S1–S5; split unrelated rewrite S6 | TS ALWAYS overwrite → 29 projects |
| H5 | Claude/templates/claudeos/docs/data-architecture-protocol.md:1,11,20,31,36,49 | `Neon (PostgreSQL) 唯一の DB 正本`, `Linux に正の DB データを置かない`, `Neon を標準 DB とする` | TEMPLATE | Rewrite as "Data Architecture Protocol v2 — Local PostgreSQL 正本 / Cloudflare optional"; keep v1 text as Deprecated appendix | INIT → .claude/claudeos/docs (0 downstream copies today; repo's own .claude/claudeos/docs lacks it) |
| H6 | Claude/templates/claudeos/examples/CLAUDE.md:72,101,138,158,193,310,312,526,528,615,645,668 | Neon (stale, no §27) | TEMPLATE | Sync with H3 or reduce to a pointer; currently drifting | INIT → .claude/claudeos/examples (5 downstream copies, older, no Neon) |
| H7 | Claude/templates/claude/claudeos/CLAUDE.md (same 12) | Neon (stale, no §27) | UNUSED → REMOVE_CANDIDATE | not referenced by TS/INIT (only its `templates/state.json` sibling is) | none |
| H8 | Claude/templates/claude/CLAUDE-back.md:551–582 `<!-- claudeos:cf-neon-guide v1 -->` §8.6 | Neon MCP tool matrix: `create_branch`, `run_sql`, `prepare_database_migration`, `complete_database_migration`, `compare_database_schema`, `list_slow_queries`, `explain_sql_statement`, `describe_project`; human-gate table | HISTORICAL (untracked backup) | Do not commit; keep as reference for the local-PG tool matrix redesign (§3 C4); move to `BackUp/` or delete from tree | none |
| H9 | Claude/CLAUDE-back.md (v9.0 starter, no Neon) | — | UNUSED (untracked) | REMOVE_CANDIDATE from tree | none |
| H10 | docs/architecture/CloudflareNeonGitHub自動化仕様.md:1,11,14,72–93,195,226 (untracked, == central) | `## 3. Neon 利用仕様`, `NEON_API_KEY`, `mcp__neon__*`, `Neonプロジェクト / branch / DB / role / connection string` | ACTIVE_DOCUMENTATION | Split per §6 below; keep original with "Deprecated / Migrated to Local PostgreSQL" banner; do NOT commit unannotated | none |
| H11 | GITHUB_POLICY.md:120 (repo copy, untracked, differs from central: no `webui` branch) | `全体フローとCloudflare / Neon運用: docs/architecture/CloudflareNeonGitHub自動化仕様.md` | POLICY | Keep; re-point §9 詳細仕様 to the split docs | none |
| H12 | AGENTS.md:31 (uncommitted) | `詳細: …/CloudflareNeonGitHub自動化仕様.md` | ACTIVE_DOCUMENTATION | Keep GitHub reference; annotate DB part | none |
| H13 | CHANGELOG.md:160 | `本番基盤は Cloudflare (Pages/Workers) + Neon PostgreSQL` | HISTORICAL | Keep verbatim; add NEW v10 entry "Migrated to Local PostgreSQL" | none |
| H14 | ~/.claude.json (OUTSIDE repo): 10 user-scope mcpServers `postgres-itsm-management`, `postgres-construction-enterprise-os`, `postgres-ccabp-production`, `postgres-ceop-production`, `postgres-open-bim-information-platform`, `postgres-civil-material-photo-logger`, `postgres-civil-technology-ip-intelligence-platform`, `postgres-mirai-sales-pipeline`, `postgres-civil-4d-ai-planner`, `postgres-civilpdf-dx-production` | each arg is a `postgresql://…@ep-…neon.tech/…` string WITH EMBEDDED PASSWORD (masked) | ACTIVE_DEPENDENCY | Migrate: re-point to `postgresql://<ro-role>@localhost/<db>` via PGPASSFILE/env, or remove; ROTATE the Neon passwords (plaintext in a user config file). All 10 timed out at this session's start (CONNECT_TIMEOUT) — consistent with Neon decommission | n/a (host) |
| H15 | .claude/claudeos/scripts/hooks/reasoning-bank.js:104, Claude/templates/claudeos/scripts/hooks/reasoning-bank.js:73 | regex `postgres|mysql` classifier | UNUSED (generic) | Keep | INIT |
| H16 | .claude/claudeos/skills/postgres-patterns/SKILL.md, Claude/templates/claudeos/skills/postgres-patterns/SKILL.md | generic PG tuning skill | UNUSED (generic) | Keep; optionally add "local ops" section (pg_stat_statements, EXPLAIN) | INIT |
| H17 | .claude/claudeos/skills/database-migrations/SKILL.md, templates copy; agents/database-reviewer.md ×2; Claude/templates/claude/claudeos/quality/12-database-testing.md (`Commit/Rollback`, `Backup/Restore`) | generic | UNUSED (generic) | Keep; add pre-migration snapshot + restore-drill steps | INIT |
| H18 | .claude/claudeos/examples/{laravel,rust,go,django}-*-CLAUDE.md, templates copies | "PostgreSQL を使う" | UNUSED (generic) | Keep | INIT |
| H19 | config/config.json.template:85–87 `backupConfig.backupDir: config/backups`, :188 `backupBeforeApply`; lib/deploy-launcher.sh, bin/deploy-launcher.sh, bin/autonomy.sh, lib/supervisor-manifest.sh:192 | config/launcher FILE backups (not DB) | UNUSED (for DB) | Keep | n/a |
| H20 | .gitignore:34,43,51,55,109,148 | `*.backup`, `config/backups/*.json`, START_PROMPT-backup | UNUSED | Keep | n/a |
| H21 | docs/agents-skills-inventory-2026Q2.md:160 | postgres-patterns listed | UNUSED | Keep | none |
| H22 | scripts/setup/migrate-agent-teams.js (25× "migration" = hook distribution) | unrelated meaning | UNUSED | Keep | n/a |
| H23 | Outside repo, informational: /home/kensan/Projects/Mirai-DX-Project/Civil-Weather-Water-Decision/deploy/scripts/db-backup.sh:183 `Use DATABASE_URL_DIRECT with a direct/unpooled Neon URL` | legacy Neon wording in an otherwise local-PG backup script | HISTORICAL (other project) | note for that project | n/a |

---

## 3. Neon-specific CONCEPTS requiring local-PostgreSQL redesign (not rename)

| # | Neon concept (where) | Why rename fails | Local PostgreSQL design |
|---|---|---|---|
| C1 | Neon project + branch per environment (CLAUDE.md §13 "project、branch", spec §3.2 "環境別分離", data-architecture-protocol) | no projects/branches in a single cluster | One cluster `postgresql@16-main`; per-env DATABASES `<app>_dev`, `<app>_staging`, `<app>_prod` (+ `<app>_ci`, `<app>_recovery`); per-env ROLES (`<app>_app`, `<app>_migrator`, `<app>_ro`); naming convention documented; `pg_hba.conf` local-only (no listen on public interface) |
| C2 | Preview branches per PR (§8.3:158, §5:84 "DB branch", START_PROMPT S2) | ephemeral copy-on-write branches don't exist | Ephemeral DB `<app>_pr<N>` via `CREATE DATABASE … TEMPLATE <app>_dev` (needs no active connections) or `pg_restore` of an anonymized dev snapshot; lifecycle script `scripts/db/preview-db.sh create|drop <pr>`; drop on PR close; cap count + disk quota; preview backend runs on host, NOT on Cloudflare |
| C3 | Connection pooling (`-pooler` endpoints, §13 "pooling") | no managed pooler | PgBouncer on host (transaction mode) or app-side pool; rule retained: pg_dump/migrations use DIRECT connection (port 5432), not pooler |
| C4 | Neon MCP tools (CLAUDE-back §8.6: create_branch/run_sql/prepare_database_migration/complete_database_migration/compare_database_schema/list_slow_queries/explain_sql_statement/describe_project/get_connection_string; spec §3.1 `mcp__neon__*`; CLAUDE.md:645) | tools vanish with Neon | psql + app migration tool (prisma/drizzle/sqitch/…) run from host; schema diff = `pg_dump --schema-only` diff (or migra); slow queries = `pg_stat_statements`; explain = `EXPLAIN (ANALYZE, BUFFERS)`; optional local postgres MCP bound to `<app>_ro` role for AI read-only investigation. Rebuild the "CTO autonomous vs human gate" matrix for these |
| C5 | `NEON_API_KEY` env (spec §1, §3.1, §6) | no API | none; DB credentials only in `~/.config/<app>/db.env` (0600) consumed by systemd `EnvironmentFile=`; NOT in Cloudflare Secrets; GitHub Secrets not required for DB |
| C6 | Deployment flow: Cloudflare Pages/Workers + Neon as "本番基盤" (§21:526, §25:668, START_PROMPT S2/S3, CHANGELOG) | Workers cannot reach localhost PG; GitHub-hosted CI cannot run migrations | Backend on host via systemd (`<app>.service`), migrations applied by host-side deploy step (pull-deploy or self-hosted runner) with pre-migration `pg_dump`; Cloudflare optional for Pages (static), Access, Tunnel, DNS; explicit prohibition on Worker/Pages Functions/Hyperdrive → local PG |
| C7 | Backup assumptions: cloud-managed, PITR/history retention implicit (§13 "backupおよびrestore" without mechanism; §25 "バックアップ・復元試験、RPO/RTO") | nothing manages backups locally | systemd pattern (§4): nightly `pg_dump -Fc` + sha256 + retention-days; hourly freshness check; daily/weekly restore drill into `<app>_recovery`; pre-backup disk-space check; `OnFailure=` alert unit; off-host encrypted export; decide PITR (WAL archiving / pgBackRest) or document RPO = 24h; pin PG_BIN 16 |
| C8 | Durability/HA (implicit multi-AZ) | single host | Document single-host risk, RPO/RTO targets, disk monitoring, off-host copy; approval-PR item for any change to retention/export |
| C9 | Human-gate list (CLAUDE-back §8.6: Neon project create/delete, dev-branch delete, main-branch apply) | objects differ | Human gate = `DROP DATABASE`/`DROP ROLE` on any env except `_pr<N>`/`_ci`, prod `pg_restore --clean`, deleting backup files, changing pg_hba/listen_addresses, retention reduction |
| C10 | Read-only investigation via MCP (§8.1:138, spec §3.3 rule 1) | MCP gone | `<app>_ro` role, `psql -c` read-only session (`SET default_transaction_read_only=on`), or local MCP with ro DSN; forbid prod writes outside PR-declared scope (already §13) |
| C11 | "DB branch" wording in §5/§13/§21 | | replace with database/role/environment vocabulary |
| C12 | Tool version matrix (new) | | pg_dump/pg_restore must be same major as server (16) — psql 18 / pg_dump 17 on PATH are traps |

---

## 4. Reusable local backup/restore assets

In-repo: NONE for PostgreSQL. (`config/config.json.template backupConfig`, `deploy-launcher.sh` backups are config-file backups; `.gitignore` has generic *.backup patterns; `quality/12-database-testing.md` lists "Backup/Restore" as a checklist item only; `deploy-runbook-template.md` exists but has no DB section.)

Host pattern A — Civil-Weather-Water-Decision (`cwwd-db-backup*`, /etc/systemd/system, secrets masked):
- `cwwd-db-backup.service` (oneshot, User=kensan): `ExecStartPre=test -f ~/.config/cwwd/db-backup.env`, `ExecStartPre=test -w /var/backups/cwwd/postgres`,
  `ExecStartPre=deploy/scripts/disk-space-check.sh --path / --path /var/backups/cwwd/postgres --root-min-free-mib 4096 --data-min-free-mib 10240 --min-free-percent 15 --min-inode-free-percent 10 --dump-size-dir …`,
  `ExecStart=deploy/scripts/db-backup.sh --env-file ~/.config/cwwd/db-backup.env --output-dir /var/backups/cwwd/postgres --retention-days 14`, `TimeoutStartSec=30min`, `UMask=0077`, `ReadWritePaths=`, `OnFailure=cwwd-db-backup-failure@%n.service`, full systemd hardening.
- `cwwd-db-backup.timer`: `OnCalendar=*-*-* 02:10:00`, `RandomizedDelaySec=30min`, `Persistent=true`.
- `cwwd-db-backup-check.service/.timer`: hourly (`*:17:00`) freshness `--warn-age-hours 24 --max-age-hours 26`.
- `cwwd-db-backup-restore-drill.service/.timer`: daily 04:20 `db-backup-restore-drill.sh --backup-dir … --warn-age-hours 26 --max-age-hours 30`, `UnsetEnvironment=DATABASE_URL DATABASE_URL_DIRECT PGPASSWORD …` (drill cannot touch prod).
- `cwwd-db-backup-export(.check)`: encrypted off-host export + passphrase-file check (26/28h).
- `cwwd-db-backup-failure@.service`: `ops-alert.sh --title "… backup failure: %i" --severity alert`.
- db-backup.sh: custom-format `pg_dump`, `.dump` + `.dump.sha256`, prunes `find -mtime +DAYS` after success, env allow-list (`DATABASE_URL|DATABASE_URL_DIRECT|BACKUP_DIR|BACKUP_RETENTION_DAYS|PG_DUMP_BIN`), auto-detects `/usr/lib/postgresql/*/bin/pg_dump`.

Host pattern B — Mirai-Web-CAD MVP (`mirai-web-cad-mvp-restore-drill.service`):
- `Requires=postgresql.service`, `After=…mvp-backup.service`, `EnvironmentFile=~/.config/mirai-web-cad/mvp-backup.env`, `Environment=PG_BIN=/usr/lib/postgresql/16/bin`, `BACKUP_DIR=/var/backups/mirai-web-cad/mvp-postgres`, `EXPECTED_RESTORE_DATABASE=mirai_web_cad_mvp_recovery`, `ExecStart=bash scripts/restore-drill-local.sh`, `ReadOnlyPaths=<backup dir>`, `ProtectHome=read-only`.
- timer: `OnCalendar=Sun *-*-* 04:30:00 Asia/Tokyo`, `RandomizedDelaySec=20min`, `Persistent=true`.
- script: restores `latest.dump` into isolated recovery DB, verifies `pg_restore --list`, compares manifest counts/versions, clears recovery data.

Recommended ClaudeOS v10 deliverable: a generic template set under `Claude/templates/claudeos/scripts/db/` + `Claude/templates/systemd/` —
`db-backup.sh`, `db-backup-check.sh`, `db-restore-drill.sh`, `disk-space-check.sh`, `preview-db.sh`, and unit templates
`<app>-db-backup.{service,timer}`, `<app>-db-backup-check.{service,timer}`, `<app>-db-restore-drill.{service,timer}`, `<app>-db-backup-failure@.service`
parameterised by app name, with `PG_BIN` pinned to 16, retention default 14d, drill into `<app>_recovery`, plus a bats test for dry-run.

---

## 5. CENTRAL_POLICY_CONFLICT (files NOT to be edited; report only)

Source A: /home/kensan/Projects/Deep-Seek-Harness-Project/GITHUB_POLICY.md
Source B: /home/kensan/Projects/Deep-Seek-Harness-Project/docs/architecture/CloudflareNeonGitHub自動化仕様.md (byte-identical to the repo's untracked copy)

| # | File:line | Statement | Conflict with v10 |
|---|---|---|---|
| CP1 | A:126 | `全体フローとCloudflare / Neon運用: docs/architecture/CloudflareNeonGitHub自動化仕様.md` | names Neon as the DB operating spec |
| CP2 | B:1 | `# Cloudflare / Neon / GitHub自動化 運用仕様` | title binds Neon into the shared basis |
| CP3 | B:11 | `Neon（PostgreSQL）のプロジェクト・DB・スキーマ運用` (共通基盤) | declares Neon a common basis for all Workspaces |
| CP4 | B:14 | `…環境変数（CLOUDFLARE_API_TOKEN / CLOUDFLARE_ACCOUNT_ID / NEON_API_KEY）を利用する` | requires NEON_API_KEY on host |
| CP5 | B:72–74 | `## 3. Neon 利用仕様` / `### 3.1 設定` | whole section is Neon-only |
| CP6 | B:76 | `Neon MCP（ホスト型 https://mcp.neon.tech/mcp）はCodex / Claude Codeに設定済み…WebUI MCP構成にも登録済み` | asserts Neon MCP is configured (in ~/.claude.json only Neon *connection strings* exist, no Neon MCP server; they time out) |
| CP7 | B:77 | `WebUIセッションでは mcp__neon__* として利用できる` | tool namespace gone |
| CP8 | B:78–79 | `認証は NEON_API_KEY…` / `systemdサービスの場合は ~/.config/deepseek-harness-web.env に NEON_API_KEY を含め…` | secret provisioning for a removed service |
| CP9 | B:83–85 | `Neonプロジェクト / branch / DB / role / connection stringの一覧・取得・作成`, `環境別（dev / staging / prod）の分離確認` | project/branch model |
| CP10 | B:88–93 | §3.3 rules incl. `5. 複数project / branchがある場合は、操作対象を明示` | branch model; rules 1–4,6 are reusable if generalized |
| CP11 | B:195 | `| Neon MCP（Codex / Claude Code） | 設定済み | NEON_API_KEY はホスト環境変数 |` | status table |
| CP12 | B:226 | `5. Cloudflare / Neonは既存設定をそのまま利用し、2章・3章のルーティングとHuman Gateを運用に適用する` | migration step mandates keeping Neon |

Precedence note: B §4.4 / A §3 say the central policy overrides Workspace CLAUDE.md for GitHub operation only ("Workspaceの記述はGitHub運用を左右しない"); they do not claim precedence over DB architecture, so a Workspace-level Local-PostgreSQL spec does not violate the central priority chain — but the reference chain (AGENTS.md → central B) will keep pointing agents at Neon until the central owner annotates B. Recommend raising an issue/PR in Deep-Seek-Harness-Project rather than editing.

---

## 6. Proposed split of docs/architecture/CloudflareNeonGitHub自動化仕様.md

Current sections: 1 目的と適用範囲 / 2 Cloudflare (2.1 MCP 2本, 2.4 WebUI, 2.2 ルーティング, 2.3 ルール) / 3 Neon (3.1 設定, 3.2 用途, 3.3 ルール) / 4 GitHub (4.1 フロー, 4.2 ロール, 4.3 Controller契約, 4.4 優先順位) / 5 品質ゲート (5.1 CI, 5.2 STABLE) / 6 現状 / 7 Workspace適用 / 8 人間承認 / 9 移行手順.

| New doc | Moves in | Must be rewritten |
|---|---|---|
| **GitHub開発運用仕様.md** | §1 (GitHub bullet), §4.1–4.4 whole, §5.1–5.2, §6 rows GitHub Ruleset / branch protection / allow_auto_merge / delete_branch_on_merge / GitHub Controller, §7, §8 "Release / タグ付け", §9 steps 1–4 | Replace DeepSeek-Harness terms ("DeepSeek Harness → Orchestrator", `bin/github-controller.sh`, `./start.sh github`) with ClaudeOS equivalents; §5.1 job names `quality (20)/(24)/compatibility` → this repo's `CI / linux-validate` and `Security Scan / secrets-scan`; align with CLAUDE.md §15–§17 (quality-gated auto-merge, Approval PR); drop `webui` branch (central-only) |
| **PostgreSQLデータ運用仕様.md** | §1 line 11, §3 (all, as "Deprecated — Neon era" appendix), §6 Neon MCP row, §8 "Secretの追加・変更・削除" (DB part), §9 step 5, §3.3 rules 1–4,6 generalized | NEW body: cluster/DB/role naming & env separation (C1), preview DB lifecycle (C2), pooling (C3), tooling & AI access matrix (C4, C10), secrets location (C5), migration policy (additive/expand-contract, pre-migration snapshot, host-side apply — C6), backup/restore-drill/retention/disk monitoring/off-host export/PITR decision/RPO-RTO (C7, C8), human gates (C9), version pinning PG_BIN 16 (C12), systemd unit templates (§4) |
| **Cloudflare公開基盤仕様.md** | §2.1–2.4 whole, §6 Cloudflare MCP row, §8 "Production deploy" + Secrets (CF part) | Add "Optional basis" framing; scope = Pages / Workers / Access / Tunnel / DNS; explicit rule "Workers・Pages Functions・Hyperdrive から Local PostgreSQL へ直接接続しない — データを持つバックエンドはホスト側 systemd で稼働し、必要なら Tunnel+Access 経由で公開"; keep docs-MCP-first routing and read-back rules; align with CLAUDE.md §12 |
| **ClaudeOS運用仕様.md** (new) | §1 適用範囲 (Workspace wording), §7 Workspace適用, §4.4 priority as a reference | NEW: template distribution map (TS vs INIT, overwrite vs copy-if-missing), which of the 5 CLAUDE.md copies is canonical, launch paths (tmux/team/cron), state.json, docs/claude index, how projects opt into DB/Cloudflare specs |
| **AI開発ガバナンス仕様.md** (new) | §2.3 rules 1–8 and §3.3 rules generalized (参照即時 / 変更は対象明示 / 破壊的=Human Gate / read-back / fail closed / secrets never logged), §5.2 STABLE, §8 human-approval list | NEW: agent autonomy vs human-gate matrix (rebuild CLAUDE-back §8.6 table for GitHub/Cloudflare/PostgreSQL), secret handling, quality gates & Approval PR cross-refs (CLAUDE.md §16/§17), stop conditions, audit/evidence rules, cross-session messaging (§27) |
| **CloudflareNeonGitHub自動化仕様.md** (existing) | stays | Prepend banner: `状態: Deprecated 2026-09 — Neon運用は Local PostgreSQL へ移行済み。分割先: GitHub開発運用仕様.md / PostgreSQLデータ運用仕様.md / Cloudflare公開基盤仕様.md`; body untouched. Note it is currently UNTRACKED — do not commit the un-annotated version. |

Cross-file follow-ups: GITHUB_POLICY.md:120 and AGENTS.md:31 re-point "詳細" to the split docs; CHANGELOG gets a v10 entry; CLAUDE.md §13 becomes a short pointer + principles, with mechanics living in PostgreSQLデータ運用仕様.md; data-architecture-protocol.md rewritten to v2 (H5).

---

## 7. Security notes (no values shown)
- ~/.claude.json holds 10 Neon DSNs with embedded passwords in plaintext (user MCP config). Rotate/revoke the Neon roles even if the projects are decommissioned; remove the entries or re-point to localhost with `PGPASSFILE`.
- No secrets found inside the repository working tree or the untracked docs.
- .brv/config.json and .agents/skills are untracked — verify they contain no credentials before any commit (not part of this audit's term set).
