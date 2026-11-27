[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Repo,

    [Parameter(Mandatory = $true)]
    [string]$Brief,

    [string]$RunDir,

    [string]$Resume,

    [ValidateRange(1, 9)]
    [int]$FixLoop,

    [switch]$AllowExtraFixLoop,

    [switch]$SkipQuotaCheck,

    [ValidateRange(1, 100)]
    [int]$QuotaCapPercent,

    [ValidateSet('medium', 'high', 'xhigh')]
    [string]$Effort = 'high',

    [ValidateSet('claude-opus-5-5', 'claude-sonnet-5-5', 'claude-haiku-5-5')]
    [string]$Model,

    [ValidateRange(0.001, 1440)]
    [double]$TimeoutMinutes = 40,

    $GateCommand,

    [ValidateRange(0.001, 1440)]
    [double]$GateTimeoutMinutes = 20,

    [int]$AutoCompactTokens,

    [double]$MaxBudgetUsd,

    [int]$MaxResumeContextTokens,

    [string]$LockDir,

    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'RunCommon.ps1')
$SkillRoot = Get-PipelineSkillRoot
$HubRoot = Get-PipelineHome -NoCreate:$DryRun
if (-not $LockDir) {
    $LockDir = Join-Path $HubRoot 'runs\.locks'
    $QuotaCacheDir = Join-Path $HubRoot 'logs\quota'
}
else { $QuotaCacheDir = Join-Path $LockDir 'quota' }

function Format-ClaudeArgument([string]$Value) {
    if ($Value -match '\s') { return '"' + $Value.Replace('"', '\"') + '"' }
    return $Value
}

function Format-CmdArgument([string]$Value) {
    if ($Value -match '[\s"&|<>^()]') { return '"' + $Value.Replace('"', '\"') + '"' }
    return $Value
}

function New-ClaudeProcessInfo([string[]]$Arguments) {
    $info = [Diagnostics.ProcessStartInfo]::new()
    if ($script:ClaudeExe -match '\.(cmd|bat)$') {
        $info.FileName = $env:ComSpec
        $parts = @((Format-CmdArgument $script:ClaudeExe)) + @($Arguments | ForEach-Object { Format-CmdArgument $_ })
        $info.Arguments = '/d /s /c "' + ($parts -join ' ') + '"'
    }
    else {
        $info.FileName = $script:ClaudeExe
        foreach ($argument in $Arguments) { $info.ArgumentList.Add($argument) }
    }
    $info.WorkingDirectory = $script:RepoPath
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    [void]$info.Environment.Remove('ANTHROPIC_API_KEY')
    return $info
}

function Find-RecordedClaudeRun([string]$Alias, [string]$SessionId, [string]$BriefPath, [string]$SuppliedRunDir, [string]$RepoPath, [switch]$LatestCompleted) {
    $paths = [Collections.Generic.List[string]]::new()
    foreach ($candidateDir in @($SuppliedRunDir, [IO.Path]::GetDirectoryName($BriefPath))) {
        if ($candidateDir) {
            $candidate = Join-Path ([IO.Path]::GetFullPath($candidateDir)) 'meta.json'
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { $paths.Add($candidate) }
        }
    }
    $aliases = @($Alias)
    if ($RepoPath) {
        $legacyAlias = [IO.Path]::GetFileName([IO.Path]::TrimEndingDirectorySeparator($RepoPath)).ToLowerInvariant()
        if ($legacyAlias -and $legacyAlias -ne $Alias) { $aliases += $legacyAlias }
    }
    foreach ($runAlias in $aliases) {
        $runRoot = Join-Path $HubRoot "runs\$runAlias"
        if (Test-Path -LiteralPath $runRoot -PathType Container) {
            Get-ChildItem -Path (Join-Path $runRoot '*\meta.json'), (Join-Path $runRoot '*\*\meta.json') -File -ErrorAction SilentlyContinue |
                ForEach-Object { $paths.Add($_.FullName) }
        }
    }
    $latest = $null
    $latestEndedAt = [datetimeoffset]::MinValue
    foreach ($path in @($paths | Select-Object -Unique)) {
        try { $meta = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json } catch { continue }
        if ($null -ne $meta.PSObject.Properties['sessionId'] -and [string]$meta.sessionId -eq $SessionId) {
            if (-not $LatestCompleted) { return [IO.Path]::GetDirectoryName($path) }
            if ($null -eq $meta.PSObject.Properties['endedAt'] -or -not $meta.endedAt) { continue }
            try { $endedAt = [datetimeoffset]$meta.endedAt } catch { continue }
            if ($endedAt -gt $latestEndedAt) {
                $latest = [IO.Path]::GetDirectoryName($path)
                $latestEndedAt = $endedAt
            }
        }
    }
    return $latest
}

