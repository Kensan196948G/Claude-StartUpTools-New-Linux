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
//   managed-agents.js session create --task-id T --role R --task-type review (--prompt P | --prompt-file F)
//                                    [--budget-cents N] [--repo https://github.com/o/r] [--ref main] [--ack-daily-soft]
//                                    (--task-type check は確認処理: 上限 $0.50)
//   managed-agents.js session run    (create と同じ引数) [--max-wait-seconds N]
//   managed-agents.js session wait --task-id T --session-id S [--max-wait-seconds N]
//   managed-agents.js session get|events|interrupt --session-id S
//   managed-agents.js session close --task-id T [--session-id S] [--confirm-not-created]
//   managed-agents.js budget status | budget reconcile --console-usd 1.23 [--note text]
//   managed-agents.js ask --role R (--prompt P | --prompt-file F) [--task-type T] [--source human|agent]
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

const SECRET_KEY_RE = /(api[_-]?key|secret|password|passwd|token|authorization|credential|\bpat\b)/i;
const SECRET_VALUE_RE = /(sk-ant-[A-Za-z0-9_-]{8,}|\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{16,}|\bgithub_pat_[A-Za-z0-9_]{16,})/;
// 設定内の秘密らしき値を、キー名と値のパターンの両方で探す (コメント用の _ キーや配列の中も見る)。
function findSecretKeys(obj, trail) {
  const hits = [];
  if (!obj || typeof obj !== 'object') return hits;
  for (const [k, v] of Object.entries(obj)) {
    const here = trail ? `${trail}.${k}` : k;
    if (v && typeof v === 'object') { hits.push(...findSecretKeys(v, here)); continue; }
    if (typeof v !== 'string' || v.trim() === '') continue;
    if (SECRET_VALUE_RE.test(v)) { hits.push(here); continue; }
    // 説明用キー (_comment 等)、「環境変数名」を持つキー (tokenEnv 等)、ID 参照はキー名では判定しない
    if (k.startsWith('_') || /Env$/.test(k) || /Ids?$/.test(k) || Array.isArray(obj)) continue;
    if (SECRET_KEY_RE.test(k)) hits.push(here);
  }
  return hits;
}

// Anthropic 側リソース ID の形式検証 (URL パスへ埋め込む前に必ず通す)。
const ID_PATTERNS = { session: /^sesn_[A-Za-z0-9]+$/, agent: /^agent_[A-Za-z0-9]+$/, environment: /^env_[A-Za-z0-9]+$/ };
function assertId(kind, id) {
  if (typeof id !== 'string' || !ID_PATTERNS[kind].test(id)) {
    throw new AdapterError('CONFIG', 'ID_INVALID', `${kind} ID の形式が不正`);
  }
  return id;
}
const TOKEN_ENV_RE = /^CLAUDEOS_MA_[A-Z0-9_]+$/;

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
//   許可リスト方式: 「許可する形」だけを列挙し、それ以外 (非配列、真偽値でない enabled、未知のフィールド値) は拒否する。
//   ローカルの roster 定義と、API から取得したリモートの実体の両方に使う。
function assertReadOnlyAgent(def) {
  const violations = [];
  const emptyOrAbsent = (v) => v === undefined || v === null || (Array.isArray(v) && v.length === 0);
  if (!def || typeof def !== 'object') throw new AdapterError('POLICY', 'READ_ONLY_VIOLATION', '読取専用ポリシー違反: agent 定義がオブジェクトではない', { violations: ['not-an-object'] });
  // 委任・拡張に関わるフィールドは「未定義 / null / 空配列」だけを許可する
  for (const k of ['mcp_servers', 'skills', 'callable_agents']) {
    if (!emptyOrAbsent(def[k])) violations.push(`${k} は PoC では宣言不可`);
  }
  if (def.multiagent !== undefined && def.multiagent !== null) violations.push('multiagent は PoC では不可');
  const tools = Array.isArray(def.tools) ? def.tools : null;
  if (!tools || tools.length !== 1 || !tools[0] || tools[0].type !== 'agent_toolset_20260401') {
    violations.push('tools は agent_toolset_20260401 の 1 件のみ');
  } else {
    const t = tools[0];
    if (!t.default_config || t.default_config.enabled !== false) violations.push('default_config.enabled は false (opt-in 方式)');
    const policy = t.default_config && t.default_config.permission_policy;
    if (policy !== undefined && policy !== null && !(typeof policy === 'object' && ['always_allow', 'always_ask', 'auto'].includes(policy.type))) violations.push('permission_policy の形が不明');
    if (t.configs !== undefined && t.configs !== null && !Array.isArray(t.configs)) violations.push('configs が配列ではない');
    for (const c of Array.isArray(t.configs) ? t.configs : []) {
      const name = c && typeof c.name === 'string' ? c.name : '(不明)';
      // enabled は真偽値のみ。読取専用以外のツールは、明示的に false の場合だけ許可する。
      if (!c || typeof c.enabled !== 'boolean') violations.push(`ツール ${name} の enabled が真偽値ではない`);
      else if (c.enabled && !READ_ONLY_TOOLS.includes(c.name)) violations.push(`書込み/実行/外部通信ツール ${name} は有効化不可`);
      const cp = c && c.permission_policy;
      if (cp !== undefined && cp !== null && !(typeof cp === 'object' && ['always_allow', 'always_ask', 'auto'].includes(cp.type))) violations.push(`ツール ${name} の permission_policy の形が不明`);
    }
  }
  if (violations.length) throw new AdapterError('POLICY', 'READ_ONLY_VIOLATION', `読取専用ポリシー違反: ${violations.join(' / ')}`, { violations });
  return true;
}

