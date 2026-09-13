#!/usr/bin/env node
'use strict';
// a2a-gateway.js — ClaudeOS v11 Control Plane A2A Gateway (localhost 限定, ゼロ依存)
//
// 目的: Codex / DeepSeek Harness など別ランタイムのプロセスが、bash/psql に
//       直接触れずに claudeos_control の一部機能 (health / dashboard / run
//       lifecycle / Task Passport) を呼べるようにする最小限の HTTP API。
//
// 設計方針 (docs/architecture/ControlPlaneデータ基盤仕様.md §5 に準拠):
//   - 127.0.0.1 にのみ bind する (0.0.0.0 で listen しない)。外部公開・DNS が
//     必要になった時点で Approval PR へ分離する (本ゲートウェイの対象外)。
//   - 秘密は 1 つだけ (Bearer token)。~/.claudeos/control-plane/a2a-token に
//     0600 で保存し、無ければ起動時に生成する。値をログへ出力しない。
//   - SQL を直接組み立てない。全ての操作は bin/control-db.sh (lib/control-db.sh
//     で実DB検証済みの ctl__* 関数) へ spawn するだけの薄いラッパーに留める。
//   - fail-soft: 個々のリクエストの失敗がプロセス全体を落とさない。
//
// 使い方:
//   node scripts/tools/a2a-gateway.js [--port 8730]
//   環境変数 CCSU_A2A_PORT でも指定可能 (--port が優先)。
//
// エンドポイント (すべて Authorization: Bearer <token> が必須):
//   GET  /health                     ctl__health
//   GET  /dashboard                  ctl__dashboard_json
//   POST /runs                       ctl__run_start        body: {project_key,...}
//   POST /runs/:id/heartbeat         ctl__run_heartbeat
//   POST /runs/:id/finish            ctl__run_finish       body: {status,...}
//   GET  /passport/:runId            ctl__passport_export
//   POST /passport                   ctl__passport_import  body: Task Passport JSON

const http = require('http');
const fs = require('fs');
const os = require('os');
const path = require('path');
const crypto = require('crypto');
const { spawnSync } = require('child_process');

const REPO_ROOT = path.resolve(__dirname, '..', '..');
const CONTROL_DB_SH = path.join(REPO_ROOT, 'bin', 'control-db.sh');

function stateDir() {
  return process.env.CCSU_CONTROL_STATE_DIR
    || path.join(process.env.CCSU_HOME || path.join(os.homedir(), '.claudeos'), 'control-plane');
}

function tokenPath() {
  return path.join(stateDir(), 'a2a-token');
}

// loadOrCreateToken — 既存トークンを読むか、無ければ生成して 0600 で保存する。
function loadOrCreateToken() {
  const dir = stateDir();
  const file = tokenPath();
  try {
    return fs.readFileSync(file, 'utf8').trim();
  } catch {
    fs.mkdirSync(dir, { recursive: true });
    const token = crypto.randomBytes(32).toString('hex');
    const tmp = `${file}.tmp.${process.pid}`;
    fs.writeFileSync(tmp, token, { mode: 0o600 });
    fs.renameSync(tmp, file);
    try { fs.chmodSync(file, 0o600); } catch { /* best-effort on some filesystems */ }
    return token;
  }
}

// timingSafeEqualStr — タイミング攻撃を避けるため長さを揃えてから比較する。
function timingSafeEqualStr(a, b) {
  const ab = Buffer.from(String(a), 'utf8');
  const bb = Buffer.from(String(b), 'utf8');
  if (ab.length !== bb.length) {
    // 長さが違っても比較コストを揃えるため、同じ長さのダミーと比較しておく。
    crypto.timingSafeEqual(ab, ab);
    return false;
  }
  return crypto.timingSafeEqual(ab, bb);
}

// runCtl — bin/control-db.sh <subcommand> [args...] を実行し {status, stdout, stderr} を返す。
//   引数は spawnSync の argv 配列として渡すため、シェル経由の文字列補間は一切しない。
function runCtl(subcommand, args = [], input) {
  const r = spawnSync('bash', [CONTROL_DB_SH, subcommand, ...args], {
    cwd: REPO_ROOT,
    encoding: 'utf8',
    input,
    timeout: 30000,
    env: { ...process.env, CLAUDEOS_PLAIN_OUTPUT: '1' },
  });
  return { status: r.status, stdout: (r.stdout || '').trim(), stderr: (r.stderr || '').trim() };
}

function sendJson(res, code, obj) {
  const body = JSON.stringify(obj);
  res.writeHead(code, { 'Content-Type': 'application/json; charset=utf-8', 'Content-Length': Buffer.byteLength(body) });
  res.end(body);
}

function readBody(req, maxBytes = 1024 * 1024) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on('data', (c) => {
      size += c.length;
      if (size > maxBytes) { reject(new Error('body too large')); req.destroy(); return; }
      chunks.push(c);
    });
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    req.on('error', reject);
  });
}

function parseJsonSafe(text) {
  try { return JSON.parse(text || '{}'); } catch { return null; }
}

// runIdFromPath — /runs/:id/... や /passport/:id からの単純な ID 抽出。
//   SQL へは渡さず bin/control-db.sh の argv 経由でのみ使われるため注入不可。
const RUN_ID_RE = /^[A-Za-z0-9_-]{1,128}$/;

