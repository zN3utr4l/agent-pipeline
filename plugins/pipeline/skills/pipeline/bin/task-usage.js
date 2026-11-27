#!/usr/bin/env node
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { execFile } = require('node:child_process');

const COUNTERS = ['cost', 'calls', 'turns', 'inputTokens', 'outputTokens', 'cacheReadTokens', 'cacheWriteTokens', 'durationMs'];
const START_FILE = 'task-usage-start.json';
const FINISH_FILE = 'task-usage.json';

function usageError(message) {
  const error = new Error(message);
  error.usage = true;
  return error;
}

function parseArgs(argv) {
  const result = { sessions: [], metas: [] };
  const single = new Set(['--phase', '--run-dir', '--snapshot']);
  const repeatable = new Map([['--session', 'sessions'], ['--meta', 'metas']]);
  for (let i = 0; i < argv.length; i++) {
    const name = argv[i];
    if (!single.has(name) && !repeatable.has(name)) throw usageError(`unknown argument: ${name}`);
    const value = argv[++i];
    if (!value || value.startsWith('--')) throw usageError(`${name} requires a value`);
    if (repeatable.has(name)) result[repeatable.get(name)].push(value);
    else {
      const key = name.slice(2).replace(/-([a-z])/g, (_, c) => c.toUpperCase());
      if (result[key] !== undefined) throw usageError(`${name} may be specified only once`);
      result[key] = value;
    }
  }
  if (!['start', 'finish'].includes(result.phase)) throw usageError('--phase must be start or finish');
  if (!result.runDir) throw usageError('--run-dir is required');
  return result;
}

function normalizeProvider(executor) {
  if (typeof executor !== 'string') return null;
  const value = executor.trim().toLowerCase();
  if (value.includes('claude') || value.includes('opus') || value.includes('sonnet')) return 'claude';
  if (value.includes('codex') || value.includes('gpt') || value.includes('terra') || value.includes('sol')) return 'codex';
  return null;
}

function readSelectors(sessionIds, metaPaths) {
  const selectors = [];
  for (const sessionId of sessionIds) {
    if (!sessionId.trim()) throw usageError('--session must not be empty');
    selectors.push({ sessionId, provider: null });
  }
  for (const metaPath of metaPaths) {
    const meta = JSON.parse(fs.readFileSync(path.resolve(metaPath), 'utf8'));
    if (!meta || typeof meta !== 'object' || Array.isArray(meta) || typeof meta.sessionId !== 'string' || !meta.sessionId.trim()) {
      throw usageError(`meta file lacks a sessionId: ${metaPath}`);
    }
    selectors.push({ sessionId: meta.sessionId, provider: normalizeProvider(meta.executor) });
  }
  return mergeSelectors([], selectors);
}

function validateTime(value, field) {
  if (typeof value !== 'string' || !Number.isFinite(Date.parse(value))) throw new Error(`${field} must be a valid date/time`);
  return value;
}

function localDate(value) {
  const date = new Date(value);
  return [date.getFullYear(), String(date.getMonth() + 1).padStart(2, '0'), String(date.getDate()).padStart(2, '0')].join('-');
}

function projectRow(row) {
  if (!row || typeof row !== 'object' || Array.isArray(row)) throw new Error('session row must be an object');
  if (typeof row.sessionId !== 'string' || !row.sessionId.trim()) throw new Error('sessionId must be a nonempty string');
  if (typeof row.provider !== 'string' || !row.provider.trim()) throw new Error('provider must be a nonempty string');
  if (!Array.isArray(row.models) || row.models.some(model => typeof model !== 'string')) throw new Error('models must be an array of strings');
  const projected = {
    sessionId: row.sessionId,
    provider: row.provider,
    models: [...new Set(row.models)].sort(),
    startedAt: validateTime(row.startedAt, 'startedAt'),
    endedAt: validateTime(row.endedAt, 'endedAt')
  };
  for (const field of COUNTERS) {
    if (typeof row[field] !== 'number' || !Number.isFinite(row[field]) || row[field] < 0) {
      throw new Error(`${field} must be a finite nonnegative number`);
    }
    projected[field] = row[field];
  }
  return projected;
}

function projectRows(rows) {
  if (!Array.isArray(rows)) throw new Error('Codeburn sessions JSON must be an array');
  const projected = new Map();
  for (const raw of rows) {
    const row = projectRow(raw);
    const key = `${row.provider}\0${row.sessionId}`;
    const prior = projected.get(key);
    if (!prior || Date.parse(row.endedAt) > Date.parse(prior.endedAt)) projected.set(key, row);
  }
  return [...projected.values()];
}

