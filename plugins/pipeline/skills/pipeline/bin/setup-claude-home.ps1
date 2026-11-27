[CmdletBinding()]
param(
    [switch]$DryRun,
    [string]$ClaudeHome = $(if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $HOME '.claude' })
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptName = 'setup-claude-home'
. (Join-Path $PSScriptRoot 'AgentLinks.ps1')

. (Join-Path $PSScriptRoot 'RunCommon.ps1')
$SkillRoot = Get-PipelineSkillRoot
$HubRoot = Get-PipelineHome -NoCreate:$DryRun
$SettingsPath = Join-Path $ClaudeHome 'settings.json'
$HubAgent = Join-Path $SkillRoot 'agents\implementer.md'
$HubSkill = $SkillRoot

# Deterministic caps on delegation (Claude Code >= 2.1.217): the executor
# cannot spawn sub-subagents, and the planning session runs at most two
# subagents at once (one executor plus one explorer).
$RequiredEnv = [ordered]@{
    CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH = '1'
    CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS = '2'
}

foreach ($required in @($HubAgent, (Join-Path $HubSkill 'SKILL.md'))) {
    if (-not (Test-Path -LiteralPath $required)) {
        throw "Missing $required. The planning session writes it; do not create it here."
    }
}

foreach ($relative in @('agents\implementer.md', 'skills\pipeline')) {
    $legacy = Get-LinkEntry (Join-Path $ClaudeHome $relative)
    if ($null -ne $legacy -and $legacy.LinkType -in @('SymbolicLink', 'Junction')) {
        Write-Step "removing legacy link $($legacy.FullName)"
        if (-not $DryRun) { $legacy.Delete() }
    }
}

# --- settings.json: add the env caps, keep everything else byte-for-byte in meaning.
$settingsRaw = if (Test-Path -LiteralPath $SettingsPath) { Get-Content -Raw -LiteralPath $SettingsPath } else { '{}' }
$settingsNewline = if ($settingsRaw -match "`r`n") { "`r`n" } else { "`n" }
$settings = $settingsRaw | ConvertFrom-Json
if ($null -eq $settings.PSObject.Properties['env']) {
    $settings | Add-Member -NotePropertyName env -NotePropertyValue ([pscustomobject]@{})
}
$missing = @()
foreach ($name in $RequiredEnv.Keys) {
    $current = $settings.env.PSObject.Properties[$name]
    if ($null -eq $current -or [string]$current.Value -ne $RequiredEnv[$name]) { $missing += $name }
}
if ($missing.Count -gt 0) {
    Write-Step "adding env $($missing -join ', ') to $SettingsPath"
}
$missingAutoCompactWindow = $null -eq $settings.PSObject.Properties['autoCompactWindow']
if ($missingAutoCompactWindow) {
    Write-Step "adding autoCompactWindow to $SettingsPath"
}
if ($missing.Count -gt 0 -or $missingAutoCompactWindow) {
    if (-not $DryRun) {
        if (-not (Test-Path -LiteralPath $ClaudeHome)) { New-Item -ItemType Directory -Force -Path $ClaudeHome | Out-Null }
        if (Test-Path -LiteralPath $SettingsPath) { Copy-Item -LiteralPath $SettingsPath -Destination "$SettingsPath.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')" }
        foreach ($name in $missing) {
            if ($null -ne $settings.env.PSObject.Properties[$name]) { $settings.env.$name = $RequiredEnv[$name] }
            else { $settings.env | Add-Member -NotePropertyName $name -NotePropertyValue $RequiredEnv[$name] }
        }
        if ($missingAutoCompactWindow) {
            $settings | Add-Member -NotePropertyName autoCompactWindow -NotePropertyValue 400000
        }
        $json = ($settings | ConvertTo-Json -Depth 32) -replace "`r?`n", $settingsNewline
        [IO.File]::WriteAllText($SettingsPath, $json + $settingsNewline, [Text.UTF8Encoding]::new($false))
    }
}

Write-Output "${ScriptName}: done"
