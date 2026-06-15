#!/usr/bin/env node
/**
 * refresh-onboarding
 *
 * ONBOARDING.md の「揮発セクション」を実ソースから決定論的に再生成する。
 * `/team-onboarding`（プロンプト駆動コマンド）の補完として、Verify ループの
 * STABLE 達成フック `onboarding-refresh-on-stable` から確実な実体として呼ばれる。
 *
 * 再生成対象:
 *   §1 Goal / §2 KPI / §3 失敗パターン / §4 成功パターン / §11 再開ポイント
 *     → state.json があれば実値、無ければ「未取得」定型（陳腐化値を残さない）
 *   §5 Agent 件数 / §6 Command 件数  → ディレクトリ実数で件数行のみ更新（人手curated表は保持）
 *   §8 直近 Git 活動                 → git log から表を再生成
 *
 * 設計原則:
 *   - state.json は .gitignore 除外＝コミット上は常に不在。「不在フォールバック」が通常パス。
 *   - 現行 state スキーマの learning ブロックに failure_patterns / success_patterns は
 *     存在しない（usage_history / dead_weight のみ）。よって §3/§4 は state があっても
 *     当該フィールド欠損として「未取得」を返すのがスキーマ準拠の正しい挙動。
 *   - 人手で分類した §5/§6 のカテゴリ表は機械再生成せず、件数のみ追従させる。
 *
 * Exit 0 = 更新済み（または既に最新）, Exit 1 = エラー。
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const root = path.resolve(__dirname, '..');

// 未取得定型（斜体単行）。state.json 不在/欠損時に陳腐化値の代わりに置く。
const UNAVAILABLE = (reason) => `*未取得 — ${reason}*`;

/**
 * state.json 由来の任意文字列を Markdown へ安全に埋め込む形へ正規化する。
 *
 * replaceSectionBody は本文中の行頭 `## ` / `---` を「次セクション境界」と解釈するため、
 * 値に改行付き `## ...` や `---` が混入すると、次回 state 不在フォールバック時に
 * 置換がそこで止まり陳腐化行が残る（決定論・stale 排除要件の破れ）。
 * テーブルセル内の生改行も表崩れを招く。よって埋め込み前に:
 *   - 改行（CR/LF）を空白へ畳む → 行頭メタ文字によるセクション境界誤検出を根絶
 *   - `|` をエスケープ → テーブル崩れ防止
 *   - 連続空白を 1 個へ正規化し前後を trim
 * @param {*} value 任意値（null/undefined は空文字）
 * @returns {string} 単一行・セル安全な文字列
 */
function sanitizeCell(value) {
  if (value == null) return '';
  return String(value)
    .replace(/\r?\n/g, ' ')
    .replace(/\|/g, '\\|')
    .replace(/\s+/g, ' ')
    .trim();
}

/**
 * state.json テキストを安全に parse する。
 * @param {string|null} text ファイル全文。null/空なら null。
 * @returns {object|null} parse 成功時オブジェクト、失敗・不在時 null
 */
function parseState(text) {
  if (!text || !text.trim()) return null;
  try {
    const obj = JSON.parse(text);
    // 配列・プリミティブは state とみなさない（オブジェクトのみ受理）。
    return obj && typeof obj === 'object' && !Array.isArray(obj) ? obj : null;
  } catch {
    return null;
  }
}

/**
 * §1 Goal セクション本文を生成する。
 * @param {object|null} state
 * @returns {string} markdown 本文
 */
function renderGoalSection(state) {
  const goal = state && state.goal;
  if (!goal || !goal.title) {
    return UNAVAILABLE('state.json 未配置のため Goal 未設定。セッション開始時に /goal で設定される');
  }
  const exec = (state && state.execution) || {};
  const auto = (state && state.automation) || {};
  const mode = auto.self_evolution || auto.auto_issue_generation
    ? 'Auto Mode + Agent Teams'
    : '手動運用';
  const maxMin = exec.max_duration_minutes != null ? `${exec.max_duration_minutes} 分` : '未設定';
  const rows = [
    ['Goal Title', goal.title],
    ['Goal Description', goal.description || '（説明なし）'],
    ['運用モード', mode],
    ['最大作業時間', maxMin],
    ['現在フェーズ', exec.phase || '未設定'],
  ];
  return [
    '`state.json` から取得した現在値:',
    '',
    '| 項目 | 現在値 |',
    '|---|---|',
    ...rows.map(([k, v]) => `| ${k} | ${sanitizeCell(v)} |`),
  ].join('\n');
}

