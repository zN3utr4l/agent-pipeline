'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');

function parseArgs(args) {
  const options = { runs: path.join(process.env.PIPELINE_HOME || path.join(require('node:os').homedir(), '.pipeline'), 'runs'), roots: '', json: false };
  for (let i = 0; i < args.length; i++) {
    const flag = args[i];
    if (flag === '--json' || flag === '--help' || flag === '--all') { options[flag.slice(2)] = true; continue; }
    if (!['--runs', '--roots', '--since', '--until', '--repo', '--registry', '--out'].includes(flag)) throw new Error(`unknown option ${flag}`);
    const value = args[++i];
    if (!value || value.startsWith('--')) throw new Error(`missing value for ${flag}`);
    options[flag.slice(2)] = value;
  }
  for (const key of ['since', 'until']) {
    const value = options[key];
    if (value && (!/^\d{4}-\d{2}-\d{2}$/.test(value) || !Number.isFinite(Date.parse(value)) || new Date(value).toISOString().slice(0, 10) !== value)) {
      throw new Error(`${key} must be a valid YYYY-MM-DD date`);
    }
  }
  if (options.since && options.until && options.since > options.until) throw new Error('since must not follow until');
  return options;
}

function readJson(file) {
  const value = JSON.parse(fs.readFileSync(file, 'utf8').replace(/^\uFEFF/, ''));
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error('expected an object');
  return value;
}

function numeric(value) { return typeof value === 'number' && Number.isFinite(value) && value >= 0; }

function localDate(time) {
  const parts = new Intl.DateTimeFormat('en', { year: 'numeric', month: '2-digit', day: '2-digit' }).formatToParts(new Date(time));
  const values = Object.fromEntries(parts.map(part => [part.type, part.value]));
  return `${values.year}-${values.month}-${values.day}`;
}

function distribution(values) {
  const sorted = values.toSorted((a, b) => a - b);
  const n = sorted.length;
  return {
    samples: n,
    median: n ? (sorted[Math.floor((n - 1) / 2)] + sorted[Math.floor(n / 2)]) / 2 : null,
    p90: n ? sorted[Math.ceil(n * 0.9) - 1] : null,
  };
}

function summarize(rows, repo) {
  const exitCodes = {};
  const gates = new Map();
  for (const row of rows) {
    exitCodes[row.exitCode] = (exitCodes[row.exitCode] || 0) + 1;
    if (row.gate) {
      const command = row.gate.command;
      const key = JSON.stringify(command);
      if (!gates.has(key)) gates.set(key, { command, runs: 0, red: 0, flaky: 0 });
      const g = gates.get(key);
      g.runs++;
      if (row.gate.flaky === true) g.flaky++;
      if (row.gate.timedOut === true || row.gate.exitCode !== 0) g.red++;
    }
  }
  const fixLoopRuns = rows.filter(r => r.fixLoop).length;
  const costs = rows.map(r => r.cost).filter(numeric);
  return {
    repo, runs: rows.length, exitCodes, fixLoopRuns,
    red: [...gates.values()].reduce((sum, g) => sum + g.red, 0),
    flaky: [...gates.values()].reduce((sum, g) => sum + g.flaky, 0),
    fixLoopRate: rows.length ? fixLoopRuns / rows.length : 0,
    freshFixBriefs: rows.reduce((sum, r) => sum + r.fixBriefs, 0),
    deadlineExits: rows.filter(r => r.exitCode === 124).length,
    sandboxExits: rows.filter(r => r.exitCode === 75).length,
    briefChars: distribution(rows.map(r => r.briefChars).filter(numeric)),
    claudeContextPerTurn: distribution(rows.map(r => r.claudeContextPerTurn).filter(numeric)),
    costUsd: costs.reduce((sum, cost) => sum + cost, 0), costSamples: costs.length,
    gates: [...gates.values()].sort((a, b) => String(a.command).localeCompare(String(b.command))).map(g => ({ ...g, redRate: g.red / g.runs })),
  };
}

