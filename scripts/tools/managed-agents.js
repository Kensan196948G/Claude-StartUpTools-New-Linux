#!/usr/bin/env node
'use strict';
// managed-agents.js — ClaudeOS × Claude Managed Agents の薄い Adapter (依存ゼロ・Node 組み込み fetch)
//
// 位置づけ: Local Claude Code が主系。Managed Agents は「低リスク・読取専用タスク」のクラウド補完先で、
//   既存 Agent Router (scripts/tools/agent-router.js) から選べる実行先の 1 つとして統合する。
//   新しいオーケストレーターは作らない。Agent ループと sandbox は Anthropic 側が持つ。
//
// 実装根拠: Anthropic 公式ドキュメント (platform.claude.com/docs/en/managed-agents/*) 2026-10-10 参照。
//   beta ヘッダ managed-agents-2026-04-01 / anthropic-version 2023-06-01。
//   SDK を使わず REST を直接呼ぶのは、本リポジトリが依存ゼロ (package.json dependencies:{}、
//   CI は npm install --package-lock-only) の bash + Node 構成のため。
//
// 安全設計:
//   - mode=disabled|dry-run では一切ネットワークへ出ない。live は config で明示した場合のみ。
//   - API キーは環境変数 ANTHROPIC_API_KEY からのみ読む。設定・台帳・出力へ保存/表示しない。
//   - セッション作成は Budget Guard の予約を通過した場合のみ。budget.max_list_cost は必ず付く。
//   - セッション作成 (POST) は自動再試行しない (重複課金防止)。再試行は冪等な GET のみ最大 1 回。
//   - 予算到達セッションの再開・上限引き上げ・削除は実装しない (人間の判断)。
//   - PoC の Agent は read / glob / grep のみ。MCP を宣言しないため、過去の MCP 実行クラッシュ経路を通らない。
//
// CLI:
//   managed-agents.js status [--probe]
//   managed-agents.js agents list|plan|sync [--role r]
//   managed-agents.js env plan|ensure
//   managed-agents.js session create --task-id T --role R (--prompt P | --prompt-file F) [--budget-cents N]
//                                    [--class check] [--repo https://github.com/o/r] [--ref main] [--ack-daily-soft]
//   managed-agents.js session run    (create と同じ引数) [--max-wait-seconds N]
//   managed-agents.js session wait --task-id T --session-id S [--max-wait-seconds N]
//   managed-agents.js session get|events|interrupt|close --session-id S [--task-id T]
//   managed-agents.js budget status | budget reconcile --console-usd 1.23 [--note text]
//   managed-agents.js route --json '<task json>' [--task-id T] [--budget-cents N]
//
// 終了コード: 0 成功 / 2 設定 / 3 予算 / 4 認証・権限 (BLOCKED) / 5 API 障害 / 6 重複 / 7 ポリシー拒否 / 8 タイムアウト

const fs = require('fs');
const os = require('os');
const path = require('path');
const crypto = require('crypto');
const budget = require('./managed-budget.js');
const payloadBuilder = require('./managed-session-payload.js');
const agentRouter = require('./agent-router.js');

const REPO_ROOT = path.resolve(__dirname, '..', '..');
const DEFAULT_BASE_URL = 'https://api.anthropic.com';
const DEFAULT_BETA = 'managed-agents-2026-04-01';
const API_VERSION = '2023-06-01';
const READ_ONLY_TOOLS = ['read', 'glob', 'grep'];

// --- エラー分類 ---
//   fallback: 'local' = 既存の Local 実行経路へ安全に戻してよい (予算不足・API 障害・未設定)
//             'none'  = 戻さない。認証・権限・ポリシー拒否は BLOCKED として人間へ返す
const ERROR_CLASSES = Object.freeze({
  CONFIG:            { exit: 2, fallback: 'local', state: 'UNAVAILABLE' },
  KEY_MISSING:       { exit: 2, fallback: 'local', state: 'UNAVAILABLE' },
  BUDGET:            { exit: 3, fallback: 'local', state: 'BUDGET_DENIED' },
  BILLING:           { exit: 3, fallback: 'local', state: 'CREDIT_SHORTAGE' },
  SESSION_BUDGET:    { exit: 3, fallback: 'none',  state: 'BUDGET_REACHED' },
  AUTH:              { exit: 4, fallback: 'none',  state: 'BLOCKED' },
  PERMISSION:        { exit: 4, fallback: 'none',  state: 'BLOCKED' },
  RATE_LIMIT:        { exit: 5, fallback: 'local', state: 'API_UNAVAILABLE' },
  SERVICE:           { exit: 5, fallback: 'local', state: 'API_UNAVAILABLE' },
  NETWORK:           { exit: 5, fallback: 'local', state: 'API_UNAVAILABLE' },
  INVALID_REQUEST:   { exit: 5, fallback: 'none',  state: 'FAILED' },
  NOT_FOUND:         { exit: 5, fallback: 'none',  state: 'FAILED' },
  CONFLICT:          { exit: 5, fallback: 'none',  state: 'FAILED' },
  DUPLICATE:         { exit: 6, fallback: 'none',  state: 'DUPLICATE' },
  POLICY:            { exit: 7, fallback: 'none',  state: 'BLOCKED' },
  TIMEOUT:           { exit: 8, fallback: 'local', state: 'API_UNAVAILABLE' },
});

class AdapterError extends Error {
  constructor(cls, code, message, extra) {
    super(message);
    this.cls = ERROR_CLASSES[cls] ? cls : 'CONFIG';
    this.code = code;
    this.extra = extra || {};
  }
}

function classifyHttp(status, body) {
  const type = (body && body.error && body.error.type) || '';
  const message = (body && body.error && body.error.message) || '';
  if (status === 401 || type === 'authentication_error') return 'AUTH';
  if (status === 403 || type === 'permission_error') return 'PERMISSION';
  if (status === 402 || type === 'billing_error') return 'BILLING';
  if (status === 429 || type === 'rate_limit_error') return 'RATE_LIMIT';
  if (status === 529 || type === 'overloaded_error' || status >= 500) return 'SERVICE';
  if (status === 404) return 'NOT_FOUND';
  if (status === 409) return 'CONFLICT';
  // クレジット不足の HTTP コードは公式に未確認 (402 / 400 のいずれもあり得る)。文言でも拾う。
  if (/credit balance|usage limits|billing/i.test(message)) return 'BILLING';
  return 'INVALID_REQUEST';
}

