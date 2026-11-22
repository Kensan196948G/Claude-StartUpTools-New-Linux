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

function loadErrText(tpl) {
  const a = tpl.indexOf('/*et-start*/errText(r, fallback) {');
  const b = tpl.indexOf('}/*et-end*/');
  assert.ok(a > 0 && b > a, 'errText が見つからない');
  return new Function('r', 'fallback', tpl.slice(a + '/*et-start*/errText(r, fallback) {'.length, b));
}

test('v2.html: エラー表示 (実コードを実行) — サーバーの message を優先し、生コードは日本語へ、未知のコードはそのまま出す', () => {
  const { tpl } = loadTemplate();
  const errText = loadErrText(tpl);
  assert.equal(errText({ error: 'START_NOT_CONFIRMED', message: 'supervisor を確認できませんでした' }, 'x'), 'supervisor を確認できませんでした', 'message を最優先');
  assert.match(errText({ error: 'DURATION_OVER_LIMIT' }, 'x'), /上限/, '生コード DURATION_OVER_LIMIT を出さない');
  assert.ok(!/DURATION_OVER_LIMIT/.test(errText({ error: 'DURATION_OVER_LIMIT' }, 'x')));
  assert.match(errText({ error: 'NOT_RUNNING' }, 'x'), /稼働していません/);
  assert.match(errText({ error: 'HOST_REJECTED' }, 'x'), /STARTUP_WEB_ALLOWED_HOSTS/);
  assert.equal(errText({ error: 'SOMETHING_NEW' }, 'x'), 'SOMETHING_NEW', '未知のコードは握りつぶさずそのまま出す');
  assert.equal(errText({ ok: false, exitCode: 1, stderr: 'boom\n' }, 'x'), 'boom', 'コード無しは stderr');
  assert.match(errText({ error: 'START_FAILED', stderr: 'no tmux' }, 'x'), /起動に失敗.*no tmux/, '既知コードは日本語に stderr を添える');
  assert.equal(errText(null, '既定の文言'), '既定の文言');
  assert.equal(errText({ error: 'X', message: 'y'.repeat(900) }, 'x').length, 400, '長すぎる文言は切り詰める');
});

test('v2.html: 左メニューで画面を移動したら、前の画面のエラーバナーを消す', () => {
  const { tpl } = loadTemplate();
  assert.ok(tpl.includes('go[k] = () => this.setState({ screen: k, notice: null });'));
});

function runStop(tpl, response) {
  const a = tpl.indexOf('/*stop-start*/');
  const b = tpl.indexOf('/*stop-end*/');
  assert.ok(a > 0 && b > a, 'stop の本体が見つからない');
  const body = tpl.slice(a + '/*stop-start*/'.length, b);
  const calls = { post: null, patch: null, refreshed: 0 };
  const fake = {
    state: { sessions: [{ project: 'Alpha' }, { project: 'Beta' }], logFor: 'Alpha' },
    livePost(url, payload) { calls.post = { url, payload }; return Promise.resolve(response); },
    errText: loadErrText(tpl),
    logged(op, p, r) { return [op, p, r]; },
    setState(p) { calls.patch = p; },
    refreshLive() { calls.refreshed++; },
  };
  const run = new Function('project', 'now', 'after', 'return ' + body);
  return run.call(fake, 'Alpha', true, '').then(() => calls);
}

test('v2.html: 停止ボタンは confirm:true と force を送り、サーバーが停止を実行したときだけ「停止しました」と表示する (実コードを実行)', async () => {
  const { tpl } = loadTemplate();
  const ok = await runStop(tpl, { ok: true, exitCode: 0 });
  assert.equal(ok.post.url, '/api/startup/stop');
  assert.deepEqual(ok.post.payload, { project: 'Alpha', force: true, confirm: true }, 'now ではなく force、かつ confirm:true を送る');
  assert.equal(ok.patch.notice.tone, 'ok');
  assert.deepEqual(ok.patch.sessions.map((x) => x.project), ['Beta'], '成功時だけ一覧から外す');
  assert.equal(ok.refreshed, 1);
  // 以前の不具合: サーバーは confirm 無しだと確認待ち (ok:true, requiresConfirm:true) を返すだけで何も停止しない。成功と表示してはいけない
  const pending = await runStop(tpl, { ok: true, requiresConfirm: true });
  assert.equal(pending.patch.notice.tone, 'err', '確認待ちの応答を成功扱いにしない');
  assert.equal(pending.patch.sessions, undefined, '停止していないのに一覧から外さない');
  const dry = await runStop(tpl, { ok: true, requiresConfirm: true, dryRunOnly: true });
  assert.match(dry.patch.notice.text, /DRY-RUN ONLY/, 'DRY-RUN ONLY のときは専用の文言');
  const nr = await runStop(tpl, { ok: false, error: 'NOT_RUNNING' });
  assert.equal(nr.patch.notice.tone, 'err');
  assert.match(nr.patch.notice.text, /稼働していません/);
  assert.equal(nr.patch.sessions, undefined);
});

