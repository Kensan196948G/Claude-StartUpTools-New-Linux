#!/usr/bin/env node
'use strict';
// managed-budget.js — Managed Agents 用 Budget Guard と使用量台帳 (整数セント)
//
// 役割:
//   - Managed Agents のセッション予算・日次・月次予算を「作成前の事前予約」で強制する。
//     Managed Agents の上限は「跨いだモデルリクエストは完走する」pre-request gate のため、
//     実績ではなく上限額 (budget.max_list_cost) を予約しないと 1 セッション分の超過を許す。
//   - 台帳は Claude Code / Agent SDK の台帳 (lib/credits.sh, ~/.claudeos/credits/ledger.jsonl) とは
//     別ファイル。同じ利用分を二重集計しない。config.agentSdk.monthlyBudgetUsd には触れない。
//   - 段階ガードは lib/credits.sh と同じ語彙 (credit-cap:warn / verify-only / stop) を再利用し、
//     Managed 用に 100% (credit-cap:exhausted) を追加する。比率は整数演算で判定する。
//
// 正本の扱い: 実際の請求・クレジット残高は Anthropic Console が正本。この台帳は list 価格ベースの
//   予測・監査・照合用であり、`reconcile` で Console の値と突き合わせる。
//
// 台帳 (JSONL, 追記専用) のエントリ:
//   reserve   { task_id, cents, task_class, role, ts }           セッション作成前の予約
//   usage     { task_id, session_id, list_cost_cents, final, .. } 累積値 (合算せず最大値を採用)
//   release   { task_id, reason }                                 作成失敗時の予約解除
//   reconcile { console_cents, ledger_cents, diff_cents, .. }     Console との照合記録

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

// 初期 PoC のハード上限。設定ファイルでこれを超える値を指定しても検証で拒否する
// (設定の書き換えだけで予算制御を無効化できないようにする)。
const HARD_LIMITS = Object.freeze({
  monthlyBudgetCents: 10000,      // $100 (月額クレジット全体) を超える枠は設定不可
  sessionMaxCents: 500,           // 単一セッション $5 まで
  connectionTestMaxCents: 100,
  dailySoftCents: 10000,
  maxConcurrentSessions: 1,       // PoC は並列 1 固定
  maxApiRetries: 1,
});

const DEFAULT_POLICY = Object.freeze({
  monthlyBudgetCents: 2000,       // Managed Agents 月間 PoC 予算 $20
  sessionMaxCents: 200,           // 単一セッション上限 $2
  connectionTestMaxCents: 50,     // 初回接続テスト・確認処理 (task_class=check) 上限 $0.50
  dailySoftCents: 300,            // 日次ソフト予算 $3
  maxConcurrentSessions: 1,
  maxApiRetries: 1,
  warnPct: 70,
  verifyOnlyPct: 85,
  stopPct: 95,
  exhaustedPct: 100,
});

class BudgetError extends Error {
  constructor(code, message, details) {
    super(message);
    this.code = code; this.details = details || {};
  }
}

// --- 金額変換 (浮動小数を経由しない) ---

// usdToCents('2') => 200, usdToCents('0.50') => 50。小数 3 桁以上・負数・指数表記は拒否。
function usdToCents(usd) {
  const s = String(usd).trim();
  const m = /^(\d+)(?:\.(\d{1,2}))?$/.exec(s);
  if (!m) throw new BudgetError('AMOUNT_INVALID', `USD 金額は 0 以上・小数 2 桁以内の 10 進表記のみ (actual: ${s})`);
  const cents = Number(m[1]) * 100 + Number((m[2] || '').padEnd(2, '0') || 0);
  if (!Number.isSafeInteger(cents)) throw new BudgetError('AMOUNT_INVALID', `金額が大きすぎる (actual: ${s})`);
  return cents;
}

function centsToUsd(cents) {
  const n = Math.trunc(Number(cents));
  const sign = n < 0 ? '-' : '';
  const a = Math.abs(n);
  return `${sign}${Math.trunc(a / 100)}.${String(a % 100).padStart(2, '0')}`;
}

