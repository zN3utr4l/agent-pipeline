$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\skills\pipeline')).Path
$work = Join-Path ([IO.Path]::GetTempPath()) ('pipeline-setup-' + [guid]::NewGuid())
$codexHome = Join-Path $work 'codex'
$claudeHome = Join-Path $work 'claude'
$env:PIPELINE_HOME = Join-Path $work 'state'
$assertions = 0
function Assert-True([bool]$Condition, [string]$Message) {
    $script:assertions++
    if (-not $Condition) { throw $Message }
}
function Invoke-Setup([string]$Name, [string[]]$Extra = @()) {
    $arguments = @('-ClaudeHome', $claudeHome) + $Extra
    if ($Name -eq 'setup-codex-home.ps1') { $arguments += @('-CodexHome', $codexHome) }
    $output = (& pwsh -NoProfile -File (Join-Path $root "bin\$Name") @arguments 2>&1 | Out-String)
    return [pscustomobject]@{ Output = $output; ExitCode = $LASTEXITCODE }
}
function Test-LinkResolves([string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    return $null -ne $item -and $item.LinkType -in @('SymbolicLink', 'Junction') -and $item.ResolveLinkTarget($true).Exists
}
try {
    $exceptions = foreach ($agent in @('codex-AGENTS.md','implementer.md')) {
        $text = Get-Content -Raw (Join-Path $root "agents\$agent")
        $exception = [regex]::Match($text, '(?m)^- Exception:.*').Value.TrimEnd()
        Assert-True ($exception -match 'Long steps:.*detached.*exit code.*jobs.pid.*9 minutes.*sleep.*Never end the turn.*report') "$agent long-step exception missing"
        $exception
    }
    Assert-True ($exceptions[0] -ceq $exceptions[1]) 'agent long-step exceptions must be identical'
    New-Item -ItemType Directory -Force -Path $codexHome,$claudeHome | Out-Null
    Set-Content (Join-Path $codexHome 'config.toml') "[existing]`nvalue = true"
    Set-Content (Join-Path $claudeHome 'settings.json') '{"effortLevel":"xhigh","enabledPlugins":{"fixture@team":true}}'
    foreach ($name in @('brainstorming','writing-plans','test-driven-development','systematic-debugging','verification-before-completion','sample-ui','executing-plans','using-superpowers','subagent-driven-development')) {
        $directory = Join-Path $claudeHome "skills\$name"
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
        Set-Content (Join-Path $directory 'SKILL.md') '# Fixture skill'
    }
    $plugin = Join-Path $work 'plugin-cache'
    $pluginSkill = Join-Path $plugin 'skills\sample-ui'
    New-Item -ItemType Directory -Force -Path $pluginSkill,(Join-Path $claudeHome 'plugins') | Out-Null
    Set-Content (Join-Path $pluginSkill 'SKILL.md') '# Plugin skill'
    @{ plugins = @{ 'fixture@team' = @(@{ scope = 'user'; installPath = $plugin }) } } | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $claudeHome 'plugins\installed_plugins.json')
    foreach ($name in @('synced-skill','docs','google-workspace','import-memory','morning')) {
        $directory = Join-Path $claudeHome "skills\synced\fixture\$name"
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
        Set-Content (Join-Path $directory 'SKILL.md') '# Synced skill'
    }
    New-Item -ItemType Directory -Force -Path (Join-Path $codexHome 'skills') | Out-Null
    $dry = Invoke-Setup 'setup-codex-home.ps1' @('-DryRun')
    Assert-True ($dry.ExitCode -eq 0 -and -not (Test-Path (Join-Path $codexHome 'AGENTS.md'))) "dry setup must not write: $($dry.Output)"
    $first = Invoke-Setup 'setup-codex-home.ps1'
    Assert-True ($first.ExitCode -eq 0) "Codex setup failed: $($first.Output)"
    foreach ($name in @('pipeline','brainstorming','writing-plans','test-driven-development','systematic-debugging','verification-before-completion','sample-ui')) {
        Assert-True (Test-LinkResolves (Join-Path $codexHome "skills\$name")) "skill not linked: $name"
    }
    foreach ($name in @('executing-plans','using-superpowers','subagent-driven-development')) {
        Assert-True (-not (Test-Path (Join-Path $codexHome "skills\$name"))) "execution skill exposed: $name"
    }
    Assert-True ((Get-Item (Join-Path $codexHome 'skills\sample-ui')).ResolveLinkTarget($true).FullName -eq $pluginSkill) 'enabled plugin must take precedence over user skill'
    Assert-True (Test-LinkResolves (Join-Path $codexHome 'skills\synced-skill')) 'synced skill must be shared'
    foreach ($name in @('docs','google-workspace','import-memory','morning')) {
        Assert-True (-not (Test-Path (Join-Path $codexHome "skills\$name"))) "Claude-only synced skill exposed: $name"
    }
    Assert-True (Test-LinkResolves (Join-Path $codexHome 'AGENTS.md')) 'Codex instructions must resolve'
    $toml = Get-Content -Raw (Join-Path $codexHome 'config.toml')
    Assert-True (($toml -split '(?m)^\s*\[')[0] -match 'project_doc_max_bytes = 131072') 'root TOML key missing'
    Assert-True (@(Get-ChildItem $codexHome -Filter 'config.toml.bak-*').Count -eq 1) 'TOML backup missing'
    $second = Invoke-Setup 'setup-codex-home.ps1'
    Assert-True ($second.ExitCode -eq 0 -and $second.Output -notmatch '(?m)^setup-codex-home: (link|relink|removing|adding)') 'Codex setup must be idempotent'
    $legacyAgent = Join-Path $claudeHome 'agents\implementer.md'
    $legacySkill = Join-Path $claudeHome 'skills\pipeline'
    New-Item -ItemType Directory -Force -Path (Split-Path $legacyAgent) | Out-Null
    New-Item -ItemType SymbolicLink -Path $legacyAgent -Target (Join-Path $root 'agents\implementer.md') | Out-Null
    New-Item -ItemType Junction -Path $legacySkill -Target $root | Out-Null
    $dryClaude = Invoke-Setup 'setup-claude-home.ps1' @('-DryRun')
    Assert-True ($dryClaude.ExitCode -eq 0 -and (Test-LinkResolves $legacyAgent) -and (Test-LinkResolves $legacySkill)) 'dry Claude setup must preserve legacy links'
    $firstClaude = Invoke-Setup 'setup-claude-home.ps1'
    Assert-True ($firstClaude.ExitCode -eq 0) "Claude setup failed: $($firstClaude.Output)"
    Assert-True (-not (Test-Path $legacyAgent) -and -not (Test-Path $legacySkill)) 'Claude setup must remove duplicate legacy links'
    Assert-True ((Test-Path (Join-Path $root 'agents\implementer.md')) -and (Test-Path (Join-Path $root 'SKILL.md'))) 'removing legacy links must preserve their targets'
    $settings = Get-Content -Raw (Join-Path $claudeHome 'settings.json') | ConvertFrom-Json
    Assert-True ($settings.env.CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH -eq '1' -and $settings.env.CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS -eq '2') 'delegation caps missing'
    Assert-True ($settings.autoCompactWindow -eq 400000 -and $settings.effortLevel -eq 'xhigh' -and $settings.enabledPlugins.'fixture@team') 'Claude settings were lost'
    Assert-True (@(Get-ChildItem $claudeHome -Filter 'settings.json.bak-*').Count -eq 1) 'Claude backup missing'
    $secondClaude = Invoke-Setup 'setup-claude-home.ps1'
    Assert-True ($secondClaude.ExitCode -eq 0 -and $secondClaude.Output -notmatch '(?m)^setup-claude-home: (link|relink|adding|removing|deleting)') 'Claude setup must be idempotent'
    Assert-True (Test-Path (Join-Path $env:PIPELINE_HOME 'runs\.locks')) 'state layout not initialized'
    $updated = Join-Path $work 'updated-skill'
    Copy-Item -LiteralPath $root -Destination $updated -Recurse
    $root = $updated
    $relink = Invoke-Setup 'setup-codex-home.ps1'
    Assert-True ($relink.ExitCode -eq 0 -and $relink.Output.Contains('relink')) 'cache update not relinked for Codex'
    $updatedClaude = Invoke-Setup 'setup-claude-home.ps1'
    Assert-True ($updatedClaude.ExitCode -eq 0 -and -not (Test-Path $legacyAgent) -and -not (Test-Path $legacySkill)) 'Claude setup must not create duplicate links after a cache update'
    Assert-True ((Get-Item (Join-Path $codexHome 'skills\pipeline')).ResolveLinkTarget($true).FullName -eq $updated) 'updated Codex skill points to old cache'
    $linkedBrief = & pwsh -NoProfile -File (Join-Path $codexHome 'skills\pipeline\bin\new-brief.ps1') -Repo $work -Topic linked-skill -DryRun 2>&1 | Out-String
    Assert-True ($LASTEXITCODE -eq 0 -and $linkedBrief.Contains((Join-Path $updated 'templates\report.md'))) 'linked skill must resolve code from the updated plugin cache'
    foreach ($contents in @('', 'user instructions')) {
        (Get-Item (Join-Path $codexHome 'AGENTS.md')).Delete()
        Set-Content (Join-Path $codexHome 'AGENTS.md') $contents -NoNewline
        $conflict = Invoke-Setup 'setup-codex-home.ps1'
        if ($contents.Length -eq 0) {
            Assert-True ($conflict.ExitCode -eq 0 -and (Test-LinkResolves (Join-Path $codexHome 'AGENTS.md'))) 'empty file must be replaced with the link'
        }
        else {
            Assert-True ($conflict.ExitCode -ne 0 -and [IO.File]::ReadAllText((Join-Path $codexHome 'AGENTS.md')) -ceq $contents) 'non-empty file must never be overwritten'
        }
        [IO.File]::Delete((Join-Path $codexHome 'AGENTS.md'))
        $restore = Invoke-Setup 'setup-codex-home.ps1'
        Assert-True ($restore.ExitCode -eq 0) 'fixture restore failed'
    }
    Set-Content $legacyAgent '' -NoNewline
    New-Item -ItemType Directory -Path $legacySkill | Out-Null
    Set-Content (Join-Path $legacySkill 'SKILL.md') 'user skill'
    $realClaude = Invoke-Setup 'setup-claude-home.ps1'
    Assert-True ($realClaude.ExitCode -eq 0 -and (Get-Item $legacyAgent).Length -eq 0 -and (Get-Content -Raw (Join-Path $legacySkill 'SKILL.md')).Trim() -eq 'user skill') 'Claude migration must preserve real files and directories, even empty ones'
    $brokenHome = Join-Path $work 'broken-claude'
    $claudeHome = $brokenHome
    New-Item -ItemType Directory -Force -Path (Join-Path $brokenHome 'agents'),(Join-Path $brokenHome 'skills') | Out-Null
    $missingTarget = Join-Path $work 'legacy-target'
    New-Item -ItemType Directory -Path $missingTarget | Out-Null
    New-Item -ItemType SymbolicLink -Path (Join-Path $brokenHome 'agents\implementer.md') -Target $missingTarget | Out-Null
    New-Item -ItemType SymbolicLink -Path (Join-Path $brokenHome 'skills\pipeline') -Target $missingTarget | Out-Null
    (Get-Item $missingTarget).Delete()
    $brokenClaude = Invoke-Setup 'setup-claude-home.ps1'
    Assert-True ($brokenClaude.ExitCode -eq 0 -and $null -eq (Get-Item (Join-Path $brokenHome 'agents\implementer.md') -Force -ErrorAction SilentlyContinue) -and $null -eq (Get-Item (Join-Path $brokenHome 'skills\pipeline') -Force -ErrorAction SilentlyContinue)) 'Claude migration must remove broken legacy links'
    $codexHome = Join-Path $work 'fresh-codex'; $claudeHome = Join-Path $work 'fresh-claude'
    foreach ($name in @('setup-codex-home.ps1','setup-claude-home.ps1')) {
        $fresh = Invoke-Setup $name
        Assert-True ($fresh.ExitCode -eq 0) "fresh home failed: $($fresh.Output)"
    }
    Write-Output "agent setup tests: PASS ($assertions assertions)"
}
finally {
    if ([IO.Path]::GetFullPath($work).StartsWith([IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
}
