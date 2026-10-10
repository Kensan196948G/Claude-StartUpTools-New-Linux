#!/usr/bin/env node
'use strict';
// managed-session-payload.js — ClaudeOS v11 Managed Agents Session Payload Builder
//
// POST /v1/sessions の body を設定契約 (config/managed-agents.json) から構築する。
// docs/claude/07 §6-2 / §7-1 の公式仕様に準拠:
//   body: { agent, environment_id, vault_ids, budget, title, metadata, resources, initial_events }
//   agent は ID 文字列、または {type:"agent", id, version} (agent_id / prompt は受理されない)
//   inference_geo は session 最上位ではなく agent の model オブジェクト内に置く (2026-10 現行仕様で確認)
//   budget: { type: "limit", max_list_cost: { amount: "<セント整数文字列>", currency: "USD" } }
//   budget は後付け不可 → **budget 無しの Session 作成は例外で拒否する (P0 要件 6)**
//
// CLI:
//   node scripts/tools/managed-session-payload.js session-create \
//        --config config/managed-agents.json [--budget-cents 500] [--agent agent_...]
//   → stdout に payload JSON (成功時)。失敗時は stderr にエラー JSON + 終了コード 2/3
//
// 終了コード: 0 成功 / 2 設定契約不成立 / 3 budget 必須違反 (BUDGET_REQUIRED)

const fs = require('fs');

const ERR_CONFIG = 2;
const ERR_BUDGET = 3;

class PayloadError extends Error {
  constructor(code, error, message, details) {
    super(message);
    this.code = code; this.error = error; this.details = details || {};
  }
}

function loadConfig(configPath) {
  let raw;
  try { raw = JSON.parse(fs.readFileSync(configPath, 'utf8')); }
  catch (e) { throw new PayloadError(ERR_CONFIG, 'CONFIG_UNREADABLE', `config を読み込めない: ${configPath} (${e.message})`); }
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) {
    throw new PayloadError(ERR_CONFIG, 'CONFIG_INVALID', 'config は JSON オブジェクトである必要がある');
  }
  return raw;
}

// --- 設定契約の検証 (schema 相当) ---
// mode=disabled は常に local 実行のため payload 生成不可。
// dry-run / live では environmentId / orchestratorId / budget が必須。
// プレースホルダ (ID 中に "xxx" を含む) は未設定扱い。
function validate(config, opts) {
  const opts_ = opts || {};
  const mode = String(config.mode || 'disabled');
  if (mode === 'disabled') {
    throw new PayloadError(ERR_CONFIG, 'MODE_DISABLED', 'config mode=disabled は payload 生成不可 (Goal Router は local へフォールバック)');
  }
  if (mode !== 'dry-run' && mode !== 'live') {
    throw new PayloadError(ERR_CONFIG, 'MODE_INVALID', `mode は disabled|dry-run|live のみ (actual: ${mode})`);
  }
  if (config.enabled !== true) {
    throw new PayloadError(ERR_CONFIG, 'NOT_ENABLED', 'enabled=false のため payload 生成不可');
  }
  if (opts_.bypassMode && opts_.bypassMode !== mode) {
    // 検証専用モード差し替え (dry-run 前提のテスト用)。live 強制は不可。
    if (String(opts_.bypassMode) === 'live') {
      throw new PayloadError(ERR_CONFIG, 'MODE_ESCALATION_FORBIDDEN', 'bypassMode=live への昇格は禁止 (設定ファイルのみで昇格可)');
    }
  }
  const agent = String(opts_.agent || config.orchestratorId || '');
  if (!agent.startsWith('agent_') || /xxx/.test(agent)) {
    throw new PayloadError(ERR_CONFIG, 'AGENT_NOT_CONFIGURED', `orchestratorId が未設定/プレースホルダ (${agent || '空'})`);
  }
  const envId = String(opts_.environmentId || config.environmentId || '');
  if (!envId.startsWith('env_') || /xxx/.test(envId)) {
    throw new PayloadError(ERR_CONFIG, 'ENVIRONMENT_NOT_CONFIGURED', `environmentId が未設定/プレースホルダ (${envId || '空'})`);
  }
  const vaultIds = Array.isArray(config.vaultIds) ? config.vaultIds.filter((v) => typeof v === 'string' && v.startsWith('vlt_') && !/xxx/.test(v)) : [];
  // budget (必須): opts > config の順。amount はセント整数の「文字列」のみ。
  const budgetSrc = (opts_.budgetCents != null ? { amountCents: String(opts_.budgetCents), currency: 'USD' } : config.budget) || {};
  const amount = budgetSrc.amountCents;
  const currency = budgetSrc.currency || 'USD';
  if (amount == null || amount === '' ) {
    throw new PayloadError(ERR_BUDGET, 'BUDGET_REQUIRED', 'budget は Session 作成時に必須 (後付け不可)。budget 無指定の Managed 自律実行は禁止', { field: 'budget.amountCents' });
  }
  // 公式仕様: 先頭ゼロなしの正の整数文字列 (> 0)。"0" / "0500" / "25.00" は API 側でも拒否される。
  if (!/^[1-9][0-9]*$/.test(String(amount))) {
    throw new PayloadError(ERR_BUDGET, 'BUDGET_AMOUNT_INVALID', `budget.amountCents は先頭ゼロなしの正の整数文字列のみ (actual: ${amount})`, { field: 'budget.amountCents' });
  }
  // 単一セッション上限 (Budget Guard から渡される)。上限超過の payload は生成しない。
  if (opts_.maxCents != null && Number(amount) > Number(opts_.maxCents)) {
    throw new PayloadError(ERR_BUDGET, 'BUDGET_SESSION_CAP_EXCEEDED', `budget.amountCents ${amount} が単一セッション上限 ${opts_.maxCents} を超える`, { field: 'budget.amountCents' });
  }
  if (currency !== 'USD') {
    throw new PayloadError(ERR_BUDGET, 'BUDGET_CURRENCY_INVALID', `budget.currency は USD のみ (actual: ${currency})`, { field: 'budget.currency' });
  }
  return { agent, envId, vaultIds, amount: String(amount), currency, mode };
}

