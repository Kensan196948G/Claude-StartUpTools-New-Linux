'use strict';
/**
 * state-machine.js — Ship Native run の状態遷移 (正本)
 *
 * 不変条件:
 *   - HUMAN_APPROVAL_REQUIRED → HUMAN_APPROVED は、検証済みの人間承認 (human-gate.verifyApproval が ok)
 *     を evidence.approval_id として伴う場合だけ許す。
 *   - MERGE_QUEUED / MERGING へは HUMAN_APPROVED からのみ入れる。
 *   - MERGED は GitHub API の再取得で merged=true を確認した evidence.merge_commit_sha を伴う場合だけ。
 *   - 終端 (COMPLETED / FAILED / STOPPED) からは遷移しない。BLOCKED は再開 (resume) 可能。
 *   - head SHA が変わったら HUMAN_APPROVED 以降の状態から SHIP_REVALIDATING へ戻る (承認失効)。
 */

const STATES = [
  'IDLE', 'DISCOVERY', 'PLANNING', 'IMPLEMENTING',
  'LOCAL_TESTING', 'LOCAL_REMEDIATION',
  'PR_CREATING',
  'SHIP_STARTING', 'SHIP_REVIEWING', 'SHIP_REMEDIATING', 'SHIP_REVALIDATING',
  'QUALITY_EVALUATING', 'QUALITY_FAILED',
  'HUMAN_APPROVAL_REQUIRED', 'HUMAN_APPROVED',
  'MERGE_QUEUED', 'MERGING', 'MERGED',
  'COMPLETED', 'BLOCKED', 'FAILED', 'STOPPED',
];

const TERMINAL = new Set(['COMPLETED', 'FAILED', 'STOPPED']);
// どの非終端状態からでも入れる退避先
const ANY_TO = new Set(['BLOCKED', 'FAILED', 'STOPPED']);

const T = {
  IDLE: ['DISCOVERY'],
  DISCOVERY: ['PLANNING'],
  PLANNING: ['IMPLEMENTING'],
  IMPLEMENTING: ['LOCAL_TESTING'],
  LOCAL_TESTING: ['LOCAL_REMEDIATION', 'PR_CREATING', 'QUALITY_EVALUATING'],
  LOCAL_REMEDIATION: ['LOCAL_TESTING'],
  PR_CREATING: ['SHIP_STARTING', 'QUALITY_EVALUATING'],
  SHIP_STARTING: ['SHIP_REVIEWING'],
  SHIP_REVIEWING: ['SHIP_REMEDIATING', 'SHIP_REVALIDATING', 'QUALITY_EVALUATING'],
  SHIP_REMEDIATING: ['SHIP_REVALIDATING', 'SHIP_REVIEWING'],
  SHIP_REVALIDATING: ['QUALITY_EVALUATING', 'SHIP_REMEDIATING'],
  QUALITY_EVALUATING: ['QUALITY_FAILED', 'HUMAN_APPROVAL_REQUIRED'],
  QUALITY_FAILED: ['SHIP_REMEDIATING', 'LOCAL_REMEDIATION', 'SHIP_REVALIDATING'],
  HUMAN_APPROVAL_REQUIRED: ['HUMAN_APPROVED', 'SHIP_REMEDIATING', 'SHIP_REVALIDATING'],
  HUMAN_APPROVED: ['MERGE_QUEUED', 'SHIP_REVALIDATING'],
  MERGE_QUEUED: ['MERGING', 'MERGED', 'SHIP_REVALIDATING'],
  MERGING: ['MERGED', 'SHIP_REVALIDATING'],
  MERGED: ['COMPLETED'],
  BLOCKED: ['DISCOVERY', 'LOCAL_TESTING', 'SHIP_REVALIDATING', 'QUALITY_EVALUATING', 'HUMAN_APPROVAL_REQUIRED'],
  COMPLETED: [], FAILED: [], STOPPED: [],
};

/** canTransition(from, to, evidence) → { ok, reason } */
function canTransition(from, to, evidence = {}) {
  if (!STATES.includes(from)) return { ok: false, reason: 'UNKNOWN_FROM' };
  if (!STATES.includes(to)) return { ok: false, reason: 'UNKNOWN_TO' };
  if (TERMINAL.has(from)) return { ok: false, reason: 'TERMINAL_STATE' };
  const allowed = ANY_TO.has(to) || (T[from] || []).includes(to);
  if (!allowed) return { ok: false, reason: `ILLEGAL_TRANSITION ${from}->${to}` };
  if (to === 'HUMAN_APPROVED') {
    if (!evidence.approval_verified || !evidence.approval_id) return { ok: false, reason: 'HUMAN_APPROVAL_NOT_VERIFIED' };
  }
  if (to === 'HUMAN_APPROVAL_REQUIRED') {
    if (evidence.gate_verdict !== 'PASS') return { ok: false, reason: 'QUALITY_GATE_NOT_PASS' };
  }
  if (to === 'MERGE_QUEUED' || to === 'MERGING') {
    if (!evidence.approval_verified) return { ok: false, reason: 'HUMAN_APPROVAL_NOT_VERIFIED' };
  }
  if (to === 'MERGED') {
    if (!evidence.merge_confirmed || !/^[0-9a-f]{40}$/.test(String(evidence.merge_commit_sha || ''))) {
      return { ok: false, reason: 'MERGE_NOT_CONFIRMED' };
    }
  }
  return { ok: true };
}

/** transition(run, to, evidence) — run を破壊的に更新して返す。違反は例外 */
function transition(run, to, evidence = {}, now = new Date()) {
  const r = canTransition(run.state, to, evidence);
  if (!r.ok) {
    const err = new Error(r.reason);
    err.code = 'ILLEGAL_TRANSITION';
    throw err;
  }
  run.history = run.history || [];
  run.history.push({ from: run.state, to, at: now.toISOString(), evidence: summarize(evidence) });
  run.state = to;
  run.updated_at = now.toISOString();
  return run;
}

function summarize(e) {
  const keep = ['approval_id', 'gate_verdict', 'head_sha', 'base_sha', 'merge_commit_sha', 'reason', 'pr', 'eval_id'];
  const o = {};
  for (const k of keep) if (e[k] !== undefined) o[k] = e[k];
  return o;
}

/** onHeadChanged — head SHA が変わったら承認以降の状態を巻き戻す (承認失効) */
function onHeadChanged(run, newHead, now = new Date()) {
  if (run.head_sha === newHead) return { changed: false };
  const prev = run.head_sha;
  run.head_sha = newHead;
  const stale = ['QUALITY_EVALUATING', 'HUMAN_APPROVAL_REQUIRED', 'HUMAN_APPROVED', 'MERGE_QUEUED', 'MERGING'];
  if (stale.includes(run.state)) transition(run, 'SHIP_REVALIDATING', { reason: 'HEAD_CHANGED', head_sha: newHead }, now);
  return { changed: true, prev };
}

module.exports = { STATES, TERMINAL, TRANSITIONS: T, canTransition, transition, onHeadChanged };
