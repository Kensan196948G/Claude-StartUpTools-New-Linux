#!/usr/bin/env node
// scripts/tools/measure-kpi.js
// KPI 自動収集スクリプト。gh CLI を使って GitHub から CI・Issue 情報を取得し、
// state.json.metrics を更新する。session-start / session-end hooks から呼ばれる。
// --background フラグで呼ばれた場合はエラーを無視して静かに終了する。

const { execSync } = require("child_process");
const fs = require("fs");
const path = require("path");

const STATE_FILE = path.join(process.cwd(), "state.json");
const SILENT = process.argv.includes("--background");

function readJson(file) {
  try { return JSON.parse(fs.readFileSync(file, "utf8")); } catch { return null; }
}

function writeJsonAtomic(file, data) {
  const tmp = `${file}.tmp.${process.pid}`;
  fs.writeFileSync(tmp, JSON.stringify(data, null, 2) + "\n", "utf8");
  fs.renameSync(tmp, file);
}

function tryExec(cmd) {
  try {
    return execSync(cmd, { encoding: "utf8", timeout: 15000 }).trim();
  } catch { return null; }
}

function pct(v) {
  return v === null || v === undefined ? "n/a" : `${Math.round(v * 100)}%`;
}

// GitHub Actions の直近 run から CI 成功率を計算する
function collectCISuccessRate() {
  const out = tryExec("gh run list --limit 10 --json status,conclusion 2>/dev/null");
  if (!out) return null;
  try {
    const runs = JSON.parse(out).filter(r => r.status === "completed");
    if (runs.length === 0) return null;
    const recent = runs.slice(0, 5);
    const success = recent.filter(r => r.conclusion === "success").length;
    return success / recent.length;
  } catch { return null; }
}

// linux-validate workflow の成功率をテスト成功率とみなす
function collectTestSuccessRate() {
  const out = tryExec(
    "gh run list --workflow linux-validate.yml --limit 5 --json status,conclusion 2>/dev/null"
  );
  if (!out) return null;
  try {
    const runs = JSON.parse(out).filter(r => r.status === "completed");
    if (runs.length === 0) return null;
    const success = runs.filter(r => r.conclusion === "success").length;
    return success / runs.length;
  } catch { return null; }
}

// open / closed Issues から完了率を計算する
function collectIssueCompletionRate() {
  const openOut  = tryExec("gh issue list --state open   --json number --limit 200 2>/dev/null");
  const closedOut = tryExec("gh issue list --state closed --json number --limit 200 2>/dev/null");
  try {
    const open   = openOut   ? JSON.parse(openOut).length   : null;
    const closed = closedOut ? JSON.parse(closedOut).length : null;
    if (open === null || closed === null) return null;
    const total = open + closed;
    return total > 0 ? closed / total : 1.0;
  } catch { return null; }
}

// セッション開始以降にマージされた PR を数える
function countSessionPRs(sessionStartIso) {
  if (!sessionStartIso) return null;
  const out = tryExec(
    "gh pr list --state merged --json mergedAt,number --limit 50 2>/dev/null"
  );
  if (!out) return null;
  try {
    const prs = JSON.parse(out);
    return prs.filter(pr => pr.mergedAt && pr.mergedAt >= sessionStartIso).length;
  } catch { return null; }
}

function main() {
  const state = readJson(STATE_FILE);
  if (!state) {
    if (!SILENT) console.log("[measure-kpi] state.json not found — skip");
    return;
  }

  state.metrics = state.metrics || {};

  const ci    = collectCISuccessRate();
  const test  = collectTestSuccessRate();
  const issue = collectIssueCompletionRate();
  const now   = new Date().toISOString();

  if (ci    !== null) state.metrics.ci_success_rate       = ci;
  if (test  !== null) state.metrics.test_success_rate     = test;
  if (issue !== null) state.metrics.issue_completion_rate = issue;
  state.metrics.last_measured_at = now;

  // セッション中 PR 数を session_prs_created へ反映
  const sessionStart = (state.execution || {}).current_session_start_at;
  const sessionPRs   = countSessionPRs(sessionStart);
  if (sessionPRs !== null) {
    state.metrics.session_prs_created   = sessionPRs;
    state.metrics.session_completed_tasks = sessionPRs; // PRs を完了タスクの代理指標とする
  }

  writeJsonAtomic(STATE_FILE, state);

  if (!SILENT) {
    console.log(
      `[measure-kpi] CI=${pct(ci)} test=${pct(test)} issues=${pct(issue)} PRs=${sessionPRs ?? "n/a"} @ ${now}`
    );
  }
}

main();
