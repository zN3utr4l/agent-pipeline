import type { ClientSurface } from 'claude-code'

// Frame timers cease at unmount, so a headless or absent band cannot poll GitHub.
export default function RunnerPoll(_props: Record<string, never>, surface: ClientSurface<boolean>) {
  const { Box } = surface.elements
  if (surface.state === undefined) {
    surface.setState(true)
    surface.every(1000, () => surface.post('poll'))
    surface.post('poll')
  }
  return <Box height={0} />
}
