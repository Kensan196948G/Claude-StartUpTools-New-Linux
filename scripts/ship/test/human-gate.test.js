'use strict';
// Human Gate / Merge Executor の敵対的テスト
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { tmpHome, testPolicy, fakePr, fakeGh, H1, H2, B1, B2 } = require('./helpers');

tmpHome();
const store = require('../lib/store');
const hg = require('../lib/human-gate');
const quality = require('../lib/quality');
const merge = require('../lib/merge');

const FAST = { N: 1 << 10, r: 8, p: 1, maxmem: 64 * 1024 * 1024 };
const PASS = 'correct horse battery staple';
const bundle = hg.generateKey('Kensan', PASS, { kdf: FAST, test: true });
const priv = hg.loadPrivateKey(bundle, PASS);
const trusted = { name: 'Kensan', key_id: bundle.key_id, public_key: bundle.public_key };

function policy(over = {}) {
  return testPolicy({ humanGate: { approverKeys: [trusted], ...(over.humanGate || {}) }, merge: { centralProfileEnforced: true, ...(over.merge || {}) } });
}
const REPO = 'o/r';
function mkGate(over = {}) {
  return { repo: REPO, pr: 7, head_sha: H1, base_sha: B1, verdict: 'PASS', risk: 'R2', policy_version: '5.0.0', quality_eval_id: 'qe_x', ...over };
}
function writeGate(g) { store.writeRecord(store.paths.gate(g.repo, g.pr, g.head_sha), g); }
function writeQualityPass(head = H1, base = B1) {
  const rec = { schema: store.SCHEMA.quality, eval_id: store.newId('qe'), repo: REPO, pr: 7, head_sha: head, base_sha: base,
    finished_at: new Date().toISOString(), verdict: 'PASS', reasons: [], checks: [{ id: 's', category: 'secrets', status: 'PASS' }] };
  quality.seal(rec);
  store.writeRecord(store.paths.quality(REPO, head, rec.eval_id), rec);
  return rec;
}
function approve(g = mkGate(), opts = {}) {
  const a = hg.issueApproval({ gate: g, quality: null, bundle, privateKey: priv, policy: policy(), ...opts });
  store.writeRecord(store.paths.approval(REPO, 7, a.approval_id), a);
  return a;
}
function resetStore() { fs.rmSync(store.shipHome(), { recursive: true, force: true }); fs.mkdirSync(store.shipHome(), { recursive: true }); }

// ---------------- 鍵 ----------------
test('鍵: パスフレーズ違いでは秘密鍵を取り出せない / 弱いパスフレーズは拒否', () => {
  assert.throws(() => hg.loadPrivateKey(bundle, 'wrong passphrase!!'), /BAD_PASSPHRASE/);
  assert.throws(() => hg.generateKey('x', 'short'), /PASSPHRASE_TOO_SHORT/);
  assert.throws(() => hg.generateKey('x', 'aaaaaaaaaaaaaaaa'), /PASSPHRASE_TOO_SIMPLE/);
  assert.doesNotMatch(JSON.stringify(bundle), /PRIVATE KEY/);
});
test('鍵: 本番鍵 (test:false) では環境変数のパスフレーズを使わない', () => {
  process.env.CLAUDEOS_SHIP_TEST_PASSPHRASE = PASS;
  const prod = { ...bundle, test: false, wrapped: { ...bundle.wrapped, test: false } };
  // TTY が無いテスト環境では NO_TTY で拒否される (環境変数経路は使われない)
  assert.throws(() => hg.readPassphrase(prod), /NO_TTY/);
  assert.equal(hg.readPassphrase(bundle), PASS);
  delete process.env.CLAUDEOS_SHIP_TEST_PASSPHRASE;
});
test('鍵: 弱い KDF パラメータの鍵束は (test 以外) 拒否', () => {
  const w = hg.wrap(Buffer.from('x'), PASS, FAST);
  assert.throws(() => hg.unwrap(w, PASS), /KDF_TOO_WEAK/);
});