// フォールバック可否。安全上の拒否 (policyDenied) がある場合は分類に関わらず戻さない。
function fallbackDecision(cls, opts) {
  const c = ERROR_CLASSES[cls] || ERROR_CLASSES.CONFIG;
  if (opts && opts.policyDenied) return { to: 'none', state: 'BLOCKED', reason: 'security-or-human-gate-denial-is-not-bypassed' };
  return { to: c.fallback, state: c.state, reason: c.fallback === 'local' ? 'local-path-unaffected' : 'requires-human-decision' };
}

// --- 秘密の非表示 ---
function redact(text, secrets) {
  let s = String(text);
  for (const v of secrets || []) {
    if (typeof v === 'string' && v.length >= 6) s = s.split(v).join('<redacted>');
  }
  return s
    .replace(/sk-ant-[A-Za-z0-9_-]{8,}/g, '<redacted:anthropic-key>')
    .replace(/\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{16,}/g, '<redacted:github-token>')
    .replace(/\bgithub_pat_[A-Za-z0-9_]{16,}/g, '<redacted:github-token>')
    .replace(/(Bearer\s+)[A-Za-z0-9._~+/=-]{8,}/gi, '$1<redacted>');
}

const SECRET_KEY_RE = /(api[_-]?key|secret|password|passwd|token|authorization|credential)/i;
function findSecretKeys(obj, trail) {
  const hits = [];
  if (!obj || typeof obj !== 'object') return hits;
  for (const [k, v] of Object.entries(obj)) {
    const here = trail ? `${trail}.${k}` : k;
    if (k.startsWith('_')) continue;
    if (v && typeof v === 'object') { hits.push(...findSecretKeys(v, here)); continue; }
    // 「環境変数名」を持つキー (tokenEnv 等) と ID 参照は秘密ではない
    if (/Env$/.test(k) || /Ids?$/.test(k)) continue;
    if (SECRET_KEY_RE.test(k) && typeof v === 'string' && v.trim() !== '') hits.push(here);
  }
  return hits;
}

// --- 設定 ---
function resolveConfigPath(explicit, env) {
  return explicit || env.CLAUDEOS_MANAGED_AGENTS_CONFIG || path.join(REPO_ROOT, 'config', 'managed-agents.json');
}

function resolveStateDir(config, env) {
  if (env.CLAUDEOS_MA_STATE_DIR) return env.CLAUDEOS_MA_STATE_DIR;
  if (config && typeof config.stateDir === 'string' && config.stateDir) return config.stateDir.replace(/^~(?=\/|$)/, os.homedir());
  return path.join(env.CLAUDEOS_HOME || path.join(os.homedir(), '.claudeos'), 'managed-agents');
}

function isPlaceholder(id) { return !id || /xxx/i.test(String(id)); }

function loadRoster(config) {
  const p = (config && config.rosterPath) ? path.resolve(REPO_ROOT, config.rosterPath) : path.join(REPO_ROOT, 'config', 'managed-agents-roster.json');
  let roster;
  try { roster = JSON.parse(fs.readFileSync(p, 'utf8')); } catch (e) {
    throw new AdapterError('CONFIG', 'ROSTER_UNREADABLE', `roster を読み込めない: ${p} (${e.message})`);
  }
  if (!roster || typeof roster.agents !== 'object') throw new AdapterError('CONFIG', 'ROSTER_INVALID', 'roster.agents が無い');
  return roster;
}

// PoC の Agent は読取専用であることを構造で保証する (system プロンプト頼みにしない)。
function assertReadOnlyAgent(def) {
  const violations = [];
  if (Array.isArray(def.mcp_servers) && def.mcp_servers.length) violations.push('mcp_servers は PoC では宣言不可');
  if (def.multiagent) violations.push('multiagent は PoC では不可');
  if (Array.isArray(def.skills) && def.skills.length) violations.push('skills は PoC では不可');
  const tools = Array.isArray(def.tools) ? def.tools : [];
  if (tools.length !== 1 || tools[0].type !== 'agent_toolset_20260401') violations.push('tools は agent_toolset_20260401 の 1 件のみ');
  for (const t of tools) {
    if (t.type !== 'agent_toolset_20260401') continue;
    if (!t.default_config || t.default_config.enabled !== false) violations.push('default_config.enabled は false (opt-in 方式)');
    for (const c of t.configs || []) {
      if (c.enabled === true && !READ_ONLY_TOOLS.includes(c.name)) violations.push(`書込み/実行/外部通信ツール ${c.name} は有効化不可`);
    }
    const policy = t.default_config && t.default_config.permission_policy && t.default_config.permission_policy.type;
    if (policy && policy !== 'always_allow' && policy !== 'always_ask' && policy !== 'auto') violations.push(`permission_policy ${policy} は不明`);
  }
  if (violations.length) throw new AdapterError('POLICY', 'READ_ONLY_VIOLATION', `読取専用ポリシー違反: ${violations.join(' / ')}`, { violations });
  return true;
}

function agentDefinition(roster, role) {
  const a = roster.agents[role];
  if (!a) throw new AdapterError('CONFIG', 'ROLE_UNKNOWN', `roster に role=${role} が無い (候補: ${Object.keys(roster.agents).join(', ')})`);
  const body = {
    name: a.name,
    description: a.description,
    model: a.model,
    system: a.system,
    tools: [JSON.parse(JSON.stringify(roster.readOnlyToolset))],
  };
  assertReadOnlyAgent(body);
  const sha = crypto.createHash('sha256').update(JSON.stringify(body)).digest('hex').slice(0, 16);
  body.metadata = { claudeos_role: role, claudeos_def_sha: sha, claudeos_phase: String(roster.phase || 'poc') };
  return { body, sha, taskTypes: Array.isArray(a.taskTypes) ? a.taskTypes : [] };
}

// 設定契約の検証 (ネットワークなし)。Goal Router / status / route から使う。
function validateConfig(config) {
  const reasons = [];
  if (!config) return { ok: false, mode: 'missing', reasons: ['config-missing'] };
  const mode = String(config.mode || 'disabled');
  if (config.enabled !== true) reasons.push('not-enabled');
  if (mode === 'disabled') reasons.push('mode-disabled');
  else if (mode !== 'dry-run' && mode !== 'live') reasons.push('mode-invalid');
  const secretKeys = findSecretKeys(config, '');
  if (secretKeys.length) reasons.push(`secret-in-config:${secretKeys.join(',')}`);
  let policy = null;
  try { policy = budget.normalizePolicy(config.budgetPolicy); } catch (e) { reasons.push(`budget-policy-invalid:${e.message}`); }
  if (policy && policy.monthlyBudgetCents <= 0) reasons.push('monthly-budget-not-configured');
  const base = String(config.apiBaseUrl || DEFAULT_BASE_URL);
  if (!isAllowedBaseUrl(base)) reasons.push('api-base-url-not-allowed');
  try {
    const roster = loadRoster(config);
    for (const role of Object.keys(roster.agents)) agentDefinition(roster, role);
  } catch (e) { reasons.push(`roster-invalid:${e.code || e.message}`); }
  return { ok: reasons.length === 0, mode, reasons, policy };
}

