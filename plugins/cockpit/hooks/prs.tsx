import { atom, read, update } from 'claude-code'
import type { EngineInterface, On } from 'claude-code'

import type { PrFeed, PrRow, PrUi, PrVerdict } from '../types'
import { coarse, COLOR, GLYPH, MINUTE } from './look'
import { accountsOf, loginFor } from './github'
import { registryOf } from './pipeline'
import { verdictOf } from '../core/readings'

const pipelineHome = { plugin: 'cockpit', key: 'pipelineHome' } as const

// The PR lane: the account's open pull requests, what each waits on, and a nudge for Codex.

// What the lanes draw from; this module is the only writer.
const prsView = atom({ plugin: 'cockpit', key: 'prs' } as const, null)
const prUi = atom({ plugin: 'cockpit', key: 'prUi' } as const, { isExpanded: false, isHidden: false, asked: {} })

const EVERY = 5 * MINUTE

// A second press within this window posts the comment: the first only arms it.
const CONFIRM_MS = 6000

// How long an asked review shows as asked before the lane goes back to the verdict.
const ASKED_MS = 45 * MINUTE

let accounts = accountsOf({})
const loadAccounts = async ($: EngineInterface) => {
  try {
    const home = await read($, pipelineHome)
    accounts = accountsOf(home === '' ? {} : registryOf(await $.fs.read(`${home}\\config\\executors.json`)))
  }
  catch { accounts = accountsOf({}) }
}
const tokenFor = async ($: EngineInterface) => {
  const login = loginFor(await $.session.cwd(), accounts)
  const env: Record<string, string> = {}
  if (login !== undefined) {
    const token = await $.process.run(['gh', 'auth', 'token', '--user', login], { timeoutMs: 15_000 })
    if (token.exitCode === 0 && token.stdout.trim() !== '') env.GH_TOKEN = token.stdout.trim()
  }
  return { login, env }
}

const QUERY = `query {
  viewer {
    login
    pullRequests(states: OPEN, first: 20, orderBy: {field: UPDATED_AT, direction: DESC}) {
      totalCount
      nodes {
        number title url isDraft reviewDecision mergeable
        repository { name }
        headRefName headRefOid
        headRepository { nameWithOwner }
        commits(last: 1) { nodes { commit { committedDate statusCheckRollup { state } } } }
        timelineItems(last: 1, itemTypes: [HEAD_REF_FORCE_PUSHED_EVENT]) { nodes { ... on HeadRefForcePushedEvent { createdAt } } }
        reactions(content: THUMBS_UP, first: 10) { nodes { createdAt user { login } } }
        reviews(last: 10) { nodes { author { login } submittedAt } }
      }
    }
  }
  reviewRequests: search(query: "is:open is:pr review-requested:@me archived:false", type: ISSUE, first: 20) {
    issueCount
    nodes {
      ... on PullRequest {
        number title url
        repository { name }
        author { login }
      }
    }
  }
}`

