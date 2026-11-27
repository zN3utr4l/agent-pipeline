import { expect, mock, test } from 'claude-code/testing'
import type { FsEntry, On, SessionRateLimit } from 'claude-code'
import { clockAt, resetAt } from '../hooks/look'
import { accountsOf } from '../hooks/github'

const MINUTE = 60_000
const NOW = Date.parse('2026-10-05T10:00:00Z')
const at = (ms: number) => new Date(NOW + ms).toISOString()

const START = { cwd: 'E:/Projects/Example/Acme-Api', surface: 'terminal' as const, isInteractive: true }
const BAND = {
  plugin: 'cockpit',
  surface: 'terminal' as const,
  component: 'AbovePrompt' as const,
  props: { hasSurvey: false, isWorking: false, maxRows: 12, bodyColumns: 150 } as never,
}

const RUNS = 'E:\\State\\pipeline\\runs'
const RUN = `${RUNS}\\Acme-Api\\2026-10-05-outbox-batch`
const OTHER = `${RUNS}\\Acme-Web\\2026-10-05-session-cache`
const launch = (dir: string, extra = '', repo = 'E:\\Projects\\Example\\Acme-Api') =>
  `pwsh -NoProfile -File E:\\State\\pipeline\\bin\\codex-run.ps1 -Repo ${repo} -Brief ${dir}\\brief.md -ReasoningEffort high${extra}`
const LAUNCH = launch(RUN, ' -FullAccess -TimeoutMinutes 90')

const STEP = { turnId: 't1', index: 0, model: 'claude-opus-5-5', messageCount: 3 }
const USAGE = {
  input_tokens: 1000,
  output_tokens: 2000,
  cache_read_input_tokens: 297_000,
  cache_creation_input_tokens: 2000,
  model: 'claude-opus-5-5',
}

const CODEX = { login: 'chatgpt-codex-connector' }

const node = (number: number, name: string, extra: Record<string, unknown> = {}) => ({
  number,
  title: `PR ${number}`,
  url: `https://github.com/org/${name}/pull/${number}`,
  isDraft: false,
  reviewDecision: null,
  mergeable: 'MERGEABLE',
  repository: { name },
  headRefName: 'feature/review',
  headRefOid: 'head-sha',
  headRepository: { nameWithOwner: `fork/${name}` },
  commits: { nodes: [{ commit: { committedDate: '2026-10-01T10:00:00Z', statusCheckRollup: { state: 'SUCCESS' } } }] },
  reactions: { nodes: [] },
  reviews: { nodes: [] },
  ...extra,
})

const PULLS = {
  data: {
    viewer: {
      login: 'team-user',
      pullRequests: {
        totalCount: 4,
        nodes: [
          node(1, 'Example-Tools', { mergeable: 'CONFLICTING' }),
          node(4, 'log-analysis', { reviews: { nodes: [{ author: CODEX, submittedAt: '2026-10-01T10:03:00Z' }] } }),
          node(5, 'Acme-Web', { reviews: { nodes: [{ author: CODEX, submittedAt: '2026-09-30T10:00:00Z' }] } }),
          node(7, 'Acme-Worker', { reactions: { nodes: [{ user: CODEX, createdAt: '2026-10-01T10:03:00Z' }] } }),
        ],
      },
    },
  },
}

type Ran = { value: { exitCode: number; stdout: string; stderr: string; isStdoutTruncated: false; isStderrTruncated: false } }
type Env = Record<string, string | undefined>

const ran = (exitCode: number, stdout = '', stderr = ''): Ran => ({
  value: { exitCode, stdout, stderr, isStdoutTruncated: false, isStderrTruncated: false },
})

const codeburn = (usedPct: number) =>
  JSON.stringify({ providers: [{ id: 'codex', available: true, windows: [{ label: 'Weekly', usedPct, resetsAt: at(50 * 60 * MINUTE) }] }] })

// The engine beneath the plugin: its clock, store and env, a disk, the processes it runs.
const world = (on: On, setup: { graphql?: Ran; comment?: Ran; quota?: number; commonDir?: string; origin?: string; pathFailure?: boolean; quotaMissing?: boolean; pipelineHome?: string; env?: Env; quotaFailure?: boolean; cwd?: string; processStart?: string; runnerApi?: (path: string) => Ran; settings?: Record<string, unknown>; settingsFailure?: boolean; usage?: typeof USAGE; toolText?: string } = {}) => {
  const toasts: string[] = []
  const calls: { argv: readonly string[]; env: Env }[] = []
  const panes: string[] = []
  const tools: Record<string, unknown>[] = []
  const reads: string[] = []
  const lists: string[] = []
  const writes: string[] = []
  let settingsReads = 0
  const disk = new Map<string, { text: string; mtimeMs: number }>()
  if (setup.commonDir !== undefined) disk.set('D:\\worktrees\\feature\\.git', { text: 'gitdir: fixture', mtimeMs: NOW })
  const clock = mock.clock(on, { now: NOW })
  // The dialog a call waits on: the call returns only once it was answered.
  let dialog: () => Promise<unknown> = async () => undefined
  let duringRead: { path: string; fn: () => Promise<unknown> } | undefined

  on('settings.read', () => {
    settingsReads++
    if (setup.settingsFailure) throw new Error('settings unavailable')
    return { value: setup.settings ?? {} }
  })
  mock.store(on)
  mock.env(on, { WT_SESSION: 'tab-1', PIPELINE_HOME: setup.pipelineHome ?? 'E:\\State\\pipeline', USERPROFILE: 'E:\\Users\\colleague', ...setup.env })
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  on('session.cwd', () => ({ value: setup.cwd ?? 'E:\\Projects\\Example\\Acme-Api' }))
  on('session.usage', () => ({ value: { startedAt: NOW, context: { window: 1_000_000 }, rateLimits: [] } }))
  on('session.measure', ($, e) => ({ changed: e.changed }))
  on('command.register', ($, e) => ({ value: { command: e.name } }))
  on('ui.toast', ($, e) => {
    checkDrawing([], [e.text])
    toasts.push(e.text)

    return { value: undefined }
  })
  on('ui.open', ($, e) => {
    panes.push(e.id)

    return { value: { isPlaced: true } as never }
  })
  on('ui.render', ($, e) => {
    const { Box } = $.ui.resolve(e)

    return h(Box, {}) as never
  })
  on('session.end', ($, e) => ({ sessionId: e.sessionId }))
  on('turn.complete', () => ({ text: '' }))
  on('prompt.submit', ($, e) => ({ text: e.text }))
  on('classic.PermissionRequest', () => ({}))
  on('turn.step', async function* ($, e) {
    return { turnId: e.turnId, index: e.index, answer: '', toolUses: [], stopReason: 'end_turn', usage: setup.usage ?? USAGE }
  })
  on('tool.call', async ($, e) => {
    tools.push({ ...e })
    await dialog()

    return { result: {} as never, text: setup.toolText ?? String(e.tool) }
  })
  on('process.run', ($, e) => {
    calls.push({ argv: e.argv, env: { ...e.init?.env } })

    if (e.init?.env?.CC_RUN_PID !== undefined) {
      return ran(e.init.env.CC_RUN_PID === '1234' && e.init.env.CC_RUN_START === (setup.processStart ?? at(-1000)) ? 0 : 1)
    }

    if (e.argv[0] === 'cmd.exe') {
      if (e.argv.at(-1) === 'where codeburn.cmd') return ran(setup.quotaMissing ? 1 : 0, setup.quotaMissing ? '' : 'E:\\Tools\\codeburn.cmd')
      if (setup.quotaFailure) return ran(1, '', 'quota offline')
      return ran(0, codeburn(setup.quota ?? 25))
    }

    if (e.init?.env?.CC_PATH !== undefined) return setup.pathFailure ? ran(1, '', 'path unavailable') : ran(0, /^(?:[a-z]:|\\\\)/i.test(e.init.env.CC_PATH) ? e.init.env.CC_PATH : `${e.init.env.CC_CWD}\\${e.init.env.CC_PATH.replace(/^\.\\/, '')}`)
    if (e.argv[0] === 'pwsh') return ran(0, e.init?.env?.CC_LAUNCHER?.replace(/\\bin\\[^\\]+$/, '\\config\\executors.json') ?? '')
    if (e.argv[0] === 'git') return ran(0, e.argv.includes('get-url') ? setup.origin ?? '' : setup.commonDir ?? '')

    if (e.argv[0] === 'gh' && e.argv[1] === 'auth') {
      return ran(0, 'token-of-work\n')
    }

    if (e.argv[0] === 'gh' && e.argv[1] === 'api') {
      if (e.argv[2] !== 'graphql') return setup.runnerApi?.(e.argv[2] ?? '') ?? ran(0, JSON.stringify(e.argv[2]?.includes('/activity?') ? [] : { runners: [] }))
      return setup.graphql ?? ran(0, JSON.stringify(PULLS))
    }

    if (e.argv[0] === 'gh' && e.argv[1] === 'pr') {
      return setup.comment ?? ran(0, 'https://github.com/org/Acme-Web/pull/5#issuecomment-1\n')
    }

    return ran(0)
  })
  on('fs.list', ($, e) => {
    lists.push(e.path)
    const dir = e.path.replace(/[\\/]+$/, '').toLowerCase()
    const entries = new Map<string, FsEntry>()

    for (const [path, file] of disk) {
      if (!path.toLowerCase().startsWith(`${dir}\\`)) {
        continue
      }

      const [name = '', ...deeper] = path.slice(dir.length + 1).split('\\')
      const seen = entries.get(name)

      entries.set(name, {
        name,
        kind: deeper.length > 0 ? 'dir' : 'file',
        size: deeper.length > 0 ? 0 : file.text.length,
        mtimeMs: Math.max(file.mtimeMs, seen?.mtimeMs ?? 0),
        isLink: false,
      })
    }

    if (entries.size === 0) {
      throw new Error(`ENOENT: ${e.path}`)
    }

    return { value: [...entries.values()] }
  })
  on('fs.read', async ($, e) => {
    reads.push(e.path)
    const file = [...disk].find(([path]) => path.toLowerCase() === e.path.toLowerCase())

    if (file === undefined) {
      throw new Error(`ENOENT: ${e.path}`)
    }

    const text = file[1].text
    if (duringRead?.path === e.path) {
      const pending = duringRead
      duringRead = undefined
      await pending.fn()
    }
    return { value: text }
  })
  on('fs.write', ($, e) => {
    writes.push(e.path)
    disk.set(e.path, { text: e.text, mtimeMs: clock.now() })
    return { value: undefined }
  })

  return {
    toasts,
    panes,
    tools,
    clock,
    calls,
    reads,
    lists,
    writes,
    settingsReads: () => settingsReads,
    read: (path: string) => disk.get(path)?.text,
    write: (path: string, text: string, mtimeMs = clock.now()) => {
      disk.set(path, { text, mtimeMs })
    },
    remove: (path: string) => {
      disk.delete(path)
    },
    notifications: () => calls.filter(call => call.argv[0] === 'powershell.exe').map(call => call.env),
    whileAsking: (fn: () => Promise<unknown>) => {
      dialog = fn
    },
    whileReading: (path: string, fn: () => Promise<unknown>) => {
      duringRead = { path, fn }
    },
  }
}

// What an element shows, its nested elements' text included.
const shown = (node: unknown): string => {
  if (typeof node === 'string' || typeof node === 'number') {
    return String(node)
  }

  if (Array.isArray(node)) {
    return node.map(shown).join('')
  }

  if (typeof node === 'object' && node !== null) {
    const element = node as { children?: unknown; props?: { children?: unknown } }

    return shown(element.children ?? element.props?.children ?? [])
  }

  return ''
}

const drain = async (stream: AsyncIterable<unknown>) => {
  for await (const _ of stream) {
    // forwarded chunks are not under test
  }
}

test('reset formatter keeps exact dates and compact countdowns', async () => {
  const now = new Date(2026, 9, 6, 10, 0).getTime()
  expect(resetAt(new Date(2026, 9, 6, 12, 59).getTime(), now)).toBe('12:59')
  expect(resetAt(new Date(2026, 9, 9, 23, 10).getTime(), now)).toBe('Fri 9/10 23:10')
  expect(resetAt(new Date(2026, 9, 9, 23, 10).getTime(), now, true)).toBe('3d')
})

const QUOTA_CACHE = 'E:\\State\\pipeline\\logs\\quota\\last-good.json'

test('missing codeburn hides the Codex chip even with a saved quota', async ($, on) => {
  const w = world(on, { quotaMissing: true })
  w.write(QUOTA_CACHE, JSON.stringify({ fetchedAtUtc: at(0), quota: JSON.parse(codeburn(48)) }))
  await $.session.start(START)
  await w.clock.advance(4000)
  const ui = await $.ui.mount(BAND)
  expect(await ui.find({ key: 'codex-limits' })).toBeUndefined()
  expect(w.calls.some(call => call.argv.at(-1)?.includes('quota --format'))).toBe(false)
  expect(w.toasts.filter(text => text.includes('Codex'))).toEqual([])
})

for (const [label, env, root] of [
  ['explicit', { PIPELINE_HOME: 'E:\\State\\alternate\\\\' }, 'E:\\State\\alternate'],
  ['default', { PIPELINE_HOME: '' }, 'E:\\Users\\colleague\\.pipeline'],
  ['HOME fallback', { PIPELINE_HOME: undefined, USERPROFILE: '', HOME: 'E:\\Users\\fallback\\' }, 'E:\\Users\\fallback\\.pipeline'],
] as const) {
  test(`pipeline home resolves without a process: ${label}`, async ($, on) => {
    const w = world(on, { env })
    await $.session.start(START)
    expect(w.calls.filter(call => call.argv[0] === 'pwsh')).toEqual([])
    await w.clock.advance(4000)
    await $.command.run({ command: 'runs', args: '', origin: { kind: 'composer' }, presentation: { isFullscreen: false, columns: 120 } })
    expect(w.reads).toContain(`${root}\\config\\executors.json`)
    expect(w.read(`${root}\\logs\\quota\\last-good.json`)).toBeDefined()
  })
}