test('v2.html: Cron の「プロジェクト」列 (実コードを実行) — /Projects/ 配下の実パス・--project・妥当な末尾だけ。14 や * や +%Y… を出さない', () => {
  const { tpl } = loadTemplate();
  const start = tpl.indexOf('CRON.entries.map(');
  const end = tpl.indexOf('\n      : s.cron.map');
  const build = new Function('CRON', 'all', 'return ' + tpl.slice(start, end));
  const mk = (command, disabled) => ({ disabled: !!disabled, minute: '0', hour: '1', dow: '*', command });
  const rows = build({ entries: [
    mk('/home/kensan/Projects/Mirai-DX-Project/MIRAI_Site_Carbon_Navigator/scripts/backup_cron.sh >> /home/kensan/Projects/Mirai-DX-Project/MIRAI_Site_Carbon_Navigator/logs/backup_cron.log 2>&1'),
    mk('/home/kensan/Projects/DX-Project-Portfolio-Atlas/scripts/backup.sh >> /home/kensan/Projects/DX-Project-Portfolio-Atlas/backups/backup-cron.log 2>&1'),
    mk('docker run --rm -v /home/kensan/.ceop/backups:/backups ceop-platform:current node --experimental-strip-types scripts/backup-retention.ts /backups --keep-days 14'),
    mk('rm -rf ~/.claude/cache/*', true),
    mk('CEOP_HEALTH_URL=https://x.example/healthz /home/kensan/Projects/Mirai-DX-Project/Construction-Enterprise-Operating-Platform/scripts/health-probe.sh'),
    mk('bash /opt/run-claude.sh --project Foo >> /tmp/foo.log 2>&1'),
    mk('/home/kensan/ops/memory-guard.sh'),
  ] }, ['Mirai-DX-Project/MIRAI_Site_Carbon_Navigator', 'DX-Project-Portfolio-Atlas']);
  assert.equal(rows[0].project, 'Mirai-DX-Project/MIRAI_Site_Carbon_Navigator', '登録済みプロジェクト名と一致');
  assert.equal(rows[1].project, 'DX-Project-Portfolio-Atlas');
  assert.equal(rows[2].project, 'docker', '末尾の 14 ではなく実行するコマンド');
  assert.equal(rows[3].project, 'rm（無効）', '末尾の * ではなくコマンド名');
  assert.equal(rows[4].project, 'Mirai-DX-Project/Construction-Enterprise-Operating-Platform', '未登録でも /Projects/ 配下の実パス (scripts より前)');
  assert.equal(rows[5].project, 'Foo', '--project の引数');
  assert.equal(rows[6].project, 'memory-guard.sh');
  // レビュー指摘: -p は --project だけに限定 / 末尾トークン (/backups など) は採用せず先頭の実コマンドを出す / インタープリタは飛ばす
  const rows2 = build({ entries: [
    mk('pg_dump -p 5432 mydb > /tmp/x.sql'),
    mk('docker run --rm ceop-platform:current node scripts/backup-retention.ts /backups'),
    mk('bash /opt/run-claude.sh'),
  ] }, []);
  assert.equal(rows2[0].project, 'pg_dump', '-p 5432 をプロジェクト名にしない');
  assert.equal(rows2[1].project, 'docker', '末尾の /backups をプロジェクト名にしない');
  assert.equal(rows2[2].project, 'run-claude.sh', 'bash は飛ばして実行するスクリプトを出す');
});

