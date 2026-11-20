#!/usr/bin/env node
/**
 * synth-data.js — 合成データ生成 (Agent 評価用データセット)
 *
 * 役割: 実行履歴 (run-ledger の失敗記録 / 実行タスク) と git 履歴から、
 *       Agent 評価用の instruction/context/expected レコードを生成する。
 *       2026-09 の Synthetic Data を「この環境でできる範囲」(テキスト・コード限定)
 *       で実装する。画像・3D・センサは対象外 (GPU が無いため)。
 *
 * 原則:
 *   - 生成物は決定的 (同じ入力からは同じ出力。ソート順と id は内容ハッシュから作る)
 *   - 秘密情報を検出したら 1 件でも書き出さずに異常終了する (学習データ経由の漏えいを防ぐ)
 *   - 出所 (provenance) を必ず記録する。合成データを「実測」と混同させない
 *
 * 使い方:
 *   node scripts/tools/synth-data.js build [--source ledger|git|runs|all] [--count N] [--out FILE]
 *   node scripts/tools/synth-data.js stats [--source ...]        # 生成せずに件数だけ表示
 *   node scripts/tools/synth-data.js scan <file>                 # 秘密スキャンだけ実行
 *
 * 既定 out: <repo>/reports/synth/dataset-<YYYYMMDDThhmmss>.jsonl (stdout にも要約)
 * 保存先 root は CCSU_SYNTH_DIR で上書き可 (テスト用)
 */

'use strict';

const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { execFileSync } = require('node:child_process');

const REPO_ROOT = path.resolve(__dirname, '..', '..');
const SCHEMA = 'claudeos.synth-dataset/v1';

function runsRoot() {
  if (process.env.CCSU_RUNS_DIR) return process.env.CCSU_RUNS_DIR;
  const home = process.env.CLAUDEOS_HOME || process.env.CCSU_HOME || path.join(process.env.HOME || '', '.claudeos');
  return path.join(home, 'runs');
}

function synthDir() {
  return process.env.CCSU_SYNTH_DIR || path.join(REPO_ROOT, 'reports', 'synth');
}

function sha256(text) {
  return crypto.createHash('sha256').update(text).digest('hex');
}

/** 秘密情報のパターン。1 件でも当たればデータセットを作らない。 */
const SECRET_PATTERNS = [
  { name: 'private_key_block', re: /-----BEGIN [A-Z ]*PRIVATE KEY-----/ },
  { name: 'openai_key', re: /\bsk-[A-Za-z0-9_-]{16,}\b/ },
  { name: 'github_pat', re: /\bgh[pousr]_[A-Za-z0-9]{20,}\b/ },
  { name: 'aws_key', re: /\bAKIA[0-9A-Z]{16}\b/ },
  { name: 'google_api_key', re: /\bAIza[0-9A-Za-z_-]{30,}\b/ },
  { name: 'slack_token', re: /\bxox[baprs]-[A-Za-z0-9-]{10,}\b/ },
  { name: 'bearer_token', re: /Bearer\s+[A-Za-z0-9._-]{20,}/ },
  { name: 'env_assignment', re: /^[A-Z0-9_]*(TOKEN|SECRET|PASSWORD|API_KEY)[A-Z0-9_]*\s*=\s*\S+/m },
];

function scanSecrets(text) {
  const hits = [];
  for (const p of SECRET_PATTERNS) {
    if (p.re.test(text)) hits.push(p.name);
  }
  return hits;
}

/** readJsonl — 壊れた行は無視せず例外にする (黙って欠落させない) */
function readJsonl(file) {
  if (!fs.existsSync(file)) return [];
  const out = [];
  const lines = fs.readFileSync(file, 'utf8').split('\n');
  lines.forEach((line, i) => {
    if (line.trim() === '') return;
    try {
      out.push(JSON.parse(line));
    } catch (e) {
      throw new Error(`${file}:${i + 1} の JSON 解析に失敗: ${e.message}`);
    }
  });
  return out;
}

