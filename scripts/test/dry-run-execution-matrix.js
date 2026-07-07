#!/usr/bin/env node
"use strict";

const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawnSync } = require("child_process");

const REPO_ROOT = path.resolve(__dirname, "..", "..");

function writeJson(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, JSON.stringify(value, null, 2) + "\n", "utf8");
}

function writeFile(file, content, mode) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, content, "utf8");
  if (mode) fs.chmodSync(file, mode);
}

function makeFixture() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "claudeos-dry-run-"));
  const home = path.join(root, "home");
  const projects = path.join(root, "Projects");
  const demo = path.join(projects, "Demo");
  const clean = path.join(projects, "Clean");
  const bin = path.join(root, "bin");
  const claudeosHome = path.join(home, ".claudeos");
  const configPath = path.join(root, "config.json");
  const statePath = path.join(root, "state.json");
  const crontabFile = path.join(root, "crontab.txt");
  const crontabStub = path.join(bin, "crontab");

  fs.mkdirSync(path.join(demo, ".git"), { recursive: true });
  fs.mkdirSync(path.join(clean, ".git"), { recursive: true });
  fs.mkdirSync(path.join(demo, ".claude", "claudeos", "scripts", "hooks"), { recursive: true });
  writeJson(path.join(demo, "package.json"), { name: "demo", version: "0.0.0" });
  writeJson(path.join(demo, ".claude", "settings.json"), { hooks: {}, env: {} });
  writeFile(path.join(demo, ".claude", "claudeos", "scripts", "hooks", "session-start.js"), "\n", 0o644);
  writeFile(path.join(demo, ".claude", "claudeos", "scripts", "hooks", "agent-teams-tracker.js"), "\n", 0o644);
  writeJson(path.join(demo, "state.json"), {
    project: { phase_mode: "development" },
    deploy: { ready: false },
    stable: { stable_achieved: false, consecutive_success: 0, target_n: 3 },
    goal: { title: "Dry-run fixture" },
    execution: { max_duration_minutes: 10 },
    completed_issues: ["#1"],
    blocked_issues: ["#2"],
    mcp: { enabled: [] },
    feature_flags: { ultrareview: { monthly_cap: 50, current_month: "2000-01", count: 0 } }
  });
  writeJson(path.join(clean, "state.json"), {
    project: { phase_mode: "development" },
    deploy: { ready: false },
    stable: { stable_achieved: false, consecutive_success: 0, target_n: 3 },
    goal: { title: "Clean dry-run fixture" },
    execution: { max_duration_minutes: 10 }
  });

  writeJson(configPath, {
    projects,
    projectsDir: projects,
    linuxBase: projects,
    localExcludes: [],
    cron: {
      defaultDurationMinutes: 1,
      maxDurationMinutes: 10,
      maxProjectsPerDay: 2
    },
    supervisor: {
      defaults: { sessionMinutes: 1 }
    },
    notifications: { soundEnabled: false },
    tools: { defaultTool: "claude", claude: { command: "claude", enabled: true } }
  });
  writeJson(statePath, {
    project: { phase_mode: "development" },
    deploy: { ready: false },
    maintenance: {
      sla_target_availability: "99.9",
      mttr_target_hours: 4,
      error_budget_remaining_pct: 100,
      incident_count_30d: 0
    }
  });
  writeFile(path.join(claudeosHome, "cron-launcher.sh"), "#!/usr/bin/env bash\nexit 0\n", 0o755);
  writeFile(crontabStub, `#!/usr/bin/env bash
set -euo pipefail
store=${JSON.stringify(crontabFile)}
case "\${1:-}" in
  -l) [[ -f "$store" ]] && cat "$store"; exit 0 ;;
  -) cat > "$store"; exit 0 ;;
  *) exit 2 ;;
esac
`, 0o755);

  return { root, home, projects, demo, clean, configPath, statePath, claudeosHome, crontabStub, bin };
}

function command(label, cmd, args, options = {}) {
  return { label, cmd, args, cwd: options.cwd || REPO_ROOT, env: options.env || {} };
}