test('v2.html: tmux セッション名は ccsu_safe_name と同じ規則 (表示・役割別セッションも safeName 経由)', () => {
  const { tpl } = loadTemplate();
  assert.ok(!tpl.includes("'claudeos-' + x.project + '-"), '役割別セッション名が生の project 名を使っている');
  assert.ok(!tpl.includes("'tmux attach -t claudeos-team-' + x.project"), 'attach 案内が生の project 名を使っている');
  assert.ok(!tpl.includes(": 'claudeos-') + x.project"), 'セッション名が生の project 名を使っている');
  assert.ok(!tpl.includes(": 'claudeos-') + s.selected"), '選択中の接続案内が生の名前を使っている');
  assert.ok(tpl.includes("'claudeos-team-' : 'claudeos-') + this.safeName(x.project)"));
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
  assert.ok(!tpl.includes('プロンプト送信は未接続です'), '未接続の通知が残っている (実送信に置き換わっている)');
  assert.ok(!tpl.includes('プロンプトを送り、応答をストリーミングで確認します'), '旧い見出し説明が残っている');
});

test('v2.html: 同時実行の上限は固定の 4 ではなく state.limits.max_sessions を使う', () => {
  const { tpl } = loadTemplate();
  assert.ok(tpl.includes('s0.limits.max_sessions'), 'サーバーの上限を読んでいない');
  assert.ok(tpl.includes('{{ maxSessions }}'), 'ヘッダの上限が固定のまま');
  assert.ok(tpl.includes('s.sessions.length >= (s.maxSessions || 4)'), '起動の事前判定が固定のまま');
  assert.ok(!tpl.includes('s.sessions.length >= 4)'), '旧い固定判定が残っている');
});

test('v2.html: プロンプト送信は確認ダイアログを通して /api/session/prompt へ NDJSON で送り、中断できる', () => {
  const { tpl } = loadTemplate();
  assert.ok(tpl.includes("this.livePost('/api/session/prompt', { project: proj, text: text, model: model })"), '確認用の事前リクエスト (confirm 無し) が無い');
  assert.ok(tpl.includes('this.ask('), '送信前の確認ダイアログを通っていない');
  assert.ok(tpl.includes('confirm: true'), '確認後の実送信に confirm:true が無い');
  assert.ok(tpl.includes("accept: 'application/x-ndjson'") && tpl.includes('r.body.getReader()'), 'NDJSON を逐次読んでいない');
  assert.ok(tpl.includes('new AbortController()') && tpl.includes('this._pAbort.abort()'), '中断 (切断) の仕組みが無い');
  assert.ok(tpl.includes('!!pRunSess'), '稼働中セッションへの送信を無効化していない');
  assert.ok(tpl.includes('id=\\"f-ppick\\"') || tpl.includes('f-ppick'), '停止中プロジェクトの指定欄が無い');
  assert.ok(tpl.includes('curPromptTarget()'), '送信先の解決が共通化されていない');
});

