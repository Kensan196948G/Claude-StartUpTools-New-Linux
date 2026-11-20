#!/usr/bin/env node
/**
 * evidence-ledger.js — 研究・仮説の証拠台帳 (AI Scientist の観測層)
 *
 * 役割: 「主張 (claim) → 出所 (source) → 支持/反証 (observation) → 判断」を
 *       追跡可能な形で残す。文献・仮説・解析のうち、この環境で機械的に保証できる
 *       のは「出所が実在すること」「記録が改変されていないこと」までで、
 *       科学的判断そのものは人が行う (モデルの自己申告を根拠にしない)。
 *
 * 原則:
 *   - 主張には必ず出所を付ける (出所なしは unsupported 扱い)
 *   - ローカルファイル出所は実在確認 + sha256 記録。URL は取得せず記録のみ (取得は別工程)
 *   - observation は supports / refutes / inconclusive を人が与える (推測で埋めない)
 *   - 秘密情報を検出したら追記しない
 *
 * 使い方:
 *   node scripts/tools/evidence-ledger.js claim --text "..." --source <path|url> [--locator L] [--confidence 0-1]
 *   node scripts/tools/evidence-ledger.js hypothesis --text "..." --prediction "..." [--note N]
 *   node scripts/tools/evidence-ledger.js observe --hypothesis H --verdict supports|refutes|inconclusive [--evidence <claim-id>] [--note N]
 *   node scripts/tools/evidence-ledger.js verify                 # 出所の実在と sha256 を再確認
 *   node scripts/tools/evidence-ledger.js brief [--out FILE]     # 判断用ブリーフ (引用付き)
 *   node scripts/tools/evidence-ledger.js list [--json]
 *
 * 台帳: <repo>/.claudeos/research/ledger.json (CCSU_EVIDENCE_LEDGER で上書き可)
 */

'use strict';

const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');

const REPO_ROOT = path.resolve(__dirname, '..', '..');
const SCHEMA = 'claudeos.evidence-ledger/v1';

const { SECRET_PATTERNS } = require('./synth-data.js');

function ledgerPath() {
  return process.env.CCSU_EVIDENCE_LEDGER || path.join(REPO_ROOT, '.claudeos', 'research', 'ledger.json');
}

function sha256(text) {
  return crypto.createHash('sha256').update(text).digest('hex');
}

function scanSecrets(text) {
  const hits = [];
  for (const p of SECRET_PATTERNS) if (p.re.test(text)) hits.push(p.name);
  return hits;
}

function load() {
  const file = ledgerPath();
  if (!fs.existsSync(file)) {
    return { schema: SCHEMA, created_at: new Date().toISOString(), claims: [], hypotheses: [], observations: [] };
  }
  const data = JSON.parse(fs.readFileSync(file, 'utf8'));
  if (data.schema !== SCHEMA) throw new Error(`台帳 schema が不一致です: ${data.schema}`);
  return data;
}

function save(data) {
  const file = ledgerPath();
  fs.mkdirSync(path.dirname(file), { recursive: true });
  data.updated_at = new Date().toISOString();
  data.revision = (data.revision || 0) + 1;
  fs.writeFileSync(file, JSON.stringify(data, null, 2) + '\n');
}

function parseFlags(argv) {
  const out = { _: [] };
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (a.startsWith('--')) out[a.slice(2)] = argv[i + 1] === undefined || argv[i + 1].startsWith('--') ? true : argv[++i];
    else out._.push(a);
  }
  return out;
}

/** sourceIsLocal — URL でなければローカルパスとして扱う */
function sourceIsLocal(source) {
  return !/^https?:\/\//i.test(String(source));
}

function resolveSource(source) {
  if (sourceIsLocal(source)) return path.isAbsolute(source) ? source : path.join(REPO_ROOT, source);
  return null;
}

