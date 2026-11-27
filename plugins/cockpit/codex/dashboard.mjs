import { readdirSync, readFileSync, statSync, mkdirSync, openSync, closeSync, writeFileSync, unlinkSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { execFile } from 'node:child_process';
import { setTimeout as delay } from 'node:timers/promises';
import { outcomeOf } from '../core/readings.ts';
import { pipelineHome, readJson, writeJson, identity } from './state.mjs';
import { refreshGithub } from './github.mjs';

const list = (path, limit = 200) => { try { return readdirSync(path, { withFileTypes: true }).slice(0, limit); } catch { return []; } };
const text = (path, max = 65536) => { try { return statSync(path).size <= max ? readFileSync(path, 'utf8').replace(/^\uFEFF/, '') : ''; } catch { return ''; } };
const line = value => String(value || '').split(/\r?\n/).map(x => x.replace(/^[#>*\-\s]+/, '')).find(Boolean) || '';
async function processStartTime(pid) {
  if (!Number.isInteger(pid) || pid <= 0) return undefined;
  return new Promise(resolveAlive => {
    execFile('pwsh', ['-NoProfile', '-NonInteractive', '-Command', 'try { (Get-Process -Id ([int]$env:COCKPIT_OWNER_PID) -ErrorAction Stop).StartTime.ToUniversalTime().ToString("o") } catch { exit 1 }'],
      { env: { ...process.env, COCKPIT_OWNER_PID: String(pid) }, windowsHide: true, timeout: 5000, maxBuffer: 1024 },
      (error, output) => resolveAlive(error ? undefined : output.trim()));
  });
}
export async function ownerAlive(owner) {
  if (!Number.isInteger(owner?.pid) || owner.pid <= 0 || !Number.isFinite(Date.parse(owner.startedAt || ''))) return false;
  return Date.parse(await processStartTime(owner.pid) || '') === Date.parse(owner.startedAt);
}
export async function claimDashboard(scope, owner, isAlive = ownerAlive) {
  const directory=join(scope.home,'dashboards');mkdirSync(directory,{recursive:true});
  const path=join(directory,`${identity(scope.id)}.json`);
  const previous=readJson(path);
  if(previous){
    if(previous.scope!==scope.id || await isAlive(previous.owner))throw new Error('This session already has a companion.');
    if(readJson(path)?.token!==previous.token)throw new Error('Companion ownership changed.');
    unlinkSync(path);
  }
  const token=identity(`${process.pid}:${Date.now()}:${Math.random()}`);
  const fd=openSync(path,'wx');try{writeFileSync(fd,JSON.stringify({scope:scope.id,owner,token}));}finally{closeSync(fd);}
  return ()=>{if(readJson(path)?.token===token)unlinkSync(path);};
}
export async function cleanupStaleScopes(home, isAlive = ownerAlive, send = windowsNotify) {
  for(const file of list(join(home,'scopes'),20).filter(x=>x.isFile()&&x.name.endsWith('.json'))){
    const path=join(home,'scopes',file.name);const scope=readJson(path);
    if(!scope?.id||!scope.owner||scope.cleaned||!scope.closed&&await isAlive(scope.owner))continue;
    for(const sessionFile of list(join(home,'sessions',identity(scope.id)),100).filter(x=>x.isFile()&&x.name.endsWith('.json'))){
      const session=readJson(join(home,'sessions',identity(scope.id),sessionFile.name));
      if(session?.scope===scope.id&&session.effect?.tag)await send({action:'clear',tag:session.effect.tag},scope.owner);
    }
    if(readJson(path)?.id===scope.id)unlinkSync(path);
  }
}
export async function snapshot({ pipelineHome: home = pipelineHome(), stateHome = join(home, 'cockpit/codex'), scope, now = Date.now(), isAlive = ownerAlive, offline = false } = {}) {
  const runsRoot = join(home, 'runs');
  const locks = [];
  for (const file of list(join(runsRoot, '.locks'), Infinity).filter(x => x.isFile() && x.name.endsWith('.json'))) {
    const lock = readJson(join(runsRoot, '.locks', file.name));
    if (typeof lock?.runDir === 'string') locks.push(lock);
  }
  const history = [];
  for (const alias of list(runsRoot, Infinity).filter(x => x.isDirectory() && !x.name.startsWith('.'))) {
    for (const dir of list(join(runsRoot, alias.name), Infinity).filter(x => x.isDirectory())) {
      const path = resolve(runsRoot, alias.name, dir.name);
      try {
        const modifiedAt = statSync(path).mtimeMs;
        const datedAt = /^\d{4}-\d{2}-\d{2}(?:-|$)/.test(dir.name) ? Date.parse(dir.name.slice(0, 10)) : NaN;
        history.push({ path, name: `${alias.name}/${dir.name}`, at: Number.isFinite(datedAt) ? datedAt : modifiedAt, modifiedAt });
      } catch {}
    }
  }
  history.sort((a, b) => b.at - a.at || b.modifiedAt - a.modifiedAt || b.name.localeCompare(a.name));
  const candidates = new Map(history.slice(0, 100).map(x => [x.path, x.name]));
  for (const lock of locks) {
    const path = resolve(lock.runDir);
    if (path.toLowerCase().startsWith(resolve(runsRoot).toLowerCase() + (process.platform === 'win32' ? '\\' : '/'))) candidates.set(path, path.slice(resolve(runsRoot).length + 1));
  }
  const runs = [];
  for (const [path, name] of candidates) {
    const meta = readJson(join(path, 'meta.json'));
    const lock = locks.find(x => resolve(x.runDir).toLowerCase() === path.toLowerCase());
    const alive = lock && !offline ? await isAlive({ pid: lock.pid, startedAt: lock.processStartTime }) : false;
    const priority = Boolean(lock && !meta?.endedAt && (offline || alive));
    const unknown = offline && lock ? 'liveness unknown (offline)' : 'unknown / abandoned';
    if (!meta) { runs.push({ name, priority, startedAt: Date.parse(lock?.startedAt || ''), phase: alive ? 'pending' : 'unknown', outcome: { title: alive ? 'starting (live owner)' : unknown } }); continue; }
    const startedAt = Date.parse(meta.startedAt || '');
    const current = filename => { try { return statSync(join(path, filename)).mtimeMs >= startedAt - 1000; } catch { return false; } };
    const gateFile = readJson(join(path, 'gate.json'));
    const gate = gateFile && Date.parse(gateFile.startedAt || '') >= startedAt ? gateFile : meta.gate;
    const progress = current('progress.md') ? line(text(join(path, 'progress.md')).replace(/^\s*#{1,6}\s+.*$/gm,'')) : '';
    const report = current('report.md') ? line(text(join(path, 'report.md'))) : '';
    const usage = current('task-usage.json') ? readJson(join(path, 'task-usage.json')) : undefined;
    const phase = meta.endedAt ? 'ended' : alive ? gate && !gate.endedAt ? 'gate' : 'running' : 'unknown';
    const outcome = meta.endedAt ? outcomeOf({ ...meta, gate, reportPresent: Boolean(report) }) : { title: phase === 'unknown' ? unknown : phase };
    runs.push({ name, priority, phase, outcome, progress, report, startedAt, usageAvailable: Boolean(usage) });
  }
  runs.sort((a, b) => Number(b.priority) - Number(a.priority) || (b.startedAt || 0) - (a.startedAt || 0));
  const saved = readJson(join(home, 'logs/quota/last-good.json'));
  const quotaAt = Date.parse(saved?.fetchedAtUtc || '');
  const provider = Array.isArray(saved?.quota?.providers) ? saved.quota.providers.find(x => x?.id === 'codex') : undefined;
  const windows = Array.isArray(provider?.windows) ? provider.windows.filter(x => Number.isFinite(x?.usedPct)).map(x => ({ label: x.label || x.name || x.id || 'window', usedPct: x.usedPct, resetsAt: x.resetsAt })) : [];
  const quota = { fetchedAt: Number.isFinite(quotaAt) ? quotaAt : undefined, stale: !Number.isFinite(quotaAt) || now - quotaAt >= 600000 || now < quotaAt - 5000 || provider?.available !== true || !windows.length || windows.some(x=>Number.isFinite(Date.parse(x.resetsAt || '')) && now>=Date.parse(x.resetsAt)), windows };
  const sessionRoot = join(stateHome, 'sessions');
  const sessionDirs = scope ? [join(sessionRoot,identity(scope))] : [sessionRoot,...list(sessionRoot,100).filter(x=>x.isDirectory()).map(x=>join(sessionRoot,x.name))];
  const sessions = sessionDirs.flatMap(dir=>list(dir,100).filter(x => x.isFile() && x.name.endsWith('.json')).map(x => ({ ...readJson(join(dir,x.name)), file: join(dir,x.name) }))).filter(x => x.sessionId && (!scope || x.scope === scope));
  return { now, runs, quota, sessions };
}
const clean = value => String(value ?? '').replace(/[\x00-\x1f\x7f-\x9f]/g, ' ').replace(/[\u202a-\u202e\u2066-\u2069]/g, '');
const columns = (value, width) => {
  let used=0;let result='';
  for(const char of clean(value)){
    const code=char.codePointAt(0);
    const size=/\p{Mark}/u.test(char)?0:code>=0x1100&&(code<=0x115f||code>=0x2e80&&code<=0xa4cf||code>=0xac00&&code<=0xd7a3||code>=0xf900&&code<=0xfaff||code>=0xfe10&&code<=0xfe6f||code>=0xff01&&code<=0xff60||code>=0x1f300)?2:1;
    if(used+size>width)break;result+=char;used+=size;
  }
  return result;
};
export function render(value, width = 100, rows = 30) {
  width = Math.max(12, Math.min(240, Number(width) || 100)); rows = Math.max(4, Math.min(60, Number(rows) || 30));
  const age = at => Number.isFinite(at) ? `${Math.max(0, Math.floor((value.now - at) / 1000))}s` : 'unknown';
  const lines = ['Codex Cockpit (read only)', `quota ${value.quota.stale ? 'stale' : 'current'} ${age(value.quota.fetchedAt)}: ${value.quota.windows.map(x => `${x.label} ${x.usedPct}%`).join(' | ') || 'unknown'}`];
  for (const session of value.sessions.slice(0, 3)) {
    const stale=!Number.isFinite(session.updatedAt)||value.now-session.updatedAt>=60000;
    lines.push(`session ${stale?'last known / stale ':''}${session.phase} ${session.model || ''} (${age(session.updatedAt)})`);
    if (session.usage && Object.keys(session.usage).length) lines.push(`last request tokens ${Object.entries(session.usage).map(([k,v])=>`${k}=${v}`).join(' ')} (${age(session.usageAt)}; historical)`);
  }
  lines.push('context: native statusline; exact breakdown unknown');
  for (const [key, ttl] of [['prs',300000],['runners',60000]]) {
    const reading = value.github?.[key];
    lines.push(`${key} ${!reading?.fetchedAt ? 'unknown' : reading.error || value.now - reading.fetchedAt >= ttl ? 'stale' : 'current'} (${age(reading?.fetchedAt)})`);
    if (key === 'prs') for (const pr of (reading?.rows || []).slice(0, 8)) lines.push(`  ${pr.repo} #${pr.number}: ${pr.verdict}`);
    else for (const repo of (reading?.rows || []).slice(0, 8)) lines.push(`  ${repo.repo}: ${repo.runners.map(x => `${x.name} ${x.status}${x.busy ? ' busy' : ''}`).join(', ') || 'no runners'} ${repo.workflows.map(x => `${x.name} ${x.status}`).join(', ')}`);
  }
  for (const run of value.runs.slice(0, 12)) { lines.push(`${run.name}: ${run.outcome.title}`); if (run.progress || run.report) lines.push(`  ${run.progress || run.report}`); }
  return lines.slice(0, rows).map(x => columns(x,width)).join('\n');
}

export async function monitor({ owner, isAlive = ownerAlive, read, draw, dispose = () => {}, signal, intervalMs = 3000 }) {
  try {
    while (!signal?.aborted && await isAlive(owner)) {
      const value = await read();
      if (signal?.aborted || !await isAlive(owner)) break;
      await draw(value);
      try { await delay(Math.max(1, intervalMs), undefined, { signal }); } catch { break; }
    }
  } finally { await dispose(); }
}

export function windowsNotify(effect, owner) {
  const script = fileURLToPath(new URL('../scripts/notify.ps1', import.meta.url));
  return new Promise(resolveNotify => {
    const clear = effect.action === 'clear';
    execFile('powershell.exe', ['-NoProfile','-NonInteractive','-File',script], { windowsHide: true, timeout: 10000, env: {
      ...process.env, CC_NOTIFY_AUMID:'Codex.Cockpit', CC_NOTIFY_GROUP:'codex-cockpit', CC_NOTIFY_APP:'Codex',
      CC_NOTIFY_OWNER_PID:String(owner.pid), CC_NOTIFY_OWNER_START:owner.startedAt,
      CC_NOTIFY_CACHE:join(process.env.LOCALAPPDATA || pipelineHome(), 'CodexCockpit/notify'),
      CC_NOTIFY_TAG:effect.tag, CC_NOTIFY_TITLE:effect.title || '', CC_NOTIFY_TEXT:'', CC_NOTIFY_FOLDER:'Codex',
      CC_NOTIFY_KIND:effect.kind === 'interrupt' ? 'error' : effect.kind || 'done',
      CC_NOTIFY_RING:clear || effect.kind === 'interrupt' ? '0;0' : effect.kind === 'permission' ? '4;100' : effect.kind === 'done' ? '1;100' : '2;100',
      CC_NOTIFY_TOAST:clear ? 'remove' : effect.toast ? 'show' : '', CC_NOTIFY_SOUND:process.env.CODEX_COCKPIT_MUTE === '1' ? '0' : '1',
    } }, () => resolveNotify());
  });
}

export function notificationDelivery(owner, send = windowsNotify) {
  const delivered = new Map();
  return {
    async update(sessions) {
      for (const session of sessions) {
        if (!session.effectId || delivered.get(session.file)?.id === session.effectId || session.owner?.pid !== owner.pid || session.owner?.startedAt !== owner.startedAt) continue;
        const latest = readJson(session.file);
        if (latest?.effectId !== session.effectId || latest?.generation !== session.effect.generation) continue;
        await send(session.effect, owner);
        delivered.set(session.file, { id: session.effectId, tag:session.effect.tag });
      }
    },
    async clear() { for (const value of delivered.values()) await send({ action:'clear',tag:value.tag }, owner); delivered.clear(); },
  };
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const args = process.argv.slice(2); const option = name => args[args.indexOf(name) + 1];
  const home = args.includes('--pipeline-home') ? option('--pipeline-home') : pipelineHome();
  const once = args.includes('--once'); const offline = once || args.includes('--offline');
  const scopePath = args.includes('--scope') ? option('--scope') : undefined;
  const scope = readJson(scopePath);
  const width = () => args.includes('--width') ? Number(option('--width')) : process.stdout.columns || 100;
  if (once) process.stdout.write(render(await snapshot({pipelineHome:home,offline:true}), width()) + '\n');
  else if (!scope?.owner || !process.stdout.isTTY) { process.stderr.write('Use --once --offline, or start through start-codex.ps1 in a terminal.\n'); process.exitCode = 1; }
  else {
    const release=await claimDashboard(scope,{pid:process.pid,startedAt:await processStartTime(process.pid)});
    await cleanupStaleScopes(scope.home);
    const controller = new AbortController(); for (const event of ['SIGINT','SIGTERM','SIGHUP']) process.on(event,()=>controller.abort());
    process.stdout.on('error',()=>controller.abort());
    const delivery = notificationDelivery(scope.owner); let github = {}; let nextPr = 0; let nextRunner = 0;
    const alive = async owner=>{const current=readJson(scopePath);return current?.id===scope.id && !current.closed && await ownerAlive(owner);};
    let checking=false;
    const ownerWatch=setInterval(async()=>{
      if(checking)return;checking=true;
      try{if(!await alive(scope.owner))controller.abort();}finally{checking=false;}
    },3000);
    await monitor({ owner:scope.owner, signal:controller.signal,
      isAlive:alive,
      read:async()=>{
        const value = await snapshot({pipelineHome:home,stateHome:scope.home,scope:scope.id,offline});
        if (!offline && (value.now >= nextPr || value.now >= nextRunner)) {
          const registry = readJson(join(home,'config/executors.json')) || {};
          github = await refreshGithub({registry,cwd:scope.cwd,previous:github,signal:controller.signal,prs:value.now>=nextPr,runners:value.now>=nextRunner});
          if (value.now>=nextPr) nextPr=value.now+300000; if(value.now>=nextRunner) nextRunner=value.now+60000;
        }
        return {...value,github};
      },
      draw:async value=>{ process.stdout.write('\x1b[H\x1b[2J'+render(value,width(),process.stdout.rows ? process.stdout.rows-1 : 30)+'\n'); await delivery.update(value.sessions); },
      dispose:async()=>{clearInterval(ownerWatch);controller.abort();try{await delivery.clear();}finally{release();}},
    });
  }
}
