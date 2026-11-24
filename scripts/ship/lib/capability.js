'use strict';
/**
 * capability.js — Ship Capability Detection
 *
 * 公式仕様 (code.claude.com/docs/en/ship-command.md, ship-command-troubleshooting.md, 2026-11-24 取得) の
 * 前提条件を、実機で確認できる範囲で判定する。/ship はセッション内コマンドで `claude --help` には出ず、
 * `claude -p "/ship"` は "Nothing started" を返す (= headless 不可) ため、CLI からは「起動できる前提が揃っているか」
 * までしか判定できない。実際に /ship が動いたかは人間が対話セッションで確認する (status: session-verify-required)。
 *
 * 各項目: { id, status: ok|fail|warn|unknown, detail, source: 'cli'|'settings'|'env'|'docs' }
 * 総合: available (前提 OK・要セッション確認) | degraded (review のみ可能・watch 不可) | unavailable | unknown
 */

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

function run(cmd, args, opts = {}) {
  const r = spawnSync(cmd, args, { encoding: 'utf8', timeout: opts.timeout || 30000, cwd: opts.cwd });
  return { status: r.status, stdout: r.stdout || '', stderr: r.stderr || '', error: r.error ? r.error.code : null };
}

function verOf(text) { const m = String(text).match(/(\d+)\.(\d+)\.(\d+)/); return m ? m.slice(1).map(Number) : null; }
function ge(a, b) { for (let i = 0; i < 3; i++) { if (a[i] !== b[i]) return a[i] > b[i]; } return true; }
function readJson(f) { try { return JSON.parse(fs.readFileSync(f, 'utf8')); } catch { return null; } }

/** projectHookCouldApprove(settings) — checkout の .claude/settings.json に Bash 系 PreToolUse / PermissionRequest hook があるか */
function projectHookCouldApprove(settings) {
  const hooks = (settings && settings.hooks) || {};
  const hits = [];
  for (const ev of ['PreToolUse', 'PermissionRequest']) {
    for (const h of hooks[ev] || []) {
      const m = h.matcher == null ? '*' : String(h.matcher);
      if (m === '*' || m === '' || /(^|\|)Bash(\||$)/.test(m) || m === '.*') hits.push(`${ev}[matcher=${m}]`);
    }
  }
  return hits;
}

function skillOff(settings) {
  const o = (settings && settings.skillOverrides) || {};
  return { ship: o['ship-local'] === 'off', steward: o.steward === 'off', bundledDisabled: settings && settings.disableBundledSkills === true };
}

function denyPush(settings) {
  const deny = ((settings && settings.permissions) || {}).deny || [];
  return deny.filter((d) => /^Bash\(git push(?:\s*\*|:\*)?\)$|^Bash\(git push \*\)$|^Bash\(git \*\)$/.test(d));
}

/**
 * detect({ projectDir, policy, runner }) — runner は (cmd,args,opts)=>{status,stdout,...} (テストで差替)
 */