// API キーを任意ホストへ送らないため、送信先は api.anthropic.com (とテスト用 loopback) に固定する。
function isAllowedBaseUrl(base) {
  try {
    const u = new URL(base);
    if (u.protocol === 'https:' && u.hostname === 'api.anthropic.com') return true;
    return (u.hostname === '127.0.0.1' || u.hostname === 'localhost') && (u.protocol === 'http:' || u.protocol === 'https:');
  } catch { return false; }
}

function createContext(opts) {
  const o = opts || {};
  const env = o.env || process.env;
  const configPath = resolveConfigPath(o.configPath, env);
  let config = o.config || null;
  if (!config && fs.existsSync(configPath)) {
    try { config = JSON.parse(fs.readFileSync(configPath, 'utf8')); } catch (e) {
      throw new AdapterError('CONFIG', 'CONFIG_UNREADABLE', `config を解釈できない: ${configPath} (${e.message})`);
    }
  }
  const validation = validateConfig(config);
  const stateDir = resolveStateDir(config, env);
  const githubTokenEnv = (config && config.github && config.github.workspace && config.github.workspace.tokenEnv) || 'CLAUDEOS_MA_GITHUB_TOKEN';
  return {
    env, config, configPath, validation,
    mode: validation.mode,
    policy: validation.policy || budget.normalizePolicy({}),
    stateDir,
    ledgerPath: path.join(stateDir, 'ledger.jsonl'),
    decisionsPath: path.join(stateDir, 'decisions.jsonl'),
    registryPath: path.join(stateDir, 'registry.json'),
    baseUrl: String((config && config.apiBaseUrl) || DEFAULT_BASE_URL).replace(/\/+$/, ''),
    betaHeader: String((config && config.betaHeader) || DEFAULT_BETA),
    apiKey: env.ANTHROPIC_API_KEY || '',
    githubTokenEnv,
    githubToken: env[githubTokenEnv] || '',
    fetch: o.fetch || globalThis.fetch,
    now: o.now || (() => new Date()),
    sleep: o.sleep || ((ms) => new Promise((r) => setTimeout(r, ms))),
    requestTimeoutMs: o.requestTimeoutMs || (config && config.requestTimeoutMs) || 30000,
  };
}

function secretsOf(ctx) { return [ctx.apiKey, ctx.githubToken].filter(Boolean); }

function requireUsable(ctx) {
  if (!ctx.validation.ok) {
    throw new AdapterError('CONFIG', 'MANAGED_UNAVAILABLE', `Managed Agents は利用不可: ${ctx.validation.reasons.join(', ')}`, { reasons: ctx.validation.reasons });
  }
}

function requireLive(ctx) {
  requireUsable(ctx);
  if (ctx.mode !== 'live') throw new AdapterError('CONFIG', 'NOT_LIVE', `mode=${ctx.mode} のため API を呼ばない (live は config で明示した場合のみ)`);
  if (!ctx.apiKey) throw new AdapterError('KEY_MISSING', 'API_KEY_MISSING', '環境変数 ANTHROPIC_API_KEY が未設定のため停止 (設定ファイルには書かない)');
}

// --- HTTP ---
async function apiRequest(ctx, method, urlPath, body, opts) {
  const idempotent = method === 'GET';
  const maxRetries = idempotent ? Math.min(1, ctx.policy.maxApiRetries) : 0;
  let attempt = 0;
  for (;;) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), ctx.requestTimeoutMs);
    let res;
    let cls = null;
    let errInfo = null;
    try {
      res = await ctx.fetch(`${ctx.baseUrl}${urlPath}`, {
        method,
        headers: {
          'x-api-key': ctx.apiKey,
          'anthropic-version': API_VERSION,
          'anthropic-beta': ctx.betaHeader,
          'content-type': 'application/json',
        },
        body: body === undefined ? undefined : JSON.stringify(body),
        signal: controller.signal,
      });
    } catch (e) {
      cls = e && e.name === 'AbortError' ? 'TIMEOUT' : 'NETWORK';
      errInfo = { message: cls === 'TIMEOUT' ? `API が ${ctx.requestTimeoutMs}ms 以内に応答しない` : `API へ接続できない (${redact(e && e.message, secretsOf(ctx))})` };
    } finally { clearTimeout(timer); }

    if (res) {
      let parsed = null;
      const text = await res.text();
      if (text) { try { parsed = JSON.parse(text); } catch { parsed = null; } }
      if (res.ok) return parsed;
      cls = classifyHttp(res.status, parsed);
      errInfo = {
        status: res.status,
        type: parsed && parsed.error && parsed.error.type,
        message: redact((parsed && parsed.error && parsed.error.message) || `HTTP ${res.status}`, secretsOf(ctx)),
        request_id: (parsed && parsed.request_id) || null,
        retry_after: res.headers && typeof res.headers.get === 'function' ? res.headers.get('retry-after') : null,
      };
    }
    const retryable = cls === 'RATE_LIMIT' || cls === 'SERVICE' || cls === 'NETWORK' || cls === 'TIMEOUT';
    if (retryable && attempt < maxRetries) {
      attempt += 1;
      const ra = Number(errInfo.retry_after);
      await ctx.sleep(Number.isFinite(ra) && ra > 0 ? Math.min(ra, 10) * 1000 : 1000);
      continue;
    }
    throw new AdapterError(cls, `API_${cls}`, errInfo.message, Object.assign({ attempts: attempt + 1, operation: (opts && opts.operation) || `${method} ${urlPath.split('?')[0]}` }, errInfo));
  }
}

async function listAll(ctx, urlPath, maxPages) {
  const out = [];
  let page = null;
  for (let n = 0; n < (maxPages || 10); n += 1) {
    const sep = urlPath.includes('?') ? '&' : '?';
    const res = await apiRequest(ctx, 'GET', page ? `${urlPath}${sep}page=${encodeURIComponent(page)}` : urlPath);
    for (const item of (res && res.data) || []) out.push(item);
    page = res && res.next_page;
    if (!page) break;
  }
  return out;
}

