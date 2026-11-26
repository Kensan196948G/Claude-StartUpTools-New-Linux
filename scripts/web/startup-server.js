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
const https  = require('https');
const { spawn, execFile } = require('child_process');

const DEFAULT_PORT = 3740;
const REPO_ROOT    = path.resolve(__dirname, '..', '..');
const PUBLIC_DIR   = path.join(__dirname, 'public');
const CLAUDEOS_HOME = process.env.CLAUDEOS_HOME || path.join(os.homedir(), '.claudeos');
const AUDIT_LOG    = path.join(CLAUDEOS_HOME, 'logs', 'web-startup-audit.log');
// 監査ログのローテーション既定値 (env で上書き可)。
//   5 MiB × 3 世代 = 最大 20 MiB で頭打ちにする (監査の意味は 1 リクエスト 1 行のまま)。
const AUDIT_MAX_BYTES_DEFAULT = 5 * 1024 * 1024;
const AUDIT_KEEP_DEFAULT = 3;
const AUDIT_KEEP_MAX = 100;   // 設定ミス (1e9 等) で世代シフトのループが暴走しないための上限
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

/**
 * isCronSchedule — 先頭 5 項目が cron のスケジュール書式かを検証する。
 *   説明コメント ("# ... then ...") を「無効化された cron 行」と誤認しないため。
 *   各項目は * / 数字 / 範囲 / 名前 (月・曜日) とカンマ列挙、任意の /step を許す。
 */
const CRON_MONTHS = ['jan', 'feb', 'mar', 'apr', 'may', 'jun', 'jul', 'aug', 'sep', 'oct', 'nov', 'dec'];
const CRON_DOWS = ['sun', 'mon', 'tue', 'wed', 'thu', 'fri', 'sat'];
function isCronSchedule(fields) {
  if (!Array.isArray(fields) || fields.length !== 5) return false;
  const end = (v, names) => v === '*' || /^\d+$/.test(v) || names.includes(String(v).toLowerCase());
  const part = (p, names) => {
    const r = p.replace(/\/\d+$/, '').split('-');
    if (r.length === 1) return end(r[0], names);
    return r.length === 2 && r[0] !== '*' && end(r[0], names) && end(r[1], names);
  };
  const field = (f, names) => f.split(',').every((p) => part(p, names));
  return field(fields[0], []) && field(fields[1], []) && field(fields[2], [])
    && field(fields[3], CRON_MONTHS) && field(fields[4], CRON_DOWS);
}

/** resolveLogFile — ログ閲覧のパス検証 (~/.claudeos 配下のみ) */
function resolveLogFile(filePath) {
  if (typeof filePath !== 'string' || filePath === '') return null;
  const base = path.resolve(CLAUDEOS_HOME);
  const full = path.resolve(filePath);
  if (full !== base && !full.startsWith(base + path.sep)) return null;
  // シンボリックリンクで配下の外を指していないこと (存在するときだけ実体パスで再検証)
  try {
    const rb = fs.realpathSync(base);
    const rf = fs.realpathSync(full);
    if (rf !== rb && !rf.startsWith(rb + path.sep)) return null;
  } catch { /* 未作成のファイルはここでは弾かない (読み取り時に空/404 になる) */ }
  return full;
}

