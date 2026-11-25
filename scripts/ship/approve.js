#!/usr/bin/env node
'use strict';
/**
 * approve.js — Human Gate CLI (人間専用。bin/ship-approve.sh から呼ぶ)
 *
 *   keygen --name NAME                     承認鍵を作る (パスフレーズを端末で 2 回入力)。
 *                                          出力の key_id / public_key を config/ship-policy.json の
 *                                          humanGate.approverKeys へ追加する PR を人が作りマージする (bootstrap)
 *   show   --repo O/R --pr N               承認前の確認画面 (gate / 品質証跡 / リスク / 現在の head・base)
 *   approve --repo O/R --pr N --head SHA   署名して承認。--head は人が画面で確認した SHA (現在の head と一致必須)
 *   reject  --repo O/R --pr N --head SHA --reason R   差し戻し (署名付き記録)
 *   revoke  --id APPROVAL_ID --reason R    承認取り消し (安全側の操作なので署名不要)
 *   ship-attest --repo O/R --pr N --head SHA --workdir DIR --reviewed yes|no --important-open N --watch STATUS [--effort E] [--notes T]
 *                                          対話セッションで /ship を実行した人が、見た結果を署名して残す。
 *                                          署名の前に 2 つの安全装置が働く (パスフレーズより前):
 *                                          (1) --workdir (/ship を実行した作業フォルダ) が --head の版で、未コミットの変更が無いこと。
 *                                              /ship が修正を作業フォルダに残したまま署名するのを止める
 *                                          (2) --reviewed yes のとき、/ship の結果にあった重大な指摘 (important) の件数を
 *                                              端末で入力し直させ、--important-open と一致しなければ止める
 *   ship-attest --kind human-diff --repo O/R --pr N --head SHA --important-open N [--notes T]
 *                                          R0・R1 の PR で、人が gh pr diff で差分を読んだことを署名して残す。
 *                                          変更ファイルの一覧とリスク分類を表示し、確認してから署名する。
 *                                          R2 以上では gate が認めない (policy.humanGate.reviewKindsByRisk)
 *
 * パスフレーズは /dev/tty からのみ読む。AI エージェント (Bash tool) には TTY が無いため承認できない。
 * それでも AI が人間の端末を乗っ取る脅威は残る — docs/architecture/SHIP_SECURITY_MODEL.md。
 */

const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const store = require('./lib/store');
const hg = require('./lib/human-gate');
const policyLib = require('./lib/policy');
const quality = require('./lib/quality');
const github = require('./lib/github');
const ghApp = require('./lib/github-app');
const { parse } = require('./ship');

function readBundle() {
  const f = hg.defaultKeyFile();
  const b = store.readRecord(f);
  if (!b || b.schema !== 'claudeos.approver-key/v1') throw Object.assign(new Error('NO_APPROVER_KEY (' + f + ') — keygen を先に実行'), { exit: 3 });
  return b;
}
function say(s) { process.stdout.write(s + '\n'); }
function confirmTty(question) {
  if (process.env.CLAUDEOS_SHIP_TEST_CONFIRM === 'yes' && readBundleSafe()?.test === true) return true;
  let fd; try { fd = fs.openSync('/dev/tty', 'r+'); } catch { throw Object.assign(new Error('NO_TTY'), { exit: 1 }); }
  try {
    fs.writeSync(fd, question + ' [yes/NO]: ');
    const buf = Buffer.alloc(64); const n = fs.readSync(fd, buf, 0, 64, null);
    return buf.subarray(0, n).toString('utf8').trim() === 'yes';
  } finally { fs.closeSync(fd); }
}
function readBundleSafe() { try { return readBundle(); } catch { return null; } }

