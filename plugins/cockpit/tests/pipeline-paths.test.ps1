Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
$fixtureRoot = Join-Path $repoRoot ('build\pipeline\cockpit-plugin\path-fixtures-' + [guid]::NewGuid().ToString('N'))
$source = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot '..\hooks\pipeline.ts')
$teamCommand = [regex]::Match($source, '(?m)^export const TEAM_REGISTRY_COMMAND = (".*")\r?$').Groups[1].Value | ConvertFrom-Json
$runPathCommand = [regex]::Match($source, "(?m)^export const RUN_PATH_COMMAND = '([^']*)'\r?$").Groups[1].Value
$previous = @{}
foreach ($name in @('PIPELINE_HOME', 'CC_LAUNCHER', 'CC_PATH', 'CC_CWD')) { $previous[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
$checks = 0

function Assert-Equal($Actual, $Expected, [string]$Label) {
    if ($Actual -cne $Expected) { throw "$Label`: expected '$Expected', received '$Actual'" }
    $script:checks++
    Write-Output "PASS $Label"
}

function Read-Command([string]$Command) {
    $value = (& pwsh -NoProfile -NonInteractive -Command $Command | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { throw "Path command exited $LASTEXITCODE" }
    return $value
}

try {
    New-Item -ItemType Directory -Force -Path $fixtureRoot | Out-Null
    . (Join-Path $repoRoot 'plugins\pipeline\skills\pipeline\bin\RunCommon.ps1')
    $env:CC_CWD = $fixtureRoot
    $env:CC_PATH = 'runs\current'
    Assert-Equal (Read-Command $runPathCommand) (Join-Path $fixtureRoot 'runs\current') 'relative explicit run path'

    $skill = Join-Path $fixtureRoot 'Plugin Cache\pipeline\skills\pipeline'
    New-Item -ItemType Directory -Force -Path (Join-Path $skill 'bin'), (Join-Path $skill 'config') | Out-Null
    $launcher = Join-Path $skill 'bin\codex-run.ps1'
    Set-Content -LiteralPath $launcher -Value '# fixture; never executed'
    $env:CC_LAUNCHER = $launcher
    Assert-Equal (Read-Command $teamCommand) (Join-Path $skill 'config\executors.json') 'marketplace cache with spaces'
    $link = Join-Path $fixtureRoot 'linked-skill'
    New-Item -ItemType Junction -Path $link -Target $skill | Out-Null
    $env:CC_LAUNCHER = Join-Path $link 'bin\codex-run.ps1'
    Assert-Equal (Read-Command $teamCommand) (Join-Path $skill 'config\executors.json') 'linked skill resolves team registry'

    $state = Join-Path $fixtureRoot 'state'
    New-Item -ItemType Directory -Force -Path (Join-Path $state 'config') | Out-Null
    Set-Content -LiteralPath (Join-Path $state 'config\executors.json') -Value '{"schemaVersion":1,"executors":{"acme-docs":{"commands":{"fullGate":"none"}}}}'
    $clone = Join-Path $fixtureRoot 'DocsCheckout'
    New-Item -ItemType Directory -Force -Path $clone | Out-Null
    $team = Get-ExecutorRegistry $state
    $script:fixtureOrigin = "git@github.com:$($team.Executors.'acme-docs'.github).git"
    $script:fixtureCommon = Join-Path $clone '.git'
    function Test-Path {
        param([string]$LiteralPath, [string]$PathType)
        if ($LiteralPath -eq $script:fixtureCommon) { return $true }
        if ($PathType) { return Microsoft.PowerShell.Management\Test-Path -LiteralPath $LiteralPath -PathType $PathType }
        return Microsoft.PowerShell.Management\Test-Path -LiteralPath $LiteralPath
    }
    function git {
        $global:LASTEXITCODE = 0
        if ($args -contains 'rev-parse') { return $script:fixtureCommon }
        if ($args -contains 'get-url') { return $script:fixtureOrigin }
        throw 'Unexpected Git fixture call'
    }
    $target = Resolve-ExecutorTarget $state $clone
    Assert-Equal $target.Alias 'acme-docs' 'team alias from origin differs from clone leaf'
    $brief = Join-Path $fixtureRoot 'task.md'
    $expected = Join-Path $state "runs\acme-docs\$(Get-Date -Format 'yyyy-MM-dd')-task"
    Assert-Equal (New-RunDirPath $state $target.Alias $brief) $expected 'launcher run directory uses team alias'
    foreach ($suffix in @('', '-2', '-3')) { New-Item -ItemType Directory -Force -Path "$expected$suffix" | Out-Null }
    Assert-Equal (New-RunDirPath $state $target.Alias $brief) "$expected-4" 'first free suffix beyond three'
    Set-Content -LiteralPath (Join-Path $expected 'meta.json') -Value '{}'
    Assert-Equal (New-RunDirPath $state $target.Alias (Join-Path $expected 'brief.md') $true 2) "$expected-fix2" 'resume follows metadata directory'
    Write-Output "$checks checks passed"
}
finally {
    foreach ($name in $previous.Keys) { [Environment]::SetEnvironmentVariable($name, $previous[$name], 'Process') }
    $fixtureParent = [IO.Path]::GetFullPath((Join-Path $repoRoot 'build/pipeline/cockpit-plugin')) + [IO.Path]::DirectorySeparatorChar
    if (-not [IO.Path]::GetFullPath($fixtureRoot).StartsWith($fixtureParent, [StringComparison]::OrdinalIgnoreCase)) { throw 'Fixture cleanup escaped its build directory.' }
    if ([IO.Directory]::Exists($fixtureRoot)) { Remove-Item -LiteralPath $fixtureRoot -Recurse -Force }
}
