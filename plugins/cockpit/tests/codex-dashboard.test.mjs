import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { accountsOf, loginFor, outcomeOf, verdictOf } from '../core/readings.ts';
import { snapshot, render, ownerAlive, monitor, notificationDelivery, claimDashboard, cleanupStaleScopes } from '../codex/dashboard.mjs';
import { processHook } from '../codex/hook.mjs';
import { writeJson, identity, readJson } from '../codex/state.mjs';
import { refreshGithub } from '../codex/github.mjs';

test('shared readers preserve account boundaries and run/PR verdict priority', () => {
  const accounts = accountsOf({ defaults: { githubAccounts: { 'C:/work': 'work', 'C:/work/nested': 'nested' } } });
  assert.equal(loginFor('C:/worker', accounts), undefined);
  assert.equal(loginFor('C:/work/nested/repo', accounts), 'nested');
  for (const [meta, title] of [[{exitCode:124},'timed out'], [{exitCode:4},'quota refused'], [{exitCode:5},'gate failed'], [{exitCode:0,reportPresent:false},'finished without a report'], [{exitCode:0,gate:{flaky:true}},'gate passed on second attempt']]) assert.equal(outcomeOf(meta).title, title);
  const pr = { isDraft: false, mergeable: 'CONFLICTING', commits: { nodes: [] }, reviews: { nodes: [] }, reactions: { nodes: [] } };
  assert.equal(verdictOf(pr), 'conflict'); assert.equal(verdictOf({...pr, isDraft:true}), 'draft');
});

test('offline once is bounded, handles stale/malformed data and never starts commands', async () => {
  const home = mkdtempSync(join(tmpdir(), 'cockpit-dashboard-'));
  const put = (file, value) => { const path = join(home, file); mkdirSync(join(path, '..'), {recursive:true}); writeFileSync(path, value); };
  try {
    put('runs/demo/one/meta.json', JSON.stringify({ startedAt:'2026-11-11T10:00:00Z', endedAt:'2026-11-11T10:01:00Z',exitCode:0,reportPresent:true }));
    put('runs/demo/one/report.md','STATUS complete');
    put('runs/demo/one/progress.md','# Progress\nWorking\x1b[31m');
    put('runs/demo/one/gate.json', JSON.stringify({ startedAt:'2020-01-01',exitCode:1 }));
    put('runs/demo/broken/meta.json','{bad');
    put('runs/.locks/demo.json',JSON.stringify({runDir:join(home,'runs/demo/one'),pid:process.pid,processStartTime:'fixture'}));
    put('logs/quota/last-good.json',JSON.stringify({fetchedAtUtc:'2020-01-01',quota:{providers:[{id:'codex',available:true,windows:[{label:'5h',usedPct:94}]}]}}));
    const value = await snapshot({pipelineHome:home, now:Date.parse('2026-11-11T11:00:00Z'), offline:true, isAlive:async()=>{throw new Error('offline snapshot probed a process');}});
    assert.equal(value.quota.stale,true); assert.equal(value.runs.length,2);
    assert.equal(value.runs.find(x=>x.name.endsWith('one')).outcome.title,'finished');
    assert.match(value.runs.find(x=>x.name.endsWith('one')).progress,/^Working/);
    const lines = render(value, 24, 12).split('\n');
    assert.ok(lines.length <= 12); assert.ok(lines.every(x => x.length <= 24)); assert.doesNotMatch(lines.join('\n'), /\x1b/);
    const run = spawnSync(process.execPath,['plugins/cockpit/codex/dashboard.mjs','--once','--offline','--pipeline-home',home,'--width','24'],{encoding:'utf8'});
    assert.equal(run.status,0); assert.match(run.stdout,/quota.*stale/i);
    put('logs/quota/last-good.json',JSON.stringify({fetchedAtUtc:'2026-11-11T11:00:00Z',quota:{providers:{}}}));
    assert.equal((await snapshot({pipelineHome:home,offline:true})).quota.stale,true);
    put('logs/quota/last-good.json',JSON.stringify({fetchedAtUtc:'2026-11-11T11:00:00Z',quota:{providers:[null,{id:'codex',available:true,windows:[]}]}}));
    assert.equal((await snapshot({pipelineHome:home,offline:true,now:Date.parse('2026-11-11T11:00:00Z')})).quota.stale,true);
  } finally { rmSync(home,{recursive:true,force:true}); }
});

