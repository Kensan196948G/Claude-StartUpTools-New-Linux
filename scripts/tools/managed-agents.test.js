#!/usr/bin/env node
'use strict';
// managed-agents.test.js — Managed Agents Adapter のユニットテスト (ネットワークなし・fetch はモック)
// 受け入れテスト対応: T01 設定 / T02 API キー未設定 / T03 予算必須 / T06 重複 / T07 タイムアウト /
//   T08 GitHub 読取専用 / T09 main への push 不可 / T10 本番アクセス拒否 / T11 秘密の非表示 / T12 Local への切替

const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync, spawnSync } = require('child_process');
const ma = require('./managed-agents.js');
const budget = require('./managed-budget.js');

const TOOL = path.join(__dirname, 'managed-agents.js');
const TEMPLATE = path.join(__dirname, '..', '..', 'config', 'managed-agents.json.template');
const FAKE_KEY = 'sk-ant-api03-TESTKEYTESTKEYTESTKEY0000';
const FAKE_GH = 'github_pat_TESTTOKENTESTTOKEN0000';
const AGENT_ID = 'agent_01REVIEWREVIEW';
const ENV_ID = 'env_01TESTENVTESTENV';
const NOW = new Date('2026-10-10T12:00:00Z');

function baseConfig(over) {
  return Object.assign({
    enabled: true,
    mode: 'live',
    environmentId: ENV_ID,
    agents: { 'repository-review': { id: AGENT_ID, version: 3 } },
    budget: { amountCents: '200', currency: 'USD' },
    budgetPolicy: {},
    github: { workspace: { repository: 'https://github.com/Kensan196948G/Claude-StartUpTools-New-Linux', ref: 'main', tokenEnv: 'CLAUDEOS_MA_GITHUB_TOKEN' } },
  }, over);
}

function jsonResponse(status, body, headers) {
  return {
    ok: status >= 200 && status < 300,
    status,
    headers: { get: (k) => (headers && headers[k.toLowerCase()]) || null },
    text: async () => (body === undefined ? '' : JSON.stringify(body)),
  };
}

const READ_ONLY_TOOLS = () => [{
  type: 'agent_toolset_20260401',
  default_config: { enabled: false, permission_policy: { type: 'always_allow' } },
  configs: ['bash', 'edit', 'write', 'web_fetch', 'web_search'].map((name) => ({ name, enabled: false }))
    .concat(['read', 'glob', 'grep'].map((name) => ({ name, enabled: true }))),
}];
// リモートの Agent は roster の定義 (system・model) と一致している状態を既定にする
const REVIEW_DEF = ma.agentDefinition(ma.loadRoster({}), 'repository-review').body;
const remoteAgent = (over) => Object.assign({ id: AGENT_ID, version: 3, archived_at: null, system: REVIEW_DEF.system, model: { id: REVIEW_DEF.model.id, speed: 'standard' }, tools: READ_ONLY_TOOLS(), mcp_servers: [], skills: [] }, over);
const remoteEnv = (over) => Object.assign({ id: ENV_ID, name: 'claudeos-managed-readonly', archived_at: null, config: { type: 'cloud', networking: { type: 'limited', allow_mcp_servers: false, allow_package_managers: false, allowed_hosts: [] } } }, over);

// handler(call, calls) -> response | undefined。undefined を返した GET /v1/agents/{id} と /v1/environments/{id} には
// 検証を通る既定の応答を返す (セッション作成前の実体検証)。calls に全リクエストを記録する。
function makeCtx(opts) {
  const o = opts || {};
  const stateDir = fs.mkdtempSync(path.join(os.tmpdir(), 'ma-adapter-'));
  const calls = [];
  // 設定パスも一時領域へ向ける。config: null (設定なし) のテストが、開発機に実在する
  // config/managed-agents.json を読んで結果が変わるのを防ぐ。
  const env = Object.assign({ ANTHROPIC_API_KEY: FAKE_KEY, CLAUDEOS_MA_GITHUB_TOKEN: FAKE_GH, CLAUDEOS_MA_STATE_DIR: stateDir, CLAUDEOS_MANAGED_AGENTS_CONFIG: path.join(stateDir, 'no-such-config.json') }, o.env);
  for (const k of Object.keys(env)) if (env[k] === null) delete env[k];
  let t = NOW.getTime();
  const ctx = ma.createContext({
    config: o.config === undefined ? baseConfig() : o.config,
    env,
    now: () => new Date(t),
    sleep: async (ms) => { t += ms; },
    requestTimeoutMs: 50,
    fetch: async (url, init) => {
      const call = { url, method: init.method, headers: init.headers, body: init.body ? JSON.parse(init.body) : undefined, signal: init.signal, redirect: init.redirect };
      calls.push(call);
      const custom = o.handler ? await o.handler(call, calls) : undefined;
      if (custom !== undefined) return custom;
      if (call.method === 'GET' && /\/v1\/agents\/agent_[A-Za-z0-9]+$/.test(url)) return jsonResponse(200, remoteAgent());
      if (call.method === 'GET' && /\/v1\/environments\/env_[A-Za-z0-9]+$/.test(url)) return jsonResponse(200, remoteEnv());
      // 既定: セッションは完了して停止している (stop_reason つきの idle イベントがある)
      if (call.method === 'GET' && /\/events\?/.test(url)) return jsonResponse(200, { data: [idleEvent('end_turn')], next_page: null });
      return jsonResponse(200, {});
    },
  });
  const sessionPosts = () => calls.filter((c) => c.method === 'POST' && c.url.endsWith('/v1/sessions'));
  return { ctx, calls, stateDir, sessionPosts, advance: (ms) => { t += ms; } };
}

const sessionArgs = (over) => Object.assign({ taskId: 'task-001', role: 'repository-review', taskType: 'review', prompt: 'README を確認してください' }, over);
const idleEvent = (type) => ({ id: 'sevt_idle', type: 'session.status_idle', processed_at: '2026-10-10T12:00:05Z', stop_reason: { type } });
const isSessionCreate = (call) => call.method === 'POST' && call.url.endsWith('/v1/sessions');
const sessionObj = (id, taskId, over) => Object.assign({ id, status: 'idle', metadata: { claudeos_task_id: taskId }, usage: { list_cost: { amount: '12', currency: 'USD' } } }, over);
const reserveTask = (ctx, taskId, sessionId, cents) => {
  budget.reserve(ctx.ledgerPath, ctx.now(), ctx.policy, { taskId, cents: cents || 200 });
  if (sessionId) budget.recordUsage(ctx.ledgerPath, ctx.now(), { taskId, sessionId, listCostCents: 0, final: false, status: 'created' });
};
const summary = (ctx) => budget.summarize(budget.readLedger(ctx.ledgerPath).entries, ctx.now(), ctx.policy);

// ---------- T01 設定の読み込み ----------

test('T01 配布テンプレートは既定で利用不可 (enabled=false / mode=disabled)', () => {
  const v = ma.validateConfig(JSON.parse(fs.readFileSync(TEMPLATE, 'utf8')), {});
  assert.equal(v.ok, false);
  assert.equal(v.mode, 'disabled');
  assert.deepEqual(v.reasons, ['not-enabled', 'mode-disabled'], 'テンプレートに秘密・不正なポリシー・不正な roster は無い');
});

test('T01 テンプレートの予算既定値は運用モデル通り (月 $20 / セッション $2 / 接続テスト $0.50 / 日次 $3 / 並列 1 / 再試行 1)', () => {
  const t = JSON.parse(fs.readFileSync(TEMPLATE, 'utf8'));
  const p = budget.normalizePolicy(t.budgetPolicy);
  assert.deepEqual([p.monthlyBudgetCents, p.sessionMaxCents, p.connectionTestMaxCents, p.dailySoftCents, p.maxConcurrentSessions, p.maxApiRetries], [2000, 200, 50, 300, 1, 1]);
  assert.deepEqual([p.warnPct, p.verifyOnlyPct, p.stopPct, p.exhaustedPct], [70, 85, 95, 100]);
  assert.equal(t.budget.amountCents, '200');
});

test('T01 有効な設定は usable、設定ファイル不在は missing、オブジェクト以外は invalid', () => {
  assert.equal(ma.validateConfig(baseConfig(), {}).ok, true);
  assert.equal(ma.validateConfig(null, {}).mode, 'missing');
  assert.equal(ma.validateConfig([], {}).ok, false);
});

test('T01 不正な mode / 予算ポリシー / 送信先 URL / vault / tokenEnv は利用不可になる', () => {
  const reasons = (over) => ma.validateConfig(baseConfig(over), {}).reasons;
  assert.ok(reasons({ mode: 'turbo' }).includes('mode-invalid'));
  assert.ok(reasons({ budgetPolicy: { maxApiRetries: 5 } }).some((r) => r.startsWith('budget-policy-invalid')));
  assert.ok(reasons({ budgetPolicy: { monthlyBudgetCents: 0 } }).includes('monthly-budget-not-configured'));
  assert.ok(reasons({ budgetPolicy: { cycle: { creditsExpireAt: 'bogus' } } }).some((r) => r.startsWith('budget-policy-invalid')));
  assert.ok(reasons({ apiBaseUrl: 'https://evil.example.com' }).includes('api-base-url-not-allowed'));
  assert.ok(reasons({ vaultIds: ['vlt_01ABC'] }).includes('vault-ids-not-allowed-in-poc'));
  assert.ok(reasons({ github: { workspace: { tokenEnv: 'ANTHROPIC_API_KEY' } } }).includes('github-token-env-invalid'));
});

test('T01 予算ポリシーのハード上限: 設定で並列数・セッション上限・月額を引き上げられない', () => {
  for (const over of [{ maxConcurrentSessions: 2 }, { sessionMaxCents: 501 }, { monthlyBudgetCents: 10001 }, { connectionTestMaxCents: 101 }, { exhaustedPct: 150 }]) {
    assert.ok(ma.validateConfig(baseConfig({ budgetPolicy: over }), {}).reasons.some((r) => r.startsWith('budget-policy-invalid')), JSON.stringify(over));
  }
});

test('T01 isAllowedBaseUrl: API キーの送信先は https://api.anthropic.com のみ。loopback はテスト用の環境変数がある時だけ', () => {
  assert.equal(ma.isAllowedBaseUrl('https://api.anthropic.com', {}), true);
  for (const bad of ['http://api.anthropic.com', 'https://api.anthropic.com.evil.test', 'https://api.anthropic.com@evil.test', 'https://user:pw@api.anthropic.com', 'https://api.anthropic.com:8443', 'http://127.0.0.1:8080', 'http://localhost:9999', 'not a url']) {
    assert.equal(ma.isAllowedBaseUrl(bad, {}), false, bad);
  }
  assert.equal(ma.isAllowedBaseUrl('http://127.0.0.1:8080', { CLAUDEOS_MA_ALLOW_LOOPBACK: '1' }), true);
  assert.equal(ma.isAllowedBaseUrl('http://localhost:8080', { CLAUDEOS_MA_ALLOW_LOOPBACK: '1' }), false);
  assert.equal(ma.isAllowedBaseUrl('https://evil.example.com', { CLAUDEOS_MA_ALLOW_LOOPBACK: '1' }), false);
});

// ---------- T02 API キー未設定時の安全な停止 ----------

