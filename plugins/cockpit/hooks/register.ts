import type { Register } from 'claude-code'

import { registerMeters } from './meters'
import { registerNotify } from './notify'
import { registerPrs } from './prs'
import { registerPipeline } from './pipeline'
import { registerRunner } from './runner'
import { registerRuns } from './runs'

// The band reads top to bottom in registration order: executors, runner, PRs, then
// meters right above the prompt.
export const register: Register = (on, options) => {
  registerPipeline(on)
  registerNotify(on, options)
  registerRuns(on, options)
  registerRunner(on, options)
  registerPrs(on)
  registerMeters(on, options)
}
