'use strict';
// audit-trail-task.test.js — PostToolUse hook (.claude/claudeos/scripts/hooks/audit-trail.js) が
// Task ツール (subagent 起動) を記録する挙動を検証する (Control Plane emission 強化)。
const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync } = require('child_process');

const HOOK = path.join(__dirname, '..', '.claude', 'claudeos', 'scripts', 'hooks', 'audit-trail.js');
const AUDIT_REL = path.join('.claude', 'claudeos', 'data', 'audit-log.jsonl');

function runHook(tmp, input) {
  execFileSync(process.execPath, [HOOK], { cwd: tmp, input: JSON.stringify(input), encoding: 'utf8' });
}

test('audit-trail: Task ツール起動を subagent_type/description 付きで記録する', () => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'audit-trail-'));
  runHook(tmp, { tool_name: 'Task', tool_input: { subagent_type: 'Explore', description: 'find the config loader' } });
  const line = fs.readFileSync(path.join(tmp, AUDIT_REL), 'utf8').trim();
  const entry = JSON.parse(line);
  assert.strictEqual(entry.tool, 'Task');
  assert.match(entry.action, /subagent_type=Explore/);
  assert.match(entry.action, /description=find the config loader/);
});

test('audit-trail: Read/Edit/Write は引き続き記録しない (ローカル編集は対象外)', () => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'audit-trail-'));
  for (const tool of ['Read', 'Edit', 'Write']) {
    runHook(tmp, { tool_name: tool, tool_input: { file_path: '/tmp/x' } });
  }
  assert.strictEqual(fs.existsSync(path.join(tmp, AUDIT_REL)), false);
});

test('audit-trail: Bash の書込コマンドは従来どおり記録される (回帰確認)', () => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'audit-trail-'));
  runHook(tmp, { tool_name: 'Bash', tool_input: { command: 'git push origin main' } });
  const line = fs.readFileSync(path.join(tmp, AUDIT_REL), 'utf8').trim();
  const entry = JSON.parse(line);
  assert.strictEqual(entry.tool, 'Bash');
  assert.match(entry.action, /git push origin main/);
});

test('.claude/claudeos と Claude/templates/claudeos の audit-trail.js は同一内容', () => {
  const templatePath = path.join(__dirname, '..', 'Claude', 'templates', 'claudeos', 'scripts', 'hooks', 'audit-trail.js');
  assert.strictEqual(fs.readFileSync(HOOK, 'utf8'), fs.readFileSync(templatePath, 'utf8'));
});