// ---------------- 承認の検証 ----------------
test('承認: 正しい承認は有効', () => {
  resetStore();
  const a = approve();
  assert.deepEqual(hg.verifyApproval(a, { policy: policy(), headSha: H1, baseSha: B1, gate: mkGate() }), { ok: true });
});
test('承認: gate が PASS でなければ発行しない', () => {
  for (const v of ['CONDITIONAL', 'FAIL', 'UNKNOWN', 'BLOCKED']) {
    assert.throws(() => hg.issueApproval({ gate: mkGate({ verdict: v }), bundle, privateKey: priv, policy: policy() }), /GATE_NOT_PASS/);
  }
});
test('偽装: AI が自分で作った鍵で署名しても信頼鍵に無いので無効', () => {
  const evil = hg.generateKey('Kensan', 'attacker passphrase 1', { kdf: FAST, test: true });
  const a = hg.issueApproval({ gate: mkGate(), bundle: evil, privateKey: hg.loadPrivateKey(evil, 'attacker passphrase 1'), policy: policy() });
  assert.equal(hg.verifyApproval(a, { policy: policy(), headSha: H1, baseSha: B1 }).reason, 'KEY_NOT_TRUSTED');
});
test('偽装: 信頼鍵の key_id を名乗っても署名が合わなければ無効', () => {
  const evil = hg.generateKey('Kensan', 'attacker passphrase 1', { kdf: FAST, test: true });
  const a = hg.issueApproval({ gate: mkGate(), bundle: { ...evil, key_id: bundle.key_id }, privateKey: hg.loadPrivateKey(evil, 'attacker passphrase 1'), policy: policy() });
  assert.equal(hg.verifyApproval(a, { policy: policy(), headSha: H1, baseSha: B1 }).reason, 'BAD_SIGNATURE');
});
test('偽装: 署名後のフィールド改変 (head 差し替え / 期限延長 / decision 変更) は無効', () => {
  const a = approve();
  for (const [k, v] of [['head_sha', H2], ['expires_at', '2099-01-01T00:00:00.000Z'], ['pr', 8], ['risk', 'R0'], ['gate_verdict', 'PASS2']]) {
    const t = { ...a, [k]: v };
    assert.equal(hg.verifyApproval(t, { policy: policy(), headSha: t.head_sha, baseSha: B1 }).reason, 'BAD_SIGNATURE', k);
  }
  const unsigned = { ...a }; delete unsigned.signature;
  assert.equal(hg.verifyApproval(unsigned, { policy: policy(), headSha: H1, baseSha: B1 }).reason, 'UNSIGNED');
});
test('偽装: 信頼鍵リストの公開鍵を差し替えても fingerprint 不一致で無効', () => {
  const evil = hg.generateKey('Kensan', 'attacker passphrase 1', { kdf: FAST, test: true });
  const a = approve();
  const p = policy({ humanGate: { approverKeys: [{ ...trusted, public_key: evil.public_key }] } });
  assert.equal(hg.verifyApproval(a, { policy: p, headSha: H1, baseSha: B1 }).reason, 'FINGERPRINT_MISMATCH');
});
test('失効: 承認後に head が変わると無効 / base が変わると無効', () => {
  const a = approve();
  assert.equal(hg.verifyApproval(a, { policy: policy(), headSha: H2, baseSha: B1 }).reason, 'STALE_HEAD');
  assert.equal(hg.verifyApproval(a, { policy: policy(), headSha: H1, baseSha: B2 }).reason, 'STALE_BASE');
});
test('失効: 期限切れ / 未来の発行時刻', () => {
  const a = approve(mkGate(), { now: new Date(Date.now() - 48 * 3600 * 1000) });
  assert.equal(hg.verifyApproval(a, { policy: policy(), headSha: H1, baseSha: B1 }).reason, 'EXPIRED');
  const b = approve(mkGate(), { now: new Date(Date.now() + 3600 * 1000) });
  assert.equal(hg.verifyApproval(b, { policy: policy(), headSha: H1, baseSha: B1 }).reason, 'ISSUED_IN_FUTURE');
});
test('失効: gate が変わった (再判定で FAIL・リスク変更) なら無効', () => {
  const a = approve();
  assert.equal(hg.verifyApproval(a, { policy: policy(), headSha: H1, baseSha: B1, gate: mkGate({ verdict: 'FAIL' }) }).reason, 'GATE_NOT_PASS');
  assert.equal(hg.verifyApproval(a, { policy: policy(), headSha: H1, baseSha: B1, gate: mkGate({ risk: 'R4' }) }).reason, 'GATE_CHANGED');
});
test('取り消し: revoke 後は無効。二重取り消しは拒否', () => {
  const a = approve();
  hg.revoke(a.approval_id, 'test', 'human');
  assert.equal(hg.verifyApproval(a, { policy: policy(), headSha: H1, baseSha: B1 }).reason, 'REVOKED');
  assert.throws(() => hg.revoke(a.approval_id, 'again', 'human'), /EEXIST/);
});
test('リプレイ: nonce は 1 回しか消費できない', () => {
  const a = approve();
  hg.consume(a);
  assert.equal(hg.verifyApproval(a, { policy: policy(), headSha: H1, baseSha: B1 }).reason, 'NONCE_CONSUMED');
  assert.throws(() => hg.consume(a), /NONCE_CONSUMED/);
});
test('差し戻し (reject) は承認として扱わない', () => {
  const a = approve(mkGate(), { decision: 'reject' });
  assert.match(hg.verifyApproval(a, { policy: policy(), headSha: H1, baseSha: B1 }).reason, /NOT_APPROVE_DECISION/);
});
test('ポリシー: approverKeys が空なら全て無効 (fail-closed) / 人間承認を外すポリシーは読み込み拒否', () => {
  const a = approve();
  assert.equal(hg.verifyApproval(a, { policy: testPolicy(), headSha: H1, baseSha: B1 }).reason, 'KEY_NOT_TRUSTED');
  const { validate } = require('../lib/policy');
  assert.throws(() => validate(testPolicy({ humanGate: { requiredForAllRisks: false } })), /POLICY_HUMAN_GATE_DISABLED/);
});
test('ポリシー: loadTrustedPolicy は作業ツリーではなく base ref の版を読む', () => {
  const { spawnSync } = require('node:child_process');
  const dir = fs.mkdtempSync(path.join(require('node:os').tmpdir(), 'pol-'));
  const g = (...a) => spawnSync('git', a, { cwd: dir, encoding: 'utf8' });
  g('init', '-q', '-b', 'main'); g('config', 'user.email', 't@t'); g('config', 'user.name', 't');
  fs.mkdirSync(path.join(dir, 'config'));
  fs.writeFileSync(path.join(dir, 'config', 'ship-policy.json'), JSON.stringify(policy()));
  g('add', '.'); g('commit', '-qm', 'base');
  g('update-ref', 'refs/remotes/origin/main', 'HEAD');
  // PR 側で信頼鍵を足す (自己承認の試み)
  const evil = { ...policy() }; evil.humanGate = { ...evil.humanGate, approverKeys: [...evil.humanGate.approverKeys, { name: 'AI', key_id: 'sha256:' + 'f'.repeat(64) }] };
  fs.writeFileSync(path.join(dir, 'config', 'ship-policy.json'), JSON.stringify(evil));
  const prev = process.env.CLAUDEOS_SHIP_TRUSTED_POLICY; delete process.env.CLAUDEOS_SHIP_TRUSTED_POLICY;
  const t = require('../lib/policy').loadTrustedPolicy(dir, 'origin/main');
  assert.equal(t.humanGate.approverKeys.length, 1);
  assert.throws(() => require('../lib/policy').loadTrustedPolicy(dir, 'origin/main; rm -rf /'), /INVALID_BASE_REF/);
  if (prev) process.env.CLAUDEOS_SHIP_TRUSTED_POLICY = prev;
  fs.rmSync(dir, { recursive: true, force: true });
});

