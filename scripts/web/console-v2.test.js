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

test('v2.html: Cron 表示 — リダイレクト除去・時刻の * 保持・曜日範囲の展開 (実コードを実行)', () => {
  const { tpl } = loadTemplate();
  const start = tpl.indexOf('CRON.entries.map(');
  const end = tpl.indexOf('\n      : s.cron.map');
  assert.ok(start > 0 && end > start, 'cron 変換ブロックが見つからない');
  const build = new Function('CRON', 'return ' + tpl.slice(start, end));
  const rows = build({ entries: [
    { disabled: false, minute: '0', hour: '2', dow: '*', command: 'bash /opt/run-claude.sh --project Foo >> /tmp/foo.log 2>&1' },
    { disabled: false, minute: '*/5', hour: '*', dow: '1-5', command: '/opt/health-probe.sh >/dev/null 2>&1' },
    { disabled: true, minute: '30', hour: '3', dow: 'mon-wed,sun', command: 'monitor.sh' },
  ] });
  assert.equal(rows[0].project, 'Foo', '末尾の 2>&1 / ログ出力先ではなく対象名を出す');
  assert.equal(rows[0].time, '02:00');
  assert.equal(rows[1].project, 'health-probe.sh');
  assert.equal(rows[1].time, '*:*/5', '* を 0 埋めして 0* にしない');
  assert.deepEqual(rows[1].dow, [1, 2, 3, 4, 5], '1-5 は月〜金へ展開する');
  assert.equal(rows[2].project, 'monitor.sh（無効）');
  assert.deepEqual(rows[2].dow, [1, 2, 3, 0], 'mon-wed,sun を展開する');
});

test('v2.html: 背景起動の通知は tmux attach ではなく supervisor ログ追従を案内する', () => {
  const { tpl } = loadTemplate();
  // 単一起動 / 複数起動の通知とも、mode === background のとき tail を案内し、それ以外は従来どおり tmux attach
  const single = tpl.indexOf("mode0 === 'background' ? '監視: tail -f ~/.claudeos/supervisor/'");
  const multi = tpl.indexOf("mode === 'background' ? '監視: tail -f ~/.claudeos/supervisor/'");
  assert.ok(single > 0, '単一起動の通知が背景モードを区別していない');
  assert.ok(multi > 0, '複数起動の通知が背景モードを区別していない');
  assert.ok(tpl.includes('背景実行は tmux を使いません'));
  assert.ok(tpl.includes("'claudeos-team-' : 'claudeos-'"), 'tmux 系モードの案内が消えている');
});

test('v2.html: 要求欄は「指示文としては渡されない」ことを明記する', () => {
  const { tpl } = loadTemplate();
  assert.ok(tpl.includes('Claude への指示文としては渡されません'));
  assert.ok(!tpl.includes('Goal Router の Evidence になります'), '旧文言が残っている');
});

test('v2.html: 起動失敗はサーバーの日本語 message を生コードより優先して表示する', () => {
  const { tpl } = loadTemplate();
  assert.ok(tpl.includes('r.message || r.error || r.stderr'), 'message を優先していない');
});

test('v2.html: 起動画面のプロジェクト一覧に「再読み込み」があり、キャッシュを捨てる API を呼ぶ', () => {
  const { tpl } = loadTemplate();
  assert.ok(tpl.includes('sc-camel-on-click="{{ reloadProjects }}"'), '再読み込みボタンが無い');
  assert.ok(tpl.includes('disabled="{{ reloadDisabled }}"'), '読み込み中の無効化が無い');
  assert.ok(tpl.includes('reloadProjects() {'), 'reloadProjects メソッドが無い');
  assert.ok(tpl.includes("/api/startup/state?refresh=1"), 'refresh=1 を指定していない');
  assert.ok(tpl.includes('projReloading: false'), '状態の初期値が無い');
  assert.ok(!tpl.includes('\\u002F'), '"\\u002F" がテンプレート内で二重にエスケープされていない');
});

