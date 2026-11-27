import type { ClientSurface } from 'claude-code'

import { COLOR, coarse, GLYPH, gauge, span } from './look'

type Props = {
  /** When the phase began: the executor's start, or the gate's. */
  from: number
  now: number
  phase: 'starting' | 'running' | 'gate'
  color: string
  timeoutMs: number
  isNarrow: boolean
}

// The spinner and the clock of a running executor, animated on the terminal's frame clock.
export default function RunClock(props: Props, surface: ClientSurface<number>) {
  const { Text } = surface.elements

  if (surface.state === undefined) {
    surface.every(1000, () => surface.setState(Date.now()))
    surface.setState(props.now)
  }

  const now = Math.max(props.now, surface.state ?? props.now)
  const frame = GLYPH.half
  const elapsed = Math.max(0, now - props.from)

  if (props.phase === 'starting') {
    return (
      <Text>
        <Text color={props.color}>{frame}</Text>
        <Text dimColor> starting {span(elapsed)}</Text>
      </Text>
    )
  }

  if (props.phase === 'gate') {
    return (
      <Text>
        <Text color={COLOR.info}>{frame}</Text>
        <Text dimColor> gate running </Text>
        <Text>{span(elapsed)}</Text>
      </Text>
    )
  }

  const fraction = elapsed / props.timeoutMs
  const tone = fraction >= 0.9 ? COLOR.bad : fraction >= 0.75 ? COLOR.warn : props.color

  return (
    <Text>
      <Text color={props.color}>{frame}</Text>
      {props.isNarrow ? null : (
        <Text>
          {' '}
          {gauge(Text, fraction, 14, tone)}
        </Text>
      )}
      <Text> {coarse(elapsed)}</Text>
      <Text dimColor>/{coarse(props.timeoutMs)}</Text>
    </Text>
  )
}