function agentDefinition(roster, role) {
  const a = Object.prototype.hasOwnProperty.call(roster.agents, role) ? roster.agents[role] : null;
  if (!a || typeof a !== 'object') throw new AdapterError('CONFIG', 'ROLE_UNKNOWN', `roster に role=${role} が無い (候補: ${Object.keys(roster.agents).join(', ')})`);
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
function validateConfig(config, env) {
  const reasons = [];
  if (!config) return { ok: false, mode: 'missing', reasons: ['config-missing'] };
  if (typeof config !== 'object' || Array.isArray(config)) return { ok: false, mode: 'invalid', reasons: ['config-not-object'] };
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
  if (!isAllowedBaseUrl(base, env)) reasons.push('api-base-url-not-allowed');
  // 初期 PoC は MCP を使わないため、MCP 認証用の vault は付けられない。
  if (Array.isArray(config.vaultIds) && config.vaultIds.length) reasons.push('vault-ids-not-allowed-in-poc');
  const tokenEnv = config.github && config.github.workspace && config.github.workspace.tokenEnv;
  if (tokenEnv !== undefined && !(typeof tokenEnv === 'string' && TOKEN_ENV_RE.test(tokenEnv))) reasons.push('github-token-env-invalid');
  try {
    const roster = loadRoster(config);
    for (const role of Object.keys(roster.agents)) agentDefinition(roster, role);
  } catch (e) { reasons.push(`roster-invalid:${e.code || e.message}`); }
  return { ok: reasons.length === 0, mode, reasons, policy };
}

// API キーを任意ホストへ送らないため、送信先は https://api.anthropic.com に固定する。
// loopback はテスト用の環境変数 CLAUDEOS_MA_ALLOW_LOOPBACK=1 を明示した場合だけ許可する
// (設定ファイルの書き換えだけでは、ローカルの別プロセスへ平文 HTTP でキーを送らせられない)。
function isAllowedBaseUrl(base, env) {
  try {
    const u = new URL(base);
    if (u.username || u.password) return false;
    if (u.protocol === 'https:' && u.hostname === 'api.anthropic.com' && (u.port === '' || u.port === '443')) return true;
    if (!env || env.CLAUDEOS_MA_ALLOW_LOOPBACK !== '1') return false;
    return u.hostname === '127.0.0.1' && (u.protocol === 'http:' || u.protocol === 'https:');
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
  const validation = validateConfig(config, env);
  const stateDir = resolveStateDir(config, env);
  const cfgTokenEnv = config && config.github && config.github.workspace && config.github.workspace.tokenEnv;
  const githubTokenEnv = typeof cfgTokenEnv === 'string' && TOKEN_ENV_RE.test(cfgTokenEnv) ? cfgTokenEnv : 'CLAUDEOS_MA_GITHUB_TOKEN';
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
    requestTimeoutMs: o.requestTimeoutMs || clampNumber(config && config.requestTimeoutMs, 30000, 1000, 120000),
    // ポーリング間隔の下限 (API を連打しない)。テストだけが小さい値を注入できる。
    minPollMs: o.minPollMs || 1000,
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
    let bodyText = '';
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
        // リダイレクトを追わない (別オリジンへ x-api-key が転送されるのを防ぐ)
        redirect: 'error',
        signal: controller.signal,
      });
      // 本文の読み取りまでをタイムアウトの対象にする (ヘッダ受信後に本文が届かない場合も打ち切る)。
      bodyText = await res.text();
    } catch (e) {
      cls = e && e.name === 'AbortError' ? 'TIMEOUT' : 'NETWORK';
      errInfo = { message: cls === 'TIMEOUT' ? `API が ${ctx.requestTimeoutMs}ms 以内に応答しない` : `API との通信に失敗した (${redact(e && e.message, secretsOf(ctx))})` };
      res = null;
    } finally { clearTimeout(timer); }

    if (res) {
      let parsed = null;
      if (bodyText) { try { parsed = JSON.parse(bodyText); } catch { parsed = null; } }
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
    if (!res || typeof res !== 'object' || (res.data !== undefined && !Array.isArray(res.data))) {
      throw new AdapterError('INVALID_REQUEST', 'LIST_RESPONSE_INVALID', '一覧応答の形が想定と異なる (data が配列ではない)');
    }
    // オブジェクト以外の要素は捨てる (後段が null のプロパティを読んで落ちないようにする)
    for (const item of res.data || []) if (item && typeof item === 'object') out.push(item);
    page = typeof res.next_page === 'string' && res.next_page ? res.next_page : null;
    if (!page) break;
  }
  // ページ上限で打ち切った場合は印を付ける。呼び出し側は「見つからなかった」と断定してはならない。
  out.truncated = !!page;
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

// リモートの Agent 実体が読取専用かどうか (metadata ではなく tools / mcp_servers の実体で判定)。
function isRemoteReadOnly(agent) {
  try { return assertReadOnlyAgent(agent); } catch { return false; }
}