// API の max_list_cost.amount 形式 (先頭ゼロなし・正の整数文字列) を検証して整数セントを返す。
function parseCentsString(amount) {
  const s = String(amount);
  if (!/^[1-9]\d*$/.test(s)) throw new BudgetError('AMOUNT_INVALID', `セント額は先頭ゼロなしの正の整数文字列のみ (actual: ${s})`);
  const n = Number(s);
  if (!Number.isSafeInteger(n)) throw new BudgetError('AMOUNT_INVALID', `金額が大きすぎる (actual: ${s})`);
  return n;
}

// --- 予算ポリシー ---

function normalizePolicy(raw) {
  const src = raw && typeof raw === 'object' ? raw : {};
  const p = {};
  for (const k of Object.keys(DEFAULT_POLICY)) {
    const v = src[k] === undefined ? DEFAULT_POLICY[k] : src[k];
    if (!Number.isInteger(v) || v < 0) throw new BudgetError('POLICY_INVALID', `budgetPolicy.${k} は 0 以上の整数 (actual: ${v})`);
    if (HARD_LIMITS[k] !== undefined && v > HARD_LIMITS[k]) {
      throw new BudgetError('POLICY_INVALID', `budgetPolicy.${k}=${v} は PoC のハード上限 ${HARD_LIMITS[k]} を超える`);
    }
    p[k] = v;
  }
  if (p.exhaustedPct > 100) throw new BudgetError('POLICY_INVALID', 'budgetPolicy.exhaustedPct は 100 以下');
  if (!(p.warnPct <= p.verifyOnlyPct && p.verifyOnlyPct <= p.stopPct && p.stopPct <= p.exhaustedPct)) {
    throw new BudgetError('POLICY_INVALID', 'budgetPolicy の閾値は warn <= verifyOnly <= stop <= exhausted');
  }
  if (p.maxConcurrentSessions < 1) throw new BudgetError('POLICY_INVALID', 'budgetPolicy.maxConcurrentSessions は 1 以上');
  const cycle = src.cycle && typeof src.cycle === 'object' ? src.cycle : {};
  const anchorDay = cycle.anchorDay == null ? null : cycle.anchorDay;
  if (anchorDay !== null && !(Number.isInteger(anchorDay) && anchorDay >= 1 && anchorDay <= 28)) {
    throw new BudgetError('POLICY_INVALID', 'budgetPolicy.cycle.anchorDay は 1〜28 の整数または null');
  }
  for (const k of ['creditsExpireAt', 'consoleVerifiedAt']) {
    if (cycle[k] != null && cycle[k] !== '' && (typeof cycle[k] !== 'string' || Number.isNaN(Date.parse(cycle[k])))) {
      throw new BudgetError('POLICY_INVALID', `budgetPolicy.cycle.${k} は ISO 8601 の日時文字列または null`);
    }
  }
  p.cycle = {
    anchorDay,
    creditsExpireAt: typeof cycle.creditsExpireAt === 'string' && cycle.creditsExpireAt ? cycle.creditsExpireAt : null,
    consoleVerifiedAt: typeof cycle.consoleVerifiedAt === 'string' && cycle.consoleVerifiedAt ? cycle.consoleVerifiedAt : null,
  };
  return p;
}

// 請求サイクル。anchorDay (Console の請求周期開始日・UTC) が未設定なら暦月を「参考値」として使う。
function billingPeriod(now, cycle) {
  const d = new Date(now);
  const anchor = cycle && cycle.anchorDay ? cycle.anchorDay : null;
  const day = anchor || 1;
  let y = d.getUTCFullYear();
  let m = d.getUTCMonth();
  if (d.getUTCDate() < day) m -= 1;
  const start = new Date(Date.UTC(y, m, day));
  const end = new Date(Date.UTC(start.getUTCFullYear(), start.getUTCMonth() + 1, day));
  return {
    start: start.toISOString(),
    end: end.toISOString(),
    basis: anchor ? 'billing-cycle' : 'calendar-month-reference',
  };
}

function dayStart(now) {
  const d = new Date(now);
  return new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate())).toISOString();
}

// --- 台帳 I/O ---

function readLedger(ledgerPath) {
  if (!fs.existsSync(ledgerPath)) return { entries: [], corrupt: 0 };
  const entries = [];
  let corrupt = 0;
  for (const line of fs.readFileSync(ledgerPath, 'utf8').split('\n')) {
    if (!line.trim()) continue;
    try {
      const e = JSON.parse(line);
      if (e && typeof e === 'object' && typeof e.type === 'string') entries.push(e); else corrupt += 1;
    } catch { corrupt += 1; }
  }
  return { entries, corrupt };
}

