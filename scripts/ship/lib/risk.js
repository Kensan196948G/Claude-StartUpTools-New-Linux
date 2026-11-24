'use strict';
/**
 * risk.js — 変更パスから R0..R4 を判定する (config/ship-policy.json risk.rules)
 *
 * 規則: 各ファイルについて最初に当たった規則のレベル (rules は R4→R0 の順) を採り、
 *       ファイル間で最大を採用する。どれにも当たらないファイルは risk.default (R2)。
 *       変更ファイル一覧が取れない (空) 場合は判定不能として R4 (安全側) を返す。
 */

const LEVELS = ['R0', 'R1', 'R2', 'R3', 'R4'];

/** globToRegExp — ** / * / ? だけをサポートする最小 glob */
function globToRegExp(glob) {
  let re = '';
  for (let i = 0; i < glob.length; i++) {
    const c = glob[i];
    if (c === '*') {
      if (glob[i + 1] === '*') {
        i++;
        if (glob[i + 1] === '/') { i++; re += '(?:.*/)?'; } else re += '.*';
      } else re += '[^/]*';
    } else if (c === '?') re += '[^/]';
    else re += c.replace(/[.+^${}()|[\]\\]/g, '\\$&');
  }
  return new RegExp('^' + re + '$');
}

function matchAny(file, patterns) {
  return patterns.some((p) => globToRegExp(p).test(file) || (!p.includes('/') && globToRegExp('**/' + p).test(file)));
}

function classifyFile(file, riskPolicy) {
  for (const rule of riskPolicy.rules || []) {
    if (matchAny(file, rule.patterns || [])) return { level: rule.level, pattern: rule.patterns.find((p) => matchAny(file, [p])) };
  }
  return { level: riskPolicy.default || 'R2', pattern: null };
}

/** classify(files, riskPolicy) → { level, files:[{file,level,pattern}], reason } */
function classify(files, riskPolicy) {
  if (!Array.isArray(files) || files.length === 0) {
    return { level: 'R4', files: [], reason: 'NO_CHANGED_FILES (判定不能のため安全側 R4)' };
  }
  const detail = files.map((f) => ({ file: f, ...classifyFile(f, riskPolicy) }));
  const max = detail.reduce((m, d) => Math.max(m, LEVELS.indexOf(d.level)), 0);
  const level = LEVELS[max];
  return { level, files: detail, reason: `max over ${files.length} files`, requirements: (riskPolicy.requirements || {})[level] || {} };
}

module.exports = { LEVELS, classify, classifyFile, globToRegExp };
