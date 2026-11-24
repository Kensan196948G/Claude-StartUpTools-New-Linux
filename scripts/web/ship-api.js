'use strict';
/**
 * ship-api.js — Ship Native Control Center 用の集約 API (Web コンソール)
 *
 * 読み取り専用の集約 (GET /api/ship/*) と、承認の「取り消し」だけを扱う。
 *   - 置き場・レコード形式の正本は scripts/ship/lib/store.js。ここは読むだけ (取り消しのみ書く)。
 *   - 承認の有効性 (VALID / STALE_HEAD / EXPIRED / REVOKED) は「表示用」の計算。
 *     実際の強制 (マージ可否) は scripts/ship/lib/human-gate.js が行う。ここの判定でマージは決まらない。
 *   - 承認 (approve) のエンドポイントは意図的に作らない。Web サーバは AI エージェントと同じ OS ユーザで
 *     動くため、ボタン押下では「人間が承認した」ことを証明できない。承認は人間が CLI
 *     (bin/ship-approve.sh) で行う。
 *   - 取り消し (revoke) は安全側 (fail-safe) の操作なので許可する。ただし Cloudflare Access の
 *     JWT (メール付き) を必須にし、実行者を監査ログへ残す (handleOpsRestart と同じ基準)。
 *
 * 不明・未取得のデータは捏造しない: 値が無ければ null / 'UNKNOWN' を返し、UI は「未取得」と表示する。
 * ship home の外のファイルパスは返さない。秘密情報は store.redact で除去してから返す。
 */

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const store = require('../ship/lib/store.js');
const { STATES, TERMINAL } = require('../ship/lib/state-machine.js');

const SHA_RE = /^[0-9a-f]{40}$/;
const SLUG_RE = /^[A-Za-z0-9_.-]{1,100}__[A-Za-z0-9_.-]{1,100}$/;
const PR_DIR_RE = /^pr-(\d{1,8})$/;
const PR_FILE_RE = /^pr-(\d{1,8})\.json$/;

const SHIP_STATES = new Set(['SHIP_STARTING', 'SHIP_REVIEWING', 'SHIP_REMEDIATING', 'SHIP_REVALIDATING']);
const BLOCKED_STATES = new Set(['BLOCKED', 'FAILED', 'QUALITY_FAILED']);
const ACTIONS_NOTE = 'GitHub Actions 実行状況は ship CLI で取得 (bin/ship.sh actions)';
const ENFORCEMENT_NOTE = '承認の有効性はこの画面では表示用の計算です。マージ可否の強制は scripts/ship/lib/human-gate.js が行います。';
const NO_APPROVE_NOTE = 'Web からの承認はできません。Web サーバは AI エージェントと同じ OS ユーザで動くため、ボタン押下では人間の承認を証明できません。人間が端末で CLI を実行してください。';

// ---------------------------------------------------------------------------
// 安全なディレクトリ走査 (シンボリックリンクは辿らない: ship home の外へ出ない)
//   store.listJson は Dirent 種別を見ないため、表示用の走査はこちらを使う。
// ---------------------------------------------------------------------------
function entries(dir) {
  try { return fs.readdirSync(dir, { withFileTypes: true }); } catch { return []; }
}
function subdirs(dir, re) {
  return entries(dir).filter((d) => d.isDirectory() && (!re || re.test(d.name))).map((d) => d.name);
}
function jsonFiles(dir) {
  return entries(dir).filter((d) => d.isFile() && d.name.endsWith('.json')).map((d) => path.join(dir, d.name));
}
function readAll(dir) {
  return jsonFiles(dir).map((f) => store.readRecord(f)).filter((r) => r && typeof r === 'object' && !Array.isArray(r));
}
function exists(file) {
  try { return fs.lstatSync(file).isFile(); } catch { return false; }
}
function repoFromSlug(s) {
  if (!SLUG_RE.test(s)) return null;
  const i = s.indexOf('__');
  const repo = s.slice(0, i) + '/' + s.slice(i + 2);
  try { store.assertRepo(repo); return repo; } catch { return null; }
}
function ts(v) {
  const t = Date.parse(String(v || ''));
  return Number.isFinite(t) ? t : 0;
}
function isSha(v) { return typeof v === 'string' && SHA_RE.test(v); }

