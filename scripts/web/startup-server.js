#!/usr/bin/env node
/**
 * startup-server.js — ClaudeOS Web スタートアップコンソール
 *
 * bin/menu.sh (L1 / T1 / S1 / 全適用 / セッション停止) をブラウザから操作するための
 * 薄い Web 層。Claude 起動の実体は既存 CLI をそのまま呼ぶ:
 *
 *   起動      → bash bin/start-claude.sh --project P --foreground|--team|--background ...
 *   停止      → bash bin/autonomy.sh stop <project> [--now]
 *   全適用    → bash bin/autonomy.sh start --all --dry-run → (人間確認) → --yes
 *   状態      → bash libexec/startup-state.sh  (read-only スナップショット)
 *
 * 設計原則 (CLAUDE.md / AGENTS.md に準拠):
 *   - 判定・起動ロジックを再実装しない。CLI が唯一の実行正本 (二重実装の回避)。
 *   - 変更系操作は必ず「計画 (--dry-run) → 人間確認 → 実行」の 2 段階。confirm 無しの
 *     POST は実行せず dry-run 計画だけを返す (Human Gate)。
 *   - 実行対象は config から列挙した既存プロジェクトのみ (任意コマンド実行は不可)。
 *   - 依存ゼロ (Node 組み込みのみ)。
 *
 * 使い方:
 *   node scripts/web/startup-server.js [--port 3740] [--host 127.0.0.1] [--lan]
 *                                      [--root <repo>] [--dry-run-only] [--allow-no-auth]
 *   npm run start:web
 *
 * 認証: STARTUP_WEB_PASSWORD (無ければ DASHBOARD_PASSWORD) を設定すると Basic 認証必須。
 *       loopback 以外へ bind する場合はパスワード必須 (fail-closed)。
 */

'use strict';

const http   = require('http');
const fs     = require('fs');
const path   = require('path');
const os     = require('os');
const crypto = require('crypto');
const { spawn } = require('child_process');

const DEFAULT_PORT = 3740;
const REPO_ROOT    = path.resolve(__dirname, '..', '..');
const PUBLIC_DIR   = path.join(__dirname, 'public');
const CLAUDEOS_HOME = process.env.CLAUDEOS_HOME || path.join(os.homedir(), '.claudeos');
const AUDIT_LOG    = path.join(CLAUDEOS_HOME, 'logs', 'web-startup-audit.log');
const BODY_LIMIT   = 64 * 1024;
const INTENT_LIMIT = 2000;

const MODES = ['foreground', 'team', 'background'];
const MODE_LABELS = {
  foreground: '🖥️ フォアグラウンド (デスクトップ端末)',
  team:       '👥 4役割一括 (tmux 4分割)',
  background: '🌙 バックグラウンド自律 (Supervisor)',
};

// ---------------------------------------------------------------------------
// 純関数 (テスト対象)
// ---------------------------------------------------------------------------

/** safeEqual — 定数時間比較 (パスワード/トークン) */
function safeEqual(a, b) {
  const ab = Buffer.from(String(a));
  const bb = Buffer.from(String(b));
  if (ab.length !== bb.length) return false;
  return crypto.timingSafeEqual(ab, bb);
}

/** isLoopback — ループバック bind かどうか */
function isLoopback(host) {
  return ['127.0.0.1', '::1', 'localhost'].includes(String(host));
}

/**
 * validateProject — プロジェクト名の検証。
 *   config から列挙した allowed に完全一致する場合のみ許可する (allowlist)。
 *   パス操作・シェル解釈に関わる文字はここで全て落ちる。
 */
function validateProject(name, allowed) {
  if (typeof name !== 'string' || name.length === 0 || name.length > 200) {
    return { ok: false, error: 'PROJECT_INVALID' };
  }
  if (/[\0\n\r\t]/.test(name) || name.startsWith('-') || name.includes('..')) {
    return { ok: false, error: 'PROJECT_INVALID' };
  }
  if (!Array.isArray(allowed) || !allowed.includes(name)) {
    return { ok: false, error: 'PROJECT_NOT_REGISTERED' };
  }
  return { ok: true, value: name };
}