// ---------------- 品質証跡の封印 ----------------
test('品質証跡: 改ざん (verdict 書き換え / hmac 再計算なし) は検出され除外される', () => {
  resetStore();
  const rec = writeQualityPass();
  assert.equal(quality.verifySeal(rec).ok, true);
  const f = store.paths.quality(REPO, H1, rec.eval_id);
  const t = JSON.parse(fs.readFileSync(f, 'utf8'));
  t.checks[0].status = 'FAIL'; t.verdict = 'PASS';
  fs.writeFileSync(f, JSON.stringify(t));
  const le = quality.latestEvidence(REPO, H1);
  assert.equal(le.evidence, null);
  assert.equal(le.rejected[0].reason, 'EVIDENCE_HASH_MISMATCH');
  // hash だけ再計算しても HMAC が合わない
  t.evidence_hash = store.sha256(store.canonical({ ...t, evidence_hash: undefined, hmac: undefined }));
  fs.writeFileSync(f, JSON.stringify(t));
  assert.equal(quality.latestEvidence(REPO, H1).rejected[0].reason, 'HMAC_MISMATCH');
});
test('品質証跡: 別 SHA のディレクトリへコピーしても対象不一致で除外', () => {
  resetStore();
  const rec = writeQualityPass(H1);
  store.writeRecord(store.paths.quality(REPO, H2, rec.eval_id), rec);
  assert.equal(quality.latestEvidence(REPO, H2).rejected[0].reason, 'SUBJECT_MISMATCH');
});

