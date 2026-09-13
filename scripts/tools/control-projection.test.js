'use strict';
const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const {
  canonicalJson,
  computeEventUid,
  copyEscape,
  splitCompleteLines,
  decideResume,
  parseAuditLine,
  parseRoutingLine,
  buildRows,
  loadCursor,
  saveCursor,
  cursorPath,
  runStream,
} = require('./control-projection.js');

function withIsolatedStateDir(fn) {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'ctl-state-'));
  const prevEnv = process.env.CCSU_CONTROL_STATE_DIR;
  process.env.CCSU_CONTROL_STATE_DIR = tmp;
  try {
    fn(tmp);
  } finally {
    if (prevEnv === undefined) delete process.env.CCSU_CONTROL_STATE_DIR; else process.env.CCSU_CONTROL_STATE_DIR = prevEnv;
    fs.rmSync(tmp, { recursive: true, force: true });
  }
}

// ---- canonicalJson / computeEventUid ---------------------------------

test('canonicalJson: キー順序が異なっても同じ文字列になる', () => {
  const a = canonicalJson({ b: 1, a: 2 });
  const b = canonicalJson({ a: 2, b: 1 });
  assert.strictEqual(a, b);
});

test('computeEventUid: 同一入力は同一ゴールデンベクタになる', () => {
  const uid = computeEventUid('audit', 3, { tool: 'Bash', action: 'git push' });
  assert.strictEqual(uid, computeEventUid('audit', 3, { action: 'git push', tool: 'Bash' }));
  assert.match(uid, /^[0-9a-f]{64}$/);
});

test('computeEventUid: stream / seq / payload のいずれかが違えば別の値になる', () => {
  const base = computeEventUid('audit', 1, { a: 1 });
  assert.notStrictEqual(base, computeEventUid('routing', 1, { a: 1 }));
  assert.notStrictEqual(base, computeEventUid('audit', 2, { a: 1 }));
  assert.notStrictEqual(base, computeEventUid('audit', 1, { a: 2 }));
});

// ---- copyEscape --------------------------------------------------------

test('copyEscape: バックスラッシュを最初に処理する (二重エスケープを防ぐ)', () => {
  assert.strictEqual(copyEscape('a\\tb'), 'a\\\\tb');
});
test('copyEscape: タブ・改行・CR をエスケープする', () => {
  assert.strictEqual(copyEscape('a\tb\nc\rd'), 'a\\tb\\nc\\rd');
});
test('copyEscape: SQLインジェクション的な文字列もデータ行としてのみ扱われる', () => {
  const payload = JSON.stringify({ note: "'; DROP TABLE control.audit_events; --" });
  const escaped = copyEscape(payload);
  assert.ok(escaped.includes('DROP TABLE'));
  assert.ok(!escaped.includes('\\n'));
});

// ---- splitCompleteLines -------------------------------------------------

test('splitCompleteLines: 末尾の不完全な行は消費しない', () => {
  const { lines, consumedBytes } = splitCompleteLines(Buffer.from('a\nb\nc', 'utf8'));
  assert.deepStrictEqual(lines, ['a', 'b']);
  assert.strictEqual(consumedBytes, 4); // "a\n" + "b\n"
});
test('splitCompleteLines: CRLF を除去する', () => {
  const { lines } = splitCompleteLines(Buffer.from('a\r\nb\r\n', 'utf8'));
  assert.deepStrictEqual(lines, ['a', 'b']);
});
test('splitCompleteLines: 日本語行でもバイトオフセットが正しい (マルチバイト文字)', () => {
  const buf = Buffer.from('こんにちは\n世界\n', 'utf8');
  const { lines, consumedBytes } = splitCompleteLines(buf);
  assert.deepStrictEqual(lines, ['こんにちは', '世界']);
  assert.strictEqual(consumedBytes, buf.length);
});
test('splitCompleteLines: 完全に空バッファなら何も返さない', () => {
  const { lines, consumedBytes } = splitCompleteLines(Buffer.alloc(0));
  assert.deepStrictEqual(lines, []);
  assert.strictEqual(consumedBytes, 0);
});

// ---- decideResume --------------------------------------------------------

