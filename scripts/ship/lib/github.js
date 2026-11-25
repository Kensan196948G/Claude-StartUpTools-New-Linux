'use strict';
/**
 * github.js — GitHub アダプタ (gh CLI 経由。CLAUDEOS_SHIP_GH_BIN で差し替え可能 = テスト用)
 *
 * 取得した事実は「GitHub から取得」として扱い、Ship 出力やローカル証跡と混ぜない。
 * 取得できない値は null を返し、呼び出し側で UNKNOWN として扱う。
 */

const { spawnSync } = require('node:child_process');
const store = require('./store');

function ghBin() { return process.env.CLAUDEOS_SHIP_GH_BIN || 'gh'; }

function gh(args, { input, env } = {}) {
  const r = spawnSync(ghBin(), args, { encoding: 'utf8', input, env: { ...process.env, ...(env || {}) }, maxBuffer: 32 * 1024 * 1024, timeout: 120000 });
  return { status: r.status, stdout: r.stdout || '', stderr: store.redact(r.stderr || ''), error: r.error ? r.error.code : null };
}

function ghJson(args, opts) {
  const r = gh(args, opts);
  if (r.status !== 0) return { ok: false, error: classifyError(r), detail: r.stderr.slice(0, 300) };
  try { return { ok: true, data: JSON.parse(r.stdout) }; } catch { return { ok: false, error: 'PARSE' }; }
}

function classifyError(r) {
  const s = r.stderr || '';
  if (r.error === 'ENOENT') return 'GH_NOT_INSTALLED';
  if (/HTTP 401|Bad credentials|not logged in|authentication/i.test(s)) return 'GH_AUTH';
  if (/rate limit|HTTP 429|secondary rate/i.test(s)) return 'GH_RATE_LIMIT';
  if (/HTTP 5\d\d|Service Unavailable|timeout|could not resolve|connection/i.test(s)) return 'GH_UNAVAILABLE';
  if (/HTTP 404|Could not resolve to a/i.test(s)) return 'GH_NOT_FOUND';
  return 'GH_ERROR';
}

// gh 2.45 (Ubuntu 24.04 の apt 版) で使えるフィールドだけを指定する。baseRefOid は GraphQL で取る
const PR_FIELDS = 'number,state,isDraft,mergeable,mergeStateStatus,headRefOid,headRefName,baseRefName,url,title,author,statusCheckRollup,mergeCommit,autoMergeRequest';

/** fetchPr(repo, n) → 正規化した PR (statusChecks / reviewThreadsUnresolved を含む) */
function fetchPr(repo, n) {
  store.assertRepo(repo); store.assertPr(n);
  const r = ghJson(['pr', 'view', String(n), '--repo', repo, '--json', PR_FIELDS]);
  if (!r.ok) return r;
  const d = r.data;
  const statusChecks = (d.statusCheckRollup || []).map((c) => ({
    name: c.name || c.context, context: c.context || c.name,
    status: c.status || c.state || null, conclusion: c.conclusion || (c.state && ['SUCCESS', 'FAILURE', 'ERROR'].includes(c.state) ? c.state : null),
  }));
  // baseRefOid は gh 2.45 の `pr view --json` に無い (2026-11-24 実機)。GraphQL で取得する
  const extra = fetchGraphqlExtra(repo, n);
  if (!extra.ok) return { ok: false, error: extra.error || 'GRAPHQL_FAILED' };
  if (extra.headRefOid && extra.headRefOid !== d.headRefOid) return { ok: false, error: 'HEAD_RACE' }; // 2 回の取得の間に push された
  return { ok: true, data: {
    number: d.number, state: d.state, isDraft: d.isDraft, mergeable: d.mergeable, mergeStateStatus: d.mergeStateStatus,
    headRefOid: d.headRefOid, headRefName: d.headRefName, baseRefOid: extra.baseRefOid, baseRefName: d.baseRefName,
    url: d.url, title: d.title, author: d.author && d.author.login, statusChecks,
    mergeCommit: d.mergeCommit && d.mergeCommit.oid, autoMerge: !!d.autoMergeRequest,
    reviewThreadsUnresolved: extra.unresolved,
  } };
}

/** fetchGraphqlExtra — baseRefOid / headRefOid / 未解決レビュースレッド数 (取れなければ null = UNKNOWN) */
function fetchGraphqlExtra(repo, n) {
  const [owner, name] = repo.split('/');
  const q = 'query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){pullRequest(number:$n){baseRefOid headRefOid reviewThreads(first:100){totalCount nodes{isResolved}}}}}';
  const r = ghJson(['api', 'graphql', '-f', `query=${q}`, '-F', `o=${owner}`, '-F', `r=${name}`, '-F', `n=${n}`]);
  if (!r.ok) return { ok: false, error: r.error };
  const pr = ((r.data.data || {}).repository || {}).pullRequest;
  if (!pr || !/^[0-9a-f]{40}$/.test(String(pr.baseRefOid || ''))) return { ok: false, error: 'BASE_OID_UNAVAILABLE' };
  const t = pr.reviewThreads;
  // 100 件を超えると数え切れないため UNKNOWN
  const unresolved = t && t.totalCount <= 100 ? t.nodes.filter((x) => !x.isResolved).length : null;
  return { ok: true, baseRefOid: pr.baseRefOid, headRefOid: pr.headRefOid || null, unresolved };
}

