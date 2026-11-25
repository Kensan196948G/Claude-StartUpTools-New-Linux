'use strict';
/**
 * human-gate.js — Human Gate (人間の最終承認) の暗号的な強制
 *
 * 前提 (実機確認 2026-11-24): AI エージェントは人間と同じ OS ユーザーで動き、パスワード無し sudo と
 * admin 権限の gh token を持つ。したがって OS 権限・ファイル所有・Web ボタンでは「人間が承認した」を証明できない。
 *
 * 設計: 承認 = 人間だけが知るパスフレーズで保護された Ed25519 秘密鍵による署名。
 *   - 鍵束 (~/.config/claudeos-approver/key.json): Ed25519 秘密鍵を scrypt(N=2^17) + AES-256-GCM で暗号化
 *   - パスフレーズは /dev/tty から echo 無しで読む (引数・環境変数・stdin パイプでは受け付けない)
 *   - 署名対象: repo / PR / head SHA / base SHA / 品質判定 (gate の hash・verdict) / 品質証跡 hash /
 *     リスク / 承認者 / 発行・失効時刻 / nonce / ポリシー版 の正規形 JSON
 *   - 検証鍵: base ブランチ (origin/main) の config/ship-policy.json の humanGate.approverKeys に登録された
 *     fingerprint と一致する公開鍵だけ (PR の変更で鍵を足しても効かない)
 *   - head / base が変われば無効 (SHA 固定)。期限切れ・取り消し・使用済み nonce も無効
 *
 * 防げるもの: AI による承認の偽装・代理生成、古い承認の流用・リプレイ、承認後のコード差し替え、
 *             PR 内でのポリシー緩和による自己承認。
 * 防げないもの (残存リスク。docs/architecture/SHIP_SECURITY_MODEL.md): root 権限で人間の承認プロセスの
 *   メモリを覗く・入力を盗むといった能動的に悪意あるエージェント。完全な対策は AI を sudo 無しの別 OS ユーザーで
 *   動かすこと (人間承認事項)。
 */

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const { spawnSync } = require('node:child_process');
const store = require('./store');

const SCRYPT = { N: 1 << 17, r: 8, p: 1, maxmem: 512 * 1024 * 1024 };
const MIN_PASSPHRASE = 12;

function defaultKeyFile() {
  return process.env.CLAUDEOS_APPROVER_KEY || path.join(os.homedir(), '.config', 'claudeos-approver', 'key.json');
}

function fingerprint(publicKeyDer) { return 'sha256:' + store.sha256(publicKeyDer); }

// --- 鍵束の暗号化 / 復号 -------------------------------------------------
function wrap(secretDer, passphrase, kdf = SCRYPT) {
  const salt = crypto.randomBytes(16); const iv = crypto.randomBytes(12);
  const key = crypto.scryptSync(passphrase.normalize('NFKC'), salt, 32, kdf);
  const c = crypto.createCipheriv('aes-256-gcm', key, iv);
  const ct = Buffer.concat([c.update(secretDer), c.final()]);
  return { kdf: 'scrypt', N: kdf.N, r: kdf.r, p: kdf.p, salt: salt.toString('base64'), iv: iv.toString('base64'),
    tag: c.getAuthTag().toString('base64'), ct: ct.toString('base64') };
}
function unwrap(w, passphrase) {
  if (w.kdf !== 'scrypt') throw new Error('UNSUPPORTED_KDF');
  if (w.N < (1 << 14) && !w.test) throw new Error('KDF_TOO_WEAK');
  const key = crypto.scryptSync(passphrase.normalize('NFKC'), Buffer.from(w.salt, 'base64'), 32,
    { N: w.N, r: w.r, p: w.p, maxmem: SCRYPT.maxmem });
  const d = crypto.createDecipheriv('aes-256-gcm', key, Buffer.from(w.iv, 'base64'));
  d.setAuthTag(Buffer.from(w.tag, 'base64'));
  try { return Buffer.concat([d.update(Buffer.from(w.ct, 'base64')), d.final()]); } catch { throw new Error('BAD_PASSPHRASE'); }
}

function checkPassphraseStrength(p) {
  if (typeof p !== 'string' || [...p].length < MIN_PASSPHRASE) throw new Error(`PASSPHRASE_TOO_SHORT (>= ${MIN_PASSPHRASE})`);
  if (new Set(p).size < 6) throw new Error('PASSPHRASE_TOO_SIMPLE');
}

