import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync, realpathSync, symlinkSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createInterface } from 'node:readline';

test('installed Codex applies exact SKILL.md path suppression (local protocol only)', {timeout:60000}, async () => {
  const work=mkdtempSync(join(tmpdir(),'cockpit-native-'));
  try {
  const skill=join(work,'home/.codex/skills/cockpit-native-fixture/SKILL.md');
  mkdirSync(join(skill,'..'),{recursive:true});mkdirSync(join(work,'repo'),{recursive:true});
  writeFileSync(skill,'---\nname: cockpit-native-fixture\ndescription: Local fixture, never execute.\n---\nNo actions.\n');
  const source=join(work,'source');mkdirSync(source);
  writeFileSync(join(source,'SKILL.md'),'---\nname: cockpit-linked-fixture\ndescription: Linked fixture.\n---\nNo actions.\n');
  const linked=join(work,'home/.codex/skills/cockpit-linked-fixture');symlinkSync(source,linked,'junction');
  writeFileSync(join(work,'home/.codex/config.toml'),'');
  const setup=spawnSync('pwsh',['-NoProfile','-File','plugins/cockpit/codex/setup.ps1','-CodexHome',join(work,'home/.codex'),'-ClaudeHome',join(work,'claude'),'-AgentsSkills',join(work,'agents/skills'),'-PipelineHome',join(work,'state')],{encoding:'utf8',windowsHide:true});
  assert.equal(setup.status,0,setup.stderr);
  const disabled=[skill,join(linked,'SKILL.md')].map(path=>`{path=${JSON.stringify(path.replaceAll('\\','/'))},enabled=false}`).join(',');
  const child=spawn(process.env.CODEX_NATIVE_EXE || 'codex.exe',['--enable','hooks','-c',`skills.config=[${disabled}]`,'app-server'],{
    cwd:join(work,'repo'),windowsHide:true,env:{...process.env,CODEX_HOME:join(work,'home/.codex'),USERPROFILE:join(work,'home'),HOME:join(work,'home')},stdio:['pipe','pipe','pipe'],
  });
  const pending=new Map();let next=0;
  const lines=createInterface({input:child.stdout});
  lines.on('line',line=>{try{const value=JSON.parse(line);if(pending.has(value.id)){const resolve=pending.get(value.id);pending.delete(value.id);resolve(value);}}catch{}});
  child.stderr.resume();
  const request=(method,params)=>new Promise((resolveRequest,reject)=>{
    const id=++next;const timeout=setTimeout(()=>{pending.delete(id);reject(new Error(`Local protocol timed out: ${method}`));},10000);
    pending.set(id,value=>{clearTimeout(timeout);if(value.error)reject(new Error(`Local protocol rejected ${method}: ${value.error.code}`));else resolveRequest(value.result);});
    child.stdin.write(JSON.stringify({id,method,params})+'\n');
  });
  const exited=new Promise(resolveExit=>{child.on('error',()=>resolveExit());child.on('close',()=>resolveExit());});
  try {
    await request('initialize',{clientInfo:{name:'cockpit-fixture',version:'1'},capabilities:{experimentalApi:true}});
    child.stdin.write('{"method":"initialized"}\n');
    const result=await request('skills/list',{cwds:[join(work,'repo')],forceReload:true});
    const skills=(result.data || []).flatMap(x=>x.skills || []);
    const found=skills.find(x=>x.name==='cockpit-native-fixture');
    assert.ok(found,'fixture skill not discovered');assert.equal(found.enabled,false,'exact path was not disabled');
    assert.equal(skills.find(x=>x.name==='cockpit-linked-fixture')?.enabled,false,'linked discovered path was not disabled');
    assert.equal(realpathSync.native(found.path).toLowerCase(),realpathSync.native(skill).toLowerCase());
    const hooks=await request('hooks/list',{cwds:[join(work,'repo')]});
    assert.equal(hooks.data[0].errors.length,0,'native hook configuration rejected');
    assert.deepEqual(hooks.data[0].warnings,[],'native hook configuration warning');
    assert.equal(hooks.data[0].hooks.length,8,`not all supported command hooks loaded: ${JSON.stringify(hooks)}`);
    assert.ok(hooks.data[0].hooks.every(h=>h.trustStatus !== 'trusted'),'installer unexpectedly trusted hooks');
    assert.ok(hooks.data[0].hooks.every(h=>h.timeoutSec===3),'native hook timeout was not applied');
  } finally {
    child.stdin.end();
    const cleanup=setTimeout(()=>{spawn('taskkill.exe',['/pid',String(child.pid),'/t','/f'],{windowsHide:true,stdio:'ignore'});},5000);
    await exited;clearTimeout(cleanup);lines.close();
  }
  } finally { rmSync(work,{recursive:true,force:true,maxRetries:10,retryDelay:100}); }
});