test('T02 API キー未設定: API を 1 回も呼ばずに停止し、台帳にも予約を残さない', async () => {
  const { ctx, calls } = makeCtx({ env: { ANTHROPIC_API_KEY: null } });
  await assert.rejects(ma.sessionCreate(ctx, sessionArgs()), (e) => e.cls === 'KEY_MISSING' && e.code === 'API_KEY_MISSING');
  assert.equal(calls.length, 0);
  assert.equal(budget.readLedger(ctx.ledgerPath).entries.length, 0);
});

test('T02 API キー未設定 (CLI): 終了コード 2・Local 経路への切替可', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ma-cli-'));
  const cfg = path.join(dir, 'managed-agents.json');
  fs.writeFileSync(cfg, JSON.stringify(baseConfig()));
  const env = { PATH: process.env.PATH, HOME: dir, CLAUDEOS_MA_STATE_DIR: dir };
  const r = spawnSync(process.execPath, [TOOL, 'session', 'create', '--config', cfg, '--task-id', 't1', '--role', 'repository-review', '--task-type', 'review', '--prompt', 'x'], { env, encoding: 'utf8' });
  assert.equal(r.status, 2);
  const err = JSON.parse(r.stderr);
  assert.equal(err.code, 'API_KEY_MISSING');
  assert.equal(err.fallback.to, 'local');
  assert.equal(err.state, 'UNAVAILABLE');
});

test('T02 mode=disabled / dry-run では live 操作を拒否し、ネットワークへ出ない', async () => {
  const dis = makeCtx({ config: baseConfig({ mode: 'disabled' }) });
  await assert.rejects(ma.sessionCreate(dis.ctx, sessionArgs()), (e) => e.code === 'MANAGED_UNAVAILABLE');
  const dry = makeCtx({ config: baseConfig({ mode: 'dry-run' }) });
  await assert.rejects(ma.sessionWait(dry.ctx, { sessionId: 'sesn_x', taskId: 't' }), (e) => e.code === 'NOT_LIVE');
  await assert.rejects(ma.sessionClose(dry.ctx, { taskId: 't' }), (e) => e.code === 'NOT_LIVE');
  await ma.sessionCreate(dry.ctx, sessionArgs());
  await ma.agentsSync(dry.ctx, null);
  await ma.envEnsure(dry.ctx);
  await ma.status(dry.ctx, { probe: true });
  assert.equal(dis.calls.length + dry.calls.length, 0);
});

// ---------- T03 予算未指定セッション作成の拒否 ----------

test('T03 予算未指定 (config にも引数にも無い) のセッション作成は拒否し、API を呼ばない', async () => {
  const { ctx, calls } = makeCtx({ config: baseConfig({ budget: undefined }) });
  await assert.rejects(ma.sessionCreate(ctx, sessionArgs()), (e) => e.cls === 'BUDGET' && e.code === 'BUDGET_REQUIRED');
  assert.equal(calls.length, 0);
});

test('T03 セッション上限 ($2) を超える予算は拒否し、セッションを作らない', async () => {
  const { ctx, sessionPosts } = makeCtx();
  await assert.rejects(ma.sessionCreate(ctx, sessionArgs({ budgetCents: '500' })), (e) => e.cls === 'BUDGET' && e.code === 'BUDGET_SESSION_CAP_EXCEEDED');
  assert.equal(sessionPosts().length, 0);
});

test('T03 作成リクエストには必ず budget.max_list_cost (セント整数の文字列・USD) が入る', async () => {
  const { ctx, sessionPosts } = makeCtx({ handler: (c) => (isSessionCreate(c) ? jsonResponse(200, { id: 'sesn_01NEW', status: 'running' }) : undefined) });
  const out = await ma.sessionCreate(ctx, sessionArgs({ budgetCents: '150' }));
  assert.equal(out.session_id, 'sesn_01NEW');
  const [post] = sessionPosts();
  assert.deepEqual(post.body.budget, { type: 'limit', max_list_cost: { amount: '150', currency: 'USD' } });
  assert.equal(post.headers['anthropic-beta'], 'managed-agents-2026-04-01');
  assert.equal(post.headers['anthropic-version'], '2023-06-01');
  assert.equal(post.redirect, 'error', 'リダイレクトを追わない');
  // agent は検証した version に固定、inference_geo と vault_ids は載せない
  assert.deepEqual(post.body.agent, { type: 'agent', id: AGENT_ID, version: 3 });
  assert.ok(!('inference_geo' in post.body) && !('vault_ids' in post.body));
  assert.equal(post.body.initial_events[0].type, 'user.message');
  assert.equal(post.body.metadata.claudeos_task_id, 'task-001');
});

test('T03 確認処理 (check): 既定額は接続テスト上限 50¢ に丸め、明示した超過額は拒否', async () => {
  const ok = makeCtx({ handler: (c) => (isSessionCreate(c) ? jsonResponse(200, { id: 'sesn_01CHK', status: 'running' }) : undefined) });
  await ma.sessionCreate(ok.ctx, sessionArgs({ taskType: 'check' }));
  assert.equal(ok.sessionPosts()[0].body.budget.max_list_cost.amount, '50');
  const over = makeCtx();
  await assert.rejects(ma.sessionCreate(over.ctx, sessionArgs({ taskType: 'check', budgetCents: '100' })), (e) => e.cls === 'BUDGET');
  assert.equal(over.sessionPosts().length, 0);
});

// ---------- T05 段階制御 (adapter 経由) ----------

test('T05 月間予算 95% 以上では新規セッションを作らない', async () => {
  const { ctx, sessionPosts } = makeCtx();
  fs.mkdirSync(path.dirname(ctx.ledgerPath), { recursive: true });
  fs.writeFileSync(ctx.ledgerPath, [
    { type: 'reserve', ts: '2026-10-02T00:00:00.000Z', task_id: 'old', cents: 200 },
    { type: 'usage', ts: '2026-10-02T00:10:00.000Z', task_id: 'old', session_id: 's', list_cost_cents: 1900, final: true },
  ].map((e) => JSON.stringify(e)).join('\n') + '\n');
  await assert.rejects(ma.sessionCreate(ctx, sessionArgs()), (e) => e.cls === 'BUDGET' && e.code === 'BUDGET_STOP');
  assert.equal(sessionPosts().length, 0);
});

// ---------- T06 重複セッション起動の防止 ----------

test('T06 同じ task_id の 2 回目は DUPLICATE で拒否し、セッション作成は 1 回だけ', async () => {
  const { ctx, sessionPosts } = makeCtx({ handler: (c) => (isSessionCreate(c) ? jsonResponse(200, { id: 'sesn_01DUP', status: 'running' }) : undefined) });
  await ma.sessionCreate(ctx, sessionArgs());
  await assert.rejects(ma.sessionCreate(ctx, sessionArgs()), (e) => e.cls === 'DUPLICATE' && e.extra.session_id === 'sesn_01DUP');
  assert.equal(sessionPosts().length, 1);
  assert.equal(ma.fallbackDecision('DUPLICATE').to, 'none');
});

test('T06 実行中セッションがある間は別タスクも作らない (並列 1)', async () => {
  const { ctx, sessionPosts } = makeCtx({ handler: (c) => (isSessionCreate(c) ? jsonResponse(200, { id: 'sesn_01RUN', status: 'running' }) : undefined) });
  await ma.sessionCreate(ctx, sessionArgs());
  await assert.rejects(ma.sessionCreate(ctx, sessionArgs({ taskId: 'task-002' })), (e) => e.cls === 'BUDGET' && e.code === 'CONCURRENCY_LIMIT');
  assert.equal(sessionPosts().length, 1);
});

// ---------- T07 API タイムアウト・障害時の安全な停止 ----------

test('T07 セッション作成のタイムアウト: POST を再試行せず停止。予約は残し、Local へ自動で戻さない', async () => {
  const { ctx, sessionPosts } = makeCtx({
    handler: (call) => (isSessionCreate(call) ? new Promise((_, reject) => {
      call.signal.addEventListener('abort', () => { const e = new Error('aborted'); e.name = 'AbortError'; reject(e); });
    }) : undefined),
  });
  let err;
  await assert.rejects(ma.sessionCreate(ctx, sessionArgs()), (e) => { err = e; return e.cls === 'TIMEOUT' && e.extra.reservation === 'kept-session-state-unknown'; });
  assert.equal(sessionPosts().length, 1, 'POST は 1 回だけ (自動再試行なし)');
  assert.equal(summary(ctx).committedMonthCents, 200);
  assert.equal(ma.errorPayload(err, ctx).body.fallback.to, 'none', '作成の成否が不明なまま Local で再実行しない');
});

test('T07 作成が 5xx / 529 / 本文読み取り失敗で終わっても予約を残す (作成済みかもしれない)。同じ task_id は作れない', async () => {
  const responses = [
    () => jsonResponse(502, { type: 'error', error: { type: 'api_error', message: 'bad gateway' } }),
    () => jsonResponse(529, { type: 'error', error: { type: 'overloaded_error', message: 'busy' } }),
    () => ({ ok: true, status: 200, headers: { get: () => null }, text: async () => { throw new TypeError('terminated'); } }),
    () => jsonResponse(200, {}),
  ];
  for (const make of responses) {
    const { ctx, sessionPosts } = makeCtx({ handler: (c) => (isSessionCreate(c) ? make() : undefined) });
    let err;
    await assert.rejects(ma.sessionCreate(ctx, sessionArgs()), (e) => { err = e; return true; });
    assert.equal(sessionPosts().length, 1);
    assert.equal(summary(ctx).committedMonthCents, 200, '予約は残る');
    assert.equal(summary(ctx).openSessions, 1);
    assert.equal(ma.errorPayload(err, ctx).body.fallback.to, 'none');
    await assert.rejects(ma.sessionCreate(ctx, sessionArgs()), (e) => e.cls === 'DUPLICATE');
    assert.equal(sessionPosts().length, 1, '二重作成しない');
  }
});

test('T07 サーバーが明確に拒否した場合 (400 / 401 / 429) だけ予約を解除する', async () => {
  for (const [status, type, cls] of [[400, 'invalid_request_error', 'INVALID_REQUEST'], [401, 'authentication_error', 'AUTH'], [429, 'rate_limit_error', 'RATE_LIMIT']]) {
    const { ctx, sessionPosts } = makeCtx({ handler: (c) => (isSessionCreate(c) ? jsonResponse(status, { type: 'error', error: { type, message: 'no' } }) : undefined) });
    await assert.rejects(ma.sessionCreate(ctx, sessionArgs()), (e) => e.cls === cls && e.extra.reservation === 'released');
    assert.equal(sessionPosts().length, 1);
    assert.equal(summary(ctx).committedMonthCents, 0);
    assert.equal(summary(ctx).openSessions, 0);
  }
});

test('T07 GET は最大 1 回だけ再試行する (無制限リトライしない)', async () => {
  const { ctx, calls } = makeCtx({ handler: () => jsonResponse(529, { type: 'error', error: { type: 'overloaded_error', message: 'busy' } }) });
  await assert.rejects(ma.apiRequest(ctx, 'GET', '/v1/agents?limit=1'), (e) => e.cls === 'SERVICE' && e.extra.attempts === 2);
  assert.equal(calls.length, 2);
});

test('T07 応答本文が届かない場合もタイムアウトで打ち切る', async () => {
  const { ctx } = makeCtx({
    handler: (call) => ({ ok: true, status: 200, headers: { get: () => null }, text: () => new Promise((_, reject) => { call.signal.addEventListener('abort', () => { const e = new Error('aborted'); e.name = 'AbortError'; reject(e); }); }) }),
  });
  await assert.rejects(ma.apiRequest(ctx, 'POST', '/v1/sessions', {}), (e) => e.cls === 'TIMEOUT');
});

