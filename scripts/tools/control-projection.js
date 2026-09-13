#!/usr/bin/env node
'use strict';
// control-projection.js — ClaudeOS v11 Control Plane 射影ワーカー (ゼロ依存)
//
// 目的: .claude/claudeos/data/*.jsonl (audit-log.jsonl / routing-pending.jsonl) を
//       PostgreSQL claudeos_control データベース (control.ingest_events) へ射影する。
//       hook は fail-soft で追記のみを行い、DB への反映はこのワーカーが cron/systemd
//       timer で out-of-band に行う。DB 障害が Claude Code のセッションを止めることはない。
//
// モード (CLAUDEOS_CONTROL_MODE または --mode):
//   shadow      (既定) 計算のみ。DB へは一切書かない。ファイルが引き続き正本。
//   compare     shadow に加え、DB 側と突き合わせて乖離 (only_file/only_db) を報告する。
//   dual-write  DB へ書き込む。ファイルも引き続き正本のまま書き続ける。
//
// カーソル/冪等性の設計 (docs/architecture/ControlPlaneデータ基盤仕様.md §6 参照):
//   - stream ごとに dev/ino/size/先頭行 sha256 を記録し、ローテーション (inode 変更) と
//     truncate (同一 inode で size 縮小) を検知して generation を進める。
//   - idempotency_key = sha256(source_stream + ':' + source_seq + ':' + canonicalJson(payload))
//     (control.ingest_events の DDL コメントと同一の式)。source_seq は generation を跨いで
//     単調増加するカーソルの通し番号であり、物理ファイルの行番号ではない。
//   - DB 未接続 (shadow) でもカーソルはローカル JSON (tmp+rename で atomic) に前進させる。
//
// CLI:
//   node scripts/tools/control-projection.js --stream audit|routing [--mode shadow|compare|dual-write]
//     [--db <name>] [--dir <repo-root>]
//
// 環境変数:
//   CLAUDEOS_CONTROL_MODE   既定モード (--mode が優先)
//   CTL_DB                  既定 db 名 (既定 claudeos_control)
//   CCSU_HOME               カーソル保存先の親 (既定 ~/.claudeos)
//   CCSU_CONTROL_STATE_DIR  カーソル保存先を直接指定 (既定 $CCSU_HOME/control-plane)

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { spawnSync } = require('child_process');

// ------------------------------------------------------------
// 純粋関数 (I/O なし。テストで直接検証する)
// ------------------------------------------------------------