function appendLedger(ledgerPath, entry) {
  fs.mkdirSync(path.dirname(ledgerPath), { recursive: true, mode: 0o700 });
  fs.appendFileSync(ledgerPath, JSON.stringify(entry) + '\n', { mode: 0o600 });
}

function sleepMs(ms) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

// 予約の判定と追記を直列化する。mkdir の原子性を使うロック (依存ゼロ)。
//   - 古いロックを自動回収しない: 「stat → 削除」は原子的でなく、他プロセスが取り直したロックを
//     消して複数プロセスが同時に臨界区間へ入り得る。取得できなければ fail-closed で止め、人間が解除する。
//   - 解放は所有者トークンが自分のものである場合だけ行う。
function withLock(ledgerPath, fn, opts) {
  const lockDir = `${ledgerPath}.lock`;
  const ownerFile = path.join(lockDir, 'owner');
  const token = `${process.pid}.${crypto.randomBytes(8).toString('hex')}`;
  const timeoutMs = (opts && opts.timeoutMs) || 5000;
  fs.mkdirSync(path.dirname(ledgerPath), { recursive: true, mode: 0o700 });
  const began = Date.now();
  for (;;) {
    try { fs.mkdirSync(lockDir, { mode: 0o700 }); break; } catch (e) {
      if (e.code !== 'EEXIST') throw e;
      if (Date.now() - began > timeoutMs) {
        throw new BudgetError('LEDGER_LOCK_TIMEOUT', `台帳ロックを取得できない (fail-closed)。他の実行が無いことを確認してから ${lockDir} を削除する`);
      }
      sleepMs(25);
    }
  }
  try {
    fs.writeFileSync(ownerFile, token, { mode: 0o600 });
    return fn();
  } finally {
    try {
      if (fs.readFileSync(ownerFile, 'utf8') === token) { fs.unlinkSync(ownerFile); fs.rmdirSync(lockDir); }
    } catch { /* 所有者でない、または既に解放済み */ }
  }
}

// --- 集計 ---

// タスク単位に畳み込む。usage の list_cost は累積値なので合算せず最大値を採用する。
function foldTasks(entries) {
  const tasks = new Map();
  for (const e of entries) {
    if (!e.task_id) continue;
    let t = tasks.get(e.task_id);
    if (e.type === 'reserve') {
      t = { task_id: e.task_id, ts: e.ts, reservedCents: Number(e.cents) || 0, actualCents: 0, final: false, released: false, session_id: null, role: e.role || null, task_class: e.task_class || null, status: 'reserved' };
      tasks.set(e.task_id, t);
    } else if (t && e.type === 'usage') {
      t.actualCents = Math.max(t.actualCents, Number(e.list_cost_cents) || 0);
      if (e.session_id) t.session_id = e.session_id;
      if (e.status) t.status = e.status;
      if (e.final === true) t.final = true;
    } else if (t && e.type === 'release') {
      t.released = true; t.status = 'released';
    }
    // 解除後に usage が届いた場合は実績を保持する (released のまま actualCents に反映済み)。
  }
  return tasks;
}

// committed: 確定済みは実績、未確定は max(予約, 実績)、解除済みは実績 (通常 0)。
//   解除後に使用量が記録された場合 (実は作成されていた) も、その実績は消さない。
function committedCents(t) {
  if (t.released) return t.actualCents;
  return t.final ? t.actualCents : Math.max(t.reservedCents, t.actualCents);
}

function summarize(entries, now, policy) {
  const period = billingPeriod(now, policy.cycle);
  const today = dayStart(now);
  const tasks = foldTasks(entries);
  const s = { period, committedMonthCents: 0, actualMonthCents: 0, committedDayCents: 0, openSessions: 0, taskCount: 0 };
  for (const t of tasks.values()) {
    const open = !t.final && !t.released;
    // 未確定のセッションは、開始した請求期間に関わらず並列数と当期の予約に数える
    // (期間の境界をまたいだ瞬間に枠が空いて 2 本目が作れてしまうのを防ぐ)。
    if (open) s.openSessions += 1;
    const inPeriod = t.ts >= period.start && t.ts < period.end;
    if (!inPeriod && !open) continue;
    s.taskCount += 1;
    s.committedMonthCents += committedCents(t);
    s.actualMonthCents += t.actualCents;
    if (t.ts >= today || open) s.committedDayCents += committedCents(t);
  }
  s.stage = stageOf(s.committedMonthCents, policy);
  return s;
}

