#!/usr/bin/env node
/**
 * run-audit-scan.js — Audit-Agent 実行スクリプト（ClaudeOS Phase 6D）
 * Verify フェーズ末尾で呼び出し、変更証跡を収集して reports/audit/YYYY-MM-DD.md に出力。
 *
 * ブランチ保護の判定順（2026-11 改修 / 第2バッチ #7）:
 *   1. rulesets API (`/repos/{owner}/{repo}/rulesets`) で active な ruleset を探す。
 *      active があれば「保護あり」= protection_source: "ruleset"。
 *      required_status_checks は ruleset 詳細 (`/rulesets/{id}`) の
 *      rules[type=required_status_checks].parameters から取得する。
 *   2. ruleset が 0 件（または rulesets API が 404）のときだけ legacy
 *      (`/branches/{branch}/protection`) を参照する。保護あり = "legacy"。
 *   3. どちらも 404 なら保護なし = "none"。
 *   4. API エラー（403 / 429 / 5xx / ネットワーク断 / JSON 破損）は "unknown"（未確認）とし、
 *      「保護なし」と混同しない（protected: null）。
 *
 * 依存の注入: gh 呼び出しは createContext({ gh }) で差し替え可能（テスト用）。
 * 実ネットワークに依存せず単体テストできる。
 */

"use strict";

const fs    = require("fs");
const path  = require("path");
const { spawnSync } = require("child_process");

const DEFAULT_ROOT = process.cwd();

const PROTECTION_SOURCE = Object.freeze({
  RULESET: "ruleset",
  LEGACY:  "legacy",
  NONE:    "none",
  UNKNOWN: "unknown",
});

// ── 実行コンテキスト（gh / root / 日付を注入可能にする） ────────────────────

// extractHttpStatus — gh の出力から HTTP ステータスを拾う。
//   gh CLI は HTTP 404 でもプロセス終了コード 1 を返すため、終了コードだけでは
//   「404 = 未設定」と「403 = 権限なし（未確認）」を区別できない。
function extractHttpStatus(text) {
  const m = /HTTP (\d{3})/.exec(text || "");
  return m ? Number(m[1]) : null;
}

// createDefaultGh — 既定の gh 実行ランナー。
//   返り値: { ok, status, out, err, httpStatus }  (status = gh プロセスの終了コード)
function createDefaultGh(root = DEFAULT_ROOT) {
  return (args) => {
    const r = spawnSync("gh", args, {
      cwd: root,
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
      timeout: 15000,
    });
    const out = (r.stdout || "").trim();
    const err = (r.stderr || "").trim();
    const exitCode = typeof r.status === "number" ? r.status : 1;
    return {
      ok: exitCode === 0,
      status: exitCode,
      out,
      err,
      httpStatus: extractHttpStatus(`${r.stdout || ""}\n${r.stderr || ""}`),
    };
  };
}

function createContext(overrides = {}) {
  const root = overrides.root || DEFAULT_ROOT;
  return {
    root,
    branch: overrides.branch || "main",
    today: overrides.today || new Date().toISOString().slice(0, 10),
    gh: overrides.gh || createDefaultGh(root),
  };
}

function reportPaths(ctx) {
  const dir = path.join(ctx.root, "reports", "audit");
  return { dir, file: path.join(dir, `${ctx.today}.md`) };
}

function run(cmd, args, ctx) {
  const r = spawnSync(cmd, args, {
    cwd: ctx.root,
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
    timeout: 10000,
  });
  return (r.stdout || "").trim();
}

// ── gh 応答の分類 ────────────────────────────────────────────────────────

function safeJson(text) {
  try {
    return { ok: true, value: JSON.parse(text) };
  } catch {
    return { ok: false, value: null };
  }
}

// classifyFailure — 失敗した gh 応答を notfound / error に分類する。
//   notfound = 404（リソース未設定。「保護なし」と言える）
//   error    = 403 / 429 / 5xx / ネットワーク断 / 判定不能（「未確認」）
function classifyFailure(res) {
  const http = Number(res?.httpStatus);
  if (Number.isFinite(http) && http > 0) {
    return http === 404 ? "notfound" : "error";
  }
  const text = `${res?.err || ""}\n${res?.out || ""}`;
  if (/HTTP 404\b/.test(text) || /"status"\s*:\s*"404"/.test(text) || /Branch not protected/.test(text)) {
    return "notfound";
  }
  return "error";
}

