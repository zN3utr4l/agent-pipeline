import { atom, read, update } from 'claude-code'
import type { EngineInterface, On, PluginOptions, SessionRateLimit } from 'claude-code'

import type { CacheView, ClaudeLimit, CodexQuota, CodexWindow } from '../types'
import { clockAt, coarse, COLOR, gauge, GLYPH, MINUTE, span, tokens, toneOf } from './look'

const pipelineHome = { plugin: 'cockpit', key: 'pipelineHome' } as const

// The meter lane: the prompt cache, when the Claude windows reset, and the Codex plan.

// What the lanes draw from; this module is the only writer.
const cacheView = atom({ plugin: 'cockpit', key: 'cache' } as const, null)
const limitsView = atom({ plugin: 'cockpit', key: 'limits' } as const, [])
const codexView = atom({ plugin: 'cockpit', key: 'codex' } as const, null)
const minute = atom({ plugin: 'cockpit', key: 'minute' } as const, 0)

const TTL_MS = { '5m': 5 * MINUTE, '1h': 60 * MINUTE } as const
const COLD = { model: 'model changed', compact: 'after compaction' } as const
const NAMES: Record<string, string> = { five_hour: '5h', seven_day: '7d', spend_limit: 'spend' }
const CODEX_NAMES: Record<string, string> = { '5-hour': '5h', Weekly: '7d' }
const STEPS = [80, 90, 100] as const

// The launcher refuses a Codex run past 85% of any window.
const CODEX_CAP = 85
let quotaCache = ''
let hasCodeburn = false

type Ttl = keyof typeof TTL_MS
type Mark = { at: number; contextTokens: number; hitPercent?: number; cold?: 'model' | 'compact' }
type Answer = { providers?: { id?: string; available?: boolean; windows?: CodexWindow[] }[] }

let ttlOption = 'auto'
let warnMs = 5 * MINUTE
let bigContext = 150_000
let compactWindow: number | undefined
let modelWindow = 0
let codexEvery = 10 * MINUTE

let isInteractive = false
let mark: Mark | null = null
let limits: ClaudeLimit[] = []
let ttlSeen: Ttl | undefined
let warnedFor = -1
let isReading = false

const ttl = (): Ttl => {
  if (ttlOption === '1h' || ttlOption === '5m') {
    return ttlOption
  }

  if (ttlSeen !== undefined) {
    return ttlSeen
  }

  // A subscription window at 100% means overage, where requests drop to the 5-minute TTL.
  return limits.some(l => l.kind !== 'spend_limit' && l.percentUsed >= 100) ? '5m' : '1h'
}

const warnWithin = () => Math.min(warnMs, TTL_MS[ttl()] / 5)

const viewOf = (): CacheView | null =>
  mark === null
    ? null
    : {
        sentAt: mark.at,
        ttlMs: TTL_MS[ttl()],
        ttlLabel: ttl(),
        warnMs: warnWithin(),
        hitPercent: mark.hitPercent,
        contextTokens: mark.contextTokens,
        isBig: mark.contextTokens >= bigContext,
        cold: mark.cold,
      }

const publish = async ($: EngineInterface, next: Mark | null) => {
  mark = next
  await update($, cacheView, () => viewOf())
}

// Every quarter minute: the cache warning when it is due, and the minute the resets count by.
const tick = async ($: EngineInterface) => {
  const now = await $.clock.now()
  const at = Math.floor(now / MINUTE)

  if ((await read($, minute)) !== at) {
    await update($, minute, () => at)
  }

  if (mark === null || mark.cold !== undefined || warnMs <= 0 || warnedFor === mark.at) {
    return
  }

  const left = mark.at + TTL_MS[ttl()] - now

  if (left > 0 && left <= warnWithin()) {
    warnedFor = mark.at
    $.ui.toast(`${GLYPH.half} Cache · expiring in ${span(left)}`, {
      timeoutMs: 10_000,
    })
  }
}