test('large archives retain recent aliases and lock rows ahead of capped history', async () => {
  const home = mkdtempSync(join(process.cwd(), 'cockpit-recency-'));
  const ended = startedAt => ({ startedAt, endedAt:startedAt, exitCode:0 });
  const put = (alias, name, meta) => {
    const path = join(home, 'runs', alias, name);
    mkdirSync(path, {recursive:true});
    if (meta) writeJson(join(path, 'meta.json'), meta);
    return path;
  };
  try {
    for (let i = 0; i < 65; i++) put(`alias-${String(i).padStart(2,'0')}`, '2026-01-01-old', ended('2026-01-01'));
    for (let i = 0; i < 220; i++) {
      const day = new Date(Date.UTC(2026, 0, i + 1)).toISOString().slice(0,10);
      put('zz-archive', `${day}-history`, ended(day));
    }
    put('aa-recent', '2026-11-11-first', ended('2026-11-11T10:00:00Z'));
    put('zz-archive', '2026-11-11-last', ended('2026-11-11T11:00:00Z'));
    // Old names and start times force lock retention and priority to be independent of recency.
    const pending = put('aa-recent', '2020-01-01-pending');
    const running = put('aa-recent', '2020-01-01-running', {startedAt:'2020-01-01'});
    const dead = put('aa-recent', '2020-01-01-dead');
    const untimed = put('aa-recent', '2020-01-01-untimed');
    for (const [name, runDir, pid] of [['pending',pending,1],['running',running,1],['dead',dead,2],['untimed',untimed,2],['outside',home,1]]) {
      writeJson(join(home, 'runs/.locks', `${name}.json`), {runDir,pid,processStartTime:'2020-01-01',...(name === 'untimed' ? {} : {startedAt:'2020-01-02'})});
    }
    const calls = [];
    const value = await snapshot({pipelineHome:home,isAlive:async owner=>{calls.push(owner);return owner.pid === 1;}});
    assert.ok(value.runs.some(x=>x.name === 'aa-recent/2026-11-11-first'), 'alphabetically early recent alias omitted');
    assert.ok(value.runs.some(x=>x.name === 'zz-archive/2026-11-11-last'), 'recent run beyond 200 directory entries omitted');
    assert.ok(value.runs.length >= 100 && value.runs.length <= 104, 'history must remain bounded, with locks retained');
    assert.equal(calls.length,4, 'outside-root lock must not be probed');
    const pendingRow = value.runs.find(x=>x.name.endsWith('-pending'));
    assert.equal(pendingRow.phase,'pending');
    assert.equal(pendingRow.startedAt,Date.parse('2020-01-02'));
    assert.equal(value.runs.find(x=>x.name.endsWith('-running')).phase,'running');
    assert.equal(value.runs.find(x=>x.name.endsWith('-dead')).phase,'unknown');
    assert.equal(Number.isFinite(value.runs.find(x=>x.name.endsWith('-untimed')).startedAt),false);
    assert.deepEqual(value.runs.slice(0,2).map(x=>x.phase).sort(),['pending','running']);
    const screen = render(value, 240, 30);
    assert.ok(screen.indexOf('-pending:') < screen.indexOf('2026-11-11-last:'));
    assert.ok(screen.indexOf('-running:') < screen.indexOf('2026-11-11-last:'));
    assert.doesNotMatch(value.runs.find(x=>x.name.endsWith('-dead')).outcome.title,/live/);
    const offline = await snapshot({pipelineHome:home,offline:true,isAlive:async()=>{throw new Error('offline process probe');}});
    for (const suffix of ['-pending','-running','-dead','-untimed']) {
      const row = offline.runs.find(x=>x.name.endsWith(suffix));
      assert.equal(row.phase,'unknown');
      assert.match(row.outcome.title,/liveness unknown.*offline/i);
    }
    assert.match(render(offline,240,30),/-pending:.*liveness unknown/);
  } finally { rmSync(home,{recursive:true,force:true}); }
});

test('owner identity and monitor cleanup prevent orphan polling', async () => {
  assert.equal(await ownerAlive({pid:process.pid,startedAt:'wrong'}),false);
  const controller = new AbortController(); let polls = 0; let cleanup = 0;
  await monitor({owner:{pid:1,startedAt:'x'},isAlive:async()=>polls<1,read:async()=>{polls++;return {};},draw:()=>{},dispose:()=>cleanup++,signal:controller.signal,intervalMs:1});
  assert.equal(polls,1); assert.equal(cleanup,1);
});