function failureReason(label, res) {
  const http = Number(res?.httpStatus);
  const code = Number.isFinite(http) && http > 0 ? `HTTP ${http}` : `exit=${res?.status ?? "?"}`;
  const detail = (res?.err || res?.out || "").split("\n")[0].slice(0, 120);
  return detail ? `${label} エラー (${code}): ${detail}` : `${label} エラー (${code})`;
}

// ── 証跡収集 ─────────────────────────────────────────────────────────────

function collectGitEvidence(ctx) {
  const log = run("git", ["log", "--pretty=format:%H|%an|%ad|%s", "--date=short", "-10"], ctx);
  return log.split("\n").filter(Boolean).map(l => {
    const [sha, author, date, ...rest] = l.split("|");
    return { sha: sha.slice(0, 8), author, date, message: rest.join("|").slice(0, 80) };
  });
}

function collectPREvidence(ctx) {
  const r = ctx.gh(["pr", "list", "--state", "merged", "--limit", "5", "--json", "number,title,mergedAt,author"]);
  if (!r.ok) return [];
  const parsed = safeJson(r.out);
  if (!parsed.ok) return [];
  return parsed.value.map(p => ({
    number: p.number,
    title:  (p.title || "").slice(0, 60),
    merged_at: (p.mergedAt || "").slice(0, 10),
    author: p.author?.login || "unknown",
  }));
}

function collectCIEvidence(ctx) {
  const r = ctx.gh(["run", "list", "--branch", "main", "--limit", "5", "--json", "conclusion,workflowName,createdAt,headSha"]);
  if (!r.ok) return [];
  const parsed = safeJson(r.out);
  if (!parsed.ok) return [];
  return parsed.value.map(run => ({
    workflow: run.workflowName,
    result:   run.conclusion || "in_progress",
    date:     (run.createdAt || "").slice(0, 10),
    sha:      (run.headSha || "").slice(0, 8),
  }));
}

// ── ブランチ保護（rulesets → legacy の順） ─────────────────────────────────

function rulesetsEndpoint() {
  return "repos/{owner}/{repo}/rulesets";
}

// probeRulesets — active な ruleset を探す。
//   返り値: { kind: "active"|"empty"|"notfound"|"error", active: [], reason? }
function probeRulesets(ctx) {
  const res = ctx.gh(["api", rulesetsEndpoint()]);
  if (!res.ok) {
    const kind = classifyFailure(res);
    return kind === "notfound"
      ? { kind: "notfound", active: [], reason: "rulesets API が 404 (rulesets 未使用)" }
      : { kind: "error", active: [], reason: failureReason("rulesets API", res) };
  }
  const parsed = safeJson(res.out);
  if (!parsed.ok) {
    return { kind: "error", active: [], reason: "rulesets API の JSON を解析できません" };
  }
  if (!Array.isArray(parsed.value)) {
    return { kind: "error", active: [], reason: "rulesets API の応答が配列ではありません" };
  }
  // enforcement が "active" のものだけを保護として数える (disabled / evaluate は保護ではない)
  const active = parsed.value.filter(rs => rs && rs.enforcement === "active");
  return { kind: active.length > 0 ? "active" : "empty", active, all: parsed.value };
}

function fetchRulesetDetail(ctx, id) {
  const res = ctx.gh(["api", `${rulesetsEndpoint()}/${id}`]);
  if (!res.ok) {
    return { ok: false, reason: failureReason(`ruleset ${id} 詳細`, res) };
  }
  const parsed = safeJson(res.out);
  if (!parsed.ok) {
    return { ok: false, reason: `ruleset ${id} 詳細の JSON を解析できません` };
  }
  return { ok: true, value: parsed.value };
}

// extractRequiredChecks — ruleset 詳細から required_status_checks の context を集める
function extractRequiredChecks(detail) {
  const contexts = [];
  for (const rule of detail?.rules || []) {
    if (rule?.type !== "required_status_checks") continue;
    const checks = rule?.parameters?.required_status_checks;
    if (Array.isArray(checks)) {
      for (const c of checks) {
        const name = typeof c === "string" ? c : c?.context;
        if (name) contexts.push(name);
      }
    }
    // 旧形式 (parameters.contexts) も許容する
    const legacy = rule?.parameters?.contexts;
    if (Array.isArray(legacy)) {
      for (const c of legacy) if (c) contexts.push(c);
    }
  }
  return [...new Set(contexts)];
}

// extractRequiredReviews — ruleset 詳細から required_approving_review_count を拾う
function extractRequiredReviews(detail) {
  let reviews = 0;
  for (const rule of detail?.rules || []) {
    if (rule?.type !== "pull_request") continue;
    const n = Number(rule?.parameters?.required_approving_review_count);
    if (Number.isFinite(n) && n > reviews) reviews = n;
  }
  return reviews;
}

