#!/usr/bin/env node
'use strict';
/**
 * ship.js — ClaudeOS Ship Integration Engine CLI (bin/ship.sh から呼ばれる)
 *
 * サブコマンド:
 *   capability [--project DIR] [--json]                 Ship の前提条件を判定し ship/capability.json に保存
 *   run-start  --project DIR --repo O/R --mode SH1..SH5 [--intent TEXT] [--pr N]
 *   run-status [--id RUN] [--json]                       run 一覧 / 詳細
 *   run-transition --id RUN --to STATE [--reason R]     (ガード付き。HUMAN_APPROVED/MERGED は専用経路のみ)
 *   run-stop   --id RUN [--reason R]
 *   discover-pr --repo O/R --branch B                    既存 PR の再利用 (重複作成防止)
 *   quality    --repo O/R --project DIR --head SHA [--base SHA] [--pr N] [--profile P] [--publish]
 *   classify   --repo O/R --pr N                         変更リスク R0..R4
 *   gate       --repo O/R --pr N [--project DIR] [--publish] [--requirements met|partial|unknown] [--impact-doc F] [--rollback-doc F]
 *   approvals  --repo O/R --pr N [--json]                承認の有効性一覧
 *   merge      --repo O/R --pr N [--dry-run]             人間承認後の自動マージ (preflight 全条件を満たす場合のみ)
 *   merge-confirm --repo O/R --pr N
 *   monitor    [--once] [--interval SEC]                 open run の head 変化検出 (承認失効) とマージ結果確認
 *   actions    --repo O/R                                GitHub Actions 実行状況の集計
 *   audit-verify                                         監査ログの連鎖検証
 *
 * 承認 (approve / revoke / keygen / ship-attest) は bin/ship-approve.sh (scripts/ship/approve.js) が担う。
 * 終了コード: 0 正常 / 1 判定 NG・拒否 / 2 引数エラー / 3 外部依存エラー (BLOCKED)
 */

const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const store = require('./lib/store');
const sm = require('./lib/state-machine');
const policyLib = require('./lib/policy');
const risk = require('./lib/risk');
const quality = require('./lib/quality');
const gateLib = require('./lib/quality-gate');
const hg = require('./lib/human-gate');
const merge = require('./lib/merge');
const github = require('./lib/github');
const capability = require('./lib/capability');

const MODES = ['SH1', 'SH2', 'SH3', 'SH4', 'SH5', 'QC', 'HG'];

function parse(argv) {
  const o = { _: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a.startsWith('--')) {
      const k = a.slice(2);
      if (i + 1 < argv.length && !argv[i + 1].startsWith('--')) { o[k] = argv[++i]; } else o[k] = true;
    } else o._.push(a);
  }
  return o;
}
function out(obj, json) {
  if (json) process.stdout.write(JSON.stringify(obj) + '\n');
  else process.stdout.write(JSON.stringify(obj, null, 2) + '\n');
}
function need(o, ...keys) {
  for (const k of keys) if (o[k] === undefined || o[k] === true) { const e = new Error('MISSING --' + k); e.exit = 2; throw e; }
}
function trustedPolicy(o) {
  try { return policyLib.loadTrustedPolicy(o.project ? path.resolve(o.project) : policyLib.REPO_ROOT, o['base-ref'] || 'origin/main'); }
  catch (e) { const err = new Error(e.message); err.exit = 3; throw err; }
}

function today() { return new Date().toISOString().slice(0, 10); }
function dailyCount(kind) {
  const f = path.join(store.shipHome(), 'usage', `${today()}.json`);
  const d = store.readRecord(f) || {};
  return { file: f, data: d, n: Number(d[kind] || 0) };
}
function bumpDaily(kind, cap) {
  const c = dailyCount(kind);
  if (c.n >= cap) { const e = new Error(`DAILY_CAP_REACHED ${kind} ${c.n}/${cap}`); e.exit = 1; throw e; }
  c.data[kind] = c.n + 1;
  store.writeRecord(c.file, c.data);
  return c.n + 1;
}