// ---------------------------------------------------------------------------
// 出力の無害化: 秘密の除去 + ship home 外のパスを隠す
// ---------------------------------------------------------------------------
function scrubPaths(value, home) {
  const homeDir = os.homedir();
  const fix = (s) => {
    if (/^(\/|~\/|[A-Za-z]:[\\/])/.test(s)) {
      const abs = path.resolve(s.replace(/^~(?=\/)/, homeDir));
      if (abs === home || abs.startsWith(home + path.sep)) return path.relative(home, abs) || '.';
      return '[PATH_HIDDEN]';
    }
    // 文中に埋まったホームディレクトリは ~ へ縮める (ユーザ名などを出さない)
    return homeDir && homeDir.length > 1 ? s.split(homeDir).join('~') : s;
  };
  const walk = (v) => {
    if (typeof v === 'string') return fix(v);
    if (Array.isArray(v)) return v.map(walk);
    if (v && typeof v === 'object') {
      const o = {};
      for (const [k, x] of Object.entries(v)) o[k] = walk(x);
      return o;
    }
    return v;
  };
  return walk(value);
}
function clean(value) {
  return scrubPaths(store.redact(value), store.shipHome());
}
function str(v, max = 500) {
  return typeof v === 'string' ? v.slice(0, max) : (v == null ? null : String(v).slice(0, max));
}

function sanitizeRun(r) {
  const ship = r.ship && typeof r.ship === 'object' ? r.ship : {};
  return clean({
    run_id: str(r.run_id, 100),
    repo: str(r.repo, 210),
    project: typeof r.project_dir === 'string' && r.project_dir ? path.basename(r.project_dir) : null,
    mode: str(r.mode, 40),
    state: STATES.includes(r.state) ? r.state : 'UNKNOWN',
    pr: Number.isInteger(r.pr) ? r.pr : null,
    head_sha: isSha(r.head_sha) ? r.head_sha : null,
    base_sha: isSha(r.base_sha) ? r.base_sha : null,
    branch: str(r.branch, 200),
    ship: {
      capability: ship.capability === undefined ? null : ship.capability,
      status: str(ship.status, 40) || 'UNKNOWN',
      notes: str(ship.notes, 1000),
    },
    history: Array.isArray(r.history) ? r.history.slice(-30) : [],
    created_at: str(r.created_at, 40),
    updated_at: str(r.updated_at, 40),
    terminal: TERMINAL.has(r.state),
  });
}

function sanitizeQuality(q) {
  const checks = Array.isArray(q.checks) ? q.checks.map((c) => ({
    id: str(c && c.id, 80),
    category: str(c && c.category, 60),
    cmd: Array.isArray(c && c.cmd) ? c.cmd.map((x) => str(x, 200)) : str(c && c.cmd, 400),
    exit_code: c && Number.isInteger(c.exit_code) ? c.exit_code : null,
    passed: c && Number.isFinite(c.passed) ? c.passed : null,
    failed: c && Number.isFinite(c.failed) ? c.failed : null,
    skipped: c && Number.isFinite(c.skipped) ? c.skipped : null,
    duration_ms: c && Number.isFinite(c.duration_ms) ? c.duration_ms : null,
    log_file: c && typeof c.log_file === 'string' ? c.log_file : null,   // clean() で ship home 外は隠す
    status: str(c && c.status, 40) || 'UNKNOWN',
  })) : [];
  return clean({
    eval_id: str(q.eval_id, 100),
    repo: str(q.repo, 210),
    head_sha: isSha(q.head_sha) ? q.head_sha : null,
    base_sha: isSha(q.base_sha) ? q.base_sha : null,
    pr: Number.isInteger(q.pr) ? q.pr : null,
    started_at: str(q.started_at, 40),
    finished_at: str(q.finished_at, 40),
    isolation: str(q.isolation, 60),
    verdict: ['PASS', 'FAIL', 'UNKNOWN'].includes(q.verdict) ? q.verdict : 'UNKNOWN',
    checks,
    evidence_hash: str(q.evidence_hash, 128),
    hmac_present: typeof q.hmac === 'string' && q.hmac.length > 0,   // HMAC 値そのものは返さない
  });
}