// ---------------- Ship 証跡 (人間署名) ----------------
test('Ship 証跡: 署名済みは gate 入力になり、head 違い・未署名は無視', () => {
  resetStore();
  const a = hg.issueShipAttestation({ repo: REPO, pr: 7, headSha: H1, reviewed: true, importantOpen: 0, watchStatus: 'checks-pass-comments-answered', bundle, privateKey: priv });
  store.writeRecord(path.join(hg.shipEvidenceDir(REPO, 7), a.attestation_id + '.json'), a);
  const ev = hg.shipEvidenceFor(REPO, 7, H1, policy());
  assert.equal(ev.reviewed, true); assert.equal(ev.importantFindingsOpen, 0);
  assert.equal(hg.shipEvidenceFor(REPO, 7, H2, policy()), null);
  const forged = { ...a, attestation_id: 'sa_forged_1', important_open: 0, reviewed: true, signature: crypto.randomBytes(64).toString('base64') };
  fs.rmSync(hg.shipEvidenceDir(REPO, 7), { recursive: true });
  store.writeRecord(path.join(hg.shipEvidenceDir(REPO, 7), 'sa_forged_1.json'), forged);
  assert.equal(hg.shipEvidenceFor(REPO, 7, H1, policy()), null);
});

// ---------------- 人の差分確認 (human-diff, R0・R1 のみ) ----------------
function diffAttest(over = {}) {
  return hg.issueShipAttestation({ repo: REPO, pr: 7, headSha: H1, reviewed: true, importantOpen: 0, watchStatus: 'not-started',
    reviewKind: 'human-diff', filesReviewed: 3, bundle, privateKey: priv, ...over });
}
function putAttest(a) { store.writeRecord(path.join(hg.shipEvidenceDir(REPO, 7), a.attestation_id + '.json'), a); }

test('human-diff: R0・R1 では証跡として認め、R2 以上では無視する (リスクは呼び出し側の計算値)', () => {
  resetStore();
  const a = diffAttest();
  assert.equal(a.schema, hg.ATTEST_SCHEMA_V2);
  assert.equal(a.review_kind, 'human-diff'); assert.equal(a.files_reviewed, 3);
  putAttest(a);
  for (const lv of ['R0', 'R1']) {
    const ev = hg.shipEvidenceFor(REPO, 7, H1, policy(), lv);
    assert.equal(ev.reviewKind, 'human-diff', lv);
    assert.match(ev.source, /^human-diff-attestation:sa_/);
  }
  for (const lv of ['R2', 'R3', 'R4']) assert.equal(hg.shipEvidenceFor(REPO, 7, H1, policy(), lv), null, lv);
  // リスクを渡さない呼び出しは ship 種別だけ (安全側)
  assert.equal(hg.shipEvidenceFor(REPO, 7, H1, policy()), null);
});

test('human-diff: 署名対象の改ざん (種類・ファイル数・head) は検証で弾く', () => {
  resetStore();
  const a = diffAttest();
  assert.equal(hg.verifyShipAttestation(a, { policy: policy(), headSha: H1 }).ok, true);
  // v2 を v1 に見せかけて review_kind を消す → 署名対象が変わるので不正
  const downgraded = { ...a, schema: hg.ATTEST_SCHEMA };
  assert.equal(hg.verifyShipAttestation(downgraded, { policy: policy(), headSha: H1 }).reason, 'BAD_SIGNATURE');
  assert.equal(hg.verifyShipAttestation({ ...a, files_reviewed: 30 }, { policy: policy(), headSha: H1 }).reason, 'BAD_SIGNATURE');
  assert.equal(hg.verifyShipAttestation({ ...a, review_kind: 'ship' }, { policy: policy(), headSha: H1 }).reason, 'BAD_SIGNATURE');
  assert.equal(hg.verifyShipAttestation({ ...a, review_kind: 'auto' }, { policy: policy(), headSha: H1 }).reason, 'REVIEW_KIND_INVALID');
  assert.equal(hg.verifyShipAttestation(a, { policy: policy(), headSha: H2 }).reason, 'STALE_HEAD');
});