test('T07 監視が上限時間を超えたら user.interrupt を送り、停止を確認できた場合だけ使用量を確定する', async () => {
  const { ctx, calls } = makeCtx({
    handler: (call) => {
      if (call.method === 'POST') return jsonResponse(200, {});
      if (/\/events\?/.test(call.url)) return jsonResponse(200, { data: [{ id: 'e1', type: 'session.status_running', processed_at: '2026-10-10T12:00:01Z' }], next_page: null });
      return jsonResponse(200, sessionObj('sesn_01SLOW', 'task-slow', { usage: { list_cost: { amount: '37', currency: 'USD' } } }));
    },
  });
  reserveTask(ctx, 'task-slow', 'sesn_01SLOW');
  await assert.rejects(ma.sessionWait(ctx, { sessionId: 'sesn_01SLOW', taskId: 'task-slow', maxWaitSeconds: 20, pollMs: 5000 }),
    (e) => e.cls === 'TIMEOUT' && e.code === 'SESSION_WAIT_TIMEOUT' && e.extra.result.interrupt_sent === true && e.extra.result.usage_finalized === true);
  const interrupts = calls.filter((c) => c.method === 'POST');
  assert.equal(interrupts.length, 1);
  assert.deepEqual(interrupts[0].body, { events: [{ type: 'user.interrupt' }] });
  assert.equal(summary(ctx).actualMonthCents, 37);
  assert.equal(summary(ctx).openSessions, 0);
});

test('T07 中断に失敗してセッションが動き続けている場合は確定せず、並列枠も解放せず、Local へも戻さない', async () => {
  const { ctx } = makeCtx({
    handler: (call) => {
      if (call.method === 'POST') return jsonResponse(500, { type: 'error', error: { type: 'api_error', message: 'boom' } });
      if (/\/events\?/.test(call.url)) return jsonResponse(200, { data: [{ id: 'e1', type: 'session.status_running', processed_at: '2026-10-10T12:00:01Z' }] });
      return jsonResponse(200, sessionObj('sesn_01LIVE', 'task-live', { status: 'running', usage: { list_cost: { amount: '5', currency: 'USD' } } }));
    },
  });
  reserveTask(ctx, 'task-live', 'sesn_01LIVE');
  let err;
  await assert.rejects(ma.sessionWait(ctx, { sessionId: 'sesn_01LIVE', taskId: 'task-live', maxWaitSeconds: 20, pollMs: 5000 }), (e) => { err = e; return e.code === 'SESSION_STILL_RUNNING'; });
  assert.equal(err.extra.result.interrupt_sent, false);
  assert.equal(err.extra.result.usage_finalized, false);
  assert.equal(summary(ctx).openSessions, 1, '並列枠は解放しない');
  assert.equal(summary(ctx).committedMonthCents, 200, '予約額のまま計上する');
  assert.equal(ma.errorPayload(err, ctx).body.fallback.to, 'none');
});

test('T07 監視中の API 障害: 未確定のまま残し、Local へ自動で戻さない', async () => {
  const { ctx } = makeCtx({ handler: () => jsonResponse(503, { type: 'error', error: { type: 'api_error', message: 'down' } }) });
  reserveTask(ctx, 'task-down', 'sesn_01DOWN');
  let err;
  await assert.rejects(ma.sessionWait(ctx, { sessionId: 'sesn_01DOWN', taskId: 'task-down' }), (e) => { err = e; return e.cls === 'SERVICE'; });
  assert.equal(summary(ctx).openSessions, 1);
  assert.equal(ma.errorPayload(err, ctx).body.fallback.to, 'none');
});

test('T07 待機時間・ポーリング間隔は範囲内に収める (不正値・極端な値で無限待機や連打にならない)', async () => {
  const run = async (config, args) => {
    const { ctx, calls } = makeCtx({
      config,
      handler: (call) => {
        if (call.method === 'POST') return jsonResponse(200, {});
        if (/\/events\?/.test(call.url)) return jsonResponse(200, { data: [] });
        return jsonResponse(200, sessionObj('sesn_01W', 'task-w'));
      },
    });
    reserveTask(ctx, 'task-w', 'sesn_01W');
    await assert.rejects(ma.sessionWait(ctx, Object.assign({ sessionId: 'sesn_01W', taskId: 'task-w' }, args)), (e) => e.code === 'SESSION_WAIT_TIMEOUT');
    return calls.filter((c) => /\/events\?/.test(c.url)).length;
  };
  // 設定値が数値でない → 既定 900 秒 / 5 秒間隔 = 181 回で打ち切り (無限ループしない)
  assert.equal(await run(baseConfig({ sessionLifecycle: { maxWaitSeconds: '15m' } }), {}), 181);
  // 1ms 間隔の指定は下限 1 秒に、極端に長い待機は上限 3600 秒に収める
  assert.equal(await run(baseConfig(), { maxWaitSeconds: 10, pollMs: 1 }), 11);
  assert.equal(await run(baseConfig(), { maxWaitSeconds: 1e9, pollMs: 60000 }), 61);
});

// ---------- 完了判定・使用量記録 ----------

test('完了 (end_turn): 結果テキストを信頼できないデータとして返し、累積 list_cost を確定記録する', async () => {
  const { ctx } = makeCtx({
    handler: (call) => {
      if (/\/events\?/.test(call.url)) {
        return jsonResponse(200, { data: [
          { id: 'e1', type: 'session.status_running', processed_at: '2026-10-10T12:00:01Z' },
          { id: 'e2', type: 'agent.message', processed_at: '2026-10-10T12:00:03Z', content: [{ type: 'text', text: 'レビュー結果: 問題なし' }] },
          idleEvent('end_turn'),
        ] });
      }
      return jsonResponse(200, sessionObj('sesn_01OK', 'task-ok', { usage: { input_tokens: 1200, output_tokens: 300, list_cost: { amount: '12', currency: 'USD' } } }));
    },
  });
  reserveTask(ctx, 'task-ok', 'sesn_01OK');
  const out = await ma.sessionWait(ctx, { sessionId: 'sesn_01OK', taskId: 'task-ok' });
  assert.equal(out.outcome, 'completed');
  assert.equal(out.text, 'レビュー結果: 問題なし');
  assert.equal(out.text_is_untrusted_agent_output, true);
  assert.equal(out.list_cost_cents, 12);
  const t = budget.foldTasks(budget.readLedger(ctx.ledgerPath).entries).get('task-ok');
  assert.equal(t.final, true);
  assert.equal(t.actualCents, 12);
});

test('予算到達 (budget_reached): 予算を引き上げ・削除せず、再開もしない', async () => {
  const { ctx, calls } = makeCtx({
    handler: (call) => {
      if (/\/events\?/.test(call.url)) return jsonResponse(200, { data: [idleEvent('budget_reached')] });
      return jsonResponse(200, sessionObj('sesn_01CAP', 'task-cap', { usage: { list_cost: { amount: '53', currency: 'USD' } } }));
    },
  });
  reserveTask(ctx, 'task-cap', 'sesn_01CAP', 50);
  let err;
  await assert.rejects(ma.sessionWait(ctx, { sessionId: 'sesn_01CAP', taskId: 'task-cap' }), (e) => { err = e; return e.cls === 'SESSION_BUDGET' && e.extra.result.list_cost_cents === 53; });
  assert.equal(calls.filter((c) => c.method !== 'GET').length, 0, 'budget 変更や追加メッセージの POST を送らない');
  assert.equal(ma.errorPayload(err, ctx).body.fallback.to, 'none');
});

test('承認要求 (requires_action): 自動承認せず中断する', async () => {
  const { ctx, calls } = makeCtx({
    handler: (call) => {
      if (call.method === 'POST') return jsonResponse(200, {});
      if (/\/events\?/.test(call.url)) return jsonResponse(200, { data: [idleEvent('requires_action')] });
      return jsonResponse(200, sessionObj('sesn_01ASK', 'task-ask', { usage: { list_cost: { amount: '3', currency: 'USD' } } }));
    },
  });
  reserveTask(ctx, 'task-ask', 'sesn_01ASK');
  await assert.rejects(ma.sessionWait(ctx, { sessionId: 'sesn_01ASK', taskId: 'task-ask' }), (e) => e.code === 'SESSION_NOT_COMPLETED');
  const posts = calls.filter((c) => c.method === 'POST');
  assert.equal(posts.length, 1);
  assert.equal(posts[0].body.events[0].type, 'user.interrupt');
  assert.ok(!posts.some((c) => JSON.stringify(c.body).includes('tool_confirmation')));
});

test('使用量が欠落・小数・指数表記のときは 0¢ で確定せず、予約額のまま計上する', async () => {
  for (const usage of [undefined, { list_cost: { amount: '150.5', currency: 'USD' } }, { list_cost: { amount: '1e2', currency: 'USD' } }, { list_cost: { amount: 12, currency: 'USD' } }]) {
    const { ctx } = makeCtx({
      handler: (call) => {
        if (/\/events\?/.test(call.url)) return jsonResponse(200, { data: [idleEvent('end_turn')] });
        return jsonResponse(200, sessionObj('sesn_01BAD', 'task-bad', { usage }));
      },
    });
    reserveTask(ctx, 'task-bad', 'sesn_01BAD');
    const out = await ma.sessionWait(ctx, { sessionId: 'sesn_01BAD', taskId: 'task-bad' });
    assert.equal(out.usage_finalized, false, JSON.stringify(usage));
    assert.equal(out.list_cost_cents, null);
    assert.equal(summary(ctx).committedMonthCents, 200);
    assert.equal(summary(ctx).openSessions, 1);
    await assert.rejects(ma.sessionClose(ctx, { taskId: 'task-bad' }), (e) => e.code === 'USAGE_UNREADABLE');
  }
});

test('task と session の対応: 別のセッションの使用量でタスクを確定できない (wait / close)', async () => {
  const { ctx } = makeCtx({
    handler: (call) => {
      if (/\/events\?/.test(call.url)) return jsonResponse(200, { data: [idleEvent('end_turn')] });
      if (/sesn_01OTHER$/.test(call.url)) return jsonResponse(200, sessionObj('sesn_01OTHER', 'another-task', { usage: { list_cost: { amount: '1', currency: 'USD' } } }));
      if (/sesn_01FORGED$/.test(call.url)) return jsonResponse(200, sessionObj('sesn_01FORGED', 'task-real', { usage: { list_cost: { amount: '1', currency: 'USD' } } }));
      return undefined;
    },
  });
  reserveTask(ctx, 'task-real', 'sesn_01REAL');
  // 台帳に記録済みのセッションと違う ID
  await assert.rejects(ma.sessionClose(ctx, { taskId: 'task-real', sessionId: 'sesn_01OTHER' }), (e) => e.code === 'TASK_SESSION_MISMATCH');
  await assert.rejects(ma.sessionWait(ctx, { taskId: 'task-real', sessionId: 'sesn_01OTHER' }), (e) => e.code === 'TASK_SESSION_MISMATCH');
  // metadata が一致していても、台帳のセッション ID と違えば拒否
  await assert.rejects(ma.sessionClose(ctx, { taskId: 'task-real', sessionId: 'sesn_01FORGED' }), (e) => e.code === 'TASK_SESSION_MISMATCH');
  // 予約の無い task_id
  await assert.rejects(ma.sessionClose(ctx, { taskId: 'no-such-task', sessionId: 'sesn_01OTHER' }), (e) => e.code === 'TASK_UNKNOWN');
  assert.equal(summary(ctx).committedMonthCents, 200, '予約は 1¢ に置き換わらない');
  assert.equal(summary(ctx).openSessions, 1);
});

