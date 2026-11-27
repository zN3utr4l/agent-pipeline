import { read } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import { accountsOf, loginFor } from './github'
import { coarse, COLOR, GLYPH, MINUTE } from './look'
import { registryOf } from './pipeline'
import type { Registry } from './pipeline'

const pipelineHome = { plugin: 'cockpit', key: 'pipelineHome' } as const

const CHANGES = /(^|[\s;&|(\\/"'`])(git(?:\.exe)?["']?\s+push|gh(?:\.exe)?["']?\s+(pr\s+(create|merge)|workflow\s+run|run\s+rerun))\b/
type Repo = { repo: string; github: string }
type Runner = { id: number; name: string; status: string; busy: boolean }
type Workflow = { name: string; status: string; head_branch: string; run_started_at?: string; created_at?: string; pull_requests?: { number: number }[] }
type Reading = { repo: string; runners: Runner[]; workflows: Workflow[] }

const api = async <T,>($: EngineInterface, github: string, path: string, env: Record<string, string>): Promise<T> => {
  const result = await $.process.run(['gh', 'api', `/repos/${github}/actions/${path}`], { env, timeoutMs: 15_000 })
  if (result.exitCode !== 0) throw new Error(`gh exit ${result.exitCode}`)
  return JSON.parse(result.stdout) as T
}
let interactive = false
let repos: Repo[] | undefined
let accounts = accountsOf({})
let reading: Reading[] = []
let stale = false
let fetching = false
let nextRead = 0
let changedAt: number | undefined

const refresh = async ($: EngineInterface) => {
  if (fetching) return
  fetching = true
  changedAt = undefined
  try {
    if (repos === undefined) {
      const home = await read($, pipelineHome)
      const registry: Registry = home === '' ? {} : registryOf(await $.fs.read(`${home}\\config\\executors.json`).catch(() => '{}'))
      const configured = registry.defaults?.cockpitRunnerRoot
      const root = typeof configured === 'string' ? configured.replace(/\\/g, '/').toLowerCase().replace(/\/+$/, '') : undefined
      accounts = accountsOf(registry)
      repos = Object.values(registry.executors ?? {}).filter((repo): repo is Repo => {
        const path = repo.repo?.replace(/\\/g, '/').toLowerCase()
        return path !== undefined && (root === undefined || path === root || path.startsWith(`${root}/`)) && typeof repo.github === 'string' && /^[\w.-]+\/[\w.-]+$/.test(repo.github)
      }).filter((repo, index, all) => all.findIndex(other => other.github === repo.github) === index)
    }
    const next: Reading[] = []
    const tokens = new Map<string, Record<string, string>>()
    for (const repo of repos) {
      const login = loginFor(repo.repo, accounts)
      const env = tokens.get(login ?? '') ?? {}
      if (login !== undefined && !tokens.has(login)) {
        const token = await $.process.run(['gh', 'auth', 'token', '--user', login], { timeoutMs: 15_000 })
        if (token.exitCode === 0 && token.stdout.trim() !== '') env.GH_TOKEN = token.stdout.trim()
        tokens.set(login, env)
      }
      const { runners } = await api<{ runners: Runner[] }>($, repo.github, 'runners?per_page=100', env)
      if (runners.length === 0) continue
      const result = await api<{ workflow_runs: Workflow[] }>($, repo.github, 'runs?per_page=20', env)
      const workflows = result.workflow_runs.filter(run => run.status === 'in_progress' || run.status === 'queued')
      next.push({ repo: repo.github.split('/')[1] ?? repo.github, runners, workflows })
    }
    reading = next
    stale = false
  } catch {
    stale = true
  } finally {
    fetching = false
    nextRead = (await $.clock.now()) + MINUTE
    $.ui.invalidate('ui.render')
  }
}

export const registerRunner: Register = on => {
  on('session.start', async ($, e, next) => {
    interactive = e.isInteractive && e.surface === 'terminal'
    return next(e)
  })
  on('ui.message', { component: 'AbovePrompt', element: 'runner-poll', surface: 'terminal' }, async ($, e, next) => {
    const now = await $.clock.now()
    if (interactive && e.data === 'poll' && (now >= nextRead || changedAt !== undefined && now >= changedAt)) await refresh($)
    return next(e)
  })
  on('tool.call', { tool: 'Bash' }, async ($, e, next) => {
    const result = await next(e)
    if (interactive && CHANGES.test(e.command)) changedAt = (await $.clock.now()) + 5000
    return result
  })
  on('tool.call', { tool: 'PowerShell' }, async ($, e, next) => {
    const result = await next(e)
    if (interactive && CHANGES.test(e.command)) changedAt = (await $.clock.now()) + 5000
    return result
  })
  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const below = await next(e)
    if (!interactive || e.surface !== 'terminal' || e.props.hasSurvey) return below
    const { Box, Client, Text } = $.ui.resolve(e)
    const now = await $.clock.now()
    const details: string[] = []
    let busy = false
    let offline = false
    for (const repo of reading) {
      for (const runner of repo.runners.filter(runner => runner.status !== 'online')) {
        details.push(`${repo.repo} ${runner.name} ${GLYPH.bad} offline`)
        offline = true
      }
      const occupied = repo.runners.some(runner => runner.busy)
      const workflows = repo.workflows.filter(run => run.status === 'queued' || occupied && run.status === 'in_progress')
      busy ||= occupied
      if (occupied && !workflows.some(run => run.status === 'in_progress')) details.push(`${repo.repo} busy`)
      for (const run of workflows) {
        const ref = run.pull_requests?.[0]?.number === undefined ? run.head_branch : `#${run.pull_requests[0].number}`
        const start = Date.parse(run.run_started_at ?? run.created_at ?? '')
        const elapsed = Number.isFinite(start) ? coarse(now - start) : '?'
        details.push(run.status === 'queued'
          ? `${repo.repo} queued (${run.name} ${ref} · ${elapsed})`
          : `${repo.repo} ${run.name} ${ref} · ${elapsed}`)
      }
    }
    const glyph = offline ? GLYPH.bad : busy ? GLYPH.half : GLYPH.dot
    return <Box flexDirection="column">
      <Client key="runner-poll" module="./runner-poll.tsx" props={{}} />
      {details.length === 0 && !stale ? null : <Box key="runner-lane" flexDirection="row" minWidth={0}>
        <Text wrap="truncate-end">
          <Text color={offline ? COLOR.bad : busy ? COLOR.info : COLOR.warn}>{glyph}</Text>
          <Text dimColor> runner · </Text>
          <Text>{details.join(' · ')}</Text>
          {stale ? <Text dimColor>{details.length === 0 ? '' : ' · '}stale reading</Text> : null}
        </Text>
      </Box>}
      {below}
    </Box>
  })
}