/** 件数は端末から 1 行読む。環境変数はテスト専用の鍵束でのみ使う。 */
function readImportantCount(bundle, question) {
  if (bundle.test === true && bundle.wrapped?.test === true && typeof process.env.CLAUDEOS_SHIP_TEST_IMPORTANT === 'string') {
    return process.env.CLAUDEOS_SHIP_TEST_IMPORTANT;
  }
  let fd; try { fd = fs.openSync('/dev/tty', 'r+'); } catch { throw Object.assign(new Error('NO_TTY'), { exit: 1 }); }
  try {
    fs.writeSync(fd, question);
    const buf = Buffer.alloc(64); const n = fs.readSync(fd, buf, 0, buf.length, null);
    const line = buf.subarray(0, n).toString('utf8');
    return line.endsWith('\n') ? line.trim() : ''; // EOF や途中で切れた行を件数として認めない
  } finally { fs.closeSync(fd); }
}

/**
 * checkReviewWorkdir — /ship を実行した作業フォルダの版と状態を確かめる。
 * レビュー中の修正が PR に取り込まれていない状態で署名する事故を防ぐ。
 * Git が報告する未追跡ファイルも変更として扱う。
 */
function checkReviewWorkdir(dir, headSha) {
  const abs = path.resolve(dir);
  // 呼び出し元の git hook などが設定した別のリポジトリ・index を参照しない。
  const env = { ...process.env };
  for (const name of ['GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE', 'GIT_COMMON_DIR', 'GIT_OBJECT_DIRECTORY',
    'GIT_ALTERNATE_OBJECT_DIRECTORIES', 'GIT_IMPLICIT_WORK_TREE', 'GIT_PREFIX', 'GIT_CONFIG', 'GIT_CONFIG_COUNT', 'GIT_CONFIG_PARAMETERS']) delete env[name];
  const git = (...a) => spawnSync('git', ['--no-optional-locks', '--no-replace-objects', '-c', 'core.fsmonitor=false', '-C', abs, ...a],
    { encoding: 'utf8', env, timeout: 10000 });
  const root = git('rev-parse', '--path-format=absolute', '--show-toplevel');
  if (root.status !== 0 || root.stderr) throw Object.assign(new Error(`REVIEW_WORKDIR_NOT_GIT: ${JSON.stringify(abs)} の Git 作業フォルダを確認できません`), { exit: 2 });
  const workdir = fs.realpathSync(root.stdout.replace(/\n$/, ''));
  function verifyHead() {
    const rev = git('rev-parse', '--verify', 'HEAD^{commit}');
    const head = rev.status === 0 && !rev.stderr ? rev.stdout.trim() : '';
    if (head !== headSha) {
      throw Object.assign(new Error(`REVIEW_WORKDIR_HEAD_MISMATCH: 作業フォルダの版 ${head || '(不明)'} が署名する版 ${headSha} と違います。`
        + ' /ship はこの版を取り出した作業フォルダで実行してください'), { exit: 1 });
    }
  }
  verifyHead();
  // git status より先に確認する。外部 clean/process フィルターは署名者の権限で動かさない。
  const filters = git('config', '--name-only', '--get-regexp', '^filter\\..*\\.(clean|process)$');
  const index = git('ls-files', '-v', '--stage', '-z');
  if (filters.status !== 1 || filters.stderr || index.status !== 0 || index.stderr ||
      index.stdout.split('\0').some((f) => f && (!f.startsWith('H ') || f.startsWith('H 160000 ')))) {
    throw Object.assign(new Error('REVIEW_WORKDIR_UNSUPPORTED: 外部 Git フィルター・サブモジュール・特殊なインデックス状態の無い作業フォルダを使用してください'), { exit: 1 });
  }
  const st = git('status', '--porcelain=v1', '--untracked-files=all', '--ignore-submodules=all');
  if (st.status !== 0 || st.stderr) throw Object.assign(new Error('REVIEW_WORKDIR_STATUS_FAILED: 作業フォルダの状態を確認できません'), { exit: 1 });
  verifyHead();
  if (st.stdout.length) {
    throw Object.assign(new Error('REVIEW_WORKDIR_DIRTY: 未コミットの変更または未追跡ファイルがあります。'
      + ' 署名を中止しました。指定した作業フォルダで git status --short --untracked-files=all を確認してください'), { exit: 1 });
  }
  return { workdir, head: headSha };
}

