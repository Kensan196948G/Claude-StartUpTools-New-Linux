'use strict';
/**
 * store.js — ClaudeOS Ship Native の永続化契約 (正本)
 *
 * 置き場 (CLAUDEOS_SHIP_HOME で上書き可。既定 $CLAUDEOS_HOME/ship):
 *   runs/<run_id>.json                          Ship Native run (状態機械)
 *   quality/<slug>/<sha>/<eval_id>.json         Local Quality Engine の証跡 (HMAC 付き)
 *   gates/<slug>/pr-<n>/<head>.json             AI Quality Gate の判定
 *   approvals/<slug>/pr-<n>/<approval_id>.json  Human Gate の署名済み承認
 *   revocations/<approval_id>.json              承認取り消し
 *   consumed/<nonce>                            承認の使用済み nonce (リプレイ防止)
 *   merges/<slug>/pr-<n>.json                   マージ実行結果 (API 再取得で確認済みのみ MERGED)
 *   audit.jsonl                                 監査イベント (prev_hash で連鎖)
 *
 * slug = owner__repo (owner/repo の '/' を '__' へ)。
 *
 * 秘密情報は書かない: 全レコードは writeRecord() 経由で redact() を通す。
 */

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');

const SCHEMA = {
  run: 'claudeos.ship-run/v1',
  quality: 'claudeos.ship-quality/v1',
  gate: 'claudeos.ship-gate/v1',
  approval: 'claudeos.ship-approval/v1',
  revocation: 'claudeos.ship-revocation/v1',
  merge: 'claudeos.ship-merge/v1',
  audit: 'claudeos.ship-audit/v1',
};

function shipHome() {
  if (process.env.CLAUDEOS_SHIP_HOME) return path.resolve(process.env.CLAUDEOS_SHIP_HOME);
  const base = process.env.CLAUDEOS_HOME || path.join(os.homedir(), '.claudeos');
  return path.join(path.resolve(base), 'ship');
}

const REPO_RE = /^[A-Za-z0-9_.-]{1,100}\/[A-Za-z0-9_.-]{1,100}$/;
const SHA_RE = /^[0-9a-f]{40}$/;
const ID_RE = /^[A-Za-z0-9_-]{6,80}$/;

function assertRepo(repo) {
  if (typeof repo !== 'string' || !REPO_RE.test(repo) || repo.includes('..')) throw new Error('INVALID_REPO');
  return repo;
}
function assertSha(sha, label = 'sha') {
  if (typeof sha !== 'string' || !SHA_RE.test(sha)) throw new Error('INVALID_' + label.toUpperCase());
  return sha;
}
function assertPr(n) {
  const v = Number(n);
  if (!Number.isInteger(v) || v <= 0 || v > 10_000_000) throw new Error('INVALID_PR');
  return v;
}
function assertId(id) {
  if (typeof id !== 'string' || !ID_RE.test(id)) throw new Error('INVALID_ID');
  return id;
}
function slug(repo) { return assertRepo(repo).replace('/', '__'); }

/** canonical — キー順を固定した JSON (署名・ハッシュ対象の正規形) */
function canonical(value) {
  if (value === null || typeof value !== 'object') return JSON.stringify(value);
  if (Array.isArray(value)) return '[' + value.map(canonical).join(',') + ']';
  const keys = Object.keys(value).filter((k) => value[k] !== undefined).sort();
  return '{' + keys.map((k) => JSON.stringify(k) + ':' + canonical(value[k])).join(',') + '}';
}
function sha256(data) { return crypto.createHash('sha256').update(data).digest('hex'); }
function newId(prefix) {
  return `${prefix}_${Date.now().toString(36)}_${crypto.randomBytes(6).toString('hex')}`;
}