// --- registry (Anthropic 側リソース ID の対応表。秘密ではないが git 管理外) ---
function readRegistry(ctx) {
  try { return JSON.parse(fs.readFileSync(ctx.registryPath, 'utf8')); } catch { return { agents: {}, environment: null }; }
}

function writeRegistry(ctx, reg) {
  fs.mkdirSync(ctx.stateDir, { recursive: true, mode: 0o700 });
  const tmp = `${ctx.registryPath}.tmp.${process.pid}`;
  fs.writeFileSync(tmp, JSON.stringify(reg, null, 2) + '\n', { mode: 0o600 });
  fs.renameSync(tmp, ctx.registryPath);
}

function appendJsonl(file, obj) {
  fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
  fs.appendFileSync(file, JSON.stringify(obj) + '\n', { mode: 0o600 });
}

function resolveAgentRef(ctx, role) {
  const cfg = ctx.config && ctx.config.agents && ctx.config.agents[role];
  if (cfg && !isPlaceholder(cfg.id) && String(cfg.id).startsWith('agent_')) return { id: cfg.id, version: Number.isInteger(cfg.version) ? cfg.version : null, source: 'config' };
  const reg = readRegistry(ctx).agents[role];
  if (reg && reg.id) return { id: reg.id, version: Number.isInteger(reg.version) ? reg.version : null, source: 'registry' };
  return null;
}

function resolveEnvironmentId(ctx) {
  const id = ctx.config && ctx.config.environmentId;
  if (!isPlaceholder(id) && String(id).startsWith('env_')) return id;
  const reg = readRegistry(ctx).environment;
  return reg && reg.id ? reg.id : null;
}

// --- Agent 定義の一覧・同期 ---
function rosterSummary(ctx) {
  const roster = loadRoster(ctx.config);
  return Object.keys(roster.agents).map((role) => {
    const def = agentDefinition(roster, role);
    const ref = resolveAgentRef(ctx, role);
    return {
      role, name: def.body.name, model: typeof def.body.model === 'string' ? def.body.model : def.body.model.id,
      task_types: def.taskTypes, definition_sha: def.sha, read_only: true,
      agent_id: ref ? ref.id : null, agent_version: ref ? ref.version : null, synced: !!ref,
    };
  });
}

async function agentsSync(ctx, onlyRole) {
  requireUsable(ctx);
  const roster = loadRoster(ctx.config);
  const roles = onlyRole ? [onlyRole] : Object.keys(roster.agents);
  const plan = roles.map((role) => ({ role, definition: agentDefinition(roster, role) }));
  if (ctx.mode !== 'live') {
    return { mode: ctx.mode, executed: false, plan: plan.map((p) => ({ role: p.role, action: 'create-or-update', request: { method: 'POST', path: '/v1/agents', body: p.definition.body } })) };
  }
  requireLive(ctx);
  const existing = await listAll(ctx, '/v1/agents?limit=100');
  const reg = readRegistry(ctx);
  const results = [];
  for (const p of plan) {
    const found = existing.find((a) => !a.archived_at && a.metadata && a.metadata.claudeos_role === p.role);
    let agent;
    let action;
    if (!found) {
      agent = await apiRequest(ctx, 'POST', '/v1/agents', p.definition.body);
      action = 'created';
    } else if (found.metadata.claudeos_def_sha !== p.definition.sha) {
      // version を渡して楽観ロック (不一致は 409 → CONFLICT として返し、黙って上書きしない)
      agent = await apiRequest(ctx, 'POST', `/v1/agents/${found.id}`, Object.assign({ version: found.version }, p.definition.body));
      action = 'updated';
    } else { agent = found; action = 'unchanged'; }
    reg.agents[p.role] = { id: agent.id, version: agent.version, def_sha: p.definition.sha, synced_at: ctx.now().toISOString() };
    results.push({ role: p.role, action, agent_id: agent.id, version: agent.version });
  }
  writeRegistry(ctx, reg);
  return { mode: ctx.mode, executed: true, results };
}

async function agentsList(ctx) {
  if (ctx.mode !== 'live' || !ctx.validation.ok) return { mode: ctx.mode, source: 'roster', agents: rosterSummary(ctx) };
  requireLive(ctx);
  const remote = await listAll(ctx, '/v1/agents?limit=100');
  return {
    mode: ctx.mode, source: 'api',
    agents: rosterSummary(ctx),
    remote: remote.map((a) => ({ id: a.id, name: a.name, version: a.version, model: a.model && (a.model.id || a.model), archived: !!a.archived_at, role: (a.metadata && a.metadata.claudeos_role) || null })),
  };
}

async function envEnsure(ctx) {
  requireUsable(ctx);
  const roster = loadRoster(ctx.config);
  const def = roster.environment;
  if (!def || !def.config || !def.config.networking || def.config.networking.type !== 'limited') {
    // networking 省略時の既定は unrestricted。PoC は limited を必ず明示する。
    throw new AdapterError('POLICY', 'ENVIRONMENT_NOT_LIMITED', 'environment.config.networking.type は limited を明示する');
  }
  const body = { name: def.name, description: def.description, config: def.config };
  if (ctx.mode !== 'live') return { mode: ctx.mode, executed: false, plan: { method: 'POST', path: '/v1/environments', body } };
  requireLive(ctx);
  const known = resolveEnvironmentId(ctx);
  let environment;
  let action;
  if (known) { environment = await apiRequest(ctx, 'GET', `/v1/environments/${known}`); action = 'existing'; }
  else {
    const all = await listAll(ctx, '/v1/environments?limit=100');
    environment = all.find((e) => e.name === def.name && !e.archived_at);
    action = environment ? 'found' : 'created';
    if (!environment) environment = await apiRequest(ctx, 'POST', '/v1/environments', body);
  }
  const reg = readRegistry(ctx);
  reg.environment = { id: environment.id, name: environment.name, synced_at: ctx.now().toISOString() };
  writeRegistry(ctx, reg);
  return { mode: ctx.mode, executed: true, action, environment_id: environment.id };
}

// --- セッション ---
function buildResources(ctx, args) {
  const ws = (ctx.config && ctx.config.github && ctx.config.github.workspace) || {};
  const repo = args.repo || ws.repository || '';
  if (!repo) return { resources: [], repo: null };
  if (!/^https:\/\/github\.com\/[A-Za-z0-9._-]+\/[A-Za-z0-9._-]+$/.test(repo) || /\.git$/.test(repo)) {
    throw new AdapterError('CONFIG', 'REPO_URL_INVALID', `repository は https://github.com/<owner>/<repo> 形式のみ (actual: ${repo})`);
  }
  const ref = args.ref || ws.ref || '';
  const resource = { type: 'github_repository', url: repo, mount_path: ws.mountPath || '/workspace/repo' };
  if (ref) resource.checkout = /^[0-9a-f]{40}$/.test(ref) ? { type: 'commit', sha: ref } : { type: 'branch', name: ref };
  return { resources: [resource], repo, tokenRequired: true };
}