function sanitizeGate(g) {
  return clean({
    repo: str(g.repo, 210),
    pr: Number.isInteger(g.pr) ? g.pr : null,
    head_sha: isSha(g.head_sha) ? g.head_sha : null,
    base_sha: isSha(g.base_sha) ? g.base_sha : null,
    verdict: ['PASS', 'CONDITIONAL', 'FAIL', 'UNKNOWN', 'BLOCKED'].includes(g.verdict) ? g.verdict : 'UNKNOWN',
    risk: str(g.risk, 20),
    reasons: Array.isArray(g.reasons) ? g.reasons.slice(0, 50).map((x) => (typeof x === 'string' ? x.slice(0, 500) : x)) : [],
    inputs: g.inputs && typeof g.inputs === 'object' ? g.inputs : null,
    evaluated_at: str(g.evaluated_at, 40),
  });
}

function sanitizeApproval(a) {
  // 署名・nonce は返さない (表示に不要。key_id だけ示す)
  return clean({
    approval_id: str(a.approval_id, 100),
    repo: str(a.repo, 210),
    pr: Number.isInteger(a.pr) ? a.pr : null,
    head_sha: isSha(a.head_sha) ? a.head_sha : null,
    base_sha: isSha(a.base_sha) ? a.base_sha : null,
    gate_verdict: str(a.gate_verdict, 20),
    risk: str(a.risk, 20),
    approver: str(a.approver, 200),
    issued_at: str(a.issued_at, 40),
    expires_at: str(a.expires_at, 40),
    key_id: str(a.key_id, 100),
    signed: typeof a.signature === 'string' && a.signature.length > 0,
  });
}

function sanitizeMerge(m) {
  const confirmed = m.confirmed === true;
  return clean({
    repo: str(m.repo, 210),
    pr: Number.isInteger(m.pr) ? m.pr : null,
    state: str(m.state, 40) || 'UNKNOWN',
    // MERGED と表示してよいのは API 再取得で確認済み (confirmed=true) かつ commit SHA がある場合だけ
    merged_confirmed: confirmed && m.state === 'MERGED' && isSha(m.merge_commit_sha),
    merge_commit_sha: isSha(m.merge_commit_sha) ? m.merge_commit_sha : null,
    confirmed,
    at: str(m.at, 40),
    reason: str(m.reason, 500),
  });
}

// ---------------------------------------------------------------------------
// 収集
// ---------------------------------------------------------------------------
function loadRuns() {
  const out = [];
  for (const r of readAll(store.paths.runsDir())) {
    if (typeof r.run_id !== 'string') continue;
    out.push(r);
  }
  out.sort((a, b) => ts(b.updated_at || b.created_at) - ts(a.updated_at || a.created_at));
  return out;
}

function knownRepos(runs) {
  const set = new Set();
  for (const r of runs) {
    try { if (r.repo) set.add(store.assertRepo(r.repo)); } catch { /* 不正な repo は数えない */ }
  }
  const home = store.shipHome();
  for (const top of ['quality', 'gates', 'approvals', 'merges']) {
    for (const s of subdirs(path.join(home, top), SLUG_RE)) {
      const repo = repoFromSlug(s);
      if (repo) set.add(repo);
    }
  }
  return [...set].sort();
}

/** knownPrs — runs / gates / approvals / merges に現れる (repo, pr) の組 */
function knownPrs(runs) {
  const map = new Map();
  const add = (repo, pr) => {
    try { store.assertRepo(repo); store.assertPr(pr); } catch { return; }
    map.set(repo + '#' + Number(pr), { repo, pr: Number(pr) });
  };
  for (const r of runs) if (r.repo && Number.isInteger(r.pr)) add(r.repo, r.pr);
  const home = store.shipHome();
  for (const top of ['gates', 'approvals']) {
    for (const s of subdirs(path.join(home, top), SLUG_RE)) {
      const repo = repoFromSlug(s);
      if (!repo) continue;
      for (const d of subdirs(path.join(home, top, s), PR_DIR_RE)) add(repo, Number(PR_DIR_RE.exec(d)[1]));
    }
  }
  for (const s of subdirs(path.join(home, 'merges'), SLUG_RE)) {
    const repo = repoFromSlug(s);
    if (!repo) continue;
    for (const d of entries(path.join(home, 'merges', s))) {
      const m = d.isFile() && PR_FILE_RE.exec(d.name);
      if (m) add(repo, Number(m[1]));
    }
  }
  return [...map.values()].sort((a, b) => (a.repo === b.repo ? b.pr - a.pr : a.repo.localeCompare(b.repo)));
}

