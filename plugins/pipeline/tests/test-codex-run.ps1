$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\skills\pipeline')).Path
$script = Join-Path $root 'bin\codex-run.ps1'
$failures = [Collections.Generic.List[string]]::new()
$assertions = 0

function Assert-True([bool]$Condition, [string]$Message) {
    $script:assertions++
    if (-not $Condition) { $failures.Add($Message) }
}

function Invoke-CodexRun {
    param([string[]]$Arguments)
    if ('-DryRun' -notin $Arguments -and '-GateCommand' -notin $Arguments -and -not (Test-Path -LiteralPath (Join-Path (Split-Path $Arguments[3]) 'brief.gate.json'))) { $Arguments += @('-GateCommand', 'none') }
    $Arguments += @('-LockDir', (Join-Path $work 'locks'))
    if ('-DryRun' -notin $Arguments -and $env:FAKE_KEEP_QUOTA_CACHE -ne '1') {
        Remove-Item -LiteralPath (Join-Path $work 'locks\quota\last-good.json') -ErrorAction SilentlyContinue
    }
    $output = (& pwsh -NoProfile -File $script @Arguments 2>&1 | Out-String)
    return [pscustomobject]@{ Output = $output; ExitCode = $LASTEXITCODE }
}

$work = Join-Path ([IO.Path]::GetTempPath()) (".test-codex-run-" + [guid]::NewGuid())
$sourceRoot = $root
$root = Join-Path $work 'hub'
$script = Join-Path $root 'bin\codex-run.ps1'
$fixture = Join-Path $root ('runs\sample-app\zz-test-codex-run-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $work | Out-Null
$originalPath = $env:PATH
$originalCodexHome = $env:CODEX_HOME
$today = Get-Date -Format 'yyyy-MM-dd'

try {
    foreach ($directory in @('bin', 'config', 'agents')) {
        New-Item -ItemType Directory -Force -Path (Join-Path $root $directory) | Out-Null
    }
    Get-ChildItem -LiteralPath (Join-Path $sourceRoot 'bin') -File | Where-Object Extension -in @('.ps1', '.js', '.cmd') | Copy-Item -Destination (Join-Path $root 'bin')
    # The lifecycle seam is checked below; CLI fixtures need no repeated Windows interop compilation.
    Add-Content (Join-Path $root 'bin\RunCommon.ps1') 'function Set-RunExecutionState([bool]$Required) { }'
    $usageFixture = Join-Path $root 'bin\task-usage.js'
    $usageText = [IO.File]::ReadAllText($usageFixture).Replace('function codeburnCandidates() {', 'function codeburnCandidates() { return [];')
    [IO.File]::WriteAllText($usageFixture, $usageText, [Text.UTF8Encoding]::new($false))
    . (Join-Path $PSScriptRoot 'TestSupport.ps1')
    $testRegistry = Initialize-TestRegistry $root
    $sampleRepo = $testRegistry.executors.'sample-app'.repo
    foreach ($relative in @('agents\codex-AGENTS.md')) {
        Copy-Item -LiteralPath (Join-Path $sourceRoot $relative) -Destination (Join-Path $root $relative)
    }
    Assert-True (Test-Path -LiteralPath $script) 'missing bin\codex-run.ps1'
    Assert-True (Test-Path -LiteralPath (Join-Path $root 'bin\codex-run.cmd')) 'missing bin\codex-run.cmd'
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'config\review-schema.json') -Destination (Join-Path $root 'config')

    $brief = Join-Path $work 'diet-tasks-1-3.md'
    Set-Content -LiteralPath $brief -Value "# Brief`nDo the thing." -Encoding utf8
    New-Item -ItemType Directory -Path $fixture | Out-Null
    $fixtureBrief = Join-Path $fixture 'brief.md'
    Copy-Item -LiteralPath $brief -Destination $fixtureBrief
    $effortAlias = Invoke-CodexRun @('-Repo', 'sample-app', '-Brief', $brief, '-Effort', 'high', '-DryRun')
    Assert-True ($effortAlias.ExitCode -eq 0 -and $effortAlias.Output -match '(?m)^command: codex ') 'Effort alias did not bind to ReasoningEffort'

    # --- Dry run with an alias: the command must be complete and nothing must be written.
    # Retired explicit/default models and recorded resumes must never launch.
    $policyRegistryPath = Join-Path $root 'config\executors.json'
    $policyRegistryText = [IO.File]::ReadAllText($policyRegistryPath)
    foreach ($retired in @('gpt-6-luna', 'gpt-6-astra', 'gpt-6-sol', 'gpt-6.1-sol', 'unknown-model')) {
        $rejected = Invoke-CodexRun @('-Repo', 'sample-app', '-Brief', $brief, '-Model', $retired, '-DryRun')
        Assert-True ($rejected.ExitCode -ne 0 -and $rejected.Output -notmatch '(?m)^command:') "fresh retired model accepted: $retired (exit $($rejected.ExitCode))"
        $policyRegistry = $policyRegistryText | ConvertFrom-Json
        $policyRegistry.defaults.codexModel = $retired
        [IO.File]::WriteAllText($policyRegistryPath, ($policyRegistry | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
        $rejectedDefault = Invoke-CodexRun @('-Repo', 'sample-app', '-Brief', $brief, '-DryRun')
        Assert-True ($rejectedDefault.ExitCode -ne 0 -and $rejectedDefault.Output -notmatch '(?m)^command:') "retired registry default accepted: $retired"
        [IO.File]::WriteAllText($policyRegistryPath, $policyRegistryText, [Text.UTF8Encoding]::new($false))
        $policyRun = Join-Path $fixture ('policy-' + $retired)
        New-Item -ItemType Directory -Force -Path $policyRun | Out-Null
        $policyId = [guid]::NewGuid().ToString()
        @{ sessionId = $policyId; model = $retired; reasoningEffort = 'medium'; effort = 'medium' } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $policyRun 'meta.json') -Encoding utf8
        foreach ($overrides in @(@(), @('-Model', 'gpt-6.2-sol', '-ReasoningEffort', 'medium'))) {
            $rejectedResume = Invoke-CodexRun (@('-Repo', 'sample-app', '-Brief', $brief, '-RunDir', $policyRun, '-Resume', $policyId, '-FixLoop', '1', '-DryRun') + $overrides)
            Assert-True ($rejectedResume.ExitCode -eq 3 -and $rejectedResume.Output.Contains($retired) -and $rejectedResume.Output.Contains('fix-<n>.md') -and $rejectedResume.Output -match 'fresh executor.*same run directory' -and $rejectedResume.Output -notmatch '(?m)^command:') "retired resume not clearly refused: $retired (exit $($rejectedResume.ExitCode))"
        }
    }

    $dry = Invoke-CodexRun @('-Repo', 'sample-app', '-Brief', $brief, '-DryRun')
    $sidecarRun = Join-Path $work 'sidecar-run'
    $sidecarBrief = Join-Path $sidecarRun 'brief.md'
    $sidecarRepo = Join-Path $root 'sidecar-repo'
    New-Item -ItemType Directory -Path $sidecarRepo | Out-Null
    foreach ($relative in @('templates\brief.md','templates\report.md','vendor\ponytail\AGENTS.md','vendor\ponytail\LICENSE','vendor\ponytail\SOURCE.md')) {
        $destination = Join-Path $root $relative
        New-Item -ItemType Directory -Force -Path (Split-Path $destination) | Out-Null
        Copy-Item -LiteralPath (Join-Path $sourceRoot $relative) -Destination $destination
    }
    $renderOutput = (& pwsh -NoProfile -File (Join-Path $root 'bin\new-brief.ps1') -Repo $sidecarRepo -Topic sidecar -RunDir $sidecarRun -GateCommand 'Write-Output sidecar-gate' 2>&1 | Out-String)
    Assert-True ($LASTEXITCODE -eq 0) "sidecar brief render failed: $renderOutput"
    $sidecarDry = Invoke-CodexRun @('-Repo', $sidecarRepo, '-Brief', $sidecarBrief, '-SkipQuotaCheck', '-DryRun')
    Assert-True ($sidecarDry.ExitCode -eq 0 -and $sidecarDry.Output.Contains('gate command: Write-Output sidecar-gate')) "rendered brief gate was lost: $($sidecarDry.Output)"
    Assert-True ($sidecarDry.Output.Contains('gate source: brief.gate.json')) 'sidecar gate source missing'
    $registryDry = Invoke-CodexRun @('-Repo', 'sample-app', '-Brief', $sidecarBrief, '-SkipQuotaCheck', '-DryRun')
    Assert-True ($registryDry.ExitCode -eq 0 -and $registryDry.Output.Contains('gate command: Write-Output sidecar-gate')) "registry gate overrode sidecar: $($registryDry.Output)"
    foreach ($command in @('Write-Output explicit-gate', 'none')) {
        $overrideDry = Invoke-CodexRun @('-Repo', $sidecarRepo, '-Brief', $sidecarBrief, '-GateCommand', $command, '-SkipQuotaCheck', '-DryRun')
        Assert-True ($overrideDry.ExitCode -eq 0 -and $overrideDry.Output.Contains("gate command: $command") -and -not $overrideDry.Output.Contains('gate source: brief.gate.json')) 'explicit gate did not override sidecar'
    }
    Copy-Item -LiteralPath $sidecarBrief -Destination (Join-Path $sidecarRun 'fix-1.md')
    $fixDry = Invoke-CodexRun @('-Repo', $sidecarRepo, '-Brief', (Join-Path $sidecarRun 'fix-1.md'), '-SkipQuotaCheck', '-DryRun')
    Assert-True ($fixDry.ExitCode -eq 0 -and $fixDry.Output.Contains('gate command: Write-Output sidecar-gate')) 'fix brief lost sidecar gate'
    foreach ($invalid in @('{', '{}', 'null', '[]', '{"command":7,"owner":"launcher"}', '{"command":"none","owner":"other"}', '{"command":"none","owner":["executor"]}', '{"command":"none"}')) {
        Set-Content -LiteralPath (Join-Path $sidecarRun 'brief.gate.json') -Value $invalid -Encoding utf8
        $invalidDry = Invoke-CodexRun @('-Repo', $sidecarRepo, '-Brief', $sidecarBrief, '-SkipQuotaCheck', '-DryRun')
        Assert-True ($invalidDry.ExitCode -eq 3 -and $invalidDry.Output.Contains('brief.gate.json')) "malformed sidecar was not refused: $invalid"
    }
    $explicitDry = Invoke-CodexRun @('-Repo', $sidecarRepo, '-Brief', $sidecarBrief, '-GateCommand', 'none', '-SkipQuotaCheck', '-DryRun')
    Assert-True ($explicitDry.ExitCode -eq 0) 'explicit gate did not bypass malformed lower-priority sidecar'
    Remove-Item -LiteralPath (Join-Path $sidecarRun 'brief.gate.json')
    $noneDry = Invoke-CodexRun @('-Repo', $sidecarRepo, '-Brief', $sidecarBrief, '-SkipQuotaCheck', '-DryRun')
    Assert-True ($noneDry.ExitCode -eq 0 -and $noneDry.Output.Contains('gate command: none')) 'unregistered target without sidecar did not use none'

    $budget = Invoke-CodexRun @('-Repo', 'sample-app', '-Brief', $brief, '-TimeoutMinutes', '95', '-GateTimeoutMinutes', '20', '-GateCommand', 'Write-Output gate', '-SkipQuotaCheck', '-DryRun')
    Assert-True ($budget.ExitCode -eq 0 -and ($budget.Output -notmatch '115-minute background budget')) 'background budget case 95/Write-Output gate/20 failed or blocked launch'
    $budget = Invoke-CodexRun @('-Repo', 'sample-app', '-Brief', $brief, '-TimeoutMinutes', '96', '-GateTimeoutMinutes', '20', '-GateCommand', 'Write-Output gate', '-SkipQuotaCheck', '-DryRun')
    Assert-True ($budget.ExitCode -eq 0 -and ($budget.Output.Contains('warning: executor 96 + gate 20 minutes exceeds the 115-minute background budget'))) 'background budget case 96/Write-Output gate/20 failed or blocked launch'
    $budget = Invoke-CodexRun @('-Repo', 'sample-app', '-Brief', $brief, '-TimeoutMinutes', '116', '-GateTimeoutMinutes', '20', '-GateCommand', 'none', '-SkipQuotaCheck', '-DryRun')
    Assert-True ($budget.ExitCode -eq 0 -and ($budget.Output.Contains('warning: executor 116 + gate 0 minutes exceeds the 115-minute background budget'))) 'background budget case 116/none/20 failed or blocked launch'
    $budget = Invoke-CodexRun @('-Repo', 'sample-app', '-Brief', $brief, '-TimeoutMinutes', '100', '-GateTimeoutMinutes', '50', '-GateCommand', 'none', '-SkipQuotaCheck', '-DryRun')
    Assert-True ($budget.ExitCode -eq 0 -and ($budget.Output -notmatch '115-minute background budget')) 'background budget case 100/none/50 failed or blocked launch'
    $budget = Invoke-CodexRun @('-Repo', 'sample-app', '-Brief', $brief, '-TimeoutMinutes', '100', '-GateTimeoutMinutes', '50', '-GateCommand', ' ', '-SkipQuotaCheck', '-DryRun')
    Assert-True ($budget.ExitCode -eq 0 -and ($budget.Output -notmatch '115-minute background budget')) 'background budget case 100/ /50 failed or blocked launch'
    $budget = Invoke-CodexRun @('-Repo', 'sample-app', '-Brief', $brief, '-TimeoutMinutes', '100', '-GateTimeoutMinutes', '16', '-GateCommand', 'Write-Output gate', '-SkipQuotaCheck', '-DryRun')
    Assert-True ($budget.ExitCode -eq 0 -and ($budget.Output.Contains('warning: executor 100 + gate 16 minutes exceeds the 115-minute background budget'))) 'background budget case 100/Write-Output gate/16 failed or blocked launch'
    Assert-True ($dry.ExitCode -eq 0) 'dry run with an alias failed'
    Assert-True ($dry.Output -match ('(?m)^command: codex exec -C "?' + [regex]::Escape($sampleRepo) + '"? ')) 'sample-app alias did not resolve to the repository path'
    foreach ($flag in @(
            '-c approval_policy=never',
            '-c sandbox_mode=workspace-write',
            '-c sandbox_workspace_write.network_access=true',
            '-c windows.sandbox_private_desktop=false',
            '-c model=gpt-6.2-sol',
            '-c model_reasoning_effort=medium',
            '-c project_doc_max_bytes=131072',
            '-c mcp_servers.github.enabled=false',
            '-c mcp_servers.primevue.enabled=false',
            '-c mcp_servers.node_repl.enabled=false',
            '-c mcp_servers.sentry.enabled=false',
            '-c mcp_servers.sample-service.enabled=false',
            '-c mcp_servers.openaiDeveloperDocs.enabled=false',
            '--color never',
            '-o ')) {
        Assert-True ($dry.Output.Contains($flag)) "flag missing from command: $flag"
    }
    Assert-True ($dry.Output -match '(?m)^command: .* -\s*$') 'prompt is not read from stdin (the final - is missing)'
    Assert-True ($dry.Output.Contains("sandbox_workspace_write.writable_roots=") -and $dry.Output.Contains('diet-tasks-1-3')) 'run dir missing from Codex writable roots'
    Assert-True ($dry.Output.Contains('gate command: flutter test --concurrency=3')) 'registry fullGate not selected by default'
    Assert-True ($dry.Output -match "(?m)^run dir: .*\\runs\\sample-app\\$today-diet-tasks-1-3\s*$") 'default run directory does not follow runs\<alias>\<date>-<brief>'
    Assert-True ($dry.Output -match "(?m)^stdin:\s+$([regex]::Escape($brief))\s*$") 'brief was not listed as stdin'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $root "runs\sample-app\$today-diet-tasks-1-3"))) 'dry run created a run directory'

    # --- A brief whose name already carries a date must not get a second one.
    $datedBrief = Join-Path $work '2026-01-02-fix-1.md'
    Copy-Item -LiteralPath $brief -Destination $datedBrief
    $dryDated = Invoke-CodexRun @('-Repo', 'sample-app', '-Brief', $datedBrief, '-DryRun')
    Assert-True ($dryDated.ExitCode -eq 0) 'dry run with an already dated brief failed'
    Assert-True ($dryDated.Output -match "(?m)^run dir: .*\\runs\\sample-app\\2026-01-02-fix-1\s*$") 'dated stem duplicated the date in the run directory name'

    $dryFixture = Invoke-CodexRun @('-Repo', 'sample-app', '-Brief', $fixtureBrief, '-DryRun')
    Assert-True ($dryFixture.ExitCode -eq 0) 'dry run using a brief in the run directory failed'
    Assert-True ($dryFixture.Output -match "(?m)^run dir: $([regex]::Escape($fixture))\s*$") 'brief.md in the run directory did not reuse its parent directory'

    # --- Model and effort are selected per run, default to Sol/medium, and apply to resumes too.
    $drySol = Invoke-CodexRun @('-Repo', 'sample-app', '-Brief', $brief, '-Model', 'gpt-6.2-sol', '-DryRun')
    Assert-True ($drySol.ExitCode -eq 0 -and $drySol.Output.Contains('-c model=gpt-6.2-sol')) 'explicit Sol model was not passed to Codex'
    $dryTerra = Invoke-CodexRun @('-Repo', 'sample-app', '-Brief', $brief, '-Model', 'gpt-6.1-terra', '-ReasoningEffort', 'high', '-DryRun')
    Assert-True ($dryTerra.ExitCode -eq 0 -and $dryTerra.Output.Contains('-c model=gpt-6.1-terra') -and $dryTerra.Output.Contains('-c model_reasoning_effort=high')) 'Terra dry run missing model or effort'
    foreach ($mode in @('executor', '-FullAccess')) {
        $astraArgs = @('-Repo', 'sample-app', '-Brief', $brief, '-Model', 'gpt-6.2-astra', '-Effort', 'high', '-DryRun')
        if ($mode -ne 'executor') { $astraArgs += $mode }
        $dryAstra = Invoke-CodexRun $astraArgs
        Assert-True ($dryAstra.ExitCode -eq 0 -and $dryAstra.Output -match '(?m)^command: .* -c model=gpt-6\.2-astra(?: |$)') "Astra dry run missing model in $mode mode"
    }
    $astraBrief = Join-Path $work 'astra-brief.md'
    Set-Content -LiteralPath $astraBrief 'Executor: codex `gpt-6.2-astra`; effort `high`.'
    $briefAstra = Invoke-CodexRun @('-Repo', 'sample-app', '-Brief', $astraBrief, '-DryRun')
    Assert-True ($briefAstra.ExitCode -eq 0 -and $briefAstra.Output.Contains('-c model=gpt-6.2-astra') -and $briefAstra.Output.Contains('-c model_reasoning_effort=high')) 'launcher ignored Astra model or effort from the brief'
    $badModel = Invoke-CodexRun @('-Repo', 'sample-app', '-Brief', $brief, '-Model', 'gpt-5.5', '-DryRun')
    Assert-True ($badModel.ExitCode -ne 0) 'unsupported Codex model was accepted'
    $unknownModel = Invoke-CodexRun @('-Repo', 'sample-app', '-Brief', $brief, '-Model', 'gpt-6.2-nova', '-DryRun')
    Assert-True ($unknownModel.ExitCode -ne 0 -and $unknownModel.Output -match 'ValidateSet') 'launcher accepted an unknown Codex model'
    $retiredModel = 'gpt-5' + '.6-sol'
    $retired = Invoke-CodexRun @('-Repo', 'sample-app', '-Brief', $brief, '-Model', $retiredModel, '-DryRun')
    Assert-True ($retired.ExitCode -ne 0) 'retired Codex model was accepted'
    $dryMedium = Invoke-CodexRun @('-Repo', 'sample-app', '-Brief', $brief, '-ReasoningEffort', 'medium', '-DryRun')
    Assert-True ($dryMedium.ExitCode -eq 0) 'medium reasoning effort was refused'
    Assert-True ($dryMedium.Output.Contains('-c model_reasoning_effort=medium')) 'medium reasoning effort was not passed to Codex'
    Assert-True (-not $dryMedium.Output.Contains('-c model_reasoning_effort=high')) 'default high setting was kept alongside medium'
    $badEffort = Invoke-CodexRun @('-Repo', 'sample-app', '-Brief', $brief, '-ReasoningEffort', 'ultra', '-DryRun')
    Assert-True ($badEffort.ExitCode -ne 0) 'unsupported reasoning effort was accepted'
    $badTimeout = Invoke-CodexRun @('-Repo', 'sample-app', '-Brief', $brief, '-TimeoutMinutes', '0', '-DryRun')
    Assert-True ($badTimeout.ExitCode -ne 0) 'non-positive timeout was accepted'

    # --- Dry run with a resume id: the resume subcommand, no -C, id before the final dash.
    $resumeId = '11111111-2222-3333-4444-555555555555'
    @{ sessionId = $resumeId; model = 'gpt-6.2-sol'; reasoningEffort = 'high' } |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $fixture 'meta.json') -Encoding utf8
    $dryResume = Invoke-CodexRun @('-Repo', 'sample-app', '-Brief', $brief, '-Resume', $resumeId, '-FixLoop', '1', '-DryRun')
    Assert-True ($dryResume.ExitCode -eq 0) "resume with recorded model identity failed: $($dryResume.Output)"
    Assert-True ($dryResume.Output -match '(?m)^command: codex exec resume ') 'resume did not use the resume subcommand'
    Assert-True (-not ($dryResume.Output -cmatch ' -C ')) 'resume passed -C, which codex exec resume rejects'
    Assert-True (-not ($dryResume.Output -match '--color')) 'resume passed --color, which codex exec resume rejects'
    Assert-True ($dryResume.Output -match "(?m)^command: .* $resumeId -\s*$") 'session ID missing before the final -'
    Assert-True ($dryResume.Output.Contains('-c approval_policy=never')) 'resume dropped the -c overrides'
    Assert-True ($dryResume.Output.Contains('-c model=gpt-6.2-sol') -and $dryResume.Output.Contains('-c model_reasoning_effort=high')) 'resume did not inherit the recorded model and effort'
    $astraResumeId = '11111111-2222-3333-4444-666666666666'
    $astraRunDir = Join-Path $work 'astra-run'
    New-Item -ItemType Directory -Path $astraRunDir | Out-Null
    @{ sessionId = $astraResumeId; model = 'gpt-6.2-astra'; reasoningEffort = 'xhigh' } |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $astraRunDir 'meta.json') -Encoding utf8
    $astraResume = Invoke-CodexRun @('-Repo', 'sample-app', '-Brief', $brief, '-RunDir', $astraRunDir, '-Resume', $astraResumeId, '-FixLoop', '1', '-DryRun')
    Assert-True ($astraResume.ExitCode -eq 0 -and $astraResume.Output -match '(?m)^command: codex exec resume .* -c model=gpt-6\.2-astra(?: |$)' -and $astraResume.Output.Contains('-c model_reasoning_effort=xhigh')) 'resume lost recorded Astra model or effort'
    $fixBrief = Join-Path $fixture 'fix-1.md'
    Copy-Item -LiteralPath $brief -Destination $fixBrief
    $fixNaming = Invoke-CodexRun @('-Repo', 'sample-app', '-Brief', $fixBrief, '-Resume', $resumeId, '-FixLoop', '1', '-DryRun')
    Assert-True ($fixNaming.ExitCode -eq 0 -and $fixNaming.Output.Contains("run dir: $($fixture)-fix1")) 'resume fix brief lost its existing run directory name'
    $explicitFix = Invoke-CodexRun @('-Repo', 'sample-app', '-Brief', $fixBrief, '-Resume', $resumeId, '-FixLoop', '1', '-RunDir', (Join-Path $work 'explicit-fix'), '-DryRun')
    Assert-True ($explicitFix.ExitCode -eq 0 -and $explicitFix.Output.Contains('run dir: ' + (Join-Path $work 'explicit-fix'))) 'explicit resume run directory lost precedence'
    $originalMetaHash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $fixture 'meta.json')).Hash
    $dryOriginalResume = Invoke-CodexRun @('-Repo', 'sample-app', '-Brief', $fixtureBrief, '-Resume', $resumeId, '-FixLoop', '1', '-DryRun')
    Assert-True ($dryOriginalResume.ExitCode -eq 0 -and $dryOriginalResume.Output -notmatch "(?m)^run dir: $([regex]::Escape($fixture))\s*$") 'resume reused the original directory and could overwrite its artifacts'
    Assert-True ((Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $fixture 'meta.json')).Hash -eq $originalMetaHash) 'resume lookup modified the original metadata'
    $dryResumeXhigh = Invoke-CodexRun @('-Repo', 'sample-app', '-Brief', $brief, '-Resume', $resumeId, '-FixLoop', '1', '-Model', 'gpt-6.2-sol', '-ReasoningEffort', 'xhigh', '-DryRun')
    Assert-True ($dryResumeXhigh.Output.Contains('-c model_reasoning_effort=xhigh')) 'resume dropped the explicit reasoning effort'
    Assert-True ($dryResumeXhigh.Output.Contains('-c model=gpt-6.2-sol')) 'resume dropped the explicit model'
    $legacyResume = Invoke-CodexRun @('-Repo', 'sample-app', '-Brief', $brief, '-Resume', 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee', '-FixLoop', '1', '-DryRun')
    Assert-True ($legacyResume.ExitCode -ne 0 -and $legacyResume.Output -match 'explicit original model and reasoning effort') 'legacy resume without model identity did not require the original model and effort'
    $legacyExplicit = Invoke-CodexRun @('-Repo', 'sample-app', '-Brief', $brief, '-Resume', 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee', '-FixLoop', '1', '-Model', 'gpt-6.1-terra', '-ReasoningEffort', 'medium', '-DryRun')
    Assert-True ($legacyExplicit.ExitCode -eq 0) "legacy resume with explicit model identity was refused: $($legacyExplicit.Output)"

    # --- Dry run with a path instead of an alias.
    $dryPath = Invoke-CodexRun @('-Repo', $work, '-Brief', $brief, '-DryRun')
    Assert-True ($dryPath.ExitCode -eq 0) 'dry run with a path failed'
    Assert-True ($dryPath.Output -match "(?m)^run dir: .*\\runs\\$([regex]::Escape((Split-Path $work -Leaf).ToLowerInvariant()))\\") 'alias derived from the path was not the lowercase directory name'

    # --- Lean: compaction cap, writable roots from executors.json, fix-loop gate.
    $lean = Invoke-CodexRun @('-Repo', 'sample-app', '-Brief', $brief, '-DryRun')
    Assert-True ($lean.Output.Contains('-c model_auto_compact_token_limit=200000')) 'compaction limit was not passed to Codex'
    $expectedRoots = ($testRegistry.executors.'sample-app'.writableRoots | ForEach-Object { "'$_'" }) -join ','
    Assert-True ($lean.Output.Contains("sandbox_workspace_write.writable_roots=[$expectedRoots,") -and $lean.Output.Contains("$root\runs\sample-app\")) 'sample-app writable roots were not passed as a TOML array of literal strings'
    $leanExtra = Invoke-CodexRun @('-Repo', 'sample-app', '-Brief', $brief, '-WritableRoot', 'D:\extra', '-AutoCompactTokens', '90000', '-DryRun')
    Assert-True ($leanExtra.Output -match "writable_roots=\[.*,'D:\\extra','$([regex]::Escape($root))\\runs\\sample-app\\[^']+'\]") '-WritableRoot was not added to the registry roots'
    Assert-True ($leanExtra.Output.Contains('model_auto_compact_token_limit=90000')) '-AutoCompactTokens was ignored'
    $leanPath = Invoke-CodexRun @('-Repo', $work, '-Brief', $brief, '-DryRun')
    Assert-True ($leanPath.Output -match "writable_roots=\['$([regex]::Escape($root))\\runs\\[^']+'\]") 'run directory was not the sole writable root for a repo without configured roots'
    $leanByPath = Invoke-CodexRun @('-Repo', $sampleRepo, '-Brief', $brief, '-DryRun')
    Assert-True ($leanByPath.Output -match 'writable_roots=') 'matching registry checkout path did not inherit writable roots'
    $full = Invoke-CodexRun @('-Repo', 'sample-app', '-Brief', $brief, '-FullAccess', '-DryRun')
    Assert-True ($full.ExitCode -eq 0) "-FullAccess dry run failed: $($full.Output)"
    Assert-True ($full.Output.Contains('-c sandbox_mode=danger-full-access') -and $full.Output.Contains('-c approval_policy=never')) '-FullAccess did not pass danger-full-access with approval never'
    Assert-True (-not ($full.Output -match 'workspace-write|sandbox_workspace_write|writable_roots=|sandbox_private_desktop')) '-FullAccess still included workspace-write sandbox overrides'
    $noLoop = Invoke-CodexRun @('-Repo', 'sample-app', '-Brief', $brief, '-Resume', $resumeId, '-DryRun')
    Assert-True ($noLoop.ExitCode -ne 0 -and $noLoop.Output -match '-FixLoop is required') 'resume accepted without -FixLoop'
    $loop2 = Invoke-CodexRun @('-Repo', 'sample-app', '-Brief', $brief, '-Resume', $resumeId, '-FixLoop', '2', '-DryRun')
    Assert-True ($loop2.ExitCode -eq 0) 'second fix loop was refused'
    $loop3 = Invoke-CodexRun @('-Repo', 'sample-app', '-Brief', $brief, '-Resume', $resumeId, '-FixLoop', '3', '-DryRun')
    Assert-True ($loop3.ExitCode -eq 3 -and $loop3.Output -match 'codex-run: refused \| fix loop 3 exceeds the cap of 2') 'third fix loop did not exit 3'
    $loop3ok = Invoke-CodexRun @('-Repo', 'sample-app', '-Brief', $brief, '-Resume', $resumeId, '-FixLoop', '3', '-AllowExtraFixLoop', '-DryRun')
    Assert-True ($loop3ok.ExitCode -eq 0) '-AllowExtraFixLoop was ignored'
    $loopFresh = Invoke-CodexRun @('-Repo', 'sample-app', '-Brief', $brief, '-FixLoop', '1', '-DryRun')
    Assert-True ($loopFresh.ExitCode -ne 0) '-FixLoop accepted without -Resume'

    # --- Non-Git targets need --skip-git-repo-check on fresh and resumed runs;
    # Git repositories do not get it in either mode.
    $dryPathResume = Invoke-CodexRun @('-Repo', $work, '-Brief', $brief, '-Resume', $resumeId, '-FixLoop', '1', '-Model', 'gpt-6.2-sol', '-ReasoningEffort', 'high', '-DryRun')
    Assert-True ($dryPath.Output -match '--skip-git-repo-check') 'non-Git target omitted --skip-git-repo-check'
    Assert-True ($dryPathResume.Output -match '--skip-git-repo-check') 'non-Git resume omitted --skip-git-repo-check'
    Assert-True (-not ($dry.Output -match '--skip-git-repo-check')) '--skip-git-repo-check was passed for a Git repository'
    Assert-True (-not ($dryResume.Output -match '--skip-git-repo-check')) '--skip-git-repo-check was passed in a Git repository resume'

    # --- Unknown repo and missing brief must fail loudly.
    $bad = Invoke-CodexRun @('-Repo', 'nonexistent-alias', '-Brief', $brief, '-DryRun')
    Assert-True ($bad.ExitCode -ne 0) 'unknown alias was accepted'
    $noBrief = Invoke-CodexRun @('-Repo', 'sample-app', '-Brief', (Join-Path $work 'missing.md'), '-DryRun')
    Assert-True ($noBrief.ExitCode -ne 0) 'missing brief was accepted'

    # --- Real runs against a fake codex placed first on PATH (no credit spent).
    $fakeBin = Join-Path $work 'bin'
    New-Item -ItemType Directory -Path $fakeBin | Out-Null
    $fake = @'
@echo off
if "%~1"=="--version" (
  echo codex-cli 0.0.0
  exit /b 0
)
if "%~1"=="mcp" (
  if not "%FAKE_CODEX_MCP_ARGS%"=="" echo %CD% %* >"%FAKE_CODEX_MCP_ARGS%"
  if "%FAKE_CODEX_MODE%"=="mcpfail" exit /b 1
  type "%FAKE_CODEX_MCP_LIST%"
  exit /b 0
)
echo -------- 1>&2
echo workdir: %CD% 1>&2
echo model: gpt-6.2-sol 1>&2
if not "%FAKE_CODEX_MODE%"=="timeout" echo session id: 00000000-0000-0000-0000-000000000001 1>&2
echo -------- 1>&2
echo args: %*
set FINAL_REPORT=
:parse
if "%~1"=="" goto :parsed
if "%~1"=="-o" set FINAL_REPORT=%~2
shift
goto :parse
:parsed
set /p FIRSTLINE=
echo stdin: %FIRSTLINE%
if not "%FAKE_CODEX_REVIEW%"=="" (
  copy /y "%FAKE_CODEX_REVIEW%" "%FINAL_REPORT%" >nul
  exit /b 0
)
if "%FAKE_CODEX_MODE%"=="credits" goto :credits
if "%FAKE_CODEX_MODE%"=="ratelimit" goto :ratelimit
if "%FAKE_CODEX_MODE%"=="capacity" goto :capacity
if "%FAKE_CODEX_MODE%"=="capacitytext" goto :capacitytext
if "%FAKE_CODEX_MODE%"=="sandbox" goto :sandbox
if "%FAKE_CODEX_MODE%"=="handshake" goto :handshake
if "%FAKE_CODEX_MODE%"=="echoquota" goto :echoquota
if "%FAKE_CODEX_MODE%"=="echoerrors" goto :echoerrors
if "%FAKE_CODEX_MODE%"=="timeout" goto :timeout
if "%FAKE_CODEX_MODE%"=="noreport" exit /b 0
if not "%FAKE_EXECUTOR_REPORT%"=="" echo Detailed executor report>"%FAKE_EXECUTOR_REPORT%"
echo # Report>"%FINAL_REPORT%"
echo Checked codex-windows-sandbox-setup.exe and the fs sandbox helper: all good.
exit /b 0

:credits
echo ERROR: Your workspace is out of credits. Ask your workspace owner to refill in order to continue. 1>&2
exit /b 1

:ratelimit
echo ERROR: You have hit your usage limit. Try again later. 1>&2
exit /b 1

:capacity
echo 2026-10-12T13:00:00Z ERROR codex_core::client: %FAKE_CODEX_ERROR% 1>&2
exit /b 1

:capacitytext
echo Documentation example: Selected model is at capacity; overloaded; server is busy. 1>&2
exit /b 1

:sandbox
echo 2026-09-03T13:05:11.669138Z ERROR codex_core::tools::router: error=exec_command failed: CreateProcess { message: "Rejected(\"Failed to create unified exec process: orchestrator_helper_launch_failed: setup refresh failed\")" } 1>&2
echo 2026-09-03T13:05:29.724679Z ERROR codex_core::tools::router: error=apply_patch verification failed: fs sandbox helper unavailable 1>&2
exit /b 0

:handshake
echo 2026-09-03T21:06:21.909984Z ERROR codex_core::tools::router: error=exec_command failed: CreateProcess { message: "Rejected(\"Failed to create unified exec process: runner handshake task failed: task 2354 was cancelled\")" } 1>&2
exit /b 0

:echoquota
echo # Report>"%FINAL_REPORT%"
echo Documentation examples: out of credits; HTTP 429; rate limit; usage limit.
echo stderr documentation: out of credits, 429, and rate limit are example text. 1>&2
echo The command completed normally.
exit /b 0

:echoerrors
echo ERROR: Your workspace is out of credits. 1>&2
echo ERROR: You have hit your usage limit. HTTP 429 rate limit. 1>&2
echo ERROR: Selected model is at capacity; overloaded; server is busy. 1>&2
if not "%FAKE_EXECUTOR_REPORT%"=="" echo Detailed executor report>"%FAKE_EXECUTOR_REPORT%"
echo # Report>"%FINAL_REPORT%"
exit /b 0

:timeout
echo partial-before-timeout
pwsh -NoProfile -File "%FAKE_TIMEOUT_SCRIPT%"
exit /b 0
'@
    Set-Content -LiteralPath (Join-Path $fakeBin 'codex.cmd') -Value $fake -Encoding ascii
$fakeCodeburn = @'
@echo off
if not "%FAKE_CODEBURN_COUNT%"=="" echo call>>"%FAKE_CODEBURN_COUNT%"
if "%FAKE_CODEBURN_MODE%"=="slow" pwsh -NoProfile -Command "Start-Sleep -Seconds 11"
if "%FAKE_CODEBURN_MODE%"=="fail" exit /b 1
if "%FAKE_CODEBURN_PCT%"=="" set FAKE_CODEBURN_PCT=10
if "%FAKE_CODEBURN_PCT_5H%"=="" set FAKE_CODEBURN_PCT_5H=%FAKE_CODEBURN_PCT%
echo {"providers":[{"id":"claude","available":true,"plan":"Max 5x","windows":[{"label":"Weekly","usedPct":%FAKE_CODEBURN_PCT%,"resetsAt":"2026-09-10T19:59:59.793Z"},{"label":"5h","usedPct":%FAKE_CODEBURN_PCT_5H%,"resetsAt":"2026-09-10T19:59:59.793Z"}]},{"id":"codex","available":true,"windows":[{"label":"Weekly","usedPct":%FAKE_CODEBURN_PCT%,"resetsAt":"2026-09-15T01:32:48.000Z"},{"label":"5h","usedPct":%FAKE_CODEBURN_PCT_5H%,"resetsAt":"2026-09-15T01:32:48.000Z"}]}]}
exit /b 0
'@
    Set-Content -LiteralPath (Join-Path $fakeBin 'codeburn.cmd') -Value ($fakeCodeburn -replace '2026-09-\d{2}T[\d:.]+Z', [datetimeoffset]::UtcNow.AddDays(7).ToString('o')) -Encoding ascii
    # npm installs a .ps1 shim next to the .cmd one, and pwsh resolves the script
    # first: the gate must still reach the executable shim.
    Set-Content -LiteralPath (Join-Path $fakeBin 'codeburn.ps1') -Value "Write-Output 'not json'`nexit 1" -Encoding ascii
    $env:PATH = "$fakeBin;$env:PATH"

    $fakeHome = Join-Path $work 'codexhome'
    $fakeRelease = Join-Path $fakeHome 'packages\standalone\releases\0.0.0-x86_64-pc-windows-msvc\codex-resources'
    New-Item -ItemType Directory -Path $fakeRelease -Force | Out-Null
    $fakeHelper = Join-Path $fakeRelease 'codex-windows-sandbox-setup.exe'
    Set-Content -LiteralPath $fakeHelper -Value '' -Encoding ascii
    $env:CODEX_HOME = $fakeHome

    # --- Read-only reviews use the same fake CLI, without writes or gates in the target.
    $env:FAKE_CODEX_MCP_LIST = Join-Path $work 'mcp-list.json'
    $env:FAKE_CODEX_MCP_ARGS = Join-Path $work 'mcp-args.txt'
    $env:FAKE_CODEX_REVIEW = Join-Path $work 'review-reply.json'
    Set-Content $env:FAKE_CODEX_MCP_LIST '[{"name":"context7","enabled":true},{"name":"sample-service","enabled":true},{"name":"already-off","enabled":false}]'
    $reviewValue = @{
        verdict = 'APPROVED'; summary = 'No material defect found.'
        findings = @(@{ id = 'R1'; severity = 'low'; path = 'src/example.ps1'; evidence = 'Concrete evidence'; fix = 'Concrete fix' })
        coverage = @('caller and shared-state writer'); limitations = @('Fixture review only')
    }
    $reviewValue | ConvertTo-Json -Depth 10 | Set-Content $env:FAKE_CODEX_REVIEW
    $readOnlyDryDir = Join-Path $work 'readonly-dry'
    $readOnlyDry = Invoke-CodexRun @('-Repo', 'sample-app', '-Brief', $brief, '-RunDir', $readOnlyDryDir, '-ReadOnly', '-DryRun')
    Assert-True ($readOnlyDry.ExitCode -eq 0 -and -not (Test-Path $readOnlyDryDir)) "read-only dry run failed or wrote artifacts: $($readOnlyDry.Output)"
    $readOnlyAstra = Invoke-CodexRun @('-Repo', 'sample-app', '-Brief', $brief, '-ReadOnly', '-Model', 'gpt-6.2-astra', '-Effort', 'high', '-DryRun')
    Assert-True ($readOnlyAstra.ExitCode -eq 0 -and $readOnlyAstra.Output -match '(?m)^command: .* -c model=gpt-6\.2-astra(?: |$)') 'Astra dry run missing model in read-only mode'
    foreach ($flag in @('-c sandbox_mode=read-only', '-c approval_policy=never', '--disable apps --disable plugins', '-c notify=[]', '-c mcp_servers.context7.enabled=false', '-c mcp_servers.sample-service.enabled=false', '--output-schema', 'review-schema.json', '-o ')) {
        Assert-True ($readOnlyDry.Output.Contains($flag)) "read-only dry run missing $flag"
    }
    Assert-True ($readOnlyDry.Output -notmatch 'danger-full-access|dangerously-bypass|sandbox_workspace_write|sandbox_mode=workspace-write|sandbox_private_desktop|EXECUTOR ROLE') 'read-only dry run retained executor privileges or role'
    Assert-True ((Get-Content -Raw $env:FAKE_CODEX_MCP_ARGS).Contains("$sampleRepo mcp list --json --disable apps --disable plugins")) 'MCP listing omitted target directory or feature isolation'
    foreach ($conflict in @(@('-FullAccess'), @('-FixLoop', '1'), @('-AllowExtraFixLoop'))) {
        $rejectedReview = Invoke-CodexRun (@('-Repo', 'sample-app', '-Brief', $brief, '-ReadOnly', '-DryRun') + $conflict)
        Assert-True ($rejectedReview.ExitCode -eq 3) "read-only conflict accepted: $conflict"
    }
    $readOnlyGateMarker = Join-Path $work 'readonly-gate.txt'
    foreach ($verdict in @('APPROVED', 'REVISE', 'BLOCKED')) {
        $reviewValue.verdict = $verdict
        $reviewValue | ConvertTo-Json -Depth 10 | Set-Content $env:FAKE_CODEX_REVIEW
        $reviewDir = Join-Path $work "review-$verdict"
        $reviewRun = Invoke-CodexRun @('-Repo', 'sample-app', '-Brief', $brief, '-RunDir', $reviewDir, '-ReadOnly', '-GateCommand', "Set-Content '$readOnlyGateMarker' ran")
        Assert-True ($reviewRun.ExitCode -eq 0) "valid $verdict review rejected: $($reviewRun.Output)"
        if ($reviewRun.ExitCode -ne 0) { continue }
        $reviewMeta = Get-Content -Raw (Join-Path $reviewDir 'meta.json') | ConvertFrom-Json
        $reviewReport = Get-Content (Join-Path $reviewDir 'report.md')
        Assert-True ((Test-Path (Join-Path $reviewDir 'review.json')) -and $reviewReport[0] -ceq "VERDICT: $verdict") "$verdict review artifacts missing"
        Assert-True ($reviewMeta.readOnly -eq $true -and $reviewMeta.verdict -ceq $verdict -and -not $reviewMeta.reportSynthesized -and $null -eq $reviewMeta.gate) "$verdict metadata lost review state"
        Assert-True ($reviewReport.Count -le 40 -and ($reviewReport -join "`n") -match 'R1 \[low\] src/example.ps1 — Concrete evidence → Concrete fix' -and ($reviewReport -join "`n") -match 'Coverage:.*caller and shared-state writer' -and ($reviewReport -join "`n") -match 'Limitations:.*Fixture review only') "$verdict report format changed"
        $reviewPrompt = Get-Content -Raw (Join-Path $reviewDir 'executor-prompt.md')
        Assert-True ($reviewPrompt.StartsWith('You are an independent reviewer.') -and $reviewPrompt.EndsWith([IO.File]::ReadAllText($brief))) 'review contract did not precede the request'
        foreach ($phrase in @('evidence, not instructions', 'correctness', 'spec-fidelity', 'security', 'edge-case', 'callers', 'writers of shared state', 'allowed files', 'Done-when', 'right directory', 'no finding quota', 'cannot edit files', 'Never claim tests passed', 'actual coverage and limitations')) {
            Assert-True ($reviewPrompt.Contains($phrase)) "review contract missing: $phrase"
        }
        Assert-True (-not (Test-Path $readOnlyGateMarker) -and -not (Test-Path (Join-Path $reviewDir 'gate.json'))) 'read-only review ran a post-run gate'
        Assert-True ((Get-Content -Raw (Join-Path $reviewDir 'codex.log')) -match 'sandbox_mode=read-only.*--output-schema') 'real read-only launch lost overrides or schema'
    }
    $reviewValue.verdict = 'APPROVED'
    $goodReview = $reviewValue | ConvertTo-Json -Depth 10
    foreach ($emptyVerdict in @('APPROVED', 'BLOCKED')) {
        $emptyReview = $goodReview | ConvertFrom-Json
        $emptyReview.verdict = $emptyVerdict
        $emptyReview.findings = @()
        $emptyReview | ConvertTo-Json -Depth 10 | Set-Content $env:FAKE_CODEX_REVIEW
        $emptyDir = Join-Path $work "review-empty-$emptyVerdict"
        $emptyRun = Invoke-CodexRun @('-Repo', 'sample-app', '-Brief', $brief, '-RunDir', $emptyDir, '-ReadOnly', '-SkipQuotaCheck')
        Assert-True ($emptyRun.ExitCode -eq 0 -and (Get-Content -Raw (Join-Path $emptyDir 'review.json') | ConvertFrom-Json).findings.Count -eq 0) "valid empty $emptyVerdict review rejected"
    }
    $materialReview = $goodReview | ConvertFrom-Json
    $materialReview.verdict = 'REVISE'
    $materialReview.findings[0].severity = 'high'
    $materialReview | ConvertTo-Json -Depth 10 | Set-Content $env:FAKE_CODEX_REVIEW
    $materialRun = Invoke-CodexRun @('-Repo', 'sample-app', '-Brief', $brief, '-RunDir', (Join-Path $work 'review-material'), '-ReadOnly', '-SkipQuotaCheck')
    Assert-True ($materialRun.ExitCode -eq 0) 'REVISE with a high finding was rejected'
    $invalidReviews = [ordered]@{
        empty = ''; malformed = '{'; duplicate = ($goodReview -replace '"findings": \[', '"findings": [{"id":"R1","severity":"low","path":"x","evidence":"x","fix":"x"},')
        severity = ($goodReview -replace '"low"', '"urgent"'); coverage = ($goodReview -replace '"coverage": \[[^\]]*\]', '"coverage": []')
        approvedHigh = ($goodReview -replace '"low"', '"high"'); approvedMedium = ($goodReview -replace '"low"', '"medium"')
        reviseEmpty = '{"verdict":"REVISE","summary":"Needs changes","findings":[],"coverage":["source"],"limitations":[]}'
        missingField = ($goodReview -replace '"summary": "[^"]*",?', '')
        blankSummary = ($goodReview -replace '"summary": "[^"]*"', '"summary": " "')
        wrongType = ($goodReview -replace '"limitations": \[[^\]]*\]', '"limitations": "none"')
        unknownField = ($goodReview -replace '"verdict":', '"extra": true, "verdict":')
    }
    foreach ($case in $invalidReviews.GetEnumerator()) {
        Set-Content $env:FAKE_CODEX_REVIEW $case.Value
        $invalidDir = Join-Path $work "review-invalid-$($case.Key)"
        New-Item -ItemType Directory $invalidDir | Out-Null
        Set-Content (Join-Path $invalidDir 'report.md') 'VERDICT: APPROVED'
        $invalidReview = Invoke-CodexRun @('-Repo', 'sample-app', '-Brief', $brief, '-RunDir', $invalidDir, '-ReadOnly', '-SkipQuotaCheck')
        Assert-True ($invalidReview.ExitCode -eq 1) "invalid review accepted: $($case.Key) (exit $($invalidReview.ExitCode))"
        $invalidMeta = Get-Content -Raw (Join-Path $invalidDir 'meta.json') | ConvertFrom-Json
        Assert-True ($invalidMeta.reportSynthesized -eq $true -and $invalidMeta.reportPresent -eq $false -and $null -eq $invalidMeta.verdict -and (Get-Content -Raw (Join-Path $invalidDir 'report.md')) -match '(?s)^STATUS: failed.*invalid review') "invalid review lacks failed report: $($case.Key)"
        Assert-True (-not (Test-Path (Join-Path $invalidDir 'review.json'))) "invalid review promoted to review.json: $($case.Key)"
    }
    Set-Content $env:FAKE_CODEX_REVIEW $goodReview
    $longReview = $goodReview | ConvertFrom-Json
    $longReview.findings = @(1..45 | ForEach-Object { @{ id = "R$_"; severity = 'low'; path = 'x'; evidence = "line 1`nline 2"; fix = 'fix' } })
    $longReview | ConvertTo-Json -Depth 10 | Set-Content $env:FAKE_CODEX_REVIEW
    $longDir = Join-Path $work 'review-long'
    $longRun = Invoke-CodexRun @('-Repo', 'sample-app', '-Brief', $brief, '-RunDir', $longDir, '-ReadOnly', '-SkipQuotaCheck')
    Assert-True ($longRun.ExitCode -eq 0 -and @(Get-Content (Join-Path $longDir 'report.md')).Count -le 40 -and @(Get-Content -Raw (Join-Path $longDir 'review.json') | ConvertFrom-Json | ForEach-Object findings).Count -eq 45) 'large review lost findings or exceeded report line cap'
    Set-Content $env:FAKE_CODEX_REVIEW $goodReview
    foreach ($badListing in @('', '{', '{}', 'null', '[{"name":"unsafe.name","enabled":true}]', '[{"name":"missing-enabled"}]', '[{"name":"x","enabled":"false"}]')) {
        Set-Content $env:FAKE_CODEX_MCP_LIST $badListing
        $listingRunDir = Join-Path $work ([guid]::NewGuid().ToString())
        $listingRun = Invoke-CodexRun @('-Repo', 'sample-app', '-Brief', $brief, '-RunDir', $listingRunDir, '-ReadOnly', '-SkipQuotaCheck')
        Assert-True ($listingRun.ExitCode -eq 75 -and -not (Test-Path $listingRunDir)) "unsafe MCP listing did not refuse before launch: $badListing"
    }
    $newlineListing = '[{"name":"unsafe\n","enabled":true}]'
    Set-Content $env:FAKE_CODEX_MCP_LIST $newlineListing
    $newlineListingRun = Invoke-CodexRun @('-Repo', 'sample-app', '-Brief', $brief, '-ReadOnly', '-DryRun')
    Assert-True ($newlineListingRun.ExitCode -eq 75) 'newline in MCP server name escaped safe-name validation'
    Set-Content $env:FAKE_CODEX_MCP_LIST '[]'
    $env:FAKE_CODEX_MODE = 'mcpfail'
    $listingFailed = Invoke-CodexRun @('-Repo', 'sample-app', '-Brief', $brief, '-ReadOnly', '-SkipQuotaCheck')
    Assert-True ($listingFailed.ExitCode -eq 75) 'MCP listing failure was not exit 75'
    $env:FAKE_CODEX_MODE = 'ok'
    . (Join-Path $root 'bin\RunCommon.ps1')
    $readOnlyLockDir = Join-Path $work 'locks'
    New-Item -ItemType Directory -Force $readOnlyLockDir | Out-Null
    $readOnlyLockPath = Get-RepoLockPath $readOnlyLockDir $sampleRepo
    $readOnlyOwner = @{ pid = $PID; processStartTime = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o'); runDir = 'held-review-lock' }
    $readOnlyOwner | ConvertTo-Json | Set-Content $readOnlyLockPath
    $heldLockText = Get-Content -Raw $readOnlyLockPath
    $heldReviewDir = Join-Path $work 'review-held-lock'
    $heldReview = Invoke-CodexRun @('-Repo', 'sample-app', '-Brief', $brief, '-RunDir', $heldReviewDir, '-ReadOnly', '-SkipQuotaCheck')
    Assert-True ($heldReview.ExitCode -eq 0 -and (Get-Content -Raw $readOnlyLockPath) -ceq $heldLockText) 'held repository lock blocked review or was changed'
    Remove-Item -LiteralPath $readOnlyLockPath
    $readOnlyHeavyLockPath = Get-RepoLockPath $readOnlyLockDir (Join-Path $root '.heavy-gate')
    Set-Content $readOnlyHeavyLockPath $heldLockText
    $heavyReview = Invoke-CodexRun @('-Repo', 'acme-api', '-Brief', $brief, '-RunDir', (Join-Path $work 'review-held-heavy'), '-ReadOnly', '-SkipQuotaCheck')
    Assert-True ($heavyReview.ExitCode -eq 0 -and (Get-Content -Raw $readOnlyHeavyLockPath).Trim() -ceq $heldLockText.Trim()) "heavy-gate lock blocked review or was changed: $($heavyReview.Output)"
    Remove-Item -LiteralPath $readOnlyHeavyLockPath
    $reviewSession = '00000000-0000-0000-0000-000000000001'
    $resumedReviewDir = Join-Path $work 'review-resume'
    $resumedReview = Invoke-CodexRun @('-Repo', 'sample-app', '-Brief', $brief, '-RunDir', $heldReviewDir, '-Resume', $reviewSession, '-ReadOnly', '-DryRun')
    Assert-True ($resumedReview.ExitCode -eq 0 -and $resumedReview.Output -match 'codex exec resume.*sandbox_mode=read-only.*--output-schema.*review-schema.json') 'read-only resume lost schema or overrides'
    Copy-Item -LiteralPath $heldReviewDir -Destination $resumedReviewDir -Recurse
    $resumedLiveReview = Invoke-CodexRun @('-Repo', 'sample-app', '-Brief', $brief, '-RunDir', $resumedReviewDir, '-Resume', $reviewSession, '-ReadOnly', '-SkipQuotaCheck')
    Assert-True ($resumedLiveReview.ExitCode -eq 0 -and (Get-Content -Raw (Join-Path $resumedReviewDir 'meta.json') | ConvertFrom-Json).attempts.Count -eq 1) 'read-only resume failed or lost attempt accounting'
    $normalResumeReview = Invoke-CodexRun @('-Repo', 'sample-app', '-Brief', $brief, '-RunDir', $heldReviewDir, '-Resume', $reviewSession, '-FixLoop', '1', '-DryRun')
    Assert-True ($normalResumeReview.ExitCode -eq 3) 'read-only session resumed as writable executor'
    $normalResumeWithoutLoop = Invoke-CodexRun @('-Repo', 'sample-app', '-Brief', $brief, '-RunDir', $heldReviewDir, '-Resume', $reviewSession, '-DryRun')
    Assert-True ($normalResumeWithoutLoop.ExitCode -eq 3) 'read-only resume mismatch did not return exit 3 without FixLoop'
    $mismatchDir = Join-Path $work 'review-mismatch'
    New-Item -ItemType Directory $mismatchDir | Out-Null
    foreach ($readOnlyField in @(@{}, @{readOnly = $false}, @{readOnly = 'true'})) {
        $mismatchMeta = @{ sessionId = 'aaaaaaaa-0000-0000-0000-000000000000'; model = 'gpt-6.2-sol'; reasoningEffort = 'high' } + $readOnlyField
        $mismatchMeta | ConvertTo-Json | Set-Content (Join-Path $mismatchDir 'meta.json')
        $mismatch = Invoke-CodexRun @('-Repo', 'sample-app', '-Brief', $brief, '-RunDir', $mismatchDir, '-Resume', $mismatchMeta.sessionId, '-ReadOnly', '-Model', 'gpt-6.2-sol', '-ReasoningEffort', 'high', '-DryRun')
        Assert-True ($mismatch.ExitCode -eq 3) 'read-only resume accepted missing or non-true metadata'
    }
    $unknownReview = Invoke-CodexRun @('-Repo', 'sample-app', '-Brief', $brief, '-Resume', 'ffffffff-0000-0000-0000-000000000000', '-ReadOnly', '-Model', 'gpt-6.2-sol', '-ReasoningEffort', 'high', '-DryRun')
    Assert-True ($unknownReview.ExitCode -eq 3) 'read-only resume accepted an unknown session'
    $noCodexPath = $env:PATH
    $gitOnlyBin = Split-Path (Get-Command git).Source -Parent
    $env:PATH = "$env:SystemRoot\System32;$PSHOME;$gitOnlyBin"
    try {
        $noCodexReview = Invoke-CodexRun @('-Repo', 'sample-app', '-Brief', $brief, '-ReadOnly', '-SkipQuotaCheck')
        Assert-True ($noCodexReview.ExitCode -eq 75 -and $noCodexReview.Output -match 'cannot fall back to Claude') 'unavailable Codex allowed a writable provider fallback'
    }
    finally { $env:PATH = $noCodexPath }
    Remove-Item Env:FAKE_CODEX_REVIEW, Env:FAKE_CODEX_MCP_LIST, Env:FAKE_CODEX_MCP_ARGS
    # --- End read-only reviews.

    $cacheDir = Join-Path $work 'locks\quota'
    New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
    $countPath = Join-Path $work 'codeburn-count.txt'
    $env:FAKE_CODEBURN_COUNT = $countPath
    $env:FAKE_CODEBURN_PCT = '42'
    $env:FAKE_KEEP_QUOTA_CACHE = '1'
    $firstQuota = Invoke-CodexRun @('-Repo', 'sample-app', '-Brief', $brief, '-RunDir', (Join-Path $work 'cache-first'), '-GateCommand', 'none')
    $secondQuota = Invoke-CodexRun @('-Repo', 'sample-app', '-Brief', $brief, '-RunDir', (Join-Path $work 'cache-second'), '-GateCommand', 'none')
    Assert-True ($firstQuota.Output -match 'quota gate: codex 42% .*fresh, age \d+s' -and $secondQuota.Output -match 'quota gate: codex 42% .*cached, age \d+s') 'fresh and cached quota status missing'
    Assert-True (@(Get-Content -LiteralPath $countPath).Count -eq 1) 'fresh cache started codeburn twice'
    (Get-Content -Raw -LiteralPath (Join-Path $cacheDir 'last-good.json') | ConvertFrom-Json | ForEach-Object { $_.fetchedAtUtc = [datetime]::UtcNow.AddMinutes(-20).ToString('o'); $_ | ConvertTo-Json -Depth 20 }) | Set-Content -LiteralPath (Join-Path $cacheDir 'last-good.json') -Encoding utf8
    $staleQuota = Invoke-CodexRun @('-Repo', 'sample-app', '-Brief', $brief, '-RunDir', (Join-Path $work 'cache-stale'), '-GateCommand', 'none')
    Assert-True ($staleQuota.Output -match 'fresh, age \d+s' -and @(Get-Content -LiteralPath $countPath).Count -eq 2) 'stale cache did not refresh once'
    Set-Content -LiteralPath (Join-Path $cacheDir 'last-good.json') -Value '{partial' -Encoding utf8
    $corruptQuota = Invoke-CodexRun @('-Repo', 'sample-app', '-Brief', $brief, '-RunDir', (Join-Path $work 'cache-corrupt'), '-GateCommand', 'none')
    Assert-True ($corruptQuota.Output -match 'fresh, age \d+s' -and @(Get-Content -LiteralPath $countPath).Count -eq 3) 'corrupt cache did not refresh'
    Remove-Item -LiteralPath (Join-Path $cacheDir 'last-good.json') -ErrorAction SilentlyContinue
    $env:FAKE_CODEBURN_MODE = 'slow'
    $slowQuota = Invoke-CodexRun @('-Repo', 'sample-app', '-Brief', $brief, '-RunDir', (Join-Path $work 'cache-slow'), '-GateCommand', 'none')
    Assert-True ($slowQuota.ExitCode -eq 0 -and $slowQuota.Output -match 'fresh, age \d+s') "slow codeburn refresh did not pass: $($slowQuota.Output.Trim())"
    Remove-Item -LiteralPath (Join-Path $cacheDir 'last-good.json') -ErrorAction SilentlyContinue
    $beforeConcurrent = @(Get-Content -LiteralPath $countPath).Count
    $jobs = @(
        (Start-Job -ScriptBlock { param($common, $cache) . $common; Test-QuotaGate 'codex' 85 150 '' $cache 600 } -ArgumentList (Join-Path $root 'bin\RunCommon.ps1'), $cacheDir),
        (Start-Job -ScriptBlock { param($common, $cache) . $common; Test-QuotaGate 'claude' 85 150 'claude-opus-5-5' $cache 600 } -ArgumentList (Join-Path $root 'bin\RunCommon.ps1'), $cacheDir)
    )
    $jobs | Wait-Job | Out-Null
    $concurrent = @($jobs | Receive-Job)
    $jobs | Remove-Job
    Assert-True ($concurrent.Count -eq 2 -and ($concurrent -join ' ') -match 'fresh, age' -and ($concurrent -join ' ') -match 'cached, age') 'concurrent launches did not share refreshed quota'
    Assert-True (@(Get-Content -LiteralPath $countPath).Count -eq ($beforeConcurrent + 1)) 'concurrent launches started codeburn more than once'
    Remove-Item Env:FAKE_CODEBURN_MODE, Env:FAKE_KEEP_QUOTA_CACHE, Env:FAKE_CODEBURN_COUNT -ErrorAction SilentlyContinue

    # A live owner blocks this repository, but a different repository path is free.
    . (Join-Path $root 'bin\RunCommon.ps1')
    $lockDir = Join-Path $work 'locks'
    New-Item -ItemType Directory -Path $lockDir -Force | Out-Null
    $repoA = Join-Path $work 'repo-a'
    $repoB = Join-Path $work 'repo-b'
    New-Item -ItemType Directory -Path $repoA, $repoB | Out-Null
    $lockPath = Get-RepoLockPath $lockDir $repoA
    $owner = Get-Process -Id $PID
    $held = @{ pid = $PID; processStartTime = $owner.StartTime.ToUniversalTime().ToString('o'); runDir = 'held-run'; repoPath = $repoA; startedAt = [DateTime]::UtcNow.ToString('o') }
    $held | ConvertTo-Json | Set-Content -LiteralPath $lockPath -Encoding utf8
    $dryBusy = Invoke-CodexRun @('-Repo', $repoA, '-Brief', $brief, '-DryRun')
    Assert-True ($dryBusy.ExitCode -eq 0 -and $dryBusy.Output -match 'lock: busy' -and (Test-Path -LiteralPath $lockPath)) 'DryRun must show a live lock without taking it'
    $busyDir = Join-Path $work 'busy'
    $busy = Invoke-CodexRun @('-Repo', $repoA, '-Brief', $brief, '-RunDir', $busyDir, '-SkipQuotaCheck')
    Assert-True ($busy.ExitCode -eq 3 -and $busy.Output.Contains("repo busy: $repoA (run held-run, pid $PID)")) 'live repository lock did not refuse with exit 3 and owner'
    Assert-True (-not (Test-Path -LiteralPath $busyDir)) 'busy launch created a run directory'
    $other = Invoke-CodexRun @('-Repo', $repoB, '-Brief', $brief, '-RunDir', (Join-Path $work 'other'), '-SkipQuotaCheck', '-GateCommand', 'none')
    Assert-True ($other.ExitCode -eq 0 -and (Test-Path -LiteralPath $lockPath)) "different repository path was blocked or disturbed the held lock: $($other.Output.Trim())"
    $held.processStartTime = [DateTime]::UtcNow.AddDays(-1).ToString('o')
    $held | ConvertTo-Json | Set-Content -LiteralPath $lockPath -Encoding utf8
    $stale = Invoke-CodexRun @('-Repo', $repoA, '-Brief', $brief, '-RunDir', (Join-Path $work 'stale'), '-SkipQuotaCheck', '-GateCommand', 'none')
    Assert-True ($stale.ExitCode -eq 0 -and $stale.Output -match 'warning: stale repo lock' -and -not (Test-Path -LiteralPath $lockPath)) 'stale lock was not reclaimed and released'
    $dryFree = Invoke-CodexRun @('-Repo', $repoA, '-Brief', $brief, '-DryRun')
    Assert-True ($dryFree.ExitCode -eq 0 -and $dryFree.Output -match 'lock: free' -and -not (Test-Path -LiteralPath $lockPath)) 'DryRun acquired a free lock'

    Test-RetroLauncher 'codex' { param($Arguments) Invoke-CodexRun $Arguments }

    $registryPath = Join-Path $root 'config\executors.json'
    $heavyRegistry = Get-Content -Raw $registryPath | ConvertFrom-Json
    $heavyRegistry.executors | Add-Member -NotePropertyName fixture-heavy -NotePropertyValue ([pscustomobject]@{repo=$repoA;heavyGate=$true;gateRetries=0;writableRoots=@();commands=[pscustomobject]@{fullGate='none'}})
    $heavyRegistry | ConvertTo-Json -Depth 10 | Set-Content $registryPath
    $heavyPath = Get-RepoLockPath $lockDir (Join-Path $root '.heavy-gate')
    $held.processStartTime = $owner.StartTime.ToUniversalTime().ToString('o')
    $held.repoPath = $repoB
    $held | ConvertTo-Json | Set-Content $heavyPath
    $heavyDry = Invoke-CodexRun @('-Repo', 'fixture-heavy', '-Brief', $brief, '-DryRun')
    Assert-True ($heavyDry.ExitCode -eq 0 -and $heavyDry.Output.Contains('heavy gate lock: busy') -and (Test-Path $heavyPath)) 'heavy dry run acquired or hid the lock'
    $heavyRun = Join-Path $work 'heavy-busy'
    $heavyBusy = Invoke-CodexRun @('-Repo', 'fixture-heavy', '-Brief', $brief, '-RunDir', $heavyRun, '-SkipQuotaCheck', '-GateCommand', 'none')
    Assert-True ($heavyBusy.ExitCode -eq 3 -and $heavyBusy.Output.Contains('heavy gate busy:') -and $heavyBusy.Output.Contains('held-run') -and -not (Test-Path $heavyRun)) 'heavy launch did not refuse a different repository owner'
    Assert-True (-not (Test-Path (Get-RepoLockPath $lockDir $repoA))) 'heavy refusal leaked repository lock'
    $nonHeavy = Invoke-CodexRun @('-Repo', $repoB, '-Brief', $brief, '-RunDir', (Join-Path $work 'non-heavy'), '-SkipQuotaCheck', '-GateCommand', 'none')
    Assert-True ($nonHeavy.ExitCode -eq 0 -and (Test-Path $heavyPath)) 'non-heavy launch disturbed the heavy lock'
    $held.processStartTime = [DateTime]::UtcNow.AddDays(-1).ToString('o')
    $held | ConvertTo-Json | Set-Content $heavyPath
    $heavyStale = Invoke-CodexRun @('-Repo', 'fixture-heavy', '-Brief', $brief, '-RunDir', (Join-Path $work 'heavy-stale'), '-SkipQuotaCheck', '-GateCommand', 'none')
    Assert-True ($heavyStale.ExitCode -eq 0 -and $heavyStale.Output.Contains('stale heavy gate lock taken over') -and -not (Test-Path $heavyPath)) 'stale heavy lock was not reclaimed and released'
    $heavyGateRun = Join-Path $work 'heavy-array-gate'
    New-Item -ItemType Directory -Path $heavyGateRun | Out-Null
    $heavyBrief = Join-Path $heavyGateRun 'brief.md'
    Copy-Item $brief $heavyBrief
    $heavyMarker = Join-Path $work 'heavy-second.txt'
    $heavyCommands = @("if (-not (Test-Path -LiteralPath '$heavyPath')) { exit 98 }; Write-Output 'FAIL first heavy'; exit 7", "Add-Content -LiteralPath '$heavyMarker' -Value ran; Write-Output 'FAIL second heavy'; exit 9")
    @{command=$heavyCommands;owner='launcher'} | ConvertTo-Json | Set-Content (Join-Path $heavyGateRun 'brief.gate.json')
    $env:FAKE_CODEX_REPORT = Join-Path $heavyGateRun 'report.md'
    $heavyArray = Invoke-CodexRun @('-Repo', 'fixture-heavy', '-Brief', $heavyBrief, '-RunDir', $heavyGateRun, '-SkipQuotaCheck')
    Remove-Item Env:FAKE_CODEX_REPORT
    if (-not (Test-Path (Join-Path $heavyGateRun 'gate.json'))) { throw "heavy gate produced no artifact: $($heavyArray.Output.Trim())" }
    $heavyGateJson = Get-Content -Raw (Join-Path $heavyGateRun 'gate.json') | ConvertFrom-Json
    Assert-True ($heavyArray.ExitCode -eq 5 -and (Test-Path $heavyMarker) -and $heavyGateJson.commands[0].exitCode -eq 7 -and $heavyGateJson.commands[1].exitCode -eq 9) 'launcher did not hold heavy lock through both array commands'
    Assert-True ($heavyGateJson.attempts.Count -eq 1 -and -not (Test-Path $heavyPath) -and -not (Test-Path (Get-RepoLockPath $lockDir $repoA))) 'zero retries ignored or heavy gate failure leaked locks'

    $commonPath = Join-Path $root 'bin\RunCommon.ps1'
    $commonText = [IO.File]::ReadAllText($commonPath)
    $lockSignature = 'function Enter-RepoLock([string]$LockDir, [string]$RepoPath, [string]$RunDir) {'
    [IO.File]::WriteAllText($commonPath, $commonText.Replace($lockSignature, $lockSignature + "`n    if ([IO.Path]::GetFileName(`$RepoPath) -eq '.heavy-gate') { throw 'injected pre-attempt crash' }"))
    try {
        foreach ($existing in @($false, $true)) {
            $earlyRun = Join-Path $work "early-crash-$existing"
            New-Item -ItemType Directory -Path $earlyRun | Out-Null
            $earlyReport = Join-Path $earlyRun 'report.md'
            if ($existing) { Set-Content -LiteralPath $earlyReport -Value 'Previous report' }
            $early = Invoke-CodexRun @('-Repo', 'fixture-heavy', '-Brief', $brief, '-RunDir', $earlyRun, '-SkipQuotaCheck', '-GateCommand', 'none')
            Assert-True ($early.ExitCode -eq 1 -and $early.Output.Contains('injected pre-attempt crash') -and $early.Output -notmatch 'attemptStartedAt|has not been set') "pre-attempt crash lost original error: $existing"
            $expectedReport = if ($existing) { '^Previous report\s*$' } else { '(?s)^STATUS: failed.*Cause: crash: launcher error: injected pre-attempt crash' }
            Assert-True ((Test-Path -LiteralPath $earlyReport) -and (Get-Content -Raw -LiteralPath $earlyReport) -match $expectedReport) "pre-attempt crash lost or overwrote report: $existing"
        }
    }
    finally { [IO.File]::WriteAllText($commonPath, $commonText) }

    # --- Quota gate: a provider above the cap costs nothing and refuses with exit 4.
    $env:FAKE_CODEX_MODE = 'ok'
    $env:FAKE_CODEBURN_PCT = '96'
    $runQuota = Join-Path $work 'run-quota'
    $quotaRefused = Invoke-CodexRun @('-Repo', 'sample-app', '-Brief', $brief, '-RunDir', $runQuota)
    Assert-True ($quotaRefused.ExitCode -eq 4) 'quota above the cap did not exit 4'
    Assert-True ($quotaRefused.Output -match 'codex-run: refused \| quota gate: codex .*\b96%') 'quota refusal omitted the provider and percentage'
    Assert-True (-not (Test-Path -LiteralPath $runQuota)) 'run directory created after a quota refusal'
    $gateText = (& pwsh -NoProfile -Command ". '$root\bin\RunCommon.ps1'; Test-QuotaGate 'codex' 95 30 '' '$work\direct-quota' 0" 2>&1 | Out-String).Trim()
    Assert-True ($gateText.StartsWith('quota gate: codex Weekly at 96%')) "Test-QuotaGate missed usage above the cap: $gateText"
    $quotaSkipped = Invoke-CodexRun @('-Repo', 'sample-app', '-Brief', $brief, '-RunDir', (Join-Path $work 'run-quota-skip'), '-SkipQuotaCheck')
    Assert-True ($quotaSkipped.ExitCode -eq 0) '-SkipQuotaCheck did not bypass the quota check'
    $env:FAKE_CODEBURN_MODE = 'fail'
    $quotaBroken = Invoke-CodexRun @('-Repo', 'sample-app', '-Brief', $brief, '-RunDir', (Join-Path $work 'run-quota-fail'))
    Assert-True ($quotaBroken.ExitCode -eq 0) 'unavailable codeburn stopped the run'
    Assert-True ($quotaBroken.Output -match 'quota gate: skipped') 'unavailable codeburn was not reported as skipped'
    Remove-Item Env:FAKE_CODEBURN_MODE -ErrorAction SilentlyContinue

    # --- Uniform 85% consumption cap (15% reserve): exactly at the cap still leaves the reserve and is allowed, decimals are not rounded.
    $env:FAKE_CODEBURN_PCT = '64'
    $freshAt64 = Invoke-CodexRun @('-Repo', 'sample-app', '-Brief', $brief, '-RunDir', (Join-Path $work 'run-fresh-64'))
    Assert-True ($freshAt64.ExitCode -eq 0 -and $freshAt64.Output -match '(?m)^quota gate: codex 64% \(cap 85%\)') 'fresh run at 64% was refused below the 85% cap'
    $env:FAKE_CODEBURN_PCT = '85'
    $freshAt85 = Invoke-CodexRun @('-Repo', 'sample-app', '-Brief', $brief, '-RunDir', (Join-Path $work 'run-fresh-85'))
    Assert-True ($freshAt85.ExitCode -eq 0 -and $freshAt85.Output -match '(?m)^quota gate: codex 85% \(cap 85%\)') 'run was refused at exactly the 85% cap, which should preserve the 15% reserve'
    $env:FAKE_CODEBURN_PCT = '85.1'
    $freshAt851 = Invoke-CodexRun @('-Repo', 'sample-app', '-Brief', $brief, '-RunDir', (Join-Path $work 'run-fresh-85-1'))
    Assert-True ($freshAt851.ExitCode -eq 4 -and $freshAt851.Output -match 'quota gate: codex .*85\.1% \(cap 85%\)') 'fresh run at 85.1% was accepted because decimal precision was lost'

    # --- Both windows: a low weekly reading must not hide a high 5-hour reading, or vice versa.
    $env:FAKE_CODEBURN_PCT = '40'
    $env:FAKE_CODEBURN_PCT_5H = '90'
    $high5h = Invoke-CodexRun @('-Repo', 'sample-app', '-Brief', $brief, '-RunDir', (Join-Path $work 'run-high-5h'))
    Assert-True ($high5h.ExitCode -eq 4 -and $high5h.Output -match 'quota gate: codex .*90%') 'high 5-hour usage with low weekly usage did not block launch'
    $env:FAKE_CODEBURN_PCT = '90'
    $env:FAKE_CODEBURN_PCT_5H = '40'
    $highWeekly = Invoke-CodexRun @('-Repo', 'sample-app', '-Brief', $brief, '-RunDir', (Join-Path $work 'run-high-weekly'))
    Assert-True ($highWeekly.ExitCode -eq 4 -and $highWeekly.Output -match 'quota gate: codex .*90%') 'high weekly usage with low 5-hour usage did not block launch'
    Remove-Item Env:FAKE_CODEBURN_PCT_5H -ErrorAction SilentlyContinue
    $env:FAKE_CODEBURN_PCT = '40'

    $env:FAKE_CODEX_MODE = 'credits'
    $runCredits = Join-Path $work 'run-credits'
    $credits = Invoke-CodexRun @('-Repo', 'sample-app', '-Brief', $brief, '-RunDir', $runCredits)
    Assert-True ($credits.ExitCode -eq 1) 'Codex exit code was not propagated'
    Assert-True (Test-Path -LiteralPath (Join-Path $runCredits 'meta.json')) 'meta.json was not written'
    $meta = Get-Content -Raw -LiteralPath (Join-Path $runCredits 'meta.json') | ConvertFrom-Json
    Assert-True ($meta.outOfCredits -eq $true) 'exhausted credit was not detected'
    Assert-True ($meta.rateLimited -eq $false) 'false rate limit error'
    Assert-True ($meta.sessionId -eq '00000000-0000-0000-0000-000000000001') 'session ID was not read from stderr'
    Assert-True ($meta.sandboxBlocked -eq $false) 'false sandbox error'
    Assert-True ($meta.exitCode -eq 1) 'exitCode missing or incorrect in meta.json'
    Assert-True ($meta.lineEndingOnly -is [array] -and $meta.lineEndingOnly.Count -eq 0) 'failed Codex run must record an empty lineEndingOnly array'
    Assert-True ($meta.wrapperExitCode -eq 1) 'wrapperExitCode missing or incorrect'
    Assert-True ($null -eq $meta.preflight) 'preflight must be null when Codex ran'
    Assert-True ($meta.reportPresent -eq $false) 'incorrect reportPresent without a report'
    Assert-True ($meta.reportSynthesized -eq $true -and (Get-Content -Raw -LiteralPath (Join-Path $runCredits 'report.md')) -match '(?s)^STATUS: failed.*Cause: quota: Codex reported out of credits') 'out-of-credits exit left no synthesized report'
    Assert-True ($meta.repo -eq 'sample-app') 'alias was not recorded in meta.json'
    Assert-True ($meta.repoPath -eq $sampleRepo) 'repoPath was not recorded in meta.json'
    Assert-True ($meta.repoRoot -eq $sampleRepo -and $meta.github -eq 'fixture-team/SampleApp') 'registered repository identity missing in Codex metadata'
    Assert-True ($meta.model -eq 'gpt-6.2-sol') 'default model missing for a fresh run'
    Assert-True ($null -eq $meta.resumedFrom) 'resumedFrom must be null for a fresh run'
    Assert-True ($meta.command -match '^codex exec -C ') 'command missing from meta.json'
    Assert-True ($null -eq $meta.fixLoop) 'fixLoop must be null for a fresh run'
    Assert-True (($meta.startedAt -as [datetime]) -le ($meta.endedAt -as [datetime])) 'inconsistent timestamps'
    $log = Get-Content -Raw -LiteralPath (Join-Path $runCredits 'codex.log')
    Assert-True ($log -match 'out of credits') 'stderr was not saved in the log'
    Assert-True ($log -match 'args: exec -C ') 'arguments were not passed to Codex'
    Assert-True ($log -match 'stdin: EXECUTOR ROLE:') 'executor prompt was not sent to stdin'
    Assert-True ($log -match "workdir: $( [regex]::Escape($sampleRepo))") 'incorrect working directory for a fresh run'
    Assert-True ($credits.Output -match 'codex-run: exit 1') 'final summary missing or incorrect'
    Assert-True (-not (Test-Path -LiteralPath (Get-RepoLockPath $lockDir $sampleRepo))) 'lock retained after executor failure'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $runCredits 'codex.stdout.log'))) 'temporary stdout file was not removed'

    $env:FAKE_CODEX_MODE = 'ok'
    foreach ($loop in @(1, 2)) {
        $historyResume = Invoke-CodexRun @('-Repo', 'sample-app', '-Brief', $brief, '-RunDir', $runCredits, '-Resume', $meta.sessionId, '-FixLoop', "$loop", '-GateCommand', 'none')
        $historyMeta = Get-Content -Raw -LiteralPath (Join-Path $runCredits 'meta.json') | ConvertFrom-Json
        Assert-True ($historyResume.ExitCode -eq 0 -and $historyMeta.wrapperExitCode -eq 0 -and $historyMeta.fixLoop -eq $loop) 'codex latest resume outcome changed'
        Assert-True (@($historyMeta.attempts).Count -eq $loop) 'codex earlier attempts lost on same-directory resume'
        if ($historyMeta.attempts) {
            $first = $historyMeta.attempts[0]
            foreach ($field in @('startedAt', 'endedAt', 'exitCode', 'wrapperExitCode', 'timedOut', 'fixLoop', 'sessionId', 'model')) {
                Assert-True ($first.$field -eq $meta.$field) "codex archived $field changed"
            }
            Assert-True ($first.reasoningEffort -eq $meta.reasoningEffort) 'codex archived reasoning effort missing'
            Assert-True ($null -eq $first.PSObject.Properties['attempts']) 'codex nested attempt history'
        }
    }

    $env:FAKE_CODEX_MODE = 'ratelimit'
    $runLimit = Join-Path $work 'run-limit'
    $limit = Invoke-CodexRun @('-Repo', 'sample-app', '-Brief', $brief, '-RunDir', $runLimit)
    $metaLimit = Get-Content -Raw -LiteralPath (Join-Path $runLimit 'meta.json') | ConvertFrom-Json
    Assert-True ($limit.ExitCode -eq 1) 'rate-limit exit code was not propagated'
    Assert-True ($metaLimit.rateLimited -eq $true) 'rate limit was not detected'
    Assert-True ($metaLimit.outOfCredits -eq $false) 'false credit error'

    foreach ($message in @('Selected model is at capacity', 'The model is overloaded', 'The server is busy')) {
        $env:FAKE_CODEX_MODE = 'capacity'
        $env:FAKE_CODEX_ERROR = $message
        $capacityRun = Join-Path $work ('run-capacity-' + [guid]::NewGuid())
        $capacity = Invoke-CodexRun @('-Repo', 'sample-app', '-Brief', $brief, '-RunDir', $capacityRun, '-SkipQuotaCheck')
        $capacityMeta = Get-Content -Raw -LiteralPath (Join-Path $capacityRun 'meta.json') | ConvertFrom-Json
        Assert-True ($capacity.ExitCode -eq 1 -and $capacityMeta.wrapperExitCode -eq 1) "capacity classification preserves exit 1: $message"
        Assert-True ($capacityMeta.rateLimited -eq $true -and $capacityMeta.outOfCredits -eq $false) "capacity classification records provider limit: $message"
        Assert-True ($capacity.Output -match 'rateLimited True') "capacity classification summary flags provider limit: $message"
        $capacityReport = Get-Content -Raw -LiteralPath (Join-Path $capacityRun 'report.md')
        Assert-True ($capacityMeta.reportSynthesized -eq $true -and $capacityReport -match 'Cause: .*capacity.*relaunch on the other provider or retry later') "capacity classification report gives cause and recovery: $message"
    }
    Remove-Item Env:FAKE_CODEX_ERROR
    $env:FAKE_CODEX_MODE = 'capacitytext'
    $capacityTextRun = Join-Path $work 'run-capacity-text'
    $capacityText = Invoke-CodexRun @('-Repo', 'sample-app', '-Brief', $brief, '-RunDir', $capacityTextRun, '-SkipQuotaCheck')
    $capacityTextMeta = Get-Content -Raw -LiteralPath (Join-Path $capacityTextRun 'meta.json') | ConvertFrom-Json
    Assert-True ($capacityText.ExitCode -eq 1 -and $capacityTextMeta.rateLimited -eq $false) 'capacity classification ignores ordinary text on failed executors'

    $env:FAKE_CODEX_MODE = 'ok'
    $runOk = Join-Path $work 'run-ok'
    $ok = Invoke-CodexRun @('-Repo', 'sample-app', '-Brief', $brief, '-RunDir', $runOk, '-Resume', $resumeId, '-FixLoop', '1')
    $metaOk = Get-Content -Raw -LiteralPath (Join-Path $runOk 'meta.json') | ConvertFrom-Json -DateKind String
    $deadline = [datetimeoffset]::Parse($metaOk.deadlineLocal)
    $reportBy = [datetimeoffset]::Parse($metaOk.reportByLocal)
    Assert-True ($metaOk.deadlineLocal -match '[+-]\d{2}:\d{2}$' -and $metaOk.reportByLocal -match '[+-]\d{2}:\d{2}$') 'deadline metadata must include local offsets'
    Assert-True ([Math]::Abs(($deadline - $reportBy).TotalMinutes - 10) -lt 0.001) 'default report reserve must be ten minutes'
    $deadlinePrompt = Get-Content -Raw -LiteralPath (Join-Path $runOk 'executor-prompt.md')
    Assert-True ($deadlinePrompt.Contains('Launcher will stop the executor at ' + $deadline.ToString('HH:mm')) -and $deadlinePrompt.Contains('Stop working and write the final report by ' + $reportBy.ToString('HH:mm'))) 'deadline header differs from metadata'
    Assert-True ($deadlinePrompt.Contains('even if incomplete, listing what is missing')) 'report instruction missing incomplete work requirement'

    Assert-True ($ok.ExitCode -eq 0) 'exit code 0 was not propagated'
    Assert-True ((Test-Path -LiteralPath (Join-Path $runOk 'task-usage-start.json')) -and (Test-Path -LiteralPath (Join-Path $runOk 'task-usage.json'))) 'automatic task usage artifacts missing'
    Assert-True ($metaOk.outOfCredits -eq $false -and $metaOk.rateLimited -eq $false) 'false failure flags on a successful run'
    Assert-True ($metaOk.sandboxBlocked -eq $false) 'sandbox mention in the report was mistaken for a block'
    Assert-True ($metaOk.resumedFrom -eq $resumeId) 'resumedFrom was not recorded'
    Assert-True ($metaOk.command -match '^codex exec resume ') 'resume command was not recorded'
    Assert-True ($ok.Output -match 'codex-run: exit 0') 'successful run omitted the final summary'
    Assert-True ($ok.Output -match '(?m)^quota gate: codex .*40%') 'successful run omitted usage below the cap'
    Assert-True ($metaOk.model -eq 'gpt-6.2-sol') 'inherited model missing from resume metadata'
    Assert-True ($metaOk.reasoningEffort -eq 'high') 'inherited reasoning effort missing from metadata'
    Assert-True ($metaOk.timeoutMinutes -eq 30) 'default timeout missing from metadata'
    Assert-True ($metaOk.timedOut -eq $false) 'successful run was marked as timed out'
    Assert-True ($metaOk.fixLoop -eq 1) 'fixLoop missing from metadata'
    Assert-True ($metaOk.autoCompactTokens -eq 200000) 'autoCompactTokens missing from metadata'
    Assert-True (@($metaOk.writableRoots).Count -eq 4 -and @($metaOk.writableRoots) -contains $runOk) 'run dir absent from writableRoots metadata'
    Assert-True ((Get-Content -Raw -LiteralPath (Join-Path $runOk 'codex.log')) -match "workdir: $( [regex]::Escape($sampleRepo))") 'incorrect working directory for a resumed run'
    $deliveredPrompt = Get-Content -Raw -LiteralPath (Join-Path $runOk 'executor-prompt.md')
    $briefBody = Get-Content -Raw -LiteralPath $brief
    Assert-True ($deliveredPrompt -match '^EXECUTOR ROLE:' -and $deliveredPrompt.Contains($brief)) 'launcher prompt omitted the executor role or original brief path'
    Assert-True ($deliveredPrompt -match '(?i)do not dispatch or relaunch a live agent' -and $deliveredPrompt -match '(?i)fixture tests and dry runs are allowed') 'launcher prompt did not distinguish live delegation from assigned fixture tests'
    Assert-True ($deliveredPrompt.EndsWith($briefBody)) 'brief body changed while delivering the prompt'
    Assert-True ((Get-Content -Raw -LiteralPath (Join-Path $runOk 'codex.log')) -match 'stdin: EXECUTOR ROLE:') 'Codex did not receive the executor role on the first line of stdin'

    $gateSuccessDir = Join-Path $work 'gate-success'
    New-Item -ItemType Directory -Path $gateSuccessDir | Out-Null
    $env:FAKE_CODEX_REPORT = Join-Path $gateSuccessDir 'report.md'
    $gateSuccess = Invoke-CodexRun @('-Repo','sample-app','-Brief',$brief,'-RunDir',$gateSuccessDir,'-GateCommand','Write-Output gate-ok')
    $gateSuccessJson = Get-Content -Raw -LiteralPath (Join-Path $gateSuccessDir 'gate.json') | ConvertFrom-Json
    Assert-True ($gateSuccess.ExitCode -eq 0 -and $gateSuccess.Output -match 'gate: exit 0') 'successful post-run gate failed'
    Assert-True ($gateSuccessJson.exitCode -eq 0 -and $gateSuccessJson.cwd -eq $sampleRepo -and $gateSuccessJson.tail -match 'gate-ok') 'gate.json missing success evidence'
    Assert-True ($gateSuccessJson.owner -eq 'launcher' -and $gateSuccessJson.reused -eq $false -and $gateSuccessJson.fingerprint -match '^[0-9A-F]{64}$' -and @($gateSuccessJson.failures).Count -eq 0) 'launcher gate.json misses owner, reused, fingerprint or failures'
    Assert-True ((Get-Content -Raw -LiteralPath (Join-Path $gateSuccessDir 'meta.json') | ConvertFrom-Json).reportSynthesized -eq $false) 'report synthesized although the executor wrote one'
    Assert-True (-not (Test-Path -LiteralPath (Get-RepoLockPath $lockDir $sampleRepo))) 'lock retained after success'
    $flakyDir = Join-Path $work 'gate-flaky'
    New-Item -ItemType Directory -Path $flakyDir | Out-Null
    $flakyCounter = Join-Path $work 'flaky.count'
    $env:FAKE_CODEX_REPORT = Join-Path $flakyDir 'report.md'
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixtures\flutter.ps1') -Destination $fakeBin
    $env:FAKE_GATE_COUNTER = $flakyCounter
    $flakyCommand = 'flutter test --concurrency=3'
    $flakyRun = Invoke-CodexRun @('-Repo','sample-app','-Brief',$brief,'-RunDir',$flakyDir,'-GateCommand',$flakyCommand)
    $flakyGate = Get-Content -Raw -LiteralPath (Join-Path $flakyDir 'gate.json') | ConvertFrom-Json
    Assert-True ($flakyRun.ExitCode -eq 0 -and $flakyGate.flaky -eq $true -and @($flakyGate.attempts).Count -eq 2) 'flaky green became wrapper failure'
    Assert-True ($flakyRun.Output.Contains('gate: exit 0 (flaky: green on retry 1; 2 failures first)')) 'flaky gate summary missing'

    $gateFailureDir = Join-Path $work 'gate-failure'
    New-Item -ItemType Directory -Path $gateFailureDir | Out-Null
    $env:FAKE_CODEX_REPORT = Join-Path $gateFailureDir 'report.md'
    $gateFailure = Invoke-CodexRun @('-Repo','sample-app','-Brief',$brief,'-RunDir',$gateFailureDir,'-GateCommand','exit 7')
    Assert-True ($gateFailure.ExitCode -eq 5 -and $gateFailure.Output -match 'gate: exit 7') 'failed gate did not exit 5'
    Assert-True ($gateFailure.Output -match '(?m)^codex-run: exit 5 \(executor 0\) \|') 'summary must report wrapper failure and executor success'
    Assert-True (-not (Test-Path -LiteralPath (Get-RepoLockPath $lockDir $sampleRepo))) 'lock retained after gate failure'
    $gateChainDir = Join-Path $work 'gate-chain-failure'
    New-Item -ItemType Directory -Path $gateChainDir | Out-Null
    $env:FAKE_CODEX_REPORT = Join-Path $gateChainDir 'report.md'
    $gateChain = Invoke-CodexRun @('-Repo','sample-app','-Brief',$brief,'-RunDir',$gateChainDir,'-GateCommand','pwsh -NoProfile -Command "exit 7"; Write-Output later')
    Assert-True ($gateChain.ExitCode -eq 5) 'earlier failed gate command masked by later success'

    # --- Matching green/red executor gates are reused; changed, timed-out or absent gates run.
    $gateRepo = Join-Path $work 'gate-repo'
    New-Item -ItemType Directory -Path $gateRepo | Out-Null
    Set-Content -LiteralPath (Join-Path $gateRepo 'source.txt') -Value 'v1' -Encoding utf8
    foreach ($case in @('reuse', 'changed', 'red', 'timeout', 'absent')) {
        $caseDir = Join-Path $work "executor-gate-$case"
        $counter = Join-Path $work "executor-gate-$case.count"
        $exitFirst = if ($case -eq 'red') { 3 } else { 0 }
        $caseCommand = "Add-Content -LiteralPath '$counter' -Value run; if (@(Get-Content -LiteralPath '$counter').Count -le 2) { exit $exitFirst }"
        New-Item -ItemType Directory -Path $caseDir | Out-Null
        if ($case -ne 'absent') { & pwsh -NoProfile -File (Join-Path $root 'bin\run-gate.ps1') -Repo $gateRepo -RunDir $caseDir -GateCommand $caseCommand *> $null }
        if ($case -eq 'changed') { Set-Content -LiteralPath (Join-Path $gateRepo 'source.txt') -Value 'v2' -Encoding utf8 }
        if ($case -eq 'timeout') {
            $priorPath = Join-Path $caseDir 'gate.json'
            $prior = Get-Content -Raw -LiteralPath $priorPath | ConvertFrom-Json
            $prior.timedOut = $true
            $prior | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $priorPath
        }
        $env:FAKE_CODEX_REPORT = Join-Path $caseDir 'report.md'
        $caseRun = Invoke-CodexRun @('-Repo', $gateRepo, '-Brief', $brief, '-RunDir', $caseDir, '-GateCommand', $caseCommand)
        $caseGate = Get-Content -Raw -LiteralPath (Join-Path $caseDir 'gate.json') | ConvertFrom-Json
        $caseMeta = Get-Content -Raw -LiteralPath (Join-Path $caseDir 'meta.json') | ConvertFrom-Json
        $caseRuns = @(Get-Content -LiteralPath $counter).Count
        $kept = Join-Path $caseDir 'gate.executor.json'
        $expectedExit = if ($case -eq 'red') { 5 } else { 0 }
        Assert-True ($caseRun.ExitCode -eq $expectedExit) "executor gate case $case exit $($caseRun.ExitCode), expected $expectedExit"
        if ($case -in @('reuse', 'red')) {
            Assert-True ($caseRuns -eq 1 -and $caseRun.Output -match "gate: exit $exitFirst \(reused\)") 'matching executor gate was run again'
            Assert-True ($caseGate.exitCode -eq $exitFirst -and $caseMeta.gate.exitCode -eq $exitFirst -and $caseMeta.wrapperExitCode -eq $expectedExit) 'reused gate changed its outcome'
            Assert-True ($caseGate.owner -eq 'executor' -and $caseGate.reused -eq $true -and $caseMeta.gate.reused -eq $true) 'reused gate not recorded in gate.json and meta.gate'
            Assert-True (-not (Test-Path -LiteralPath $kept)) 'reused executor gate also kept as gate.executor.json'
        }
        else {
            $expectedRuns = if ($case -eq 'absent') { 1 } else { 2 }
            Assert-True ($caseRuns -eq $expectedRuns -and $caseGate.owner -eq 'launcher' -and $caseGate.reused -eq $false -and $caseMeta.gate.reused -eq $false) "executor gate case $case not rerun by the launcher"
            Assert-True ((Test-Path -LiteralPath $kept) -eq ($case -ne 'absent')) "executor gate case $case kept the wrong gate.executor.json"
        }
    }
    $keptTimeout = Get-Content -Raw -LiteralPath (Join-Path $work 'executor-gate-timeout\gate.executor.json') | ConvertFrom-Json
    Assert-True ($keptTimeout.owner -eq 'executor' -and $keptTimeout.timedOut -eq $true -and (Test-Path -LiteralPath $keptTimeout.log)) 'timed-out executor gate not kept with its log'
    $origRun = Join-Path $work 'brief-gate-run'
    $briefCounter = Join-Path $work 'brief-gate.count'
    $briefCommand = "Add-Content -LiteralPath '$briefCounter' -Value run"
    New-Item -ItemType Directory -Path $origRun | Out-Null
    Copy-Item -LiteralPath $brief -Destination (Join-Path $origRun 'brief.md')
    & pwsh -NoProfile -File (Join-Path $root 'bin\run-gate.ps1') -Repo $gateRepo -RunDir $origRun -GateCommand $briefCommand *> $null
    [ordered]@{ command = $briefCommand; owner = 'executor' } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $origRun 'brief.gate.json') -Encoding utf8
    $fixRun = Join-Path $work 'brief-gate-run-fix1'
    New-Item -ItemType Directory -Path $fixRun | Out-Null
    $env:FAKE_CODEX_REPORT = Join-Path $fixRun 'report.md'
    $briefReuse = Invoke-CodexRun @('-Repo', $gateRepo, '-Brief', (Join-Path $origRun 'brief.md'), '-RunDir', $fixRun)
    $fixGate = Get-Content -Raw -LiteralPath (Join-Path $fixRun 'gate.json') | ConvertFrom-Json
    Assert-True ($briefReuse.ExitCode -eq 0 -and $briefReuse.Output -match 'gate: exit 0 \(reused\)' -and @(Get-Content -LiteralPath $briefCounter).Count -eq 1) 'fix-loop launcher did not reuse the gate in the brief directory'
    Assert-True ($fixGate.reused -eq $true -and $fixGate.reusedFrom -eq (Join-Path $origRun 'gate.json')) 'brief-directory gate copied without reused or reusedFrom'
    $gateNoneDir = Join-Path $work 'gate-none'
    New-Item -ItemType Directory -Path $gateNoneDir | Out-Null
    $env:FAKE_CODEX_REPORT = Join-Path $gateNoneDir 'report.md'
    $gateNone = Invoke-CodexRun @('-Repo','sample-app','-Brief',$brief,'-RunDir',$gateNoneDir,'-GateCommand','none')
    Assert-True ($gateNone.ExitCode -eq 0 -and -not (Test-Path -LiteralPath (Join-Path $gateNoneDir 'gate.json'))) 'GateCommand none did not skip'
    Set-Content -LiteralPath (Join-Path $fakeBin 'node.cmd') -Value "@echo off`r`nexit /b 9" -Encoding ascii
    $accountingDir = Join-Path $work 'accounting-failure'
    New-Item -ItemType Directory -Path $accountingDir | Out-Null
    $env:FAKE_CODEX_REPORT = Join-Path $accountingDir 'report.md'
    $accounting = Invoke-CodexRun @('-Repo','sample-app','-Brief',$brief,'-RunDir',$accountingDir,'-GateCommand','none')
    Assert-True ($accounting.ExitCode -eq 0 -and $accounting.Output -match 'warning: task-usage') 'task-usage failure changed exit or was silent'
    Remove-Item -LiteralPath (Join-Path $fakeBin 'node.cmd') -Force
    Remove-Item Env:FAKE_CODEX_REPORT

    # --- Ordinary output may mention quota phrases without becoming an error record.
    $env:FAKE_CODEX_MODE = 'echoquota'
    $runEchoQuota = Join-Path $work 'run-echo-quota'
    $echoQuota = Invoke-CodexRun @('-Repo', 'sample-app', '-Brief', $brief, '-RunDir', $runEchoQuota, '-ReasoningEffort', 'medium')
    $metaEchoQuota = Get-Content -Raw -LiteralPath (Join-Path $runEchoQuota 'meta.json') | ConvertFrom-Json
    Assert-True ($echoQuota.ExitCode -eq 0) 'ordinary quota text changed the exit code'
    Assert-True ($metaEchoQuota.outOfCredits -eq $false) 'ordinary out of credits text was classified as an error'
    Assert-True ($metaEchoQuota.rateLimited -eq $false) 'ordinary 429/rate limit text was classified as an error'
    Assert-True ($metaEchoQuota.reasoningEffort -eq 'medium') 'selected reasoning effort missing from metadata'

    $env:FAKE_CODEX_MODE = 'echoerrors'
    $runEchoErrors = Join-Path $work 'run-echo-errors'
    New-Item -ItemType Directory -Path $runEchoErrors | Out-Null
    $env:FAKE_CODEX_REPORT = Join-Path $runEchoErrors 'report.md'
    $echoErrors = Invoke-CodexRun @('-Repo', 'sample-app', '-Brief', $brief, '-RunDir', $runEchoErrors, '-GateCommand', 'none')
    $metaEchoErrors = Get-Content -Raw -LiteralPath (Join-Path $runEchoErrors 'meta.json') | ConvertFrom-Json
    Assert-True ($echoErrors.ExitCode -eq 0 -and $metaEchoErrors.reportPresent -eq $true) 'successful error-echo fixture lost report or success'
    Assert-True ($metaEchoErrors.outOfCredits -eq $false -and $metaEchoErrors.rateLimited -eq $false) 'successful executor error examples classified as provider exhaustion'
    Assert-True ((Get-Content -Raw -LiteralPath (Join-Path $runEchoErrors 'codex.log')) -match 'ERROR: Your workspace is out of credits' -and $echoErrors.Output -match '(?m)^codex-run: exit 0 \|') 'successful error-echo summary changed or stderr was lost'
    Remove-Item Env:FAKE_CODEX_REPORT

    foreach ($existing in @($false, $true)) {
        $preservedRun = Join-Path $work "preserved-report-$existing"
        New-Item -ItemType Directory -Path $preservedRun | Out-Null
        $env:FAKE_EXECUTOR_REPORT = Join-Path $preservedRun 'report.md'
        $env:FAKE_CODEX_REPORT = $env:FAKE_EXECUTOR_REPORT
        if ($existing) { Set-Content $env:FAKE_EXECUTOR_REPORT 'Previous report' }
        $preserved = Invoke-CodexRun @('-Repo', $repoA, '-Brief', $brief, '-RunDir', $preservedRun, '-FullAccess', '-SkipQuotaCheck', '-GateCommand', 'none')
        Assert-True ($preserved.ExitCode -eq 0 -and (Get-Content -Raw $env:FAKE_EXECUTOR_REPORT).Trim() -eq 'Detailed executor report') 'executor-written report was overwritten'
        Assert-True ((Get-Content -Raw (Join-Path $preservedRun 'report.final-message.md')).Trim() -eq '# Report') 'final message was not retained separately'
    }
    Remove-Item Env:FAKE_EXECUTOR_REPORT, Env:FAKE_CODEX_REPORT
    $unchangedRun = Join-Path $work 'unchanged-report'
    New-Item -ItemType Directory -Path $unchangedRun | Out-Null
    $env:FAKE_CODEX_REPORT = Join-Path $unchangedRun 'report.md'
    Set-Content $env:FAKE_CODEX_REPORT 'Previous report'
    $unchanged = Invoke-CodexRun @('-Repo', $repoA, '-Brief', $brief, '-RunDir', $unchangedRun, '-FullAccess', '-SkipQuotaCheck', '-GateCommand', 'none')
    Assert-True ($unchanged.ExitCode -eq 0 -and (Get-Content -Raw $env:FAKE_CODEX_REPORT).Trim() -eq '# Report' -and -not (Test-Path (Join-Path $unchangedRun 'report.final-message.md'))) 'unchanged report final-message behavior changed'
    Remove-Item Env:FAKE_CODEX_REPORT

    foreach ($mode in @('noreport', 'credits')) {
        $env:FAKE_CODEX_MODE = $mode
        $staleRun = Join-Path $work "stale-report-$mode"
        New-Item -ItemType Directory -Path $staleRun | Out-Null
        Set-Content -LiteralPath (Join-Path $staleRun 'report.md') -Value 'STATUS: ready_for_review'
        $staleGate = Join-Path $work "stale-gate-$mode.count"
        $stale = Invoke-CodexRun @('-Repo', $repoA, '-Brief', $brief, '-RunDir', $staleRun, '-Resume', $resumeId, '-FixLoop', '1', '-Model', 'gpt-6.2-sol', '-ReasoningEffort', 'high', '-FullAccess', '-SkipQuotaCheck', '-GateCommand', "Add-Content -LiteralPath '$staleGate' -Value run")
        $staleMeta = Get-Content -Raw -LiteralPath (Join-Path $staleRun 'meta.json') | ConvertFrom-Json
        Assert-True ($stale.ExitCode -ne 0 -and $staleMeta.reportPresent -eq $false) "stale report accepted as current: $mode"
        Assert-True ($staleMeta.reportSynthesized -eq $true -and (Get-Content -Raw -LiteralPath (Join-Path $staleRun 'report.md')) -match '(?s)^STATUS: failed.*Cause: (executor error|quota)') "stale report not replaced by failure: $mode"
        Assert-True ($null -eq $staleMeta.gate -and -not (Test-Path -LiteralPath $staleGate)) "stale report ran success gate: $mode"
    }

    # --- A bounded timeout kills only the launched process tree and preserves partial evidence.
    $timeoutHelper = Join-Path $fakeBin 'fake-timeout.ps1'
    Set-Content -LiteralPath $timeoutHelper -Encoding utf8 -Value @'
Set-Content -LiteralPath $env:FAKE_CHILD_PID_PATH -Value $PID -Encoding ascii
Start-Sleep -Seconds 20
'@
    $env:FAKE_TIMEOUT_SCRIPT = $timeoutHelper
    $env:FAKE_CHILD_PID_PATH = Join-Path $work 'timeout-child.pid'
    $env:FAKE_CODEX_MODE = 'timeout'
    $runTimeout = Join-Path $work 'run-timeout'
    New-Item -ItemType Directory -Path $runTimeout | Out-Null
    Set-Content -LiteralPath (Join-Path $runTimeout 'progress.md') -Value 'Task 1 done; stopped in task 2' -Encoding utf8
    Set-Content -LiteralPath (Join-Path $runTimeout 'report.md') -Value 'STATUS: ready_for_review'
    # Leave time for the fixture's nested PowerShell to start on a busy Windows runner.
    $timeout = Invoke-CodexRun @('-Repo', 'sample-app', '-Brief', $brief, '-RunDir', $runTimeout, '-TimeoutMinutes', '0.2')
    $metaTimeout = Get-Content -Raw -LiteralPath (Join-Path $runTimeout 'meta.json') | ConvertFrom-Json
    Assert-True ($timeout.ExitCode -eq 124) 'timeout did not exit 124'
    Assert-True ($metaTimeout.reportSynthesized -eq $true -and (Get-Content -Raw -LiteralPath (Join-Path $runTimeout 'report.md')) -match '(?s)^STATUS: failed.*Cause: deadline.*Task 1 done; stopped in task 2') 'deadline exit left no report with cause and progress'
    Assert-True ($metaTimeout.wrapperExitCode -eq 124) 'incorrect wrapperExitCode for a timeout'
    Assert-True ($metaTimeout.timedOut -eq $true) 'timedOut was not recorded'
    Assert-True ($metaTimeout.processTerminated -eq $true) 'exact process termination was not recorded'
    Assert-True ($metaTimeout.timeoutMinutes -eq 0.2) 'timeout duration was not recorded'
    Assert-True ((Get-Content -Raw -LiteralPath (Join-Path $runTimeout 'codex.log')) -match 'partial-before-timeout') 'partial evidence was lost on timeout'
    Assert-True (Test-Path -LiteralPath $env:FAKE_CHILD_PID_PATH) 'child process did not start in the timeout test'
    if (Test-Path -LiteralPath $env:FAKE_CHILD_PID_PATH) {
        $childPid = [int](Get-Content -Raw -LiteralPath $env:FAKE_CHILD_PID_PATH)
        Assert-True ($null -eq (Get-Process -Id $childPid -ErrorAction SilentlyContinue)) 'descendant of the Codex process survived the timeout'
    }

    $resumeTimeoutDir = Join-Path $work 'resume-timeout'
    $resumeTimeout = Invoke-CodexRun @('-Repo', 'sample-app', '-Brief', $brief, '-RunDir', $resumeTimeoutDir, '-Resume', $resumeId, '-FixLoop', '1', '-TimeoutMinutes', '0.02')
    $resumeTimeoutMeta = Get-Content -Raw -LiteralPath (Join-Path $resumeTimeoutDir 'meta.json') | ConvertFrom-Json
    Assert-True ($resumeTimeout.ExitCode -eq 124 -and $resumeTimeoutMeta.sessionId -eq $resumeId) 'timeout lost known resumed session identity'
    Assert-True ($resumeTimeoutMeta.timeoutMinutes -eq 0.02) 'resume changed the 1.2-second timeout'
    Assert-True ($resumeTimeout.Output -notmatch 'warning: task-usage finish exited 2') 'timeout accounting rejected automatic session metadata'

    # --- Codex exits 0 but the Windows sandbox rejected every command.
    $env:FAKE_CODEX_MODE = 'sandbox'
    $runSandbox = Join-Path $work 'run-sandbox'
    $sandbox = Invoke-CodexRun @('-Repo', 'sample-app', '-Brief', $brief, '-RunDir', $runSandbox)
    $metaSandbox = Get-Content -Raw -LiteralPath (Join-Path $runSandbox 'meta.json') | ConvertFrom-Json
    Assert-True ($sandbox.ExitCode -eq 75) 'sandbox block did not exit 75'
    Assert-True ($metaSandbox.exitCode -eq 0) 'Codex exit code missing for a sandbox-blocked run'
    Assert-True ($metaSandbox.wrapperExitCode -eq 75) 'wrapperExitCode did not report the sandbox block'
    Assert-True ($metaSandbox.sandboxBlocked -eq $true) 'sandbox block was not detected in the log'
    Assert-True ($metaSandbox.outOfCredits -eq $false) 'false credit error in a sandbox-blocked run'
    Assert-True ($metaSandbox.rateLimited -eq $false) 'false rate limit in a sandbox-blocked run'
    Assert-True ($sandbox.Output -match 'sandboxBlocked True') 'summary omitted the sandbox block'
    $logSandbox = Get-Content -Raw -LiteralPath (Join-Path $runSandbox 'codex.log')
    Assert-True ($logSandbox -match 'orchestrator_helper_launch_failed') 'sandbox error was not saved in the log'

    # --- The private-desktop runner handshake fails: same treatment as any sandbox rejection.
    $env:FAKE_CODEX_MODE = 'handshake'
    $runHandshake = Join-Path $work 'run-handshake'
    $handshake = Invoke-CodexRun @('-Repo', 'sample-app', '-Brief', $brief, '-RunDir', $runHandshake)
    $metaHandshake = Get-Content -Raw -LiteralPath (Join-Path $runHandshake 'meta.json') | ConvertFrom-Json
    Assert-True ($handshake.ExitCode -eq 75) 'failed runner handshake did not exit 75'
    Assert-True ($metaHandshake.sandboxBlocked -eq $true) 'failed runner handshake was not detected in the log'
    Assert-True ($metaHandshake.exitCode -eq 0) 'Codex exit code missing for the run with a failed handshake'
    Assert-True ($metaHandshake.outOfCredits -eq $false) 'false credit error in the run with a failed handshake'

    # --- The sandbox helper is missing: the preflight must stop before spending a run.
    Remove-Item -LiteralPath $fakeHelper -Force
    $env:FAKE_CODEX_MODE = 'ok'
    $runPreflight = Join-Path $work 'run-preflight'
    $preflight = Invoke-CodexRun @('-Repo', 'sample-app', '-Brief', $brief, '-RunDir', $runPreflight, '-Model', 'gpt-6.2-sol')
    $metaPreflight = Get-Content -Raw -LiteralPath (Join-Path $runPreflight 'meta.json') | ConvertFrom-Json
    Assert-True ($preflight.ExitCode -eq 75) 'sandbox preflight did not exit 75'
    Assert-True ($metaPreflight.sandboxBlocked -eq $true) 'preflight omitted sandboxBlocked in meta.json'
    Assert-True ($metaPreflight.preflight -match 'sandbox helper missing') 'preflight did not explain which helper is missing'
    Assert-True ($metaPreflight.model -eq 'gpt-6.2-sol') 'selected model missing from preflight'
    Assert-True ($metaPreflight.repoRoot -eq $sampleRepo -and $metaPreflight.github -eq 'fixture-team/SampleApp') 'preflight repository identity missing'
    Assert-True ($null -eq $metaPreflight.exitCode) 'exitCode must be null when Codex did not start'
    $logPreflight = Get-Content -Raw -LiteralPath (Join-Path $runPreflight 'codex.log')
    Assert-True ($logPreflight -match 'sandbox helper missing') 'preflight failure reason was not saved in the log'
    Assert-True (-not ($logPreflight -match 'args:')) 'Codex ran after a failed preflight'
    Assert-True ($metaPreflight.reportSynthesized -eq $true -and (Get-Content -Raw -LiteralPath (Join-Path $runPreflight 'report.md')) -match '(?s)^STATUS: failed.*Cause: preflight: sandbox helper missing') 'preflight exit left no synthesized report'

    # --- A launcher crash after the run directory exists still leaves a report; the exit stays the crash exit.
    $gitBin = Split-Path (Get-Command git).Source -Parent
    $env:PATH = "$env:SystemRoot\System32;$PSHOME;$gitBin"
    $runCrash = Join-Path $work 'run-crash'
    New-Item -ItemType Directory -Path $runCrash | Out-Null
    Set-Content -LiteralPath (Join-Path $runCrash 'report.md') -Value 'STATUS: ready_for_review'
    $crash = Invoke-CodexRun @('-Repo', 'sample-app', '-Brief', $brief, '-RunDir', $runCrash, '-SkipQuotaCheck', '-GateCommand', 'none')
    $env:PATH = "$fakeBin;$originalPath"
    Assert-True ($crash.ExitCode -eq 1) "launcher crash exit changed: $($crash.ExitCode)"
    Assert-True ((Test-Path -LiteralPath (Join-Path $runCrash 'report.md')) -and (Get-Content -Raw -LiteralPath (Join-Path $runCrash 'report.md')) -match '(?s)^STATUS: failed.*Cause: crash: launcher error') 'launcher crash left no synthesized report'
    Assert-True ((Test-Path -LiteralPath (Join-Path $runCrash 'meta.json')) -and (Get-Content -Raw -LiteralPath (Join-Path $runCrash 'meta.json') | ConvertFrom-Json).reportSynthesized -eq $true) 'launcher crash did not mark meta.json'
    $crashMeta = Get-Content -Raw -LiteralPath (Join-Path $runCrash 'meta.json') | ConvertFrom-Json
    Assert-True ($crashMeta.repoRoot -eq $sampleRepo -and $crashMeta.github -eq 'fixture-team/SampleApp') 'Codex crash metadata lost repository identity'
    Assert-True (-not (Test-Path -LiteralPath (Get-RepoLockPath $lockDir $sampleRepo))) 'lock retained after launcher crash'
    $identityRun = Join-Path $work 'identity-run'
    $identityResult = Invoke-CodexRun @('-Repo', $repoA, '-Brief', $brief, '-RunDir', $identityRun, '-FullAccess', '-SkipQuotaCheck', '-GateCommand', 'none')
    $identityMeta = Get-Content -Raw -LiteralPath (Join-Path $identityRun 'meta.json') | ConvertFrom-Json
    Assert-True ($identityResult.ExitCode -eq 0 -and $identityMeta.repoRoot -eq $repoA -and $null -eq $identityMeta.github -and $null -ne $identityMeta.PSObject.Properties['github']) 'non-Git Codex metadata identity missing or not null'
    $mainRepo = Join-Path $work 'Acme-Api'
    New-Item -ItemType Directory -Path $mainRepo | Out-Null
    & git -C $mainRepo init -b main *> $null
    & git -C $mainRepo config core.autocrlf false
    [IO.File]::WriteAllText((Join-Path $mainRepo 'source.txt'), "fixture`n")
    & git -C $mainRepo add source.txt *> $null
    & git -C $mainRepo -c user.name=Fixture -c user.email=fixture@example.invalid commit -m fixture *> $null
    Assert-True ($LASTEXITCODE -eq 0) 'Codex identity fixture commit failed'
    $worktreeRepo = Join-Path $work '.worktrees\services-win-lag'
    & git -C $mainRepo worktree add -b win-lag $worktreeRepo *> $null
    Assert-True ($LASTEXITCODE -eq 0) 'Codex identity fixture worktree failed'
    & git -C $mainRepo remote add origin git@github.com:fixture-team/acme-api.git *> $null
    $worktreeRun = Join-Path $work 'worktree-run'
    [IO.File]::WriteAllText((Join-Path $worktreeRepo 'source.txt'), "fixture`r`n")
    $worktreeResult = Invoke-CodexRun @('-Repo', $worktreeRepo, '-Brief', $brief, '-RunDir', $worktreeRun, '-FullAccess', '-SkipQuotaCheck', '-GateCommand', 'none')
    $worktreeMeta = Get-Content -Raw -LiteralPath (Join-Path $worktreeRun 'meta.json') | ConvertFrom-Json
    Assert-True ($worktreeMeta.lineEndingOnly -is [array] -and $worktreeMeta.lineEndingOnly.Count -eq 1 -and $worktreeMeta.lineEndingOnly[0] -eq 'source.txt' -and $worktreeResult.Output.Contains("git checkout -- 'source.txt'")) 'Codex worktree run must report its line-ending-only file and restoration command'
    Assert-True ($worktreeResult.ExitCode -eq 0 -and $worktreeMeta.repo -eq 'acme-api' -and $worktreeMeta.repoPath -eq $worktreeRepo -and $worktreeMeta.repoRoot -eq $mainRepo -and $worktreeMeta.github -eq 'fixture-team/acme-api') 'Codex worktree metadata did not preserve target and main-checkout identity'
    $worktreeDry = Invoke-CodexRun @('-Repo', $worktreeRepo, '-Brief', $brief, '-FullAccess', '-DryRun')
    Assert-True ($worktreeDry.ExitCode -eq 0 -and $worktreeDry.Output.Contains('runs\acme-api\')) 'Codex worktree run naming kept the worktree leaf'

    # Resume lookup survives the worktree alias migration and prefers explicit locations.
    $legacySession = 'aaaaaaaa-7777-7777-7777-777777777777'
    $legacyAliasRun = Join-Path $root 'runs\services-win-lag\legacy-run'
    New-Item -ItemType Directory -Path $legacyAliasRun -Force | Out-Null
    @{ sessionId = $legacySession; model = 'gpt-6.2-sol'; reasoningEffort = 'high' } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $legacyAliasRun 'meta.json')
    $legacyAliasResume = Invoke-CodexRun @('-Repo', $worktreeRepo, '-Brief', $brief, '-Resume', $legacySession, '-FixLoop', '1', '-DryRun')
    Assert-True ($legacyAliasResume.ExitCode -eq 0 -and $legacyAliasResume.Output.Contains('-c model=gpt-6.2-sol') -and $legacyAliasResume.Output.Contains('-c model_reasoning_effort=high')) 'Codex legacy worktree alias resume lost recorded model/effort'
    $canonicalRun = Join-Path $root 'runs\acme-api\canonical-run'
    New-Item -ItemType Directory -Path $canonicalRun -Force | Out-Null
    @{ sessionId = $legacySession; model = 'gpt-6.2-sol'; reasoningEffort = 'medium' } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $canonicalRun 'meta.json')
    $canonicalResume = Invoke-CodexRun @('-Repo', $worktreeRepo, '-Brief', $brief, '-Resume', $legacySession, '-FixLoop', '1', '-DryRun')
    Assert-True ($canonicalResume.ExitCode -eq 0 -and $canonicalResume.Output.Contains('-c model=gpt-6.2-sol') -and $canonicalResume.Output.Contains('-c model_reasoning_effort=medium')) 'Codex canonical alias did not precede legacy alias'
    @{ sessionId = $legacySession; model = 'gpt-6.1-terra'; reasoningEffort = 'xhigh' } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path (Split-Path $brief) 'meta.json')
    $briefResume = Invoke-CodexRun @('-Repo', $worktreeRepo, '-Brief', $brief, '-Resume', $legacySession, '-FixLoop', '1', '-DryRun')
    Assert-True ($briefResume.ExitCode -eq 0 -and $briefResume.Output.Contains('-c model=gpt-6.1-terra') -and $briefResume.Output.Contains('-c model_reasoning_effort=xhigh')) 'Codex brief directory did not precede alias directories'
    $suppliedRun = Join-Path $work 'supplied-resume'
    New-Item -ItemType Directory -Path $suppliedRun | Out-Null
    @{ sessionId = $legacySession; model = 'gpt-6.1-terra'; reasoningEffort = 'low' } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $suppliedRun 'meta.json')
    $suppliedResume = Invoke-CodexRun @('-Repo', $worktreeRepo, '-Brief', $brief, '-RunDir', $suppliedRun, '-Resume', $legacySession, '-FixLoop', '1', '-DryRun')
    Assert-True ($suppliedResume.ExitCode -eq 0 -and $suppliedResume.Output.Contains('-c model=gpt-6.1-terra') -and $suppliedResume.Output.Contains('-c model_reasoning_effort=low')) 'Codex supplied run directory did not precede brief directory'
    $unknownWorktreeResume = Invoke-CodexRun @('-Repo', $worktreeRepo, '-Brief', $brief, '-Resume', 'ffffffff-9999-9999-9999-999999999999', '-FixLoop', '1', '-DryRun')
    Assert-True ($unknownWorktreeResume.ExitCode -eq 3 -and $unknownWorktreeResume.Output -match 'Cannot establish prior session identity') 'Codex unknown worktree session was not refused with exit 3'
}
catch {
    $failures.Add($_.Exception.Message)
}
finally {
    Remove-Item Env:FAKE_GATE_COUNTER -ErrorAction SilentlyContinue
    $env:PATH = $originalPath
    if ($null -eq $originalCodexHome) { Remove-Item Env:CODEX_HOME -ErrorAction SilentlyContinue }
    else { $env:CODEX_HOME = $originalCodexHome }
    Remove-Item Env:FAKE_CODEX_MODE -ErrorAction SilentlyContinue
    Remove-Item Env:FAKE_CODEX_REVIEW, Env:FAKE_CODEX_MCP_LIST, Env:FAKE_CODEX_MCP_ARGS -ErrorAction SilentlyContinue
    Remove-Item Env:FAKE_CODEBURN_MODE -ErrorAction SilentlyContinue
    Remove-Item Env:FAKE_CODEBURN_PCT -ErrorAction SilentlyContinue
    Remove-Item Env:FAKE_TIMEOUT_SCRIPT -ErrorAction SilentlyContinue
    Remove-Item Env:FAKE_CHILD_PID_PATH -ErrorAction SilentlyContinue
    if ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($work)) -ne [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetTempPath())) { throw 'unsafe fixture cleanup path' }
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Error $_ -ErrorAction Continue }
    exit 1
}

Write-Output "codex-run tests: PASS ($assertions assertions)"