function collectRows(rows, issues) {
  if (!Array.isArray(rows)) throw new Error('Codeburn sessions JSON must be an array');
  const projected = new Map();
  for (const raw of rows) {
    let row;
    try { row = projectRow(raw); }
    catch {
      const identified = typeof raw?.sessionId === 'string' && typeof raw?.provider === 'string';
      issues.push({
        ...(identified ? { sessionId: raw.sessionId, provider: raw.provider } : {}),
        reason: identified ? 'invalid-counters' : 'invalid-row'
      });
      continue;
    }
    const key = `${row.provider}\0${row.sessionId}`;
    const prior = projected.get(key);
    if (!prior || Date.parse(row.endedAt) > Date.parse(prior.endedAt)) projected.set(key, row);
  }
  return [...projected.values()];
}

function baselineRow(row) {
  return Object.fromEntries([
    ['sessionId', row.sessionId], ['provider', row.provider], ['startedAt', row.startedAt],
    ...COUNTERS.map(field => [field, row[field]])
  ]);
}

function projectBaseline(row) {
  if (!row || typeof row !== 'object' || Array.isArray(row)) throw new Error('baseline must be an object');
  if (typeof row.sessionId !== 'string' || !row.sessionId.trim()) throw new Error('baseline sessionId is invalid');
  if (typeof row.provider !== 'string' || !row.provider.trim()) throw new Error('baseline provider is invalid');
  const projected = { sessionId: row.sessionId, provider: row.provider, startedAt: validateTime(row.startedAt, 'baseline startedAt') };
  for (const field of COUNTERS) {
    if (typeof row[field] !== 'number' || !Number.isFinite(row[field]) || row[field] < 0) throw new Error(`baseline ${field} is invalid`);
    projected[field] = row[field];
  }
  return projected;
}

function codeburnCandidates() {
  const candidates = [];
  const locations = [...new Set([path.dirname(process.execPath), ...(process.env.PATH || '').split(path.delimiter)])]
    .map(directory => [process.execPath, path.join(directory, 'node_modules', 'codeburn', 'dist', 'cli.js')]);
  const seen = new Set();
  for (const [executable, cli] of locations) {
    const key = `${executable}\0${cli}`;
    if (!seen.has(key) && fs.existsSync(executable) && fs.existsSync(cli)) {
      seen.add(key);
      candidates.push({ executable, prefix: [cli] });
    }
  }
  return candidates;
}

function captureCodeburn({ candidates = codeburnCandidates(), from, to, timeoutMs = 30000 }) {
  const boundedTimeout = Math.min(Math.max(timeoutMs, 1), 30000);
  if (!candidates.length) return Promise.resolve({ ok: false, error: 'Codeburn unavailable' });
  const candidate = candidates[0];
  const args = [...candidate.prefix, 'sessions', '--from', from, '--to', to, '--format', 'json', '--no-pager'];
  return new Promise(resolve => {
    execFile(candidate.executable, args, { windowsHide: true, timeout: boundedTimeout, maxBuffer: 16 * 1024 * 1024 }, (error, stdout) => {
      if (error) return resolve({ ok: false, error: `Codeburn capture failed (${error.code || 'error'})` });
      try {
        const rows = JSON.parse(stdout);
        if (!Array.isArray(rows)) throw new Error('sessions result is not an array');
        resolve({ ok: true, rows, source: 'codeburn-local-sessions' });
      } catch {
        resolve({ ok: false, error: 'Codeburn returned invalid sessions JSON' });
      }
    });
  });
}

async function captureRows(snapshot, from, to) {
  if (snapshot) {
    try {
      const rows = JSON.parse(fs.readFileSync(path.resolve(snapshot), 'utf8'));
      if (!Array.isArray(rows)) throw new Error('not an array');
      return { ok: true, rows, source: 'snapshot-fixture' };
    } catch {
      return { ok: false, error: 'Snapshot is missing or has invalid sessions JSON' };
    }
  }
  return captureCodeburn({ from, to });
}

function mergeSelectors(prior, current) {
  const selected = new Map();
  for (const selector of [...prior, ...current]) {
    const wildcard = `*\0${selector.sessionId}`;
    if (!selector.provider) {
      for (const [key, value] of selected) if (value.sessionId === selector.sessionId) selected.delete(key);
      selected.set(wildcard, selector);
    } else if (!selected.has(wildcard)) {
      selected.set(`${selector.provider}\0${selector.sessionId}`, selector);
    }
  }
  return [...selected.values()];
}

function matchingRows(rows, selector) {
  return rows.filter(row => row && row.sessionId === selector.sessionId && (!selector.provider || row.provider === selector.provider));
}

function zeroBaseline(row) {
  const result = {};
  for (const field of COUNTERS) result[field] = 0;
  return result;
}