test('empty pipeline home skips all file access and preserves independent chips', async ($, on) => {
  const w = world(on, { env: { PIPELINE_HOME: '', USERPROFILE: undefined, HOME: '' } })
  await $.session.start(START)
  expect(w.calls.filter(call => call.argv[0] === 'pwsh')).toEqual([])
  await $.tool.call({ tool: 'PowerShell', command: LAUNCH })
  for (const command of ['runs', 'prs']) {
    await $.command.run({ command, args: '', origin: { kind: 'composer' }, presentation: { isFullscreen: false, columns: 120 } })
  }
  const cache = await $.command.run({ command: 'cache', args: '', origin: { kind: 'composer' }, presentation: { isFullscreen: false, columns: 120 } })
  expect(cache.text).toContain('Prompt cache:')
  await w.clock.advance(6000)
  const ui = await $.ui.mount(BAND)
  await ui.advance(1000)
  expect(await ui.find({ key: 'codex-limits' })).toBeDefined()
  expect(w.calls.some(call => call.argv.at(-1)?.includes('quota --format'))).toBe(true)
  expect(w.reads).toEqual([])
  expect(w.lists).toEqual([])
  expect(w.writes).toEqual([])
})

for (const launcher of [
  'E:\\Plugin Cache\\pipeline\\skills\\pipeline\\bin\\codex-run.ps1',
  'E:\\LocalPlugin\\skills\\pipeline\\bin\\claude-run.ps1',
  '/e/PluginCache/pipeline/skills/pipeline/bin/codex-run.ps1',
]) {
  test(`origin slug resolves the team alias from launcher ${launcher}`, async ($, on) => {
    const w = world(on, { commonDir: 'E:/Clones/DocsCheckout/.git', origin: 'git@github.com:example/DocsCheckout.git' })
    const config = launcher.replace(/^\/([a-z])\//i, (_, drive: string) => `${drive.toUpperCase()}:\\`).replace(/\//g, '\\').replace(/\\bin\\[^\\]+$/, '\\config\\executors.json')
    w.write(config, JSON.stringify({ executors: { "acme-docs": { github: 'example/DocsCheckout' } } }))
    w.write(ACCOUNTS_FILE, JSON.stringify({ executors: { "acme-docs": { commands: { fullGate: 'none' } } } }))
    w.write('E:\\Clones\\DocsCheckout\\.git', 'gitdir: fixture')
    await $.session.start(START)
    await $.tool.call({ tool: 'PowerShell', command: `pwsh -File "${launcher}" -Repo E:\\Clones\\DocsCheckout -Brief E:\\Briefs\\task.md -FullAccess -TimeoutMinutes 90` })
    const dir = `${RUNS}\\acme-docs\\2026-10-05-task`
    w.write(LOCK, owner(dir))
    w.write(`${dir}\\executor-prompt.md`, 'prompt', NOW + 1000)
    await w.clock.advance(6000)
    const ui = await $.ui.mount(BAND)
    expect(await ui.find({ key: `clock:${dir}` })).toBeDefined()
    expect(w.reads).toContain(config)
  })
}

test('run prediction selects the first free suffix beyond three and follows resume metadata', async ($, on) => {
  const w = world(on)
  const base = `${RUNS}\\app\\2026-10-05-task`
  for (const suffix of ['', '-2', '-3']) w.write(`${base}${suffix}\\report.md`, 'old', NOW - MINUTE)
  await $.session.start(START)
  await $.tool.call({ tool: 'PowerShell', command: 'pwsh -File codex-run.ps1 -Repo E:\\Clones\\App -Brief E:\\Briefs\\task.md -FullAccess -TimeoutMinutes 90' })
  w.write(`${base}-4\\meta.json`, JSON.stringify({ startedAt: at(0), model: 'gpt-6.2-sol' }))
  w.write(LOCK, owner(`${base}-4`))
  await w.clock.advance(6000)
  const ui = await $.ui.mount(BAND)
  expect(await ui.find({ key: `clock:${base}-4` })).toBeDefined()
  await $.tool.call({ tool: 'PowerShell', command: `pwsh -File claude-run.ps1 -Repo E:\\Clones\\Other -Brief ${base}-4\\brief.md -Resume session -FixLoop 2 -TimeoutMinutes 90` })
  w.write(`${base}-4-fix2\\executor-prompt.md`, 'prompt', w.clock.now())
  w.write(`${RUNS}\\.locks\\other.json`, owner(`${base}-4-fix2`))
  await w.clock.advance(6000)
  expect(await ui.find({ key: `clock:${base}-4-fix2` })).toBeDefined()
})

test('non-Git run prediction never invokes Git', async ($, on) => {
  const w = world(on)
  await $.session.start(START)
  await $.tool.call({ tool: 'PowerShell', command: 'pwsh -File codex-run.ps1 -Repo E:\\Clones\\Plain -Brief E:\\Briefs\\task.md -FullAccess -TimeoutMinutes 90' })
  expect(w.calls.filter(call => call.argv[0] === 'git')).toEqual([])
})

test('relative explicit run directory is resolved from the session working directory', async ($, on) => {
  const w = world(on, { cwd: 'E:\\Clones\\App' })
  await $.session.start(START)
  await $.tool.call({ tool: 'PowerShell', command: 'pwsh -File codex-run.ps1 -Repo E:\\Clones\\App -Brief brief.md -RunDir runs\\current -FullAccess -TimeoutMinutes 90' })
  const dir = 'E:\\Clones\\App\\runs\\current'
  w.write(LOCK, owner(dir))
  w.write(`${dir}\\executor-prompt.md`, 'prompt', NOW + 1000)
  await w.clock.advance(6000)
  const ui = await $.ui.mount(BAND)
  expect(await ui.find({ key: `clock:${dir}` })).toBeDefined()
})

test('failed run prediction does not prevent an otherwise allowed launch', async ($, on) => {
  const w = world(on, { pathFailure: true })
  await $.session.start(START)
  await $.tool.call({ tool: 'PowerShell', command: LAUNCH })
  expect(w.tools.length).toBe(1)
})

test('missing and malformed account maps never invent an account', async () => {
  for (const githubAccounts of [undefined, null, [], 'invalid', { '': 'user' }, { 'E:\\Projects': 42 }, {}]) {
    expect(accountsOf({ defaults: { githubAccounts } })).toEqual([])
  }
})

test('runner without a registry stays quiet and does not query runner APIs', async ($, on) => {
  const w = world(on)
  await $.session.start(START)
  const ui = await $.ui.mount(BAND)
  await ui.advance(1000)
  expect(await ui.find({ key: 'runner-lane' })).toBeUndefined()
  expect(w.calls.filter(call => call.argv[2]?.includes('/actions/'))).toEqual([])
})

test('runner without a root filter monitors all registered repos and uses current auth', async ($, on) => {
  const w = world(on, { runnerApi: path => runnerResponse(path, 'offline') })
  w.write(ACCOUNTS_FILE, JSON.stringify({ executors: { app: { repo: 'E:\\Clones\\App', github: 'org/App' } } }))
  await $.session.start(START)
  const ui = await $.ui.mount(BAND)
  await ui.advance(1000)
  expect(shown(await ui.find({ key: 'runner-lane' }))).toContain('App this-pc × offline')
  expect(w.calls.filter(call => call.argv[2]?.includes('/actions/')).every(call => call.env.GH_TOKEN === undefined)).toBe(true)
})
const PANE_RUNS = { plugin: 'cockpit', surface: 'terminal' as const, component: 'Pane' as const, requestId: 'runs', props: { title: 'Executors', isFocused: true, bodyColumns: 100 } as never }

for (const age of [0, 11 * MINUTE, undefined]) {
  test(`shared quota cache age ${age} is reused only when fresh`, async ($, on) => {
    const w = world(on)
    if (age !== undefined) w.write(QUOTA_CACHE, JSON.stringify({ fetchedAtUtc: at(-age), quota: JSON.parse(codeburn(48)) }))
    await $.session.start(START)
    const ui = await $.ui.mount(BAND)
    if (age === 0) expect(shown(await ui.find({ key: 'codex-limits' }))).toContain('48%')
    await w.clock.advance(4000)
    expect(w.calls.filter(call => call.argv.at(-1)?.includes('quota --format')).length).toBe(age === 0 ? 0 : 1)
    const saved = JSON.parse(w.read(QUOTA_CACHE) ?? '')
    expect(saved.quota.providers[0].windows[0].usedPct).toBe(age === 0 ? 48 : 25)
    expect(saved.fetchedAtUtc).toBe(age === 0 ? at(0) : at(3000))
  })
}

for (const width of [160, 90]) {
  test(`limits lane at ${width} columns shows used shares and resets without hover`, async ($, on) => {
    const w = world(on)
    w.write(QUOTA_CACHE, JSON.stringify({ fetchedAtUtc: at(0), quota: JSON.parse(codeburn(48)) }))
    await $.session.start(START)
    await $.session.measure({ context: { window: 1_000_000 }, changed: ['rateLimits'], rateLimits: [
      { kind: 'five_hour', percentUsed: 12, resetsAt: at(179 * MINUTE) },
      { kind: 'seven_day', percentUsed: 63, resetsAt: at(76 * 60 * MINUTE) },
      { kind: 'seven_day_opus', percentUsed: 69, resetsAt: at(76 * 60 * MINUTE) },
    ] })
    const ui = await $.ui.mount({ ...BAND, props: { ...BAND.props as object, bodyColumns: width } as never })
    const claude = shown(await ui.find({ key: 'claude-limits' }))
    const codex = shown(await ui.find({ key: 'codex-limits' }))
    expect(claude).toContain('◇ Claude  5h ')
    expect(claude).toContain('12% reset 2h59m')
    if (width >= 100) {
      expect(claude).toContain(`7d ▰▰▰▱▱ 63% reset ${clockAt(NOW + 76 * 60 * MINUTE, NOW)}`)
      expect(codex).toContain('◆ Codex  7d ')
      expect(codex).toContain('48%')
      expect(codex).toContain(`reset ${clockAt(NOW + 50 * 60 * MINUTE, NOW)}`)
    } else {
      expect(claude).not.toContain('7d')
      expect(codex).toBe('')
    }
    expect(claude).not.toContain('opus')
    expect(elements(await ui.drawn()).filter(node => node.props.hover !== undefined)).toEqual([])
    expect(await ui.find({ key: 'resets' })).toBeUndefined()
    expect(await ui.find({ key: 'codex' })).toBeUndefined()
  })
}

test('failed Codex refresh preserves the reading age and shows it inline and dim', async ($, on) => {
  const w = world(on, { quotaFailure: true })
  w.write(QUOTA_CACHE, JSON.stringify({ fetchedAtUtc: at(0), quota: JSON.parse(codeburn(48)) }))
  await $.session.start(START)
  await w.clock.advance(21 * MINUTE)
  const ui = await $.ui.mount(BAND)
  expect(shown(await ui.find({ key: 'codex-limits' }))).toContain(' · read 21m ago')
  expect((await ui.find({ type: 'Text', text: /^ · read 21m ago$/ }))?.props.dimColor).toBe(true)
  expect(shown(await ui.find({ key: 'codex-limits' }))).not.toContain(' ?')
})

for (const pipe of ['tail -20', 'head -10', 'Select-Object -Last 20']) {
  test(`guard denies a launch piped to ${pipe}`, async ($, on) => {
    const w = world(on)
    await $.session.start(START)
    const result = denial(await $.tool.call({ tool: 'Bash', command: `${LAUNCH} 2>&1 | ${pipe}` }))
    expect(result).toContain('exit code')
    expect(result).toContain('$?')
    expect(w.tools.length).toBe(0)
  })
}

test('guard denies more than 115 minutes and allows redirect then tail', async ($, on) => {
  const w = world(on)
  await $.session.start(START)
  expect(denial(await $.tool.call({ tool: 'Bash', command: launch(RUN, ' -FullAccess -TimeoutMinutes 116') }))).toContain('Split the task')
  await $.tool.call({ tool: 'Bash', command: `${LAUNCH} > run.log 2>&1; echo $?; tail -20 run.log` })
  expect(w.tools.length).toBe(1)
})

const CODEX_RUN = 'pwsh -NoProfile -File E:\\State\\pipeline\\bin\\codex-run.ps1 -Repo E:\\Projects\\Example\\Acme-Api'
const CLAUDE_RUN = "& 'E:\\State\\pipeline\\bin\\claude-run.ps1' -Repo E:\\Projects\\Example\\Acme-Api"

for (const [name, command] of [
  ['Brief', `RD='${RUN}'\n${CODEX_RUN} -Brief "$RD\\brief.md" -FullAccess -TimeoutMinutes 90`],
  ['Brief', `${CLAUDE_RUN} -Brief "$(Join-Path $R brief.md)" -TimeoutMinutes 90`],
  ['RunDir', `${CODEX_RUN} -Brief ${RUN}\\fix-1.md -RunDir $RD -Resume abc -FixLoop 1 -FullAccess -TimeoutMinutes 90`],
  ['Repo', `pwsh -File codex-run.ps1 -Repo "\${WT}" -Brief ${RUN}\\brief.md -FullAccess -TimeoutMinutes 90`],
  ['Repo', `& claude-run.ps1 -Repo $env:WT -Brief ${RUN}\\brief.md -TimeoutMinutes 90`],
] as [string, string][]) {
  test(`the guard refuses a shell variable in -${name}: ${command.split('\n').at(-1)?.slice(0, 60)}`, async ($, on) => {
    const w = world(on)
    await $.session.start(START)
    expect(denial(await $.tool.call({ tool: 'Bash', command }))).toContain(`-${name} uses a shell variable`)
    expect(w.tools.length).toBe(0)
  })
}

for (const command of [
  `${CODEX_RUN} -Brief ${RUN}\\fix-1.md -Resume abc -FullAccess -TimeoutMinutes 90`,
  `${CODEX_RUN} -Brief ${RUN}\\fix-1.md -RunDir ${RUN} -Resume abc -FullAccess -TimeoutMinutes 90`,
  `${CLAUDE_RUN} -Brief ${RUN}\\fix-1.md -Resume abc -TimeoutMinutes 90`,
]) {
  test(`the guard refuses -Resume without -FixLoop: ${command.slice(-70)}`, async ($, on) => {
    const w = world(on)
    await $.session.start(START)
    expect(denial(await $.tool.call({ tool: 'PowerShell', command }))).toContain('-Resume without -FixLoop')
    expect(w.tools.length).toBe(0)
  })
}

for (const command of [
  `${CODEX_RUN} -Brief ${RUN}\\fix-1.md -RunDir ${RUN} -Resume abc -FixLoop 1 -FullAccess -TimeoutMinutes 90`,
  `${CLAUDE_RUN} -Brief ${RUN}\\fix-1.md -Resume abc -FixLoop:2 -TimeoutMinutes 90`,
  `LOG=run.log\n${LAUNCH} > "$LOG" 2>&1; echo exit=$?; tail -20 "$LOG"`,
]) {
  test(`the guard lets through literal paths and a resume with -FixLoop: ${command.split('\n').at(-1)?.slice(-60)}`, async ($, on) => {
    const w = world(on)
    await $.session.start(START)
    await $.tool.call({ tool: 'Bash', command })
    expect(w.tools.length).toBe(1)
  })
}

for (const alias of ['registered', 'mainrepo']) {
  test(`run tracking resolves worktree alias ${alias}`, async ($, on) => {
    const w = world(on, { commonDir: 'E:/Projects/Sandbox/MainRepo/.git' })
    if (alias === 'registered') w.write('E:\\State\\pipeline\\config\\executors.json', JSON.stringify({ executors: { registered: { repo: 'E:\\Projects\\Sandbox\\MainRepo' } } }))
    await $.session.start(START)
    await $.tool.call({ tool: 'PowerShell', command: 'pwsh -File codex-run.ps1 -Repo D:\\worktrees\\feature -Brief D:\\briefs\\task.md -FullAccess -TimeoutMinutes 90' })
    const dir = `${RUNS}\\${alias}\\2026-10-05-task`
    w.write(LOCK, owner(dir))
    w.write(`${dir}\\executor-prompt.md`, 'prompt', NOW + 1000)
    await w.clock.advance(6000)
    const ui = await $.ui.mount(BAND)
    expect(await ui.find({ key: `clock:${dir}` })).toBeDefined()
  })
}

test('runs expose gate attempts, flaky failures, fix loops and API cost totals', async ($, on) => {
  const w = world(on)
  w.write(LOCK, owner())
  await $.session.start(START)
  await $.tool.call({ tool: 'PowerShell', command: LAUNCH })
  w.write(`${RUN}\\executor-prompt.md`, 'prompt', NOW + 1000)
  w.write(`${RUN}\\gate.attempt2.log`, 'running', NOW + 2000)
  await w.clock.advance(6000)
  const ui = await $.ui.mount(BAND)
  expect(shown(await ui.find({ type: 'Text', text: /gate · attempt 2/ }))).toContain('gate · attempt 2')
  w.write(`${RUN}\\meta.json`, JSON.stringify({ model: 'gpt-6.2-sol', startedAt: at(1000), endedAt: at(6000), wrapperExitCode: 0, fixLoop: 2, reportPresent: true }))
  w.write(`${RUN}\\gate.json`, JSON.stringify({ exitCode: 0, flaky: true, attempts: [{ failures: ['one', 'two'] }, { failures: [] }], tail: '4 passed' }))
  w.write(`${RUN}\\task-usage.json`, JSON.stringify({ sessions: [{ delta: { cost: 0.5 } }, { delta: { cost: 0.38 } }] }))
  await w.clock.advance(5000)
  expect(shown(await ui.find({ key: RUN }))).toContain('fix 2')
  expect(shown(await ui.find({ key: RUN }))).toContain('≈$0.88')
  const verdict = await ui.find({ type: 'Text', text: /gate passed on second attempt/ })
  expect(shown(verdict)).toContain('gate passed on second attempt')
  expect(verdict?.props.dimColor).toBe(true)
  expect(shown(await ui.find({ key: RUN }))).toContain('2 errors on first attempt')
  checkDrawing(await ui.drawn(), w.toasts)
  expect(w.notifications().at(-1)?.CC_NOTIFY_KIND).toBe('done')
  w.write(`${OTHER}\\meta.json`, JSON.stringify({ model: 'claude-opus-5-5', startedAt: at(0), endedAt: at(6000), wrapperExitCode: 5, totalCostUsd: 1.2, fixLoop: 1, gate: { exitCode: 1 } }))
  w.write(`${OTHER}\\task-usage.json`, JSON.stringify({ sessions: [{ delta: { cost: 9 } }] }))
  await $.command.run({ command: 'runs', args: '', origin: { kind: 'composer' }, presentation: { isFullscreen: false, columns: 100 } })
  const pane = await $.ui.mount(PANE_RUNS)
  const totals = shown(await pane.find({ key: 'run-totals' }))
  expect(totals).toContain('2 run · 3 fix · 1 failed gates · 1 flaky')
  expect(totals).toContain('Codex ≈$0.88')
  expect(totals).toContain('Claude ≈$1.20')
  expect(shown(await pane.find({ key: `row:${RUN}` }))).toContain('≈$0.88')
})

const turn = (durationMs: number, extra: Record<string, unknown> = {}) => ({
  answer: 'Done: PR #12 opened.\nDetails below.',
  durationMs,
  isAborted: false,
  turnId: 't1',
  reason: 'answer' as const,
  ...extra,
})

// ─── notifications ───────────────────────────────────────────────────────────

test('a long turn ends with a toast, a Windows notification and a green tab', async ($, on) => {
  const w = world(on)

  await $.session.start(START)
  await $.turn.complete(turn(7 * MINUTE + 12_000))
  await w.clock.advance(2000)
  expect(w.toasts).toEqual(['✓ Completed in 7m12s'])
  expect(w.notifications().length).toBe(1)
  expect(w.notifications()[0]).toMatchObject({
    CC_NOTIFY_RING: '1;100',
    CC_NOTIFY_TOAST: 'show',
    CC_NOTIFY_KIND: 'done',
    CC_NOTIFY_TEXT: 'Done: PR #12 opened.',
    CC_NOTIFY_FOLDER: 'Acme-Api',
    CC_NOTIFY_TAG: 'tab-1',
  })
})

test('a short turn only marks the tab, and the next prompt clears it', async ($, on) => {
  const w = world(on)

  await $.session.start(START)
  await $.turn.complete(turn(20_000))
  await w.clock.advance(2000)
  await $.prompt.submit({ text: 'okay, continue', wait: false, origin: { kind: 'composer' } })
  await w.clock.settle()
  expect(w.toasts.length).toBe(0)
  expect(w.notifications().map(env => [env.CC_NOTIFY_RING, env.CC_NOTIFY_TOAST])).toEqual([
    ['1;100', undefined],
    ['0;0', undefined],
  ])
})

test('a permission dialog turns the tab yellow until it is answered', async ($, on) => {
  const w = world(on)

  await $.session.start(START)
  w.whileAsking(() => $.classic.PermissionRequest({ tool_name: 'Bash', tool_input: { command: 'git push origin main\necho done' } }))
  await $.tool.call({ tool: 'Bash', command: 'git push origin main' })
  await w.clock.settle()
  expect(w.notifications()[0]).toMatchObject({
    CC_NOTIFY_RING: '4;100',
    CC_NOTIFY_TOAST: 'show',
    CC_NOTIFY_KIND: 'permission',
    CC_NOTIFY_TITLE: 'Your decision is needed',
    CC_NOTIFY_TEXT: 'Bash: git push origin main',
  })
  expect(w.notifications()[1]).toMatchObject({ CC_NOTIFY_RING: '0;0', CC_NOTIFY_TOAST: 'remove' })
})

test('a question notifies once, though its dialog raises a permission request too', async ($, on) => {
  const w = world(on)

  await $.session.start(START)
  w.whileAsking(() => $.classic.PermissionRequest({ tool_name: 'AskUserQuestion', tool_input: {} }))
  await $.tool.call({
    tool: 'AskUserQuestion',
    questions: [{ question: 'Quale libreria usiamo?', header: 'Libreria', options: [], multiSelect: false }],
  })
  await w.clock.settle()
  expect(w.notifications().filter(env => env.CC_NOTIFY_TOAST === 'show').length).toBe(1)
  expect(w.notifications()[0]).toMatchObject({ CC_NOTIFY_KIND: 'question', CC_NOTIFY_TEXT: 'Quale libreria usiamo?' })
})

test('a headless run draws and notifies nothing', async ($, on) => {
  const w = world(on)

  await $.session.start({ ...START, surface: null, isInteractive: false })
  await $.turn.complete(turn(10 * MINUTE))
  await w.clock.advance(20 * MINUTE)
  expect(w.calls.length).toBe(0)
  expect(w.toasts.length).toBe(0)
})

// ─── the meter lane ──────────────────────────────────────────────────────────

test('the cache chip gets the main thread request, and warns once before expiry', { timeoutMs: 60_000 }, async ($, on) => {
  const w = world(on, { quota: 25 })

  await $.session.start(START)
  await drain($.turn.step(STEP))
  await drain($.turn.step({ ...STEP, agentId: 'a1' }))
  await w.clock.settle()

  const ui = await $.ui.mount(BAND)
  const chip = await ui.find({ type: 'Client', key: 'cache' })

  expect(chip?.props.props).toMatchObject({
    view: { sentAt: NOW, ttlMs: 60 * MINUTE, hitPercent: 99, contextTokens: 302_000, isBig: true },
  })
  expect(shown(await ui.drawn({ in: 'cache' }))).toContain(' cache ')

  await w.clock.advance(56 * MINUTE)
  expect(w.toasts.filter(text => text.startsWith('◐ Cache · expiring in 5m')).length).toBe(1)
  await w.clock.advance(5 * MINUTE)
  expect(w.toasts.filter(text => text.startsWith('◐ Cache · expiring')).length).toBe(1)

  const report = await $.command.run({
    command: 'cache',
    args: '',
    origin: { kind: 'composer' },
    presentation: { isFullscreen: false, columns: 120 },
  })

  expect(report.text).toContain('expired 1:00 ago')
  expect(report.text).toContain('302k')
})

test('the resets chip shows the time left, and each step warns once', async ($, on) => {
  const w = world(on)
  const measure = (rateLimits: SessionRateLimit[]) => ({ context: { window: 1_000_000 }, rateLimits, changed: ['rateLimits' as const] })
  const fiveHour = (percentUsed: number) => ({ kind: 'five_hour', percentUsed, resetsAt: at(2 * 60 * MINUTE + 13 * MINUTE) })

  await $.session.start(START)
  await $.session.measure(measure([fiveHour(42), { kind: 'seven_day', percentUsed: 63, resetsAt: at(76 * 60 * MINUTE) }]))

  const ui = await $.ui.mount(BAND)

  expect(shown(await ui.find({ key: 'claude-limits' }))).toContain('42% reset ')

  for (const percent of [79, 81, 85, 93, 100]) {
    await $.session.measure(measure([fiveHour(percent)]))
  }

  await w.clock.settle()
  expect(w.toasts.filter(text => text.includes('Quota 5h'))).toEqual([
    '● Quota 5h · 81% · resets in 2h13m',
    '● Quota 5h · 93% · resets in 2h13m',
    '× Quota 5h · exhausted · resets in 2h13m · 5m cache with extra usage',
  ])
})

test('the Codex chip reads the plan with codeburn and warns past the launcher cap', async ($, on) => {
  const w = world(on, { quota: 87 })

  await $.session.start(START)
  await w.clock.advance(4000)

  const ui = await $.ui.mount(BAND)

  expect(shown(await ui.find({ key: 'codex-limits' }))).toContain('7d ▰▰▰▰▱ 87%')
  expect(w.toasts.filter(text => text.startsWith('× Quota Codex 7d · 87%')).length).toBe(1)
  await w.clock.advance(10 * MINUTE)
  expect(w.toasts.filter(text => text.startsWith('× Quota Codex')).length).toBe(1)
})

// ─── the PR lane ─────────────────────────────────────────────────────────────

const PRS = {
  command: 'prs',
  args: '',
  origin: { kind: 'composer' as const },
  presentation: { isFullscreen: false, columns: 120 },
}

test('lists the open pull requests with where each stands, as the folder account', async ($, on) => {
  const w = world(on)
  w.write(ACCOUNTS_FILE, JSON.stringify({ defaults: { githubAccounts: { 'E:\\Projects\\Example': 'team-user' } } }))

  await $.session.start(START)

  const result = await $.command.run(PRS)

  expect(w.calls.filter(call => call.argv[1] === 'api').map(call => call.env.GH_TOKEN)).toEqual(['token-of-work', 'token-of-work'])
  expect(result.text).toContain('PRs for team-user: 4 open')
  expect(result.text).toContain('Example-Tools#1 conflicts')
  expect(result.text).toContain('log-analysis#4 Codex comments')
  expect(result.text).toContain('Acme-Web#5 Codex review stale')
  expect(result.text).toContain('Acme-Worker#7 ready')
})

test('Codex reactions only mark the current head ready and stale reactions offer another review', async ($, on) => {
  const pulls = [
    node(11, 'old-review', { reviews: { nodes: [{ author: CODEX, submittedAt: at(-2 * MINUTE) }] }, reactions: { nodes: [{ user: CODEX, createdAt: at(-MINUTE) }] } }),
    node(12, 'old-no-review', { reactions: { nodes: [{ user: CODEX, createdAt: at(-MINUTE) }] } }),
    node(13, 'current', { reactions: { nodes: [{ user: CODEX, createdAt: at(MINUTE) }] } }),
  ].map(pr => ({ ...pr, commits: { nodes: [{ commit: { committedDate: at(0), statusCheckRollup: { state: 'SUCCESS' } } }] } }))
  const w = world(on, { graphql: ran(0, JSON.stringify({ data: { viewer: { login: 'team-user', pullRequests: { totalCount: pulls.length, nodes: pulls } } } })) })

  await $.session.start(START)
  const result = await $.command.run(PRS)
  const ui = await $.ui.mount(BAND)

  expect(result.text).toContain('old-review#11 Codex review stale')
  expect(result.text).toContain('old-no-review#12 awaiting Codex')
  expect(result.text).toContain('current#13 ready')
  for (const pr of pulls.slice(0, 2)) expect((await ui.find({ key: `codex:${pr.url}` }))?.props.label).toBe('@codex review')
  expect(await ui.find({ key: `codex:${pulls[2].url}` })).toBeUndefined()
  expect(w.calls.find(call => call.argv[1] === 'api')?.argv.join(' ')).toContain('createdAt')
})

for (const [name, activity, forcePush, reaction, ready] of [
  ['late push of a pre-existing commit', ran(0, JSON.stringify([{ after: 'head-sha', timestamp: at(3 * MINUTE) }])), undefined, at(2 * MINUTE), false],
  ['late push without CI', ran(0, JSON.stringify([{ after: 'head-sha', timestamp: at(3 * MINUTE) }])), undefined, at(2 * MINUTE), false],
  ['reaction after the push', ran(0, JSON.stringify([{ after: 'head-sha', timestamp: at(3 * MINUTE) }])), undefined, '2026-10-05T06:04:00-04:00', true],
  ['reaction at the push time', ran(0, JSON.stringify([{ after: 'head-sha', timestamp: at(3 * MINUTE) }])), undefined, at(3 * MINUTE), true],
  ['failed activity with stale reaction', ran(1, '', 'access denied'), at(3 * MINUTE), at(2 * MINUTE), false],
  ['failed activity with fresh reaction', ran(1, '', 'access denied'), at(3 * MINUTE), at(4 * MINUTE), true],
  ['racing push with stale reaction', ran(0, JSON.stringify([{ after: 'newer-sha', timestamp: at(5 * MINUTE) }])), at(3 * MINUTE), at(2 * MINUTE), false],
  ['racing push with fresh reaction', ran(0, JSON.stringify([{ after: 'newer-sha', timestamp: at(5 * MINUTE) }])), at(3 * MINUTE), at(4 * MINUTE), true],
  ['empty activity', ran(0, '[]'), at(3 * MINUTE), at(2 * MINUTE), false],
  ['commit newer than force push', ran(0, '[]'), at(-MINUTE), at(-MINUTE / 2), false],
] as const) {
  test(`Codex readiness follows ${name}`, async ($, on) => {
    const pr = node(14, 'head-update', {
      commits: { nodes: [{ commit: { committedDate: at(0), statusCheckRollup: name.endsWith('without CI') ? null : { state: 'SUCCESS' } } }] },
      timelineItems: { nodes: forcePush === undefined ? [] : [{ createdAt: forcePush }] },
      reactions: { nodes: [{ user: CODEX, createdAt: reaction }] },
    })
    const w = world(on, {
      graphql: ran(0, JSON.stringify({ data: { viewer: { login: 'team-user', pullRequests: { totalCount: 1, nodes: [pr] } } } })),
      runnerApi: () => activity,
    })
    w.write(ACCOUNTS_FILE, JSON.stringify({ defaults: { githubAccounts: { 'E:\\Projects\\Example': 'team-user' } } }))

    await $.session.start(START)
    const result = await $.command.run(PRS)
    const ui = await $.ui.mount(BAND)

    expect(result.text).toContain(`head-update#14 ${ready ? 'ready' : 'awaiting Codex'}`)
    expect((await ui.find({ key: `codex:${pr.url}` }))?.props.label).toBe(ready ? undefined : '@codex review')
    const query = w.calls.find(call => call.argv[1] === 'api')?.argv.join(' ')
    expect(query?.includes('checkSuites')).toBe(false)
    expect(query).toContain('headRefName headRefOid')
    expect(query).toContain('headRepository { nameWithOwner }')
    expect(query).toContain('timelineItems(last: 1, itemTypes: [HEAD_REF_FORCE_PUSHED_EVENT])')
    const activityCalls = w.calls.filter(call => call.argv[2]?.includes('/activity?'))
    expect(activityCalls.length).toBe(1)
    expect(activityCalls[0]?.argv).toEqual(['gh', 'api', 'repos/fork/head-update/activity?ref=refs%2Fheads%2Ffeature%2Freview&per_page=1'])
    expect(activityCalls[0]?.env.GH_TOKEN).toBe('token-of-work')
  })
}

test('PR activity encodes branch names with URL metacharacters', async ($, on) => {
  const pr = node(14, 'odd-branch', { headRefName: 'fix/a&b#c', reactions: { nodes: [{ user: CODEX, createdAt: at(MINUTE) }] } })
  const w = world(on, { graphql: ran(0, JSON.stringify({ data: { viewer: { login: 'team-user', pullRequests: { totalCount: 1, nodes: [pr] } } } })) })
  await $.session.start(START)
  await $.command.run(PRS)
  expect(w.calls.find(call => call.argv[2]?.includes('/activity?'))?.argv[2]).toBe('repos/fork/odd-branch/activity?ref=refs%2Fheads%2Ffix%2Fa%26b%23c&per_page=1')
})

for (const [name, user, state] of [
  ['no reaction', undefined, 'SUCCESS'],
  ['human reaction', { login: 'human' }, 'SUCCESS'],
  ['red CI', CODEX, 'FAILURE'],
  ['pending CI', CODEX, 'PENDING'],
] as const) {
  test(`PR activity is skipped with ${name}`, async ($, on) => {
    const pr = node(14, 'skip-activity', {
      commits: { nodes: [{ commit: { committedDate: at(0), statusCheckRollup: { state } } }] },
      reactions: { nodes: user === undefined ? [] : [{ user, createdAt: at(MINUTE) }] },
    })
    const w = world(on, { graphql: ran(0, JSON.stringify({ data: { viewer: { login: 'team-user', pullRequests: { totalCount: 1, nodes: [pr] } } } })) })
    await $.session.start(START)
    await $.command.run(PRS)
    expect(w.calls.filter(call => call.argv[2]?.includes('/activity?')).length).toBe(0)
  })
}

test('@codex review asks for a confirmation, then comments as the folder account', async ($, on) => {
  const w = world(on)
  w.write(ACCOUNTS_FILE, JSON.stringify({ defaults: { githubAccounts: { 'E:\\Projects\\Example': 'team-user' } } }))
  const url = 'https://github.com/org/Acme-Web/pull/5'

  await $.session.start(START)
  await $.command.run(PRS)

  const ui = await $.ui.mount(BAND)

  expect(shown(await ui.find({ type: 'Text', text: /open/ }))).toContain('4 open')
  expect(await ui.find({ key: `codex:https://github.com/org/Example-Tools/pull/1` })).toBeUndefined()

  await ui.press({ key: `codex:${url}` })
  expect(w.calls.some(call => call.argv[1] === 'pr')).toBe(false)
  expect((await ui.find({ key: `codex:${url}` }))?.props.label).toBe('confirm @codex review')

  await ui.press({ key: `codex:${url}` })

  const comment = w.calls.find(call => call.argv[1] === 'pr')

  expect(comment?.argv).toEqual(['gh', 'pr', 'comment', url, '--body', '@codex review'])
  expect(comment?.env.GH_TOKEN).toBe('token-of-work')
  expect(w.toasts).toContain('● Codex · Acme-Web#5 · review requested')
  expect(await ui.find({ key: `codex:${url}` })).toBeUndefined()
  expect(await ui.find({ type: 'Text', text: /review requested/ })).toBeDefined()
})

test('an unconfirmed @codex review disarms by itself', async ($, on) => {
  const w = world(on)
  const url = 'https://github.com/org/Acme-Web/pull/5'

  await $.session.start(START)
  await $.command.run(PRS)

  const ui = await $.ui.mount(BAND)

  await ui.press({ key: `codex:${url}` })
  await w.clock.advance(7000)
  expect((await ui.find({ key: `codex:${url}` }))?.props.label).toBe('@codex review')
  await ui.press({ key: `codex:${url}` })
  expect(w.calls.some(call => call.argv[1] === 'pr')).toBe(false)
})

// ─── the executors ───────────────────────────────────────────────────────────

const denial = (result: unknown) => JSON.stringify(result)

for (const tool of ['PowerShell', 'Bash']) {
  for (const extra of [' -ReadOnly -TimeoutMinutes 30', ' -Resume abc -ReadOnly -TimeoutMinutes 30', ' -readonly -TimeoutMinutes 115']) {
    test(`read-only guard allows ${extra} through ${tool}`, async ($, on) => {
      const w = world(on)
      await $.session.start(START)
      expect(denial(await $.tool.call({ tool, command: launch(RUN, extra) }))).not.toContain('cockpit:')
      expect(w.tools.length).toBe(1)
    })
  }

  test(`read-only guard allows review in a busy worktree through ${tool}`, async ($, on) => {
    const w = world(on)
    await $.session.start(START)
    await $.tool.call({ tool, command: LAUNCH })
    expect(denial(await $.tool.call({ tool, command: launch(OTHER, ' -ReadOnly -TimeoutMinutes 30') }))).not.toContain('cockpit:')
    expect(w.tools.length).toBe(2)
  })

  test(`read-only guard leaves the worktree available to an executor through ${tool}`, async ($, on) => {
    const w = world(on)
    await $.session.start(START)
    await $.tool.call({ tool, command: launch(RUN, ' -ReadOnly -TimeoutMinutes 30') })
    const ui = await $.ui.mount(BAND)
    expect(await ui.find({ type: 'Client', key: `clock:${RUN}` })).toBeDefined()
    expect(denial(await $.tool.call({ tool, command: launch(OTHER, ' -FullAccess -TimeoutMinutes 30') }))).not.toContain('cockpit:')
    expect(w.tools.length).toBe(2)
  })
}

for (const [command, reason] of [
  [launch(RUN, ' -ReadOnly'), 'missing -TimeoutMinutes'],
  [launch(RUN, ' -ReadOnly -TimeoutMinutes 116'), 'Split the task'],
  ...['tail -20', 'head -10', 'Select-Object -Last 20'].map(pipe => [launch(RUN, ` -ReadOnly -TimeoutMinutes 30 | ${pipe}`), 'exit code']),
  [launch(RUN, ' -ReadOnly -TimeoutMinutes 30', '$WT'), '-Repo uses a shell variable'],
  [`${CODEX_RUN} -Brief $RD -ReadOnly -TimeoutMinutes 30`, '-Brief uses a shell variable'],
  [launch(RUN, ' -RunDir $RD -ReadOnly -TimeoutMinutes 30'), '-RunDir uses a shell variable'],
]) {
  test(`read-only guard preserves refusal: ${command}`, async ($, on) => {
    const w = world(on)
    await $.session.start(START)
    expect(denial(await $.tool.call({ tool: 'PowerShell', command }))).toContain(reason)
    expect(w.tools.length).toBe(0)
  })
}

for (const tool of ['Bash', 'PowerShell'] as const) {
  for (const timeout of [undefined, 600000, 8000000]) {
    test(`${tool} gives a launcher a sufficient tool timeout: ${timeout}`, async ($, on) => {
      const w = world(on)
      await $.session.start(START)
      await $.tool.call({ tool, command: LAUNCH, timeout, run_in_background: true })
      expect(w.tools[0]?.timeout).toBe(timeout === 8000000 ? timeout : 7200000)
      expect(w.tools[0]?.run_in_background).toBe(true)
    })
  }
  test(`${tool} preserves a non-launcher tool timeout`, async ($, on) => {
    const w = world(on)
    await $.session.start(START)
    await $.tool.call({ tool, command: 'Write-Output fixture', timeout: 600000 })
    expect(w.tools[0]?.timeout).toBe(600000)
    expect(w.tools[0]?.run_in_background).toBeUndefined()
  })
}

test('the launch guard refuses a Codex run without -FullAccess or a timeout, and a second one in a busy worktree', async ($, on) => {
  const w = world(on)

  await $.session.start(START)
  expect(denial(await $.tool.call({ tool: 'PowerShell', command: launch(RUN, ' -TimeoutMinutes 90') }))).toContain('-FullAccess')
  expect(denial(await $.tool.call({ tool: 'PowerShell', command: launch(RUN, ' -FullAccess') }))).toContain('missing -TimeoutMinutes')
  expect(w.tools.length).toBe(0)

  await $.tool.call({ tool: 'PowerShell', command: launch(RUN, ' -DryRun') })
  expect(w.tools.length).toBe(1)

  await $.tool.call({ tool: 'PowerShell', command: LAUNCH })
  await $.tool.call({ tool: 'Bash', command: launch(OTHER, ' -FullAccess -TimeoutMinutes 60', '/c/Example/Checkouts/Acme-Web') })
  await $.tool.call({
    tool: 'PowerShell',
    command: launch(`${RUNS}\\Acme-Worker\\2026-10-05-third`, ' -FullAccess -TimeoutMinutes 30', 'E:\\Projects\\Example\\Acme-Worker'),
  })
  expect(w.tools.length).toBe(4)
  expect(w.tools[1]?.run_in_background).toBe(true)

  const busy = await $.tool.call({
    tool: 'PowerShell',
    command: launch(`${RUNS}\\Acme-Api\\2026-10-05-second`, ' -FullAccess -TimeoutMinutes 30', 'e:\\projects\\example\\Acme-Api'),
  })

  expect(denial(busy)).toContain('in the same worktree')
  expect(denial(busy)).toContain('outbox-batch')
  expect(w.tools.length).toBe(4)
})

for (const live of ['codex.stderr.log', 'gate.log']) {
  test(`a tracked run without metadata or a lock ends despite fresh ${live}`, async ($, on) => {
    const w = world(on)

    await $.session.start(START)
    await $.tool.call({ tool: 'PowerShell', command: LAUNCH })
    w.write(`${RUN}\\executor-prompt.md`, 'prompt')
    w.write(`${RUN}\\${live}`, 'live')
    await w.clock.advance(5000)

    const ui = await $.ui.mount(BAND)

    expect(await ui.find({ type: 'Client', key: `clock:${RUN}` })).toBeUndefined()
    expect(await ui.find({ type: 'Text', text: /no outcome/ })).toBeDefined()
    expect(w.toasts.filter(text => text.includes('no outcome')).length).toBe(1)
    expect(w.notifications().filter(env => env.CC_NOTIFY_TEXT?.includes('no outcome')).length).toBe(1)
    await w.clock.advance(5000)
    expect(w.toasts.filter(text => text.includes('no outcome')).length).toBe(1)
    expect(w.notifications().filter(env => env.CC_NOTIFY_TEXT?.includes('no outcome')).length).toBe(1)
    await $.tool.call({ tool: 'PowerShell', command: launch(OTHER, ' -FullAccess -TimeoutMinutes 90') })
    expect(w.tools.length).toBe(2)
  })
}

test('a launcher refusal ends the tracked run at once and frees its worktree', async ($, on) => {
  const output = 'C:\\Temp\\claude\\tasks\\b1.output'
  const w = world(on, { toolText: `Command running in background with ID: b1. Output is being written to: ${output}. You will be notified when it completes.` })

  await $.session.start(START)
  await $.tool.call({ tool: 'PowerShell', command: LAUNCH })
  w.write(output, 'codex-run: refused | quota gate: codex Weekly at 100% (cap 85%)\n\n[exited with code 4]\n')
  await w.clock.advance(5000)

  const ui = await $.ui.mount(BAND)

  expect(await ui.find({ type: 'Client', key: `clock:${RUN}` })).toBeUndefined()
  expect(await ui.find({ type: 'Text', text: /refused/ })).toBeDefined()
  await $.tool.call({ tool: 'PowerShell', command: launch(OTHER, ' -FullAccess -TimeoutMinutes 90') })
  expect(w.tools.length).toBe(2)
})

for (const redirect of ["*> 'C:\\Temp\\launch logs\\refused.out'", '> "C:\\Temp\\refused.out"', '2>&1 > C:\\Temp\\refused.out', '> C:\\Temp\\refused.out', '']) {
  test(`a redirected refusal frees the worktree immediately: ${redirect || 'launcher.out fallback'}`, async ($, on) => {
    const output = 'C:\\Temp\\claude\\tasks\\b1.output'
    const w = world(on, { toolText: `Output is being written to: ${output}.` })
    await $.session.start(START)
    await $.tool.call({ tool: 'PowerShell', command: `${LAUNCH} ${redirect}; echo "exit=$LASTEXITCODE"` })
    const target = redirect.includes('launch logs') ? 'C:\\Temp\\launch logs\\refused.out' : redirect ? 'C:\\Temp\\refused.out' : `${RUN}\\launcher.out`
    w.write(target, 'codex-run: refused | quota gate: codex Weekly at 100% (cap 85%)\n')
    w.write(output, 'exit=4\n')
    await $.tool.call({ tool: 'PowerShell', command: launch(OTHER, ' -FullAccess -TimeoutMinutes 90') })
    expect(w.tools.length).toBe(2)
    expect(w.toasts.some(text => text.includes('refused') && text.includes('quota gate:'))).toBe(true)
  })
}

for (const launcher of ['codex-run.ps1', 'claude-run.ps1']) {
  for (const [redirect, file] of [[`*> '${RUN}\\launcher.log'`, 'launcher.log'], ['', 'launcher.out']]) {
    for (const error of [
      'Cannot process command because of one or more missing mandatory parameters: Brief.',
      "A parameter cannot be found that matches parameter name 'X'.",
      "Cannot bind parameter 'X' because it is null.",
    ]) {
      for (const exit of ['exit=\n', 'exit \n']) {
        test(`PowerShell parameter binding refusal from ${launcher} frees its worktree (${file})`, async ($, on) => {
          const output = 'C:\\Temp\\claude\\tasks\\b1.output'
          const w = world(on, { toolText: `Command running in background with ID: b1. Output is being written to: ${output}.` })
          const command = `${LAUNCH.replace('codex-run.ps1', launcher)} ${redirect}`
          await $.session.start(START)
          await $.tool.call({ tool: 'PowerShell', command })
          w.write(`${RUN}\\${file}`, `${launcher}: ${error}\n`)
          w.write(output, exit)
          await $.tool.call({ tool: 'PowerShell', command: launch(OTHER, ' -FullAccess -TimeoutMinutes 90') })
          expect(w.tools.length).toBe(2)
          expect(w.toasts.some(text => text.includes('refused') && text.includes(error))).toBe(true)
        })
      }
    }
  }
}

for (const redirect of ['', "> 'C:\\Temp\\refused.out'"]) {
  test(`a prior attempt's refusal file cannot finish a new launch: ${redirect || 'launcher.out'}`, async ($, on) => {
    const w = world(on)
    w.write(LOCK, owner())
    w.write(redirect ? 'C:\\Temp\\refused.out' : `${RUN}\\launcher.out`, 'codex-run: refused | old quota refusal\n', NOW - MINUTE)
    await $.session.start(START)
    await $.tool.call({ tool: 'PowerShell', command: `${LAUNCH} ${redirect}` })
    await $.tool.call({ tool: 'PowerShell', command: launch(OTHER, ' -FullAccess -TimeoutMinutes 90') })
    expect(w.tools.length).toBe(1)
    expect(w.toasts.some(text => text.includes('refused'))).toBe(false)
  })
}

test('a refusal written before the background tool returns belongs to the current launch', async ($, on) => {
  const w = world(on)
  await $.session.start(START)
  w.whileAsking(async () => {
    w.write(`${RUN}\\launcher.out`, 'codex-run: refused | immediate quota refusal\n')
    await w.clock.advance(1000)
  })
  await $.tool.call({ tool: 'PowerShell', command: LAUNCH })
  w.whileAsking(async () => undefined)
  await $.tool.call({ tool: 'PowerShell', command: launch(OTHER, ' -FullAccess -TimeoutMinutes 90') })
  expect(w.tools.length).toBe(2)
  expect(w.toasts.some(text => text.includes('immediate quota refusal'))).toBe(true)
})

for (const exit of [4, 3, 0]) {
  for (const metadata of [false, true]) {
    test(`exit=${exit} without a refusal line settles only a failed launch without metadata: ${metadata}`, async ($, on) => {
      const output = 'C:\\Temp\\claude\\tasks\\b1.output'
      const w = world(on, { toolText: `Output is being written to: ${output}.` })
      w.write(LOCK, owner())
      await $.session.start(START)
      await $.tool.call({ tool: 'PowerShell', command: LAUNCH })
      if (metadata) w.write(`${RUN}\\meta.json`, JSON.stringify({ startedAt: at(0) }))
      w.write(output, `exit=${exit}\n`)
      await $.tool.call({ tool: 'PowerShell', command: launch(OTHER, ' -FullAccess -TimeoutMinutes 90') })
      expect(w.tools.length).toBe(exit !== 0 && !metadata ? 2 : 1)
      if (exit !== 0 && !metadata) expect(w.toasts.some(text => text.includes('refused'))).toBe(true)
    })
  }
}

for (const completed of ['metadata', 'silent log']) {
  test(`the launch guard re-probes a busy run with ${completed} before the next poll`, async ($, on) => {
    const w = world(on)

    await $.session.start(START)
    await $.tool.call({ tool: 'PowerShell', command: LAUNCH })
    w.write(`${RUN}\\executor-prompt.md`, 'prompt')
    w.write(`${RUN}\\codex.stderr.log`, 'live')
    await w.clock.advance(2000)
    if (completed === 'metadata') {
      w.write(`${RUN}\\meta.json`, JSON.stringify({ startedAt: at(0), endedAt: at(2000), exitCode: 0, wrapperExitCode: 0 }))
    } else {
      w.write(`${RUN}\\codex.stderr.log`, 'live', w.clock.now() - 10 * MINUTE)
    }

    await $.tool.call({ tool: 'PowerShell', command: launch(OTHER, ' -FullAccess -TimeoutMinutes 90') })
    expect(w.tools.length).toBe(2)
    await w.clock.advance(5000)
    expect(w.toasts.filter(text => text.includes('outbox-batch')).length).toBe(1)
  })
}

for (const live of ['codex.stderr.log', 'gate.log']) {
  test(`the launch guard still refuses a live launcher whose ${live} moved within ten minutes`, async ($, on) => {
    const w = world(on)
    w.write(LOCK, owner())

    await $.session.start(START)
    await $.tool.call({ tool: 'PowerShell', command: LAUNCH })
    w.write(`${RUN}\\executor-prompt.md`, 'prompt')
    w.write(`${RUN}\\${live}`, 'live')
    await w.clock.advance(9 * MINUTE)
    w.write(`${RUN}\\${live}`, 'still live')
    await w.clock.advance(MINUTE)

    expect(denial(await $.tool.call({ tool: 'PowerShell', command: launch(OTHER, ' -FullAccess -TimeoutMinutes 90') }))).toContain('in the same worktree')
    expect(w.tools.length).toBe(1)
  })
}

const LOCK = `${RUNS}\\.locks\\repo.json`
const owner = (runDir = RUN, processStartTime = at(-1000)) =>
  JSON.stringify({ pid: 1234, processStartTime, runDir, repoPath: 'E:\\Projects\\Example\\Acme-Api', startedAt: at(0) })

for (const live of ['claude metadata', 'codex.stderr.log', 'gate.log']) {
  test(`a silent run with a live launcher stays tracked: ${live}`, async ($, on) => {
    const w = world(on, { processStart: at(-1000) })
    const isClaude = live === 'claude metadata'
    const command = isClaude ? LAUNCH.replace('codex-run.ps1', 'claude-run.ps1') : LAUNCH

    await $.session.start(START)
    await $.tool.call({ tool: 'PowerShell', command })
    w.write(`${RUN}\\meta.json`, JSON.stringify({ model: isClaude ? 'claude-opus-5-5' : 'gpt-6.2-sol', startedAt: at(0) }))
    if (!isClaude) w.write(`${RUN}\\${live}`, 'working')
    w.write(LOCK, owner())
    await w.clock.advance(9 * MINUTE)
    expect(w.calls.filter(call => call.env.CC_RUN_PID !== undefined).length).toBeGreaterThan(0)
    expect(w.reads).toContain(LOCK)
    await w.clock.advance((isClaude ? 21 : 1) * MINUTE)

    const ui = await $.ui.mount(BAND)
    expect((await ui.find({ type: 'Client', key: `clock:${RUN}` }))?.props.props).toMatchObject({ phase: live === 'gate.log' ? 'gate' : 'running' })
    expect(w.toasts.filter(text => text.includes('outbox-batch')).length).toBe(0)
    expect(denial(await $.tool.call({ tool: 'PowerShell', command: launch(OTHER, ' -FullAccess -TimeoutMinutes 90') }))).toContain('in the same worktree')
    expect(w.tools.length).toBe(1)
    const checks = w.calls.filter(call => call.env.CC_RUN_PID !== undefined).length
    await $.command.run({ ...PRS, command: 'runs' })
    const pane = await $.ui.mount(PANE_RUNS)
    expect(await pane.find({ key: `open:${RUN}` })).toBeDefined()
    expect(await pane.find({ type: 'Text', text: /in progress/ })).toBeDefined()
    expect(await pane.find({ type: 'Text', text: /no outcome/ })).toBeUndefined()
    expect(w.calls.filter(call => call.env.CC_RUN_PID !== undefined).length).toBe(checks)

    w.remove(LOCK)
    w.write(`${RUN}\\meta.json`, JSON.stringify({ startedAt: at(0), endedAt: at(w.clock.now() - NOW), exitCode: 0, wrapperExitCode: 0 }))
    await w.clock.advance(5000)
    expect(w.toasts.filter(text => text.includes('outbox-batch')).length).toBe(1)
    expect(w.toasts.filter(text => text.includes('no outcome')).length).toBe(0)
  })
}

for (const state of ['dead pid', 'reused pid', 'other run', 'missing lock']) {
  test(`a fresh run ends once when its launcher lock has ${state}`, async ($, on) => {
    const w = world(on, { processStart: state === 'dead pid' ? 'missing' : at(-2000) })

    await $.session.start(START)
    await $.tool.call({ tool: 'PowerShell', command: LAUNCH })
    w.write(`${RUN}\\meta.json`, JSON.stringify({ model: 'gpt-6.2-sol', startedAt: at(0) }))
    w.write(`${RUN}\\codex.stderr.log`, 'just written')
    if (state !== 'missing lock') w.write(LOCK, owner(state === 'other run' ? OTHER : RUN))
    await w.clock.advance(5000)
    const ui = await $.ui.mount(BAND)
    expect(await ui.find({ type: 'Client', key: `clock:${RUN}` })).toBeUndefined()
    expect(w.toasts.filter(text => text.includes('no outcome')).length).toBe(1)
    expect(w.notifications().filter(env => env.CC_NOTIFY_TEXT?.includes('no outcome')).length).toBe(1)
    expect(w.calls.filter(call => call.env.CC_RUN_PID !== undefined).length).toBe(state === 'other run' || state === 'missing lock' ? 0 : 1)
    await $.command.run({ ...PRS, command: 'runs' })
    const pane = await $.ui.mount(PANE_RUNS)
    expect(await pane.find({ type: 'Text', text: /no outcome/ })).toBeDefined()
    expect(w.calls.filter(call => call.env.CC_RUN_PID !== undefined).length).toBe(state === 'other run' || state === 'missing lock' ? 0 : 2)
    await w.clock.advance(5000)
    expect(w.toasts.filter(text => text.includes('no outcome')).length).toBe(1)
    expect(w.notifications().filter(env => env.CC_NOTIFY_TEXT?.includes('no outcome')).length).toBe(1)
    await $.tool.call({ tool: 'PowerShell', command: launch(OTHER, ' -FullAccess -TimeoutMinutes 90') })
    expect(w.tools.length).toBe(2)
  })
}

for (const state of ['dead pid', 'removed lock']) {
  test(`a previously live launcher ends after ${state}, respecting the alive cache`, async ($, on) => {
    const setup = { processStart: at(-1000) }
    const w = world(on, setup)
    await $.session.start(START)
    await $.tool.call({ tool: 'PowerShell', command: LAUNCH })
    w.write(`${RUN}\\executor-prompt.md`, 'prompt')
    w.write(LOCK, owner())
    await w.clock.advance(5000)
    const ui = await $.ui.mount(BAND)
    expect(await ui.find({ key: `clock:${RUN}` })).toBeDefined()

    if (state === 'removed lock') w.remove(LOCK)
    else setup.processStart = 'missing'
    w.write(`${RUN}\\codex.stderr.log`, 'fresh output')
    if (state === 'dead pid') {
      await w.clock.advance(55_000)
      expect(await ui.find({ key: `clock:${RUN}` })).toBeDefined()
      expect(w.calls.filter(call => call.env.CC_RUN_PID !== undefined).length).toBe(1)
      expect(w.toasts.filter(text => text.includes('no outcome')).length).toBe(0)
    }
    await w.clock.advance(5000)
    expect(await ui.find({ key: `clock:${RUN}` })).toBeUndefined()
    expect(w.toasts.filter(text => text.includes('no outcome')).length).toBe(1)
    expect(w.calls.filter(call => call.env.CC_RUN_PID !== undefined).length).toBe(state === 'dead pid' ? 2 : 1)
  })
}

test('a launch tracked during an in-flight poll keeps its lane and completion', async ($, on) => {
  const w = world(on)
  w.write(LOCK, owner())
  w.write(`${RUNS}\\.locks\\other.json`, owner(OTHER))

  await $.session.start(START)
  await $.tool.call({ tool: 'PowerShell', command: LAUNCH })
  w.write(`${RUN}\\meta.json`, JSON.stringify({ startedAt: at(0) }))
  w.whileReading(`${RUN}\\meta.json`, async () => {
    await $.tool.call({ tool: 'PowerShell', command: launch(OTHER, ' -FullAccess -TimeoutMinutes 90', 'E:\\Projects\\Example\\Acme-Web') })
    w.write(`${OTHER}\\meta.json`, JSON.stringify({ startedAt: at(1500) }))
  })
  await w.clock.advance(2000)
  const ui = await $.ui.mount(BAND)
  expect(await ui.find({ type: 'Client', key: `clock:${RUN}` })).toBeDefined()
  expect(await ui.find({ type: 'Client', key: `clock:${OTHER}` })).toBeDefined()
  w.write(`${OTHER}\\meta.json`, JSON.stringify({ startedAt: at(1500), endedAt: at(2000), exitCode: 0, wrapperExitCode: 0 }))
  await w.clock.advance(5000)
  expect(w.toasts.filter(text => text.includes('session-cache')).length).toBe(1)
})

for (const snapshot of ['running', 'done']) {
  test(`a guard settlement during a poll with a ${snapshot} snapshot stays done and announces once`, async ($, on) => {
    const w = world(on)

    await $.session.start(START)
    await $.tool.call({ tool: 'PowerShell', command: LAUNCH })
    const final = JSON.stringify({ startedAt: at(0), endedAt: at(1500), exitCode: 0, wrapperExitCode: 0 })
    w.write(`${RUN}\\meta.json`, snapshot === 'done' ? final : JSON.stringify({ startedAt: at(0) }))
    w.whileReading(`${RUN}\\meta.json`, async () => {
      w.write(`${RUN}\\meta.json`, final)
      await $.tool.call({ tool: 'PowerShell', command: launch(OTHER, ' -FullAccess -TimeoutMinutes 90') })
      w.write(`${OTHER}\\meta.json`, JSON.stringify({ startedAt: at(1500) }))
    })
    await w.clock.advance(2000)
    const ui = await $.ui.mount(BAND)
    expect(await ui.find({ type: 'Client', key: `clock:${RUN}` })).toBeUndefined()
    expect(await ui.find({ type: 'Text', text: /^finished$/ })).toBeDefined()
    await w.clock.advance(5000)
    expect(w.toasts.filter(text => text.includes('outbox-batch')).length).toBe(1)
    expect(w.notifications().filter(env => env.CC_NOTIFY_TITLE?.includes('outbox-batch')).length).toBe(1)
  })
}

test('a live launcher is checked at most once a minute across polls, guard probes and scans', async ($, on) => {
  const w = world(on, { processStart: at(-1000) })

  await $.session.start(START)
  await $.tool.call({ tool: 'PowerShell', command: LAUNCH })
  w.write(`${RUN}\\meta.json`, JSON.stringify({ model: 'gpt-6.2-sol', startedAt: at(0) }))
  w.write(LOCK, owner())
  await w.clock.advance(5000)
  expect(w.calls.filter(call => call.env.CC_RUN_PID !== undefined).length).toBe(1)
  for (let i = 0; i < 11; i++) {
    await w.clock.advance(5000)
    expect(denial(await $.tool.call({ tool: 'PowerShell', command: launch(OTHER, ' -FullAccess -TimeoutMinutes 90') }))).toContain('in the same worktree')
    await $.command.run({ ...PRS, command: 'runs' })
    expect(w.calls.filter(call => call.env.CC_RUN_PID !== undefined).length).toBe(1)
  }
  expect(w.calls.filter(call => call.env.CC_RUN_PID !== undefined).length).toBe(1)
  await w.clock.advance(5000)
  expect(w.calls.filter(call => call.env.CC_RUN_PID !== undefined).length).toBe(2)
  w.remove(LOCK)
  w.write(`${RUN}\\meta.json`, JSON.stringify({ model: 'gpt-6.2-sol', startedAt: at(0), endedAt: at(11 * MINUTE), exitCode: 0, wrapperExitCode: 0 }))
  await w.clock.advance(5000)
  w.write(`${RUN}\\meta.json`, JSON.stringify({ model: 'gpt-6.2-sol', startedAt: at(0) }))
  await $.command.run({ ...PRS, command: 'runs' })
  const pane = await $.ui.mount(PANE_RUNS)
  expect(await pane.find({ type: 'Text', text: /no outcome/ })).toBeDefined()
})

for (const command of [
  'wc -c /e/State/pipeline/bin/codex-run.ps1',
  'grep -n SkipGitCheck /e/State/pipeline/bin/codex-run.ps1',
  'Get-Content E:\\State\\pipeline\\bin\\claude-run.ps1',
  "cat > brief.md <<'EOF'\ncodex-run.ps1 -Brief x\\brief.md\nEOF",
  'cat /e/State/pipeline/bin/codex-run.ps1',
  'sed -n 1p /e/State/pipeline/bin/codex-run.ps1',
  'Select-String -Path E:\\State\\pipeline\\bin\\claude-run.ps1 -Pattern Brief',
  'echo "codex-run.ps1 -Brief x\\brief.md"',
  'F=E:/State/pipeline/bin/claude-run.ps1; grep -n Brief "$F"',
  'F=C:/x/codex-run.ps1 && wc -c "$F"',
  "Set-Content brief.md @'\nclaude-run.ps1 -Brief x\\brief.md\n'@",
  "echo 'text; codex-run.ps1 -Brief x\\brief.md'",
]) {
  test(`the guard passes launcher mentions in ${command}`, async ($, on) => {
    const w = world(on)

    await $.session.start(START)
    await $.tool.call({ tool: 'Bash', command })
    expect(w.tools.length).toBe(1)
    expect(w.tools[0]?.run_in_background).toBeUndefined()
  })
}

for (const command of [
  launch(RUN, ' -TimeoutMinutes 90'),
  '& \'E:\\State\\pipeline\\bin\\claude-run.ps1\' -Brief x\\brief.md',
  'echo ready; codex-run.ps1 -Brief x\\brief.md -TimeoutMinutes 90',
  'echo ready && claude-run.ps1 -Brief x\\brief.md',
  'pwsh -Command "& codex-run.ps1 -Brief x\\brief.md -TimeoutMinutes 90"',
  "bash -c 'codex-run.ps1 -Brief x/brief.md -TimeoutMinutes 90'",
  'TERM=dumb codex-run.ps1 -Brief x\\brief.md -TimeoutMinutes 90',
]) {
  test(`the guard refuses a real launch in ${command}`, async ($, on) => {
    const w = world(on)

    await $.session.start(START)
    expect(denial(await $.tool.call({ tool: 'PowerShell', command }))).toContain(
      command.includes('codex-run') ? '-FullAccess' : 'missing -TimeoutMinutes',
    )
    expect(w.tools.length).toBe(0)
  })
}

for (const command of [
  launch(OTHER, ' -FullAccess -TimeoutMinutes 90'),
  "& 'E:\\State\\pipeline\\bin\\claude-run.ps1' -Repo E:\\Projects\\Example\\Acme-Api -Brief x\\brief.md -TimeoutMinutes 90",
  'echo ready; codex-run.ps1 -Repo E:\\Projects\\Example\\Acme-Api -Brief x\\brief.md -FullAccess -TimeoutMinutes 90',
  'echo ready && claude-run.ps1 -Repo E:\\Projects\\Example\\Acme-Api -Brief x\\brief.md -TimeoutMinutes 90',
]) {
  test(`the guard refuses a busy worktree in ${command}`, async ($, on) => {
    const w = world(on)

    await $.session.start(START)
    await $.tool.call({ tool: 'PowerShell', command: LAUNCH })
    expect(denial(await $.tool.call({ tool: 'PowerShell', command }))).toContain('in the same worktree')
    expect(w.tools.length).toBe(1)
  })
}

test('the guard can be switched off', { options: { launchGuard: false } }, async ($, on) => {
  const w = world(on)

  await $.session.start(START)
  await $.tool.call({ tool: 'PowerShell', command: launch(RUN) })
  expect(w.tools.length).toBe(1)
  expect(w.tools[0]?.run_in_background).toBeUndefined()
})

test('a launched run gets a live lane, then a notification with the gate verdict', async ($, on) => {
  const w = world(on)
  w.write(LOCK, owner())

  await $.session.start(START)
  w.write(`${RUN}\\brief.md`, '# Outbox bucket', NOW - MINUTE)
  await $.tool.call({ tool: 'PowerShell', command: LAUNCH })
  w.write(`${RUN}\\executor-prompt.md`, 'prompt', NOW + 1000)
  w.write(
    `${RUN}\\codex.stderr.log`,
    "codex\nReading the brief.\nexec\n\"pwsh.exe\" -Command 'dotnet build'\n succeeded in 1200ms:\ncodex\nUpdating the outbox batch and tests.\n",
    NOW + 2000,
  )
  await w.clock.advance(6000)

  const ui = await $.ui.mount(BAND)

  expect((await ui.find({ type: 'Client', key: `clock:${RUN}` }))?.props.props).toMatchObject({
    phase: 'running',
    from: NOW + 1000,
    timeoutMs: 90 * MINUTE,
  })
  expect(shown(await ui.drawn({ in: `clock:${RUN}` }))).toContain('/1h30m')
  expect(await ui.find({ type: 'Text', text: /outbox-batch/ })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /Updating the outbox batch/ })).toBeDefined()

  w.remove(`${RUN}\\codex.stderr.log`)
  w.write(`${RUN}\\codex.log`, 'codex\nDone.\n', NOW + 23 * MINUTE)
  w.write(`${RUN}\\report.md`, '# Report\n\nOutbox in bucket.', NOW + 23 * MINUTE)
  w.write(
    `${RUN}\\meta.json`,
    `\uFEFF${JSON.stringify({
      model: 'gpt-6.2-sol',
      reasoningEffort: 'high',
      startedAt: at(1000),
      endedAt: at(25 * MINUTE + 1000),
      exitCode: 0,
      wrapperExitCode: 0,
      timedOut: false,
      reportPresent: true,
      timeoutMinutes: 90,
      gate: { command: 'dotnet test', exitCode: 0, timedOut: false, tail: 'Passed!  - Failed: 0, Passed: 412, Skipped: 0' },
    })}`,
    NOW + 25 * MINUTE,
  )
  await w.clock.advance(5000)

  expect(w.toasts).toContain('✓ Codex · outbox-batch · gate passed · 412 test · 25m')
  expect(w.notifications().at(-1)).toMatchObject({
    CC_NOTIFY_TOAST: 'show',
    CC_NOTIFY_KIND: 'done',
    CC_NOTIFY_TITLE: 'Codex finished · outbox-batch',
    CC_NOTIFY_TEXT: 'gate passed · 412 test · 25m',
  })
  expect(w.notifications().at(-1)?.CC_NOTIFY_RING).toBeUndefined()
  expect(w.notifications().at(-1)?.CC_NOTIFY_TAG).toMatch(/^run-/)

  await w.clock.advance(5000)
  expect(w.toasts.filter(text => text.startsWith('✓ Codex')).length).toBe(1)
  expect(await ui.find({ type: 'Text', text: /gate passed/ })).toBeDefined()

  await ui.press({ key: `report:${RUN}` })
  expect(w.panes).toEqual(['runs'])

  const pane = await $.ui.mount({
    plugin: 'cockpit',
    surface: 'terminal',
    component: 'Pane',
    requestId: 'runs',
    props: { title: 'Executors', isFocused: true, bodyColumns: 100 } as never,
  })

  expect(await pane.find({ type: 'Markdown' })).toMatchObject({ props: { text: '# Report\n\nOutbox in bucket.' } })

  await pane.press({ key: 'tab:log' })
  expect(await pane.find({ type: 'Text', text: /Done\./ })).toBeDefined()

  await ui.press({ key: `x:${RUN}` })
  expect(await ui.find({ type: 'Text', text: /outbox-batch/ })).toBeUndefined()
})

