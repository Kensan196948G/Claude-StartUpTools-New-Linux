'use strict';
/**
 * app.js — ClaudeOS Web スタートアップコンソール (依存なし)
 *
 * 変更系操作は必ず「計画 (--dry-run) → 確認 → 実行」。計画を見ていない状態では
 * 実行ボタンを有効化しない (ブラウザ側でも Human Gate を表現する)。
 */

const $ = (id) => document.getElementById(id);

const S = {
  state: null,
  server: null,
  selected: null,      // 選択中プロジェクト名
  mode: 'background',
  plans: {},           // project -> true (計画確認済み)
  allPlanned: false,
};

const STATUS_LABEL = {
  ok: '待機',
  running: '実行中',
  'goal-reached': '目標達成済',
  'crash-loop': 'クラッシュ',
  blocked: 'ブロック中',
};

function esc(s) {
  return String(s === undefined || s === null ? '' : s)
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

async function api(method, url, body) {
  const opt = { method, headers: {} };
  if (body !== undefined) {
    opt.headers['Content-Type'] = 'application/json';
    opt.body = JSON.stringify(body);
  }
  const res = await fetch(url, opt);
  let data;
  try { data = await res.json(); } catch { data = { ok: false, error: 'BAD_RESPONSE' }; }
  return { status: res.status, data };
}

// ---------------------------------------------------------------------------
// 描画
// ---------------------------------------------------------------------------

function renderBadges() {
  const st = S.state, sv = S.server || {};
  const badges = [];
  badges.push(`<span class="badge info">実行中 ${st.sessions.count} / 上限 ${st.limits.max_sessions}</span>`);
  badges.push(`<span class="badge">${esc(st.projects_dir)}</span>`);
  if (sv.dryRunOnly) badges.push('<span class="badge warn">DRY-RUN ONLY (実起動しません)</span>');
  badges.push(sv.authRequired
    ? '<span class="badge ok">Basic 認証 有効</span>'
    : '<span class="badge warn">認証なし (loopback 限定)</span>');
  if (!sv.capabilities || !sv.capabilities.desktopTerminal) {
    badges.push('<span class="badge warn">デスクトップ端末なし → foreground 不可</span>');
  } else {
    badges.push('<span class="badge ok">デスクトップ端末 あり</span>');
  }
  $('badges').innerHTML = badges.join('');
  $('meta').textContent =
    `host=${st.host} / generated=${st.generated_at} / config=${st.config_path}`;
}

function renderProjects() {
  const q = $('filter').value.trim().toLowerCase();
  const list = S.state.projects.filter(p =>
    !q || p.name.toLowerCase().includes(q) || (p.group || '').toLowerCase().includes(q));
  $('proj-count').textContent = String(S.state.projects.length);

  if (!list.length) { $('projects').innerHTML = '<div class="hint">該当なし</div>'; return; }

  // グループ単位でまとめる (projectGroups 設定時の表示に合わせる)
  const groups = new Map();
  for (const p of list) {
    const g = p.group || '(直下)';
    if (!groups.has(g)) groups.set(g, []);
    groups.get(g).push(p);
  }

  let html = '';
  for (const [g, items] of groups) {
    html += `<h3 class="group">📁 ${esc(g)} (${items.length})</h3>`;
    html += '<div class="table-wrap"><table><thead><tr><th>プロジェクト</th><th>状態</th><th class="col-sup">Supervisor</th><th></th></tr></thead><tbody>';
    for (const p of items) {
      const st = p.run_status;
      const label = STATUS_LABEL[st] || st;
      const sup = p.supervisor
        ? `${esc(p.supervisor.status)}${p.supervisor.alive ? ' / alive' : ''}` +
          (p.supervisor.restarts_today ? ` / 再開${p.supervisor.restarts_today}` : '')
        : '<span class="hint">—</span>';
      // グループ名は見出し (📁) と重複するため狭幅では隠す → viewport 依存の表示は CSS 側で切替
      const slash = p.name.indexOf('/');
      const prefix = slash === -1 ? '' : p.name.slice(0, slash + 1);
      const leaf = slash === -1 ? p.name : p.name.slice(slash + 1);
      const icons = `${p.foreground && p.foreground.alive ? ' 🖥️' : ''}${p.tmux.active ? ' 🧩' : ''}`;
      html += `<tr class="${p.name === S.selected ? 'selected' : ''}" data-name="${esc(p.name)}">
        <td class="name" title="${esc(p.name)}">${prefix ? `<span class="grp">${esc(prefix)}</span>` : ''}<span class="leaf">${esc(leaf)}</span>${icons}</td>
        <td><span class="chip ${esc(st)}">${esc(label)}</span></td>
        <td class="mono col-sup">${sup}</td>
        <td class="actions">
          <button class="tiny primary" data-act="select" data-name="${esc(p.name)}">選択</button>
          <button class="tiny ghost" data-act="log" data-name="${esc(p.name)}">ログ</button>
          ${p.running ? `<button class="tiny stop" data-act="stop" data-name="${esc(p.name)}">停止</button>` : ''}
        </td></tr>`;
    }
    html += '</tbody></table></div>';
  }
  $('projects').innerHTML = html;

  $('projects').querySelectorAll('button[data-act]').forEach(b => {
    b.addEventListener('click', () => {
      const name = b.dataset.name;
      if (b.dataset.act === 'select') selectProject(name);
      else if (b.dataset.act === 'log') showLog(name);
      else if (b.dataset.act === 'stop') stopProject(name);
    });
  });
}

function renderSessions() {
  const s = S.state.sessions;
  $('sess-count').textContent = String(s.count);
  const rows = [];
  const mk = (label, arr, chip) => arr.forEach(n =>
    rows.push(`<div class="row"><span class="chip ${chip}">${label}</span>
      <span class="mono grow">${esc(n)}</span></div>`));
  mk('Supervisor', s.headless, 'running');
  mk('Foreground', s.foreground, 'running');
  mk('tmux', s.tmux, 'goal-reached');

  if (!rows.length) {
    $('sessions').innerHTML = '<div class="hint">なし — 起動中の Claude セッションはありません</div>';
  } else {
    $('sessions').innerHTML = rows.join('');
  }

  const hist = (s.history || []).slice(0, 8).map(h =>
    `<tr><td class="name">${esc(h.project)}</td><td><span class="chip ok">${esc(h.status)}</span></td>
     <td class="mono">${esc(h.start_time)}</td></tr>`).join('');
  if (hist) {
    $('sessions').innerHTML += `<h3 class="group">🕘 直近のセッション履歴</h3>
      <div class="table-wrap"><table><thead><tr><th>プロジェクト</th><th>状態</th><th>開始</th></tr></thead><tbody>${hist}</tbody></table></div>`;
  }
}

function renderModes() {
  const modes = (S.server && S.server.modes) || [];
  const desktopOk = !(S.server && S.server.capabilities) || S.server.capabilities.desktopTerminal;
  $('modes').innerHTML = modes.map(m => {
    const blocked = m.id === 'foreground' && !desktopOk;
    return `<label><input type="radio" name="mode" value="${m.id}"
      ${m.id === S.mode ? 'checked' : ''} ${blocked ? 'disabled' : ''}> ${esc(m.label)}
      ${blocked ? '<span class="att">— デスクトップ端末が無いため不可</span>' : ''}</label>`;
  }).join('');
  $('modes').querySelectorAll('input[name=mode]').forEach(r =>
    r.addEventListener('change', () => { S.mode = r.value; onFormChange(); }));
  if ($('modes').querySelector('input[value=foreground]')?.disabled && S.mode === 'foreground') {
    S.mode = 'background';
    $('modes').querySelector('input[value=background]').checked = true;
  }
}

function renderGoals() {
  const g = S.state.goals;
  const opts = ['<option value="auto">🎯 自動判定 (auto — Goal Router に任せる)</option>'];
  if (g.primary.length) {
    opts.push('<optgroup label="Primary">');
    g.primary.forEach(x => opts.push(`<option value="${esc(x.name)}">${esc(x.name)} — ${esc(x.label_ja)}</option>`));
    opts.push('</optgroup>');
  }
  if (g.specialized.length) {
    opts.push('<optgroup label="Specialized">');
    g.specialized.forEach(x => opts.push(`<option value="${esc(x.name)}">${esc(x.name)} — ${esc(x.label_ja)}</option>`));
    opts.push('</optgroup>');
  }
  $('goal').innerHTML = opts.join('');
}

function renderCliEquiv() {
  if (!S.selected) { $('cli-equiv').textContent = '(プロジェクトを選択してください)'; return; }
  const d = $('duration').value;
  const goal = $('goal').value;
  const intent = $('intent').value.trim();
  const parts = ['bash bin/start-claude.sh --project', shellq(S.selected), '--' + S.mode];
  if (goal && goal !== 'auto') parts.push('--goal', shellq(goal));
  if (intent) parts.push('--intent', shellq(intent));
  if (d !== '') parts.push('--duration', d);
  $('cli-equiv').textContent = parts.join(' ') + '\n\n# 停止\nbash bin/autonomy.sh stop ' +
    shellq(S.selected) + '\n# 接続\ntmux attach -t claudeos-' + S.selected.replace(/[^A-Za-z0-9_-]/g, '_');
}

function shellq(s) { return "'" + String(s).replace(/'/g, "'\\''") + "'"; }

// ---------------------------------------------------------------------------
// 操作
// ---------------------------------------------------------------------------

function selectProject(name) {
  S.selected = name;
  $('selected-name').textContent = name;
  $('selected-name').className = 'okmsg';
  const p = S.state.projects.find(x => x.name === name);
  if (p) {
    if (p.run_status === 'running') {
      $('op-msg').innerHTML = '<span class="att">⚠️ このプロジェクトは実行中です。起動すると CLI 側の多重起動防止で拒否されるか、再起動扱いになります。</span>';
    } else {
      $('op-msg').textContent = '';
    }
  }
  $('duration').value = S.mode === 'background' ? (S.state.limits.default_session_minutes ?? 300)
                                                : (S.state.limits.foreground_minutes ?? 0);
  onFormChange();
  renderProjects();
  $('attach-hint').textContent = 'tmux attach -t claudeos-' + name.replace(/[^A-Za-z0-9_-]/g, '_');
}

function onFormChange() {
  const sel = $('goal').value;
  S.allPlanned = false;
  $('btn-all-apply').disabled = true;
  $('btn-all-apply').classList.add('hidden');
  $('btn-all-plan').disabled = false;
  $('btn-plan').disabled = !S.selected;
  $('btn-launch').disabled = true;              // 計画確認まで起動不可 (Human Gate)
  $('gate').textContent = '※ 変更を反映しました。もう一度「計画を確認」してください。';
  renderCliEquiv();
}

async function doPlan() {
  if (!S.selected) return;
  $('btn-plan').disabled = true;
  $('plan-out').textContent = '計画を作成中 (--dry-run)…';
  const r = await api('POST', '/api/startup/plan', {
    project: S.selected, mode: S.mode,
    goal: $('goal').value, intent: $('intent').value,
    duration: $('duration').value,
  });
  $('btn-plan').disabled = false;
  if (r.data.error) {
    $('plan-out').textContent = '❌ ' + r.data.error;
    $('op-msg').innerHTML = `<span class="err">計画失敗: ${esc(r.data.error)}</span>`;
    return;
  }
  $('plan-out').textContent = (r.data.plan || '') + (r.data.stderr ? '\n--- stderr ---\n' + r.data.stderr : '');
  const cap = r.data.capacity || {};
  $('op-msg').innerHTML = `計画: <span class="${r.data.ok ? 'okmsg' : 'err'}">${r.data.ok ? 'OK' : 'FAILED'}</span>` +
    ` / exit=${r.data.exitCode}` +
    (Number.isInteger(cap.running) ? ` / 稼働 ${cap.running}/${cap.max}` : '');
  $('btn-launch').disabled = !r.data.ok;
  $('gate').textContent = r.data.ok
    ? '※ 計画を確認しました。内容に問題がなければ「🚀 起動実行」を押してください (Human Gate)。'
    : '※ 計画が失敗しているため起動できません。';
}

async function doLaunch() {
  $('btn-launch').disabled = true;
  $('op-msg').textContent = '起動中…';
  const r = await api('POST', '/api/startup/launch', {
    project: S.selected, mode: S.mode,
    goal: $('goal').value, intent: $('intent').value,
    duration: $('duration').value, confirm: true,
  });
  if (r.data.started) {
    $('op-msg').innerHTML = `<span class="okmsg">✅ 起動しました (pid=${esc(r.data.pid)})</span> ` +
      `<span class="hint">${esc(r.data.modeLabel || '')}</span>`;
    if (r.data.args) $('plan-out').textContent = '実行: bash bin/start-claude.sh ' + r.data.args.join(' ');
  } else {
    $('op-msg').innerHTML = `<span class="err">❌ 起動できません: ${esc(r.data.error || r.data.detail || r.status)}</span>`;
    if (r.data.plan) $('plan-out').textContent = r.data.plan;
  }
  await reload();
  if (S.selected) $('btn-launch').disabled = false;
}

async function stopProject(name) {
  const r1 = await api('POST', '/api/startup/stop', { project: name });
  if (r1.data.requiresConfirm) {
    if (!confirm(`${name} を停止します。よろしいですか?\n\n${r1.data.plan}`)) return;
    const forced = confirm('即停止 (--now, 強制 kill) にしますか?\n[OK]=即停止 / [キャンセル]=グレースフル停止');
    const r2 = await api('POST', '/api/startup/stop', { project: name, force: forced, confirm: true });
    if (r2.data.ok) {
      $('op-msg').innerHTML = `<span class="okmsg">✅ ${esc(name)} を停止しました</span>`;
    } else {
      $('op-msg').innerHTML = `<span class="err">❌ 停止に失敗: ${esc(r2.data.error || r2.status)}</span>`;
    }
  } else if (r1.data.error) {
    $('op-msg').innerHTML = `<span class="err">❌ ${esc(r1.data.error)}</span>`;
  }
  await reload();
}

async function showLog(name) {
  $('modal-title').textContent = '📄 ログ: ' + name;
  $('modal-body').textContent = '読み込み中…';
  $('modal').classList.remove('hidden');
  const r = await api('GET', '/api/startup/log?lines=300&project=' + encodeURIComponent(name));
  if (r.data.ok) {
    $('modal-body').textContent = r.data.file + '\n' + '─'.repeat(60) + '\n' + (r.data.content || '(空)');
  } else if (r.data.error === 'LOG_NOT_FOUND') {
    $('modal-body').textContent =
      'このプロジェクトのログファイルはまだありません。\n\n' +
      '起動すると ~/.claudeos/supervisor/<project>.log または ~/.claudeos/logs/ に出力されます。';
  } else {
    $('modal-body').textContent = '❌ ' + (r.data.error || r.status);
  }
}

async function doAllPlan() {
  $('btn-all-plan').disabled = true;
  $('all-out').textContent = '計画を作成中 (autonomy.sh start --all --dry-run)…';
  const r = await api('POST', '/api/startup/apply-all', {});
  $('btn-all-plan').disabled = false;
  $('all-out').textContent = (r.data.plan || '') + (r.data.stderr ? '\n--- stderr ---\n' + r.data.stderr : '');
  if (r.data.ok) {
    $('btn-all-apply').classList.remove('hidden');
    $('btn-all-apply').disabled = false;
  }
}

async function doAllApply() {
  if (!confirm('上記の計画で Supervisor 全適用を実行します。\nAGENTS.md の規定どおり、これは人間の最終判断を伴う操作です。\nよろしいですか?')) return;
  $('btn-all-apply').disabled = true;
  const r = await api('POST', '/api/startup/apply-all', { confirm: true });
  $('all-out').textContent = (r.data.plan || '') + (r.data.started ? '\n\n✅ 全適用を開始しました (pid=' + r.data.pid + ')' : '');
  if (r.data.error) $('all-out').textContent += '\n❌ ' + r.data.error;
  await reload();
}

async function reload() {
  const r = await api('GET', '/api/startup/state');
  if (!r.data.ok) {
    $('meta').innerHTML = `<span class="err">状態取得失敗: ${esc(r.data.error)} ${esc(r.data.detail || '')}</span>`;
    return;
  }
  const prevMode = S.mode;
  S.state = r.data.state;
  S.server = r.data.server;
  const modes = (S.server.modes || []).map(m => m.id);
  if (!modes.includes(S.mode)) S.mode = 'background';
  renderBadges();
  renderModes();
  renderGoals();
  renderProjects();
  renderSessions();
  if (S.selected) renderCliEquiv();
  if (prevMode !== S.mode && S.selected) selectProject(S.selected);
}

function init() {
  $('btn-reload').addEventListener('click', reload);
  $('filter').addEventListener('input', () => renderProjects());
  $('btn-plan').addEventListener('click', doPlan);
  $('btn-launch').addEventListener('click', doLaunch);
  $('btn-all-plan').addEventListener('click', doAllPlan);
  $('btn-all-apply').addEventListener('click', doAllApply);
  $('modal-close').addEventListener('click', () => $('modal').classList.add('hidden'));
  ['goal', 'duration', 'intent'].forEach(id => $(id).addEventListener('input', onFormChange));
  reload();
  setInterval(reload, 15000);
}

document.addEventListener('DOMContentLoaded', init);