test('decideResume: 前回カーソルなしは fresh', () => {
  assert.strictEqual(decideResume(null, { dev: 1, ino: 1, size: 10 }, 'h'), 'fresh');
});
test('decideResume: 同一 inode でサイズ変化なしは idle', () => {
  const prev = { dev: 1, ino: 1, offset: 10, firstLineHash: 'h' };
  assert.strictEqual(decideResume(prev, { dev: 1, ino: 1, size: 10 }, 'h'), 'idle');
});
test('decideResume: 同一 inode でサイズ増加は resume', () => {
  const prev = { dev: 1, ino: 1, offset: 10, firstLineHash: 'h' };
  assert.strictEqual(decideResume(prev, { dev: 1, ino: 1, size: 20 }, 'h'), 'resume');
});
test('decideResume: 同一 inode でサイズ縮小は truncated', () => {
  const prev = { dev: 1, ino: 1, offset: 10, firstLineHash: 'h' };
  assert.strictEqual(decideResume(prev, { dev: 1, ino: 1, size: 3 }, 'h'), 'truncated');
});
test('decideResume: inode 変化は rotated', () => {
  const prev = { dev: 1, ino: 1, offset: 10, firstLineHash: 'h' };
  assert.strictEqual(decideResume(prev, { dev: 1, ino: 2, size: 5 }, 'h2'), 'rotated');
});
test('decideResume: inode 同一でも先頭行ハッシュ不一致 (inode 再利用) は rotated', () => {
  const prev = { dev: 1, ino: 1, offset: 10, firstLineHash: 'h' };
  assert.strictEqual(decideResume(prev, { dev: 1, ino: 1, size: 20 }, 'different'), 'rotated');
});

// ---- parseAuditLine / parseRoutingLine ----------------------------------

test('parseAuditLine: tool を event_type の接尾辞にする', () => {
  const parsed = parseAuditLine(JSON.stringify({ ts: '2026-09-13T00:00:00Z', session: 's1', project: 'p1', tool: 'Bash', action: 'git push' }));
  assert.strictEqual(parsed.event_type, 'audit.bash');
  assert.strictEqual(parsed.project_key, 'p1');
  assert.strictEqual(parsed.run_ref, 's1');
});
test('parseRoutingLine: execution を agent_ref にする', () => {
  const parsed = parseRoutingLine(JSON.stringify({ at: '2026-09-13T00:00:00Z', execution: 'Subagent', task_type: 'change' }));
  assert.strictEqual(parsed.event_type, 'router.decision');
  assert.strictEqual(parsed.agent_ref, 'Subagent');
});
test('parseAuditLine: 壊れた JSON は例外を投げる (呼び出し側が握りつぶす契約)', () => {
  assert.throws(() => parseAuditLine('{not json'));
});

// ---- buildRows -----------------------------------------------------------

test('buildRows: 空行はスキップしつつ seq は消費する (欠番を空けない設計)', () => {
  const lines = ['{"ts":"t","tool":"Bash","action":"a"}', '', '{"ts":"t","tool":"Bash","action":"b"}'];
  const { rows, nextSeq } = buildRows('audit', require('./control-projection.js').parseAuditLine, lines, 0);
  assert.strictEqual(rows.length, 2);
  assert.strictEqual(nextSeq, 3);
  assert.strictEqual(rows[0].source_seq, 0);
  assert.strictEqual(rows[1].source_seq, 2);
});
test('buildRows: 壊れた行は静かにスキップし他の行の取り込みを止めない', () => {
  const lines = ['not json', '{"ts":"t","tool":"Bash","action":"a"}'];
  const { rows } = buildRows('audit', require('./control-projection.js').parseAuditLine, lines, 0);
  assert.strictEqual(rows.length, 1);
});

// ---- cursor 永続化 (atomic write) -----------------------------------------

test('saveCursor / loadCursor: 書いた内容がそのまま読み戻る', () => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'ctl-cursor-'));
  const prevEnv = process.env.CCSU_CONTROL_STATE_DIR;
  process.env.CCSU_CONTROL_STATE_DIR = tmp;
  try {
    saveCursor('audit', { dev: 1, ino: 2, offset: 100, nextSeq: 5, generation: 1, firstLineHash: 'h' });
    const loaded = loadCursor('audit');
    assert.deepStrictEqual(loaded, { dev: 1, ino: 2, offset: 100, nextSeq: 5, generation: 1, firstLineHash: 'h' });
  } finally {
    if (prevEnv === undefined) delete process.env.CCSU_CONTROL_STATE_DIR; else process.env.CCSU_CONTROL_STATE_DIR = prevEnv;
    fs.rmSync(tmp, { recursive: true, force: true });
  }
});
test('loadCursor: カーソルファイルが無ければ null', () => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'ctl-cursor-'));
  const prevEnv = process.env.CCSU_CONTROL_STATE_DIR;
  process.env.CCSU_CONTROL_STATE_DIR = tmp;
  try {
    assert.strictEqual(loadCursor('nope'), null);
  } finally {
    if (prevEnv === undefined) delete process.env.CCSU_CONTROL_STATE_DIR; else process.env.CCSU_CONTROL_STATE_DIR = prevEnv;
    fs.rmSync(tmp, { recursive: true, force: true });
  }
});
test('cursorPath: stream ごとに別のファイルになる', () => {
  const prevEnv = process.env.CCSU_CONTROL_STATE_DIR;
  process.env.CCSU_CONTROL_STATE_DIR = '/tmp/ctl-test-dir';
  try {
    assert.notStrictEqual(cursorPath('audit'), cursorPath('routing'));
  } finally {
    if (prevEnv === undefined) delete process.env.CCSU_CONTROL_STATE_DIR; else process.env.CCSU_CONTROL_STATE_DIR = prevEnv;
  }
});