test('a relaunch in the same run directory is announced again', async ($, on) => {
  const w = world(on)
  w.write(LOCK, owner())

  await $.session.start(START)
  w.write(`${RUN}\\brief.md`, '# Outbox bucket', NOW - MINUTE)
  await $.tool.call({ tool: 'PowerShell', command: LAUNCH })
  w.write(`${RUN}\\meta.json`, JSON.stringify({ startedAt: at(1000), endedAt: at(2000), exitCode: 0, wrapperExitCode: 0 }))
  await w.clock.advance(5000)

  expect(w.toasts.length).toBe(1)
  expect(w.notifications().filter(env => env.CC_NOTIFY_TOAST === 'show').length).toBe(1)

  await w.clock.advance(20_000)
  await $.tool.call({ tool: 'PowerShell', command: LAUNCH })
  await w.clock.advance(2000)
  expect(w.toasts.length).toBe(1)
  expect(denial(await $.tool.call({ tool: 'PowerShell', command: LAUNCH }))).toContain('in the same worktree')
  expect(w.tools.length).toBe(2)

  w.write(`${RUN}\\meta.json`, JSON.stringify({ startedAt: at(27_000), endedAt: at(28_000), exitCode: 0, wrapperExitCode: 0 }))
  await w.clock.advance(5000)

  expect(w.toasts.length).toBe(2)
  expect(w.notifications().filter(env => env.CC_NOTIFY_TOAST === 'show').length).toBe(2)
})

