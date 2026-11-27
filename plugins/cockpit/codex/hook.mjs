import { mkdirSync, rmdirSync, unlinkSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { identity, readJson, writeJson } from './state.mjs';

export const events = ['SessionStart', 'SessionEnd', 'UserPromptSubmit', 'PermissionRequest', 'PostToolUse', 'PostModelRequest', 'Stop', 'Interrupt'];
export function reduceSession(previous, event, payload, now = Date.now()) {
  const state = { ...(previous || {}), sessionId: String(payload.session_id).slice(0, 128), event, updatedAt: now };
  if (typeof payload.cwd === 'string') state.cwd = payload.cwd.slice(0, 2048);
  if (typeof payload.model === 'string') state.model = payload.model.slice(0, 100);
  state.generation ||= 0;
  if (event === 'SessionStart') { state.phase = 'starting'; state.waitKind = undefined; }
  if (event === 'UserPromptSubmit') { state.phase = 'running'; state.waitKind = undefined; state.turnStartedAt = now; state.generation++; }
  if (event === 'PermissionRequest' && state.phase !== 'waiting') { state.phase = 'waiting'; state.waitKind = 'approval'; state.generation++; }
  if (event === 'PostToolUse') { state.phase = 'running'; state.waitKind = undefined; }
  if (event === 'PostModelRequest') {
    if (payload.status === 'failed') state.phase = 'error';
    else if (payload.status === 'cancelled') state.phase = 'interrupted';
    else if (payload.status === 'completed') state.phase = 'running';
    if (payload.token_usage && typeof payload.token_usage === 'object') {
      state.usage = {};
      for (const key of ['input_tokens', 'output_tokens', 'total_tokens', 'cached_input_tokens']) {
        const value = payload.token_usage[key];
        if (Number.isSafeInteger(value) && value >= 0) state.usage[key] = value;
      }
      state.usageAt = now;
    }
  }
  if (event === 'Stop' && !['error', 'interrupted'].includes(state.phase)) { state.phase = 'stopped'; state.waitKind = undefined; }
  if (event === 'Interrupt') { state.phase = 'interrupted'; state.waitKind = undefined; }
  if (event === 'SessionEnd') { state.phase = 'ended'; state.waitKind = undefined; }
  if (state.phase !== 'waiting') state.waitKind = undefined;
  return state;
}

export function processHook(event, payload, { home, owner, scope, interactive = false, now = Date.now(), notify } = {}) {
  if (!events.includes(event) || typeof payload?.session_id !== 'string' || !home || !interactive) return;
  const key = identity(`${scope || ''}:${payload.session_id}`);
  const directory = scope ? join(home, 'sessions', identity(scope)) : join(home, 'sessions');
  const path = join(directory, `${key}.json`);
  mkdirSync(directory, { recursive: true });
  const lock = `${path}.lock`;
  // Never delay or block the agent if a hook is already updating this session.
  try { mkdirSync(lock); } catch {
    const held=readJson(join(lock,'owner.json'));
    if(held?.key!==key || !Number.isInteger(held.pid) || held.pid<=0)return;
    try{process.kill(held.pid,0);return;}catch(error){if(error.code!=='ESRCH')return;}
    try{unlinkSync(join(lock,'owner.json'));rmdirSync(lock);mkdirSync(lock);}catch{return;}
  }
  writeFileSync(join(lock,'owner.json'),JSON.stringify({key,pid:process.pid}));
  try {
    const previous = readJson(path);
    const state = reduceSession(previous, event, payload, now);
    state.owner = owner; state.scope = scope;
    let effect;
    const effectBase = { tag: key.slice(0, 16), generation: state.generation, at: now };
    if (event === 'UserPromptSubmit' || event === 'PostToolUse' && previous?.phase === 'waiting' || event === 'SessionEnd') effect = { ...effectBase, action: 'clear' };
    else if (state.phase === 'waiting' && (previous?.phase !== 'waiting' || now - (previous.effect?.at || 0) >= 20000)) effect = { ...effectBase, action: 'show', kind: 'permission', title: 'Codex approval requested', toast: true };
    else if (state.phase === 'error' && previous?.phase !== 'error') effect = { ...effectBase, action: 'show', kind: 'error', title: 'Codex model request failed', toast: true };
    else if (state.phase === 'interrupted' && previous?.phase !== 'interrupted') effect = { ...effectBase, action: 'show', kind: 'interrupt', title: 'Codex interrupted', toast: true };
    else if (event === 'Stop' && state.phase === 'stopped' && previous?.phase !== 'stopped') {
      const toast = now - (state.turnStartedAt || now) >= 120000;
      effect = !toast && (previous?.phase === 'waiting' || previous?.effect?.action === 'clear' && previous.effect.kind === 'permission') ? { ...effectBase, action: 'clear' } : { ...effectBase, action: 'show', kind: 'done', title: 'Codex turn stopped', toast };
    }
    else if (previous?.phase === 'waiting' && state.phase !== 'waiting') effect = { ...effectBase, action: 'clear' };
    if (effect?.action === 'clear' && previous?.phase === 'waiting') effect.kind = 'permission';
    if (effect) { state.effect = effect; state.effectId = identity(JSON.stringify(effect)); }
    writeJson(path, state);
    if (effect && notify) notify(effect);
    return state;
  } finally { unlinkSync(join(lock,'owner.json'));rmdirSync(lock); }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  // Stop requires a JSON object. Every event uses the same neutral response;
  // no decision, continuation, tool replacement or model feedback is returned.
  try {
    let input = '';
    for await (const chunk of process.stdin) { input += chunk; if (input.length > 1048576) throw new Error('oversized'); }
    const scope = readJson(process.env.CODEX_COCKPIT_SCOPE);
    if (scope?.id && scope?.home && scope?.owner) processHook(process.argv[2], JSON.parse(input), { ...scope, interactive: true, scope: scope.id });
  } catch { /* Notifications must not change CLI behavior. */ }
  process.stdout.write('{}\n');
}