test('GitHub read adapter keeps last good, filters runner roots, dedupes slugs and never switches auth', async () => {
  const calls=[];
  const registry={defaults:{githubAccounts:{'C:/work':'expected'},cockpitRunnerRoot:'C:/work'},executors:{a:{repo:'C:/work/a',github:'org/a'},duplicate:{repo:'C:/work/b',github:'org/a'},outside:{repo:'C:/worker/c',github:'org/c'}}};
  const run=async(args)=>{
    calls.push(args);
    if(args[0]==='auth') return {status:0,stdout:'TRANSIENT'};
    if(args.includes('graphql')) return {status:0,stdout:JSON.stringify({data:{viewer:{pullRequests:{nodes:[]}}}})};
    if(args[1].includes('runners')) return {status:0,stdout:'{"runners":[]}'};
    return {status:0,stdout:'{"workflow_runs":[]}'};
  };
  const reading=await refreshGithub({registry,cwd:'C:/work/a',run,now:1000});
  assert.equal(reading.runners.rows.length,1); assert.equal(reading.prs.fetchedAt,1000);
  assert.equal(calls.filter(x=>x[1]?.includes('runners')).length,1);
  assert.ok(calls.every(x=>x[0]==='auth'||x[0]==='api'));
  const failed=await refreshGithub({registry,cwd:'C:/work/a',run:async()=>({status:1,stdout:''}),previous:reading,now:2000});
  assert.equal(failed.prs.fetchedAt,1000); assert.equal(failed.prs.error,'GitHub reading unavailable');
});

test('notification delivery ignores superseded generations and isolates owners', async()=>{
  const home=mkdtempSync(join(tmpdir(),'cockpit-delivery-'));
  try{
    const owner={pid:1,startedAt:'fixture'};const effects=[];const send=async effect=>effects.push(effect);
    const options={home,owner,scope:'scope-a',interactive:true,now:1000};
    processHook('PermissionRequest',{session_id:'a'},options);
    let value=await snapshot({pipelineHome:home,stateHome:home,scope:'scope-a'});
    const delivery=notificationDelivery(owner,send);
    processHook('UserPromptSubmit',{session_id:'a'},{...options,now:1100});
    await delivery.update(value.sessions);assert.equal(effects.length,0,'superseded approval delivered');
    value=await snapshot({pipelineHome:home,stateHome:home,scope:'scope-a'});
    await delivery.update(value.sessions);await delivery.update(value.sessions);
    assert.equal(effects.length,1);assert.equal(effects[0].action,'clear');
    processHook('PermissionRequest',{session_id:'b'},{...options,scope:'scope-b',owner:{pid:2,startedAt:'other'}});
    const other=await snapshot({pipelineHome:home,stateHome:home,scope:'scope-b'});
    await delivery.update(other.sessions);assert.equal(effects.length,1,'foreign session notified');
    await delivery.clear();assert.equal(effects.length,2);
  }finally{rmSync(home,{recursive:true,force:true});}
});

test('companion ownership and stale cleanup preserve live sessions',async()=>{
  const home=mkdtempSync(join(tmpdir(),'cockpit-owners-'));
  try{
    const scope={id:'one',home};const owner={pid:1,startedAt:'fixture'};
    const release=await claimDashboard(scope,owner,async()=>true);
    await assert.rejects(()=>claimDashboard(scope,owner,async()=>true),/already has/);
    const releaseNew=await claimDashboard(scope,{pid:2,startedAt:'new'},async()=>false);
    release();assert.ok(readJson(join(home,'dashboards',identity(scope.id)+'.json')),'old release removed new owner');releaseNew();
    writeJson(join(home,'scopes/one.json'),{...scope,owner,closed:true});
    writeJson(join(home,'scopes/two.json'),{id:'two',home,owner,closed:false});
    processHook('PermissionRequest',{session_id:'a'},{home,owner,scope:'one',interactive:true,now:1});
    const cleared=[];await cleanupStaleScopes(home,async()=>true,async effect=>cleared.push(effect));
    assert.equal(cleared.length,1);assert.equal(readJson(join(home,'scopes/one.json')),undefined);assert.ok(readJson(join(home,'scopes/two.json')));
  }finally{rmSync(home,{recursive:true,force:true});}
});