// --- 秘密情報の除去 (トークン・鍵・接続文字列らしきもの) ---
const SECRET_RES = [
  /gh[pousr]_[A-Za-z0-9]{20,}/g,
  /github_pat_[A-Za-z0-9_]{20,}/g,
  /sk-[A-Za-z0-9_-]{20,}/g,
  /xox[abpr]-[A-Za-z0-9-]{10,}/g,
  /-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----/g,
  /(postgres(?:ql)?:\/\/)[^\s'"@]+@/gi,
  /(authorization:\s*)(bearer|token|basic)\s+[^\s'"]+/gi,
];
function redactString(s) {
  let out = s;
  for (const re of SECRET_RES) {
    out = out.replace(re, (m, p1) => (typeof p1 === 'string' && /^(postgres|authorization)/i.test(p1) ? p1 + '[REDACTED]@' : '[REDACTED]'));
  }
  return out;
}
function redact(value) {
  if (typeof value === 'string') return redactString(value);
  if (Array.isArray(value)) return value.map(redact);
  if (value && typeof value === 'object') {
    const o = {};
    for (const [k, v] of Object.entries(value)) {
      o[k] = /^(token|password|secret|private_?key|passphrase|authorization)$/i.test(k) ? '[REDACTED]' : redact(v);
    }
    return o;
  }
  return value;
}

function ensureDir(dir) { fs.mkdirSync(dir, { recursive: true, mode: 0o700 }); }

/** writeRecord — 原子的に書く (tmp → rename)。既存を上書きしない exclusive も選べる */
function writeRecord(file, obj, { exclusive = false } = {}) {
  ensureDir(path.dirname(file));
  const body = JSON.stringify(redact(obj), null, 2) + '\n';
  if (exclusive) {
    fs.writeFileSync(file, body, { flag: 'wx', mode: 0o600 });
    return file;
  }
  const tmp = `${file}.${process.pid}.${crypto.randomBytes(4).toString('hex')}.tmp`;
  fs.writeFileSync(tmp, body, { mode: 0o600 });
  fs.renameSync(tmp, file);
  return file;
}
function readRecord(file) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch { return null; }
}
function listJson(dir) {
  try {
    return fs.readdirSync(dir).filter((f) => f.endsWith('.json')).map((f) => path.join(dir, f));
  } catch { return []; }
}

const paths = {
  run: (id) => path.join(shipHome(), 'runs', assertId(id) + '.json'),
  runsDir: () => path.join(shipHome(), 'runs'),
  qualityDir: (repo, sha) => path.join(shipHome(), 'quality', slug(repo), assertSha(sha)),
  quality: (repo, sha, id) => path.join(shipHome(), 'quality', slug(repo), assertSha(sha), assertId(id) + '.json'),
  gate: (repo, pr, head) => path.join(shipHome(), 'gates', slug(repo), 'pr-' + assertPr(pr), assertSha(head, 'head') + '.json'),
  gatesDir: (repo, pr) => path.join(shipHome(), 'gates', slug(repo), 'pr-' + assertPr(pr)),
  approvalsDir: (repo, pr) => path.join(shipHome(), 'approvals', slug(repo), 'pr-' + assertPr(pr)),
  approval: (repo, pr, id) => path.join(shipHome(), 'approvals', slug(repo), 'pr-' + assertPr(pr), assertId(id) + '.json'),
  revocation: (id) => path.join(shipHome(), 'revocations', assertId(id) + '.json'),
  consumed: (nonce) => path.join(shipHome(), 'consumed', assertId(nonce)),
  merge: (repo, pr) => path.join(shipHome(), 'merges', slug(repo), 'pr-' + assertPr(pr) + '.json'),
  audit: () => path.join(shipHome(), 'audit.jsonl'),
  hmacKey: () => path.join(shipHome(), 'keys', 'evidence-hmac.key'),
  locks: () => path.join(shipHome(), 'locks'),
};

// --- 監査ログ (prev_hash 連鎖。改ざん検出用。改ざん防止は OS 権限分離が必要 — docs 参照) ---
function lastAuditHash(file) {
  try {
    const data = fs.readFileSync(file, 'utf8').trimEnd();
    if (!data) return null;
    const last = data.slice(data.lastIndexOf('\n') + 1);
    return JSON.parse(last).hash || null;
  } catch { return null; }
}
function appendAudit(event, fields = {}) {
  const file = paths.audit();
  ensureDir(path.dirname(file));
  const entry = redact({
    schema: SCHEMA.audit,
    ts: new Date().toISOString(),
    event: String(event),
    actor: fields.actor || process.env.CLAUDEOS_SHIP_ACTOR || 'claudeos',
    ...fields,
  });
  entry.prev_hash = lastAuditHash(file);
  entry.hash = sha256(canonical({ ...entry, hash: undefined }));
  fs.appendFileSync(file, JSON.stringify(entry) + '\n', { mode: 0o600 });
  return entry;
}
function verifyAuditChain(file = paths.audit()) {
  let prev = null; let n = 0;
  let text = '';
  try { text = fs.readFileSync(file, 'utf8'); } catch { return { ok: true, entries: 0 }; }
  for (const line of text.split('\n')) {
    if (!line.trim()) continue;
    n++;
    let e;
    try { e = JSON.parse(line); } catch { return { ok: false, entries: n, error: 'PARSE', at: n }; }
    if (e.prev_hash !== prev) return { ok: false, entries: n, error: 'CHAIN_BROKEN', at: n };
    const expect = sha256(canonical({ ...e, hash: undefined }));
    if (expect !== e.hash) return { ok: false, entries: n, error: 'HASH_MISMATCH', at: n };
    prev = e.hash;
  }
  return { ok: true, entries: n };
}

/** withLock — 同一キーの排他 (PR 単位の同時修正・二重マージを防ぐ)。取れなければ null */
function withLock(key, fn) {
  ensureDir(paths.locks());
  const file = path.join(paths.locks(), key.replace(/[^A-Za-z0-9_.-]/g, '_') + '.lock');
  let fd;
  try {
    fd = fs.openSync(file, 'wx', 0o600);
  } catch (e) {
    if (e.code !== 'EEXIST') throw e;
    // 古いロック (所有プロセスが死んでいる) は回収する
    const holder = Number(String(fs.readFileSync(file, 'utf8')).trim());
    let alive = false;
    if (Number.isInteger(holder) && holder > 0) {
      try { process.kill(holder, 0); alive = true; } catch (err) { alive = err.code === 'EPERM'; }
    }
    if (alive) return { locked: false, holder };
    fs.rmSync(file, { force: true });
    fd = fs.openSync(file, 'wx', 0o600);
  }
  try {
    fs.writeSync(fd, String(process.pid));
    return { locked: true, value: fn() };
  } finally {
    fs.closeSync(fd);
    fs.rmSync(file, { force: true });
  }
}

module.exports = {
  SCHEMA, shipHome, paths, slug, canonical, sha256, newId, redact,
  assertRepo, assertSha, assertPr, assertId,
  writeRecord, readRecord, listJson, ensureDir,
  appendAudit, verifyAuditChain, withLock,
};