function scan(options) {
  const root = path.resolve(options.runs);
  if (!fs.statSync(root).isDirectory()) throw new Error(`runs is not a directory: ${root}`);
  const rows = [];
  const skipped = { meta: 0, gate: 0, usage: 0 };
  const normalize = name => name.toLowerCase().replace(/[^a-z0-9]/g, '');
  const normalizePath = value => value.replace(/[\\/]+/g, '\\').replace(/\\+$/, '').toLowerCase();
  const candidates = [];
  const registryFile = options.registry || path.join(process.env.PIPELINE_HOME || path.join(require('node:os').homedir(), '.pipeline'), 'config', 'executors.json');
  let registeredRoots = [];
  try {
    const executors = readJson(registryFile).executors;
    if (executors && typeof executors === 'object' && !Array.isArray(executors)) {
      registeredRoots = Object.entries(executors).filter(([, value]) => typeof value?.repo === 'string').map(([name, value]) => [normalizePath(value.repo), name.toLowerCase()]);
    }
  } catch { /* Registry is optional on other machines. */ }
  for (const directory of options.roots.split(',').filter(Boolean)) {
    try {
      for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
        if (entry.isDirectory() && normalize(entry.name)) candidates.push({ name: entry.name, directory: path.resolve(directory, entry.name) });
      }
    } catch { /* A root may be absent on a different machine. */ }
  }
  candidates.sort((a, b) => b.name.length - a.name.length || a.name.localeCompare(b.name));
  const mainCheckouts = new Map();
  const leaf = directory => path.win32.basename(directory.replace(/[\\/]+$/, '')).toLowerCase();
  function canonical(rootPath, fallback) {
    if (rootPath) {
      const match = registeredRoots.find(([registered]) => registered === normalizePath(rootPath));
      if (match) return match[1];
    }
    return leaf(fallback || rootPath || '');
  }
  function repository(meta, dir) {
    if (typeof meta.repoRoot === 'string' && meta.repoRoot.trim()) return canonical(meta.repoRoot);
    if (typeof meta.repoPath === 'string' && meta.repoPath && fs.existsSync(path.join(meta.repoPath, '.git'))) {
      if (!mainCheckouts.has(meta.repoPath)) {
        let main = null;
        try {
          const common = execFileSync('git', ['--no-optional-locks', '-c', `safe.directory=${meta.repoPath}`, '-C', meta.repoPath,
            'rev-parse', '--path-format=absolute', '--git-common-dir'], { encoding: 'utf8', windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] }).trim();
          if (common) main = path.dirname(common);
        } catch { /* Deleted or unreadable worktrees use the folder fallback. */ }
        mainCheckouts.set(meta.repoPath, main);
      }
      if (mainCheckouts.get(meta.repoPath)) return canonical(mainCheckouts.get(meta.repoPath));
    }
    const folder = path.relative(root, dir).split(path.sep)[0] || path.basename(dir);
    const candidate = candidates.find(item => normalize(folder).startsWith(normalize(item.name)));
    if (candidate) return canonical(candidate.directory, candidate.name);
    return folder.toLowerCase();
  }
  function visit(dir) {
    const entries = fs.readdirSync(dir, { withFileTypes: true });
    const files = new Set(entries.filter(e => e.isFile()).map(e => e.name));
    if (!files.has('meta.json')) {
      for (const entry of entries) if (entry.isDirectory() && entry.name !== 'before') visit(path.join(dir, entry.name));
      return;
    }
    let currentMeta;
    try { currentMeta = readJson(path.join(dir, 'meta.json')); }
    catch { skipped.meta++; return; }
    const attempts = [...(Array.isArray(currentMeta.attempts) ? currentMeta.attempts : []), currentMeta];
    for (const meta of attempts) {
      const current = meta === currentMeta;
      if (!meta || typeof meta !== 'object' || Array.isArray(meta)) { skipped.meta++; continue; }
      const repo = repository(meta, dir);
      if (options.repo && repo && repo !== options.repo.toLowerCase()) continue;
      const time = typeof meta.startedAt === 'string' ? Date.parse(meta.startedAt) : NaN;
      const date = Number.isFinite(time) ? localDate(time) : null;
      if (date && ((options.since && date < options.since) || (options.until && date > options.until))) continue;
      const exitCode = Object.hasOwn(meta, 'wrapperExitCode') ? meta.wrapperExitCode : meta.exitCode;
      if (!repo || !date || !Number.isInteger(exitCode)) { skipped.meta++; continue; }
      const recordedGate = !current || Array.isArray(currentMeta.attempts);
      let gate = null;
      if ((recordedGate && meta.gate) || (current && (!recordedGate || !Object.hasOwn(meta, 'gate')) && files.has('gate.json'))) {
        try {
          const value = (recordedGate && meta.gate) || readJson(path.join(dir, 'gate.json'));
          const validCommand = typeof value.command === 'string' ? value.command.trim() :
            Array.isArray(value.command) && value.command.length > 0 && value.command.every(c => typeof c === 'string' && c.trim());
          if (!validCommand || (!Number.isInteger(value.exitCode) && value.timedOut !== true)) throw new Error('partial gate');
          gate = value;
        } catch { skipped.gate++; }
      }
      let cost = null;
      if (current && files.has('task-usage.json')) {
        try {
          const usage = readJson(path.join(dir, 'task-usage.json'));
          if (usage.phase !== 'finish' || !Array.isArray(usage.sessions) || !usage.sessions.length || usage.sessions.some(s => !numeric(s?.delta?.cost))) throw new Error('partial usage');
          cost = usage.sessions.reduce((sum, s) => sum + s.delta.cost, 0);
        } catch { skipped.usage++; }
      }
      if (cost === null && numeric(meta.totalCostUsd)) cost = meta.totalCostUsd;
      let briefChars = numeric(meta.briefChars) ? meta.briefChars : null;
      const briefName = typeof meta.brief === 'string' ? path.win32.basename(meta.brief) : 'brief.md';
      const localBrief = files.has(briefName) ? briefName : 'brief.md';
      if (current && briefChars === null && files.has(localBrief)) briefChars = fs.readFileSync(path.join(dir, localBrief), 'utf8').replace(/^\uFEFF/, '').length;
      const isClaude = /claude|opus|sonnet/i.test(meta.executor || meta.model || '')
        || (!/codex|gpt/i.test(meta.executor || meta.model || '') && numeric(meta.numTurns));
      rows.push({ repo, exitCode, gate, cost, briefChars,
        model: typeof meta.model === 'string' && meta.model.trim() ? meta.model : 'unknown',
        effort: meta.reasoningEffort || meta.effort || 'unknown',
        sessionId: typeof meta.sessionId === 'string' && meta.sessionId.trim() ? meta.sessionId : null,
        resumedFrom: typeof meta.resumedFrom === 'string' && meta.resumedFrom.trim() ? meta.resumedFrom : null,
        fixLoop: numeric(meta.fixLoop) && meta.fixLoop > 0,
        fixBriefs: current ? [...files].filter(f => /^(?:fix-\d+(?:-[a-z0-9]+)?|fix-brief-\d+|group-fix\d+|fix\d+)\.md$/i.test(f)).length : 0,
        claudeContextPerTurn: isClaude && numeric(meta.contextPerTurn) ? meta.contextPerTurn : null });
    }
  }
  visit(root);
  let repositories = [...new Set(rows.map(r => r.repo))].sort().map(repo => summarize(rows.filter(r => r.repo === repo), repo));
  if (!options.json && !options.repo) {
    if (!options.all) {
      const small = new Set(repositories.filter(r => r.runs < 3).map(r => r.repo));
      repositories = repositories.filter(r => !small.has(r.repo));
      if (small.size) repositories.push(summarize(rows.filter(r => small.has(r.repo)), `other (${small.size} repos)`));
    }
    repositories.sort((a, b) => Number(a.repo.startsWith('other (')) - Number(b.repo.startsWith('other (')) || b.runs - a.runs || a.repo.localeCompare(b.repo));
  }
  const firstBySession = new Map(rows.filter(r => !r.fixLoop && r.sessionId).map(r => [r.sessionId, r]));
  const groups = new Map();
  for (const row of rows) {
    const firstRun = row.fixLoop ? firstBySession.get(row.resumedFrom) : row;
    const executor = firstRun || row;
    const key = JSON.stringify([executor.model, executor.effort]);
    if (!groups.has(key)) groups.set(key, { model: executor.model, effort: executor.effort, rows: [] });
    groups.get(key).rows.push({ ...row, firstRun });
  }
  const executors = [...groups.values()].map(group => {
    const summary = summarize(group.rows, '');
    const firstRuns = group.rows.length - summary.fixLoopRuns;
    const firstRunsWithFixLoops = new Set(group.rows.filter(r => r.fixLoop && r.firstRun).map(r => r.firstRun)).size;
    return {
      model: group.model, effort: group.effort, firstRuns, firstRunsWithFixLoops,
      fixLoopRuns: summary.fixLoopRuns,
      unmatchedFixLoopRuns: group.rows.filter(r => r.fixLoop && !r.firstRun).length,
      fixLoopRate: firstRuns ? firstRunsWithFixLoops / firstRuns : null,
      deadlineExits: summary.deadlineExits, red: summary.red, flaky: summary.flaky,
      medianCostUsd: distribution(group.rows.map(r => r.cost).filter(numeric)).median,
      costUsd: summary.costUsd, costSamples: summary.costSamples,
    };
  }).sort((a, b) => a.model.localeCompare(b.model) || a.effort.localeCompare(b.effort));
  return { filters: { since: options.since || null, until: options.until || null, repo: options.repo || null }, skipped,
    repositories, executors, overall: summarize(rows, 'Overall') };
}

