import { atom, read, update } from 'claude-code'
import type { EngineInterface, On, PluginOptions } from 'claude-code'

import type { RunDetail, RunLine, RunOutcome, RunProvider, RunsPane, RunTab, RunView } from '../types'
import { clip, clockAt, coarse, COLOR, GLYPH, MINUTE, shortModel, span } from './look'
import { registryOf, RUN_PATH_COMMAND, TEAM_REGISTRY_COMMAND } from './pipeline'
import type { Registry } from './pipeline'
import { outcomeOf } from '../core/readings'

const pipelineHome = { plugin: 'cockpit', key: 'pipelineHome' } as const

// The pipeline's executors: the launch guard, a lane per run this session launched, a toast
// when one ends, and the runs pane. Everything is read from the run directories the launchers
// write under the hub (meta.json, progress.md, gate.json, the logs), never from a transcript.

// What the lanes draw from; this module is the only writer.
const runsView = atom({ plugin: 'cockpit', key: 'runs' } as const, [])
const catalog = atom({ plugin: 'cockpit', key: 'catalog' } as const, [])
const paneView = atom({ plugin: 'cockpit', key: 'pane' } as const, { mode: 'list' })
const detailView = atom({ plugin: 'cockpit', key: 'detail' } as const, null)

let hub = ''
let RUNS = ''
const PANE = 'runs'
const POLL_MS = 5000
const NARRATION_MS = 15_000

// A finished lane stays this long unless dismissed.
const KEEP_MS = 3 * 60 * MINUTE

// The launchers' own defaults (codex-run.ps1, claude-run.ps1).
const DEFAULT_TIMEOUT: Record<RunProvider, number> = { codex: 30, claude: 40 }

const LAUNCHER = /^(?:.*[\\/])?(codex|claude)-run(?:\.ps1|\.cmd)?$/i