// lib/credits.sh credits__guard と同じ段階思想。整数演算: spent*100 >= pct*budget。
function stageOf(spentCents, policy) {
  const b = policy.monthlyBudgetCents;
  if (b <= 0) return 'unconfigured';
  const reached = (pct) => spentCents * 100 >= pct * b;
  if (reached(policy.exhaustedPct)) return 'exhausted';
  if (reached(policy.stopPct)) return 'stop';
  if (reached(policy.verifyOnlyPct)) return 'verify-only';
  if (reached(policy.warnPct)) return 'warn';
  return 'ok';
}

function stageReason(stage) {
  return stage === 'ok' || stage === 'unconfigured' ? '' : `credit-cap:${stage}`;
}

// --- Budget Guard ---
// 新規セッション作成の可否を判定する (副作用なし)。
//   request: { cents, taskClass ('check' = 低コストの確認処理), ackDailySoft }
function guard(entries, now, policy, request) {
  const req = request || {};
  const cents = req.cents;
  const taskClass = req.taskClass || 'task';
  const s = summarize(entries, now, policy);
  const deny = (code, message) => ({ allow: false, code, message, stage: s.stage, reason: stageReason(s.stage), summary: s });

  if (cents == null) return deny('BUDGET_REQUIRED', 'セッション予算は必須 (予算未指定のセッション作成は禁止)');
  if (!Number.isInteger(cents) || cents < 1) return deny('BUDGET_AMOUNT_INVALID', `セッション予算は 1 セント以上の整数 (actual: ${cents})`);
  const cap = taskClass === 'check' ? Math.min(policy.connectionTestMaxCents, policy.sessionMaxCents) : policy.sessionMaxCents;
  if (cents > cap) return deny('SESSION_CAP_EXCEEDED', `セッション予算 ${cents}¢ が上限 ${cap}¢ (${taskClass}) を超える`);
  if (policy.monthlyBudgetCents <= 0) return deny('BUDGET_NOT_CONFIGURED', 'Managed Agents の月間予算が未設定 (無制限実行は禁止)');
  if (policy.cycle.creditsExpireAt && new Date(now).toISOString() >= new Date(policy.cycle.creditsExpireAt).toISOString()) {
    return deny('CREDITS_EXPIRED', 'クレジット失効日時を過ぎている。Console で残高・有効期限を確認すること');
  }
  if (s.stage === 'exhausted') return deny('BUDGET_EXHAUSTED', '月間予算 100% 以上: 実行禁止');
  if (s.stage === 'stop') return deny('BUDGET_STOP', '月間予算 95% 以上: 新規 Managed Agents セッション停止');
  if (s.stage === 'verify-only' && taskClass !== 'check') return deny('BUDGET_VERIFY_ONLY', '月間予算 85% 以上: 低コストの確認処理 (task_class=check) のみ許可');
  if (s.committedMonthCents + cents > policy.monthlyBudgetCents) {
    return deny('MONTHLY_RESERVATION_EXCEEDED', `予約後の月間合計 ${s.committedMonthCents + cents}¢ が月間予算 ${policy.monthlyBudgetCents}¢ を超える`);
  }
  if (s.openSessions >= policy.maxConcurrentSessions) return deny('CONCURRENCY_LIMIT', `実行中セッション数が上限 ${policy.maxConcurrentSessions} に達している`);
  const warnings = [];
  if (s.committedDayCents + cents > policy.dailySoftCents) {
    if (!req.ackDailySoft) return deny('DAILY_SOFT_EXCEEDED', `予約後の日次合計 ${s.committedDayCents + cents}¢ が日次ソフト予算 ${policy.dailySoftCents}¢ を超える (--ack-daily-soft で明示許可)`);
    warnings.push('daily-soft-exceeded-acknowledged');
  }
  if (s.stage === 'warn') warnings.push('credit-cap:warn');
  if (s.period.basis !== 'billing-cycle') warnings.push('period-is-calendar-month-reference');
  return { allow: true, code: 'OK', message: '', stage: s.stage, reason: stageReason(s.stage), warnings, summary: s };
}