function Get-ClaudeResumeProgress([string]$RepoPath) {
    $fingerprint = Get-SourceFingerprint $RepoPath
    if (-not $fingerprint) { throw 'source fingerprint unavailable' }
    $head = (& git --no-optional-locks -c "safe.directory=$RepoPath" -C $RepoPath rev-parse --verify --quiet HEAD 2>$null | Out-String).TrimEnd()
    if ($LASTEXITCODE -ne 0) {
        $branch = (& git --no-optional-locks -c "safe.directory=$RepoPath" -C $RepoPath symbolic-ref -q HEAD 2>$null | Out-String).Trim()
        if ($LASTEXITCODE -ne 0 -or -not $branch) { throw 'HEAD unavailable' }
        & git --no-optional-locks -c "safe.directory=$RepoPath" -C $RepoPath show-ref --verify --quiet $branch 2>$null
        if ($LASTEXITCODE -ne 1) { throw 'HEAD unavailable' }
        $head = ''
    }
    $status = & git --no-optional-locks -c "safe.directory=$RepoPath" -C $RepoPath status --porcelain=v2 -uall 2>$null | Out-String
    if ($LASTEXITCODE -ne 0) { throw 'Git status unavailable' }
    return @{ fingerprint = $fingerprint; head = $head; status = $status }
}

if (-not (Test-Path -LiteralPath $Brief -PathType Leaf)) {
    throw "Brief file not found: $Brief"
}
if ($Resume -and -not $PSBoundParameters.ContainsKey('FixLoop')) {
    throw '-FixLoop is required with -Resume'
}
if ($PSBoundParameters.ContainsKey('FixLoop') -and -not $Resume) {
    throw '-FixLoop applies to -Resume only'
}

$Brief = (Resolve-Path -LiteralPath $Brief).Path
$registry = Get-ExecutorRegistry $HubRoot
if (-not $PSBoundParameters.ContainsKey('AutoCompactTokens')) {
    # Claude 5 models have 1M windows; a 150k threshold thrashes when a repository autoload alone fills ~125k tokens.
    $AutoCompactTokens = if ($null -ne $registry.Defaults.PSObject.Properties['claudeAutoCompactTokens']) { [int]$registry.Defaults.claudeAutoCompactTokens } else { [int]$registry.Defaults.autoCompactTokens }
}
if (-not $PSBoundParameters.ContainsKey('MaxBudgetUsd')) { $MaxBudgetUsd = [double]$registry.Defaults.maxBudgetUsd }
if (-not $PSBoundParameters.ContainsKey('MaxResumeContextTokens')) { $MaxResumeContextTokens = [int]$registry.Defaults.maxResumeContextTokens }
# The brief is replayed as input on every executor turn, so its size is a cost multiplier.
$briefWarnChars = if ($null -ne $registry.Defaults.PSObject.Properties['briefWarnChars']) { [int]$registry.Defaults.briefWarnChars } else { 6000 }
# The vendored Code economy section is fixed text, so only our text counts.
$briefChars = ([regex]::Replace((Get-Content -Raw -LiteralPath $Brief), '(?ms)^## Code economy\r?$.*?(?=^## )', '')).Length
$briefWarning = if ($briefChars -gt $briefWarnChars) { "brief warning: $briefChars characters, above $briefWarnChars; the brief is input on every executor turn" } else { $null }
$repoInfo = Resolve-ExecutorTarget $HubRoot $Repo
$script:RepoPath = $repoInfo.Path
$deadline = Get-ExecutorDeadline $TimeoutMinutes
$suppliedRunDir = $RunDir
if (-not $RunDir) { $RunDir = New-RunDirPath $HubRoot $repoInfo.Alias $Brief ([bool]$Resume) $FixLoop }
$RunDir = [IO.Path]::GetFullPath($RunDir)
$attemptStartedAt = [datetime]::MinValue
$startedAt = [datetime]::MinValue
try {
    Confirm-BriefPaths $Brief $repoInfo.Path $HubRoot
    $selectedGate = Get-GateCommand $repoInfo.Entry $GateCommand $PSBoundParameters.ContainsKey('GateCommand') ([IO.Path]::GetDirectoryName($Brief))
}
catch {
    Write-Output "claude-run: refused | $($_.Exception.Message)"
    exit 3
}
if (-not $PSBoundParameters.ContainsKey('GateCommand') -and (Test-Path -LiteralPath (Join-Path ([IO.Path]::GetDirectoryName($Brief)) 'brief.gate.json'))) {
    Write-Output 'gate source: brief.gate.json'
}
$GateTimeoutMinutes = Get-GateTimeoutMinutes $repoInfo.Entry $GateTimeoutMinutes $PSBoundParameters.ContainsKey('GateTimeoutMinutes')
$gateBudgetMinutes = if (Test-GateEnabled $selectedGate) { $GateTimeoutMinutes } else { 0 }
if ($TimeoutMinutes + $gateBudgetMinutes -gt 115) {
    Write-Output "warning: executor $TimeoutMinutes + gate $gateBudgetMinutes minutes exceeds the 115-minute background budget"
}