function cmdClaim(argv) {
  const f = parseFlags(argv);
  if (!f.text) { process.stderr.write('❌ [ERR ] --text が必要です\n'); return 2; }
  if (!f.source) { process.stderr.write('❌ [ERR ] --source が必要です (出所のない主張は登録できません)\n'); return 2; }
  const confidence = f.confidence === undefined || f.confidence === true ? null : Number(f.confidence);
  if (confidence !== null && (Number.isNaN(confidence) || confidence < 0 || confidence > 1)) {
    process.stderr.write('❌ [ERR ] --confidence は 0〜1\n');
    return 2;
  }

  const payload = `${f.text}\n${f.source}\n${f.locator || ''}`;
  const leaks = scanSecrets(payload);
  if (leaks.length > 0) {
    process.stderr.write(`❌ [ERR ] 秘密情報の疑いがあるため登録しません: ${[...new Set(leaks)].join(', ')}\n`);
    return 2;
  }

  const local = resolveSource(f.source);
  const exists = local ? fs.existsSync(local) : null;
  const sourceSha = local && exists ? sha256(fs.readFileSync(local)) : null;

  const data = load();
  const id = `claim-${sha256(payload).slice(0, 12)}`;
  if (data.claims.some((c) => c.id === id)) {
    process.stdout.write(JSON.stringify({ skipped: 'duplicate', id }) + '\n');
    return 0;
  }
  const claim = {
    id,
    text: f.text,
    source: f.source,
    locator: f.locator || null,
    source_kind: local ? 'local-file' : 'url',
    source_exists: exists,
    source_sha256: sourceSha,
    confidence,
    status: exists === false ? 'unsupported' : 'unverified',
    created_at: new Date().toISOString(),
  };
  data.claims.push(claim);
  save(data);
  process.stdout.write(JSON.stringify(claim) + '\n');
  return exists === false ? 1 : 0;
}

function cmdHypothesis(argv) {
  const f = parseFlags(argv);
  if (!f.text || !f.prediction) {
    process.stderr.write('❌ [ERR ] --text と --prediction が必要です\n');
    return 2;
  }
  const payload = `${f.text}\n${f.prediction}`;
  if (scanSecrets(payload).length > 0) {
    process.stderr.write('❌ [ERR ] 秘密情報の疑いがあるため登録しません\n');
    return 2;
  }
  const data = load();
  const id = `hyp-${sha256(payload).slice(0, 12)}`;
  if (data.hypotheses.some((h) => h.id === id)) {
    process.stdout.write(JSON.stringify({ skipped: 'duplicate', id }) + '\n');
    return 0;
  }
  const hyp = {
    id,
    text: f.text,
    prediction: f.prediction,
    note: f.note && f.note !== true ? f.note : null,
    status: 'open',            // open | supported | mixed | refuted
    created_at: new Date().toISOString(),
  };
  data.hypotheses.push(hyp);
  save(data);
  process.stdout.write(JSON.stringify(hyp) + '\n');
  return 0;
}

function cmdObserve(argv) {
  const f = parseFlags(argv);
  const verdict = f.verdict;
  if (!f.hypothesis || !['supports', 'refutes', 'inconclusive'].includes(verdict)) {
    process.stderr.write('❌ [ERR ] --hypothesis と --verdict supports|refutes|inconclusive が必要です\n');
    return 2;
  }
  const data = load();
  const hyp = data.hypotheses.find((h) => h.id === f.hypothesis || h.id.startsWith(String(f.hypothesis)));
  if (!hyp) { process.stderr.write(`❌ [ERR ] 仮説が見つかりません: ${f.hypothesis}\n`); return 2; }

  if (f.evidence && !data.claims.some((c) => c.id === f.evidence)) {
    process.stderr.write(`❌ [ERR ] 証拠 (claim) が見つかりません: ${f.evidence}\n`);
    return 2;
  }
  const note = f.note && f.note !== true ? f.note : '';
  if (scanSecrets(note).length > 0) { process.stderr.write('❌ [ERR ] 秘密情報の疑いがあるため記録しません\n'); return 2; }

  data.observations.push({
    id: `obs-${sha256(`${hyp.id}${verdict}${f.evidence || ''}${note}`).slice(0, 12)}`,
    hypothesis: hyp.id,
    verdict,
    evidence: f.evidence || null,
    note: note || null,
    created_at: new Date().toISOString(),
  });
  // 仮説の状態は観測の集計だけで決める (推測を混ぜない)
  const obs = data.observations.filter((o) => o.hypothesis === hyp.id);
  const s = obs.filter((o) => o.verdict === 'supports').length;
  const r = obs.filter((o) => o.verdict === 'refutes').length;
  hyp.status = r > 0 && s === 0 ? 'refuted' : r > 0 && s > 0 ? 'mixed' : s > 0 ? 'supported' : 'open';
  if (!hyp.observations) hyp.observations = { supports: 0, refutes: 0, inconclusive: 0 };
  hyp.observations = {
    supports: s,
    refutes: r,
    inconclusive: obs.filter((o) => o.verdict === 'inconclusive').length,
  };
  save(data);
  process.stdout.write(JSON.stringify({ hypothesis: hyp.id, status: hyp.status, observations: hyp.observations }) + '\n');
  return 0;
}

