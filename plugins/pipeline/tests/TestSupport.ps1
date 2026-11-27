function Initialize-TestRegistry([string]$Root) {
    $registry = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'fixtures\executors.json') | ConvertFrom-Json
    $raw = $registry | ConvertTo-Json -Depth 32
    $raw = $raw.Replace('{{root}}', ($Root | ConvertTo-Json -Compress).Trim('"'))
    $registry = $raw | ConvertFrom-Json
    New-Item -ItemType Directory -Force -Path (Join-Path $Root 'config') | Out-Null
    foreach ($entry in $registry.executors.PSObject.Properties) {
        New-Item -ItemType Directory -Force -Path $entry.Value.repo | Out-Null
        & git -C $entry.Value.repo init -b fixture-branch *> $null
        if ($LASTEXITCODE) { throw "fixture git init failed: $($entry.Name)" }
    }
    $workflowDir = Join-Path $registry.executors.'sample-app'.repo '.github\workflows'
    New-Item -ItemType Directory -Force -Path $workflowDir | Out-Null
    Set-Content (Join-Path $workflowDir 'ci-sample-app.yml') 'name: fixture'
    $registry | ConvertTo-Json -Depth 32 | Set-Content -LiteralPath (Join-Path $Root 'config\executors.json') -Encoding utf8
    @{ projects = @{} } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Root 'config\projects.json')
    $env:PIPELINE_HOME = $Root
    $env:CODEX_HOME = Join-Path $Root 'codex-home'
    $env:CLAUDE_CONFIG_DIR = Join-Path $Root 'claude-home'
    New-Item -ItemType Directory -Force -Path $env:CODEX_HOME,$env:CLAUDE_CONFIG_DIR | Out-Null
    Set-Content -LiteralPath (Join-Path $env:CODEX_HOME 'config.toml') -Value "[mcp_servers.sample-service]`ncommand = 'fixture'"
    return $registry
}

