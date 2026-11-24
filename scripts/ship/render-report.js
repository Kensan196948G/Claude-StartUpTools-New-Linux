#!/usr/bin/env node
'use strict';
/**
 * render-report.js — 完成報告書 Markdown を外部依存の無い単一 HTML に変換する
 *   node scripts/ship/render-report.js <in.md> <out.html> [kpis.json]
 * kpis.json: [[値, ラベル, 状態], ...] (実測値だけを入れること)
 */
const fs = require('node:fs');
const [inFile, outFile, kpiFile] = process.argv.slice(2);
if (!inFile || !outFile) { console.error('usage: render-report.js <in.md> <out.html> [kpis.json]'); process.exit(2); }
const md = fs.readFileSync(inFile, 'utf8');
const kpi = kpiFile ? JSON.parse(fs.readFileSync(kpiFile, 'utf8')) : [];
const esc = (s) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
const inline = (s) => esc(s).replace(/\*\*(.+?)\*\*/g, '<strong>$1</strong>').replace(/`([^`]+)`/g, '<code>$1</code>')
  .replace(/(https:\/\/github\.com\/[^\s<)]+)/g, '<a href="$1">$1</a>')
  .replace(/\[(実測|推定|未検証)(・未検証)?\]/g, (m, a, b) => `<span class="tag t-${a}">${a}${b || ''}</span>`);
let html = ''; let inTable = false; let inList = false; let rows = [];
const flushTable = () => { if (!inTable) return; const [h, , ...b] = rows; html += '<div class="tw"><table><thead><tr>' + h.map((c) => `<th>${inline(c)}</th>`).join('') + '</tr></thead><tbody>' + b.map((r) => '<tr>' + r.map((c) => `<td>${inline(c)}</td>`).join('') + '</tr>').join('') + '</tbody></table></div>'; inTable = false; rows = []; };
const flushList = () => { if (inList) { html += '</ul>'; inList = false; } };
const icons = { 1: '🎯', 2: '🔬', 3: '🧩', 4: '🧪', 5: '🚢', 6: '💰', 7: '⚠️', 8: '↩️', 9: '🔗', 10: '🔐' };
for (const line of md.split('\n')) {
  if (/^\|/.test(line)) { flushList(); inTable = true; rows.push(line.replace(/^\||\|$/g, '').split('|').map((s) => s.trim())); continue; }
  flushTable();
  let m;
  if ((m = line.match(/^# (.+)/))) { html += `<h1>🚢 ${inline(m[1])}</h1>__KPI__<section class="card">`; continue; }
  if ((m = line.match(/^## (\d+)\. (.+)/))) { flushList(); html += `</section><section class="card"><h2>${icons[m[1]] || ''} ${m[1]}. ${inline(m[2])}</h2>`; if (m[1] === '3') html += '__PIPE__'; if (m[1] === '5') html += '__STATES__'; continue; }
  if ((m = line.match(/^### (.+)/))) { flushList(); html += `<h3>${inline(m[1])}</h3>`; continue; }
  if ((m = line.match(/^> (.+)/))) { html += `<p class="note">${inline(m[1])}</p>`; continue; }
  if ((m = line.match(/^\s*(?:- |\d+\. )(.+)/))) { if (!inList) { html += '<ul>'; inList = true; } html += `<li>${inline(m[1])}</li>`; continue; }
  flushList();
  if (line.trim()) html += `<p>${inline(line)}</p>`;
}
flushTable(); flushList();
const steps = ['指示', '調査・計画', '実装', 'ローカルテスト', 'PR', '/ship (人)', 'Ship 署名 (人)', '隔離品質', 'AI Quality Gate', '人間承認 (署名)', '自動マージ', '結果確認・監査'];
const pipe = '<div class="pipe" aria-label="開発パイプライン">' + steps.map((s, i) => `<div class="st ${/人/.test(s) ? 'human' : ''}" style="--i:${i}"><span>${i + 1}</span>${esc(s)}</div>`).join('<div class="ar">→</div>') + '</div><p class="small">緑枠 = 人が行う工程（/ship は公式仕様で人が入力する）。</p>';
const st = ['DISCOVERY', 'PLANNING', 'IMPLEMENTING', 'LOCAL_TESTING', 'PR_CREATING', 'SHIP_REVIEWING', 'SHIP_REVALIDATING', 'QUALITY_EVALUATING', 'HUMAN_APPROVAL_REQUIRED', 'HUMAN_APPROVED', 'MERGE_QUEUED', 'MERGED', 'COMPLETED'];
const W = st.length * 96 + 20;
const svg = `<svg viewBox="0 0 ${W} 150" role="img" aria-label="主要な状態遷移"><defs><marker id="a" markerWidth="8" markerHeight="8" refX="7" refY="4" orient="auto"><path d="M0,0 L8,4 L0,8z" fill="currentColor"/></marker></defs>`
  + st.map((s, i) => { const x = 10 + i * 96; return `<g class="node ${/HUMAN/.test(s) ? 'g' : ''}" style="--i:${i}"><rect x="${x}" y="40" width="88" height="44" rx="8"/><text x="${x + 44}" y="66" font-size="7.5" text-anchor="middle">${s}</text></g>` + (i < st.length - 1 ? `<line x1="${x + 88}" y1="62" x2="${x + 96}" y2="62" stroke="currentColor" marker-end="url(#a)"/>` : ''); }).join('')
  + `<path d="M ${10 + 10 * 96 + 44} 84 C ${10 + 10 * 96} 140, ${10 + 6 * 96 + 44} 140, ${10 + 6 * 96 + 44} 86" fill="none" stroke="#c0392b" stroke-dasharray="4 3" marker-end="url(#a)"/><text x="${10 + 8 * 96 + 44}" y="140" font-size="9" fill="#c0392b" text-anchor="middle">head / base が変われば承認失効 → 再検証</text></svg>`;
const kpis = '<div class="kpis">' + kpi.map(([v, l, s], i) => `<div class="kpi" style="--i:${i}"><div class="v">${esc(v)}</div><div class="l">${esc(l)}</div><div class="s">${esc(s)}</div></div>`).join('') + '</div>';
html = html.replace('</section>', '').replace('__KPI__', kpis).replace('__PIPE__', pipe)
  .replace('__STATES__', '<h3>主要な状態遷移（全 22 状態は state-machine.js）</h3><div class="svgw">' + svg + '</div>');
const css = `:root{--bg:#f6f8fb;--fg:#17202a;--card:#fff;--mut:#5d6d7e;--acc:#1f6feb;--ok:#1a7f37;--warn:#9a6700;--bad:#c0392b;--bd:#d8dee4}
@media (prefers-color-scheme:dark){:root{--bg:#0d1117;--fg:#e6edf3;--card:#161b22;--mut:#9aa7b4;--acc:#58a6ff;--ok:#3fb950;--warn:#d29922;--bad:#ff7b72;--bd:#30363d}}
body{margin:0;font:15px/1.7 system-ui,"Noto Sans JP",sans-serif;background:var(--bg);color:var(--fg)}main{max-width:1100px;margin:0 auto;padding:24px}
h1{font-size:26px;margin:8px 0 4px;background:linear-gradient(90deg,var(--acc),#8250df);-webkit-background-clip:text;background-clip:text;color:transparent}
h2{font-size:19px;border-left:4px solid var(--acc);padding-left:10px}h3{font-size:16px}a{color:var(--acc)}
.card{background:var(--card);border:1px solid var(--bd);border-radius:12px;padding:8px 20px 16px;margin:16px 0;animation:up .5s ease both}
.tw{overflow-x:auto}table{border-collapse:collapse;width:100%;font-size:13.5px}th,td{border:1px solid var(--bd);padding:6px 8px;text-align:left;vertical-align:top}th{background:color-mix(in srgb,var(--acc) 10%,transparent)}
code{background:color-mix(in srgb,var(--mut) 15%,transparent);padding:1px 5px;border-radius:4px;font-size:.9em;word-break:break-all}
.note{border:1px solid var(--warn);background:color-mix(in srgb,var(--warn) 12%,transparent);padding:8px 12px;border-radius:8px}
.tag{font-size:11px;padding:1px 6px;border-radius:10px;border:1px solid}.t-実測{color:var(--ok)}.t-推定{color:var(--warn)}.t-未検証{color:var(--bad)}
.kpis{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:10px;margin:16px 0}
.kpi{background:var(--card);border:1px solid var(--bd);border-radius:12px;padding:12px;animation:up .5s ease both;animation-delay:calc(var(--i)*80ms)}
.kpi .v{font-size:24px;font-weight:700;color:var(--acc)}.kpi .l{color:var(--mut);font-size:12px}.kpi .s{font-size:12px;color:var(--ok)}
.pipe{display:flex;flex-wrap:wrap;align-items:center;gap:6px;margin:12px 0}.st{border:2px solid var(--acc);border-radius:10px;padding:6px 10px;font-size:13px;animation:pop .4s ease both;animation-delay:calc(var(--i)*90ms)}
.st span{display:inline-block;background:var(--acc);color:#fff;border-radius:50%;width:20px;height:20px;text-align:center;font-size:11px;line-height:20px;margin-right:6px}
.st.human{border-color:var(--ok)}.st.human span{background:var(--ok)}.ar{color:var(--mut)}.small{font-size:12px;color:var(--mut)}
.svgw{overflow-x:auto;color:var(--mut)}svg{min-width:900px;width:100%}svg rect{fill:var(--card);stroke:var(--acc);stroke-width:1.5}svg text{fill:var(--fg)}
.node{animation:pop .4s ease both;animation-delay:calc(var(--i)*70ms)}.node.g rect{stroke:var(--ok);stroke-width:2.5}
@keyframes up{from{opacity:0;transform:translateY(8px)}to{opacity:1;transform:none}}@keyframes pop{from{opacity:0;transform:scale(.9)}to{opacity:1;transform:none}}
@media (prefers-reduced-motion:reduce){*{animation:none!important}}footer{color:var(--mut);font-size:12px;text-align:center;margin:24px 0}`;
const title = (md.match(/^# (.+)/m) || [, 'Report'])[1];
fs.writeFileSync(outFile, `<!doctype html><html lang="ja"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${esc(title)}</title><style>${css}</style></head><body><main>${html}</section><footer>単一ファイル HTML（外部 CDN なし）。生成元: ${esc(inFile)}</footer></main></body></html>`);
console.log('wrote', outFile);