function readRunRecords() {
  const root = runsRoot();
  let dirs = [];
  try {
    dirs = fs.readdirSync(root).filter((d) => d.startsWith('run-'));
  } catch {
    return [];
  }
  const records = [];
  for (const d of dirs) {
    const file = path.join(root, d, 'run.json');
    try {
      records.push(JSON.parse(fs.readFileSync(file, 'utf8')));
    } catch {
      /* 壊れた run.json は候補から外す (件数は stats に出る) */
    }
  }
  return records;
}

function readGitSubjects(limit) {
  try {
    const out = execFileSync('git', ['-C', REPO_ROOT, 'log', `--max-count=${limit}`, '--format=%s'], {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
    });
    return out.split('\n').map((s) => s.trim()).filter(Boolean);
  } catch {
    return [];
  }
}

/**
 * buildRecords — 出所ごとの合成レコード
 *   failure-triage : run-ledger の失敗 signature から「症状→切り分け」タスクを作る
 *   task-plan      : 実行タスクから「計画立案」タスクを作る
 *   commit-intent  : git subject から「変更意図の説明」タスクを作る
 * 期待値 (expected) は必ず出所から機械的に導ける形に留める (推測を書かない)。
 */
function buildRecords(sources) {
  const records = [];
  const push = (kind, seed, body) => {
    const id = `syn-${kind}-${sha256(seed).slice(0, 12)}`;
    records.push({
      id,
      kind,
      instruction: body.instruction,
      context: body.context,
      expected: body.expected,
      provenance: body.provenance,
      content_sha256: sha256(JSON.stringify([kind, body.instruction, body.context, body.expected])),
    });
  };

  if (sources.has('ledger')) {
    const failures = readJsonl(path.join(runsRoot(), 'failures.jsonl'));
    const bySig = new Map();
    for (const f of failures) {
      const sig = String(f.signature || '');
      if (!sig) continue;
      if (!bySig.has(sig)) bySig.set(sig, { signature: sig, notes: [], projects: new Set(), count: 0 });
      const e = bySig.get(sig);
      e.notes.push(String(f.note || ''));
      e.projects.add(String(f.project || ''));
      e.count += 1;
    }
    for (const [sig, e] of [...bySig.entries()].sort((a, b) => a[0].localeCompare(b[0]))) {
      const note = e.notes.filter(Boolean).sort()[0] || '(note なし)';
      push('failure-triage', sig, {
        instruction: '次の失敗ログを切り分け、原因の候補と次に確認すべき点を挙げよ。',
        context: { signature: sig, occurrences: e.count, sample_note: note },
        expected: {
          signature: sig,
          occurrences: e.count,
          projects: [...e.projects].filter(Boolean).sort(),
          // 期待値は「同一 signature は同一原因」という判定に使える情報のみ
          requires_signature_match: true,
        },
        provenance: { source: 'run-ledger:failures.jsonl', ref: sig },
      });
    }
  }

  if (sources.has('runs')) {
    for (const r of readRunRecords().sort((a, b) => String(a.run_id).localeCompare(String(b.run_id)))) {
      push('task-plan', String(r.run_id), {
        instruction: '次の run を再開する手順を 1 つ選べ (checkpoint の phase から再開する)。',
        context: {
          run_id: r.run_id,
          project: r.project,
          task: r.task,
          status: r.status,
          phase: r.phase,
          checkpoints: (r.checkpoints || []).map((c) => c.phase),
        },
        expected: {
          resume_from_phase: r.phase,
          attempts: r.attempts || 1,
          resumable: (r.checkpoints || []).length > 0 && !['completed'].includes(r.status),
        },
        provenance: { source: 'run-ledger:run.json', ref: String(r.run_id) },
      });
    }
  }

  if (sources.has('git')) {
    for (const subject of [...new Set(readGitSubjects(400))].sort()) {
      push('commit-intent', subject, {
        instruction: '次のコミット件名が意図した変更内容を 1 文で説明せよ。',
        context: { subject },
        expected: { subject, scope_hint: (subject.match(/^([a-z]+)(\(([^)]+)\))?:/) || [])[3] || null },
        provenance: { source: 'git log --format=%s', ref: subject },
      });
    }
  }
  return records;
}