async function handle(req, res) {
  const url = new URL(req.url, 'http://localhost');
  const method = req.method;
  const parts = url.pathname.split('/').filter(Boolean);

  try {
    if (method === 'GET' && parts.length === 1 && parts[0] === 'health') {
      const r = runCtl('health');
      return sendJson(res, r.status === 0 ? 200 : 503, { ok: r.status === 0, detail: r.stdout || r.stderr });
    }
    if (method === 'GET' && parts.length === 1 && parts[0] === 'dashboard') {
      const r = runCtl('dashboard');
      const parsed = parseJsonSafe(r.stdout);
      return sendJson(res, 200, parsed || { health: false, error: 'dashboard unavailable' });
    }
    if (method === 'POST' && parts.length === 1 && parts[0] === 'runs') {
      const body = parseJsonSafe(await readBody(req));
      if (!body || !body.project_key) return sendJson(res, 400, { error: 'project_key is required' });
      const args = ['--project-key', body.project_key];
      if (body.run_kind) args.push('--run-kind', body.run_kind);
      if (body.goal_type) args.push('--goal-type', body.goal_type);
      if (body.lease_owner) args.push('--lease-owner', body.lease_owner);
      if (body.git_head_sha) args.push('--git-head-sha', body.git_head_sha);
      const r = runCtl('run-start', args);
      if (r.status !== 0) return sendJson(res, 502, { error: r.stderr || 'run-start failed' });
      return sendJson(res, 201, { run_id: r.stdout });
    }
    if (method === 'POST' && parts.length === 3 && parts[0] === 'runs' && parts[2] === 'heartbeat' && RUN_ID_RE.test(parts[1])) {
      const r = runCtl('run-heartbeat', ['--run-id', parts[1]]);
      return sendJson(res, r.status === 0 ? 200 : 502, { ok: r.status === 0, detail: r.stderr });
    }
    if (method === 'POST' && parts.length === 3 && parts[0] === 'runs' && parts[2] === 'finish' && RUN_ID_RE.test(parts[1])) {
      const body = parseJsonSafe(await readBody(req));
      if (!body || !body.status) return sendJson(res, 400, { error: 'status is required' });
      const args = ['--run-id', parts[1], '--status', body.status];
      if (body.exit_code !== undefined) args.push('--exit-code', String(body.exit_code));
      if (body.summary) args.push('--summary', body.summary);
      const r = runCtl('run-finish', args);
      return sendJson(res, r.status === 0 ? 200 : 502, { ok: r.status === 0, detail: r.stderr });
    }
    if (method === 'GET' && parts.length === 2 && parts[0] === 'passport' && RUN_ID_RE.test(parts[1])) {
      const r = runCtl('passport-export', ['--run-id', parts[1]]);
      if (r.status !== 0) return sendJson(res, 404, { error: r.stderr || 'run not found' });
      const parsed = parseJsonSafe(r.stdout);
      return sendJson(res, 200, parsed || { error: 'invalid passport produced' });
    }
    if (method === 'POST' && parts.length === 1 && parts[0] === 'passport') {
      const raw = await readBody(req);
      const tmp = path.join(os.tmpdir(), `a2a-passport-${process.pid}-${Date.now()}.json`);
      fs.writeFileSync(tmp, raw, { mode: 0o600 });
      try {
        const r = runCtl('passport-import', ['--file', tmp]);
        if (r.status !== 0) return sendJson(res, 422, { error: r.stderr || 'passport rejected' });
        return sendJson(res, 201, { run_id: r.stdout });
      } finally {
        try { fs.unlinkSync(tmp); } catch { /* best-effort cleanup */ }
      }
    }
    return sendJson(res, 404, { error: 'not found' });
  } catch (e) {
    return sendJson(res, 500, { error: String(e && e.message || e) });
  }
}

function main() {
  const argv = process.argv.slice(2);
  const pi = argv.indexOf('--port');
  const port = pi >= 0 ? Number(argv[pi + 1]) : Number(process.env.CCSU_A2A_PORT || 8730);
  const token = loadOrCreateToken();

  const server = http.createServer((req, res) => {
    const auth = req.headers.authorization || '';
    const m = /^Bearer\s+(.+)$/.exec(auth);
    if (!m || !timingSafeEqualStr(m[1], token)) {
      return sendJson(res, 401, { error: 'unauthorized' });
    }
    handle(req, res).catch((e) => sendJson(res, 500, { error: String(e && e.message || e) }));
  });

  // 127.0.0.1 にのみ bind する。0.0.0.0 や外部公開は行わない
  // (docs/architecture/ControlPlaneデータ基盤仕様.md §5)。
  server.listen(port, '127.0.0.1', () => {
    process.stdout.write(`a2a-gateway listening on http://127.0.0.1:${port} (token: ${tokenPath()})\n`);
  });

  const shutdown = () => { server.close(() => process.exit(0)); };
  process.on('SIGINT', shutdown);
  process.on('SIGTERM', shutdown);
}

if (require.main === module) main();

module.exports = { loadOrCreateToken, timingSafeEqualStr, runCtl, tokenPath, RUN_ID_RE };
