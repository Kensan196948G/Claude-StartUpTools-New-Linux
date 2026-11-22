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
 *   allowed (config 登録 + projectsDir 配下の実在フォルダ) に完全一致する場合のみ許可する。
 *   パス操作・シェル解釈に関わる文字はここで全て落ちる (allowed の中身が広がっても、
 *   `..`・改行・先頭 `-` はここで拒否される)。
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
  // Web には TTY が無い。foreground を素で起動すると TUI が端末を得られず即座に落ち、
  // ブラウザターミナルからも見えない。tmux を介して起動し CLI 端末から attach できるようにする。
  if (o.mode === 'foreground') args.push('--tmux');
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
  // Web には TTY が無い。stop --all は非対話で --yes が必須 (Human Gate は confirm で通過済み)。
  if (o.all) args.push('--yes');
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

/**
 * projectNames — state から allowlist を作る。
 *   config 登録済み (projects) に加えて、projectsDir 配下に実在する全フォルダ
 *   (all_folders) を含める。Web UI / ブラウザターミナルから「フォルダ以下すべて」を
 *   起動対象にできるようにするためで、パス操作・シェル解釈の拒否は validateProject 側に残る。
 */
function projectNames(state) {
  const names = ((state && state.projects) || []).map(p => p.name);
  const extra = (state && Array.isArray(state.all_folders)) ? state.all_folders : [];
  return Array.from(new Set([...names, ...extra]));
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
/**
 * runCmd — 外部コマンドを shell を介さず 1 回だけ実行する (読み取り専用 API 用)。
 * 引数は配列で渡し、文字列連結によるシェル解釈を起こさない。上限時間で SIGKILL する。
 */
function runCmd(cmd, args, opts) {
  const o = opts || {};
  return new Promise((resolve) => {
    let out = '', err = '', done = false;
    let child;
    try {
      child = spawn(cmd, args, { cwd: o.cwd || REPO_ROOT, stdio: ['ignore', 'pipe', 'pipe'] });
    } catch (e) {
      return resolve({ exitCode: 127, stdout: '', stderr: String(e && e.message) });
    }
    const timer = setTimeout(() => {
      if (done) return;
      done = true;
      try { child.kill('SIGKILL'); } catch { /* noop */ }
      resolve({ exitCode: 124, stdout: out, stderr: err + '\n(timeout)' });
    }, o.timeoutMs || 8000);
    child.stdout.on('data', d => { out += d; });
    child.stderr.on('data', d => { err += d; });
    child.on('error', e => {
      if (done) return; done = true; clearTimeout(timer);
      resolve({ exitCode: 127, stdout: out, stderr: err + '\n' + String(e && e.message) });
    });
    child.on('close', code => {
      if (done) return; done = true; clearTimeout(timer);
      resolve({ exitCode: code, stdout: out, stderr: err });
    });
  });
}

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

/**
 * runDetached — 切り離し起動しつつ、CLI の終了コードと出力を短時間だけ待って回収する。
 *   目的: 起動 CLI が即時失敗した場合に started:true を返さない (QA BUG-05)。
 *   Web から起動する CLI は tmux/supervisor を用意して戻るため、通常は数秒で終了する。
 *   時間内に終わらなければ timedOut:true を返し、プロセスは殺さない (起動は継続)。
 */
function runDetached(script, args, opts) {
  const o = opts || {};
  return new Promise((resolve) => {
    const child = spawn('bash', [script].concat(args), {
      cwd: o.cwd || REPO_ROOT,
      env: o.env || process.env,
      detached: true,
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    let out = '', err = '', done = false;
    const trim = s => (s.length > 8000 ? s.slice(-8000) : s);
    const finish = (r) => { if (done) return; done = true; clearTimeout(timer); resolve(r); };
    const timer = setTimeout(() => {
      try { child.unref(); } catch { /* 既に終了 */ }
      finish({ pid: child.pid, exitCode: null, timedOut: true, stdout: trim(out), stderr: trim(err) });
    }, o.waitMs || 15000);
    child.stdout.on('data', d => { out = trim(out + d); });
    child.stderr.on('data', d => { err = trim(err + d); });
    child.on('error', e => finish({ pid: child.pid, exitCode: -1, stdout: trim(out), stderr: String(e && e.message) }));
    child.on('exit', (code, signal) => finish({ pid: child.pid, exitCode: code, signal, stdout: trim(out), stderr: trim(err) }));
  });
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

  /**
   * state の短命キャッシュ。
   *   libexec/startup-state.sh は projectsDir 配下の全フォルダを走査するため、
   *   370 件規模では実測 12 秒前後かかる。UI は 15 秒ごとに取得するため、そのままでは
   *   常時 CPU を使い続ける。既定 20 秒だけ結果を使い回す (STARTUP_STATE_CACHE_MS で変更可)。
   *   走査 12 秒 > UI 周期 15 秒のため、TTL は走査時間より十分長く取る必要がある。
   *   起動・停止などの変更系の後は invalidateState() で必ず捨てる。
   */
  const STATE_CACHE_MS = Number(process.env.STARTUP_STATE_CACHE_MS || 20000);
  let stateCache = null;

  function invalidateState() { stateCache = null; }

  async function getState() {
    const now = Date.now();
    if (stateCache && (now - stateCache.at) < STATE_CACHE_MS) {
      return { ok: true, value: stateCache.value, cached: true };
    }
    const r = await runScript(LIBEXEC_STATE, [], { cwd: conf.root, timeoutMs: conf.stateTimeoutMs });
    if (r.exitCode !== 0) return { ok: false, error: 'STATE_EXEC', stderr: r.stderr };
    const parsed = parseState(r.stdout);
    if (parsed.ok) stateCache = { at: now, value: parsed.value };
    return parsed;
  }

  function json(res, code, obj) {
    const body = JSON.stringify(obj);
    res.writeHead(code, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' });
    res.end(body);
  }

  function readBody(req) {
    return new Promise((resolve) => {
      let size = 0, buf = '', done = false;
      const finish = (v) => { if (done) return; done = true; resolve(v); };
      req.on('data', chunk => {
        if (done) return;                       // 超過後は読み捨てる (接続は切らない)
        size += chunk.length;
        if (size > BODY_LIMIT) { finish({ ok: false, error: 'BODY_TOO_LARGE' }); return; }
        buf += chunk;
      });
      req.on('end', () => {
        if (!buf) return finish({ ok: true, value: {} });
        try { finish({ ok: true, value: JSON.parse(buf) }); }
        catch { finish({ ok: false, error: 'BODY_INVALID_JSON' }); }
      });
      req.on('error', () => finish({ ok: false, error: 'BODY_READ' }));
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
    invalidateState();
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
      invalidateState();
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
      const projectLog = (ctx.state.projects.find(p => p.name === v.value.project) || {}).log_file || '';
      // CLI の終了コードまで待つ。即時失敗を started:true と誤報しない (QA BUG-05)。
      const r = await runDetached(BIN_START, args, { cwd: conf.root, waitMs: 15000 });
      // 起動直後は state が古い (resolveContext が起動前の状態をキャッシュしている)。
      // ここで捨てないと 20 秒間 running=false のままになり、直後の停止が 409 NOT_RUNNING になる。
      invalidateState();
      if (r.timedOut || r.exitCode !== 0) {
        appendAudit({ action: 'launch-failed', project: v.value.project, mode: v.value.mode,
                      goal: v.value.goal, pid: r.pid, exitCode: r.exitCode, remote });
        return json(res, 200, {
          ok: false, started: false, error: r.timedOut ? 'START_TIMEOUT' : 'START_FAILED',
          exitCode: r.exitCode, pid: r.pid, args,
          log: projectLog, output: r.stdout, stderr: r.stderr,
        });
      }
      appendAudit({ action: 'launch', project: v.value.project, mode: v.value.mode,
                    goal: v.value.goal, pid: r.pid, remote });
      return json(res, 200, {
        ok: true, started: true, pid: r.pid, args,
        modeLabel: MODE_LABELS[v.value.mode],
        log: projectLog,
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
      invalidateState();
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
      invalidateState();
      if (body.confirm !== true || conf.dryRunOnly) {
        appendAudit({ action: 'apply-all-plan', exit: dry.exitCode, remote });
        return json(res, 200, {
          ok: dry.exitCode === 0, requiresConfirm: true, dryRunOnly: conf.dryRunOnly,
          exitCode: dry.exitCode, plan: dry.stdout, stderr: dry.stderr, args: dryArgs,
        });
      }
      if (dry.exitCode !== 0) {
        // dry-run が失敗した計画で実適用へ進まない (AGENTS.md: 計画を確認してから --yes)。
        // ここを素通りさせると、対象の検証に失敗したまま全プロジェクトへ適用してしまう (QA BUG-02)。
        appendAudit({ action: 'apply-all-blocked', exit: dry.exitCode, remote });
        return json(res, 200, {
          ok: false, error: 'PLAN_FAILED', exitCode: dry.exitCode,
          plan: dry.stdout, stderr: dry.stderr, args: dryArgs,
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

  /**
   * handleCronOps — crontab の内容を読むだけ (追加・削除はしない)。
   *   このサービスは NoNewPrivileges=yes で動くため crontab の setgid 昇格ができず、
   *   サービス文脈の `crontab -l` は失敗する。そこでユーザー文脈のタイマーが書く
   *   スナップショット ($CLAUDEOS_HOME/cron-snapshot.json) を優先して読む。
   *   スナップショットが無い/壊れている場合だけ、直接 crontab を試す。
   */
  async function handleCronOps(res) {
    const snapFile = path.join(CLAUDEOS_HOME, 'cron-snapshot.json');
    try {
      const snap = JSON.parse(fs.readFileSync(snapFile, 'utf8'));
      if (snap && snap.ok && Array.isArray(snap.entries)) {
        return json(res, 200, {
          ok: true, available: true, source: 'snapshot',
          generated_at: snap.generated_at || null,
          count: snap.entries.length, entries: snap.entries,
          note: 'ユーザータイマーが書いたスナップショット (NoNewPrivileges のため直接 crontab は読めない)',
        });
      }
    } catch { /* スナップショット無し: 下の直接取得へ */ }

    const r = await runCmd('crontab', ['-l'], { timeoutMs: 5000 });
    if (r.exitCode !== 0) {
      return json(res, 200, {
        ok: true, available: false, count: 0, entries: [],
        note: 'crontab を取得できません', stderr: String(r.stderr || '').slice(0, 300),
      });
    }
    const entries = [];
    r.stdout.split('\n').forEach((line) => {
      const t = line.trim();
      if (!t || t.startsWith('#') === false && t.indexOf('=') === 0) return;
      const disabled = t.startsWith('#');
      const body = disabled ? t.replace(/^#(?:DISABLED-\d+)?#?\s*/, '') : t;
      const m = /^(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(.+)$/.exec(body);
      if (!m) return;
      entries.push({
        disabled,
        schedule: [m[1], m[2], m[3], m[4], m[5]].join(' '),
        minute: m[1], hour: m[2], dom: m[3], month: m[4], dow: m[5],
        command: m[6].trim(),
      });
    });
    return json(res, 200, { ok: true, available: true, count: entries.length, entries });
  }

  /** handleSystemdOps — systemd --user のサービス状態を読むだけ */
  async function handleSystemdOps(res) {
    const r = await runCmd('systemctl',
      ['--user', 'list-units', '--type=service', '--all', '--no-legend', '--plain'],
      { timeoutMs: 8000 });
    if (r.exitCode !== 0) {
      return json(res, 200, {
        ok: true, available: false, count: 0, units: [],
        note: 'systemctl --user を実行できません', stderr: String(r.stderr || '').slice(0, 300),
      });
    }
    // enabled/disabled は list-unit-files から、実行コマンドは ExecStart から取る
    const ef = await runCmd('systemctl',
      ['--user', 'list-unit-files', '--type=service', '--no-legend', '--plain'],
      { timeoutMs: 8000 });
    const enabledMap = {};
    ef.stdout.split('\n').forEach((line) => {
      const f = line.trim().split(/\s+/);
      if (f[0]) enabledMap[f[0]] = f[1];
    });

    const units = [];
    const names = [];
    r.stdout.split('\n').forEach((line) => {
      const t = line.trim();
      if (!t || !/^claude/i.test(t)) return;   // このプロジェクトの unit のみ
      const f = t.split(/\s+/);
      names.push(f[0]);
      units.push({
        name: f[0], load: f[1], active: f[2], sub: f[3],
        description: f.slice(4).join(' '),
        enabled_file: enabledMap[f[0]] || 'unknown',
        enabled: enabledMap[f[0]] === 'enabled',
      });
    });

    // ExecStart を実値で埋める (件数はこのプロジェクトの unit のみ = 数件)
    await Promise.all(units.map(async (u) => {
      const sh = await runCmd('systemctl',
        ['--user', 'show', u.name, '-p', 'ExecStart', '--value'], { timeoutMs: 5000 });
      u.exec_start = sh.exitCode === 0 ? String(sh.stdout || '').trim().slice(0, 300) : '';
    }));

    return json(res, 200, { ok: true, available: true, count: units.length, units });
  }

  /* ---------------------------------------------------------------------
   * 診断・品質・DevOps・SecOps の読み取り専用 API
   *   「実行して結果を表示する」画面のため、許可したコマンドだけを実行する。
   *   任意コマンドは受け付けない (allowlist)。
   * ------------------------------------------------------------------- */

  /** 実行を許可する診断スクリプト (libexec/diag-*.sh)。名前は allowlist のキー。 */
  const DIAG_SCRIPTS = {
    'all-tools': 'diag-all-tools.sh',
    'architecture': 'diag-architecture.sh',
    'claude-compat': 'diag-claude-compat.sh',
    'control-plane': 'diag-control-plane.sh',
    'mcp-health': 'diag-mcp-health.sh',
    'mounts': 'diag-mounts.sh',
    'postgres': 'diag-postgres.sh',
    'worktree': 'diag-worktree.sh',
    'agent-teams': 'diag-agent-teams.sh',
  };

  /** handleDiagOps — ?name=<key> で許可された診断スクリプトを 1 つ実行する */
  async function handleDiagOps(res, url) {
    const name = String(url.searchParams.get('name') || 'all-tools');
    const script = DIAG_SCRIPTS[name];
    if (!script) {
      return json(res, 400, { ok: false, error: 'UNKNOWN_DIAG', allowed: Object.keys(DIAG_SCRIPTS) });
    }
    const r = await runScript(path.join('libexec', script), [], { cwd: conf.root, timeoutMs: 60000 });
    return json(res, 200, {
      ok: true, name, script: 'libexec/' + script,
      exitCode: r.exitCode, output: String(r.stdout || '') + String(r.stderr || ''),
    });
  }

  /**
   * release-check のバックグラウンドジョブ。
   *   実チェック (test/lint/build) は数分かかるため同期 HTTP では返さない。
   *   start でジョブを起こし、GET で状態と結果を返す (UI はポーリング)。
   *   同時に 1 ジョブだけ。二重起動は既存ジョブを返す。
   */
  let rcJob = null;

  /** release-check の出力行を QC のキーへ対応付ける (❌=NG / ✅=OK / ⏭️=SKIP) */
  function parseReleaseChecks(output) {
    const KEYS = [
      ['git_state', /git\s*worktree/i],
      ['readme', /readme/i],
      ['gitignore', /gitignore/i],
      ['test', /\btest\b/i],
      ['lint', /\blint\b/i],
      ['build', /\bbuild\b/i],
    ];
    const checks = {};
    String(output || '').split('\n').forEach((line) => {
      const mark = /❌/.test(line) ? 'NG' : (/✅/.test(line) ? 'OK' : (/⏭/.test(line) ? 'SKIP' : null));
      if (!mark) return;
      const hit = KEYS.find(([, re]) => re.test(line));
      if (!hit) return;
      if (checks[hit[0]]) return;                 // 最初の一致を採用
      checks[hit[0]] = { v: mark, d: line.replace(/^\s*[❌✅⏭]️?\s*/, '').trim().slice(0, 160) };
    });
    return checks;
  }

  /** handleReleaseCheckStart — ジョブを開始する (POST) */
  async function handleReleaseCheckStart(res, body) {
    const dry = !!(body && body.dry);
    if (rcJob && rcJob.status === 'running') {
      return json(res, 200, { ok: true, alreadyRunning: true, job: rcJob });
    }
    rcJob = { id: 'rc-' + Date.now().toString(36), mode: dry ? 'dry-run' : 'run',
              status: 'running', startedAt: new Date().toISOString(),
              finishedAt: null, exitCode: null, output: '', checks: {} };
    const job = rcJob;
    const args = dry ? ['--dry-run'] : [];
    runScript('bin/release-check.sh', args, { cwd: conf.root, timeoutMs: 600000 })
      .then((r) => {
        job.output = String(r.stdout || '') + String(r.stderr || '');
        job.exitCode = r.exitCode;
        job.checks = parseReleaseChecks(job.output);
        job.status = 'done';
        job.finishedAt = new Date().toISOString();
      })
      .catch((e) => {
        job.output = 'ジョブ実行に失敗: ' + String(e && e.message);
        job.status = 'done';
        job.exitCode = null;
        job.finishedAt = new Date().toISOString();
      });
    return json(res, 200, { ok: true, job });
  }

  /** handleReleaseCheckOps — 現在のジョブ状態 (GET, ポーリング用) */
  async function handleReleaseCheckOps(res) {
    if (!rcJob) {
      return json(res, 200, { ok: true, job: null, note: 'まだ実行していません。start で開始します。' });
    }
    return json(res, 200, { ok: true, job: rcJob });
  }

  /** handleDevopsOps — 実測できる読み取り専用の事実だけを返す */
  async function handleDevopsOps(res) {
    const [head, branch, timers, dbs] = await Promise.all([
      runCmd('git', ['-C', conf.root, 'rev-parse', '--short', 'HEAD'], { timeoutMs: 8000 }),
      runCmd('git', ['-C', conf.root, 'rev-parse', '--abbrev-ref', 'HEAD'], { timeoutMs: 8000 }),
      runCmd('systemctl', ['--user', 'list-timers', '--no-legend', '--plain'], { timeoutMs: 8000 }),
      runCmd('psql', ['-lqt'], { timeoutMs: 10000 }),
    ]);
    const timerLines = String(timers.stdout || '').split('\n').filter((l) => l.trim()).length;
    const dbLines = String(dbs.stdout || '').split('\n').map((l) => l.split('|')[0].trim()).filter(Boolean).length;
    return json(res, 200, {
      ok: true, available: true,
      release: { head: String(head.stdout || '').trim(), branch: String(branch.stdout || '').trim() },
      infra: { user_timers: timers.exitCode === 0 ? timerLines : null },
      data: { databases: dbs.exitCode === 0 ? dbLines : null },
      metrics: { node: process.version, uptime_s: Math.round(process.uptime()) },
      note: '読み取り専用。デプロイ・再起動・DB 変更は行わない。',
    });
  }

  /** handleSecopsOps — ツールの有無と直近レポートの有無だけを返す */
  async function handleSecopsOps(res) {
    const gl = await runCmd('gitleaks', ['version'], { timeoutMs: 5000 });
    const repoAudit = path.join(conf.root, 'reports', 'audit');
    let auditFiles = 0;
    try { auditFiles = fs.readdirSync(repoAudit).length; } catch { auditFiles = 0; }
    return json(res, 200, {
      ok: true, available: true,
      tools: {
        gitleaks: { present: gl.exitCode === 0, version: String(gl.stdout || '').trim().slice(0, 80) || null },
        audit_scan: { command: 'npm run audit:scan', present: true },
        supervisor_audit: { command: 'bash bin/supervisor-audit.sh report', present: fs.existsSync(path.join(conf.root, 'bin', 'supervisor-audit.sh')) },
        cmdb_scan: { command: 'npm run cmdb:scan', present: true },
      },
      reports: { audit_files: auditFiles },
      note: '実行はしていない (有無の確認のみ)。スキャン実行は API 未対応。',
    });
  }

  /**
   * handleManagedAgentsOps — Managed Agents の実状態を読むだけ。
   *   config/roster はリポジトリ、registry/ledger/decisions は ~/.claudeos/managed-agents。
   *   config が無い場合は available:false とし、他は読めた分だけ返す (嘘の 0 件を返さない)。
   */
  async function handleManagedAgentsOps(res) {
    const readJson = (p) => {
      try { return { ok: true, value: JSON.parse(fs.readFileSync(p, 'utf8')) }; }
      catch (e) { return { ok: false, error: String(e && e.code || e && e.message || e).slice(0, 120) }; }
    };
    const readJsonl = (p, limit) => {
      try {
        const lines = fs.readFileSync(p, 'utf8').split('\n').filter(Boolean);
        const rows = [];
        for (const l of lines) { try { rows.push(JSON.parse(l)); } catch { /* 壊れた行は捨てる */ } }
        return { ok: true, rows: rows.slice(-limit), total: rows.length };
      } catch (e) { return { ok: false, rows: [], total: 0, error: String(e && e.code || e).slice(0, 120) }; }
    };

    const stateDir = path.join(CLAUDEOS_HOME, 'managed-agents');
    const cfg = readJson(path.join(conf.root, 'config', 'managed-agents.json'));
    const roster = readJson(path.join(conf.root, 'config', 'managed-agents-roster.json'));
    const registry = readJson(path.join(stateDir, 'registry.json'));
    const ledger = readJsonl(path.join(stateDir, 'ledger.jsonl'), 2000);
    const decisions = readJsonl(path.join(stateDir, 'decisions.jsonl'), 2000);

    const now = new Date();
    const ym = now.toISOString().slice(0, 7);
    const ymd = now.toISOString().slice(0, 10);
    let monthCents = 0, todayCount = 0;
    ledger.rows.forEach((r) => {
      const ts = String(r.ts || '');
      if (r.type === 'reserve' || typeof r.cents === 'number') {
        if (ts.slice(0, 7) === ym && typeof r.cents === 'number') monthCents += r.cents;
      }
      if (ts.slice(0, 10) === ymd) todayCount += 1;
    });

    const log = ledger.rows.slice(-10).reverse().map((r) => ({
      t: String(r.ts || '').replace('T', ' ').slice(0, 19),
      role: r.role || '—',
      prompt: [r.type, r.task_id, r.task_class].filter(Boolean).join(' · ') || '—',
      result: (typeof r.cents === 'number' ? r.cents + '¢' : '—'),
    }));

    const registryAgents = (registry.ok && registry.value && registry.value.agents) ? Object.keys(registry.value.agents) : [];
    const rosterAgents = (roster.ok && roster.value && roster.value.agents) ? Object.keys(roster.value.agents) : [];

    return json(res, 200, {
      ok: true,
      available: !!(cfg.ok || roster.ok || registry.ok || ledger.ok),
      config: { available: cfg.ok, mode: cfg.ok ? (cfg.value.mode || cfg.value.managedMode || 'unknown') : null,
                note: cfg.ok ? null : 'config/managed-agents.json がありません' },
      roster: { available: roster.ok, count: rosterAgents.length, agents: rosterAgents },
      registry: { available: registry.ok, count: registryAgents.length, agents: registryAgents },
      usage: { month_cents: monthCents, today_count: todayCount,
               ledger_total: ledger.total, decisions_total: decisions.total },
      log,
    });
  }

  /**
   * handleAgentCatalogOps — SubAgent カタログ (config/agent-catalog.json) を読むだけ。
   *   first_class(常時配布) / catalog(必要時読込) / merge(統合) / remove_candidate(削除候補)
   *   をそのまま返し、件数も添える。編集は一切しない。
   */
  async function handleAgentCatalogOps(res) {
    const file = path.join(conf.root, 'config', 'agent-catalog.json');
    let raw;
    try { raw = fs.readFileSync(file, 'utf8'); } catch (e) {
      return json(res, 200, {
        ok: true, available: false,
        note: 'config/agent-catalog.json を読めません',
        detail: String(e && e.message).slice(0, 200),
      });
    }
    let d;
    try { d = JSON.parse(raw); } catch (e) {
      return json(res, 200, { ok: true, available: false, note: 'JSON として解釈できません' });
    }
    const arr = (v) => (Array.isArray(v) ? v : []);
    const obj = (v) => (v && typeof v === 'object' && !Array.isArray(v) ? v : {});
    return json(res, 200, {
      ok: true, available: true, file,
      schema_version: d.schemaVersion == null ? null : d.schemaVersion,
      first_class: arr(d.first_class),
      catalog: arr(d.catalog),
      merge: obj(d.merge),
      remove_candidate: obj(d.remove_candidate),
      counts: {
        first_class: arr(d.first_class).length,
        catalog: arr(d.catalog).length,
        merge: Object.keys(obj(d.merge)).length,
        remove_candidate: Object.keys(obj(d.remove_candidate)).length,
      },
    });
  }

  /** handleAgentsOps — Agent Teams 使用状況 (state.json 由来) を JSON で返す */
  async function handleAgentsOps(res) {
    const tool = path.join(REPO_ROOT, 'scripts', 'tools', 'agent-teams-status.js');
    const r = await runCmd(process.execPath, [tool, '--json'], { cwd: REPO_ROOT, timeoutMs: 10000 });
    if (r.exitCode !== 0) {
      return json(res, 200, {
        ok: true, available: false, data: null,
        note: 'agent-teams-status を実行できません', stderr: String(r.stderr || '').slice(0, 300),
      });
    }
    let data = null;
    try { data = JSON.parse(r.stdout); } catch { data = null; }
    if (!data) {
      return json(res, 200, { ok: true, available: false, data: null, note: 'JSON を解釈できません' });
    }
    return json(res, 200, { ok: true, available: true, data });
  }

  /**
   * handleAudit — 変更系操作の監査ログ (JSON Lines) の末尾を返す。
   *   UI が「最近の操作」とログ・監査の表を実データで描けるようにするための読み取り専用 API。
   *   パスは AUDIT_LOG 固定で、リクエストからパスを受け取らない。
   */
  async function handleAudit(res, url) {
    const raw = parseInt(url.searchParams.get('lines') || '50', 10);
    const lines = Math.min(Math.max(Number.isFinite(raw) ? raw : 50, 1), 500);
    let text = '';
    try {
      text = fs.readFileSync(AUDIT_LOG, 'utf8');
    } catch {
      return json(res, 200, { ok: true, file: AUDIT_LOG, lines, entries: [], note: '監査ログはまだありません' });
    }
    const entries = [];
    for (const row of text.split('\n')) {
      const t = row.trim();
      if (!t) continue;
      try { entries.push(JSON.parse(t)); } catch { /* 壊れた行は捨てる (記録は best-effort) */ }
    }
    return json(res, 200, { ok: true, file: AUDIT_LOG, lines, entries: entries.slice(-lines) });
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
      if (pn === '/api/startup/audit' && req.method === 'GET') return handleAudit(res, url);

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

      /* 読み取り専用の運用情報 (cron / systemd / agents)。値は実測で、書き込みは一切しない。 */
      if (req.method === 'GET' && pn === '/api/ops/cron') return handleCronOps(res);
      if (req.method === 'GET' && pn === '/api/ops/systemd') return handleSystemdOps(res);
      if (req.method === 'GET' && pn === '/api/ops/agents') return handleAgentsOps(res);
      if (req.method === 'GET' && pn === '/api/ops/agent-catalog') return handleAgentCatalogOps(res);
      if (req.method === 'GET' && pn === '/api/ops/managed-agents') return handleManagedAgentsOps(res);
      if (req.method === 'GET' && pn === '/api/ops/diag') return handleDiagOps(res, url);
      if (req.method === 'POST' && pn === '/api/ops/release-check/start') {
        const b = await readBody(req);
        if (!b.ok) return json(res, 400, { ok: false, error: b.error });
        return handleReleaseCheckStart(res, b.value);
      }
      if (req.method === 'GET' && pn === '/api/ops/release-check') return handleReleaseCheckOps(res);
      if (req.method === 'GET' && pn === '/api/ops/devops') return handleDevopsOps(res);
      if (req.method === 'GET' && pn === '/api/ops/secops') return handleSecopsOps(res);

      /**
       * 旧 UI (設計プロトタイプ) の画面 URL は単一ページへ集約したため、
       * ブックマークからの流入が 404 にならないよう 302 で `/` へ送る。
       * (ログイン後 Access を通過した直後に 404 になる混乱を避ける)
       */
      const LEGACY_SCREENS = ['/startup-console.html', '/session-monitor.html',
                              '/logs-audit.html', '/mission-control.html'];
      if ((req.method === 'GET' || req.method === 'HEAD') && LEGACY_SCREENS.includes(pn)) {
        res.writeHead(302, { Location: '/', 'Cache-Control': 'no-store' });
        return res.end();
      }

      /**
       * ルート直下は統合コンソール v2 (public/v2.html) を返す。
       * 旧コンソールは /index.html で引き続き参照できるようにし、
       * ファイルを 1 つに保つ (v2.html が正本)。
       */
      if ((req.method === 'GET' || req.method === 'HEAD') && pn === '/') {
        const v2File = path.join(PUBLIC_DIR, 'v2.html');
        return fs.readFile(v2File, (e, data) => {
          if (e) { res.writeHead(404); return res.end('404'); }
          res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store' });
          res.end(req.method === 'HEAD' ? undefined : data);
        });
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
              allowNoAuth: false, dryRunOnly: false, pidFile: '', help: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--port') o.port = parseInt(argv[++i], 10);
    else if (a === '--host') o.host = argv[++i];
    else if (a === '--lan') { o.lan = true; o.host = '0.0.0.0'; }
    else if (a === '--root') o.root = path.resolve(argv[++i]);
    else if (a === '--pid-file') o.pidFile = path.resolve(argv[++i]);
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
    '  --pid-file <path> 起動後に自分の PID を書き出す (bin/web-startup.sh 用)',
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

  /* PID ファイルは「このプロセス自身」が書く。
     pgrep で先頭の startup-server.js を拾うと、別ポートで動く既存インスタンスを
     記録してしまい、--stop が無関係なサーバを止める (QA BUG-01)。 */
  const removePidFile = () => {
    if (!o.pidFile) return;
    try {
      if (fs.readFileSync(o.pidFile, 'utf8').trim() === String(process.pid)) fs.unlinkSync(o.pidFile);
    } catch { /* 既に無い・読めない場合は何もしない */ }
  };
  process.on('exit', removePidFile);

  server.listen(o.port, o.host, () => {
    if (o.pidFile) {
      try {
        fs.mkdirSync(path.dirname(o.pidFile), { recursive: true });
        fs.writeFileSync(o.pidFile, String(process.pid) + '\n');
      } catch (e) {
        process.stderr.write('❌ PID ファイルを書けません: ' + o.pidFile + ' (' + String(e && e.message) + ')\n');
        server.close(() => process.exit(1));
        return;
      }
    }
    const shown = isLoopback(o.host) ? 'http://localhost:' + o.port : 'http://' + o.host + ':' + o.port;
    process.stdout.write('🌐 ClaudeOS Web スタートアップコンソール: ' + shown + '\n');
    process.stdout.write('   root=' + o.root + ' auth=' + (authPass ? 'required' : 'off') +
      ' dryRunOnly=' + o.dryRunOnly + (o.pidFile ? ' pidFile=' + o.pidFile : '') + '\n');
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
