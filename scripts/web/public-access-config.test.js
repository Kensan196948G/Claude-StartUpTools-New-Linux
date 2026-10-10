#!/usr/bin/env node
'use strict';
/**
 * public-access-config.test.js — Cloudflare 公開設定 (設計値) の安全検証
 *
 * cloudflared config / Access policy は「repo に置いた設計値」であり、適用は人間の Y/N 後。
 * ここではテンプレートがリンク単位で広がっていないこと (誤って everyone / ドメイン許可 /
 * ワイルドカード / LAN bind を書いていないこと) を機械的に固定する。
 *
 * 対象:
 *   config/cloudflare/web-startup-tunnel.yml
 *   config/cloudflare/web-startup-access-policy.json
 */

const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const TUNNEL_YML = path.join(ROOT, 'config', 'cloudflare', 'web-startup-tunnel.yml');
const POLICY_JSON = path.join(ROOT, 'config', 'cloudflare', 'web-startup-access-policy.json');

const HOSTNAME = 'claude-startuptools.mirai-dx-platform.com';
const ALLOWED_EMAIL = 'kensan1969@gmail.com';

const policy = JSON.parse(fs.readFileSync(POLICY_JSON, 'utf8'));
const tunnel = fs.readFileSync(TUNNEL_YML, 'utf8');
const yamlLines = tunnel.split('\n').filter(l => !l.trim().startsWith('#'));

test('Access policy: 対象 hostname は tunnel と一致する', () => {
  assert.equal(policy.hostname, HOSTNAME);
  assert.equal(policy.application.domain, HOSTNAME);
  assert.equal(policy.application.type, 'self_hosted');
});

test('Access policy: allow は kensan1969@gmail.com の 1 件のみ', () => {
  const allow = policy.policies.filter(p => p.decision === 'allow');
  assert.equal(allow.length, 1);
  assert.equal(allow[0].include.length, 1);
  assert.deepEqual(allow[0].include[0], { email: { email: ALLOWED_EMAIL } });
  assert.deepEqual(allow[0].exclude, []);
});

test('Access policy: catch-all は deny で最後に置く (fail closed)', () => {
  const decisions = policy.policies.map(p => p.decision);
  assert.equal(decisions[decisions.length - 1], 'deny');
  const deny = policy.policies[policy.policies.length - 1];
  assert.deepEqual(deny.include, [{ everyone: {} }]);
  // precedence 昇順 = 評価順 (allow が先、deny が後)
  const prec = policy.policies.map(p => p.precedence);
  assert.deepEqual(prec, [...prec].sort((a, b) => a - b));
});

test('Access policy: 広すぎる条件 (ドメイン単位 / ワイルドカード / everyone allow) を含まない', () => {
  const flat = JSON.stringify(policy.policies);
  assert.ok(!flat.includes('"email_domain"'), 'email_domain (ドメイン単位許可) は禁止');
  assert.ok(!/[*?]/.test(flat), 'ワイルドカード条件は禁止');
  assert.ok(!flat.includes('"ip"'), 'IP 条件は禁止');
  policy.policies.forEach(p => {
    if (p.decision !== 'allow') return;
    assert.ok(!JSON.stringify(p.include).includes('"everyone"'), 'allow に everyone は禁止');
  });
});

test('Access policy: service token は無効 (自動化経路を開けていない)', () => {
  assert.equal(policy.service_tokens.enabled, false);
});

test('Access policy: session_duration は 8h 以下 (長時間の無操作セッションを許さない)', () => {
  const m = /^(\d+)([hdm])$/.exec(policy.application.session_duration);
  assert.ok(m, 'session_duration の形式が不正');
  const hours = m[2] === 'h' ? Number(m[1]) : m[2] === 'd' ? Number(m[1]) * 24 : Number(m[1]) / 60;
  assert.ok(hours <= 8, `session_duration が長すぎる: ${policy.application.session_duration}`);
});

test('tunnel: 対象 hostname を loopback の 3740 へ向ける', () => {
  assert.ok(tunnel.includes(`hostname: ${HOSTNAME}`));
  assert.ok(tunnel.includes('service: http://127.0.0.1:3740'));
});

test('tunnel: 0.0.0.0 / LAN アドレスへの公開を含まない', () => {
  assert.ok(!/0\.0\.0\.0/.test(yamlLines.join('\n')), 'LAN bind は禁止 (公開は tunnel 側)');
  assert.ok(!/192\.168\./.test(yamlLines.join('\n')));
});

test('tunnel: catch-all は http_status:404 で最後 (未定義 hostname を閉じる)', () => {
  const last = yamlLines.filter(l => l.trim()).slice(-1)[0];
  assert.equal(last.trim(), '- service: http_status:404');
  assert.equal((tunnel.match(/http_status:404/g) || []).length, 1);
});

test('tunnel: secret / 実 ID を commit していない (placeholder のみ)', () => {
  assert.ok(tunnel.includes('<TUNNEL_ID>'), 'tunnel ID は placeholder であること');
  assert.ok(!/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/.test(tunnel), '実 UUID を書かない');
  // 値 (コメント以外) に secret 系キーを持ち込まない
  assert.ok(!/api[_-]?token|secret|password|_key:/i.test(yamlLines.join('\n')), 'secret を設定値として書かない');
  assert.ok(policy.application.allowed_idps.every(v => v === '<GOOGLE_IDP_ID>'), 'IdP ID も placeholder');
});
