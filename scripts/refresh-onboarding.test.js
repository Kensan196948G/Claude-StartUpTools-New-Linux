'use strict';
/**
 * refresh-onboarding の純粋関数 単体テスト。
 * `node --test`（npm run test:node）で実行される。
 * Issue #17: ONBOARDING.md Verify 連動 自動再生成フックの決定論実体。
 *
 * 受入れ条件のうち本テストが守る不変条件:
 *   - state.json があれば実値を埋める
 *   - state.json 不在/欠損でも陳腐化した旧値を残さず「未取得」定型へ落ちる
 *   - 見出し配下のみ差し替え、他セクションを破壊しない
 */

const { test } = require('node:test');
const assert = require('node:assert/strict');

const {
  parseState,
  renderGoalSection,
  renderKpiSection,
  renderFailureSection,
  renderSuccessSection,
  renderResumeSection,
  renderGitLogSection,
  replaceSectionBody,
  refreshOnboarding,
} = require('./refresh-onboarding.js');

// --- parseState ---

test('parseState: 空文字 / null は null を返す', () => {
  assert.equal(parseState(''), null);
  assert.equal(parseState('   '), null);
  assert.equal(parseState(null), null);
});

test('parseState: 不正 JSON は throw せず null を返す', () => {
  assert.equal(parseState('{ not json'), null);
});

test('parseState: 配列やプリミティブではなくオブジェクトのみ受理する', () => {
  assert.deepEqual(parseState('{"goal":{"title":"x"}}'), { goal: { title: 'x' } });
  // JSON としては valid だがオブジェクトでない値
  assert.equal(parseState('42'), null);
  assert.equal(parseState('"str"'), null);
});

// --- renderGoalSection ---

test('renderGoalSection: state 不在なら「未取得」定型（陳腐化値を残さない）', () => {
  const body = renderGoalSection(null);
  assert.match(body, /未取得/);
  assert.doesNotMatch(body, /ClaudeOS v8/); // 旧リポジトリの陳腐化値が混入しないこと
});

test('renderGoalSection: goal.title があれば実値テーブルを生成する', () => {
  const state = {
    goal: { title: 'My Goal', description: 'desc' },
    execution: { phase: 'Monitor', max_duration_minutes: 300 },
    automation: { self_evolution: true },
  };
  const body = renderGoalSection(state);
  assert.match(body, /My Goal/);
  assert.match(body, /desc/);
  assert.match(body, /Auto Mode \+ Agent Teams/);
  assert.match(body, /300 分/);
  assert.match(body, /Monitor/);
});

test('renderGoalSection: automation フラグ無しは「手動運用」', () => {
  const state = { goal: { title: 'G' }, execution: {}, automation: {} };
  assert.match(renderGoalSection(state), /手動運用/);
});

// --- renderKpiSection ---

test('renderKpiSection: state 不在なら「未取得」', () => {
  assert.match(renderKpiSection(null), /未取得/);
});

test('renderKpiSection: target があれば現在値も埋める / 欠損は「未計測」', () => {
  assert.match(renderKpiSection({ kpi: { success_rate_target: 0.9, success_rate_current: 0.8 } }), /0\.9 \| 0\.8/);
  assert.match(renderKpiSection({ kpi: { success_rate_target: 0.9 } }), /0\.9 \| 未計測/);
});

// --- renderFailureSection / renderSuccessSection ---

test('renderFailureSection: 現行スキーマに無いフィールドは「未取得」', () => {
  // state があっても learning.failure_patterns は現行スキーマに存在しない
  assert.match(renderFailureSection({ learning: { usage_history: [] } }), /未取得/);
  assert.match(renderFailureSection(null), /未取得/);
});

test('renderFailureSection: パターン配列があれば番号付き列挙（最大5件）', () => {
  const state = { learning: { failure_patterns: ['a', 'b', 'c', 'd', 'e', 'f'] } };
  const body = renderFailureSection(state);
  assert.match(body, /^1\. a$/m);
  assert.match(body, /^5\. e$/m);
  assert.doesNotMatch(body, /^6\. /m); // 5件で打ち切り
});

test('renderSuccessSection: 不在は「未取得」/ 配列は列挙', () => {
  assert.match(renderSuccessSection(null), /未取得/);
  assert.match(renderSuccessSection({ learning: { success_patterns: ['win'] } }), /^1\. win$/m);
});

// --- renderResumeSection ---

test('renderResumeSection: Idle / 不在は「未取得」', () => {
  assert.match(renderResumeSection(null), /未取得/);
  assert.match(renderResumeSection({ execution: { phase: 'Idle' } }), /未取得/);
});

