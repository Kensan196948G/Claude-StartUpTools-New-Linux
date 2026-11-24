'use strict';
// テスト共通: 一時 ship home / テスト用ポリシー / 偽 GitHub
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

function tmpHome() {
  const d = fs.mkdtempSync(path.join(os.tmpdir(), 'ship-test-'));
  process.env.CLAUDEOS_SHIP_HOME = d;
  return d;
}

function testPolicy(over = {}) {
  const base = JSON.parse(fs.readFileSync(path.join(__dirname, '..', '..', '..', 'config', 'ship-policy.json'), 'utf8'));
  const p = { ...base, ...over };
  p.humanGate = { ...base.humanGate, ...(over.humanGate || {}) };
  p.merge = { ...base.merge, ...(over.merge || {}) };
  p.quality = { ...base.quality, ...(over.quality || {}) };
  p.ship = { ...base.ship, ...(over.ship || {}) };
  return p;
}

const H1 = 'a'.repeat(40); const H2 = 'b'.repeat(40); const B1 = 'c'.repeat(40); const B2 = 'd'.repeat(40);

function fakePr(over = {}) {
  return { number: 7, state: 'OPEN', isDraft: false, mergeable: 'MERGEABLE', mergeStateStatus: 'CLEAN',
    headRefOid: H1, headRefName: 'feat/x', baseRefOid: B1, baseRefName: 'main', url: 'https://github.com/o/r/pull/7', title: 't',
    statusChecks: [{ name: 'linux-validate', conclusion: 'SUCCESS' }], reviewThreadsUnresolved: 0, autoMerge: false, mergeCommit: null, ...over };
}

function fakeGh({ pr = fakePr(), contexts = ['claudeos/human-approval', 'claudeos/local-quality'], enableOk = true, afterEnable } = {}) {
  const calls = [];
  let current = pr;
  return {
    calls,
    set(p) { current = p; },
    fetchPr(repo, n) { calls.push(['fetchPr', repo, n]); return current ? { ok: true, data: current } : { ok: false, error: 'GH_UNAVAILABLE' }; },
    rulesetRequiredContexts() { calls.push(['ruleset']); return contexts ? { ok: true, data: contexts.map((c) => ({ context: c })) } : { ok: false, error: 'GH_AUTH' }; },
    enableAutoMerge(repo, n, head) { calls.push(['enableAutoMerge', repo, n, head]); if (afterEnable) current = afterEnable(current); return enableOk ? { ok: true } : { ok: false, error: 'GH_ERROR' }; },
    disableAutoMerge(repo, n) { calls.push(['disableAutoMerge', repo, n]); return { ok: true }; },
  };
}

module.exports = { tmpHome, testPolicy, fakePr, fakeGh, H1, H2, B1, B2 };
