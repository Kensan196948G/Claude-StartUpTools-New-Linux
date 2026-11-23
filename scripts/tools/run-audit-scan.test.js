// run-audit-scan.test.js — ブランチ保護判定（rulesets → legacy）の回帰テスト
// gh 呼び出しは注入したスタブのみ。実ネットワーク・実 ruleset には触れない（読み取り専用の判定ロジックのみ検証）。
"use strict";

const test   = require("node:test");
const assert = require("node:assert");
const fs     = require("node:fs");
const os     = require("node:os");
const path   = require("node:path");

const scan = require("./run-audit-scan.js");

// ── テスト用 gh 応答 ─────────────────────────────────────────────────────

function ok(payload) {
  return { ok: true, status: 0, out: JSON.stringify(payload), err: "", httpStatus: null };
}
function okRaw(text) {
  return { ok: true, status: 0, out: text, err: "", httpStatus: null };
}
function fail(http, message) {
  return {
    ok: false,
    status: 1, // gh CLI は HTTP 404 でもプロセス終了コード 1
    out: JSON.stringify({ message, status: String(http) }),
    err: `gh: ${message} (HTTP ${http})`,
    httpStatus: http,
  };
}

const RULESET_DETAIL = {
  id: 100,
  name: "central-auto-merge",
  enforcement: "active",
  conditions: { ref_name: { include: ["refs/heads/main"], exclude: [] } },
  rules: [
    { type: "pull_request", parameters: { required_approving_review_count: 1 } },
    {
      type: "required_status_checks",
      parameters: {
        strict_required_status_checks_policy: true,
        required_status_checks: [{ context: "Secrets scan (gitleaks)" }, { context: "linux-validate" }],
      },
    },
    { type: "non_fast_forward" },
  ],
};

// stubGh — URL の形で応答を振り分け、呼ばれた引数を記録する
function stubGh(routes) {
  const calls = [];
  const gh = (args) => {
    const s = args.join(" ");
    calls.push(s);
    if (routes.rulesets && /\/rulesets$/.test(s)) return routes.rulesets;
    if (routes.rulesetDetail && /\/rulesets\/\d+$/.test(s)) return routes.rulesetDetail;
    if (routes.protection && /\/protection$/.test(s)) return routes.protection(args);
    if (routes.other && routes.other(args)) return routes.other(args);
    if (/^(pr list|run list)/.test(s)) return ok([]);
    return fail(500, `unexpected gh call: ${s}`);
  };
  gh.calls = calls;
  gh.calledWith = (re) => calls.some(c => re.test(c));
  return gh;
}

function ctxWith(gh, overrides = {}) {
  return scan.createContext({ gh, root: fs.mkdtempSync(path.join(os.tmpdir(), "auditscan-")), today: "2026-01-02", ...overrides });
}

// ── 1. ruleset が active なら保護あり（legacy を参照しない） ──────────────

test("ruleset active: protection_source=ruleset / ruleset_names / required_status_checks を詳細から取る", () => {
  const gh = stubGh({
    rulesets: ok([
      { id: 100, name: "central-auto-merge", enforcement: "active" },
      { id: 101, name: "disabled-ruleset", enforcement: "disabled" },
    ]),
    rulesetDetail: ok(RULESET_DETAIL),
    protection: () => fail(404, "Branch not protected"),
  });
  const ctx = ctxWith(gh);
  const bp = scan.checkBranchProtection(ctx);

  assert.strictEqual(bp.protected, true);
  assert.strictEqual(bp.protection_source, "ruleset");
  assert.deepStrictEqual(bp.ruleset_names, ["central-auto-merge"]); // disabled は含めない
  assert.strictEqual(bp.required_checks, 2);
  assert.deepStrictEqual(bp.required_status_checks, ["Secrets scan (gitleaks)", "linux-validate"]);
  assert.strictEqual(bp.required_reviews, 1);
  // active な ruleset があるので legacy は叩かない
  assert.strictEqual(gh.calledWith(/\/branches\/main\/protection$/), false);
});

// ── 2. ruleset 0 件 + legacy 保護あり ───────────────────────────────────

test("ruleset 0件 + legacy 保護あり: protection_source=legacy と required_reviews を返す", () => {
  const gh = stubGh({
    rulesets: ok([]),
    protection: () => ok({
      required_status_checks: { contexts: ["linux-validate"] },
      required_pull_request_reviews: { required_approving_review_count: 2 },
    }),
  });
  const bp = scan.checkBranchProtection(ctxWith(gh));

  assert.strictEqual(bp.protected, true);
  assert.strictEqual(bp.protection_source, "legacy");
  assert.deepStrictEqual(bp.ruleset_names, []);
  assert.strictEqual(bp.required_checks, 1);
  assert.deepStrictEqual(bp.required_status_checks, ["linux-validate"]);
  assert.strictEqual(bp.required_reviews, 2);
});

// ── 3. ruleset 0 件 + legacy 404 → 保護なし ─────────────────────────────

test("両方なし: ruleset 0件 + legacy 404 → protection_source=none, protected=false", () => {
  const gh = stubGh({
    rulesets: ok([]),
    protection: () => fail(404, "Branch not protected"),
  });
  const bp = scan.checkBranchProtection(ctxWith(gh));

  assert.strictEqual(bp.protected, false);
  assert.strictEqual(bp.protection_source, "none");
  assert.strictEqual(bp.required_checks, 0);
  assert.strictEqual(bp.reason, undefined); // 「未確認」ではない
});