function buildMatrix(fx) {
  return [
    command("deploy-prep dry-run", "bash", ["bin/deploy-prep.sh", "--env", "staging", "--dry-run"]),
    command("maintenance-mode dry-run", "bash", ["bin/maintenance-mode.sh", "--dry-run"]),
    command("incident-response dry-run", "bash", ["bin/incident-response.sh", "--priority", "P2", "--dry-run"]),
    command("weekly-devops read-only", "bash", ["bin/weekly-devops.sh"]),
    command("set-statusline dry-run", "bash", ["bin/set-statusline.sh", "--dry-run"]),
    command("start-dashboard dry-run", "bash", ["bin/start-dashboard.sh", "--dry-run", "--no-browser", "--port", "3737"]),
    command("dashboard-service register dry-run", "bash", ["bin/dashboard-service.sh", "--register", "--dry-run"]),
    command("dashboard-service unregister dry-run", "bash", ["bin/dashboard-service.sh", "--unregister", "--dry-run"]),
    command("deploy-launcher dry-run", "bash", ["bin/deploy-launcher.sh", "--dry-run"]),
    command("start-claude background dry-run", "bash", ["bin/start-claude.sh", "--project", "Clean", "--background", "--duration", "1", "--dry-run"]),
    command("autonomy start dry-run", "bash", ["bin/autonomy.sh", "start", "Clean", "--duration", "1", "--dry-run"]),
    command("autonomy start all dry-run", "bash", ["bin/autonomy.sh", "start", "--all", "--duration", "1", "--dry-run"]),
    command("cron list read-only", "bash", ["bin/cron-schedule.sh", "list"]),
    command("cron add dry-run", "bash", ["bin/cron-schedule.sh", "--dry-run", "add", "--project", "Demo", "--time", "09:00", "--dow", "1", "--duration", "1"]),
    command("cron remove dry-run", "bash", ["bin/cron-schedule.sh", "--dry-run", "remove", "--id", "dummy"]),
    command("cron remove-all dry-run", "bash", ["bin/cron-schedule.sh", "--dry-run", "remove-all"]),
    command("cron bulk-register default dry-run", "bash", ["bin/cron-schedule.sh", "bulk-register", "--duration", "1"]),
    command("init-claudeos-project dry-run", "node", ["scripts/setup/init-claudeos-project.js", "--target", fx.demo, "--dry-run"]),
    command("migrate-agent-teams dry-run", "node", ["scripts/setup/migrate-agent-teams.js", "--dry-run", "--config", fx.configPath]),
    command("install-mcp dry", "node", ["scripts/setup/install-mcp.js", "--project", fx.demo, "--dry"]),
    command("dashboard render dry", "node", ["scripts/dashboards/render.js", "--project", fx.demo, "--dry"]),
    command("codemap render dry", "node", [path.join(REPO_ROOT, "scripts/dashboards/render-codemap.js"), "--dry"], { cwd: fx.demo }),
    command("deploy runbook dry", "node", [path.join(REPO_ROOT, "scripts/release/generate-deploy-runbook.js"), "--dry", "--force", "--env", "staging"], { cwd: fx.demo }),
    command("changelog dry", "node", ["scripts/release/generate-changelog.js", "--dry", "--to", "HEAD", "--version", "dry-run"]),
    command("lint-and-fix dry", "node", [path.join(REPO_ROOT, "scripts/lint/lint-and-fix.js"), "--dry", "--no-fix"], { cwd: fx.demo }),
    command("launch-parallel-cron dry-run", "bash", ["scripts/tools/launch-parallel-cron.sh", "Demo", "--roles", "cto,qa", "--duration", "1", "--dry-run"]),
    command("run-ultrareview dry-run", "node", [path.join(REPO_ROOT, "scripts/tools/run-ultrareview.js"), "--dry-run", "--timeout", "1"], { cwd: fx.demo }),
    command("sync-github-projects dry-run", "node", [path.join(REPO_ROOT, "scripts/tools/sync-github-projects.js"), "--dry-run"], { cwd: fx.demo })
  ];
}

function main() {
  const fx = makeFixture();
  const baseEnv = {
    ...process.env,
    HOME: fx.home,
    PATH: `${fx.bin}${path.delimiter}${process.env.PATH || ""}`,
    AI_STARTUP_CONFIG_PATH: fx.configPath,
    CLAUDEOS_HOME: fx.claudeosHome,
    CCSU_STATE_FILE: fx.statePath,
    CCSU_CLAUDE_SETTINGS: path.join(fx.home, ".claude", "settings.json"),
    CCSU_CRONTAB_BIN: fx.crontabStub,
    CCSU_SKIP_DEPLOY_SYNC: "1",
    CCSU_SKIP_ENV_FILE: "1",
    CLAUDEOS_AUTO_DEPLOY: "0",
    CLAUDEOS_PLAIN_OUTPUT: "1",
    CCSU_DISABLE_TERMINAL_TAB: "1",
    CCSU_MAX_SESSION_MINUTES: "10",
    CCSU_MAX_SESSIONS: "10"
  };

  const failures = [];
  const matrix = buildMatrix(fx);
  for (const item of matrix) {
    const res = spawnSync(item.cmd, item.args, {
      cwd: item.cwd,
      env: { ...baseEnv, ...item.env },
      encoding: "utf8",
      timeout: 30000,
      maxBuffer: 1024 * 1024 * 16
    });
    if (res.status === 0) {
      console.log(`ok - ${item.label}`);
      continue;
    }
    failures.push({ item, res });
    console.log(`not ok - ${item.label}`);
  }

  if (failures.length > 0) {
    console.error(`\nDry-run validation failed: ${failures.length}/${matrix.length}`);
    for (const { item, res } of failures) {
      console.error(`\n[${item.label}]`);
      console.error(`cmd: ${item.cmd} ${item.args.join(" ")}`);
      console.error(`cwd: ${item.cwd}`);
      console.error(`status: ${res.status} signal: ${res.signal || ""}`);
      if (res.error) console.error(`error: ${res.error.message}`);
      if (res.stdout) console.error(`stdout:\n${res.stdout.trim()}`);
      if (res.stderr) console.error(`stderr:\n${res.stderr.trim()}`);
    }
    process.exit(1);
  }

  console.log(`\nDry-run validation passed: ${matrix.length}/${matrix.length}`);
  console.log(`fixture: ${fx.root}`);
}

if (require.main === module) main();
