'use strict';
/**
 * quality-gate.js — ClaudeOS AI Quality Gate
 *
 * Anthropic 公式の Claude Approvals ではない。ClaudeOS 独自の品質判定。
 * 判定は決定的な規則で行い、AI (Ship / /code-review) の所見は入力の 1 つに過ぎない。
 *
 * evaluate(inputs, policy) → { verdict: PASS|CONDITIONAL|FAIL|UNKNOWN|BLOCKED, reasons[], checks[] }
 *
 * inputs:
 *   pr        { state, isDraft, mergeable, mergeStateStatus, headRefOid, baseRefOid, baseRefName,
 *               reviewThreadsUnresolved, statusChecks:[{name,conclusion,status}] } (GitHub から取得)
 *   headSha   判定対象 (= 承認対象) の head
 *   baseSha   判定対象の base
 *   quality   Local Quality Engine の封印済み証跡 (latestEvidence) と sealOk
 *   ship      { required, capability, reviewed: true|false|null, importantFindingsOpen: n|null,
 *               watchStatus, source } — 取得できないものは null (= UNKNOWN 扱い)
 *   risk      risk.classify の結果
 *   requirements { status: 'met'|'partial'|'unknown', notes } — 要件充足 (run の intent に対する自己申告ではなく人が読む報告書へ回す)
 *   residual  残存課題の配列
 *
 * 規則の優先順位: BLOCKED (外部・権限) > FAIL (明確な不合格) > UNKNOWN (証跡不足) > CONDITIONAL (人の判断要) > PASS
 * 自動マージの前提として扱えるのは PASS のみ。PASS は人間の承認を意味しない。
 */

const ORDER = ['PASS', 'CONDITIONAL', 'UNKNOWN', 'FAIL', 'BLOCKED'];

function worst(a, b) { return ORDER.indexOf(a) >= ORDER.indexOf(b) ? a : b; }