// ── 4. API 403 → unknown（保護なしと混同しない） ─────────────────────────

test("API 403: protection_source=unknown / protected=null（保護なしではない）", () => {
  const gh = stubGh({
    rulesets: fail(403, "Resource not accessible by integration"),
    protection: () => fail(404, "Branch not protected"),
  });
  const bp = scan.checkBranchProtection(ctxWith(gh));

  assert.strictEqual(bp.protected, null);
  assert.strictEqual(bp.protection_source, "unknown");
  assert.notStrictEqual(bp.protection_source, "none");
  assert.strictEqual(bp.required_checks, null);
  assert.match(bp.reason, /403|rulesets API/);
});

// ── 5. JSON 破損 → unknown ──────────────────────────────────────────────

test("rulesets の JSON 破損: protection_source=unknown（推測で none にしない）", () => {
  const gh = stubGh({
    rulesets: okRaw("{ this is not json"),
    protection: () => fail(404, "Branch not protected"),
  });
  const bp = scan.checkBranchProtection(ctxWith(gh));

  assert.strictEqual(bp.protected, null);
  assert.strictEqual(bp.protection_source, "unknown");
  assert.match(bp.reason, /JSON/);
});

test("legacy protection の JSON 破損: protection_source=unknown", () => {
  const gh = stubGh({
    rulesets: ok([]),
    protection: () => okRaw("<<broken>>"),
  });
  const bp = scan.checkBranchProtection(ctxWith(gh));

  assert.strictEqual(bp.protected, null);
  assert.strictEqual(bp.protection_source, "unknown");
});

// ── 6. 既存キー維持 + レポートへの反映 ──────────────────────────────────

test("既存キー(protected/required_checks/required_reviews)を維持し、レポートに protection_source を出す", () => {
  const gh = stubGh({
    rulesets: ok([{ id: 100, name: "central-auto-merge", enforcement: "active" }]),
    rulesetDetail: ok(RULESET_DETAIL),
    protection: () => fail(404, "Branch not protected"),
  });
  const ctx = ctxWith(gh);
  const bp = scan.checkBranchProtection(ctx);

  for (const key of ["protected", "required_checks", "required_reviews"]) {
    assert.ok(Object.prototype.hasOwnProperty.call(bp, key), `${key} が無い`);
  }
  assert.strictEqual(typeof bp.required_checks, "number");
  assert.strictEqual(typeof bp.required_reviews, "number");

  const built = scan.buildReport(ctx, [], [], [], bp, { scanned: false });
  assert.match(built.report, /protection_source \| ruleset/);
  assert.match(built.report, /ブランチ保護\(ruleset\): central-auto-merge/);
  assert.strictEqual(built.failCount, 0); // unknown/none は FAIL にしない
});

// ── 7. disabled / evaluate のみは保護として数えない ──────────────────────

test("ruleset が disabled/evaluate のみ + legacy 404 → none", () => {
  const gh = stubGh({
    rulesets: ok([
      { id: 200, name: "off", enforcement: "disabled" },
      { id: 201, name: "observe", enforcement: "evaluate" },
    ]),
    protection: () => fail(404, "Branch not protected"),
  });
  const bp = scan.checkBranchProtection(ctxWith(gh));

  assert.strictEqual(bp.protected, false);
  assert.strictEqual(bp.protection_source, "none");
  assert.deepStrictEqual(bp.ruleset_names, []);
});

// ── 8. legacy 側が 500 → unknown ────────────────────────────────────────

test("legacy 500: protection_source=unknown", () => {
  const gh = stubGh({
    rulesets: ok([]),
    protection: () => fail(500, "Server Error"),
  });
  const bp = scan.checkBranchProtection(ctxWith(gh));

  assert.strictEqual(bp.protected, null);
  assert.strictEqual(bp.protection_source, "unknown");
});

// ── 9. --json の機械可読サマリ（後方互換: 既定出力は維持） ──────────────

test("--json: 最終行に protection_source/ruleset_names を含む JSON を出し、レポートも書く", () => {
  const gh = stubGh({
    rulesets: ok([{ id: 100, name: "central-auto-merge", enforcement: "active" }]),
    rulesetDetail: ok(RULESET_DETAIL),
    protection: () => fail(404, "Branch not protected"),
  });
  const ctx = ctxWith(gh);

  const lines = [];
  const original = console.log;
  console.log = (...a) => lines.push(a.join(" "));
  let result;
  try {
    result = scan.main(["--json"], ctx);
  } finally {
    console.log = original;
  }

  const last = JSON.parse(lines[lines.length - 1]);
  assert.strictEqual(last.protection_source, "ruleset");
  assert.deepStrictEqual(last.ruleset_names, ["central-auto-merge"]);
  assert.strictEqual(last.protected, true);
  assert.strictEqual(last.required_checks, 2);
  assert.strictEqual(last.ok, true);
  assert.ok(fs.existsSync(last.report), "レポートが生成されていない");
  assert.match(fs.readFileSync(last.report, "utf8"), /protection_source \| ruleset/);
  assert.strictEqual(result.branchProt.protection_source, "ruleset");
  // 既定の人間向け出力も維持されている
  assert.ok(lines.some(l => l.includes("=== Audit-Agent スキャン ===")));
  assert.ok(lines.some(l => l.includes("準拠チェック: PASS=")));
});
