[CmdletBinding()]
param(
    [switch]$DryRun,
    [string]$CodexHome = $(if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }),
    [string]$ClaudeHome = $(if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $HOME '.claude' }),
    [string]$AgentsSkills = (Join-Path $HOME '.agents/skills'),
    [string[]]$ActivePluginDirectory = @(),
    [string[]]$AdoptSkill = @(),
    [string[]]$VerifiedMcpServer = @(),
    [string]$PlanPath,
    [string]$ApplyPlan,
    [switch]$Rollback,
    [switch]$SyncSkillsOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptName = 'setup-codex-home'
. (Join-Path $PSScriptRoot 'AgentLinks.ps1')

$CodexHome = [IO.Path]::GetFullPath($CodexHome)
$ClaudeHome = [IO.Path]::GetFullPath($ClaudeHome)
$AgentsSkills = [IO.Path]::GetFullPath($AgentsSkills)
if ($SyncSkillsOnly -or $Rollback) {
    Invoke-CodexSkillSync -CodexHome $CodexHome -ClaudeHome $ClaudeHome -AgentsSkills $AgentsSkills -ActivePluginDirectory $ActivePluginDirectory -AdoptSkill $AdoptSkill -VerifiedMcpServer $VerifiedMcpServer -DryRun $DryRun.IsPresent -PlanPath $PlanPath -ApplyPlan $ApplyPlan -Rollback:$Rollback
    return
}

. (Join-Path $PSScriptRoot 'RunCommon.ps1')
$SkillRoot = Get-PipelineSkillRoot
$HubRoot = Get-PipelineHome -NoCreate:$DryRun
$SkillsDir = Join-Path $CodexHome 'skills'
$HubAgents = Join-Path $SkillRoot 'agents\codex-AGENTS.md'
$HubPipeline = $SkillRoot

function Ensure-TomlTopLevelKey([string]$Path, [string]$Key, [string]$Value) {
    $lines = [Collections.Generic.List[string]]::new()
    if (Test-Path -LiteralPath $Path) { $lines.AddRange([string[]](Get-Content -LiteralPath $Path)) }
    $firstTable = $lines.FindIndex([Predicate[string]] { param($line) $line -match '^\s*\[' })
    $topCount = if ($firstTable -ge 0) { $firstTable } else { $lines.Count }
    $pattern = "^\s*$([regex]::Escape($Key))\s*="
    for ($i = 0; $i -lt $topCount; $i++) {
        if ($lines[$i] -match $pattern) { return }
    }
    Write-Step "adding $Key = $Value to $Path"
    if ($DryRun) { return }
    $backup = "$Path.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    $existed = Test-Path -LiteralPath $Path
    if ($existed) { Copy-Item -LiteralPath $Path -Destination $backup }
    $lines.Insert($topCount, "$Key = $Value")
    $lines.Insert($topCount + 1, '')
    Set-Content -LiteralPath $Path -Value $lines -Encoding utf8
    if (-not (Get-Command python -ErrorAction SilentlyContinue)) { Write-Warning 'Python unavailable; existing TOML was preserved apart from the numeric root key.'; return }
    & python -c "import tomllib,sys; tomllib.load(open(sys.argv[1],'rb'))" $Path 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        if ($existed) { Copy-Item -LiteralPath $backup -Destination $Path -Force } else { [IO.File]::Delete($Path) }
        throw "config.toml did not parse after the edit; restored from $backup"
    }
}

if (-not (Test-Path -LiteralPath $HubAgents)) {
    throw "Missing $HubAgents. The planning session writes it; do not create it here."
}
if (-not (Test-Path -LiteralPath $HubPipeline -PathType Container)) {
    throw "Missing $HubPipeline. The planning session writes it; do not create it here."
}

$skillsEntry = Get-LinkEntry $SkillsDir
if ($skillsEntry -and $skillsEntry.LinkType) { throw 'Skills root must be a real directory; unknown root link preserved.' }
Invoke-CodexSkillSync -CodexHome $CodexHome -ClaudeHome $ClaudeHome -AgentsSkills $AgentsSkills -ActivePluginDirectory $ActivePluginDirectory -AdoptSkill $AdoptSkill -VerifiedMcpServer $VerifiedMcpServer -DryRun $DryRun.IsPresent -PlanPath $PlanPath -ApplyPlan $ApplyPlan

# These two legacy setup-owned links retain the original caller contract.
Ensure-Link (Join-Path $SkillsDir 'pipeline') $HubPipeline $DryRun.IsPresent

Ensure-Link (Join-Path $CodexHome 'AGENTS.md') $HubAgents $DryRun.IsPresent

Ensure-TomlTopLevelKey (Join-Path $CodexHome 'config.toml') 'project_doc_max_bytes' '131072'

Write-Output "${ScriptName}: done (see provenance and portability above)"