// Commands after which the list is stale: a pull request opened, merged or closed, a push.
const CHANGES = /(^|[\s;&|(\\/"'`])(gh(\.exe)?["']?\s+pr\s+(create|merge|close|ready|reopen|comment)|git\s+push)\b/

const LABELS: Record<PrVerdict, { text: string; tone: keyof typeof COLOR }> = {
  conflict: { text: 'conflicts', tone: 'bad' },
  'ci-red': { text: 'CI failed', tone: 'bad' },
  changes: { text: 'changes requested', tone: 'bad' },
  'ci-running': { text: 'CI running', tone: 'info' },
  'codex-stale': { text: 'Codex review stale', tone: 'warn' },
  'codex-comments': { text: 'Codex comments', tone: 'warn' },
  'codex-waiting': { text: 'awaiting Codex', tone: 'warn' },
  review: { text: 'review requested', tone: 'warn' },
  draft: { text: 'draft', tone: 'track' },
  ready: { text: 'ready', tone: 'ok' },
}

const verdictGlyph = (verdict: PrVerdict) =>
  LABELS[verdict].tone === 'bad' ? GLYPH.bad : verdict === 'ci-running' ? GLYPH.half : verdict === 'ready' ? GLYPH.ok : GLYPH.dot

const ORDER = Object.keys(LABELS) as PrVerdict[]

// The verdicts a fresh review would settle: Codex has not looked at the last commit.
const ASKABLE: readonly PrVerdict[] = ['codex-stale', 'codex-waiting']

type Node = {
  number: number
  title: string
  url: string
  isDraft: boolean
  reviewDecision: string | null
  mergeable: string
  repository: { name: string }
  headRefName: string
  headRefOid: string
  headRepository: { nameWithOwner: string } | null
  commits: { nodes: { commit: { committedDate: string; statusCheckRollup: { state: string } | null } }[] }
  timelineItems?: { nodes: { createdAt: string }[] }
  reactions: { nodes: { createdAt: string; user: { login: string } | null }[] }
  reviews: { nodes: { author: { login: string } | null; submittedAt: string | null }[] }
}

type ReviewNode = Pick<Node, 'number' | 'title' | 'url' | 'repository'> & { author: { login: string } | null }
type Answer = { data: { viewer: { login: string; pullRequests: { totalCount: number; nodes: Node[] } }; reviewRequests?: { issueCount: number; nodes: ReviewNode[] } } }

let isInteractive = false
let isFetching = false

const isCodex = (login: string | undefined) => login !== undefined && /codex/i.test(login)

const rowOf = (node: Node, pushedAt?: number): PrRow => ({
  repo: node.repository.name,
  number: node.number,
  title: node.title,
  url: node.url,
  verdict: verdictOf(node, pushedAt),
  codexAt: node.reviews.nodes.filter(review => isCodex(review.author?.login)).at(-1)?.submittedAt ?? undefined,
})

const counts = (feed: PrFeed) =>
  ORDER.map(verdict => [verdict, verdict === 'review' ? (feed.reviewTotal ?? 0) : feed.rows.filter(row => row.verdict === verdict).length] as const).filter(([, n]) => n > 0)

const summary = (feed: PrFeed) =>
  [`${feed.total} open`, ...counts(feed).map(([verdict, n]) => `${n} ${LABELS[verdict].text}`)].join(' · ')

const firstLine = (text: string) => text.trim().split('\n')[0]?.slice(0, 80) ?? ''

const refresh = async ($: EngineInterface) => {
  if (isFetching) {
    return
  }

  isFetching = true

  try {
    const { login, env } = await tokenFor($)
    const run = await $.process.run(['gh', 'api', 'graphql', '-f', `query=${QUERY}`], { env, timeoutMs: 30_000 })
    const fetchedAt = await $.clock.now()

    if (run.exitCode !== 0) {
      const error = firstLine(run.stderr) || `gh exited with ${run.exitCode}`

      await update($, prsView, previous => ({ ...(previous ?? { rows: [], total: 0 }), login: login ?? '', fetchedAt, error }))

      return
    }

    const { viewer, reviewRequests } = (JSON.parse(run.stdout) as Answer).data
    const rows = await Promise.all(viewer.pullRequests.nodes.map(async node => {
      let pushedAt: number | undefined
      if (node.headRepository !== null && [undefined, 'SUCCESS'].includes(node.commits.nodes[0]?.commit.statusCheckRollup?.state) && node.reactions.nodes.some(reaction => isCodex(reaction.user?.login))) {
        try {
          const activity = await $.process.run(['gh', 'api', `repos/${node.headRepository.nameWithOwner}/activity?ref=${encodeURIComponent(`refs/heads/${node.headRefName}`)}&per_page=1`], { env, timeoutMs: 5000 })
          if (activity.exitCode === 0) {
            const latest = (JSON.parse(activity.stdout) as { after: string; timestamp: string }[])[0]
            if (latest?.after === node.headRefOid && Number.isFinite(Date.parse(latest.timestamp))) pushedAt = Date.parse(latest.timestamp)
          }
        } catch { /* Use the commit and force-push fallback when ref activity is unavailable. */ }
      }
      return rowOf(node, pushedAt)
    }))
    const owned = new Set(rows.map(row => row.url))
    const reviews = reviewRequests?.nodes.filter(node => !owned.has(node.url)) ?? []
    rows.push(...reviews.map(node => ({ repo: node.repository.name, number: node.number, title: node.title, url: node.url, verdict: 'review' as const, author: node.author?.login })))

    await update($, prsView, () => ({
      login: viewer.login,
      rows,
      reviewTotal: (reviewRequests?.issueCount ?? 0) - ((reviewRequests?.nodes.length ?? 0) - reviews.length),
      total: viewer.pullRequests.totalCount,
      fetchedAt,
    }))
  } catch (error) {
    const fetchedAt = await $.clock.now()

    await update($, prsView, previous => ({ ...(previous ?? { rows: [], total: 0, login: '' }), fetchedAt, error: firstLine(String(error)) }))
  } finally {
    isFetching = false
  }
}

// Two presses: the first arms the button for a few seconds, the second posts `@codex review`.
const askCodex = async ($: EngineInterface, row: PrRow) => {
  const ui = await read($, prUi)

  if (ui.confirming !== row.url) {
    await update($, prUi, state => ({ ...state, confirming: row.url }))
    $.clock.after(CONFIRM_MS, () => {
      void update($, prUi, state => (state.confirming === row.url ? { ...state, confirming: undefined } : state))
    })

    return
  }

  const now = await $.clock.now()

  await update($, prUi, state => ({ ...state, confirming: undefined, asked: { ...state.asked, [row.url]: now } }))

  const { env } = await tokenFor($)
  const run = await $.process.run(['gh', 'pr', 'comment', row.url, '--body', '@codex review'], { env, timeoutMs: 30_000 })

  if (run.exitCode === 0) {
    $.ui.toast(`${GLYPH.dot} Codex · ${row.repo}#${row.number} · review requested`, { timeoutMs: 6000 })
  } else {
    await update($, prUi, state => {
      const { [row.url]: _, ...asked } = state.asked

      return { ...state, asked }
    })
    $.ui.toast(`${GLYPH.bad} Codex · ${row.repo}#${row.number} · comment could not be posted · ${firstLine(run.stderr) || `exit ${run.exitCode}`}`, {
      timeoutMs: 10_000,
    })
  }
}

const listing = (feed: PrFeed | null) => {
  if (feed === null) {
    return 'PR: no data yet.'
  }

  const rows = feed.rows.map(row => `- ${row.repo}#${row.number} ${LABELS[row.verdict].text}: ${row.title}${row.author === undefined ? '' : ` · ${row.author}`} (${row.url})`)
  const error = feed.error === undefined ? '' : `\nLast refresh failed: ${feed.error}`

  return [`PRs for ${feed.login}: ${summary(feed)}`, ...rows].join('\n') + error
}

// A review asked and not yet answered: no Codex review newer than the ask.
const isAsked = (ui: PrUi, row: PrRow, now: number) => {
  const at = ui.asked[row.url]

  return at !== undefined && now - at < ASKED_MS && (row.codexAt === undefined || Date.parse(row.codexAt) < at)
}

export const registerPrs = (on: On) => {
  on('session.start', { isInteractive: true }, async ($, e, next) => {
    await loadAccounts($)
    isInteractive = true
    await $.command.register({ name: 'prs', description: 'Refresh and open the row for your PRs and review requests' })
    $.clock.after(1000, () => {
      void refresh($)
    })
    $.clock.every(EVERY, () => {
      void refresh($)
    })

    return next(e)
  })

  on('command.run', { command: 'prs' }, async $ => {
    await update($, prUi, state => ({ ...state, isHidden: false, isExpanded: true }))
    await refresh($)

    return { text: listing(await read($, prsView)) }
  })

  on('tool.call', { tool: 'Bash' }, async ($, e, next) => {
    const result = await next(e)

    if (isInteractive && CHANGES.test(e.command)) {
      $.clock.after(5000, () => {
        void refresh($)
      })
    }

    return result
  })

  on('tool.call', { tool: 'PowerShell' }, async ($, e, next) => {
    const result = await next(e)

    if (isInteractive && CHANGES.test(e.command)) {
      $.clock.after(5000, () => {
        void refresh($)
      })
    }

    return result
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    if (e.surface !== 'terminal' || e.props.hasSurvey || !isInteractive) {
      return next(e)
    }

    const below = await next(e)
    const feed = await read($, prsView)
    const ui = await read($, prUi)

    if (feed === null || ui.isHidden || (feed.error === undefined && feed.rows.length === 0)) {
      return below
    }

    const { Box, Button, Link, Text } = $.ui.resolve(e)
    const now = await $.clock.now()
    const width = e.props.bodyColumns
    const repoWidth = Math.min(Math.floor(width / 4), 28, Math.max(...feed.rows.map(row => `${row.repo}#${row.number}`.length), 8))
    const head = (
      <Box flexDirection="row" columnGap={2}>
        <Text>
          <Text color={COLOR.info}>{GLYPH.pr}</Text>
          <Text dimColor> PR </Text>
          <Text bold>{feed.total}</Text><Text dimColor> open</Text>
          {counts(feed).map(([verdict, n]) => (
            <Text>
              <Text dimColor> · </Text>
              <Text color={COLOR[LABELS[verdict].tone]}>{verdictGlyph(verdict)}</Text>
              <Text>
                {' '}
                {n} {LABELS[verdict].text}
              </Text>
            </Text>
          ))}
          {feed.error === undefined ? null : <Text color={COLOR.bad}> · refresh failed</Text>}
          <Text dimColor> · {coarse(now - feed.fetchedAt)} ago</Text>
        </Text>
        <Button key="pr-toggle" plain hotkey="p" dimColor label={ui.isExpanded ? `${GLYPH.open} close` : `${GLYPH.closed} details`} onPress={() => update($, prUi, state => ({ ...state, isExpanded: !state.isExpanded }))} />
        <Button key="pr-refresh" plain hotkey="a" dimColor label="refresh" onPress={() => refresh($)} />
        <Button key="pr-hide" plain hotkey="h" dimColor label="hide" onPress={() => update($, prUi, state => ({ ...state, isHidden: true }))} />
      </Box>
    )
    const rows = ui.isExpanded
      ? feed.rows.map(row => {
          const label = LABELS[row.verdict]
          const asked = isAsked(ui, row, now)
          const isArmed = ui.confirming === row.url

          return (
            <Box key={row.url} flexDirection="row" columnGap={1} paddingLeft={2}>
              <Text color={COLOR[label.tone]}>{verdictGlyph(row.verdict)}</Text>
              <Box width={repoWidth} flexShrink={0}>
                <Link href={row.url} label={`${row.repo}#${row.number}`} />
              </Box>
              <Box flexGrow={1} flexShrink={1} minWidth={0}>
                <Text wrap="truncate-end">
                  {asked ? <Text dimColor>review requested {coarse(now - (ui.asked[row.url] ?? now))} ago</Text> : <Text color={COLOR[label.tone]}>{label.text}</Text>}
                  <Text dimColor> · {row.title}</Text>
                </Text>
              </Box>
              <Box key={`tail:${row.url}`} flexShrink={0} flexDirection="row" columnGap={1}>
              {row.author === undefined ? null : <Text dimColor wrap="truncate-end">{row.author}</Text>}
              {ASKABLE.includes(row.verdict) && !asked ? (
                <Button
                  key={`codex:${row.url}`}
                  plain
                  dimColor={!isArmed}
                  {...(isArmed ? { variant: 'primary' as const } : {})}
                  label={isArmed ? 'confirm @codex review' : '@codex review'}
                  onPress={() => askCodex($, row)}
                />
              ) : null}
              </Box>
            </Box>
          )
        })
      : null

    return (
      <Box flexDirection="column">
        {head}
        {rows}
        {below}
      </Box>
    )
  })
}
