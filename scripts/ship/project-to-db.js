#!/usr/bin/env node
'use strict';
/**
 * project-to-db.js — Ship Native ファイルストア → claudeos_control (migration 0006) の射影
 *
 * 正本はファイルストア (scripts/ship/lib/store.js)。DB は検索・監査用の射影であり、
 * ここで生成する SQL は何度流しても同じ結果になる (冪等):
 *   - 追記専用表は INSERT ... ON CONFLICT (<自然キー>) DO NOTHING
 *   - 可変表 (ship_sessions) は source_updated_at が新しい時だけ上書き
 *   - 全体を 1 トランザクションにまとめ、1 件でも DB 制約に反したら全体をロールバック
 *
 * 使い方:
 *   node scripts/ship/project-to-db.js [--home DIR]                 dry-run (既定)。件数と除外理由の JSON を出す
 *   node scripts/ship/project-to-db.js --sql [--home DIR]           SQL を stdout へ
 *   node scripts/ship/project-to-db.js --apply --db NAME [--role R|none] [--home DIR]
 *                                                                   psql (Unix socket) で適用
 *   共通: --policy-file FILE  policy_versions.content_sha256 を埋める
 *         --strict            除外レコードが 1 件でもあれば exit 3 (適用もしない)
 *
 * 安全規約:
 *   - psql は spawnSync(引数配列) で起動し、シェル文字列を組み立てない。SQL は stdin で渡す。
 *   - 値は sqlLiteral() で単一引用符を二重化した標準文字列リテラルにする
 *     (standard_conforming_strings = on をトランザクション内で強制)。NUL / 不正 UTF-16 は拒否。
 *   - HMAC 値・鍵・秘密鍵・passphrase は射影しない。秘密らしき文字列を含むレコードは除外する。
 *   - 接続は PGHOST (既定 /var/run/postgresql) の peer 認証のみ。接続文字列を受け付けない。
 *
 * 終了コード: 0=成功 / 1=psql 適用失敗 / 2=引数エラー / 3=--strict で除外あり
 */

const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const store = require('./lib/store');
const sm = require('./lib/state-machine');

// ------------------------------------------------------------
// SQL リテラル
// ------------------------------------------------------------

/** assertCleanString — NUL と不正な UTF-16 (孤立サロゲート) を拒否する */
function assertCleanString(s) {
  if (s.includes('\u0000')) throw new Error('NUL_BYTE');
  if (typeof s.isWellFormed === 'function' ? !s.isWellFormed() : /[\uD800-\uDFFF]/.test(s.replace(/[\uD800-\uDBFF][\uDC00-\uDFFF]/g, ''))) {
    throw new Error('MALFORMED_UNICODE');
  }
  return s;
}

/**
 * sqlLiteral(v) — 値を SQL リテラルへ。
 *   null/undefined → NULL、boolean → TRUE/FALSE、有限数 → 数値、string → '...' (' を '' に)。
 *   standard_conforming_strings = on 前提 (バックスラッシュはそのままの文字)。
 */
