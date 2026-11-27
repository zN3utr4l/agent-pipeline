'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const script = path.resolve(__dirname, '../skills/pipeline/bin/retro-scan.js');
const fixture = fs.mkdtempSync(path.join(os.tmpdir(), '.test-retro-scan-'));
let assertions = 0;
function equal(actual, expected) { assertions++; assert.deepEqual(actual, expected); }
function ok(condition, message) { assertions++; assert.ok(condition, message); }
function run(repo, name, meta, artifacts = {}) {
  const dir = path.join(fixture, repo, name);
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, 'meta.json'), typeof meta === 'string' ? meta : JSON.stringify(meta));
  for (const [file, value] of Object.entries(artifacts)) {
    fs.writeFileSync(path.join(dir, file), typeof value === 'string' ? value : JSON.stringify(value));
  }
}
function cli(...args) {
  const result = spawnSync(process.execPath, [script, '--runs', fixture, ...args], { encoding: 'utf8', env: { ...process.env, TZ: 'UTC' } });
  equal(result.status, 0);
  return result.stdout;
}
try {
  ok(fs.existsSync(script), 'retro scanner is not implemented');
  const defaultHome = path.join(fixture, 'default-home');
  const defaultState = path.join(defaultHome, '.pipeline');
  const defaultRun = path.join(defaultState, 'runs', 'old-alias', 'default-run');
  fs.mkdirSync(defaultRun, { recursive: true });
  fs.mkdirSync(path.join(defaultState, 'config'), { recursive: true });
  fs.writeFileSync(path.join(defaultRun, 'meta.json'), JSON.stringify({ startedAt: '2026-09-15T10:00:00Z', exitCode: 0, repoRoot: defaultHome }));
  fs.writeFileSync(path.join(defaultState, 'config', 'executors.json'), JSON.stringify({ executors: { 'default-alias': { repo: defaultHome } } }));
  const defaultScan = spawnSync(process.execPath, [script, '--json'], { encoding: 'utf8', env: { ...process.env, USERPROFILE: defaultHome, HOME: defaultHome, PIPELINE_HOME: '', TZ: 'UTC' } });
  equal(defaultScan.status, 0);
  equal(JSON.parse(defaultScan.stdout).repositories.map(r => [r.repo, r.runs]), [['default-alias', 1]]);
  fs.rmSync(defaultHome, { recursive: true, force: true });
  run('alpha', '2026-09-15-claude', { repo: 'alpha', executor: 'opus', startedAt: '2026-09-15T10:00:00Z', wrapperExitCode: 0, exitCode: 1, briefChars: 100, contextPerTurn: 1000, numTurns: 2, totalCostUsd: 9 }, {
    'brief.md': 'not the recorded size',
    'gate.json': { command: 'npm test', exitCode: 0, timedOut: false, flaky: true },
    'task-usage.json': { phase: 'finish', sessions: [{ delta: { cost: 1.25 } }] },
  });
  run('alpha', '2026-09-16-codex', { repo: 'alpha', executor: 'codex', startedAt: '2026-09-16T12:00:00Z', wrapperExitCode: 5, exitCode: 0, fixLoop: 2, contextPerTurn: 999999 }, {
    'brief.md': 'x'.repeat(300), 'group-fix2.md': 'fix', 'fix-1.md': 'fix', 'fix-1-fresh.md': 'fix', 'fix-brief-3.md': 'fix', 'fix4.md': 'fix',
    'fix-evidence.md': 'no', 'fix-plan.md': 'no', 'prefix-1.md': 'no',
    'gate.json': { command: 'npm test', exitCode: 1, timedOut: false },
    'task-usage.json': { phase: 'finish', sessions: [{ delta: { cost: 0.75 } }] },
  });
  run('beta', '2026-09-17-deadline', { repo: 'beta', model: 'claude-opus-5-5', startedAt: '2026-09-17T23:59:59Z', exitCode: 124, contextPerTurn: 3000, briefChars: 200, totalCostUsd: 2 }, {
    'gate.json': { command: 'flutter test', exitCode: null, timedOut: true }, 'fix-brief-2.md': 'fix', 'fix-evidence.md': 'no',
  });
  run('beta', '2026-09-18-sandbox', { repo: 'beta', executor: 'codex', startedAt: '2026-09-18T00:00:00Z', wrapperExitCode: 75, exitCode: 0 }, {
    'gate.json': '{bad', 'task-usage.json': { phase: 'finish', sessions: [{ delta: { cost: null } }] },
  });
  run('beta', '2026-09-19-null-wrapper', { repo: 'beta', startedAt: '2026-09-19T00:00:00Z', wrapperExitCode: null, exitCode: 0 });
  run('beta', '2026-09-20-malformed', '{oops');
  run('beta', '2026-09-20-partial', {});
  run('alpha', '2026-09-01-old', { repo: 'alpha', executor: 'codex', startedAt: '2026-09-01T00:00:00Z', wrapperExitCode: 0 });
  // Valid-looking saved metadata inside a run is not another run.
  const saved = path.join(fixture, 'alpha/2026-09-16-codex/before');
  fs.mkdirSync(saved);
  fs.writeFileSync(path.join(saved, 'meta.json'), JSON.stringify({ repo: 'ghost', startedAt: '2026-09-16', exitCode: 0 }));
  const data = JSON.parse(cli('--since', '2026-09-15', '--json'));
  equal(data.overall.runs, 4);
  equal(data.overall.exitCodes, { '0': 1, '5': 1, '75': 1, '124': 1 });
  equal(data.overall.fixLoopRuns, 1);
  equal(data.overall.fixLoopRate, 0.25);
  equal(data.overall.freshFixBriefs, 6);
  equal(data.overall.deadlineExits, 1);
  equal(data.overall.sandboxExits, 1);
  equal(data.overall.briefChars, { samples: 3, median: 200, p90: 300 });
  equal(data.overall.claudeContextPerTurn, { samples: 2, median: 2000, p90: 3000 });
  equal(data.overall.costUsd, 4);
  equal(data.overall.costSamples, 3);
  equal(data.overall.gates, [{ command: 'flutter test', runs: 1, red: 1, flaky: 0, redRate: 1 }, { command: 'npm test', runs: 2, red: 1, flaky: 1, redRate: 0.5 }]);
  equal(data.skipped, { meta: 3, gate: 1, usage: 1 });
  equal(data.repositories.map(r => r.repo), ['alpha', 'beta']);
  const filtered = JSON.parse(cli('--since', '2026-09-16', '--until', '2026-09-17', '--repo', 'beta', '--json'));
  equal(filtered.overall.runs, 1);
  equal(filtered.repositories[0].repo, 'beta');
  equal(filtered.overall.exitCodes, { '124': 1 });
  const markdown = cli('--since', '2026-09-15');
  ok(markdown.includes('| other (2 repos) |') && !markdown.includes('| alpha |') && !markdown.includes('| beta |') && markdown.includes('| Overall |'), 'small repositories folded in default tables');
  ok(markdown.includes('| other (2 repos) | 4 | 1/25.0% | 6 | 1 | 1 | 2/1 | 200/300 (n=3) | 2000/3000 (n=2) | 4.00 (3) |'), 'folded raw samples preserve metrics');
  ok(markdown.includes('| other (2 repos) | 0: 1, 5: 1, 75: 1, 124: 1 |'), 'folded exit distribution');
  ok(markdown.includes('| other (2 repos) | npm test | 2 | 1 | 1 | 50.0% |') && markdown.includes('| other (2 repos) | flutter test | 1 | 1 | 0 | 100.0% |'), 'folded gate counts and rates');
  const allMarkdown = cli('--since', '2026-09-15', '--all');
  ok(allMarkdown.includes('| alpha |') && allMarkdown.includes('| beta |') && !allMarkdown.includes('other ('), '--all retains every repository');
  const overallRows = text => text.split('\n').filter(line => line.startsWith('| Overall |'));
  equal(overallRows(markdown), overallRows(allMarkdown));
  equal(JSON.parse(cli('--since', '2026-09-15', '--all', '--json')), data);
  const repoMarkdown = cli('--since', '2026-09-15', '--repo', 'beta');
  ok(repoMarkdown.includes('| beta | 2 |') && !repoMarkdown.includes('other ('), '--repo does not fold a small repository');
  ok(markdown.includes('npm test') && markdown.includes('flutter test'), 'gate commands');
  ok(markdown.includes('API-equivalent') && markdown.includes('Skipped'), 'coverage and skipped artifacts');
  const out = path.join(fixture, 'scan.json');
  equal(cli('--since', '2026-09-15', '--json', '--out', out), '');
  equal(JSON.parse(fs.readFileSync(out, 'utf8')), data);
  equal(JSON.parse(cli('--repo', 'missing', '--json')).overall.runs, 0);
  for (const args of [['--since', 'nonsense'], ['--since', '2026-02-30'], ['--since', '2026-09-18', '--until', '2026-09-17'], ['--wat'], ['--repo']]) {
    const result = spawnSync(process.execPath, [script, '--runs', fixture, ...args], { encoding: 'utf8' });
    equal(result.status, 1);
    ok(result.stderr.includes('retro-scan:'), 'clear CLI error');
  }
  const missing = spawnSync(process.execPath, [script, '--runs', path.join(fixture, 'absent')], { encoding: 'utf8' });
  equal(missing.status, 1);
  for (const [repo, count] of [['gamma', 3], ['delta', 5]]) {
    for (let i = 0; i < count; i++) run(repo, `2026-09-21-${i}`, { repo, executor: 'codex', startedAt: '2026-09-21T00:00:00Z', wrapperExitCode: 0 });
  }
  const summaryNames = text => text.split('## Exit-code distribution')[0].split('\n')
    .filter(line => line.startsWith('| ') && !line.startsWith('| Repo |')).map(line => line.split('|')[1].trim());
  equal(summaryNames(cli('--since', '2026-09-15')), ['delta', 'gamma', 'other (2 repos)', 'Overall']);
  equal(summaryNames(cli('--since', '2026-09-15', '--all')), ['delta', 'gamma', 'alpha', 'beta', 'Overall']);
  const expandedJson = JSON.parse(cli('--since', '2026-09-15', '--json'));
  equal(expandedJson.repositories.map(r => r.repo), ['alpha', 'beta', 'delta', 'gamma']);
  equal(expandedJson.overall.runs, 12);
  equal(data.repositories[0].flaky, 1);
  equal(data.overall.red, 2);
  equal(data.overall.flaky, 1);
  ok(markdown.includes('Red/flaky gates') && markdown.includes('## Executors'), 'both tables are printed');
  run('routing', 'first', { sessionId: 'routing-session', model: 'gpt-test', reasoningEffort: 'medium', startedAt: '2026-12-01', exitCode: 0, totalCostUsd: 1 }, { 'gate.json': { command: 'test', exitCode: 0, flaky: true } });
  run('routing', 'second-first', { sessionId: 'no-fix-session', model: 'gpt-test', effort: 'medium', startedAt: '2026-12-01', exitCode: 0 });
  run('routing', 'fix', { resumedFrom: 'routing-session', model: 'different-model', effort: 'high', fixLoop: 1, startedAt: '2026-12-02', exitCode: 124, totalCostUsd: 3 }, { 'gate.json': { command: 'test', exitCode: 1 } });
  run('routing', 'fix2', { resumedFrom: 'routing-session', model: 'different-model', effort: 'high', fixLoop: 2, startedAt: '2026-12-03', exitCode: 0 });
  run('routing', 'old-first', { sessionId: 'old-session', model: 'gpt-test', effort: 'medium', startedAt: '2026-11-30', exitCode: 0 });
  run('routing', 'unmatched', { resumedFrom: 'old-session', model: 'gpt-test', effort: 'medium', fixLoop: 1, startedAt: '2026-12-03', exitCode: 0 });
  run('routing', 'unknown', { resumedFrom: 'missing-session', startedAt: '2026-12-03', fixLoop: 1, exitCode: 0 });
  const routed = JSON.parse(cli('--since', '2026-12-01', '--json'));
  equal(routed.executors.length, 2);
  equal(routed.executors[0], { model: 'gpt-test', effort: 'medium', firstRuns: 2, firstRunsWithFixLoops: 1, fixLoopRuns: 3, unmatchedFixLoopRuns: 1, fixLoopRate: 0.5, deadlineExits: 1, red: 1, flaky: 1, medianCostUsd: 2, costUsd: 4, costSamples: 2 });
  equal(routed.executors[1], { model: 'unknown', effort: 'unknown', firstRuns: 0, firstRunsWithFixLoops: 0, fixLoopRuns: 1, unmatchedFixLoopRuns: 1, fixLoopRate: null, deadlineExits: 0, red: 0, flaky: 0, medianCostUsd: null, costUsd: 0, costSamples: 0 });
  ok(cli('--since', '2026-12-01').includes('| gpt-test | medium | 2 | 1/50.0% | 3 | 1 | 1 | 1/1 | 2.00 | 4.00 (2) |'), 'executor markdown matched-session metrics');
  const allRouting = JSON.parse(cli('--since', '2026-11-30', '--repo', 'routing', '--json'));
  equal(allRouting.executors[0].firstRunsWithFixLoops, 2);
  equal(allRouting.executors[0].firstRuns, 3);
  equal(allRouting.executors[0].unmatchedFixLoopRuns, 0);
  const loopsOnly = JSON.parse(cli('--since', '2026-12-02', '--json'));
  equal(loopsOnly.executors.find(e => e.model === 'different-model').unmatchedFixLoopRuns, 2);
  equal(loopsOnly.executors.find(e => e.model === 'different-model').fixLoopRate, null);
  run('history', 'same-directory', { model: 'gpt-test', reasoningEffort: 'medium', sessionId: 'history-session', resumedFrom: 'history-session', fixLoop: 2, startedAt: '2027-01-03', wrapperExitCode: 0,
    gate: null, attempts: [
      { model: 'gpt-test', reasoningEffort: 'medium', sessionId: 'history-session', startedAt: '2027-01-01', exitCode: 1, wrapperExitCode: 124, timedOut: true, fixLoop: null, gate: null },
      { model: 'gpt-test', reasoningEffort: 'medium', sessionId: 'history-session', resumedFrom: 'history-session', startedAt: '2027-01-02', exitCode: 0, wrapperExitCode: 75, fixLoop: 1, gate: { command: 'archived test', exitCode: 7 } },
    ] }, { 'gate.json': { command: 'stale test', exitCode: 7 }, 'task-usage.json': { phase: 'finish', sessions: [{ delta: { cost: 2 } }] }, 'fix-1.md': 'fix' });
  run('history', 'legacy', { model: 'gpt-test', reasoningEffort: 'medium', startedAt: '2027-01-04', exitCode: 0 });
  const history = JSON.parse(cli('--repo', 'history', '--since', '2027-01-01', '--json'));
  equal(history.overall.runs, 4);
  equal(history.overall.exitCodes, { '0': 2, '75': 1, '124': 1 });
  equal(history.overall.deadlineExits, 1);
  equal(history.overall.sandboxExits, 1);
  equal(history.overall.fixLoopRuns, 2);
  equal(history.overall.gates, [{ command: 'archived test', runs: 1, red: 1, flaky: 0, redRate: 1 }]);
  equal(history.overall.costUsd, 2);
  equal(history.overall.costSamples, 1);
  equal(history.overall.freshFixBriefs, 1);
  equal(history.executors[0].firstRunsWithFixLoops, 1);
  equal(history.executors[0].unmatchedFixLoopRuns, 0);
  const historyFirst = JSON.parse(cli('--repo', 'history', '--until', '2027-01-01', '--json'));
  equal(historyFirst.overall.exitCodes, { '124': 1 });
  for (let i = 0; i < 2; i++) run('array-gates', `2027-02-01-${i}`, { startedAt: '2027-02-01', exitCode: 5 }, {
    'gate.json': { command: ['api test', 'worker test'], exitCode: 7, timedOut: false,
      commands: [{ command: 'api test', exitCode: 7, failures: ['FAIL api'] }, { command: 'worker test', exitCode: 9, failures: ['FAIL worker'] }] },
  });
  const arrays = JSON.parse(cli('--repo', 'array-gates', '--json'));
  equal(arrays.overall.gates, [{ command: ['api test', 'worker test'], runs: 2, red: 2, flaky: 0, redRate: 1 }]);
  ok(cli('--repo', 'array-gates').includes('api test; worker test'), 'array gate markdown preserves command order');
  const help = spawnSync(process.execPath, [script, '--help'], { encoding: 'utf8' });
  equal(help.status, 0);
  ok(help.stdout.includes('--all'), 'usage must document --all');
  ok(help.stdout.includes('inclusive local dates'), 'usage must explain local-date filters');
  run('timezone', 'eve-boundary', { repo: 'timezone', startedAt: '2026-10-05T23:30:00Z', exitCode: 0 });
  const zoned = spawnSync(process.execPath, [script, '--runs', fixture, '--repo', 'timezone', '--since', '2026-10-06', '--json'], {
    encoding: 'utf8', env: { ...process.env, TZ: 'America/New_York' },
  });
  equal(zoned.status, 0);
  equal(JSON.parse(zoned.stdout).overall.runs, 0);
  const zonedPrior = spawnSync(process.execPath, [script, '--runs', fixture, '--repo', 'timezone', '--until', '2026-10-05', '--json'], {
    encoding: 'utf8', env: { ...process.env, TZ: 'America/New_York' },
  });
  equal(zonedPrior.status, 0);
  equal(JSON.parse(zonedPrior.stdout).overall.runs, 1);
  const repos = path.join(fixture, 'repos');
  for (const name of ['Acme', 'Acme.Api', '.DotRepo']) fs.mkdirSync(path.join(repos, name), { recursive: true });
  fs.mkdirSync(path.join(repos, '.hub'), { recursive: true });
  const registry = path.join(fixture, 'executors.json');
  fs.writeFileSync(registry, JSON.stringify({ executors: { hub: { repo: path.join(repos, '.hub') } } }));
  run('hub-task', 'registered-root', { startedAt: '2026-11-01T00:00:00Z', exitCode: 0, repoRoot: `${path.join(repos, '.hub').toUpperCase()}${path.sep}` });
  equal(JSON.parse(cli('--since', '2026-11-01', '--roots', repos, '--registry', registry, '--repo', 'hub', '--json')).overall.runs, 1);
  fs.rmSync(path.join(fixture, 'hub-task'), { recursive: true, force: true });
  const main = path.join(repos, 'Acme.Api');
  function git(...args) {
    const result = spawnSync('git', ['-C', main, ...args], { encoding: 'utf8' });
    equal(result.status, 0);
  }
  git('init', '-b', 'main');
  fs.writeFileSync(path.join(main, 'source.txt'), 'fixture');
  git('add', 'source.txt');
  git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-m', 'fixture');
  const worktree = path.join(fixture, '.worktrees', 'services-win-lag');
  git('worktree', 'add', '-b', 'win-lag', worktree);
  const meta = { startedAt: '2026-11-01T00:00:00Z', exitCode: 0 };
  run('old-alias', 'root-first', { ...meta, repo: 'old-alias', repoRoot: 'C:\\fixture\\Acme.Api', repoPath: worktree });
  run('worktree-alias', 'git-fallback', { ...meta, repo: 'worktree-alias', repoPath: worktree });
  run('Acme-Api-phase2', 'longest-prefix', { ...meta, repo: 'Acme-Api-phase2', repoPath: path.join(fixture, 'deleted-worktree') });
  run('dotrepo-task', 'dot-folder', { ...meta, repo: 'dotrepo-task' });
  run('unmatched-folder', 'folder-fallback', { ...meta, repo: 'obsolete-meta-alias' });
  run('root-precedence', 'root-wins', { ...meta, repoRoot: 'C:/fixture/Canonical', repoPath: worktree });
  const grouped = JSON.parse(cli('--since', '2026-11-01', '--until', '2026-11-29', '--roots', repos, '--json'));
  equal(grouped.repositories.map(r => [r.repo, r.runs]), [['.dotrepo', 1], ['acme.api', 3], ['canonical', 1], ['unmatched-folder', 1]]);
  equal(JSON.parse(cli('--since', '2026-11-01', '--roots', repos, '--repo', 'Acme.Api', '--json')).overall.runs, 3);
  const groupedMarkdown = cli('--since', '2026-11-01', '--until', '2026-11-29', '--roots', repos);
  ok(groupedMarkdown.includes('grouping by repository') && groupedMarkdown.includes('| acme.api | 3 |'), 'filters must name repository grouping');
  ok(groupedMarkdown.includes('other (3 repos)'), 'folding must follow repository grouping');
  ok(help.stdout.includes('--roots'), 'usage must document roots');
  console.log(`retro-scan tests: PASS (${assertions} assertions)`);
} finally {
  assert.equal(path.dirname(fixture), path.resolve(os.tmpdir()));
  assert.ok(path.basename(fixture).startsWith('.test-retro-scan-'));
  fs.rmSync(fixture, { recursive: true, force: true });
}