function writeJsonl(outFile, records) {
  fs.mkdirSync(path.dirname(outFile), { recursive: true });
  const body = records.map((r) => JSON.stringify(r)).join('\n') + '\n';
  fs.writeFileSync(outFile, body);
}

function parseArgs(argv) {
  const opts = { sources: new Set(), count: 0, out: '' };
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (a === '--source') {
      const v = argv[++i];
      if (v === 'all' || !v) ['ledger', 'runs', 'git'].forEach((s) => opts.sources.add(s));
      else opts.sources.add(v);
    } else if (a === '--count') {
      opts.count = Number(argv[++i] || 0);
    } else if (a === '--out') {
      opts.out = argv[++i] || '';
    }
  }
  if (opts.sources.size === 0) ['ledger', 'runs', 'git'].forEach((s) => opts.sources.add(s));
  return opts;
}

function cmdBuild(argv) {
  const opts = parseArgs(argv);
  let records = buildRecords(opts.sources);
  if (opts.count > 0) records = records.slice(0, opts.count);

  const blob = records.map((r) => JSON.stringify(r)).join('\n');
  const leaks = scanSecrets(blob);
  if (leaks.length > 0) {
    process.stderr.write(`❌ [ERR ] 秘密情報の疑いを検出したため書き出しを中止しました: ${[...new Set(leaks)].join(', ')}\n`);
    return 2;
  }

  const stamp = new Date().toISOString().replace(/[-:]/g, '').replace(/\..*/, 'Z');
  const out = opts.out || path.join(synthDir(), `dataset-${stamp}.jsonl`);
  writeJsonl(out, records);

  const byKind = records.reduce((acc, r) => { acc[r.kind] = (acc[r.kind] || 0) + 1; return acc; }, {});
  process.stdout.write(JSON.stringify({
    schema: SCHEMA,
    out,
    count: records.length,
    by_kind: byKind,
    sources: [...opts.sources].sort(),
    digest: sha256(blob + '\n'),
  }) + '\n');
  return 0;
}

function cmdStats(argv) {
  const opts = parseArgs(argv);
  const records = buildRecords(opts.sources);
  const blob = records.map((r) => JSON.stringify(r)).join('\n');
  process.stdout.write(JSON.stringify({
    schema: SCHEMA,
    count: records.length,
    by_kind: records.reduce((acc, r) => { acc[r.kind] = (acc[r.kind] || 0) + 1; return acc; }, {}),
    secret_hits: scanSecrets(blob),
    digest: sha256(blob + '\n'),
  }) + '\n');
  return 0;
}

function cmdScan(file) {
  if (!file) { process.stderr.write('scan には対象ファイルが必要です\n'); return 2; }
  const text = fs.readFileSync(file, 'utf8');
  const hits = scanSecrets(text);
  process.stdout.write(JSON.stringify({ file, secret_hits: hits }) + '\n');
  return hits.length > 0 ? 1 : 0;
}

function main() {
  const [cmd, ...rest] = process.argv.slice(2);
  switch (cmd) {
    case 'build': return cmdBuild(rest);
    case 'stats': return cmdStats(rest);
    case 'scan': return cmdScan(rest[0]);
    default:
      process.stdout.write(
        'usage: synth-data.js build|stats|scan [--source ledger|runs|git|all] [--count N] [--out FILE]\n'
      );
      return cmd ? 2 : 0;
  }
}

if (require.main === module) process.exit(main());

module.exports = { buildRecords, scanSecrets, readJsonl, runsRoot, synthDir, SECRET_PATTERNS };