const report = (now: number) => {
  if (mark === null) {
    return 'Prompt cache: no main-thread requests yet.'
  }

  const left = mark.at + TTL_MS[ttl()] - now
  const label = ttlOption === 'auto' ? `${ttl()}, auto` : ttl()
  const hit = mark.hitPercent === undefined ? '' : `, ${mark.hitPercent}% read from cache`
  const lines = [`Prompt cache (TTL ${label})`, `  last request: ${span(now - mark.at)} ago${hit}`]

  if (mark.cold !== undefined) {
    lines.push(`  cold: ${COLD[mark.cold]}. The next message will rewrite it.`)
  } else {
    lines.push(left > 0 ? `  expires in ${span(left)} (at ${clockAt(now + left, now)})` : `  expired ${span(-left)} ago`)
  }

  if (mark.cold !== undefined || left <= 0) {
    lines.push(
      mark.contextTokens >= bigContext
        ? `  Tip: the next message will rewrite ${tokens(mark.contextTokens)} cache tokens. Start a new chat (or use /clear) if you are changing topics. Consider /compact if you need this context.`
        : '  Tip: the context is small, so continuing here costs little.',
    )
  } else if (left <= warnWithin()) {
    lines.push('  Tip: send a message now to continue with this context.')
  } else {
    lines.push('  Tip: the cache is warm. Continuing here costs only the new tokens.')
  }

  return lines.join('\n')
}

const limitName = (limit: { kind: string }) => NAMES[limit.kind] ?? limit.kind

const limitWarning = (limit: SessionRateLimit, step: number, now: number) => {
  const left = limit.resetsAt === undefined ? undefined : Date.parse(limit.resetsAt) - now
  const reset = left === undefined ? '' : ` · resets in ${coarse(left)}`

  return step < 100
    ? `${GLYPH.dot} Quota ${limitName(limit)} · ${limit.percentUsed}%${reset}`
    : `${GLYPH.bad} Quota ${limitName(limit)} · exhausted${reset} · 5m cache with extra usage`
}

// One toast per window, step and reset, across sessions: the store remembers which went out.
const warnLimits = async ($: EngineInterface, readings: readonly SessionRateLimit[], now: number) => {
  const stored = await $.store.get('warned')
  const warned = new Set(Array.isArray(stored) ? stored.map(String) : [])
  const before = warned.size

  for (const limit of readings) {
    const crossed = STEPS.filter(step => limit.percentUsed >= step)
    const top = crossed.at(-1)
    const left = limit.resetsAt === undefined ? undefined : Date.parse(limit.resetsAt) - now

    if (top === undefined || (left !== undefined && left <= 0)) {
      continue
    }

    const key = (step: number) => `${limit.kind}@${limit.resetsAt ?? ''}:${step}`

    if (!warned.has(key(top))) {
      $.ui.toast(limitWarning(limit, top, now), { timeoutMs: 10_000 })
    }

    crossed.forEach(step => warned.add(key(step)))
  }

  if (warned.size !== before) {
    await $.store.set('warned', [...warned].slice(-60))
  }
}

// codeburn answers in about twenty seconds (it asks the provider), so it runs in the background.
const quotaOf = (answer: Answer, fetchedAt: number): CodexQuota => {
  const provider = answer.providers?.find(provider => provider.id === 'codex')
  const windows = (provider?.windows ?? []).filter(window => typeof window.usedPct === 'number' && Number.isFinite(window.usedPct))
  return provider?.available === true && windows.length > 0
    ? { windows, fetchedAt }
    : { windows: [], fetchedAt, error: 'codeburn could not find a Codex plan' }
}

const sharedQuota = async ($: EngineInterface): Promise<CodexQuota | undefined> => {
  if (quotaCache === '') return undefined
  try {
    const saved = JSON.parse((await $.fs.read(quotaCache)).replace(/^\uFEFF/, '')) as { fetchedAtUtc: string; quota: Answer }
    const fetchedAt = Date.parse(saved.fetchedAtUtc)
    const age = (await $.clock.now()) - fetchedAt
    const quota = quotaOf(saved.quota, fetchedAt)
    return Number.isFinite(age) && age >= -5000 && age < codexEvery && quota.error === undefined ? quota : undefined
  } catch {
    return undefined
  }
}

const readCodex = async ($: EngineInterface) => {
  if (isReading || !hasCodeburn) {
    return
  }

  isReading = true

  try {
    const cached = await sharedQuota($)
    if (cached !== undefined) {
      await update($, codexView, () => cached)
      await warnCodex($, cached, await $.clock.now())
      return
    }
    const run = await $.process.run(['cmd.exe', '/d', '/s', '/c', 'codeburn.cmd quota --format json --no-color'], {
      env: { NODE_USE_ENV_PROXY: '1', NO_COLOR: '1' },
      timeoutMs: 90_000,
    })
    const fetchedAt = await $.clock.now()
    const previous = await read($, codexView)

    if (run.exitCode !== 0) {
      const error = run.stderr.trim().split('\n')[0]?.slice(0, 120) || `codeburn exited with ${run.exitCode}`

      await update($, codexView, () => ({ windows: previous?.windows ?? [], fetchedAt: previous?.fetchedAt ?? fetchedAt, error }))

      return
    }

    const answer = JSON.parse(run.stdout) as Answer
    const next = quotaOf(answer, fetchedAt)

    if (next.error === undefined && quotaCache !== '') {
      await $.fs.write(quotaCache, JSON.stringify({ fetchedAtUtc: new Date(fetchedAt).toISOString(), quota: answer })).catch(() => undefined)
    }

    await update($, codexView, () => next)
    await $.store.set('codex', next)
    await warnCodex($, next, fetchedAt)
  } catch (error) {
    const fetchedAt = await $.clock.now()

    await update($, codexView, previous => ({ windows: previous?.windows ?? [], fetchedAt: previous?.fetchedAt ?? fetchedAt, error: String(error).slice(0, 120) }))
  } finally {
    isReading = false
  }
}