/**
 * §2 KPI セクション本文を生成する。
 * @param {object|null} state
 * @returns {string}
 */
function renderKpiSection(state) {
  const kpi = state && state.kpi;
  if (!kpi || kpi.success_rate_target == null) {
    return UNAVAILABLE('state.json 未配置のため KPI 未計測');
  }
  return [
    '| KPI | 目標値 | 現在値 |',
    '|---|---|---|',
    `| success_rate_target | ${sanitizeCell(kpi.success_rate_target)} | ${kpi.success_rate_current != null ? sanitizeCell(kpi.success_rate_current) : '未計測'} |`,
  ].join('\n');
}

/**
 * §3 失敗パターン本文を生成する。
 * 現行スキーマに learning.failure_patterns は無いため、存在時のみ列挙し、
 * 通常は「未取得」を返す。
 * @param {object|null} state
 * @returns {string}
 */
function renderFailureSection(state) {
  const patterns = state && state.learning && state.learning.failure_patterns;
  if (!Array.isArray(patterns) || patterns.length === 0) {
    return UNAVAILABLE('state.json.learning.failure_patterns 未記録。セッション進行で自動蓄積される');
  }
  return patterns.slice(0, 5).map((p, i) => `${i + 1}. ${sanitizeCell(typeof p === 'string' ? p : JSON.stringify(p))}`).join('\n');
}

/**
 * §4 成功パターン本文を生成する。
 * @param {object|null} state
 * @returns {string}
 */
function renderSuccessSection(state) {
  const patterns = state && state.learning && state.learning.success_patterns;
  if (!Array.isArray(patterns) || patterns.length === 0) {
    return UNAVAILABLE('state.json.learning.success_patterns 未記録');
  }
  return patterns.slice(0, 5).map((p, i) => `${i + 1}. ${sanitizeCell(typeof p === 'string' ? p : JSON.stringify(p))}`).join('\n');
}

/**
 * §11 再開ポイント本文を生成する。
 * @param {object|null} state
 * @returns {string}
 */
function renderResumeSection(state) {
  const exec = state && state.execution;
  if (!exec || !exec.phase || exec.phase === 'Idle') {
    return UNAVAILABLE('state.json 未配置 or 進行中セッションなし。Monitor フェーズから新規開始する');
  }
  const rows = [
    ['前回停止', exec.last_stop_at || '不明'],
    ['前回要約', exec.last_session_summary || '（記録なし）'],
    ['現在フェーズ', exec.phase],
    ['残時間', exec.remaining_minutes != null ? `${exec.remaining_minutes} 分` : '不明'],
  ];
  return [
    '`state.json.execution` より:',
    '',
    '| 項目 | 値 |',
    '|---|---|',
    ...rows.map(([k, v]) => `| ${k} | ${sanitizeCell(v)} |`),
  ].join('\n');
}

/**
 * §8 直近 Git 活動の表本文を生成する。
 * @param {Array<{hash:string, subject:string}>} commits
 * @param {string} activity 活動ラベル（'active' = HEAD あり / 'unknown' = git 取得不可）
 * @returns {string}
 */
function renderGitLogSection(commits, activity) {
  if (!Array.isArray(commits) || commits.length === 0) {
    // activity ラベルで文言を分岐: HEAD があるのに列挙が空（極稀な特殊状態）と
    // リポジトリ未初期化を取り違えないよう、原因の主語を一致させる。
    const reason = activity === 'active'
      ? 'git log 取得不可 — HEAD は存在するがコミット列挙が空'
      : 'git history 取得不可 — Git リポジトリ未初期化';
    return UNAVAILABLE(reason);
  }
  return [
    `（直近 ${commits.length} 件 / ${activity} 判定）`,
    '',
    '| Hash | 概要 |',
    '|---|---|',
    ...commits.map(c => `| ${sanitizeCell(c.hash)} | ${sanitizeCell(c.subject)} |`),
  ].join('\n');
}