test('task と session の対応: 台帳にセッション ID が無い予約は metadata の一致を要求する', async () => {
  const { ctx } = makeCtx({ handler: (call) => (/sesn_01OTHER$/.test(call.url) ? jsonResponse(200, sessionObj('sesn_01OTHER', 'another-task')) : undefined) });
  reserveTask(ctx, 'task-nosid', null);
  await assert.rejects(ma.sessionClose(ctx, { taskId: 'task-nosid', sessionId: 'sesn_01OTHER' }), (e) => e.code === 'TASK_SESSION_MISMATCH');
  assert.equal(summary(ctx).openSessions, 1);
});

test('session close: 成否不明の予約はセッション一覧から突き合わせて確定する', async () => {
  const found = makeCtx({
    handler: (call) => {
      if (/\/v1\/sessions\?/.test(call.url)) return jsonResponse(200, { data: [sessionObj('sesn_01A', 'other'), sessionObj('sesn_01FOUND', 'task-unknown')], next_page: null });
      if (/sesn_01FOUND$/.test(call.url)) return jsonResponse(200, sessionObj('sesn_01FOUND', 'task-unknown', { usage: { list_cost: { amount: '9', currency: 'USD' } } }));
      return undefined;
    },
  });
  reserveTask(found.ctx, 'task-unknown', null);
  const out = await ma.sessionClose(found.ctx, { taskId: 'task-unknown' });
  assert.deepEqual([out.session_id, out.finalized, out.list_cost_cents], ['sesn_01FOUND', true, 9]);
  assert.equal(summary(found.ctx).openSessions, 0);
});

test('session close: セッションが見つからない場合、人間の明示確認が無ければ予約を解除しない', async () => {
  const { ctx, advance } = makeCtx({ handler: (call) => (/\/v1\/sessions\?/.test(call.url) ? jsonResponse(200, { data: [], next_page: null }) : undefined) });
  reserveTask(ctx, 'task-lost', null);
  // 予約直後は、明示確認があっても解除しない (作成リクエストの応答待ちと行き違わないため)
  await assert.rejects(ma.sessionClose(ctx, { taskId: 'task-lost', confirmNotCreated: true }), (e) => e.code === 'RESERVATION_TOO_RECENT');
  assert.equal(summary(ctx).openSessions, 1);
  advance(3 * 60 * 1000);
  await assert.rejects(ma.sessionClose(ctx, { taskId: 'task-lost' }), (e) => e.code === 'TASK_SESSION_NOT_FOUND');
  assert.equal(summary(ctx).openSessions, 1);
  const out = await ma.sessionClose(ctx, { taskId: 'task-lost', confirmNotCreated: true });
  assert.equal(out.released, true);
  assert.equal(summary(ctx).openSessions, 0);
});

test('session close: セッション一覧を最後まで読めない場合は「未作成」と断定せず、解除しない', async () => {
  const { ctx, advance } = makeCtx({ handler: (call) => (/\/v1\/sessions\?/.test(call.url) ? jsonResponse(200, { data: [sessionObj('sesn_01Z', 'other')], next_page: 'more' }) : undefined) });
  reserveTask(ctx, 'task-many', null);
  advance(3 * 60 * 1000);
  await assert.rejects(ma.sessionClose(ctx, { taskId: 'task-many', confirmNotCreated: true }), (e) => e.code === 'SESSION_LIST_TRUNCATED');
  assert.equal(summary(ctx).openSessions, 1);
});

test('解除と作成成功が行き違っても費用と並列枠が消えない (解除後に届いた使用量が予約を復活させる)', async () => {
  const { ctx, sessionPosts } = makeCtx({
    handler: (c) => {
      if (!isSessionCreate(c)) return undefined;
      // 作成応答の直前に、別の操作が予約を解除した状態を作る
      budget.release(ctx.ledgerPath, ctx.now(), 'task-001', 'confirmed-not-created-by-operator');
      return jsonResponse(200, { id: 'sesn_01RACE', status: 'running' });
    },
  });
  await ma.sessionCreate(ctx, sessionArgs());
  assert.equal(sessionPosts().length, 1);
  assert.deepEqual([summary(ctx).openSessions, summary(ctx).committedMonthCents], [1, 200]);
  await assert.rejects(ma.sessionCreate(ctx, sessionArgs({ taskId: 'task-002' })), (e) => e.code === 'CONCURRENCY_LIMIT');
});

test('session close: 停止を示すイベントが無い idle (未開始かもしれない) は確定しない', async () => {
  const { ctx } = makeCtx({
    handler: (call) => {
      if (/\/events\?/.test(call.url)) return jsonResponse(200, { data: [], next_page: null });
      if (/sesn_01FRESH$/.test(call.url)) return jsonResponse(200, sessionObj('sesn_01FRESH', 'task-fresh', { usage: { list_cost: { amount: '0', currency: 'USD' } } }));
      return undefined;
    },
  });
  reserveTask(ctx, 'task-fresh', 'sesn_01FRESH');
  await assert.rejects(ma.sessionClose(ctx, { taskId: 'task-fresh' }), (e) => e.code === 'SESSION_NOT_SETTLED');
  assert.deepEqual([summary(ctx).openSessions, summary(ctx).committedMonthCents], [1, 200]);
});

test('既存セッションに対する操作の失敗は、原因に関わらず Local へ自動で戻さない', async () => {
  const fallbackOf = async (promise, ctx) => {
    let err;
    await assert.rejects(promise, (e) => { err = e; return true; });
    return ma.errorPayload(err, ctx).body.fallback.to;
  };
  // 完了イベントの後、最終取得が接続断
  const net = makeCtx({ handler: (call, calls) => (/sesn_01NET$/.test(call.url) && calls.filter((c) => /sesn_01NET$/.test(c.url)).length > 1 ? Promise.reject(new TypeError('fetch failed')) : (/sesn_01NET$/.test(call.url) ? jsonResponse(200, sessionObj('sesn_01NET', 'task-net')) : undefined)) });
  reserveTask(net.ctx, 'task-net', 'sesn_01NET');
  assert.equal(await fallbackOf(ma.sessionWait(net.ctx, { sessionId: 'sesn_01NET', taskId: 'task-net' }), net.ctx), 'none');
  // イベント応答の形が想定外 (data がオブジェクト / null 要素)
  for (const data of [{}, 5]) {
    const bad = makeCtx({ handler: (call) => (/\/events\?/.test(call.url) ? jsonResponse(200, { data }) : (/sesn_01BADEV$/.test(call.url) ? jsonResponse(200, sessionObj('sesn_01BADEV', 'task-badev')) : undefined)) });
    reserveTask(bad.ctx, 'task-badev', 'sesn_01BADEV');
    assert.equal(await fallbackOf(ma.sessionWait(bad.ctx, { sessionId: 'sesn_01BADEV', taskId: 'task-badev' }), bad.ctx), 'none');
    assert.equal(summary(bad.ctx).openSessions, 1);
  }
  // 最終取得が空本文
  const empty = makeCtx({ handler: (call, calls) => (/sesn_01EMPTY$/.test(call.url) ? (calls.filter((c) => /sesn_01EMPTY$/.test(c.url)).length > 1 ? jsonResponse(200, undefined) : jsonResponse(200, sessionObj('sesn_01EMPTY', 'task-empty'))) : undefined) });
  reserveTask(empty.ctx, 'task-empty', 'sesn_01EMPTY');
  assert.equal(await fallbackOf(ma.sessionWait(empty.ctx, { sessionId: 'sesn_01EMPTY', taskId: 'task-empty' }), empty.ctx), 'none');
  // API キー未設定・task_id なしの wait、API 障害の close / interrupt
  const nokey = makeCtx({ env: { ANTHROPIC_API_KEY: null } });
  assert.equal(await fallbackOf(ma.sessionWait(nokey.ctx, { sessionId: 'sesn_01X', taskId: 't' }), nokey.ctx), 'none');
  const down = makeCtx({ handler: () => jsonResponse(503, { type: 'error', error: { type: 'api_error', message: 'down' } }) });
  reserveTask(down.ctx, 'task-d', 'sesn_01D');
  assert.equal(await fallbackOf(ma.sessionWait(down.ctx, { sessionId: 'sesn_01D' }), down.ctx), 'none');
  assert.equal(await fallbackOf(ma.sessionClose(down.ctx, { taskId: 'task-d' }), down.ctx), 'none');
  assert.equal(await fallbackOf(ma.dispatch(down.ctx, ['session', 'interrupt'], { 'session-id': 'sesn_01D' }), down.ctx), 'none');
  assert.equal(await fallbackOf(ma.dispatch(down.ctx, ['session', 'get'], { 'session-id': 'sesn_01D' }), down.ctx), 'none');
});

test('session wait: 無関係なセッションへ中断を送らない (監視の前に task との対応を確認する)', async () => {
  const { ctx, calls } = makeCtx({ handler: (call) => (/sesn_01VICTIM$/.test(call.url) ? jsonResponse(200, sessionObj('sesn_01VICTIM', 'someone-else', { status: 'running' })) : undefined) });
  reserveTask(ctx, 'task-mine', null);
  await assert.rejects(ma.sessionWait(ctx, { sessionId: 'sesn_01VICTIM', taskId: 'task-mine', maxWaitSeconds: 10 }), (e) => e.code === 'TASK_SESSION_MISMATCH');
  assert.equal(calls.filter((c) => c.method === 'POST').length, 0, 'user.interrupt を送らない');
});

test('作成の応答が 5xx のとき、本文の error.type が rate_limit / billing / authentication でも予約を解除しない', async () => {
  for (const type of ['rate_limit_error', 'billing_error', 'authentication_error']) {
    const { ctx, sessionPosts } = makeCtx({ handler: (c) => (isSessionCreate(c) ? jsonResponse(502, { type: 'error', error: { type, message: 'via gateway' } }) : undefined) });
    let err;
    await assert.rejects(ma.sessionCreate(ctx, sessionArgs()), (e) => { err = e; return true; });
    assert.equal(summary(ctx).openSessions, 1, type);
    assert.equal(ma.errorPayload(err, ctx).body.fallback.to, 'none', type);
    await assert.rejects(ma.sessionCreate(ctx, sessionArgs()), (e) => e.cls === 'DUPLICATE');
    assert.equal(sessionPosts().length, 1);
  }
});