/** validateMode — 起動モードの検証 */
function validateMode(mode) {
  if (!MODES.includes(mode)) return { ok: false, error: 'MODE_INVALID' };
  return { ok: true, value: mode };
}

/** validateGoal — auto または Router が定義する Goal 名のみ許可 */
function validateGoal(goal, goals) {
  if (goal === undefined || goal === null || goal === '' || goal === 'auto') {
    return { ok: true, value: '' };            // 空 = 自動判定 (CLI 既定と同じ)
  }
  const pool = []
    .concat((goals && goals.primary) || [])
    .concat((goals && goals.specialized) || [])
    .map(g => (typeof g === 'string' ? g : g.name));
  if (!pool.includes(goal)) return { ok: false, error: 'GOAL_INVALID' };
  return { ok: true, value: goal };
}

/** sanitizeIntent — 要求テキストの正規化 (改行除去・長さ上限・制御文字除去) */
function sanitizeIntent(intent) {
  if (intent === undefined || intent === null) return '';
  let s = String(intent).replace(/[\0-\x08\x0b\x0c\x0e-\x1f\x7f]/g, ' ');
  s = s.replace(/[\r\n\t]+/g, ' ').replace(/\s{2,}/g, ' ').trim();
  return s.slice(0, INTENT_LIMIT);
}

/**
 * validateDuration — 分数の検証。CLI (bin/start-claude.sh) と同じ制約を先に弾く。
 *   foreground / team: 0 (無制限) 可、上限なし
 *   background:        1..max_session_minutes
 */
function validateDuration(duration, mode, limits) {
  const lim = limits || {};
  const maxMin = Number.isInteger(lim.max_session_minutes) ? lim.max_session_minutes : 300;
  const defBg  = Number.isInteger(lim.default_session_minutes) ? lim.default_session_minutes : 300;
  const defFg  = Number.isInteger(lim.foreground_minutes) ? lim.foreground_minutes : 0;
  let n = duration;
  if (n === undefined || n === null || n === '') return { ok: true, value: mode === 'background' ? defBg : defFg };
  n = Number(n);
  if (!Number.isInteger(n) || n < 0) return { ok: false, error: 'DURATION_INVALID' };
  if (mode === 'background') {
    if (n === 0) return { ok: false, error: 'DURATION_UNLIMITED_BACKGROUND' };
    if (maxMin > 0 && n > maxMin) return { ok: false, error: 'DURATION_OVER_LIMIT' };
  }
  return { ok: true, value: n };
}

/** buildLaunchArgs — bin/start-claude.sh の引数組み立て (順序は CLI の期待どおり) */
function buildLaunchArgs(o) {
  const args = ['--project', o.project, '--' + o.mode];
  if (o.goal) args.push('--goal', o.goal);
  if (o.intent) args.push('--intent', o.intent);
  if (o.duration !== undefined && o.duration !== null) args.push('--duration', String(o.duration));
  if (o.dryRun) args.push('--dry-run');
  return args;
}

/** buildStopArgs — bin/autonomy.sh の引数組み立て */
function buildStopArgs(o) {
  const args = ['stop', o.all ? '--all' : o.project];
  if (o.force) args.push('--now');
  return args;
}

/** buildApplyAllArgs — 全適用。dryRun=true は計画のみ (AGENTS.md: 必ず --dry-run 先行) */
function buildApplyAllArgs(o) {
  const args = ['start', '--all'];
  if (o.duration !== undefined && o.duration !== null) args.push('--duration', String(o.duration));
  if (o.dryRun) args.push('--dry-run'); else args.push('--yes');
  return args;
}