$maxFixLoops = [int]$registry.Defaults.maxFixLoops
$fixRefusal = if ($Resume) { Test-FixLoopGate $FixLoop $maxFixLoops $AllowExtraFixLoop.IsPresent } else { $null }
if ($fixRefusal) {
    Write-Output "claude-run: refused | $fixRefusal"
    exit 3
}

$resumeBaseline = $null
$repoPrefix = [IO.Path]::TrimEndingDirectorySeparator($repoInfo.Path)
if ($Resume -and -not $DryRun -and (Test-Path -LiteralPath (Join-Path $repoInfo.Path '.git')) -and
    $RunDir -ine $repoPrefix -and -not $RunDir.StartsWith($repoPrefix + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    try {
        $baselineDir = Find-RecordedClaudeRun $repoInfo.Alias $Resume $Brief $suppliedRunDir $repoInfo.Path -LatestCompleted
        if (-not $baselineDir) { throw 'no completed attempt baseline' }
        $baseline = Get-Content -Raw -LiteralPath (Join-Path $baselineDir 'result.json') | ConvertFrom-Json
        if ($null -eq $baseline.PSObject.Properties['result'] -or $null -eq $baseline.result) { throw 'no previous result text' }
        $resumeBaseline = ([string]$baseline.result).TrimEnd()
    }
    catch { Write-Output "warning: resume no-op detection skipped: $($_.Exception.Message)" }
}

$allowedModels = @('claude-opus-5-5', 'claude-sonnet-5-5', 'claude-haiku-5-5')
$briefIdentity = Get-BriefExecutorIdentity $Brief 'claude'
$resumeGuard = $null
if ($Resume) {
    $previousRunDir = Find-RecordedClaudeRun $repoInfo.Alias $Resume $Brief $suppliedRunDir $repoInfo.Path
    $previousMeta = $null
    $metaPath = if ($previousRunDir) { Join-Path $previousRunDir 'meta.json' } else { $null }
    if ($metaPath -and (Test-Path -LiteralPath $metaPath -PathType Leaf)) {
        try { $previousMeta = Get-Content -Raw -LiteralPath $metaPath | ConvertFrom-Json } catch { $previousMeta = $null }
    }

    if ($null -ne $previousMeta -and $null -ne $previousMeta.PSObject.Properties['model'] -and [string]$previousMeta.model -and [string]$previousMeta.model -notin $allowedModels) {
        Write-Output "claude-run: refused | recorded model '$($previousMeta.model)' is retired or unsupported; start a fresh executor with a fix-<n>.md brief in the same run directory."
        exit 3
    }
    $resultPath = if ($previousRunDir) { Join-Path $previousRunDir 'result.json' } else { $null }
    $previousResult = $null
    if ($resultPath -and (Test-Path -LiteralPath $resultPath -PathType Leaf)) {
        try { $previousResult = Get-Content -Raw -LiteralPath $resultPath | ConvertFrom-Json } catch { $previousResult = $null }
    }
    if ($null -eq $previousResult -or $null -eq $previousResult.PSObject.Properties['num_turns'] -or $null -eq $previousResult.PSObject.Properties['usage'] -or $null -eq $previousResult.usage.PSObject.Properties['cache_read_input_tokens']) {
        Write-Output "claude-run: refused | resume refused: no recorded run for session $Resume under runs\$($repoInfo.Alias); launch a fresh session"
        exit 3
    }
    $contextPerTurn = [math]::Round([double]$previousResult.usage.cache_read_input_tokens / [math]::Max(1, [int]$previousResult.num_turns))
    if ($contextPerTurn -gt $MaxResumeContextTokens) {
        Write-Output "claude-run: refused | resume refused: transcript averages $contextPerTurn tokens per turn (limit $MaxResumeContextTokens); write a fresh fix brief and launch a new session"
        exit 3
    }
    $resumeGuard = [ordered]@{ previousRunDir = $previousRunDir; contextPerTurn = $contextPerTurn; limit = $MaxResumeContextTokens }

    # The recorded session's model/effort carry forward unless the caller states an
    # explicit, matching value; a mismatch or an unusable legacy record needs a fresh session.
    $recordedModel = $null
    if ($null -ne $previousMeta -and $null -ne $previousMeta.PSObject.Properties['model'] -and $allowedModels -contains [string]$previousMeta.model) {
        $recordedModel = [string]$previousMeta.model
    }
    if ($PSBoundParameters.ContainsKey('Model')) {
        if ($null -ne $recordedModel -and $recordedModel -ne $Model) {
            Write-Output "claude-run: refused | resume refused: -Model $Model does not match recorded model $recordedModel for session $Resume; launch a fresh session"
            exit 3
        }
    }
    elseif ($null -ne $recordedModel) {
        $Model = $recordedModel
    }
    else {
        Write-Output "claude-run: refused | resume refused: recorded model missing or unsupported for session $Resume; pass -Model explicitly"
        exit 3
    }

    $recordedEffort = $null
    if ($null -ne $previousMeta -and $null -ne $previousMeta.PSObject.Properties['effort'] -and @('medium', 'high', 'xhigh') -contains [string]$previousMeta.effort) {
        $recordedEffort = [string]$previousMeta.effort
    }
    if ($PSBoundParameters.ContainsKey('Effort')) {
        if ($null -ne $recordedEffort -and $recordedEffort -ne $Effort) {
            Write-Output "claude-run: refused | resume refused: -Effort $Effort does not match recorded effort $recordedEffort for session $Resume; launch a fresh session"
            exit 3
        }
    }
    elseif ($null -ne $recordedEffort) {
        $Effort = $recordedEffort
    }
    else {
        Write-Output "claude-run: refused | resume refused: recorded effort missing or unsupported for session $Resume; pass -Effort explicitly"
        exit 3
    }
}
if (-not $PSBoundParameters.ContainsKey('Model') -and -not $Resume) {
    $Model = if ($briefIdentity.Model) { $briefIdentity.Model } elseif ($null -ne $registry.Defaults.PSObject.Properties['model']) { [string]$registry.Defaults.model } else { 'claude-opus-5-5' }
}
if (-not $PSBoundParameters.ContainsKey('Effort') -and -not $Resume -and $briefIdentity.Effort) { $Effort = $briefIdentity.Effort }
if ($Model -notin $allowedModels) { throw "Unsupported resolved Claude model '$Model'. Allowed: $($allowedModels -join ', ')." }
if ($Effort -notin @('medium', 'high', 'xhigh')) { throw "Unsupported resolved Claude effort '$Effort'." }
if (-not $Resume -and (($PSBoundParameters.ContainsKey('Model') -and $briefIdentity.Model -and $Model -ne $briefIdentity.Model) -or ($PSBoundParameters.ContainsKey('Effort') -and $briefIdentity.Effort -and $Effort -ne $briefIdentity.Effort))) {
    Write-Output "identity override: brief $($briefIdentity.Model)/$($briefIdentity.Effort); explicit selection $Model/$Effort"
}
if (-not $PSBoundParameters.ContainsKey('QuotaCapPercent')) {
    # A fresh lot needs most of a window; a fix loop resume needs a slice of one.
    $capKey = if ($Resume -and $null -ne $registry.Defaults.PSObject.Properties['quotaCapPercentResume']) { 'quotaCapPercentResume' } else { 'quotaCapPercent' }
    $QuotaCapPercent = [int]$registry.Defaults.$capKey
}
# A dry run spends nothing, so only a real launch pays for the quota reading.
# Without a reading the launch is blind, so the gate fails closed; -SkipQuotaCheck is the explicit override.
if (-not $DryRun -and -not $SkipQuotaCheck) {
    $quotaGate = Test-QuotaGate 'claude' $QuotaCapPercent ([int]$registry.Defaults.quotaRefreshTimeoutSeconds) $Model $QuotaCacheDir ([int]$registry.Defaults.quotaCacheTtlSeconds)
    if ($quotaGate -like 'quota gate:*') {
        Write-Output "claude-run: refused | $quotaGate"
        exit 4
    }
    if ($quotaGate -like 'skipped:*' -and $quotaGate -ne 'skipped: codeburn is not on PATH') {
        Write-Output "claude-run: refused | quota gate: claude gave no reading ($quotaGate); check the window yourself and pass -SkipQuotaCheck"
        exit 4
    }
    if ($quotaGate -eq 'skipped: codeburn is not on PATH') { Write-Warning $quotaGate }
    else { Write-Output "quota gate: $quotaGate" }
}

$sessionId = if ($Resume) { $Resume } else { [guid]::NewGuid().ToString() }
$budgetText = [Convert]::ToString($MaxBudgetUsd, [Globalization.CultureInfo]::InvariantCulture)
$settings = @{
    fallbackModel = @()
    switchModelsOnFlag = $false
    hooks = @{ PreToolUse = @(@{
        matcher = 'Bash|PowerShell'
        hooks = @(@{ type = 'command'; command = 'pwsh -NoProfile -File "' + (Join-Path $SkillRoot 'hooks\guard-executor-git.ps1') + '"' })
    }) }
} | ConvertTo-Json -Depth 8 -Compress -EscapeHandling EscapeHtml
# Keep cmd shims from interpreting the hook matcher's pipe.
$settings = $settings.Replace('|', '\u007c')
$arguments = @(
    '--plugin-dir', ([IO.Path]::GetFullPath((Join-Path $SkillRoot '..\..'))),
    '--print', '--agent', 'pipeline:implementer', '--model', $Model, '--effort', $Effort,
    '--settings', $settings,
    '--permission-mode', 'acceptEdits', '--disallowedTools', 'Agent', '--strict-mcp-config',
    '--output-format', 'json', '--allowedTools', 'Read,Edit,Write,Glob,Grep,Bash,PowerShell',
    '--autocompact', [string]$AutoCompactTokens, '--max-budget-usd', $budgetText,
    '--add-dir', $RunDir
)
if ($Resume) { $arguments += @('--resume', $Resume) } else { $arguments += @('--session-id', $sessionId) }
$arguments += "Read the executor prompt at $(Join-Path $RunDir 'executor-prompt.md') first. Work only in $($repoInfo.Path) and the run directory $RunDir, within that brief. Your final response must be the report in the shape the brief names."
$argumentLine = ($arguments | ForEach-Object { Format-ClaudeArgument $_ }) -join ' '
if ($briefWarning) { Write-Output $briefWarning }

if ($DryRun) {
    if (-not $SkipQuotaCheck) {
        $dryQuota = Test-QuotaGate 'claude' $QuotaCapPercent ([int]$registry.Defaults.quotaRefreshTimeoutSeconds) $Model $QuotaCacheDir ([int]$registry.Defaults.quotaCacheTtlSeconds) -CacheOnly
        Write-Output $(if ($dryQuota -like 'quota gate:*') { $dryQuota } else { "quota gate: $dryQuota" })
    }
    $lockState = Get-RepoLockState $LockDir $repoInfo.Path
    Write-Output "lock: $($lockState.Status)"
    if ($null -ne $repoInfo.Entry -and $null -ne $repoInfo.Entry.PSObject.Properties['heavyGate'] -and $repoInfo.Entry.heavyGate -eq $true) {
        $heavyState = Get-RepoLockState $LockDir (Join-Path $HubRoot '.heavy-gate')
        Write-Output "heavy gate lock: $($heavyState.Status)"
    }
    Write-Output "command: claude $argumentLine"
    Write-Output "gate command: $selectedGate"
    Write-Output "run dir: $RunDir"
    Write-Output (Get-ExecutorRoleHeader $Brief $deadline $RunDir)
    Write-Output 'gate: allowed'
    exit 0
}

$heavyGate = $null -ne $repoInfo.Entry -and $null -ne $repoInfo.Entry.PSObject.Properties['heavyGate'] -and $repoInfo.Entry.heavyGate -eq $true
$heavyGateTarget = Join-Path $HubRoot '.heavy-gate'
$heavyLock = $null
$deviceLocks = [Collections.Generic.List[object]]::new()
$repoLock = Enter-RepoLock $LockDir $repoInfo.Path $RunDir
if (-not $repoLock.Acquired) {
    $owner = $repoLock.State.Owner
    $busyRun = if ($owner) { $owner.runDir } else { 'unknown' }
    $busyPid = if ($owner) { $owner.pid } else { 'unknown' }
    Write-Output "repo busy: $($repoInfo.Path) (run $busyRun, pid $busyPid)"
    exit 3
}
if ($repoLock.State.Status -eq 'stale') { Write-Output "warning: stale repo lock taken over: $($repoLock.State.Path)" }
try {
Set-RunExecutionState $true
foreach ($serial in @(Get-BriefDevices $Brief)) {
    $deviceLock = Enter-RepoLock $LockDir (Get-DeviceLockTarget $HubRoot $serial) $RunDir
    if (-not $deviceLock.Acquired) {
        $owner = $deviceLock.State.Owner
        $busyRun = if ($owner) { $owner.runDir } else { 'unknown' }
        $busyPid = if ($owner) { $owner.pid } else { 'unknown' }
        Write-Output "device busy: $serial (run $busyRun, pid $busyPid)"
        exit 3
    }
    $deviceLocks.Add($deviceLock)
    if ($deviceLock.State.Status -eq 'stale') { Write-Output "warning: stale device lock taken over: $serial ($($deviceLock.State.Path))" }
}
if ($heavyGate) {
    $heavyLock = Enter-RepoLock $LockDir $heavyGateTarget $RunDir
    if (-not $heavyLock.Acquired) {
        $owner = $heavyLock.State.Owner
        $busyRun = if ($owner) { $owner.runDir } else { 'unknown' }
        $busyPid = if ($owner) { $owner.pid } else { 'unknown' }
        Write-Output "heavy gate busy: another heavy-gate run holds the machine lock (run $busyRun, pid $busyPid)"
        exit 3
    }
    if ($heavyLock.State.Status -eq 'stale') { Write-Output "warning: stale heavy gate lock taken over: $($heavyLock.State.Path)" }
}
$resumeProgress = $null
if ($null -ne $resumeBaseline) {
    try { $resumeProgress = Get-ClaudeResumeProgress $repoInfo.Path }
    catch { Write-Output "warning: resume no-op detection skipped: $($_.Exception.Message)" }
}
$attemptStartedAt = [DateTime]::UtcNow
$attempts = Get-RunAttempts $RunDir ([bool]$Resume)
New-Item -ItemType Directory -Force -Path $RunDir | Out-Null
$RunDir = (Resolve-Path -LiteralPath $RunDir).Path
$runBrief = Join-Path $RunDir 'brief.md'
# Never overwrite the run's first brief: a later brief from outside the run directory keeps its own name.
if ([IO.Path]::GetDirectoryName($Brief) -ine $RunDir) {
    $briefCopy = if (Test-Path -LiteralPath $runBrief) { Join-Path $RunDir ([IO.Path]::GetFileName($Brief)) } else { $runBrief }
    if (-not (Test-Path -LiteralPath $briefCopy)) { Copy-Item -LiteralPath $Brief -Destination $briefCopy }
}
$promptPath = Join-Path $RunDir 'executor-prompt.md'
$briefBody = Get-Content -Raw -LiteralPath $Brief
[IO.File]::WriteAllText($promptPath, (Get-ExecutorRoleHeader $Brief $deadline $RunDir) + $briefBody, [Text.UTF8Encoding]::new($false))
$script:ClaudeExe = (Get-Command claude -ErrorAction Stop).Source

$authInfo = New-ClaudeProcessInfo @('auth', 'status', '--json')
$authProcess = [Diagnostics.Process]::new()
$authProcess.StartInfo = $authInfo
[void]$authProcess.Start()
$authOutTask = $authProcess.StandardOutput.ReadToEndAsync()
$authErrTask = $authProcess.StandardError.ReadToEndAsync()
$authTimedOut = -not $authProcess.WaitForExit(30000)
if ($authTimedOut) {
    $authProcess.Kill($true)
    [void]$authProcess.WaitForExit(5000)
}
$authText = $authOutTask.GetAwaiter().GetResult()
[void]$authErrTask.GetAwaiter().GetResult()
$authState = $null
try { $authState = $authText | ConvertFrom-Json } catch { $authState = $null }
$authOkay = -not $authTimedOut -and $authProcess.ExitCode -eq 0 -and $null -ne $authState -and $authState.loggedIn -eq $true -and $authState.authMethod -eq 'claude.ai' -and $authState.apiProvider -eq 'firstParty'
$authDecision = [ordered]@{
    verified = $authOkay
    authMethod = if ($authOkay) { 'claude.ai' } else { 'unverified' }
    apiProvider = if ($authOkay) { 'firstParty' } else { 'unverified' }
    apiKeyRemovedFromChild = $true
}
$authDecision | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $RunDir 'auth-decision.json') -Encoding utf8
if (-not $authOkay) {
    [ordered]@{
        attempts = $attempts
        repo = $repoInfo.Alias
        repoPath = $repoInfo.Path
        repoRoot = $repoInfo.Root
        github = $repoInfo.GitHub
        brief = $Brief
        runDir = $RunDir
        sessionId = $null
        model = $Model
        briefModel = $briefIdentity.Model
        briefEffort = $briefIdentity.Effort
        effort = $Effort
        auth = $authDecision
        deadlineLocal = $deadline.DeadlineLocal
        reportByLocal = $deadline.ReportByLocal
        startedAt = [DateTime]::UtcNow.ToString('o')
        wrapperExitCode = 2
        reportPresent = $false
        reportSynthesized = Write-MissingReport $RunDir 'auth: Claude subscription authentication not verified; no model launched' -AttemptStartedAt $attemptStartedAt
    } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $RunDir 'meta.json') -Encoding utf8
    Write-Output 'claude-run: authentication not verified; no model launched'
    Write-Output "run dir: $RunDir"
    exit 2
}