function loadGates(repo, pr) {
  const gates = readAll(store.paths.gatesDir(repo, pr)).filter((g) => isSha(g.head_sha));
  gates.sort((a, b) => ts(b.evaluated_at) - ts(a.evaluated_at));
  return gates;
}
function loadApprovals(repo, pr) {
  const list = readAll(store.paths.approvalsDir(repo, pr)).filter((a) => typeof a.approval_id === 'string');
  list.sort((a, b) => ts(b.issued_at) - ts(a.issued_at));
  return list;
}
function loadMerge(repo, pr) {
  const file = store.paths.merge(repo, pr);
  return exists(file) ? store.readRecord(file) : null;
}
function latestQuality(repo, sha) {
  if (!isSha(sha)) return null;
  const list = readAll(store.paths.qualityDir(repo, sha));
  list.sort((a, b) => ts(b.finished_at || b.started_at) - ts(a.finished_at || a.started_at));
  return list[0] || null;
}
function isRevoked(approvalId) {
  try { return exists(store.paths.revocation(approvalId)); } catch { return false; }
}

/**
 * latestHeadFor — その PR の「最新 head」。run (最も新しく更新されたもの) の head を優先し、
 *   無ければ最も新しいゲート判定の head。どちらも無ければ null (= 不明)。
 */
function latestHeadFor(prRuns, gates) {
  const r = prRuns.find((x) => isSha(x.head_sha));
  if (r) return { head: r.head_sha, source: 'run' };
  if (gates[0]) return { head: gates[0].head_sha, source: 'gate' };
  return { head: null, source: null };
}

/**
 * approvalValidity — 表示用の有効性。優先順: REVOKED > EXPIRED > STALE_HEAD > VALID。
 *   強制は human-gate.js。ここは「人間が見て判断するため」の目安。
 */
function approvalValidity(a, latestHead, now = Date.now()) {
  if (typeof a.approval_id === 'string' && isRevoked(a.approval_id)) return { state: 'REVOKED', reason: 'REVOCATION_RECORDED' };
  const exp = Date.parse(String(a.expires_at || ''));
  if (!Number.isFinite(exp)) return { state: 'EXPIRED', reason: 'EXPIRES_AT_INVALID' };
  if (exp <= now) return { state: 'EXPIRED', reason: 'EXPIRED' };
  if (!latestHead) return { state: 'STALE_HEAD', reason: 'LATEST_HEAD_UNKNOWN' };
  if (a.head_sha !== latestHead) return { state: 'STALE_HEAD', reason: 'HEAD_MISMATCH' };
  return { state: 'VALID', reason: null };
}

function approveCommand(repo, pr, head) {
  return `bin/ship-approve.sh approve --repo ${repo} --pr ${pr} --head ${head || '<head_sha>'}`;
}

/** prSummary — 1 PR の集約 (overview の一覧と /api/ship/pr の詳細で共用) */
function collectPr(repo, pr, allRuns, now) {
  const prRuns = allRuns.filter((r) => r.repo === repo && r.pr === pr);
  const gates = loadGates(repo, pr);
  const approvals = loadApprovals(repo, pr);
  const merge = loadMerge(repo, pr);
  const lh = latestHeadFor(prRuns, gates);
  const gateLatest = lh.head ? gates.find((g) => g.head_sha === lh.head) || null : null;
  const qLatest = lh.head ? latestQuality(repo, lh.head) : null;
  const approvalsV = approvals.map((a) => ({ raw: a, validity: approvalValidity(a, lh.head, now) }));
  const hasValid = approvalsV.some((x) => x.validity.state === 'VALID');
  const mergeS = merge ? sanitizeMerge(merge) : null;
  const pending = !!(gateLatest && gateLatest.verdict === 'PASS' && !hasValid && !(mergeS && mergeS.merged_confirmed));
  return { prRuns, gates, approvalsV, merge: mergeS, lh, gateLatest, qLatest, hasValid, pending };
}