function sqlLiteral(v) {
  if (v === null || v === undefined) return 'NULL';
  if (typeof v === 'boolean') return v ? 'TRUE' : 'FALSE';
  if (typeof v === 'number') {
    if (!Number.isFinite(v)) throw new Error('NON_FINITE_NUMBER');
    return String(v);
  }
  if (typeof v === 'bigint') return v.toString();
  if (typeof v === 'string') return "'" + assertCleanString(v).replace(/'/g, "''") + "'";
  throw new Error('UNSUPPORTED_LITERAL_TYPE ' + typeof v);
}

/** deepAssertClean — jsonb に入れる値の全文字列 (キー含む) を検査 */
function deepAssertClean(value) {
  if (typeof value === 'string') { assertCleanString(value); return; }
  if (Array.isArray(value)) { value.forEach(deepAssertClean); return; }
  if (value && typeof value === 'object') {
    for (const [k, v] of Object.entries(value)) { assertCleanString(k); deepAssertClean(v); }
  }
}

/** sqlJson(obj) — jsonb リテラル */
function sqlJson(obj) {
  deepAssertClean(obj);
  return sqlLiteral(JSON.stringify(obj === undefined ? null : obj)) + '::jsonb';
}

/** sqlTs(iso) — timestamptz リテラル (正規化した ISO 8601) */
function sqlTs(v) {
  if (v === null || v === undefined) return 'NULL';
  return sqlLiteral(toIso(v)) + '::timestamptz';
}

// ------------------------------------------------------------
// 検証ヘルパ (DB 側の CHECK / ドメインと同じ規則を先に当て、違反レコードは除外する)
// ------------------------------------------------------------
const SHA40 = /^[0-9a-f]{40}$/;
const HEX64 = /^[0-9a-f]{64}$/;
const KEY_ID = /^sha256:[0-9a-f]{64}$/;
const SIG_B64 = /^(?=.{16,2048}$)[A-Za-z0-9+/]+={0,2}$/;
const POLICY_VERSION = /^[0-9A-Za-z][0-9A-Za-z._+-]{0,63}$/;
const STATES = new Set(sm.STATES);
const MODES = new Set(['SH1', 'SH2', 'SH3', 'SH4', 'SH5', 'QC', 'HG']);
const RISKS = new Set(['R0', 'R1', 'R2', 'R3', 'R4']);
const GATE_VERDICTS = new Set(['PASS', 'CONDITIONAL', 'FAIL', 'UNKNOWN', 'BLOCKED']);
const QUALITY_VERDICTS = new Set(['PASS', 'FAIL', 'UNKNOWN']);
const CHECK_STATUSES = new Set(['PASS', 'FAIL', 'ERROR', 'NOT_RUN']);
const DECISIONS = new Set(['approve', 'approve-conditional', 'reject']);
const MERGE_STATES = new Set(['MERGED', 'MERGED_UNEXPECTED_HEAD', 'MERGE_QUEUED', 'OPEN', 'CLOSED', 'UNKNOWN']);
const WATCH_STATUSES = new Set(['checks-pass-comments-answered', 'stopped', 'not-started', 'running']);

// control.safe_text と同じ拒否パターン (0001_foundation.sql)
const SAFE_TEXT_DENY = [
  /:\/\/[^/@\s]+:[^/@\s]+@/i,
  /(postgres(ql)?|mysql|mongodb(\+srv)?|redis|amqps?):\/\//i,
  /(sk-ant-|ghp_[A-Za-z0-9]{10}|gho_[A-Za-z0-9]{10}|github_pat_|AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY-----)/i,
  /(password|passwd|secret|api[_-]?key|access[_-]?token|bearer)\s*[=:]\s*\S{8,}/i,
];
// control.jsonb_free_of_credentials と同じ拒否パターン (0006)
const JSON_DENY = [
  /(-----BEGIN [A-Z ]*PRIVATE KEY-----|sk-ant-|github_pat_|ghp_[A-Za-z0-9]{10}|AKIA[0-9A-Z]{16})/i,
  /(postgres(ql)?|mysql|mongodb(\+srv)?|redis):\/\/[^"\s]*:[^"\s]*@/i,
];

class RecordError extends Error {}
function bad(reason) { throw new RecordError(reason); }

function toIso(v) {
  const t = typeof v === 'string' || typeof v === 'number' ? Date.parse(v) : (v instanceof Date ? v.getTime() : NaN);
  if (!Number.isFinite(t)) bad('INVALID_TIMESTAMP');
  return new Date(t).toISOString();
}
function reqTs(v, label) { if (v === null || v === undefined) bad('MISSING_' + label); return toIso(v); }
function optTs(v) { return v === null || v === undefined ? null : toIso(v); }
function reqSha(v, label) { if (typeof v !== 'string' || !SHA40.test(v)) bad('INVALID_' + label); return v; }
function optSha(v, label) { return v === null || v === undefined || v === '' ? null : reqSha(v, label); }
function reqRepo(v) { try { return store.assertRepo(v); } catch { return bad('INVALID_REPO'); } }
function reqPr(v) { try { return store.assertPr(v); } catch { return bad('INVALID_PR'); } }
function optPr(v) { return v === null || v === undefined ? null : reqPr(v); }
function reqId(v, label) { if (typeof v !== 'string' || !/^[A-Za-z0-9_-]{6,80}$/.test(v)) bad('INVALID_' + label); return v; }
function optId(v, label) { return v === null || v === undefined ? null : reqId(v, label); }
function oneOf(set, v, label) { if (!set.has(v)) bad('INVALID_' + label); return v; }
function optPolicy(v) {
  if (v === null || v === undefined) return null;
  if (typeof v !== 'string' || !POLICY_VERSION.test(v)) bad('INVALID_POLICY_VERSION');
  return v;
}
function safeText(v, label, { required = false, max = 4000 } = {}) {
  if (v === null || v === undefined) { if (required) bad('MISSING_' + label); return null; }
  const s = String(v);
  try { assertCleanString(s); } catch (e) { bad(e.message + '_' + label); }
  if (SAFE_TEXT_DENY.some((re) => re.test(s))) bad('SECRET_PATTERN_' + label);
  return s.length > max ? s.slice(0, max) : s;
}
function safeJson(v, label) {
  try { deepAssertClean(v); } catch (e) { bad(e.message + '_' + label); }
  const text = JSON.stringify(v);
  if (JSON_DENY.some((re) => re.test(text))) bad('SECRET_PATTERN_' + label);
  return v;
}
function nonNegIntOrNull(v, label) {
  if (v === null || v === undefined) return null;
  const n = Number(v);
  if (!Number.isInteger(n) || n < 0) bad('INVALID_' + label);
  return n;
}
function intOrNull(v, label) {
  if (v === null || v === undefined) return null;
  const n = Number(v);
  if (!Number.isInteger(n) || Math.abs(n) > 2147483647) bad('INVALID_' + label);
  return n;
}
function simpleToken(v, re, label) {
  if (v === null || v === undefined) return null;
  if (typeof v !== 'string' || !re.test(v)) bad('INVALID_' + label);
  return v;
}

/** projectKey(repo) — control.projects.project_key (^[a-z0-9][a-z0-9._-]{0,126}$) を repo から決定的に作る */
function projectKey(repo) {
  const k = 'gh.' + repo.toLowerCase().replace('/', '__');
  if (/^[a-z0-9][a-z0-9._-]{0,126}$/.test(k)) return k;
  return 'gh.' + store.sha256(repo.toLowerCase()).slice(0, 40);
}

// ------------------------------------------------------------
// ストアの走査
// ------------------------------------------------------------
function listDirs(dir) {
  try { return fs.readdirSync(dir, { withFileTypes: true }).filter((d) => d.isDirectory()).map((d) => path.join(dir, d.name)); } catch { return []; }
}
function listFiles(dir) {
  try { return fs.readdirSync(dir, { withFileTypes: true }).filter((d) => d.isFile()).map((d) => path.join(dir, d.name)); } catch { return []; }
}
function rel(file) { return path.relative(store.shipHome(), file); }

/** readStore(home) — 全レコードを読み、{kind, file, rec} の配列にする (中身の検証はしない) */
function readStore() {
  const home = store.shipHome();
  const out = [];
  const pushJson = (kind, file) => out.push({ kind, file, rec: store.readRecord(file) });
  for (const f of store.listJson(path.join(home, 'runs'))) pushJson('run', f);
  for (const s of listDirs(path.join(home, 'quality'))) {
    for (const shaDir of listDirs(s)) for (const f of store.listJson(shaDir)) pushJson('quality', f);
  }
  for (const s of listDirs(path.join(home, 'gates'))) {
    for (const prDir of listDirs(s)) for (const f of store.listJson(prDir)) pushJson('gate', f);
  }
  for (const s of listDirs(path.join(home, 'ship-evidence'))) {
    for (const prDir of listDirs(s)) for (const f of store.listJson(prDir)) pushJson('attestation', f);
  }
  for (const s of listDirs(path.join(home, 'approvals'))) {
    for (const prDir of listDirs(s)) for (const f of store.listJson(prDir)) pushJson('approval', f);
  }
  for (const f of store.listJson(path.join(home, 'revocations'))) pushJson('revocation', f);
  for (const f of listFiles(path.join(home, 'consumed'))) {
    let approvalId = null; let mtime = null;
    try { approvalId = fs.readFileSync(f, 'utf8').trim(); mtime = fs.statSync(f).mtime; } catch { /* 除外理由で拾う */ }
    out.push({ kind: 'consumption', file: f, rec: { nonce: path.basename(f), approval_id: approvalId, consumed_at: mtime } });
  }
  for (const s of listDirs(path.join(home, 'merges'))) for (const f of store.listJson(s)) pushJson('merge', f);
  let audit = '';
  try { audit = fs.readFileSync(store.paths.audit(), 'utf8'); } catch { /* 無ければ空 */ }
  audit.split('\n').forEach((line, i) => {
    if (!line.trim()) return;
    let rec = null;
    try { rec = JSON.parse(line); } catch { rec = null; }
    out.push({ kind: 'audit', file: store.paths.audit(), line: i + 1, rec, raw: line });
  });
  return out;
}

// ------------------------------------------------------------
// レコード → 正規化値
// ------------------------------------------------------------
function sealBody(rec) {
  const body = { ...rec };
  delete body.evidence_hash;
  delete body.hmac;
  return store.canonical(body);
}

const normalizers = {
  run(r) {
    const repo = reqRepo(r.repo);
    const history = Array.isArray(r.history) ? r.history : [];
    return {
      run_id: reqId(r.run_id, 'RUN_ID'), repo, pr: optPr(r.pr),
      project_dir: safeText(r.project_dir, 'PROJECT_DIR'),
      mode: oneOf(MODES, r.mode, 'MODE'), state: oneOf(STATES, r.state, 'STATE'),
      head_sha: optSha(r.head_sha, 'HEAD_SHA'), base_sha: optSha(r.base_sha, 'BASE_SHA'),
      branch: r.branch === null || r.branch === undefined ? null
        : (typeof r.branch === 'string' && r.branch.length >= 1 && r.branch.length <= 255 && !/[\s\x00-\x1f\x7f]/.test(r.branch) ? r.branch : bad('INVALID_BRANCH')),
      ship_capability: simpleToken(r.ship && r.ship.capability, /^[A-Za-z0-9_.-]{1,64}$/, 'SHIP_CAPABILITY'),
      ship_status: simpleToken(r.ship && r.ship.status, /^[A-Za-z0-9_.-]{1,64}$/, 'SHIP_STATUS'),
      retries: nonNegIntOrNull(r.retries, 'RETRIES') || 0,
      created_at: reqTs(r.created_at, 'CREATED_AT'), updated_at: reqTs(r.updated_at, 'UPDATED_AT'),
      history: history.map((h, i) => ({
        seq: i, from: oneOf(STATES, h && h.from, 'HISTORY_FROM'), to: oneOf(STATES, h && h.to, 'HISTORY_TO'),
        at: reqTs(h && h.at, 'HISTORY_AT'),
        evidence: safeJson(h && h.evidence && typeof h.evidence === 'object' && !Array.isArray(h.evidence) ? h.evidence : {}, 'HISTORY_EVIDENCE'),
      })),
    };
  },
  quality(r) {
    if (typeof r.evidence_hash !== 'string' || !HEX64.test(r.evidence_hash)) bad('INVALID_EVIDENCE_HASH');
    // 内容の改ざん検出 (HMAC は鍵が要るので検証しない。HMAC 値も DB へ入れない)
    if (store.sha256(sealBody(r)) !== r.evidence_hash) bad('EVIDENCE_HASH_MISMATCH');
    const verdict = oneOf(QUALITY_VERDICTS, r.verdict, 'VERDICT');
    const finished = optTs(r.finished_at);
    if (verdict === 'PASS' && !finished) bad('PASS_WITHOUT_FINISHED_AT');
    const started = reqTs(r.started_at, 'STARTED_AT');
    if (finished && Date.parse(finished) < Date.parse(started)) bad('FINISHED_BEFORE_STARTED');
    const checks = (Array.isArray(r.checks) ? r.checks : []).map((c, i) => {
      if (!c || typeof c !== 'object') bad('INVALID_CHECK');
      const status = oneOf(CHECK_STATUSES, c.status, 'CHECK_STATUS');
      const exit = intOrNull(c.exit_code, 'CHECK_EXIT_CODE');
      const failed = nonNegIntOrNull(c.failed, 'CHECK_FAILED');
      if (status === 'PASS' && (exit !== 0 || (failed || 0) !== 0)) bad('CHECK_PASS_INCONSISTENT');
      return {
        seq: i, id: simpleToken(c.id, /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/, 'CHECK_ID') || bad('MISSING_CHECK_ID'),
        category: simpleToken(c.category, /^[a-z0-9][a-z0-9+_.-]{0,63}$/, 'CHECK_CATEGORY'),
        command: safeText(c.cmd, 'CHECK_CMD'), status, exit_code: exit,
        passed: nonNegIntOrNull(c.passed, 'CHECK_PASSED'), failed, skipped: nonNegIntOrNull(c.skipped, 'CHECK_SKIPPED'),
        duration_ms: nonNegIntOrNull(c.duration_ms, 'CHECK_DURATION') || 0,
        reason: safeText(c.reason, 'CHECK_REASON'), log_ref: safeText(c.log_file, 'CHECK_LOG'),
      };
    });
    if (checks.length > 32767) bad('TOO_MANY_CHECKS');
    return {
      eval_id: reqId(r.eval_id, 'EVAL_ID'), repo: reqRepo(r.repo), pr: optPr(r.pr),
      head_sha: reqSha(r.head_sha, 'HEAD_SHA'), base_sha: optSha(r.base_sha, 'BASE_SHA'),
      profile: simpleToken(r.profile, /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/, 'PROFILE'),
      policy_version: optPolicy(r.policy_version),
      isolation: safeText(r.isolation, 'ISOLATION'), runner_host: safeText(r.host, 'HOST', { max: 255 }),
      verdict, reasons: safeJson(Array.isArray(r.reasons) ? r.reasons : [], 'REASONS'),
      evidence_hash: r.evidence_hash, started_at: started, finished_at: finished, checks,
    };
  },
  gate(r) {
    return {
      repo: reqRepo(r.repo), pr: reqPr(r.pr),
      head_sha: reqSha(r.head_sha, 'HEAD_SHA'), base_sha: reqSha(r.base_sha, 'BASE_SHA'),
      verdict: oneOf(GATE_VERDICTS, r.verdict, 'VERDICT'), risk: oneOf(RISKS, r.risk, 'RISK'),
      risk_detail: safeJson(Array.isArray(r.risk_detail) ? r.risk_detail : [], 'RISK_DETAIL'),
      reasons: safeJson(Array.isArray(r.reasons) ? r.reasons : [], 'REASONS'),
      checks: safeJson(Array.isArray(r.checks) ? r.checks : [], 'CHECKS'),
      quality_eval_id: optId(r.quality_eval_id, 'QUALITY_EVAL_ID'),
      ship_source: safeText(r.ship_source, 'SHIP_SOURCE'),
      policy_version: optPolicy(r.policy_version),
      gate_hash: r.gate_hash === null || r.gate_hash === undefined ? null
        : (HEX64.test(String(r.gate_hash)) ? r.gate_hash : bad('INVALID_GATE_HASH')),
      evaluated_at: reqTs(r.evaluated_at, 'EVALUATED_AT'),
    };
  },
  attestation(r) {
    if (typeof r.reviewed !== 'boolean') bad('INVALID_REVIEWED');
    if (typeof r.key_id !== 'string' || !KEY_ID.test(r.key_id)) bad('INVALID_KEY_ID');
    if (typeof r.signature !== 'string' || !SIG_B64.test(r.signature)) bad('INVALID_SIGNATURE');
    return {
      attestation_id: reqId(r.attestation_id, 'ATTESTATION_ID'), repo: reqRepo(r.repo), pr: reqPr(r.pr),
      head_sha: reqSha(r.head_sha, 'HEAD_SHA'), reviewed: r.reviewed,
      review_effort: simpleToken(r.review_effort, /^[a-z0-9_-]{1,32}$/, 'REVIEW_EFFORT'),
      important_open: nonNegIntOrNull(r.important_open, 'IMPORTANT_OPEN') ?? bad('MISSING_IMPORTANT_OPEN'),
      watch_status: oneOf(WATCH_STATUSES, r.watch_status, 'WATCH_STATUS'),
      notes: safeText(r.notes, 'NOTES'), approver: safeText(r.approver, 'APPROVER', { required: true, max: 200 }),
      key_id: r.key_id, issued_at: reqTs(r.issued_at, 'ISSUED_AT'), nonce: reqId(r.nonce, 'NONCE'), signature: r.signature,
    };
  },
  approval(r) {
    if (typeof r.key_id !== 'string' || !KEY_ID.test(r.key_id)) bad('INVALID_KEY_ID');
    if (typeof r.signature !== 'string' || !SIG_B64.test(r.signature)) bad('INVALID_SIGNATURE');
    const decision = oneOf(DECISIONS, r.decision, 'DECISION');
    const gateVerdict = oneOf(GATE_VERDICTS, r.gate_verdict, 'GATE_VERDICT');
    if (decision === 'approve' && gateVerdict !== 'PASS') bad('APPROVE_WITHOUT_PASS');
    const issued = reqTs(r.issued_at, 'ISSUED_AT');
    const expires = reqTs(r.expires_at, 'EXPIRES_AT');
    if (Date.parse(expires) <= Date.parse(issued)) bad('EXPIRES_NOT_AFTER_ISSUED');
    const hexOrNull = (v, label) => (v === null || v === undefined ? null : (HEX64.test(String(v)) ? v : bad('INVALID_' + label)));
    return {
      approval_id: reqId(r.approval_id, 'APPROVAL_ID'), repo: reqRepo(r.repo), pr: reqPr(r.pr),
      head_sha: reqSha(r.head_sha, 'HEAD_SHA'), base_sha: reqSha(r.base_sha, 'BASE_SHA'),
      decision, gate_verdict: gateVerdict, gate_hash: hexOrNull(r.gate_hash, 'GATE_HASH'),
      quality_eval_id: optId(r.quality_eval_id, 'QUALITY_EVAL_ID'),
      quality_evidence_hash: hexOrNull(r.quality_evidence_hash, 'QUALITY_EVIDENCE_HASH'),
      risk: oneOf(RISKS, r.risk, 'RISK'), approver: safeText(r.approver, 'APPROVER', { required: true, max: 200 }),
      key_id: r.key_id, issued_at: issued, expires_at: expires, nonce: reqId(r.nonce, 'NONCE'),
      policy_version: optPolicy(r.policy_version), signature: r.signature,
    };
  },
  revocation(r) {
    return {
      approval_id: reqId(r.approval_id, 'APPROVAL_ID'),
      reason: safeText(r.reason, 'REASON') || '', actor: safeText(r.actor, 'ACTOR', { required: true, max: 200 }),
      at: reqTs(r.at, 'AT'),
    };
  },
  consumption(r) {
    return { nonce: reqId(r.nonce, 'NONCE'), approval_id: reqId(r.approval_id, 'APPROVAL_ID'), consumed_at: reqTs(r.consumed_at, 'CONSUMED_AT') };
  },
  merge(r) {
    const state = oneOf(MERGE_STATES, r.state, 'MERGE_STATE');
    const confirmed = r.confirmed === true;
    const mergeSha = optSha(r.merge_commit_sha, 'MERGE_COMMIT_SHA');
    if (confirmed && (!mergeSha || !['MERGED', 'MERGED_UNEXPECTED_HEAD'].includes(state))) bad('CONFIRMED_WITHOUT_MERGE_COMMIT');
    return {
      repo: reqRepo(r.repo), pr: reqPr(r.pr), state, confirmed, merge_commit_sha: mergeSha,
      head_sha: optSha(r.head_sha, 'HEAD_SHA'), expected_head_sha: optSha(r.expected_head, 'EXPECTED_HEAD'),
      reason: safeText(r.reason, 'REASON'), observed_at: reqTs(r.at, 'AT'),
    };
  },
  audit(r, item) {
    if (!r || typeof r !== 'object' || Array.isArray(r)) bad('AUDIT_PARSE');
    const event = String(r.event || '');
    const action = 'ship.' + event;
    if (!/^[a-z][a-z0-9._-]{0,95}$/.test(action) || !event) bad('INVALID_AUDIT_EVENT');
    const repo = typeof r.repo === 'string' && /^[A-Za-z0-9_.-]{1,100}\/[A-Za-z0-9_.-]{1,100}$/.test(r.repo) && !r.repo.includes('..') ? r.repo : null;
    let subject = 'ship';
    if (repo && r.pr) subject = `${repo}#${Number(r.pr)}`;
    else if (repo) subject = repo;
    else if (typeof r.run_id === 'string') subject = r.run_id;
    else if (typeof r.approval_id === 'string') subject = r.approval_id;
    else if (typeof r.eval_id === 'string') subject = r.eval_id;
    const detail = safeJson(r, 'AUDIT_DETAIL');
    const streamName = 'ship/audit.jsonl';
    return {
      occurred_at: reqTs(r.ts, 'TS'), actor: safeText(r.actor || 'claudeos', 'ACTOR', { required: true, max: 200 }),
      action, subject_ref: safeText(subject, 'SUBJECT', { required: true, max: 300 }), repo, detail,
      // 0001 §冪等性 の規約: sha256(source_stream || ':' || source_seq || ':' || canonical_json)
      idempotency_key: store.sha256(`${streamName}:${item.line}:${store.canonical(r)}`),
    };
  },
};

// ------------------------------------------------------------
// SQL 生成
// ------------------------------------------------------------
const PID = (repo) => `control.ship_project_id(${sqlLiteral(repo)})`;
const PRID = (repo, pr) => (pr === null || pr === undefined ? 'NULL' : `control.ship_pull_request_id(${sqlLiteral(repo)}, ${sqlLiteral(pr)})`);
const rows = (list) => list.map((r) => '  (' + r.join(', ') + ')').join(',\n');

/**
 * buildProjection({ policyFile }) → { sql, summary }
 *   ストアを読み、検証済みレコードだけから冪等 SQL を作る。除外は summary.rejected に理由付きで入る。
 */
function buildProjection({ policyFile = null } = {}) {
  const items = readStore();
  const ok = { run: [], quality: [], gate: [], attestation: [], approval: [], revocation: [], consumption: [], merge: [], audit: [] };
  const rejected = [];
  for (const item of items) {
    const where = rel(item.file) + (item.line ? ':' + item.line : '');
    if (!item.rec || typeof item.rec !== 'object') { rejected.push({ kind: item.kind, file: where, reason: 'UNREADABLE' }); continue; }
    try {
      ok[item.kind].push({ where, v: normalizers[item.kind](item.rec, item) });
    } catch (e) {
      if (!(e instanceof RecordError) && !/^(NUL_BYTE|MALFORMED_UNICODE)/.test(e.message)) throw e;
      rejected.push({ kind: item.kind, file: where, reason: e.message });
    }
  }

  // ストア内での一意性 (DB の UNIQUE より先に検出し、全体ロールバックを避ける)
  const dedupe = (list, keyOf, reason) => {
    const seen = new Map(); const keep = [];
    for (const x of list) {
      const k = keyOf(x.v);
      if (seen.has(k) && seen.get(k) !== x.where) { rejected.push({ kind: reason.kind, file: x.where, reason: reason.code + ' (' + seen.get(k) + ')' }); continue; }
      seen.set(k, x.where); keep.push(x);
    }
    return keep;
  };
  ok.approval = dedupe(ok.approval, (v) => v.approval_id, { kind: 'approval', code: 'DUPLICATE_APPROVAL_ID' });
  ok.approval = dedupe(ok.approval, (v) => v.nonce, { kind: 'approval', code: 'DUPLICATE_NONCE' });
  ok.attestation = dedupe(ok.attestation, (v) => v.nonce, { kind: 'attestation', code: 'DUPLICATE_NONCE' });
  ok.quality = dedupe(ok.quality, (v) => v.eval_id, { kind: 'quality', code: 'DUPLICATE_EVAL_ID' });
  ok.run = dedupe(ok.run, (v) => v.run_id, { kind: 'run', code: 'DUPLICATE_RUN_ID' });

  // 承認の nonce と使用記録の nonce が食い違うものは除外 (DB の複合 FK と同じ規則)
  const approvalNonce = new Map(ok.approval.map((x) => [x.v.approval_id, x.v.nonce]));
  ok.consumption = ok.consumption.filter((x) => {
    const n = approvalNonce.get(x.v.approval_id);
    if (n !== undefined && n !== x.v.nonce) { rejected.push({ kind: 'consumption', file: x.where, reason: 'NONCE_MISMATCH' }); return false; }
    return true;
  });

  // policy 版
  const policies = new Map();
  for (const k of ['quality', 'gate', 'approval']) for (const x of ok[k]) if (x.v.policy_version) policies.set(x.v.policy_version, null);
  let policyInfo = null;
  if (policyFile) {
    const text = fs.readFileSync(policyFile, 'utf8');
    const json = JSON.parse(text);
    const version = optPolicy(json.policyVersion);
    if (version) {
      policyInfo = { version, schema: typeof json.schema === 'string' && /^[a-z0-9][a-z0-9._/-]{0,95}$/.test(json.schema) ? json.schema : null,
        sha: store.sha256(text), ref: safeText(path.basename(policyFile), 'POLICY_FILE') };
      policies.set(version, policyInfo);
    }
  }

  // repo / PR 集合
  const repos = new Set(); const prs = new Map();
  const addPr = (repo, pr) => { repos.add(repo); if (pr) prs.set(repo + '#' + pr, { repo, pr }); };
  for (const k of ['run', 'quality', 'gate', 'attestation', 'approval', 'merge']) for (const x of ok[k]) addPr(x.v.repo, x.v.pr);
  for (const x of ok.audit) if (x.v.repo) repos.add(x.v.repo);

  const s = [];
  s.push('-- generated by scripts/ship/project-to-db.js (Ship Native → claudeos_control 0006 射影)');
  s.push('-- 冪等: 何度流しても同じ結果。1 件でも制約違反なら全体がロールバックされる。');
  s.push('BEGIN;');
  s.push('SET LOCAL standard_conforming_strings = on;');
  s.push("SET LOCAL client_encoding = 'UTF8';");

  if (policies.size) {
    const pv = [...policies.entries()].sort().map(([v, info]) => [sqlLiteral(v), sqlLiteral(info ? info.schema : null), sqlLiteral(info ? info.sha : null), sqlLiteral(info ? info.ref : null)]);
    s.push(`INSERT INTO control.policy_versions (policy_version, policy_schema, content_sha256, source_ref) VALUES\n${rows(pv)}\nON CONFLICT (policy_version) DO UPDATE\n  SET content_sha256 = EXCLUDED.content_sha256, policy_schema = COALESCE(control.policy_versions.policy_schema, EXCLUDED.policy_schema),\n      source_ref = COALESCE(control.policy_versions.source_ref, EXCLUDED.source_ref)\n  WHERE control.policy_versions.content_sha256 IS NULL AND EXCLUDED.content_sha256 IS NOT NULL;`);
  }

  // projects: 既存 project (remote_slug 一致) を優先して再利用し、無ければ作る
  for (const repo of [...repos].sort()) {
    s.push(`INSERT INTO control.projects (project_key, display_name, remote_slug, metadata)\nSELECT ${sqlLiteral(projectKey(repo))}, ${sqlLiteral(repo)}, ${sqlLiteral(repo)}, ${sqlJson({ source: 'ship-native' })}\n WHERE NOT EXISTS (SELECT 1 FROM control.projects p WHERE lower(p.remote_slug) = lower(${sqlLiteral(repo)}))\nON CONFLICT (project_key) DO NOTHING;`);
  }
  if (prs.size) {
    const pr = [...prs.values()].sort((a, b) => (a.repo + a.pr).localeCompare(b.repo + b.pr)).map((p) => [PID(p.repo), sqlLiteral(p.repo), sqlLiteral(p.pr)]);
    s.push(`INSERT INTO control.pull_requests (project_id, repo, pr_number) VALUES\n${rows(pr)}\nON CONFLICT (repo, pr_number) DO NOTHING;`);
  }

  for (const { v } of ok.run) {
    s.push(`INSERT INTO control.ship_sessions (ship_run_id, project_id, pull_request_id, repo, project_dir, mode, state, head_sha, base_sha, branch,\n  ship_capability, ship_status, retries, source_created_at, source_updated_at) VALUES\n  (${[sqlLiteral(v.run_id), PID(v.repo), PRID(v.repo, v.pr), sqlLiteral(v.repo), sqlLiteral(v.project_dir), sqlLiteral(v.mode), sqlLiteral(v.state),
      sqlLiteral(v.head_sha), sqlLiteral(v.base_sha), sqlLiteral(v.branch), sqlLiteral(v.ship_capability), sqlLiteral(v.ship_status), sqlLiteral(v.retries),
      sqlTs(v.created_at), sqlTs(v.updated_at)].join(', ')})\nON CONFLICT (ship_run_id) DO UPDATE SET\n  pull_request_id = EXCLUDED.pull_request_id, project_dir = EXCLUDED.project_dir, mode = EXCLUDED.mode, state = EXCLUDED.state,\n  head_sha = EXCLUDED.head_sha, base_sha = EXCLUDED.base_sha, branch = EXCLUDED.branch, ship_capability = EXCLUDED.ship_capability,\n  ship_status = EXCLUDED.ship_status, retries = EXCLUDED.retries, source_updated_at = EXCLUDED.source_updated_at\n  WHERE control.ship_sessions.source_updated_at < EXCLUDED.source_updated_at;`);
    if (v.history.length) {
      const h = v.history.map((t) => [sqlLiteral(t.seq), sqlLiteral(t.from), sqlLiteral(t.to), sqlTs(t.at), sqlJson(t.evidence)]);
      s.push(`INSERT INTO control.ship_state_transitions (ship_session_id, seq, from_state, to_state, transitioned_at, evidence)\nSELECT ss.ship_session_id, t.seq, t.from_state, t.to_state, t.transitioned_at, t.evidence\n  FROM control.ship_sessions ss,\n       (VALUES\n${rows(h).replace(/^/gm, '     ')}\n       ) AS t (seq, from_state, to_state, transitioned_at, evidence)\n WHERE ss.ship_run_id = ${sqlLiteral(v.run_id)}\nON CONFLICT (ship_session_id, seq) DO NOTHING;`);
    }
  }

  for (const { v } of ok.quality) {
    s.push(`INSERT INTO control.quality_evaluations (eval_id, project_id, pull_request_id, repo, head_sha, base_sha, profile, policy_version,\n  isolation, runner_host, verdict, reasons, evidence_hash, started_at, finished_at) VALUES\n  (${[sqlLiteral(v.eval_id), PID(v.repo), PRID(v.repo, v.pr), sqlLiteral(v.repo), sqlLiteral(v.head_sha), sqlLiteral(v.base_sha), sqlLiteral(v.profile),
      sqlLiteral(v.policy_version), sqlLiteral(v.isolation), sqlLiteral(v.runner_host), sqlLiteral(v.verdict), sqlJson(v.reasons), sqlLiteral(v.evidence_hash),
      sqlTs(v.started_at), sqlTs(v.finished_at)].join(', ')})\nON CONFLICT (eval_id) DO NOTHING;`);
    if (v.checks.length) {
      const c = v.checks.map((t) => [sqlLiteral(t.seq), sqlLiteral(t.id), sqlLiteral(t.category), sqlLiteral(t.command), sqlLiteral(t.status), sqlLiteral(t.exit_code),
        sqlLiteral(t.passed), sqlLiteral(t.failed), sqlLiteral(t.skipped), sqlLiteral(t.duration_ms), sqlLiteral(t.reason), sqlLiteral(t.log_ref)]);
      s.push(`INSERT INTO control.test_results (quality_evaluation_id, check_seq, check_id, category, command, status, exit_code,\n  passed_count, failed_count, skipped_count, duration_ms, reason, log_ref)\nSELECT q.quality_evaluation_id, t.check_seq::smallint, t.check_id, t.category, t.command, t.status, t.exit_code::integer,\n       t.passed_count::integer, t.failed_count::integer, t.skipped_count::integer, t.duration_ms::integer, t.reason, t.log_ref\n  FROM control.quality_evaluations q,\n       (VALUES\n${rows(c).replace(/^/gm, '     ')}\n       ) AS t (check_seq, check_id, category, command, status, exit_code, passed_count, failed_count, skipped_count, duration_ms, reason, log_ref)\n WHERE q.eval_id = ${sqlLiteral(v.eval_id)}\nON CONFLICT (quality_evaluation_id, check_seq) DO NOTHING;`);
    }
  }

  for (const { v } of ok.gate) {
    s.push(`INSERT INTO control.gate_evaluations (project_id, pull_request_id, repo, head_sha, base_sha, verdict, risk_level, risk_detail, reasons, checks,\n  quality_eval_id, ship_source, policy_version, gate_hash, evaluated_at) VALUES\n  (${[PID(v.repo), PRID(v.repo, v.pr), sqlLiteral(v.repo), sqlLiteral(v.head_sha), sqlLiteral(v.base_sha), sqlLiteral(v.verdict), sqlLiteral(v.risk),
      sqlJson(v.risk_detail), sqlJson(v.reasons), sqlJson(v.checks), sqlLiteral(v.quality_eval_id), sqlLiteral(v.ship_source), sqlLiteral(v.policy_version),
      sqlLiteral(v.gate_hash), sqlTs(v.evaluated_at)].join(', ')})\nON CONFLICT (pull_request_id, head_sha, evaluated_at) DO NOTHING;`);
  }

  for (const { v } of ok.attestation) {
    s.push(`INSERT INTO control.ship_review_attestations (attestation_id, pull_request_id, repo, head_sha, reviewed, review_effort, important_open,\n  watch_status, notes, approver, key_id, issued_at, nonce, signature) VALUES\n  (${[sqlLiteral(v.attestation_id), PRID(v.repo, v.pr), sqlLiteral(v.repo), sqlLiteral(v.head_sha), sqlLiteral(v.reviewed), sqlLiteral(v.review_effort),
      sqlLiteral(v.important_open), sqlLiteral(v.watch_status), sqlLiteral(v.notes), sqlLiteral(v.approver), sqlLiteral(v.key_id), sqlTs(v.issued_at),
      sqlLiteral(v.nonce), sqlLiteral(v.signature)].join(', ')})\nON CONFLICT (attestation_id) DO NOTHING;`);
  }

  // 承認: 衝突対象は approval_id のみ。別の承認が同じ nonce を使うと UNIQUE 違反で全体が止まる (= DB 側のリプレイ防止)
  for (const { v } of ok.approval) {
    s.push(`INSERT INTO control.human_approvals (approval_id, project_id, pull_request_id, repo, head_sha, base_sha, decision, gate_verdict, gate_hash,\n  quality_eval_id, quality_evidence_hash, risk_level, approver, key_id, issued_at, expires_at, nonce, policy_version, signature) VALUES\n  (${[sqlLiteral(v.approval_id), PID(v.repo), PRID(v.repo, v.pr), sqlLiteral(v.repo), sqlLiteral(v.head_sha), sqlLiteral(v.base_sha), sqlLiteral(v.decision),
      sqlLiteral(v.gate_verdict), sqlLiteral(v.gate_hash), sqlLiteral(v.quality_eval_id), sqlLiteral(v.quality_evidence_hash), sqlLiteral(v.risk),
      sqlLiteral(v.approver), sqlLiteral(v.key_id), sqlTs(v.issued_at), sqlTs(v.expires_at), sqlLiteral(v.nonce), sqlLiteral(v.policy_version),
      sqlLiteral(v.signature)].join(', ')})\nON CONFLICT (approval_id) DO NOTHING;`);
  }

  // 取り消し / 使用記録: 対象承認が DB に無ければ (孤児) 何もしない
  for (const { v } of ok.revocation) {
    s.push(`INSERT INTO control.approval_revocations (approval_id, reason, actor, revoked_at)\nSELECT ${sqlLiteral(v.approval_id)}, ${sqlLiteral(v.reason)}, ${sqlLiteral(v.actor)}, ${sqlTs(v.at)}\n WHERE EXISTS (SELECT 1 FROM control.human_approvals a WHERE a.approval_id = ${sqlLiteral(v.approval_id)})\nON CONFLICT (approval_id) DO NOTHING;`);
  }
  for (const { v } of ok.consumption) {
    s.push(`INSERT INTO control.approval_consumptions (approval_id, nonce, consumed_at)\nSELECT ${sqlLiteral(v.approval_id)}, ${sqlLiteral(v.nonce)}, ${sqlTs(v.consumed_at)}\n WHERE EXISTS (SELECT 1 FROM control.human_approvals a WHERE a.approval_id = ${sqlLiteral(v.approval_id)} AND a.nonce = ${sqlLiteral(v.nonce)})\nON CONFLICT (approval_id) DO NOTHING;`);
  }

  for (const { v } of ok.merge) {
    s.push(`INSERT INTO control.merge_events (project_id, pull_request_id, repo, state, confirmed, merge_commit_sha, head_sha, expected_head_sha, reason, observed_at) VALUES\n  (${[PID(v.repo), PRID(v.repo, v.pr), sqlLiteral(v.repo), sqlLiteral(v.state), sqlLiteral(v.confirmed), sqlLiteral(v.merge_commit_sha),
      sqlLiteral(v.head_sha), sqlLiteral(v.expected_head_sha), sqlLiteral(v.reason), sqlTs(v.observed_at)].join(', ')})\nON CONFLICT (pull_request_id, observed_at, state) DO NOTHING;`);
  }

  // 監査: 既存 control.audit_events (追記専用・行ダイジェスト付き) を再利用
  for (const { v } of ok.audit) {
    s.push(`INSERT INTO control.audit_events (occurred_at, project_id, actor, actor_kind, action, subject_kind, subject_ref, outcome, severity, detail, idempotency_key) VALUES\n  (${[sqlTs(v.occurred_at), v.repo ? PID(v.repo) : 'NULL', sqlLiteral(v.actor), sqlLiteral('agent'), sqlLiteral(v.action), sqlLiteral('ship'),
      sqlLiteral(v.subject_ref), sqlLiteral('success'), sqlLiteral('info'), sqlJson(v.detail), sqlLiteral(v.idempotency_key)].join(', ')})\nON CONFLICT (idempotency_key) DO NOTHING;`);
  }

  s.push('COMMIT;');
  const counts = Object.fromEntries(Object.entries(ok).map(([k, v]) => [k, v.length]));
  const chain = store.verifyAuditChain();
  return {
    sql: s.join('\n') + '\n',
    summary: { ship_home: store.shipHome(), counts, projects: repos.size, pull_requests: prs.size, policy_versions: policies.size,
      rejected, audit_chain: chain },
  };
}

// ------------------------------------------------------------
// psql 適用
// ------------------------------------------------------------
function resolvePsql() {
  if (process.env.PG_BIN) return path.join(process.env.PG_BIN, 'psql');
  const ls = spawnSync('pg_lsclusters', [], { encoding: 'utf8' });
  if (ls.status === 0) {
    const line = ls.stdout.split('\n').slice(1).find((l) => /\bonline\b/.test(l) && /\s5432\s/.test(l));
    const ver = line && line.trim().split(/\s+/)[0];
    if (ver && /^[0-9]+$/.test(ver) && fs.existsSync(`/usr/lib/postgresql/${ver}/bin/psql`)) return `/usr/lib/postgresql/${ver}/bin/psql`;
  }
  return 'psql';
}

function applySql(sql, { db, role }) {
  if (!/^[a-z][a-z0-9_]{0,62}$/.test(db)) throw Object.assign(new Error('INVALID_DB_NAME'), { exit: 2 });
  let body = sql;
  if (role && role !== 'none') {
    if (!/^[a-z][a-z0-9_]{0,62}$/.test(role)) throw Object.assign(new Error('INVALID_ROLE_NAME'), { exit: 2 });
    // 権限を落としてから書く (0001 §6: SET ROLE で claudeos_control_app へ)
    body = sql.replace(/^BEGIN;$/m, `BEGIN;\nSET LOCAL ROLE "${role}";`);
  }
  const env = { ...process.env, PGHOST: process.env.PGHOST || '/var/run/postgresql' };
  delete env.DATABASE_URL; // 接続は socket + peer のみ
  const r = spawnSync(resolvePsql(), ['-X', '-q', '-v', 'ON_ERROR_STOP=1', '-h', env.PGHOST, '-d', db, '-f', '-'],
    { input: body, encoding: 'utf8', env, maxBuffer: 64 * 1024 * 1024 });
  return { status: r.status, stdout: r.stdout || '', stderr: r.stderr || (r.error ? String(r.error.message) : '') };
}

// ------------------------------------------------------------
// CLI
// ------------------------------------------------------------
function parseArgs(argv) {
  const o = { mode: 'dry-run', role: 'claudeos_control_app' };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    const val = () => { const v = argv[++i]; if (v === undefined) throw Object.assign(new Error('MISSING_VALUE ' + a), { exit: 2 }); return v; };
    if (a === '--sql') o.mode = 'sql';
    else if (a === '--apply') o.mode = 'apply';
    else if (a === '--db') o.db = val();
    else if (a === '--role') o.role = val();
    else if (a === '--home') o.home = val();
    else if (a === '--policy-file') o.policyFile = val();
    else if (a === '--strict') o.strict = true;
    else if (a === '-h' || a === '--help') o.help = true;
    else throw Object.assign(new Error('UNKNOWN_ARG ' + a), { exit: 2 });
  }
  if (o.mode === 'apply' && !o.db) throw Object.assign(new Error('--apply には --db NAME が必要です'), { exit: 2 });
  return o;
}