function context(o) {
  const pol = policyLib.loadTrustedPolicy(o.project ? path.resolve(o.project) : policyLib.REPO_ROOT, o['base-ref'] || 'origin/main');
  const p = github.fetchPr(o.repo, o.pr);
  if (!p.ok) throw Object.assign(new Error('PR_FETCH ' + p.error), { exit: 3 });
  const pr = p.data;
  const gate = store.readRecord(store.paths.gate(o.repo, o.pr, pr.headRefOid));
  const q = quality.latestEvidence(o.repo, pr.headRefOid);
  return { pol, pr, gate, q };
}

function show(ctx) {
  const { pr, gate, q } = ctx;
  say('━━━ ClaudeOS Human Gate — 最終確認 ━━━');
  say(`PR         : ${pr.url}  (${pr.title})`);
  say(`状態       : ${pr.state}${pr.isDraft ? ' / DRAFT' : ''}  mergeable=${pr.mergeable}`);
  say(`head SHA   : ${pr.headRefOid}`);
  say(`base       : ${pr.baseRefName} @ ${pr.baseRefOid}`);
  say(`品質判定   : ${gate ? gate.verdict : '未判定 (ship gate を先に実行)'}  リスク=${gate ? gate.risk : '?'}`);
  if (gate && gate.reasons.length) gate.reasons.slice(0, 20).forEach((r) => say('   - ' + r));
  say(`ローカル品質: ${q.evidence ? `${q.evidence.verdict} (eval ${q.evidence.eval_id}, ${q.evidence.checks.length} checks, 封印 OK)` : '証跡なし'}`);
  if (q.rejected.length) say(`   ⚠ 封印検証に失敗した証跡 ${q.rejected.length} 件を除外`);
  say(`GitHub checks: ${(pr.statusChecks || []).map((c) => `${c.name}=${c.conclusion || c.status}`).join(', ') || 'なし'}`);
  say('この承認は上記 head SHA と base SHA に固定されます。1 コミットでも変われば無効になります。');
}