/** generateKey(name, passphrase) → 鍵束オブジェクト (保存は呼び出し側) */
function generateKey(name, passphrase, { kdf = SCRYPT, test = false } = {}) {
  checkPassphraseStrength(passphrase);
  if (!/^[\p{L}\p{N} ._@-]{1,80}$/u.test(String(name))) throw new Error('INVALID_APPROVER_NAME');
  const { publicKey, privateKey } = crypto.generateKeyPairSync('ed25519');
  const pubDer = publicKey.export({ type: 'spki', format: 'der' });
  const privDer = privateKey.export({ type: 'pkcs8', format: 'der' });
  return {
    schema: 'claudeos.approver-key/v1', name, test: !!test,
    created_at: new Date().toISOString(),
    public_key: pubDer.toString('base64'), key_id: fingerprint(pubDer),
    wrapped: { ...wrap(privDer, passphrase, kdf), test: !!test },
  };
}

function loadPrivateKey(bundle, passphrase) {
  const der = unwrap(bundle.wrapped, passphrase);
  const priv = crypto.createPrivateKey({ key: der, format: 'der', type: 'pkcs8' });
  // 復号した秘密鍵が鍵束の公開鍵と対であることを確認
  const pub = crypto.createPublicKey(priv).export({ type: 'spki', format: 'der' });
  if (fingerprint(pub) !== bundle.key_id) throw new Error('KEY_MISMATCH');
  return priv;
}

/**
 * readPassphraseFromTty(prompt) — /dev/tty から echo 無しで読む。TTY が無ければ拒否。
 * テスト専用: 鍵束が test:true のときだけ CLAUDEOS_SHIP_TEST_PASSPHRASE を使う
 * (パスフレーズの知識が証明の本体なので、入力経路を増やしても AI に承認能力は生じない。
 *  本番鍵では人間がパスフレーズを環境変数へ置いて AI に見られる事故を防ぐため拒否する)。
 */
function readPassphrase(bundle, prompt = '承認パスフレーズ: ') {
  if (bundle && bundle.test === true && bundle.wrapped && bundle.wrapped.test === true
      && typeof process.env.CLAUDEOS_SHIP_TEST_PASSPHRASE === 'string') {
    return process.env.CLAUDEOS_SHIP_TEST_PASSPHRASE;
  }
  let fd;
  try { fd = fs.openSync('/dev/tty', 'r+'); } catch { throw new Error('NO_TTY (承認は人間の端末から対話入力でのみ行える)'); }
  try {
    const tty = { stdio: [fd, fd, 'ignore'] };
    if (spawnSync('stty', ['-echo'], tty).status !== 0) throw new Error('NO_TTY');
    fs.writeSync(fd, prompt);
    const buf = Buffer.alloc(1024); let s = '';
    for (;;) {
      const n = fs.readSync(fd, buf, 0, buf.length, null);
      if (n <= 0) break;
      s += buf.subarray(0, n).toString('utf8');
      if (s.includes('\n')) break;
    }
    spawnSync('stty', ['echo'], tty);
    fs.writeSync(fd, '\n');
    return s.replace(/\r?\n[\s\S]*$/, '');
  } finally { fs.closeSync(fd); }
}

// --- 承認の発行 / 検証 ---------------------------------------------------
const SIGNED_FIELDS = ['schema', 'approval_id', 'repo', 'pr', 'head_sha', 'base_sha', 'gate_verdict', 'gate_hash',
  'quality_eval_id', 'quality_evidence_hash', 'risk', 'approver', 'key_id', 'issued_at', 'expires_at', 'nonce',
  'policy_version', 'decision'];

function signedPayload(a) {
  const o = {};
  for (const k of SIGNED_FIELDS) o[k] = a[k] === undefined ? null : a[k];
  return store.canonical(o);
}

function gateHash(gate) {
  return store.sha256(store.canonical({ repo: gate.repo, pr: gate.pr, head_sha: gate.head_sha, base_sha: gate.base_sha,
    verdict: gate.verdict, risk: gate.risk, policy_version: gate.policy_version, quality_eval_id: gate.quality_eval_id || null }));
}

/**
 * issueApproval({gate, quality, bundle, privateKey, policy, decision}) — 署名済み承認を作る。
 * PASS 以外の gate には承認を発行しない (CONDITIONAL の個別判断は decision:'approve-conditional' を明示し、
 * それでも Merge Executor は PASS 以外を自動マージしない)。
 */
