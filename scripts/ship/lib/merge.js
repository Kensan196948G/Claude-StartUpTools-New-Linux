'use strict';
/**
 * merge.js — Merge Executor (人間承認後の GitHub 自動マージ)
 *
 * GitHub 側の強制 (二重化の外側):
 *   - Commit Status は SHA ごとに付く。承認コマンドが head SHA に `claudeos/human-approval=success` を付けるため、
 *     承認後に head が 1 つでも変われば新 SHA には承認ステータスが無く、GitHub はマージしない (SHA 固定が GitHub ネイティブ)
 *   - ruleset の strict_required_status_checks_policy=true により base が進めば update-branch が必要 → head が変わる → 再承認
 *   - ruleset が `claudeos/human-approval` と `claudeos/local-quality` を必須にしていることを、登録前に API で確認する
 *     (していなければ auto-merge を登録しない。登録 = 即マージになり得るため)
 *
 * ClaudeOS 側の強制 (二重化の内側): 署名検証・gate PASS・ローカル品質 PASS・中央ポリシー施行フラグ。
 */

const store = require('./store');
const hg = require('./human-gate');
const quality = require('./quality');
const github = require('./github');

function preflight({ repo, pr, policy, gh = github, now = new Date() }) {
  const reasons = [];
  const facts = {};
  const p = gh.fetchPr(repo, pr);
  if (!p.ok) return { ok: false, blocked: true, reasons: ['PR_FETCH: ' + p.error], facts };
  const d = p.data; facts.pr = d;
  if (d.state !== 'OPEN') reasons.push('PR_NOT_OPEN (' + d.state + ')');
  if (d.isDraft) reasons.push('PR_DRAFT');
  if (d.mergeable === 'CONFLICTING' || d.mergeStateStatus === 'DIRTY') reasons.push('MERGE_CONFLICT');
  if (!(policy.merge.allowedBaseBranches || []).includes(d.baseRefName)) reasons.push('BASE_NOT_ALLOWED (' + d.baseRefName + ')');

  // 中央ポリシー施行 (人間が承認・反映するまで false。false の間は登録しない)
  if (policy.merge.centralProfileEnforced !== true) reasons.push('CENTRAL_POLICY_PROFILE_NOT_ENFORCED (中央 GITHUB_POLICY の Ship Native プロファイル施行待ち)');

  // ruleset が ClaudeOS の 2 つの context を必須にしているか
  const rc = gh.rulesetRequiredContexts(repo, d.baseRefName);
  if (!rc.ok) reasons.push('RULESET_UNREADABLE: ' + rc.error);
  else {
    const ctx = new Set(rc.data.map((c) => c.context));
    facts.required_contexts = [...ctx];
    for (const need of [policy.humanGate.statusContext, policy.quality.statusContext]) {
      if (!ctx.has(need)) reasons.push('RULESET_DOES_NOT_REQUIRE ' + need + ' (auto-merge 登録が人間承認前のマージになり得る)');
    }
  }

  // AI Quality Gate (現 head)
  const gate = store.readRecord(store.paths.gate(repo, pr, d.headRefOid));
  facts.gate = gate ? { verdict: gate.verdict, risk: gate.risk } : null;
  if (!gate) reasons.push('NO_GATE_FOR_HEAD');
  else {
    if (gate.verdict !== 'PASS') reasons.push('GATE_NOT_PASS (' + gate.verdict + ')');
    if (gate.base_sha !== d.baseRefOid) reasons.push('GATE_BASE_STALE');
  }

  // ローカル品質 (現 head・封印検証)
  const q = quality.latestEvidence(repo, d.headRefOid);
  facts.quality = q.evidence ? { eval_id: q.evidence.eval_id, verdict: q.evidence.verdict } : null;
  if (!q.evidence || q.evidence.verdict !== 'PASS') reasons.push('LOCAL_QUALITY_NOT_PASS');

  // 人間承認 (現 head / base、gate hash 一致、未使用 nonce、未取り消し、未期限切れ、信頼鍵)
  const found = hg.findValidApproval(repo, pr, { policy, headSha: d.headRefOid, baseSha: d.baseRefOid, gate, now });
  facts.approval_checks = found.results;
  if (!found.approval) reasons.push('NO_VALID_HUMAN_APPROVAL');
  facts.approval_id = found.approval ? found.approval.approval_id : null;

  // GitHub 側チェック (外部のもの)。失敗があれば登録しない
  const own = new Set([policy.humanGate.statusContext, policy.quality.statusContext]);
  const failing = (d.statusChecks || []).filter((c) => !own.has(c.name) && ['FAILURE', 'ERROR', 'CANCELLED', 'TIMED_OUT'].includes(String(c.conclusion || '').toUpperCase()));
  if (failing.length) reasons.push('REQUIRED_CHECKS_FAILING: ' + failing.map((c) => c.name).join(','));

  return { ok: reasons.length === 0, reasons, facts, approval: found.approval };
}