const cmds = {
  keygen(o) {
    if (!o.name) throw Object.assign(new Error('MISSING --name'), { exit: 2 });
    const f = hg.defaultKeyFile();
    if (fs.existsSync(f) && !o.force) throw Object.assign(new Error('KEY_EXISTS ' + f), { exit: 1 });
    const p1 = hg.readPassphrase(null, '新しい承認パスフレーズ (12 文字以上): ');
    const p2 = hg.readPassphrase(null, 'もう一度: ');
    if (p1 !== p2) throw Object.assign(new Error('PASSPHRASE_MISMATCH'), { exit: 1 });
    const b = hg.generateKey(o.name, p1);
    store.ensureDir(path.dirname(f));
    fs.writeFileSync(f, JSON.stringify(b, null, 2) + '\n', { mode: 0o600, flag: o.force ? 'w' : 'wx' });
    store.appendAudit('approver_key_created', { key_id: b.key_id, approver: b.name });
    say(`鍵を保存しました: ${f}`);
    say('次の 1 行を config/ship-policy.json の humanGate.approverKeys に追加する PR を作り、内容を自分で確認してマージしてください:');
    say(JSON.stringify({ name: b.name, key_id: b.key_id, public_key: b.public_key }));
    return 0;
  },
  'attach-app'(o) {
    for (const k of ['app-id', 'installation-id', 'pem']) if (!o[k] || o[k] === true) throw Object.assign(new Error('MISSING --' + k), { exit: 2 });
    const bundle = readBundle();
    const pass = hg.readPassphrase(bundle, 'GitHub App 鍵を暗号化するパスフレーズ (承認パスフレーズ): ');
    const pem = fs.readFileSync(o.pem, 'utf8');
    const nb = ghApp.attachApp(bundle, pass, { appId: o['app-id'], installationId: o['installation-id'], pem });
    fs.writeFileSync(hg.defaultKeyFile(), JSON.stringify(nb, null, 2) + '\n', { mode: 0o600 });
    store.appendAudit('approver_app_attached', { key_id: nb.key_id, app_id: nb.github_app.app_id });
    say(`GitHub App ${nb.github_app.app_id} を鍵束に暗号化して格納しました。元の PEM ファイル (${o.pem}) は安全に削除してください。`);
    return 0;
  },
  show(o) { show(context(o)); return 0; },
  approve(o) { return decide(o, 'approve'); },
  reject(o) { return decide(o, 'reject'); },
  revoke(o) {
    if (!o.id) throw Object.assign(new Error('MISSING --id'), { exit: 2 });
    const r = hg.revoke(o.id, o.reason || '', process.env.USER || 'human');
    say(JSON.stringify(r));
    return 0;
  },
  'ship-attest'(o) {
    // --kind が指定されたら (値なし・空も含む) ship 以外は humanDiffAttest で検証する
    if (o.kind != null && o.kind !== 'ship') return humanDiffAttest(o);
    for (const k of ['repo', 'pr', 'head', 'workdir', 'reviewed', 'important-open', 'watch']) if (!o[k] || o[k] === true) throw Object.assign(new Error('MISSING --' + k), { exit: 2 });
    store.assertSha(o.head, 'head');
    const repo = store.assertRepo(o.repo);
    const pr = store.assertPr(o.pr);
    const reviewed = o.reviewed === 'yes';
    if (!reviewed && o.reviewed !== 'no') throw Object.assign(new Error('REVIEWED_MUST_BE_YES_OR_NO'), { exit: 2 });
    const importantOpen = Number(o['important-open']);
    if (!/^(0|[1-9]\d*)$/.test(o['important-open']) || !Number.isSafeInteger(importantOpen)) {
      throw Object.assign(new Error('IMPORTANT_OPEN_INVALID: 重大な指摘の件数は 0 以上の整数で指定してください'), { exit: 2 });
    }
    // 署名前に /ship を実行した作業フォルダ・対象 SHA・重大所見の件数を確認する。
    const wd = checkReviewWorkdir(o.workdir, o.head);
    const bundle = readBundle();
    if (reviewed) {
      const typed = readImportantCount(bundle, `対象: ${repo} #${pr} @ ${wd.head}\n作業フォルダ: ${JSON.stringify(wd.workdir)}\n/ship が報告した未解決の重大な指摘の件数を入力してください (nit は数えない): `);
      if (typed !== String(importantOpen)) {
        throw Object.assign(new Error('IMPORTANT_OPEN_MISMATCH: 入力した件数が --important-open と一致しません。署名を中止しました'), { exit: 1 });
      }
    }
    const pass = hg.readPassphrase(bundle, `Ship 結果の証明 (PR #${pr}) パスフレーズ: `);
    const key = hg.loadPrivateKey(bundle, pass);
    // 端末での入力待ちの間にファイルや HEAD が変わっていないか再確認する。
    if (checkReviewWorkdir(wd.workdir, o.head).workdir !== wd.workdir) {
      throw Object.assign(new Error('REVIEW_WORKDIR_CHANGED: 確認した作業フォルダが変わりました'), { exit: 1 });
    }
    const a = hg.issueShipAttestation({ repo, pr, headSha: o.head, reviewed, importantOpen,
      watchStatus: o.watch, reviewEffort: o.effort || 'high', notes: o.notes || '', bundle, privateKey: key });
    store.writeRecord(path.join(hg.shipEvidenceDir(o.repo, o.pr), a.attestation_id + '.json'), a, { exclusive: true });
    store.appendAudit('ship_attested', { repo, pr, head_sha: o.head, reviewed: a.reviewed, important_open: a.important_open, approver: a.approver,
      workdir_clean: true, workdir_head: wd.head, important_retyped: reviewed });
    say(JSON.stringify({ attestation_id: a.attestation_id, head_sha: a.head_sha }));
    return 0;
  },
};