const warnCodex = async ($: EngineInterface, quota: CodexQuota, now: number) => {
  const stored = await $.store.get('codexWarned')
  const warned = new Set(Array.isArray(stored) ? stored.map(String) : [])
  const before = warned.size

  for (const window of quota.windows) {
    const key = `${window.label}@${window.resetsAt ?? ''}`

    if (window.usedPct < CODEX_CAP || warned.has(key)) {
      continue
    }

    const reset = window.resetsAt === undefined ? '' : ` · reset ${clockAt(Date.parse(window.resetsAt), now)}`

    warned.add(key)
    $.ui.toast(`${GLYPH.bad} Quota Codex ${CODEX_NAMES[window.label] ?? window.label} · ${window.usedPct}% · launches blocked above 85%${reset}`, {
      timeoutMs: 12_000,
    })
  }

  if (warned.size !== before) {
    await $.store.set('codexWarned', [...warned].slice(-40))
  }
}

export const registerMeters = (on: On, options: PluginOptions) => {
  ttlOption = String(options.ttl ?? 'auto')
  warnMs = Number(options.warnMinutes ?? 5) * MINUTE
  bigContext = Number(options.bigContextK ?? 150) * 1000
  codexEvery = Number(options.codexQuotaMinutes ?? 10) * MINUTE

  on('session.start', { isInteractive: true }, async ($, e, next) => {
    isInteractive = true
    const home = await read($, pipelineHome)
    quotaCache = home === '' ? '' : `${home}\\logs\\quota\\last-good.json`
    try {
      hasCodeburn = (await $.process.run(['cmd.exe', '/d', '/s', '/c', 'where codeburn.cmd'], { timeoutMs: 5000 })).exitCode === 0
    } catch { hasCodeburn = false }
    const view = await read($, cacheView)

    mark =
      view === null || view.sentAt === null
        ? null
        : { at: view.sentAt, contextTokens: view.contextTokens, hitPercent: view.hitPercent, cold: view.cold }

    const settings = await $.settings.read().catch(() => ({}))
    const configured = (settings as Record<string, unknown>).autoCompactWindow
    compactWindow = typeof configured === 'number' && Number.isFinite(configured) && configured > 0 ? configured : undefined
    const usage = await $.session.usage()
    modelWindow = usage.context.window
    const live = usage.rateLimits
    const last = (await $.store.get('limits')) as ClaudeLimit[] | undefined

    limits = live.length > 0 ? [...live] : (last ?? [])
    await update($, limitsView, () => limits)

    if (hasCodeburn && (await read($, codexView)) === null) {
      const stored = (await $.store.get('codex')) as CodexQuota | undefined

      await update($, codexView, () => stored ?? null)
    }

    const cached = hasCodeburn ? await sharedQuota($) : undefined
    if (cached !== undefined) await update($, codexView, () => cached)

    await $.command.register({ name: 'cache', description: 'Show prompt cache expiry, hit rate, and whether to start a new chat' })
    $.clock.every(15_000, () => {
      void tick($)
    })

    if (hasCodeburn && codexEvery > 0) {
      $.clock.after(3000, () => {
        void readCodex($)
      })
      $.clock.every(codexEvery, () => {
        void readCodex($)
      })
    }

    await tick($)

    return next(e)
  })

  // Subagents keep caches of their own: only the main thread's requests count.
  on('turn.step', async function* ($, e, next) {
    if (e.agentId !== undefined || !isInteractive) {
      return yield* next(e)
    }

    const sentAt = await $.clock.now()
    const result = yield* next(e)
    const usage = result.usage

    if (usage !== null) {
      const prompt = usage.input_tokens + usage.cache_read_input_tokens + usage.cache_creation_input_tokens

      await publish($, {
        at: sentAt,
        contextTokens: prompt + usage.output_tokens,
        hitPercent: prompt > 0 ? Math.round((usage.cache_read_input_tokens / prompt) * 100) : 0,
      })
    }

    return result
  })

  on('session.measure', async ($, e, next) => {
    if (isInteractive && compactWindow === undefined) {
      modelWindow = e.context.window
      await update($, cacheView, () => viewOf())
    }

    if (isInteractive && e.rateLimits.length > 0) {
      limits = [...e.rateLimits]
      await update($, limitsView, () => limits)
      await $.store.set('limits', limits)
      await update($, cacheView, () => viewOf())
      await warnLimits($, e.rateLimits, await $.clock.now())
    }

    return next(e)
  })

  on('session.end', { reason: 'clear' }, async ($, e, next) => {
    if (isInteractive) {
      await publish($, null)
    }

    return next(e)
  })

  on('classic.SessionStart', async ($, e, next) => {
    if (e.seconds_since_last_response !== undefined && e.context_tokens !== undefined) {
      const now = await $.clock.now()

      await publish($, { at: now - e.seconds_since_last_response * 1000, contextTokens: e.context_tokens })
    }

    return next(e)
  })

  on('classic.PostModelSwitch', async ($, e, next) => {
    ttlSeen = e.cache_ttl

    if (mark !== null) {
      await publish($, { ...mark, cold: 'model' })
    }

    return next(e)
  })

  on('classic.PostCompact', async ($, e, next) => {
    if (mark !== null) {
      await publish($, { ...mark, cold: 'compact' })
    }

    return next(e)
  })

  on('command.run', { command: 'cache' }, async $ => ({ text: report(await $.clock.now()) }))

  // The lane nearest the prompt: registered last, it draws beneath the others.
  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    if (e.surface !== 'terminal' || e.props.hasSurvey || !isInteractive) {
      return next(e)
    }

    const below = await next(e)
    const { Box, Client, Text } = $.ui.resolve(e)
    const view = await read($, cacheView)
    const claude = await read($, limitsView)
    const codex = await read($, codexView)
    const window = compactWindow ?? modelWindow
    const context = view === null || view.sentAt === null || window <= 0 ? null : view.contextTokens
    const fraction = context === null ? 0 : context / window
    const contextTone = COLOR[toneOf(fraction, bigContext / window, 0.9)]

    await read($, minute)

    const now = await $.clock.now()
    const resets = claude.filter(limit => limit.kind === 'five_hour' || limit.kind === 'seven_day' || limit.percentUsed >= 70)
    const windows = codex?.windows ?? []
    const age = codexAge(codex, now)
    const fit = { hit: true, codexReset: true, week: true, bars: true, claudeReset: true, contextTokens: true }
    const isConfirmed = ttlOption !== 'auto' || ttlSeen !== undefined
    const shownClaude = () => resets.filter(limit => fit.week || limit.kind !== 'seven_day')
    const shownCodex = () => windows.filter(window => fit.week || window.label !== 'Weekly')
    const cacheWidth = () => {
      if (view === null || view.sentAt === null) return 9
      if (view.cold !== undefined) return `○ cache cold · ${view.cold === 'model' ? 'model changed' : 'after /compact'}`.length
      const left = view.sentAt + view.ttlMs - now
      if (left <= 0) return `○ cache expired ${span(-left)} ago${view.isBig ? ' · new chat or /compact' : ''}`.length
      return `◷ cache ${isConfirmed ? '' : '≥'}${span(left)}`.length + (fit.bars ? 6 : 0) + (fit.hit && view.hitPercent !== undefined ? ` hit ${view.hitPercent}%`.length : 0)
    }
    const contextValue = () => fit.contextTokens ? `${tokens(context ?? 0)}/${tokens(window)}` : `${Math.round(fraction * 100)}%`
    const measure = () => cacheWidth()
      + (context === null ? 0 : 3 + 'ctx '.length + contextValue().length + (fit.bars ? 6 : 0))
      + (shownClaude().length === 0 ? 0 : 3 + '◇ Claude  '.length + shownClaude().map(limit => quotaText(limitName(limit), limit.percentUsed, limit.resetsAt, now, fit.claudeReset)).join(' · ').length + (fit.bars ? 6 * shownClaude().length : 0))
      + (!hasCodeburn || windows.length > 0 && shownCodex().length === 0 && age === '' ? 0 : 3 + '◆ Codex  '.length + (shownCodex().length === 0 ? (windows.length === 0 ? 1 : 0) : shownCodex().map(window => quotaText(CODEX_NAMES[window.label] ?? window.label, window.usedPct, window.resetsAt, now, fit.codexReset)).join(' · ').length + (fit.bars ? 6 * shownCodex().length : 0)) + age.length)
    for (const part of ['hit', 'codexReset', 'week', 'bars', 'contextTokens', 'claudeReset'] as const) {
      if (measure() <= e.props.bodyColumns) break
      fit[part] = false
    }
    const lane = (
      <Box key="meters-lane" flexDirection="row" columnGap={3}>
        <Client key="cache" module="./cache-chip.tsx" props={{
          view: view ?? { sentAt: null, ttlMs: 1, ttlLabel: '1h', warnMs: 0, contextTokens: 0, isBig: false },
          now, showBar: fit.bars, showHit: fit.hit, isConfirmed,
        }} />
        {context === null ? null : <Box key="context"><Text>
          <Text dimColor>ctx </Text><Text color={contextTone}>{contextValue()}</Text>
          {fit.bars ? <Text> {gauge(Text, fraction, 5, contextTone)}</Text> : null}
        </Text></Box>}
        {shownClaude().length === 0 ? null : (
          <Box key="claude-limits"><Text>
            <Text color={COLOR.claude}>{GLYPH.claude}</Text><Text dimColor> Claude  </Text>
            {shownClaude().map((limit, i) => <Text key={`claude:${limit.kind}`} dimColor={expired(limit.resetsAt, now)}>
              <Text dimColor>{i === 0 ? '' : ' · '}{limitName(limit)} </Text>
              {quotaCells(Text, limitName(limit), limit.percentUsed, limit.resetsAt, now, fit.claudeReset, fit.bars, 80, 95)}
            </Text>)}
          </Text></Box>)}
        {hasCodeburn ? codexChip(Box, Text, codex, now, shownCodex(), fit.codexReset, fit.bars) : null}
      </Box>
    )

    return (
      <Box flexDirection="column">
        {lane}
        {below}
      </Box>
    )
  })
}