// ---------------------------------------------------------------------
const cmds = {
  capability(o) {
    const pol = policyLib.loadPolicy();
    const r = capability.detect({ projectDir: path.resolve(o.project || process.cwd()), policy: pol });
    store.writeRecord(path.join(store.shipHome(), 'capability.json'), r);
    store.appendAudit('ship_capability', { overall: r.overall, blockers: r.blockers, watch_blockers: r.watch_blockers });
    out(r, o.json);
    return r.overall === 'unavailable' ? 1 : 0;
  },

  'run-start'(o) {
    need(o, 'project', 'repo', 'mode');
    if (!MODES.includes(o.mode)) { const e = new Error('INVALID_MODE'); e.exit = 2; throw e; }
    const pol = policyLib.loadPolicy();
    bumpDaily('runs', pol.limits.dailyRunCap);
    const projectDir = path.resolve(o.project);
    const head = spawnSync('git', ['-C', projectDir, 'rev-parse', 'HEAD'], { encoding: 'utf8' }).stdout.trim() || null;
    const branch = spawnSync('git', ['-C', projectDir, 'rev-parse', '--abbrev-ref', 'HEAD'], { encoding: 'utf8' }).stdout.trim() || null;
    const cap = store.readRecord(path.join(store.shipHome(), 'capability.json'));
    const run = {
      schema: store.SCHEMA.run, run_id: store.newId('run'), repo: store.assertRepo(o.repo), project_dir: projectDir,
      mode: o.mode, state: 'IDLE', intent: String(o.intent || '').slice(0, 2000), pr: o.pr ? store.assertPr(o.pr) : null,
      head_sha: /^[0-9a-f]{40}$/.test(head) ? head : null, base_sha: null, branch,
      ship: { capability: cap ? cap.overall : 'unknown', status: 'not-started', notes: 'Ship (/ship) は人が対話セッションで入力する。ClaudeOS は代行しない' },
      retries: 0, created_at: new Date().toISOString(), updated_at: new Date().toISOString(), history: [],
    };
    // 同一 repo + branch の active run は 1 つまで (複数エージェントが同じ PR を同時修正しない)
    const dup = store.listJson(store.paths.runsDir()).map(store.readRecord)
      .find((r) => r && r.repo === run.repo && r.branch === run.branch && !sm.TERMINAL.has(r.state));
    if (dup) { const e = new Error('ACTIVE_RUN_EXISTS ' + dup.run_id); e.exit = 1; throw e; }
    sm.transition(run, 'DISCOVERY', { reason: 'run-start' });
    store.writeRecord(store.paths.run(run.run_id), run, { exclusive: true });
    store.appendAudit('run_started', { run_id: run.run_id, repo: run.repo, mode: run.mode });
    out(run, o.json);
    return 0;
  },

  'run-status'(o) {
    if (o.id) { const r = store.readRecord(store.paths.run(o.id)); out(r || { error: 'NOT_FOUND' }, o.json); return r ? 0 : 1; }
    const runs = store.listJson(store.paths.runsDir()).map(store.readRecord).filter(Boolean)
      .map((r) => ({ run_id: r.run_id, repo: r.repo, mode: r.mode, state: r.state, pr: r.pr, head_sha: r.head_sha, updated_at: r.updated_at }));
    out(runs, o.json);
    return 0;
  },

  'run-transition'(o) {
    need(o, 'id', 'to');
    if (['HUMAN_APPROVED', 'MERGE_QUEUED', 'MERGING', 'MERGED'].includes(o.to)) {
      const e = new Error('RESTRICTED_TRANSITION (承認・マージは ship merge / monitor が検証付きで遷移させる)'); e.exit = 1; throw e;
    }
    const file = store.paths.run(o.id);
    const lock = store.withLock('run-' + o.id, () => {
      const run = store.readRecord(file);
      if (!run) throw Object.assign(new Error('NOT_FOUND'), { exit: 1 });
      const ev = { reason: o.reason || null };
      if (o.to === 'HUMAN_APPROVAL_REQUIRED') {
        const g = run.pr && run.head_sha ? store.readRecord(store.paths.gate(run.repo, run.pr, run.head_sha)) : null;
        ev.gate_verdict = g ? g.verdict : null;
      }
      sm.transition(run, o.to, ev);
      store.writeRecord(file, run);
      store.appendAudit('run_transition', { run_id: run.run_id, to: o.to, reason: ev.reason });
      return run;
    });
    if (!lock.locked) { const e = new Error('RUN_LOCKED'); e.exit = 1; throw e; }
    out(lock.value, o.json);
    return 0;
  },

  'run-stop'(o) {
    need(o, 'id');
    const file = store.paths.run(o.id);
    const run = store.readRecord(file);
    if (!run) return 1;
    sm.transition(run, 'STOPPED', { reason: o.reason || 'user-stop' });
    store.writeRecord(file, run);
    store.appendAudit('run_stopped', { run_id: run.run_id, reason: o.reason || 'user-stop' });
    out({ run_id: run.run_id, state: run.state, note: '対話セッションで /ship を実行中なら、そのセッションで `/ship stop` を入力して watch を止めること' }, o.json);
    return 0;
  },

  'discover-pr'(o) {
    need(o, 'repo', 'branch');
    const r = github.findPrForBranch(o.repo, o.branch);
    if (!r.ok) { out(r, o.json); return 3; }
    out({ repo: o.repo, branch: o.branch, existing: r.data, action: r.data.length ? 'REUSE' : 'CREATE' }, o.json);
    return 0;
  },

  quality(o) {
    need(o, 'repo', 'project', 'head');
    const pol = policyLib.loadPolicy();
    bumpDaily('quality', pol.limits.dailyQualityRunCap);
    const rec = quality.runQuality({ repo: o.repo, repoDir: path.resolve(o.project), headSha: o.head, baseSha: o.base || null,
      pr: o.pr ? Number(o.pr) : null, profile: o.profile || 'claudeos-self', policy: pol });
    let published = null;
    if (o.publish) published = publishQuality(rec, pol);
    const summary = { eval_id: rec.eval_id, verdict: rec.verdict, head_sha: rec.head_sha, isolation: rec.isolation, reasons: rec.reasons,
      checks: rec.checks.map((c) => ({ id: c.id, status: c.status, exit_code: c.exit_code, passed: c.passed, failed: c.failed, skipped: c.skipped, ms: c.duration_ms, reason: c.reason })),
      evidence_hash: rec.evidence_hash, published };
    out(summary, o.json);
    return rec.verdict === 'PASS' ? 0 : 1;
  },

  classify(o) {
    need(o, 'repo', 'pr');
    const pol = policyLib.loadPolicy();
    const f = github.changedFiles(o.repo, o.pr);
    if (!f.ok) { out({ error: f.error }, o.json); return 3; }
    out(risk.classify(f.data, pol.risk), o.json);
    return 0;
  },

  gate(o) {
    need(o, 'repo', 'pr');
    const pol = trustedPolicy(o);
    const p = github.fetchPr(o.repo, o.pr);
    if (!p.ok) { out({ verdict: 'BLOCKED', reason: p.error }, o.json); return 3; }
    const pr = p.data;
    const files = github.changedFiles(o.repo, o.pr);
    const rk = risk.classify(files.ok ? files.data : [], pol.risk);
    // 取得に失敗した理由を残す (変更ファイル 0 件と区別するため。どちらも安全側 R4)
    if (!files.ok) rk.reason = `CHANGED_FILES_UNAVAILABLE: ${files.error}${files.detail ? ' (' + String(files.detail).slice(0, 200) + ')' : ''} — 安全側 R4`;
    const q = quality.latestEvidence(o.repo, pr.headRefOid);
    const ship = hg.shipEvidenceFor(o.repo, o.pr, pr.headRefOid, pol);
    const riskDocs = { impactAnalysis: docExists(o['impact-doc']), rollbackPlan: docExists(o['rollback-doc']) };
    const res = gateLib.evaluate({ pr, headSha: pr.headRefOid, baseSha: pr.baseRefOid, quality: q, ship, risk: rk, riskDocs,
      requirements: { status: o.requirements || 'unknown' }, residual: [] }, pol);
    const gate = { schema: store.SCHEMA.gate, repo: o.repo, pr: Number(o.pr), head_sha: pr.headRefOid, base_sha: pr.baseRefOid,
      verdict: res.verdict, risk: rk.level, risk_detail: rk.files.slice(0, 200), reasons: res.reasons, checks: res.checks,
      quality_eval_id: q.evidence ? q.evidence.eval_id : null, ship_source: ship ? ship.source : null,
      policy_version: pol.policyVersion, evaluated_at: new Date().toISOString(),
      note: 'ClaudeOS AI Quality Gate (独自機能。Anthropic 公式の Claude Approvals ではない)。PASS は人間の承認を意味しない' };
    gate.gate_hash = hg.gateHash(gate);
    store.writeRecord(store.paths.gate(o.repo, o.pr, pr.headRefOid), gate);
    store.appendAudit('quality_gate', { repo: o.repo, pr: Number(o.pr), head_sha: pr.headRefOid, verdict: res.verdict, risk: rk.level });
    out(gate, o.json);
    return res.verdict === 'PASS' ? 0 : 1;
  },

  approvals(o) {
    need(o, 'repo', 'pr');
    const pol = trustedPolicy(o);
    const p = github.fetchPr(o.repo, o.pr);
    const head = p.ok ? p.data.headRefOid : null; const base = p.ok ? p.data.baseRefOid : null;
    const gate = head ? store.readRecord(store.paths.gate(o.repo, o.pr, head)) : null;
    const list = store.listJson(store.paths.approvalsDir(o.repo, o.pr)).map((f) => {
      const a = store.readRecord(f);
      const v = head ? hg.verifyApproval(a, { policy: pol, headSha: head, baseSha: base, gate }) : { ok: false, reason: 'PR_UNKNOWN' };
      return { approval_id: a && a.approval_id, approver: a && a.approver, head_sha: a && a.head_sha, issued_at: a && a.issued_at, expires_at: a && a.expires_at, valid: v.ok, reason: v.reason || null };
    });
    out({ repo: o.repo, pr: Number(o.pr), current_head: head, current_base: base, approvals: list }, o.json);
    return 0;
  },

  merge(o) {
    need(o, 'repo', 'pr');
    const pol = trustedPolicy(o);
    const r = merge.execute({ repo: o.repo, pr: Number(o.pr), policy: pol, dryRun: !!o['dry-run'] });
    out(r, o.json);
    return ['REFUSED', 'FAILED', 'BUSY'].includes(r.state) ? 1 : 0;
  },

  'merge-confirm'(o) {
    need(o, 'repo', 'pr');
    out(merge.confirm({ repo: o.repo, pr: Number(o.pr) }), o.json);
    return 0;
  },

  monitor(o) {
    const pol = policyLib.loadPolicy();
    const tick = () => monitorTick(pol);
    if (o.once || !o.interval) { out(tick(), o.json); return 0; }
    const sec = Math.max(60, Number(o.interval) || 300);
    out(tick(), o.json);
    setInterval(() => out(tick(), o.json), sec * 1000);
    return null; // 常駐
  },

  actions(o) {
    need(o, 'repo');
    const r = github.actionsRuns(o.repo, Number(o.limit || 100));
    if (!r.ok) { out({ error: r.error }, o.json); return 3; }
    const by = {};
    for (const x of r.data) { const k = x.workflowName; by[k] = by[k] || { runs: 0, failure: 0 }; by[k].runs++; if (x.conclusion === 'failure') by[k].failure++; }
    const summary = { repo: o.repo, sampled: r.data.length, by_workflow: by, collected_at: new Date().toISOString(),
      note: '分数・課金額は gh run list から取得できない (billing API は個人アカウントで別権限)。実行回数のみ実測' };
    store.writeRecord(path.join(store.shipHome(), 'actions-usage.json'), summary);
    out(summary, o.json);
    return 0;
  },

  'audit-verify'(o) { const r = store.verifyAuditChain(); out(r, o.json); return r.ok ? 0 : 1; },
};