// 重複防止 + ガード + 予約を 1 つのロック内で行う。
function reserve(ledgerPath, now, policy, request) {
  if (!request || !request.taskId || !/^[A-Za-z0-9._:-]{1,128}$/.test(request.taskId)) {
    throw new BudgetError('TASK_ID_INVALID', 'task_id は必須 (英数字と . _ : - のみ、128 文字以内)');
  }
  return withLock(ledgerPath, () => {
    const { entries, corrupt } = readLedger(ledgerPath);
    if (corrupt > 0) return { allow: false, code: 'LEDGER_CORRUPT', message: `台帳に解釈できない行が ${corrupt} 件ある (fail-closed)` };
    const existing = foldTasks(entries).get(request.taskId);
    if (existing && !existing.released) {
      return { allow: false, code: 'DUPLICATE_TASK', message: `task_id=${request.taskId} は既に実行済み/実行中 (session=${existing.session_id || '未確定'})`, existing };
    }
    const g = guard(entries, now, policy, request);
    if (!g.allow) return g;
    appendLedger(ledgerPath, { type: 'reserve', ts: new Date(now).toISOString(), task_id: request.taskId, cents: request.cents, task_class: request.taskClass || 'task', role: request.role || null, plane: 'managed-agents' });
    return g;
  });
}

function recordUsage(ledgerPath, now, u) {
  if (!u || !u.taskId) throw new BudgetError('TASK_ID_INVALID', 'recordUsage: task_id は必須');
  const cents = Number(u.listCostCents);
  if (!Number.isInteger(cents) || cents < 0) throw new BudgetError('AMOUNT_INVALID', `list_cost_cents は 0 以上の整数 (actual: ${u.listCostCents})`);
  return withLock(ledgerPath, () => appendLedger(ledgerPath, {
    type: 'usage', ts: new Date(now).toISOString(), task_id: u.taskId, session_id: u.sessionId || null,
    list_cost_cents: cents, final: u.final === true, status: u.status || null,
    input_tokens: Number(u.inputTokens) || 0, output_tokens: Number(u.outputTokens) || 0,
    cache_read_input_tokens: Number(u.cacheReadInputTokens) || 0, active_seconds: Number(u.activeSeconds) || 0,
    model: u.model || null, plane: 'managed-agents',
  }));
}

function release(ledgerPath, now, taskId, reason) {
  return withLock(ledgerPath, () => appendLedger(ledgerPath, { type: 'release', ts: new Date(now).toISOString(), task_id: taskId, reason: reason || null, plane: 'managed-agents' }));
}

// Console の実績 (人間が Console から転記した値) と台帳の実績合計を照合する。
function reconcile(ledgerPath, now, policy, consoleCents, note) {
  if (!Number.isInteger(consoleCents) || consoleCents < 0) throw new BudgetError('AMOUNT_INVALID', 'console_cents は 0 以上の整数');
  return withLock(ledgerPath, () => {
    const { entries, corrupt } = readLedger(ledgerPath);
    const s = summarize(entries, now, policy);
    const result = {
      period: s.period, console_cents: consoleCents, ledger_actual_cents: s.actualMonthCents,
      diff_cents: consoleCents - s.actualMonthCents, corrupt_lines: corrupt,
      note: 'Console が正本。台帳は list 価格ベース (割引前) の予測値で、他経路の API 利用は含まない',
    };
    appendLedger(ledgerPath, { type: 'reconcile', ts: new Date(now).toISOString(), console_cents: consoleCents, ledger_cents: s.actualMonthCents, diff_cents: result.diff_cents, period_start: s.period.start, memo: note || null, plane: 'managed-agents' });
    return result;
  });
}

module.exports = {
  DEFAULT_POLICY, HARD_LIMITS, BudgetError, withLock, usdToCents, centsToUsd, parseCentsString, normalizePolicy,
  billingPeriod, readLedger, foldTasks, summarize, stageOf, stageReason, guard, reserve,
  recordUsage, release, reconcile,
};