$info = New-ClaudeProcessInfo $arguments
$process = [Diagnostics.Process]::new()
$process.StartInfo = $info
Invoke-TaskUsage $HubRoot $RunDir 'start' | Write-Output
$startedAt = [DateTime]::UtcNow
$deadline = Get-ExecutorDeadline $TimeoutMinutes ([datetimeoffset]$startedAt)
[IO.File]::WriteAllText($promptPath, (Get-ExecutorRoleHeader $Brief $deadline $RunDir) + $briefBody, [Text.UTF8Encoding]::new($false))
$meta = [ordered]@{
    attempts = $attempts
    repo = $repoInfo.Alias
    repoPath = $repoInfo.Path
    repoRoot = $repoInfo.Root
    github = $repoInfo.GitHub
    brief = $Brief
    runDir = $RunDir
    resumedFrom = if ($Resume) { $Resume } else { $null }
    fixLoop = if ($Resume) { $FixLoop } else { $null }
    sessionId = $sessionId
    model = $Model
    briefModel = $briefIdentity.Model
    briefEffort = $briefIdentity.Effort
    effort = $Effort
    autoCompactTokens = $AutoCompactTokens
    maxBudgetUsd = $MaxBudgetUsd
    briefChars = $briefChars
    numTurns = $null
    contextPerTurn = $null
    totalCostUsd = $null
    auth = $authDecision
    resumeGuard = $resumeGuard
    deadlineLocal = $deadline.DeadlineLocal
    reportByLocal = $deadline.ReportByLocal
    startedAt = $startedAt.ToString('o')
    pid = $null
    endedAt = $null
    exitCode = $null
    timedOut = $false
    processTerminated = $false
    terminationDiagnostic = $null
    permissionDenials = $null
    reportPresent = $false
    actualModels = @()
    resultIsError = $null
    wrapperExitCode = $null
}
[void]$process.Start()
$meta.pid = $process.Id
$launchedProcessStartedAt = $process.StartTime.ToUniversalTime()
$meta | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $RunDir 'meta.json') -Encoding utf8
$outTask = $process.StandardOutput.ReadToEndAsync()
$errTask = $process.StandardError.ReadToEndAsync()
$timeoutMilliseconds = [int][Math]::Min([int]::MaxValue, [Math]::Ceiling($TimeoutMinutes * 60 * 1000))
$meta.timedOut = -not $process.WaitForExit($timeoutMilliseconds)
if ($meta.timedOut) {
    try {
        $currentProcess = Get-Process -Id $process.Id -ErrorAction SilentlyContinue
        if ($null -ne $currentProcess -and $currentProcess.StartTime.ToUniversalTime() -eq $launchedProcessStartedAt) {
            $process.Kill($true)
            $process.WaitForExit()
            $meta.processTerminated = $true
        }
        elseif ($null -ne $currentProcess) {
            $meta.terminationDiagnostic = 'PID identity changed; no termination attempted'
        }
    }
    catch {
        $meta.terminationDiagnostic = "exact process-tree termination failed: $($_.Exception.Message)"
    }
}
$meta.stoppedJobs = @(Stop-RunJobs $RunDir $startedAt)
$stdout = $outTask.GetAwaiter().GetResult()
$stderr = $errTask.GetAwaiter().GetResult()
[IO.File]::WriteAllText((Join-Path $RunDir 'result.json'), $stdout)
[IO.File]::WriteAllText((Join-Path $RunDir 'claude.stderr.log'), $stderr)
$meta.exitCode = if ($process.HasExited) { $process.ExitCode } else { $null }
$meta.endedAt = [DateTime]::UtcNow.ToString('o')
try {
    $result = $stdout | ConvertFrom-Json
    if ($null -ne $result.PSObject.Properties['permission_denials']) { $meta.permissionDenials = @($result.permission_denials).Count }
    if ($null -ne $result.PSObject.Properties['result'] -and $result.result) {
        [IO.File]::WriteAllText((Join-Path $RunDir 'report.md'), [string]$result.result)
        $meta.reportPresent = $true
    }
    if ($null -ne $result.PSObject.Properties['session_id'] -and $result.session_id) { $meta.sessionId = $result.session_id }
    if ($null -ne $result.PSObject.Properties['modelUsage']) { $meta.actualModels = @($result.modelUsage.PSObject.Properties.Name) }
    if ($null -ne $result.PSObject.Properties['is_error']) { $meta.resultIsError = [bool]$result.is_error }
    if ($null -ne $result.PSObject.Properties['num_turns']) { $meta.numTurns = [int]$result.num_turns }
    if ($null -ne $result.PSObject.Properties['total_cost_usd']) { $meta.totalCostUsd = [double]$result.total_cost_usd }
    if ($null -ne $meta.numTurns -and $null -ne $result.PSObject.Properties['usage'] -and $null -ne $result.usage.PSObject.Properties['cache_read_input_tokens']) {
        $meta.contextPerTurn = [int][math]::Round([double]$result.usage.cache_read_input_tokens / [math]::Max(1, $meta.numTurns))
    }
}
catch {
    $meta.resultIsError = $true
}
$meta.wrapperExitCode = if ($meta.timedOut) { 124 } elseif ($meta.exitCode -ne 0 -or -not $meta.reportPresent -or $meta.resultIsError) { 1 } else { 0 }
$meta.reportSynthesized = $false
if ($null -ne $resumeProgress -and $meta.reportPresent) {
    try { $progress = Get-ClaudeResumeProgress $repoInfo.Path }
    catch {
        $progress = $null
        Write-Output "warning: resume no-op detection skipped: $($_.Exception.Message)"
    }
    if ($null -ne $progress -and ([string]$result.result).TrimEnd() -ceq $resumeBaseline -and
        $progress.fingerprint -ceq $resumeProgress.fingerprint -and $progress.head -ceq $resumeProgress.head -and $progress.status -ceq $resumeProgress.status) {
        Move-Item -LiteralPath (Join-Path $RunDir 'report.md') -Destination (Join-Path $RunDir 'report.previous.md') -Force
        [IO.File]::WriteAllText((Join-Path $RunDir 'report.md'), "STATUS: failed`n`nCause: resume repeated the previous report without changes`n", [Text.UTF8Encoding]::new($false))
        $meta.wrapperExitCode = 1
        $meta.reportSynthesized = $true
        $meta.resumeNoop = $true
    }
}
$meta.gate = $null
if ($meta.wrapperExitCode -eq 0 -and (Test-GateEnabled $selectedGate)) {
    $meta.gate = Invoke-LauncherGate $selectedGate $repoInfo.Path $RunDir $GateTimeoutMinutes (Get-GateFailurePattern $repoInfo.Entry) ([IO.Path]::GetDirectoryName($Brief)) (Get-GateRetries $repoInfo.Entry $registry.Defaults)
    $reusedNote = if ($meta.gate.reused) { ' (reused)' } else { '' }
    $flakyNote = if (($meta.gate -is [Collections.IDictionary] -and $meta.gate.Contains('flaky') -or $null -ne $meta.gate.PSObject.Properties['flaky']) -and $meta.gate.flaky) { " (flaky: green on retry $(@($meta.gate.attempts).Count - 1); $(@($meta.gate.attempts[0].failures).Count) failures first)" } else { '' }
    Write-Output "gate: exit $($meta.gate.exitCode)$flakyNote$reusedNote"
    if ($meta.gate.timedOut -or $meta.gate.exitCode -ne 0) { $meta.wrapperExitCode = 5 }
}
if (-not $meta.reportPresent) {
    $cause = if ($meta.timedOut) { "deadline: the executor exceeded -TimeoutMinutes $TimeoutMinutes" }
    elseif ($meta.exitCode -ne 0) { "executor error: claude exited $($meta.exitCode)" }
    elseif ($meta.resultIsError) { 'executor error: the result was an error or unreadable' }
    else { 'executor error: the session ended without a final message' }
    $meta.reportSynthesized = Write-MissingReport $RunDir $cause -AttemptStartedAt $attemptStartedAt
}
$meta | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $RunDir 'meta.json') -Encoding utf8
Invoke-TaskUsage $HubRoot $RunDir 'finish' | Write-Output