function docExists(f) { return !!(f && typeof f === 'string' && fs.existsSync(f) && fs.statSync(f).size > 200); }

/** publishQuality — Commit Status 登録。品質プロセス専用トークン (CLAUDEOS_QA_TOKEN_FILE) があればそれを使う */
function publishQuality(rec, pol) {
  let token = null;
  const tf = process.env.CLAUDEOS_QA_TOKEN_FILE;
  if (tf && fs.existsSync(tf)) token = fs.readFileSync(tf, 'utf8').trim();
  const state = rec.verdict === 'PASS' ? 'success' : rec.verdict === 'FAIL' ? 'failure' : 'error';
  const failed = rec.checks.filter((c) => c.status !== 'PASS').map((c) => c.id);
  const desc = rec.verdict === 'PASS' ? `PASS ${rec.checks.length} checks eval=${rec.eval_id}` : `${rec.verdict}: ${failed.join(',') || rec.reasons.join(',')}`.slice(0, 140);
  const r = github.postStatus(rec.repo, rec.head_sha, { context: pol.quality.statusContext, state, description: desc }, { token });
  store.appendAudit('quality_published', { repo: rec.repo, head_sha: rec.head_sha, eval_id: rec.eval_id, state, ok: r.ok, identity: token ? 'qa-token' : 'gh-default' });
  return { ...r, state, identity: token ? 'qa-token' : 'gh-default' };
}

