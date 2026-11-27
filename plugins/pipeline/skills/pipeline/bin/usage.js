#!/usr/bin/env node
'use strict';

// Token usage from local Claude Code transcripts, no npm needed.
const fs = require('fs'), path = require('path');
const args = process.argv.slice(2);
const die = message => { console.error(`usage: ${message}`); process.exit(2); };
const has = name => args.includes(name);
const flag = (name, def) => {
  const i = args.indexOf(name);
  if (i < 0) return def;
  if (args[i + 1] === undefined || args[i + 1].startsWith('--')) die(`${name} requires a value`);
  return args[i + 1];
};
const numberFlag = (name, def, integer = false) => {
  const value = Number(flag(name, def));
  if (!Number.isFinite(value) || value <= 0 || (integer && !Number.isInteger(value))) die(`${name} must be a positive${integer ? ' integer' : ''}`);
  return value;
};
const parseIso = (name, value) => {
  const dateOnly = /^\d{4}-\d{2}-\d{2}$/.test(value);
  const candidate = dateOnly ? `${value}T00:00:00.000Z` : value;
  if (!dateOnly && !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(?::\d{2}(?:\.\d{1,3})?)?(?:Z|[+-]\d{2}:\d{2})$/.test(value)) die(`${name} must be an ISO date/time with a timezone`);
  const [, yearText, monthText, dayText] = /^(\d{4})-(\d{2})-(\d{2})/.exec(value);
  const year = Number(yearText), month = Number(monthText), day = Number(dayText);
  const leap = year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0);
  const monthDays = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
  if (month < 1 || month > 12 || day < 1 || day > monthDays[month - 1]) die(`${name} is not a valid ISO date/time`);
  const timestamp = Date.parse(candidate);
  if (!Number.isFinite(timestamp)) die(`${name} is not a valid ISO date/time`);
  return timestamp;
};
const explicitBounds = has('--since') || has('--until');
if (explicitBounds && (has('--hours') || has('--days'))) die('--since/--until cannot be combined with --hours/--days');
const now = Date.now();
const days = explicitBounds ? null : numberFlag('--days', 7);
const hours = explicitBounds || !has('--hours') ? null : numberFlag('--hours', null);
const top = numberFlag('--top', 10, true), asJson = has('--json');
const profile = process.env.USERPROFILE || process.env.HOME;
const defaultRoot = profile ? path.join(profile, '.claude', 'projects') : null;
const root = flag('--root', defaultRoot);
if (!root || !fs.existsSync(root) || !fs.statSync(root).isDirectory()) die('--root must be an existing directory');
const since = explicitBounds && has('--since') ? parseIso('--since', flag('--since')) : explicitBounds ? -Infinity : now - (hours !== null ? hours * 3600e3 : days * 864e5);
const until = explicitBounds && has('--until') ? parseIso('--until', flag('--until')) : now;
if (since >= until) die('--since must be earlier than --until');
const byModelDay = {}, sessions = {};
const coverage = { transcriptFiles: 0, matchedTranscriptFiles: 0, usageRecords: 0, syntheticRecords: 0, includedCalls: 0 };
const r = x => Math.round(x * 10) / 10;

function walk(d) {
  for (const e of fs.readdirSync(d, { withFileTypes: true })) {
    const p = path.join(d, e.name);
    if (e.isDirectory()) walk(p);
    else if (e.name.endsWith('.jsonl')) { coverage.transcriptFiles++; handle(p); }
  }
}

function handle(p) {
  if (fs.statSync(p).mtimeMs < since) return;
  const seen = new Map();
  for (const l of fs.readFileSync(p, 'utf8').split('\n')) {
    if (!l) continue;
    let o;
    try { o = JSON.parse(l); } catch { continue; }
    const m = o.message;
    if (!m || !m.usage) continue;
    coverage.usageRecords++;
    if (m.model === '<synthetic>') { coverage.syntheticRecords++; continue; }
    const ts = Date.parse(o.timestamp || 0);
    if (!ts || ts < since || ts >= until) continue;
    seen.set(m.id || o.uuid, { u: m.usage, model: m.model || '?', ts, sid: o.sessionId || path.basename(p, '.jsonl') });
  }
  if (seen.size) coverage.matchedTranscriptFiles++;
  const identity = path.relative(root, p).split(path.sep).join('/');
  const proj = identity.split('/')[0] || path.basename(path.dirname(p));
  for (const { u, model, ts, sid } of seen.values()) {
    coverage.includedCalls++;
    const day = new Date(ts).toISOString().slice(0, 10), k = model + '|' + day;
    const a = byModelDay[k] || (byModelDay[k] = { model, day, calls: 0, inputK: 0, cacheReadM: 0, cacheWriteM: 0, outputK: 0 });
    a.calls++;
    a.inputK += (u.input_tokens || 0) / 1e3;
    a.cacheReadM += (u.cache_read_input_tokens || 0) / 1e6;
    a.cacheWriteM += (u.cache_creation_input_tokens || 0) / 1e6;
    a.outputK += (u.output_tokens || 0) / 1e3;
    const s = sessions[identity] || (sessions[identity] = { identity, sessionId: sid, project: proj, modelSet: new Set(), calls: 0, maxCtx: 0, cacheRead: 0, output: 0, first: ts, last: ts });
    s.modelSet.add(model);
    s.calls++;
    s.cacheRead += u.cache_read_input_tokens || 0;
    s.output += u.output_tokens || 0;
    const ctx = (u.input_tokens || 0) + (u.cache_read_input_tokens || 0) + (u.cache_creation_input_tokens || 0);
    if (ctx > s.maxCtx) s.maxCtx = ctx;
    if (ts > s.last) s.last = ts;
    if (ts < s.first) s.first = ts;
  }
}

