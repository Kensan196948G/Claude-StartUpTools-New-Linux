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

function baseConfig(over) {
  return Object.assign({
    enabled: true,
    mode: 'live',
    environmentId: 'env_01TESTENVTESTENV',
    agents: { 'repository-review': { id: 'agent_01REVIEWREVIEW', version: 3 } },
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

// handler(call) -> response | throws。calls に全リクエストを記録する。
function makeCtx(opts) {
  const o = opts || {};
  const stateDir = fs.mkdtempSync(path.join(os.tmpdir(), 'ma-adapter-'));
  const calls = [];
  const env = Object.assign({ ANTHROPIC_API_KEY: FAKE_KEY, CLAUDEOS_MA_GITHUB_TOKEN: FAKE_GH, CLAUDEOS_MA_STATE_DIR: stateDir }, o.env);
  for (const k of Object.keys(env)) if (env[k] === null) delete env[k];
  let t = new Date('2026-10-10T12:00:00Z').getTime();
  const ctx = ma.createContext({
    config: o.config === undefined ? baseConfig() : o.config,
    env,
    now: () => new Date(t),
    sleep: async (ms) => { t += ms; },
    requestTimeoutMs: 50,
    fetch: async (url, init) => {
      const call = { url, method: init.method, headers: init.headers, body: init.body ? JSON.parse(init.body) : undefined, signal: init.signal };
      calls.push(call);
      return o.handler ? o.handler(call, calls) : jsonResponse(200, {});
    },
  });
  return { ctx, calls, stateDir, advance: (ms) => { t += ms; } };
}

const sessionArgs = (over) => Object.assign({ taskId: 'task-001', role: 'repository-review', prompt: 'README を確認してください', taskClass: 'task' }, over);
const idleEvent = (type) => ({ id: 'sevt_idle', type: 'session.status_idle', processed_at: '2026-10-10T12:00:05Z', stop_reason: { type } });

// ---------- T01 設定の読み込み ----------

test('T01 配布テンプレートは既定で利用不可 (enabled=false / mode=disabled)', () => {
  const v = ma.validateConfig(JSON.parse(fs.readFileSync(TEMPLATE, 'utf8')));
  assert.equal(v.ok, false);
  assert.equal(v.mode, 'disabled');
  assert.ok(v.reasons.includes('not-enabled'));
  assert.ok(v.reasons.includes('mode-disabled'));
  // テンプレート自体に秘密らしき値・不正な予算ポリシーは無い
  assert.ok(!v.reasons.some((r) => r.startsWith('secret-in-config') || r.startsWith('budget-policy-invalid') || r.startsWith('roster-invalid')));
});

test('T01 テンプレートの予算既定値は運用モデル通り (月 $20 / セッション $2 / 接続テスト $0.50 / 日次 $3 / 並列 1 / 再試行 1)', () => {
  const t = JSON.parse(fs.readFileSync(TEMPLATE, 'utf8'));
  const p = budget.normalizePolicy(t.budgetPolicy);
  assert.deepEqual([p.monthlyBudgetCents, p.sessionMaxCents, p.connectionTestMaxCents, p.dailySoftCents, p.maxConcurrentSessions, p.maxApiRetries], [2000, 200, 50, 300, 1, 1]);
  assert.deepEqual([p.warnPct, p.verifyOnlyPct, p.stopPct, p.exhaustedPct], [70, 85, 95, 100]);
  assert.equal(t.budget.amountCents, '200');
});

test('T01 有効な設定は usable、設定ファイル不在は missing で安全側', () => {
  assert.equal(ma.validateConfig(baseConfig()).ok, true);
  const v = ma.validateConfig(null);
  assert.equal(v.ok, false);
  assert.equal(v.mode, 'missing');
});

test('T01 不正な mode / 予算ポリシー / 送信先 URL は利用不可になる', () => {
  assert.ok(ma.validateConfig(baseConfig({ mode: 'turbo' })).reasons.includes('mode-invalid'));
  assert.ok(ma.validateConfig(baseConfig({ budgetPolicy: { maxApiRetries: 5 } })).reasons.some((r) => r.startsWith('budget-policy-invalid')));
  assert.ok(ma.validateConfig(baseConfig({ budgetPolicy: { monthlyBudgetCents: 0 } })).reasons.includes('monthly-budget-not-configured'));
  assert.ok(ma.validateConfig(baseConfig({ apiBaseUrl: 'https://evil.example.com' })).reasons.includes('api-base-url-not-allowed'));
});

test('T01 isAllowedBaseUrl: API キーの送信先は api.anthropic.com と loopback のみ', () => {
  assert.equal(ma.isAllowedBaseUrl('https://api.anthropic.com'), true);
  assert.equal(ma.isAllowedBaseUrl('http://127.0.0.1:8080'), true);
  assert.equal(ma.isAllowedBaseUrl('http://api.anthropic.com'), false);
  assert.equal(ma.isAllowedBaseUrl('https://api.anthropic.com.evil.test'), false);
  assert.equal(ma.isAllowedBaseUrl('not a url'), false);
});

// ---------- T02 API キー未設定時の安全な停止 ----------

test('T02 API キー未設定: API を 1 回も呼ばずに停止し、台帳にも予約を残さない', async () => {
  const { ctx, calls } = makeCtx({ env: { ANTHROPIC_API_KEY: null } });
  await assert.rejects(ma.sessionCreate(ctx, sessionArgs()), (e) => e.cls === 'KEY_MISSING' && e.code === 'API_KEY_MISSING');
  assert.equal(calls.length, 0);
  assert.equal(budget.readLedger(ctx.ledgerPath).entries.length, 0);
});

test('T02 API キー未設定 (CLI): 終了コード 2・Local 経路への切替可・キー値は出力に無い', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ma-cli-'));
  const cfg = path.join(dir, 'managed-agents.json');
  fs.writeFileSync(cfg, JSON.stringify(baseConfig()));
  const env = { PATH: process.env.PATH, HOME: dir, CLAUDEOS_MA_STATE_DIR: dir };
  const r = spawnSync(process.execPath, [TOOL, 'session', 'create', '--config', cfg, '--task-id', 't1', '--role', 'repository-review', '--prompt', 'x'], { env, encoding: 'utf8' });
  assert.equal(r.status, 2);
  const err = JSON.parse(r.stderr);
  assert.equal(err.code, 'API_KEY_MISSING');
  assert.equal(err.fallback.to, 'local');
  assert.equal(err.state, 'UNAVAILABLE');
});

test('T02 mode=disabled / dry-run では live 操作を拒否する', async () => {
  const dis = makeCtx({ config: baseConfig({ mode: 'disabled' }) });
  await assert.rejects(ma.sessionCreate(dis.ctx, sessionArgs()), (e) => e.code === 'MANAGED_UNAVAILABLE');
  const dry = makeCtx({ config: baseConfig({ mode: 'dry-run' }) });
  await assert.rejects(ma.sessionWait(dry.ctx, { sessionId: 'sesn_x' }), (e) => e.code === 'NOT_LIVE');
  assert.equal(dis.calls.length + dry.calls.length, 0);
});

// ---------- T03 予算未指定セッション作成の拒否 ----------

test('T03 予算未指定 (config にも引数にも無い) のセッション作成は拒否し、API を呼ばない', async () => {
  const { ctx, calls } = makeCtx({ config: baseConfig({ budget: undefined }) });
  await assert.rejects(ma.sessionCreate(ctx, sessionArgs()), (e) => e.cls === 'BUDGET' && e.code === 'BUDGET_REQUIRED');
  assert.equal(calls.length, 0);
});

test('T03 セッション上限 ($2) を超える予算は拒否し、API を呼ばない', async () => {
  const { ctx, calls } = makeCtx();
  await assert.rejects(ma.sessionCreate(ctx, sessionArgs({ budgetCents: '500' })), (e) => e.cls === 'BUDGET' && e.code === 'BUDGET_SESSION_CAP_EXCEEDED');
  assert.equal(calls.length, 0);
});

test('T03 作成リクエストには必ず budget.max_list_cost (セント整数の文字列・USD) が入る', async () => {
  const { ctx, calls } = makeCtx({ handler: () => jsonResponse(200, { id: 'sesn_01NEW', status: 'running' }) });
  const out = await ma.sessionCreate(ctx, sessionArgs({ budgetCents: '150' }));
  assert.equal(out.session_id, 'sesn_01NEW');
  assert.equal(calls.length, 1);
  assert.equal(calls[0].method, 'POST');
  assert.ok(calls[0].url.endsWith('/v1/sessions'));
  assert.deepEqual(calls[0].body.budget, { type: 'limit', max_list_cost: { amount: '150', currency: 'USD' } });
  assert.equal(calls[0].headers['anthropic-beta'], 'managed-agents-2026-04-01');
  assert.equal(calls[0].headers['anthropic-version'], '2023-06-01');
  // agent は version 固定参照、inference_geo は session 最上位に載せない
  assert.deepEqual(calls[0].body.agent, { type: 'agent', id: 'agent_01REVIEWREVIEW', version: 3 });
  assert.ok(!('inference_geo' in calls[0].body));
  assert.equal(calls[0].body.initial_events[0].type, 'user.message');
});

test('T03 確認処理 (check) は接続テスト上限 50¢ を超えると拒否', async () => {
  const { ctx, calls } = makeCtx();
  await assert.rejects(ma.sessionCreate(ctx, sessionArgs({ taskClass: 'check', budgetCents: '100' })), (e) => e.cls === 'BUDGET');
  assert.equal(calls.length, 0);
});

// ---------- T05 段階制御 (adapter 経由) ----------

test('T05 月間予算 95% 以上では新規セッションを作らない (API を呼ばない)', async () => {
  const { ctx, calls } = makeCtx();
  fs.mkdirSync(path.dirname(ctx.ledgerPath), { recursive: true });
  fs.writeFileSync(ctx.ledgerPath, [
    { type: 'reserve', ts: '2026-10-02T00:00:00.000Z', task_id: 'old', cents: 200 },
    { type: 'usage', ts: '2026-10-02T00:10:00.000Z', task_id: 'old', session_id: 's', list_cost_cents: 1900, final: true },
  ].map((e) => JSON.stringify(e)).join('\n') + '\n');
  await assert.rejects(ma.sessionCreate(ctx, sessionArgs()), (e) => e.cls === 'BUDGET' && e.code === 'BUDGET_STOP');
  assert.equal(calls.length, 0);
});

// ---------- T06 重複セッション起動の防止 ----------

test('T06 同じ task_id の 2 回目は DUPLICATE で拒否し、API は 1 回しか呼ばれない', async () => {
  const { ctx, calls } = makeCtx({ config: baseConfig({ budgetPolicy: { maxConcurrentSessions: 3 } }), handler: () => jsonResponse(200, { id: 'sesn_01DUP', status: 'running' }) });
  await ma.sessionCreate(ctx, sessionArgs());
  await assert.rejects(ma.sessionCreate(ctx, sessionArgs()), (e) => e.cls === 'DUPLICATE' && e.extra.session_id === 'sesn_01DUP');
  assert.equal(calls.length, 1);
  assert.equal(ma.fallbackDecision('DUPLICATE').to, 'none');
});

test('T06 実行中セッションがある間は別タスクも作らない (並列 1)', async () => {
  const { ctx, calls } = makeCtx({ handler: () => jsonResponse(200, { id: 'sesn_01RUN', status: 'running' }) });
  await ma.sessionCreate(ctx, sessionArgs());
  await assert.rejects(ma.sessionCreate(ctx, sessionArgs({ taskId: 'task-002' })), (e) => e.cls === 'BUDGET' && e.code === 'CONCURRENCY_LIMIT');
  assert.equal(calls.length, 1);
});

// ---------- T07 API タイムアウト時の安全な停止 ----------

test('T07 セッション作成のタイムアウト: POST を再試行せず停止し、予約は残す (作成有無が不明なため)', async () => {
  const { ctx, calls } = makeCtx({
    handler: (call) => new Promise((_, reject) => {
      call.signal.addEventListener('abort', () => { const e = new Error('aborted'); e.name = 'AbortError'; reject(e); });
    }),
  });
  await assert.rejects(ma.sessionCreate(ctx, sessionArgs()), (e) => e.cls === 'TIMEOUT' && e.extra.reservation === 'kept-session-state-unknown');
  assert.equal(calls.length, 1, 'POST は 1 回だけ (自動再試行なし)');
  const s = budget.summarize(budget.readLedger(ctx.ledgerPath).entries, new Date('2026-10-10T12:00:00Z'), ctx.policy);
  assert.equal(s.committedMonthCents, 200);
});

test('T07 作成が API エラー (5xx) で失敗したら予約を解除し、POST は再試行しない', async () => {
  const { ctx, calls } = makeCtx({ handler: () => jsonResponse(500, { type: 'error', error: { type: 'api_error', message: 'boom' } }) });
  await assert.rejects(ma.sessionCreate(ctx, sessionArgs()), (e) => e.cls === 'SERVICE' && e.extra.reservation === 'released');
  assert.equal(calls.length, 1);
  const s = budget.summarize(budget.readLedger(ctx.ledgerPath).entries, new Date('2026-10-10T12:00:00Z'), ctx.policy);
  assert.equal(s.committedMonthCents, 0);
  assert.equal(s.openSessions, 0);
});

test('T07 GET は最大 1 回だけ再試行する (無制限リトライしない)', async () => {
  const { ctx, calls } = makeCtx({ handler: () => jsonResponse(529, { type: 'error', error: { type: 'overloaded_error', message: 'busy' } }) });
  await assert.rejects(ma.apiRequest(ctx, 'GET', '/v1/agents?limit=1'), (e) => e.cls === 'SERVICE' && e.extra.attempts === 2);
  assert.equal(calls.length, 2);
});

test('T07 監視が上限時間を超えたら user.interrupt を送り、以後は再開しない', async () => {
  const { ctx, calls } = makeCtx({
    handler: (call) => {
      if (call.method === 'POST') return jsonResponse(200, {});
      if (/\/events\?/.test(call.url)) return jsonResponse(200, { data: [{ id: 'e1', type: 'session.status_running', processed_at: '2026-10-10T12:00:01Z' }], next_page: null });
      return jsonResponse(200, { id: 'sesn_01SLOW', status: 'idle', usage: { list_cost: { amount: '37', currency: 'USD' } } });
    },
  });
  budget.reserve(ctx.ledgerPath, ctx.now(), ctx.policy, { taskId: 'task-slow', cents: 200 });
  await assert.rejects(ma.sessionWait(ctx, { sessionId: 'sesn_01SLOW', taskId: 'task-slow', maxWaitSeconds: 20, pollMs: 5000 }), (e) => e.cls === 'TIMEOUT' && e.code === 'SESSION_WAIT_TIMEOUT');
  const interrupts = calls.filter((c) => c.method === 'POST');
  assert.equal(interrupts.length, 1);
  assert.deepEqual(interrupts[0].body, { events: [{ type: 'user.interrupt' }] });
  // 中断後に使用量を確定記録する (実績 37¢)
  const s = budget.summarize(budget.readLedger(ctx.ledgerPath).entries, ctx.now(), ctx.policy);
  assert.equal(s.actualMonthCents, 37);
  assert.equal(s.openSessions, 0);
});

// ---------- 完了判定・使用量記録 ----------

test('完了 (end_turn): 結果テキストを返し、累積 list_cost を確定記録する', async () => {
  const { ctx } = makeCtx({
    handler: (call) => {
      if (/\/events\?/.test(call.url)) {
        return jsonResponse(200, { data: [
          { id: 'e1', type: 'session.status_running', processed_at: '2026-10-10T12:00:01Z' },
          { id: 'e2', type: 'agent.message', processed_at: '2026-10-10T12:00:03Z', content: [{ type: 'text', text: 'レビュー結果: 問題なし' }] },
          idleEvent('end_turn'),
        ] });
      }
      return jsonResponse(200, { id: 'sesn_01OK', status: 'idle', usage: { input_tokens: 1200, output_tokens: 300, list_cost: { amount: '12', currency: 'USD' } } });
    },
  });
  budget.reserve(ctx.ledgerPath, ctx.now(), ctx.policy, { taskId: 'task-ok', cents: 200 });
  const out = await ma.sessionWait(ctx, { sessionId: 'sesn_01OK', taskId: 'task-ok' });
  assert.equal(out.outcome, 'completed');
  assert.equal(out.text, 'レビュー結果: 問題なし');
  assert.equal(out.list_cost_cents, 12);
  const t = budget.foldTasks(budget.readLedger(ctx.ledgerPath).entries).get('task-ok');
  assert.equal(t.final, true);
  assert.equal(t.actualCents, 12);
});

test('予算到達 (budget_reached): 予算を引き上げ・削除せず、再開もしない', async () => {
  const { ctx, calls } = makeCtx({
    handler: (call) => {
      if (/\/events\?/.test(call.url)) return jsonResponse(200, { data: [idleEvent('budget_reached')] });
      return jsonResponse(200, { id: 'sesn_01CAP', status: 'idle', usage: { list_cost: { amount: '53', currency: 'USD' } } });
    },
  });
  budget.reserve(ctx.ledgerPath, ctx.now(), ctx.policy, { taskId: 'task-cap', cents: 50, taskClass: 'check' });
  await assert.rejects(ma.sessionWait(ctx, { sessionId: 'sesn_01CAP', taskId: 'task-cap' }), (e) => e.cls === 'SESSION_BUDGET' && e.extra.result.list_cost_cents === 53);
  // セッション更新 (budget 変更) や追加メッセージの POST は一切送らない
  assert.equal(calls.filter((c) => c.method !== 'GET').length, 0);
  assert.equal(ma.fallbackDecision('SESSION_BUDGET').to, 'none');
});

test('承認要求 (requires_action): 自動承認せず中断する', async () => {
  const { ctx, calls } = makeCtx({
    handler: (call) => {
      if (call.method === 'POST') return jsonResponse(200, {});
      if (/\/events\?/.test(call.url)) return jsonResponse(200, { data: [idleEvent('requires_action')] });
      return jsonResponse(200, { id: 'sesn_01ASK', status: 'idle', usage: { list_cost: { amount: '3', currency: 'USD' } } });
    },
  });
  await assert.rejects(ma.sessionWait(ctx, { sessionId: 'sesn_01ASK' }), (e) => e.code === 'SESSION_NOT_COMPLETED');
  const posts = calls.filter((c) => c.method === 'POST');
  assert.equal(posts.length, 1);
  assert.equal(posts[0].body.events[0].type, 'user.interrupt');
  assert.ok(!posts.some((c) => JSON.stringify(c.body).includes('tool_confirmation')));
});

test('latestStatusEvent / outcomeOf: processed_at が最新の status を根拠にする', () => {
  const events = [idleEvent('end_turn'), { id: 'e9', type: 'session.status_running', processed_at: '2026-10-10T12:00:09Z' }];
  assert.equal(ma.outcomeOf(ma.latestStatusEvent(events)), null); // 後から running に戻っている
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
});

test('T08 GitHub リポジトリは github_repository リソースとしてマウントし、トークンは環境変数からのみ渡す', async () => {
  const { ctx, calls } = makeCtx({ handler: () => jsonResponse(200, { id: 'sesn_01GH', status: 'running' }) });
  await ma.sessionCreate(ctx, sessionArgs());
  const res = calls[0].body.resources;
  assert.equal(res.length, 1);
  assert.equal(res[0].type, 'github_repository');
  assert.equal(res[0].url, 'https://github.com/Kensan196948G/Claude-StartUpTools-New-Linux');
  assert.deepEqual(res[0].checkout, { type: 'branch', name: 'main' });
  assert.equal(res[0].authorization_token, FAKE_GH);
  assert.ok(!('vault_ids' in calls[0].body));
});

test('T08 GitHub トークン未設定ならリポジトリ付きセッションを作らない', async () => {
  const { ctx, calls } = makeCtx({ env: { CLAUDEOS_MA_GITHUB_TOKEN: null } });
  await assert.rejects(ma.sessionCreate(ctx, sessionArgs()), (e) => e.code === 'GITHUB_TOKEN_MISSING');
  assert.equal(calls.length, 0);
  assert.equal(budget.readLedger(ctx.ledgerPath).entries.length, 0);
});

test('T08 SSH 形式・.git 付き・github.com 以外の URL は拒否する', async () => {
  for (const repo of ['git@github.com:o/r.git', 'https://github.com/o/r.git', 'https://gitlab.com/o/r', 'https://github.com/o']) {
    const { ctx } = makeCtx();
    await assert.rejects(ma.sessionCreate(ctx, sessionArgs({ repo })), (e) => e.code === 'REPO_URL_INVALID', repo);
  }
});

test('T09 bash / write / edit / web / MCP を持つ Agent 定義は同期前に拒否される (main へ push する手段が無い)', () => {
  const toolset = (configs) => [{ type: 'agent_toolset_20260401', default_config: { enabled: false, permission_policy: { type: 'always_allow' } }, configs }];
  for (const name of ['bash', 'write', 'edit', 'web_fetch', 'web_search']) {
    assert.throws(() => ma.assertReadOnlyAgent({ tools: toolset([{ name, enabled: true }]) }), (e) => e.cls === 'POLICY' && e.code === 'READ_ONLY_VIOLATION', name);
  }
  // 既定で全ツール有効 (default_config.enabled 省略) も拒否
  assert.throws(() => ma.assertReadOnlyAgent({ tools: [{ type: 'agent_toolset_20260401' }] }), (e) => e.code === 'READ_ONLY_VIOLATION');
  // GitHub MCP (PR 作成・push の経路) は PoC では宣言不可
  assert.throws(() => ma.assertReadOnlyAgent({ tools: toolset([{ name: 'read', enabled: true }]), mcp_servers: [{ type: 'url', name: 'github', url: 'https://api.githubcopilot.com/mcp' }] }), (e) => e.code === 'READ_ONLY_VIOLATION');
  assert.throws(() => ma.assertReadOnlyAgent({ tools: [...toolset([{ name: 'read', enabled: true }]), { type: 'mcp_toolset', mcp_server_name: 'github' }] }), (e) => e.code === 'READ_ONLY_VIOLATION');
  assert.equal(ma.assertReadOnlyAgent({ tools: toolset([{ name: 'read', enabled: true }, { name: 'grep', enabled: true }]) }), true);
});

test('T09 Environment は limited networking (外向き通信 deny-by-default) を明示する', async () => {
  const roster = ma.loadRoster({});
  assert.equal(roster.environment.config.networking.type, 'limited');
  assert.equal(roster.environment.config.networking.allow_mcp_servers, false);
  assert.equal(roster.environment.config.networking.allow_package_managers, false);
  const { ctx } = makeCtx({ config: baseConfig({ mode: 'dry-run' }) });
  const plan = await ma.envEnsure(ctx);
  assert.equal(plan.executed, false);
  assert.equal(plan.plan.body.config.networking.type, 'limited');
});

// ---------- T10 本番環境への無承認アクセス拒否 / Agent Router 統合 ----------

const lowRiskTask = (over) => Object.assign({ task_type: 'review', complexity: 'medium', risk: 'low', read_only: true, files_affected: 10, managed: { requested: true } }, over);

test('Router 統合: 明示要求のある低リスク・読取専用タスクだけ ManagedAgent になる', () => {
  const { ctx } = makeCtx();
  const d = ma.route(ctx, lowRiskTask(), { taskId: 'r-1' });
  assert.equal(d.execution, 'ManagedAgent');
  assert.equal(d.managed.selected, true);
  assert.equal(d.managed.fallback_execution, 'Subagent');
});

test('Router 統合: Local が稼働中で明示要求が無ければ Managed を並列起動しない', () => {
  const { ctx } = makeCtx();
  const d = ma.route(ctx, lowRiskTask({ managed: {} }));
  assert.equal(d.execution, 'Subagent');
  assert.equal(d.managed.eligible, true);
  assert.equal(d.managed.selected, false);
});

test('Router 統合: Local が使えない場合は許可済みタスクを Managed へ', () => {
  const { ctx } = makeCtx();
  const d = ma.route(ctx, lowRiskTask({ managed: { local_available: false } }));
  assert.equal(d.execution, 'ManagedAgent');
});

test('T10 本番・DB・デプロイ・Secret・書込み・高リスクのタスクは Managed へ出さない (policy 拒否)', () => {
  const cases = [
    { deployment_impact: 'high' }, { deployment_impact: 'medium' }, { database_impact: 'medium' }, { security_impact: 'high' },
    { risk: 'medium' }, { read_only: false }, { task_type: 'deploy' }, { task_type: 'migration' },
    { managed: { requested: true, requires_secrets: true } }, { managed: { requested: true, human_gate: true } },
    { managed: { requested: true, data_sensitivity: 'confidential' } }, { managed: { requested: true, requires_external_network: true } },
  ];
  for (const c of cases) {
    const { ctx } = makeCtx();
    const d = ma.route(ctx, lowRiskTask(c));
    assert.notEqual(d.execution, 'ManagedAgent', JSON.stringify(c));
    assert.equal(d.managed.selected, false);
    assert.equal(d.managed.policy_denied, true, JSON.stringify(c));
  }
});

test('T10 Local が使えなくても、人間承認待ち・高リスクのタスクを Managed で代行しない', () => {
  const { ctx } = makeCtx();
  const d = ma.route(ctx, lowRiskTask({ deployment_impact: 'high', managed: { local_available: false, human_gate: true } }));
  assert.notEqual(d.execution, 'ManagedAgent');
  assert.equal(d.managed.policy_denied, true);
  assert.ok(d.guardrails.some((g) => g.includes('フォールバックで承認・拒否を回避しない')));
});

test('Router 統合: 決定履歴 (実行先・理由・戻り先) を記録する', () => {
  const { ctx } = makeCtx();
  ma.route(ctx, lowRiskTask(), { taskId: 'hist-1' });
  ma.route(ctx, lowRiskTask({ risk: 'high' }), { taskId: 'hist-2' });
  const lines = fs.readFileSync(ctx.decisionsPath, 'utf8').trim().split('\n').map((l) => JSON.parse(l));
  assert.equal(lines.length, 2);
  assert.deepEqual(lines.map((l) => [l.task_id, l.execution, l.managed_selected]), [['hist-1', 'ManagedAgent', true], ['hist-2', 'Subagent', false]]);
  assert.ok(lines[1].denied.includes('risk'));
});

// ---------- T12 Local Claude Code への安全な切替 ----------

test('T12 Managed が未設定・無効でも Router は既存の Local 実行先を返す (経路を壊さない)', () => {
  for (const config of [null, baseConfig({ enabled: false }), baseConfig({ mode: 'disabled' })]) {
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

test('T12 予算不足・重複タスクは Managed を選ばず Local の決定を保持する', () => {
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
  budget.reserve(dupe.ctx.ledgerPath, dupe.ctx.now(), dupe.ctx.policy, { taskId: 'same', cents: 100 });
  const d2 = ma.route(dupe.ctx, lowRiskTask(), { taskId: 'same' });
  assert.notEqual(d2.execution, 'ManagedAgent');
  assert.ok(d2.managed.denied.includes('duplicate-task'));
});

test('T12 フォールバック可否: 予算不足・API 障害は Local へ、認証・権限・ポリシー拒否は BLOCKED', () => {
  for (const cls of ['CONFIG', 'KEY_MISSING', 'BUDGET', 'BILLING', 'RATE_LIMIT', 'SERVICE', 'NETWORK', 'TIMEOUT']) {
    assert.equal(ma.fallbackDecision(cls).to, 'local', cls);
  }
  for (const cls of ['AUTH', 'PERMISSION', 'POLICY']) {
    const f = ma.fallbackDecision(cls);
    assert.equal(f.to, 'none', cls);
    assert.equal(f.state, 'BLOCKED', cls);
  }
  // 安全上の拒否がある場合は、API 障害であっても戻さない
  assert.deepEqual(ma.fallbackDecision('SERVICE', { policyDenied: true }), { to: 'none', state: 'BLOCKED', reason: 'security-or-human-gate-denial-is-not-bypassed' });
});

test('T12 認証エラー (401) は再試行せず BLOCKED、予約は解除する', async () => {
  const { ctx, calls } = makeCtx({ handler: () => jsonResponse(401, { type: 'error', error: { type: 'authentication_error', message: 'invalid x-api-key' }, request_id: 'req_1' }) });
  await assert.rejects(ma.sessionCreate(ctx, sessionArgs()), (e) => e.cls === 'AUTH' && e.extra.request_id === 'req_1');
  assert.equal(calls.length, 1);
  const p = ma.errorPayload(new ma.AdapterError('AUTH', 'API_AUTH', 'invalid'), ctx);
  assert.equal(p.exit, 4);
  assert.equal(p.body.state, 'BLOCKED');
  assert.equal(p.body.fallback.to, 'none');
});

// ---------- T11 Secret・Credential の非表示 ----------

test('T11 redact: API キー・GitHub トークン・Bearer を伏せる', () => {
  const s = ma.redact(`key=${FAKE_KEY} gh=${FAKE_GH} classic=ghp_ABCDEFGHIJKLMNOPQRSTUVWX Authorization: Bearer abcdefghijklmnop`, []);
  assert.ok(!s.includes(FAKE_KEY));
  assert.ok(!s.includes(FAKE_GH));
  assert.ok(!s.includes('ghp_ABCDEFGHIJKLMNOPQRSTUVWX'));
  assert.ok(!s.includes('abcdefghijklmnop'));
  assert.equal(ma.redact('token is hunter2-very-secret', ['hunter2-very-secret']), 'token is <redacted>');
});

test('T11 設定ファイルに秘密らしき値があれば利用不可にする (環境変数名と ID は対象外)', () => {
  assert.deepEqual(ma.findSecretKeys({ apiKey: 'sk-ant-xxx', nested: { authorization_token: 'ghp_x' }, github: { workspace: { tokenEnv: 'NAME' } }, vaultIds: ['vlt_1'], _comment: 'token' }, ''), ['apiKey', 'nested.authorization_token']);
  const v = ma.validateConfig(baseConfig({ apiKey: FAKE_KEY }));
  assert.equal(v.ok, false);
  assert.ok(v.reasons.some((r) => r === 'secret-in-config:apiKey'));
  assert.ok(!JSON.stringify(v).includes(FAKE_KEY));
});

test('T11 dry-run の出力・台帳・決定履歴に API キーと GitHub トークンの値が現れない', async () => {
  const { ctx, calls } = makeCtx({ config: baseConfig({ mode: 'dry-run' }) });
  const plan = await ma.sessionCreate(ctx, sessionArgs());
  assert.equal(plan.executed, false);
  assert.equal(calls.length, 0);
  const text = JSON.stringify(plan);
  assert.ok(!text.includes(FAKE_KEY));
  assert.ok(!text.includes(FAKE_GH));
  assert.equal(plan.request.headers['x-api-key'], '<env:ANTHROPIC_API_KEY>');
  assert.equal(plan.request.body.resources[0].authorization_token, '<env:CLAUDEOS_MA_GITHUB_TOKEN>');
  assert.deepEqual(plan.request.body.budget.max_list_cost, { amount: '200', currency: 'USD' });
  assert.equal(fs.existsSync(ctx.ledgerPath), false, 'dry-run は台帳へ書かない');
});

test('T11 live 実行後の台帳・決定履歴・status にも秘密の値が残らない', async () => {
  const { ctx, stateDir } = makeCtx({ handler: () => jsonResponse(200, { id: 'sesn_01SEC', status: 'running' }) });
  await ma.sessionCreate(ctx, sessionArgs());
  const st = await ma.status(ctx, {});
  assert.equal(st.api_key_present, true);
  assert.equal(st.github_token_present, true);
  const all = JSON.stringify(st) + fs.readdirSync(stateDir).map((f) => fs.readFileSync(path.join(stateDir, f), 'utf8')).join('\n');
  assert.ok(!all.includes(FAKE_KEY));
  assert.ok(!all.includes(FAKE_GH));
});

test('T11 API エラーメッセージに含まれた秘密も伏せる', async () => {
  const { ctx } = makeCtx({ handler: () => jsonResponse(400, { type: 'error', error: { type: 'invalid_request_error', message: `bad token ${FAKE_GH}` } }) });
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

test('agents sync (live): 未作成は作成、定義変更は version つき更新、一致は変更なし', async () => {
  const roster = ma.loadRoster({});
  const qa = ma.agentDefinition(roster, 'quality-assurance');
  const { ctx, calls } = makeCtx({
    handler: (call) => {
      if (call.method === 'GET') {
        return jsonResponse(200, { data: [
          { id: 'agent_QA', version: 4, metadata: { claudeos_role: 'quality-assurance', claudeos_def_sha: qa.sha } },
          { id: 'agent_DOC', version: 2, metadata: { claudeos_role: 'documentation', claudeos_def_sha: 'stale' } },
          { id: 'agent_OLD', version: 1, archived_at: '2026-09-01T00:00:00Z', metadata: { claudeos_role: 'repository-review' } },
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
  const reg = JSON.parse(fs.readFileSync(ctx.registryPath, 'utf8'));
  assert.equal(reg.agents['quality-assurance'].id, 'agent_QA');
});

test('status: 設定・予算・Agent 定義を返す。--probe は live 以外で API を呼ばない', async () => {
  const dry = makeCtx({ config: baseConfig({ mode: 'dry-run' }) });
  const st = await ma.status(dry.ctx, { probe: true });
  assert.equal(st.usable, true);
  assert.equal(st.mode, 'dry-run');
  assert.equal(st.probe.ok, false);
  assert.equal(st.probe.code, 'NOT_LIVE');
  assert.equal(dry.calls.length, 0);
  assert.equal(st.agents.length, 3);
  assert.equal(st.budget.remaining_month_cents, 2000);
  assert.equal(st.budget.period.basis, 'calendar-month-reference');
});

test('CLI: status は設定なしでも成功し、route は Local の決定を返す', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ma-cli-'));
  const env = { PATH: process.env.PATH, HOME: dir, CLAUDEOS_MA_STATE_DIR: dir, CLAUDEOS_MANAGED_AGENTS_CONFIG: path.join(dir, 'none.json') };
  const st = JSON.parse(execFileSync(process.execPath, [TOOL, 'status'], { env, encoding: 'utf8' }));
  assert.equal(st.mode, 'missing');
  assert.equal(st.usable, false);
  const d = JSON.parse(execFileSync(process.execPath, [TOOL, 'route', '--json', JSON.stringify(lowRiskTask())], { env, encoding: 'utf8' }));
  assert.equal(d.execution, 'Subagent');
  assert.equal(d.managed.selected, false);
});

test('CLI: budget reconcile は Console の値 (USD) をセントへ変換して照合する', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ma-cli-'));
  const env = { PATH: process.env.PATH, HOME: dir, CLAUDEOS_MA_STATE_DIR: dir, CLAUDEOS_MANAGED_AGENTS_CONFIG: path.join(dir, 'none.json') };
  const r = JSON.parse(execFileSync(process.execPath, [TOOL, 'budget', 'reconcile', '--console-usd', '1.15'], { env, encoding: 'utf8' }));
  assert.equal(r.console_cents, 115);
  assert.equal(r.ledger_actual_cents, 0);
  assert.equal(r.diff_cents, 115);
});
