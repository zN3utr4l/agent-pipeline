'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const test = require('node:test');

const root = path.resolve(__dirname, '../skills/pipeline');
const cli = path.join(root, 'bin', 'task-usage.js');
const numeric = ['cost', 'calls', 'turns', 'inputTokens', 'outputTokens', 'cacheReadTokens', 'cacheWriteTokens', 'durationMs'];

function tempDir(t) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'task-usage-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  return dir;
}

function row(sessionId, values = {}) {
  return {
    sessionId,
    title: `SECRET TITLE ${sessionId}`,
    project: `SECRET PROJECT ${sessionId}`,
    provider: values.provider || 'codex',
    models: values.models || ['gpt-test'],
    cost: 1,
    calls: 2,
    turns: 3,
    inputTokens: 100,
    outputTokens: 20,
    cacheReadTokens: 30,
    cacheWriteTokens: 10,
    startedAt: '2026-09-14T08:00:00.000Z',
    endedAt: '2026-09-14T08:05:00.000Z',
    durationMs: 300000,
    ...values
  };
}

function writeJson(file, value) {
  fs.writeFileSync(file, JSON.stringify(value));
}

function run(args) {
  return spawnSync(process.execPath, [cli, ...args], { cwd: root, encoding: 'utf8' });
}

test('automatic finish metadata without a session is advisory, explicit metadata remains strict', t => {
  const dir = tempDir(t);
  const snapshot = path.join(dir, 'snapshot.json');
  writeJson(snapshot, []);
  writeJson(path.join(dir, 'meta.json'), { sessionId: null });
  assert.equal(run(['--phase', 'start', '--run-dir', dir, '--snapshot', snapshot]).status, 0);
  const explicit = run(['--phase', 'finish', '--run-dir', dir, '--meta', path.join(dir, 'meta.json'), '--snapshot', snapshot]);
  assert.equal(explicit.status, 2);
  const result = run(['--phase', 'finish', '--run-dir', dir, '--snapshot', snapshot]);
  assert.equal(result.status, 0, result.stderr);
  const artifact = JSON.parse(fs.readFileSync(path.join(dir, 'task-usage.json')));
  assert.equal(artifact.status, 'incomplete');
  assert.ok(artifact.issues.some(issue => issue.reason === 'no-selected-sessions'));
});

test('selected deltas, cache arithmetic, resume dedup, and privacy projection', t => {
  const dir = tempDir(t);
  const before = path.join(dir, 'before.json');
  const after = path.join(dir, 'after.json');
  const meta = path.join(dir, 'meta.json');
  writeJson(before, [row('root'), row('worker', { provider: 'claude', cost: 2, inputTokens: 200 })]);
  writeJson(meta, { sessionId: 'root', executor: 'codex', title: 'META SECRET', credentials: 'NOPE' });

  let result = run(['--phase', 'start', '--run-dir', dir, '--session', 'root', '--session', 'root', '--meta', meta, '--snapshot', before]);
  assert.equal(result.status, 0, result.stderr);
  const start = JSON.parse(fs.readFileSync(path.join(dir, 'task-usage-start.json')));
  assert.equal(start.baselines.length, 2, 'start retains all readable rows');
  assert.equal(start.selection.length, 1, 'repeated explicit/meta IDs deduplicate');
  assert.deepEqual(Object.keys(start.baselines[0]), ['sessionId', 'provider', 'startedAt', ...numeric]);

  writeJson(after, [
    row('root', { cost: 1.5, calls: 4, turns: 5, inputTokens: 130, outputTokens: 25, cacheReadTokens: 50, cacheWriteTokens: 14, durationMs: 360000 }),
    row('worker', { provider: 'claude', cost: 3, calls: 5, turns: 7, inputTokens: 260, outputTokens: 28, cacheReadTokens: 45, cacheWriteTokens: 16, durationMs: 420000 })
  ]);
  result = run(['--phase', 'finish', '--run-dir', dir, '--session', 'root', '--session', 'worker', '--session', 'worker', '--snapshot', after]);
  assert.equal(result.status, 0, result.stderr);
  const usagePath = path.join(dir, 'task-usage.json');
  const usage = JSON.parse(fs.readFileSync(usagePath));
  assert.equal(usage.status, 'complete');
  assert.equal(usage.sessions.length, 2);
  const rootRow = usage.sessions.find(x => x.sessionId === 'root');
  assert.deepEqual(rootRow.delta, {
    cost: 0.5, calls: 2, turns: 2, inputTokens: 30, outputTokens: 5,
    cacheReadTokens: 20, cacheWriteTokens: 4, durationMs: 60000, totalTokens: 59
  });
  assert.equal(usage.totals.totalTokens, 148);
  const serialized = fs.readFileSync(usagePath, 'utf8');
  for (const secret of ['SECRET TITLE', 'SECRET PROJECT', 'META SECRET', 'credentials', 'NOPE']) {
    assert.equal(serialized.includes(secret), false, `privacy projection excludes ${secret}`);
  }
});