test('the brief tab shows the latest attempt brief, not the first one', async ($, on) => {
  const w = world(on)

  await $.session.start(START)
  w.write(`${RUN}\\brief.md`, '# Outbox bucket', NOW - MINUTE)
  w.write(`${RUN}\\fix-1.md`, '# Fix 1', NOW - MINUTE)
  await $.tool.call({ tool: 'PowerShell', command: LAUNCH })
  w.write(`${RUN}\\meta.json`, JSON.stringify({ brief: `${RUN}\\fix-1.md`, startedAt: at(1000), endedAt: at(2000), exitCode: 0, wrapperExitCode: 0 }))
  await w.clock.advance(5000)

  const ui = await $.ui.mount(BAND)
  await ui.press({ key: `report:${RUN}` })
  const pane = await $.ui.mount({
    plugin: 'cockpit',
    surface: 'terminal',
    component: 'Pane',
    requestId: 'runs',
    props: { title: 'Executors', isFocused: true, bodyColumns: 100 } as never,
  })

  await pane.press({ key: 'tab:brief' })
  expect(await pane.find({ type: 'Markdown' })).toMatchObject({ props: { text: '# Fix 1' } })
})

test('a red gate says so, in red, and names the exit', async ($, on) => {
  const w = world(on)

  await $.session.start(START)
  await $.tool.call({ tool: 'PowerShell', command: LAUNCH })
  w.write(`${RUN}\\executor-prompt.md`, 'prompt', NOW + 1000)
  w.write(
    `${RUN}\\meta.json`,
    JSON.stringify({
      startedAt: at(1000),
      endedAt: at(9 * MINUTE),
      exitCode: 0,
      wrapperExitCode: 5,
      timedOut: false,
      reportPresent: true,
      gate: { exitCode: 1, timedOut: false, tail: 'Failed: 2' },
    }),
    NOW + 9 * MINUTE,
  )
  await w.clock.advance(6000)
  expect(w.toasts).toContain('× Codex · outbox-batch · gate failed · exit 1 · 8m')
  expect(w.notifications().at(-1)).toMatchObject({ CC_NOTIFY_KIND: 'error' })
})