$reportState = if ($meta.reportPresent) { 'written' } else { 'missing' }
$loopState = if ($Resume) { $FixLoop } else { 'none' }
$executorExitNote = if ($meta.wrapperExitCode -ne $meta.exitCode) { " (executor $($meta.exitCode))" } else { '' }
Write-Output "claude-run: exit $($meta.wrapperExitCode)$executorExitNote | session $($meta.sessionId) | report $reportState | timedOut $($meta.timedOut) | fixLoop $loopState | turns $($meta.numTurns) | contextPerTurn $($meta.contextPerTurn) | usd $($meta.totalCostUsd)"
Write-Output "run dir: $RunDir"
exit $meta.wrapperExitCode
}
catch {
    [void](Write-MissingReport $RunDir "crash: launcher error: $($_.Exception.Message)" -UpdateMeta -Target $repoInfo -AttemptStartedAt $attemptStartedAt)
    throw
}
finally {
    [void](Stop-RunJobs $RunDir $startedAt)
    Write-LineEndingSummary $repoInfo.Path $RunDir
    try {
        try { if ($null -ne $heavyLock -and $heavyLock.Acquired) { Exit-RepoLock $heavyLock } }
        finally {
            try { foreach ($deviceLock in $deviceLocks) { Exit-RepoLock $deviceLock } }
            finally { Exit-RepoLock $repoLock }
        }
    }
    finally { Set-RunExecutionState $false }
}
