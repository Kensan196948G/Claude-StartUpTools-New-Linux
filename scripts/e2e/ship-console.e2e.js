#!/usr/bin/env node
'use strict';
/* ============================================================
   ship-console.e2e.js — Ship Native Control Center のブラウザ検証 (Playwright)

   目的: ship.html が API (/api/ship/*) の実値を画面へ出していることを、API と DOM の突き合わせで確かめる。
   承認ボタンが存在しないこと (人間は CLI で承認する) も検査する。

   使い方:
     node scripts/e2e/ship-console.e2e.js                    # http://127.0.0.1:3740
     CONSOLE_URL=http://127.0.0.1:3804 node scripts/e2e/ship-console.e2e.js

   出力: reports/e2e/ship-<timestamp>/{overview,dark}.png, result.json
   終了コード: 失敗が 1 件でもあれば 1。playwright を require できなければ 2。
   ============================================================ */
const fs = require('fs');
const path = require('path');
const http = require('http');

const BASE = process.env.CONSOLE_URL || 'http://127.0.0.1:3740';
const OUT_DIR = path.join(__dirname, '..', '..', 'reports', 'e2e', 'ship-' + new Date().toISOString().replace(/[:.]/g, '-'));
const results = [];

function getJson(p) {
  return new Promise((resolve) => {
    const req = http.get(BASE + p, { timeout: 20000 }, (res) => {
      let d = '';
      res.on('data', (c) => { d += c; });
      res.on('end', () => { try { resolve(JSON.parse(d)); } catch { resolve(null); } });
    });
    req.on('error', () => resolve(null));
    req.on('timeout', () => { req.destroy(); resolve(null); });
  });
}
function record(name, ok, detail) {
  results.push({ name, ok, detail });
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name.padEnd(22)} ${detail}`);
}

(async () => {
  let chromium;
  try { ({ chromium } = require('playwright')); } catch (e) {
    console.error('playwright を require できません: ' + String(e && e.message));
    process.exit(2);
  }
  fs.mkdirSync(OUT_DIR, { recursive: true });
  const browser = await chromium.launch({ headless: true });
  const page = await browser.newPage({ viewport: { width: 1440, height: 1100 } });
  const errors = [];
  page.on('console', (m) => { if (m.type() === 'error') errors.push(m.text()); });
  page.on('pageerror', (e) => errors.push('pageerror: ' + e.message));

  try {
    const ov = await getJson('/api/ship/overview');
    record('overview API', !!(ov && ov.ok), ov ? `counts=${JSON.stringify(ov.counts)}` : 'API 応答なし');

    await page.goto(BASE + '/ship.html', { waitUntil: 'domcontentloaded' });
    await page.waitForFunction(() => /最終更新|取得に失敗/.test(document.getElementById('live').textContent || ''), null, { timeout: 25000 }).catch(() => {});
    const liveText = await page.textContent('#live');
    record('初回取得', /最終更新/.test(liveText || ''), (liveText || '').slice(0, 80));

    // KPI と API の突き合わせ
    const kpis = await page.$$eval('.kpi', (ns) => ns.map((n) => ({ l: n.querySelector('.label').textContent, v: n.querySelector('.value').textContent })));
    const kv = Object.fromEntries(kpis.map((k) => [k.l, k.v]));
    const c = (ov && ov.counts) || {};
    const kpiOk = ov && kv['稼働中 run'] === String(c.runs_active) && kv['承認待ち'] === String(c.approval_pending)
      && kv['マージ確認済み'] === String(c.merged) && kv['BLOCKED / FAILED'] === String(c.blocked_or_failed);
    record('KPI = API', !!kpiOk, JSON.stringify(kv));

    // run 表の行数
    const runs = await getJson('/api/ship/runs');
    const rowCount = await page.$$eval('#runs-table tbody tr', (r) => r.length).catch(() => 0);
    const nRuns = runs && Array.isArray(runs.runs) ? runs.runs.length : -1;
    const emptyShown = (await page.textContent('#runs-table')).includes('データなし');
    record('run 表 = API', nRuns === 0 ? emptyShown : rowCount === nRuns, `DOM ${rowCount} 行 / API ${nRuns} 件`);

    // パイプライン: STATES 全件 + 現在状態の強調
    const liCount = await page.$$eval('#pipeline-list li', (l) => l.filter((x) => !/選択中の run なし/.test(x.textContent)).length);
    const cur = await page.$$eval('#pipeline-list li.current', (l) => l.map((x) => x.textContent));
    const first = nRuns > 0 ? runs.runs[0].state : null;
    record('パイプライン', ov && liCount === ov.states.length && (first ? cur[0] === first : cur.length === 0), `状態 ${liCount} / 現在 ${cur[0] || 'なし'}`);

    // 承認ボタンが無い・CLI コマンドの説明がある
    const approveBtn = await page.$$eval('button', (bs) => bs.filter((b) => /^\s*承認(する)?\s*$/.test(b.textContent || '')).length);
    const notice = await page.textContent('#approval .notice');
    record('承認ボタンなし', approveBtn === 0 && /証明できません/.test(notice || ''), `承認ボタン ${approveBtn} 個`);
    if (c.approval_pending > 0) {
      const cmd = await page.textContent('#pending');
      record('承認コマンド表示', /bin\/ship-approve\.sh approve --repo \S+ --pr \d+ --head [0-9a-f]{40}/.test(cmd || ''), (cmd || '').slice(0, 100));
    }

    // 監査チェーン
    const au = await getJson('/api/ship/audit?limit=50');
    const chainText = await page.textContent('#chain');
    record('監査チェーン', au && (au.chain.ok ? /整合 OK/.test(chainText) : /不整合/.test(chainText)), chainText.trim());
    await page.screenshot({ path: path.join(OUT_DIR, 'overview.png'), fullPage: true });

    // ダーク切り替え (保存される)
    await page.click('#theme-toggle');
    const theme = await page.evaluate(() => [document.documentElement.getAttribute('data-theme'), localStorage.getItem('claudeos.ship.theme')]);
    record('ダーク切り替え', theme[0] === 'dark' && theme[1] === 'dark', theme.join(','));
    await page.screenshot({ path: path.join(OUT_DIR, 'dark.png'), fullPage: true });

    const unexpected = errors.filter((e) => !/net::ERR_|Failed to load resource/i.test(e));
    record('console error', unexpected.length === 0, unexpected.length ? unexpected[0].slice(0, 120) : 'なし');
  } catch (e) {
    record('実行', false, String((e && e.message) || e).slice(0, 200));
  } finally {
    await browser.close();
  }
  const failed = results.filter((r) => !r.ok);
  fs.writeFileSync(path.join(OUT_DIR, 'result.json'), JSON.stringify({ base: BASE, at: new Date().toISOString(), results, failed: failed.length }, null, 2));
  console.log(`\n${results.length - failed.length}/${results.length} PASS  -> ${OUT_DIR}`);
  process.exit(failed.length ? 1 : 0);
})();