function resolveSessionRequest(ctx, args) {
  if (!args.taskId) throw new AdapterError('CONFIG', 'TASK_ID_REQUIRED', '--task-id は必須 (重複実行防止のキー)');
  if (!args.role) throw new AdapterError('CONFIG', 'ROLE_REQUIRED', '--role は必須');
  if (!args.prompt || !String(args.prompt).trim()) throw new AdapterError('CONFIG', 'PROMPT_REQUIRED', '--prompt または --prompt-file は必須');
  const roster = loadRoster(ctx.config);
  const def = agentDefinition(roster, args.role);
  const taskClass = args.taskClass === 'check' ? 'check' : 'task';

  // 予算: 明示指定 > config.budget。どちらも無ければ拒否 (予算未指定セッション禁止)。
  let cents = null;
  if (args.budgetCents != null) cents = budget.parseCentsString(args.budgetCents);
  else if (ctx.config.budget && ctx.config.budget.amountCents != null && ctx.config.budget.amountCents !== '') cents = budget.parseCentsString(ctx.config.budget.amountCents);
  if (cents == null) throw new AdapterError('BUDGET', 'BUDGET_REQUIRED', 'セッション予算が未指定 (--budget-cents か config.budget.amountCents が必須)');
  if ((ctx.config.budget && ctx.config.budget.currency && ctx.config.budget.currency !== 'USD')) throw new AdapterError('BUDGET', 'BUDGET_CURRENCY_INVALID', 'budget.currency は USD のみ');
  return { roster, def, taskClass, cents };
}

function buildSessionPayload(ctx, args, req, agentRef, environmentId, withSecrets) {
  const { resources } = buildResources(ctx, args);
  if (resources.length) {
    if (withSecrets) {
      if (!ctx.githubToken) throw new AdapterError('KEY_MISSING', 'GITHUB_TOKEN_MISSING', `環境変数 ${ctx.githubTokenEnv} が未設定 (読取専用の fine-grained PAT: Contents=Read のみ)`);
      resources[0].authorization_token = ctx.githubToken;
    } else {
      resources[0].authorization_token = `<env:${ctx.githubTokenEnv}>`;
    }
  }
  const cap = req.taskClass === 'check' ? Math.min(ctx.policy.connectionTestMaxCents, ctx.policy.sessionMaxCents) : ctx.policy.sessionMaxCents;
  let built;
  try {
    built = payloadBuilder.sessionCreate(ctx.config, {
      agent: agentRef.id,
      agentVersion: agentRef.version,
      environmentId,
      budgetCents: String(req.cents),
      maxCents: cap,
      title: `claudeos:${args.role}:${args.taskId}`,
      metadata: { claudeos_task_id: String(args.taskId).slice(0, 512), claudeos_role: args.role },
      resources,
      initialEvents: payloadBuilder.messageEvent(String(args.prompt)).events,
    });
  } catch (e) {
    if (e instanceof payloadBuilder.PayloadError) {
      throw new AdapterError(e.code === payloadBuilder.ERR_BUDGET ? 'BUDGET' : 'CONFIG', e.error, e.message, e.details);
    }
    throw e;
  }
  return built.payload;
}

function consoleUrl(ctx, sessionId) {
  const ws = (ctx.config && ctx.config.consoleWorkspace) || 'default';
  return `https://platform.claude.com/workspaces/${ws}/sessions/${sessionId}`;
}

async function sessionCreate(ctx, args) {
  requireUsable(ctx);
  const req = resolveSessionRequest(ctx, args);
  const now = ctx.now();
  const guardRequest = { taskId: args.taskId, cents: req.cents, taskClass: req.taskClass, role: args.role, ackDailySoft: !!args.ackDailySoft };

  if (ctx.mode !== 'live') {
    // dry-run: 台帳へ書かずに判定だけ行い、送信予定の payload を秘密なしで返す。
    const { entries, corrupt } = budget.readLedger(ctx.ledgerPath);
    const dup = budget.foldTasks(entries).get(args.taskId);
    const g = corrupt > 0 ? { allow: false, code: 'LEDGER_CORRUPT', message: '台帳に解釈できない行がある' } : budget.guard(entries, now, ctx.policy, guardRequest);
    const agentRef = resolveAgentRef(ctx, args.role) || { id: 'agent_DRYRUN_UNSYNCED', version: null, source: 'placeholder' };
    const environmentId = resolveEnvironmentId(ctx) || 'env_DRYRUN_UNSYNCED';
    const payload = buildSessionPayload(ctx, args, req, agentRef, environmentId, false);
    return {
      mode: ctx.mode, executed: false, task_id: args.taskId, role: args.role,
      duplicate: !!(dup && !dup.released),
      budget_guard: { allow: g.allow, code: g.code, stage: g.stage || null, message: g.message || '' },
      request: { method: 'POST', path: '/v1/sessions', headers: { 'x-api-key': '<env:ANTHROPIC_API_KEY>', 'anthropic-version': API_VERSION, 'anthropic-beta': ctx.betaHeader }, body: payload },
    };
  }

  requireLive(ctx);
  const agentRef = resolveAgentRef(ctx, args.role);
  if (!agentRef) throw new AdapterError('CONFIG', 'AGENT_NOT_SYNCED', `role=${args.role} の agent が未同期 (agents sync を先に実行)`);
  const environmentId = resolveEnvironmentId(ctx);
  if (!environmentId) throw new AdapterError('CONFIG', 'ENVIRONMENT_NOT_SYNCED', 'environment が未作成 (env ensure を先に実行)');
  const payload = buildSessionPayload(ctx, args, req, agentRef, environmentId, true);
  if (!payload.budget || !payload.budget.max_list_cost || payload.budget.max_list_cost.amount !== String(req.cents)) {
    throw new AdapterError('BUDGET', 'BUDGET_NOT_APPLIED', 'payload に budget.max_list_cost が反映されていない (送信しない)');
  }

  // 重複防止 + 予算ガード + 予約 (1 ロック内)。通過しなければ API を呼ばない。
  let g;
  try { g = budget.reserve(ctx.ledgerPath, now, ctx.policy, guardRequest); } catch (e) {
    if (e instanceof budget.BudgetError) throw new AdapterError('BUDGET', e.code, e.message);
    throw e;
  }
  if (!g.allow) {
    if (g.code === 'DUPLICATE_TASK') throw new AdapterError('DUPLICATE', g.code, g.message, { session_id: g.existing && g.existing.session_id });
    throw new AdapterError('BUDGET', g.code, g.message, { stage: g.stage || null, reason: g.reason || '' });
  }

  let session;
  try {
    session = await apiRequest(ctx, 'POST', '/v1/sessions', payload, { operation: 'POST /v1/sessions' });
  } catch (e) {
    // 作成に失敗したので予約を解除する。POST は再試行しない。
    // ただしタイムアウト・接続断は「作成されたか不明」なので予約を残す (保守側・人間が Console で確認)。
    const uncertain = e instanceof AdapterError && (e.cls === 'TIMEOUT' || e.cls === 'NETWORK');
    if (!uncertain) budget.release(ctx.ledgerPath, ctx.now(), args.taskId, `create-failed:${e.cls || 'unknown'}`);
    if (e instanceof AdapterError) e.extra.reservation = uncertain ? 'kept-session-state-unknown' : 'released';
    throw e;
  }
  budget.recordUsage(ctx.ledgerPath, ctx.now(), { taskId: args.taskId, sessionId: session.id, listCostCents: 0, final: false, status: 'created' });
  appendJsonl(ctx.decisionsPath, { ts: ctx.now().toISOString(), kind: 'session-created', task_id: args.taskId, role: args.role, session_id: session.id, budget_cents: req.cents, stage: g.stage });
  return {
    mode: ctx.mode, executed: true, task_id: args.taskId, role: args.role, session_id: session.id, status: session.status,
    budget_cents: req.cents, budget_stage: g.stage, warnings: g.warnings || [], console_url: consoleUrl(ctx, session.id),
  };
}