test('human-diff: 発行時の入力検証 (ファイル数必須・watch は not-started・種類は既知のみ)', () => {
  assert.throws(() => diffAttest({ filesReviewed: null }), /FILES_REVIEWED_REQUIRED/);
  assert.throws(() => diffAttest({ filesReviewed: 0 }), /FILES_REVIEWED_REQUIRED/);
  assert.throws(() => diffAttest({ watchStatus: 'checks-pass-comments-answered' }), /WATCH_STATUS_MUST_BE_NOT_STARTED/);
  assert.throws(() => diffAttest({ reviewKind: 'auto' }), /REVIEW_KIND_INVALID/);
});

test('human-diff: 従来 (v1) の /ship 署名はすべてのリスクで引き続き有効', () => {
  resetStore();
  const a = hg.issueShipAttestation({ repo: REPO, pr: 7, headSha: H1, reviewed: true, importantOpen: 0, watchStatus: 'not-started', bundle, privateKey: priv });
  assert.equal(a.schema, hg.ATTEST_SCHEMA);
  assert.equal(a.review_kind, undefined);
  putAttest(a);
  for (const lv of ['R0', 'R1', 'R2', 'R3', 'R4']) assert.equal(hg.shipEvidenceFor(REPO, 7, H1, policy(), lv).reviewKind, 'ship', lv);
  assert.equal(hg.shipEvidenceFor(REPO, 7, H1, policy()).reviewKind, 'ship');
});

test('human-diff: reviewKindsByRisk が無い旧ポリシーでは ship だけを認める (fail-closed)', () => {
  const old = policy(); old.humanGate = { ...old.humanGate }; delete old.humanGate.reviewKindsByRisk;
  assert.equal(hg.reviewKindAllowed(old, 'R0', 'human-diff'), false);
  assert.equal(hg.reviewKindAllowed(old, 'R0', 'ship'), true);
  const p = policy();
  assert.equal(hg.reviewKindAllowed(p, 'R5', 'ship'), false);
  assert.equal(hg.reviewKindAllowed(p, undefined, 'human-diff'), false);
});