function Test-RetroLauncher([string]$Provider, [scriptblock]$Invoke) {
    $identityBrief = Join-Path $work 'retro-identity.md'
    $briefModel = if ($Provider -eq 'codex') { 'gpt-6.1-terra' } else { 'claude-haiku-5-5' }
    $overrideModel = if ($Provider -eq 'codex') { 'gpt-6.2-sol' } else { 'claude-opus-5-5' }
    Set-Content $identityBrief "Target: fixture. Executor: $Provider ``$briefModel``; effort ``high``."
    $base = @('-Repo', $repoB, '-Brief', $identityBrief, '-SkipQuotaCheck', '-GateCommand', 'none')
    $identity = & $Invoke ($base + @('-DryRun'))
    $modelFlag = if ($Provider -eq 'codex') { "model=$briefModel" } else { "--model $briefModel" }
    $effortFlag = if ($Provider -eq 'codex') { 'model_reasoning_effort=high' } else { '--effort high' }
    Assert-True ($identity.ExitCode -eq 0 -and $identity.Output.Contains($modelFlag) -and $identity.Output.Contains($effortFlag)) "$Provider ignored brief model/effort: $($identity.Output)"
    $override = & $Invoke ($base + @('-Model', $overrideModel, '-Effort', 'medium', '-DryRun'))
    Assert-True ($override.ExitCode -eq 0 -and $override.Output -match "identity override:.*$briefModel.*high.*$overrideModel.*medium") "$Provider did not explain explicit identity override"
    $modelOnly = & $Invoke ($base + @('-Model', $overrideModel, '-DryRun'))
    Assert-True ($modelOnly.ExitCode -eq 0 -and $modelOnly.Output.Contains($effortFlag)) "$Provider explicit model suppressed brief effort"
    $effortOnly = & $Invoke ($base + @('-Effort', 'medium', '-DryRun'))
    Assert-True ($effortOnly.ExitCode -eq 0 -and $effortOnly.Output.Contains($modelFlag)) "$Provider explicit effort suppressed brief model"
    $identityDir = Join-Path $work 'retro-identity'
    $identityRun = & $Invoke ($base + @('-RunDir', $identityDir))
    $identityMeta = Get-Content -Raw (Join-Path $identityDir 'meta.json') | ConvertFrom-Json
    Assert-True ($identityRun.ExitCode -eq 0 -and $identityMeta.model -eq $briefModel -and $identityMeta.briefModel -eq $briefModel -and $identityMeta.briefEffort -eq 'high') "$Provider did not record brief identity"
    $actualEffort = if ($Provider -eq 'codex') { $identityMeta.reasoningEffort } else { $identityMeta.effort }
    Assert-True ($actualEffort -eq 'high') "$Provider launched at a different effort from the brief"
    Set-Content $identityBrief "Executor: $Provider ``$overrideModel``; effort ``medium``."
    $resume = & $Invoke ($base + @('-RunDir', $identityDir, '-Resume', $identityMeta.sessionId, '-FixLoop', '1', '-DryRun'))
    Assert-True ($resume.ExitCode -eq 0 -and $resume.Output.Contains($modelFlag) -and $resume.Output.Contains($effortFlag)) "$Provider let brief identity replace recorded resume identity"
    $explicitRun = & $Invoke ($base + @('-RunDir', (Join-Path $work 'retro-explicit'), '-Model', $briefModel, '-Effort', 'high'))
    $explicitMeta = Get-Content -Raw (Join-Path $work 'retro-explicit\meta.json') | ConvertFrom-Json
    Assert-True ($explicitRun.ExitCode -eq 0 -and $explicitMeta.model -eq $briefModel -and $explicitMeta.briefModel -eq $overrideModel -and $explicitMeta.briefEffort -eq 'medium') "$Provider lost brief identity when parameters override it"

    $commonPath = Join-Path $root 'bin\RunCommon.ps1'
    $commonText = [IO.File]::ReadAllText($commonPath)
    $powerLog = Join-Path $work 'retro-power.log'
    # Override only the native seam in the fixture, keeping launcher acquisition and cleanup real.
    Add-Content $commonPath @"
function Set-RunExecutionState([bool]`$Required) {
    Add-Content -LiteralPath '$powerLog' -Value `$Required
}
"@
    try {
        $notesBrief = Join-Path $work 'retro-notes.md'
        Set-Content $notesBrief "## Known state`nNo device work.`n`nRepo notes:`n- Run adb -s emulator-5554 emu geo fix 9 45.`n`n## Verify`nNone."
        $notesPath = Get-RepoLockPath $lockDir (Get-DeviceLockTarget $root 'emulator-5554')
        @{ pid = $PID; processStartTime = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o'); runDir = 'held-notes-device' } | ConvertTo-Json | Set-Content $notesPath
        $notesRun = & $Invoke @('-Repo', $repoB, '-Brief', $notesBrief, '-SkipQuotaCheck', '-GateCommand', 'none', '-RunDir', (Join-Path $work 'retro-notes'))
        Assert-True ($notesRun.ExitCode -eq 0 -and (Test-Path $notesPath)) "$Provider locked a device mentioned only in Repo notes"
        Assert-True ((Get-Content $powerLog) -join ',' -eq 'True,False') "$Provider notes run leaked power hold"
        Remove-Item $powerLog, $notesPath

        foreach ($surface in @('Device: `R58M123ABC`', 'Device: emulator-5556', "## Known state`nUse ``emulator-5556`` for screenshots.`n`nRepo notes:`n- adb -s emulator-5554 emu geo fix 9 45.`n`n## Verify`nNone.", "Device: ``192.168.1.2:5555``")) {
            $deviceBrief = Join-Path $work 'retro-device.md'
            Set-Content $deviceBrief $surface
            $serial = if ($surface -match 'emulator-5556') { 'emulator-5556' } elseif ($surface -match '192') { '192.168.1.2:5555' } else { 'R58M123ABC' }
            $deviceTarget = Get-DeviceLockTarget $root $serial
            $devicePath = Get-RepoLockPath $lockDir $deviceTarget
            $holder = @{ pid = $PID; processStartTime = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o'); runDir = 'held-device-run' }
            $holder | ConvertTo-Json | Set-Content $devicePath
            $deviceBase = @('-Repo', $repoB, '-Brief', $deviceBrief, '-SkipQuotaCheck', '-GateCommand', 'none')
            $busy = & $Invoke ($deviceBase + @('-RunDir', (Join-Path $work 'retro-device-busy')))
            Assert-True ($busy.ExitCode -eq 3 -and $busy.Output.Contains("device busy: $serial") -and $busy.Output.Contains('held-device-run')) "$Provider did not refuse shared device: $serial"
            Assert-True (-not (Test-Path (Get-RepoLockPath $lockDir $repoB))) "$Provider device refusal leaked repo lock"
            Assert-True ((Get-Content $powerLog) -join ',' -eq 'True,False') "$Provider device refusal leaked power hold"
            Remove-Item $powerLog
            $holder.pid = [int]::MaxValue
            $holder | ConvertTo-Json | Set-Content $devicePath
            $stale = & $Invoke ($deviceBase + @('-RunDir', (Join-Path $work "retro-device-$serial".Replace(':', '-'))))
            Assert-True ($stale.ExitCode -eq 0 -and $stale.Output.Contains('stale device lock taken over') -and -not (Test-Path $devicePath)) "$Provider did not reclaim/release stale device: $serial"
            Assert-True ((Get-Content $powerLog) -join ',' -eq 'True,False') "$Provider successful run leaked power hold"
            Remove-Item $powerLog
        }

        Set-Content $deviceBrief 'Use emulator-5554 and emulator-5556.'
        $devicePath = Get-RepoLockPath $lockDir (Get-DeviceLockTarget $root 'emulator-5556')
        $holder.pid = $PID
        $holder | ConvertTo-Json | Set-Content $devicePath
        $partial = & $Invoke ($deviceBase + @('-RunDir', (Join-Path $work 'retro-partial-lock')))
        $firstDevicePath = Get-RepoLockPath $lockDir (Get-DeviceLockTarget $root 'emulator-5554')
        Assert-True ($partial.ExitCode -eq 3 -and $partial.Output.Contains('emulator-5556') -and -not (Test-Path $firstDevicePath) -and (Test-Path $devicePath)) "$Provider failed to release an earlier device after a later refusal"
        Assert-True ((Get-Content $powerLog) -join ',' -eq 'True,False') "$Provider partial device refusal leaked power hold"
        Remove-Item $powerLog, $devicePath
        $dry = & $Invoke ($deviceBase + @('-DryRun'))
        Assert-True ($dry.ExitCode -eq 0 -and -not (Test-Path $powerLog) -and -not (Test-Path $firstDevicePath) -and -not (Test-Path $devicePath)) "$Provider dry run acquired power/device state"

        $crashText = [IO.File]::ReadAllText($commonPath)
        $signature = 'function Enter-RepoLock([string]$LockDir, [string]$RepoPath, [string]$RunDir) {'
        [IO.File]::WriteAllText($commonPath, $crashText.Replace($signature, $signature + "`n    if ([IO.Path]::GetFileName(`$RepoPath) -like '.device-*') { throw 'injected device acquisition error' }"))
        $crash = & $Invoke ($deviceBase + @('-RunDir', (Join-Path $work 'retro-device-crash')))
        Assert-True ($crash.ExitCode -eq 1 -and $crash.Output.Contains('injected device acquisition error')) "$Provider lost device acquisition error"
        Assert-True ((Get-Content $powerLog) -join ',' -eq 'True,False') "$Provider launcher error leaked power hold"
        Assert-True (-not (Test-Path (Get-RepoLockPath $lockDir $repoB))) "$Provider launcher error leaked repo lock"
        Remove-Item $powerLog
        [IO.File]::WriteAllText($commonPath, $crashText)

        $fakePath = Join-Path $fakeBin "$Provider.cmd"
        $fakeText = [IO.File]::ReadAllText($fakePath)
        try {
            [IO.File]::WriteAllText($fakePath, "@echo off`r`nif `"%~1`"==`"auth`" goto original`r`npwsh -NoProfile -Command `"Start-Sleep -Seconds 30`"`r`nexit /b 0`r`n:original`r`n" + $fakeText)
            $timeout = & $Invoke ($deviceBase + @('-RunDir', (Join-Path $work 'retro-device-timeout'), '-TimeoutMinutes', '0.02'))
            Assert-True ($timeout.ExitCode -eq 124) "$Provider device fixture did not time out: $($timeout.Output)"
            Assert-True ((Get-Content $powerLog) -join ',' -eq 'True,False') "$Provider timeout leaked power hold"
            Assert-True (-not (Test-Path $firstDevicePath) -and -not (Test-Path $devicePath) -and -not (Test-Path (Get-RepoLockPath $lockDir $repoB))) "$Provider timeout leaked device/repo lock"
        }
        finally { [IO.File]::WriteAllText($fakePath, $fakeText) }
    }
    finally { [IO.File]::WriteAllText($commonPath, $commonText) }
}