function usageCents(session) {
  const amount = session && session.usage && session.usage.list_cost && session.usage.list_cost.amount;
  return /^\d+$/.test(String(amount)) ? Number(amount) : 0;
}

function recordSessionUsage(ctx, taskId, session, final, status) {
  const u = (session && session.usage) || {};
  budget.recordUsage(ctx.ledgerPath, ctx.now(), {
    taskId, sessionId: session && session.id, listCostCents: usageCents(session), final, status,
    inputTokens: u.input_tokens, outputTokens: u.output_tokens, cacheReadInputTokens: u.cache_read_input_tokens,
    activeSeconds: u.active_seconds,
    model: session && session.agent && session.agent.model && (session.agent.model.id || session.agent.model),
  });
}

// 完了判定はイベントの最新 status を根拠にする (session.status だけでは待機理由が分からない)。
function latestStatusEvent(events) {
  const statuses = events
    .map((e, i) => ({ e, i }))
    .filter(({ e }) => /^session\.status_(idle|running|rescheduled|terminated)$/.test(e.type || ''));
  statuses.sort((a, b) => {
    const pa = a.e.processed_at || '';
    const pb = b.e.processed_at || '';
    if (pa !== pb) return pa < pb ? -1 : 1;
    return a.i - b.i;
  });
  return statuses.length ? statuses[statuses.length - 1].e : null;
}

function outcomeOf(statusEvent) {
  if (!statusEvent) return null;
  if (statusEvent.type === 'session.status_terminated') return 'terminated';
  if (statusEvent.type !== 'session.status_idle') return null;
  const t = statusEvent.stop_reason && statusEvent.stop_reason.type;
  if (t === 'end_turn') return 'completed';
  if (t === 'budget_reached') return 'budget_reached';
  if (t === 'retries_exhausted') return 'failed';
  if (t === 'requires_action') return 'requires_action';
  return `idle:${t || 'unknown'}`;
}

function collectText(events) {
  const parts = [];
  for (const e of events) {
    if (e.type !== 'agent.message' || !Array.isArray(e.content)) continue;
    for (const b of e.content) if (b && b.type === 'text' && typeof b.text === 'string') parts.push(b.text);
  }
  return parts.join('\n');
}

async function sendInterrupt(ctx, sessionId) {
  return apiRequest(ctx, 'POST', `/v1/sessions/${sessionId}/events`, { events: [{ type: 'user.interrupt' }] }, { operation: 'interrupt' });
}

async function sessionWait(ctx, args) {
  requireLive(ctx);
  if (!args.sessionId) throw new AdapterError('CONFIG', 'SESSION_ID_REQUIRED', '--session-id は必須');
  const maxWaitMs = (Number(args.maxWaitSeconds) > 0 ? Number(args.maxWaitSeconds) : (ctx.config.sessionLifecycle && ctx.config.sessionLifecycle.maxWaitSeconds) || 900) * 1000;
  const pollMs = Number(args.pollMs) > 0 ? Number(args.pollMs) : 5000;
  const began = ctx.now().getTime();
  let outcome = null;
  let events = [];
  let interrupted = false;
  try {
    for (;;) {
      events = await listAll(ctx, `/v1/sessions/${args.sessionId}/events?limit=1000`, 20);
      outcome = outcomeOf(latestStatusEvent(events));
      if (outcome === 'requires_action') {
        // PoC の Agent は承認不要ツールのみ。承認要求が来たら自動承認せず止める。
        await sendInterrupt(ctx, args.sessionId).catch(() => {});
        interrupted = true;
        break;
      }
      if (outcome) break;
      if (ctx.now().getTime() - began >= maxWaitMs) {
        // 無限待機しない。上限時間で中断を送り、以後は再開しない。
        await sendInterrupt(ctx, args.sessionId).catch(() => {});
        interrupted = true;
        outcome = 'timeout';
        break;
      }
      await ctx.sleep(pollMs);
    }
  } catch (e) {
    // 監視中の API 障害: 使用量を未確定のまま残す (予約額で保守的に計上され続ける)。
    if (e instanceof AdapterError) e.extra = Object.assign({ session_id: args.sessionId, task_id: args.taskId || null, usage_recorded: 'pending-run-session-close' }, e.extra);
    throw e;
  }
  const session = await apiRequest(ctx, 'GET', `/v1/sessions/${args.sessionId}`);
  if (args.taskId) recordSessionUsage(ctx, args.taskId, session, true, outcome);
  const errors = events.filter((e) => e.type === 'session.error').map((e) => ({ type: (e.error && e.error.type) || 'unknown', message: redact((e.error && e.error.message) || '', secretsOf(ctx)).slice(0, 500) }));
  const result = {
    session_id: args.sessionId, task_id: args.taskId || null, outcome, interrupted,
    list_cost_cents: usageCents(session), usage: session.usage || null,
    session_errors: errors, text: redact(collectText(events), secretsOf(ctx)), console_url: consoleUrl(ctx, args.sessionId),
  };
  appendJsonl(ctx.decisionsPath, { ts: ctx.now().toISOString(), kind: 'session-finished', task_id: args.taskId || null, session_id: args.sessionId, outcome, list_cost_cents: result.list_cost_cents });
  if (outcome === 'budget_reached') {
    throw new AdapterError('SESSION_BUDGET', 'SESSION_BUDGET_REACHED', 'セッション予算に到達して一時停止した。自動では再開・上限引き上げをしない', { result });
  }
  if (outcome === 'timeout') throw new AdapterError('TIMEOUT', 'SESSION_WAIT_TIMEOUT', `セッションが ${Math.round(maxWaitMs / 1000)} 秒以内に完了しないため中断した`, { result });
  if (errors.some((x) => x.type === 'billing_error')) throw new AdapterError('BILLING', 'SESSION_BILLING_ERROR', 'API クレジット不足または利用上限に到達した。新規実行を停止する', { result });
  if (outcome !== 'completed') throw new AdapterError('INVALID_REQUEST', 'SESSION_NOT_COMPLETED', `セッションが完了しなかった (outcome=${outcome})`, { result });
  return result;
}

