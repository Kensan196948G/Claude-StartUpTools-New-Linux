'use strict';
/**
 * quality.js — Ubuntu Local Quality Engine
 *
 * 1. 対象 SHA を独立した clone (作業ツリーとは別ディレクトリ・別 .git) に detach で取り出す
 * 2. HEAD == 対象 SHA を確認 (古い SHA の結果を流用させない)
 * 3. 各チェックを bwrap で隔離実行:
 *      - ネットワーク遮断 (--unshare-net)
 *      - $HOME を空の tmpfs で覆う → ~/.config/gh, ~/.claude, ~/.claudeos (承認・証跡・HMAC 鍵) が見えない
 *      - 環境変数は最小限 (--clearenv)。GITHUB_TOKEN 等は渡らない
 *      - / は読み取り専用。書けるのは clone ディレクトリと /tmp (tmpfs) だけ
 * 4. 証跡 (チェックごとの exit code / 件数 / 時間 / ログ) を evidence_hash + HMAC で封印して保存
 *
 * 判定: 全チェック PASS → PASS / いずれか FAIL → FAIL / 実行できなかったチェックがある → UNKNOWN。
 *       実行していないチェックを合格扱いにしない。
 *
 * 限界 (docs/architecture/LOCAL_QUALITY_ENGINE.md): HMAC 鍵は ClaudeOS と同じ OS ユーザーが読める。
 * 開発エージェントによる意図的な改ざんの「防止」には専用 OS ユーザー (claudeos-qa) での実行が必要。
 */

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const { spawnSync } = require('node:child_process');
const store = require('./store');

function hmacKey() {
  const file = process.env.CLAUDEOS_SHIP_HMAC_KEY_FILE || store.paths.hmacKey();
  if (!fs.existsSync(file)) {
    store.ensureDir(path.dirname(file));
    fs.writeFileSync(file, crypto.randomBytes(32).toString('hex'), { mode: 0o600, flag: 'wx' });
  }
  return Buffer.from(fs.readFileSync(file, 'utf8').trim(), 'hex');
}

function sealBody(rec) {
  const body = { ...rec };
  delete body.evidence_hash;
  delete body.hmac;
  return store.canonical(body);
}
function seal(rec, key = hmacKey()) {
  rec.evidence_hash = store.sha256(sealBody(rec));
  rec.hmac = crypto.createHmac('sha256', key).update(rec.evidence_hash).digest('hex');
  return rec;
}
function verifySeal(rec, key = hmacKey()) {
  if (!rec || typeof rec.evidence_hash !== 'string' || typeof rec.hmac !== 'string') return { ok: false, reason: 'UNSEALED' };
  if (store.sha256(sealBody(rec)) !== rec.evidence_hash) return { ok: false, reason: 'EVIDENCE_HASH_MISMATCH' };
  const expect = crypto.createHmac('sha256', key).update(rec.evidence_hash).digest('hex');
  const a = Buffer.from(expect, 'hex'); const b = Buffer.from(rec.hmac, 'hex');
  if (a.length !== b.length || !crypto.timingSafeEqual(a, b)) return { ok: false, reason: 'HMAC_MISMATCH' };
  return { ok: true };
}