type Tags = ReturnType<EngineInterface['ui']['resolve']>

const expired = (reset: string | undefined, now: number) => reset !== undefined && Date.parse(reset) <= now
const resetText = (name: string, reset: string | undefined, now: number) =>
  reset === undefined || !Number.isFinite(Date.parse(reset)) ? '?' : name === '5h' ? coarse(Date.parse(reset) - now) : clockAt(Date.parse(reset), now)
const quotaText = (name: string, percent: number, reset: string | undefined, now: number, showReset: boolean) =>
  `${name} ${expired(reset, now) ? '? stale reading' : `${percent}%${showReset ? ` reset ${resetText(name, reset, now)}` : ''}`}`
const quotaCells = (Text: Tags['Text'], name: string, percent: number, reset: string | undefined, now: number, showReset: boolean, bars: boolean, warnAt: number, badAt: number) => {
  if (expired(reset, now)) return <Text dimColor>? stale reading</Text>
  const tone = COLOR[toneOf(percent, warnAt, badAt)]
  return <Text>
    {bars ? <Text>{gauge(Text, percent / 100, 5, tone)} </Text> : null}
    <Text color={tone}>{percent}%</Text>
    {showReset ? <Text dimColor> reset {resetText(name, reset, now)}</Text> : null}
  </Text>
}
const codexAge = (codex: CodexQuota | null, now: number) =>
  codex !== null && (codex.error !== undefined || now - codex.fetchedAt > 2 * codexEvery) ? ` · read ${coarse(now - codex.fetchedAt)} ago` : ''
const codexChip = (Box: Tags['Box'], Text: Tags['Text'], codex: CodexQuota | null, now: number, windows: CodexWindow[], showReset: boolean, bars: boolean) => {
  const age = codexAge(codex, now)
  if (windows.length === 0 && (codex?.windows.length ?? 0) > 0 && age === '') return null
  return (
    <Box key="codex-limits"><Text>
      <Text color={COLOR.codex}>{GLYPH.codex}</Text><Text dimColor> Codex  </Text>
      {windows.length === 0 ? ((codex?.windows.length ?? 0) > 0 ? null : <Text dimColor>{codex === null ? GLYPH.wait : '?'}</Text>) : windows.map((window, i) => (
        <Text key={`codex:${window.label}`} dimColor={expired(window.resetsAt, now)}>
          <Text dimColor>{i === 0 ? '' : ' · '}{CODEX_NAMES[window.label] ?? window.label} </Text>
          {quotaCells(Text, CODEX_NAMES[window.label] ?? window.label, window.usedPct, window.resetsAt, now, showReset, bars, 70, CODEX_CAP)}
        </Text>
      ))}
      {age === '' ? null : <Text dimColor>{age}</Text>}
    </Text></Box>
  )
}
