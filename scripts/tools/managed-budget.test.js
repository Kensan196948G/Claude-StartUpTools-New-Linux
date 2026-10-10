#!/usr/bin/env node
'use strict';
// managed-budget.test.js — Budget Guard と台帳のユニットテスト
// 受け入れテスト対応: T03 (予算未指定の拒否) / T04 (セント変換) / T05 (段階制御) / T06 (重複防止)

const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const b = require('./managed-budget.js');

const NOW = new Date('2026-10-10T12:00:00Z');
const policy = (over) => b.normalizePolicy(Object.assign({}, over));
const tmpLedger = () => path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'ma-budget-')), 'ledger.jsonl');

// 月内に確定済み消費 cents を持つ台帳エントリ
function spent(cents, ts = '2026-10-05T00:00:00.000Z', id = 'past') {
  return [
    { type: 'reserve', ts, task_id: id, cents: 200 },
    { type: 'usage', ts, task_id: id, session_id: `sesn_${id}`, list_cost_cents: cents, final: true },
  ];
}

test('T04 usdToCents: 浮動小数を経由せず整数セントへ変換する', () => {
  assert.equal(b.usdToCents('2'), 200);
  assert.equal(b.usdToCents('0.50'), 50);
  assert.equal(b.usdToCents('0.5'), 50);
  assert.equal(b.usdToCents('20.00'), 2000);
  assert.equal(b.usdToCents('0.07'), 7);
  assert.equal(b.usdToCents('1.15'), 115); // 1.15*100 は浮動小数だと 114.99999999999999
  assert.equal(b.usdToCents(3), 300);
});

test('T04 usdToCents: 小数 3 桁・負数・指数表記・空文字は拒否', () => {
  for (const bad of ['1.234', '-1', '1e2', '', 'abc', '1.', '.5', '$2']) {
    assert.throws(() => b.usdToCents(bad), (e) => e.code === 'AMOUNT_INVALID', `should reject ${bad}`);
  }
});

test('T04 centsToUsd / parseCentsString: 表示と API 形式', () => {
  assert.equal(b.centsToUsd(200), '2.00');
  assert.equal(b.centsToUsd(5), '0.05');
  assert.equal(b.centsToUsd(2053), '20.53');
  assert.equal(b.parseCentsString('200'), 200);
  for (const bad of ['0', '0200', '2.00', '-5', '', '2e2']) {
    assert.throws(() => b.parseCentsString(bad), (e) => e.code === 'AMOUNT_INVALID', `should reject ${bad}`);
  }
});

test('T03 guard: 予算未指定のセッションは拒否する', () => {
  const g = b.guard([], NOW, policy(), { taskClass: 'task' });
  assert.equal(g.allow, false);
  assert.equal(g.code, 'BUDGET_REQUIRED');
});

test('T03 guard: 0 以下・非整数・上限超過の予算は拒否する', () => {
  assert.equal(b.guard([], NOW, policy(), { cents: 0 }).code, 'BUDGET_AMOUNT_INVALID');
  assert.equal(b.guard([], NOW, policy(), { cents: 1.5 }).code, 'BUDGET_AMOUNT_INVALID');
  assert.equal(b.guard([], NOW, policy(), { cents: 201 }).code, 'SESSION_CAP_EXCEEDED');
  assert.equal(b.guard([], NOW, policy(), { cents: 200 }).allow, true);
});

test('T03 guard: 確認処理 (check) は接続テスト上限 50¢ まで', () => {
  assert.equal(b.guard([], NOW, policy(), { cents: 50, taskClass: 'check' }).allow, true);
  assert.equal(b.guard([], NOW, policy(), { cents: 51, taskClass: 'check' }).code, 'SESSION_CAP_EXCEEDED');
});

test('T03 guard: 月間予算 0 は無制限ではなく実行不可', () => {
  assert.equal(b.guard([], NOW, policy({ monthlyBudgetCents: 0 }), { cents: 100 }).code, 'BUDGET_NOT_CONFIGURED');
});

