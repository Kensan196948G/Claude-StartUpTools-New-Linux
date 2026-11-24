'use strict';
// github.js: gh 2.45 の実機挙動 (pr view --json に baseRefOid が無い) に合わせた取得経路のテスト
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const T = fs.mkdtempSync(path.join(os.tmpdir(), 'ship-gh-'));
function fakeGh(body) {
  const f = path.join(T, 'gh-' + Math.random().toString(36).slice(2));
  fs.writeFileSync(f, '#!/usr/bin/env node\nconst a=process.argv.slice(2);\n' + body, { mode: 0o755 });
  process.env.CLAUDEOS_SHIP_GH_BIN = f;
}
const github = require('../lib/github');
const H = 'a'.repeat(40); const B = 'b'.repeat(40);
const VIEW = `if(a[0]==='pr'&&a[1]==='view'){const w=a[a.indexOf('--json')+1].split(',');
 if(w.includes('baseRefOid')){console.error('Unknown JSON field: "baseRefOid"');process.exit(1);}
 console.log(JSON.stringify({number:1,state:'OPEN',isDraft:false,mergeable:'MERGEABLE',mergeStateStatus:'CLEAN',headRefOid:'${H}',headRefName:'x',baseRefName:'main',url:'u',title:'t',author:{login:'k'},statusCheckRollup:[{__typename:'StatusContext',context:'claudeos/local-quality',state:'SUCCESS'},{name:'linux-validate',status:'COMPLETED',conclusion:'SUCCESS'}],mergeCommit:null,autoMergeRequest:null}));process.exit(0);}`;

test('fetchPr: pr view に baseRefOid を要求せず、GraphQL から base を取る', () => {
  fakeGh(VIEW + `if(a[1]==='graphql'){console.log(JSON.stringify({data:{repository:{pullRequest:{baseRefOid:'${B}',headRefOid:'${H}',reviewThreads:{totalCount:2,nodes:[{isResolved:true},{isResolved:false}]}}}}}));process.exit(0);} process.exit(1);`);
  const r = github.fetchPr('o/r', 1);
  assert.equal(r.ok, true, r.error);
  assert.equal(r.data.baseRefOid, B);
  assert.equal(r.data.reviewThreadsUnresolved, 1);
  // StatusContext (Commit Status) の state も conclusion に正規化される
  assert.deepEqual(r.data.statusChecks.map((c) => [c.name, c.conclusion]), [['claudeos/local-quality', 'SUCCESS'], ['linux-validate', 'SUCCESS']]);
});

test('fetchPr: base が取れなければ失敗 (推測しない)', () => {
  fakeGh(VIEW + `if(a[1]==='graphql'){console.log(JSON.stringify({data:{repository:{pullRequest:{baseRefOid:null,headRefOid:'${H}',reviewThreads:{totalCount:0,nodes:[]}}}}}));process.exit(0);} process.exit(1);`);
  const r = github.fetchPr('o/r', 1);
  assert.equal(r.ok, false);
  assert.equal(r.error, 'BASE_OID_UNAVAILABLE');
});

test('fetchPr: 2 回の取得の間に head が変わったら失敗 (古い SHA で判定しない)', () => {
  fakeGh(VIEW + `if(a[1]==='graphql'){console.log(JSON.stringify({data:{repository:{pullRequest:{baseRefOid:'${B}',headRefOid:'${'c'.repeat(40)}',reviewThreads:{totalCount:0,nodes:[]}}}}}));process.exit(0);} process.exit(1);`);
  assert.equal(github.fetchPr('o/r', 1).error, 'HEAD_RACE');
});

test('fetchPr: レビュースレッドが 100 件を超えると未解決数は UNKNOWN (null)', () => {
  fakeGh(VIEW + `if(a[1]==='graphql'){console.log(JSON.stringify({data:{repository:{pullRequest:{baseRefOid:'${B}',headRefOid:'${H}',reviewThreads:{totalCount:150,nodes:[]}}}}}));process.exit(0);} process.exit(1);`);
  assert.equal(github.fetchPr('o/r', 1).data.reviewThreadsUnresolved, null);
});

test('classifyError: 認証・レート制限・障害を区別する', () => {
  assert.equal(github.classifyError({ stderr: 'HTTP 401: Bad credentials' }), 'GH_AUTH');
  assert.equal(github.classifyError({ stderr: 'API rate limit exceeded' }), 'GH_RATE_LIMIT');
  assert.equal(github.classifyError({ stderr: 'HTTP 503 Service Unavailable' }), 'GH_UNAVAILABLE');
  assert.equal(github.classifyError({ error: 'ENOENT', stderr: '' }), 'GH_NOT_INSTALLED');
});

test('postStatus: token は引数に載せない / 不正 state は拒否', () => {
  const log = path.join(T, 'args.log');
  fakeGh(`require('fs').writeFileSync(${JSON.stringify(log)}, JSON.stringify({a, tok: process.env.GH_TOKEN||null}));process.exit(0);`);
  assert.equal(github.postStatus('o/r', H, { context: 'c', state: 'success', description: 'd' }, { token: 'secret-token-value' }).ok, true);
  const got = JSON.parse(fs.readFileSync(log, 'utf8'));
  assert.ok(!got.a.join(' ').includes('secret-token-value'));
  assert.equal(got.tok, 'secret-token-value');
  assert.throws(() => github.postStatus('o/r', H, { context: 'c', state: 'approved' }), /INVALID_STATE/);
});

test.after(() => { fs.rmSync(T, { recursive: true, force: true }); delete process.env.CLAUDEOS_SHIP_GH_BIN; });