// ---------------------------------------------------------------------------
// 公開: 集約関数
// ---------------------------------------------------------------------------
function readOptionalJson(name) {
  const file = path.join(store.shipHome(), name);
  if (!exists(file)) return null;
  const v = store.readRecord(file);
  return v && typeof v === 'object' ? clean(v) : null;
}

function overview(now = Date.now()) {
  const runs = loadRuns();
  const prs = knownPrs(runs).map(({ repo, pr }) => {
    const c = collectPr(repo, pr, runs, now);
    const run = c.prRuns[0] || null;
    const best = ['VALID', 'STALE_HEAD', 'EXPIRED', 'REVOKED'].find((s) => c.approvalsV.some((x) => x.validity.state === s)) || null;
    return {
      repo, pr,
      latest_head: c.lh.head,
      latest_head_source: c.lh.source,
      run_id: run ? run.run_id : null,
      run_state: run && STATES.includes(run.state) ? run.state : (run ? 'UNKNOWN' : null),
      ship_status: run && run.ship && run.ship.status ? str(run.ship.status, 40) : null,
      gate_verdict: c.gateLatest ? sanitizeGate(c.gateLatest).verdict : null,
      gate_risk: c.gateLatest ? str(c.gateLatest.risk, 20) : null,
      quality_verdict: c.qLatest ? sanitizeQuality(c.qLatest).verdict : null,
      approval_count: c.approvalsV.length,
      approval_best: best,
      merge_state: c.merge ? c.merge.state : null,
      merged_confirmed: c.merge ? c.merge.merged_confirmed : false,
      merge_commit_sha: c.merge ? c.merge.merge_commit_sha : null,
      merge_at: c.merge ? c.merge.at : null,
      merge_reason: c.merge ? c.merge.reason : null,
      pending_approval: c.pending,
      approve_command: c.pending ? approveCommand(repo, pr, c.lh.head) : null,
    };
  });

  // ローカル品質の成功率: 判定が PASS / FAIL の記録だけを分母にする (UNKNOWN は除外)
  let pass = 0; let decided = 0;
  const home = store.shipHome();
  for (const s of subdirs(path.join(home, 'quality'), SLUG_RE)) {
    for (const sha of subdirs(path.join(home, 'quality', s), SHA_RE)) {
      for (const q of readAll(path.join(home, 'quality', s, sha))) {
        if (q.verdict === 'PASS') { pass++; decided++; } else if (q.verdict === 'FAIL') decided++;
      }
    }
  }

  const actions = readOptionalJson('actions-usage.json');
  return {
    generated_at: new Date(now).toISOString(),
    counts: {
      projects: knownRepos(runs).length,
      runs_active: runs.filter((r) => STATES.includes(r.state) && !TERMINAL.has(r.state)).length,
      ship_running: runs.filter((r) => SHIP_STATES.has(r.state) || (r.ship && r.ship.status === 'running')).length,
      quality_evaluating: runs.filter((r) => r.state === 'QUALITY_EVALUATING').length,
      approval_pending: prs.filter((p) => p.pending_approval).length,
      merged: prs.filter((p) => p.merged_confirmed).length,
      blocked_or_failed: runs.filter((r) => BLOCKED_STATES.has(r.state)).length,
    },
    local_quality_success_rate: decided ? Math.round((pass / decided) * 1000) / 1000 : null,
    local_quality_sample: { pass, decided },
    ship_capability: readOptionalJson('capability.json'),
    actions,
    actions_note: actions ? null : ACTIONS_NOTE,
    states: STATES.slice(),
    terminal_states: [...TERMINAL],
    prs,
    enforcement_note: ENFORCEMENT_NOTE,
    approve_note: NO_APPROVE_NOTE,
  };
}