// probeLegacy — legacy branch protection を参照する。
//   返り値: { kind: "protected"|"none"|"error", contexts, reviews, reason? }
function probeLegacy(ctx) {
  const res = ctx.gh(["api", `repos/{owner}/{repo}/branches/${ctx.branch}/protection`]);
  if (!res.ok) {
    const kind = classifyFailure(res);
    return kind === "notfound"
      ? { kind: "none", contexts: [], reviews: 0 }
      : { kind: "error", contexts: [], reviews: 0, reason: failureReason("branch protection API", res) };
  }
  const parsed = safeJson(res.out);
  if (!parsed.ok) {
    return { kind: "error", contexts: [], reviews: 0, reason: "branch protection API の JSON を解析できません" };
  }
  const d = parsed.value;
  const contexts = (d?.required_status_checks?.contexts || []).filter(Boolean);
  const reviews = d?.required_pull_request_reviews?.required_approving_review_count || 0;
  return { kind: "protected", contexts, reviews };
}

/**
 * checkBranchProtection — 保護状態を判定する。
 *   返り値の既存キー（protected / required_reviews / required_checks）は維持し、
 *   protection_source / ruleset_names / required_status_checks を追加する。
 *   unknown のときは protected: null（= 保護なしではない）。
 */
function checkBranchProtection(ctx) {
  const rulesets = probeRulesets(ctx);

  if (rulesets.kind === "active") {
    const names = rulesets.active.map(rs => rs.name).filter(Boolean);
    const ids = rulesets.active.map(rs => rs.id).filter(id => id !== undefined && id !== null);
    const contexts = [];
    const detailErrors = [];
    let reviews = 0;
    for (const id of ids) {
      const detail = fetchRulesetDetail(ctx, id);
      if (!detail.ok) {
        detailErrors.push(detail.reason);
        continue;
      }
      contexts.push(...extractRequiredChecks(detail.value));
      reviews = Math.max(reviews, extractRequiredReviews(detail.value));
    }
    const uniqueContexts = [...new Set(contexts)];
    const result = {
      protected: true,
      protection_source: PROTECTION_SOURCE.RULESET,
      ruleset_names: names,
      required_checks: uniqueContexts.length,
      required_status_checks: uniqueContexts,
      required_reviews: reviews,
    };
    if (detailErrors.length > 0) result.detail_errors = detailErrors;
    return result;
  }

  const rulesetProblem = rulesets.kind === "error" ? rulesets.reason : null;
  const legacy = probeLegacy(ctx);

  if (legacy.kind === "protected") {
    const result = {
      protected: true,
      protection_source: PROTECTION_SOURCE.LEGACY,
      ruleset_names: [],
      required_checks: legacy.contexts.length,
      required_status_checks: legacy.contexts,
      required_reviews: legacy.reviews,
    };
    // ruleset 側が読めなかったことは残す（legacy で保護は確認できている）
    if (rulesetProblem) result.ruleset_error = rulesetProblem;
    return result;
  }

  if (legacy.kind === "none" && !rulesetProblem) {
    return {
      protected: false,
      protection_source: PROTECTION_SOURCE.NONE,
      ruleset_names: [],
      required_checks: 0,
      required_status_checks: [],
      required_reviews: 0,
    };
  }

  // どちらも確認できなかった → 未確認（保護なしとは区別する）
  return {
    protected: null,
    protection_source: PROTECTION_SOURCE.UNKNOWN,
    ruleset_names: [],
    required_checks: null,
    required_status_checks: [],
    required_reviews: 0,
    reason: rulesetProblem || legacy.reason || "保護状態を確認できません",
  };
}

function checkSecretsLeak(ctx) {
  const r = ctx.gh(["run", "list", "--branch", "main", "--limit", "10", "--json", "conclusion,workflowName"]);
  if (!r.ok) return { scanned: false };
  const parsed = safeJson(r.out);
  if (!parsed.ok) return { scanned: false };
  const runs = parsed.value;
  const scan = runs.find(x => String(x.workflowName || "").toLowerCase().includes("secret")
    || String(x.workflowName || "").toLowerCase().includes("security"));
  if (!scan) return { scanned: false };
  return { scanned: true, result: scan.conclusion };
}

// ── 準拠チェック ─────────────────────────────────────────────────────────