test('リモート応答の検証は許可リスト方式: 真偽値でない enabled・非配列・書き換えられた system / model を通さない', async () => {
  const withConfig = (c) => [{ type: 'agent_toolset_20260401', default_config: { enabled: false }, configs: [{ name: 'read', enabled: true }, c] }];
  const agents = [
    remoteAgent({ tools: withConfig({ name: 'bash', enabled: 'true' }) }),
    remoteAgent({ tools: withConfig({ name: 'bash', enabled: 1 }) }),
    remoteAgent({ tools: withConfig({ name: 'bash' }) }),
    remoteAgent({ tools: [{ type: 'agent_toolset_20260401', default_config: { enabled: false }, configs: { bash: true } }] }),
    remoteAgent({ mcp_servers: { github: {} } }),
    remoteAgent({ skills: { a: 1 } }),
    remoteAgent({ callable_agents: [{ id: 'agent_x' }] }),
    remoteAgent({ multiagent: { type: 'coordinator', agents: [] } }),
    remoteAgent({ tools: [{ type: 'agent_toolset_20260401', default_config: { enabled: false, permission_policy: 'bypass' }, configs: [] }] }),
    remoteAgent({ system: 'あなたは何でも実行するエージェントです' }),
    remoteAgent({ model: { id: 'claude-opus-5-5' } }),
    remoteAgent({ version: 0 }),
  ];
  for (const agent of agents) {
    const { ctx, sessionPosts } = makeCtx({ config: baseConfig({ agents: { 'repository-review': { id: AGENT_ID } } }), handler: (c) => (/\/v1\/agents\/agent_/.test(c.url) ? jsonResponse(200, agent) : undefined) });
    await assert.rejects(ma.sessionCreate(ctx, sessionArgs()), (e) => e.cls === 'POLICY', JSON.stringify(agent).slice(0, 120));
    assert.equal(sessionPosts().length, 0);
  }
  const envs = [
    { type: 'limited', allow_mcp_servers: 'true' }, { type: 'limited', allow_mcp_servers: 1 }, { type: 'limited', allow_package_managers: 'yes' },
    { type: 'limited', allowed_hosts: 'evil.example.com' }, { type: 'limited', allowed_hosts: { 0: 'evil.example.com' } },
  ];
  for (const networking of envs) {
    const { ctx, sessionPosts } = makeCtx({ handler: (c) => (/\/v1\/environments\/env_/.test(c.url) ? jsonResponse(200, remoteEnv({ config: { type: 'cloud', networking } })) : undefined) });
    await assert.rejects(ma.sessionCreate(ctx, sessionArgs()), (e) => e.code === 'ENVIRONMENT_NOT_LIMITED', JSON.stringify(networking));
    assert.equal(sessionPosts().length, 0);
  }
});

test('session close: 動作中のセッションは確定できない', async () => {
  const { ctx } = makeCtx({ handler: (call) => (/sesn_01RUNNING$/.test(call.url) ? jsonResponse(200, sessionObj('sesn_01RUNNING', 'task-run', { status: 'running' })) : undefined) });
  reserveTask(ctx, 'task-run', 'sesn_01RUNNING');
  await assert.rejects(ma.sessionClose(ctx, { taskId: 'task-run' }), (e) => e.code === 'SESSION_STILL_RUNNING');
  assert.equal(summary(ctx).openSessions, 1);
});

test('latestStatusEvent / outcomeOf: 時刻は数値で比較し、最新の status を根拠にする', () => {
  const events = [idleEvent('end_turn'), { id: 'e9', type: 'session.status_running', processed_at: '2026-10-10T12:00:09Z' }];
  assert.equal(ma.outcomeOf(ma.latestStatusEvent(events)), null, '後から running に戻っている');
  // 小数秒の桁数が混在しても順序を取り違えない
  const mixed = [{ id: 'r', type: 'session.status_running', processed_at: '2026-10-10T12:00:05Z' }, { id: 'i', type: 'session.status_idle', processed_at: '2026-10-10T12:00:05.900Z', stop_reason: { type: 'end_turn' } }];
  assert.equal(ma.outcomeOf(ma.latestStatusEvent(mixed)), 'completed');
  assert.equal(ma.outcomeOf({ type: 'session.status_terminated' }), 'terminated');
  assert.equal(ma.outcomeOf(idleEvent('retries_exhausted')), 'failed');
  assert.equal(ma.outcomeOf(null), null);
});

// ---------- エラー分類 ----------

test('classifyHttp: 認証・権限・課金・レート制限・障害を区別する', () => {
  const body = (type, message) => ({ type: 'error', error: { type, message: message || '' } });
  assert.equal(ma.classifyHttp(401, body('authentication_error')), 'AUTH');
  assert.equal(ma.classifyHttp(403, body('permission_error')), 'PERMISSION');
  assert.equal(ma.classifyHttp(402, body('billing_error')), 'BILLING');
  assert.equal(ma.classifyHttp(400, body('invalid_request_error', 'Your credit balance is too low')), 'BILLING');
  assert.equal(ma.classifyHttp(400, body('invalid_request_error', 'budget.max_list_cost must be greater than')), 'INVALID_REQUEST');
  assert.equal(ma.classifyHttp(429, body('rate_limit_error')), 'RATE_LIMIT');
  assert.equal(ma.classifyHttp(500, body('api_error')), 'SERVICE');
  assert.equal(ma.classifyHttp(529, body('overloaded_error')), 'SERVICE');
  assert.equal(ma.classifyHttp(504, null), 'SERVICE');
  assert.equal(ma.classifyHttp(404, body('not_found_error')), 'NOT_FOUND');
  // 409 の error.type は資料により表記が異なるため HTTP ステータスで判定する
  assert.equal(ma.classifyHttp(409, body('invalid_request_error')), 'CONFLICT');
  assert.equal(ma.classifyHttp(409, body('conflict_error')), 'CONFLICT');
});

// ---------- T08 / T09 GitHub 読取専用・main への push 不可 ----------

test('T08 roster の全 Agent は read / glob / grep のみで、MCP・書込み・実行・Web ツールを持たない', () => {
  const roster = ma.loadRoster({});
  assert.deepEqual(Object.keys(roster.agents).sort(), ['documentation', 'quality-assurance', 'repository-review']);
  for (const role of Object.keys(roster.agents)) {
    const { body } = ma.agentDefinition(roster, role);
    assert.equal(body.tools.length, 1);
    assert.equal(body.tools[0].type, 'agent_toolset_20260401');
    assert.equal(body.tools[0].default_config.enabled, false);
    assert.deepEqual(body.tools[0].configs.filter((c) => c.enabled).map((c) => c.name).sort(), ['glob', 'grep', 'read']);
    assert.ok(!('mcp_servers' in body));
    assert.equal(body.metadata.claudeos_role, role);
  }
  for (const role of ['constructor', '__proto__', 'toString', 'nope']) {
    assert.throws(() => ma.agentDefinition(roster, role), (e) => e.code === 'ROLE_UNKNOWN', role);
  }
});

test('T08 GitHub リポジトリは github_repository リソースとしてマウントし、トークンは環境変数からのみ渡す', async () => {
  const { ctx, sessionPosts } = makeCtx({ handler: (c) => (isSessionCreate(c) ? jsonResponse(200, { id: 'sesn_01GH', status: 'running' }) : undefined) });
  await ma.sessionCreate(ctx, sessionArgs());
  const res = sessionPosts()[0].body.resources;
  assert.equal(res.length, 1);
  assert.equal(res[0].type, 'github_repository');
  assert.equal(res[0].url, 'https://github.com/Kensan196948G/Claude-StartUpTools-New-Linux');
  assert.deepEqual(res[0].checkout, { type: 'branch', name: 'main' });
  assert.equal(res[0].authorization_token, FAKE_GH);
});

test('T08 GitHub トークン未設定・API キーの取り違えではセッションを作らない', async () => {
  const none = makeCtx({ env: { CLAUDEOS_MA_GITHUB_TOKEN: null } });
  await assert.rejects(ma.sessionCreate(none.ctx, sessionArgs()), (e) => e.code === 'GITHUB_TOKEN_MISSING');
  const swapped = makeCtx({ env: { CLAUDEOS_MA_GITHUB_TOKEN: FAKE_KEY } });
  await assert.rejects(ma.sessionCreate(swapped.ctx, sessionArgs()), (e) => e.code === 'GITHUB_TOKEN_IS_API_KEY');
  for (const t of [none, swapped]) {
    assert.equal(t.sessionPosts().length, 0);
    assert.equal(budget.readLedger(t.ctx.ledgerPath).entries.length, 0);
  }
});

test('T08 SSH 形式・.git 付き・github.com 以外の URL は拒否する', async () => {
  for (const repo of ['git@github.com:o/r.git', 'https://github.com/o/r.git', 'https://gitlab.com/o/r', 'https://github.com/o']) {
    const { ctx, sessionPosts } = makeCtx();
    await assert.rejects(ma.sessionCreate(ctx, sessionArgs({ repo })), (e) => e.code === 'REPO_URL_INVALID', repo);
    assert.equal(sessionPosts().length, 0);
  }
});

test('T09 bash / write / edit / web / MCP を持つ Agent 定義は同期前に拒否される (main へ push する手段が無い)', () => {
  const toolset = (configs) => [{ type: 'agent_toolset_20260401', default_config: { enabled: false, permission_policy: { type: 'always_allow' } }, configs }];
  for (const name of ['bash', 'write', 'edit', 'web_fetch', 'web_search']) {
    assert.throws(() => ma.assertReadOnlyAgent({ tools: toolset([{ name, enabled: true }]) }), (e) => e.cls === 'POLICY' && e.code === 'READ_ONLY_VIOLATION', name);
  }
  assert.throws(() => ma.assertReadOnlyAgent({ tools: [{ type: 'agent_toolset_20260401' }] }), (e) => e.code === 'READ_ONLY_VIOLATION', '既定で全ツール有効');
  assert.throws(() => ma.assertReadOnlyAgent({ tools: toolset([{ name: 'read', enabled: true }]), mcp_servers: [{ type: 'url', name: 'github', url: 'https://api.githubcopilot.com/mcp' }] }), (e) => e.code === 'READ_ONLY_VIOLATION');
  assert.throws(() => ma.assertReadOnlyAgent({ tools: [...toolset([{ name: 'read', enabled: true }]), { type: 'mcp_toolset', mcp_server_name: 'github' }] }), (e) => e.code === 'READ_ONLY_VIOLATION');
  assert.equal(ma.assertReadOnlyAgent({ tools: toolset([{ name: 'read', enabled: true }, { name: 'grep', enabled: true }]) }), true);
});

test('T09 セッション作成前にリモートの Agent 実体を検証する: 書込み可・MCP 付き・version 不一致・archive 済みでは作らない', async () => {
  const tampered = [
    remoteAgent({ tools: [{ type: 'agent_toolset_20260401', default_config: { enabled: true }, configs: [] }] }),
    remoteAgent({ tools: [...READ_ONLY_TOOLS().map((t) => Object.assign(t, { configs: t.configs.concat([{ name: 'bash', enabled: true }]) }))] }),
    remoteAgent({ mcp_servers: [{ type: 'url', name: 'github', url: 'https://api.githubcopilot.com/mcp' }] }),
    remoteAgent({ version: 9 }),
    remoteAgent({ archived_at: '2026-10-01T00:00:00Z' }),
    {},
  ];
  for (const agent of tampered) {
    const { ctx, sessionPosts } = makeCtx({ handler: (c) => (/\/v1\/agents\/agent_/.test(c.url) ? jsonResponse(200, agent) : undefined) });
    await assert.rejects(ma.sessionCreate(ctx, sessionArgs()), (e) => e.cls === 'POLICY', JSON.stringify(agent).slice(0, 80));
    assert.equal(sessionPosts().length, 0);
    assert.equal(budget.readLedger(ctx.ledgerPath).entries.length, 0, '予約もしない');
  }
});

