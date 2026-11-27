import { atom, update } from 'claude-code'
import type { On } from 'claude-code'

export const pipelineHome = atom({ plugin: 'cockpit', key: 'pipelineHome' } as const, '')
export const RUN_PATH_COMMAND = '[IO.Path]::GetFullPath($env:CC_PATH, $env:CC_CWD)'

export const registerPipeline = (on: On) => {
  on('session.start', { isInteractive: true }, async ($, e, next) => {
    let home = ''
    try {
      home = await $.env.get('PIPELINE_HOME') ?? ''
      if (home === '') {
        const profile = await $.env.get('USERPROFILE') || await $.env.get('HOME') || ''
        if (profile !== '') home = `${profile.replace(/[\\/]+$/, '')}\\.pipeline`
      }
      home = home.replace(/\//g, '\\').replace(/\\+$/, '')
    } catch { }
    await update($, pipelineHome, () => home)
    return next(e)
  })
}

export type Registry = {
  defaults?: { githubAccounts?: unknown; cockpitRunnerRoot?: string }
  executors?: Record<string, { repo?: string; github?: string }>
}

export const registryOf = (text: string): Registry => {
  const value = JSON.parse(text.replace(/^\uFEFF/, ''))
  if (value === null || typeof value !== 'object' || Array.isArray(value)) throw new Error('Invalid registry')
  return value
}

export const TEAM_REGISTRY_COMMAND = "$file = if (Test-Path -LiteralPath $env:CC_LAUNCHER) { Get-Item -LiteralPath $env:CC_LAUNCHER } else { Get-Item -LiteralPath (Get-Command $env:CC_LAUNCHER -TotalCount 1 -ErrorAction Stop).Source }; if ($file.LinkType) { $file = $file.ResolveLinkTarget($true) }; $root = Get-Item -LiteralPath (Split-Path (Split-Path $file.FullName -Parent) -Parent); if ($root.LinkType) { $root = $root.ResolveLinkTarget($true) }; Join-Path $root.FullName 'config\\executors.json'"