/**
 * 既存 markdown の `## {sectionNum}.` 見出し配下の本文を newBody で差し替える。
 * 見出し行自体は保持し、次の `## ` 見出し or `---` 区切り or EOF までを置換する。
 * 見出しが見つからなければ原文を返す（破壊しない）。
 * @param {string} md 全文
 * @param {number} sectionNum セクション番号
 * @param {string} newBody 新しい本文（見出し行は含めない）
 * @returns {string}
 */
function replaceSectionBody(md, sectionNum, newBody) {
  const lines = md.split('\n');
  const headRe = new RegExp(`^## ${sectionNum}\\. `);
  const headIdx = lines.findIndex(l => headRe.test(l));
  if (headIdx === -1) return md;
  let endIdx = lines.length;
  for (let i = headIdx + 1; i < lines.length; i++) {
    if (/^## /.test(lines[i]) || /^---\s*$/.test(lines[i])) { endIdx = i; break; }
  }
  const rebuilt = [
    ...lines.slice(0, headIdx),
    lines[headIdx],
    '',
    newBody.replace(/\s+$/, ''),
    '',
    ...lines.slice(endIdx),
  ];
  return rebuilt.join('\n');
}

/**
 * `## {sectionNum}.` 見出し配下の範囲に限定して正規表現置換を行う。
 * replaceSectionBody と同じ境界スキャン（次の `## ` 見出し / `---` / EOF）で
 * 対象セクションのみを切り出し、その範囲内の最初の一致だけを置換する。
 * 全文 replace と異なり、他セクションに同形パターンが現れても誤爆しない。
 * @param {string} md 全文
 * @param {number} sectionNum セクション番号
 * @param {RegExp} re 置換対象（範囲内で一致を探す）
 * @param {string|function} replacement 置換文字列（$1 等の後方参照可）または置換関数。
 *   置換値に動的データを差し込む場合は関数形式が安全（$ 連番の誤解釈を受けない）。
 * @returns {string} 見出しが無い or 不一致なら原文をそのまま返す
 */
function replaceCountInSection(md, sectionNum, re, replacement) {
  const lines = md.split('\n');
  const headRe = new RegExp(`^## ${sectionNum}\\. `);
  const headIdx = lines.findIndex(l => headRe.test(l));
  if (headIdx === -1) return md;
  let endIdx = lines.length;
  for (let i = headIdx + 1; i < lines.length; i++) {
    if (/^## /.test(lines[i]) || /^---\s*$/.test(lines[i])) { endIdx = i; break; }
  }
  const before = lines.slice(0, headIdx + 1);
  const section = lines.slice(headIdx + 1, endIdx);
  const after = lines.slice(endIdx);
  const patched = section.join('\n').replace(re, replacement);
  return [...before, patched, ...after].join('\n');
}

/**
 * ONBOARDING.md 全文を入力に、揮発セクションを再生成した全文を返す（純粋関数）。
 * @param {string} md 既存 ONBOARDING.md
 * @param {object} ctx { state, agentCount, commandCount, commits, activity }
 * @returns {string} 再生成後の全文
 */
function refreshOnboarding(md, ctx) {
  const { state, agentCount, commandCount, commits, activity } = ctx;
  let out = md;

  // §1/§2/§3/§4/§11: state.json 由来（不在なら「未取得」）
  out = replaceSectionBody(out, 1, renderGoalSection(state));
  out = replaceSectionBody(out, 2, renderKpiSection(state));
  out = replaceSectionBody(out, 3, renderFailureSection(state));
  out = replaceSectionBody(out, 4, renderSuccessSection(state));
  out = replaceSectionBody(out, 11, renderResumeSection(state));

  // §5/§6: 件数行のみディレクトリ実数へ追従（人手 curated 表は保持）。
  // 全文 replace ではなく該当セクション範囲に限定し、他所の同形パターンを誤爆しない。
  // 置換は関数形式で行う: agentCount/commandCount に将来 `$` を含む値が来ても
  // String.replace の後方参照解釈を受けず、確実にリテラルとして差し込まれる。
  if (agentCount != null) {
    out = replaceCountInSection(out, 5, /(直下に \*\*)(\d+) (体\*\*)/, (_m, p1, _n, p3) => `${p1}${agentCount} ${p3}`);
  }
  if (commandCount != null) {
    out = replaceCountInSection(out, 6, /(直下に \*\*)(\d+) (個\*\*)/, (_m, p1, _n, p3) => `${p1}${commandCount} ${p3}`);
  }

  // §8: git log から表を再生成
  out = replaceSectionBody(out, 8, renderGitLogSection(commits, activity));

  return out;
}

module.exports = {
  sanitizeCell,
  parseState,
  renderGoalSection,
  renderKpiSection,
  renderFailureSection,
  renderSuccessSection,
  renderResumeSection,
  renderGitLogSection,
  replaceSectionBody,
  replaceCountInSection,
  refreshOnboarding,
};

// 直接実行されたときのみ ONBOARDING.md を書き換える（require 時は副作用なし）
if (require.main !== module) {
  return;
}

// --- Read sources ---
function readIfExists(p) {
  try {
    return fs.readFileSync(p, 'utf8');
  } catch {
    return null;
  }
}

function countMd(dir) {
  try {
    return fs.readdirSync(dir).filter(f => f.endsWith('.md')).length;
  } catch {
    return null;
  }
}

function gitLog(n) {
  try {
    // 短縮ハッシュ長をリポジトリ規模に依存させず固定（--abbrev=7）、
    // subject 内の空白に影響されないようタブ（%x09）区切りで取得する。
    const raw = execFileSync(
      'git',
      ['log', `-${n}`, '--no-color', '--abbrev=7', '--format=%h%x09%s'],
      { cwd: root, encoding: 'utf8' }
    ).trim();
    if (!raw) return [];
    return raw.split('\n').map(line => {
      const tab = line.indexOf('\t');
      return tab === -1
        ? { hash: line, subject: '' }
        : { hash: line.slice(0, tab), subject: line.slice(tab + 1) };
    });
  } catch {
    return [];
  }
}

// 取得するコミット件数（ONBOARDING §8 は直近 N 件を表示する慣例）。
const GIT_LOG_COUNT = 12;

/**
 * §8 用の活動ラベルを返す。
 * 経過時間の厳密判定は Date 不可（リポジトリ規約）かつ state.execution の責務のため、
 * ここでは「HEAD コミットが存在するか」のみを事実として返す。
 *   - 'active'  : HEAD あり（コミット履歴が存在する通常リポジトリ）
 *   - 'unknown' : git 取得不可（未初期化 / HEAD 無し）
 * 取得件数は呼び出し側が定数 GIT_LOG_COUNT を直接渡す（本関数は件数を持たない）。
 * @returns {string} 'active' | 'unknown'
 */
function gitActivity() {
  try {
    const head = execFileSync('git', ['rev-parse', '--verify', 'HEAD'], { cwd: root, encoding: 'utf8' }).trim();
    return head ? 'active' : 'unknown';
  } catch {
    return 'unknown';
  }
}

const onboardingPath = path.join(root, 'ONBOARDING.md');
const existing = readIfExists(onboardingPath);
if (existing == null) {
  console.error('ONBOARDING.md が見つかりません。先に /team-onboarding で初期生成してください。');
  process.exit(1);
}

const state = parseState(readIfExists(path.join(root, 'state.json')));
const agentCount = countMd(path.join(root, '.claude', 'claudeos', 'agents'));
const commandCount = countMd(path.join(root, '.claude', 'claudeos', 'commands'));
const activity = gitActivity();
const commits = gitLog(GIT_LOG_COUNT);

const updated = refreshOnboarding(existing, { state, agentCount, commandCount, commits, activity });

console.log(
  `Source — state.json: ${state ? 'present' : 'absent'}, agents: ${agentCount}, commands: ${commandCount}, commits: ${commits.length} (${activity})`
);

if (updated === existing) {
  console.log('ONBOARDING.md already up-to-date — no changes written.');
  process.exit(0);
}

fs.writeFileSync(onboardingPath, updated, 'utf8');
console.log(`ONBOARDING.md refreshed — state=${state ? 'present' : 'absent(未取得)'}, agents=${agentCount}, commands=${commandCount}, commits=${commits.length}`);
process.exit(0);