// セッション作成の直前に、使う Agent と Environment の実体を API から取得して検証する。
//   - Agent: 固定する version が最新版と一致し、tools が read / glob / grep のみ・MCP なし
//   - Environment: limited networking で、MCP・パッケージマネージャを許可していない
// registry や config の ID を信用せず、ここで構造を確認できなければセッションを作らない。
async function verifyRemoteResources(ctx, agentRef, environmentId, expected) {
  assertId('agent', agentRef.id);
  assertId('environment', environmentId);
  const agent = await apiRequest(ctx, 'GET', `/v1/agents/${agentRef.id}`);
  if (!agent || typeof agent !== 'object' || agent.archived_at) throw new AdapterError('POLICY', 'AGENT_ARCHIVED', 'agent が archive 済み、または取得できない');
  if (!Number.isInteger(agent.version) || agent.version < 1) throw new AdapterError('POLICY', 'AGENT_VERSION_UNKNOWN', 'agent の version を確認できない');
  if (agentRef.version != null && agent.version !== agentRef.version) {
    throw new AdapterError('POLICY', 'AGENT_VERSION_DRIFT', `agent の最新 version (${agent.version}) が固定 version (${agentRef.version}) と異なる。agents sync で再同期する`);
  }
  assertReadOnlyAgent(agent);
  // 指示文 (system) とモデルも roster の定義と一致することを確認する (Console 等での書き換えを検出)。
  if (expected) {
    const modelId = (m) => (m && typeof m === 'object' ? m.id : m);
    if (agent.system !== expected.system) throw new AdapterError('POLICY', 'AGENT_DEFINITION_DRIFT', 'agent の system が roster の定義と異なる。agents sync で再同期する');
    if (modelId(agent.model) !== modelId(expected.model)) throw new AdapterError('POLICY', 'AGENT_DEFINITION_DRIFT', 'agent の model が roster の定義と異なる。agents sync で再同期する');
  }
  const environment = await apiRequest(ctx, 'GET', `/v1/environments/${environmentId}`);
  assertLimitedEnvironment(environment);
  return { agentVersion: agent.version };
}