function git(args, cwd) {
  return spawnSync('git', args, { cwd, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
}

/** prepareCheckout — 独立 clone を作り、対象 SHA に detach する */
function prepareCheckout(repoDir, sha, workRoot) {
  store.assertSha(sha);
  store.ensureDir(workRoot);
  const dir = fs.mkdtempSync(path.join(workRoot, sha.slice(0, 12) + '-'));
  let r = git(['clone', '--quiet', '--no-hardlinks', '--no-checkout', repoDir, dir]);
  if (r.status !== 0) throw Object.assign(new Error('CLONE_FAILED'), { detail: r.stderr.slice(0, 300) });
  r = git(['-c', 'advice.detachedHead=false', 'checkout', '--quiet', '--detach', sha], dir);
  if (r.status !== 0) throw Object.assign(new Error('CHECKOUT_FAILED'), { detail: r.stderr.slice(0, 300) });
  const head = git(['rev-parse', 'HEAD'], dir).stdout.trim();
  if (head !== sha) throw new Error('HEAD_MISMATCH');
  // clone の origin は元リポジトリ (ローカルパス) を指す。サンドボックス内からは書けないが、念のため外す
  git(['remote', 'remove', 'origin'], dir);
  return dir;
}

function isolationAvailable() {
  const r = spawnSync('bwrap', ['--ro-bind', '/', '/', '--unshare-net', '--die-with-parent', 'true'], { encoding: 'utf8' });
  return r.status === 0;
}

/** sandboxArgv — bwrap の引数列 (テスト可能な純関数) */
function sandboxArgv(cmd, { workDir, home = os.homedir(), extraRo = [], env = {} }) {
  const argv = ['--ro-bind', '/', '/', '--dev', '/dev', '--proc', '/proc', '--tmpfs', '/tmp',
    '--tmpfs', home];
  for (const ro of extraRo) argv.push('--ro-bind', ro, ro);
  argv.push('--bind', workDir, workDir, '--chdir', workDir,
    '--unshare-net', '--unshare-pid', '--unshare-ipc', '--die-with-parent', '--new-session', '--clearenv');
  // GitHub Actions ランナーが常に設定する非機密の基本変数だけを渡す (USER が無いと set -u のスクリプトが落ちる。
  // 2026-11-24 実測: 27 件が "USER: unbound variable")。トークン類は一切渡さない。
  const user = os.userInfo().username;
  const baseEnv = { PATH: env.PATH || process.env.PATH, HOME: home, USER: user, LOGNAME: user, SHELL: '/bin/bash',
    LANG: 'C.UTF-8', TERM: 'dumb', CI: '1', TZ: 'UTC', ...env };
  for (const [k, v] of Object.entries(baseEnv)) argv.push('--setenv', k, String(v));
  argv.push('--', ...cmd);
  return argv;
}

/** extraReadOnlyMounts — $HOME 配下にあるツールチェーン (nvm 等) だけを読み取り専用で戻す */
function extraReadOnlyMounts(home = os.homedir()) {
  const out = new Set();
  for (const tool of ['node', 'npm', 'bats', 'shellcheck', 'jq', 'trivy', 'tmux', 'git']) {
    const r = spawnSync('bash', ['-c', `command -v ${tool}`], { encoding: 'utf8' });
    const p = (r.stdout || '').trim();
    if (!p || !p.startsWith(home + '/')) continue;
    let real = p; try { real = fs.realpathSync(p); } catch { /* keep */ }
    // ~/.nvm/versions/node/vX/bin/node → ~/.nvm/versions/node/vX を戻す (npm の lib も必要)
    const m = real.match(/^(.*\/versions\/node\/[^/]+)\//);
    out.add(m ? m[1] : path.dirname(real));
  }
  return [...out];
}

/** parseCounts — TAP (bats / node --test) から件数を数える。数えられなければ null */
function parseCounts(text) {
  const nodePass = [...text.matchAll(/^# pass (\d+)$/gm)].reduce((s, m) => s + Number(m[1]), 0);
  const nodeFail = [...text.matchAll(/^# fail (\d+)$/gm)].reduce((s, m) => s + Number(m[1]), 0);
  const nodeSkip = [...text.matchAll(/^# skipped (\d+)$/gm)].reduce((s, m) => s + Number(m[1]), 0);
  const okLines = (text.match(/^ok \d+/gm) || []).length;
  const notOk = (text.match(/^not ok \d+/gm) || []).length;
  const skipLines = (text.match(/^ok \d+ .*# skip/gim) || []).length;
  const hasNode = /^# pass \d+$/m.test(text);
  // node --test は ok 行も出すため、node の集計がある分は bats 由来の ok 行から差し引く
  const batsOk = Math.max(0, okLines - (hasNode ? nodePass + nodeSkip : 0));
  const passed = (hasNode ? nodePass : 0) + batsOk - skipLines;
  const failed = (hasNode ? nodeFail : 0) + Math.max(0, notOk - (hasNode ? nodeFail : 0));
  if (okLines === 0 && notOk === 0 && !hasNode) return null;
  return { passed: Math.max(0, passed), failed, skipped: nodeSkip + skipLines };
}

function redactLog(s) { return store.redact(String(s)); }

/** runSecretsCheck — trivy (offline) で対象ツリーと base..head の差分パッチを走査 */
function secretsCheck({ dir, baseSha, headSha, logFile, timeoutSec, sandbox }) {
  const which = spawnSync('bash', ['-c', 'command -v trivy'], { encoding: 'utf8' });
  if (which.status !== 0) return { status: 'NOT_RUN', reason: 'TRIVY_NOT_INSTALLED', exit_code: null };
  const patchDir = fs.mkdtempSync(path.join(path.dirname(dir), 'patch-'));
  if (baseSha) {
    const p = git(['log', '-p', '--no-color', `${baseSha}..${headSha}`], dir);
    fs.writeFileSync(path.join(patchDir, 'range.patch'), p.status === 0 ? p.stdout : '');
  }
  const args = ['fs', '--scanners', 'secret', '--offline-scan', '--skip-db-update', '--quiet', '--format', 'json',
    '--exit-code', '1', '--skip-dirs', '.git'];
  const outs = [];
  let worst = 0;
  for (const target of [dir, patchDir]) {
    const r = sandbox(['trivy', ...args, target], { extraBind: target === patchDir ? [patchDir] : [] }, timeoutSec);
    let found = 0;
    try { found = (JSON.parse(r.stdout || '{}').Results || []).reduce((s, x) => s + (x.Secrets || []).length, 0); } catch { /* */ }
    // 値は記録しない。件数と位置 (ファイル/行) のみ
    let locs = [];
    try {
      locs = (JSON.parse(r.stdout || '{}').Results || []).flatMap((x) => (x.Secrets || []).map((s) => {
        const t = path.isAbsolute(x.Target) ? path.relative(target, x.Target) : x.Target;
        return `${t}:${s.StartLine} ${s.RuleID}`;
      }));
    } catch { /* */ }
    outs.push(`target=${target === dir ? 'tree' : 'base..head patch'} exit=${r.status} findings=${found}\n${locs.join('\n')}\n${redactLog(r.stderr || '').slice(0, 2000)}`);
    if (r.status !== 0) worst = r.status === 1 ? Math.max(worst, 1) : 2;
  }
  fs.rmSync(patchDir, { recursive: true, force: true });
  fs.writeFileSync(logFile, outs.join('\n---\n'), { mode: 0o600 });
  if (worst === 2) return { status: 'ERROR', exit_code: 2, reason: 'TRIVY_ERROR' };
  return { status: worst === 0 ? 'PASS' : 'FAIL', exit_code: worst };
}

/**
 * runQuality({repo, repoDir, headSha, baseSha, pr, profile, policy}) → 封印済み証跡
 */
function runQuality(opts) {
  const { repo, repoDir, headSha, baseSha = null, pr = null, policy } = opts;
  store.assertRepo(repo); store.assertSha(headSha, 'head');
  if (baseSha) store.assertSha(baseSha, 'base');
  const q = policy.quality;
  const profile = q.profiles[opts.profile];
  if (!profile) throw new Error('UNKNOWN_PROFILE');
  const evalId = store.newId('qe');
  const evDir = store.paths.qualityDir(repo, headSha);
  const logDir = path.join(evDir, evalId + '.logs');
  store.ensureDir(logDir);
  const rec = {
    schema: store.SCHEMA.quality, eval_id: evalId, repo, pr, head_sha: headSha, base_sha: baseSha,
    profile: opts.profile, policy_version: policy.policyVersion,
    started_at: new Date().toISOString(), finished_at: null,
    host: os.hostname(), node: process.version, isolation: null, checks: [], verdict: 'UNKNOWN', reasons: [],
  };

  const isolated = isolationAvailable();
  if (!isolated && !(q.allowUnisolated === true)) {
    rec.isolation = 'unavailable';
    rec.reasons.push('ISOLATION_UNAVAILABLE (bwrap が使えないため実行しない。fail-closed)');
    rec.finished_at = new Date().toISOString();
    return finalize(rec);
  }
  rec.isolation = isolated ? 'bwrap(net=none,home=tmpfs,ro-root)' : 'none';

  const workRoot = path.join(store.shipHome(), 'work', store.slug(repo));
  let dir;
  try {
    dir = prepareCheckout(repoDir, headSha, workRoot);
  } catch (e) {
    rec.reasons.push('CHECKOUT: ' + e.message);
    rec.finished_at = new Date().toISOString();
    return finalize(rec);
  }
  const ro = extraReadOnlyMounts();
  // 読み取り専用で渡すキャッシュ (TLA+ jar)。鍵・認証情報を含まないディレクトリだけを許可する
  const formalCache = path.join(os.homedir(), '.cache', 'claudeos', 'formal');
  const cacheEnv = {};
  if (fs.existsSync(path.join(formalCache, 'tla2tools.jar'))) { ro.push(formalCache); cacheEnv.CCSU_FORMAL_CACHE = formalCache; }
  const sandbox = (cmd, { extraBind = [] } = {}, timeoutSec = q.checkTimeoutSec) => {
    if (!isolated) return spawnSync(cmd[0], cmd.slice(1), { cwd: dir, encoding: 'utf8', timeout: timeoutSec * 1000, maxBuffer: 256 * 1024 * 1024 });
    const argv = sandboxArgv(cmd, { workDir: dir, extraRo: ro, env: cacheEnv });
    // extraBind (パッチ置き場) は読み取り専用で追加
    const idx = argv.indexOf('--bind');
    for (const b of extraBind) argv.splice(idx, 0, '--ro-bind', b, b);
    return spawnSync('bwrap', argv, { encoding: 'utf8', timeout: timeoutSec * 1000, maxBuffer: 256 * 1024 * 1024 });
  };

  try {
    for (const check of profile.checks) {
      const logFile = path.join(logDir, check.id + '.log');
      const t0 = Date.now();
      const entry = { id: check.id, category: check.category, cmd: check.cmd.join(' '), exit_code: null,
        passed: null, failed: null, skipped: null, duration_ms: 0, log_file: path.relative(store.shipHome(), logFile), status: 'NOT_RUN' };
      if (check.cmd[0] === '@secrets') {
        Object.assign(entry, secretsCheck({ dir, baseSha, headSha, logFile, timeoutSec: q.checkTimeoutSec, sandbox }));
      } else {
        const r = sandbox(check.cmd);
        const out = (r.stdout || '') + (r.stderr ? '\n[stderr]\n' + r.stderr : '');
        fs.writeFileSync(logFile, redactLog(out), { mode: 0o600 });
        if (r.error && r.error.code === 'ETIMEDOUT') { entry.status = 'ERROR'; entry.reason = 'TIMEOUT'; }
        else if (r.status === null) { entry.status = 'ERROR'; entry.reason = 'SIGNAL ' + r.signal; }
        else {
          entry.exit_code = r.status;
          entry.status = r.status === 0 ? 'PASS' : 'FAIL';
          if (check.parser === 'tap') Object.assign(entry, parseCounts(out) || {});
          // 件数で失敗が出ているのに exit 0 なら FAIL (assertion 抜けの見逃し防止)
          if (entry.status === 'PASS' && Number(entry.failed) > 0) { entry.status = 'FAIL'; entry.reason = 'FAILED_COUNT_NONZERO'; }
        }
      }
      entry.duration_ms = Date.now() - t0;
      rec.checks.push(entry);
    }
  } finally {
    // HEAD が途中で動いていないこと (チェックが git checkout した等) を最後に再確認
    const head = git(['rev-parse', 'HEAD'], dir).stdout.trim();
    if (head !== headSha) rec.reasons.push('HEAD_MOVED_DURING_RUN');
    if (!process.env.CLAUDEOS_SHIP_KEEP_WORK) fs.rmSync(dir, { recursive: true, force: true });
  }
  rec.finished_at = new Date().toISOString();
  return finalize(rec);
}

function verdictOf(rec) {
  if (rec.reasons.some((r) => /HEAD_MOVED|ISOLATION|CHECKOUT/.test(r))) return 'UNKNOWN';
  if (rec.checks.length === 0) return 'UNKNOWN';
  if (rec.checks.some((c) => c.status === 'FAIL')) return 'FAIL';
  if (rec.checks.some((c) => c.status !== 'PASS')) return 'UNKNOWN';
  return 'PASS';
}

function finalize(rec) {
  rec.verdict = verdictOf(rec);
  seal(rec);
  store.writeRecord(store.paths.quality(rec.repo, rec.head_sha, rec.eval_id), rec, { exclusive: true });
  store.appendAudit('quality_evaluated', { repo: rec.repo, pr: rec.pr, head_sha: rec.head_sha, eval_id: rec.eval_id, verdict: rec.verdict });
  return rec;
}

/** latestEvidence(repo, sha) — 封印検証に通った最新の証跡 (改ざんされたものは除外し、理由を返す) */
function latestEvidence(repo, sha) {
  const files = store.listJson(store.paths.qualityDir(repo, sha));
  const valid = []; const rejected = [];
  for (const f of files) {
    const rec = store.readRecord(f);
    const v = verifySeal(rec);
    if (!v.ok || rec.head_sha !== sha || rec.repo !== repo) rejected.push({ file: path.basename(f), reason: v.ok ? 'SUBJECT_MISMATCH' : v.reason });
    else valid.push(rec);
  }
  valid.sort((a, b) => String(a.finished_at).localeCompare(String(b.finished_at)));
  return { evidence: valid[valid.length - 1] || null, rejected };
}

module.exports = {
  runQuality, latestEvidence, seal, verifySeal, sandboxArgv, parseCounts, prepareCheckout,
  isolationAvailable, extraReadOnlyMounts, verdictOf,
};
