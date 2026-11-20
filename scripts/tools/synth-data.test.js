// synth-data.test.js — 合成データ生成の決定性・出所記録・秘密スキャンを検証する
'use strict';
const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { execFileSync } = require('node:child_process');

const CLI = path.join(__dirname, 'synth-data.js');

function sandbox() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'synth-'));
  const runs = path.join(root, 'runs');
  const out = path.join(root, 'out');
  fs.mkdirSync(runs, { recursive: true });
  fs.mkdirSync(out, { recursive: true });
  const failures = [
    { at: '2026-09-25T09:00:00Z', run_id: 'run-1', project: 'Demo', status: 'failed', signature: 'sig-aaaa', note: 'test failed at 09:00:00Z exit code 137 in /tmp/a/b.log' },
    { at: '2026-09-25T10:00:00Z', run_id: 'run-2', project: 'Demo', status: 'failed', signature: 'sig-aaaa', note: 'test failed at 10:00:00Z exit code 137 in /tmp/a/c.log' },
    { at: '2026-09-25T11:00:00Z', run_id: 'run-3', project: 'Other', status: 'blocked', signature: 'sig-bbbb', note: 'cloudflare tunnel handshake timeout' },
  ];
  fs.writeFileSync(path.join(runs, 'failures.jsonl'), failures.map((f) => JSON.stringify(f)).join('\n') + '\n');
  fs.mkdirSync(path.join(runs, 'run-20260925T000000-deadbeef'), { recursive: true });
  fs.writeFileSync(path.join(runs, 'run-20260925T000000-deadbeef', 'run.json'), JSON.stringify({
    run_id: 'run-20260925T000000-deadbeef', project: 'Demo', task: '大規模移行', status: 'stale',
    phase: 'analyze', attempts: 2, checkpoints: [{ seq: 1, phase: 'analyze' }],
  }));
  return { root, runs, out };
}

function run(args, env) {
  try {
    return { code: 0, stdout: execFileSync(process.execPath, [CLI, ...args], { encoding: 'utf8', env: { ...process.env, ...env } }) };
  } catch (e) {
    return { code: e.status, stdout: e.stdout ? String(e.stdout) : '' };
  }
}

test('synth-data: ledger から signature 単位の failure-triage を生成する', () => {
  const sb = sandbox();
  const r = run(['build', '--source', 'ledger', '--out', path.join(sb.out, 'ds.jsonl')], { CCSU_RUNS_DIR: sb.runs });
  assert.strictEqual(r.code, 0, r.stdout);
  const summary = JSON.parse(r.stdout);
  assert.strictEqual(summary.count, 2);                    // signature は 2 種類に集約
  assert.strictEqual(summary.by_kind['failure-triage'], 2);
  const lines = fs.readFileSync(path.join(sb.out, 'ds.jsonl'), 'utf8').trim().split('\n').map(JSON.parse);
  assert.strictEqual(lines.length, 2);
  for (const l of lines) {
    assert.match(l.id, /^syn-failure-triage-[0-9a-f]{12}$/);
    assert.strictEqual(l.kind, 'failure-triage');
    assert.ok(l.instruction && l.context && l.expected);
    assert.ok(l.provenance.source.startsWith('run-ledger:'));
    assert.strictEqual(l.content_sha256.length, 64);
  }
  const a = lines.find((l) => l.context.signature === 'sig-aaaa');
  assert.strictEqual(a.context.occurrences, 2);
  assert.deepStrictEqual(a.expected.projects, ['Demo']);
  assert.strictEqual(a.expected.requires_signature_match, true);
});

test('synth-data: 出力は決定的 (同入力・同 digest、順序も安定)', () => {
  const sb = sandbox();
  const env = { CCSU_RUNS_DIR: sb.runs };
  const r1 = run(['build', '--source', 'ledger', '--out', path.join(sb.out, 'a.jsonl')], env);
  const r2 = run(['build', '--source', 'ledger', '--out', path.join(sb.out, 'b.jsonl')], env);
  assert.strictEqual(JSON.parse(r1.stdout).digest, JSON.parse(r2.stdout).digest);
  assert.strictEqual(fs.readFileSync(path.join(sb.out, 'a.jsonl'), 'utf8'), fs.readFileSync(path.join(sb.out, 'b.jsonl'), 'utf8'));
});

test('synth-data: run.json から再開可否を含む task-plan を作る', () => {
  const sb = sandbox();
  const r = run(['build', '--source', 'runs', '--out', path.join(sb.out, 'runs.jsonl')], { CCSU_RUNS_DIR: sb.runs });
  assert.strictEqual(r.code, 0, r.stdout);
  const lines = fs.readFileSync(path.join(sb.out, 'runs.jsonl'), 'utf8').trim().split('\n').map(JSON.parse);
  assert.strictEqual(lines.length, 1);
  assert.strictEqual(lines[0].kind, 'task-plan');
  assert.strictEqual(lines[0].expected.resume_from_phase, 'analyze');
  assert.strictEqual(lines[0].expected.resumable, true);
});

test('synth-data: git 履歴から commit-intent を生成する', () => {
  const r = run(['stats', '--source', 'git']);
  assert.strictEqual(r.code, 0, r.stdout);
  const s = JSON.parse(r.stdout);
  assert.ok(s.by_kind['commit-intent'] > 0, 'commit-intent が 0 件');
  assert.strictEqual(s.secret_hits.length, 0);
});

test('synth-data: 秘密情報を検出したら書き出さず rc=2 (学習データ経由の漏えい防止)', () => {
  const sb = sandbox();
  fs.appendFileSync(path.join(sb.runs, 'failures.jsonl'),
    JSON.stringify({ at: 'x', run_id: 'run-9', project: 'Demo', status: 'failed', signature: 'sig-cccc', note: 'leaked key sk-abcdef0123456789ABCDEF' }) + '\n');
  const outFile = path.join(sb.out, 'leak.jsonl');
  const r = run(['build', '--source', 'ledger', '--out', outFile], { CCSU_RUNS_DIR: sb.runs });
  assert.strictEqual(r.code, 2);
  assert.strictEqual(fs.existsSync(outFile), false);
});

test('synth-data: --count と --source の絞り込みが効く', () => {
  const sb = sandbox();
  const r = run(['build', '--source', 'ledger', '--count', '1', '--out', path.join(sb.out, 'one.jsonl')], { CCSU_RUNS_DIR: sb.runs });
  assert.strictEqual(JSON.parse(r.stdout).count, 1);
  const s = run(['stats', '--source', 'ledger'], { CCSU_RUNS_DIR: sb.runs });
  assert.deepStrictEqual(Object.keys(JSON.parse(s.stdout).by_kind), ['failure-triage']);
});

test('synth-data: scan は既存ファイルの秘密検出に使える', () => {
  const sb = sandbox();
  const clean = path.join(sb.out, 'clean.txt');
  const dirty = path.join(sb.out, 'dirty.txt');
  fs.writeFileSync(clean, 'nothing sensitive here\n');
  fs.writeFileSync(dirty, 'GITHUB_TOKEN=ghp_0123456789abcdefghijABCDEFG\n');
  assert.strictEqual(run(['scan', clean]).code, 0);
  const d = run(['scan', dirty]);
  assert.strictEqual(d.code, 1);
  assert.ok(JSON.parse(d.stdout).secret_hits.includes('github_pat'));
});