test('T09 セッション作成前にリモートの Environment を検証する: unrestricted・MCP 許可・許可ホストありでは作らない', async () => {
  const bad = [
    remoteEnv({ config: { type: 'cloud', networking: { type: 'unrestricted' } } }),
    remoteEnv({ config: { type: 'cloud' } }),
    remoteEnv({ config: { type: 'cloud', networking: { type: 'limited', allow_mcp_servers: true } } }),
    remoteEnv({ config: { type: 'cloud', networking: { type: 'limited', allow_package_managers: true } } }),
    remoteEnv({ config: { type: 'cloud', networking: { type: 'limited', allowed_hosts: ['evil.example.com'] } } }),
    remoteEnv({ archived_at: '2026-10-01T00:00:00Z' }),
  ];
  for (const environment of bad) {
    const { ctx, sessionPosts } = makeCtx({ handler: (c) => (/\/v1\/environments\/env_/.test(c.url) ? jsonResponse(200, environment) : undefined) });
    await assert.rejects(ma.sessionCreate(ctx, sessionArgs()), (e) => e.cls === 'POLICY' && e.code === 'ENVIRONMENT_NOT_LIMITED');
    assert.equal(sessionPosts().length, 0);
  }
});

test('T09 env ensure: 既存の Environment が limited でなければ採用しない。roster は limited を明示する', async () => {
  const roster = ma.loadRoster({});
  assert.deepEqual(roster.environment.config.networking, { type: 'limited', allow_package_managers: false, allow_mcp_servers: false });
  const dry = makeCtx({ config: baseConfig({ mode: 'dry-run' }) });
  assert.equal((await ma.envEnsure(dry.ctx)).plan.body.config.networking.type, 'limited');
  const live = makeCtx({ handler: (c) => (/\/v1\/environments\/env_/.test(c.url) ? jsonResponse(200, remoteEnv({ config: { type: 'cloud', networking: { type: 'unrestricted' } } })) : undefined) });
  await assert.rejects(ma.envEnsure(live.ctx), (e) => e.code === 'ENVIRONMENT_NOT_LIMITED');
  assert.equal(fs.existsSync(live.ctx.registryPath), false, 'registry に登録しない');
});

test('T09 対象外のタスク種別は Router を通さずに session create を呼んでも作れない', async () => {
  for (const taskType of ['deploy', 'feature', 'migration', 'docs', '', 'REVIEW ; rm']) {
    const { ctx, calls } = makeCtx();
    await assert.rejects(ma.sessionCreate(ctx, sessionArgs({ taskType })), (e) => e.cls === 'POLICY', taskType);
    assert.equal(calls.length, 0);
  }
});

test('ID の形式検証: パスへ埋め込む ID に区切り文字やクエリを混ぜられない', async () => {
  const { ctx, calls } = makeCtx();
  for (const sessionId of ['', '../agents', 'x/../../agents/agent_abc/archive?', 'sesn_ok/../x', 'sesn_ab?x=1']) {
    await assert.rejects(ma.dispatch(ctx, ['session', 'get'], { 'session-id': sessionId }), (e) => e.code === 'ID_INVALID', sessionId);
    await assert.rejects(ma.dispatch(ctx, ['session', 'events'], { 'session-id': sessionId }), (e) => e.code === 'ID_INVALID');
    await assert.rejects(ma.dispatch(ctx, ['session', 'interrupt'], { 'session-id': sessionId }), (e) => e.code === 'ID_INVALID');
  }
  const badEnv = makeCtx({ config: baseConfig({ environmentId: 'env_x/../../agents' }) });
  await assert.rejects(ma.sessionCreate(badEnv.ctx, sessionArgs()), (e) => e.code === 'ID_INVALID');
  assert.equal(calls.length + badEnv.calls.length, 0);
});

// ---------- T10 本番環境への無承認アクセス拒否 / Agent Router 統合 ----------

const safeManaged = (over) => Object.assign({ requested: true, data_sensitivity: 'internal', human_gate: false, requires_secrets: false, requires_external_network: false }, over);
const lowRiskTask = (over) => Object.assign({ task_type: 'review', complexity: 'medium', risk: 'low', read_only: true, files_affected: 10, managed: safeManaged() }, over);

test('Router 統合: 明示要求があり、安全条件を明示した低リスク・読取専用タスクだけ ManagedAgent になる', () => {
  const { ctx } = makeCtx();
  const d = ma.route(ctx, lowRiskTask(), { taskId: 'r-1' });
  assert.equal(d.execution, 'ManagedAgent');
  assert.equal(d.managed.selected, true);
  assert.equal(d.managed.fallback_execution, 'Subagent');
});

test('Router 統合: Local が稼働中で明示要求が無ければ Managed を並列起動しない', () => {
  const { ctx } = makeCtx();
  for (const m of [safeManaged({ requested: false }), safeManaged({ requested: undefined }), safeManaged({ requested: undefined, local_available: null }), safeManaged({ requested: 'yes' })]) {
    const d = ma.route(ctx, lowRiskTask({ managed: m }));
    assert.equal(d.execution, 'Subagent', JSON.stringify(m));
    assert.equal(d.managed.selected, false);
  }
});

test('Router 統合: Local が使えない (明示的な false) 場合は許可済みタスクを Managed へ', () => {
  const { ctx } = makeCtx();
  assert.equal(ma.route(ctx, lowRiskTask({ managed: safeManaged({ requested: false, local_available: false }) })).execution, 'ManagedAgent');
});

test('T10 本番・DB・デプロイ・Secret・書込み・高リスクのタスクは Managed へ出さない (policy 拒否)', () => {
  const cases = [
    { deployment_impact: 'high' }, { deployment_impact: 'medium' }, { database_impact: 'medium' }, { security_impact: 'high' },
    { risk: 'medium' }, { risk: undefined }, { read_only: false }, { read_only: undefined }, { task_type: 'deploy' }, { task_type: 'migration' },
    { managed: safeManaged({ requires_secrets: true }) }, { managed: safeManaged({ human_gate: true }) },
    { managed: safeManaged({ data_sensitivity: 'confidential' }) }, { managed: safeManaged({ requires_external_network: true }) },
  ];
  for (const c of cases) {
    const { ctx } = makeCtx();
    const d = ma.route(ctx, lowRiskTask(c));
    assert.notEqual(d.execution, 'ManagedAgent', JSON.stringify(c));
    assert.equal(d.managed.policy_denied, true, JSON.stringify(c));
  }
});

test('T10 安全条件は fail-closed: 不明な値・省略・呼び出し側による緩和では Managed を選ばない', () => {
  const cases = [
    // 真偽値でない値・省略は「未確認」として拒否
    { managed: safeManaged({ human_gate: 'yes' }) }, { managed: safeManaged({ human_gate: 'no' }) }, { managed: safeManaged({ human_gate: undefined }) },
    { managed: safeManaged({ requires_secrets: 'TRUE' }) }, { managed: safeManaged({ requires_secrets: undefined }) },
    { managed: safeManaged({ requires_external_network: 'yes' }) }, { managed: safeManaged({ requires_external_network: null }) },
    // 未知のレベル文字列は low ではなく critical 扱い
    { security_impact: 'High ' }, { security_impact: 'severe' }, { deployment_impact: 'prod' }, { database_impact: 'yes' }, { risk: 'extreme' },
    // 呼び出し側は許可リスト・時間上限を広げられない
    { task_type: 'deploy', managed: safeManaged({ allowed_task_types: ['deploy'] }) },
    { task_type: 'deploy-prod', managed: safeManaged({ allowed_task_types: ['deploy-prod'] }) },
    { expected_duration_min: 600, managed: safeManaged({ max_duration_min: 9999 }) },
    { expected_duration_min: 'forever' }, { expected_duration_min: -5 },
    { needs_inter_agent_communication: 'maybe' }, { read_only: 'yes' },
  ];
  for (const c of cases) {
    const { ctx } = makeCtx();
    const d = ma.route(ctx, lowRiskTask(c));
    assert.notEqual(d.execution, 'ManagedAgent', JSON.stringify(c));
    assert.equal(d.managed.selected, false, JSON.stringify(c));
    assert.equal(d.managed.policy_denied, true, JSON.stringify(c));
  }
  // 許可リストは狭めることだけできる
  const { ctx } = makeCtx();
  assert.equal(ma.route(ctx, lowRiskTask({ managed: safeManaged({ allowed_task_types: ['docs'] }) })).managed.policy_denied, true);
  assert.equal(ma.route(ctx, lowRiskTask({ managed: safeManaged({ allowed_task_types: ['review'] }) })).execution, 'ManagedAgent');
});

test('T10 Local が使えなくても、人間承認待ち・高リスクのタスクを Managed で代行しない', () => {
  const { ctx } = makeCtx();
  const d = ma.route(ctx, lowRiskTask({ deployment_impact: 'high', managed: safeManaged({ local_available: false, human_gate: true }) }));
  assert.notEqual(d.execution, 'ManagedAgent');
  assert.equal(d.managed.policy_denied, true);
  assert.ok(d.guardrails.some((g) => g.includes('フォールバックで承認・拒否を回避しない')));
});

test('Router 統合: 決定履歴 (実行先・理由・戻り先) を記録する', () => {
  const { ctx } = makeCtx();
  ma.route(ctx, lowRiskTask(), { taskId: 'hist-1' });
  ma.route(ctx, lowRiskTask({ risk: 'high' }), { taskId: 'hist-2' });
  const lines = fs.readFileSync(ctx.decisionsPath, 'utf8').trim().split('\n').map((l) => JSON.parse(l));
  assert.deepEqual(lines.map((l) => [l.task_id, l.execution, l.managed_selected]), [['hist-1', 'ManagedAgent', true], ['hist-2', 'Subagent', false]]);
  assert.ok(lines[1].denied.includes('risk'));
});

// ---------- T12 Local Claude Code への安全な切替 ----------

test('T12 Managed が未設定・無効でも Router は既存の Local 実行先を返す (経路を壊さない)', () => {
  for (const config of [null, baseConfig({ enabled: false }), baseConfig({ mode: 'disabled' }), baseConfig({ budgetPolicy: { cycle: { creditsExpireAt: 'bogus' } } })]) {
    const { ctx } = makeCtx({ config });
    const d = ma.route(ctx, lowRiskTask());
    assert.equal(d.execution, 'Subagent');
    assert.ok(d.managed.denied.includes('managed-unavailable'));
    assert.equal(d.managed.policy_denied, false);
  }
});

test('T12 API キー未設定 (live) は Managed を選ばず Local へ', () => {
  const { ctx } = makeCtx({ env: { ANTHROPIC_API_KEY: null } });
  const d = ma.route(ctx, lowRiskTask());
  assert.equal(d.execution, 'Subagent');
  assert.equal(d.managed.evidence.api_key_present, false);
});

