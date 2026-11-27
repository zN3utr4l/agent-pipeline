import { execFile } from 'node:child_process';
import { accountsOf, loginFor, verdictOf } from '../core/readings.ts';

const QUERY = `query { viewer { pullRequests(states:OPEN,first:20,orderBy:{field:UPDATED_AT,direction:DESC}) { nodes {
 number url isDraft reviewDecision mergeable repository { name } commits(last:1) { nodes { commit { committedDate statusCheckRollup { state } } } }
 timelineItems(last:1,itemTypes:[HEAD_REF_FORCE_PUSHED_EVENT]) { nodes { ... on HeadRefForcePushedEvent { createdAt } } }
 reactions(content:THUMBS_UP,first:10) { nodes { createdAt user { login } } } reviews(last:10) { nodes { author { login } submittedAt } }
} } } }`;
export function ghRead(args, env, signal) {
  return new Promise(resolve => {
    execFile('gh', args, { env: { ...process.env, ...env }, signal, windowsHide: true, timeout: 15000, maxBuffer: 1048576 }, (error, stdout) => resolve({ status: error ? 1 : 0, stdout }));
  });
}
export async function refreshGithub({ registry = {}, cwd = '', previous = {}, now = Date.now(), run = ghRead, signal, prs = true, runners = true }) {
  const next = { ...previous };
  const accounts = accountsOf(registry);
  const tokens = new Map();
  const auth = async path => {
    const login = loginFor(path, accounts);
    if (!login) return {};
    if (!tokens.has(login)) {
      const token = await run(['auth', 'token', '--user', login], {}, signal);
      if (token.status !== 0 || !token.stdout.trim()) throw new Error('unavailable');
      tokens.set(login, { GH_TOKEN: token.stdout.trim() });
    }
    return tokens.get(login);
  };
  const query = async (args, path) => {
    if (signal?.aborted) throw new Error('closed');
    const result = await run(args, await auth(path), signal);
    if (result.status !== 0) throw new Error('unavailable');
    return JSON.parse(result.stdout);
  };
  if (prs) {
    try {
      const result = await query(['api', 'graphql', '-f', `query=${QUERY}`], cwd);
      const nodes = result.data.viewer.pullRequests.nodes;
      if (!Array.isArray(nodes)) throw new Error('partial');
      next.prs = { fetchedAt: now, rows: nodes.map(pr => ({ number: pr.number, repo: pr.repository.name, verdict: verdictOf(pr) })) };
    } catch { next.prs = { ...previous.prs, error: 'GitHub reading unavailable' }; }
  }
  if (runners) {
    try {
      const normalize = path => path.replace(/\\/g, '/').toLowerCase().replace(/\/+$/, '');
      const root = registry.defaults?.cockpitRunnerRoot;
      const seen = new Set(); const rows = [];
      for (const entry of Object.values(registry.executors || {})) {
        if (!entry.repo || !/^[\w.-]+\/[\w.-]+$/.test(entry.github || '')) continue;
        const path = normalize(entry.repo);
        if (root && path !== normalize(root) && !path.startsWith(`${normalize(root)}/`)) continue;
        const slug = entry.github.toLowerCase();
        if (seen.has(slug)) continue; seen.add(slug);
        if (seen.size > 20) break;
        const runners = await query(['api', `repos/${slug}/actions/runners?per_page=100`], entry.repo);
        const workflows = await query(['api', `repos/${slug}/actions/runs?per_page=20`], entry.repo);
        if (!Array.isArray(runners.runners) || !Array.isArray(workflows.workflow_runs)) throw new Error('partial');
        rows.push({ repo: slug, runners: runners.runners.map(x => ({ name: x.name, status: x.status, busy: x.busy })), workflows: workflows.workflow_runs.filter(x => ['in_progress', 'queued'].includes(x.status)).map(x => ({ name: x.name, status: x.status })) });
      }
      next.runners = { fetchedAt: now, rows };
    } catch { next.runners = { ...previous.runners, error: 'GitHub reading unavailable' }; }
  }
  return next;
}
