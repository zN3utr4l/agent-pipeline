export type Account = { root: string; login: string }
export const accountsOf = (registry: { defaults?: { githubAccounts?: unknown } }): Account[] => {
  const map = registry.defaults?.githubAccounts
  if (map === null || typeof map !== 'object' || Array.isArray(map)) return []
  const entries = Object.entries(map)
  if (entries.some(([root, login]) => root.trim() === '' || typeof login !== 'string' || login.trim() === '')) return []
  return entries.map(([root, login]) => ({ root: root.replace(/\\/g, '/').toLowerCase().replace(/\/+$/, ''), login: login as string })).sort((a, b) => b.root.length - a.root.length)
}
export const loginFor = (cwd: string, accounts: Account[]) => {
  const dir = cwd.replace(/\\/g, '/').toLowerCase().replace(/\/+$/, '')
  return accounts.find(rule => dir === rule.root || dir.startsWith(`${rule.root}/`))?.login
}

type Gate = { exitCode?: number; timedOut?: boolean; tail?: string; flaky?: boolean; attempts?: { failures?: string[] }[] }
type Meta = { wrapperExitCode?: number | null; exitCode?: number | null; gate?: Gate | null; timedOut?: boolean; timeoutMinutes?: number; reportPresent?: boolean; totalCostUsd?: number; outOfCredits?: boolean; rateLimited?: boolean }
type Outcome = { tone: 'ok' | 'warn' | 'bad'; title: string; detail?: string }
const EXITS: Record<number, Outcome> = {
  1: { title: 'execution or report failed', tone: 'bad' },
  2: { title: 'Claude authentication', tone: 'bad' },
  3: { title: 'repository busy or resume refused', tone: 'warn' },
  4: { title: 'quota refused', tone: 'warn' },
  75: { title: 'preflight or sandbox', tone: 'bad' },
}
export const testsIn = (tail: string) => {
  const vitest = /Tests\s+(\d+)\s+passed/i.exec(tail)
  if (vitest !== null) return `${vitest[1]} test`
  const dotnet = [...tail.matchAll(/Passed:\s*(\d+)/g)].reduce((sum, match) => sum + Number(match[1]), 0)
  if (dotnet > 0) return `${dotnet} test`
  const generic = /(\d+)\s+(?:passed|superati|tests? passed)/i.exec(tail)
  return generic === null ? undefined : `${generic[1]} test`
}
export const outcomeOf = (meta: Meta): Outcome => {
  const exit = meta.wrapperExitCode ?? meta.exitCode ?? null
  const gate = meta.gate ?? undefined
  const cost = typeof meta.totalCostUsd === 'number' ? `≈$${meta.totalCostUsd.toFixed(2)}` : undefined
  const tests = gate?.tail === undefined ? undefined : testsIn(gate.tail)
  const detail = (...parts: (string | undefined)[]) => parts.filter(part => part !== undefined).join(' · ') || undefined
  if (meta.timedOut === true || exit === 124) return { tone: 'bad', title: 'timed out', detail: detail(meta.timeoutMinutes === undefined ? undefined : `over ${meta.timeoutMinutes}m`, cost) }
  if (exit === 0) {
    if (meta.reportPresent === false) return { tone: 'warn', title: 'finished without a report', detail: detail(cost) }
    if (gate?.flaky === true) return { tone: 'warn', title: 'gate passed on second attempt', detail: detail(`${gate.attempts?.[0]?.failures?.length ?? 0} errors on first attempt`, tests, cost) }
    return gate === undefined ? { tone: 'ok', title: 'finished', detail: detail('no gate', cost) } : { tone: 'ok', title: 'gate passed', detail: detail(tests, cost) }
  }
  if (exit === 5) return { tone: 'bad', title: gate?.timedOut === true ? 'gate timed out' : 'gate failed', detail: detail(gate?.exitCode === undefined ? undefined : `exit ${gate.exitCode}`, cost) }
  const known = exit === null ? undefined : EXITS[exit]
  const why = meta.outOfCredits === true ? 'out of credits' : meta.rateLimited === true ? "usage limit" : undefined
  return { tone: known?.tone ?? 'bad', title: known?.title ?? (exit === null ? 'interrupted' : `exit ${exit}`), detail: detail(why, cost) }
}

type Pr = {
  isDraft: boolean; mergeable: string; reviewDecision?: string | null
  commits: { nodes: { commit: { committedDate: string; statusCheckRollup: { state: string } | null } }[] }
  reviews: { nodes: { author: { login: string } | null; submittedAt: string | null }[] }
  timelineItems?: { nodes: { createdAt: string }[] }
  reactions: { nodes: { createdAt: string; user: { login: string } | null }[] }
}
export const verdictOf = (node: Pr, pushedAt?: number): 'draft' | 'conflict' | 'ci-red' | 'changes' | 'ci-running' | 'ready' | 'codex-waiting' | 'codex-stale' | 'codex-comments' => {
  const commit = node.commits.nodes[0]?.commit
  const ci = commit?.statusCheckRollup?.state
  const isCodex = (login: string | undefined) => login !== undefined && /codex/i.test(login)
  const reviewedAt = node.reviews.nodes.filter(review => isCodex(review.author?.login)).at(-1)?.submittedAt ?? undefined
  if (node.isDraft) return 'draft'
  if (node.mergeable === 'CONFLICTING') return 'conflict'
  if (ci === 'FAILURE' || ci === 'ERROR') return 'ci-red'
  if (node.reviewDecision === 'CHANGES_REQUESTED') return 'changes'
  if (ci === 'PENDING' || ci === 'EXPECTED') return 'ci-running'
  const headUpdatedAt = pushedAt ?? Math.max(commit === undefined ? -Infinity : Date.parse(commit.committedDate), ...(node.timelineItems?.nodes.map(event => Date.parse(event.createdAt)) ?? []))
  if (node.reactions.nodes.some(reaction => isCodex(reaction.user?.login) && commit !== undefined && Date.parse(reaction.createdAt) >= headUpdatedAt)) return 'ready'
  if (reviewedAt === undefined) return 'codex-waiting'
  return commit !== undefined && reviewedAt < commit.committedDate ? 'codex-stale' : 'codex-comments'
}