function deltaFor(row, baseline) {
  const delta = {};
  for (const field of COUNTERS) {
    if (row[field] < baseline[field]) return null;
    delta[field] = Math.round((row[field] - baseline[field]) * 1e12) / 1e12;
  }
  delta.totalTokens = delta.inputTokens + delta.cacheReadTokens + delta.cacheWriteTokens + delta.outputTokens;
  return delta;
}

function emptyTotals() {
  return Object.fromEntries([...COUNTERS, 'totalTokens'].map(field => [field, 0]));
}

function addTotals(total, delta) {
  for (const field of Object.keys(total)) total[field] = Math.round((total[field] + delta[field]) * 1e12) / 1e12;
}

function writeExclusive(file, value) {
  const fd = fs.openSync(file, 'wx');
  try { fs.writeFileSync(fd, `${JSON.stringify(value, null, 2)}\n`); }
  finally { fs.closeSync(fd); }
}

async function start(options, selectors, runDir) {
  const outputPath = path.join(runDir, START_FILE);
  if (fs.existsSync(outputPath)) throw usageError(`refusing to overwrite ${outputPath}`);
  const capturedAt = new Date().toISOString();
  const date = localDate(capturedAt);
  const capture = await captureRows(options.snapshot, date, date);
  let baselines = [], status = 'ready', advisory = null, issues = [];
  if (capture.ok) {
    try {
      baselines = collectRows(capture.rows, issues).map(baselineRow);
      if (issues.length) { status = 'incomplete'; advisory = 'Some Codeburn session rows were invalid'; }
    }
    catch { status = 'unknown'; advisory = 'Codeburn sessions schema or counters were invalid'; }
  } else { status = 'unknown'; advisory = capture.error; }
  const artifact = {
    schemaVersion: 1, phase: 'start', capturedAt, status,
    selection: selectors, baselines,
    source: capture.source || 'unavailable',
    coverage: 'all readable local session rows retained as numeric baselines; only exact selected IDs are reportable',
    ...(issues.length ? { issues } : {}),
    ...(advisory ? { advisory } : {})
  };
  writeExclusive(outputPath, artifact);
  console.log(`task-usage start status=${status} path=${outputPath} selected=${selectors.length} baselines=${baselines.length}`);
}

