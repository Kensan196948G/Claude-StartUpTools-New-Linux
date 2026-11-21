'use strict';
/* ============================================================
   console-v2.test.js — 統合コンソール (WebUI2 artifact) の静的検査

   この UI は Anthropic design-component 形式の単一 HTML で、画面と
   コンポーネント本体は <script type="__bundler/template"> に JSON 文字列として
   入っている。ここでは「実データに繋がっていること」を静的に固定する。
   (見た目・操作の実検証はブラウザで行い、この検査は退行の早期検出が目的)
   ============================================================ */
const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');

const FILE = path.join(__dirname, 'public', 'v2.html');

function loadTemplate() {
  const raw = fs.readFileSync(FILE, 'utf8');
  const m = raw.match(/<script type="__bundler\/template">([\s\S]*?)<\/script>/);
  assert.ok(m, '__bundler/template ブロックが見つからない');
  return { raw, tpl: JSON.parse(m[1]) };
}

test('v2.html: template ブロックが JSON として読める', () => {
  const { tpl } = loadTemplate();
  assert.ok(tpl.length > 100000, 'template が想定より小さい');
  assert.ok(tpl.includes('class Component extends DCLogic'));
});

test('v2.html: 実データ取得の橋渡しがある', () => {
  const { tpl } = loadTemplate();
  assert.ok(tpl.includes('refreshLive()'), 'refreshLive が無い');
  assert.ok(tpl.includes('/api/startup/state'), 'state API を参照していない');
  assert.ok(tpl.includes('/api/startup/audit'), 'audit API を参照していない');
  assert.ok(tpl.includes('livePost('), 'livePost が無い');
});

test('v2.html: 起動系の操作が実 API を叩く (見せかけのタイマーではない)', () => {
  const { tpl } = loadTemplate();
  assert.ok(tpl.includes("'/api/startup/plan'"), 'plan API を叩いていない');
  assert.ok(tpl.includes("'/api/startup/launch'"), 'launch API を叩いていない');
  assert.ok(tpl.includes("'/api/startup/stop'"), 'stop API を叩いていない');
  // 計画は以前 this.later(750, ...) で偽装していた。その残骸が無いことを固定する。
  assert.ok(!tpl.includes("this.later(750, () => this.setState({ busy: '', planKey: key, planText: lines.join"),
    '計画の偽装タイマーが残っている');
});

test('v2.html: プロジェクト一覧は実データを優先する', () => {
  const { tpl } = loadTemplate();
  assert.ok(tpl.includes('this.state.realProjects'), 'realProjects を参照していない');
});

test('v2.html: 取得前はサンプル名を出さず「取得中」を表示する', () => {
  const { tpl } = loadTemplate();
  // 設計時のサンプル一覧 (22 件) を初期描画に使うと、空環境でも件数が実データと食い違う。
  assert.ok(!tpl.includes('ArcSphere3D'), 'サンプル一覧のフォールバックが残っている');
  assert.ok(tpl.includes('取得中'), '取得中の表示が無い');
  assert.ok(tpl.includes('projCountText'), '件数の表示が読み込み状態を考慮していない');
});

test('v2.html: 「サンプルデータ · 実起動しません」という誤った表示が無い', () => {
  const { tpl } = loadTemplate();
  assert.ok(!tpl.includes('サンプルデータ · 実起動しません'),
    '実データ接続後もサンプル表示が残っている');
});