async function sessionRun(ctx, args) {
  const created = await sessionCreate(ctx, args);
  if (!created.executed) return created;
  const waited = await sessionWait(ctx, { sessionId: created.session_id, taskId: args.taskId, maxWaitSeconds: args.maxWaitSeconds, pollMs: args.pollMs });
  return Object.assign({}, created, waited);
}

async function sessionClose(ctx, args) {
  requireLive(ctx);
  if (!args.sessionId || !args.taskId) throw new AdapterError('CONFIG', 'ARGS_REQUIRED', '--session-id と --task-id は必須');
  const session = await apiRequest(ctx, 'GET', `/v1/sessions/${args.sessionId}`);
  if (session.status === 'running' || session.status === 'rescheduling') {
    throw new AdapterError('CONFLICT', 'SESSION_STILL_RUNNING', `セッションが ${session.status} のため確定できない (先に interrupt)`);
  }
  recordSessionUsage(ctx, args.taskId, session, true, `closed:${session.status}`);
  return { session_id: session.id, task_id: args.taskId, status: session.status, list_cost_cents: usageCents(session), finalized: true };
}

// --- 状態確認 ---
function budgetStatus(ctx) {
  const { entries, corrupt } = budget.readLedger(ctx.ledgerPath);
  const s = budget.summarize(entries, ctx.now(), ctx.policy);
  const lastReconcile = entries.filter((e) => e.type === 'reconcile').pop() || null;
  return {
    ledger_path: ctx.ledgerPath, corrupt_lines: corrupt, policy: ctx.policy,
    period: s.period, stage: s.stage, reason: budget.stageReason(s.stage),
    committed_month_cents: s.committedMonthCents, actual_month_cents: s.actualMonthCents,
    committed_day_cents: s.committedDayCents, open_sessions: s.openSessions, task_count: s.taskCount,
    remaining_month_cents: Math.max(0, ctx.policy.monthlyBudgetCents - s.committedMonthCents),
    last_reconcile: lastReconcile,
    source_of_truth: 'Anthropic Console (実請求・クレジット残高)。この台帳は list 価格ベースの予測・監査用',
    separate_from: 'Claude Code / Agent SDK の台帳 (lib/credits.sh) とは別集計',
  };
}

async function status(ctx, args) {
  const out = {
    mode: ctx.mode, enabled: !!(ctx.config && ctx.config.enabled === true), usable: ctx.validation.ok,
    reasons: ctx.validation.reasons, config_path: ctx.configPath, config_present: !!ctx.config,
    api_base_url: ctx.baseUrl, beta_header: ctx.betaHeader,
    api_key_present: !!ctx.apiKey, github_token_env: ctx.githubTokenEnv, github_token_present: !!ctx.githubToken,
    environment_id: ctx.config ? resolveEnvironmentId(ctx) : null,
    budget: budgetStatus(ctx),
  };
  try { out.agents = rosterSummary(ctx); } catch (e) { out.agents = []; out.roster_error = e.code || e.message; }
  if (args && args.probe) {
    // 稼働確認。トークンを消費しない一覧取得 1 回のみ (mode=live 以外では実行しない)。
    try {
      requireLive(ctx);
      await apiRequest(ctx, 'GET', '/v1/agents?limit=1');
      out.probe = { ok: true };
    } catch (e) {
      out.probe = { ok: false, class: e.cls || 'CONFIG', code: e.code || 'UNKNOWN', message: e.message };
    }
  }
  return out;
}

// --- Agent Router 統合 ---
// Router は純関数のため、可用性・予算・重複といった「証拠」をここで集めて渡す。
function route(ctx, task, args) {
  const a = args || {};
  const taskClass = String(task.task_type || '').toLowerCase() === 'check' ? 'check' : 'task';
  let cents = null;
  try {
    if (a.budgetCents != null) cents = budget.parseCentsString(a.budgetCents);
    else if (ctx.config && ctx.config.budget && ctx.config.budget.amountCents) cents = budget.parseCentsString(ctx.config.budget.amountCents);
  } catch { cents = null; }
  const { entries, corrupt } = budget.readLedger(ctx.ledgerPath);
  const g = corrupt > 0 ? { allow: false, code: 'LEDGER_CORRUPT', stage: 'unknown' } : budget.guard(entries, ctx.now(), ctx.policy, { cents, taskClass, ackDailySoft: !!a.ackDailySoft });
  const dup = a.taskId ? budget.foldTasks(entries).get(a.taskId) : null;
  const keyOk = ctx.mode === 'live' ? !!ctx.apiKey : true;
  // ガードが許可した場合は段階 (ok/warn/verify-only)、拒否した場合はその理由コードを予算状態として渡す。
  const budgetState = g.allow ? g.stage : String(g.code || 'denied').toLowerCase();
  const managed = Object.assign({}, task.managed || {}, {
    available: ctx.validation.ok && keyOk,
    budget_state: budgetState,
    duplicate: !!(dup && !dup.released),
  });
  if (task.managed && task.managed.available === false) managed.available = false;
  const decision = agentRouter.route(Object.assign({}, task, { managed }));
  decision.managed.evidence = {
    mode: ctx.mode, usable: ctx.validation.ok, reasons: ctx.validation.reasons, api_key_present: !!ctx.apiKey,
    budget_code: g.code, budget_stage: g.stage || null, request_cents: cents,
  };
  appendJsonl(ctx.decisionsPath, {
    ts: ctx.now().toISOString(), kind: 'route', task_id: a.taskId || null, task_type: decision.inputs.task_type,
    execution: decision.execution, managed_selected: decision.managed.selected, denied: decision.managed.denied,
    fallback_execution: decision.managed.fallback_execution, policy_denied: decision.managed.policy_denied,
  });
  return decision;
}