test('renderResumeSection: 進行中フェーズなら execution 実値を埋める', () => {
  const state = {
    execution: {
      phase: 'Verify',
      last_stop_at: '2026-06-15T00:00:00Z',
      last_session_summary: 'done',
      remaining_minutes: 120,
    },
  };
  const body = renderResumeSection(state);
  assert.match(body, /Verify/);
  assert.match(body, /2026-06-15T00:00:00Z/);
  assert.match(body, /done/);
  assert.match(body, /120 分/);
});

// --- renderGitLogSection ---

test('renderGitLogSection: コミット無しは「未取得」', () => {
  assert.match(renderGitLogSection([], 'active'), /未取得/);
  assert.match(renderGitLogSection(null, 'active'), /未取得/);
});

test('renderGitLogSection: パイプ文字をエスケープして表崩れを防ぐ', () => {
  const commits = [{ hash: 'abc1234', subject: 'feat: a | b' }];
  const body = renderGitLogSection(commits, 'active');
  assert.match(body, /abc1234/);
  assert.match(body, /a \\\| b/); // | が \| にエスケープされる
});

// --- replaceSectionBody ---

const SAMPLE = [
  '# Title',
  '',
  '## 1. Goal',
  '',
  'OLD GOAL BODY',
  '',
  '## 2. KPI',
  '',
  'OLD KPI BODY',
  '',
  '---',
  '',
  '## 11. Resume',
  '',
  'OLD RESUME',
].join('\n');

test('replaceSectionBody: 該当見出し配下のみ差し替え、他セクションは保持', () => {
  const out = replaceSectionBody(SAMPLE, 1, 'NEW GOAL');
  assert.match(out, /## 1\. Goal\n\nNEW GOAL/);
  assert.doesNotMatch(out, /OLD GOAL BODY/);
  assert.match(out, /OLD KPI BODY/); // §2 は無傷
});

test('replaceSectionBody: 次の見出しが無い末尾セクションも差し替えできる', () => {
  const out = replaceSectionBody(SAMPLE, 11, 'NEW RESUME');
  assert.match(out, /## 11\. Resume\n\nNEW RESUME/);
  assert.doesNotMatch(out, /OLD RESUME/);
});

test('replaceSectionBody: 見出しが見つからなければ原文を破壊しない', () => {
  assert.equal(replaceSectionBody(SAMPLE, 99, 'X'), SAMPLE);
});

test('replaceSectionBody: --- 区切りを越えて隣接セクションを侵食しない', () => {
  const out = replaceSectionBody(SAMPLE, 2, 'NEW KPI');
  assert.match(out, /NEW KPI/);
  assert.match(out, /^---$/m); // 区切りは残る
  assert.match(out, /## 11\. Resume/); // 区切り後のセクションは無傷
});

// --- refreshOnboarding（統合：純粋関数合成） ---

test('refreshOnboarding: state 不在で §1/§2/§11 が全て「未取得」へ落ちる', () => {
  const md = [
    '## 1. Goal', '', 'ClaudeOS v8 自律開発最適化', '',
    '## 2. KPI', '', '0.9（旧値）', '',
    '## 11. Resume', '', 'v3.2.23 (PR #175)',
  ].join('\n');
  const out = refreshOnboarding(md, {
    state: null, agentCount: null, commandCount: null, commits: [], activity: 'unknown',
  });
  assert.doesNotMatch(out, /ClaudeOS v8/);
  assert.doesNotMatch(out, /PR #175/);
  assert.equal((out.match(/未取得/g) || []).length >= 3, true);
});

test('refreshOnboarding: 件数行は実数へ追従する', () => {
  const md = [
    '## 5. Agents', '', '`dir` 直下に **43 体** の…', '',
    '## 6. Commands', '', '`dir` 直下に **42 個** の…',
  ].join('\n');
  const out = refreshOnboarding(md, {
    state: null, agentCount: 50, commandCount: 38, commits: [], activity: 'unknown',
  });
  assert.match(out, /\*\*50 体\*\*/);
  assert.match(out, /\*\*38 個\*\*/);
  assert.doesNotMatch(out, /\*\*43 体\*\*/);
});

test('refreshOnboarding: agentCount=null のとき件数行を書き換えない', () => {
  const md = '## 5. Agents\n\n`dir` 直下に **43 体** の…';
  const out = refreshOnboarding(md, {
    state: null, agentCount: null, commandCount: null, commits: [], activity: 'unknown',
  });
  assert.match(out, /\*\*43 体\*\*/); // null は「不明＝触らない」
});