// protectionEvidence — 保護状態の説明文（protection_source を必ず含める）
function protectionEvidence(bp) {
  switch (bp.protection_source) {
    case PROTECTION_SOURCE.RULESET:
      return `ブランチ保護(ruleset): ${bp.ruleset_names.join(", ") || "(名称不明)"} / required_checks=${bp.required_checks}`;
    case PROTECTION_SOURCE.LEGACY:
      return `ブランチ保護(legacy): required_checks=${bp.required_checks} / required_reviews=${bp.required_reviews}`;
    case PROTECTION_SOURCE.NONE:
      return "main への直接 push が許可されている（保護なし）";
    default:
      return `保護状態は未確認（API エラー。保護なしではない）: ${bp.reason || "原因不明"}`;
  }
}

// protectionStatus — protected=true のみ PASS。none と unknown は WARN（FAIL ではない）
function protectionStatus(bp) {
  return bp.protected === true ? "PASS" : "WARN";
}

function complianceCheck(gitLog, prs, ciRuns, branchProt, secretsScan) {
  const items = [];

  // 変更管理: PR 経由でのマージ確認
  items.push({
    control: "変更管理 — PR経由マージ",
    status: protectionStatus(branchProt),
    evidence: protectionEvidence(branchProt),
  });

  // CI 成功確認
  const recentCI = ciRuns.find(r => r.workflow === "CI");
  items.push({
    control: "CI パイプライン成功",
    status: recentCI?.result === "success" ? "PASS" : "WARN",
    evidence: recentCI ? `最新 CI: ${recentCI.result} (${recentCI.date})` : "CI 実行記録なし",
  });

  // Secrets スキャン
  items.push({
    control: "Secrets / セキュリティスキャン",
    status: secretsScan.scanned ? (secretsScan.result === "success" ? "PASS" : "FAIL") : "WARN",
    evidence: secretsScan.scanned ? `スキャン結果: ${secretsScan.result}` : "スキャン実行記録なし",
  });

  // コミット証跡
  items.push({
    control: "コミット証跡（変更者・日時）",
    status: gitLog.length > 0 ? "PASS" : "WARN",
    evidence: `直近 ${gitLog.length} コミット記録済み`,
  });

  // PR レビュー承認
  items.push({
    control: "PR レビュー承認記録",
    status: prs.length > 0 ? "PASS" : "WARN",
    evidence: prs.length > 0 ? `${prs.length} 件の merge 済み PR 確認` : "PR 記録なし",
  });

  return items;
}

// ── レポート生成 ──────────────────────────────────────────────────────────

function buildReport(ctx, gitLog, prs, ciRuns, branchProt, secretsScan) {
  const compliance = complianceCheck(gitLog, prs, ciRuns, branchProt, secretsScan);
  const passCount  = compliance.filter(c => c.status === "PASS").length;
  const warnCount  = compliance.filter(c => c.status === "WARN").length;
  const failCount  = compliance.filter(c => c.status === "FAIL").length;

  const lines = [
    `# 監査レポート — ${ctx.today}`,
    ``,
    `**生成**: ClaudeOS Audit-Agent Phase 6D`,
    `**プロジェクト**: ${path.basename(ctx.root)}`,
    `**レビュー日**: ${ctx.today}`,
    ``,
    `## 📊 準拠サマリー`,
    ``,
    `| 結果 | 件数 |`,
    `|---|---|`,
    `| ✅ PASS | ${passCount} |`,
    `| ⚠️ WARN | ${warnCount} |`,
    `| ❌ FAIL | ${failCount} |`,
    ``,
    `## 🔍 準拠チェック詳細`,
    ``,
    `| 管理策 | 状態 | 証跡 |`,
    `|---|---|---|`,
    ...compliance.map(c => `| ${c.control} | ${c.status === "PASS" ? "✅" : c.status === "FAIL" ? "❌" : "⚠️"} ${c.status} | ${c.evidence} |`),
    ``,
    `## 🛡️ ブランチ保護`,
    ``,
    `| 項目 | 値 |`,
    `|---|---|`,
    `| protection_source | ${branchProt.protection_source} |`,
    `| protected | ${branchProt.protected === null ? "unknown" : branchProt.protected} |`,
    `| ruleset_names | ${branchProt.ruleset_names?.length ? branchProt.ruleset_names.join(", ") : "(なし)"} |`,
    `| required_checks | ${branchProt.required_checks === null ? "unknown" : branchProt.required_checks} |`,
    ``,
    `## 📝 変更証跡（直近10コミット）`,
    ``,
    `| SHA | 変更者 | 日付 | メッセージ |`,
    `|---|---|---|---|`,
    ...gitLog.map(g => `| \`${g.sha}\` | ${g.author} | ${g.date} | ${g.message} |`),
    ``,
    `## 🔀 マージ済み PR（直近5件）`,
    ``,
    prs.length > 0
      ? [`| PR# | タイトル | マージ日 | 担当者 |`, `|---|---|---|---|`,
         ...prs.map(p => `| #${p.number} | ${p.title} | ${p.merged_at} | ${p.author} |`)].join("\n")
      : "_記録なし_",
    ``,
    `## ⚙️ CI/CD 実行記録（直近5件）`,
    ``,
    ciRuns.length > 0
      ? [`| ワークフロー | 結果 | 日付 | SHA |`, `|---|---|---|---|`,
         ...ciRuns.map(r => `| ${r.workflow} | ${r.result} | ${r.date} | \`${r.sha}\` |`)].join("\n")
      : "_記録なし_",
    ``,
    `---`,
    ``,
    `**[停止理由]**`,
    `- 状態: 完了`,
    `- 理由: Audit スキャン完了 (PASS=${passCount} WARN=${warnCount} FAIL=${failCount})`,
    `- 次アクション: ${failCount > 0 ? "FAIL 項目を Issue 起票してセキュリティに連絡" : "問題なし — 次フェーズへ移行"}`,
  ];

  return { report: lines.join("\n"), passCount, warnCount, failCount };
}