function markdown(data) {
  const cell = value => String(value).replace(/\|/g, '\\|').replace(/[\r\n]+/g, ' ');
  const metric = d => `${d.median ?? 'n/a'}/${d.p90 ?? 'n/a'} (n=${d.samples})`;
  const percent = value => `${(100 * value).toFixed(1)}%`;
  const summaries = [...data.repositories, data.overall];
  const lines = ['# Run retrospective scan', '',
    `Filters: since ${data.filters.since || 'any'}, until ${data.filters.until || 'any'} (inclusive local dates), repo ${data.filters.repo || 'all'}; grouping by repository alias from the registry for a matching root, else repoRoot, Git main checkout, longest normalized root-folder prefix, or run folder.`, '',
    '| Repo | Runs | Fix-loop runs/rate | Fresh fix briefs | Deadline | Sandbox | Red/flaky gates | Brief chars median/p90 | Claude context/turn median/p90 | API-equivalent USD (samples) |',
    '|---|---:|---:|---:|---:|---:|---:|---|---|---:|'];
  for (const r of summaries) lines.push(`| ${cell(r.repo)} | ${r.runs} | ${r.fixLoopRuns}/${percent(r.fixLoopRate)} | ${r.freshFixBriefs} | ${r.deadlineExits} | ${r.sandboxExits} | ${r.red}/${r.flaky} | ${metric(r.briefChars)} | ${metric(r.claudeContextPerTurn)} | ${r.costUsd.toFixed(2)} (${r.costSamples}) |`);
  lines.push('', '## Exit-code distribution', '', '| Repo | Wrapper exit codes (code: runs) |', '|---|---|');
  for (const r of summaries) lines.push(`| ${cell(r.repo)} | ${Object.entries(r.exitCodes).map(([code, n]) => `${code}: ${n}`).join(', ') || 'none'} |`);
  lines.push('', '## Gates by command', '', '| Repo | Command | Runs | Red | Flaky | Red rate |', '|---|---|---:|---:|---:|---:|');
  for (const r of summaries) for (const g of r.gates) lines.push(`| ${cell(r.repo)} | ${cell(Array.isArray(g.command) ? g.command.join('; ') : g.command)} | ${g.runs} | ${g.red} | ${g.flaky} | ${percent(g.redRate)} |`);
  lines.push('', '## Executors', '', '| Model | Effort | First runs | First runs with fix loops/rate | Total fix-loop runs | Unmatched fix-loop runs | Deadline | Red/flaky gates | Median API-equivalent USD | Total API-equivalent USD (samples) |', '|---|---|---:|---:|---:|---:|---:|---:|---:|---:|');
  for (const e of data.executors) lines.push(`| ${cell(e.model)} | ${cell(e.effort)} | ${e.firstRuns} | ${e.firstRunsWithFixLoops}/${e.fixLoopRate === null ? 'n/a' : percent(e.fixLoopRate)} | ${e.fixLoopRuns} | ${e.unmatchedFixLoopRuns} | ${e.deadlineExits} | ${e.red}/${e.flaky} | ${e.medianCostUsd === null ? 'n/a' : e.medianCostUsd.toFixed(2)} | ${e.costUsd.toFixed(2)} (${e.costSamples}) |`);
  lines.push('', `Skipped malformed/partial artifacts: meta=${data.skipped.meta}, gate=${data.skipped.gate}, usage=${data.skipped.usage}.`,
    'Executor routing rate counts distinct first runs with a matched resumedFrom/sessionId fix loop divided by first runs. Unmatched loops are excluded from the rate and retain their recorded model/effort.',
    'Outcome uses wrapperExitCode; exitCode is used only when the wrapper field is absent. Missing metrics stay unknown; medians average the two middle samples, p90 uses nearest rank.',
    'API-equivalent cost prefers task-usage.json finish deltas, falling back to meta.totalCostUsd (which may be cumulative on legacy resumes). Coverage is partial; these are estimates, not invoices.');
  return lines.join('\n') + '\n';
}

if (require.main === module) {
  try {
    const options = parseArgs(process.argv.slice(2));
    if (options.help) {
      process.stdout.write('Usage: node bin/retro-scan.js [--runs <dir>] [--roots <dir,dir> (optional checkout roots)] [--since YYYY-MM-DD] [--until YYYY-MM-DD] (inclusive local dates) [--repo <repository>] [--registry <file>] [--all] [--json] [--out <file>]\n');
    } else {
      const data = scan(options);
      const output = options.json ? JSON.stringify(data, null, 2) + '\n' : markdown(data);
      if (options.out) fs.writeFileSync(options.out, output, 'utf8');
      else process.stdout.write(output);
    }
  } catch (error) {
    process.stderr.write(`retro-scan: ${error.message}\n`);
    process.exitCode = 1;
  }
}