function main(argv = process.argv.slice(2)) {
  let o;
  try { o = parseArgs(argv); } catch (e) { process.stderr.write(e.message + '\n'); return e.exit || 2; }
  if (o.help) { process.stdout.write(fs.readFileSync(__filename, 'utf8').split('\n').slice(2, 28).join('\n') + '\n'); return 0; }
  if (o.home) process.env.CLAUDEOS_SHIP_HOME = path.resolve(o.home);
  const { sql, summary } = buildProjection({ policyFile: o.policyFile || null });
  if (summary.rejected.length) process.stderr.write(`[project-to-db] 除外 ${summary.rejected.length} 件: ` + JSON.stringify(summary.rejected) + '\n');
  if (o.strict && summary.rejected.length) return 3;
  if (o.mode === 'sql') { process.stdout.write(sql); return 0; }
  if (o.mode === 'dry-run') { process.stdout.write(JSON.stringify({ mode: 'dry-run', ...summary }, null, 2) + '\n'); return 0; }
  let r;
  try { r = applySql(sql, { db: o.db, role: o.role }); } catch (e) { process.stderr.write(e.message + '\n'); return e.exit || 1; }
  if (r.status !== 0) { process.stderr.write('[project-to-db] psql 適用失敗 (全体ロールバック):\n' + r.stderr); return 1; }
  process.stdout.write(JSON.stringify({ mode: 'apply', db: o.db, ...summary }, null, 2) + '\n');
  return 0;
}

if (require.main === module) process.exitCode = main();

module.exports = { sqlLiteral, sqlJson, sqlTs, assertCleanString, projectKey, buildProjection, applySql, parseArgs, main, normalizers, RecordError };