test('v2.html: ストリームイベントの反映 (実コードを実行): 部分テキスト・ツール・結果・終了・エラー', () => {
  const { tpl } = loadTemplate();
  const a = tpl.indexOf('/*pe-start*/');
  const b = tpl.indexOf('/*pe-end*/');
  assert.ok(a > 0 && b > a, 'promptApply が見つからない');
  const apply = new Function('m', 'ev', tpl.slice(a + '/*pe-start*/'.length, b));
  const run = (evs) => evs.reduce((m, ev) => apply(m, ev), { id: 'a1', role: 'assistant', text: '', events: [], streaming: true });
  const delta = (text) => ({ type: 'stream_event', event: { type: 'content_block_delta', delta: { type: 'text_delta', text } } });

  // 部分テキスト (--include-partial-messages): 逐次連結し、最終の assistant で二重にならない
  let m = run([
    { type: 'web/start', resumed: true, forked: true },
    { type: 'system', subtype: 'init', session_id: 's' },
    { type: 'stream_event', event: { type: 'message_start' } },
    delta('He'), delta('llo'),
    { type: 'assistant', message: { content: [{ type: 'text', text: 'Hello' }, { type: 'tool_use', name: 'Bash' }] } },
    { type: 'user', message: { content: [{ type: 'tool_result' }] } },
    { type: 'stream_event', event: { type: 'message_start' } },
    delta('Done'),
    { type: 'assistant', message: { content: [{ type: 'text', text: 'Done' }] } },
    { type: 'result', subtype: 'success', total_cost_usd: 0.0123 },
    { type: 'web/raw', text: 'raw line' },
    { type: 'web/end', exitCode: 0, signal: null, timedOut: false, aborted: false },
  ]);
  assert.equal(m.text, 'Hello\n\nDone', '部分テキストは連結し、最終メッセージで二重にしない');
  assert.equal(m.streaming, false);
  assert.equal(m.stopped, false);
  assert.ok(m.events.some(e => e.label === 'start' && e.detail.includes('分岐')));
  const tool = m.events.find(e => e.label === 'tool_use');
  assert.equal(tool.detail, 'Bash');
  assert.equal(tool.done, true, 'tool_result で完了にする');
  assert.ok(m.events.some(e => e.label === 'result' && e.detail.includes('$0.0123') && e.after === true));
  assert.ok(m.events.every(e => e.done === true), '終了時は全イベントを完了にする');

  // 部分テキストが無い (--include-partial-messages 非対応) 場合は assistant の本文を使う
  m = run([{ type: 'assistant', message: { content: [{ type: 'text', text: 'A' }] } }, { type: 'assistant', message: { content: [{ type: 'text', text: 'B' }] } }]);
  assert.equal(m.text, 'A\n\nB');

  // 異常終了 / タイムアウト / 中断
  m = run([{ type: 'web/end', exitCode: 3, stderr: 'boom', timedOut: false, aborted: false }]);
  assert.equal(m.streaming, false);
  assert.ok(m.events.some(e => e.label === 'exit 3' && e.detail === 'boom'));
  assert.match(m.text, /エラーで終了/);
  m = run([{ type: 'web/end', exitCode: null, signal: 'SIGTERM', timedOut: true, aborted: false }]);
  assert.match(m.text, /時間上限/);
  m = run([{ type: 'web/end', exitCode: null, signal: 'SIGTERM', timedOut: false, aborted: true }]);
  assert.equal(m.stopped, true);
  // 入力を壊さない (純粋関数)
  const orig = { text: 'x', events: [] };
  apply(orig, { type: 'web/raw', text: 'y' });
  assert.deepEqual(orig, { text: 'x', events: [] });
});

test('v2.html: web/end の追加ケース (シグナル終了・系譜の破棄・中断は誤ってエラー表示しない) と新しいエラー文言', () => {
  const { tpl } = loadTemplate();
  const a = tpl.indexOf('/*pe-start*/');
  const b = tpl.indexOf('/*pe-end*/');
  const apply = new Function('m', 'ev', tpl.slice(a + '/*pe-start*/'.length, b));
  const base = { text: '', events: [], streaming: true };
  let m = apply(base, { type: 'web/end', exitCode: null, signal: 'SIGKILL', timedOut: false, aborted: false });
  assert.ok(m.events.some(e => e.label === 'signal SIGKILL'), 'シグナルで終了した場合も表示する (吹き出しが空のまま消えない)');
  assert.match(m.text, /エラーで終了/);
  m = apply(base, { type: 'web/end', exitCode: 1, lineageReset: true, stderr: 'x' });
  assert.ok(m.events.some(e => e.label === 'session' && e.detail.includes('破棄')), '履歴を破棄したことを知らせる');
  m = apply(base, { type: 'web/end', exitCode: null, signal: 'SIGTERM', aborted: true });
  assert.equal(m.stopped, true);
  assert.ok(!m.events.some(e => String(e.label).startsWith('signal')), '利用者が中断した場合はエラー扱いにしない');
  ['PROMPT_DISABLED', 'PROMPT_AUTH_NOT_CONFIGURED', 'PROMPT_AUTH_FAILED', 'HOST_REJECTED', 'ORIGIN_REQUIRED', 'CROSS_SITE_REJECTED', 'CLAUDE_UNAVAILABLE', 'PROMPT_IN_PROGRESS']
    .forEach((k) => assert.ok(tpl.includes(k + ':'), k + ' の日本語メッセージが無い'));
  assert.ok(tpl.includes("let cur = { id: aid, role: 'assistant'"), '1 メッセージ分をローカルに蓄積していない');
});

