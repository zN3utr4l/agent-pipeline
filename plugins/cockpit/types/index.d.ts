/** The main thread's prompt cache, as the meter lane draws it. */
export type CacheView = {
  /** When the last main-thread request went out; null before the first. */
  sentAt: number | null
  ttlMs: number
  ttlLabel: '5m' | '1h'
  /** How long before expiry the chip turns amber. */
  warnMs: number
  hitPercent?: number
  contextTokens: number
  /** Past the big-context threshold: expiry advises a new chat or /compact. */
  isBig: boolean
  /** Written afresh by the next request whatever the clock says. */
  cold?: 'model' | 'compact'
}

export type ClaudeLimit = { kind: string; percentUsed: number; resetsAt?: string }

export type CodexWindow = { label: string; usedPct: number; resetsAt?: string }

/** The last codeburn reading of the Codex plan. */
export type CodexQuota = { windows: CodexWindow[]; fetchedAt: number; error?: string }

export type RunProvider = 'codex' | 'claude'

/** Starting until the executor's files appear, gate while the launcher's post-run gate runs. */
export type RunPhase = 'starting' | 'running' | 'gate' | 'done'

export type RunOutcome = { tone: 'ok' | 'warn' | 'bad'; title: string; detail?: string }

/** One executor run, from its run directory under the hub. */
export type RunView = {
  dir: string
  provider: RunProvider
  model: string
  effort: string
  repo: string
  /** The launch's -Repo, lowercased: one executor per worktree. */
  worktree?: string
  topic: string
  launchedAt: number
  startedAt?: number
  endedAt?: number
  timeoutMs: number
  phase: RunPhase
  fixLoop?: number
  costUsd?: number
  flaky?: boolean
  gateAttempt?: number
  /** When the gate phase began, for its own clock. */
  phaseFrom?: number
  /** Where the launcher may write until one of them appears (base, base-2, base-3). */
  candidates?: string[]
  /** What the executor last said: Codex's narration, else progress.md. */
  line?: string
  /** The launch's background output file, read while starting for a launcher refusal. */
  output?: string
  /** Explicit shell redirect target for the launcher's output. */
  launcherOutput?: string
  outcome?: RunOutcome
}

export type RunTab = 'report' | 'log' | 'progress' | 'gate' | 'brief'

export type RunsPane = { mode: 'list' } | { mode: 'run'; dir: string; tab: RunTab }

export type RunLine = { tone: 'say' | 'cmd' | 'ok' | 'bad'; text: string }

/** The open tab of one run in the pane. */
export type RunDetail = { dir: string; tab: RunTab; markdown?: string; code?: string; lines?: RunLine[]; missing?: string }

/** Where an open pull request stands, worst first. */
export type PrVerdict =
  | 'conflict'
  | 'ci-red'
  | 'changes'
  | 'ci-running'
  | 'codex-stale'
  | 'codex-comments'
  | 'codex-waiting'
  | 'review'
  | 'draft'
  | 'ready'

export type PrRow = { repo: string; number: number; title: string; url: string; verdict: PrVerdict; codexAt?: string; author?: string }

/** The last fetch of the account's open pull requests. */
export type PrFeed = {
  login: string
  rows: PrRow[]
  /** All open pull requests, `rows` holding the most recently updated. */
  total: number
  reviewTotal?: number
  fetchedAt: number
  /** Why the last fetch failed; `rows` are then the previous ones. */
  error?: string
}

/** The PR lane's own state: open or not, and the reviews asked of Codex by URL. */
export type PrUi = { isExpanded: boolean; isHidden: boolean; asked: Record<string, number>; confirming?: string }

declare module 'claude-code' {
  interface PluginState {
    cockpit: {
      pipelineHome: string
      cache: CacheView | null
      limits: ClaudeLimit[]
      codex: CodexQuota | null
      minute: number
      runs: RunView[]
      catalog: RunView[]
      pane: RunsPane
      detail: RunDetail | null
      prs: PrFeed | null
      prUi: PrUi
    }
  }
}