function issueApproval({ gate, quality, bundle, privateKey, policy, decision = 'approve', now = new Date() }) {
  if (!gate || !gate.head_sha || !gate.base_sha) throw new Error('GATE_REQUIRED');
  if (decision === 'approve' && gate.verdict !== 'PASS') throw new Error('GATE_NOT_PASS (' + gate.verdict + ')');
  if (!['approve', 'approve-conditional', 'reject'].includes(decision)) throw new Error('INVALID_DECISION');
  const ttl = Number(policy.humanGate.approvalTtlHours || 24);
  const a = {
    schema: store.SCHEMA.approval,
    approval_id: store.newId('ha'),
    repo: store.assertRepo(gate.repo), pr: store.assertPr(gate.pr),
    head_sha: store.assertSha(gate.head_sha, 'head'), base_sha: store.assertSha(gate.base_sha, 'base'),
    gate_verdict: gate.verdict, gate_hash: gateHash(gate),
    quality_eval_id: quality ? quality.eval_id : null, quality_evidence_hash: quality ? quality.evidence_hash : null,
    risk: gate.risk, approver: bundle.name, key_id: bundle.key_id,
    issued_at: now.toISOString(), expires_at: new Date(now.getTime() + ttl * 3600 * 1000).toISOString(),
    nonce: crypto.randomBytes(16).toString('hex'), policy_version: policy.policyVersion, decision,
  };
  a.signature = crypto.sign(null, Buffer.from(signedPayload(a)), privateKey).toString('base64');
  return a;
}

/** trustedKeys(policy, keyBundles) — policy の fingerprint 一覧に一致する公開鍵だけを返す */
function resolveTrustedKey(policy, approval, publicKeyB64) {
  const list = (policy.humanGate.approverKeys || []);
  const entry = list.find((k) => k.key_id === approval.key_id);
  if (!entry) return { ok: false, reason: 'KEY_NOT_TRUSTED' };
  if (entry.name && entry.name !== approval.approver) return { ok: false, reason: 'APPROVER_NAME_MISMATCH' };
  const b64 = publicKeyB64 || entry.public_key;
  if (!b64) return { ok: false, reason: 'PUBLIC_KEY_MISSING' };
  const der = Buffer.from(b64, 'base64');
  if (fingerprint(der) !== approval.key_id) return { ok: false, reason: 'FINGERPRINT_MISMATCH' };
  return { ok: true, key: crypto.createPublicKey({ key: der, format: 'der', type: 'spki' }) };
}

/**
 * verifyApproval(approval, ctx) → { ok, reason }
 * ctx: { policy (trusted), headSha, baseSha, gate (現在の head の gate), now, checkConsumed=true }
 */
function verifyApproval(approval, ctx) {
  const { policy, headSha, baseSha, gate, now = new Date(), checkConsumed = true } = ctx;
  if (!approval || approval.schema !== store.SCHEMA.approval) return { ok: false, reason: 'NOT_AN_APPROVAL' };
  if (typeof approval.signature !== 'string') return { ok: false, reason: 'UNSIGNED' };
  const tk = resolveTrustedKey(policy, approval);
  if (!tk.ok) return tk;
  let sigOk = false;
  try { sigOk = crypto.verify(null, Buffer.from(signedPayload(approval)), tk.key, Buffer.from(approval.signature, 'base64')); } catch { sigOk = false; }
  if (!sigOk) return { ok: false, reason: 'BAD_SIGNATURE' };
  if (approval.decision !== 'approve') return { ok: false, reason: 'NOT_APPROVE_DECISION (' + approval.decision + ')' };
  if (approval.head_sha !== headSha) return { ok: false, reason: 'STALE_HEAD' };
  if (approval.base_sha !== baseSha) return { ok: false, reason: 'STALE_BASE' };
  if (Date.parse(approval.expires_at) <= now.getTime()) return { ok: false, reason: 'EXPIRED' };
  if (Date.parse(approval.issued_at) > now.getTime() + 5 * 60 * 1000) return { ok: false, reason: 'ISSUED_IN_FUTURE' };
  if (fs.existsSync(store.paths.revocation(approval.approval_id))) return { ok: false, reason: 'REVOKED' };
  if (checkConsumed && fs.existsSync(store.paths.consumed(approval.nonce))) return { ok: false, reason: 'NONCE_CONSUMED' };
  if (gate) {
    if (gate.verdict !== 'PASS') return { ok: false, reason: 'GATE_NOT_PASS' };
    if (gateHash(gate) !== approval.gate_hash) return { ok: false, reason: 'GATE_CHANGED' };
  }
  return { ok: true };
}