// canonicalJson — オブジェクトキーを再帰的にソートした決定論的 JSON 文字列。
//   同じ内容なら再シリアライズしても常に同じ文字列になるため、idempotency_key が安定する。
function canonicalJson(value) {
  if (value === null || typeof value !== 'object') return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(',')}]`;
  const keys = Object.keys(value).sort();
  return `{${keys.map((k) => `${JSON.stringify(k)}:${canonicalJson(value[k])}`).join(',')}}`;
}

function sha256Hex(str) {
  return crypto.createHash('sha256').update(str, 'utf8').digest('hex');
}

// computeEventUid — control.ingest_events.idempotency_key と同一の式。
function computeEventUid(stream, seq, payload) {
  return sha256Hex(`${stream}:${seq}:${canonicalJson(payload)}`);
}

// copyEscape — PostgreSQL COPY (TEXT format) 向けのエスケープ。
//   バックスラッシュを最初に処理しないと、後続のタブ/改行エスケープを二重に壊す。
function copyEscape(value) {
  return String(value)
    .replace(/\\/g, '\\\\')
    .replace(/\t/g, '\\t')
    .replace(/\n/g, '\\n')
    .replace(/\r/g, '\\r');
}

// splitCompleteLines — バッファを改行で分割し、末尾の不完全な行は消費しない。
//   戻り値: { lines: string[], consumedBytes: number }
//   consumedBytes は最後の完全な改行までのバイト数 (UTF-8 のマルチバイト文字を正しく数える)。
function splitCompleteLines(buffer) {
  const lines = [];
  let start = 0;
  let consumedBytes = 0;
  for (let i = 0; i < buffer.length; i++) {
    if (buffer[i] === 0x0a) {
      let end = i;
      if (end > start && buffer[end - 1] === 0x0d) end--; // CRLF 対応
      const line = buffer.slice(start, end).toString('utf8');
      lines.push(line);
      start = i + 1;
      consumedBytes = start;
    }
  }
  return { lines, consumedBytes };
}

// decideResume — 前回カーソルと現在の stat / 先頭行ハッシュから再開種別を決める。
//   'fresh'     : 前回カーソルなし (初回実行)
//   'idle'      : 同一 inode でサイズ変化なし (追記なし)
//   'resume'    : 同一 inode でサイズが前回オフセット以上 (通常の追記)
//   'truncated' : 同一 inode だがサイズが前回オフセット未満 (copytruncate 等)
//   'rotated'   : inode が変わった、または同一 inode で先頭行ハッシュが不一致 (inode 再利用)
function decideResume(prevCursor, stat, firstLineHash) {
  if (!prevCursor) return 'fresh';
  const sameInode = prevCursor.dev === stat.dev && prevCursor.ino === stat.ino;
  if (!sameInode) return 'rotated';
  if (prevCursor.firstLineHash != null && firstLineHash != null && prevCursor.firstLineHash !== firstLineHash) {
    return 'rotated';
  }
  if (stat.size < prevCursor.offset) return 'truncated';
  if (stat.size === prevCursor.offset) return 'idle';
  return 'resume';
}

// parseAuditLine — audit-trail.js が書く JSONL 1 行 ({ts,session,project,tool,action}) を
//   ingest_events 相当のフィールドへ正規化する。
function parseAuditLine(rawLine) {
  const rec = JSON.parse(rawLine);
  const tool = String(rec.tool || 'unknown').toLowerCase();
  return {
    event_type: `audit.${tool}`,
    event_time: rec.ts || new Date().toISOString(),
    project_key: rec.project || null,
    run_ref: rec.session || null,
    agent_ref: null,
    payload: rec,
  };
}

// parseRoutingLine — agent-router skill が追記する routing-pending.jsonl の 1 行
//   ({at, execution, worktree, reasons[], task_type, project?}) を正規化する。
function parseRoutingLine(rawLine) {
  const rec = JSON.parse(rawLine);
  return {
    event_type: 'router.decision',
    event_time: rec.at || new Date().toISOString(),
    project_key: rec.project || null,
    run_ref: null,
    agent_ref: rec.execution || null,
    payload: rec,
  };
}

const STREAMS = {
  audit: { file: '.claude/claudeos/data/audit-log.jsonl', parse: parseAuditLine },
  routing: { file: '.claude/claudeos/data/routing-pending.jsonl', parse: parseRoutingLine },
};

// ------------------------------------------------------------
// I/O ヘルパ
// ------------------------------------------------------------

function stateDir() {
  return process.env.CCSU_CONTROL_STATE_DIR || path.join(process.env.CCSU_HOME || path.join(require('os').homedir(), '.claudeos'), 'control-plane');
}

function cursorPath(streamKey) {
  return path.join(stateDir(), `cursor-${streamKey}.json`);
}

function loadCursor(streamKey) {
  try {
    return JSON.parse(fs.readFileSync(cursorPath(streamKey), 'utf8'));
  } catch {
    return null;
  }
}

// saveCursor — atomic write (tmp+rename)。リポジトリの他ファイルと同じ規約。
function saveCursor(streamKey, cursor) {
  const dir = stateDir();
  fs.mkdirSync(dir, { recursive: true });
  const dest = cursorPath(streamKey);
  const tmp = `${dest}.tmp.${process.pid}`;
  fs.writeFileSync(tmp, JSON.stringify(cursor, null, 2) + '\n');
  fs.renameSync(tmp, dest);
}

function statSafe(filePath) {
  try {
    const st = fs.statSync(filePath);
    return { dev: st.dev, ino: st.ino, size: st.size };
  } catch {
    return null;
  }
}

function readFirstLineHash(filePath) {
  try {
    const fd = fs.openSync(filePath, 'r');
    const buf = Buffer.alloc(4096);
    const n = fs.readSync(fd, buf, 0, buf.length, 0);
    fs.closeSync(fd);
    const nl = buf.indexOf(0x0a);
    const line = nl >= 0 ? buf.slice(0, nl) : buf.slice(0, n);
    return sha256Hex(line.toString('utf8'));
  } catch {
    return null;
  }
}

// readNewChunk — fromOffset から現在の EOF までを読み、完全な行だけを返す。
function readNewChunk(filePath, fromOffset, toSize) {
  if (toSize <= fromOffset) return { lines: [], newOffset: fromOffset };
  const fd = fs.openSync(filePath, 'r');
  const len = toSize - fromOffset;
  const buf = Buffer.alloc(len);
  fs.readSync(fd, buf, 0, len, fromOffset);
  fs.closeSync(fd);
  const { lines, consumedBytes } = splitCompleteLines(buf);
  return { lines, newOffset: fromOffset + consumedBytes };
}

// ------------------------------------------------------------
// psql 経由の DB アクセス (ゼロ依存: pg ドライバを使わず CLI へ shell out する)
// ------------------------------------------------------------

function pgHost() {
  return process.env.PGHOST || '/var/run/postgresql';
}

function psqlBin() {
  return process.env.PG_BIN ? path.join(process.env.PG_BIN, 'psql') : 'psql';
}

// runPsql — SQL 文字列を stdin 経由で渡す (シェル文字列補間をしないため injection 不可)。
function runPsql(db, sql, extraArgs = []) {
  const args = ['-h', pgHost(), '-d', db, '-v', 'ON_ERROR_STOP=1', '-q', ...extraArgs, '-f', '-'];
  const r = spawnSync(psqlBin(), args, { input: sql, encoding: 'utf8' });
  return { status: r.status, stdout: r.stdout || '', stderr: r.stderr || '' };
}

// fetchExistingUids — 指定 stream の idempotency_key 集合を DB から取得する (compare 用)。
function fetchExistingUids(db, streamKey) {
  const sql = `select idempotency_key from control.ingest_events where source_stream = '${streamKey.replace(/'/g, "''")}';`;
  const r = runPsql(db, sql, ['-A', '-t']);
  if (r.status !== 0) return { ok: false, uids: new Set(), error: r.stderr.slice(0, 300) };
  const uids = new Set(r.stdout.split('\n').map((s) => s.trim()).filter(Boolean));
  return { ok: true, uids };
}