function assertLimitedEnvironment(environment) {
  const net = environment && environment.config && environment.config.networking;
  const violations = [];
  // 許可リスト方式: allow_* は「未定義 / null / false」だけ、allowed_hosts は「未定義 / null / 空配列」だけを許可する。
  const off = (v) => v === undefined || v === null || v === false;
  const noHosts = (v) => v === undefined || v === null || (Array.isArray(v) && v.length === 0);
  if (!environment || typeof environment !== 'object' || environment.archived_at) violations.push('environment が archive 済み、または取得できない');
  if (!net || typeof net !== 'object' || net.type !== 'limited') violations.push('networking.type が limited ではない');
  if (net && !off(net.allow_mcp_servers)) violations.push('allow_mcp_servers が無効と確認できない');
  if (net && !off(net.allow_package_managers)) violations.push('allow_package_managers が無効と確認できない');
  if (net && !noHosts(net.allowed_hosts)) violations.push('allowed_hosts が空と確認できない');
  if (violations.length) throw new AdapterError('POLICY', 'ENVIRONMENT_NOT_LIMITED', `Environment が PoC の条件を満たさない: ${violations.join(' / ')}`, { violations });
  return true;
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
    } else if (found.metadata.claudeos_def_sha !== p.definition.sha || !isRemoteReadOnly(found)) {
      // metadata が一致していても、リモートの実体 (Console 等で変更され得る) が読取専用でなければ定義で上書きする。
      assertId('agent', found.id);
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
  if (known) { environment = await apiRequest(ctx, 'GET', `/v1/environments/${assertId('environment', known)}`); action = 'existing'; }
  else {
    const all = await listAll(ctx, '/v1/environments?limit=100');
    environment = all.find((e) => e.name === def.name && !e.archived_at);
    action = environment ? 'found' : 'created';
    if (!environment) environment = await apiRequest(ctx, 'POST', '/v1/environments', body);
  }
  // 既存の Environment を採用する場合も、limited networking であることを実体で確認する。
  assertLimitedEnvironment(environment);
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

// 依頼文はクラウドへ送信される。秘密らしき値を含むもの・長すぎるものは送信前に拒否する
// (ローカルで見た鍵や接続文字列を、依頼文に書いて外へ出してしまうのを防ぐ)。
const MAX_PROMPT_CHARS = 8000;
const PROMPT_SECRET_RE = /(sk-ant-[A-Za-z0-9_-]{8,}|\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{16,}|\bgithub_pat_[A-Za-z0-9_]{16,}|\bAKIA[0-9A-Z]{16}\b|-----BEGIN [A-Z ]*PRIVATE KEY-----|\b(?:postgres(?:ql)?|mysql|mongodb(?:\+srv)?|redis|amqp):\/\/[^\s:@/]+:[^\s@/]+@)/;
function assertPromptSafe(prompt) {
  const text = String(prompt);
  if (text.length > MAX_PROMPT_CHARS) throw new AdapterError('POLICY', 'PROMPT_TOO_LONG', `依頼文が長すぎる (${text.length} 文字、上限 ${MAX_PROMPT_CHARS})`);
  if (PROMPT_SECRET_RE.test(text)) throw new AdapterError('POLICY', 'PROMPT_CONTAINS_SECRET', '依頼文に秘密らしき値 (API キー・トークン・秘密鍵・認証情報つき接続文字列) が含まれるため送信しない');
  return true;
}

function resolveSessionRequest(ctx, args) {
  if (!args.taskId) throw new AdapterError('CONFIG', 'TASK_ID_REQUIRED', '--task-id は必須 (重複実行防止のキー)');
  if (!args.role) throw new AdapterError('CONFIG', 'ROLE_REQUIRED', '--role は必須');
  if (!args.prompt || !String(args.prompt).trim()) throw new AdapterError('CONFIG', 'PROMPT_REQUIRED', '--prompt または --prompt-file は必須');
  assertPromptSafe(args.prompt);
  const roster = loadRoster(ctx.config);
  const def = agentDefinition(roster, args.role);
  // タスク種別は必須。Router の許可リストと、その Agent が担当する種別の両方に含まれる場合だけ受け付ける
  // (Router を通さずに session create を直接呼んでも、対象外の種別は作れない)。
  const taskType = String(args.taskType || (args.taskClass === 'check' ? 'check' : '')).trim().toLowerCase();
  if (!taskType) throw new AdapterError('POLICY', 'TASK_TYPE_REQUIRED', '--task-type は必須');
  if (!agentRouter.MANAGED_TASK_TYPES.includes(taskType) || !def.taskTypes.includes(taskType)) {
    throw new AdapterError('POLICY', 'TASK_TYPE_NOT_ALLOWED', `task_type=${taskType} は role=${args.role} の対象外 (許可: ${def.taskTypes.filter((t) => agentRouter.MANAGED_TASK_TYPES.includes(t)).join(', ')})`);
  }
  const taskClass = taskType === 'check' ? 'check' : 'task';

  // 予算: 明示指定 > config.budget。どちらも無ければ拒否 (予算未指定セッション禁止)。
  let cents = null;
  if (args.budgetCents != null) cents = budget.parseCentsString(args.budgetCents);
  else if (ctx.config.budget && ctx.config.budget.amountCents != null && ctx.config.budget.amountCents !== '') {
    cents = budget.parseCentsString(ctx.config.budget.amountCents);
    // 確認処理は既定額を接続テスト上限へ丸める (明示指定した場合は丸めず、上限超過として拒否する)。
    if (taskClass === 'check') cents = Math.min(cents, ctx.policy.connectionTestMaxCents);
  }
  if (cents == null) throw new AdapterError('BUDGET', 'BUDGET_REQUIRED', 'セッション予算が未指定 (--budget-cents か config.budget.amountCents が必須)');
  if ((ctx.config.budget && ctx.config.budget.currency && ctx.config.budget.currency !== 'USD')) throw new AdapterError('BUDGET', 'BUDGET_CURRENCY_INVALID', 'budget.currency は USD のみ');
  return { roster, def, taskClass, cents };
}

function buildSessionPayload(ctx, args, req, agentRef, environmentId, withSecrets) {
  const { resources } = buildResources(ctx, args);
  if (resources.length) {
    if (withSecrets) {
      if (!ctx.githubToken) throw new AdapterError('KEY_MISSING', 'GITHUB_TOKEN_MISSING', `環境変数 ${ctx.githubTokenEnv} が未設定 (読取専用の fine-grained PAT: Contents=Read のみ)`);
      // API キーを GitHub トークンとして送らない (環境変数の取り違え・設定の誘導を防ぐ)
      if (ctx.githubToken === ctx.apiKey || /^sk-ant-/.test(ctx.githubToken)) throw new AdapterError('POLICY', 'GITHUB_TOKEN_IS_API_KEY', `環境変数 ${ctx.githubTokenEnv} の値が Anthropic の API キーに見える (送信しない)`);
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
  // 使う Agent / Environment の実体を検証し、検証した version に固定する (課金の発生しない GET 2 回)。
  const verified = await verifyRemoteResources(ctx, agentRef, environmentId, req.def.body);
  agentRef.version = verified.agentVersion;
  const payload = buildSessionPayload(ctx, args, req, agentRef, environmentId, true);
  if ('vault_ids' in payload) throw new AdapterError('POLICY', 'VAULT_NOT_ALLOWED', 'PoC では vault_ids を送信しない');
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
    // POST は再試行しない。サーバーが明確に拒否した場合 (4xx) だけ予約を解除する。
    // タイムアウト・接続断・5xx / 529 は「作成されたか不明」なので予約を残す。解除すると同じ task_id で
    // 二重に作成でき、Local へのフォールバックと合わせて二重実行になる。
    // 成否は `session close --task-id <id>` (セッション一覧から突き合わせ) で確定する。
    //   「明確な拒否」は HTTP ステータスが 4xx の場合だけ。本文の error.type が rate_limit_error 等でも、
    //   ステータスが 5xx ならゲートウェイ由来で作成済みかもしれないので、成否不明として扱う。
    const status = e instanceof AdapterError ? Number(e.extra.status) : NaN;
    const definite = e instanceof AdapterError && status >= 400 && status < 500
      && ['AUTH', 'PERMISSION', 'BILLING', 'RATE_LIMIT', 'INVALID_REQUEST', 'NOT_FOUND', 'CONFLICT'].includes(e.cls);
    if (definite) {
      budget.release(ctx.ledgerPath, ctx.now(), args.taskId, `create-rejected:${e.cls}`);
      e.extra.reservation = 'released';
      throw e;
    }
    // 成否不明: 予約を残し、Local へ自動で戻さない (同じタスクの二重実行を防ぐ)。想定外の例外も同じ扱い。
    const err = e instanceof AdapterError ? e : new AdapterError('NETWORK', 'CREATE_OUTCOME_UNKNOWN', `セッション作成の結果を確認できない (${redact(e && e.message, secretsOf(ctx))})`);
    err.extra.reservation = 'kept-session-state-unknown';
    err.noFallback = true;
    throw err;
  }
  if (!session || typeof session.id !== 'string' || !ID_PATTERNS.session.test(session.id)) {
    const err = new AdapterError('CONFLICT', 'SESSION_ID_MISSING', 'セッション作成の応答に有効な ID が無い (予約は残す。Console で確認する)', { reservation: 'kept-session-state-unknown' });
    err.noFallback = true;
    throw err;
  }
  try {
    budget.recordUsage(ctx.ledgerPath, ctx.now(), { taskId: args.taskId, sessionId: session.id, listCostCents: 0, final: false, status: 'created' });
    appendJsonl(ctx.decisionsPath, { ts: ctx.now().toISOString(), kind: 'session-created', task_id: args.taskId, role: args.role, session_id: session.id, budget_cents: req.cents, stage: g.stage });
  } catch (e) {
    // セッションは作成済み。記録に失敗しても session_id を必ず返し、Local へは戻さない (二重実行防止)。
    const err = new AdapterError('CONFLICT', 'LEDGER_RECORD_FAILED', `セッションは作成済みだが台帳への記録に失敗した (${e.message})`, { session_id: session.id, task_id: args.taskId, reservation: 'kept' });
    err.noFallback = true;
    throw err;
  }
  return {
    mode: ctx.mode, executed: true, task_id: args.taskId, role: args.role, session_id: session.id, status: session.status,
    budget_cents: req.cents, budget_stage: g.stage, warnings: g.warnings || [], console_url: consoleUrl(ctx, session.id),
  };
}

// 累積 list_cost (セント整数の文字列)。欠落・小数・指数表記など解釈できない場合は null。
function usageCents(session) {
  const amount = session && session.usage && session.usage.list_cost && session.usage.list_cost.amount;
  return typeof amount === 'string' && /^\d+$/.test(amount) && Number.isSafeInteger(Number(amount)) ? Number(amount) : null;
}

// task_id とセッションの対応を確認する。別のセッションの使用量でタスクを確定させない
// (安価な別セッションを指定して予約と並列枠を解放する迂回を防ぐ)。
function assertTaskSessionBinding(ctx, taskId, session) {
  const meta = (session && session.metadata) || {};
  if (meta.claudeos_task_id !== taskId) {
    throw new AdapterError('POLICY', 'TASK_SESSION_MISMATCH', 'セッションの metadata.claudeos_task_id が task_id と一致しない (台帳へ記録しない)');
  }
  const task = budget.foldTasks(budget.readLedger(ctx.ledgerPath).entries).get(taskId);
  if (!task) throw new AdapterError('POLICY', 'TASK_UNKNOWN', `task_id=${taskId} の予約が台帳に無い`);
  if (task.session_id && task.session_id !== session.id) {
    throw new AdapterError('POLICY', 'TASK_SESSION_MISMATCH', 'task_id に記録済みのセッションと異なるセッションが指定された (台帳へ記録しない)');
  }
  return task;
}

// 使用量を台帳へ記録する。確定 (final) にできるのは、セッションが停止しており、かつ使用量を解釈できた場合だけ。
// それ以外は未確定のまま残し、予約額で保守的に計上し続ける。
function recordSessionUsage(ctx, taskId, session, status) {
  assertTaskSessionBinding(ctx, taskId, session);
  const u = (session && session.usage) || {};
  const cents = usageCents(session);
  const stopped = session.status === 'idle' || session.status === 'terminated';
  const final = stopped && cents !== null;
  budget.recordUsage(ctx.ledgerPath, ctx.now(), {
    taskId, sessionId: session && session.id, listCostCents: cents === null ? 0 : cents, final,
    status: final ? status : `${status}:unconfirmed`,
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
  // 時刻は数値で比較する (小数秒の桁数が混在すると文字列比較では順序が逆転する)。
  const at = (e) => { const t = Date.parse(e.processed_at); return Number.isNaN(t) ? -Infinity : t; };
  statuses.sort((a, b) => (at(a.e) - at(b.e)) || (a.i - b.i));
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

const MAX_WAIT_SECONDS = 3600;
// 数値引数を範囲内に収める。解釈できない値は既定値。
//   value も def も数値として解釈できない場合は min を使う (NaN を返さない: NaN の待機上限は無限待機になる)。
function clampNumber(value, def, min, max) {
  const pick = (v) => { const n = typeof v === 'number' || typeof v === 'string' ? Number(v) : NaN; return Number.isFinite(n) && n > 0 ? n : null; };
  const n = pick(value);
  const d = pick(def);
  return Math.min(max, Math.max(min, n !== null ? n : (d !== null ? d : min)));
}

async function sendInterrupt(ctx, sessionId) {
  assertId('session', sessionId);
  return apiRequest(ctx, 'POST', `/v1/sessions/${sessionId}/events`, { events: [{ type: 'user.interrupt' }] }, { operation: 'interrupt' });
}

async function sessionWaitInner(ctx, args) {
  requireLive(ctx);
  // task_id が無いと使用量を記録できず、予約が未確定のまま残る。
  if (!args.taskId) throw new AdapterError('CONFIG', 'TASK_ID_REQUIRED', '--task-id は必須 (使用量の記録先)');
  assertId('session', args.sessionId);
  const known = budget.foldTasks(budget.readLedger(ctx.ledgerPath).entries).get(args.taskId);
  if (!known || known.released) throw new AdapterError('POLICY', 'TASK_UNKNOWN', `task_id=${args.taskId} の有効な予約が台帳に無い`);
  if (known.session_id && known.session_id !== args.sessionId) throw new AdapterError('POLICY', 'TASK_SESSION_MISMATCH', 'task_id に記録済みのセッションと異なるセッションが指定された');
  // 監視や中断を始める前に、指定されたセッションが本当にこのタスクのものかを確認する
  // (無関係なセッションへ user.interrupt を送らない)。
  assertTaskSessionBinding(ctx, args.taskId, await apiRequest(ctx, 'GET', `/v1/sessions/${args.sessionId}`));
  const cfgWait = ctx.config.sessionLifecycle && ctx.config.sessionLifecycle.maxWaitSeconds;
  const maxWaitMs = clampNumber(args.maxWaitSeconds, clampNumber(cfgWait, 900, 10, MAX_WAIT_SECONDS), 10, MAX_WAIT_SECONDS) * 1000;
  const pollMs = clampNumber(args.pollMs, 5000, ctx.minPollMs, 60000);
  const began = ctx.now().getTime();
  let outcome = null;
  let events = [];
  let interruptSent = false;
  let interruptError = null;
  const tryInterrupt = async () => {
    try { await sendInterrupt(ctx, args.sessionId); interruptSent = true; } catch (e) { interruptError = (e && e.cls) || 'UNKNOWN'; }
  };
  try {
    for (;;) {
      events = await listAll(ctx, `/v1/sessions/${args.sessionId}/events?limit=1000`, 20);
      outcome = outcomeOf(latestStatusEvent(events));
      if (outcome === 'requires_action') {
        // PoC の Agent は承認不要ツールのみ。承認要求が来たら自動承認せず中断を試みる。
        await tryInterrupt();
        break;
      }
      if (outcome) break;
      if (ctx.now().getTime() - began >= maxWaitMs) {
        // 無限待機しない。上限時間で中断を試み、以後は再開しない。
        await tryInterrupt();
        outcome = 'timeout';
        break;
      }
      await ctx.sleep(pollMs);
    }
  } catch (e) {
    // 監視中の API 障害: 使用量を未確定のまま残す (予約額で保守的に計上され続ける)。
    // セッションはクラウド側で動いている可能性があるため、Local へ自動で戻さない。
    if (e instanceof AdapterError) {
      e.extra = Object.assign({ session_id: args.sessionId, task_id: args.taskId || null, usage_recorded: 'pending-run-session-close' }, e.extra);
      e.noFallback = true;
    }
    throw e;
  }
  const session = await apiRequest(ctx, 'GET', `/v1/sessions/${args.sessionId}`);
  // 停止を確認できた場合だけ確定する。中断が失敗してまだ動いているなら未確定のまま (並列枠も解放しない)。
  const stopped = session.status === 'idle' || session.status === 'terminated';
  if (args.taskId) recordSessionUsage(ctx, args.taskId, session, outcome);
  const errors = events.filter((e) => e.type === 'session.error').map((e) => ({ type: (e.error && e.error.type) || 'unknown', message: redact((e.error && e.error.message) || '', secretsOf(ctx)).slice(0, 500) }));
  const cents = usageCents(session);
  const result = {
    session_id: args.sessionId, task_id: args.taskId || null, outcome,
    session_status: session.status, stopped, interrupt_sent: interruptSent, interrupt_error: interruptError,
    usage_finalized: !!args.taskId && stopped && cents !== null,
    list_cost_cents: cents, usage: session.usage || null,
    session_errors: errors,
    // Agent の出力は信頼できないデータ。呼び出し側は指示として扱わない。
    text_is_untrusted_agent_output: true,
    text: redact(collectText(events), secretsOf(ctx)), console_url: consoleUrl(ctx, args.sessionId),
  };
  appendJsonl(ctx.decisionsPath, { ts: ctx.now().toISOString(), kind: 'session-finished', task_id: args.taskId || null, session_id: args.sessionId, outcome, session_status: session.status, list_cost_cents: cents });
  if (!stopped) {
    const err = new AdapterError('CONFLICT', 'SESSION_STILL_RUNNING', `セッションを停止できていない (status=${session.status})。課金が続く可能性があるため Console で確認し、interrupt の後 session close で確定する`, { result });
    err.noFallback = true;
    throw err;
  }
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
  const waited = await afterSessionExists(ctx, sessionWait(ctx, { sessionId: created.session_id, taskId: args.taskId, maxWaitSeconds: args.maxWaitSeconds, pollMs: args.pollMs }), { session_id: created.session_id, task_id: args.taskId });
  return Object.assign({}, created, waited);
}

// 公開する wait / close は必ず afterSessionExists を通す (呼び出し経路によって扱いが変わらないようにする)。
function sessionWait(ctx, args) {
  return afterSessionExists(ctx, (async () => sessionWaitInner(ctx, args))(), { session_id: (args && args.sessionId) || null, task_id: (args && args.taskId) || null });
}
function sessionClose(ctx, args) {
  return afterSessionExists(ctx, (async () => sessionCloseInner(ctx, args))(), { session_id: (args && args.sessionId) || null, task_id: (args && args.taskId) || null });
}

// セッションが既に存在する (または存在し得る) 操作の失敗は、原因に関わらず Local へ自動で戻さない。
// 既定を「戻さない」にし、戻してよい経路 (セッション作成の送信前の失敗) だけを例外にする。
// 想定外の例外 (応答の形が違う、台帳ロックを取れない等) も AdapterError に包んで同じ扱いにする。
async function afterSessionExists(ctx, promise, ids) {
  try { return await promise; } catch (e) {
    let err = e;
    if (!(e instanceof AdapterError)) {
      const cls = e instanceof budget.BudgetError ? 'BUDGET' : 'INVALID_REQUEST';
      err = new AdapterError(cls, (e && e.code) || 'UNEXPECTED_AFTER_SESSION', redact(e && e.message, secretsOf(ctx)));
    }
    err.extra = Object.assign({}, ids, err.extra);
    err.noFallback = true;
    throw err;
  }
}

async function sessionCloseInner(ctx, args) {
  requireLive(ctx);
  if (!args.taskId) throw new AdapterError('CONFIG', 'ARGS_REQUIRED', '--task-id は必須');
  const task = budget.foldTasks(budget.readLedger(ctx.ledgerPath).entries).get(args.taskId);
  if (!task || task.released) throw new AdapterError('POLICY', 'TASK_UNKNOWN', `task_id=${args.taskId} の有効な予約が台帳に無い`);
  let sessionId = args.sessionId || task.session_id || '';
  if (!sessionId) {
    // 作成の成否が不明なまま予約が残ったタスク: セッション一覧から metadata.claudeos_task_id で突き合わせる。
    const sessions = await listAll(ctx, '/v1/sessions?limit=100', 10);
    const matches = sessions.filter((s) => s.metadata && s.metadata.claudeos_task_id === args.taskId);
    if (matches.length > 1) throw new AdapterError('CONFLICT', 'TASK_SESSION_AMBIGUOUS', `task_id=${args.taskId} に対応するセッションが複数ある (Console で確認する)`, { session_ids: matches.map((s) => s.id) });
    if (matches.length === 0) {
      // 一覧を最後まで読めていない場合は「見つからない」と断定できないため、解除しない。
      if (sessions.truncated) {
        throw new AdapterError('CONFLICT', 'SESSION_LIST_TRUNCATED', 'セッション一覧が取得上限を超えており、未作成と断定できない。Console でセッション ID を確認し --session-id を指定する');
      }
      // 作成リクエストの応答待ちと行き違わないよう、予約から一定時間が経つまでは解除しない。
      const minAgeMs = Math.max(120000, ctx.requestTimeoutMs * 2);
      const ageMs = ctx.now().getTime() - Date.parse(task.ts);
      if (!(ageMs >= minAgeMs)) {
        throw new AdapterError('CONFLICT', 'RESERVATION_TOO_RECENT', `予約から ${Math.round(minAgeMs / 1000)} 秒が経つまでは解除できない (作成リクエストが処理中の可能性がある)`);
      }
      // 作成されなかったと判断できるのは人間だけなので、明示指定を要求する。
      if (!args.confirmNotCreated) {
        throw new AdapterError('CONFLICT', 'TASK_SESSION_NOT_FOUND', '対応するセッションが見つからない。Console で作成されていないことを確認してから --confirm-not-created を付けて予約を解除する');
      }
      budget.release(ctx.ledgerPath, ctx.now(), args.taskId, 'confirmed-not-created-by-operator');
      return { task_id: args.taskId, released: true, finalized: false };
    }
    sessionId = matches[0].id;
  }
  assertId('session', sessionId);
  const session = await apiRequest(ctx, 'GET', `/v1/sessions/${sessionId}`);
  if (!session || typeof session !== 'object' || (session.status !== 'idle' && session.status !== 'terminated')) {
    throw new AdapterError('CONFLICT', 'SESSION_STILL_RUNNING', `セッションが ${session && session.status} のため確定できない (先に interrupt)`);
  }
  assertTaskSessionBinding(ctx, args.taskId, session);
  if (session.status === 'idle') {
    // idle は「まだ開始していない」状態でも返り得る。停止を示すイベント (stop_reason つきの idle) がある場合だけ確定する。
    const events = await listAll(ctx, `/v1/sessions/${sessionId}/events?limit=1000`, 20);
    const outcome = outcomeOf(latestStatusEvent(events));
    if (!outcome || outcome === 'requires_action') {
      throw new AdapterError('CONFLICT', 'SESSION_NOT_SETTLED', 'セッションが停止したことをイベントで確認できないため確定しない (interrupt の後に再実行する)');
    }
  }
  if (usageCents(session) === null) throw new AdapterError('CONFLICT', 'USAGE_UNREADABLE', 'セッションの使用量を解釈できないため確定しない (予約額のまま計上)');
  recordSessionUsage(ctx, args.taskId, session, `closed:${session.status}`);
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
    sessions_today: s.sessionsToday, remaining_sessions_today: Math.max(0, ctx.policy.maxSessionsPerDay - s.sessionsToday),
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
    else if (ctx.config && ctx.config.budget && ctx.config.budget.amountCents) {
      cents = budget.parseCentsString(ctx.config.budget.amountCents);
      if (taskClass === 'check') cents = Math.min(cents, ctx.policy.connectionTestMaxCents);
    }
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

// --- 依頼の入口 (メニューと skill の共通経路) ---
// ask: タスク ID の採番、種別の決定、Router による判定、実行までを 1 つにまとめる。
//   人 (メニュー) と Claude (skill) のどちらから呼んでも同じ制約 (予算・回数・読取専用・依頼文の検査) がかかる。
//   Router が Managed を選ばなかった場合は実行せず、Local 側の決定を返す。
function defaultTaskType(def) {
  return def.taskTypes.find((t) => t !== 'check' && agentRouter.MANAGED_TASK_TYPES.includes(t)) || '';
}

async function ask(ctx, args) {
  requireUsable(ctx);
  if (!args.role) throw new AdapterError('CONFIG', 'ROLE_REQUIRED', '--role は必須');
  if (!args.prompt || !String(args.prompt).trim()) throw new AdapterError('CONFIG', 'PROMPT_REQUIRED', '--prompt または --prompt-file は必須');
  assertPromptSafe(args.prompt);
  const source = args.source === 'agent' ? 'agent' : 'human';
  const def = agentDefinition(loadRoster(ctx.config), args.role);
  const taskType = String(args.taskType || defaultTaskType(def)).trim().toLowerCase();
  const stamp = ctx.now().toISOString().replace(/[-:]/g, '').replace(/\.\d+Z$/, 'Z');
  const taskId = args.taskId || `ask-${args.role}-${stamp}`;

  // この入口から出せるのは読取専用の Agent だけなので、安全条件は固定値で宣言する。
  // 可用性・予算・回数・重複は route() が台帳から判定する。
  const decision = route(ctx, {
    task_type: taskType, complexity: 'medium', risk: 'low', read_only: true, files_affected: 10, expected_duration_min: 15,
    managed: { requested: true, data_sensitivity: 'internal', human_gate: false, requires_secrets: false, requires_external_network: false },
  }, { taskId, budgetCents: args.budgetCents, ackDailySoft: !!args.ackDailySoft });
  appendJsonl(ctx.decisionsPath, { ts: ctx.now().toISOString(), kind: 'ask', source, task_id: taskId, role: args.role, task_type: taskType, execution: decision.execution });

  if (decision.execution !== 'ManagedAgent') {
    return {
      mode: ctx.mode, executed: false, managed: false, source, task_id: taskId, role: args.role, task_type: taskType,
      denied: decision.managed.denied, policy_denied: decision.managed.policy_denied,
      budget_code: decision.managed.evidence.budget_code,
      // Managed へ出せない場合の Local 側の実行先。安全上の拒否 (policy_denied) の場合も、Local の承認手続きはそのまま適用される。
      do_locally_with: decision.managed.fallback_execution,
    };
  }
  const result = await sessionRun(ctx, Object.assign({}, args, { taskId, taskType, taskClass: taskType === 'check' ? 'check' : 'task' }));
  return Object.assign({ managed: true, source, task_type: taskType }, result);
}

// --- CLI ---
// 値を取るオプションと真偽フラグを明示的に分ける。値が無い・未知のオプションはエラーにする
// (--budget-cents の値を忘れて既定額で実行される、といった黙った読み替えを防ぐ)。
const VALUE_OPTIONS = new Set(['config', 'source', 'role', 'task-id', 'task-type', 'prompt', 'prompt-file', 'budget-cents', 'class', 'repo', 'ref', 'session-id', 'max-wait-seconds', 'poll-ms', 'console-usd', 'note', 'json']);
const FLAG_OPTIONS = new Set(['probe', 'ack-daily-soft', 'confirm-not-created']);
function parseArgs(argv) {
  const pos = [];
  const opts = {};
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (!a.startsWith('--')) { pos.push(a); continue; }
    const key = a.slice(2);
    if (FLAG_OPTIONS.has(key)) { opts[key] = true; continue; }
    if (!VALUE_OPTIONS.has(key)) throw new AdapterError('CONFIG', 'OPTION_UNKNOWN', `不明なオプション: --${key}`);
    // 値は次の引数をそのまま使う ("--" で始まる文字列も値として受け取る。例: --prompt "--verbose を説明")
    if (i + 1 >= argv.length) throw new AdapterError('CONFIG', 'OPTION_VALUE_REQUIRED', `--${key} には値が必要`);
    opts[key] = argv[i + 1];
    i += 1;
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
    taskType: typeof o['task-type'] === 'string' ? o['task-type'] : '',
    confirmNotCreated: o['confirm-not-created'] === true,
    source: o.source === 'agent' ? 'agent' : 'human',
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
    // 以下は既存セッションに対する操作。失敗しても Local へ自動で戻さない (afterSessionExists)。
    const ids = { session_id: a.sessionId || null, task_id: a.taskId || null };
    if (sub === 'wait') return afterSessionExists(ctx, (async () => sessionWait(ctx, a))(), ids);
    if (sub === 'close') return afterSessionExists(ctx, (async () => sessionClose(ctx, a))(), ids);
    if (sub === 'get') return afterSessionExists(ctx, (async () => { requireLive(ctx); return apiRequest(ctx, 'GET', `/v1/sessions/${assertId('session', a.sessionId)}`); })(), ids);
    if (sub === 'events') {
      return afterSessionExists(ctx, (async () => {
        requireLive(ctx);
        const data = await listAll(ctx, `/v1/sessions/${assertId('session', a.sessionId)}/events?limit=1000`, 20);
        return { data, truncated: data.truncated };
      })(), ids);
    }
    if (sub === 'interrupt') return afterSessionExists(ctx, (async () => { requireLive(ctx); await sendInterrupt(ctx, a.sessionId); return { session_id: a.sessionId, interrupt_sent: true }; })(), ids);
  }
  if (cmd === 'budget') {
    if (sub === 'status' || !sub) return budgetStatus(ctx);
    if (sub === 'reconcile') {
      if (typeof o['console-usd'] !== 'string') throw new AdapterError('CONFIG', 'ARGS_REQUIRED', '--console-usd <Console の当期利用額> は必須');
      return budget.reconcile(ctx.ledgerPath, ctx.now(), ctx.policy, budget.usdToCents(o['console-usd']), typeof o.note === 'string' ? o.note : null);
    }
  }
  if (cmd === 'ask') return ask(ctx, sessionArgs(o));
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
      // noFallback: クラウド側でセッションが動いている (かもしれない) 場合。Local で再実行すると二重実行になる。
      fallback: e.noFallback
        ? { to: 'none', state: 'NEEDS_OPERATOR', reason: 'managed-session-state-unconfirmed' }
        : fallbackDecision(cls),
      details: e.extra || {},
    },
  };
}

async function main() {
  let ctx = null;
  try {
    const { pos, opts } = parseArgs(process.argv.slice(2));
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
  budgetStatus, status, route, ask, assertPromptSafe, latestStatusEvent, outcomeOf, errorPayload, dispatch, parseArgs,
};

if (require.main === module) main();