test('/runs opens the pane on the runs of the last two weeks', async ($, on) => {
  const w = world(on)

  await $.session.start(START)
  w.write(`${RUN}\\codex.log`, 'codex\nDone.\n', NOW - 60 * MINUTE)
  w.write(`${RUN}\\meta.json`, JSON.stringify({ model: 'gpt-6.2-sol', reasoningEffort: 'high', startedAt: at(-90 * MINUTE), endedAt: at(-60 * MINUTE), exitCode: 0, wrapperExitCode: 0, reportPresent: true }), NOW - 60 * MINUTE)
  w.write(`${RUNS}\\Acme-Web\\2026-09-01-old\\meta.json`, JSON.stringify({ model: 'gpt-6.2-sol', endedAt: '2026-09-01T10:00:00Z' }), NOW - 30 * 24 * 60 * MINUTE)
  w.write(`${RUNS}\\Acme-Web\\2026-10-04-claude-lot\\result.json`, '{}', NOW - 20 * 60 * MINUTE)
  w.write(
    `${RUNS}\\Acme-Web\\2026-10-04-claude-lot\\meta.json`,
    JSON.stringify({ model: 'claude-opus-5-5', effort: 'high', startedAt: at(-21 * 60 * MINUTE), endedAt: at(-20 * 60 * MINUTE), exitCode: 0, wrapperExitCode: 0, totalCostUsd: 3.2 }),
    NOW - 20 * 60 * MINUTE,
  )

  const result = await $.command.run({ ...PRS, command: 'runs' })

  expect(result.text).toBe('Opened the executor pane.')
  expect(w.panes).toEqual(['runs'])

  const pane = await $.ui.mount({
    plugin: 'cockpit',
    surface: 'terminal',
    component: 'Pane',
    requestId: 'runs',
    props: { title: 'Executors', isFocused: true, bodyColumns: 100 } as never,
  })

  expect(await pane.find({ key: `open:${RUN}` })).toBeDefined()
  expect(await pane.find({ key: `open:${RUNS}\\Acme-Web\\2026-10-04-claude-lot` })).toBeDefined()
  expect(await pane.find({ key: `open:${RUNS}\\Acme-Web\\2026-09-01-old` })).toBeUndefined()
  expect(shown(await pane.find({ type: 'Text', text: /2 run/ }))).toContain('2 run')
})