walk(root);

const byModelDayRows = Object.values(byModelDay)
  .sort((a, b) => a.day.localeCompare(b.day) || a.model.localeCompare(b.model))
  .map(a => ({ model: a.model, day: a.day, calls: a.calls, inputK: r(a.inputK), cacheReadM: r(a.cacheReadM), cacheWriteM: r(a.cacheWriteM), outputK: r(a.outputK) }));

const totalMap = {};
for (const a of Object.values(byModelDay)) {
  const t = totalMap[a.model] || (totalMap[a.model] = { model: a.model, calls: 0, inputK: 0, cacheReadM: 0, cacheWriteM: 0, outputK: 0 });
  t.calls += a.calls;
  t.inputK += a.inputK;
  t.cacheReadM += a.cacheReadM;
  t.cacheWriteM += a.cacheWriteM;
  t.outputK += a.outputK;
}
const totals = Object.values(totalMap)
  .sort((a, b) => a.model.localeCompare(b.model))
  .map(t => ({
    model: t.model,
    calls: t.calls,
    inputK: r(t.inputK),
    cacheReadM: r(t.cacheReadM),
    cacheWriteM: r(t.cacheWriteM),
    outputK: r(t.outputK),
    cacheReadPerCallK: r(t.calls ? t.cacheReadM * 1e3 / t.calls : 0)
  }));

const allSessionRows = Object.values(sessions)
  .map(s => {
    const models = [...s.modelSet].sort();
    return { project: s.project, model: models.length === 1 ? models[0] : 'mixed', calls: s.calls, maxCtxK: r(s.maxCtx / 1e3), cacheReadM: r(s.cacheRead / 1e6), outputK: r(s.output / 1e3), hours: r((s.last - s.first) / 36e5), identity: s.identity, sessionId: s.sessionId, models };
  })
  .sort((a, b) => b.maxCtxK - a.maxCtxK);
const sessionRows = allSessionRows.slice(0, top);
const sessionValues = Object.values(sessions);
const totalCacheRead = sessionValues.reduce((sum, s) => sum + s.cacheRead, 0);
const overValues = sessionValues.filter(s => s.maxCtx > 200000);
const overCacheRead = overValues.reduce((sum, s) => sum + s.cacheRead, 0);
const summary = {
  sessions: sessionValues.length,
  over200k: overValues.length,
  over200kCacheReadShare: r(totalCacheRead ? overCacheRead * 100 / totalCacheRead : 0)
};
const metadata = {
  bounds: {
    since: Number.isFinite(since) ? new Date(since).toISOString() : null,
    until: new Date(until).toISOString(),
    endExclusive: true,
    lens: explicitBounds ? 'explicit' : hours !== null ? 'hours' : 'days'
  },
  coverage,
  source: 'local Claude Code transcript usage records only',
  note: 'Token metrics and API-equivalent estimates are not subscription percentages, invoices, or remaining subscription allowance.'
};

// console.table emits ANSI colours under FORCE_COLOR and box-drawing characters
// the IBM437 console garbles, so text mode prints plain fixed-width ASCII.
function table(rows) {
  if (!rows.length) { console.log('(none)'); return; }
  const cols = Object.keys(rows[0]);
  const cells = rows.map(row => cols.map(c => String(row[c])));
  const widths = cols.map((c, i) => Math.max(c.length, ...cells.map(r => r[i].length)));
  const right = cols.map(c => rows.every(row => typeof row[c] === 'number'));
  const line = values => values.map((v, i) => (right[i] ? v.padStart(widths[i]) : v.padEnd(widths[i]))).join('  ').trimEnd();
  console.log(line(cols));
  console.log(widths.map(w => '-'.repeat(w)).join('  '));
  for (const row of cells) console.log(line(row));
}

if (asJson) {
  console.log(JSON.stringify({ byModelDay: byModelDayRows, totals, sessions: sessionRows, summary, metadata }, null, 2));
} else {
  console.log('BY MODEL AND DAY');
  table(byModelDayRows);
  console.log('TOTAL BY MODEL');
  table(totals);
  console.log('TOP SESSIONS BY PEAK CONTEXT');
  table(sessionRows);
  console.log(`SUMMARY: ${summary.sessions} sessions; ${summary.over200k} over 200k; ${summary.over200kCacheReadShare}% of cache reads from sessions over 200k`);
  console.log(`COVERAGE: ${coverage.includedCalls} calls in ${coverage.matchedTranscriptFiles}/${coverage.transcriptFiles} transcript files; end exclusive`);
  console.log(`NOTE: ${metadata.note}`);
}
