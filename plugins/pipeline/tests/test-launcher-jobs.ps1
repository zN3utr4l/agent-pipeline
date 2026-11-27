$ErrorActionPreference = 'Stop'
$source = (Resolve-Path (Join-Path $PSScriptRoot '..\skills\pipeline')).Path
$work = Join-Path ([IO.Path]::GetTempPath()) ('.test-launcher-jobs-' + [guid]::NewGuid())
$root = Join-Path $work 'hub'
$fakeBin = Join-Path $work 'fake-bin'
$assertions = 0
$failures = [Collections.Generic.List[string]]::new()
$originalPath = $env:PATH
$originalPipelineHome = $env:PIPELINE_HOME
$originalCodexHome = $env:CODEX_HOME
$originalClaudeHome = $env:CLAUDE_CONFIG_DIR
$older = $null
function Assert-True([bool]$Condition, [string]$Message) {
    $script:assertions++
    if (-not $Condition) { $failures.Add($Message) }
}
try {
    New-Item -ItemType Directory -Force -Path $root,$fakeBin | Out-Null
    foreach ($directory in @('bin','agents','hooks','config')) {
        Copy-Item -LiteralPath (Join-Path $source $directory) -Destination $root -Recurse
    }
    Add-Content (Join-Path $root 'bin\RunCommon.ps1') @'
function Set-RunExecutionState([bool]$Required) { }
function Invoke-TaskUsage([string]$HubRoot, [string]$RunDir, [string]$Phase) { }
'@
    . (Join-Path $PSScriptRoot 'TestSupport.ps1')
    $registry = Initialize-TestRegistry $root
    $repo = $registry.executors.'sample-app'.repo
    Copy-Item (Join-Path $PSScriptRoot 'fixtures\long-step-executor.js') $fakeBin
    Set-Content (Join-Path $fakeBin 'codex.cmd') @'
@echo off
if "%~1"=="--version" ( echo codex-cli 0.0.0 & exit /b 0 )
if "%~1"=="mcp" ( echo [] & exit /b 0 )
node "%~dp0long-step-executor.js" %*
'@
    Set-Content (Join-Path $fakeBin 'claude.cmd') @'
@echo off
if "%~1"=="auth" ( echo {"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty"} & exit /b 0 )
node "%~dp0long-step-executor.js" %*
'@
    Set-Content (Join-Path $fakeBin 'codeburn.cmd') @'
@echo off
echo {"providers":[{"id":"codex","available":true,"windows":[{"label":"Weekly","usedPct":10}]},{"id":"claude","available":true,"windows":[{"label":"Weekly","usedPct":10}]}]}
'@
    $env:PATH = "$fakeBin;$PSHOME;$(Split-Path (Get-Command node).Source);$(Split-Path (Get-Command git).Source);$env:SystemRoot\System32"
    $older = Start-Process node -ArgumentList '-e "setInterval(() => {}, 1000)"' -WindowStyle Hidden -PassThru
    $env:LONG_STEP_OLDER = [string]$older.Id
    foreach ($provider in @('codex','claude')) {
        foreach ($mode in @('success','rate-limit','timeout')) {
            $run = Join-Path $work "$provider-$mode"
            New-Item -ItemType Directory -Path $run | Out-Null
            $brief = Join-Path $run 'brief.md'
            Set-Content $brief '# Fixture brief'
            $env:LONG_STEP_RUN = $run
            $env:LONG_STEP_PROVIDER = $provider
            $env:LONG_STEP_MODE = $mode
            $minutes = if ($mode -eq 'timeout') { '0.3' } else { '1' }
            $arguments = @('-NoProfile','-File',('"' + (Join-Path $root "bin\$provider-run.ps1") + '"'),'-Repo',('"' + $repo + '"'),'-Brief',('"' + $brief + '"'),'-RunDir',('"' + $run + '"'),'-LockDir',('"' + (Join-Path $work 'locks') + '"'),'-GateCommand','none','-TimeoutMinutes',$minutes)
            $launcher = Start-Process pwsh -ArgumentList $arguments -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $run 'launcher.out') -RedirectStandardError (Join-Path $run 'launcher.err')
            if (-not $launcher.WaitForExit(60000)) { $launcher.Kill($true); throw "$provider/$mode fixture launcher did not exit" }
            $output = (Get-Content -Raw (Join-Path $run 'launcher.out')) + (Get-Content -Raw (Join-Path $run 'launcher.err'))
            $code = $launcher.ExitCode
            $expected = if ($mode -eq 'timeout') { 124 } elseif ($mode -eq 'rate-limit') { 1 } else { 0 }
            Assert-True ($code -eq $expected) "$provider/$mode exit $code, expected ${expected}: $output"
            Assert-True ((Get-Content -Raw (Join-Path $run 'executor-prompt.md')).Contains("Run directory: $run")) "$provider/$mode did not supply run directory"
            $childrenPath = Join-Path $run 'children.json'
            Assert-True (Test-Path $childrenPath) "$provider/$mode did not start child"
            if (Test-Path $childrenPath) {
                $children = @(Get-Content -Raw $childrenPath | ConvertFrom-Json)
                foreach ($childId in $children) {
                    Assert-True ($null -eq (Get-Process -Id $childId -ErrorAction SilentlyContinue)) "$provider/$mode left child $childId alive"
                }
                $meta = Get-Content -Raw (Join-Path $run 'meta.json') | ConvertFrom-Json
                Assert-True ($children[0] -in $meta.stoppedJobs -or ($mode -eq 'timeout' -and $meta.processTerminated)) "$provider/$mode did not record job termination"
            }
            Assert-True ($null -ne (Get-Process -Id $older.Id -ErrorAction SilentlyContinue)) "$provider/$mode stopped an older unrelated process"
            Assert-True ((Test-Path (Join-Path $run 'jobs.pid')) -and (Get-Content -Raw (Join-Path $run 'jobs.pid')) -in @('', $null)) "$provider/$mode did not empty jobs.pid"
        }
    }
}
finally {
    if ($older -and -not $older.HasExited) { $older.Kill($true); $older.WaitForExit() }
    foreach ($file in Get-ChildItem -LiteralPath $work -Filter children.json -Recurse -ErrorAction SilentlyContinue) {
        foreach ($childId in @(Get-Content -Raw $file | ConvertFrom-Json)) {
            $child = Get-Process -Id $childId -ErrorAction SilentlyContinue
            if ($child) { $child.Kill($true); $child.WaitForExit() }
        }
    }
    $env:PATH = $originalPath
    $env:PIPELINE_HOME = $originalPipelineHome
    $env:CODEX_HOME = $originalCodexHome
    $env:CLAUDE_CONFIG_DIR = $originalClaudeHome
    foreach ($name in @('LONG_STEP_RUN','LONG_STEP_PROVIDER','LONG_STEP_MODE','LONG_STEP_OLDER')) { Remove-Item "Env:\$name" -ErrorAction SilentlyContinue }
    if ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($work)) -ne [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetTempPath())) { throw 'unsafe fixture cleanup path' }
    Remove-Item -LiteralPath $work -Recurse -Force
}
if ($failures.Count) { $failures | ForEach-Object { Write-Output "FAIL: $_" }; Write-Output "launcher-jobs tests: FAIL ($($failures.Count) failures, $assertions assertions)"; exit 1 }
Write-Output "launcher-jobs tests: PASS ($assertions assertions)"
