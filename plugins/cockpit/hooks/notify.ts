import type { EngineInterface, On, PluginOptions, TurnCompleteInput } from 'claude-code'

import { clip, firstLine, GLYPH, MINUTE, pad } from './look'

// Waits and turn ends: a Windows notification, and the tab's ring in Windows Terminal.

// A turn's end is drawn after the engine has finished drawing it.
const SETTLE_MS = 1500

// One wait raises its permission request, its tool call and a notification: the first one speaks.
const ECHO_MS = 20_000

// The OSC 9;4 states Windows Terminal draws on the tab and on its taskbar button. Claude Code
// draws none of its own there, so the mod sets and clears every one.
const RING = { waiting: '4;100', done: '1;100', error: '2;100', none: '0;0' } as const

// What a field in a tool's input says about the call, in the order a dialog shows them.
const DETAILS = ['command', 'file_path', 'notebook_path', 'url', 'path', 'skill', 'description', 'prompt']

type Kind = 'permission' | 'question' | 'plan' | 'done' | 'error'
type Ring = keyof typeof RING
type Notice = { kind: Kind; title: string; text: string }
type Job = { ring?: Ring; toast?: 'show' | 'remove'; notice?: Notice }

let minMs = 2 * MINUTE
let hasToasts = true
let hasBadge = true
let hasSound = true

let isInteractive = false
let tag = ''
let folder = ''
let ring: Ring = 'none'
let hasToast = false
let asked: { tool: string; at: number } | undefined
let epoch = 0
let queue: Promise<unknown> = Promise.resolve()

// A turn's length to the second, the way the notification says it.
const span = (ms: number) => {
  const seconds = Math.round(ms / 1000)
  const minutes = Math.floor(seconds / 60)

  return minutes < 60 ? `${minutes}m${pad(seconds % 60)}s` : `${Math.floor(minutes / 60)}h${pad(minutes % 60)}m`
}

const field = (input: unknown, key: string) => {
  const value = typeof input === 'object' && input !== null ? (input as Record<string, unknown>)[key] : undefined

  return typeof value === 'string' && value.trim() !== '' ? value : undefined
}

// What the dialog waits on, the way the notification says it.
const askNotice = (tool: string, input: unknown): Notice => {
  if (tool === 'AskUserQuestion') {
    const questions = (input as { questions?: { question?: string }[] } | null)?.questions ?? []
    const more = questions.length > 1 ? ` (+${questions.length - 1})` : ''

    return { kind: 'question', title: 'Claude has a question', text: clip(firstLine(questions[0]?.question ?? ''), 160) + more }
  }

  if (tool === 'ExitPlanMode') {
    return { kind: 'plan', title: 'Plan ready for approval', text: 'Review the plan and approve it or ask for changes.' }
  }

  const name = tool.startsWith('mcp__') ? tool.split('__').slice(1).join(' · ') : tool
  const detail = DETAILS.map(key => field(input, key)).find(value => value !== undefined)

  return {
    kind: 'permission',
    title: 'Your decision is needed',
    text: detail === undefined ? `Permission for ${name}` : `${name}: ${clip(firstLine(detail), 150)}`,
  }
}

const endNotice = (e: TurnCompleteInput): Notice => {
  const took = span(e.durationMs)
  const text = clip(firstLine(e.answer), 140)

  if (e.reason === 'error') {
    return { kind: 'error', title: `Stopped by an error after ${took}`, text }
  }

  return e.reason === 'refusal'
    ? { kind: 'error', title: `Refused after ${took}`, text }
    : { kind: 'done', title: `Completed in ${took}`, text }
}