// Only executable positions count. Quotes keep arguments together; literal blocks never
// become command segments. Wrapper command strings are scanned as commands in their turn.
const launcherOf = (command: string): { provider: RunProvider; path: string } | undefined => {
  const segments: string[][] = []
  let words: string[] = []
  let word = ''
  let started = false
  let quote = ''
  const heredocs: { delimiter: string; tabs: boolean }[] = []
  const endWord = () => {
    if (started) words.push(word)
    word = ''
    started = false
  }
  const endSegment = () => {
    endWord()
    if (words.length > 0) segments.push(words)
    words = []
  }

  for (let i = 0; i < command.length; i++) {
    const char = command[i] ?? ''

    if (quote !== '') {
      if (char === quote) {
        if (quote === "'" && command[i + 1] === "'") {
          word += char
          i++
        } else {
          quote = ''
        }
      } else if ((char === '`' || (char === '\\' && quote === '"')) && command[i + 1] === quote) {
        word += command[++i]
      } else {
        word += char
      }
      continue
    }

    const hereString = /^@(['"])\r?\n/.exec(command.slice(i))
    if (hereString !== null) {
      const end = new RegExp(`^${hereString[1]}@`, 'm').exec(command.slice(i + hereString[0].length))
      i = end === null ? command.length : i + hereString[0].length + end.index + 1
      started = true
      continue
    }

    const heredoc = /^<<(-?)\s*(?:'([^']+)'|"([^"]+)"|([\w-]+))/.exec(command.slice(i))
    if (heredoc !== null) {
      endWord()
      heredocs.push({ delimiter: heredoc[2] ?? heredoc[3] ?? heredoc[4] ?? '', tabs: heredoc[1] === '-' })
      i += heredoc[0].length - 1
      continue
    }

    if (char === "'" || char === '"') {
      quote = char
      started = true
    } else if (char === '`' || (char === '\\' && /[\s;'"|&]/.test(command[i + 1] ?? ''))) {
      word += command[++i] ?? ''
      started = true
    } else if (char === '#' && !started) {
      while (i + 1 < command.length && command[i + 1] !== '\n') i++
    } else if (char === '\n' || char === ';' || char === '|' || char === '&') {
      endSegment()
      if (char === '\n') {
        for (const doc of heredocs.splice(0)) {
          let found = false
          while (i + 1 < command.length) {
            const start = i + 1
            const end = command.indexOf('\n', start)
            const line = command.slice(start, end < 0 ? command.length : end).replace(/\r$/, '')
            i = end < 0 ? command.length : end
            if ((doc.tabs ? line.replace(/^\t+/, '') : line) === doc.delimiter) {
              found = true
              break
            }
          }
          if (!found) i = command.length
        }
      }
    } else if (/\s/.test(char)) {
      endWord()
    } else {
      word += char
      started = true
    }
  }
  endSegment()

  for (const segment of segments) {
    let executableIndex = 0
    while (/^[A-Za-z_][A-Za-z0-9_]*=/.test(segment[executableIndex] ?? '')) executableIndex++
    const program = segment[executableIndex] ?? ''
    const direct = LAUNCHER.exec(program)
    if (direct !== null) return { provider: direct[1]?.toLowerCase() as RunProvider, path: program }

    const shell = program.split(/[\\/]/).at(-1)?.replace(/\.exe$/i, '').toLowerCase()
    if (shell !== 'pwsh' && shell !== 'powershell' && shell !== 'bash') continue

    const option = segment.findIndex((arg, index) => index > executableIndex &&
      (shell === 'bash' ? arg === '-c' : /^-(?:File|Command)$/i.test(arg)))
    if (option < 0) continue

    const script = segment[option + 1] ?? ''
    const match = LAUNCHER.exec(script)
    const launcher = /^-File$/i.test(segment[option] ?? '')
      ? match === null ? undefined : { provider: match[1]?.toLowerCase() as RunProvider, path: script }
      : launcherOf(script)
    if (launcher !== undefined) return launcher
  }
  return undefined
}

const PROVIDER = {
  codex: { name: 'Codex', glyph: GLYPH.codex, color: COLOR.codex },
  claude: { name: 'Claude', glyph: GLYPH.claude, color: COLOR.claude },
} as const

const EXITS: Record<number, { title: string; tone: RunOutcome['tone'] }> = {
  1: { title: 'execution or report failed', tone: 'bad' },
  2: { title: 'Claude authentication', tone: 'bad' },
  3: { title: 'repository busy or resume refused', tone: 'warn' },
  4: { title: 'quota refused', tone: 'warn' },
  75: { title: 'preflight or sandbox', tone: 'bad' },
}

const TABS: readonly { tab: RunTab; label: string; key: string }[] = [
  { tab: 'report', label: 'report', key: 'r' },
  { tab: 'log', label: 'log', key: 'l' },
  { tab: 'progress', label: 'progress', key: 'p' },
  { tab: 'gate', label: 'gate', key: 'g' },
  { tab: 'brief', label: 'brief', key: 'b' },
]

type Meta = {
  model?: string
  effort?: string
  reasoningEffort?: string
  startedAt?: string
  endedAt?: string | null
  exitCode?: number | null
  wrapperExitCode?: number | null
  timedOut?: boolean
  timeoutMinutes?: number
  reportPresent?: boolean
  outOfCredits?: boolean
  rateLimited?: boolean
  totalCostUsd?: number
  fixLoop?: number
  brief?: string
  gate?: Gate | null
}

type Gate = { exitCode?: number; timedOut?: boolean; tail?: string; durationSeconds?: number; flaky?: boolean; attempts?: { failures?: string[] }[] }

type Entry = { name: string; kind: string; size: number; mtimeMs: number }

let hasGuard = true
let hasToasts = true
let hasSound = true
let isInteractive = false
let folder = ''
let isPolling = false

// Per run directory: the stderr size last read and when, so a busy log is read at most every 15s.
const narrated = new Map<string, { size: number; at: number; line?: string }>()
const launcherAliveUntil = new Map<string, number>()
const launcherChecks = new Map<string, Promise<boolean>>()
const announced = new Set<string>()

const forgetLauncher = (dir: string) => {
  launcherAliveUntil.delete(dir)
  launcherChecks.delete(dir)
}

const toWindows = (path: string) =>
  path
    .replace(/^\/(?:mnt\/)?([a-z])\//i, (_, drive: string) => `${drive.toUpperCase()}:\\`)
    .replace(/\//g, '\\')
    .replace(/\\+$/, '')

const parentOf = (path: string) => path.slice(0, Math.max(0, path.lastIndexOf('\\')))
const leafOf = (path: string) => path.slice(path.lastIndexOf('\\') + 1)
const isUnder = (path: string, root: string) => path.toLowerCase().startsWith(`${root.toLowerCase()}\\`)

const argOf = (command: string, name: string) => {
  const match = new RegExp(`(?:^|\\s)-${name}(?::|\\s+)(?:"([^"]*)"|'([^']*)'|([^\\s;|&]+))`, 'i').exec(command)

  return match === null ? undefined : (match[1] ?? match[2] ?? match[3])
}

const hasFlag = (command: string, name: string) => new RegExp(`(?:^|\\s)-${name}(?=$|[\\s:;|&'"])`, 'i').test(command)

// A path the shell expands later ("$RD\brief.md", ${RD}, $env:X, $(...)): the guard reads the literal text,
// tracks a run directory that never appears and then holds the worktree busy for good.
const variablePathOf = (command: string) => ['Brief', 'RunDir', 'Repo'].find(name => argOf(command, name)?.includes('$'))

const today = (now: number) => {
  const date = new Date(now)

  return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, '0')}-${String(date.getDate()).padStart(2, '0')}`
}

const dated = (name: string, now: number) => (/^\d{4}-\d{2}-\d{2}-/.test(name) ? name : `${today(now)}-${name}`)

const fullPath = async ($: EngineInterface, path: string) => {
  const result = await $.process.run(['pwsh', '-NoProfile', '-NonInteractive', '-Command', RUN_PATH_COMMAND], {
    env: { CC_PATH: toWindows(path), CC_CWD: toWindows(await $.session.cwd()) }, timeoutMs: 5000,
  })
  if (result.exitCode !== 0 || result.stdout.trim() === '') throw new Error('Could not resolve the run path')
  return toWindows(result.stdout.trim())
}

const registryAt = async ($: EngineInterface, path: string): Promise<Registry> => {
  try { return registryOf(await $.fs.read(path)) } catch { return {} }
}

const teamRegistry = async ($: EngineInterface, launcher: string): Promise<Registry> => {
  try {
    const result = await $.process.run(['pwsh', '-NoProfile', '-NonInteractive', '-Command', TEAM_REGISTRY_COMMAND], {
      env: { CC_LAUNCHER: toWindows(launcher) }, timeoutMs: 5000,
    })
    return result.exitCode === 0 ? registryAt($, result.stdout.trim()) : {}
  } catch { return {} }
}

// Where the launcher will write, as New-RunDirPath decides: the brief's own run directory, or a
// new one named after it (a resume's `<run>-fix<N>`), using the first free suffix.
const runDirsOf = async ($: EngineInterface, command: string, now: number): Promise<string[]> => {
  if (hub === '') return []
  const explicit = argOf(command, 'RunDir')

  if (explicit !== undefined) {
    return [await fullPath($, explicit)]
  }

  const briefArg = argOf(command, 'Brief')

  if (briefArg === undefined) {
    return []
  }

  const brief = await fullPath($, briefArg)
  const parent = parentOf(brief)
  const isOwnBrief = leafOf(brief).toLowerCase() === 'brief.md'
  const repoArg = argOf(command, 'Repo') ?? ''
  const team = await teamRegistry($, launcherOf(command)?.path ?? '')
  const user = await registryAt($, `${hub}\\config\\executors.json`)
  const executors = { ...team.executors }
  for (const [key, entry] of Object.entries(user.executors ?? {})) executors[key] = { ...executors[key], ...entry }
  let alias = repoArg.toLowerCase()
  if (repoArg !== '' && (/[\\/]/.test(repoArg) || executors[alias] === undefined)) {
    const path = await fullPath($, repoArg)
    let main = path
    let github: string | undefined
    try {
      const entries = await $.fs.list(path)
      if (entries.some(entry => entry.name.toLowerCase() === '.git')) {
        const result = await $.process.run(['git', '--no-optional-locks', '-c', `safe.directory=${path}`, '-C', path, 'rev-parse', '--path-format=absolute', '--git-common-dir'], { timeoutMs: 5000 })
        if (result.exitCode === 0 && result.stdout.trim() !== '') main = parentOf(toWindows(result.stdout.trim()))
        const origin = await $.process.run(['git', '--no-optional-locks', '-c', `safe.directory=${path}`, '-C', path, 'remote', 'get-url', 'origin'], { timeoutMs: 5000 })
        const slug = /^(?:https?:\/\/(?:[^/@]+@)?github\.com(?::\d+)?\/|ssh:\/\/(?:[^/@]+@)?github\.com(?::\d+)?\/|(?:[^/@:]+@)?github\.com:)([^/]+)\/([^/?#]+?)(?:\.git)?\/?$/i.exec(origin.stdout.trim())
        if (origin.exitCode === 0 && slug !== null) github = `${slug[1]}/${slug[2]}`.toLowerCase()
      }
    } catch { }
    alias = leafOf(main).toLowerCase()
    const entries = Object.entries(executors)
    alias = entries.find(([, entry]) => typeof entry.repo === 'string' && toWindows(entry.repo).toLowerCase() === main.toLowerCase())?.[0]
      ?? entries.find(([, entry]) => github !== undefined && entry.github?.toLowerCase() === github)?.[0] ?? alias
  }
  const resume = argOf(command, 'Resume')

  if (resume !== undefined && await readText($, `${parent}\\meta.json`) !== undefined) {
    return [`${parent}-fix${argOf(command, 'FixLoop') ?? '1'}`]
  }

  if (resume === undefined && isOwnBrief && isUnder(parent, RUNS)) {
    return [parent]
  }

  const stem = resume === undefined ? leafOf(brief).replace(/\.[^.]+$/, '') : `${isOwnBrief ? leafOf(parent) : leafOf(brief).replace(/\.[^.]+$/, '')}-fix${argOf(command, 'FixLoop') ?? '1'}`
  const base = `${RUNS}\\${alias}\\${dated(stem, now)}`
  let candidate = base
  for (let suffix = 2; ; suffix++) {
    try { await $.fs.list(candidate) } catch { return [candidate] }
    candidate = `${base}-${suffix}`
  }
}

// The worktree a launch works in, as -Repo names it: a path or a hub alias.
const worktreeOf = (command: string) => toWindows(argOf(command, 'Repo') ?? '').toLowerCase()

// Why a launch may not go, in the words the model reads; undefined lets it through. Several
// executors may run at once, each in its own worktree: two in one worktree collide.
const refusalOf = (command: string, provider: RunProvider, busy: RunView | undefined) => {
  const readOnly = provider === 'codex' && hasFlag(command, 'ReadOnly')
  if (command.split(/[;\n]/).some(segment => launcherOf(segment) !== undefined && /\|\s*(?:tail|head|Select-Object)\b/i.test(segment))) {
    return "cockpit: The pipe hides the launcher's exit code. Redirect output to a file, print $?, and read the file."
  }
  const variable = variablePathOf(command)
  if (variable !== undefined) {
    return `cockpit: -${variable} uses a shell variable (${argOf(command, variable) ?? ''}): Cockpit reads the command literally and cannot detect when this run ends, which leaves the worktree blocked. Write out the full path and rerun.`
  }
  if (!readOnly && argOf(command, 'Resume') !== undefined && argOf(command, 'FixLoop') === undefined) {
    return 'cockpit: -Resume without -FixLoop stops the launcher immediately ("-FixLoop is required with -Resume") while the wrapper exits 0. Add -FixLoop <n> (1 for the first fix) and rerun.'
  }
  if (Number(argOf(command, 'TimeoutMinutes')) > 115) {
    return 'cockpit: -TimeoutMinutes above 115 is unsafe. Background Bash calls stop after two hours. Split the task.'
  }
  if (provider === 'codex' && !readOnly && !hasFlag(command, 'FullAccess')) {
    return 'cockpit: Run codex-run with -FullAccess, including when resuming. The Windows sandbox blocks NuGet, Git in worktrees, and Docker. Add -FullAccess and rerun.'
  }

  if (argOf(command, 'TimeoutMinutes') === undefined) {
    return `cockpit: missing -TimeoutMinutes. The ${provider}-run default is ${DEFAULT_TIMEOUT[provider]} minutes, so heavy tasks such as Yarn, NuGet, or long suites may time out. Choose a timeout that fits the task, such as -TimeoutMinutes 90, and rerun.`
  }

  if (!readOnly && busy !== undefined) {
    return `cockpit: ${PROVIDER[busy.provider].name} is already working on ${busy.topic} in the same worktree (${argOf(command, 'Repo') ?? ''}). The launcher refuses a second executor in that worktree (exit 3). Wait for its notification or use another worktree.`
  }

  return undefined
}

const readJson = async ($: EngineInterface, path: string): Promise<Meta | undefined> => {
  if (hub === '') return undefined
  try {
    return JSON.parse((await $.fs.read(path)).replace(/^\uFEFF/, '')) as Meta
  } catch {
    return undefined
  }
}

const readText = async ($: EngineInterface, path: string) => {
  if (hub === '') return undefined
  try {
    return (await $.fs.read(path)).replace(/^\uFEFF/, '')
  } catch {
    return undefined
  }
}

const artifacts = async ($: EngineInterface, dir: string, meta: Meta): Promise<Meta> => {
  const gate = (await readJson($, `${dir}\\gate.json`)) as Gate | undefined
  let cost = meta.totalCostUsd
  if (cost === undefined) {
    const text = await readText($, `${dir}\\task-usage.json`)
    try {
      const usage = JSON.parse(text ?? '') as { sessions?: { delta?: { cost?: number } }[] }
      const costs = (usage.sessions ?? []).flatMap(session => typeof session.delta?.cost === 'number' && Number.isFinite(session.delta.cost) ? [session.delta.cost] : [])
      if (costs.length > 0) cost = costs.reduce((sum, value) => sum + value, 0)
    } catch { }
  }
  return { ...meta, gate: gate ?? meta.gate, totalCostUsd: cost }
}

// The last thing Codex said: the first line of its newest narration block in the live log.
const narrationOf = (log: string) => {
  const blocks = log.slice(-200_000).split(/\r?\n(?=codex\r?\n)/)
  const last = blocks.at(-1) ?? ''
  const lines = last.split(/\r?\n/)

  if (lines[0]?.trim() !== 'codex') {
    return undefined
  }

  const said = lines.slice(1).find(line => line.trim() !== '')

  return said === undefined ? undefined : said.trim()
}

const progressLine = (text: string) => {
  const line = text
    .split('\n')
    .map(row => row.replace(/^[#>*\-\s]+/, '').trim())
    .find(row => row !== '')

  return line === undefined ? undefined : line
}

// A launcher holding its repo lock may still be working, even without recent output.
const abandonedRun = async ($: EngineInterface, run: RunView, now: number): Promise<RunView | undefined> => {
  let locks: Entry[] = []
  const lockDir = `${RUNS}\\.locks`
  try { locks = (await $.fs.list(lockDir)) as Entry[] } catch { }

  for (const entry of locks.filter(entry => entry.kind === 'file' && /\.json$/i.test(entry.name))) {
    let owner: { pid?: number; processStartTime?: string; runDir?: string }
    try {
      owner = JSON.parse((await readText($, `${lockDir}\\${entry.name}`)) ?? '')
    } catch { continue }
    if (typeof owner?.runDir !== 'string' || toWindows(owner.runDir).toLowerCase() !== toWindows(run.dir).toLowerCase()) continue
    if (!Number.isInteger(owner.pid) || (owner.pid ?? 0) <= 0 || typeof owner.processStartTime !== 'string') break
    if (now < (launcherAliveUntil.get(run.dir) ?? 0)) return undefined

    let checking = launcherChecks.get(run.dir)
    if (checking === undefined) {
      checking = $.process.run(['pwsh', '-NoProfile', '-NonInteractive', '-Command',
        'try { $ownerProcess = Get-Process -Id ([int]$env:CC_RUN_PID) -ErrorAction Stop; if ($ownerProcess.StartTime.ToUniversalTime() -eq ([datetime]$env:CC_RUN_START).ToUniversalTime()) { exit 0 } } catch { }; exit 1'], {
        env: { CC_RUN_PID: String(owner.pid), CC_RUN_START: owner.processStartTime },
        timeoutMs: 5000,
      }).then(state => state.exitCode === 0).catch(() => true)
      launcherChecks.set(run.dir, checking)
    }
    const alive = await checking
    if (launcherChecks.get(run.dir) === checking) {
      launcherChecks.delete(run.dir)
      if (alive) launcherAliveUntil.set(run.dir, now + MINUTE)
    }
    if (alive) return undefined
    break
  }

  forgetLauncher(run.dir)
  return { ...run, endedAt: now, phase: 'done', outcome: { tone: 'warn', title: 'no outcome', detail: 'the launcher did not write meta.json' } }
}

// A launcher that refuses exits before meta.json; its output may be redirected by the shell.
const launcherRefusal = async ($: EngineInterface, run: RunView, now: number): Promise<RunView | undefined> => {
  if (run.phase !== 'starting') return undefined
  const output = run.output === undefined ? '' : (await readText($, run.output)) ?? ''
  const refusal = (text: string) => /^(?:codex|claude)-run: refused \| (.+)$/m.exec(text)?.[1]
    ?? /^((?:codex|claude)-run\.ps1: (?:Cannot process command because of one or more missing mandatory parameters:|A parameter cannot be found that matches parameter name|Cannot bind parameter)[^\r\n]*)/im.exec(text)?.[1]
  let reason = refusal(output)
  for (const path of new Set([run.launcherOutput, `${run.dir}\\launcher.out`])) {
    if (reason !== undefined) break
    if (path === undefined) continue
    try {
      const entry = (await $.fs.list(parentOf(path))).find(entry => entry.name.toLowerCase() === leafOf(path).toLowerCase())
      if (entry === undefined || entry.mtimeMs < run.launchedAt) continue
      reason = refusal((await readText($, path)) ?? '')
    } catch { }
  }
  const exit = /^exit=(-?\d+)\s*$/m.exec(output)?.[1]
  if (reason === undefined && exit !== undefined && Number(exit) !== 0 && await readText($, `${run.dir}\\meta.json`) === undefined) {
    reason = `exit ${exit} · ${EXITS[Number(exit)]?.title ?? 'the launcher did not write meta.json'}`
  }
  if (reason === undefined) return undefined
  forgetLauncher(run.dir)

  return { ...run, endedAt: now, phase: 'done', outcome: { tone: 'bad', title: 'refused', detail: reason.trim() } }
}

// One look at a run directory: a single listing, then only the files whose state changed.
const probe = async ($: EngineInterface, run: RunView, now: number): Promise<RunView> => {
  const refused = await launcherRefusal($, run, now)
  if (refused !== undefined) return refused

  let entries: Entry[]

  try {
    entries = (await $.fs.list(run.dir)) as Entry[]
  } catch {
    return run
  }

  const file = (name: string) => entries.find(entry => entry.name.toLowerCase() === name)
  const storedMeta = file('meta.json') === undefined ? undefined : await readJson($, `${run.dir}\\meta.json`)
  const metaStartedAt = storedMeta?.startedAt === undefined ? NaN : Date.parse(storedMeta.startedAt)
  const meta = metaStartedAt >= run.launchedAt - 10_000 ? storedMeta : undefined
  const startedAt =
    (meta?.startedAt === undefined ? undefined : Date.parse(meta.startedAt)) ??
    file('executor-prompt.md')?.mtimeMs ??
    file('task-usage-start.json')?.mtimeMs ??
    run.startedAt

  if (typeof meta?.endedAt === 'string') {
    forgetLauncher(run.dir)
    narrated.delete(run.dir)
    const final = await artifacts($, run.dir, meta)

    return {
      ...run,
      model: meta.model ?? run.model,
      effort: meta.reasoningEffort ?? meta.effort ?? run.effort,
      startedAt,
      endedAt: Date.parse(meta.endedAt),
      phase: 'done',
      outcome: outcomeOf(final),
      fixLoop: final.fixLoop,
      costUsd: final.totalCostUsd,
      flaky: final.gate?.flaky,
    }
  }

  const abandoned = await abandonedRun($, { ...run, startedAt }, now)
  if (abandoned !== undefined) {
    narrated.delete(run.dir)
    return abandoned
  }

  const isStarted = startedAt !== undefined && (file('executor-prompt.md') !== undefined || meta !== undefined)
  const attempts = entries.flatMap(entry => /^gate\.attempt(\d+)\.log$/i.exec(entry.name)?.[1] ?? [])
  const attempt = attempts.length === 0 ? undefined : Math.max(...attempts.map(Number)) + (file('gate.log') === undefined ? 0 : 1)
  const gateLog = file('gate.log') ?? (attempt === undefined ? undefined : file(`gate.attempt${attempt}.log`))
  const finished = run.provider === 'codex' ? file('codex.log') : undefined
  const phase = gateLog !== undefined || finished !== undefined ? 'gate' : isStarted ? 'running' : 'starting'
  const progress = file('progress.md') === undefined ? undefined : progressLine((await readText($, `${run.dir}\\progress.md`)) ?? '')
  const live = file('codex.stderr.log')
  const seen = narrated.get(run.dir)
  let line = seen?.line ?? progress

  if (live !== undefined && (seen === undefined || (live.size !== seen.size && now - seen.at >= NARRATION_MS))) {
    const said = narrationOf((await readText($, `${run.dir}\\codex.stderr.log`)) ?? '')

    line = said ?? line
    narrated.set(run.dir, { size: live.size, at: now, line })
  }

  return {
    ...run,
    model: meta?.model ?? run.model,
    effort: meta?.reasoningEffort ?? meta?.effort ?? run.effort,
    startedAt: isStarted ? startedAt : undefined,
    phase,
    gateAttempt: attempt,
    fixLoop: meta?.fixLoop ?? run.fixLoop,
    phaseFrom: phase === 'gate' ? (run.phase === 'gate' ? run.phaseFrom : (finished?.mtimeMs ?? now)) : undefined,
    line: line ?? run.line,
  }
}

const hashOf = (text: string) => {
  let hash = 5381

  for (let i = 0; i < text.length; i++) {
    hash = ((hash << 5) + hash + text.charCodeAt(i)) | 0
  }

  return (hash >>> 0).toString(36)
}

// The end of a run, said once: a line in the terminal and a Windows notification.
const announce = async ($: EngineInterface, run: RunView) => {
  const outcome = run.outcome

  if (outcome === undefined || announced.has(run.dir)) {
    return
  }
  announced.add(run.dir)
  forgetLauncher(run.dir)

  const who = PROVIDER[run.provider].name
  const took = run.startedAt === undefined || run.endedAt === undefined ? undefined : span(run.endedAt - run.startedAt)
  const succeeded = outcome.tone === 'ok' || run.flaky === true
  const title = succeeded ? `${who} finished · ${run.topic}` : `${who} stopped · ${run.topic}`
  const text = [outcome.title, outcome.detail, took].filter(part => part !== undefined).join(' · ')

  $.ui.toast(`${succeeded ? GLYPH.ok : GLYPH.bad} ${who} · ${clip(run.topic, 36)} · ${text}`, { timeoutMs: 10_000 })

  if (!hasToasts) {
    return
  }

  const script = `${$.plugin.root}/scripts/notify.ps1`.replace(/\//g, '\\')

  await $.process
    .run(['powershell.exe', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', script], {
      env: {
        CC_NOTIFY_TOAST: 'show',
        CC_NOTIFY_KIND: succeeded ? 'done' : 'error',
        CC_NOTIFY_TITLE: title,
        CC_NOTIFY_TEXT: text,
        CC_NOTIFY_FOLDER: folder,
        CC_NOTIFY_TAG: `run-${hashOf(run.dir)}`,
        CC_NOTIFY_SOUND: hasSound ? '1' : '0',
      },
      timeoutMs: 20_000,
    })
    .catch(() => undefined)
}

const poll = async ($: EngineInterface) => {
  if (isPolling || hub === '') {
    return
  }

  isPolling = true

  try {
    const now = await $.clock.now()
    const runs = await read($, runsView)
    const before = new Map(runs.map(run => [run.dir, run]))
    const next = new Map<string, RunView>()

    for (const run of runs) {
      if (run.phase === 'done') {
        if (run.endedAt === undefined || now - run.endedAt < KEEP_MS) {
          next.set(run.dir, run)
        }

        continue
      }

      const seen = await locate($, run, now)

      if (seen === undefined) {
        continue
      }

      const probed = await probe($, seen, now)

      next.set(run.dir, probed)

      if (probed.phase === 'done') {
        await announce($, probed)
      }
    }

    await update($, runsView, current => current.flatMap(run => {
      const previous = before.get(run.dir)
      if (previous === undefined || run.launchedAt !== previous.launchedAt ||
          (run.phase === 'done' && previous.phase !== 'done')) return [run]
      const probed = next.get(run.dir)
      return probed === undefined ? [] : [run.phase === 'done' && probed.phase !== 'done' ? run : probed]
    }))
  } finally {
    isPolling = false
  }
}

// A run whose directory is still a guess settles on the first candidate the launcher wrote
// after the launch; one that never appears is dropped after five minutes.
const locate = async ($: EngineInterface, run: RunView, now: number): Promise<RunView | undefined> => {
  if (run.candidates === undefined || run.candidates.length === 0) {
    return run
  }

  for (const dir of run.candidates) {
    try {
      const entries = (await $.fs.list(dir)) as Entry[]
      const newest = Math.max(0, ...entries.map(entry => entry.mtimeMs))

      if (newest >= run.launchedAt - 10_000) {
        const { candidates: _, ...known } = run

        return { ...known, dir, topic: topicOf(dir), repo: leafOf(parentOf(dir)) }
      }
    } catch {
      // Not written yet.
    }
  }

  return now - run.launchedAt > 5 * MINUTE ? undefined : run
}

const topicOf = (dir: string) => leafOf(dir).replace(/^\d{4}-\d{2}-\d{2}-/, '')

const outputOf = (text: string | undefined) => /Output is being written to: (.+?\.output)\b/.exec(text ?? '')?.[1]

const track = async ($: EngineInterface, command: string, provider: RunProvider, dirs: string[], now: number, output?: string) => {
  if (dirs.length === 0) {
    return
  }

  const minutes = Number(argOf(command, 'TimeoutMinutes') ?? DEFAULT_TIMEOUT[provider])
  const dir = dirs[0] ?? ''
  const redirect = /(?:\*>|(?<!>)>)(?![>&])\s*(?:"([^"]+)"|'([^']+)'|([^\s;|&]+))/.exec(command)
  const target = redirect?.[1] ?? redirect?.[2] ?? redirect?.[3]
  const launcherOutput = target === undefined ? undefined : await fullPath($, target).catch(() => undefined)
  announced.delete(dir)
  const run: RunView = {
    dir,
    provider,
    model: argOf(command, 'Model') ?? (provider === 'codex' ? 'gpt-6.2-sol' : 'claude-opus-5-5'),
    effort: argOf(command, provider === 'codex' ? 'ReasoningEffort' : 'Effort') ?? (provider === 'codex' ? 'medium' : 'high'),
    repo: leafOf(parentOf(dir)),
    worktree: provider === 'codex' && hasFlag(command, 'ReadOnly') ? '' : worktreeOf(command),
    topic: topicOf(dir),
    launchedAt: now,
    timeoutMs: (Number.isFinite(minutes) ? minutes : DEFAULT_TIMEOUT[provider]) * MINUTE,
    phase: 'starting',
    fixLoop: Number(argOf(command, 'FixLoop') ?? 0),
    ...(dirs.length > 1 ? { candidates: dirs } : {}),
    ...(output === undefined ? {} : { output }),
    ...(launcherOutput === undefined ? {} : { launcherOutput }),
  }

  await update($, runsView, runs => [...runs.filter(other => other.dir !== dir), run])
  $.clock.after(1500, () => {
    void poll($)
  })
}

const busyIn = (runs: readonly RunView[], worktree: string) =>
  worktree === '' ? undefined : runs.find(run => run.phase !== 'done' && run.worktree === worktree)

const launch = async ($: EngineInterface, command: string) => {
  const launcher = launcherOf(command)

  if (!isInteractive || launcher === undefined) {
    return { kind: 'pass' as const }
  }

  if (hasFlag(command, 'DryRun')) {
    return { kind: 'pass' as const }
  }
  const provider = launcher.provider

  if (hasGuard) {
    const worktree = worktreeOf(command)
    const runs = await read($, runsView)
    const now = await $.clock.now()

    for (const run of runs.filter(run => run.phase !== 'done' && worktree !== '' && run.worktree === worktree)) {
      const seen = await locate($, run, now)
      const probed = seen === undefined ? undefined : await probe($, seen, now)
      await update($, runsView, current => current.flatMap(other => other.dir !== run.dir || other.phase === 'done' || other.launchedAt !== run.launchedAt
        ? [other] : (probed === undefined ? [] : [probed])))
      if (probed?.phase === 'done') await announce($, probed)
    }

    const refusal = refusalOf(command, provider, busyIn(await read($, runsView), worktree))

    if (refusal !== undefined) {
      return { kind: 'deny' as const, reason: refusal }
    }
  }

  return { kind: 'track' as const, provider, launchedAt: await $.clock.now(), dirs: await runDirsOf($, command, await $.clock.now()).catch(() => []), guarded: hasGuard }
}

// ─── the runs pane ───────────────────────────────────────────────────────────

const summarize = async ($: EngineInterface, dir: string, now: number): Promise<RunView | undefined> => {
  let entries: Entry[]

  try {
    entries = (await $.fs.list(dir)) as Entry[]
  } catch {
    return undefined
  }

  const file = (name: string) => entries.find(entry => entry.name.toLowerCase() === name)
  const meta = file('meta.json') === undefined ? undefined : await readJson($, `${dir}\\meta.json`)
  const isCodex = (meta?.model ?? '').startsWith('gpt') || file('codex.log') !== undefined || file('codex.stderr.log') !== undefined
  const isClaude = (meta?.model ?? '').startsWith('claude') || file('claude.stderr.log') !== undefined || file('result.json') !== undefined

  if (!isCodex && !isClaude) {
    return undefined
  }

  const provider: RunProvider = isCodex ? 'codex' : 'claude'
  const base: RunView = {
    dir,
    provider,
    model: meta?.model ?? '',
    effort: meta?.reasoningEffort ?? meta?.effort ?? '',
    repo: leafOf(parentOf(dir)),
    topic: topicOf(dir),
    launchedAt: meta?.startedAt === undefined ? (file('executor-prompt.md')?.mtimeMs ?? 0) : Date.parse(meta.startedAt),
    timeoutMs: (meta?.timeoutMinutes ?? DEFAULT_TIMEOUT[provider]) * MINUTE,
    phase: 'running',
  }

  if (typeof meta?.endedAt === 'string') {
    forgetLauncher(dir)
    const final = await artifacts($, dir, meta)
    return { ...base, startedAt: base.launchedAt, endedAt: Date.parse(meta.endedAt), phase: 'done', outcome: outcomeOf(final), fixLoop: final.fixLoop, costUsd: final.totalCostUsd, flaky: final.gate?.flaky }
  }

  const started = { ...base, startedAt: base.launchedAt }
  return (await abandonedRun($, started, now)) ?? started
}

const scan = async ($: EngineInterface) => {
  if (hub === '') {
    await update($, catalog, () => [])
    return
  }
  const now = await $.clock.now()
  const cutoff = now - 14 * 24 * 60 * MINUTE
  const found: RunView[] = []
  let repos: Entry[] = []

  try {
    repos = (await $.fs.list(RUNS)) as Entry[]
  } catch {
    await update($, catalog, () => [])

    return
  }

  for (const repo of repos.filter(entry => entry.kind === 'dir')) {
    let entries: Entry[] = []

    try {
      entries = (await $.fs.list(`${RUNS}\\${repo.name}`)) as Entry[]
    } catch {
      continue
    }

    for (const entry of entries) {
      const date = /^(\d{4}-\d{2}-\d{2})-/.exec(entry.name)

      if (entry.kind !== 'dir' || date === null || Date.parse(date[1] ?? '') < cutoff) {
        continue
      }

      const run = await summarize($, `${RUNS}\\${repo.name}\\${entry.name}`, now)

      if (run !== undefined) {
        found.push(run)
      }
    }
  }

  found.sort((a, b) => (b.startedAt ?? b.launchedAt) - (a.startedAt ?? a.launchedAt))
  await update($, catalog, () => found.slice(0, 30))
}

// Codex's live or final log as the pane shows it: what it said, what it ran, how that went.
const logLines = (log: string): RunLine[] => {
  const lines = log.split(/\r?\n/)
  const out: RunLine[] = []

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i]?.trim() ?? ''

    if (line === 'codex') {
      const said = lines.slice(i + 1).find(row => row.trim() !== '')

      if (said !== undefined) {
        out.push({ tone: 'say', text: said.trim() })
      }
    } else if (line === 'exec') {
      const command = (lines[i + 1] ?? '').trim().replace(/^"[^"]*pwsh\.exe"\s+-Command\s+/i, '')

      out.push({ tone: 'cmd', text: clip(command.replace(/^["']|["']$/g, ''), 160) })
    } else {
      const done = /^(succeeded|exited (\d+)) in (\d+)ms/.exec(line)

      if (done !== null) {
        const ms = Number(done[3])
        const took = ms >= 1000 ? `${(ms / 1000).toFixed(1)}s` : `${ms}ms`

        out.push(done[2] === undefined ? { tone: 'ok', text: took } : { tone: 'bad', text: `exit ${done[2]} · ${took}` })
      }
    }
  }

  return out.slice(-120)
}

const openRun = async ($: EngineInterface, dir: string, tab: RunTab) => {
  const detail: RunDetail = { dir, tab }
  const missing = (name: string) => ({ ...detail, missing: `${name} is unavailable.` })
  let next: RunDetail

  if (tab === 'report') {
    const text = await readText($, `${dir}\\report.md`)

    next = text === undefined ? missing('report.md') : { ...detail, markdown: clip(text, 9800) }
  } else if (tab === 'progress') {
    const text = await readText($, `${dir}\\progress.md`)

    next = text === undefined ? missing('progress.md') : { ...detail, markdown: clip(text, 9800) }
  } else if (tab === 'brief') {
    // The latest attempt's brief: a fix brief launched into the run directory leaves brief.md as the first one.
    const brief = (await readJson($, `${dir}\\meta.json`))?.brief
    const text = (brief === undefined ? undefined : await readText($, brief)) ?? (await readText($, `${dir}\\brief.md`))

    next = text === undefined ? missing('brief.md') : { ...detail, markdown: clip(text, 9800) }
  } else if (tab === 'gate') {
    const gate = (await readJson($, `${dir}\\gate.json`)) as { command?: string; exitCode?: number; tail?: string } | undefined
    const meta = await readJson($, `${dir}\\meta.json`)
    const tail = gate?.tail ?? meta?.gate?.tail

    next = tail === undefined ? missing('gate.json') : { ...detail, code: clip(tail, 9800) }
  } else {
    const live = (await readText($, `${dir}\\codex.stderr.log`)) ?? (await readText($, `${dir}\\codex.log`))

    next = live === undefined ? missing('The Codex log') : { ...detail, lines: logLines(live) }
  }

  await update($, detailView, () => next)
  await update($, paneView, (): RunsPane => ({ mode: 'run', dir, tab }))
  await $.ui.open({ id: PANE, title: 'Executors', focus: true, columns: 100 })
}

const openList = async ($: EngineInterface) => {
  await update($, paneView, (): RunsPane => ({ mode: 'list' }))
  await $.ui.open({ id: PANE, title: 'Executors', focus: true, columns: 100 })
  await scan($)
}

const dismiss = async ($: EngineInterface, dir: string) => {
  await update($, runsView, runs => runs.filter(run => run.dir !== dir))
}

export const registerRuns = (on: On, options: PluginOptions) => {
  hasGuard = options.launchGuard !== false
  hasToasts = options.windowsNotification !== false
  hasSound = options.sound !== false

  on('session.start', { isInteractive: true }, async ($, e, next) => {
    isInteractive = true
    hub = await read($, pipelineHome)
    RUNS = hub === '' ? '' : `${hub}\\runs`
    folder = e.cwd.split(/[\\/]/).filter(Boolean).at(-1) ?? e.cwd
    await $.command.register({ name: 'runs', description: 'Open a pane with pipeline executor runs, reports, logs, and gates' })
    $.clock.every(POLL_MS, () => {
      void poll($)
    })

    return next(e)
  })

  on('command.run', { command: 'runs' }, async $ => {
    await openList($)

    return { text: 'Opened the executor pane.' }
  })

  on('tool.call', { tool: 'Bash' }, async ($, e, next) => {
    const plan = await launch($, e.command)

    if (plan.kind === 'pass') {
      return next(e)
    }

    if (plan.kind === 'deny') {
      return { deny: plan.reason }
    }

    const result = await next(plan.guarded ? { ...e, run_in_background: true, timeout: Math.max(e.timeout ?? 0, 7200000) } : e)

    if (!('deny' in result) && result.isError !== true) {
      await track($, e.command, plan.provider, plan.dirs, plan.launchedAt, outputOf(result.text))
    }

    return result
  })

  on('tool.call', { tool: 'PowerShell' }, async ($, e, next) => {
    const plan = await launch($, e.command)

    if (plan.kind === 'pass') {
      return next(e)
    }

    if (plan.kind === 'deny') {
      return { deny: plan.reason }
    }

    const result = await next(plan.guarded ? { ...e, run_in_background: true, timeout: Math.max(e.timeout ?? 0, 7200000) } : e)

    if (!('deny' in result) && result.isError !== true) {
      await track($, e.command, plan.provider, plan.dirs, plan.launchedAt, outputOf(result.text))
    }

    return result
  })

  // A lane per run: running ones animate, finished ones keep their verdict until dismissed.
  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    if (e.surface !== 'terminal' || e.props.hasSurvey || !isInteractive) {
      return next(e)
    }

    const below = await next(e)
    const all = await read($, runsView)
    const runs = all.slice(-3)
    if (runs.length === 0) return below
    const { Box, Button, Client, Text } = $.ui.resolve(e)
    const now = await $.clock.now()
    const whoWidth = 18
    const topicWidth = Math.min(30, Math.floor(e.props.bodyColumns / 4))
    const lanes = runs.map((run, index) => {
      const look = PROVIDER[run.provider]
      const isFirst = index === runs.length - 1
      const done = run.phase === 'done'
      const who = <Box width={whoWidth} flexShrink={0}><Text dimColor={done} wrap="truncate-end">
        <Text {...(done ? { dimColor: true } : { color: look.color })}>{look.glyph}</Text> {run.provider}
        <Text dimColor> {shortModel(run.model)}{run.effort === '' ? '' : `·${run.effort}`}</Text>
      </Text></Box>
      const topic = <Box width={topicWidth} flexShrink={0}><Text bold={!done} dimColor={done} wrap="truncate-end">{run.topic}</Text></Box>
      if (!done) return <Box key={run.dir} flexDirection="column">
        <Box flexDirection="row" columnGap={1}>
          {who}{topic}
          <Box flexGrow={1} minWidth={0} justifyContent="flex-end">
            <Client key={`clock:${run.dir}`} module="./run-clock.tsx" props={{
              from: run.phaseFrom ?? run.startedAt ?? run.launchedAt, now, phase: run.phase,
              color: look.color, timeoutMs: run.timeoutMs,
              isNarrow: e.props.bodyColumns - whoWidth - topicWidth < 38,
            }} />
          </Box>
        </Box>
        {run.line === undefined && (run.fixLoop ?? 0) === 0 && run.gateAttempt === undefined ? null : <Text dimColor wrap="truncate-end">
          {'    └ '}{[(run.fixLoop ?? 0) >= 1 ? `fix ${run.fixLoop}` : undefined, run.phase === 'gate' && run.gateAttempt !== undefined ? `gate · attempt ${run.gateAttempt}` : undefined, run.line].filter(part => part !== undefined).join(' · ')}
        </Text>}
      </Box>
      const outcome = run.outcome ?? { tone: 'warn' as const, title: 'no outcome' }
      const took = run.startedAt === undefined || run.endedAt === undefined ? '' : span(run.endedAt - run.startedAt)
      return <Box key={run.dir} flexDirection="row" columnGap={1}>
        <Text color={COLOR[outcome.tone]}>{outcome.tone === 'ok' || run.flaky ? GLYPH.ok : GLYPH.bad}</Text>
        {who}{topic}
        <Box flexGrow={1} flexShrink={1} minWidth={0}><Text dimColor wrap="truncate-end">
          <Text dimColor>{outcome.title}</Text>
          <Text dimColor>{outcome.detail === undefined ? '' : ` · ${outcome.detail}`}{(run.fixLoop ?? 0) >= 1 ? ` · fix ${run.fixLoop}` : ''}{run.endedAt === undefined ? '' : ` · ${coarse(now - run.endedAt)} ago`}</Text>
        </Text></Box>
        <Box width={7} flexShrink={0} justifyContent="flex-end"><Text dimColor>{took}</Text></Box>
        <Box flexShrink={0} flexDirection="row" columnGap={1}>
          <Button key={`report:${run.dir}`} plain dimColor {...(isFirst ? { hotkey: 'r' } : {})} label="report" onPress={() => openRun($, run.dir, 'report')} />
          <Button key={`log:${run.dir}`} plain dimColor {...(isFirst ? { hotkey: 'l' } : {})} label="log" onPress={() => openRun($, run.dir, run.provider === 'codex' ? 'log' : 'progress')} />
          <Button key={`x:${run.dir}`} plain dimColor {...(isFirst ? { hotkey: 'x' } : {})} label="close" onPress={() => dismiss($, run.dir)} />
        </Box>
      </Box>
    })
    return <Box flexDirection="column">
      {lanes}
      {all.length > 3 ? <Text dimColor>{`+${all.length - 3} more · /runs`}</Text> : null}
      {below}
    </Box>
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Button, Code, Markdown, Text } = $.ui.resolve(e)
    const view = await read($, paneView)
    const now = await $.clock.now()
    const rule = <Text dimColor wrap="truncate-end">{'─'.repeat(Math.max(1, e.props.bodyColumns))}</Text>
    const close = <Button key="close" plain dimColor hotkey="q" role="dismiss" label="Close" onPress={() => $.ui.close({ id: PANE })} />

    if (view.mode === 'list') {
      const runs = await read($, catalog)

      return (
        <Box flexDirection="column" rowGap={0}>
          <Box flexDirection="row" columnGap={2} marginBottom={1}>
            <Text bold>Executors</Text>
            <Box key="run-totals"><Text dimColor>
              last 14 days · {runs.length} run · {runs.reduce((sum, run) => sum + (run.fixLoop ?? 0), 0)} fix · {runs.filter(run => run.outcome?.title === 'gate failed' || run.outcome?.title === 'gate timed out').length} failed gates · {runs.filter(run => run.flaky).length} flaky
              {(['codex', 'claude'] as const).map(provider => ` · ${PROVIDER[provider].name} ≈$${runs.filter(run => run.provider === provider).reduce((sum, run) => sum + (run.costUsd ?? 0), 0).toFixed(2)}`)}
            </Text></Box>
            <Button key="scan" plain dimColor hotkey="a" label="refresh" onPress={() => scan($)} />
          </Box>
          {close}{rule}
          {runs.length === 0 ? <Text dimColor>No runs in the last 14 days, or the list is still loading.</Text> : null}
          {runs.map((run, index) => {
            const look = PROVIDER[run.provider]
            const tone = run.phase !== 'done' ? COLOR.info : COLOR[run.outcome?.tone ?? 'warn']
            const mark = run.phase !== 'done' ? GLYPH.half : run.outcome?.tone === 'ok' || run.flaky ? GLYPH.ok : GLYPH.bad
            const pathWidth = Math.max(12, Math.min(40, e.props.bodyColumns - 52))
            const path = `${run.repo} / ${run.topic}`
            const when = clockAt(run.startedAt ?? run.launchedAt, now)
            const took = run.endedAt === undefined || run.startedAt === undefined ? coarse(now - (run.startedAt ?? now)) : span(run.endedAt - run.startedAt)

            return (
              <Box key={`row:${run.dir}`} flexDirection="row" columnGap={1}>
                <Text color={tone}>{mark}</Text>
                <Text color={look.color}>{look.glyph}</Text>
                <Box width={12}>
                  <Text dimColor>
                    {shortModel(run.model) || run.provider}
                    {run.effort === '' ? '' : `·${run.effort}`}
                  </Text>
                </Box>
                <Box width={pathWidth} flexShrink={0}>
                  <Button key={`open:${run.dir}`} plain {...(index < 9 ? { hotkey: String(index + 1) } : {})} label={path.length > pathWidth ? `…${path.slice(-(pathWidth - 1))}` : path} onPress={() => openRun($, run.dir, 'report')} />
                </Box>
                <Box width={10} justifyContent="flex-end">
                  <Text dimColor>{when}</Text>
                </Box>
                <Box width={6} justifyContent="flex-end">
                  <Text dimColor>{took}</Text>
                </Box>
                <Box width={8} justifyContent="flex-end"><Text dimColor>{run.costUsd === undefined ? '' : `≈$${run.costUsd.toFixed(2)}`}</Text></Box>
                <Box flexGrow={1} flexShrink={1} minWidth={0}><Text color={tone} wrap="truncate-end">
                  {run.phase !== 'done' ? 'in progress' : (run.outcome?.title ?? '')}
                  {run.outcome?.detail === undefined ? '' : ` · ${run.outcome.detail}`}
                  {(run.fixLoop ?? 0) >= 1 ? ` · fix ${run.fixLoop}` : ''}
                </Text></Box>
              </Box>
            )
          })}
        </Box>
      )
    }

    const runs = [...(await read($, runsView)), ...(await read($, catalog))]
    const run = runs.find(one => one.dir === view.dir)
    const detail = await read($, detailView)
    const look = run === undefined ? undefined : PROVIDER[run.provider]
    const outcome = run?.outcome
    const body =
      detail === null || detail.dir !== view.dir || detail.tab !== view.tab ? (
        <Text dimColor>{GLYPH.wait}</Text>
      ) : detail.missing !== undefined ? (
        <Text dimColor>{detail.missing}</Text>
      ) : detail.markdown !== undefined ? (
        <Markdown text={detail.markdown} />
      ) : detail.code !== undefined ? (
        <Code source={detail.code} language="text" />
      ) : (
        <Box flexDirection="column">
          {(detail.lines ?? []).map(line =>
            line.tone === 'say' ? (
              <Text wrap="wrap">{line.text}</Text>
            ) : line.tone === 'cmd' ? (
              <Text dimColor wrap="truncate-end">
                {'  $ '}
                {line.text}
              </Text>
            ) : (
              <Text color={line.tone === 'ok' ? COLOR.ok : COLOR.bad}>
                {'    '}
                {line.tone === 'ok' ? GLYPH.ok : GLYPH.bad} {line.text}
              </Text>
            ),
          )}
        </Box>
      )

    return (
      <Box flexDirection="column">
        <Box flexDirection="row" columnGap={2}>
          <Button key="back" plain dimColor hotkey="e" label="← list" onPress={() => openList($)} />
          {look === undefined || run === undefined ? null : (
            <Text>
              <Text color={look.color}>{look.glyph}</Text>
              <Text bold> {run.topic}</Text>
              <Text dimColor>
                {' '}
                · {run.repo} · {shortModel(run.model)}
                {run.effort === '' ? '' : `·${run.effort}`}
              </Text>
            </Text>
          )}
        </Box>
        {close}{rule}
        {run === undefined ? null : (
          <Text dimColor>
            {run.startedAt === undefined ? 'not started yet' : `started ${clockAt(run.startedAt, now)}`}
            {run.endedAt === undefined || run.startedAt === undefined ? (run.phase === 'done' ? '' : ' · in progress') : ` · ${span(run.endedAt - run.startedAt)}`}
            {outcome === undefined ? '' : ` · ${outcome.title}${outcome.detail === undefined ? '' : ` (${outcome.detail})`}`}
            {(run.fixLoop ?? 0) >= 1 ? ` · fix ${run.fixLoop}` : ''}
          </Text>
        )}
        <Box flexDirection="row" columnGap={1} marginY={1}>
          {TABS.map(item =>
            item.tab === view.tab ? (
              <Button key={`tab:${item.tab}`} variant="primary" hotkey={item.key} label={item.label} onPress={() => openRun($, view.dir, item.tab)} />
            ) : (
              <Button key={`tab:${item.tab}`} plain dimColor hotkey={item.key} label={item.label} onPress={() => openRun($, view.dir, item.tab)} />
            ),
          )}
        </Box>
        {rule}
        {body}
      </Box>
    )
  })
}
