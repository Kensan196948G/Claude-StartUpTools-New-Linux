#!/usr/bin/env node
'use strict';
// managed-session-payload.test.js — managed-session-payload.js のユニットテスト
// 検証対象: 設定契約検証 / budget 必須化 / payload 形式 / イベント構築

const { test } = require('node:test');
const assert = require('node:assert');
const {
  sessionCreate, messageEvent, toolConfirmation, validate, loadConfig,
  PayloadError, ERR_CONFIG, ERR_BUDGET,
} = require('./managed-session-payload.js');

// --- fixture: 契約充足 config ---
function fixture(over = {}) {
  return Object.assign({
    enabled: true,
    mode: 'dry-run',
    environmentId: 'env_01TESTTESTTESTTEST',
    orchestratorId: 'agent_01ORCHORCHORCHORCH',
    vaultIds: ['vlt_01VAULTVAULTVAULT'],
    budget: { amountCents: '500', currency: 'USD' },
    inferenceGeo: 'global',
    github: {
      workspace: { type: 'repository_resource', resource: 'repo:org/repo' },
      mcp: { allowedTools: ['create_pull_request'], blockedTools: ['get_file_contents'] },
    },
  }, over);
}

test('validate: 契約充足 config は通過し budget を返す', () => {
  const v = validate(fixture());
  assert.equal(v.agent, 'agent_01ORCHORCHORCHORCH');
  assert.equal(v.envId, 'env_01TESTTESTTESTTEST');
  assert.equal(v.amount, '500');
  assert.equal(v.currency, 'USD');
  assert.equal(v.mode, 'dry-run');
});

test('validate: mode=disabled は CONFIG エラー', () => {
  assert.throws(() => validate(fixture({ mode: 'disabled' })), (e) => e.error === 'MODE_DISABLED' && e.code === ERR_CONFIG);
});

test('validate: enabled=false は CONFIG エラー', () => {
  assert.throws(() => validate(fixture({ enabled: false })), (e) => e.error === 'NOT_ENABLED');
});

test('validate: mode=live への昇格 (bypassMode) は禁止', () => {
  assert.throws(() => validate(fixture({ mode: 'dry-run' }), { bypassMode: 'live' }), (e) => e.error === 'MODE_ESCALATION_FORBIDDEN');
});

test('validate: プレースホルダ ID は未設定扱い', () => {
  assert.throws(() => validate(fixture({ orchestratorId: 'agent_xxxxxxxxxxxxxxxxxxxxxxxx' })), (e) => e.error === 'AGENT_NOT_CONFIGURED');
  assert.throws(() => validate(fixture({ environmentId: 'env_xxxxxxxxxxxxxxxxxxxxxxxx' })), (e) => e.error === 'ENVIRONMENT_NOT_CONFIGURED');
});

test('validate: budget 無しは BUDGET_REQUIRED (後付け不可の強制)', () => {
  const c = fixture();
  delete c.budget;
  assert.throws(() => validate(c), (e) => e.error === 'BUDGET_REQUIRED' && e.code === ERR_BUDGET);
});

test('validate: budget amount の非整数 / 非 USD は拒否', () => {
  assert.throws(() => validate(fixture({ budget: { amountCents: '5.00', currency: 'USD' } })), (e) => e.error === 'BUDGET_AMOUNT_INVALID');
  assert.throws(() => validate(fixture({ budget: { amountCents: '500', currency: 'JPY' } })), (e) => e.error === 'BUDGET_CURRENCY_INVALID');
});

test('sessionCreate: POST /v1/sessions body の公式形式を構築', () => {
  const { payload, meta } = sessionCreate(fixture());
  // inference_geo は session 最上位では受理されない (現行仕様: agent の model オブジェクト内)。config にあっても載せない。
  assert.deepEqual(Object.keys(payload).sort(), ['agent', 'budget', 'environment_id', 'vault_ids']);
  assert.equal(payload.agent, 'agent_01ORCHORCHORCHORCH'); // agent_id ではなく ID 文字列 (spec §6-2)
  assert.equal(payload.budget.type, 'limit');
  assert.deepEqual(payload.budget.max_list_cost, { amount: '500', currency: 'USD' });
  assert.equal(meta.github_primary, 'repository_resource');
  assert.deepEqual(meta.mcp_blocked_tools, ['get_file_contents']);
  assert.ok(!('prompt' in payload)); // prompt は受理されない
});