const ACCOUNTS_FILE = 'E:\\State\\pipeline\\config\\executors.json'

for (const registry of [undefined, '{broken', JSON.stringify({ defaults: { githubAccounts: { 'E:\\Projects\\Example': 'registry-work', 'E:\\Projects\\Example\\Acme-Api': 'specific-work' } } })]) {
  test(`PR account uses only user registry accounts: ${registry}`, async ($, on) => {
    const w = world(on)
    if (registry !== undefined) w.write(ACCOUNTS_FILE, registry)
    await $.session.start(START)
    w.write(ACCOUNTS_FILE, JSON.stringify({ defaults: { githubAccounts: { 'E:\\Projects\\Example': 'changed-after-start' } } }))
    await $.command.run(PRS)
    await $.command.run(PRS)
    expect(w.calls.filter(call => call.argv[1] === 'auth').map(call => call.argv.at(-1))).toEqual(
      registry?.startsWith('{"') ? ['specific-work', 'specific-work'] : [],
    )
    expect(w.reads.filter(path => path === ACCOUNTS_FILE).length).toBe(1)
  })
}

test('PR registry selects a custom root without matching sibling prefixes', async ($, on) => {
  const w = world(on, { cwd: 'E:\\Projects\\App' })
  w.write(ACCOUNTS_FILE, JSON.stringify({ defaults: { githubAccounts: { 'E:\\Project': 'wrong', 'E:\\Projects': 'custom' } } }))
  await $.session.start(START)
  await $.command.run(PRS)
  expect(w.calls.find(call => call.argv[1] === 'auth')?.argv.at(-1)).toBe('custom')
})