/** parseState — libexec/startup-state.sh の出力検証 (壊れた出力で UI を壊さない) */
function parseState(text) {
  let data;
  try { data = JSON.parse(text); } catch { return { ok: false, error: 'STATE_PARSE' }; }
  if (!data || typeof data !== 'object' || !Array.isArray(data.projects)) {
    return { ok: false, error: 'STATE_SHAPE' };
  }
  return { ok: true, value: data };
}

/** projectNames — state から allowlist を作る */
function projectNames(state) {
  return ((state && state.projects) || []).map(p => p.name);
}

/** resolveLogFile — ログ閲覧のパス検証 (~/.claudeos 配下のみ) */
function resolveLogFile(filePath) {
  if (typeof filePath !== 'string' || filePath === '') return null;
  const base = path.resolve(CLAUDEOS_HOME);
  const full = path.resolve(filePath);
  if (full !== base && !full.startsWith(base + path.sep)) return null;
  return full;
}

/** tailLines — ファイル末尾 N 行 (存在しなければ空文字)。末尾改行は含めない。 */
function tailLines(filePath, lines) {
  const n = Number.isInteger(lines) && lines > 0 ? Math.min(lines, 2000) : 200;
  try {
    const text = fs.readFileSync(filePath, 'utf8');
    const arr = text.split('\n');
    if (arr.length && arr[arr.length - 1] === '') arr.pop();   // 末尾改行の空要素を落とす
    return arr.slice(Math.max(0, arr.length - n)).join('\n');
  } catch {
    return '';
  }
}

/**
 * resolveStaticPath — ディレクトリトラバーサル防止 (public 配下のみ)。
 *   percent-encoding (%2e%2e%2f 等) を復号してから検証する。
 */
function resolveStaticPath(urlPath) {
  const clean = String(urlPath).split('?')[0];
  let decoded;
  try { decoded = decodeURIComponent(clean); } catch { return null; }
  const rel = decoded === '/' ? 'index.html' : decoded.replace(/^\/+/, '');
  if (rel.split('/').some(seg => seg === '..')) return null;
  const full = path.resolve(PUBLIC_DIR, rel);
  if (full !== PUBLIC_DIR && !full.startsWith(PUBLIC_DIR + path.sep)) return null;
  return full;
}

/** checkBasicAuth — Basic 認証 (authPass 未設定なら素通し) */
function checkBasicAuth(header, user, pass) {
  if (!pass) return true;
  if (typeof header !== 'string' || !header.startsWith('Basic ')) return false;
  const decoded = Buffer.from(header.slice(6), 'base64').toString('utf8');
  const colon = decoded.indexOf(':');
  if (colon === -1) return false;
  return safeEqual(decoded.slice(0, colon), user) && safeEqual(decoded.slice(colon + 1), pass);
}

/** checkOrigin — 変更系リクエストの Origin 検証 (他サイトからの CSRF 起動を防ぐ) */
function checkOrigin(origin, hostHeader) {
  if (!origin) return true;                       // 同一オリジンの fetch は Origin を付けない場合がある
  let u;
  try { u = new URL(origin); } catch { return false; }
  if (!hostHeader) return false;
  return u.host === hostHeader;
}

/** auditLine — 監査ログ 1 行 (JSON Lines) */
function auditLine(entry) {
  return JSON.stringify(Object.assign({ ts: new Date().toISOString() }, entry));
}

// ---------------------------------------------------------------------------
// 実行ヘルパ
// ---------------------------------------------------------------------------

