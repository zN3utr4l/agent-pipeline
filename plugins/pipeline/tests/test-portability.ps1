$ErrorActionPreference = 'Stop'
$skill = Join-Path $PSScriptRoot '..\skills\pipeline'
. (Join-Path $skill 'bin\RunCommon.ps1')
$work = Join-Path ([IO.Path]::GetTempPath()) ('pipeline-port-' + [guid]::NewGuid())
$previousHome = $env:PIPELINE_HOME
$assertions = 0
function Assert-True([bool]$Condition, [string]$Message) {
    $script:assertions++
    if (-not $Condition) { throw $Message }
}
try {
    $env:PIPELINE_HOME = Join-Path $work 'state'
    $state = Get-PipelineHome
    Assert-True ($state -eq $env:PIPELINE_HOME -and (Test-Path $state -PathType Container)) 'PIPELINE_HOME must be created separately from code'
    $registry = Get-ExecutorRegistry $state
    Assert-True ($registry.Defaults.quotaCapPercent -eq 85 -and $registry.Defaults.maxFixLoops -eq 2) 'packaged guard defaults must survive'
    Assert-True ($null -eq $registry.Defaults.PSObject.Properties['githubAccounts']) 'example registry must not contain accounts'
    Assert-True ($null -eq (Get-GitHubAccount $state $work)) 'account selection must be optional'
    Assert-True (@($registry.Executors.PSObject.Properties).Count -eq 3) 'all three example entries must ship'
    foreach ($entry in $registry.Executors.PSObject.Properties) {
        Assert-True ($entry.Value.github -match '^[^/]+/[^/]+$') "example origin missing: $($entry.Name)"
        Assert-True ($entry.Value.repo -eq "C:\Example\Checkouts\$($entry.Name)" -and $null -eq $entry.Value.PSObject.Properties['writableRoots']) "local state leaked: $($entry.Name)"
    }
    $repo = Join-Path $work 'checkout'
    New-Item -ItemType Directory -Force -Path $repo | Out-Null
    & git -C $repo init -b main *> $null
    if ($LASTEXITCODE) { throw 'fixture git init failed' }
    $slug = $registry.Executors.'acme-api'.github
    & git -C $repo remote add origin "git@github.com:$slug.git" *> $null
    if ($LASTEXITCODE) { throw 'fixture origin failed' }
    $target = Resolve-ExecutorTarget $state $repo
    Assert-True ($target.Alias -eq 'acme-api' -and $target.Path -eq $repo) 'origin must resolve the example alias'
    $userRegistry = Join-Path $state 'config\executors.json'
    '{"executors":{"acme-api":{"repo":null}}}' | Set-Content -LiteralPath $userRegistry
    Push-Location $repo
    try { $aliasTarget = Resolve-ExecutorTarget $state 'acme-api' }
    finally { Pop-Location }
    Assert-True ($aliasTarget.Path -eq $repo) 'alias without a path must resolve the matching current checkout'
    @{ defaults = @{ maxFixLoops = 1; githubAccounts = @{ $work = 'fixture-user' } }; executors = @{ 'acme-api' = @{ repo = $repo; commands = @{ fullGate = 'Write-Output user-gate' } } } } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $userRegistry
    $merged = Get-ExecutorRegistry $state
    Assert-True ($merged.Defaults.maxFixLoops -eq 1 -and $merged.Defaults.quotaCapPercent -eq 85) 'user defaults must merge'
    Assert-True ($merged.Executors.'acme-api'.github -eq $slug -and $merged.Executors.'acme-api'.commands.fullGate -eq 'Write-Output user-gate' -and $merged.Executors.'acme-api'.commands.analyze -like 'dotnet build*') 'nested user entry must merge'
    Assert-True ((Get-GitHubAccount $state $repo) -eq 'fixture-user') 'user account mapping must apply'
    Assert-True ((Resolve-ExecutorTarget $state 'acme-api').Path -eq $repo) 'explicit user repo must resolve an alias'
    $env:PIPELINE_HOME = ''
    Assert-True ((Get-PipelineHome -NoCreate) -eq (Join-Path $HOME '.pipeline')) 'default state must be outside sensitive Claude configuration'
    Write-Output "portability tests: PASS ($assertions assertions)"
}
finally {
    $env:PIPELINE_HOME = $previousHome
    if ([IO.Path]::GetFullPath($work).StartsWith([IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
}