/**
 * execute — preflight → nonce 消費 → auto-merge 登録 → 結果の再取得。
 * MERGED は API で merged を確認できた場合だけ記録する。
 */
function execute({ repo, pr, policy, gh = github, now = new Date(), dryRun = false }) {
  const lock = store.withLock(`merge-${store.slug(repo)}-${pr}`, () => {
    const pf = preflight({ repo, pr, policy, gh, now });
    if (!pf.ok) {
      store.appendAudit('merge_refused', { repo, pr, reasons: pf.reasons });
      return { state: 'REFUSED', reasons: pf.reasons, facts: pf.facts };
    }
    if (dryRun) return { state: 'DRY_RUN_OK', facts: pf.facts };
    const head = pf.facts.pr.headRefOid;
    hg.consume(pf.approval);
    const r = gh.enableAutoMerge(repo, pr, head);
    if (!r.ok) {
      store.appendAudit('merge_enable_failed', { repo, pr, head_sha: head, error: r.error });
      return { state: 'FAILED', reasons: ['ENABLE_AUTO_MERGE: ' + r.error], facts: pf.facts };
    }
    store.appendAudit('merge_queued', { repo, pr, head_sha: head, approval_id: pf.approval.approval_id });
    const rec = confirm({ repo, pr, gh, expectHead: head });
    return { ...rec, approval_id: pf.approval.approval_id };
  });
  if (!lock.locked) return { state: 'BUSY', reasons: ['ANOTHER_MERGE_IN_PROGRESS pid=' + lock.holder] };
  return lock.value;
}

/** confirm — GitHub を再取得してマージ結果を記録 (merged の確認が取れない限り MERGED にしない) */
function confirm({ repo, pr, gh = github, expectHead = null }) {
  const p = gh.fetchPr(repo, pr);
  const rec = { schema: store.SCHEMA.merge, repo, pr: Number(pr), at: new Date().toISOString(), expected_head: expectHead };
  if (!p.ok) Object.assign(rec, { state: 'UNKNOWN', confirmed: false, reason: p.error });
  else if (p.data.state === 'MERGED' && /^[0-9a-f]{40}$/.test(String(p.data.mergeCommit || ''))) {
    Object.assign(rec, { state: 'MERGED', confirmed: true, merge_commit_sha: p.data.mergeCommit, head_sha: p.data.headRefOid });
    if (expectHead && p.data.headRefOid !== expectHead) Object.assign(rec, { state: 'MERGED_UNEXPECTED_HEAD', confirmed: true });
  } else if (p.data.state === 'MERGED') {
    // merged と言うが merge commit を確認できない → MERGED と記録しない
    Object.assign(rec, { state: 'MERGED_UNCONFIRMED', confirmed: false, head_sha: p.data.headRefOid, reason: 'NO_MERGE_COMMIT' });
  } else if (p.data.autoMerge) Object.assign(rec, { state: 'MERGE_QUEUED', confirmed: false, head_sha: p.data.headRefOid });
  else Object.assign(rec, { state: p.data.state, confirmed: false, head_sha: p.data.headRefOid });
  store.writeRecord(store.paths.merge(repo, pr), rec);
  store.appendAudit('merge_observed', { repo, pr, state: rec.state, merge_commit_sha: rec.merge_commit_sha || null });
  return rec;
}

module.exports = { preflight, execute, confirm };