/** findValidApproval(repo, pr, ctx) — 有効な承認を 1 つ探す (無ければ理由一覧) */
function findValidApproval(repo, pr, ctx) {
  const results = [];
  for (const f of store.listJson(store.paths.approvalsDir(repo, pr))) {
    const a = store.readRecord(f);
    const v = verifyApproval(a, ctx);
    results.push({ approval_id: a && a.approval_id, ...v });
    if (v.ok) return { approval: a, results };
  }
  return { approval: null, results };
}

/** consume(approval) — nonce を使用済みにする (排他作成。2 回目は失敗 = リプレイ防止) */
function consume(approval) {
  const file = store.paths.consumed(approval.nonce);
  store.ensureDir(path.dirname(file));
  try { fs.writeFileSync(file, approval.approval_id + '\n', { flag: 'wx', mode: 0o600 }); } catch (e) {
    if (e.code === 'EEXIST') throw new Error('NONCE_CONSUMED');
    throw e;
  }
  store.appendAudit('approval_consumed', { approval_id: approval.approval_id, repo: approval.repo, pr: approval.pr, head_sha: approval.head_sha });
}

function revoke(approvalId, reason, actor) {
  const rec = { schema: store.SCHEMA.revocation, approval_id: store.assertId(approvalId), reason: String(reason || '').slice(0, 500), actor: String(actor || 'unknown').slice(0, 200), at: new Date().toISOString() };
  store.writeRecord(store.paths.revocation(approvalId), rec, { exclusive: true });
  store.appendAudit('approval_revoked', { approval_id: approvalId, actor: rec.actor, reason: rec.reason });
  return rec;
}

// --- Ship レビューの証跡 (人間署名) --------------------------------------
// Max X20 の /ship は人間が対話セッションで入力したときだけ動く (headless 不可)。その結果を AI が自己申告すると
// 品質判定の入力を AI が書けてしまうため、/ship を実行した人間が見た結果を署名して残す。
// v1: /ship の結果への署名 (review_kind を持たない。互換のため検証は従来どおり)。
// v2: review_kind (ship | human-diff) と、human-diff のとき人が確認した変更ファイル数を署名対象に含める。
//     どの種類をどのリスクで認めるかは policy.humanGate.reviewKindsByRisk が決める (gate 側で判定)。
const ATTEST_SCHEMA = 'claudeos.ship-attestation/v1';
const ATTEST_SCHEMA_V2 = 'claudeos.ship-attestation/v2';
const ATTEST_FIELDS = ['schema', 'attestation_id', 'repo', 'pr', 'head_sha', 'reviewed', 'review_effort', 'important_open',
  'watch_status', 'notes', 'approver', 'key_id', 'issued_at', 'nonce'];
const ATTEST_FIELDS_V2 = [...ATTEST_FIELDS, 'review_kind', 'files_reviewed'];
const REVIEW_KINDS = ['ship', 'human-diff'];
function attestPayload(a) {
  const fields = a.schema === ATTEST_SCHEMA_V2 ? ATTEST_FIELDS_V2 : ATTEST_FIELDS;
  const o = {}; for (const k of fields) o[k] = a[k] === undefined ? null : a[k]; return store.canonical(o);
}
/** 証跡の種類。v1 は常に ship */
function reviewKindOf(a) { return a && a.schema === ATTEST_SCHEMA_V2 ? a.review_kind : 'ship'; }

function issueShipAttestation({ repo, pr, headSha, reviewed, importantOpen, watchStatus, reviewEffort = 'high', notes = '',
  reviewKind = 'ship', filesReviewed = null, bundle, privateKey, now = new Date() }) {
  if (typeof reviewed !== 'boolean') throw new Error('REVIEWED_BOOLEAN_REQUIRED');
  const n = Number(importantOpen);
  if (!Number.isInteger(n) || n < 0) throw new Error('IMPORTANT_OPEN_INVALID');
  if (!REVIEW_KINDS.includes(reviewKind)) throw new Error('REVIEW_KIND_INVALID');
  let files = null;
  if (reviewKind === 'human-diff') {
    // 人が差分を読んだ宣言。watch は存在しないので not-started 固定、確認したファイル数を必須にする
    if (watchStatus !== 'not-started') throw new Error('WATCH_STATUS_MUST_BE_NOT_STARTED_FOR_HUMAN_DIFF');
    files = Number(filesReviewed);
    if (!Number.isInteger(files) || files < 1) throw new Error('FILES_REVIEWED_REQUIRED');
  }
  if (!['checks-pass-comments-answered', 'stopped', 'not-started', 'running'].includes(watchStatus)) throw new Error('WATCH_STATUS_INVALID');
  const v2 = reviewKind !== 'ship';
  const a = { schema: v2 ? ATTEST_SCHEMA_V2 : ATTEST_SCHEMA, attestation_id: store.newId('sa'), repo: store.assertRepo(repo), pr: store.assertPr(pr),
    head_sha: store.assertSha(headSha, 'head'), reviewed, review_effort: String(reviewEffort), important_open: n,
    watch_status: watchStatus, notes: String(notes).slice(0, 500), approver: bundle.name, key_id: bundle.key_id,
    issued_at: now.toISOString(), nonce: crypto.randomBytes(16).toString('hex') };
  if (v2) { a.review_kind = reviewKind; a.files_reviewed = files; }
  a.signature = crypto.sign(null, Buffer.from(attestPayload(a)), privateKey).toString('base64');
  return a;
}