// ── メイン ─────────────────────────────────────────────────────────────────

function main(argv = process.argv.slice(2), ctx = createContext()) {
  const wantJson = argv.includes("--json");
  const paths = reportPaths(ctx);

  console.log("=== Audit-Agent スキャン ===");
  fs.mkdirSync(paths.dir, { recursive: true });

  console.log("git 変更証跡を収集中...");
  const gitLog      = collectGitEvidence(ctx);
  console.log("PR 証跡を収集中...");
  const prs         = collectPREvidence(ctx);
  console.log("CI 実行記録を収集中...");
  const ciRuns      = collectCIEvidence(ctx);
  console.log("ブランチ保護を確認中...");
  const branchProt  = checkBranchProtection(ctx);
  console.log("Secrets スキャン結果を確認中...");
  const secretsScan = checkSecretsLeak(ctx);

  const { report, passCount, warnCount, failCount } = buildReport(ctx, gitLog, prs, ciRuns, branchProt, secretsScan);
  fs.writeFileSync(paths.file, report, "utf8");

  console.log(`\n準拠チェック: PASS=${passCount} WARN=${warnCount} FAIL=${failCount}`);
  console.log(`ブランチ保護: source=${branchProt.protection_source}`
    + ` rulesets=${branchProt.ruleset_names?.length ? branchProt.ruleset_names.join(",") : "-"}`
    + ` required_checks=${branchProt.required_checks === null ? "unknown" : branchProt.required_checks}`);
  console.log(`出力: ${paths.file}`);

  // --json: 最終行に機械可読サマリを 1 行だけ出す（既定出力は変えない）
  //   「最終行が JSON」という契約を守るため、人間向けの締めメッセージの後に出す。
  const jsonLine = wantJson
    ? JSON.stringify({
        ok: failCount === 0,
        pass: passCount,
        warn: warnCount,
        fail: failCount,
        protected: branchProt.protected,
        protection_source: branchProt.protection_source,
        ruleset_names: branchProt.ruleset_names || [],
        required_checks: branchProt.required_checks,
        required_status_checks: branchProt.required_status_checks || [],
        report: paths.file,
      })
    : null;

  if (failCount > 0) {
    console.log("\n⚠️ FAIL 項目あり — Security に連絡し Issue 起票してください");
    if (jsonLine) console.log(jsonLine);
    process.exit(1);
  }

  console.log("\n[停止理由]\n- 状態: 完了\n- 理由: 全準拠チェック PASS\n- 次アクション: PR 作成・マージへ移行");
  if (jsonLine) console.log(jsonLine);
  return { passCount, warnCount, failCount, branchProt, reportPath: paths.file };
}

if (require.main === module) {
  main();
}

module.exports = {
  PROTECTION_SOURCE,
  createContext,
  createDefaultGh,
  extractHttpStatus,
  classifyFailure,
  reportPaths,
  collectGitEvidence,
  collectPREvidence,
  collectCIEvidence,
  probeRulesets,
  fetchRulesetDetail,
  extractRequiredChecks,
  extractRequiredReviews,
  probeLegacy,
  checkBranchProtection,
  checkSecretsLeak,
  protectionEvidence,
  protectionStatus,
  complianceCheck,
  buildReport,
  main,
};
