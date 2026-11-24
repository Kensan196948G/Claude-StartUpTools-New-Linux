'use strict';
/**
 * github-app.js — 人間専用 GitHub App による承認ステータス登録
 *
 * 問題: Commit Status は token を持つ者なら誰でも付けられる。AI エージェントは admin 権限の gh token を持つため、
 *       `claudeos/human-approval=success` を自分で付けられる。
 * 対策: ruleset の必須チェックを「特定の GitHub App (integration_id) が付けた context」に限定し、
 *       その App の秘密鍵 (PEM) を承認者のパスフレーズで暗号化して鍵束に格納する。
 *       パスフレーズを知らない AI は App として status を付けられない → GitHub 自身が未承認マージを拒否する。
 *
 * App の作成 (Checks/Commit statuses: write のみ・他は権限なし) と ruleset の integration_id 指定は人間承認事項。
 */

const crypto = require('node:crypto');
const { spawnSync } = require('node:child_process');
const hg = require('./human-gate');

function b64url(buf) { return Buffer.from(buf).toString('base64').replace(/=+$/, '').replace(/\+/g, '-').replace(/\//g, '_'); }

/** appJwt(appId, pem, now) — RS256 JWT (有効 9 分) */
function appJwt(appId, pem, now = Math.floor(Date.now() / 1000)) {
  const header = b64url(JSON.stringify({ alg: 'RS256', typ: 'JWT' }));
  const payload = b64url(JSON.stringify({ iat: now - 60, exp: now + 540, iss: String(appId) }));
  const sig = crypto.sign('RSA-SHA256', Buffer.from(`${header}.${payload}`), crypto.createPrivateKey(pem));
  return `${header}.${payload}.${b64url(sig)}`;
}

/** attachApp(bundle, passphrase, {appId, installationId, pem}) — 鍵束へ App 鍵を暗号化して追加 */
function attachApp(bundle, passphrase, { appId, installationId, pem }) {
  if (!/^\d{1,12}$/.test(String(appId)) || !/^\d{1,14}$/.test(String(installationId))) throw new Error('INVALID_APP_IDS');
  crypto.createPrivateKey(pem); // 形式検証
  hg.loadPrivateKey(bundle, passphrase); // パスフレーズが正しいことを確認
  const kdf = bundle.wrapped.test ? { N: bundle.wrapped.N, r: 8, p: 1, maxmem: hg.SCRYPT.maxmem } : hg.SCRYPT;
  return { ...bundle, github_app: { app_id: String(appId), installation_id: String(installationId), wrapped: { ...hg.wrap(Buffer.from(pem), passphrase, kdf), test: !!bundle.wrapped.test } } };
}

function curlJson(method, url, headers, body) {
  // ヘッダ (Bearer / token) は argv に載せず stdin 経由 (-H @-) で渡す
  const args = ['-sS', '-m', '30', '-X', method, '-H', '@-', '-H', 'Accept: application/vnd.github+json', '-H', 'X-GitHub-Api-Version: 2022-11-28'];
  if (body) args.push('--data-binary', JSON.stringify(body));
  args.push('-w', '\n%{http_code}', url);
  const r = spawnSync(process.env.CLAUDEOS_SHIP_CURL_BIN || 'curl', args, { input: headers.join('\n') + '\n', encoding: 'utf8' });
  const text = r.stdout || '';
  const i = text.lastIndexOf('\n');
  const code = Number(text.slice(i + 1));
  let data = null; try { data = JSON.parse(text.slice(0, i)); } catch { /* */ }
  return { ok: code >= 200 && code < 300, code, data };
}

/** installationToken(bundle, passphrase) → 短命 token (1 時間) */
function installationToken(bundle, passphrase) {
  if (!bundle.github_app) throw new Error('NO_GITHUB_APP_IN_BUNDLE');
  const pem = hg.unwrap(bundle.github_app.wrapped, passphrase).toString('utf8');
  const jwt = appJwt(bundle.github_app.app_id, pem);
  const r = curlJson('POST', `https://api.github.com/app/installations/${bundle.github_app.installation_id}/access_tokens`, [`Authorization: Bearer ${jwt}`]);
  if (!r.ok || !r.data || !r.data.token) throw new Error('APP_TOKEN_FAILED http=' + r.code);
  return r.data.token;
}

function postStatusAsApp(token, repo, sha, { context, state, description }) {
  const r = curlJson('POST', `https://api.github.com/repos/${repo}/statuses/${sha}`, [`Authorization: token ${token}`],
    { state, context, description: String(description || '').slice(0, 140) });
  return r.ok ? { ok: true } : { ok: false, error: 'HTTP_' + r.code };
}

module.exports = { appJwt, attachApp, installationToken, postStatusAsApp, b64url };