/**
 * changedFiles(repo, n) — PR の変更ファイル一覧 (リスク分類の入力)。
 * REST の pulls/{n}/files を使い、リネームは**変更前のパスも含める** (API が previous_filename を返す場合)。
 * gh pr view --json files は新しいパスしか返さないため、指示書 (R2) を docs/ (R0) へリネームすると
 * 低いリスクに見えてしまう (2026-11-25 /ship 237 の指摘)。旧パスも分類すれば、最大値で R2 以上になる。
 * GitHub の上限は 3000 件。changed_files と件数が合わない (取り切れない) 場合は失敗として返し、
 * 呼び出し側は安全側 (R4) で扱う。
 */
function changedFiles(repo, n) {
  try { store.assertRepo(repo); store.assertPr(n); } catch { return { ok: false, error: 'INVALID_ARGS' }; }
  const r = ghJson(['api', '--paginate', '--slurp', `repos/${repo}/pulls/${n}/files?per_page=100`]);
  if (!r.ok) return r;
  const entries = (Array.isArray(r.data) ? r.data : []).flat();
  if (!entries.every((f) => f && typeof f.filename === 'string')) return { ok: false, error: 'PARSE' };
  const total = ghJson(['api', `repos/${repo}/pulls/${n}`, '--jq', '{changed_files}']);
  if (!total.ok) return total;
  if (Number(total.data.changed_files) !== entries.length) {
    return { ok: false, error: 'FILES_INCOMPLETE', detail: `listed=${entries.length} changed_files=${total.data.changed_files}` };
  }
  const out = [];
  for (const f of entries) {
    out.push(f.filename);
    if (typeof f.previous_filename === 'string' && f.previous_filename !== f.filename) out.push(f.previous_filename);
  }
  return { ok: true, data: [...new Set(out)] };
}

/** findPrForBranch(repo, branch) — 既存 PR の再利用 (重複作成防止) */
function findPrForBranch(repo, branch) {
  if (!/^[A-Za-z0-9._/-]{1,200}$/.test(branch)) return { ok: false, error: 'INVALID_BRANCH' };
  const r = ghJson(['pr', 'list', '--repo', repo, '--head', branch, '--state', 'open', '--json', 'number,headRefOid,url']);
  if (!r.ok) return r;
  return { ok: true, data: r.data };
}

/** rulesetRequiredContexts(repo, branch) — 対象ブランチに効く ruleset の必須 status context (取得不能なら null) */
function rulesetRequiredContexts(repo, branch = 'main') {
  const r = ghJson(['api', `repos/${repo}/rules/branches/${encodeURIComponent(branch)}`]);
  if (!r.ok) return { ok: false, error: r.error };
  const contexts = [];
  for (const rule of r.data || []) {
    if (rule.type === 'required_status_checks') {
      for (const c of (rule.parameters || {}).required_status_checks || []) contexts.push({ context: c.context, integration_id: c.integration_id || null });
    }
  }
  return { ok: true, data: contexts };
}

/** postStatus(repo, sha, {context, state, description, target_url}, token?) — Commit Status API */
function postStatus(repo, sha, s, { token } = {}) {
  store.assertRepo(repo); store.assertSha(sha);
  if (!['success', 'failure', 'pending', 'error'].includes(s.state)) throw new Error('INVALID_STATE');
  const args = ['api', '-X', 'POST', `repos/${repo}/statuses/${sha}`, '-f', `state=${s.state}`, '-f', `context=${s.context}`,
    '-f', `description=${String(s.description || '').slice(0, 140)}`];
  if (s.target_url) args.push('-f', `target_url=${s.target_url}`);
  // token は引数に載せず環境変数で渡す (ps から見えない)
  const r = gh(args, token ? { env: { GH_TOKEN: token, GITHUB_TOKEN: '' } } : {});
  return r.status === 0 ? { ok: true } : { ok: false, error: classifyError(r), detail: r.stderr.slice(0, 200) };
}

function enableAutoMerge(repo, n, headSha) {
  store.assertSha(headSha);
  // グローバルの kensan-auto-merge-guard が要求する形 (--auto --squash --match-head-commit <40hex>)
  const r = gh(['pr', 'merge', String(n), '--repo', repo, '--auto', '--squash', '--match-head-commit', headSha]);
  return r.status === 0 ? { ok: true } : { ok: false, error: classifyError(r), detail: r.stderr.slice(0, 300) };
}

function disableAutoMerge(repo, n) {
  const r = gh(['pr', 'merge', String(n), '--repo', repo, '--disable-auto']);
  return r.status === 0 ? { ok: true } : { ok: false, error: classifyError(r) };
}

function actionsRuns(repo, limit = 50) {
  return ghJson(['run', 'list', '--repo', repo, '--limit', String(limit), '--json', 'databaseId,workflowName,status,conclusion,createdAt,event,headSha']);
}

module.exports = { gh, ghJson, fetchPr, changedFiles, findPrForBranch, rulesetRequiredContexts, postStatus, enableAutoMerge, disableAutoMerge, actionsRuns, classifyError };
