/* ship.js — Ship Native Control Center (読み取り専用の表示 + 承認の取り消しのみ)
 *
 * 方針:
 *   - 値は API (/api/ship/*) の実データだけを表示する。無いものは「未取得」/「データなし」。デモデータは作らない。
 *   - DOM は textContent で組み立てる (innerHTML に外部データを入れない)。
 *   - 承認ボタンは置かない。人間が端末で bin/ship-approve.sh を実行する (理由は画面に明記)。
 */
(function () {
  'use strict';

  var POLL_MS = 15000;
  var EMPTY = 'データなし — デモデータは表示しません';
  var UNKNOWN = 'UNKNOWN / 未取得';
  var state = { overview: null, runs: [], pr: null, selectedPr: '', selectedRun: '', timer: null, loading: false };

  // ---------- DOM ヘルパ ----------
  function $(id) { return document.getElementById(id); }
  function el(tag, attrs, children) {
    var e = document.createElement(tag);
    if (attrs) {
      Object.keys(attrs).forEach(function (k) {
        var v = attrs[k];
        if (v == null || v === false) return;
        if (k === 'class') e.className = v;
        else if (k === 'text') e.textContent = v;
        else if (k.slice(0, 2) === 'on') e.addEventListener(k.slice(2), v);
        else e.setAttribute(k, v === true ? '' : v);
      });
    }
    (children || []).forEach(function (c) {
      if (c == null) return;
      e.appendChild(typeof c === 'string' || typeof c === 'number' ? document.createTextNode(String(c)) : c);
    });
    return e;
  }
  function clear(node) { while (node.firstChild) node.removeChild(node.firstChild); return node; }
  function empty(text) { return el('p', { class: 'empty', text: text || EMPTY }); }
  function short(sha) { return typeof sha === 'string' && sha.length >= 7 ? sha.slice(0, 12) : null; }
  function shaCell(sha) { return short(sha) ? el('span', { class: 'sha', title: sha, text: short(sha) }) : unk(); }
  function unk() { return badge(UNKNOWN, 'unk'); }
  function val(v) { return v == null || v === '' ? UNKNOWN : String(v); }
  function fmtTime(s) {
    if (!s) return UNKNOWN;
    var d = new Date(s);
    return isNaN(d.getTime()) ? String(s) : d.toLocaleString('ja-JP', { hour12: false });
  }
  function badge(text, tone) { return el('span', { class: 'badge b-' + (tone || 'unk'), text: text }); }

  var TONE = {
    PASS: 'ok', VALID: 'ok', MERGED: 'ok', COMPLETED: 'ok', HUMAN_APPROVED: 'ok', running: 'info', done: 'ok',
    CONDITIONAL: 'warn', STALE_HEAD: 'warn', EXPIRED: 'warn', HUMAN_APPROVAL_REQUIRED: 'warn', BLOCKED: 'bad',
    FAIL: 'bad', FAILED: 'bad', QUALITY_FAILED: 'bad', REVOKED: 'bad', STOPPED: 'unk', UNKNOWN: 'unk',
  };
  function stateBadge(v) {
    if (v == null || v === '') return unk();
    return badge(String(v), TONE[v] || (/^SHIP_|QUALITY_EVALUATING|MERGING|MERGE_QUEUED/.test(v) ? 'info' : 'unk'));
  }

  function table(caption, headers, rows) {
    if (!rows.length) return empty();
    var thead = el('thead', null, [el('tr', null, headers.map(function (h) { return el('th', { scope: 'col', text: h }); }))]);
    var tbody = el('tbody', null, rows.map(function (cells) {
      return el('tr', null, cells.map(function (c) { return el('td', null, [c == null ? unk() : c]); }));
    }));
    return el('table', null, [el('caption', { text: caption }), thead, tbody]);
  }

  function copyBtn(text) {
    return el('button', {
      type: 'button', class: 'btn small ghost', 'aria-label': 'コマンドをコピー',
      onclick: function (ev) {
        var b = ev.currentTarget;
        var done = function (ok) { b.textContent = ok ? 'コピーしました' : 'コピー不可 (手動で選択)'; setTimeout(function () { b.textContent = 'コピー'; }, 2000); };
        if (navigator.clipboard && navigator.clipboard.writeText) navigator.clipboard.writeText(text).then(function () { done(true); }, function () { done(false); });
        else done(false);
      },
    }, ['コピー']);
  }
  function cmdBlock(cmd) { return el('div', { class: 'cmd' }, [el('code', { text: cmd }), copyBtn(cmd)]); }

  // ---------- 取得 ----------
  function getJson(url) {
    return fetch(url, { credentials: 'same-origin', headers: { accept: 'application/json' } }).then(function (r) {
      return r.json().catch(function () { return null; }).then(function (j) {
        if (!r.ok || !j || j.ok === false) throw new Error((j && j.error) || ('HTTP ' + r.status));
        return j;
      });
    });
  }
  function live(msg) { $('live').textContent = msg; }

  function refresh() {
    if (state.loading) return;
    state.loading = true;
    live('更新中…');
    Promise.all([getJson('/api/ship/overview'), getJson('/api/ship/runs'), getJson('/api/ship/audit?limit=50')])
      .then(function (res) {
        state.overview = res[0];
        state.runs = res[1].runs || [];
        renderOverview();
        renderRuns();
        renderPipeline();
        renderPrSelect();
        renderPending();
        renderMerges();
        renderAudit(res[2]);
        return loadPr();
      })
      .then(function () {
        live('最終更新 ' + new Date().toLocaleTimeString('ja-JP', { hour12: false }) + ' (15 秒ごとに自動更新)');
      })
      .catch(function (e) {
        live('取得に失敗しました: ' + String(e && e.message || e) + ' — 表示中の値は前回のものか未取得です');
      })
      .then(function () { state.loading = false; });
  }

  function loadPr() {
    var key = state.selectedPr;
    if (!key) { state.pr = null; renderPrDetail(); return Promise.resolve(); }
    var i = key.lastIndexOf('#');
    var url = '/api/ship/pr?repo=' + encodeURIComponent(key.slice(0, i)) + '&pr=' + encodeURIComponent(key.slice(i + 1));
    return getJson(url).then(function (j) { state.pr = j; renderPrDetail(); }, function (e) {
      state.pr = null; renderPrDetail(String(e && e.message || e));
    });
  }

  // ---------- 描画 ----------
  function renderOverview() {
    var o = state.overview;
    var c = o.counts || {};
    var kp = clear($('kpis'));
    var items = [
      ['プロジェクト (repo)', c.projects], ['稼働中 run', c.runs_active], ['Ship 実行中', c.ship_running],
      ['品質評価中', c.quality_evaluating], ['承認待ち', c.approval_pending, c.approval_pending > 0 ? 'attention' : ''],
      ['マージ確認済み', c.merged], ['BLOCKED / FAILED', c.blocked_or_failed, c.blocked_or_failed > 0 ? 'alert' : ''],
      ['ローカル品質成功率', o.local_quality_success_rate == null ? null : Math.round(o.local_quality_success_rate * 1000) / 10 + '%'],
    ];
    items.forEach(function (it) {
      kp.appendChild(el('div', { class: 'kpi ' + (it[2] || '') }, [
        el('div', { class: 'label', text: it[0] }),
        el('div', { class: 'value', text: it[1] == null ? '—' : String(it[1]) }),
        it[1] == null ? el('div', { class: 'label', text: '未取得' }) : null,
      ]));
    });
    var f = clear($('facts'));
    var cap = o.ship_capability;
    var add = function (k, v) { f.appendChild(el('dt', { text: k })); f.appendChild(el('dd', null, [v])); };
    add('/ship 対応状況', cap ? document.createTextNode(JSON.stringify(cap)) : badge('未取得 (capability.json なし)', 'unk'));
    add('GitHub Actions', o.actions ? document.createTextNode(JSON.stringify(o.actions)) : document.createTextNode(o.actions_note || UNKNOWN));
    var sample = o.local_quality_sample || {};
    add('品質判定の母数', document.createTextNode(sample.decided ? ('PASS ' + sample.pass + ' / 判定済み ' + sample.decided + ' (UNKNOWN は除外)') : EMPTY));
    add('強制の所在', document.createTextNode(o.enforcement_note || ''));
    $('generated').textContent = '生成時刻: ' + fmtTime(o.generated_at);
  }

  function renderRuns() {
    var rows = state.runs.map(function (r) {
      return [
        el('span', { class: 'sha', text: val(r.run_id) }),
        document.createTextNode(val(r.repo)),
        document.createTextNode(r.pr == null ? '—' : '#' + r.pr),
        document.createTextNode(val(r.mode)),
        stateBadge(r.state),
        shaCell(r.head_sha),
        stateBadge(r.ship && r.ship.status),
        document.createTextNode(fmtTime(r.updated_at)),
        r.terminal ? document.createTextNode('終端') : el('code', { text: '/ship stop' }),
      ];
    });
    clear($('runs-table')).appendChild(table('Ship Native run (新しい順)',
      ['run', 'repo', 'PR', 'mode', '状態', 'head SHA', 'ship', '更新', '停止方法 (セッション内)'], rows));
  }

  function renderPipeline() {
    var o = state.overview;
    var sel = $('pipeline-run');
    var prev = state.selectedRun || sel.value;
    clear(sel);
    if (!state.runs.length) sel.appendChild(el('option', { value: '', text: '(run なし)' }));
    state.runs.forEach(function (r) { sel.appendChild(el('option', { value: r.run_id, text: r.run_id + ' — ' + val(r.state) })); });
    if (prev && state.runs.some(function (r) { return r.run_id === prev; })) sel.value = prev;
    state.selectedRun = sel.value;
    var run = state.runs.find(function (r) { return r.run_id === sel.value; }) || null;
    var visited = {};
    if (run && Array.isArray(run.history)) run.history.forEach(function (h) { if (h && h.from) visited[h.from] = true; });
    var term = {};
    (o.terminal_states || []).forEach(function (s) { term[s] = true; });
    var list = clear($('pipeline-list'));
    (o.states || []).forEach(function (s) {
      var cur = run && run.state === s;
      var cls = [cur ? 'current' : '', visited[s] ? 'visited' : '', term[s] ? 'terminal' : ''].join(' ').trim();
      list.appendChild(el('li', { class: cls, 'aria-current': cur ? 'step' : null, text: s }));
    });
    if (!run) list.appendChild(el('li', { text: '選択中の run なし — 強調表示なし' }));
  }

  function renderPrSelect() {
    var sel = $('pr-select');
    var prs = state.overview.prs || [];
    var prev = state.selectedPr || sel.value;
    clear(sel);
    if (!prs.length) sel.appendChild(el('option', { value: '', text: '(PR なし)' }));
    prs.forEach(function (p) {
      var key = p.repo + '#' + p.pr;
      sel.appendChild(el('option', { value: key, text: key + (p.pending_approval ? ' — 承認待ち' : '') }));
    });
    if (prev && prs.some(function (p) { return p.repo + '#' + p.pr === prev; })) sel.value = prev;
    else {
      // 初回は承認待ちの PR を優先して開く
      var firstPending = prs.find(function (p) { return p.pending_approval; });
      if (firstPending) sel.value = firstPending.repo + '#' + firstPending.pr;
    }
    state.selectedPr = sel.value;
  }

  function renderPending() {
    var box = clear($('pending'));
    var pend = (state.overview.prs || []).filter(function (p) { return p.pending_approval; });
    if (!pend.length) { box.appendChild(empty('承認待ちはありません')); return; }
    pend.forEach(function (p) {
      box.appendChild(el('div', { class: 'pending-item' }, [
        el('div', null, [el('strong', { text: p.repo + ' #' + p.pr }), ' ', stateBadge(p.gate_verdict), ' risk: ', document.createTextNode(val(p.gate_risk)),
          ' · head ', shaCell(p.latest_head), ' · 品質 ', stateBadge(p.quality_verdict)]),
        p.approve_command ? cmdBlock(p.approve_command) : null,
      ]));
    });
  }

  function renderPrDetail(err) {
    var qb = clear($('quality-body'));
    var ab = clear($('approvals-table'));
    var d = state.pr;
    if (!d) {
      qb.appendChild(empty(err ? ('取得失敗: ' + err) : EMPTY));
      ab.appendChild(empty(err ? ('取得失敗: ' + err) : EMPTY));
      return;
    }
    qb.appendChild(el('p', null, ['最新 head: ', shaCell(d.latest_head), ' (出典: ', document.createTextNode(val(d.latest_head_source)), ')']));
    if (!d.quality.length) qb.appendChild(empty());
    d.quality.forEach(function (q) {
      var match = q.sha_match === true ? badge('証跡 SHA = 最新 head', 'ok')
        : q.sha_match === false ? badge('最新 head ではない (古い証跡)', 'warn')
        : badge(q.is_latest_head ? '最新 head・証跡なし' : '証跡なし', 'unk');
      var head = el('h3', null, ['head ', shaCell(q.head_sha), ' ', stateBadge(q.verdict), ' ', match]);
      qb.appendChild(head);
      if (q.missing) { qb.appendChild(empty('この head の品質証跡は未取得です')); return; }
      qb.appendChild(el('p', { class: 'hint' }, ['評価 ', document.createTextNode(val(q.eval_id)), ' · 隔離: ', document.createTextNode(val(q.isolation)),
        ' · 完了 ', document.createTextNode(fmtTime(q.finished_at)), ' · HMAC ', q.hmac_present ? badge('あり', 'ok') : badge('なし', 'bad')]));
      var wrap = el('div', { class: 'table-wrap' });
      wrap.appendChild(table('品質チェック', ['id', 'カテゴリ', 'コマンド', '状態', 'exit', 'pass/fail/skip', '時間'], (q.checks || []).map(function (c) {
        return [
          document.createTextNode(val(c.id)), document.createTextNode(val(c.category)),
          el('code', { text: Array.isArray(c.cmd) ? c.cmd.join(' ') : val(c.cmd) }),
          stateBadge(c.status), document.createTextNode(c.exit_code == null ? '—' : String(c.exit_code)),
          document.createTextNode([c.passed, c.failed, c.skipped].map(function (n) { return n == null ? '?' : n; }).join(' / ')),
          document.createTextNode(c.duration_ms == null ? '—' : (c.duration_ms / 1000).toFixed(1) + 's'),
        ];
      })));
      qb.appendChild(wrap);
    });
    if (d.gates && d.gates.length) {
      qb.appendChild(el('h3', { text: 'AI Quality Gate 判定' }));
      var gw = el('div', { class: 'table-wrap' });
      gw.appendChild(table('ゲート判定 (新しい順)', ['head', '判定', 'risk', '理由', '評価時刻'], d.gates.map(function (g) {
        return [shaCell(g.head_sha), stateBadge(g.verdict), document.createTextNode(val(g.risk)),
          document.createTextNode((g.reasons || []).map(function (x) { return typeof x === 'string' ? x : JSON.stringify(x); }).join(' / ') || '—'),
          document.createTextNode(fmtTime(g.evaluated_at))];
      })));
      qb.appendChild(gw);
    }

    ab.appendChild(el('p', { class: 'hint', text: d.enforcement_note || '' }));
    ab.appendChild(el('p', null, ['この PR の承認コマンド (人間が端末で実行):']));
    ab.appendChild(cmdBlock(d.approve_command));
    ab.appendChild(table('承認 (表示用の有効性)', ['承認 ID', 'head', '有効性', '承認者', '発行', '期限', 'ゲート', '操作'], d.approvals.map(function (a) {
      return [
        el('span', { class: 'sha', text: val(a.approval_id) }), shaCell(a.head_sha),
        el('span', null, [stateBadge(a.validity), a.validity_reason ? el('small', { text: ' ' + a.validity_reason }) : null]),
        document.createTextNode(val(a.approver)), document.createTextNode(fmtTime(a.issued_at)), document.createTextNode(fmtTime(a.expires_at)),
        stateBadge(a.gate_verdict),
        a.validity === 'REVOKED' ? document.createTextNode('—')
          : el('button', { type: 'button', class: 'btn small danger', onclick: function () { openRevoke(a.approval_id); } }, ['取り消し']),
      ];
    })));
  }

  function renderMerges() {
    var rows = (state.overview.prs || []).filter(function (p) { return p.merge_state; }).map(function (p) {
      return [
        document.createTextNode(p.repo + ' #' + p.pr),
        p.merged_confirmed ? badge('MERGED (確認済み)', 'ok') : badge(String(p.merge_state) + ' (未確認)', p.merge_state === 'MERGED' ? 'warn' : 'unk'),
        shaCell(p.merge_commit_sha), document.createTextNode(fmtTime(p.merge_at)), document.createTextNode(val(p.merge_reason)),
      ];
    });
    clear($('merge-table')).appendChild(table('マージ記録', ['PR', '状態', 'merge commit', '時刻', '理由'], rows));
  }

  function renderAudit(a) {
    var ch = a.chain || {};
    var c = clear($('chain'));
    c.appendChild(document.createTextNode('チェーン検証: '));
    c.appendChild(ch.ok ? badge('整合 OK (' + ch.entries + ' 件)', 'ok')
      : badge('不整合: ' + val(ch.error) + ' (' + val(ch.at) + ' 行目)', 'bad'));
    var rows = (a.entries || []).slice().reverse().map(function (e) {
      var rest = {};
      Object.keys(e).forEach(function (k) { if (['schema', 'ts', 'event', 'actor', 'hash', 'prev_hash'].indexOf(k) < 0) rest[k] = e[k]; });
      return [document.createTextNode(fmtTime(e.ts)), el('code', { text: val(e.event) }), document.createTextNode(val(e.actor)),
        el('code', { text: JSON.stringify(rest) }), shaCell(e.hash)];
    });
    clear($('audit-table')).appendChild(table('監査イベント (新しい順・最大 50 件 / 全 ' + (a.total || 0) + ' 件)', ['時刻', 'イベント', '実行者', '内容', 'hash'], rows));
  }

  // ---------- 取り消し ----------
  function openRevoke(id) {
    var dlg = $('revoke-dialog');
    $('revoke-id').textContent = id;
    $('revoke-reason').value = '';
    $('revoke-result').textContent = '';
    $('revoke-submit').disabled = false;
    if (typeof dlg.showModal === 'function') dlg.showModal(); else dlg.setAttribute('open', '');
    $('revoke-reason').focus();
  }
  function closeRevoke() { var d = $('revoke-dialog'); if (typeof d.close === 'function') d.close(); else d.removeAttribute('open'); }
  function submitRevoke(ev) {
    ev.preventDefault();
    var id = $('revoke-id').textContent;
    var reason = $('revoke-reason').value.trim();
    var out = $('revoke-result');
    if (!reason) { out.textContent = '理由を入力してください'; return; }
    $('revoke-submit').disabled = true;
    out.textContent = '送信中…';
    fetch('/api/ship/approvals/revoke', {
      method: 'POST', credentials: 'same-origin',
      headers: { 'content-type': 'application/json', accept: 'application/json' },
      body: JSON.stringify({ approval_id: id, reason: reason }),
    }).then(function (r) {
      return r.json().catch(function () { return {}; }).then(function (j) {
        if (r.ok && j.ok) { out.textContent = '取り消しました (' + j.revoked_by + ')'; setTimeout(function () { closeRevoke(); refresh(); }, 900); return; }
        var msg = { AUTH_JWT_REQUIRED: 'Cloudflare Access の認証 (JWT) がありません。Access 経由で開いてください。',
          SHIP_AUTH_FAILED: 'Access の認証に失敗しました (メール付き JWT が必要)。',
          SHIP_AUTH_NOT_CONFIGURED: 'サーバに Cloudflare Access が設定されていないため取り消しできません。CLI で取り消してください。',
          ALREADY_REVOKED: '既に取り消し済みです。', APPROVAL_NOT_FOUND: '承認が見つかりません。' }[j.error];
        out.textContent = '失敗 (HTTP ' + r.status + '): ' + (msg || j.error || '不明なエラー');
        $('revoke-submit').disabled = false;
      });
    }).catch(function (e) { out.textContent = '送信に失敗しました: ' + String(e && e.message || e); $('revoke-submit').disabled = false; });
  }

  // ---------- テーマ ----------
  function applyTheme(t) {
    document.documentElement.setAttribute('data-theme', t);
    var b = $('theme-toggle');
    b.setAttribute('aria-pressed', t === 'dark' ? 'true' : 'false');
    b.textContent = t === 'dark' ? '☀️ ライト' : '🌙 ダーク';
  }
  function toggleTheme() {
    var t = document.documentElement.getAttribute('data-theme') === 'dark' ? 'light' : 'dark';
    try { localStorage.setItem('claudeos.ship.theme', t); } catch (e) { /* 保存できなくても切り替える */ }
    applyTheme(t);
  }

  // ---------- 起動 ----------
  function start() {
    applyTheme(document.documentElement.getAttribute('data-theme') === 'dark' ? 'dark' : 'light');
    $('theme-toggle').addEventListener('click', toggleTheme);
    $('refresh').addEventListener('click', refresh);
    $('pr-select').addEventListener('change', function (e) { state.selectedPr = e.target.value; loadPr(); });
    $('pipeline-run').addEventListener('change', function (e) { state.selectedRun = e.target.value; renderPipeline(); });
    $('revoke-form').addEventListener('submit', submitRevoke);
    $('revoke-cancel').addEventListener('click', closeRevoke);
    refresh();
    state.timer = setInterval(function () { if (!document.hidden) refresh(); }, POLL_MS);
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start); else start();
})();