/** runScript — 子プロセス実行 (完了待ち)。stdout/stderr を返す */
function runScript(script, args, opts) {
  const o = opts || {};
  return new Promise((resolve) => {
    const child = spawn('bash', [script].concat(args), {
      cwd: o.cwd || REPO_ROOT,
      env: o.env || process.env,
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    let out = '', err = '';
    let done = false;
    const timer = setTimeout(() => {
      if (done) return;
      done = true;
      try { child.kill('SIGKILL'); } catch { /* noop */ }
      resolve({ exitCode: 124, stdout: out, stderr: err + '\n(timeout)' });
    }, o.timeoutMs || 180000);
    child.stdout.on('data', d => { out += d; });
    child.stderr.on('data', d => { err += d; });
    child.on('error', e => {
      if (done) return; done = true; clearTimeout(timer);
      resolve({ exitCode: 127, stdout: out, stderr: String(e.message) });
    });
    child.on('close', code => {
      if (done) return; done = true; clearTimeout(timer);
      resolve({ exitCode: code === null ? 1 : code, stdout: out, stderr: err });
    });
  });
}

/** startDetached — 切り離して起動 (HTTP 応答を塞がない)。起動できたことだけ返す */
function startDetached(script, args, opts) {
  const o = opts || {};
  const child = spawn('bash', [script].concat(args), {
    cwd: o.cwd || REPO_ROOT,
    env: o.env || process.env,
    detached: true,
    stdio: 'ignore',
  });
  child.unref();
  return { pid: child.pid };
}

function appendAudit(entry) {
  try {
    fs.mkdirSync(path.dirname(AUDIT_LOG), { recursive: true });
    fs.appendFileSync(AUDIT_LOG, auditLine(entry) + '\n');
  } catch { /* 監査ログ失敗で操作は止めない (記録は best-effort) */ }
}

// ---------------------------------------------------------------------------
// サーバ本体
// ---------------------------------------------------------------------------

function createServer(cfg) {
  const conf = Object.assign({
    root: REPO_ROOT,
    port: DEFAULT_PORT,
    host: '127.0.0.1',
    authUser: 'claudeos',
    authPass: process.env.STARTUP_WEB_PASSWORD || process.env.DASHBOARD_PASSWORD || '',
    dryRunOnly: process.env.STARTUP_WEB_DRY_RUN_ONLY === '1',
    stateTimeoutMs: 30000,
    planTimeoutMs: 120000,
  }, cfg || {});

  const BIN_START = path.join(conf.root, 'bin', 'start-claude.sh');
  const BIN_AUTONOMY = path.join(conf.root, 'bin', 'autonomy.sh');
  const LIBEXEC_STATE = path.join(conf.root, 'libexec', 'startup-state.sh');

  // 変更系操作は同時 1 件 (レースで同じプロジェクトを二重起動しない)
  let busy = false;

  async function getState() {
    const r = await runScript(LIBEXEC_STATE, [], { cwd: conf.root, timeoutMs: conf.stateTimeoutMs });
    if (r.exitCode !== 0) return { ok: false, error: 'STATE_EXEC', stderr: r.stderr };
    return parseState(r.stdout);
  }

  function json(res, code, obj) {
    const body = JSON.stringify(obj);
    res.writeHead(code, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' });
    res.end(body);
  }

  function readBody(req) {
    return new Promise((resolve) => {
      let size = 0, buf = '';
      req.on('data', chunk => {
        size += chunk.length;
        if (size > BODY_LIMIT) { resolve({ ok: false, error: 'BODY_TOO_LARGE' }); req.destroy(); return; }
        buf += chunk;
      });
      req.on('end', () => {
        if (!buf) return resolve({ ok: true, value: {} });
        try { resolve({ ok: true, value: JSON.parse(buf) }); }
        catch { resolve({ ok: false, error: 'BODY_INVALID_JSON' }); }
      });
      req.on('error', () => resolve({ ok: false, error: 'BODY_READ' }));
    });
  }

  /** resolveContext — state から allowlist / goals / limits を取り出す */
  async function resolveContext() {
    const st = await getState();
    if (!st.ok) return st;
    return {
      ok: true,
      state: st.value,
      allowed: projectNames(st.value),
      goals: st.value.goals || { primary: [], specialized: [] },
      limits: st.value.limits || {},
    };
  }

  /** validateLaunchRequest — plan / launch 共通の入力検証 */
  function validateLaunchRequest(body, ctx) {
    const proj = validateProject(body.project, ctx.allowed);
    if (!proj.ok) return proj;
    const mode = validateMode(body.mode);
    if (!mode.ok) return mode;
    const goal = validateGoal(body.goal, ctx.goals);
    if (!goal.ok) return goal;
    const dur = validateDuration(body.duration, mode.value, ctx.limits);
    if (!dur.ok) return dur;
    return {
      ok: true,
      value: {
        project: proj.value,
        mode: mode.value,
        goal: goal.value,
        intent: sanitizeIntent(body.intent),
        duration: dur.value,
      },
    };
  }

  /** handlePlan — 起動計画のみ (--dry-run)。実行しない */
  async function handlePlan(res, body, remote) {
    const ctx = await resolveContext();
    if (!ctx.ok) return json(res, 500, { ok: false, error: ctx.error, detail: ctx.stderr || '' });
    const v = validateLaunchRequest(body, ctx);
    if (!v.ok) return json(res, 400, { ok: false, error: v.error });
    const args = buildLaunchArgs(Object.assign({ dryRun: true }, v.value));
    const r = await runScript(BIN_START, args, { cwd: conf.root, timeoutMs: conf.planTimeoutMs });
    appendAudit({ action: 'plan', project: v.value.project, mode: v.value.mode, goal: v.value.goal,
                  exit: r.exitCode, remote });
    const maxSessions = Number.isInteger(ctx.limits.max_sessions) ? ctx.limits.max_sessions : 4;
    return json(res, 200, {
      ok: r.exitCode === 0, exitCode: r.exitCode, args,
      modeLabel: MODE_LABELS[v.value.mode],
      capacity: { running: ctx.state.sessions.count, max: maxSessions },
      plan: r.stdout, stderr: r.stderr,
    });
  }

  /** handleLaunch — confirm=true で初めて実起動する (Human Gate) */
  async function handleLaunch(res, body, remote) {
    const ctx = await resolveContext();
    if (!ctx.ok) return json(res, 500, { ok: false, error: ctx.error, detail: ctx.stderr || '' });
    const v = validateLaunchRequest(body, ctx);
    if (!v.ok) return json(res, 400, { ok: false, error: v.error });

    // 同時実行上限 (CLI 側 session__enforce_launch_limits と同じ既定) を先に可視化
    const maxSessions = Number.isInteger(ctx.limits.max_sessions) ? ctx.limits.max_sessions : 4;
    const running = ctx.state.sessions.count;

    if (body.confirm !== true || conf.dryRunOnly) {
      const args = buildLaunchArgs(Object.assign({ dryRun: true }, v.value));
      const r = await runScript(BIN_START, args, { cwd: conf.root, timeoutMs: conf.planTimeoutMs });
      appendAudit({ action: 'launch-plan', project: v.value.project, mode: v.value.mode,
                    goal: v.value.goal, exit: r.exitCode, remote,
                    dryRunOnly: conf.dryRunOnly });
      return json(res, 200, {
        ok: r.exitCode === 0,
        requiresConfirm: true,
        dryRunOnly: conf.dryRunOnly,
        exitCode: r.exitCode, args,
        modeLabel: MODE_LABELS[v.value.mode],
        plan: r.stdout, stderr: r.stderr,
        capacity: { running, max: maxSessions },
      });
    }

    if (busy) return json(res, 409, { ok: false, error: 'OPERATION_IN_PROGRESS' });
    busy = true;
    try {
      const args = buildLaunchArgs(v.value);
      const r = startDetached(BIN_START, args, { cwd: conf.root });
      appendAudit({ action: 'launch', project: v.value.project, mode: v.value.mode,
                    goal: v.value.goal, pid: r.pid, remote });
      return json(res, 200, {
        ok: true, started: true, pid: r.pid, args,
        modeLabel: MODE_LABELS[v.value.mode],
        log: (ctx.state.projects.find(p => p.name === v.value.project) || {}).log_file || '',
        capacity: { running, max: maxSessions },
      });
    } finally {
      busy = false;
    }
  }

  /** handleStop — Session 停止。--now (force) は確認必須 */
  async function handleStop(res, body, remote) {
    const ctx = await resolveContext();
    if (!ctx.ok) return json(res, 500, { ok: false, error: ctx.error, detail: ctx.stderr || '' });
    if (body.all === true) {
      if (body.confirm !== true || conf.dryRunOnly) {
        return json(res, 200, { ok: true, requiresConfirm: true, plan: 'autonomy.sh stop --all を実行します。', args: buildStopArgs({ all: true, force: !!body.force }) });
      }
    } else {
      const proj = validateProject(body.project, ctx.allowed);
      if (!proj.ok) return json(res, 400, { ok: false, error: proj.error });
      const target = ctx.state.projects.find(p => p.name === proj.value) || {};
      if (!target.running) return json(res, 409, { ok: false, error: 'NOT_RUNNING' });
      if (body.confirm !== true || conf.dryRunOnly) {
        return json(res, 200, {
          ok: true, requiresConfirm: true, dryRunOnly: conf.dryRunOnly,
          plan: `autonomy.sh stop ${proj.value}${body.force ? ' --now' : ''} を実行します。`,
          args: buildStopArgs({ project: proj.value, force: !!body.force }),
        });
      }
    }
    if (busy) return json(res, 409, { ok: false, error: 'OPERATION_IN_PROGRESS' });
    busy = true;
    try {
      const o = body.all === true ? { all: true, force: !!body.force } : { project: body.project, force: !!body.force };
      const args = buildStopArgs(o);
      const r = await runScript(BIN_AUTONOMY, args, { cwd: conf.root, timeoutMs: conf.planTimeoutMs });
      appendAudit({ action: 'stop', project: body.all ? '--all' : body.project, force: !!body.force,
                    exit: r.exitCode, remote });
      return json(res, 200, { ok: r.exitCode === 0, exitCode: r.exitCode, args, output: r.stdout, stderr: r.stderr });
    } finally {
      busy = false;
    }
  }

  /** handleApplyAll — Supervisor 全適用。計画 (dry-run) → confirm で --yes */
  async function handleApplyAll(res, body, remote) {
    if (busy) return json(res, 409, { ok: false, error: 'OPERATION_IN_PROGRESS' });
    const dryArgs = buildApplyAllArgs({ dryRun: true, duration: body.duration });
    busy = true;
    try {
      const dry = await runScript(BIN_AUTONOMY, dryArgs, { cwd: conf.root, timeoutMs: conf.planTimeoutMs });
      if (body.confirm !== true || conf.dryRunOnly) {
        appendAudit({ action: 'apply-all-plan', exit: dry.exitCode, remote });
        return json(res, 200, {
          ok: dry.exitCode === 0, requiresConfirm: true, dryRunOnly: conf.dryRunOnly,
          exitCode: dry.exitCode, plan: dry.stdout, stderr: dry.stderr, args: dryArgs,
        });
      }
      const args = buildApplyAllArgs({ dryRun: false, duration: body.duration });
      const r = startDetached(BIN_AUTONOMY, args, { cwd: conf.root });
      appendAudit({ action: 'apply-all', pid: r.pid, remote, dryExit: dry.exitCode });
      return json(res, 200, { ok: true, started: true, pid: r.pid, args, plan: dry.stdout });
    } finally {
      busy = false;
    }
  }

  /** handleLog — ログ閲覧 (~/.claudeos 配下のみ) */
  async function handleLog(req, res, url) {
    const ctx = await resolveContext();
    if (!ctx.ok) return json(res, 500, { ok: false, error: ctx.error });
    const name = url.searchParams.get('project');
    const proj = validateProject(name, ctx.allowed);
    if (!proj.ok) return json(res, 400, { ok: false, error: proj.error });
    const target = ctx.state.projects.find(p => p.name === proj.value) || {};
    const file = resolveLogFile(target.log_file);
    if (!file) return json(res, 404, { ok: false, error: 'LOG_NOT_FOUND' });
    const lines = parseInt(url.searchParams.get('lines') || '200', 10);
    return json(res, 200, {
      ok: true, file, lines,
      content: tailLines(file, lines),
    });
  }

  const server = http.createServer(async (req, res) => {
    const url = new URL(req.url, 'http://' + (req.headers.host || 'localhost'));
    const pn = url.pathname;
    const remote = (req.socket && req.socket.remoteAddress) || '?';

    if (pn === '/api/health') {
      return json(res, 200, { ok: true, service: 'claudeos-web-startup', dryRunOnly: conf.dryRunOnly });
    }

    if (!checkBasicAuth(req.headers['authorization'], conf.authUser, conf.authPass)) {
      res.writeHead(401, { 'WWW-Authenticate': 'Basic realm="ClaudeOS Web Startup"', 'Content-Type': 'text/plain; charset=utf-8' });
      return res.end('401 Unauthorized');
    }

    if (req.method !== 'GET' && req.method !== 'HEAD') {
      if (!checkOrigin(req.headers.origin, req.headers.host)) {
        return json(res, 403, { ok: false, error: 'ORIGIN_REJECTED' });
      }
    }

    try {
      if (pn === '/api/startup/state' && req.method === 'GET') {
        const ctx = await resolveContext();
        if (!ctx.ok) return json(res, 500, { ok: false, error: ctx.error, detail: ctx.stderr || '' });
        return json(res, 200, {
          ok: true, state: ctx.state,
          server: {
            dryRunOnly: conf.dryRunOnly,
            authRequired: !!conf.authPass,
            host: conf.host, port: conf.port,
            modes: MODES.map(m => ({ id: m, label: MODE_LABELS[m] })),
            capabilities: {
              tmux: !!process.env.TMUX_BIN || true,
              desktopTerminal: !!(process.env.DISPLAY || process.env.WAYLAND_DISPLAY),
            },
          },
        });
      }

      if (pn === '/api/startup/log' && req.method === 'GET') return handleLog(req, res, url);

      if (req.method === 'POST' && pn === '/api/startup/plan') {
        const b = await readBody(req);
        if (!b.ok) return json(res, 400, { ok: false, error: b.error });
        return handlePlan(res, b.value, remote);
      }
      if (req.method === 'POST' && pn === '/api/startup/launch') {
        const b = await readBody(req);
        if (!b.ok) return json(res, 400, { ok: false, error: b.error });
        return handleLaunch(res, b.value, remote);
      }
      if (req.method === 'POST' && pn === '/api/startup/stop') {
        const b = await readBody(req);
        if (!b.ok) return json(res, 400, { ok: false, error: b.error });
        return handleStop(res, b.value, remote);
      }
      if (req.method === 'POST' && pn === '/api/startup/apply-all') {
        const b = await readBody(req);
        if (!b.ok) return json(res, 400, { ok: false, error: b.error });
        return handleApplyAll(res, b.value, remote);
      }

      if (req.method === 'GET' || req.method === 'HEAD') {
        const file = resolveStaticPath(pn);
        if (!file) { res.writeHead(404); return res.end('404'); }
        return fs.readFile(file, (e, data) => {
          if (e) { res.writeHead(404); return res.end('404'); }
          res.writeHead(200, { 'Content-Type': contentType(file), 'Cache-Control': 'no-store' });
          res.end(req.method === 'HEAD' ? undefined : data);
        });
      }

      return json(res, 404, { ok: false, error: 'NOT_FOUND' });
    } catch (e) {
      return json(res, 500, { ok: false, error: 'INTERNAL', detail: String(e && e.message) });
    }
  });

  return server;
}

function contentType(file) {
  const ext = path.extname(file);
  return ({
    '.html': 'text/html; charset=utf-8',
    '.js':   'application/javascript; charset=utf-8',
    '.css':  'text/css; charset=utf-8',
    '.svg':  'image/svg+xml',
    '.json': 'application/json; charset=utf-8',
  })[ext] || 'application/octet-stream';
}

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------

function parseArgs(argv) {
  const o = { port: DEFAULT_PORT, host: '127.0.0.1', root: REPO_ROOT, lan: false,
              allowNoAuth: false, dryRunOnly: false, help: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--port') o.port = parseInt(argv[++i], 10);
    else if (a === '--host') o.host = argv[++i];
    else if (a === '--lan') { o.lan = true; o.host = '0.0.0.0'; }
    else if (a === '--root') o.root = path.resolve(argv[++i]);
    else if (a === '--dry-run-only') o.dryRunOnly = true;
    else if (a === '--allow-no-auth') o.allowNoAuth = true;
    else if (a === '--help' || a === '-h') o.help = true;
    else if (/^\d+$/.test(a)) o.port = parseInt(a, 10);
  }
  return o;
}

function usage() {
  return [
    'ClaudeOS Web スタートアップコンソール (bin/menu.sh の Web 版)',
    '',
    '  node scripts/web/startup-server.js [options]',
    '',
    '  --port <n>        待ち受けポート (既定 3740)',
    '  --host <addr>     bind アドレス (既定 127.0.0.1)',
    '  --lan             0.0.0.0 で待ち受け (要 STARTUP_WEB_PASSWORD)',
    '  --root <dir>      リポジトリルート (テスト用)',
    '  --dry-run-only    起動系操作は常に --dry-run (実起動しない)',
    '  --allow-no-auth   loopback 以外でもパスワード無しを許可 (非推奨)',
    '  -h, --help        このヘルプ',
    '',
    '  認証: STARTUP_WEB_PASSWORD (無ければ DASHBOARD_PASSWORD) で Basic 認証。',
    '  ユーザ名は STARTUP_WEB_USER (既定 claudeos)。',
  ].join('\n');
}

function main() {
  const o = parseArgs(process.argv.slice(2));
  if (o.help) { process.stdout.write(usage() + '\n'); return; }

  const authPass = process.env.STARTUP_WEB_PASSWORD || process.env.DASHBOARD_PASSWORD || '';
  if (!isLoopback(o.host) && !authPass && !o.allowNoAuth) {
    process.stderr.write(
      '❌ 非ループバック (' + o.host + ') へ bind するには STARTUP_WEB_PASSWORD が必要です。\n' +
      '   これは Claude 起動操作をネットワークへ露出させるためです (fail-closed)。\n');
    process.exit(2);
  }

  const server = createServer({
    root: o.root, port: o.port, host: o.host,
    authUser: process.env.STARTUP_WEB_USER || 'claudeos',
    authPass, dryRunOnly: o.dryRunOnly,
  });

  server.listen(o.port, o.host, () => {
    const shown = isLoopback(o.host) ? 'http://localhost:' + o.port : 'http://' + o.host + ':' + o.port;
    process.stdout.write('🌐 ClaudeOS Web スタートアップコンソール: ' + shown + '\n');
    process.stdout.write('   root=' + o.root + ' auth=' + (authPass ? 'required' : 'off') +
      ' dryRunOnly=' + o.dryRunOnly + '\n');
  });

  const shutdown = () => { server.close(() => process.exit(0)); setTimeout(() => process.exit(0), 2000); };
  process.on('SIGTERM', shutdown);
  process.on('SIGINT', shutdown);
}

module.exports = {
  createServer, parseArgs, usage, main,
  safeEqual, isLoopback, validateProject, validateMode, validateGoal, validateDuration,
  sanitizeIntent, buildLaunchArgs, buildStopArgs, buildApplyAllArgs, parseState,
  projectNames, resolveLogFile, resolveStaticPath, tailLines, checkBasicAuth, checkOrigin,
  auditLine, MODES, MODE_LABELS, DEFAULT_PORT,
};

if (require.main === module) main();