function detect({ projectDir = process.cwd(), policy, runner = run, env = process.env, home = os.homedir() } = {}) {
  const items = [];
  const add = (id, status, detail, source = 'cli') => items.push({ id, status, detail, source });
  const sp = policy ? policy.ship : { minClaudeVersion: '2.1.330', minGhVersion: '2.63.0', minGitVersion: '2.38.0' };

  // --- バイナリとバージョン ---
  const cv = runner('claude', ['--version']);
  const cver = cv.status === 0 ? verOf(cv.stdout) : null;
  if (!cver) add('claude.version', 'fail', 'claude が見つからない / version 取得不可');
  else add('claude.version', ge(cver, verOf(sp.minClaudeVersion)) ? 'ok' : 'fail', `${cver.join('.')} (要 >= ${sp.minClaudeVersion})`);

  const gv = runner('gh', ['--version']);
  const gver = gv.status === 0 ? verOf(gv.stdout) : null;
  if (!gver) add('gh.version', 'fail', 'gh が見つからない');
  else add('gh.version', ge(gver, verOf(sp.minGhVersion)) ? 'ok' : 'fail',
    `${gver.join('.')} (要 >= ${sp.minGhVersion}。未満だと watch が修正を push できない — 公式 docs)`);

  const tv = runner('git', ['--version']);
  const tver = tv.status === 0 ? verOf(tv.stdout) : null;
  if (!tver) add('git.version', 'fail', 'git が見つからない');
  else add('git.version', ge(tver, verOf(sp.minGitVersion)) ? 'ok' : 'warn', `${tver.join('.')} (要 >= ${sp.minGitVersion}。未満だと base の取り込みは人が行う)`);

  // --- 認証 ---
  const ca = runner('claude', ['auth', 'status']);
  let auth = null; try { auth = JSON.parse(ca.stdout); } catch { /* */ }
  if (!auth) add('claude.auth', 'unknown', 'claude auth status を解析できない');
  else if (!auth.loggedIn) add('claude.auth', 'fail', '未ログイン');
  else add('claude.auth', auth.apiProvider === 'firstParty' ? 'ok' : 'fail',
    `method=${auth.authMethod} provider=${auth.apiProvider} plan=${auth.subscriptionType || '?'}/${auth.planTier || '?'}${auth.apiProvider !== 'firstParty' ? ' (third-party provider では /ship は使えない)' : ''}`);
  const plan = auth ? { subscriptionType: auth.subscriptionType || null, planTier: auth.planTier || null } : null;

  const gs = runner('gh', ['auth', 'status']);
  const ghOut = gs.stdout + gs.stderr;
  add('gh.auth', /Active account: true/.test(ghOut) || (gs.status === 0 && /Logged in/.test(ghOut)) ? 'ok' : 'fail',
    /Active account: true/.test(ghOut) ? 'active account あり' : 'gh 未ログイン / active account なし');

  // --- 環境 (feature flag 取得を止める設定) ---
  const flagOff = ['DISABLE_TELEMETRY', 'CLAUDE_CODE_USE_BEDROCK', 'CLAUDE_CODE_USE_VERTEX', 'CLAUDE_CODE_USE_FOUNDRY'].filter((k) => env[k]);
  add('env.feature_flags', flagOff.length ? 'fail' : 'ok', flagOff.length ? `${flagOff.join(',')} が設定されている (/ship が出ない)` : 'feature-flag 取得を止める変数なし', 'env');
  const pathParts = String(env.PATH || '').split(':');
  const badPath = pathParts.filter((p) => p === '' || !p.startsWith('/'));
  const absProject = path.resolve(projectDir);
  const inCheckout = pathParts.filter((p) => p.startsWith('/') && (p === absProject || p.startsWith(absProject + path.sep)));
  add('env.path', badPath.length || inCheckout.length ? 'fail' : 'ok',
    badPath.length ? 'PATH に空/相対エントリ (watch 不可)' : inCheckout.length ? `PATH に checkout 内のフォルダ (${inCheckout.join(',')}) (watch 不可)` : 'OK', 'env');

  // --- settings ---
  const userSettings = readJson(path.join(home, '.claude', 'settings.json')) || {};
  const projSettings = readJson(path.join(projectDir, '.claude', 'settings.json')) || {};
  const localSettings = readJson(path.join(projectDir, '.claude', 'settings.local.json')) || {};
  const managed = readJson('/etc/claude-code/managed-settings.json') || {};
  for (const [label, s] of [['user', userSettings], ['project', projSettings], ['local', localSettings], ['managed', managed]]) {
    const off = skillOff(s);
    if (off.ship || off.steward || off.bundledDisabled) add(`settings.${label}.skills`, 'fail', `ship-local=${off.ship} steward=${off.steward} disableBundledSkills=${off.bundledDisabled}`, 'settings');
    const dp = denyPush(s);
    if (dp.length) add(`settings.${label}.deny_push`, 'fail', `deny ${dp.join(',')} → watch が始まらない`, 'settings');
    const mode = ((s.permissions || {}).defaultMode) || null;
    if (mode === 'bypassPermissions') add(`settings.${label}.mode`, 'fail', 'bypassPermissions では watch が始まらない', 'settings');
  }
  const hookHits = projectHookCouldApprove(projSettings);
  add('settings.project.hooks', hookHits.length ? 'fail' : 'ok',
    hookHits.length ? `checkout の .claude/settings.json に ${hookHits.join(', ')} → 公式仕様により watch が始まらない (/ship の review だけは可能)` : 'watch を止める project hook なし', 'settings');
  const userHooks = projectHookCouldApprove(userSettings);
  if (userHooks.length) add('settings.user.hooks', 'warn', `ユーザー設定に ${userHooks.join(', ')}。watch 中の gh/git (Claude Code 自身が実行) には PreToolUse は効かない — マージ防止は GitHub ruleset が担う`, 'settings');
  const um = (userSettings.permissions || {}).defaultMode;
  add('settings.mode', um === 'auto' ? 'ok' : 'warn', `defaultMode=${um || 'default'} (無人の watch には auto mode が必要)`, 'settings');

  // --- リポジトリ ---
  const remote = runner('git', ['-C', projectDir, 'remote', 'get-url', 'origin']);
  const isGithub = remote.status === 0 && /github\.com[:/]/.test(remote.stdout);
  add('repo.github', isGithub ? 'ok' : 'fail', isGithub ? 'github.com リモート' : 'GitHub 以外 / remote なし (PR は開かれない)');
  let visibility = null;
  if (isGithub) {
    const m = remote.stdout.trim().match(/github\.com[:/]([^/]+\/[^/.]+?)(?:\.git)?$/);
    if (m) {
      const rv = runner('gh', ['repo', 'view', m[1], '--json', 'visibility,isFork,viewerPermission']);
      try {
        const v = JSON.parse(rv.stdout); visibility = v.visibility;
        add('repo.fork', v.isFork ? 'fail' : 'ok', v.isFork ? 'fork では /ship は PR を開かない' : 'fork ではない');
        add('repo.permission', ['ADMIN', 'MAINTAIN', 'WRITE'].includes(v.viewerPermission) ? 'ok' : 'fail', `viewerPermission=${v.viewerPermission}`);
        if (v.visibility === 'PUBLIC') add('repo.visibility', 'warn', 'PUBLIC: /ship は未コミット変更をコミットしない (ブランチにコミット済みの内容だけ push)');
        if (v.viewerPermission === 'ADMIN') add('repo.admin_merge_risk', 'warn', 'ADMIN 権限: ruleset が人間承認を要求しない限り、watch / auto-merge がマージに至り得る (公式 docs の警告)');
      } catch { add('repo.visibility', 'unknown', 'gh repo view 失敗'); }
    }
  }
  add('ship.headless', 'fail', '/ship・/steward は人が入力した行からのみ起動 (claude -p では "Nothing started")。ClaudeOS は入力を代行しない', 'docs');
  add('ship.cloud_session', 'fail', 'cloud session では /ship は使えない (公式)', 'docs');
  add('ship.org_agents', plan && /^(team|enterprise)/i.test(String(plan.subscriptionType)) ? 'unknown' : 'fail',
    `組織版 Claude Ship (Code Review / PR Steward / Claude Approvals) は Team / Enterprise のみ。現在 plan=${plan ? plan.subscriptionType : '?'} → 契約対象外`, 'docs');

  // --- 総合判定 ---
  const blockers = ['claude.version', 'claude.auth', 'env.feature_flags', 'repo.github'].filter((id) => items.some((i) => i.id === id && i.status === 'fail'))
    .concat(items.filter((i) => /^settings\.\w+\.skills$/.test(i.id) && i.status === 'fail').map((i) => i.id));
  const watchBlockers = items.filter((i) => i.status === 'fail' && (['gh.version', 'gh.auth', 'env.path', 'settings.project.hooks', 'repo.fork', 'repo.permission'].includes(i.id) || /deny_push|\.mode$/.test(i.id))).map((i) => i.id);
  let overall;
  if (items.some((i) => i.id === 'claude.version' && i.status === 'fail') && !cver) overall = 'unavailable';
  else if (blockers.length) overall = 'unavailable';
  else if (watchBlockers.length) overall = 'degraded';
  else overall = 'available';
  return {
    schema: 'claudeos.ship-capability/v1', checked_at: new Date().toISOString(), project_dir: absProject,
    overall, review_possible: overall !== 'unavailable', watch_possible: overall === 'available',
    headless: false, session_verification: 'required (人が対話セッションで /ship terms を実行して確認する)',
    blockers, watch_blockers: watchBlockers, plan, visibility, items,
  };
}

module.exports = { detect, projectHookCouldApprove, skillOff, denyPush, verOf, ge };