test('missing, reset, invalid, and old missing-baseline sessions are incomplete; new sessions use zero', t => {
  const dir = tempDir(t);
  const before = path.join(dir, 'before.json');
  const after = path.join(dir, 'after.json');
  writeJson(before, [row('reset'), row('kept')]);
  assert.equal(run(['--phase', 'start', '--run-dir', dir, '--session', 'reset', '--snapshot', before]).status, 0);
  writeJson(after, [
    row('reset', { calls: 1 }),
    row('invalid', { cost: -1 }),
    row('old', { startedAt: '2020-01-01T00:00:00.000Z' }),
    row('new', { startedAt: '2099-01-01T00:00:00.000Z', cost: 0.25, inputTokens: 5, outputTokens: 2, cacheReadTokens: 3, cacheWriteTokens: 1 })
  ]);
  const result = run(['--phase', 'finish', '--run-dir', dir,
    '--session', 'reset', '--session', 'missing', '--session', 'invalid', '--session', 'old', '--session', 'new', '--snapshot', after]);
  assert.equal(result.status, 0, result.stderr);
  const usage = JSON.parse(fs.readFileSync(path.join(dir, 'task-usage.json')));
  assert.equal(usage.status, 'incomplete');
  assert.equal(usage.sessions.find(x => x.sessionId === 'new').baseline, 'zero-new');
  assert.equal(usage.sessions.find(x => x.sessionId === 'new').delta.totalTokens, 11);
  for (const reason of ['counter-decreased', 'missing-row', 'invalid-counters', 'missing-old-baseline']) {
    assert.ok(usage.issues.some(x => x.reason === reason), `contains ${reason}`);
  }
});

test('bad snapshot schema is advisory and repeated start refuses overwrite', t => {
  const dir = tempDir(t);
  const bad = path.join(dir, 'bad.json');
  writeJson(bad, { sessions: 'not-an-array' });
  let result = run(['--phase', 'start', '--run-dir', dir, '--session', 'x', '--snapshot', bad]);
  assert.equal(result.status, 0, result.stderr);
  const start = JSON.parse(fs.readFileSync(path.join(dir, 'task-usage-start.json')));
  assert.equal(start.status, 'unknown');
  result = run(['--phase', 'start', '--run-dir', dir, '--session', 'x', '--snapshot', bad]);
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /refus/i);
});

test('the same session ID under different providers is counted once per provider', t => {
  const dir = tempDir(t);
  const before = path.join(dir, 'before.json');
  const after = path.join(dir, 'after.json');
  writeJson(before, [row('shared'), row('shared', { provider: 'claude' })]);
  assert.equal(run(['--phase', 'start', '--run-dir', dir, '--session', 'shared', '--snapshot', before]).status, 0);
  writeJson(after, [row('shared', { calls: 3 }), row('shared', { provider: 'claude', calls: 4 })]);
  assert.equal(run(['--phase', 'finish', '--run-dir', dir, '--snapshot', after]).status, 0);
  const usage = JSON.parse(fs.readFileSync(path.join(dir, 'task-usage.json')));
  assert.equal(usage.sessions.length, 2);
  assert.equal(usage.totals.calls, 3);
});