test('T05 stageOf: 70 / 85 / 95 / 100% の境界を整数演算で判定する', () => {
  const p = policy(); // 月間 2000¢
  assert.equal(b.stageOf(0, p), 'ok');
  assert.equal(b.stageOf(1399, p), 'ok');
  assert.equal(b.stageOf(1400, p), 'warn');
  assert.equal(b.stageOf(1699, p), 'warn');
  assert.equal(b.stageOf(1700, p), 'verify-only');
  assert.equal(b.stageOf(1899, p), 'verify-only');
  assert.equal(b.stageOf(1900, p), 'stop');
  assert.equal(b.stageOf(1999, p), 'stop');
  assert.equal(b.stageOf(2000, p), 'exhausted');
  assert.equal(b.stageOf(2500, p), 'exhausted');
});

test('T05 stageReason: lib/credits.sh と同じ語彙を使う', () => {
  assert.equal(b.stageReason('ok'), '');
  assert.equal(b.stageReason('warn'), 'credit-cap:warn');
  assert.equal(b.stageReason('verify-only'), 'credit-cap:verify-only');
  assert.equal(b.stageReason('stop'), 'credit-cap:stop');
  assert.equal(b.stageReason('exhausted'), 'credit-cap:exhausted');
});

test('T05 guard: 70% は警告つきで許可', () => {
  const g = b.guard(spent(1400), NOW, policy(), { cents: 100 });
  assert.equal(g.allow, true);
  assert.equal(g.stage, 'warn');
  assert.ok(g.warnings.includes('credit-cap:warn'));
});

test('T05 guard: 85% は通常タスクを止め、低コストの確認処理だけ許可', () => {
  const entries = spent(1700);
  const task = b.guard(entries, NOW, policy(), { cents: 100, taskClass: 'task' });
  assert.equal(task.allow, false);
  assert.equal(task.code, 'BUDGET_VERIFY_ONLY');
  const check = b.guard(entries, NOW, policy(), { cents: 50, taskClass: 'check' });
  assert.equal(check.allow, true);
  assert.equal(check.stage, 'verify-only');
});

test('T05 guard: 95% は新規セッション停止、100% は実行禁止 (確認処理も不可)', () => {
  assert.equal(b.guard(spent(1900), NOW, policy(), { cents: 10, taskClass: 'check' }).code, 'BUDGET_STOP');
  assert.equal(b.guard(spent(2000), NOW, policy(), { cents: 1, taskClass: 'check' }).code, 'BUDGET_EXHAUSTED');
});

test('T05 guard: 予約後に月間予算を超える要求は拒否する (1 セッション分の超過を許さない)', () => {
  const g = b.guard(spent(1350), NOW, policy({ dailySoftCents: 5000 }), { cents: 200 });
  assert.equal(g.allow, true); // 1350 + 200 = 1550 <= 2000
  const over = b.guard([...spent(1300, '2026-10-05T00:00:00.000Z', 'a'), ...spent(600, '2026-10-06T00:00:00.000Z', 'b')], NOW, policy({ verifyOnlyPct: 99, stopPct: 99 }), { cents: 200 });
  assert.equal(over.allow, false);
  assert.equal(over.code, 'MONTHLY_RESERVATION_EXCEEDED');
});

test('T05 guard: 日次ソフト予算は既定で拒否、明示許可で警告つき許可', () => {
  const today = spent(250, '2026-10-10T01:00:00.000Z', 'today');
  const denied = b.guard(today, NOW, policy(), { cents: 100 });
  assert.equal(denied.code, 'DAILY_SOFT_EXCEEDED');
  const ack = b.guard(today, NOW, policy(), { cents: 100, ackDailySoft: true });
  assert.equal(ack.allow, true);
  assert.ok(ack.warnings.includes('daily-soft-exceeded-acknowledged'));
});

test('guard: 並列実行数 1 を超える新規セッションは拒否する', () => {
  const open = [{ type: 'reserve', ts: '2026-10-10T11:00:00.000Z', task_id: 'running', cents: 100 }];
  assert.equal(b.guard(open, NOW, policy(), { cents: 100 }).code, 'CONCURRENCY_LIMIT');
});

test('guard: クレジット失効日時を過ぎたら新規実行を止める', () => {
  const p = policy({ cycle: { creditsExpireAt: '2026-10-09T00:00:00Z' } });
  assert.equal(b.guard([], NOW, p, { cents: 100 }).code, 'CREDITS_EXPIRED');
});

