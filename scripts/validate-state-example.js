#!/usr/bin/env node
// Validates state JSON files against state.schema.json
// (type + required + enum checks, no external deps).
//
// Usage:
//   node scripts/validate-state-example.js                 # state.json.example + scripts/setup/state-template.json
//   node scripts/validate-state-example.js <file> [...]    # arbitrary state files (old / new / fixtures)
//   node scripts/validate-state-example.js --json <file>   # machine-readable result
//
// Exported for tests: validateState(obj, schema) → string[] errors

const fs = require('fs');
const path = require('path');

const root = path.resolve(__dirname, '..');

function jsTypeOf(value) {
  if (value === null) return 'null';
  if (Array.isArray(value)) return 'array';
  return typeof value;
}

function checkType(value, typeDef, fieldPath, errors) {
  if (!typeDef.type) return true;
  const allowed = Array.isArray(typeDef.type) ? typeDef.type : [typeDef.type];
  const actual = jsTypeOf(value);
  const matched = allowed.some(t => {
    if (t === actual) return true;
    if (t === 'integer' && typeof value === 'number' && Number.isInteger(value)) return true;
    if (t === 'number' && typeof value === 'number') return true;
    return false;
  });
  if (!matched) {
    errors.push(`${fieldPath}: expected ${JSON.stringify(typeDef.type)}, got "${actual}"`);
    return false;
  }
  return true;
}

function checkEnum(value, typeDef, fieldPath, errors) {
  if (!Array.isArray(typeDef.enum)) return;
  if (!typeDef.enum.includes(value)) {
    errors.push(`${fieldPath}: value ${JSON.stringify(value)} not in enum ${JSON.stringify(typeDef.enum)}`);
  }
}

function validateNode(value, schemaDef, fieldPath, errors) {
  if (!schemaDef) return;
  if (!checkType(value, schemaDef, fieldPath, errors)) return;
  checkEnum(value, schemaDef, fieldPath, errors);
  if (typeof schemaDef.minimum === 'number' && typeof value === 'number' && value < schemaDef.minimum) {
    errors.push(`${fieldPath}: ${value} < minimum ${schemaDef.minimum}`);
  }
  if (typeof schemaDef.maximum === 'number' && typeof value === 'number' && value > schemaDef.maximum) {
    errors.push(`${fieldPath}: ${value} > maximum ${schemaDef.maximum}`);
  }
  if (typeof value === 'object' && value !== null && !Array.isArray(value)) {
    for (const req of schemaDef.required || []) {
      if (!(req in value)) errors.push(`${fieldPath}: missing required field "${req}"`);
    }
    for (const [key, propSchema] of Object.entries(schemaDef.properties || {})) {
      if (!(key in value)) continue;
      validateNode(value[key], propSchema, `${fieldPath}.${key}`, errors);
    }
  }
  if (Array.isArray(value)) {
    if (typeof schemaDef.maxItems === 'number' && value.length > schemaDef.maxItems) {
      errors.push(`${fieldPath}: ${value.length} items > maxItems ${schemaDef.maxItems}`);
    }
    if (schemaDef.items) value.forEach((v, i) => validateNode(v, schemaDef.items, `${fieldPath}[${i}]`, errors));
  }
}

function validateState(obj, schema) {
  const errors = [];
  for (const req of schema.required || []) {
    if (!(req in obj)) errors.push(`Missing required field: "${req}"`);
  }
  for (const [key, propSchema] of Object.entries(schema.properties || {})) {
    if (!(key in obj)) continue;
    validateNode(obj[key], propSchema, key, errors);
  }
  return errors;
}

function loadSchema() {
  return JSON.parse(fs.readFileSync(path.join(root, 'state.schema.json'), 'utf8'));
}

// Seed/template files are partial by design: only "required" at top level is relaxed for them.
function validateFile(file, schema, { partial = false } = {}) {
  const obj = JSON.parse(fs.readFileSync(file, 'utf8'));
  const errors = validateState(obj, schema).filter(e => !(partial && /missing required field/i.test(e)));
  return errors;
}

if (require.main === module) {
  const schema = loadSchema();
  const args = process.argv.slice(2);
  const asJson = args.includes('--json');
  const files = args.filter(a => a !== '--json');
  const targets = files.length
    ? files.map(f => ({ file: path.resolve(f), partial: false }))
    : [
        { file: path.join(root, 'state.json.example'), partial: false },
        { file: path.join(root, 'scripts', 'setup', 'state-template.json'), partial: true },
      ];
  let failed = false;
  const report = [];
  for (const t of targets) {
    const errors = validateFile(t.file, schema, { partial: t.partial });
    report.push({ file: path.relative(root, t.file), ok: errors.length === 0, errors });
    if (errors.length) failed = true;
  }
  if (asJson) {
    console.log(JSON.stringify(report, null, 2));
  } else {
    for (const r of report) {
      if (r.ok) console.log(`${r.file}: validation PASSED`);
      else { console.error(`${r.file}: validation FAILED`); r.errors.forEach(e => console.error('  ' + e)); }
    }
  }
  process.exit(failed ? 1 : 0);
}

module.exports = { validateState, validateFile, loadSchema };