// insertRows — TEMP テーブルへ COPY してから control.ingest_events へ ON CONFLICT DO NOTHING で流し込む。
//   ユーザーデータは COPY のデータ行にのみ現れ、SQL 文字列へは一切補間しない。
function insertRows(db, roleForSetRole, rows) {
  if (rows.length === 0) return { ok: true, inserted: 0 };
  const copyLines = rows.map((r) => copyEscape(JSON.stringify(r))).join('\n');
  const setRole = roleForSetRole ? `SET ROLE "${roleForSetRole}";\n` : '';
  const sql = `BEGIN;
${setRole}CREATE TEMP TABLE ctl_stage (payload text) ON COMMIT DROP;
COPY ctl_stage (payload) FROM STDIN;
${copyLines}
\\.
INSERT INTO control.ingest_events
  (idempotency_key, batch_id, source_stream, source_seq, content_sha256,
   event_type, event_time, project_key, run_ref, agent_ref, payload)
SELECT v->>'idempotency_key', NULL, v->>'source_stream', (v->>'source_seq')::bigint,
       v->>'content_sha256', v->>'event_type', (v->>'event_time')::timestamptz,
       v->>'project_key', v->>'run_ref', v->>'agent_ref', v->'payload'
  FROM (SELECT payload::jsonb AS v FROM ctl_stage) s
ON CONFLICT (idempotency_key) DO NOTHING;
COMMIT;
`;
  const r = runPsql(db, sql);
  if (r.status !== 0) return { ok: false, error: r.stderr.slice(0, 500) };
  return { ok: true, inserted: rows.length };
}

// ------------------------------------------------------------
// 1 stream の処理 (shadow / compare / dual-write 共通の入口)
// ------------------------------------------------------------

function buildRows(streamKey, parse, lines, startSeq) {
  const rows = [];
  let seq = startSeq;
  for (const line of lines) {
    if (!line.trim()) { seq++; continue; }
    let parsed;
    try {
      parsed = parse(line);
    } catch (e) {
      seq++;
      continue; // 壊れた行はスキップ (静かに落とさず、呼び出し側で reject カウントする設計は将来拡張)
    }
    const uid = computeEventUid(streamKey, seq, parsed.payload);
    rows.push({
      idempotency_key: uid,
      source_stream: streamKey,
      source_seq: seq,
      content_sha256: sha256Hex(line),
      event_type: parsed.event_type,
      event_time: parsed.event_time,
      project_key: parsed.project_key,
      run_ref: parsed.run_ref,
      agent_ref: parsed.agent_ref,
      payload: parsed.payload,
    });
    seq++;
  }
  return { rows, nextSeq: seq };
}