function listRuns() {
  return { runs: loadRuns().map(sanitizeRun) };
}

/** prDetail — repo / pr は検証済み (不正は例外 INVALID_REPO / INVALID_PR) */
function prDetail(repoIn, prIn, now = Date.now()) {
  const repo = store.assertRepo(repoIn);
  const pr = store.assertPr(prIn);
  const runs = loadRuns();
  const c = collectPr(repo, pr, runs, now);
  const heads = new Set();
  if (c.lh.head) heads.add(c.lh.head);
  for (const g of c.gates) heads.add(g.head_sha);
  for (const r of c.prRuns) if (isSha(r.head_sha)) heads.add(r.head_sha);
  for (const x of c.approvalsV) if (isSha(x.raw.head_sha)) heads.add(x.raw.head_sha);
  const quality = [];
  for (const h of heads) {
    const q = latestQuality(repo, h);
    quality.push(q ? Object.assign(sanitizeQuality(q), { sha_match: q.head_sha === h && h === c.lh.head })
      : { head_sha: h, verdict: 'UNKNOWN', missing: true, checks: [], sha_match: null, is_latest_head: h === c.lh.head });
  }
  return {
    repo, pr,
    latest_head: c.lh.head,
    latest_head_source: c.lh.source,
    runs: c.prRuns.map(sanitizeRun),
    quality,
    gates: c.gates.map(sanitizeGate),
    approvals: c.approvalsV.map((x) => Object.assign(sanitizeApproval(x.raw), {
      validity: x.validity.state, validity_reason: x.validity.reason,
    })),
    merge: c.merge,
    pending_approval: c.pending,
    approve_command: approveCommand(repo, pr, c.lh.head),
    enforcement_note: ENFORCEMENT_NOTE,
    approve_note: NO_APPROVE_NOTE,
  };
}

function auditTail(limitIn) {
  const raw = parseInt(String(limitIn == null ? '50' : limitIn), 10);
  const limit = Math.min(Math.max(Number.isFinite(raw) ? raw : 50, 1), 500);
  let text = '';
  try { text = fs.readFileSync(store.paths.audit(), 'utf8'); } catch { text = ''; }
  const list = [];
  for (const line of text.split('\n')) {
    if (!line.trim()) continue;
    try { list.push(JSON.parse(line)); } catch { list.push({ event: 'UNPARSEABLE_LINE' }); }
  }
  return { limit, total: list.length, entries: list.slice(-limit).map(clean), chain: store.verifyAuditChain() };
}

function findApproval(id) {
  const home = store.shipHome();
  for (const s of subdirs(path.join(home, 'approvals'), SLUG_RE)) {
    for (const d of subdirs(path.join(home, 'approvals', s), PR_DIR_RE)) {
      const file = path.join(home, 'approvals', s, d, id + '.json');
      if (exists(file)) return store.readRecord(file);
    }
  }
  return null;
}

/**
 * revokeApproval — 承認の取り消し (安全側)。actor は検証済み JWT のメール。
 *   返り値 { status, body }。revocations/<id>.json を exclusive で書き、監査へ approval_revoked を残す。
 */