test('v2.html: 権限モードの表記は固定の「auto」や「自律実行と同じ権限」にしない (サーバー設定を確認画面で示す)', () => {
  const { tpl } = loadTemplate();
  assert.ok(!tpl.includes('permission-mode: auto'), '固定の auto 表記が残っている');
  assert.ok(!tpl.includes('自律実行と同じ権限'), '実態と異なる「自律実行と同じ権限」が残っている');
  assert.ok(tpl.includes('権限モードはサーバー設定'));
});

test('v2.html: Cron 登録 / Systemd 起動・停止・自動起動は「計画のみ」(実コードを実行) — 実行したように見せず、サーバーの dry-run 出力を表示する', async () => {
  const { tpl } = loadTemplate();
  const a = tpl.indexOf('/*op-start*/opsPlan(op, project, extra) {');
  const b = tpl.indexOf('}/*op-end*/');
  assert.ok(a > 0 && b > a, 'opsPlan が見つからない');
  const body = tpl.slice(a + '/*op-start*/opsPlan(op, project, extra) {'.length, b);
  const run = (resp, op, project, extra) => {
    const calls = { post: null, patch: null };
    const fake = {
      state: { sdOut: 'old' },
      livePost(url, payload) { calls.post = { url, payload }; return Promise.resolve(resp); },
      errText: loadErrText(tpl),
      logged(o, p, r) { return [o, p, r]; },
      setState(p) { calls.patch = p; },
    };
    return new Function('op', 'project', 'extra', body).call(fake, op, project, extra).then(() => calls);
  };
  const ok = await run({ ok: true, command: 'bash bin/systemd-control.sh stop Foo --dry-run', plan: '[dry-run] systemctl --user stop x', stderr: '' }, 'systemd-stop', 'Foo');
  assert.equal(ok.post.url, '/api/ops/plan');
  assert.deepEqual(ok.post.payload, { op: 'systemd-stop', project: 'Foo' }, '実行 API ではなく計画 API を叩く');
  assert.match(ok.patch.notice.text, /^【計画のみ・何も変更していません】/);
  assert.match(ok.patch.notice.text, /\[dry-run\] systemctl --user stop x/);
  assert.equal(ok.patch.notice.tone, 'ok');
  assert.match(ok.patch.sdOut, /dry-run/, 'systemd は出力欄にも表示する');
  const cli = await run({ ok: false, command: 'bash bin/cron-schedule.sh add ... --dry-run', plan: '', stderr: '月曜は登録上限を超えます' }, 'cron-add', 'Foo', { time: '21:00' });
  assert.deepEqual(cli.post.payload, { op: 'cron-add', project: 'Foo', time: '21:00' });
  assert.equal(cli.patch.notice.tone, 'warn', 'CLI の検証エラーも計画の結果として表示する');
  assert.match(cli.patch.notice.text, /月曜は登録上限/);
  assert.equal(cli.patch.sdOut, 'old', 'cron のときは systemd 出力欄を触らない');
  const rej = await run({ ok: false, error: 'PROJECT_NOT_REGISTERED' }, 'systemd-start', 'x');
  assert.match(rej.patch.notice.text, /台帳.*に無いため、計画を作れません/, 'systemd の管理外 unit は理由と対処を示す');
  assert.match(rej.patch.notice.text, /systemctl --user/);
  const rej2 = await run({ ok: false, error: 'PROJECT_NOT_REGISTERED' }, 'cron-add', 'x');
  assert.match(rej2.patch.notice.text, /登録されていません/, 'Cron など他の操作の検証エラーは従来どおり日本語で表示する');
  assert.ok(tpl.includes("this.opsPlan(op.replace(' ', '-'), String(name).replace(/^claudeos-/, '').replace(/\\.service$/, ''))"), 'unit 名 → プロジェクト名の変換');
  assert.ok(tpl.includes("this.opsPlan('cron-add', s.cfProject"), 'Cron 登録が計画 API を使う');
});