test('malformed finish rows make the artifact incomplete while valid selected evidence survives', t => {
  const dir = tempDir(t);
  const before = path.join(dir, 'before.json');
  const after = path.join(dir, 'after.json');
  writeJson(before, [row('root')]);
  assert.equal(run(['--phase', 'start', '--run-dir', dir, '--session', 'root', '--snapshot', before]).status, 0);
  writeJson(after, [null, { unsupported: true }, row('root', { calls: 5 })]);
  const result = run(['--phase', 'finish', '--run-dir', dir, '--snapshot', after]);
  assert.equal(result.status, 0, result.stderr);
  const usage = JSON.parse(fs.readFileSync(path.join(dir, 'task-usage.json')));
  assert.equal(usage.status, 'incomplete');
  assert.equal(usage.sessions.length, 1);
  assert.equal(usage.sessions[0].delta.calls, 3);
  assert.equal(usage.issues.filter(issue => issue.reason === 'invalid-row').length, 2);
});

test('a persisted baseline with a missing counter cannot produce complete null totals', t => {
  const dir = tempDir(t);
  const snapshot = path.join(dir, 'snapshot.json');
  writeJson(snapshot, [row('root')]);
  assert.equal(run(['--phase', 'start', '--run-dir', dir, '--session', 'root', '--snapshot', snapshot]).status, 0);
  const startPath = path.join(dir, 'task-usage-start.json');
  const start = JSON.parse(fs.readFileSync(startPath));
  delete start.baselines[0].calls;
  writeJson(startPath, start);
  writeJson(snapshot, [row('root', { calls: 5 })]);
  const result = run(['--phase', 'finish', '--run-dir', dir, '--snapshot', snapshot]);
  assert.equal(result.status, 0, result.stderr);
  const usage = JSON.parse(fs.readFileSync(path.join(dir, 'task-usage.json')));
  assert.equal(usage.status, 'incomplete');
  assert.equal(usage.sessions.length, 0);
  assert.ok(usage.issues.some(issue => issue.reason === 'invalid-baseline'));
});

test('a malformed baseline capture timestamp is explicit while valid baseline deltas survive', t => {
  const dir = tempDir(t);
  const snapshot = path.join(dir, 'snapshot.json');
  writeJson(snapshot, [row('root')]);
  assert.equal(run(['--phase', 'start', '--run-dir', dir, '--session', 'root', '--snapshot', snapshot]).status, 0);
  const startPath = path.join(dir, 'task-usage-start.json');
  const start = JSON.parse(fs.readFileSync(startPath));
  start.capturedAt = 'not-a-timestamp';
  writeJson(startPath, start);
  writeJson(snapshot, [row('root', { calls: 4 })]);
  const result = run(['--phase', 'finish', '--run-dir', dir, '--snapshot', snapshot]);
  assert.equal(result.status, 0, result.stderr);
  const usage = JSON.parse(fs.readFileSync(path.join(dir, 'task-usage.json')));
  assert.equal(usage.status, 'incomplete');
  assert.equal(usage.sessions[0].delta.calls, 2);
  assert.ok(usage.issues.some(issue => issue.reason === 'invalid-baseline-timestamp'));
});

test('finishing without selected sessions cannot report complete zero usage', t => {
  const dir = tempDir(t);
  const snapshot = path.join(dir, 'snapshot.json');
  writeJson(snapshot, [row('unselected')]);
  assert.equal(run(['--phase', 'start', '--run-dir', dir, '--snapshot', snapshot]).status, 0);
  const result = run(['--phase', 'finish', '--run-dir', dir, '--snapshot', snapshot]);
  assert.equal(result.status, 0, result.stderr);
  const usage = JSON.parse(fs.readFileSync(path.join(dir, 'task-usage.json')));
  assert.notEqual(usage.status, 'complete');
  assert.ok(usage.issues.some(issue => issue.reason === 'no-selected-sessions'));
});