test('v2.html: 起動通知の tmux 名は ccsu_safe_name と同じ規則 (サブフォルダの / を _ にする)', () => {
  const { execFileSync } = require('node:child_process');
  const { tpl } = loadTemplate();
  const m = /safeName\(x\) \{ return [^\n]*? \}\n/.exec(tpl);
  assert.ok(m, 'safeName が見つからない');
  const safeName = new Function('x', m[0].replace(/^safeName\(x\) \{/, '').replace(/\}\n$/, ''));
  for (const name of ['Alpha-App', 'Business-Project/AI-Company-Control-Center', 'みらい/Project 1']) {
    const bash = execFileSync('bash', ['-c', 'source "$1/lib/common.sh"; ccsu_safe_name "$2"', '_', path.join(__dirname, '..', '..'), name], { encoding: 'utf8' });
    assert.equal(safeName(name), bash, name);
  }
  // 案内文は生の名前ではなく safeName を使う
  assert.ok(tpl.includes("'claudeos-') + this.safeName(sel0)"), '単一起動の tmux 名が safeName を使っていない');
  assert.ok(tpl.includes("'claudeos-') + this.safeName(started[0])"), '複数起動の tmux 名が safeName を使っていない');
});

test('v2.html: セッション一覧はサーバーの実状態 (state.sessions) から作る (宣言順ごと実コードを実行)', () => {
  const { tpl } = loadTemplate();
  const a = tpl.indexOf('const folders = Array.isArray(s0.all_folders)');
  const b = tpl.indexOf('/*ss-end*/');
  assert.ok(a > 0 && b > a, 'セッション変換ブロックが見つからない');
  // folders / registered の構築から変換ブロックまでを丸ごと実行する (TDZ: registered より前に参照しない)
  const code = tpl.slice(a, b);
  assert.ok(code.indexOf('const registered') < code.indexOf('/*ss-start*/'), 'registered の宣言が変換ブロックより後ろにある');
  const safeName = (x) => String(x).replace(/[^A-Za-z0-9_-]/g, '_');
  const build = new Function('s0', code + '\nreturn realSessions;');
  const rows = build.call({ safeName }, {
    all_folders: ['Business-Project/AI-Company-Control-Center', 'Alpha-App'],
    projects: [{ name: 'Alpha-App' }],
    sessions: {
      tmux: ['claudeos-Business-Project_AI-Company-Control-Center', 'claudeos-team-Alpha-App', 'claudeos-unknown_x'],
      headless: ['Alpha-App'], foreground: ['Alpha-App'] } });
  const by = Object.fromEntries(rows.map(r => [r.project, r.mode]));
  assert.equal(by['Business-Project/AI-Company-Control-Center'], 'foreground', 'tmux 名 (_ 置換) から実プロジェクト名へ戻す');
  assert.equal(by['Alpha-App'], 'background', '同一プロジェクトは 1 件 (先勝ち)');
  assert.equal(by['unknown_x'], 'foreground', '解決できない名前はそのまま出す');
  assert.equal(rows.length, 3);
  // サーバーが何も返さなければ 0 件 (起動ボタンのローカル追加に依存しない)
  assert.deepEqual(build.call({ safeName }, { all_folders: [], projects: [], sessions: { tmux: [], headless: [], foreground: [] } }), []);
  assert.deepEqual(build.call({ safeName }, {}), []);
  assert.ok(tpl.includes('realProjects: folders, sessions: realSessions,'), 'refreshLive が sessions を更新していない');
});

test('v2.html: セッション画面はライブログを表示し、送信は見せかけの応答を返さない', () => {
  const { tpl } = loadTemplate();
  assert.ok(tpl.includes('ライブログ（読み取り専用・3 秒ごとに更新）'), 'ライブログのカードが無い');
  assert.ok(tpl.includes('{{ pLive }}'));
  assert.ok(tpl.includes("/api/startup/log?project="), 'ログ API を参照していない');
  assert.ok(tpl.includes('this._logTimer = setInterval'), 'ライブログのポーリングが無い');
  assert.ok(tpl.includes('if (this._logTimer) clearInterval(this._logTimer);'), 'アンマウント時に停止していない');
  assert.ok(!tpl.includes('の Claude Code がこのプロンプトを受け取り'), 'セッション画面のプロトタイプ固定応答が残っている');
  assert.ok(tpl.includes('プロンプト送信は未接続です'), '送信が未接続であることを明示していない');
  assert.ok(!tpl.includes('プロンプトを送り、応答をストリーミングで確認します'), '旧い見出し説明が残っている');
});

test('v2.html: 同時実行の上限は固定の 4 ではなく state.limits.max_sessions を使う', () => {
  const { tpl } = loadTemplate();
  assert.ok(tpl.includes('s0.limits.max_sessions'), 'サーバーの上限を読んでいない');
  assert.ok(tpl.includes('{{ maxSessions }}'), 'ヘッダの上限が固定のまま');
  assert.ok(tpl.includes('s.sessions.length >= (s.maxSessions || 4)'), '起動の事前判定が固定のまま');
  assert.ok(!tpl.includes('s.sessions.length >= 4)'), '旧い固定判定が残っている');
});