test('T12 予算不足・重複タスク・クレジット失効は Managed を選ばず Local の決定を保持する', () => {
  const full = makeCtx();
  fs.mkdirSync(path.dirname(full.ctx.ledgerPath), { recursive: true });
  fs.writeFileSync(full.ctx.ledgerPath, [
    { type: 'reserve', ts: '2026-10-02T00:00:00.000Z', task_id: 'old', cents: 200 },
    { type: 'usage', ts: '2026-10-02T00:10:00.000Z', task_id: 'old', session_id: 's', list_cost_cents: 2000, final: true },
  ].map((e) => JSON.stringify(e)).join('\n') + '\n');
  const d = ma.route(full.ctx, lowRiskTask());
  assert.equal(d.execution, 'Subagent');
  assert.ok(d.managed.denied.includes('budget-budget_exhausted'));
  assert.equal(d.managed.policy_denied, false);

  const dupe = makeCtx();
  reserveTask(dupe.ctx, 'same', null, 100);
  const d2 = ma.route(dupe.ctx, lowRiskTask(), { taskId: 'same' });
  assert.notEqual(d2.execution, 'ManagedAgent');
  assert.ok(d2.managed.denied.includes('duplicate-task'));

  const expired = makeCtx({ config: baseConfig({ budgetPolicy: { cycle: { creditsExpireAt: '2026-10-09T00:00:00Z' } } }) });
  const d3 = ma.route(expired.ctx, lowRiskTask());
  assert.equal(d3.execution, 'Subagent');
  assert.ok(d3.managed.denied.includes('budget-credits_expired'));
});

test('T12 確認処理 (check) の Router 判定は既定額を接続テスト上限へ丸めて行う', () => {
  const { ctx } = makeCtx();
  const d = ma.route(ctx, lowRiskTask({ task_type: 'check' }));
  assert.equal(d.execution, 'ManagedAgent');
  assert.equal(d.managed.evidence.request_cents, 50);
});

test('T12 フォールバック可否: 予算不足・API 障害は Local へ、認証・権限・ポリシー拒否は BLOCKED', () => {
  for (const cls of ['CONFIG', 'KEY_MISSING', 'BUDGET', 'BILLING', 'RATE_LIMIT', 'SERVICE', 'NETWORK', 'TIMEOUT']) {
    assert.equal(ma.fallbackDecision(cls).to, 'local', cls);
  }
  for (const cls of ['AUTH', 'PERMISSION', 'POLICY']) {
    assert.deepEqual([ma.fallbackDecision(cls).to, ma.fallbackDecision(cls).state], ['none', 'BLOCKED'], cls);
  }
  assert.deepEqual(ma.fallbackDecision('SERVICE', { policyDenied: true }), { to: 'none', state: 'BLOCKED', reason: 'security-or-human-gate-denial-is-not-bypassed' });
});

test('T12 認証エラー (401) は再試行せず BLOCKED', async () => {
  const { ctx, sessionPosts } = makeCtx({ handler: (c) => (isSessionCreate(c) ? jsonResponse(401, { type: 'error', error: { type: 'authentication_error', message: 'invalid x-api-key' }, request_id: 'req_1' }) : undefined) });
  let err;
  await assert.rejects(ma.sessionCreate(ctx, sessionArgs()), (e) => { err = e; return e.cls === 'AUTH' && e.extra.request_id === 'req_1'; });
  assert.equal(sessionPosts().length, 1);
  const p = ma.errorPayload(err, ctx);
  assert.deepEqual([p.exit, p.body.state, p.body.fallback.to], [4, 'BLOCKED', 'none']);
});

test('T12 セッション作成後に台帳へ記録できない場合: session_id を返し、Local へ戻さない', async () => {
  const { ctx } = makeCtx({
    handler: (c) => {
      if (!isSessionCreate(c)) return undefined;
      // 作成応答の直前に、他プロセスがロックを保持した状態を作る
      fs.mkdirSync(`${ctx.ledgerPath}.lock`);
      return jsonResponse(200, { id: 'sesn_01LOCKED', status: 'running' });
    },
  });
  let err;
  await assert.rejects(ma.sessionCreate(ctx, sessionArgs()), (e) => { err = e; return e.code === 'LEDGER_RECORD_FAILED'; });
  assert.equal(err.extra.session_id, 'sesn_01LOCKED');
  assert.equal(ma.errorPayload(err, ctx).body.fallback.to, 'none');
  fs.rmdirSync(`${ctx.ledgerPath}.lock`);
  assert.equal(summary(ctx).openSessions, 1, '予約は残っている');
});

// ---------- T11 Secret・Credential の非表示 ----------

test('T11 redact: API キー・GitHub トークン・Bearer を伏せる', () => {
  const s = ma.redact(`key=${FAKE_KEY} gh=${FAKE_GH} classic=ghp_ABCDEFGHIJKLMNOPQRSTUVWX Authorization: Bearer abcdefghijklmnop`, []);
  for (const secret of [FAKE_KEY, FAKE_GH, 'ghp_ABCDEFGHIJKLMNOPQRSTUVWX', 'abcdefghijklmnop']) assert.ok(!s.includes(secret));
  assert.equal(ma.redact('token is hunter2-very-secret', ['hunter2-very-secret']), 'token is <redacted>');
});

test('T11 設定ファイルの秘密検出: キー名と値のパターンの両方で見る (環境変数名と ID は対象外)', () => {
  assert.deepEqual(ma.findSecretKeys({ apiKey: 'x', nested: { authorization_token: 'y' }, github: { workspace: { tokenEnv: 'NAME' } }, vaultIds: ['vlt_1'], _comment: 'token の説明' }, ''), ['apiKey', 'nested.authorization_token']);
  // 中立なキー名・配列・コメント用キー・*Env キーに書かれた実トークンも検出する
  assert.deepEqual(ma.findSecretKeys({ note: FAKE_KEY, list: ['ok', FAKE_GH], _memo: 'ghp_ABCDEFGHIJKLMNOPQRSTUVWX', tokenEnv: FAKE_GH }, ''), ['note', 'list.1', '_memo', 'tokenEnv']);
  const v = ma.validateConfig(baseConfig({ apiKey: FAKE_KEY }), {});
  assert.equal(v.ok, false);
  assert.ok(v.reasons.includes('secret-in-config:apiKey'));
  assert.ok(!JSON.stringify(v).includes(FAKE_KEY));
});

test('T11 dry-run の出力・台帳・決定履歴に API キーと GitHub トークンの値が現れない', async () => {
  const { ctx, calls } = makeCtx({ config: baseConfig({ mode: 'dry-run' }) });
  const plan = await ma.sessionCreate(ctx, sessionArgs());
  assert.equal(plan.executed, false);
  assert.equal(calls.length, 0);
  const text = JSON.stringify(plan);
  assert.ok(!text.includes(FAKE_KEY) && !text.includes(FAKE_GH));
  assert.equal(plan.request.headers['x-api-key'], '<env:ANTHROPIC_API_KEY>');
  assert.equal(plan.request.body.resources[0].authorization_token, '<env:CLAUDEOS_MA_GITHUB_TOKEN>');
  assert.deepEqual(plan.request.body.budget.max_list_cost, { amount: '200', currency: 'USD' });
  assert.equal(fs.existsSync(ctx.ledgerPath), false, 'dry-run は台帳へ書かない');
});

test('T11 live 実行後の台帳・決定履歴・status にも秘密の値が残らない', async () => {
  const { ctx, stateDir } = makeCtx({ handler: (c) => (isSessionCreate(c) ? jsonResponse(200, { id: 'sesn_01SEC', status: 'running' }) : undefined) });
  await ma.sessionCreate(ctx, sessionArgs());
  const st = await ma.status(ctx, {});
  assert.deepEqual([st.api_key_present, st.github_token_present], [true, true]);
  const all = JSON.stringify(st) + fs.readdirSync(stateDir).map((f) => fs.readFileSync(path.join(stateDir, f), 'utf8')).join('\n');
  assert.ok(!all.includes(FAKE_KEY) && !all.includes(FAKE_GH));
});

test('T11 API エラーメッセージに含まれた秘密も伏せる', async () => {
  const { ctx } = makeCtx({ handler: (c) => (isSessionCreate(c) ? jsonResponse(400, { type: 'error', error: { type: 'invalid_request_error', message: `bad token ${FAKE_GH}` } }) : undefined) });
  await assert.rejects(ma.sessionCreate(ctx, sessionArgs()), (e) => !e.message.includes(FAKE_GH) && e.message.includes('<redacted'));
});

// ---------- Agent 定義の同期・一覧・状態確認 ----------

test('agents sync (dry-run): API を呼ばずに作成計画だけ返す', async () => {
  const { ctx, calls } = makeCtx({ config: baseConfig({ mode: 'dry-run' }) });
  const out = await ma.agentsSync(ctx, null);
  assert.equal(out.executed, false);
  assert.equal(out.plan.length, 3);
  assert.equal(calls.length, 0);
});

test('agents sync (live): 未作成は作成、定義変更は version つき更新、実体が一致する場合だけ変更なし', async () => {
  const roster = ma.loadRoster({});
  const sha = (role) => ma.agentDefinition(roster, role).sha;
  const { ctx, calls } = makeCtx({
    handler: (call) => {
      if (call.method === 'GET') {
        return jsonResponse(200, { data: [
          remoteAgent({ id: 'agent_QA', version: 4, metadata: { claudeos_role: 'quality-assurance', claudeos_def_sha: sha('quality-assurance') } }),
          remoteAgent({ id: 'agent_DOC', version: 2, metadata: { claudeos_role: 'documentation', claudeos_def_sha: 'stale' } }),
          remoteAgent({ id: 'agent_OLD', version: 1, archived_at: '2026-09-01T00:00:00Z', metadata: { claudeos_role: 'repository-review' } }),
        ], next_page: null });
      }
      if (call.url.endsWith('/v1/agents')) return jsonResponse(200, { id: 'agent_NEW', version: 1 });
      return jsonResponse(200, { id: 'agent_DOC', version: 3 });
    },
  });
  const out = await ma.agentsSync(ctx, null);
  assert.deepEqual(out.results.map((r) => [r.role, r.action, r.agent_id, r.version]), [
    ['repository-review', 'created', 'agent_NEW', 1],
    ['quality-assurance', 'unchanged', 'agent_QA', 4],
    ['documentation', 'updated', 'agent_DOC', 3],
  ]);
  const update = calls.find((c) => c.method === 'POST' && c.url.endsWith('/v1/agents/agent_DOC'));
  assert.equal(update.body.version, 2, '楽観ロック用に現行 version を渡す');
  assert.equal(JSON.parse(fs.readFileSync(ctx.registryPath, 'utf8')).agents['quality-assurance'].id, 'agent_QA');
});

test('agents sync (live): metadata が一致していても実体が読取専用でなければ定義で上書きする', async () => {
  const roster = ma.loadRoster({});
  const sha = ma.agentDefinition(roster, 'quality-assurance').sha;
  const { ctx, calls } = makeCtx({
    handler: (call) => {
      if (call.method === 'GET') {
        return jsonResponse(200, { data: [remoteAgent({ id: 'agent_QA', version: 4, metadata: { claudeos_role: 'quality-assurance', claudeos_def_sha: sha }, tools: [{ type: 'agent_toolset_20260401', default_config: { enabled: true } }], mcp_servers: [{ type: 'url', name: 'github', url: 'https://x.example/mcp' }] })] });
      }
      return jsonResponse(200, { id: 'agent_QA', version: 5 });
    },
  });
  const out = await ma.agentsSync(ctx, 'quality-assurance');
  assert.deepEqual([out.results[0].action, out.results[0].version], ['updated', 5]);
  const update = calls.find((c) => c.method === 'POST');
  assert.equal(update.body.tools[0].default_config.enabled, false);
  assert.ok(!('mcp_servers' in update.body) || update.body.mcp_servers.length === 0);
});