test('summarize: usage の list_cost は累積値。合算せず最大値を採用する (二重集計しない)', () => {
  const entries = [
    { type: 'reserve', ts: '2026-10-10T01:00:00.000Z', task_id: 't1', cents: 200 },
    { type: 'usage', ts: '2026-10-10T01:01:00.000Z', task_id: 't1', session_id: 's1', list_cost_cents: 30, final: false },
    { type: 'usage', ts: '2026-10-10T01:02:00.000Z', task_id: 't1', session_id: 's1', list_cost_cents: 80, final: false },
    { type: 'usage', ts: '2026-10-10T01:03:00.000Z', task_id: 't1', session_id: 's1', list_cost_cents: 120, final: true },
  ];
  const s = b.summarize(entries, NOW, policy());
  assert.equal(s.actualMonthCents, 120);
  assert.equal(s.committedMonthCents, 120); // 確定後は予約額ではなく実績
  assert.equal(s.openSessions, 0);
});

test('summarize: 未確定セッションは予約額で保守的に計上し、解除済みは 0', () => {
  const entries = [
    { type: 'reserve', ts: '2026-10-10T01:00:00.000Z', task_id: 'open', cents: 200 },
    { type: 'usage', ts: '2026-10-10T01:01:00.000Z', task_id: 'open', session_id: 's1', list_cost_cents: 20, final: false },
    { type: 'reserve', ts: '2026-10-10T02:00:00.000Z', task_id: 'failed', cents: 150 },
    { type: 'release', ts: '2026-10-10T02:00:01.000Z', task_id: 'failed', reason: 'create-failed' },
  ];
  const s = b.summarize(entries, NOW, policy());
  assert.equal(s.committedMonthCents, 200);
  assert.equal(s.actualMonthCents, 20);
  assert.equal(s.openSessions, 1);
});

test('billingPeriod: anchorDay 未設定は暦月の参考値、設定時は請求サイクル', () => {
  const ref = b.billingPeriod(NOW, { anchorDay: null });
  assert.equal(ref.basis, 'calendar-month-reference');
  assert.equal(ref.start, '2026-10-01T00:00:00.000Z');
  const cyc = b.billingPeriod(NOW, { anchorDay: 15 });
  assert.equal(cyc.basis, 'billing-cycle');
  assert.equal(cyc.start, '2026-09-15T00:00:00.000Z');
  assert.equal(cyc.end, '2026-10-15T00:00:00.000Z');
  assert.equal(b.billingPeriod(new Date('2026-10-20T00:00:00Z'), { anchorDay: 15 }).start, '2026-10-15T00:00:00.000Z');
});

test('summarize: 前の請求期間の消費は当期に含めない', () => {
  const s = b.summarize(spent(1900, '2026-09-20T00:00:00.000Z'), NOW, policy());
  assert.equal(s.committedMonthCents, 0);
  assert.equal(s.stage, 'ok');
});

test('normalizePolicy: 無制限リトライ・不正な閾値順・不正な anchorDay を拒否する', () => {
  assert.throws(() => b.normalizePolicy({ maxApiRetries: 2 }), (e) => e.code === 'POLICY_INVALID');
  assert.throws(() => b.normalizePolicy({ warnPct: 90, verifyOnlyPct: 85 }), (e) => e.code === 'POLICY_INVALID');
  assert.throws(() => b.normalizePolicy({ monthlyBudgetCents: 20.5 }), (e) => e.code === 'POLICY_INVALID');
  assert.throws(() => b.normalizePolicy({ cycle: { anchorDay: 31 } }), (e) => e.code === 'POLICY_INVALID');
  assert.throws(() => b.normalizePolicy({ maxConcurrentSessions: 0 }), (e) => e.code === 'POLICY_INVALID');
});

test('T06 reserve: 同じ task_id の 2 回目は DUPLICATE_TASK で拒否する', () => {
  const ledger = tmpLedger();
  const p = policy();
  const first = b.reserve(ledger, NOW, p, { taskId: 'task-1', cents: 100 });
  assert.equal(first.allow, true);
  const second = b.reserve(ledger, NOW, p, { taskId: 'task-1', cents: 100 });
  assert.equal(second.allow, false);
  assert.equal(second.code, 'DUPLICATE_TASK');
  assert.equal(b.readLedger(ledger).entries.filter((e) => e.type === 'reserve').length, 1);
});