// ---------------- Merge Executor ----------------
function readyState() {
  resetStore();
  const g = mkGate();
  writeQualityPass();
  writeGate(g);
  return { g, a: approve(g) };
}
test('マージ: 全条件を満たすときだけ auto-merge を登録し、GitHub で確認して MERGED を記録', () => {
  const { a } = readyState();
  const gh = fakeGh({ afterEnable: (p) => ({ ...p, state: 'MERGED', mergeCommit: 'e'.repeat(40) }) });
  const r = merge.execute({ repo: REPO, pr: 7, policy: policy(), gh });
  assert.equal(r.state, 'MERGED', JSON.stringify(r.reasons));
  assert.equal(r.confirmed, true);
  assert.equal(r.approval_id, a.approval_id);
  assert.deepEqual(gh.calls.find((c) => c[0] === 'enableAutoMerge'), ['enableAutoMerge', REPO, 7, H1]);
  // 同じ承認では 2 回目は実行できない (nonce 消費済み)
  const r2 = merge.execute({ repo: REPO, pr: 7, policy: policy(), gh: fakeGh() });
  assert.equal(r2.state, 'REFUSED');
  assert.ok(r2.reasons.includes('NO_VALID_HUMAN_APPROVAL'));
});
test('マージ: 承認が無ければ登録しない (承認前マージの防止)', () => {
  readyState();
  fs.rmSync(store.paths.approvalsDir(REPO, 7), { recursive: true });
  const gh = fakeGh();
  const r = merge.execute({ repo: REPO, pr: 7, policy: policy(), gh });
  assert.equal(r.state, 'REFUSED');
  assert.ok(!gh.calls.some((c) => c[0] === 'enableAutoMerge'));
});
test('マージ: 承認後に head が変わったら登録しない', () => {
  readyState();
  const gh = fakeGh({ pr: fakePr({ headRefOid: H2 }) });
  const r = merge.execute({ repo: REPO, pr: 7, policy: policy(), gh });
  assert.equal(r.state, 'REFUSED');
  assert.ok(r.reasons.includes('NO_VALID_HUMAN_APPROVAL'));
  assert.ok(r.reasons.includes('NO_GATE_FOR_HEAD'));
  assert.ok(!gh.calls.some((c) => c[0] === 'enableAutoMerge'));
});
test('マージ: base が進んだら登録しない', () => {
  readyState();
  const r = merge.execute({ repo: REPO, pr: 7, policy: policy(), gh: fakeGh({ pr: fakePr({ baseRefOid: B2 }) }) });
  assert.equal(r.state, 'REFUSED');
  assert.ok(r.reasons.includes('GATE_BASE_STALE'));
});
test('マージ: ruleset が承認 context を必須にしていなければ登録しない (登録 = 即マージの危険)', () => {
  readyState();
  const r = merge.execute({ repo: REPO, pr: 7, policy: policy(), gh: fakeGh({ contexts: ['linux-validate'] }) });
  assert.equal(r.state, 'REFUSED');
  assert.ok(r.reasons.some((x) => x.startsWith('RULESET_DOES_NOT_REQUIRE claudeos/human-approval')));
  const r2 = merge.execute({ repo: REPO, pr: 7, policy: policy(), gh: fakeGh({ contexts: null }) });
  assert.ok(r2.reasons.some((x) => x.startsWith('RULESET_UNREADABLE')));
});
test('マージ: 中央ポリシー施行前 (centralProfileEnforced=false) は登録しない', () => {
  readyState();
  const r = merge.execute({ repo: REPO, pr: 7, policy: policy({ merge: { centralProfileEnforced: false } }), gh: fakeGh() });
  assert.equal(r.state, 'REFUSED');
  assert.ok(r.reasons.some((x) => x.startsWith('CENTRAL_POLICY_PROFILE_NOT_ENFORCED')));
});
test('マージ: draft / conflict / 失敗チェック / ローカル品質なし / 取り消し済み', () => {
  readyState();
  for (const [pr, reason] of [[fakePr({ isDraft: true }), 'PR_DRAFT'], [fakePr({ mergeable: 'CONFLICTING' }), 'MERGE_CONFLICT'],
    [fakePr({ statusChecks: [{ name: 'Secrets scan (gitleaks)', conclusion: 'FAILURE' }] }), 'REQUIRED_CHECKS_FAILING: Secrets scan (gitleaks)'], [fakePr({ state: 'CLOSED' }), 'PR_NOT_OPEN (CLOSED)']]) {
    const r = merge.execute({ repo: REPO, pr: 7, policy: policy(), gh: fakeGh({ pr }) });
    assert.ok(r.reasons.includes(reason), reason + ' / ' + r.reasons.join(','));
  }
  const { a } = readyState();
  hg.revoke(a.approval_id, 'r', 'human');
  assert.equal(merge.execute({ repo: REPO, pr: 7, policy: policy(), gh: fakeGh() }).state, 'REFUSED');
  readyState();
  fs.rmSync(path.join(store.shipHome(), 'quality'), { recursive: true });
  assert.ok(merge.execute({ repo: REPO, pr: 7, policy: policy(), gh: fakeGh() }).reasons.includes('LOCAL_QUALITY_NOT_PASS'));
});
test('マージ: 登録できても GitHub で merged を確認できなければ MERGED と記録しない', () => {
  readyState();
  const r = merge.execute({ repo: REPO, pr: 7, policy: policy(), gh: fakeGh({ afterEnable: (p) => ({ ...p, autoMerge: true }) }) });
  assert.equal(r.state, 'MERGE_QUEUED');
  assert.equal(r.confirmed, false);
  readyState();
  const r2 = merge.execute({ repo: REPO, pr: 7, policy: policy(), gh: fakeGh({ afterEnable: (p) => ({ ...p, state: 'MERGED', mergeCommit: null }) }) });
  assert.equal(r2.state, 'MERGED_UNCONFIRMED');
  assert.equal(r2.confirmed, false);
});
test('マージ: dry-run は nonce を消費せず登録もしない', () => {
  const { a } = readyState();
  const gh = fakeGh();
  assert.equal(merge.execute({ repo: REPO, pr: 7, policy: policy(), gh, dryRun: true }).state, 'DRY_RUN_OK');
  assert.ok(!gh.calls.some((c) => c[0] === 'enableAutoMerge'));
  assert.equal(fs.existsSync(store.paths.consumed(a.nonce)), false);
});
test('マージ: 監査ログに拒否・キュー・観測が連鎖で残る', () => {
  readyState();
  merge.execute({ repo: REPO, pr: 7, policy: policy(), gh: fakeGh({ afterEnable: (p) => ({ ...p, state: 'MERGED', mergeCommit: 'e'.repeat(40) }) }) });
  const events = fs.readFileSync(store.paths.audit(), 'utf8').trim().split('\n').map((l) => JSON.parse(l).event);
  for (const e of ['approval_consumed', 'merge_queued', 'merge_observed']) assert.ok(events.includes(e), e);
  assert.equal(store.verifyAuditChain().ok, true);
});