/** tailLines — ファイル末尾 N 行 (存在しなければ空文字)。末尾改行は含めない。 */
function tailLines(filePath, lines) {
  const n = Number.isInteger(lines) && lines > 0 ? Math.min(lines, 2000) : 200;
  try {
    // ライブ表示は 3 秒ごとに呼ばれる。巨大ログを毎回全読みしないよう、末尾の最大 512KB だけ読む。
    const MAX_BYTES = 512 * 1024;
    const fd = fs.openSync(filePath, 'r');
    let text;
    try {
      const size = fs.fstatSync(fd).size;
      const len = Math.min(size, MAX_BYTES);
      const buf = Buffer.alloc(len);
      if (len > 0) fs.readSync(fd, buf, 0, len, size - len);
      text = buf.toString('utf8');
      if (size > len) text = text.slice(text.indexOf('\n') + 1);   // 先頭の欠けた行を捨てる
    } finally {
      fs.closeSync(fd);
    }
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
// 監査ログのローテーション (サイズ上限 + 世代管理)
//   追記のたびにサイズを見て、閾値以上なら <log> → <log>.1 → <log>.2 … と
//   世代をシフトする。内容は書き換えず rename/unlink だけなので、監査行はそのまま残る。
//   失敗してもリクエストは落とさない (fail-open)。失敗は stderr に 1 行だけ出す。
// ---------------------------------------------------------------------------

/** warnAudit — 監査ログの失敗を stderr に 1 行だけ出す (処理は止めない) */
function warnAudit(message) {
  try {
    process.stderr.write('⚠️  [WARN] audit: ' + String(message) + '\n');
  } catch { /* stderr すら書けない状況では何もしない (fail-open) */ }
}

/**
 * auditRotateConfig — ローテーション設定を env から解決する。
 *   STARTUP_WEB_AUDIT_MAX_BYTES : 回転閾値 (バイト)。既定 5 MiB。不正値は既定。
 *   STARTUP_WEB_AUDIT_KEEP      : 保持する世代数 (.1〜.keep)。既定 3。0 で履歴を残さない。
 *   設定ミスで監査が止まらないよう、不正値は既定へフォールバックする。
 */
function auditRotateConfig(env) {
  const e = env || {};
  const keepRaw = Number(e.STARTUP_WEB_AUDIT_KEEP);
  return {
    maxBytes: Math.floor(positiveNumber(e.STARTUP_WEB_AUDIT_MAX_BYTES, AUDIT_MAX_BYTES_DEFAULT)),
    keep: Number.isFinite(keepRaw) && keepRaw >= 0
      ? Math.min(AUDIT_KEEP_MAX, Math.floor(keepRaw))
      : AUDIT_KEEP_DEFAULT,
  };
}

/**
 * rotateAuditLog — 追記前のローテーション。閾値以上なら世代シフトする。
 *   keep === 0 のときは履歴を残さないので truncate する。
 *   返り値 { rotated, reason } — 失敗しても throw しない (fail-open)。
 *     reason: 'absent' | 'below-threshold' | 'rotated' | 'truncated'
 *           | 'stat-failed' | 'rename-failed' | 'truncate-failed'
 */
function rotateAuditLog(file, opts) {
  const o = opts || {};
  const maxBytes = Number.isFinite(o.maxBytes) ? o.maxBytes : AUDIT_MAX_BYTES_DEFAULT;
  // 世代数の上限を設ける (設定ミスで 1e9 世代のループにしない)
  const keep = Number.isInteger(o.keep) && o.keep >= 0
    ? Math.min(AUDIT_KEEP_MAX, o.keep)
    : AUDIT_KEEP_DEFAULT;

  let size;
  try {
    size = fs.statSync(file).size;
  } catch (e) {
    return { rotated: false, reason: e && e.code === 'ENOENT' ? 'absent' : 'stat-failed' };
  }
  if (size < maxBytes) return { rotated: false, reason: 'below-threshold' };

  if (keep === 0) {
    try {
      fs.truncateSync(file, 0);
      return { rotated: true, reason: 'truncated' };
    } catch { return { rotated: false, reason: 'truncate-failed' }; }
  }

  try {
    // 古い世代から順に 1 つ後ろへ送る: .keep は捨て、.keep-1 → .keep、…、.1 → .2、無印 → .1。
    //   無い世代 (ENOENT) は「その世代はまだ無い」だけなので無視する。
    for (let i = keep; i >= 1; i--) {
      const from = i === 1 ? file : file + '.' + (i - 1);
      const to = file + '.' + i;
      if (i === keep) {
        try { fs.unlinkSync(to); } catch (e) { if (!e || e.code !== 'ENOENT') throw e; }
      }
      try { fs.renameSync(from, to); } catch (e) { if (!e || e.code !== 'ENOENT') throw e; }
    }
  } catch {
    return { rotated: false, reason: 'rename-failed' };
  }

  // 設定変更で keep が減ったときの余剰世代 (.keep+1 以降) を掃除する。
  //   回転時にしか走らない (readdir 1 回) ので通常経路のコストは増えない。
  try {
    const dir = path.dirname(file);
    const base = path.basename(file);
    for (const name of fs.readdirSync(dir)) {
      if (!name.startsWith(base + '.')) continue;
      const n = Number(name.slice(base.length + 1));
      if (!Number.isInteger(n) || n <= keep) continue;
      try { fs.unlinkSync(path.join(dir, name)); } catch { /* 消せないものは放置 (fail-open) */ }
    }
  } catch { /* readdir 失敗は無視 (回転自体は完了している) */ }

  return { rotated: true, reason: 'rotated' };
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

/**
 * supervisorStateFile — supervisor の状態ファイル。lib/common.sh の ccsu_safe_name と同じ規則
 *   ([A-Za-z0-9_-] 以外は 1 バイトずつ _ に置換) で <dir>/<safe>.json を返す。
 */
function safeProjectName(project) {
  return Array.from(Buffer.from(String(project), 'utf8'))
    .map(b => (/[A-Za-z0-9_-]/.test(String.fromCharCode(b)) ? String.fromCharCode(b) : '_')).join('');
}

function supervisorStateFile(dir, project) {
  return path.join(dir, safeProjectName(project) + '.json');
}

function isPidAlive(pid) {
  try { process.kill(pid, 0); return true; } catch (e) { return !!e && e.code === 'EPERM'; }
}

/**
 * confirmSupervisorRunning — 背景起動のあと supervisor が実在するか短時間ポーリングして確認する。
 *   「CLI が exit 0 で戻った」だけでは起動の証拠にならない (入力待ち分岐でのキャンセル、
 *   起動直後の停止などでも exit 0 になり得る) ため、status=running かつ pid 生存を要求する。
 */
async function confirmSupervisorRunning(dir, project, waitMs) {
  const file = supervisorStateFile(dir, project);
  const until = Date.now() + waitMs;
  let last = null;
  for (;;) {
    try {
      const st = JSON.parse(fs.readFileSync(file, 'utf8'));
      last = { status: st.status || '', reason: st.last_reason || '', pid: st.pid };
      if (st.status === 'running' && Number.isInteger(st.pid) && st.pid > 0 && isPidAlive(st.pid)) {
        return { ok: true, state: last };
      }
    } catch { /* 未生成 / 読めない */ }
    if (Date.now() >= until) return { ok: false, state: last };
    await new Promise(r => setTimeout(r, 250));
  }
}

// ---------------------------------------------------------------------------
// プロンプト送信 (POST /api/session/prompt) — 高リスク機能 (Approval PR で導入)
//   ヘッドレス (claude -p) の会話を Web から 1 ターンずつ進める。実セッションへの直接入力ではなく、
//   「前回の自律セッションを分岐 (--fork-session) → 以後は Web 専用の会話系譜を --resume」で進める。
//   自律実行の会話履歴 (トランスクリプト) には書き込まない。
// ---------------------------------------------------------------------------
const PROMPT_MAX_CHARS = 4000;
const PROMPT_MODELS = ['auto', 'opus', 'sonnet', 'haiku'];
const PROMPT_PERMISSION_MODES = ['auto', 'acceptEdits', 'plan', 'default'];   // 既定は acceptEdits。auto は明示指定のときだけ
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const SECRET_ENV_RE = /(^ANTHROPIC_API_KEY$|^CLAUDEOS_SMTP_|^STARTUP_WEB_|^DASHBOARD_PASSWORD$|^CF_ACCESS_|TOKEN|SECRET|PASSWORD|PASSWD|CREDENTIAL|PRIVATE_KEY|API_?KEY|_KEY$|_DSN$|^SSH_AUTH_SOCK$|^CLOUDFLARE_|^AWS_|^NEON_|^(DATABASE|POSTGRES|POSTGRESQL|DB|REDIS|MONGO|MONGODB|MYSQL)[A-Z_]*URL$|^PG(PASSWORD|PASSFILE)$)/i;
const ENV_KEEP = new Set(['CLAUDE_CODE_OAUTH_TOKEN', 'ANTHROPIC_AUTH_TOKEN']);   // claude 自身の認証 (消すと起動できない)

// 子プロセスへ渡してよい環境変数 (allowlist)。ここに無い名前は、秘密らしくなくても渡さない。
const ENV_ALLOW = new Set([
  'PATH', 'HOME', 'USER', 'LOGNAME', 'SHELL', 'LANG', 'LANGUAGE', 'TERM', 'COLORTERM', 'TZ', 'TMPDIR', 'NO_COLOR', 'NODE_ENV',
  'HTTP_PROXY', 'HTTPS_PROXY', 'NO_PROXY', 'http_proxy', 'https_proxy', 'no_proxy',
  'SSL_CERT_FILE', 'SSL_CERT_DIR', 'NODE_EXTRA_CA_CERTS', 'REQUESTS_CA_BUNDLE',
]);
const ENV_ALLOW_PREFIX = ['LC_', 'XDG_', 'CLAUDE_', 'ANTHROPIC_'];   // 秘密らしい名前 (API キー等) は下の denylist で更に除く

/**
 * scrubEnv — claude 子プロセスへ渡す環境を allowlist で絞り、更に秘密らしい名前を除く (二重の防御)。
 *   extraPass: 運用者が明示した追加名 (STARTUP_WEB_PROMPT_ENV_PASS)。allowlist と denylist の両方を越えて渡す。
 */
function scrubEnv(env, extraPass) {
  const out = {};
  const pass = new Set(Array.isArray(extraPass) ? extraPass : []);
  Object.keys(env || {}).forEach((k) => {
    if (ENV_KEEP.has(k) || pass.has(k)) { out[k] = env[k]; return; }   // claude 自身の認証 / 運用者の明示
    const allowed = ENV_ALLOW.has(k) || ENV_ALLOW_PREFIX.some(p => k.startsWith(p));
    if (allowed && !SECRET_ENV_RE.test(k)) out[k] = env[k];
  });
  return out;
}

// ---------------------------------------------------------------------------
// 日次の使用量 (回数と累計予算)。<webPromptDir>/usage-YYYY-MM-DD.json (ローカル日付)。
//   起動時に予算ぶんを先に確保 (reserve) し、終了時に実コストへ精算する。中断・クラッシュでも使用済みとして残る。
// ---------------------------------------------------------------------------
function usageDay(d) {
  const t = d || new Date();
  const p = (n) => String(n).padStart(2, '0');
  return t.getFullYear() + '-' + p(t.getMonth() + 1) + '-' + p(t.getDate());
}
function usageFile(dir, day) { return path.join(dir, 'usage-' + day + '.json'); }
function readPromptUsage(dir, day) {
  const file = usageFile(dir, day);
  const j = readJsonFile(file);
  // ファイルはあるのに読めない (破損) ときは「不明」として扱い、上限を守れないので送信させない (fail-closed)
  if (!j && fs.existsSync(file)) return { day, count: 0, spentUsd: 0, corrupt: true };
  const count = j && Number.isInteger(j.count) && j.count >= 0 ? j.count : 0;
  const spentUsd = j && typeof j.spentUsd === 'number' && j.spentUsd >= 0 ? j.spentUsd : 0;
  return { day, count, spentUsd };
}
function writePromptUsage(dir, u) {
  try {
    fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
    const file = usageFile(dir, u.day);
    const tmp = file + '.tmp-' + process.pid;
    fs.writeFileSync(tmp, JSON.stringify({ day: u.day, count: u.count, spentUsd: Math.round(u.spentUsd * 10000) / 10000 }) + '\n', { mode: 0o600 });
    fs.renameSync(tmp, file);
    // 古い日のファイルを掃除する (best-effort)
    fs.readdirSync(dir).forEach((n) => {
      // 今日より古い日だけ掃除する (日付をまたぐ精算が、当日の使用量ファイルを消して上限をリセットしないように)
      if (/^usage-\d{4}-\d{2}-\d{2}\.json$/.test(n) && n !== path.basename(file) && n < 'usage-' + usageDay() + '.json') { try { fs.rmSync(path.join(dir, n), { force: true }); } catch { /* 無視 */ } }
    });
    return true;
  } catch { return false; }
}
/** checkPromptDailyLimit — 回数または累計予算の上限に達していれば拒否理由を返す */
function checkPromptDailyLimit(usage, limits) {
  if (usage.corrupt) return { ok: false, error: 'PROMPT_USAGE_UNREADABLE' };
  if (usage.count >= limits.maxCount) return { ok: false, error: 'PROMPT_DAILY_LIMIT' };
  if (usage.spentUsd + limits.perRunUsd > limits.budgetUsd) return { ok: false, error: 'PROMPT_DAILY_BUDGET' };
  return { ok: true };
}

/** checkOpsDailyLimit — 変更系操作の日次上限。使用量が読めない (破損) ときは上限を守れないので拒否する (fail-closed) */
function checkOpsDailyLimit(usage, maxCount) {
  if (usage.corrupt) return { ok: false, error: 'OPS_USAGE_UNREADABLE' };
  if (usage.count >= maxCount) return { ok: false, error: 'OPS_DAILY_LIMIT' };
  return { ok: true };
}

/**
 * opsChildEnv — 変更系の実行 (systemd-control) へ渡す環境。サーバー自身の秘密 (STARTUP_WEB_* / CF_ACCESS_* 等) と
 *   claude の認証トークンは渡さない。--user の systemctl に必要な XDG_RUNTIME_DIR (XDG_ 接頭辞) と DBUS_SESSION_BUS_ADDRESS は通す。
 */
function opsChildEnv(env) {
  const out = scrubEnv(env, ['DBUS_SESSION_BUS_ADDRESS', 'CLAUDEOS_HOME']);
  Object.keys(out).forEach((k) => { if (k.startsWith('ANTHROPIC_') || k.startsWith('CLAUDE_')) delete out[k]; });
  return out;
}

/**
 * isProtectedOpsTarget — Web から再起動してはいけない対象 (自己ロックアウトの防止)。
 *   このサービス自身 (web-startup) を再起動すると実行中のリクエストごと止まり、
 *   公開トンネル (cloudflared / tunnel) を再起動すると、利用者の唯一の経路が切れる。
 *   台帳に載っていなくても (将来載っても) 拒否できるよう、名前で固定拒否する。
 *   部分一致 (大文字小文字を区別しない) は意図した fail-closed。tunnel を名前に含む正当な
 *   プロジェクト (例: wind-tunnel-sim) も拒否される (誤拒否)。単語境界や完全一致へ狭めると
 *   cftunnel のような実在し得る unit が保護から外れ、唯一の経路を切る再起動を許すため、狭めない。
 */
function isProtectedOpsTarget(project) {
  return /web-startup|cloudflared|tunnel/i.test(String(project || ''));
}

/** validatePromptText — 長さ・制御文字 (NUL) を検証して整形済みの本文を返す */
function validatePromptText(text) {
  if (typeof text !== 'string') return { ok: false, error: 'PROMPT_REQUIRED' };
  const t = text.trim();
  if (t === '') return { ok: false, error: 'PROMPT_REQUIRED' };
  if (t.length > PROMPT_MAX_CHARS) return { ok: false, error: 'PROMPT_TOO_LONG', max: PROMPT_MAX_CHARS };
  if (t.indexOf('\u0000') >= 0) return { ok: false, error: 'PROMPT_INVALID' };
  return { ok: true, value: t };
}

function validatePromptModel(model) {
  if (model === undefined || model === null || model === '') return { ok: true, value: 'auto' };
  if (typeof model !== 'string' || !PROMPT_MODELS.includes(model)) return { ok: false, error: 'MODEL_INVALID' };
  return { ok: true, value: model };
}

function readJsonFile(file) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch { return null; }
}

/**
 * findAutonomousSessionId — 自律実行 (cron-launcher) が保存した、当該プロジェクトの最新 session_id。
 *   ファイル名ではなく JSON の project フィールドで照合する (非 ASCII 名は safe 名が衝突するため)。
 */
function findAutonomousSessionId(sessionsDir, project) {
  let best = null;
  let files = [];
  try { files = fs.readdirSync(sessionsDir).filter(f => f.endsWith('.json')); } catch { return ''; }
  for (const f of files) {
    const full = path.join(sessionsDir, f);
    const j = readJsonFile(full);
    if (!j || j.project !== project || typeof j.sessionId !== 'string' || !UUID_RE.test(j.sessionId)) continue;
    let t = 0;
    try { t = fs.statSync(full).mtimeMs; } catch { /* 取得不能は古い扱い */ }
    if (!best || t > best.t) best = { t, id: j.sessionId };
  }
  return best ? best.id : '';
}

/** Web 専用の会話系譜 (自律実行の会話とは別 ID)。ファイル名は safe 名 + project のハッシュで衝突を避ける。 */
function webLineageFile(dir, project) {
  const h = crypto.createHash('sha256').update(String(project)).digest('hex').slice(0, 8);
  return path.join(dir, safeProjectName(project) + '-' + h + '.json');
}

function readWebLineage(dir, project) {
  const j = readJsonFile(webLineageFile(dir, project));
  // project が一致しない系譜は使わない (別プロジェクトの会話文脈を引き継がない)
  return (j && j.project === project && typeof j.session_id === 'string' && UUID_RE.test(j.session_id)) ? j.session_id : '';
}

function writeWebLineage(dir, project, sessionId, forkedFrom) {
  if (!UUID_RE.test(String(sessionId))) return false;
  try {
    fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
    const file = webLineageFile(dir, project);
    const tmp = file + '.tmp-' + process.pid;
    fs.writeFileSync(tmp, JSON.stringify({ project, session_id: sessionId, forked_from: forkedFrom || '', updated_at: new Date().toISOString() }) + '\n', { mode: 0o600 });
    fs.renameSync(tmp, file);
    return true;
  } catch { return false; }
}

/** removeWebLineage — resume に失敗した系譜を捨てる (次回は新規会話/分岐から始める) */
function removeWebLineage(dir, project) {
  try { fs.rmSync(webLineageFile(dir, project), { force: true }); } catch { /* 無ければ何もしない */ }
}

/** positiveNumber — 有限の正数だけを採用し、それ以外 (NaN / 0 / 負数) は既定値へ戻す (上限が黙って無効化されない) */
function positiveNumber(v, def) {
  const n = Number(v);
  return Number.isFinite(n) && n > 0 ? n : def;
}

/** 実行中のプロンプト子プロセス (shutdown 時にプロセスグループごと停止する) */
const ACTIVE_PROMPT_CHILDREN = new Set();
function killActivePrompts() {
  ACTIVE_PROMPT_CHILDREN.forEach((c) => {
    try { process.kill(-c.pid, 'SIGKILL'); } catch { try { c.kill('SIGKILL'); } catch { /* 既に終了 */ } }
  });
}

/**
 * sanitizePromptEvent — claude の stream-json から、ブラウザへ中継してよい項目だけを残す (許可リスト)。
 *   tool_result (ファイル内容・コマンド出力) や tool_use の入力、hook / status などは中継しない。
 */
function sanitizePromptEvent(ev) {
  if (!ev || typeof ev !== 'object') return null;
  const t = ev.type;
  if (t === 'system') {
    return ev.subtype === 'init'
      ? { type: 'system', subtype: 'init', session_id: ev.session_id, model: ev.model, permissionMode: ev.permissionMode }
      : null;
  }
  if (t === 'stream_event') {
    const se = ev.event || {};
    if (se.type === 'message_start') return { type: 'stream_event', event: { type: 'message_start' } };
    if (se.type === 'content_block_delta' && se.delta && se.delta.type === 'text_delta' && typeof se.delta.text === 'string') {
      return { type: 'stream_event', event: { type: 'content_block_delta', delta: { type: 'text_delta', text: se.delta.text.slice(0, 20000) } } };
    }
    return null;
  }
  if (t === 'assistant') {
    const c = ev.message && Array.isArray(ev.message.content) ? ev.message.content : [];
    return { type: 'assistant', message: { content: c.map((b) => {
      if (b && b.type === 'text') return { type: 'text', text: String(b.text || '').slice(0, 50000) };
      if (b && b.type === 'tool_use') return { type: 'tool_use', name: String(b.name || '').slice(0, 80) };
      return null;
    }).filter(Boolean) } };
  }
  if (t === 'user') return { type: 'user' };
  if (t === 'result') {
    return { type: 'result', subtype: ev.subtype, is_error: !!ev.is_error,
      result: typeof ev.result === 'string' ? ev.result.slice(0, 50000) : undefined,
      total_cost_usd: typeof ev.total_cost_usd === 'number' ? ev.total_cost_usd : undefined, session_id: ev.session_id };
  }
  return null;
}

function b64urlToBuf(s) { return Buffer.from(String(s).replace(/-/g, '+').replace(/_/g, '/'), 'base64'); }

/**
 * isEmailLike — 実行者として監査に残せる「メール形式」の値か。
 *   verifyAccessJwt は email クレームが無いと sub を email 欄へ入れて返すため、
 *   `jwt.email` の有無だけでは sub だけの JWT を弾けない (BUG-09)。
 *   実起動 (requireLaunchJwt) と変更系 (handleOpsRestart) は同じこの基準を使う。
 */
function isEmailLike(value) {
  return /@/.test(String(value || ''));
}

/**
 * verifyAccessJwt — Cloudflare Access の JWT (Cf-Access-Jwt-Assertion) を検証する。
 *   署名 (RS256 / JWKS)・iss (https://<team>)・aud・exp を確認する。オリジンが Access を経由した
 *   リクエストだけを受け付けるための検証で、ヘッダ (メールアドレス) の自己申告は信用しない。
 */
async function verifyAccessJwt(token, o) {
  try {
    const parts = String(token || '').split('.');
    if (parts.length !== 3) return { ok: false, error: 'JWT_MALFORMED' };
    const header = JSON.parse(b64urlToBuf(parts[0]).toString('utf8'));
    const payload = JSON.parse(b64urlToBuf(parts[1]).toString('utf8'));
    if (header.alg !== 'RS256') return { ok: false, error: 'JWT_ALG' };
    if (typeof header.kid !== 'string' || header.kid === '') return { ok: false, error: 'JWT_KEY_UNKNOWN' };
    const findKey = (keys) => (keys || []).find(k => k && k.kid === header.kid && k.kty === 'RSA');
    let jwk;
    try {
      jwk = findKey(await o.getKeys(false));
      if (!jwk) jwk = findKey(await o.getKeys(true));   // 鍵のローテーション直後は 1 度だけ再取得する
    } catch {
      return { ok: false, error: 'JWKS_UNAVAILABLE' };
    }
    if (!jwk) return { ok: false, error: 'JWT_KEY_UNKNOWN' };
    const pub = crypto.createPublicKey({ key: jwk, format: 'jwk' });
    if (!crypto.verify('RSA-SHA256', Buffer.from(parts[0] + '.' + parts[1]), pub, b64urlToBuf(parts[2]))) {
      return { ok: false, error: 'JWT_SIGNATURE' };
    }
    const now = Math.floor((o.now || Date.now()) / 1000);
    if (typeof payload.exp !== 'number' || payload.exp <= now) return { ok: false, error: 'JWT_EXPIRED' };
    if (typeof payload.nbf === 'number' && payload.nbf > now + 60) return { ok: false, error: 'JWT_NOT_YET_VALID' };
    const aud = Array.isArray(payload.aud) ? payload.aud : [payload.aud];
    if (!aud.includes(o.aud)) return { ok: false, error: 'JWT_AUD' };
    if (payload.iss !== 'https://' + o.teamDomain) return { ok: false, error: 'JWT_ISS' };
    return { ok: true, email: String(payload.email || payload.sub || '') };
  } catch {
    return { ok: false, error: 'JWT_INVALID' };
  }
}

/** fetchAccessKeys — https://<team>.cloudflareaccess.com/cdn-cgi/access/certs の公開鍵 (JWKS) を取得する */
function fetchAccessKeys(teamDomain) {
  return new Promise((resolve, reject) => {
    if (!/^[a-z0-9-]+(\.[a-z0-9-]+)*\.cloudflareaccess\.com$/i.test(String(teamDomain))) return reject(new Error('TEAM_DOMAIN_INVALID'));
    const r = https.get({ host: teamDomain, path: '/cdn-cgi/access/certs', timeout: 8000, headers: { accept: 'application/json' } }, (res) => {
      let d = '';
      res.on('data', (c) => { d += c; if (d.length > 262144) { r.destroy(new Error('JWKS_TOO_LARGE')); } });
      res.on('end', () => {
        try { const j = JSON.parse(d); resolve(Array.isArray(j.keys) ? j.keys : []); } catch (e) { reject(e); }
      });
    });
    r.on('timeout', () => r.destroy(new Error('JWKS_TIMEOUT')));
    r.on('error', reject);
  });
}

/**
 * isProjectRunning — プロジェクトが稼働中か。登録済み (state.projects[].running) に加えて、
 *   実際の稼働情報 (state.sessions の headless / foreground / tmux) も見る。
 *   登録外のフォルダ (all_folders 由来) は state.projects に載らないため、これが無いと停止も二重送信防止も効かない。
 */
function isProjectRunning(state, name) {
  const p = ((state && state.projects) || []).find(x => x.name === name);
  if (p && p.running === true) return true;
  const s = (state && state.sessions) || {};
  const has = (arr, v) => Array.isArray(arr) && arr.includes(v);
  const safe = safeProjectName(name);
  return has(s.headless, name) || has(s.foreground, name) || has(s.tmux, 'claudeos-' + safe) || has(s.tmux, 'claudeos-team-' + safe);
}

/** resolveProjectDir — projects_dir 配下の実在ディレクトリだけを返す (シンボリックリンクで外へ出ない) */
function resolveProjectDir(state, name) {
  const baseRaw = state && state.projects_dir ? String(state.projects_dir) : '';
  if (!baseRaw) return '';
  const base = path.resolve(baseRaw);
  const full = path.resolve(base, String(name));
  if (!full.startsWith(base + path.sep)) return '';
  try {
    const rb = fs.realpathSync(base);
    const rf = fs.realpathSync(full);
    if (!rf.startsWith(rb + path.sep) || !fs.statSync(rf).isDirectory()) return '';
    return rf;
  } catch { return ''; }
}

/**
 * buildPromptArgs — claude -p の引数。本文は最後に `--` の後ろへ置き、先頭が - でもオプション扱いにしない。
 *   resumeId があれば --resume、fork=true なら --fork-session (分岐して元の会話に書き込まない)。
 */
function buildPromptArgs(o) {
  const args = ['-p', '--output-format', 'stream-json', '--verbose', '--include-partial-messages',
    '--permission-mode', o.permissionMode || 'auto'];
  if (o.noPermissionPrompts) args.push('--permission-prompts', 'none');
  if (o.resumeId) args.push('--resume', o.resumeId);
  if (o.resumeId && o.fork) args.push('--fork-session');
  if (o.model && o.model !== 'auto') args.push('--model', o.model);
  if (o.budgetUsd > 0) args.push('--max-budget-usd', String(o.budgetUsd));
  args.push('--', o.text);
  return args;
}

// ---------------------------------------------------------------------------
// ビルド識別子 — /api/health が返す「いま動いている成果物」の同一性
// ---------------------------------------------------------------------------

/** COMMIT_SHA_RE — manifest と env が持つ commit の表現 (git の完全 SHA のみ) */
const COMMIT_SHA_RE = /^[0-9a-f]{40}$/;

/**
 * readCommitFromManifest — release 成果物ルートの manifest.json から commit を読む。
 *   成果物には .git が無いため、commit の出所はマニフェストだけになる。
 *   無い・壊れている・形が 40 桁 SHA でない場合は '' (例外は投げない)。
 */
function readCommitFromManifest(root) {
  if (!root) return '';
  try {
    const m = JSON.parse(fs.readFileSync(path.join(root, 'manifest.json'), 'utf8'));
    const c = String((m && m.commit) || '').trim().toLowerCase();
    return COMMIT_SHA_RE.test(c) ? c : '';
  } catch { return ''; }
}

/** readPackageVersion — package.json の version (無い・壊れている場合は '') */
function readPackageVersion(root) {
  if (!root) return '';
  try {
    const p = JSON.parse(fs.readFileSync(path.join(root, 'package.json'), 'utf8'));
    return typeof p.version === 'string' ? p.version.trim() : '';
  } catch { return ''; }
}

/**
 * resolveBuildInfo — 稼働中成果物の識別子 { commit, version } を解決する。
 *   commit の解決順: env.GIT_COMMIT → <root>/manifest.json の commit → ''。
 *     - 40 桁 SHA 以外の値は「無い」ものとして次の出所へ進む
 *       (health は 40 桁 SHA か空文字しか返さない契約)。
 *     - git コマンドは実行しない (release 成果物には .git が無い)。
 *   version は <root>/package.json の version (無ければ '')。
 *   返り値は引数 (root, env) だけで決まる (テストはこれを直接叩く)。
 */
function resolveBuildInfo(opts) {
  const { root, env } = opts || {};
  const e = env || {};
  const fromEnv = String(e.GIT_COMMIT == null ? '' : e.GIT_COMMIT).trim().toLowerCase();
  const commit = COMMIT_SHA_RE.test(fromEnv) ? fromEnv : readCommitFromManifest(root);
  return { commit, version: readPackageVersion(root) };
}

function appendAudit(entry) {
  const line = auditLine(entry) + '\n';
  try {
    fs.mkdirSync(path.dirname(AUDIT_LOG), { recursive: true });
  } catch { /* ディレクトリ作成の失敗は下の追記失敗で 1 行にまとめて報告する */ }

  // 追記の前にサイズを見てローテーションする (fail-open: 失敗してもリクエストは落とさない)
  let rot;
  try {
    rot = rotateAuditLog(AUDIT_LOG, auditRotateConfig(process.env));
  } catch (e) {
    rot = { rotated: false, reason: 'unexpected' };
  }
  if (!rot.rotated && rot.reason !== 'absent' && rot.reason !== 'below-threshold') {
    warnAudit('ローテーションに失敗しました (' + rot.reason + '): ' + AUDIT_LOG + ' — 追記を続行します');
  }

  try {
    fs.appendFileSync(AUDIT_LOG, line);
  } catch (e) {
    // 従来は握りつぶしていたが、「記録できない」ことは stderr に 1 行だけ残す (処理は止めない)
    warnAudit('追記できません: ' + AUDIT_LOG + ' (' + String(e && e.message) + ')');
  }
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
    // 背景起動 (S1) 後に supervisor の実在を確認する。0 で無効 (テスト用)
    supervisorDir: process.env.CCSU_SUP_DIR || path.join(CLAUDEOS_HOME, 'supervisor'),
    launchConfirmMs: 8000,
    // プロンプト送信 (POST /api/session/prompt)
    sessionsDir: process.env.CLAUDEOS_SESSIONS_DIR || path.join(CLAUDEOS_HOME, 'sessions'),
    webPromptDir: path.join(CLAUDEOS_HOME, 'web-prompt'),
    claudeBin: process.env.CLAUDE_BIN || 'claude',
    promptEnabled: process.env.STARTUP_WEB_PROMPT_ENABLE === '1',   // 既定は無効 (高リスク機能)
    promptBudgetUsd: positiveNumber(process.env.STARTUP_WEB_PROMPT_BUDGET_USD, 2),
    promptTimeoutMs: Math.max(1000, positiveNumber(process.env.STARTUP_WEB_PROMPT_TIMEOUT_MS, 600000)),
    opsPlanTimeoutMs: positiveNumber(process.env.STARTUP_WEB_OPS_PLAN_TIMEOUT_MS, 15000),   // dry-run は短時間で終わる
    opsPlanMaxConcurrent: 3,
    // 実起動 (launch / apply-all の confirm=true) に Cloudflare Access の JWT を要求する。既定は無効 (ローカル直アクセスの運用を壊さない)
    launchRequireJwt: process.env.STARTUP_WEB_LAUNCH_REQUIRE_JWT === '1',
    // 変更系の実行 (段階 2: Systemd restart のみ。docs/architecture/WEB_MUTATING_OPS_DESIGN.md)。既定は無効 (高リスク機能)
    opsRestartEnabled: process.env.STARTUP_WEB_OPS_RESTART_ENABLE === '1',
    opsDailyMax: Math.floor(positiveNumber(process.env.STARTUP_WEB_OPS_DAILY_MAX, 20)),            // 1 日の実行回数の上限 (プロンプト送信とは別カウント)
    opsExecTimeoutMs: positiveNumber(process.env.STARTUP_WEB_OPS_EXEC_TIMEOUT_MS, 30000),
    webOpsDir: path.join(CLAUDEOS_HOME, 'web-ops'),
    promptDailyMax: Math.floor(positiveNumber(process.env.STARTUP_WEB_PROMPT_DAILY_MAX, 50)),          // 1 日の送信回数の上限
    promptDailyBudgetUsd: positiveNumber(process.env.STARTUP_WEB_PROMPT_DAILY_BUDGET_USD, 10),        // 1 日の累計予算の上限 (USD)
    promptEnvPass: String(process.env.STARTUP_WEB_PROMPT_ENV_PASS || '').split(',').map(x => x.trim()).filter(x => /^[A-Za-z_][A-Za-z0-9_]*$/.test(x)),
    promptPermission: PROMPT_PERMISSION_MODES.includes(process.env.STARTUP_WEB_PROMPT_PERMISSION)
      ? process.env.STARTUP_WEB_PROMPT_PERMISSION : 'acceptEdits',
    // 認証: Basic パスワード (STARTUP_WEB_PASSWORD) か Cloudflare Access の JWT 検証 (どちらも無ければ送信は拒否)
    accessTeamDomain: process.env.CF_ACCESS_TEAM_DOMAIN || '',
    accessAud: process.env.CF_ACCESS_AUD || '',
    // 公開ホスト名 (Cloudflare 経由の Host)。loopback (127.0.0.1 / localhost / [::1]) は常に許可
    allowedHosts: String(process.env.STARTUP_WEB_ALLOWED_HOSTS || '').split(',').map(x => x.trim().toLowerCase()).filter(Boolean),
  }, cfg || {});

  conf.allowedHosts = (conf.allowedHosts || []).map(x => String(x).trim().toLowerCase());

  // いま動いている成果物の識別子 (health で公開)。起動時に 1 回だけ解決する。
  //   env (release-promote / unit が注入) → 成果物ルートの manifest.json → 空文字。
  const buildInfo = resolveBuildInfo({ root: conf.root, env: process.env });

  const BIN_START = path.join(conf.root, 'bin', 'start-claude.sh');
  const BIN_AUTONOMY = path.join(conf.root, 'bin', 'autonomy.sh');
  const LIBEXEC_STATE = path.join(conf.root, 'libexec', 'startup-state.sh');

  // 変更系操作は同時 1 件 (レースで同じプロジェクトを二重起動しない)
  let busy = false;
  let opsExecRunning = false;   // 変更系の実行は常に 1 件まで
  let opsPlanRunning = 0;   // 計画 (dry-run) の同時実行数 (読み取りだが bash を起動するため上限を設ける)

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
  async function handleLaunch(res, body, remote, user) {
    const ctx = await resolveContext();
    if (!ctx.ok) return json(res, 500, { ok: false, error: ctx.error, detail: ctx.stderr || '' });
    const v = validateLaunchRequest(body, ctx);
    if (!v.ok) return json(res, 400, { ok: false, error: v.error });

    // Web 会話 (プロンプト送信) の実行中は、同じプロジェクトを起動しない (同じ作業ツリーへの二重書き込みを避ける)
    if (promptActive && promptActive.project === v.value.project) {
      return json(res, 409, { ok: false, error: 'PROMPT_IN_PROGRESS', message: 'このプロジェクトは Web 会話の実行中です。完了後に起動してください。' });
    }
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
      if (v.value.mode === 'background' && conf.launchConfirmMs > 0) {
        const c = await confirmSupervisorRunning(conf.supervisorDir, v.value.project, conf.launchConfirmMs);
        if (!c.ok) {
          appendAudit({ action: 'launch-unconfirmed', project: v.value.project, mode: v.value.mode,
                        goal: v.value.goal, pid: r.pid, supervisor: c.state && c.state.status, remote });
          return json(res, 200, {
            ok: false, started: false, error: 'START_NOT_CONFIRMED',
            message: '起動コマンドは終了コード 0 で戻りましたが、supervisor の稼働を確認できませんでした'
              + (c.state && c.state.status ? ' (status=' + c.state.status + (c.state.reason ? ': ' + c.state.reason : '') + ')' : ' (状態ファイルなし)')
              + '。起動に時間がかかっている場合は、数秒後にセッション監視で再確認してください',
            exitCode: r.exitCode, pid: r.pid, args, log: projectLog,
            output: r.stdout, stderr: r.stderr, supervisor: c.state,
          });
        }
      }
      appendAudit({ action: 'launch', project: v.value.project, mode: v.value.mode,
                    goal: v.value.goal, pid: r.pid, remote, user: user || undefined });
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
      // 登録外のフォルダ (all_folders 由来) は state.projects に載らないため、実際の稼働情報 (state.sessions) でも判定する
      if (!isProjectRunning(ctx.state, proj.value)) return json(res, 409, { ok: false, error: 'NOT_RUNNING' });
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
  async function handleApplyAll(res, body, remote, user) {
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
      // Web 会話 (プロンプト送信) の実行中は全適用しない (同じ作業ツリーへ supervisor が起動して二重書き込みになる)
      if (promptActive) {
        appendAudit({ action: 'apply-all-blocked', error: 'PROMPT_IN_PROGRESS', project: promptActive.project, remote });
        return json(res, 409, { ok: false, error: 'PROMPT_IN_PROGRESS', message: 'Web 会話の実行中は全適用できません。完了後に実行してください。' });
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
      appendAudit({ action: 'apply-all', pid: r.pid, remote, dryExit: dry.exitCode, user: user || undefined });
      return json(res, 200, { ok: true, started: true, pid: r.pid, args, plan: dry.stdout });
    } finally {
      busy = false;
    }
  }

  /**
   * handleOpsPlan — Cron / Systemd の変更系操作の「計画のみ」(段階 1。docs/architecture/WEB_MUTATING_OPS_DESIGN.md)。
   *   CLI を必ず --dry-run 付きで実行し、その出力を返すだけ。実データは変更しない (実行は未接続のまま)。
   *   操作名は許可リストから引数を組み立てる (シェル文字列を作らない)。
   *   cron run-now は、サービスが NoNewPrivileges のため crontab を読めず「未登録」と誤報し得るので対象外 (方式 B の導入後)。
   */
  async function handleOpsPlan(res, body, remote) {
    const op = typeof body.op === 'string' ? body.op : '';
    const rejectPlan = (status, error, extra) => {
      appendAudit(Object.assign({ action: 'ops-plan-rejected', error, op: op.slice(0, 40), remote }, extra || {}));
      return json(res, status, { ok: false, error });
    };
    const SYSTEMD_VERBS = { 'systemd-start': 'start', 'systemd-stop': 'stop', 'systemd-restart': 'restart', 'systemd-enable': 'enable', 'systemd-disable': 'disable' };
    const isCron = op === 'cron-add';
    if (!isCron && !Object.prototype.hasOwnProperty.call(SYSTEMD_VERBS, op)) return rejectPlan(400, 'OP_INVALID');
    const ctx = await resolveContext();
    if (!ctx.ok) return json(res, 500, { ok: false, error: ctx.error });
    const proj = validateProject(body.project, ctx.allowed);
    if (!proj.ok) return rejectPlan(400, proj.error, { project: typeof body.project === 'string' ? body.project.slice(0, 120) : '' });
    let bin, args;
    const params = {};
    if (isCron) {
      const time = typeof body.time === 'string' ? body.time : '';
      if (!/^([01]\d|2[0-3]):[0-5]\d$/.test(time)) return rejectPlan(400, 'TIME_INVALID', { project: proj.value });
      const dow = String(body.dow === undefined || body.dow === null ? '' : body.dow);
      if (!/^[0-6](,[0-6]){0,6}$/.test(dow)) return rejectPlan(400, 'DOW_INVALID', { project: proj.value });
      // 数値か、数字だけの文字列のみ (true / [] / '1e2' などを通さない)
      const durOk = (typeof body.duration === 'number') || (typeof body.duration === 'string' && /^[0-9]{1,4}$/.test(body.duration));
      const dur = durOk ? Number(body.duration) : NaN;
      if (!Number.isInteger(dur) || dur < 1 || dur > 1440) return rejectPlan(400, 'DURATION_INVALID', { project: proj.value });
      const goal = validateGoal(body.goal, ctx.goals);
      if (!goal.ok) return rejectPlan(400, goal.error, { project: proj.value });
      bin = path.join(conf.root, 'bin', 'cron-schedule.sh');
      args = ['add', '--project', proj.value, '--time', time, '--dow', dow, '--duration', String(dur)];
      if (goal.value) args.push('--goal-type', goal.value);
      Object.assign(params, { time, dow, duration: dur, goal: goal.value });
    } else {
      bin = path.join(conf.root, 'bin', 'systemd-control.sh');
      args = [SYSTEMD_VERBS[op], proj.value];
    }
    args.push('--dry-run');
    if (opsPlanRunning >= conf.opsPlanMaxConcurrent) return rejectPlan(429, 'OPS_PLAN_BUSY', { project: proj.value });
    opsPlanRunning++;
    let r;
    try {
      r = await runScript(bin, args, { cwd: conf.root, timeoutMs: conf.opsPlanTimeoutMs });
    } finally {
      opsPlanRunning--;
    }
    appendAudit(Object.assign({ action: 'ops-plan', op, project: proj.value, exit: r.exitCode, remote }, params));
    const clean = (t) => String(t || '').replace(/\u001b\[[0-9;]*m/g, '').trim().slice(0, 4000);   // ANSI 除去・長さ上限
    return json(res, 200, {
      ok: r.exitCode === 0, op, dryRun: true, exitCode: r.exitCode,
      command: 'bash bin/' + path.basename(bin) + ' ' + args.join(' '),
      plan: clean(r.stdout),
      stderr: r.exitCode === 0 ? '' : clean(r.stderr),   // 成功時は環境依存のパス等を返さない
    });
  }

  // ---------------------------------------------------------------------------
  // プロンプト送信 (Approval PR): ヘッドレス会話を 1 ターンずつ進め、NDJSON でストリーミングする。
  //   これは「公開画面からホスト上で Claude に作業をさせる」= 実質リモートコード実行に近い高リスク機能のため、
  //   既定で無効 (STARTUP_WEB_PROMPT_ENABLE=1 で明示的に有効化) とし、次を全て満たさない限り拒否する (fail-closed)。
  //   - 認証: Basic パスワード (STARTUP_WEB_PASSWORD) か、Cloudflare Access の JWT 検証 (CF_ACCESS_TEAM_DOMAIN + CF_ACCESS_AUD)
  //   - Host の許可リスト (loopback / STARTUP_WEB_ALLOWED_HOSTS) と、Origin 必須・Host 一致・JSON のみ・Sec-Fetch-Site (DNS rebinding / CSRF 対策)
  //   - confirm:true (UI の二段階確認。サーバー側の人間確認ではなく、誤操作と自動送信の防止) / dryRunOnly では拒否
  //   - 自律実行中のプロジェクトには送らない / 同時 1 件 / 本文 4000 文字・NUL 禁止 / モデルは許可リスト
  //   - 予算・時間上限 / 秘密環境変数を子へ渡さない / 子はプロセスグループごと停止 / ブラウザへは許可リストのイベントだけ中継
  //   - 監査ログ (本文は記録せず長さとハッシュのみ。拒否も記録)
  // ---------------------------------------------------------------------------
  let promptActive = null;
  let promptsFlagSupport = null;   // true / false。--help の取得に失敗したら null のまま (失敗をキャッシュしない)
  let accessKeysCache = null;
  const promptRejectAudit = {};   // 認証前の拒否の監査を間引くための最終記録時刻

  function supportsPermissionPromptsFlag() {
    if (promptsFlagSupport !== null) return Promise.resolve(promptsFlagSupport);
    return new Promise((resolve) => {
      execFile(conf.claudeBin, ['--help'], { timeout: 10000, env: scrubEnv(process.env, conf.promptEnvPass), maxBuffer: 1 << 20 }, (err, stdout) => {
        if (err) return resolve(null);
        promptsFlagSupport = /--permission-prompts/.test(String(stdout));
        resolve(promptsFlagSupport);
      });
    });
  }

  function isSupervisorActive(project) {
    const st = readJsonFile(supervisorStateFile(conf.supervisorDir, project));
    return !!(st && st.status === 'running' && Number.isInteger(st.pid) && st.pid > 0 && isPidAlive(st.pid));
  }

  async function getAccessKeys(force) {
    if (typeof conf.accessKeys === 'function') return conf.accessKeys(!!force);
    const now = Date.now();
    // 通常は 10 分キャッシュ。強制再取得 (未知 kid) は 60 秒に 1 回まで (不正な kid での取得連打を避ける)
    if (accessKeysCache && now - accessKeysCache.at < (force ? 60000 : 600000)) return accessKeysCache.keys;
    const keys = await fetchAccessKeys(conf.accessTeamDomain);
    accessKeysCache = { at: now, keys };
    return keys;
  }

  /** authenticatePrompt — Basic (共通検査を通過済み) か Access JWT。どちらも無ければ拒否 */
  async function authenticatePrompt(req) {
    if (conf.authPass) return { ok: true, user: conf.authUser, mode: 'basic' };
    if (conf.accessTeamDomain && conf.accessAud) {
      const v = await verifyAccessJwt(req.headers['cf-access-jwt-assertion'], {
        teamDomain: conf.accessTeamDomain, aud: conf.accessAud, getKeys: getAccessKeys });
      if (!v.ok) return { ok: false, error: 'PROMPT_AUTH_FAILED', detail: v.error };
      // 実行者を監査に残せない JWT では送信しない。verifyAccessJwt は email クレームが無いと
      // sub を email 欄へ入れて返すため、実起動・Systemd 再起動と同じ「メール形式」を要求する (F4)。
      if (!isEmailLike(v.email)) return { ok: false, error: 'PROMPT_AUTH_FAILED', detail: 'NO_EMAIL' };
      return { ok: true, user: v.email, mode: 'access-jwt' };
    }
    return { ok: false, error: 'PROMPT_AUTH_NOT_CONFIGURED' };
  }

  /**
   * checkMutationRequest — 変更系 POST (launch / stop / apply-all / plan / release-check) の共通検査。
   *   Host: loopback / IP リテラル / STARTUP_WEB_ALLOWED_HOSTS のみ (DNS rebinding は名前解決を悪用するため、名前だけ縛る)。
   *   本文があるなら JSON のみ (text/plain の単純リクエストによる CSRF を避ける)。Sec-Fetch-Site が same-origin/none 以外は拒否。
   *   Origin は従来どおり (付いていれば Host と一致が必須)。CLI からの直接呼び出しを壊さないため、無い場合は許可する。
   */
  function checkMutationRequest(req) {
    const host = String(req.headers.host || '').toLowerCase();
    const loop = /^(127\.0\.0\.1|localhost|\[::1\])(:\d+)?$/;
    const ipLit = /^(\d{1,3}(\.\d{1,3}){3}|\[[0-9a-fA-F:]+\])(:\d+)?$/;
    if (!loop.test(host) && !ipLit.test(host) && !conf.allowedHosts.includes(host)) return { ok: false, status: 403, error: 'HOST_REJECTED' };
    const hasBody = Number(req.headers['content-length'] || 0) > 0 || !!req.headers['transfer-encoding'];
    if (hasBody && !/^application\/json(\s*;|$)/i.test(String(req.headers['content-type'] || ''))) return { ok: false, status: 415, error: 'UNSUPPORTED_MEDIA_TYPE' };
    const sfs = req.headers['sec-fetch-site'];
    if (sfs && sfs !== 'same-origin' && sfs !== 'none') return { ok: false, status: 403, error: 'CROSS_SITE_REJECTED' };
    return { ok: true };
  }

  /** checkPromptRequest — Host 許可リスト / JSON のみ / Origin 必須かつ Host 一致 / Sec-Fetch-Site */
  function checkPromptRequest(req) {
    const host = String(req.headers.host || '').toLowerCase();
    const loop = /^(127\.0\.0\.1|localhost|\[::1\])(:\d+)?$/;
    if (!loop.test(host) && !conf.allowedHosts.includes(host)) return { ok: false, status: 403, error: 'HOST_REJECTED' };
    if (!/^application\/json(\s*;|$)/i.test(String(req.headers['content-type'] || ''))) {
      return { ok: false, status: 415, error: 'UNSUPPORTED_MEDIA_TYPE' };
    }
    const origin = req.headers.origin;
    if (!origin) return { ok: false, status: 403, error: 'ORIGIN_REQUIRED' };
    let oh = '';
    try { oh = new URL(String(origin)).host; } catch { return { ok: false, status: 403, error: 'ORIGIN_REJECTED' }; }
    if (oh !== host) return { ok: false, status: 403, error: 'ORIGIN_REJECTED' };
    const sfs = req.headers['sec-fetch-site'];
    if (sfs && sfs !== 'same-origin' && sfs !== 'none') return { ok: false, status: 403, error: 'CROSS_SITE_REJECTED' };
    return { ok: true };
  }

  /**
   * requireLaunchJwt — 実起動の追加認証。STARTUP_WEB_LAUNCH_REQUIRE_JWT=1 のとき、Access の JWT (メール付き) が無ければ拒否する。
   *   Cloudflare のエッジ認証を迂回された場合 (オリジンへの直接アクセス) でも、実起動できないようにする多層防御。
   *   Basic では代替できない (fail-closed)。拒否のときは応答まで済ませて { ok:false } を返す。
   */
  async function requireLaunchJwt(req, res, action, body, remote) {
    if (!conf.launchRequireJwt) return { ok: true, user: '' };
    let error = '';
    let detail = '';   // 監査にだけ残す内部の理由 (応答には出さない。JWKS 取得障害と不正アクセスを区別するため)
    let user = '';
    if (!conf.accessTeamDomain || !conf.accessAud) {
      error = 'AUTH_NOT_CONFIGURED';
    } else {
      const v = await verifyAccessJwt(req.headers['cf-access-jwt-assertion'], {
        teamDomain: conf.accessTeamDomain, aud: conf.accessAud, getKeys: getAccessKeys });
      // 実行者はメールで特定する (verifyAccessJwt は email が無いと sub を返すため、メールの形でなければ拒否する)
      if (!v.ok || !isEmailLike(v.email)) { error = 'AUTH_JWT_REQUIRED'; detail = v.ok ? 'NO_EMAIL' : String(v.error || ''); } else user = v.email;
    }
    if (error) {
      // 認証前の拒否は、同じ理由につき 1 分に 1 件へ間引く (監査ログの洪水を避ける)
      const nowMs = Date.now();
      const key = action + ':' + error;
      if (!(promptRejectAudit[key] && nowMs - promptRejectAudit[key] < 60000)) {
        promptRejectAudit[key] = nowMs;
        appendAudit({ action: action + '-rejected', error, detail: detail || undefined, remote,
          project: body && typeof body.project === 'string' ? body.project.slice(0, 120) : '' });
      }
      json(res, 403, { ok: false, error });
      return { ok: false };
    }
    return { ok: true, user };
  }

  /**
   * handleOpsRestart — Systemd unit の再起動 (段階 2。Approval PR)。claudeos-<project>.service だけが対象。
   *   認証は Cloudflare Access の JWT のみ (Basic では実行しない)。機能フラグが無効なら何もしない。
   *   confirm=true、機能フラグ、JWT、保護対象の拒否、日次上限、同時実行 1 件、監査ログ (JWT のメール付き) を全て満たす。
   *   成否は systemd-control.sh の終了コードで判定する (失敗を成功と誤報しない)。
   */
  async function handleOpsRestart(req, res, body, remote) {
    let user = '';
    const reject = (status, error, extra) => {
      // 認証前 (user 不明) の拒否は、同じ理由につき 1 分に 1 件へ間引く。認証後の拒否は常に記録する
      const nowMs = Date.now();
      const key = 'ops:' + error;
      if (user || !(promptRejectAudit[key] && nowMs - promptRejectAudit[key] < 60000)) {
        if (!user) promptRejectAudit[key] = nowMs;
        appendAudit({ action: 'ops-exec-rejected', op: 'systemd-restart', error, status, user, remote,
          project: typeof body.project === 'string' ? body.project.slice(0, 120) : '' });
      }
      return json(res, status, Object.assign({ ok: false, error }, extra || {}));
    };
    if (!conf.opsRestartEnabled) return reject(403, 'OPS_DISABLED');
    const chk = checkPromptRequest(req);   // Origin 必須かつ Host 一致・JSON のみ・Sec-Fetch-Site (checkMutationRequest より厳格)
    if (!chk.ok) return reject(chk.status, chk.error);
    if (!conf.accessTeamDomain || !conf.accessAud) return reject(403, 'OPS_AUTH_NOT_CONFIGURED');
    const jwt = await verifyAccessJwt(req.headers['cf-access-jwt-assertion'], {
      teamDomain: conf.accessTeamDomain, aud: conf.accessAud, getKeys: getAccessKeys });
    if (!jwt.ok) return reject(403, 'OPS_AUTH_FAILED');
    // 実行者を監査に残せない JWT では実行しない。email クレームが無い JWT は verifyAccessJwt が
    // sub を email 欄へ入れて返すため、実起動と同じ「メール形式」で判定する (BUG-09)。
    // 拒否時は user='' のままなので、監査には実行者空の ops-exec-rejected が残る。
    if (!isEmailLike(jwt.email)) return reject(403, 'OPS_AUTH_FAILED');
    user = jwt.email;
    if (body.confirm !== true) return reject(400, 'CONFIRM_REQUIRED');
    if (conf.dryRunOnly) return reject(403, 'DRY_RUN_ONLY');
    const ctx = await resolveContext();
    if (!ctx.ok) return json(res, 500, { ok: false, error: ctx.error });
    const proj = validateProject(body.project, ctx.allowed);
    if (!proj.ok) return reject(400, proj.error);
    if (isProtectedOpsTarget(proj.value)) return reject(403, 'OPS_TARGET_PROTECTED');
    if (opsExecRunning) return reject(409, 'OPS_IN_PROGRESS');
    opsExecRunning = true;
    try {
      // 日次使用量を実行前に確保する (失敗した実行も使用済みとして残す)
      const day = usageDay();
      const u0 = readPromptUsage(conf.webOpsDir, day);
      const dl = checkOpsDailyLimit(u0, conf.opsDailyMax);
      const daily = { count: u0.count, max: conf.opsDailyMax };
      if (!dl.ok) return reject(429, dl.error, { daily });
      if (!writePromptUsage(conf.webOpsDir, { day, count: u0.count + 1, spentUsd: 0 })) {
        return reject(500, 'OPS_USAGE_WRITE_FAILED', { message: '使用量の記録に失敗したため実行しません (上限を守れないため)。' });
      }
      daily.count = u0.count + 1;
      const bin = path.join(conf.root, 'bin', 'systemd-control.sh');
      const r = await runScript(bin, ['restart', proj.value], { cwd: conf.root, timeoutMs: conf.opsExecTimeoutMs, env: opsChildEnv(process.env) });
      appendAudit({ action: 'ops-restart', project: proj.value, exit: r.exitCode, user, remote });
      const clean = (t) => String(t || '').replace(/\u001b\[[0-9;]*m/g, '').trim().slice(0, 4000);
      const ok = r.exitCode === 0;
      return json(res, 200, Object.assign({
        ok, op: 'systemd-restart', project: proj.value, exitCode: r.exitCode, daily,
        output: clean(r.stdout), stderr: ok ? '' : clean(r.stderr),
      }, ok ? {} : { error: 'RESTART_FAILED' }));
    } finally {
      opsExecRunning = false;
    }
  }

  async function handlePrompt(req, res, body, remote) {
    let user = '';
    const reject = (status, error, extra) => {
      // 認証前 (user 不明) の拒否は、同じ理由につき 1 分に 1 件へ間引く。認証後の拒否は常に記録する
      const nowMs = Date.now();
      if (user || !(promptRejectAudit[error] && nowMs - promptRejectAudit[error] < 60000)) {
        if (!user) promptRejectAudit[error] = nowMs;
        appendAudit({ action: 'prompt-rejected', error, status, user, remote,
          project: typeof body.project === 'string' ? body.project.slice(0, 200) : '' });
      }
      return json(res, status, Object.assign({ ok: false, error }, extra || {}));
    };
    if (!conf.promptEnabled) {
      return reject(403, 'PROMPT_DISABLED', { message: 'プロンプト送信は無効です。有効化には STARTUP_WEB_PROMPT_ENABLE=1 と認証 (STARTUP_WEB_PASSWORD または Cloudflare Access の JWT 検証) の設定が必要です。' });
    }
    const chk = checkPromptRequest(req);
    if (!chk.ok) return reject(chk.status, chk.error);
    const au = await authenticatePrompt(req);
    if (!au.ok) return reject(403, au.error, au.detail ? { detail: au.detail } : undefined);
    user = au.user || '';

    const ctx = await resolveContext();
    if (!ctx.ok) return json(res, 500, { ok: false, error: ctx.error });
    const proj = validateProject(body.project, ctx.allowed);
    if (!proj.ok) return reject(400, proj.error);
    const text = validatePromptText(body.text);
    if (!text.ok) return reject(400, text.error, { max: text.max });
    const model = validatePromptModel(body.model);
    if (!model.ok) return reject(400, model.error);
    if (conf.dryRunOnly) return reject(403, 'DRY_RUN_ONLY');

    const dir = resolveProjectDir(ctx.state, proj.value);
    if (!dir) return reject(404, 'PROJECT_DIR_NOT_FOUND');

    const promptsNone = await supportsPermissionPromptsFlag();
    if (promptsNone === null) return reject(503, 'CLAUDE_UNAVAILABLE', { message: 'claude の機能確認 (--help) に失敗しました。' });

    // 自律実行中のプロジェクトには送らない (同じ作業ツリー・会話系譜への二重書き込みと、自律実行への混入を避ける)
    const sessionRunning = () => isProjectRunning(ctx.state, proj.value) || isSupervisorActive(proj.value);
    if (sessionRunning()) {
      return reject(409, 'SESSION_RUNNING', { message: '自律実行中のプロジェクトにはプロンプトを送れません。先に停止してください。' });
    }

    const webId = readWebLineage(conf.webPromptDir, proj.value);
    const autoId = webId ? '' : findAutonomousSessionId(conf.sessionsDir, proj.value);
    const resumeId = webId || autoId;
    const fork = !webId && !!autoId;
    const args = buildPromptArgs({
      text: text.value, resumeId, fork, model: model.value, budgetUsd: conf.promptBudgetUsd,
      permissionMode: conf.promptPermission, noPermissionPrompts: promptsNone,
    });

    const dailyLimits = { maxCount: conf.promptDailyMax, budgetUsd: conf.promptDailyBudgetUsd, perRunUsd: conf.promptBudgetUsd };
    const usageNow = readPromptUsage(conf.webPromptDir, usageDay());
    const dl = checkPromptDailyLimit(usageNow, dailyLimits);
    if (!dl.ok) {
      return reject(429, dl.error, { daily: { count: usageNow.count, max: conf.promptDailyMax, spentUsd: usageNow.spentUsd, budgetUsd: conf.promptDailyBudgetUsd },
        message: '本日の上限に達しました (翌日 0 時にリセット、または STARTUP_WEB_PROMPT_DAILY_MAX / STARTUP_WEB_PROMPT_DAILY_BUDGET_USD で変更)。' });
    }
    if (body.confirm !== true) {
      return json(res, 200, {
        ok: true, requiresConfirm: true, project: proj.value, cwd: dir,
        daily: { count: usageNow.count, max: conf.promptDailyMax, spentUsd: usageNow.spentUsd, budgetUsd: conf.promptDailyBudgetUsd },
        resumed: !!resumeId, forked: fork, model: model.value,
        permissionMode: conf.promptPermission, budgetUsd: conf.promptBudgetUsd, timeoutMs: conf.promptTimeoutMs,
        command: 'claude ' + args.slice(0, -1).join(' ') + ' <本文 ' + text.value.length + ' 文字>',
      });
    }
    if (promptActive) return reject(409, 'OPERATION_IN_PROGRESS');
    // spawn 直前に再判定 (await の間に自律実行が始まった場合の二重書き込みを避ける)
    if (isSupervisorActive(proj.value)) return reject(409, 'SESSION_RUNNING', { message: '自律実行中のプロジェクトにはプロンプトを送れません。先に停止してください。' });

    // 日次使用量を spawn 前に確保する (await の間の競合を避けるため、ここで再読込して書く)
    const usageDayKey = usageDay();
    const u0 = readPromptUsage(conf.webPromptDir, usageDayKey);
    const dl2 = checkPromptDailyLimit(u0, dailyLimits);
    if (!dl2.ok) return reject(429, dl2.error);
    const reservedUsd = conf.promptBudgetUsd;
    if (!writePromptUsage(conf.webPromptDir, { day: usageDayKey, count: u0.count + 1, spentUsd: u0.spentUsd + reservedUsd })) {
      return reject(500, 'USAGE_WRITE_FAILED', { message: '使用量の記録に失敗したため送信しません (上限を守れないため)。' });
    }

    const t0 = Date.now();
    const sha = crypto.createHash('sha256').update(text.value).digest('hex').slice(0, 12);
    const baseAudit = { project: proj.value, chars: text.value.length, sha, resumed: !!resumeId, forked: fork, model: model.value, user, remote };
    // detached: 子をプロセスグループの先頭にし、タイムアウト/切断/停止時に孫 (ツールが起動したプロセス) ごと止める
    const child = spawn(conf.claudeBin, args, { cwd: dir, env: scrubEnv(process.env, conf.promptEnvPass), stdio: ['ignore', 'pipe', 'pipe'], detached: true });
    ACTIVE_PROMPT_CHILDREN.add(child);
    promptActive = { project: proj.value, child };
    let started = false, finalized = false, aborted = false, timedOut = false, sawInit = false;
    let sessionId = '', stderrTail = '', lineBuf = '', exitTimer = null, killTimer = null, costUsd = null;

    const killGroup = (sig) => {
      if (!child.pid) return;
      try { process.kill(-child.pid, sig); } catch { try { child.kill(sig); } catch { /* 既に終了 */ } }
    };
    const groupAlive = () => {
      if (!child.pid) return false;
      try { process.kill(-child.pid, 0); return true; } catch (e) { return !!e && e.code === 'EPERM'; }
    };
    const scheduleKill = (ms) => {
      if (killTimer) return;
      killTimer = setTimeout(() => { if (groupAlive()) killGroup('SIGKILL'); }, ms);
      if (killTimer.unref) killTimer.unref();
    };
    const killChild = () => { killGroup('SIGTERM'); scheduleKill(5000); };
    const timer = setTimeout(() => { timedOut = true; killChild(); }, conf.promptTimeoutMs);

    const writeLine = (obj) => {
      if (!started || res.writableEnded || res.destroyed) return;
      const ok = res.write(JSON.stringify(obj) + '\n');
      if (!ok) {   // 遅いクライアントでメモリが膨らまないよう、drain まで子の出力を止める
        try { child.stdout.pause(); } catch { /* 終了済み */ }
        res.once('drain', () => { try { child.stdout.resume(); } catch { /* 終了済み */ } });
      }
    };
    const emitLine = (line) => {
      if (!line.trim()) return;
      let ev;
      try { ev = JSON.parse(line); } catch { writeLine({ type: 'web/raw', text: line.slice(0, 300) }); return; }
      if (ev && typeof ev.session_id === 'string' && UUID_RE.test(ev.session_id)) sessionId = ev.session_id;
      if (ev && ev.type === 'system' && ev.subtype === 'init') sawInit = true;
      if (ev && ev.type === 'result' && typeof ev.total_cost_usd === 'number' && ev.total_cost_usd >= 0) costUsd = ev.total_cost_usd;
      const out = sanitizePromptEvent(ev);
      if (out) writeLine(out);
    };
    const finalize = (code, signal) => {
      if (finalized) return;
      finalized = true;
      clearTimeout(timer);
      if (exitTimer) clearTimeout(exitTimer);
      ACTIVE_PROMPT_CHILDREN.delete(child);
      if (lineBuf) emitLine(lineBuf);
      if (groupAlive()) { killGroup('SIGTERM'); scheduleKill(3000); }   // ツールが残した孫プロセスを残さない
      let lineageReset = false;
      // 破棄するのは resume 自体が失敗したとき (会話が始まらず init が来ない) だけ。中断・タイムアウト・予算超過・ツール失敗では、
      // claude 側に会話が残っているので系譜を保持する
      if (webId && !sawInit && !aborted && !timedOut) { removeWebLineage(conf.webPromptDir, proj.value); lineageReset = true; }
      else if (sessionId) writeWebLineage(conf.webPromptDir, proj.value, sessionId, autoId);
      writeLine({ type: 'web/end', exitCode: code, signal: signal || null, sessionId, timedOut, aborted, lineageReset,
                  durationMs: Date.now() - t0, stderr: code === 0 ? '' : stderrTail.slice(-1000) });
      if (started && !res.writableEnded) res.end();
      if (promptActive && promptActive.child === child) promptActive = null;
      // 確保した予算を実コストへ精算する (コスト不明 = 予算ぶんを使ったものとして残す)
      if (costUsd !== null) {
        const cur = readPromptUsage(conf.webPromptDir, usageDayKey);
        if (!cur.corrupt) writePromptUsage(conf.webPromptDir, { day: usageDayKey, count: cur.count, spentUsd: Math.max(0, cur.spentUsd - reservedUsd + costUsd) });
      }
      appendAudit(Object.assign({ action: 'prompt', costUsd, exit: code, signal: signal || null, timedOut, aborted, lineageReset, durationMs: Date.now() - t0 }, baseAudit));
    };

    child.on('error', (e) => {
      if (started || finalized) return;   // 起動後の error は close で処理する
      finalized = true;
      clearTimeout(timer);
      ACTIVE_PROMPT_CHILDREN.delete(child);
      if (promptActive && promptActive.child === child) promptActive = null;
      { // 起動できなかった送信は使用量に数えない (誤設定の claude で上限を使い切る自己 DoS を避ける)
        const cur = readPromptUsage(conf.webPromptDir, usageDayKey);
        if (!cur.corrupt) writePromptUsage(conf.webPromptDir, { day: usageDayKey, count: Math.max(0, cur.count - 1), spentUsd: Math.max(0, cur.spentUsd - reservedUsd) });
      }
      appendAudit(Object.assign({ action: 'prompt-failed', error: 'SPAWN_FAILED' }, baseAudit));
      if (!res.headersSent) json(res, 500, { ok: false, error: 'SPAWN_FAILED', detail: String(e && e.message).slice(0, 200) });
    });
    child.once('spawn', () => {
      started = true;
      appendAudit(Object.assign({ action: 'prompt-start' }, baseAudit));
      res.writeHead(200, { 'Content-Type': 'application/x-ndjson; charset=utf-8', 'Cache-Control': 'no-store', 'X-Accel-Buffering': 'no' });
      writeLine({ type: 'web/start', project: proj.value, resumed: !!resumeId, forked: fork, model: model.value });
    });
    child.stdout.on('data', (d) => {
      lineBuf += d.toString('utf8');
      let i;
      while ((i = lineBuf.indexOf('\n')) >= 0) { const line = lineBuf.slice(0, i); lineBuf = lineBuf.slice(i + 1); emitLine(line); }
      if (lineBuf.length > 1048576) lineBuf = '';
    });
    child.stderr.on('data', (d) => { stderrTail = (stderrTail + d.toString('utf8')).slice(-4000); });
    res.on('close', () => { if (!finalized) { aborted = true; killChild(); } });
    // 孫が stdout を握ったままだと 'close' が来ないため、'exit' から一定時間で必ず確定してロックを解放する
    child.on('exit', (code, signal) => { exitTimer = setTimeout(() => finalize(code, signal), 3000); });
    child.on('close', (code, signal) => finalize(code, signal));
  }

  /** handleLog — ログ閲覧 (~/.claudeos 配下のみ) */
  async function handleLog(req, res, url) {
    const ctx = await resolveContext();
    if (!ctx.ok) return json(res, 500, { ok: false, error: ctx.error });
    const name = url.searchParams.get('project');
    const proj = validateProject(name, ctx.allowed);
    if (!proj.ok) return json(res, 400, { ok: false, error: proj.error });
    const target = ctx.state.projects.find(p => p.name === proj.value) || {};
    let file = resolveLogFile(target.log_file);
    if (!file) {
      // 登録外のサブフォルダ (all_folders 由来) は state に log_file が無い。
      // supervisor が書く既定のログ (~/.claudeos/supervisor/<safe>.log) があればそれを返す。
      const cand = resolveLogFile(path.join(conf.supervisorDir, safeProjectName(proj.value) + '.log'));
      if (cand && fs.existsSync(cand)) file = cand;
    }
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
      if (!isCronSchedule([m[1], m[2], m[3], m[4], m[5]])) return;   // 説明コメントを除外
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
      // commit/version は「いま動いている成果物」の識別子 (配備後の同一性確認用)。
      // 既存キー (ok/service/dryRunOnly) は後方互換のため維持する。
      return json(res, 200, {
        ok: true, service: 'claudeos-web-startup', dryRunOnly: conf.dryRunOnly,
        commit: buildInfo.commit, version: buildInfo.version,
      });
    }

    if (!checkBasicAuth(req.headers['authorization'], conf.authUser, conf.authPass)) {
      res.writeHead(401, { 'WWW-Authenticate': 'Basic realm="ClaudeOS Web Startup"', 'Content-Type': 'text/plain; charset=utf-8' });
      return res.end('401 Unauthorized');
    }

    if (req.method !== 'GET' && req.method !== 'HEAD') {
      if (!checkOrigin(req.headers.origin, req.headers.host)) {
        return json(res, 403, { ok: false, error: 'ORIGIN_REJECTED' });
      }
      // プロンプト送信と Systemd 再起動は各ハンドラ内でより厳格に検査する。それ以外の変更系はここで共通検査する
      if (pn !== '/api/session/prompt' && pn !== '/api/ops/systemd/restart') {
        const mg = checkMutationRequest(req);
        if (!mg.ok) {
          const nowMs = Date.now();
          if (!(promptRejectAudit[mg.error] && nowMs - promptRejectAudit[mg.error] < 60000)) {
            promptRejectAudit[mg.error] = nowMs;
            appendAudit({ action: 'mutation-rejected', error: mg.error, path: pn, remote });
          }
          return json(res, mg.status, { ok: false, error: mg.error });
        }
      }
    }

    try {
      if (pn === '/api/startup/state' && req.method === 'GET') {
        // ?refresh=1: UI の「再読み込み」。20 秒キャッシュを捨てて再走査する。
        // 連打で全フォルダ走査 (370 件で約 12 秒) が重なるのを避けるため、直近 3 秒以内は捨てない。
        if (url.searchParams.get('refresh') === '1' && stateCache && (Date.now() - stateCache.at) > 3000) {
          invalidateState();
        }
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
        let who = '';
        if (b.value && b.value.confirm === true && !conf.dryRunOnly) {   // 実起動のときだけ (計画の表示は従来どおり)
          const a = await requireLaunchJwt(req, res, 'launch', b.value, remote);
          if (!a.ok) return;
          who = a.user;
        }
        return handleLaunch(res, b.value, remote, who);
      }
      if (req.method === 'POST' && pn === '/api/startup/stop') {
        const b = await readBody(req);
        if (!b.ok) return json(res, 400, { ok: false, error: b.error });
        return handleStop(res, b.value, remote);
      }
      if (req.method === 'POST' && pn === '/api/session/prompt') {
        const b = await readBody(req);
        if (!b.ok) return json(res, 400, { ok: false, error: b.error });
        if (!b.value || typeof b.value !== 'object' || Array.isArray(b.value)) return json(res, 400, { ok: false, error: 'BODY_NOT_OBJECT' });
        return await handlePrompt(req, res, b.value, remote);
      }
      if (req.method === 'POST' && pn === '/api/ops/systemd/restart') {
        const b = await readBody(req);
        if (!b.ok) return json(res, 400, { ok: false, error: b.error });
        if (!b.value || typeof b.value !== 'object' || Array.isArray(b.value)) return json(res, 400, { ok: false, error: 'BODY_NOT_OBJECT' });
        return await handleOpsRestart(req, res, b.value, remote);
      }
      if (req.method === 'POST' && pn === '/api/ops/plan') {
        const b = await readBody(req);
        if (!b.ok) return json(res, 400, { ok: false, error: b.error });
        if (!b.value || typeof b.value !== 'object' || Array.isArray(b.value)) return json(res, 400, { ok: false, error: 'BODY_NOT_OBJECT' });
        return handleOpsPlan(res, b.value, remote);
      }
      if (req.method === 'POST' && pn === '/api/startup/apply-all') {
        const b = await readBody(req);
        if (!b.ok) return json(res, 400, { ok: false, error: b.error });
        let who = '';
        if (b.value && b.value.confirm === true && !conf.dryRunOnly) {
          const a = await requireLaunchJwt(req, res, 'apply-all', b.value, remote);
          if (!a.ok) return;
          who = a.user;
        }
        return handleApplyAll(res, b.value, remote, who);
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

      /* Ship Native Control Center (v5.0)。GET は読み取り専用の集約。POST は承認の取り消し (安全側) のみで、
         Access JWT (メール付き) を必須にする。承認 (approve) の経路は意図的に無い (scripts/web/ship-api.js 参照)。 */
      if (pn.startsWith('/api/ship/')) {
        let shipApi;
        try { shipApi = require('./ship-api.js'); } catch { return json(res, 503, { ok: false, error: 'SHIP_API_UNAVAILABLE' }); }
        return await shipApi.handle(req, res, url, {
          json, readBody, checkStrict: checkPromptRequest,
          authEmail: async (r) => {
            if (!conf.accessTeamDomain || !conf.accessAud) return { ok: false, status: 403, error: 'SHIP_AUTH_NOT_CONFIGURED' };
            if (!r.headers['cf-access-jwt-assertion']) return { ok: false, status: 401, error: 'AUTH_JWT_REQUIRED' };
            const v = await verifyAccessJwt(r.headers['cf-access-jwt-assertion'], {
              teamDomain: conf.accessTeamDomain, aud: conf.accessAud, getKeys: getAccessKeys });
            if (!v.ok || !isEmailLike(v.email)) return { ok: false, status: 403, error: 'SHIP_AUTH_FAILED' };
            return { ok: true, email: v.email };
          },
          onReject: (info) => {   // 認証前の拒否は同じ理由につき 1 分に 1 件へ間引く (handleOpsRestart と同じ)
            const nowMs = Date.now(); const key = 'ship:' + info.error;
            if (promptRejectAudit[key] && nowMs - promptRejectAudit[key] < 60000) return;
            promptRejectAudit[key] = nowMs;
            appendAudit({ action: 'ship-revoke-rejected', error: info.error, status: info.status, remote });
          },
        });
      }

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

  const shutdown = () => { killActivePrompts(); server.close(() => process.exit(0)); setTimeout(() => process.exit(0), 2000); };
  process.on('SIGTERM', shutdown);
  process.on('SIGINT', shutdown);
}

module.exports = {
  createServer, parseArgs, usage, main,
  safeEqual, isLoopback, validateProject, validateMode, validateGoal, validateDuration,
  sanitizeIntent, buildLaunchArgs, buildStopArgs, buildApplyAllArgs, parseState,
  projectNames, isCronSchedule, supervisorStateFile, resolveLogFile,
  scrubEnv, usageDay, readPromptUsage, writePromptUsage, checkPromptDailyLimit, checkOpsDailyLimit, isProtectedOpsTarget, opsChildEnv, validatePromptText, validatePromptModel, findAutonomousSessionId, buildPromptArgs,
  resolveProjectDir, readWebLineage, writeWebLineage, removeWebLineage, PROMPT_MAX_CHARS,
  positiveNumber, sanitizePromptEvent, verifyAccessJwt, webLineageFile, isProjectRunning, resolveStaticPath, tailLines, checkBasicAuth, checkOrigin,
  isEmailLike,
  auditLine, MODES, MODE_LABELS, DEFAULT_PORT, resolveBuildInfo,
  appendAudit, auditRotateConfig, rotateAuditLog,
};

if (require.main === module) main();
