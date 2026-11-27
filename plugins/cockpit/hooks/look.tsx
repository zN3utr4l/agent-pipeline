import type { ClientElements } from 'claude-code'

type TextTag = ClientElements['Text']

// One palette for every lane: provider hues, three tones, and the gauge track.
export const COLOR = {
  claude: 'claude',
  codex: 'merged',
  ok: 'success',
  warn: 'warning',
  bad: 'error',
  info: 'permission',
  track: 'inactive',
} as const

export type Tone = 'ok' | 'warn' | 'bad'

// Glyphs Cascadia Mono draws itself, so no fallback font changes their width or weight.
export const GLYPH = {
  cache: '◷',
  claude: '◇',
  codex: '◆',
  pr: '↑',
  ok: '✓',
  bad: '×',
  dot: '●',
  ring: '○',
  half: '◐',
  open: '▾',
  closed: '▸',
  wait: '…',
} as const

export const SPINNER = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'] as const

const DAYS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'] as const

export const MINUTE = 60_000

export const pad = (n: number) => String(n).padStart(2, '0')

// "0:42" under two minutes, "47m" under an hour, "3h05m" under a day, "2d04h" past it.
export const span = (ms: number) => {
  const seconds = Math.floor(Math.max(0, ms) / 1000)
  const minutes = Math.floor(seconds / 60)
  const hours = Math.floor(minutes / 60)

  if (seconds < 120) {
    return `${minutes}:${pad(seconds % 60)}`
  }

  if (minutes < 60) {
    return `${minutes}m`
  }

  return hours < 24 ? `${hours}h${pad(minutes % 60)}m` : `${Math.floor(hours / 24)}d${pad(hours % 24)}h`
}

// The same to the minute, for what changes slowly: a reset hours away.
export const coarse = (ms: number) => (ms < 2 * MINUTE ? `${Math.max(0, Math.round(ms / MINUTE))}m` : span(ms))

// A wall-clock time: "14:32" today, "Thu 21:59" within the week, "12/10 21:59" past it.
export const clockAt = (at: number, now: number) => {
  const date = new Date(at)
  const time = `${pad(date.getHours())}:${pad(date.getMinutes())}`
  const days = Math.round((startOfDay(at) - startOfDay(now)) / (24 * 60 * MINUTE))

  if (days === 0) {
    return time
  }

  return Math.abs(days) < 7 ? `${DAYS[date.getDay()]} ${time}` : `${pad(date.getDate())}/${pad(date.getMonth() + 1)} ${time}`
}

const startOfDay = (at: number) => {
  const date = new Date(at)

  date.setHours(0, 0, 0, 0)

  return date.getTime()
}

export const resetAt = (at: number, now: number, narrow = false) => {
  if (!Number.isFinite(at)) return '?'
  if (narrow) {
    const minutes = Math.max(0, Math.floor((at - now) / MINUTE))
    return minutes >= 1440 ? `${Math.floor(minutes / 1440)}d` : minutes >= 60 ? `${Math.floor(minutes / 60)}h` : `${minutes}m`
  }
  const date = new Date(at)
  const time = `${pad(date.getHours())}:${pad(date.getMinutes())}`
  return startOfDay(at) === startOfDay(now) ? time : `${DAYS[date.getDay()]} ${date.getDate()}/${date.getMonth() + 1} ${time}`
}

export const clip = (text: string, max: number) => (text.length > max ? `${text.slice(0, Math.max(1, max - 1))}…` : text)

export const firstLine = (text: string) =>
  text
    .split('\n')
    .map(row => row.trim())
    .find(row => row !== '') ?? ''

export const tokens = (n: number) =>
  n >= 1_000_000 ? `${(n / 1_000_000).toFixed(1)}M` : n >= 1000 ? `${Math.round(n / 1000)}k` : String(n)

// "sol", "luna", "opus": the family, which is what tells two executors apart.
export const shortModel = (model: string) =>
  model
    .replace(/^gpt-[\d.]+-/, '')
    .replace(/^claude-/, '')
    .replace(/-\d+(-\d+)*$/, '')

export const toneOf = (percent: number, warnAt: number, badAt: number): Tone =>
  percent >= badAt ? 'bad' : percent >= warnAt ? 'warn' : 'ok'

// One pill per cell, shared by cache, quotas and run clocks.
export const bar = (fraction: number, width: number) => {
  const full = Math.round(Math.min(1, Math.max(0, fraction)) * width)
  return { fill: '▰'.repeat(full), rest: '▱'.repeat(width - full) }
}

export const gauge = (Text: TextTag, fraction: number, width: number, color: string) => {
  const { fill, rest } = bar(fraction, width)

  return (
    <Text>
      <Text color={color}>{fill}</Text>
      <Text dimColor>{rest}</Text>
    </Text>
  )
}