function revokeApproval(body, actor, now = Date.now()) {
  if (!body || typeof body !== 'object' || Array.isArray(body)) return { status: 400, body: { ok: false, error: 'BODY_NOT_OBJECT' } };
  let id;
  try { id = store.assertId(body.approval_id); } catch { return { status: 400, body: { ok: false, error: 'INVALID_APPROVAL_ID' } }; }
  const reason = typeof body.reason === 'string' ? body.reason.trim() : '';
  if (!reason) return { status: 400, body: { ok: false, error: 'REASON_REQUIRED' } };
  if (reason.length > 500) return { status: 400, body: { ok: false, error: 'REASON_TOO_LONG' } };
  if (!/@/.test(String(actor || ''))) return { status: 403, body: { ok: false, error: 'SHIP_AUTH_FAILED' } };
  const appr = findApproval(id);
  if (!appr) return { status: 404, body: { ok: false, error: 'APPROVAL_NOT_FOUND' } };
  const rec = {
    schema: store.SCHEMA.revocation,
    approval_id: id,
    repo: typeof appr.repo === 'string' ? appr.repo : null,
    pr: Number.isInteger(appr.pr) ? appr.pr : null,
    head_sha: isSha(appr.head_sha) ? appr.head_sha : null,
    reason,
    revoked_by: actor,
    revoked_at: new Date(now).toISOString(),
    source: 'web-console',
  };
  try {
    store.writeRecord(store.paths.revocation(id), rec, { exclusive: true });
  } catch (e) {
    if (e && e.code === 'EEXIST') return { status: 409, body: { ok: false, error: 'ALREADY_REVOKED' } };
    throw e;
  }
  store.appendAudit('approval_revoked', { approval_id: id, actor, repo: rec.repo, pr: rec.pr, reason, source: 'web-console' });
  return { status: 200, body: { ok: true, approval_id: id, revoked_at: rec.revoked_at, revoked_by: actor } };
}

// ---------------------------------------------------------------------------
// HTTP ハンドラ (startup-server.js から呼ぶ)
//   ctx = {
//     json(res, code, obj),
//     readBody(req) → Promise<{ ok, value | error }>,
//     checkStrict(req) → { ok, status, error }    // Origin 必須・JSON のみ (checkPromptRequest)
//     authEmail(req) → Promise<{ ok, email } | { ok:false, status, error }>   // Access JWT + メール形式
//     onReject?(info)                              // 拒否の監査 (任意)
//   }
//   /api/ship/ 以外は false を返す (呼び出し側が次の経路へ進む)。
// ---------------------------------------------------------------------------
async function handle(req, res, url, ctx) {
  const pn = url.pathname;
  if (!pn.startsWith('/api/ship/')) return false;
  const send = (code, obj) => { ctx.json(res, code, obj); return true; };
  const get = req.method === 'GET' || req.method === 'HEAD';

  if (pn === '/api/ship/overview') return get ? send(200, Object.assign({ ok: true }, overview())) : send(405, { ok: false, error: 'METHOD_NOT_ALLOWED' });
  if (pn === '/api/ship/runs') return get ? send(200, Object.assign({ ok: true }, listRuns())) : send(405, { ok: false, error: 'METHOD_NOT_ALLOWED' });
  if (pn === '/api/ship/audit') return get ? send(200, Object.assign({ ok: true }, auditTail(url.searchParams.get('limit')))) : send(405, { ok: false, error: 'METHOD_NOT_ALLOWED' });
  if (pn === '/api/ship/pr') {
    if (!get) return send(405, { ok: false, error: 'METHOD_NOT_ALLOWED' });
    try {
      return send(200, Object.assign({ ok: true }, prDetail(url.searchParams.get('repo'), url.searchParams.get('pr'))));
    } catch (e) {
      const m = String(e && e.message);
      if (m === 'INVALID_REPO' || m === 'INVALID_PR') return send(400, { ok: false, error: m });
      throw e;
    }
  }
  if (pn === '/api/ship/approvals/revoke') {
    if (req.method !== 'POST') return send(405, { ok: false, error: 'METHOD_NOT_ALLOWED' });
    const reject = (status, error) => {
      if (typeof ctx.onReject === 'function') ctx.onReject({ status, error });
      return send(status, { ok: false, error });
    };
    const chk = ctx.checkStrict(req);
    if (!chk.ok) return reject(chk.status, chk.error);
    const auth = await ctx.authEmail(req);
    if (!auth.ok) return reject(auth.status || 403, auth.error || 'SHIP_AUTH_FAILED');
    const b = await ctx.readBody(req);
    if (!b.ok) return send(400, { ok: false, error: b.error });
    const r = revokeApproval(b.value, auth.email);
    return send(r.status, r.body);
  }
  return send(404, { ok: false, error: 'NOT_FOUND' });
}

module.exports = {
  handle, overview, listRuns, prDetail, auditTail, revokeApproval, approvalValidity, approveCommand,
  scrubPaths, ACTIONS_NOTE, ENFORCEMENT_NOTE, NO_APPROVE_NOTE,
};