async function finish(options, selectors, runDir) {
  const startPath = path.join(runDir, START_FILE);
  const outputPath = path.join(runDir, FINISH_FILE);
  if (fs.existsSync(outputPath)) throw usageError(`refusing to overwrite ${outputPath}`);
  const capturedAt = new Date().toISOString();
  if (!fs.existsSync(startPath)) throw usageError(`missing start artifact: ${startPath}`);
  let baselineArtifact;
  try { baselineArtifact = JSON.parse(fs.readFileSync(startPath, 'utf8')); }
  catch {
    const artifact = {
      schemaVersion: 1, phase: 'finish', capturedAt, baselineCapturedAt: null, status: 'unknown',
      sessions: [], totals: emptyTotals(), issues: [{ reason: 'invalid-baseline-artifact' }],
      coverage: { selected: selectors.length, reported: 0, source: 'unavailable', childCoverage: 'not assumed' },
      meaning: 'API-equivalent Codeburn cost estimate; not subscription quota or an invoice. Token totals include input, cache read, cache write, and output tokens.'
    };
    writeExclusive(outputPath, artifact);
    console.log(`task-usage finish status=unknown path=${outputPath} selected=${selectors.length} reported=0 issues=1`);
    return;
  }
  const issues = [], sessions = [], totals = emptyTotals();
  let invalidArtifact = false;
  if (!baselineArtifact || typeof baselineArtifact !== 'object' || Array.isArray(baselineArtifact) || baselineArtifact.phase !== 'start') {
    issues.push({ reason: 'invalid-baseline-artifact' });
    invalidArtifact = true;
    baselineArtifact = {};
  }
  const priorSelection = (Array.isArray(baselineArtifact.selection) ? baselineArtifact.selection : []).filter(selector => {
    const valid = selector && typeof selector.sessionId === 'string' && selector.sessionId.trim()
      && (selector.provider === null || typeof selector.provider === 'string');
    if (!valid) issues.push({ reason: 'invalid-baseline-selection' });
    return valid;
  });
  const baselineRows = Array.isArray(baselineArtifact.baselines) ? baselineArtifact.baselines : [];
  if (!Array.isArray(baselineArtifact.selection) || !Array.isArray(baselineArtifact.baselines)) {
    issues.push({ reason: 'invalid-baseline-artifact' });
    invalidArtifact = true;
  }
  const baselineTime = Date.parse(baselineArtifact.capturedAt);
  const validBaselineTime = typeof baselineArtifact.capturedAt === 'string' && Number.isFinite(baselineTime);
  if (!validBaselineTime) issues.push({ reason: 'invalid-baseline-timestamp' });
  const from = localDate(validBaselineTime ? baselineArtifact.capturedAt : capturedAt);
  const to = localDate(capturedAt);
  const selected = mergeSelectors(priorSelection, selectors);
  if (!selected.length) issues.push({ reason: 'no-selected-sessions' });
  const capture = await captureRows(options.snapshot, from, to);
  let rows = [];
  if (capture.ok) {
    try { rows = collectRows(capture.rows, issues); }
    catch { issues.push({ reason: 'invalid-schema' }); invalidArtifact = true; }
  } else issues.push({ reason: 'capture-failed', detail: capture.error });
  const baselines = new Map(), invalidBaselineKeys = new Set();
  for (const raw of baselineRows) {
    let baseline;
    try { baseline = projectBaseline(raw); }
    catch {
      issues.push({
        ...(typeof raw?.sessionId === 'string' ? { sessionId: raw.sessionId } : {}),
        ...(typeof raw?.provider === 'string' ? { provider: raw.provider } : {}),
        reason: 'invalid-baseline'
      });
      if (typeof raw?.sessionId === 'string' && typeof raw?.provider === 'string') invalidBaselineKeys.add(`${raw.provider}\0${raw.sessionId}`);
      continue;
    }
    baselines.set(`${baseline.provider}\0${baseline.sessionId}`, baseline);
  }
  for (const selector of selected) {
    const rawMatches = capture.ok ? matchingRows(rows, selector) : [];
    if (!rawMatches.length) {
      issues.push({ sessionId: selector.sessionId, ...(selector.provider ? { provider: selector.provider } : {}), reason: 'missing-row' });
      continue;
    }
    for (const row of rawMatches) {
      const key = `${row.provider}\0${row.sessionId}`;
      let baseline = baselines.get(key), baselineKind = 'captured';
      if (!baseline) {
        if (invalidBaselineKeys.has(key)) continue;
        if (!validBaselineTime) {
          issues.push({ sessionId: row.sessionId, provider: row.provider, reason: 'missing-baseline' });
          continue;
        }
        if (Date.parse(row.startedAt) < baselineTime) {
          issues.push({ sessionId: row.sessionId, provider: row.provider, reason: 'missing-old-baseline' });
          continue;
        }
        baseline = zeroBaseline(row);
        baselineKind = 'zero-new';
      }
      const delta = deltaFor(row, baseline);
      if (!delta) {
        issues.push({ sessionId: row.sessionId, provider: row.provider, reason: 'counter-decreased' });
        continue;
      }
      const session = { sessionId: row.sessionId, provider: row.provider, models: row.models, baseline: baselineKind, delta, totals: Object.fromEntries(COUNTERS.map(field => [field, row[field]])) };
      session.totals.totalTokens = row.inputTokens + row.cacheReadTokens + row.cacheWriteTokens + row.outputTokens;
      sessions.push(session);
      addTotals(totals, delta);
    }
  }
  const status = !capture.ok || invalidArtifact ? 'unknown' : (issues.length ? 'incomplete' : 'complete');
  const artifact = {
    schemaVersion: 1, phase: 'finish', capturedAt, baselineCapturedAt: validBaselineTime ? baselineArtifact.capturedAt : null, status,
    sessions, totals, issues,
    coverage: { selected: selected.length, reported: sessions.length, source: capture.source || 'unavailable', childCoverage: 'not assumed' },
    meaning: 'API-equivalent Codeburn cost estimate; not subscription quota or an invoice. Token totals include input, cache read, cache write, and output tokens.'
  };
  writeExclusive(outputPath, artifact);
  console.log(`task-usage finish status=${status} path=${outputPath} selected=${selected.length} reported=${sessions.length} issues=${issues.length}`);
}

async function main(argv) {
  const options = parseArgs(argv);
  const runDir = path.resolve(options.runDir);
  if (!fs.existsSync(runDir) || !fs.statSync(runDir).isDirectory()) throw usageError('--run-dir must be an existing directory');
  const runMeta = path.join(runDir, 'meta.json');
  if (options.phase === 'finish' && !options.sessions.length && !options.metas.length && fs.existsSync(runMeta)) {
    const meta = JSON.parse(fs.readFileSync(runMeta, 'utf8'));
    if (typeof meta?.sessionId === 'string' && meta.sessionId.trim()) options.metas.push(runMeta);
  }
  const selectors = readSelectors(options.sessions, options.metas);
  if (options.phase === 'start') await start(options, selectors, runDir);
  else await finish(options, selectors, runDir);
}

if (require.main === module) {
  main(process.argv.slice(2)).catch(error => {
    console.error(`${error.usage ? 'usage' : 'task-usage'}: ${error.message}`);
    process.exitCode = error.usage ? 2 : 1;
  });
}

module.exports = { captureCodeburn, projectRows, localDate };