/**
 * humanDiffAttest — R0・R1 向け「人の差分確認」の署名。
 * - リスクは表示用にここでも計算するが、認めるかどうかは gate が変更ファイルから計算したリスクで決める
 * - R2 以上の PR では署名自体を拒否する (誤操作の防止。gate 側でも無視される)
 * - 変更ファイル数を署名対象に含める (読んだ範囲の宣言)
 */
function humanDiffAttest(o) {
  if (o.kind !== 'human-diff') throw Object.assign(new Error('REVIEW_KIND_INVALID: ' + o.kind), { exit: 2 });
  for (const k of ['repo', 'pr', 'head', 'important-open']) if (o[k] == null || o[k] === true) throw Object.assign(new Error('MISSING --' + k), { exit: 2 });
  store.assertSha(o.head, 'head');
  const ctx = context(o);
  if (ctx.pr.headRefOid !== o.head) throw Object.assign(new Error(`HEAD_MISMATCH: 指定 ${o.head} / 現在 ${ctx.pr.headRefOid}`), { exit: 1 });
  const files = github.changedFiles(o.repo, o.pr);
  if (!files.ok) throw Object.assign(new Error('CHANGED_FILES_UNAVAILABLE ' + (files.error || '')), { exit: 3 });
  const rk = require('./lib/risk').classify(files.data, ctx.pol.risk);
  say('━━━ ClaudeOS — 差分確認の署名 (human-diff) ━━━');
  say(`PR       : #${o.pr} ${ctx.pr.title || ''}`);
  say(`head     : ${ctx.pr.headRefOid}`);
  say(`リスク   : ${rk.level} (${rk.reason})`);
  say(`変更ファイル (${files.data.length}):`);
  // 「すべて読んだ」と署名させるので、省略せず全件を表示する
  for (const d of rk.files) say(`  ${d.level}  ${d.file}`);
  if (!hg.reviewKindAllowed(ctx.pol, rk.level, 'human-diff')) {
    throw Object.assign(new Error(`HUMAN_DIFF_NOT_ALLOWED_FOR_${rk.level}: このリスクでは /ship のレビューと署名 (--kind ship) が必要`), { exit: 1 });
  }
  say('');
  say(`差分の確認: gh pr diff ${o.pr} --repo ${o.repo}`);
  if (!confirmTty(`上の ${files.data.length} ファイルの差分をすべて読み、問題が無いことを確認しましたか`)) { say('中止しました'); return 1; }
  const bundle = readBundle();
  const pass = hg.readPassphrase(bundle, `差分確認の署名 (PR #${o.pr}) パスフレーズ: `);
  const key = hg.loadPrivateKey(bundle, pass);
  const a = hg.issueShipAttestation({ repo: o.repo, pr: o.pr, headSha: o.head, reviewed: true, importantOpen: o['important-open'],
    watchStatus: 'not-started', reviewEffort: 'human', notes: o.notes || '', reviewKind: 'human-diff', filesReviewed: files.data.length, bundle, privateKey: key });
  store.writeRecord(path.join(hg.shipEvidenceDir(o.repo, o.pr), a.attestation_id + '.json'), a, { exclusive: true });
  store.appendAudit('ship_attested', { repo: o.repo, pr: Number(o.pr), head_sha: o.head, reviewed: true, important_open: a.important_open,
    review_kind: 'human-diff', files_reviewed: a.files_reviewed, risk: rk.level, approver: a.approver });
  say(JSON.stringify({ attestation_id: a.attestation_id, head_sha: a.head_sha, review_kind: 'human-diff', files_reviewed: a.files_reviewed }));
  return 0;
}

