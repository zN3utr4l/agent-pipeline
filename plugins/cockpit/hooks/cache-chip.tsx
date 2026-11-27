import type { ClientSurface } from 'claude-code'

import type { CacheView } from '../types'
import { COLOR, gauge, GLYPH, span } from './look'

type Props = { view: CacheView; now: number; showBar: boolean; showHit: boolean; isConfirmed: boolean }

const COLD = { model: 'model changed', compact: 'after /compact' } as const

// Counts the cache down on the terminal's own clock, so the band is not redrawn every second.
export default function CacheChip(props: Props, surface: ClientSurface<number>) {
  const { Text } = surface.elements
  const { view } = props

  if (surface.state === undefined) {
    surface.every(1000, () => surface.setState(Date.now()))
    surface.setState(props.now)
  }

  const now = Math.max(props.now, surface.state ?? props.now)

  if (view.sentAt === null) {
    return <Text dimColor>{GLYPH.cache} cache —</Text>
  }

  if (view.cold !== undefined) {
    return (
      <Text dimColor>
        {GLYPH.ring} cache cold · {COLD[view.cold]}
      </Text>
    )
  }

  const left = view.sentAt + view.ttlMs - now

  if (left <= 0) {
    return view.isBig ? (
      <Text>
        <Text color={COLOR.bad}>
          {GLYPH.ring} cache expired {span(-left)} ago
        </Text>
        <Text dimColor> · new chat or /compact</Text>
      </Text>
    ) : (
      <Text dimColor>
        {GLYPH.ring} cache expired {span(-left)} ago
      </Text>
    )
  }

  const isWarn = left <= view.warnMs
  const tone = isWarn ? COLOR.warn : COLOR.ok
  const time = isWarn ? (
    <Text bold color={COLOR.warn}>
      {props.isConfirmed ? '' : '≥'}{span(left)}
    </Text>
  ) : (
    <Text bold>{props.isConfirmed ? '' : '≥'}{span(left)}</Text>
  )

  return (
    <Text>
      <Text color={tone}>{isWarn ? GLYPH.half : GLYPH.cache}</Text>
      <Text dimColor> cache </Text>
      {time}
      {props.showBar ? <Text> {gauge(Text, left / view.ttlMs, 5, tone)}</Text> : null}
      {!props.showHit || view.hitPercent === undefined ? null : <Text dimColor> hit {view.hitPercent}%</Text>}
    </Text>
  )
}