function verifyShipAttestation(a, { policy, headSha }) {
  if (!a || (a.schema !== ATTEST_SCHEMA && a.schema !== ATTEST_SCHEMA_V2) || typeof a.signature !== 'string') return { ok: false, reason: 'NOT_AN_ATTESTATION' };
  if (a.schema === ATTEST_SCHEMA_V2 && !REVIEW_KINDS.includes(a.review_kind)) return { ok: false, reason: 'REVIEW_KIND_INVALID' };
  const tk = resolveTrustedKey(policy, a);
  if (!tk.ok) return tk;
  let ok = false;
  try { ok = crypto.verify(null, Buffer.from(attestPayload(a)), tk.key, Buffer.from(a.signature, 'base64')); } catch { ok = false; }
  if (!ok) return { ok: false, reason: 'BAD_SIGNATURE' };
  if (a.head_sha !== headSha) return { ok: false, reason: 'STALE_HEAD' };
  return { ok: true };
}

function shipEvidenceDir(repo, pr) { return path.join(store.shipHome(), 'ship-evidence', store.slug(repo), 'pr-' + store.assertPr(pr)); }

/**
 * reviewKindAllowed(policy, riskLevel, kind) — そのリスクでその種類のレビュー証跡を認めるか。
 * 未記載のリスク・種類は認めない (fail-closed)。reviewKindsByRisk 自体が無い旧ポリシーでは ship だけを認める。
 */
function reviewKindAllowed(policy, riskLevel, kind) {
  const map = policy && policy.humanGate && policy.humanGate.reviewKindsByRisk;
  if (!map) return kind === 'ship';
  const allowed = map[riskLevel];
  return Array.isArray(allowed) && allowed.includes(kind);
}

/**
 * shipEvidenceFor(repo, pr, head, policy, riskLevel) → gate の ship 入力 ({reviewed, importantFindingsOpen, source, reviewKind} or null)
 * riskLevel は gate が変更ファイルから計算した値 (署名側の申告は使わない)。そのリスクで認めない種類の証跡は無視する。
 * riskLevel が無い呼び出しは ship 種別だけを認める (安全側)。
 */
function shipEvidenceFor(repo, pr, headSha, policy, riskLevel = null) {
  const valid = [];
  for (const f of store.listJson(shipEvidenceDir(repo, pr))) {
    const a = store.readRecord(f);
    if (!verifyShipAttestation(a, { policy, headSha }).ok) continue;
    const kind = reviewKindOf(a);
    if (riskLevel ? !reviewKindAllowed(policy, riskLevel, kind) : kind !== 'ship') continue;
    valid.push(a);
  }
  if (!valid.length) return null;
  valid.sort((x, y) => String(x.issued_at).localeCompare(String(y.issued_at)));
  const a = valid[valid.length - 1];
  const kind = reviewKindOf(a);
  const prefix = kind === 'human-diff' ? 'human-diff-attestation:' : 'human-signed-attestation:';
  return { reviewed: a.reviewed === true, importantFindingsOpen: a.important_open, watchStatus: a.watch_status, reviewKind: kind, source: prefix + a.attestation_id };
}

module.exports = {
  issueShipAttestation, verifyShipAttestation, shipEvidenceFor, shipEvidenceDir, ATTEST_SCHEMA, ATTEST_SCHEMA_V2,
  REVIEW_KINDS, reviewKindOf, reviewKindAllowed,
  generateKey, loadPrivateKey, readPassphrase, issueApproval, verifyApproval, findValidApproval,
  consume, revoke, gateHash, signedPayload, fingerprint, wrap, unwrap, defaultKeyFile, checkPassphraseStrength,
  resolveTrustedKey, SCRYPT,
};