function runStream(streamKey, repoRoot, mode, db, roleForSetRole) {
  const stream = STREAMS[streamKey];
  if (!stream) return { ok: false, error: `unknown stream: ${streamKey}` };
  const filePath = path.join(repoRoot, stream.file);
  const stat = statSafe(filePath);
  const prevCursor = loadCursor(streamKey);

  if (!stat) {
    return { ok: true, stream: streamKey, mode, status: 'file-absent', rows: 0 };
  }
  const firstLineHash = readFirstLineHash(filePath);
  const resume = decideResume(prevCursor, stat, firstLineHash);

  if (resume === 'idle') {
    return { ok: true, stream: streamKey, mode, status: 'idle', rows: 0 };
  }

  let fromOffset = 0;
  let seq = 0;
  let generation = prevCursor ? prevCursor.generation : 1;
  let drainedRows = [];

  if (resume === 'resume') {
    fromOffset = prevCursor.offset;
    seq = prevCursor.nextSeq;
  } else if (resume === 'rotated' && prevCursor) {
    // audit-trail.js のローテーションは <file> を <file>.1 へ rename して新しい
    // <file> を作る。前回カーソルの inode が <file>.1 に一致する間だけ、旧世代の
    // 未読分 (rename 前に読み切れていなかった分) を回収してから新世代へ切り替える。
    // これを省くと、ローテーション直前に書かれた行が永久に失われる。
    const rotatedPath = `${filePath}.1`;
    const rotatedStat = statSafe(rotatedPath);
    if (rotatedStat && rotatedStat.dev === prevCursor.dev && rotatedStat.ino === prevCursor.ino) {
      const drained = readNewChunk(rotatedPath, prevCursor.offset, rotatedStat.size);
      drainedRows = buildRows(streamKey, stream.parse, drained.lines, prevCursor.nextSeq).rows;
    }
    generation = generation + 1;
  }
  // fresh / truncated は先頭から読み直す (generation は fresh=1、truncated は据え置き)。

  const { lines, newOffset } = readNewChunk(filePath, fromOffset, stat.size);
  const { rows: freshRows, nextSeq } = buildRows(streamKey, stream.parse, lines, seq);
  const rows = drainedRows.concat(freshRows);

  const result = { ok: true, stream: streamKey, mode, status: resume, generation, rows: rows.length };
  if (drainedRows.length > 0) result.drained = drainedRows.length;

  if (mode === 'compare') {
    const existing = fetchExistingUids(db, streamKey);
    if (!existing.ok) {
      result.compare = { error: existing.error };
    } else {
      const fileUids = new Set(rows.map((r) => r.idempotency_key));
      const onlyFile = [...fileUids].filter((u) => !existing.uids.has(u));
      const onlyDb = [...existing.uids].filter((u) => !fileUids.has(u));
      result.compare = {
        file_count: fileUids.size,
        db_count: existing.uids.size,
        only_file: onlyFile.length,
        only_db: onlyDb.length,
        verdict: onlyFile.length === 0 && onlyDb.length === 0 ? 'match' : 'drift',
      };
    }
    // compare は診断のみ。カーソルは前進させない。
    return result;
  }

  if (mode === 'dual-write' && rows.length > 0) {
    const ins = insertRows(db, roleForSetRole, rows);
    if (!ins.ok) {
      result.ok = false;
      result.error = ins.error;
      return result; // DB 失敗時はカーソルを進めない (次回同じ範囲を再送し冪等に吸収させる)
    }
    result.inserted = ins.inserted;
  }

  // shadow / dual-write (成功時) はカーソルを前進させる。
  saveCursor(streamKey, { dev: stat.dev, ino: stat.ino, offset: newOffset, nextSeq, generation, firstLineHash });
  return result;
}

// ------------------------------------------------------------
// CLI
// ------------------------------------------------------------

function parseArgs(argv) {
  const out = { stream: null, mode: null, db: null, dir: null, roleForSetRole: null };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--stream') out.stream = argv[++i];
    else if (a === '--mode') out.mode = argv[++i];
    else if (a === '--db') out.db = argv[++i];
    else if (a === '--dir') out.dir = argv[++i];
    else if (a === '--set-role') out.roleForSetRole = argv[++i];
  }
  return out;
}

function main() {
  const opt = parseArgs(process.argv.slice(2));
  const mode = opt.mode || process.env.CLAUDEOS_CONTROL_MODE || 'shadow';
  const db = opt.db || process.env.CTL_DB || 'claudeos_control';
  const repoRoot = opt.dir || path.resolve(__dirname, '..', '..');
  const streams = opt.stream ? [opt.stream] : Object.keys(STREAMS);

  const results = [];
  for (const s of streams) {
    try {
      results.push(runStream(s, repoRoot, mode, db, opt.roleForSetRole));
    } catch (e) {
      // fail-soft: 1 stream の異常が他 stream や呼び出し元に波及しない。
      results.push({ ok: false, stream: s, mode, error: String(e && e.message || e) });
    }
  }
  process.stdout.write(JSON.stringify({ mode, db, results }, null, 2) + '\n');
  const anyFail = results.some((r) => !r.ok);
  process.exitCode = anyFail ? 1 : 0;
}

if (require.main === module) main();

module.exports = {
  canonicalJson,
  sha256Hex,
  computeEventUid,
  copyEscape,
  splitCompleteLines,
  decideResume,
  parseAuditLine,
  parseRoutingLine,
  buildRows,
  statSafe,
  loadCursor,
  saveCursor,
  cursorPath,
  runStream,
  STREAMS,
};