test('T06 reserve: 完了済みタスクも重複扱い、作成失敗で解除したタスクは再実行できる', () => {
  const ledger = tmpLedger();
  const p = policy();
  assert.equal(b.reserve(ledger, NOW, p, { taskId: 'done', cents: 50 }).allow, true);
  b.recordUsage(ledger, NOW, { taskId: 'done', sessionId: 's1', listCostCents: 10, final: true });
  assert.equal(b.reserve(ledger, NOW, p, { taskId: 'done', cents: 50 }).code, 'DUPLICATE_TASK');

  assert.equal(b.reserve(ledger, NOW, p, { taskId: 'retry', cents: 50 }).allow, true);
  b.release(ledger, NOW, 'retry', 'create-failed:SERVICE');
  assert.equal(b.reserve(ledger, NOW, p, { taskId: 'retry', cents: 50 }).allow, true);
});

test('T06 reserve: task_id が無い・不正な場合は例外', () => {
  const ledger = tmpLedger();
  assert.throws(() => b.reserve(ledger, NOW, policy(), { cents: 50 }), (e) => e.code === 'TASK_ID_INVALID');
  assert.throws(() => b.reserve(ledger, NOW, policy(), { taskId: 'a b', cents: 50 }), (e) => e.code === 'TASK_ID_INVALID');
});

test('reserve: 台帳に解釈できない行があれば fail-closed で拒否する', () => {
  const ledger = tmpLedger();
  fs.writeFileSync(ledger, '{"type":"reserve","ts":"2026-10-10T00:00:00.000Z","task_id":"x","cents":10}\nnot-json\n');
  const g = b.reserve(ledger, NOW, policy(), { taskId: 'new', cents: 50 });
  assert.equal(g.allow, false);
  assert.equal(g.code, 'LEDGER_CORRUPT');
});

test('reconcile: Console の実績との差分を返し、照合記録を残す', () => {
  const ledger = tmpLedger();
  const p = policy();
  b.reserve(ledger, NOW, p, { taskId: 'r1', cents: 100 });
  b.recordUsage(ledger, NOW, { taskId: 'r1', sessionId: 's1', listCostCents: 42, final: true });
  const r = b.reconcile(ledger, NOW, p, 40, 'console 転記');
  assert.equal(r.ledger_actual_cents, 42);
  assert.equal(r.console_cents, 40);
  assert.equal(r.diff_cents, -2);
  assert.equal(b.readLedger(ledger).entries.filter((e) => e.type === 'reconcile').length, 1);
  // 照合記録は消費額に影響しない
  assert.equal(b.summarize(b.readLedger(ledger).entries, NOW, p).actualMonthCents, 42);
});

test('normalizePolicy: PoC のハード上限を超える値・不正な日時は拒否する', () => {
  for (const over of [{ maxConcurrentSessions: 2 }, { sessionMaxCents: 501 }, { monthlyBudgetCents: 10001 }, { dailySoftCents: 10001 }, { exhaustedPct: 101 }]) {
    assert.throws(() => b.normalizePolicy(over), (e) => e.code === 'POLICY_INVALID', JSON.stringify(over));
  }
  assert.throws(() => b.normalizePolicy({ cycle: { creditsExpireAt: 'bogus' } }), (e) => e.code === 'POLICY_INVALID');
  assert.throws(() => b.normalizePolicy({ cycle: { consoleVerifiedAt: 12345 } }), (e) => e.code === 'POLICY_INVALID');
  assert.equal(b.normalizePolicy({ cycle: { creditsExpireAt: '2026-11-01T00:00:00Z' } }).cycle.creditsExpireAt, '2026-11-01T00:00:00Z');
});

test('請求期間・日付の境界: 前期間に開始した未確定セッションも並列数と予約に数える', () => {
  const open = [{ type: 'reserve', ts: '2026-09-30T23:59:50.000Z', task_id: 'cross', cents: 200 }];
  const justAfter = new Date('2026-10-01T00:00:05Z');
  const g = b.guard(open, justAfter, policy(), { cents: 100 });
  assert.equal(g.allow, false);
  assert.equal(g.code, 'CONCURRENCY_LIMIT');
  const s = b.summarize(open, justAfter, policy());
  assert.deepEqual([s.openSessions, s.committedMonthCents, s.committedDayCents], [1, 200, 200]);
  // 確定後は開始した期間の実績になり、当期の枠は空く
  const closed = [...open, { type: 'usage', ts: '2026-10-01T00:01:00.000Z', task_id: 'cross', session_id: 's', list_cost_cents: 150, final: true }];
  assert.deepEqual([b.summarize(closed, justAfter, policy()).openSessions, b.summarize(closed, justAfter, policy()).committedMonthCents], [0, 0]);
});

