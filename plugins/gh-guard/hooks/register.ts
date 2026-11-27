import type { EngineInterface, Register } from 'claude-code'

let accounts: { root: string; label: string; login: string }[] = []
let bashWrapper = false

const GH = /(^|[\s;&|(\\/"'`])gh(\.exe)?["']?\s+(?!auth\b)/
const OWN_TOKEN = /\bGH_TOKEN\s*=|\$env:GH_TOKEN\b/i
const CD = /(?:^|[\s;&|(])(?:cd|pushd|Set-Location|sl)\s+(?:-(?:Literal)?Path\s+)?["']?([A-Za-z]:[\\/][^"'\s;&|)]*|\/(?:mnt\/)?[A-Za-z]\/[^"'\s;&|)]*)/gi

const normalize = (path: string) => {
  const forward = path.replace(/\\/g, '/').toLowerCase()
  const drive = /^\/(?:mnt\/)?([a-z])(\/|$)/.exec(forward)
  const local = drive === null ? forward : `${drive[1]}:/${forward.slice(drive[0].length)}`

  return local.replace(/\/+$/, '')
}

const loadAccounts = async ($: EngineInterface) => {
  accounts = []
  bashWrapper = false

  try {
    const profile = (await $.env.get('USERPROFILE')) || (await $.env.get('HOME'))
    const home = (await $.env.get('PIPELINE_HOME')) || (profile ? `${profile}/.pipeline` : '')
    if (home === '') return
    const source = await $.fs.read(`${home.replace(/[\\/]+$/, '')}/config/executors.json`)
    const registry = JSON.parse(source.replace(/^\uFEFF/, ''))
    const map = registry.defaults?.githubAccounts

    if (map === null || typeof map !== 'object' || Array.isArray(map)) return
    const entries = Object.entries(map)
    if (entries.some(([root, login]) => !/^(?:[a-z]:\/|\/\/[^/])/i.test(root.replace(/\\/g, '/')) || typeof login !== 'string' || !/^[a-z\d][a-z\d-]{0,38}$/i.test(login))) return

    accounts = entries.map(([root, login]) => ({ root: normalize(root), label: root.replace(/\//g, '\\').replace(/\\+$/, ''), login: login as string }))
      .sort((a, b) => b.root.length - a.root.length)
    bashWrapper = registry.defaults.githubBashWrapper === true
  } catch {
    // An unavailable registry disables folder rules for this session.
  }
}

const ruleFor = (path: string) => {
  const dir = normalize(path)

  return accounts.find(rule => dir === rule.root || dir.startsWith(`${rule.root}/`))
}

// The folder gh runs in: the last absolute cd before it, else the session's.
const dirOf = (before: string, cwd: string) => {
  const moves = [...before.matchAll(CD)]

  return moves.at(-1)?.[1] ?? cwd
}

const activeLogin = async ($: EngineInterface) => {
  const configDir = (await $.env.get('GH_CONFIG_DIR')) ?? `${(await $.env.get('APPDATA')) ?? ''}/GitHub CLI`

  try {
    const hosts = await $.fs.read(`${configDir}/hosts.yml`)

    return typeof hosts === 'string' ? /^\s+user:\s*(\S+)\s*$/m.exec(hosts)?.[1] : undefined
  } catch {
    return undefined
  }
}

const verdict = async ($: EngineInterface, shell: 'bash' | 'powershell', command: string) => {
  const match = GH.exec(command)

  if (match === null || OWN_TOKEN.test(command) || (await $.env.get('GH_TOKEN')) !== undefined) {
    return undefined
  }

  const cwd = await $.session.cwd()
  const dir = dirOf(command.slice(0, match.index), cwd)
  const rule = ruleFor(dir) ?? ruleFor(cwd)

  if (rule === undefined) {
    return undefined
  }

  // Trust the folder account only when the user has installed a Bash wrapper for it.
  const wrapped = shell === 'bash' && bashWrapper ? ruleFor(dir)?.login : undefined
  const effective = wrapped ?? (await activeLogin($))

  if (effective === undefined || effective.toLowerCase() === rule.login.toLowerCase()) {
    return undefined
  }

  const token =
    shell === 'powershell'
      ? `\`$env:GH_TOKEN = gh auth token --user ${rule.login};\``
      : `\`GH_TOKEN=$(gh auth token --user ${rule.login})\``
  const wrapperFix = bashWrapper ? `Run it in Bash from ${rule.label}, or ` : ''

  return `gh-guard: this command would run as ${effective}. ${rule.label} requires ${rule.login}. ${wrapperFix}${wrapperFix ? 'prefix' : 'Prefix'} the command with ${token}. Avoid changing authentication with gh auth login/logout.`
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await loadAccounts($)

    return next(e)
  })

  on('tool.call', { tool: 'Bash' }, async ($, e, next) => {
    const reason = await verdict($, 'bash', e.command)

    return reason === undefined ? next(e) : { deny: reason }
  })

  on('tool.call', { tool: 'PowerShell' }, async ($, e, next) => {
    const reason = await verdict($, 'powershell', e.command)

    return reason === undefined ? next(e) : { deny: reason }
  })
}