test('sessionCreate: budget 上書き (--budget-cents) は config より優先', () => {
  const { payload } = sessionCreate(fixture(), { budgetCents: '250' });
  assert.equal(payload.budget.max_list_cost.amount, '250');
});

test('sessionCreate: vaultIds のプレースホルダ/非 vlt_ は除外', () => {
  const { payload } = sessionCreate(fixture({ vaultIds: ['vlt_xxx', 'bad', 'vlt_01OKOKOKOK'] }));
  assert.deepEqual(payload.vault_ids, ['vlt_01OKOKOKOK']);
});

test('messageEvent: user.message を events ラッパで構築', () => {
  const ev = messageEvent('テスト');
  assert.deepEqual(ev, { events: [{ type: 'user.message', content: [{ type: 'text', text: 'テスト' }] }] });
  assert.throws(() => messageEvent(''), (e) => e.error === 'MESSAGE_REQUIRED');
});

test('toolConfirmation: allow/deny のみ許可 (human_gate は呼び出し側で人間決裁後に allow)', () => {
  const ev = toolConfirmation('sevt_01X', 'allow');
  assert.deepEqual(ev, { events: [{ type: 'user.tool_confirmation', tool_use_id: 'sevt_01X', result: 'allow' }] });
  assert.throws(() => toolConfirmation('sevt_01X', 'yes'), (e) => e.error === 'CONFIRMATION_RESULT_INVALID');
  assert.throws(() => toolConfirmation('', 'allow'), (e) => e.error === 'TOOL_USE_ID_REQUIRED');
});

test('loadConfig: 不正 JSON は CONFIG_UNREADABLE', () => {
  assert.throws(() => loadConfig('/nonexistent/managed-agents.json'), (e) => e.error === 'CONFIG_UNREADABLE');
});

test('validate: budget は先頭ゼロなしの正の整数文字列のみ ("0" / "0500" は拒否)', () => {
  assert.throws(() => validate(fixture({ budget: { amountCents: '0', currency: 'USD' } })), (e) => e.error === 'BUDGET_AMOUNT_INVALID');
  assert.throws(() => validate(fixture({ budget: { amountCents: '0500', currency: 'USD' } })), (e) => e.error === 'BUDGET_AMOUNT_INVALID');
});

test('validate: maxCents (単一セッション上限) を超える budget は拒否', () => {
  assert.throws(() => validate(fixture(), { maxCents: 200 }), (e) => e.error === 'BUDGET_SESSION_CAP_EXCEEDED' && e.code === ERR_BUDGET);
  assert.equal(validate(fixture(), { budgetCents: '200', maxCents: 200 }).amount, '200');
});

test('sessionCreate: version 固定参照・resources・initial_events・title・metadata を載せられる', () => {
  const { payload } = sessionCreate(fixture(), {
    agent: 'agent_01ROLEROLEROLE', agentVersion: 4, environmentId: 'env_01OTHEROTHER', budgetCents: '150',
    title: 'claudeos:review:t1', metadata: { claudeos_task_id: 't1' },
    resources: [{ type: 'github_repository', url: 'https://github.com/o/r' }],
    initialEvents: messageEvent('hello').events,
  });
  assert.deepEqual(payload.agent, { type: 'agent', id: 'agent_01ROLEROLEROLE', version: 4 });
  assert.equal(payload.environment_id, 'env_01OTHEROTHER');
  assert.deepEqual(payload.budget.max_list_cost, { amount: '150', currency: 'USD' });
  assert.equal(payload.resources[0].type, 'github_repository');
  assert.equal(payload.initial_events[0].type, 'user.message');
  assert.equal(payload.title, 'claudeos:review:t1');
});