test('status: 設定・予算・Agent 定義を返す。--probe は live 以外で API を呼ばない', async () => {
  const dry = makeCtx({ config: baseConfig({ mode: 'dry-run' }) });
  const st = await ma.status(dry.ctx, { probe: true });
  assert.deepEqual([st.usable, st.mode, st.probe.ok, st.probe.code], [true, 'dry-run', false, 'NOT_LIVE']);
  assert.equal(dry.calls.length, 0);
  assert.equal(st.agents.length, 3);
  assert.equal(st.budget.remaining_month_cents, 2000);
  assert.equal(st.budget.period.basis, 'calendar-month-reference');
});

// ---------- 依頼の入口 (ask): メニューと skill の共通経路 ----------

test('ask: タスク ID を採番し、role の既定種別で Router を通してから実行する', async () => {
  let createdTaskId = null;
  const { ctx, sessionPosts } = makeCtx({
    handler: (call) => {
      if (isSessionCreate(call)) { createdTaskId = call.body.metadata.claudeos_task_id; return jsonResponse(200, { id: 'sesn_01ASKOK', status: 'running' }); }
      if (/\/events\?/.test(call.url)) return jsonResponse(200, { data: [{ id: 'm', type: 'agent.message', processed_at: '2026-10-10T12:00:03Z', content: [{ type: 'text', text: '確認しました' }] }, idleEvent('end_turn')] });
      if (/sesn_01ASKOK$/.test(call.url)) return jsonResponse(200, sessionObj('sesn_01ASKOK', createdTaskId, { usage: { list_cost: { amount: '7', currency: 'USD' } } }));
      return undefined;
    },
  });
  const out = await ma.ask(ctx, { role: 'repository-review', prompt: 'README と設計書の食い違いを確認', source: 'agent' });
  assert.deepEqual([out.managed, out.executed, out.outcome, out.list_cost_cents, out.source, out.task_type], [true, true, 'completed', 7, 'agent', 'review']);
  assert.match(out.task_id, /^ask-repository-review-\d{8}T\d{6}Z$/);
  assert.equal(sessionPosts().length, 1);
  assert.equal(sessionPosts()[0].body.budget.max_list_cost.amount, '200');
  // 誰の判断で実行したかが履歴に残る
  const history = fs.readFileSync(ctx.decisionsPath, 'utf8').trim().split('\n').map((l) => JSON.parse(l));
  assert.ok(history.some((h) => h.kind === 'ask' && h.source === 'agent' && h.execution === 'ManagedAgent'));
  assert.equal(summary(ctx).openSessions, 0);
});

test('ask: role ごとの既定種別 (review / qa-analysis / docs)。check は明示した時だけ', async () => {
  for (const [role, expected] of [['repository-review', 'review'], ['quality-assurance', 'qa-analysis'], ['documentation', 'docs']]) {
    const { ctx } = makeCtx({ config: baseConfig({ mode: 'dry-run' }) });
    const out = await ma.ask(ctx, { role, prompt: '確認してください' });
    assert.equal(out.executed, false);
    assert.equal(out.request.body.metadata.claudeos_role, role);
    assert.equal(out.request.body.budget.max_list_cost.amount, '200', `${role} → ${expected}`);
  }
  const chk = makeCtx({ config: baseConfig({ mode: 'dry-run' }) });
  assert.equal((await ma.ask(chk.ctx, { role: 'repository-review', prompt: '確認', taskType: 'check' })).request.body.budget.max_list_cost.amount, '50');
});

test('ask: Managed へ出せない場合は実行せず、Local 側の実行先を返す (予算・回数・未設定キー)', async () => {
  // 本日の上限回数に到達
  const limited = makeCtx();
  fs.mkdirSync(path.dirname(limited.ctx.ledgerPath), { recursive: true });
  fs.writeFileSync(limited.ctx.ledgerPath, ['a', 'b', 'c', 'd', 'e'].flatMap((id) => [
    { type: 'reserve', ts: '2026-10-10T01:00:00.000Z', task_id: id, cents: 10 },
    { type: 'usage', ts: '2026-10-10T01:01:00.000Z', task_id: id, session_id: `s${id}`, list_cost_cents: 1, final: true },
  ]).map((e) => JSON.stringify(e)).join('\n') + '\n');
  const out = await ma.ask(limited.ctx, { role: 'repository-review', prompt: '確認', source: 'agent' });
  assert.deepEqual([out.managed, out.executed, out.do_locally_with, out.policy_denied], [false, false, 'Subagent', false]);
  assert.ok(out.denied.includes('budget-daily_session_limit'));
  assert.equal(limited.sessionPosts().length, 0);

  // API キーなし (live)
  const nokey = makeCtx({ env: { ANTHROPIC_API_KEY: null } });
  const o2 = await ma.ask(nokey.ctx, { role: 'documentation', prompt: '確認' });
  assert.deepEqual([o2.managed, o2.do_locally_with], [false, 'Subagent']);
  assert.equal(nokey.calls.length, 0);

  // 月間予算を使い切り
  const full = makeCtx();
  fs.mkdirSync(path.dirname(full.ctx.ledgerPath), { recursive: true });
  fs.writeFileSync(full.ctx.ledgerPath, [
    { type: 'reserve', ts: '2026-10-02T00:00:00.000Z', task_id: 'old', cents: 200 },
    { type: 'usage', ts: '2026-10-02T00:10:00.000Z', task_id: 'old', session_id: 's', list_cost_cents: 2000, final: true },
  ].map((e) => JSON.stringify(e)).join('\n') + '\n');
  const o3 = await ma.ask(full.ctx, { role: 'repository-review', prompt: '確認' });
  assert.equal(o3.managed, false);
  assert.equal(full.sessionPosts().length, 0);
});

test('ask: 設定が無効・role が不明・依頼文が空なら何も送らない', async () => {
  const off = makeCtx({ config: baseConfig({ mode: 'disabled' }) });
  await assert.rejects(ma.ask(off.ctx, { role: 'repository-review', prompt: '確認' }), (e) => e.code === 'MANAGED_UNAVAILABLE');
  const { ctx, calls } = makeCtx();
  await assert.rejects(ma.ask(ctx, { role: 'constructor', prompt: '確認' }), (e) => e.code === 'ROLE_UNKNOWN');
  await assert.rejects(ma.ask(ctx, { role: 'repository-review', prompt: '   ' }), (e) => e.code === 'PROMPT_REQUIRED');
  await assert.rejects(ma.ask(ctx, { prompt: '確認' }), (e) => e.code === 'ROLE_REQUIRED');
  assert.equal(calls.length + off.calls.length, 0);
});

test('依頼文の検査: 秘密らしき値・長すぎる依頼文はクラウドへ送らない (ask / session create とも)', async () => {
  const secrets = [
    `このキーで確認して ${FAKE_KEY}`,
    `token: ${FAKE_GH}`,
    'ghp_ABCDEFGHIJKLMNOPQRSTUVWX を使って',
    'AKIAABCDEFGHIJKLMNOP',
    '-----BEGIN OPENSSH PRIVATE KEY-----\nabc',
    'DB は postgresql://app:s3cretpw@localhost:5432/prod です',
  ];
  for (const prompt of secrets) {
    const { ctx, calls } = makeCtx();
    await assert.rejects(ma.ask(ctx, { role: 'repository-review', prompt }), (e) => e.cls === 'POLICY' && e.code === 'PROMPT_CONTAINS_SECRET', prompt.slice(0, 20));
    await assert.rejects(ma.sessionCreate(ctx, sessionArgs({ prompt })), (e) => e.code === 'PROMPT_CONTAINS_SECRET');
    assert.equal(calls.length, 0);
    assert.equal(fs.existsSync(ctx.ledgerPath), false, '予約もしない');
  }
  const { ctx, calls } = makeCtx();
  await assert.rejects(ma.ask(ctx, { role: 'repository-review', prompt: 'あ'.repeat(8001) }), (e) => e.code === 'PROMPT_TOO_LONG');
  assert.equal(calls.length, 0);
  // 認証情報を含まない URL や普通の文は通る
  assert.equal(ma.assertPromptSafe('postgresql://localhost:5432/app の接続設定の書き方を README で確認して'), true);
  assert.equal(ma.assertPromptSafe('token という単語や sk-ant という接頭辞の説明があるか確認して'), true);
});

test('status: 本日の回数と残り回数を返す', async () => {
  const { ctx } = makeCtx({ config: baseConfig({ mode: 'dry-run' }) });
  reserveTask(ctx, 't-today', 'sesn_01T', 10);
  const st = await ma.status(ctx, {});
  assert.deepEqual([st.budget.sessions_today, st.budget.remaining_sessions_today, st.budget.policy.maxSessionsPerDay], [1, 4, 5]);
});

// ---------- CLI ----------

test('parseArgs: 値の無いオプション・不明なオプションはエラー。-- で始まる値も受け取れる', () => {
  assert.throws(() => ma.parseArgs(['session', 'create', '--budget-cents']), (e) => e.code === 'OPTION_VALUE_REQUIRED');
  assert.throws(() => ma.parseArgs(['status', '--config']), (e) => e.code === 'OPTION_VALUE_REQUIRED');
  assert.throws(() => ma.parseArgs(['status', '--no-such-flag']), (e) => e.code === 'OPTION_UNKNOWN');
  const { pos, opts } = ma.parseArgs(['session', 'create', '--prompt', '--verbose を説明', '--ack-daily-soft', '--task-id', 't1']);
  assert.deepEqual(pos, ['session', 'create']);
  assert.deepEqual(opts, { prompt: '--verbose を説明', 'ack-daily-soft': true, 'task-id': 't1' });
});

test('CLI: status は設定なしでも成功し、route は Local の決定を返す', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ma-cli-'));
  const env = { PATH: process.env.PATH, HOME: dir, CLAUDEOS_MA_STATE_DIR: dir, CLAUDEOS_MANAGED_AGENTS_CONFIG: path.join(dir, 'none.json') };
  const st = JSON.parse(execFileSync(process.execPath, [TOOL, 'status'], { env, encoding: 'utf8' }));
  assert.deepEqual([st.mode, st.usable], ['missing', false]);
  const d = JSON.parse(execFileSync(process.execPath, [TOOL, 'route', '--json', JSON.stringify(lowRiskTask())], { env, encoding: 'utf8' }));
  assert.equal(d.execution, 'Subagent');
  assert.equal(d.managed.selected, false);
});

test('CLI: 値の無いオプションは終了コード 2 で止まり、既定値で実行されない', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ma-cli-'));
  const env = { PATH: process.env.PATH, HOME: dir, CLAUDEOS_MA_STATE_DIR: dir, CLAUDEOS_MANAGED_AGENTS_CONFIG: path.join(dir, 'none.json') };
  const r = spawnSync(process.execPath, [TOOL, 'session', 'create', '--task-id', 't', '--budget-cents'], { env, encoding: 'utf8' });
  assert.equal(r.status, 2);
  assert.equal(JSON.parse(r.stderr).code, 'OPTION_VALUE_REQUIRED');
});

test('CLI: budget reconcile は Console の値 (USD) をセントへ変換して照合する', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ma-cli-'));
  const env = { PATH: process.env.PATH, HOME: dir, CLAUDEOS_MA_STATE_DIR: dir, CLAUDEOS_MANAGED_AGENTS_CONFIG: path.join(dir, 'none.json') };
  const r = JSON.parse(execFileSync(process.execPath, [TOOL, 'budget', 'reconcile', '--console-usd', '1.15'], { env, encoding: 'utf8' }));
  assert.deepEqual([r.console_cents, r.ledger_actual_cents, r.diff_cents], [115, 0, 115]);
});
