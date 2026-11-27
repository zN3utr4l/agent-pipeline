import { expect, mock, test } from 'claude-code/testing'
import type { On } from 'claude-code'

const hosts = (login: string) =>
  `github.com:\n    git_protocol: https\n    users:\n        acme-user:\n        personal-user:\n    user: ${login}\n`

const WORKSPACE = 'C:/Example/Acme'
const ACCOUNTS_FILE = 'C:/Example/State/config/executors.json'
const config = (githubAccounts: Record<string, string> = { [WORKSPACE]: 'acme-user' }, githubBashWrapper = false) =>
  JSON.stringify({ defaults: { githubAccounts, githubBashWrapper } })

const world = (on: On, active: string, cwd = WORKSPACE, registry: string | null = config(), onRegistryRead?: () => void) => {
  const ran: string[] = []

  mock.env(on, { APPDATA: 'C:/Users/example/AppData/Roaming', PIPELINE_HOME: 'C:/Example/State' })
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  on('session.cwd', () => ({ value: cwd }))
  on('fs.read', ($, e) => {
    if (e.path.replace(/\\/g, '/') === ACCOUNTS_FILE) {
      onRegistryRead?.()
      if (registry === null) throw new Error('ENOENT')
      return { value: registry }
    }
    return { value: hosts(active) }
  })
  on('tool.call', ($, e) => {
    ran.push(String(e.tool))

    return { result: {} as never, text: 'ok' }
  })

  return ran
}

test('blocks gh from PowerShell when the active account is the other one', async ($, on) => {
  const ran = world(on, 'personal-user')
  await $.session.start({ cwd: WORKSPACE, surface: 'terminal', isInteractive: true })
  const result = await $.tool.call({ tool: 'PowerShell', command: 'gh pr list' })

  expect(ran.length).toBe(0)
  expect(JSON.stringify(result)).toContain('requires acme-user')
})

test('lets gh from PowerShell through when the active account fits', async ($, on) => {
  const ran = world(on, 'acme-user')
  await $.session.start({ cwd: WORKSPACE, surface: 'terminal', isInteractive: true })

  await $.tool.call({ tool: 'PowerShell', command: 'gh pr list' })
  expect(ran).toEqual(['PowerShell'])
})

test('trusts the bash wrapper inside a ruled folder', async ($, on) => {
  const ran = world(on, 'personal-user', WORKSPACE, config(undefined, true))
  await $.session.start({ cwd: WORKSPACE, surface: 'terminal', isInteractive: true })

  await $.tool.call({ tool: 'Bash', command: 'cd /c/Example/Acme/acme-api && gh pr view 3' })
  expect(ran).toEqual(['Bash'])
})

test('checks the active account in Bash unless a wrapper is configured', async ($, on) => {
  const ran = world(on, 'personal-user')
  await $.session.start({ cwd: WORKSPACE, surface: 'terminal', isInteractive: true })
  const result = await $.tool.call({ tool: 'Bash', command: 'cd /c/Example/Acme/acme-api && gh pr view 3' })

  expect(ran.length).toBe(0)
  expect(JSON.stringify(result)).toContain('requires acme-user')
})

test('blocks bash gh run from a folder the wrapper does not know', async ($, on) => {
  const ran = world(on, 'personal-user', WORKSPACE, config(undefined, true))
  await $.session.start({ cwd: WORKSPACE, surface: 'terminal', isInteractive: true })
  const result = await $.tool.call({ tool: 'Bash', command: 'cd /c/Temp && gh pr view 3 -R org/repo' })

  expect(ran.length).toBe(0)
  expect(JSON.stringify(result)).toContain('gh-guard')
})

test('ignores commands that do not run gh, gh auth and an explicit token', async ($, on) => {
  const ran = world(on, 'personal-user')
  await $.session.start({ cwd: WORKSPACE, surface: 'terminal', isInteractive: true })

  await $.tool.call({ tool: 'PowerShell', command: 'git status; echo high' })
  await $.tool.call({ tool: 'PowerShell', command: 'gh auth status' })
  await $.tool.call({ tool: 'PowerShell', command: '$env:GH_TOKEN = gh auth token --user acme-user; gh pr list' })
  expect(ran.length).toBe(3)
})

test('leaves folders without a rule alone', async ($, on) => {
  const ran = world(on, 'personal-user', 'C:\\Example\\Unmapped')
  await $.session.start({ cwd: 'C:/Example/Unmapped', surface: 'terminal', isInteractive: true })

  await $.tool.call({ tool: 'PowerShell', command: 'gh pr list' })
  expect(ran.length).toBe(1)
})

for (const registry of [null, '{broken']) {
  test(`guard has no folder rules without a valid registry (${registry === null ? 'missing' : 'malformed'})`, async ($, on) => {
    const ran = world(on, 'personal-user', WORKSPACE, registry)
    await $.session.start({ cwd: WORKSPACE, surface: 'terminal', isInteractive: true })
    await $.tool.call({ tool: 'PowerShell', command: 'gh pr list' })
    expect(ran).toEqual(['PowerShell'])
  })
}

test('guard uses the longest configured folder prefix', async ($, on) => {
  const cwd = 'C:\\Example\\Acme\\App\\src'
  const ran = world(on, 'personal-user', cwd, config({ [WORKSPACE]: 'acme-user', 'C:\\Example\\Acme\\App': 'specific-user' }))
  await $.session.start({ cwd, surface: 'terminal', isInteractive: true })
  const result = JSON.stringify(await $.tool.call({ tool: 'PowerShell', command: 'gh pr list' }))
  expect(ran.length).toBe(0)
  expect(result).toContain('requires specific-user')
  expect(result).toContain('App')
})

test('guard reads the registry once per session and ignores sibling prefixes', async ($, on) => {
  let reads = 0
  const ran = world(on, 'personal-user', 'C:\\Example\\AcmeTwo', config(), () => {
    reads += 1
  })
  await $.session.start({ cwd: 'C:/Example/AcmeTwo', surface: 'terminal', isInteractive: true })
  await $.tool.call({ tool: 'PowerShell', command: 'gh pr list' })
  await $.tool.call({ tool: 'PowerShell', command: 'gh pr list' })
  expect(ran.length).toBe(2)
  expect(reads).toBe(1)
})