function decide(o, decision) {
  for (const k of ['repo', 'pr', 'head']) if (!o[k] || o[k] === true) throw Object.assign(new Error('MISSING --' + k), { exit: 2 });
  store.assertSha(o.head, 'head');
  const bundle = readBundle();
  const ctx = context(o);
  show(ctx);
  if (ctx.pr.headRefOid !== o.head) throw Object.assign(new Error(`HEAD_MISMATCH: 指定 ${o.head} / 現在 ${ctx.pr.headRefOid}`), { exit: 1 });
  if (decision === 'approve') {
    if (!ctx.gate) throw Object.assign(new Error('NO_GATE (ship gate を先に実行)'), { exit: 1 });
    if (ctx.gate.verdict !== 'PASS') throw Object.assign(new Error('GATE_NOT_PASS: ' + ctx.gate.verdict + ' — PASS 以外は承認しても自動マージされない'), { exit: 1 });
    if (!(ctx.pol.humanGate.approverKeys || []).some((k) => k.key_id === bundle.key_id)) {
      throw Object.assign(new Error('KEY_NOT_TRUSTED: この鍵は base ブランチの ship-policy.json に登録されていない'), { exit: 1 });
    }
  }
  if (!confirmTty(decision === 'approve' ? `PR #${o.pr} (head ${o.head.slice(0, 12)}) を承認しますか` : `PR #${o.pr} を差し戻しますか`)) { say('中止しました'); return 1; }
  const pass = hg.readPassphrase(bundle);
  const key = hg.loadPrivateKey(bundle, pass);
  const gate = ctx.gate || { repo: o.repo, pr: Number(o.pr), head_sha: ctx.pr.headRefOid, base_sha: ctx.pr.baseRefOid, verdict: 'NONE', risk: null, policy_version: ctx.pol.policyVersion };
  const a = hg.issueApproval({ gate, quality: ctx.q.evidence, bundle, privateKey: key, policy: ctx.pol, decision });
  if (decision === 'reject') a.reason = String(o.reason || '').slice(0, 500);
  store.writeRecord(store.paths.approval(o.repo, o.pr, a.approval_id), a, { exclusive: true });
  store.appendAudit(decision === 'approve' ? 'human_approved' : 'human_rejected', { approval_id: a.approval_id, repo: o.repo, pr: Number(o.pr), head_sha: a.head_sha, base_sha: a.base_sha, approver: a.approver, gate_verdict: a.gate_verdict });
  if (decision === 'approve') {
    // GitHub へ SHA 固定の承認ステータスを付ける (ruleset の必須チェック)。
    // 鍵束に人間専用 GitHub App があればその App として付ける (ruleset で integration_id を限定すれば AI は偽装できない)。
    const status = { context: ctx.pol.humanGate.statusContext, state: 'success', description: `approved by ${a.approver} id=${a.approval_id}` };
    let r; let identity;
    if (bundle.github_app) {
      identity = 'github-app:' + bundle.github_app.app_id;
      try { r = ghApp.postStatusAsApp(ghApp.installationToken(bundle, pass), o.repo, a.head_sha, status); } catch (e) { r = { ok: false, error: e.message }; }
    } else {
      identity = 'gh-default (⚠ AI も同じ token で付けられる。GitHub App 化を推奨)';
      r = github.postStatus(o.repo, a.head_sha, status);
    }
    store.appendAudit('human_approval_published', { approval_id: a.approval_id, ok: r.ok, error: r.error || null, identity });
    say(r.ok ? `GitHub に承認ステータスを登録しました (${identity})` : `⚠ GitHub への登録に失敗: ${r.error} (承認記録はローカルに保存済み)`);
  }
  say(JSON.stringify({ approval_id: a.approval_id, decision, head_sha: a.head_sha, expires_at: a.expires_at }));
  return 0;
}

function main(argv = process.argv.slice(2)) {
  const o = parse(argv);
  const cmd = o._[0];
  if (!cmd || !cmds[cmd]) {
    const lines = fs.readFileSync(__filename, 'utf8').split('\n');
    process.stdout.write(lines.slice(3, lines.indexOf(' */')).map((l) => l.replace(/^ \* ?/, '')).join('\n') + '\n');
    return o.help === true || !cmd ? 0 : 2;
  }
  try { return cmds[cmd](o); } catch (e) { process.stderr.write(`ship-approve: ${e.message}\n`); return e.exit || 1; }
}

module.exports = { main, cmds };
if (require.main === module) process.exitCode = main();