/** monitorTick — 全 active run について GitHub 事実と照合 (古い状態だけを根拠にマージしない) */
function monitorTick(pol) {
  const results = [];
  for (const f of store.listJson(store.paths.runsDir())) {
    const run = store.readRecord(f);
    if (!run || sm.TERMINAL.has(run.state) || !run.pr) continue;
    const lock = store.withLock('run-' + run.run_id, () => {
      const r = store.readRecord(f);
      const p = github.fetchPr(r.repo, r.pr);
      if (!p.ok) {
        r.retries = (r.retries || 0) + 1;
        if (r.retries >= pol.limits.circuitBreakerFailures && r.state !== 'BLOCKED') sm.transition(r, 'BLOCKED', { reason: 'CIRCUIT_OPEN ' + p.error });
        r.next_retry_at = new Date(Date.now() + Math.min(pol.limits.backoffMaxSec, pol.limits.backoffBaseSec * 2 ** r.retries) * 1000).toISOString();
        store.writeRecord(f, r);
        return { run_id: r.run_id, error: p.error, retries: r.retries };
      }
      r.retries = 0;
      const d = p.data;
      const ev = { run_id: r.run_id, pr: r.pr, state: r.state };
      if (d.state === 'MERGED') {
        const m = merge.confirm({ repo: r.repo, pr: r.pr });
        if (m.state === 'MERGED' && ['MERGE_QUEUED', 'MERGING'].includes(r.state)) {
          sm.transition(r, 'MERGED', { merge_confirmed: true, merge_commit_sha: m.merge_commit_sha });
          sm.transition(r, 'COMPLETED', { reason: 'merged' });
        } else if (m.state === 'MERGED') {
          // ClaudeOS の承認経路を通らずにマージされた → 記録して停止 (成功扱いにしない)
          store.appendAudit('merged_outside_gate', { run_id: r.run_id, repo: r.repo, pr: r.pr, from_state: r.state });
          sm.transition(r, 'STOPPED', { reason: 'MERGED_OUTSIDE_HUMAN_GATE' });
        }
      } else if (d.state === 'CLOSED') {
        sm.transition(r, 'STOPPED', { reason: 'PR_CLOSED' });
      } else {
        const hc = sm.onHeadChanged(r, d.headRefOid);
        if (r.base_sha && r.base_sha !== d.baseRefOid && ['HUMAN_APPROVAL_REQUIRED', 'HUMAN_APPROVED', 'MERGE_QUEUED', 'MERGING'].includes(r.state)) {
          sm.transition(r, 'SHIP_REVALIDATING', { reason: 'BASE_CHANGED', base_sha: d.baseRefOid });
        }
        r.base_sha = d.baseRefOid;
        if (hc.changed) {
          ev.head_changed = { from: hc.prev, to: d.headRefOid };
          // 承認後に head が変わった → auto-merge が登録済みなら外す (GitHub の SHA 単位 status でも止まるが二重化)
          if (d.autoMerge) { github.disableAutoMerge(r.repo, r.pr); store.appendAudit('auto_merge_disabled', { run_id: r.run_id, reason: 'HEAD_CHANGED' }); }
        }
      }
      ev.new_state = r.state;
      store.writeRecord(f, r);
      return ev;
    });
    results.push(lock.locked ? lock.value : { run_id: run.run_id, skipped: 'LOCKED' });
  }
  return { checked_at: new Date().toISOString(), runs: results };
}

function main(argv = process.argv.slice(2)) {
  const o = parse(argv);
  const cmd = o._[0];
  if (!cmd || !cmds[cmd] || o.help) {
    process.stdout.write(fs.readFileSync(__filename, 'utf8').split('\n').slice(2, 30).map((l) => l.replace(/^ \* ?/, '')).join('\n') + '\n');
    return cmd && !cmds[cmd] ? 2 : 0;
  }
  try { return cmds[cmd](o); } catch (e) {
    process.stderr.write(`ship: ${e.message}${e.detail ? ' — ' + e.detail : ''}\n`);
    return e.exit || (e.code === 'ILLEGAL_TRANSITION' ? 1 : 1);
  }
}

module.exports = { main, monitorTick, publishQuality, cmds, parse };

if (require.main === module) {
  const rc = main();
  if (rc !== null) process.exitCode = rc;
}