test('解除済みタスクに後から使用量が届いた場合、その実績は消さない (実は作成されていた場合)', () => {
  const entries = [
    { type: 'reserve', ts: '2026-10-10T01:00:00.000Z', task_id: 'ghost', cents: 200 },
    { type: 'release', ts: '2026-10-10T01:00:01.000Z', task_id: 'ghost', reason: 'create-rejected' },
    { type: 'usage', ts: '2026-10-10T01:05:00.000Z', task_id: 'ghost', session_id: 's', list_cost_cents: 40, final: true },
  ];
  const s = b.summarize(entries, NOW, policy());
  assert.deepEqual([s.committedMonthCents, s.actualMonthCents, s.openSessions], [40, 40, 0]);
});

test('ロック: 取得できなければ fail-closed。古いロックを自動回収せず、他者のロックを解放しない', () => {
  const ledger = tmpLedger();
  const lockDir = `${ledger}.lock`;
  fs.mkdirSync(lockDir);
  const old = new Date(Date.now() - 10 * 60 * 1000);
  fs.utimesSync(lockDir, old, old); // 10 分前のロックでも回収しない
  assert.throws(() => b.withLock(ledger, () => 'entered', { timeoutMs: 200 }), (e) => e.code === 'LEDGER_LOCK_TIMEOUT');
  assert.ok(fs.existsSync(lockDir), '他者のロックは残る');
  assert.throws(() => b.reserve(ledger, NOW, policy(), { taskId: 'blocked', cents: 10 }, undefined), (e) => e.code === 'LEDGER_LOCK_TIMEOUT');
  fs.rmdirSync(lockDir);
  assert.equal(b.withLock(ledger, () => 'entered'), 'entered');
  assert.equal(fs.existsSync(lockDir), false, '自分のロックは解放する');
  assert.throws(() => b.withLock(ledger, () => { throw new Error('boom'); }), /boom/);
  assert.equal(fs.existsSync(lockDir), false, '例外時も解放する');
});

test('ロック: 複数プロセスが同時に予約しても並列数 1 を超えて許可しない', () => {
  const { spawnSync } = require('child_process');
  const ledger = tmpLedger();
  const script = `
    const b = require(${JSON.stringify(require.resolve('./managed-budget.js'))});
    const g = b.reserve(process.argv[1], new Date('2026-10-10T12:00:00Z'), b.normalizePolicy({}), { taskId: 'p-' + process.argv[2], cents: 100 });
    process.stdout.write(g.allow ? 'ALLOW' : g.code);`;
  const runner = `
    const { spawn } = require('child_process');
    let left = 8; const out = [];
    for (let i = 0; i < 8; i += 1) {
      const c = spawn(process.execPath, ['-e', ${JSON.stringify(script)}, ${JSON.stringify(ledger)}, String(i)]);
      let s = ''; c.stdout.on('data', (d) => { s += d; });
      c.on('close', () => { out.push(s); left -= 1; if (!left) process.stdout.write(JSON.stringify(out)); });
    }`;
  const r = spawnSync(process.execPath, ['-e', runner], { encoding: 'utf8', timeout: 60000 });
  const results = JSON.parse(r.stdout);
  assert.equal(results.length, 8);
  assert.equal(results.filter((x) => x === 'ALLOW').length, 1, JSON.stringify(results));
  assert.equal(results.filter((x) => x === 'CONCURRENCY_LIMIT').length, 7, JSON.stringify(results));
  assert.equal(fs.existsSync(`${ledger}.lock`), false);
});

test('台帳ファイルは所有者のみ読み書き可 (0600) で作られる', () => {
  const ledger = tmpLedger();
  b.reserve(ledger, NOW, policy(), { taskId: 'perm', cents: 10 });
  assert.equal(fs.statSync(ledger).mode & 0o777, 0o600);
});