function cmdVerify() {
  const data = load();
  const results = data.claims.map((c) => {
    const local = resolveSource(c.source);
    if (!local) return { id: c.id, source: c.source, kind: 'url', checked: false, note: 'URL は取得しない (別工程)' };
    const exists = fs.existsSync(local);
    const current = exists ? sha256(fs.readFileSync(local)) : null;
    return {
      id: c.id,
      source: c.source,
      kind: 'local-file',
      checked: true,
      exists,
      sha256_match: exists ? current === c.source_sha256 : null,
    };
  });
  const broken = results.filter((r) => r.checked && (!r.exists || r.sha256_match === false));
  process.stdout.write(JSON.stringify({ schema: SCHEMA, checked: results.filter((r) => r.checked).length, broken: broken.length, results }, null, 2) + '\n');
  return broken.length > 0 ? 1 : 0;
}

function cmdBrief(argv) {
  const f = parseFlags(argv);
  const data = load();
  const byStatus = {};
  for (const c of data.claims) byStatus[c.status] = (byStatus[c.status] || 0) + 1;
  const lines = [];
  lines.push('# 証拠ブリーフ', '');
  lines.push(`生成: ${new Date().toISOString()}`);
  lines.push(`主張 ${data.claims.length} 件 / 仮説 ${data.hypotheses.length} 件 / 観測 ${data.observations.length} 件`);
  lines.push('');
  lines.push('## 仮説');
  if (data.hypotheses.length === 0) lines.push('- (なし)');
  for (const h of data.hypotheses) {
    lines.push(`- [${h.status}] ${h.text}`);
    lines.push(`  - 予測: ${h.prediction}`);
    lines.push(`  - 観測: supports=${h.observations?.supports ?? 0} refutes=${h.observations?.refutes ?? 0} inconclusive=${h.observations?.inconclusive ?? 0}`);
  }
  lines.push('');
  lines.push('## 主張と出所');
  if (data.claims.length === 0) lines.push('- (なし)');
  for (const c of [...data.claims].sort((a, b) => a.id.localeCompare(b.id))) {
    const loc = c.locator ? ` (${c.locator})` : '';
    lines.push(`- [${c.status}] ${c.text}`);
    lines.push(`  - 出所: ${c.source}${loc}${c.source_sha256 ? ` sha256=${c.source_sha256.slice(0, 12)}` : ''}`);
  }
  const body = lines.join('\n') + '\n';
  const out = f.out && f.out !== true ? f.out : null;
  if (out) {
    fs.mkdirSync(path.dirname(path.resolve(out)), { recursive: true });
    fs.writeFileSync(path.resolve(out), body);
    process.stdout.write(JSON.stringify({ out: path.resolve(out), claims: data.claims.length, hypotheses: data.hypotheses.length }) + '\n');
  } else {
    process.stdout.write(body);
  }
  return 0;
}

function cmdList(argv) {
  const f = parseFlags(argv);
  const data = load();
  if (f.json) process.stdout.write(JSON.stringify(data) + '\n');
  else {
    for (const h of data.hypotheses) process.stdout.write(`hyp\t${h.status}\t${h.id}\t${h.text}\n`);
    for (const c of data.claims) process.stdout.write(`claim\t${c.status}\t${c.id}\t${c.source}\n`);
  }
  return 0;
}

function main() {
  const [cmd, ...rest] = process.argv.slice(2);
  switch (cmd) {
    case 'claim': return cmdClaim(rest);
    case 'hypothesis': return cmdHypothesis(rest);
    case 'observe': return cmdObserve(rest);
    case 'verify': return cmdVerify(rest);
    case 'brief': return cmdBrief(rest);
    case 'list': return cmdList(rest);
    default:
      process.stdout.write('usage: evidence-ledger.js claim|hypothesis|observe|verify|brief|list\n');
      return cmd ? 2 : 0;
  }
}

if (require.main === module) process.exit(main());

module.exports = { load, save, ledgerPath, scanSecrets, sourceIsLocal, resolveSource, SCHEMA };