test('review requests share the query, dedupe owned PRs and show authors without Codex actions', async ($, on) => {
  const review = node(9, 'Acme-Web', { author: { login: 'colleague' } })
  const w = world(on, { graphql: ran(0, JSON.stringify({ data: { ...PULLS.data, reviewRequests: {
    issueCount: 2,
    nodes: [PULLS.data.viewer.pullRequests.nodes[2], review],
  } } })) })
  await $.session.start(START)
  const result = await $.command.run(PRS)
  expect(result.text).toContain('4 open')
  expect(result.text).toContain('1 review requested')
  expect(result.text).toContain('Acme-Web#9 review requested')
  expect(result.text).toContain('colleague')
  expect(result.text?.split('Acme-Web#5').length).toBe(2)
  const calls = w.calls.filter(call => call.argv[2] === 'graphql')
  expect(calls.length).toBe(1)
  expect(calls[0]?.argv.at(-1)).toContain('is:open is:pr review-requested:@me archived:false')
  const ui = await $.ui.mount(BAND)
  expect(shown(await ui.find({ type: 'Text', text: /open/ }))).toContain('1 review requested')
  expect(await ui.find({ type: 'Text', text: /colleague/ })).toBeDefined()
  expect(await ui.find({ key: `codex:${review.url}` })).toBeUndefined()
  expect((await ui.find({ type: 'Text', text: /^review requested$/ }))?.props.color).toBe('warning')
})

// Checked against CascadiaMono.ttf with the brief's cmap.js (2026-10-07).
const CASCADIA = new Set([... '°·—…≈≥←↑◇◆✓×●○◐◷▾▸▰▱─└⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'])
const elements = (tree: unknown): { type?: string; props: Record<string, unknown>; children?: unknown }[] => {
  if (Array.isArray(tree)) return tree.flatMap(elements)
  if (tree === null || typeof tree !== 'object') return []
  const node = tree as { type?: string; props?: Record<string, unknown>; children?: unknown }
  return [{ ...node, props: node.props ?? {} }, ...elements(node.children ?? node.props?.children)]
}
const checkDrawing = (tree: unknown, toasts: string[] = []) => {
  const nodes = elements(tree)
  const text = shown(tree) + nodes.map(node => String(node.props.label ?? node.props.text ?? node.props.source ?? '')).join('') + toasts.join('')
  const glyphs = [...new Set([...text].filter(ch => ch.codePointAt(0)! > 127))]
  expect(glyphs.filter(ch => !CASCADIA.has(ch))).toEqual([])
  expect(nodes.flatMap(node => Object.entries(node.props).filter(([key, value]) => /color/i.test(key) && typeof value === 'string' && value.includes('#')))).toEqual([])
}

for (const width of [150, 100, 70]) {
  test(`band foundations, PR tails and runs at ${width} columns`, async ($, on) => {
    const ci = ['FAILURE', 'PENDING'].map((state, i) => node(20 + i, 'Example-App', { title: 'A long title that must leave space at the end of the PR row', commits: { nodes: [{ commit: { committedDate: at(0), statusCheckRollup: { state } } }] } }))
    const w = world(on, { graphql: ran(0, JSON.stringify({ data: { ...PULLS.data, viewer: { ...PULLS.data.viewer, pullRequests: { totalCount: 6, nodes: [...PULLS.data.viewer.pullRequests.nodes, ...ci] } } } })) })
    w.write(QUOTA_CACHE, JSON.stringify({ fetchedAtUtc: at(0), quota: JSON.parse(codeburn(48)) }))
    await $.session.start(START)
    await drain($.turn.step(STEP))
    await $.session.measure({ context: { window: 1_000_000 }, changed: ['rateLimits'], rateLimits: [
      { kind: 'five_hour', percentUsed: 42, resetsAt: at(179 * MINUTE) },
      { kind: 'seven_day', percentUsed: 63, resetsAt: at(76 * 60 * MINUTE) },
    ] })
    await $.command.run(PRS)
    for (let i = 0; i < 4; i++) {
      const dir = `${RUNS}\\App${i}\\2026-10-05-topic${i}`
      w.write(`${RUNS}\\.locks\\app${i}.json`, owner(dir))
      await $.tool.call({ tool: 'PowerShell', command: launch(dir, ' -FullAccess -TimeoutMinutes 90', `E:\\Projects\\Sandbox\\App${i}`) })
      w.write(`${dir}\\meta.json`, JSON.stringify({ model: 'gpt-6.2-sol', startedAt: at(i) }))
      w.write(`${dir}\\progress.md`, 'Progress verified')
    }
    await w.clock.advance(2000)
    const ui = await $.ui.mount({ ...BAND, props: { ...BAND.props as object, bodyColumns: width } as never })
    const tree = await ui.drawn()
    checkDrawing(tree, w.toasts)
    expect(shown(await ui.find({ key: ci[0]!.url })).startsWith('×')).toBe(true)
    expect(shown(await ui.find({ key: ci[1]!.url })).startsWith('◐')).toBe(true)
    expect(shown(await ui.find({ key: PULLS.data.viewer.pullRequests.nodes[3]!.url })).startsWith('✓')).toBe(true)
    expect(shown(await ui.find({ key: PULLS.data.viewer.pullRequests.nodes[2]!.url })).startsWith('●')).toBe(true)
    expect(await ui.find({ type: 'Text', text: /\+1 more · \/runs/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /└ Progress/ })).toBeDefined()
    const row = await ui.find({ key: PULLS.data.viewer.pullRequests.nodes[2]!.url })
    expect(elements(row).some(node => node.props.flexGrow === 1 && node.props.minWidth === 0)).toBe(true)
    expect(await ui.find({ key: `codex:${PULLS.data.viewer.pullRequests.nodes[2]!.url}` })).toBeDefined()
    const cache = await ui.drawn({ in: 'cache' })
    checkDrawing(cache)
    expect(shown(cache)).toContain('≥')
    expect(shown(await ui.find({ key: 'claude-limits' }))).toContain('42%')
    await $.command.run({ ...PRS, command: 'runs' })
    const pane = await $.ui.mount(PANE_RUNS)
    checkDrawing(await pane.drawn(), w.toasts)
    expect((await pane.find({ key: 'close' }))?.props).toMatchObject({ hotkey: 'q', role: 'dismiss' })
    expect(elements(await pane.drawn()).filter(node => typeof node.props.hotkey === 'string' && /^[1-9]$/.test(node.props.hotkey as string)).map(node => node.props.hotkey)).toEqual(['1', '2', '3', '4'])
    expect(elements(await pane.drawn()).some(node => node.props.justifyContent === 'flex-end')).toBe(true)
  })
}