function sessionCreate(config, opts) {
  const v = validate(config, opts);
  const opts_ = opts || {};
  // agent version を指定した場合はピン留め参照 ({type:"agent", id, version}) にする。
  const agentRef = Number.isInteger(opts_.agentVersion) && opts_.agentVersion >= 1
    ? { type: 'agent', id: v.agent, version: opts_.agentVersion }
    : v.agent;
  const payload = {
    agent: agentRef,
    environment_id: v.envId,
    budget: { type: 'limit', max_list_cost: { amount: v.amount, currency: v.currency } },
  };
  if (v.vaultIds.length) payload.vault_ids = v.vaultIds;
  if (typeof opts_.title === 'string' && opts_.title) payload.title = opts_.title.slice(0, 200);
  if (opts_.metadata && typeof opts_.metadata === 'object') payload.metadata = opts_.metadata;
  // resources (github_repository 等) と initial_events は呼び出し側 (adapter) が組み立てて渡す。
  // authorization_token を含み得るため、builder はここで受け取るだけでログ・meta へは出さない。
  if (Array.isArray(opts_.resources) && opts_.resources.length) payload.resources = opts_.resources;
  if (Array.isArray(opts_.initialEvents) && opts_.initialEvents.length) payload.initial_events = opts_.initialEvents;
  // inference_geo は session 最上位では受理されない (現行仕様: agent の model オブジェクト内にのみ置く)。
  // 地域固定が必要な場合は roster (config/managed-agents-roster.json) の model を {id, inference_geo} で書く。
  // GitHub 主系の制約は payload body には載せない (spec: body は agent/environment/vaults/budget のみ)。
  // Control Plane が user.message で指示するため、builder は制約サマリを meta として返す。
  const github = config.github || {};
  const meta = {
    mode: v.mode,
    github_primary: (github.workspace && github.workspace.type) || 'repository_resource',
    github_workspace: github.workspace ? github.workspace.resource : null,
    mcp_allowed_tools: (github.mcp && github.mcp.allowedTools) || [],
    mcp_blocked_tools: (github.mcp && github.mcp.blockedTools) || [],
    budget_max_list_cost: payload.budget.max_list_cost,
  };
  return { payload, meta };
}

// --- user.message イベントの構築 (2 段階ライフサイクル ②) ---
function messageEvent(text) {
  if (!text || typeof text !== 'string') {
    throw new PayloadError(ERR_CONFIG, 'MESSAGE_REQUIRED', 'user.message の text は必須');
  }
  return { events: [{ type: 'user.message', content: [{ type: 'text', text: String(text) }] }] };
}

// --- tool_confirmation イベント (Conditional アクションの承認。human_gate はここで allow しない) ---
function toolConfirmation(toolUseId, result) {
  if (!toolUseId) throw new PayloadError(ERR_CONFIG, 'TOOL_USE_ID_REQUIRED', 'tool_use_id は必須');
  if (result !== 'allow' && result !== 'deny') {
    throw new PayloadError(ERR_CONFIG, 'CONFIRMATION_RESULT_INVALID', "result は 'allow' | 'deny' のみ");
  }
  return { events: [{ type: 'user.tool_confirmation', tool_use_id: toolUseId, result }] };
}

function main() {
  const argv = process.argv.slice(2);
  const cmd = argv[0];
  const getOpt = (name) => {
    const i = argv.indexOf(name);
    return i >= 0 ? argv[i + 1] : null;
  };
  const emit = (code, obj) => {
    process.stdout.write(JSON.stringify(obj, null, 2) + '\n');
    process.exit(code);
  };
  try {
    if (cmd === 'session-create') {
      const configPath = getOpt('--config');
      if (!configPath) throw new PayloadError(ERR_CONFIG, 'CONFIG_ARG_REQUIRED', '--config は必須');
      const config = loadConfig(configPath);
      const out = sessionCreate(config, {
        budgetCents: getOpt('--budget-cents'),
        agent: getOpt('--agent'),
      });
      emit(0, out);
    } else if (cmd === 'message-event') {
      emit(0, messageEvent(getOpt('--text')));
    } else if (cmd === 'tool-confirmation') {
      emit(0, toolConfirmation(getOpt('--tool-use-id'), getOpt('--result')));
    } else {
      throw new PayloadError(ERR_CONFIG, 'USAGE', 'usage: managed-session-payload.js session-create|message-event|tool-confirmation');
    }
  } catch (e) {
    process.stderr.write(JSON.stringify({ error: e.error || 'UNEXPECTED', message: e.message, details: e.details || {} }) + '\n');
    process.exit(e.code || 1);
  }
}

module.exports = { loadConfig, validate, sessionCreate, messageEvent, toolConfirmation, PayloadError, ERR_CONFIG, ERR_BUDGET };

if (require.main === module) main();
