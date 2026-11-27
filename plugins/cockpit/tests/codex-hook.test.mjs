import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, rmSync, readFileSync, readdirSync, writeFileSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { reduceSession, processHook } from '../codex/hook.mjs';
import { identity } from '../codex/state.mjs';

test('supported events reduce without recording content or deciding permissions', () => {
  let state;
  const payload = { session_id: 'one', cwd: 'C:/work', model: 'gpt-6-astra', prompt: 'PRIVATE', transcript_path: 'do-not-open', tool_input: { secret: 'PRIVATE' } };
  const step = (event, extra = {}) => state = reduceSession(state, event, { ...payload, ...extra }, 1000);
  step('SessionStart'); assert.equal(state.phase, 'starting');
  step('UserPromptSubmit'); assert.equal(state.phase, 'running');
  step('PermissionRequest'); assert.equal(state.phase, 'waiting');
  assert.equal(state.waitKind, 'approval');
  const generation = state.generation;
  step('PermissionRequest'); assert.equal(state.generation, generation);
  step('PostToolUse'); assert.equal(state.phase, 'running');
  step('PostModelRequest', { status: 'failed', error: 'PRIVATE', token_usage: { input_tokens: 14, output_tokens: 4 } });
  assert.equal(state.phase, 'error'); assert.equal(state.usage.input_tokens, 14);
  step('Stop', { last_assistant_message: 'PRIVATE' }); assert.equal(state.phase, 'error');
  step('UserPromptSubmit'); step('Stop'); assert.equal(state.phase, 'stopped');
  step('Interrupt'); assert.equal(state.phase, 'interrupted');
  step('SessionEnd'); assert.equal(state.phase, 'ended');
  assert.doesNotMatch(JSON.stringify(state), /PRIVATE|transcript|tool_input|last_assistant/);
});

test('persisted sessions isolate identities, dedupe notifications and clear on input', () => {
  const home = mkdtempSync(join(tmpdir(), 'cockpit-hook-'));
  try {
    const effects = [];
    const options = { home, now: 1000, notify: (effect) => effects.push(effect), interactive: true, owner: { pid: process.pid, startedAt: 'fixture' } };
    processHook('SessionStart', { session_id: 'a' }, options);
    processHook('UserPromptSubmit', { session_id: 'a' }, options);
    processHook('PermissionRequest', { session_id: 'a' }, options);
    processHook('PermissionRequest', { session_id: 'a' }, { ...options, now: 1100 });
    processHook('PermissionRequest', { session_id: 'b' }, options);
    assert.equal(effects.filter(x => x.kind === 'permission').length, 2);
    processHook('UserPromptSubmit', { session_id: 'a' }, options);
    assert.equal(effects.at(-1).action, 'clear');
    processHook('PostModelRequest', { session_id: 'a', status: 'cancelled' }, options);
    assert.equal(effects.at(-1).kind, 'interrupt');
    const files = readdirSync(join(home, 'sessions')).filter(x => x.endsWith('.json'));
    assert.equal(files.length, 2);
    for (const file of files) assert.doesNotMatch(readFileSync(join(home, 'sessions', file), 'utf8'), /prompt|transcript/);
    const count = effects.length;
    processHook('PermissionRequest', { session_id: 'headless' }, { ...options, interactive: false });
    assert.equal(effects.length, count);
  } finally { rmSync(home, { recursive: true, force: true }); }
});

test('resolved approvals are cleared without replaying stale permission effects', () => {
  const home = mkdtempSync(join(tmpdir(), 'cockpit-hook-resolution-'));
  try {
    const options = { home, interactive: true, now: 1000 };
    const step = (event, extra = {}, now = 1000) => processHook(event, { session_id: 'a', ...extra }, { ...options, now });
    step('UserPromptSubmit'); step('PermissionRequest');
    let state = step('PostModelRequest', { status: 'completed' }, 1100);
    assert.equal(state.phase, 'running'); assert.equal(state.waitKind, undefined); assert.equal(state.effect.action, 'clear');
    state = step('Stop', {}, 1200);
    assert.equal(state.waitKind, undefined); assert.equal(state.effect.action, 'clear');
    step('UserPromptSubmit', {}, 2000); state = step('PermissionRequest', {}, 2100);
    assert.equal(state.effect.kind, 'permission');
    state = step('Stop', {}, 2200); assert.equal(state.effect.action, 'clear'); assert.equal(state.waitKind, undefined);
    for (const [event, extra, kind] of [['PostModelRequest', { status: 'failed' }, 'error'], ['PostModelRequest', { status: 'cancelled' }, 'interrupt'], ['Interrupt', {}, 'interrupt']]) {
      step('UserPromptSubmit'); step('PermissionRequest'); state = step(event, extra);
      assert.equal(state.waitKind, undefined); assert.equal(state.effect.kind, kind);
      state = step('Stop'); assert.notEqual(state.effect.kind, 'permission');
    }
    step('UserPromptSubmit'); step('PermissionRequest'); state = step('SessionEnd');
    assert.equal(state.waitKind, undefined); assert.equal(state.effect.action, 'clear');
    step('UserPromptSubmit'); step('PermissionRequest'); state = step('UserPromptSubmit');
    assert.equal(state.waitKind, undefined); assert.equal(state.effect.action, 'clear');
    state = step('PermissionRequest'); const firstEffect = state.effectId;
    state = step('PermissionRequest', {}, 20999); assert.equal(state.effectId, firstEffect);
    state = step('PermissionRequest', {}, 21000); assert.notEqual(state.effectId, firstEffect);
    state = step('SessionStart'); assert.equal(state.waitKind, undefined); assert.equal(state.effect.action, 'clear');
    step('UserPromptSubmit');
    step('PermissionRequest'); state = step('Stop', {}, 122000);
    assert.equal(state.effect.kind, 'done'); assert.equal(state.effect.toast, true);
  } finally { rmSync(home, { recursive: true, force: true }); }
});

test('command hook always produces neutral JSON, including malformed input', () => {
  for (const input of ['{bad', JSON.stringify({ session_id: 'a', transcript_path: 'unreadable', last_assistant_message: 'PRIVATE' })]) {
    const run = spawnSync(process.execPath, ['plugins/cockpit/codex/hook.mjs', 'Stop'], { input, encoding: 'utf8', env: { ...process.env, CODEX_COCKPIT_SCOPE: '' } });
    assert.equal(run.status, 0); assert.deepEqual(JSON.parse(run.stdout), {});
    assert.equal(run.stderr, '');
  }
});

test('session locks preserve unknown and live owners and reclaim an owned dead process', () => {
  const home = mkdtempSync(join(tmpdir(), 'cockpit-hook-lock-'));
  try {
    const key = identity(':locked');
    const lock = join(home, 'sessions', `${key}.json.lock`);
    mkdirSync(lock, { recursive: true });
    const invoke = () => processHook('UserPromptSubmit', { session_id: 'locked' }, { home, interactive: true });
    assert.equal(invoke(), undefined);
    writeFileSync(join(lock, 'owner.json'), JSON.stringify({ key, pid: process.pid }));
    assert.equal(invoke(), undefined);
    writeFileSync(join(lock, 'owner.json'), JSON.stringify({ key, pid: 2147483647 }));
    assert.equal(invoke().phase, 'running');
    assert.equal(existsSync(lock), false);
  } finally { rmSync(home, { recursive: true, force: true }); }
});