// ---- runStream (shadow モード: DB 不要。ファイル I/O とローテーション drain の統合検証) ----

test('runStream shadow: fresh 実行は全行を検出しカーソルを保存する', () => {
  withIsolatedStateDir(() => {
    const repo = fs.mkdtempSync(path.join(os.tmpdir(), 'ctl-repo-'));
    const dataDir = path.join(repo, '.claude', 'claudeos', 'data');
    fs.mkdirSync(dataDir, { recursive: true });
    fs.writeFileSync(path.join(dataDir, 'audit-log.jsonl'),
      '{"ts":"t0","tool":"Bash","action":"a"}\n{"ts":"t1","tool":"Bash","action":"b"}\n');
    const result = runStream('audit', repo, 'shadow', 'unused-db', null);
    assert.strictEqual(result.ok, true);
    assert.strictEqual(result.status, 'fresh');
    assert.strictEqual(result.rows, 2);
    const cursor = loadCursor('audit');
    assert.strictEqual(cursor.nextSeq, 2);
    assert.strictEqual(cursor.generation, 1);
  });
});

test('runStream shadow: 追記後の再実行は resume で新規行だけ検出する', () => {
  withIsolatedStateDir(() => {
    const repo = fs.mkdtempSync(path.join(os.tmpdir(), 'ctl-repo-'));
    const dataDir = path.join(repo, '.claude', 'claudeos', 'data');
    fs.mkdirSync(dataDir, { recursive: true });
    const file = path.join(dataDir, 'audit-log.jsonl');
    fs.writeFileSync(file, '{"ts":"t0","tool":"Bash","action":"a"}\n');
    runStream('audit', repo, 'shadow', 'unused-db', null);
    fs.appendFileSync(file, '{"ts":"t1","tool":"Bash","action":"b"}\n');
    const result = runStream('audit', repo, 'shadow', 'unused-db', null);
    assert.strictEqual(result.status, 'resume');
    assert.strictEqual(result.rows, 1);
  });
});

test('runStream shadow: ローテーション後は旧ファイル(.1)の未読分を drain してから新世代を読む (取りこぼしゼロ)', () => {
  withIsolatedStateDir(() => {
    const repo = fs.mkdtempSync(path.join(os.tmpdir(), 'ctl-repo-'));
    const dataDir = path.join(repo, '.claude', 'claudeos', 'data');
    fs.mkdirSync(dataDir, { recursive: true });
    const file = path.join(dataDir, 'audit-log.jsonl');
    const rotated = `${file}.1`;

    // 1 回目: 3 行書いてカーソルを 2 行目までしか進めない状況を作る
    // (audit-trail.js の rotateIfNeeded は現在の書込み前にサイズ判定するため、
    //  ローテーション発生時点で「まだ射影ワーカーが読んでいない末尾行」が
    //  <file>.1 側に残りうる、という現実のタイミングを模擬する)。
    fs.writeFileSync(file, '{"ts":"t0","tool":"Bash","action":"a"}\n{"ts":"t1","tool":"Bash","action":"b"}\n');
    let r1 = runStream('audit', repo, 'shadow', 'unused-db', null);
    assert.strictEqual(r1.rows, 2);

    // まだ射影していない3行目を追記してから、実際の rotateIfNeeded と同じ rename でローテーションする。
    fs.appendFileSync(file, '{"ts":"t2","tool":"Bash","action":"unread-before-rotation"}\n');
    fs.renameSync(file, rotated); // <file>.1 は旧 inode を保持。<file> はまだ存在しない。
    fs.writeFileSync(file, '{"ts":"t3","tool":"Bash","action":"new-generation"}\n'); // 新しい inode

    const r2 = runStream('audit', repo, 'shadow', 'unused-db', null);
    assert.strictEqual(r2.status, 'rotated');
    assert.strictEqual(r2.drained, 1); // t2 (旧世代の未読分) を回収
    assert.strictEqual(r2.rows, 2); // drain 1 件 + 新世代 1 件
    assert.strictEqual(r2.generation, 2);
  });
});