function evaluate(inputs, policy) {
  const checks = [];
  let verdict = 'PASS';
  const add = (id, result, detail) => {
    checks.push({ id, result, detail });
    verdict = worst(verdict, result);
  };
  const { pr, headSha, baseSha, quality, ship, risk } = inputs;

  // --- PR 状態 (GitHub 事実) ---
  if (!pr) add('pr.fetched', 'BLOCKED', 'PR 情報を GitHub から取得できない');
  else {
    add('pr.open', pr.state === 'OPEN' ? 'PASS' : 'FAIL', `state=${pr.state}`);
    add('pr.not_draft', pr.isDraft ? 'FAIL' : 'PASS', `isDraft=${pr.isDraft}`);
    add('pr.head_match', pr.headRefOid === headSha ? 'PASS' : 'FAIL', `pr.head=${pr.headRefOid} target=${headSha}`);
    if (baseSha) add('pr.base_match', pr.baseRefOid === baseSha ? 'PASS' : 'FAIL', `pr.base=${pr.baseRefOid} target=${baseSha}`);
    else add('pr.base_known', 'UNKNOWN', 'base SHA が未指定');
    const allowed = (policy.merge.allowedBaseBranches || []).includes(pr.baseRefName);
    add('pr.base_branch_allowed', allowed ? 'PASS' : 'FAIL', `base=${pr.baseRefName}`);
    if (pr.mergeable === 'CONFLICTING' || pr.mergeStateStatus === 'DIRTY') add('pr.no_conflict', 'FAIL', 'マージ競合');
    else if (pr.mergeable === 'MERGEABLE') add('pr.no_conflict', 'PASS', '');
    else add('pr.no_conflict', 'UNKNOWN', `mergeable=${pr.mergeable}`);
    if (pr.reviewThreadsUnresolved == null) add('pr.review_threads', 'UNKNOWN', '未解決スレッド数を取得できない');
    else add('pr.review_threads', pr.reviewThreadsUnresolved === 0 ? 'PASS' : 'FAIL', `unresolved=${pr.reviewThreadsUnresolved}`);
    // GitHub 側のチェック (必須チェックの結果は最終的に GitHub が強制する。ここでは失敗の早期検出)
    const sc = Array.isArray(pr.statusChecks) ? pr.statusChecks : [];
    const failing = sc.filter((c) => ['FAILURE', 'ERROR', 'CANCELLED', 'TIMED_OUT', 'ACTION_REQUIRED'].includes(String(c.conclusion || c.state || '').toUpperCase()));
    const pending = sc.filter((c) => ['PENDING', 'QUEUED', 'IN_PROGRESS', 'EXPECTED'].includes(String(c.status || c.state || '').toUpperCase()) && !c.conclusion);
    // ClaudeOS 自身が出す 2 つの context (品質・承認) は判定の循環を避けて除外する
    const own = new Set([policy.quality.statusContext, policy.humanGate.statusContext]);
    const failingExt = failing.filter((c) => !own.has(c.name || c.context));
    const pendingExt = pending.filter((c) => !own.has(c.name || c.context));
    if (failingExt.length) add('github.checks', 'FAIL', 'failing: ' + failingExt.map((c) => c.name || c.context).join(', '));
    else if (pendingExt.length) add('github.checks', 'UNKNOWN', 'pending: ' + pendingExt.map((c) => c.name || c.context).join(', '));
    else add('github.checks', 'PASS', `${sc.length} checks`);
  }

  // --- Local Quality Engine ---
  if (policy.quality.requireLocalQuality) {
    const ev = quality && quality.evidence;
    if (!ev) add('local.evidence', 'UNKNOWN', `head ${headSha} の封印済み証跡がない${quality && quality.rejected && quality.rejected.length ? ` (改ざん/不一致で除外 ${quality.rejected.length} 件)` : ''}`);
    else if (ev.head_sha !== headSha) add('local.evidence', 'FAIL', '証跡の SHA が対象と不一致');
    else {
      add('local.evidence', 'PASS', `eval=${ev.eval_id}`);
      add('local.verdict', ev.verdict === 'PASS' ? 'PASS' : ev.verdict === 'FAIL' ? 'FAIL' : 'UNKNOWN', `verdict=${ev.verdict}`);
      if (baseSha && ev.base_sha && ev.base_sha !== baseSha) add('local.base_current', policy.humanGate.baseChangePolicy === 'invalidate' ? 'UNKNOWN' : 'CONDITIONAL', `証跡 base=${ev.base_sha} 現在 base=${baseSha} (再検証が必要)`);
      const secrets = (ev.checks || []).find((c) => c.category === 'secrets');
      if (!secrets) add('local.secrets', 'UNKNOWN', 'シークレット検査の証跡がない');
      else add('local.secrets', secrets.status === 'PASS' ? 'PASS' : secrets.status === 'FAIL' ? 'FAIL' : 'UNKNOWN', secrets.status);
    }
  }

  // --- Ship レビュー ---
  const riskLevel = risk && risk.level;
  const shipRequired = !!(policy.ship.required || (policy.ship.requiredForRisk || []).includes(riskLevel));
  if (!ship || ship.reviewed == null) {
    if (shipRequired) add('ship.reviewed', policy.ship.fallbackReviewAllowed ? 'CONDITIONAL' : 'UNKNOWN', 'Ship レビューの証跡がない (Ship 必須)');
    else add('ship.reviewed', 'CONDITIONAL', 'Ship レビュー未実施 (このリスクでは必須ではないが人が確認する)');
  } else if (ship.reviewed === false) {
    add('ship.reviewed', shipRequired ? 'FAIL' : 'CONDITIONAL', 'Ship レビュー未完了');
  } else {
    add('ship.reviewed', 'PASS', `source=${ship.source || 'unknown'}`);
    if (ship.importantFindingsOpen == null) add('ship.findings', 'UNKNOWN', '重大所見の未解決数を取得できない');
    else add('ship.findings', ship.importantFindingsOpen === 0 ? 'PASS' : 'FAIL', `important open=${ship.importantFindingsOpen}`);
  }

  // --- リスク ---
  if (!risk) add('risk.classified', 'UNKNOWN', 'リスク未判定');
  else {
    add('risk.classified', 'PASS', `${risk.level} (${risk.reason})`);
    const req = risk.requirements || {};
    const docs = inputs.riskDocs || {};
    if (req.impactAnalysis && !docs.impactAnalysis) add('risk.impact_analysis', 'CONDITIONAL', `${risk.level} は変更影響分析が必要`);
    if (req.rollbackPlan && !docs.rollbackPlan) add('risk.rollback_plan', 'CONDITIONAL', `${risk.level} はロールバック手順が必要`);
  }

  // --- 要件・残存課題 (人の判断へ) ---
  const reqs = inputs.requirements || { status: 'unknown' };
  if (reqs.status === 'met') add('requirements', 'PASS', reqs.notes || '');
  else if (reqs.status === 'partial') add('requirements', 'CONDITIONAL', reqs.notes || '一部未充足');
  else add('requirements', 'CONDITIONAL', '要件充足は人が完成報告書で確認する');
  if (Array.isArray(inputs.residual) && inputs.residual.length) add('residual', 'CONDITIONAL', `${inputs.residual.length} 件の残存課題`);

  const reasons = checks.filter((c) => c.result !== 'PASS').map((c) => `[${c.result}] ${c.id}: ${c.detail}`);
  return { verdict, reasons, checks, ship_required: shipRequired };
}

module.exports = { evaluate, ORDER };
