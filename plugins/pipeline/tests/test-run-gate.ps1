$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\skills\pipeline')).Path
$script = Join-Path $root 'bin\run-gate.ps1'
$failures = [Collections.Generic.List[string]]::new()
$assertions = 0

function Assert-True([bool]$Condition, [string]$Message) {
    $script:assertions++
    if (-not $Condition) { $failures.Add($Message) }
}

function Invoke-RunGate([string[]]$Arguments) {
    $output = (& pwsh -NoProfile -File $script @Arguments 2>&1 | Out-String)
    return [pscustomobject]@{ Output = $output; ExitCode = $LASTEXITCODE }
}

function Get-GitState([string]$Repo) {
    return (Get-ChildItem -LiteralPath (Join-Path $Repo '.git') -Recurse -File -Force | Sort-Object FullName | ForEach-Object { "$($_.FullName)|$($_.Length)|$($_.LastWriteTimeUtc.Ticks)" }) -join "`n"
}

$work = Join-Path ([IO.Path]::GetTempPath()) ('.test-run-gate-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $work | Out-Null
$sourceRoot = $root
$root = Join-Path $work 'skill'
Copy-Item -LiteralPath $sourceRoot -Destination $root -Recurse
. (Join-Path $PSScriptRoot 'TestSupport.ps1')
$testRegistry = Initialize-TestRegistry $root
$sampleRepo = $testRegistry.executors.'sample-app'.repo
$logRepo = $testRegistry.executors.'sample-log'.repo
$script = Join-Path $root 'bin\run-gate.ps1'


try {
    Assert-True (Test-Path -LiteralPath $script) 'bin\run-gate.ps1 missing'
    . (Join-Path $root 'bin\RunCommon.ps1')

    $lineEndingRepo = Join-Path $work 'line-ending-repo'
    $lineEndingRun = Join-Path $work 'line-ending-run'
    New-Item -ItemType Directory -Path $lineEndingRepo, $lineEndingRun | Out-Null
    $lineEndingMetaPath = Join-Path $lineEndingRun 'meta.json'
    '{"exitCode":7,"wrapperExitCode":5,"gate":{"exitCode":9}}' | Set-Content -LiteralPath $lineEndingMetaPath
    & git -C $lineEndingRepo init -b main *> $null
    & git -C $lineEndingRepo config core.autocrlf false
    foreach ($name in @("line's ending.txt", 'real.txt')) { [IO.File]::WriteAllText((Join-Path $lineEndingRepo $name), "first`nsecond`n") }
    & git -C $lineEndingRepo add .
    & git -C $lineEndingRepo -c user.name=Fixture -c user.email=fixture@example.invalid commit -m base *> $null
    Assert-True ($LASTEXITCODE -eq 0) 'line-ending fixture commit failed'
    $cleanSummary = Write-LineEndingSummary $lineEndingRepo $lineEndingRun
    $lineEndingMeta = Get-Content -Raw -LiteralPath $lineEndingMetaPath | ConvertFrom-Json
    Assert-True ($lineEndingMeta.lineEndingOnly -is [array] -and $lineEndingMeta.lineEndingOnly.Count -eq 0 -and -not $cleanSummary) 'clean repository must record an empty array without a warning'
    $lineEndingWorktree = Join-Path $work 'line-ending-worktree'
    & git -C $lineEndingRepo worktree add -b endings $lineEndingWorktree *> $null
    Assert-True ($LASTEXITCODE -eq 0) 'line-ending fixture worktree failed'
    [IO.File]::WriteAllText((Join-Path $lineEndingWorktree "line's ending.txt"), "first`r`nsecond`r`n")
    [IO.File]::WriteAllText((Join-Path $lineEndingWorktree 'real.txt'), "changed`r`nsecond`r`n")
    $lineEndingDiff = (& git -C $lineEndingWorktree diff | Out-String)
    $LASTEXITCODE = 17
    $summary = Write-LineEndingSummary $lineEndingWorktree $lineEndingRun
    Assert-True ($LASTEXITCODE -eq 17) 'line-ending diagnostic changed the native exit code'
    $lineEndingMeta = Get-Content -Raw -LiteralPath $lineEndingMetaPath | ConvertFrom-Json
    Assert-True ($lineEndingMeta.lineEndingOnly -is [array] -and $lineEndingMeta.lineEndingOnly.Count -eq 1 -and $lineEndingMeta.lineEndingOnly[0] -ceq "line's ending.txt") 'line-ending diagnostic must list only the CRLF-only worktree file'
    Assert-True (@($summary).Count -eq 1 -and $summary.Contains("git checkout -- 'line''s ending.txt'")) 'line-ending summary must print one quoted restoration command'
    Assert-True ($lineEndingMeta.exitCode -eq 7 -and $lineEndingMeta.wrapperExitCode -eq 5 -and $lineEndingMeta.gate.exitCode -eq 9) 'line-ending diagnostic changed the outcome or gate'
    Assert-True ((& git -C $lineEndingWorktree diff | Out-String) -ceq $lineEndingDiff) 'line-ending diagnostic restored or changed files'
    Write-LineEndingSummary $lineEndingRun $lineEndingRun | Out-Null
    $lineEndingMeta = Get-Content -Raw -LiteralPath $lineEndingMetaPath | ConvertFrom-Json
    Assert-True ($lineEndingMeta.lineEndingOnly -is [array] -and $lineEndingMeta.lineEndingOnly.Count -eq 0) 'non-Git target must record an empty array'

    $genericRepo = Join-Path $work "generic repo's source"
    New-Item -ItemType Directory -Path $genericRepo | Out-Null
    Set-Content -LiteralPath (Join-Path $genericRepo 'source.txt') -Value 'source'
    & git -C $genericRepo init -b main *> $null
    Assert-True ($LASTEXITCODE -eq 0) 'generic gate fixture git init failed'
    & git -C $genericRepo add source.txt *> $null
    & git -C $genericRepo -c user.name=Fixture -c user.email=fixture@example.invalid commit -m fixture *> $null
    Assert-True ($LASTEXITCODE -eq 0) 'generic gate fixture commit failed'
    $genericWorktree = Join-Path $work ".worktrees\generic repo's win-lag"
    & git -C $genericRepo worktree add -b win-lag $genericWorktree *> $null
    Assert-True ($LASTEXITCODE -eq 0) 'generic gate fixture worktree add failed'
    $genericRepo = $genericWorktree
    $genericRun = Join-Path $work "generic run's artifacts"
    $counter = Join-Path $work 'generic.count'
    $command = "Add-Content -LiteralPath '$counter' -Value 'once'"
    $briefOutput = (& pwsh -NoProfile -File (Join-Path $root 'bin\new-brief.ps1') -Repo $genericRepo -Topic generic -RunDir $genericRun -GateOwner executor -GateCommand $command -DryRun 2>&1 | Out-String)
    Assert-True ($LASTEXITCODE -eq 0 -and $briefOutput.Contains(('Full gate: `' + $command + '`'))) 'explicit full gate did not render'
    $line = [regex]::Match($briefOutput, 'after the last edit run `([^`]+)` once').Groups[1].Value
    Assert-True ($line.Contains("-Repo '" + $genericRepo.Replace("'", "''") + "'") -and $line.Contains('-GateCommand')) 'executor gate line did not quote target and override command'
    if ($line) {
        Invoke-Expression $line | Out-Null
        Assert-True ($LASTEXITCODE -eq 0) 'rendered gate line failed'
        $genericGate = Get-Content -Raw -LiteralPath (Join-Path $genericRun 'gate.json') | ConvertFrom-Json
        Assert-True ($genericGate.owner -eq 'executor' -and $genericGate.fingerprint -match '^[0-9A-F]{64}$' -and $genericGate.cwd -eq $genericRepo) 'rendered line did not write executor gate with source fingerprint'
        $reused = Invoke-LauncherGate $command $genericRepo $genericRun 20 '' ''
        Assert-True ($reused.reused -eq $true -and @(Get-Content -LiteralPath $counter).Count -eq 1) 'launcher did not reuse generic executor gate'
    }
    $launcherBrief = (& pwsh -NoProfile -File (Join-Path $root 'bin\new-brief.ps1') -Repo sample-log -Topic override -GateOwner launcher -GateCommand none -DryRun 2>&1 | Out-String)
    Assert-True ($LASTEXITCODE -eq 0 -and $launcherBrief.Contains('Full gate: `none`') -and $launcherBrief.Contains('Gate owner: launcher;') -and -not $launcherBrief.Contains('bin\run-gate.ps1')) 'explicit launcher owner did not override registry executor owner'

    # --- Non-Git fingerprint: file content and relative path, never write time or generated directories.
    $plain = Join-Path $work 'plain'
    New-Item -ItemType Directory -Path (Join-Path $plain 'src') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $plain 'src\a.txt') -Value 'alpha' -Encoding utf8
    $base = Get-SourceFingerprint $plain
    Assert-True ($base -match '^[0-9A-F]{64}$') "non-Git fingerprint missing: $base"
    foreach ($dir in @('runs', 'logs', 'node_modules', 'build', '.dart_tool', 'pkg\.git', 'pkg\node_modules')) {
        New-Item -ItemType Directory -Path (Join-Path $plain $dir) -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $plain "$dir\noise.txt") -Value 'noise' -Encoding utf8
    }
    Assert-True ((Get-SourceFingerprint $plain) -eq $base) 'excluded directories changed the non-Git fingerprint'
    (Get-Item -LiteralPath (Join-Path $plain 'src\a.txt')).LastWriteTimeUtc = [datetime]::UtcNow.AddHours(-5)
    Assert-True ((Get-SourceFingerprint $plain) -eq $base) 'write time changed the content fingerprint'
    Set-Content -LiteralPath (Join-Path $plain 'src\a.txt') -Value 'alpha2' -Encoding utf8
    $changed = Get-SourceFingerprint $plain
    Assert-True ($changed -ne $base) 'content change kept the non-Git fingerprint'
    Set-Content -LiteralPath (Join-Path $plain 'src\b.txt') -Value 'beta' -Encoding utf8
    Assert-True ((Get-SourceFingerprint $plain) -ne $changed) 'new file kept the non-Git fingerprint'

    # --- Git fingerprint: tracked and untracked non-ignored content, invariant to a commit, no Git writes.
    $gitRepo = Join-Path $work 'git'
    New-Item -ItemType Directory -Path $gitRepo | Out-Null
    & git -C $gitRepo init -b main *> $null
    Set-Content -LiteralPath (Join-Path $gitRepo '.gitignore') -Value 'ignored.txt' -Encoding utf8
    Set-Content -LiteralPath (Join-Path $gitRepo 'tracked.txt') -Value 'one' -Encoding utf8
    & git -C $gitRepo add .gitignore tracked.txt *> $null
    & git -C $gitRepo -c user.name=Fixture -c user.email=fixture@example.invalid commit -m base *> $null
    Assert-True ($LASTEXITCODE -eq 0) 'fixture git commit failed'
    Set-Content -LiteralPath (Join-Path $gitRepo 'tracked.txt') -Value 'two' -Encoding utf8
    Set-Content -LiteralPath (Join-Path $gitRepo 'untracked.txt') -Value 'new' -Encoding utf8
    Set-Content -LiteralPath (Join-Path $gitRepo 'ignored.txt') -Value 'skip' -Encoding utf8
    $gitBefore = Get-GitState $gitRepo
    $gitBase = Get-SourceFingerprint $gitRepo
    Assert-True ($gitBase -match '^[0-9A-F]{64}$') "Git fingerprint missing: $gitBase"
    Assert-True ((Get-GitState $gitRepo) -eq $gitBefore) 'fingerprint wrote under .git'
    Set-Content -LiteralPath (Join-Path $gitRepo 'ignored.txt') -Value 'skip2' -Encoding utf8
    Assert-True ((Get-SourceFingerprint $gitRepo) -eq $gitBase) 'ignored file changed the Git fingerprint'
    Set-Content -LiteralPath (Join-Path $gitRepo 'untracked.txt') -Value 'new2' -Encoding utf8
    Assert-True ((Get-SourceFingerprint $gitRepo) -ne $gitBase) 'untracked change kept the Git fingerprint'
    Set-Content -LiteralPath (Join-Path $gitRepo 'untracked.txt') -Value 'new' -Encoding utf8
    Set-Content -LiteralPath (Join-Path $gitRepo 'tracked.txt') -Value 'three' -Encoding utf8
    Assert-True ((Get-SourceFingerprint $gitRepo) -ne $gitBase) 'tracked change kept the Git fingerprint'
    Set-Content -LiteralPath (Join-Path $gitRepo 'tracked.txt') -Value 'two' -Encoding utf8
    & git -C $gitRepo add -A *> $null
    & git -C $gitRepo -c user.name=Fixture -c user.email=fixture@example.invalid commit -m same-content *> $null
    Assert-True ($LASTEXITCODE -eq 0) 'fixture git second commit failed'
    Assert-True ((Get-SourceFingerprint $gitRepo) -eq $gitBase) 'a commit of the same content changed the Git fingerprint'

    # --- run-gate.ps1: executor-owned gate.json through the launcher's gate code, exit code passed through.
    $runGreen = Join-Path $work 'run-green'
    $green = Invoke-RunGate @('-Repo', $plain, '-RunDir', $runGreen, '-GateCommand', "Write-Output 'gate-ok'; Write-Output 'FAIL text on a green run'")
    Assert-True ($green.ExitCode -eq 0 -and $green.Output -match 'run-gate: exit 0') "green run-gate failed: $($green.Output.Trim())"
    $greenJson = Get-Content -Raw -LiteralPath (Join-Path $runGreen 'gate.json') | ConvertFrom-Json
    Assert-True ($greenJson.owner -eq 'executor' -and $greenJson.reused -eq $false) 'executor gate owner or reused flag wrong'
    Assert-True ($greenJson.fingerprint -eq (Get-SourceFingerprint $plain)) 'executor gate fingerprint does not match the source'
    Assert-True ($greenJson.cwd -eq $plain -and $greenJson.exitCode -eq 0 -and $greenJson.timedOut -eq $false -and $greenJson.tail -match 'gate-ok') 'executor gate.json misses command evidence'
    Assert-True (@($greenJson.failures).Count -eq 0) 'green gate listed failures'
    Assert-True ((Get-Content -Raw -LiteralPath (Join-Path $runGreen 'gate.log')) -match 'gate-ok') 'gate.log not written'

    $runRed = Join-Path $work 'run-red'
    $red = Invoke-RunGate @('-Repo', $plain, '-RunDir', $runRed, '-GateCommand', "Write-Output ' FAIL  src/a.test.ts > adds'; Write-Output 'ok line'; exit 7")
    $redJson = Get-Content -Raw -LiteralPath (Join-Path $runRed 'gate.json') | ConvertFrom-Json
    Assert-True ($red.ExitCode -eq 7 -and $redJson.exitCode -eq 7) "red gate exit not passed through: $($red.ExitCode)"
    Assert-True (@($redJson.failures).Count -eq 1 -and @($redJson.failures)[0] -match 'FAIL  src/a.test.ts > adds') 'red gate failures not extracted'
    Assert-True ($red.Output -match 'FAIL  src/a.test.ts > adds') 'run-gate did not print the failures'
    Assert-True (@($redJson.attempts).Count -eq 1 -and $redJson.flaky -eq $false) 'non-runner command was retried'

    $retryDir = Join-Path $work 'retry-green'
    $retryCounter = Join-Path $work 'retry.count'
    $originalPath = $env:PATH
    $env:PATH = (Join-Path $PSScriptRoot 'fixtures') + [IO.Path]::PathSeparator + $env:PATH
    $env:FAKE_GATE_COUNTER = $retryCounter
    $retryCommand = 'flutter test --concurrency=3'
    $retry = Invoke-RunGate @('-Repo', $plain, '-RunDir', $retryDir, '-GateCommand', $retryCommand)
    $retryJson = Get-Content -Raw -LiteralPath (Join-Path $retryDir 'gate.json') | ConvertFrom-Json
    Assert-True ($retry.ExitCode -eq 0 -and $retryJson.flaky -eq $true -and @($retryJson.attempts).Count -eq 2) 'fail-then-pass did not become flaky green'
    Assert-True ($retryJson.attempts[0].exitCode -eq 1 -and @($retryJson.attempts[0].failures).Count -eq 2 -and $retryJson.attempts[1].exitCode -eq 0) 'retry attempt evidence missing'
    Assert-True ($null -ne $retryJson.attempts[0].PSObject.Properties['command'] -and $retryJson.attempts[0].command -eq $retryCommand -and $retryJson.attempts[1].command -eq "flutter test --concurrency=3 'test/b_test.dart'" -and $retryJson.command -eq $retryCommand) 'retry command not narrowed or base command lost'
    Assert-True ((Get-Content -LiteralPath $retryCounter)[1] -eq 'test|--concurrency=3|test/b_test.dart') 'retry invoked the full suite'
    Assert-True ($retryJson.attempts[0].log -eq (Join-Path $retryDir 'gate.attempt1.log') -and (Get-Content -Raw -LiteralPath $retryJson.attempts[0].log) -match 'breaks \[E\]') 'first attempt log not kept'
    Assert-True ($retryJson.durationSeconds -eq $retryJson.attempts[1].durationSeconds -and $retryJson.totalDurationSeconds -ge $retryJson.durationSeconds) 'gate durations lost final/total semantics'
    $env:PATH = $originalPath
    Remove-Item Env:FAKE_GATE_COUNTER
    $noFileDir = Join-Path $work 'no-file'
    New-Item -ItemType Directory -Path $noFileDir | Out-Null
    $noFileCounter = Join-Path $work 'no-file.count'
    $noFileCommand = "Add-Content -LiteralPath '$noFileCounter' -Value run; Write-Output 'FAIL no path'; exit 7"
    $noFile = Invoke-PostRunGate $noFileCommand $plain $noFileDir 20 'executor'
    Assert-True ($noFile.exitCode -eq 7 -and @($noFile.attempts).Count -eq 1 -and @(Get-Content $noFileCounter).Count -eq 1) 'failure without a test file was retried'
    $redReused = Invoke-LauncherGate $noFileCommand $plain $noFileDir 20 '' ''
    Assert-True ($redReused.reused -eq $true -and $redReused.exitCode -eq 7 -and @(Get-Content $noFileCounter).Count -eq 1) 'matching red executor gate was rerun'
    $disabledDir = Join-Path $work 'retry-disabled'
    New-Item -ItemType Directory -Path $disabledDir | Out-Null
    $disabled = Invoke-PostRunGate 'exit 7' $plain $disabledDir 20 'launcher' '' 0
    Assert-True ($disabled.exitCode -eq 7 -and @($disabled.attempts).Count -eq 1 -and $disabled.flaky -eq $false) 'zero retries did not disable retry'
    Assert-True ((Get-GateRetries ([pscustomobject]@{ gateRetries = 0 }) ([pscustomobject]@{ gateRetries = 2 })) -eq 0) 'entry retry override ignored'
    Assert-True ((Get-GateRetries $null ([pscustomobject]@{ gateRetries = 2 })) -eq 2 -and (Get-GateRetries $null ([pscustomobject]@{})) -eq 1) 'retry default fallback wrong'

    $runSlow = Join-Path $work 'run-slow'
    $slow = Invoke-RunGate @('-Repo', $plain, '-RunDir', $runSlow, '-GateCommand', 'Start-Sleep -Seconds 30', '-TimeoutMinutes', '0.02')
    $slowJson = Get-Content -Raw -LiteralPath (Join-Path $runSlow 'gate.json') | ConvertFrom-Json
    Assert-True ($slow.ExitCode -eq 124 -and $slowJson.timedOut -eq $true) 'gate timeout not reported with exit 124'
    Assert-True (@($slowJson.attempts).Count -eq 1 -and $slowJson.flaky -eq $false) 'timeout gate was retried'
    $slowRerun = Invoke-LauncherGate 'Start-Sleep -Seconds 30' $plain $runSlow 0.02 '' ''
    Assert-True ($slowRerun.reused -eq $false -and $slowRerun.owner -eq 'launcher' -and (Test-Path (Join-Path $runSlow 'gate.executor.json'))) 'timed-out executor gate was reused'

    # --- Gate output is read as UTF-8: vitest's cross survives into gate.log and failures.
    $runCross = Join-Path $work 'run-cross'
    $crossLine = "   $([char]0x00D7) adds numbers FAIL"
    $crossRun = Invoke-RunGate @('-Repo', $plain, '-RunDir', $runCross, '-GateCommand', "Write-Output ('   ' + [char]0x00D7 + ' adds numbers FAIL'); exit 1")
    $crossJson = Get-Content -Raw -LiteralPath (Join-Path $runCross 'gate.json') | ConvertFrom-Json
    Assert-True ($crossRun.ExitCode -eq 1 -and ([IO.File]::ReadAllText((Join-Path $runCross 'gate.log'))).Contains($crossLine)) 'cross line mangled in gate.log'
    Assert-True (@($crossJson.failures).Count -eq 1 -and @($crossJson.failures)[0] -ceq $crossLine) "cross line missing from failures: $(@($crossJson.failures) -join ' | ')"

    # --- Fix loops: with no gate.json in the run directory, the brief's (original) run directory is consulted.
    $origDir = Join-Path $work 'orig-run'
    $briefCounter = Join-Path $work 'brief-dir.count'
    $countCommand = "Add-Content -LiteralPath '$briefCounter' -Value run"
    & pwsh -NoProfile -File $script -Repo $plain -RunDir $origDir -GateCommand $countCommand *> $null
    $origText = Get-Content -Raw -LiteralPath (Join-Path $origDir 'gate.json')
    $fixDir = Join-Path $work 'orig-run-fix1'
    New-Item -ItemType Directory -Path $fixDir | Out-Null
    $fromBrief = Invoke-LauncherGate $countCommand $plain $fixDir 20 '' $origDir
    $fixJson = Get-Content -Raw -LiteralPath (Join-Path $fixDir 'gate.json') | ConvertFrom-Json
    Assert-True ($fromBrief.reused -eq $true -and $fixJson.reused -eq $true -and $fixJson.owner -eq 'executor' -and @(Get-Content -LiteralPath $briefCounter).Count -eq 1) 'matching gate in the brief directory not reused'
    Assert-True ($fixJson.reusedFrom -eq (Join-Path $origDir 'gate.json') -and (Get-Content -Raw -LiteralPath (Join-Path $origDir 'gate.json')) -eq $origText) 'brief-directory gate not copied with reusedFrom, or the original changed'
    Set-Content -LiteralPath (Join-Path $plain 'src\c.txt') -Value 'gamma' -Encoding utf8
    $fixDir2 = Join-Path $work 'orig-run-fix2'
    New-Item -ItemType Directory -Path $fixDir2 | Out-Null
    $rerun = Invoke-LauncherGate $countCommand $plain $fixDir2 20 '' $origDir
    Assert-True ($rerun.reused -eq $false -and $rerun.owner -eq 'launcher' -and @(Get-Content -LiteralPath $briefCounter).Count -eq 2) 'stale brief-directory gate was reused'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $fixDir2 'gate.executor.json')) -and (Get-Content -Raw -LiteralPath (Join-Path $origDir 'gate.json')) -eq $origText) 'stale brief-directory gate was moved or changed'

    $noGate = Invoke-RunGate @('-Repo', $plain, '-RunDir', (Join-Path $work 'run-none'))
    Assert-True ($noGate.ExitCode -ne 0 -and $noGate.Output -match 'no full gate') 'target without a full gate not refused'

    # A failing native command aborts a legacy string before the second command.
    $legacyDir = Join-Path $work 'legacy-chain'
    New-Item -ItemType Directory -Path $legacyDir | Out-Null
    $marker = Join-Path $work 'second-ran.txt'
    $first = "Write-Output 'FAIL first'; pwsh -NoProfile -Command 'exit 7'"
    $second = "Add-Content -LiteralPath '$marker' -Value second; Write-Output 'FAIL second'; exit 9"
    $legacy = Invoke-PostRunGate ($first + '; $a=$LASTEXITCODE; ' + $second + '; exit ($a+$LASTEXITCODE)') $plain $legacyDir 20 'executor' '' 0
    Assert-True ($legacy.exitCode -ne 0 -and -not (Test-Path $marker)) 'legacy native failure reproduction changed'
    $arrayDir = Join-Path $work 'array-gate'
    New-Item -ItemType Directory -Path $arrayDir | Out-Null
    $commands = @($first, $second)
    $arrayResult = Invoke-PostRunGate $commands $plain $arrayDir 20 'executor'
    Assert-True (@($arrayResult.attempts).Count -eq 1) 'multi-command gate was retried'
    Assert-True (Test-Path $marker) 'array gate skipped the second failing command'
    $arrayJson = Get-Content -Raw (Join-Path $arrayDir 'gate.json') | ConvertFrom-Json
    Assert-True ($arrayJson.exitCode -ne 0 -and $arrayJson.commands.Count -eq 2 -and $arrayJson.commands[0].exitCode -ne 0 -and $arrayJson.commands[1].exitCode -eq 9) 'array gate lost command exit codes'
    Assert-True ($arrayJson.commands[0].durationSeconds -ge 0 -and $arrayJson.commands[1].durationSeconds -ge 0 -and $arrayJson.commands[0].failures -contains 'FAIL first' -and $arrayJson.commands[1].failures -contains 'FAIL second') 'array gate lost command timing or failures'
    $selected = Get-GateCommand ([pscustomobject]@{commands=[pscustomobject]@{fullGate=$commands}}) '' $false ''
    Assert-True ($selected -is [array] -and $selected.Count -eq 2) 'registry array gate was flattened'
    Assert-True ((Get-GateCommand $null $commands $true '') -is [array]) 'explicit array gate was flattened'
    @{command=$commands;owner='executor'} | ConvertTo-Json | Set-Content (Join-Path $arrayDir 'brief.gate.json')
    Assert-True ((Get-GateCommand $null '' $false $arrayDir).Count -eq 2) 'sidecar array gate was flattened'
    $sidecarResult = Invoke-RunGate @('-Repo', $plain, '-RunDir', $arrayDir)
    Assert-True ($sidecarResult.ExitCode -ne 0 -and (Get-Content -Raw (Join-Path $arrayDir 'gate.json') | ConvertFrom-Json).commands.Count -eq 2) 'run-gate did not honor array sidecar'
    $greenCommands = @("Write-Output 'first green'", "Write-Output 'second green'")
    $arrayGreen = Invoke-PostRunGate $greenCommands $plain $arrayDir 20 'executor' '' 0
    $arrayReused = Invoke-LauncherGate $greenCommands $plain $arrayDir 20 '' '' 0
    Assert-True ($arrayReused.reused -and $arrayReused.commands.Count -eq 2) 'matching array gate was not reused'
    $singleArray = @('Write-Output one')
    $one = Invoke-PostRunGate $singleArray $plain $arrayDir 20 'executor' '' 0
    $oneReused = Invoke-LauncherGate $singleArray $plain $arrayDir 20 '' '' 0
    Assert-True ($oneReused.reused -and $oneReused.command -is [array] -and $oneReused.commands.Count -eq 1) 'single-element array gate was not preserved and reused'
    $arrayChanged = Invoke-LauncherGate @($greenCommands[1], $greenCommands[0]) $plain $arrayDir 20 '' '' 0
    Assert-True (-not $arrayChanged.reused -and $arrayChanged.commands[0].command -eq $greenCommands[1]) 'reordered array gate was incorrectly reused'
    $briefArrayDir = Join-Path $work 'array-brief'
    & (Join-Path $root 'bin\new-brief.ps1') -Repo $plain -Topic array -RunDir $briefArrayDir -GateOwner executor -GateCommand $greenCommands *> $null
    Assert-True ((Get-Content -Raw (Join-Path $briefArrayDir 'brief.gate.json') | ConvertFrom-Json).command.Count -eq 2) 'new-brief lost the gate array'
    $api = (Get-ExecutorRegistry $root).Executors.'acme-api'
    Assert-True ($api.gateRetries -eq 0 -and $api.heavyGate -eq $true -and $api.commands.fullGate.Count -eq 2) 'Integration gates must be separate, heavy and unretried'
    Assert-True ((Get-GateTimeoutMinutes $api 20 $false) -eq 30 -and (Get-GateTimeoutMinutes $api 45 $true) -eq 45 -and (Get-GateTimeoutMinutes $null 20 $false) -eq 20) 'registry gate timeout not applied or not overridable'
    # A hand-run heavy gate takes the machine lock; inside a launcher run it defers to the ancestor holding it.
    $runGateText = Get-Content -Raw -LiteralPath $script
    Assert-True ($runGateText.Contains("'.heavy-gate'") -and $runGateText.Contains('Test-AncestorProcess') -and $runGateText.Contains('Exit-RepoLock')) 'run-gate does not take the heavy gate lock'
    $ancestorProbe = "& { . '$((Join-Path $root 'bin\RunCommon.ps1').Replace("'", "''"))'; Write-Output ((Test-AncestorProcess $PID).ToString() + '|' + (Test-AncestorProcess 999999).ToString()) }"
    $ancestorResult = (& pwsh -NoProfile -Command $ancestorProbe 2>&1 | Out-String).Trim()
    Assert-True ($ancestorResult -eq 'True|False') "ancestor check wrong: $ancestorResult"

    # --- Failure extraction from fixture logs: vitest, flutter, hub pwsh tests; cap and override.
    $cross = [char]0x00D7
    $vitest = @(
        ' RUN  v1.6.0 D:/repo',
        ' src/ok.test.ts (3 tests) 12ms',
        "   $cross adds numbers 5ms",
        '     expected 3 to be 4',
        ' FAIL  src/bad.test.ts > adds numbers',
        'AssertionError: expected 3 to be 4',
        ' Test Files  1 failed | 1 passed (2)'
    ) -join "`n"
    $vitestFailures = @(Get-GateFailures $vitest '')
    Assert-True ($vitestFailures.Count -eq 3 -and $vitestFailures[0] -match 'adds numbers 5ms' -and $vitestFailures[1] -match '^ FAIL' -and $vitestFailures[2] -match '^AssertionError') "vitest failures wrong: $($vitestFailures -join ' | ')"
    $flutter = @(
        '00:01 +0: loading test/a_test.dart',
        '00:03 +4: test/a_test.dart: works',
        '00:04 +4 -1: test/b_test.dart: breaks [E]',
        '  Expected: <1>',
        '00:05 +4 -1: Some tests failed.'
    ) -join "`r`n"
    $flutterFailures = @(Get-GateFailures $flutter '')
    Assert-True ($flutterFailures.Count -eq 2 -and $flutterFailures[0] -match 'breaks \[E\]$' -and $flutterFailures[1] -match 'Some tests failed') "flutter failures wrong: $($flutterFailures -join ' | ')"
    $pwshLog = "pipeline skill tests: PASS (127 assertions)`nWrite-Error: handoff exceeds 950 words`ncodex-run tests: PASS (1 assertions)"
    $pwshFailures = @(Get-GateFailures $pwshLog '')
    Assert-True ($pwshFailures.Count -eq 1 -and $pwshFailures[0] -eq 'Write-Error: handoff exceeds 950 words') "pwsh failures wrong: $($pwshFailures -join ' | ')"
    $many = (0..99 | ForEach-Object { "FAIL case $_" }) -join "`n"
    $capped = @(Get-GateFailures $many '')
    Assert-True ($capped.Count -eq 40 -and $capped[0] -eq 'FAIL case 0') 'failures not capped at the first 40 lines'
    Assert-True ((Get-GateFailurePattern ([pscustomobject]@{ gateFailurePattern = 'BOOM' })) -eq 'BOOM' -and (Get-GateFailurePattern ([pscustomobject]@{ repo = 'x' })) -eq '' -and (Get-GateFailurePattern $null) -eq '') 'gateFailurePattern not read from the registry entry'
    $override = @(Get-GateFailures "x BOOM`nFAIL y" 'BOOM')
    Assert-True ($override.Count -eq 1 -and $override[0] -eq 'x BOOM') 'registry pattern did not override the defaults'

    # Retry selection preserves options, deduplicates paths and quotes literal file arguments.
    $flutterFiles = @('00:04 +4 -1: D:/repo with spaces/test/a_test.dart: breaks [E]', '00:04 +4 -1: test/b_test.dart: breaks [E]')
    $flutterRetry = Get-GateRetryCommand 'flutter test test --concurrency 3' $flutterFiles
    Assert-True ($flutterRetry -eq "flutter test --concurrency 3 'D:/repo with spaces/test/a_test.dart' 'test/b_test.dart'") 'Flutter retry did not replace directory selection or preserve options'
    Assert-True ((Get-GateRetryCommand 'flutter test --flavor production test' @('00:04 +4 -1: test/b_test.dart: breaks [E]')) -eq "flutter test --flavor production 'test/b_test.dart'") 'Flutter retry changed a value-taking option'
    $jsFailures = @(' FAIL  src/bad.test.ts > adds', 'FAIL src/other.spec.js', ' FAIL  src/bad.test.ts > subtracts')
    Assert-True ((Get-GateRetryCommand 'npx vitest run src --reporter=verbose' $jsFailures) -eq "npx vitest run --reporter=verbose 'src/bad.test.ts' 'src/other.spec.js'") 'Vitest retry did not select unique failing files'
    Assert-True ((Get-GateRetryCommand 'jest --runInBand' @("FAIL src/it's a test.spec.ts")) -eq "jest --runInBand 'src/it''s a test.spec.ts'") 'Jest retry did not quote a filename safely'
    foreach ($unsupported in @('flutter analyze', 'pwsh -File tests.ps1', 'flutter test; Write-Output done', 'flutter test | Out-String', 'npm test', 'vitest related src/a.ts', 'jest --findRelatedTests src/a.ts', 'flutter test --unknown-option value')) {
        Assert-True ($null -eq (Get-GateRetryCommand $unsupported $flutterFiles)) "unsafe or non-runner command narrowed: $unsupported"
    }
    Assert-True ($null -eq (Get-GateRetryCommand @('flutter test', 'jest') $jsFailures)) 'multi-command array was narrowed'
    Assert-True ($null -eq (Get-GateRetryCommand 'flutter test' @('Some tests failed.'))) 'pathless runner failure was narrowed'
    Assert-True ($null -eq (Get-GateRetryCommand 'flutter test' @('FAIL src/bad.test.ts'))) 'runner accepted a different runner failure format'

    # --- Registry: executor-owned gates, SampleApp architecture tests, this file in the hub gate.
    $registry = Get-Content -Raw -LiteralPath (Join-Path $root 'config\executors.json') | ConvertFrom-Json
    foreach ($entry in $registry.executors.PSObject.Properties) {
        $owner = if ($null -ne $entry.Value.PSObject.Properties['gateOwner']) { [string]$entry.Value.gateOwner } else { 'launcher' }
        if ($owner -eq 'executor') {
            Assert-True (-not [string]::IsNullOrWhiteSpace($entry.Value.commands.fullGate) -and $entry.Value.commands.fullGate.Trim() -ine 'none') "executor gate missing for $($entry.Name)"
        }
        if ($entry.Name -in @('pipeline-tools', 'sample-app')) {
            Assert-True ($owner -eq 'executor') "short gate must be executor-owned: $($entry.Name)"
        }
    }
    Assert-True ($registry.executors.'sample-app'.commands.analyze -eq 'flutter analyze; flutter test test/architecture') 'SampleApp analyze lacks the architecture tests'
    Assert-True ($registry.executors.'pipeline-tools'.commands.fullGate -eq 'pwsh -NoProfile -File tests\run-all.ps1' -and (Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'run-all.ps1')).Contains("'test-run-gate.ps1'")) 'hub parallel fullGate lacks test-run-gate.ps1'
}
catch {
    $failures.Add($_.Exception.Message)
}
finally {
    if ($originalPath) { $env:PATH = $originalPath }
    Remove-Item Env:FAKE_GATE_COUNTER -ErrorAction SilentlyContinue
    for ($attempt = 1; $attempt -le 3 -and (Test-Path -LiteralPath $work); $attempt++) {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $work) { Start-Sleep -Milliseconds 200 }
    }
}

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Error $_ -ErrorAction Continue }
    exit 1
}

Write-Output "run-gate tests: PASS ($assertions assertions)"