// --- CLI ---
function parseArgs(argv) {
  const pos = [];
  const opts = {};
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (a.startsWith('--')) {
      const key = a.slice(2);
      const next = argv[i + 1];
      if (next === undefined || next.startsWith('--')) opts[key] = true; else { opts[key] = next; i += 1; }
    } else pos.push(a);
  }
  return { pos, opts };
}

function sessionArgs(o) {
  let prompt = typeof o.prompt === 'string' ? o.prompt : '';
  if (!prompt && typeof o['prompt-file'] === 'string') prompt = fs.readFileSync(o['prompt-file'], 'utf8');
  return {
    taskId: typeof o['task-id'] === 'string' ? o['task-id'] : '', role: typeof o.role === 'string' ? o.role : '', prompt,
    budgetCents: typeof o['budget-cents'] === 'string' ? o['budget-cents'] : null,
    taskClass: o.class === 'check' ? 'check' : 'task',
    repo: typeof o.repo === 'string' ? o.repo : '', ref: typeof o.ref === 'string' ? o.ref : '',
    ackDailySoft: o['ack-daily-soft'] === true,
    sessionId: typeof o['session-id'] === 'string' ? o['session-id'] : '',
    maxWaitSeconds: o['max-wait-seconds'], pollMs: o['poll-ms'],
  };
}

async function dispatch(ctx, pos, o) {
  const [cmd, sub] = pos;
  if (cmd === 'status') return status(ctx, { probe: o.probe === true });
  if (cmd === 'agents') {
    if (sub === 'list' || !sub) return agentsList(ctx);
    if (sub === 'plan') return agentsSync(Object.assign({}, ctx, { mode: ctx.mode === 'live' ? 'dry-run' : ctx.mode }), typeof o.role === 'string' ? o.role : null);
    if (sub === 'sync') return agentsSync(ctx, typeof o.role === 'string' ? o.role : null);
  }
  if (cmd === 'env') {
    if (sub === 'plan') return envEnsure(Object.assign({}, ctx, { mode: ctx.mode === 'live' ? 'dry-run' : ctx.mode }));
    if (sub === 'ensure') return envEnsure(ctx);
  }
  if (cmd === 'session') {
    const a = sessionArgs(o);
    if (sub === 'create') return sessionCreate(ctx, a);
    if (sub === 'run') return sessionRun(ctx, a);
    if (sub === 'wait') return sessionWait(ctx, a);
    if (sub === 'close') return sessionClose(ctx, a);
    if (sub === 'get') { requireLive(ctx); return apiRequest(ctx, 'GET', `/v1/sessions/${a.sessionId}`); }
    if (sub === 'events') { requireLive(ctx); return { data: await listAll(ctx, `/v1/sessions/${a.sessionId}/events?limit=1000`, 20) }; }
    if (sub === 'interrupt') { requireLive(ctx); await sendInterrupt(ctx, a.sessionId); return { session_id: a.sessionId, interrupted: true }; }
  }
  if (cmd === 'budget') {
    if (sub === 'status' || !sub) return budgetStatus(ctx);
    if (sub === 'reconcile') {
      if (typeof o['console-usd'] !== 'string') throw new AdapterError('CONFIG', 'ARGS_REQUIRED', '--console-usd <Console の当期利用額> は必須');
      return budget.reconcile(ctx.ledgerPath, ctx.now(), ctx.policy, budget.usdToCents(o['console-usd']), typeof o.note === 'string' ? o.note : null);
    }
  }
  if (cmd === 'route') {
    let task;
    try { task = JSON.parse(typeof o.json === 'string' ? o.json : fs.readFileSync(0, 'utf8')); } catch (e) {
      throw new AdapterError('CONFIG', 'TASK_JSON_INVALID', `task JSON を解釈できない (${e.message})`);
    }
    return route(ctx, task, { taskId: typeof o['task-id'] === 'string' ? o['task-id'] : null, budgetCents: typeof o['budget-cents'] === 'string' ? o['budget-cents'] : null, ackDailySoft: o['ack-daily-soft'] === true });
  }
  throw new AdapterError('CONFIG', 'USAGE', 'usage: managed-agents.js status|agents|env|session|budget|route (詳細はファイル冒頭)');
}

function errorPayload(e, ctx) {
  const cls = e instanceof AdapterError ? e.cls : (e instanceof budget.BudgetError ? 'BUDGET' : 'CONFIG');
  const meta = ERROR_CLASSES[cls];
  return {
    exit: meta.exit,
    body: {
      ok: false, class: cls, code: e.code || 'UNEXPECTED', state: meta.state,
      message: redact(e.message, ctx ? secretsOf(ctx) : []),
      fallback: fallbackDecision(cls),
      details: e.extra || {},
    },
  };
}

async function main() {
  const { pos, opts } = parseArgs(process.argv.slice(2));
  let ctx = null;
  try {
    ctx = createContext({ configPath: typeof opts.config === 'string' ? opts.config : undefined });
    const out = await dispatch(ctx, pos, opts);
    process.stdout.write(redact(JSON.stringify(out, null, 2), secretsOf(ctx)) + '\n');
  } catch (e) {
    const p = errorPayload(e, ctx);
    process.stderr.write(redact(JSON.stringify(p.body), ctx ? secretsOf(ctx) : []) + '\n');
    process.exitCode = p.exit;
  }
}

module.exports = {
  ERROR_CLASSES, AdapterError, classifyHttp, fallbackDecision, redact, findSecretKeys, validateConfig,
  isAllowedBaseUrl, assertReadOnlyAgent, agentDefinition, loadRoster, createContext, apiRequest,
  agentsSync, agentsList, envEnsure, sessionCreate, sessionWait, sessionRun, sessionClose,
  budgetStatus, status, route, latestStatusEvent, outcomeOf, errorPayload, dispatch, parseArgs,
};

if (require.main === module) main();