test('expired quota readings are dim and honest', async ($, on) => {
  const w = world(on)
  await $.session.start(START)
  await $.session.measure({ context: { window: 1_000_000 }, changed: ['rateLimits'], rateLimits: [{ kind: 'five_hour', percentUsed: 99, resetsAt: at(-MINUTE) }] })
  const ui = await $.ui.mount(BAND)
  const window = await ui.find({ type: 'Text', text: /stale reading/ })
  expect(shown(window)).toContain('stale reading')
  expect((await ui.findAll({ type: 'Text', text: /stale reading/ })).some(node => node.props.dimColor === true)).toBe(true)
  expect(shown(window)).not.toContain('99%')
})

const runnerRegistry = JSON.stringify({ defaults: { cockpitRunnerRoot: 'E:\\Projects\\Sandbox', githubAccounts: { 'E:\\Projects\\Sandbox': 'runner-owner', 'E:\\Projects\\Example': 'work' } }, executors: {
  app: { repo: 'E:\\Projects\\Sandbox\\Example-App', github: 'fixture-owner/Example-App' },
  portal: { repo: 'E:\\Projects\\Sandbox\\Example-Portal', github: 'fixture-owner/Example-Portal' },
  docs: { repo: 'E:\\Projects\\Sandbox\\Example-Docs', github: 'fixture-owner/Example-Docs' },
  noRunner: { repo: 'E:\\Projects\\Sandbox\\Other', github: 'fixture-owner/Other' },
  work: { repo: 'E:\\Projects\\Example\\App', github: 'org/App' },
} })
const runnerResponse = (path: string, state: string) => {
  if (path.includes('/actions/runners')) return ran(0, JSON.stringify({ runners: path.includes('/Other/') ? [] : [{ id: 1, name: 'this-pc', status: state === 'offline' ? 'offline' : 'online', busy: state === 'busy' && path.includes('/Example-App/') }] }))
  const busy = state === 'busy' && path.includes('/Example-App/')
  const queued = (state === 'queued' || state === 'busy') && path.includes('/Example-Portal/')
  return ran(0, JSON.stringify({ workflow_runs: [...(busy || queued ? [{ name: busy ? 'ci-app' : 'ci-portal', status: busy ? 'in_progress' : 'queued', run_started_at: at(-12 * MINUTE), head_branch: 'fix/cache', pull_requests: busy ? [{ number: 160 }] : [] }] : []), { name: 'completed-archive', status: 'completed', head_branch: 'main' }] }))
}
for (const state of ['busy', 'queued', 'offline', 'idle']) {
  test(`runner lane ${state}`, async ($, on) => {
    const w = world(on, { runnerApi: path => runnerResponse(path, state) })
    w.write(ACCOUNTS_FILE, runnerRegistry)
    await $.session.start(START)
    await w.clock.advance(60_000)
    expect(w.calls.filter(call => call.argv[2]?.includes('/actions/')).length).toBe(0)
    const ui = await $.ui.mount(BAND)
    await ui.advance(1000)
    const lane = await ui.find({ key: 'runner-lane' })
    if (state === 'idle') expect(lane).toBeUndefined()
    else {
      expect(lane).toBeDefined()
      checkDrawing(lane)
      if (state === 'busy') {
        expect(shown(lane)).toContain('◐ runner · Example-App ci-app #160 · 13m')
        expect(shown(lane)).toContain('Example-Portal queued')
      }
      if (state === 'queued') expect(shown(lane)).toContain('● runner · Example-Portal queued')
      if (state === 'offline') expect(shown(lane).split('× offline').length).toBe(4)
    }
    expect(w.calls.filter(call => call.argv[2]?.includes('/org/App/')).length).toBe(0)
    expect(w.calls.filter(call => call.argv[1] === 'auth' && call.argv.at(-1) === 'runner-owner').length).toBe(1)
    const runCalls = w.calls.filter(call => call.argv[2]?.includes('/actions/runs?'))
    expect(runCalls.length).toBe(3)
    expect(runCalls.every(call => call.argv[2]?.endsWith('/actions/runs?per_page=20'))).toBe(true)
    expect(shown(await ui.drawn())).not.toContain('completed-archive')
    if (state === 'busy') {
      const text = shown(await ui.drawn())
      expect(text.indexOf('runner ·') < text.indexOf(' PR ')).toBe(true)
      expect(text.indexOf(' PR ') < text.indexOf(' Codex ')).toBe(true)
    }
    const count = w.calls.filter(call => call.argv[2]?.includes('/actions/')).length
    await w.clock.advance(59_000)
    await ui.advance(1000)
    expect(w.calls.filter(call => call.argv[2]?.includes('/actions/')).length).toBe(count)
    await w.clock.advance(1000)
    await ui.advance(1000)
    const refreshed = w.calls.filter(call => call.argv[2]?.includes('/actions/')).length
    expect(refreshed).toBe(count * 2)
    await ui.unmount()
    await w.clock.advance(60_000)
    expect(w.calls.filter(call => call.argv[2]?.includes('/actions/')).length).toBe(refreshed)
  })
}

test('runner retains last reading on a failed call and refreshes after CI commands', async ($, on) => {
  let failed = false
  const w = world(on, { runnerApi: path => failed ? ran(1, '', 'offline') : runnerResponse(path, 'busy') })
  w.write(ACCOUNTS_FILE, runnerRegistry)
  await $.session.start(START)
  const ui = await $.ui.mount(BAND)
  await ui.advance(1000)
  expect(await ui.find({ key: 'runner-lane' })).toBeDefined()
  for (const command of ['git push', 'gh pr create', 'gh pr merge', 'gh workflow run ci', 'gh run rerun 123']) {
    const before = w.calls.filter(call => call.argv[2]?.includes('/actions/')).length
    await $.tool.call({ tool: 'Bash', command })
    await w.clock.advance(5000)
    await ui.advance(1000)
    expect(w.calls.filter(call => call.argv[2]?.includes('/actions/')).length > before).toBe(true)
  }
  failed = true
  await w.clock.advance(60_000)
  await ui.advance(1000)
  const lane = shown(await ui.find({ key: 'runner-lane' }))
  expect(lane).toContain('ci-app #160')
  expect(lane).toContain('stale reading')
})

test('runner resolves each distinct account once per refresh', async ($, on) => {
  const w = world(on, { runnerApi: path => runnerResponse(path, 'busy') })
  const registry = JSON.parse(runnerRegistry)
  registry.defaults.githubAccounts['E:\\Projects\\Sandbox\\Example-Portal'] = 'second-owner'
  w.write(ACCOUNTS_FILE, JSON.stringify(registry))
  await $.session.start(START)
  const ui = await $.ui.mount(BAND)
  await ui.advance(1000)
  expect(w.calls.filter(call => call.argv[1] === 'auth').map(call => call.argv.at(-1)).sort()).toEqual(['runner-owner', 'second-owner'])
})

test('runner never polls in a headless session even with a band and CI commands', async ($, on) => {
  const w = world(on, { runnerApi: path => runnerResponse(path, 'busy') })
  w.write(ACCOUNTS_FILE, runnerRegistry)
  await $.session.start({ ...START, isInteractive: false })
  const ui = await $.ui.mount(BAND)
  await $.tool.call({ tool: 'PowerShell', command: 'git push' })
  await w.clock.advance(120_000)
  await ui.advance(120_000)
  expect(w.calls.filter(call => call.argv[2]?.includes('/actions/')).length).toBe(0)
  expect(await ui.find({ key: 'runner-lane' })).toBeUndefined()
})


for (const [amount, color] of [[149_999, 'success'], [150_000, 'warning'], [359_999, 'warning'], [360_000, 'error']] as const) {
  test(`context tone at ${amount} tokens`, async ($, on) => {
    world(on, { settings: { autoCompactWindow: 400_000 }, usage: { ...USAGE, input_tokens: amount, output_tokens: 0, cache_read_input_tokens: 0, cache_creation_input_tokens: 0 } })
    await $.session.start(START)
    await drain($.turn.step(STEP))
    const ui = await $.ui.mount(BAND)
    const context = await ui.find({ key: 'context' })
    expect(context).toBeDefined()
    const label = elements(context).find(node => shown(node) === 'ctx ')
    expect(label?.props.dimColor).toBe(true)
    expect(label?.props.color).toBeUndefined()
    expect(elements(context).find(node => /^\d+k\/400k$/.test(shown(node)))?.props.color).toBe(color)
    expect(elements(context).filter(node => node.props.color && node.props.color !== color)).toEqual([])
    checkDrawing(context)
  })
}

for (const settings of [{ autoCompactWindow: 400_000 }, {}, { autoCompactWindow: 0 }, { autoCompactWindow: -1 }, { autoCompactWindow: '400000' }, { autoCompactWindow: null }]) {
  test(`context denominator from settings or model: ${JSON.stringify(settings)}`, async ($, on) => {
    const w = world(on, { settings })
    await $.session.start(START)
    await drain($.turn.step(STEP))
    const ui = await $.ui.mount(BAND)
    expect(shown(await ui.find({ key: 'context' }))).toContain(settings.autoCompactWindow === 400_000 ? 'ctx 302k/400k' : 'ctx 302k/1.0M')
    await drain($.turn.step({ ...STEP, index: 1 }))
    await ui.drawn()
    expect(w.settingsReads()).toBe(1)
  })
}

test('context model fallback follows measurement when settings are unavailable', async ($, on) => {
  const w = world(on, { settingsFailure: true })
  await $.session.start(START)
  await drain($.turn.step(STEP))
  const ui = await $.ui.mount(BAND)
  expect(shown(await ui.find({ key: 'context' }))).toContain('302k/1.0M')
  await $.session.measure({ context: { window: 500_000 }, changed: ['context'], rateLimits: [] })
  expect(shown(await ui.find({ key: 'context' }))).toContain('302k/500k')
  expect(w.settingsReads()).toBe(1)
})

for (const width of [150, 100, 70, 40]) {
  test(`context priority fit at ${width} columns`, async ($, on) => {
    const w = world(on, { settings: { autoCompactWindow: 400_000 }, usage: { ...USAGE, input_tokens: 180_000, output_tokens: 0, cache_read_input_tokens: 0, cache_creation_input_tokens: 0 } })
    w.write(QUOTA_CACHE, JSON.stringify({ fetchedAtUtc: at(0), quota: { providers: [{ id: 'codex', available: true, windows: [{ label: '5-hour', usedPct: 48, resetsAt: at(179 * MINUTE) }, { label: 'Weekly', usedPct: 63, resetsAt: at(76 * 60 * MINUTE) }] }] } }))
    await $.session.start(START)
    await drain($.turn.step(STEP))
    await $.session.measure({ context: { window: 1_000_000 }, changed: ['rateLimits'], rateLimits: [
      { kind: 'five_hour', percentUsed: 42, resetsAt: at(179 * MINUTE) },
      { kind: 'seven_day', percentUsed: 63, resetsAt: at(76 * 60 * MINUTE) },
    ] })
    const ui = await $.ui.mount({ ...BAND, props: { ...BAND.props as object, bodyColumns: width } as never })
    const tree = await ui.drawn()
    const context = shown(await ui.find({ key: 'context' }))
    const cache = shown(await ui.drawn({ in: 'cache' }))
    expect(context).toContain(width <= 70 ? 'ctx 45%' : 'ctx 180k/400k')
    const contextNodes = elements(await ui.find({ key: 'context' }))
    expect(contextNodes.find(node => shown(node) === 'ctx ')?.props).toMatchObject({ dimColor: true })
    expect(contextNodes.find(node => shown(node) === 'ctx ')?.props.color).toBeUndefined()
    expect(contextNodes.find(node => shown(node) === (width <= 70 ? '45%' : '180k/400k'))?.props.color).toBe('warning')
    expect(/[▰▱]/.test(context)).toBe(/[▰▱]/.test(cache))
    expect(/[▰▱]/.test(context)).toBe(width === 150)
    expect(shown(await ui.find({ key: 'claude-limits' }))).toContain('42%')
    expect(shown(await ui.find({ key: 'codex-limits' }))).toContain('48%')
    const lane = await ui.find({ key: 'meters-lane' })
    const nodes = elements(lane)
    expect(nodes.findIndex(node => node.props.key === 'context') > nodes.findIndex(node => node.props.key === 'cache')).toBe(true)
    if (width >= 70) expect(cache.length + context.length + shown(await ui.find({ key: 'claude-limits' })).length + shown(await ui.find({ key: 'codex-limits' })).length + 9 <= width).toBe(true)
    checkDrawing(tree)
  })
}

test('context is absent before the first reply and after clear', async ($, on) => {
  world(on, { settings: { autoCompactWindow: 400_000 } })
  await $.session.start(START)
  const ui = await $.ui.mount(BAND)
  expect(await ui.find({ key: 'context' })).toBeUndefined()
  await drain($.turn.step(STEP))
  expect(await ui.find({ key: 'context' })).toBeDefined()
  await $.session.end({ reason: 'clear', sessionId: 's1', resume: { id: 's1' } })
  expect(await ui.find({ key: 'context' })).toBeUndefined()
})