// One notifier at a time, in order: a badge cleared right after it was drawn stays cleared.
const send = ($: EngineInterface, job: Job) => {
  const env: Record<string, string> = { CC_NOTIFY_TAG: tag, CC_NOTIFY_FOLDER: folder, CC_NOTIFY_SOUND: hasSound ? '1' : '0' }

  if (hasBadge && job.ring !== undefined && job.ring !== ring) {
    env.CC_NOTIFY_RING = RING[job.ring]
    ring = job.ring
  }

  if (hasToasts && job.toast === 'show' && job.notice !== undefined) {
    env.CC_NOTIFY_TOAST = 'show'
    env.CC_NOTIFY_KIND = job.notice.kind
    env.CC_NOTIFY_TITLE = job.notice.title
    env.CC_NOTIFY_TEXT = job.notice.text
    hasToast = true
  } else if (job.toast === 'remove' && hasToast) {
    env.CC_NOTIFY_TOAST = 'remove'
    hasToast = false
  }

  if (env.CC_NOTIFY_RING === undefined && env.CC_NOTIFY_TOAST === undefined) {
    return
  }

  const script = `${$.plugin.root}/scripts/notify.ps1`.replace(/\//g, '\\')
  const argv = ['powershell.exe', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', script]

  queue = queue.then(() => $.process.run(argv, { env, timeoutMs: 20_000 })).catch(() => undefined)
}

// `*` stands for a wait known only from its notification, whose tool is not named.
const ask = async ($: EngineInterface, tool: string, input: unknown) => {
  const now = await $.clock.now()

  if (asked !== undefined && now - asked.at < ECHO_MS && (asked.tool === tool || asked.tool === '*' || tool === '*')) {
    asked = { tool: tool === '*' ? asked.tool : tool, at: asked.at }

    return
  }

  asked = { tool, at: now }
  send($, { ring: 'waiting', toast: 'show', notice: askNotice(tool, input) })
}

const answered = ($: EngineInterface, tool: string) => {
  if (asked === undefined || (asked.tool !== tool && asked.tool !== '*')) {
    return
  }

  asked = undefined
  send($, { ring: 'none', toast: 'remove' })
}

export const registerNotify = (on: On, options: PluginOptions) => {
  minMs = Number(options.minMinutes ?? 2) * MINUTE
  hasToasts = options.windowsNotification !== false
  hasBadge = options.tabBadge !== false
  hasSound = options.sound !== false

  // A session nobody sits at draws nothing: every lane and notification waits for the REPL.
  on('session.start', { isInteractive: true }, async ($, e, next) => {
    isInteractive = true
    tag = (await $.env.get('WT_SESSION')) ?? `cc-${(await $.clock.now()).toString(36)}`
    folder = e.cwd.split(/[\\/]/).filter(Boolean).at(-1) ?? e.cwd

    return next(e)
  })

  // The dialog for a tool call, a question (AskUserQuestion) or a plan (ExitPlanMode).
  on('classic.PermissionRequest', async ($, e, next) => {
    if (isInteractive) {
      await ask($, e.tool_name, e.tool_input)
    }

    return next(e)
  })

  on('classic.Notification', async ($, e, next) => {
    if (isInteractive && e.notification_type === 'permission_prompt') {
      await ask($, '*', { description: e.message })
    }

    if (isInteractive && e.notification_type === 'elicitation_dialog') {
      await ask($, 'AskUserQuestion', { questions: [{ question: e.message }] })
    }

    return next(e)
  })

  on('tool.call', { tool: 'AskUserQuestion' }, async ($, e, next) => {
    if (isInteractive) {
      await ask($, e.tool, e)
    }

    return next(e)
  })

  on('tool.call', { tool: 'ExitPlanMode' }, async ($, e, next) => {
    if (isInteractive) {
      await ask($, e.tool, e)
    }

    return next(e)
  })

  // A call returns once its dialog was answered and the tool ran: the wait is over.
  on('tool.call', async ($, e, next) => {
    try {
      return await next(e)
    } finally {
      answered($, e.tool)
    }
  })

  on('prompt.submit', async ($, e, next) => {
    if (isInteractive) {
      epoch += 1
      asked = undefined
      send($, { ring: 'none', toast: 'remove' })
    }

    return next(e)
  })

  // Main-thread turns only: a subagent's run ends inside a turn the person is waiting on.
  on('turn.complete', async ($, e, next) => {
    const result = await next(e)

    if (!isInteractive || e.agentId !== undefined) {
      return result
    }

    const at = epoch
    const notice = endNotice(e)
    const isLong = e.durationMs >= minMs

    asked = undefined

    if (isLong && !e.isAborted) {
      $.ui.toast(`${notice.kind === 'error' ? GLYPH.bad : GLYPH.ok} ${notice.title}`, { timeoutMs: 8000 })
    }

    $.clock.after(SETTLE_MS, () => {
      if (epoch !== at) {
        return
      }

      if (e.isAborted) {
        send($, { ring: 'none', toast: 'remove' })
      } else {
        send($, { ring: notice.kind === 'error' ? 'error' : 'done', toast: isLong ? 'show' : 'remove', notice })
      }
    })

    return result
  })

  on('session.end', async ($, e, next) => {
    if (isInteractive) {
      asked = undefined
      send($, { ring: 'none' })
    }

    return next(e)
  })
}
