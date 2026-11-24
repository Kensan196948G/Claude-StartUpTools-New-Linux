'use strict';
/**
 * policy.js — config/ship-policy.json の読み込み
 *
 * loadPolicy(file)           作業ツリーの版 (表示・ローカル品質用)
 * loadTrustedPolicy(repoDir) base ブランチ (origin/<base>) にコミット済みの版。
 *   Human Gate / AI Quality Gate / Merge Executor はこちらを使う。PR の変更コードで
 *   ポリシーを緩めても、マージ判定には反映されない (自己承認・自己緩和の防止)。
 */

const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const REPO_ROOT = path.resolve(__dirname, '..', '..', '..');
const DEFAULT_FILE = path.join(REPO_ROOT, 'config', 'ship-policy.json');
const POLICY_REL = 'config/ship-policy.json';

function validate(p) {
  if (!p || p.schema !== 'claudeos.ship-policy/v1') throw new Error('POLICY_SCHEMA');
  if (typeof p.policyVersion !== 'string') throw new Error('POLICY_VERSION');
  for (const k of ['ship', 'quality', 'risk', 'humanGate', 'merge', 'limits']) {
    if (!p[k] || typeof p[k] !== 'object') throw new Error('POLICY_MISSING_' + k.toUpperCase());
  }
  // 人間承認は全リスクで必須 (ポリシー値でも外せない)
  if (p.humanGate.requiredForAllRisks !== true) throw new Error('POLICY_HUMAN_GATE_DISABLED');
  return p;
}

function loadPolicy(file = process.env.CLAUDEOS_SHIP_POLICY || DEFAULT_FILE) {
  return validate(JSON.parse(fs.readFileSync(file, 'utf8')));
}

/** loadTrustedPolicy — base ref (既定 origin/main) にある版を git show で読む */
function loadTrustedPolicy(repoDir = REPO_ROOT, baseRef = 'origin/main') {
  if (process.env.CLAUDEOS_SHIP_TRUSTED_POLICY) return loadPolicy(process.env.CLAUDEOS_SHIP_TRUSTED_POLICY);
  if (!/^[A-Za-z0-9_./-]{1,200}$/.test(baseRef)) throw new Error('INVALID_BASE_REF');
  const r = spawnSync('git', ['-C', repoDir, 'show', `${baseRef}:${POLICY_REL}`], { encoding: 'utf8' });
  if (r.status !== 0) {
    const e = new Error('TRUSTED_POLICY_UNAVAILABLE');
    e.detail = String(r.stderr || '').slice(0, 200);
    throw e;
  }
  return validate(JSON.parse(r.stdout));
}

module.exports = { loadPolicy, loadTrustedPolicy, validate, DEFAULT_FILE, POLICY_REL, REPO_ROOT };