test('v2.html: Systemd 再起動は「計画 → 確認 → 実行」の二段階 (実コードを実行) — 1 回目は実行せず、30 秒以内の 2 回目だけ実行する', async () => {
  const { tpl } = loadTemplate();
  const a = tpl.indexOf('/*rs-start*/sdRestart(unit) {');
  const b = tpl.indexOf('}/*rs-end*/');
  assert.ok(a > 0 && b > a, 'sdRestart が見つからない');
  const body = tpl.slice(a + '/*rs-start*/sdRestart(unit) {'.length, b);
  const make = (planTone, resp, st) => {
    const calls = { plan: [], post: [] };
    const fake = {
      state: Object.assign({ sdArm: '', sdArmAt: 0, notice: null }, st || {}),
      opsPlan(op, proj) { calls.plan.push([op, proj]); this.state.notice = { tone: planTone, text: 'plan' }; return Promise.resolve(); },
      livePost(url, payload) { calls.post.push({ url, payload }); return Promise.resolve(resp); },
      errText: loadErrText(tpl),
      logged(o, p, r) { return [o, p, r]; },
      setState(p) { Object.assign(this.state, p); },
    };
    return { fake, calls, run: (unit) => new Function('unit', body).call(fake, unit) };
  };
  // 1 回目: 計画のみ。実行 API は呼ばず、確認待ちにする
  const t1 = make('ok', { ok: true });
  await t1.run('claudeos-Foo.service');
  assert.deepEqual(t1.calls.plan, [['systemd-restart', 'Foo']], 'unit 名 → プロジェクト名');
  assert.equal(t1.calls.post.length, 0, '1 回目は実行しない');
  assert.equal(t1.fake.state.sdArm, 'claudeos-Foo.service');
  // 計画が取れなかった (管理外 unit など) ときは確認待ちにしない
  const t0 = make('warn', { ok: true });
  await t0.run('claude-startuptools-ttyd.service');
  assert.equal(t0.fake.state.sdArm, '', '計画に失敗したら 2 回目でも実行へ進めない');
  // 2 回目 (30 秒以内・同じ unit): 実行
  const t2 = make('ok', { ok: true, output: 'restart ok' }, { sdArm: 'claudeos-Foo.service', sdArmAt: Date.now() - 1000 });
  await t2.run('claudeos-Foo.service');
  assert.deepEqual(t2.calls.post, [{ url: '/api/ops/systemd/restart', payload: { project: 'Foo', confirm: true } }]);
  assert.equal(t2.calls.plan.length, 0);
  assert.equal(t2.fake.state.sdArm, '', '実行後は確認待ちを解除');
  assert.match(t2.fake.state.notice.text, /再起動しました/);
  assert.equal(t2.fake.state.notice.tone, 'ok');
  // 別の unit / 30 秒超過は、確認待ちとして扱わず計画から
  const t3 = make('ok', { ok: true }, { sdArm: 'claudeos-Foo.service', sdArmAt: Date.now() - 1000 });
  await t3.run('claudeos-Bar.service');
  assert.equal(t3.calls.post.length, 0, '別の unit は実行しない');
  const t4 = make('ok', { ok: true }, { sdArm: 'claudeos-Foo.service', sdArmAt: Date.now() - 31000 });
  await t4.run('claudeos-Foo.service');
  assert.equal(t4.calls.post.length, 0, '30 秒を過ぎたら計画からやり直す');
  // サーバーの拒否・失敗は日本語で表示する (成功扱いにしない)
  for (const [resp, re] of [[{ ok: false, error: 'OPS_DISABLED' }, /無効です/], [{ ok: false, error: 'OPS_AUTH_FAILED' }, /認証に失敗/],
    [{ ok: false, error: 'OPS_TARGET_PROTECTED' }, /自己ロックアウト/], [{ ok: false, error: 'OPS_DAILY_LIMIT' }, /上限/],
    [{ ok: false, error: 'RESTART_FAILED', stderr: 'Unit not loaded' }, /再起動に失敗しました.*Unit not loaded/]]) {
    const t = make('ok', resp, { sdArm: 'claudeos-Foo.service', sdArmAt: Date.now() });
    await t.run('claudeos-Foo.service');
    assert.equal(t.fake.state.notice.tone, 'warn');
    assert.match(t.fake.state.notice.text, re);
  }
  assert.ok(tpl.includes('restart: () => this.sdRestart(u.name)'), '行の再起動ボタンが sdRestart を呼ぶ');
  assert.ok(tpl.includes('{{ u.restartLabel }}'), '再起動ボタンの描画');
});