test('duplicate finish rows use the latest endedAt record consistently', t => {
  const dir = tempDir(t);
  const before = path.join(dir, 'before.json');
  const after = path.join(dir, 'after.json');
  writeJson(before, [row('root')]);
  assert.equal(run(['--phase', 'start', '--run-dir', dir, '--session', 'root', '--snapshot', before]).status, 0);
  writeJson(after, [
    row('root', { calls: 3, endedAt: '2026-09-14T08:06:00.000Z' }),
    row('root', { calls: 7, endedAt: '2026-09-14T08:07:00.000Z' })
  ]);
  const result = run(['--phase', 'finish', '--run-dir', dir, '--snapshot', after]);
  assert.equal(result.status, 0, result.stderr);
  const usage = JSON.parse(fs.readFileSync(path.join(dir, 'task-usage.json')));
  assert.equal(usage.status, 'complete');
  assert.equal(usage.sessions.length, 1);
  assert.equal(usage.sessions[0].delta.calls, 5);
  assert.equal(usage.sessions[0].totals.calls, 7);
});

test('numeric fields reject non-finite values and Codeburn absence is bounded advisory', async () => {
  const mod = require('../skills/pipeline/bin/task-usage.js');
  for (const field of numeric) {
    const candidate = row('bad');
    candidate[field] = Number.NaN;
    assert.throws(() => mod.projectRows([candidate]), /finite nonnegative/i);
  }
  const captured = await mod.captureCodeburn({ candidates: [], from: '2026-09-14', to: '2026-09-15', timeoutMs: 10 });
  assert.equal(captured.ok, false);
  assert.match(captured.error, /unavailable/i);
});

test('query dates follow the local calendar across UTC midnight', () => {
  const script = `const { localDate } = require(${JSON.stringify(cli)}); console.log(JSON.stringify(process.argv.slice(1).map(localDate)))`;
  const instants = ['2026-09-14T22:30:00.000Z', '2026-09-14T00:30:00.000Z'];
  for (const [zone, expected] of [
    ['Europe/Rome', ['2026-09-15', '2026-09-14']],
    ['America/Los_Angeles', ['2026-09-14', '2026-09-13']],
    ['UTC', ['2026-09-14', '2026-09-14']]
  ]) {
    const result = spawnSync(process.execPath, ['-e', script, ...instants], { encoding: 'utf8', env: { ...process.env, TZ: zone } });
    assert.equal(result.status, 0, result.stderr);
    assert.deepEqual(JSON.parse(result.stdout), expected, zone);
  }
});

test('malformed persisted selection stays advisory and retains valid selected deltas', t => {
  const dir = tempDir(t);
  const snapshot = path.join(dir, 'snapshot.json');
  writeJson(snapshot, [row('root')]);
  assert.equal(run(['--phase', 'start', '--run-dir', dir, '--session', 'root', '--snapshot', snapshot]).status, 0);
  const startPath = path.join(dir, 'task-usage-start.json');
  const start = JSON.parse(fs.readFileSync(startPath));
  start.selection.push(null);
  writeJson(startPath, start);
  writeJson(snapshot, [row('root', { calls: 4 })]);
  const result = run(['--phase', 'finish', '--run-dir', dir, '--snapshot', snapshot]);
  assert.equal(result.status, 0, result.stderr);
  const usage = JSON.parse(fs.readFileSync(path.join(dir, 'task-usage.json')));
  assert.notEqual(usage.status, 'complete');
  assert.equal(usage.sessions[0].delta.calls, 2);
  assert.ok(usage.issues.some(issue => issue.reason === 'invalid-baseline-selection'));
});
