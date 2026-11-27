Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-PipelineSkillRoot {
    $directory = Get-Item -LiteralPath (Join-Path $PSScriptRoot '..') -Force
    if ($directory.LinkType) { return $directory.ResolveLinkTarget($true).FullName }
    return $directory.FullName
}

function Get-PipelineHome([switch]$NoCreate) {
    $state = [IO.Path]::GetFullPath($(if ($env:PIPELINE_HOME) { $env:PIPELINE_HOME } else { Join-Path $HOME '.pipeline' }))
    if (-not $NoCreate) {
        foreach ($relative in @('config', 'runs\.locks', 'logs\quota')) { [void][IO.Directory]::CreateDirectory((Join-Path $state $relative)) }
    }
    return $state
}

function Merge-RegistryObject($Target, $Override) {
    foreach ($property in $Override.PSObject.Properties) {
        $current = $Target.PSObject.Properties[$property.Name]
        if ($null -ne $current -and $current.Value -is [pscustomobject] -and $property.Value -is [pscustomobject]) {
            Merge-RegistryObject $current.Value $property.Value
        }
        else { $Target | Add-Member -NotePropertyName $property.Name -NotePropertyValue $property.Value -Force }
    }
}

function Get-ExecutorRegistry([string]$HubRoot) {
    $json = Get-Content -Raw -LiteralPath (Join-Path (Get-PipelineSkillRoot) 'config\executors.json') | ConvertFrom-Json
    $path = Join-Path $HubRoot 'config\executors.json'
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        $user = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json
        if ($user -isnot [pscustomobject]) { throw "Invalid executor registry: $path" }
        Merge-RegistryObject $json $user
    }
    return [pscustomobject]@{ Defaults = $json.defaults; Executors = $json.executors }
}

function Resolve-ExecutorTarget([string]$HubRoot, [string]$Name) {
    $registry = Get-ExecutorRegistry $HubRoot
    $key = $Name.ToLowerInvariant()
    $entry = $registry.Executors.PSObject.Properties[$key]
    $matchEntry = $null
    $alias = $null
    if ($null -ne $entry) {
        if ($key -notmatch '^[a-z0-9][a-z0-9._-]*$') { throw "Invalid repository alias '$Name'" }
        $full = if ($null -ne $entry.Value.PSObject.Properties['repo'] -and $entry.Value.repo) { [string]$entry.Value.repo } else { (Get-Location).Path }
        $matchEntry = $entry.Value
        $alias = $key
    }
    else {
        $projectPath = Join-Path $HubRoot 'config\projects.json'
        $project = if (Test-Path -LiteralPath $projectPath -PathType Leaf) { (Get-Content -Raw -LiteralPath $projectPath | ConvertFrom-Json).projects.PSObject.Properties[$key] } else { $null }
        if ($null -ne $project) {
            $full = [string]$project.Value.repo
            $alias = $key
        }
        elseif (Test-Path -LiteralPath $Name -PathType Container) { $full = (Resolve-Path -LiteralPath $Name).Path }
        else { throw "Repo '$Name' is neither a registered alias nor an existing directory." }
    }
    if (-not (Test-Path -LiteralPath $full -PathType Container)) { throw "Repository path does not exist: $full" }
    $full = (Resolve-Path -LiteralPath $full).Path
    $repoRoot = $full
    $github = $null
    $githubReason = 'not a git repository'
    if (Test-Path -LiteralPath (Join-Path $full '.git')) {
        $commonDir = (& git --no-optional-locks -c "safe.directory=$full" -C $full rev-parse --path-format=absolute --git-common-dir 2>$null | Out-String).Trim()
        if ($LASTEXITCODE -ne 0 -or -not $commonDir) { throw "could not resolve Git common directory for '$full'" }
        $repoRoot = Split-Path -Path ([IO.Path]::TrimEndingDirectorySeparator($commonDir)) -Parent
        $origin = (& git --no-optional-locks -c "safe.directory=$full" -C $full remote get-url origin 2>$null | Out-String).Trim()
        if ($LASTEXITCODE -ne 0 -or -not $origin) { $githubReason = 'no origin remote' }
        elseif ($origin -match '^(?:https?://(?:[^/@]+@)?github\.com(?::\d+)?/|ssh://(?:[^/@]+@)?github\.com(?::\d+)?/|(?:[^/@:]+@)?github\.com:)([^/]+)/([^/?#]+?)(?:\.git)?/?$') {
            $github = "$($Matches[1])/$($Matches[2])"
            $githubReason = $null
        }
        else { $githubReason = 'origin host is not github.com (Azure DevOps and other hosts have no GitHub identity)' }
    }
    if ($null -eq $matchEntry) {
        $match = $registry.Executors.PSObject.Properties | Where-Object {
            $null -ne $_.Value.PSObject.Properties['repo'] -and $_.Value.repo -and [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath([string]$_.Value.repo)) -ieq $repoRoot
        } | Select-Object -First 1
        if (-not $match -and $github) {
            $match = $registry.Executors.PSObject.Properties | Where-Object { $null -ne $_.Value.PSObject.Properties['github'] -and $_.Value.github -ieq $github } | Select-Object -First 1
        }
        if ($match) { $alias = $match.Name; $matchEntry = $match.Value }
    }
    elseif ($null -eq $matchEntry.PSObject.Properties['repo'] -or -not $matchEntry.repo) {
        if (-not $github -or $null -eq $matchEntry.PSObject.Properties['github'] -or $github -ine $matchEntry.github) {
            throw "Alias '$Name' has no user repo path and the current checkout origin does not match; pass a checkout path or configure repo in PIPELINE_HOME\config\executors.json."
        }
    }
    if (-not $alias) { $alias = (Split-Path -Path $repoRoot -Leaf).ToLowerInvariant() }
    if ($null -ne $matchEntry -and $null -ne $matchEntry.PSObject.Properties['github'] -and $matchEntry.github) {
        $github = [string]$matchEntry.github
        $githubReason = $null
    }
    return [pscustomobject]@{ Alias = $alias; Path = $full; Root = $repoRoot; GitHub = $github; GitHubReason = $githubReason; Entry = $matchEntry }
}

# Native stdout is decoded with the console codepage; read non-ASCII text (issue bodies, branch names) as UTF-8 and restore it.
function Invoke-Utf8Native([scriptblock]$Command) {
    $previous = [Console]::OutputEncoding
    try { [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false); & $Command }
    finally { [Console]::OutputEncoding = $previous }
}

function Write-LineEndingSummary([string]$RepoPath, [string]$RunDir) {
    $metaPath = Join-Path $RunDir 'meta.json'
    if (-not (Test-Path -LiteralPath $metaPath -PathType Leaf)) { return }
    $previousEncoding = [Console]::OutputEncoding
    $previousExitCode = Get-Variable LASTEXITCODE -Scope Global -ValueOnly -ErrorAction SilentlyContinue
    try {
        [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
        $lineEndingOnly = @()
        try {
            if (Test-Path -LiteralPath (Join-Path $RepoPath '.git')) {
                $changed = (& git --no-optional-locks -c "safe.directory=$RepoPath" -C $RepoPath diff --no-ext-diff --no-textconv --name-only -z 2>$null) -join "`n"
                if ($LASTEXITCODE -ne 0) { throw 'git diff failed' }
                foreach ($path in ($changed -split "`0" | Where-Object { $_ })) {
                    & git --no-optional-locks -c "safe.directory=$RepoPath" -C $RepoPath diff --no-ext-diff --no-textconv --ignore-cr-at-eol --quiet -- $path 2>$null
                    if ($LASTEXITCODE -eq 0) { $lineEndingOnly += $path }
                    elseif ($LASTEXITCODE -ne 1) { throw "git diff failed for $path" }
                }
            }
        }
        catch { $lineEndingOnly = @(); Write-Warning "line-ending scan: $($_.Exception.Message)" }
        $meta = Get-Content -Raw -LiteralPath $metaPath | ConvertFrom-Json -DateKind String
        $meta | Add-Member -NotePropertyName lineEndingOnly -NotePropertyValue $lineEndingOnly -Force
        $meta | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $metaPath -Encoding utf8
        if ($lineEndingOnly.Count) {
            $paths = ($lineEndingOnly | ForEach-Object { "'" + $_.Replace("'", "''") + "'" }) -join ' '
            Write-Output "line-ending-only: $paths | restore: git checkout -- $paths"
        }
    }
    catch { Write-Warning "line-ending summary: $($_.Exception.Message)" }
    finally { [Console]::OutputEncoding = $previousEncoding; $global:LASTEXITCODE = $previousExitCode }
}

function Get-GitHubAccount([string]$HubRoot, [string]$RepoRoot) {
    $defaults = (Get-ExecutorRegistry $HubRoot).Defaults
    if ($null -eq $defaults.PSObject.Properties['githubAccounts']) { return $null }
    $normalized = [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($RepoRoot))
    $match = $defaults.githubAccounts.PSObject.Properties | Where-Object {
        $prefix = [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($_.Name))
        $normalized -ieq $prefix -or $normalized.StartsWith($prefix + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
    } | Sort-Object { $_.Name.Length } -Descending | Select-Object -First 1
    if ($match) { return [string]$match.Value }
    return $null
}

function Get-RunAttempts([string]$RunDir, [bool]$Resumed) {
    $path = Join-Path $RunDir 'meta.json'
    if (-not $Resumed -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { return ,@() }
    $previous = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json -AsHashtable -DateKind String
    $attempts = @()
    if ($previous.Contains('attempts')) { $attempts = @($previous.attempts) }
    [void]$previous.Remove('attempts')
    foreach ($field in @('startedAt', 'endedAt', 'exitCode', 'timedOut', 'fixLoop', 'sessionId', 'model')) {
        if (-not $previous.Contains($field)) { $previous[$field] = $null }
    }
    if (-not $previous.Contains('wrapperExitCode')) { $previous.wrapperExitCode = $previous.exitCode }
    if (-not $previous.Contains('reasoningEffort')) {
        $previous.reasoningEffort = if ($previous.Contains('effort')) { $previous.effort } else { $null }
    }
    $gatePath = Join-Path $RunDir 'gate.json'
    if (-not $previous.Contains('gate') -and (Test-Path -LiteralPath $gatePath -PathType Leaf)) {
        try { $previous.gate = Get-Content -Raw -LiteralPath $gatePath | ConvertFrom-Json -AsHashtable -DateKind String } catch { }
    }
    return ,@($attempts + @($previous))
}

function Get-ExecutorDeadline([double]$TimeoutMinutes, [datetimeoffset]$LaunchLocal = [datetimeoffset]::Now) {
    $deadline = [TimeZoneInfo]::ConvertTime($LaunchLocal.AddMinutes($TimeoutMinutes), [TimeZoneInfo]::Local)
    $reportBy = [TimeZoneInfo]::ConvertTime($deadline.AddMinutes(-[Math]::Max(10.0, 0.15 * $TimeoutMinutes)), [TimeZoneInfo]::Local)
    return [pscustomobject]@{
        DeadlineLocal = $deadline.ToString('o')
        ReportByLocal = $reportBy.ToString('o')
        Header = "Launcher will stop the executor at $($deadline.ToString('HH:mm')) local time.`r`nStop working and write the final report by $($reportBy.ToString('HH:mm')) local time, even if incomplete, listing what is missing.`r`n"
    }
}

function Get-ExecutorRoleHeader([string]$BriefPath, $Deadline, [string]$RunDir) {
    return "EXECUTOR ROLE: Execute the assigned brief below directly. Original brief path: $BriefPath`r`nRun directory: $RunDir (for progress.md and jobs.pid).`r`nDo not dispatch or relaunch a live agent. Assigned launcher fixture tests and dry runs are allowed.`r`n" + $Deadline.Header + "`r`n"
}

function Stop-RunJobs([string]$RunDir, [datetime]$StartedAt) {
    if ($StartedAt -eq [datetime]::MinValue) { return }
    $jobsPath = Join-Path $RunDir 'jobs.pid'
    if (-not (Test-Path -LiteralPath $jobsPath -PathType Leaf)) { return }
    $stopped = [Collections.Generic.List[int]]::new()
    foreach ($line in Get-Content -LiteralPath $jobsPath) {
        $jobId = 0
        if (-not [int]::TryParse($line.Trim(), [ref]$jobId) -or $jobId -le 0) { continue }
        $job = Get-Process -Id $jobId -ErrorAction SilentlyContinue
        if ($null -eq $job) { continue }
        try {
            if ($job.StartTime.ToUniversalTime() -lt $StartedAt) { continue }
            $job.Kill($true)
            if (-not $job.WaitForExit(5000)) { throw 'process did not exit after termination' }
            $stopped.Add($jobId)
        }
        catch { Write-Warning "job ${jobId}: $($_.Exception.Message)" }
    }
    [IO.File]::WriteAllText($jobsPath, '')
    $metaPath = Join-Path $RunDir 'meta.json'
    if (Test-Path -LiteralPath $metaPath -PathType Leaf) {
        $jobMeta = Get-Content -Raw -LiteralPath $metaPath | ConvertFrom-Json -AsHashtable -DateKind String
        $jobMeta['stoppedJobs'] = @(@($jobMeta['stoppedJobs']) + $stopped.ToArray() | Where-Object { $null -ne $_ } | Select-Object -Unique)
        $jobMeta | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $metaPath -Encoding utf8
    }
    return $stopped.ToArray()
}

function Get-BriefPathCitations([string]$Text, [string]$Quotes) {
    # shortcut: quoted text is one path only when it starts with one and holds no list separator; other quoted text is searched again
    # with the remaining quote kinds, so `"C:\Program Files\x.exe" --flag` keeps its spaces; unquoted paths end at whitespace.
    # Only drive paths are checked: probing a brief's UNC path could send Windows credentials to the cited host.
    $start = '[A-Za-z]:[\\/]'
    $unquoted = '(?<![\w/\\])' + $start + '[^\s`"''|,;()]+'
    $pattern = if ($Quotes) { '(?<!\w)(?<quote>[' + $Quotes + '])(?<text>[^\r\n]*?)\k<quote>|(?<text>' + $unquoted + ')' } else { '(?<text>' + $unquoted + ')' }
    foreach ($citation in [regex]::Matches($Text, $pattern)) {
        $inner = $citation.Groups['text'].Value
        $quote = $citation.Groups['quote']
        if (-not $quote.Success) { [pscustomobject]@{ Path = $inner; Quoted = $false; Quotes = '' } }
        elseif ($inner -match "^$start" -and $inner -notmatch '[,;]') { [pscustomobject]@{ Path = $inner; Quoted = $true; Quotes = $Quotes.Replace($quote.Value, '') } }
        else { Get-BriefPathCitations $inner $Quotes.Replace($quote.Value, '') }
    }
}

function Confirm-BriefPaths([string]$BriefPath, [string]$RepoPath, [string]$HubRoot) {
    $roots = @($RepoPath, $HubRoot) | ForEach-Object { [IO.Path]::GetFullPath($_).TrimEnd('\', '/') }
    $citations = [Collections.Generic.Queue[object]]::new()
    Get-BriefPathCitations ([IO.File]::ReadAllText($BriefPath)) ('`"' + "'") | ForEach-Object { $citations.Enqueue($_) }
    $missing = @(while ($citations.Count) {
        $citation = $citations.Dequeue()
        $quoted = $citation.Quoted
        # Text after a quoted path's first space may be command arguments: `C:\Program Files\tool.exe --config D:\x.json`.
        if ($quoted -and $citation.Path -match '\s(.*)$') { Get-BriefPathCitations $Matches[1] $citation.Quotes | ForEach-Object { $citations.Enqueue($_) } }
        $path = $citation.Path -replace '^([A-Za-z]:[^:]*):.*$', '$1'
        if ($path -match '[*?<>{}\[\]]|\.\.\.|…') { continue }
        if (-not $quoted) { $path = $path.TrimEnd('.', ':') }
        $full = [IO.Path]::GetFullPath($path).TrimEnd('\', '/')
        $internal = @($roots | Where-Object { $full -ieq $_ -or $full.StartsWith($_ + '\', [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
        # A quoted command such as `C:\Program Files\tool.exe --flag` passes when its executable, a file ending before whitespace, exists.
        $executable = $quoted -and @([regex]::Matches($citation.Path, '\s') | Where-Object { Test-Path -LiteralPath $citation.Path.Substring(0, $_.Index) -PathType Leaf }).Count -gt 0
        if (-not $internal -and -not $executable -and -not (Test-Path -LiteralPath $path)) { $path }
    })
    if ($missing.Count) { throw "missing external brief paths: $(($missing | Select-Object -Unique) -join '; ') (a file created after launch belongs in the run directory or the repository)" }
}

function New-RunDirPath([string]$HubRoot, [string]$Alias, [string]$BriefPath, [bool]$Resumed = $false, [int]$FixLoop = 0) {
    $briefFullPath = [IO.Path]::GetFullPath($BriefPath)
    $parentPath = [IO.Path]::GetDirectoryName($briefFullPath)
    if ($Resumed) {
        if (Test-Path -LiteralPath (Join-Path $parentPath 'meta.json') -PathType Leaf) { return "$parentPath-fix$FixLoop" }
        $stem = if ([IO.Path]::GetFileName($briefFullPath) -ieq 'brief.md') { Split-Path $parentPath -Leaf } else { [IO.Path]::GetFileNameWithoutExtension($BriefPath) }
        $BriefPath = Join-Path $parentPath "$stem-fix$FixLoop.md"
        $briefFullPath = [IO.Path]::GetFullPath($BriefPath)
    }
    $runsPrefix = [IO.Path]::GetFullPath((Join-Path $HubRoot 'runs')) + [IO.Path]::DirectorySeparatorChar
    if ([IO.Path]::GetFileName($briefFullPath) -ieq 'brief.md' -and $parentPath.StartsWith($runsPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        return $parentPath
    }
    $stem = [IO.Path]::GetFileNameWithoutExtension($BriefPath)
    $name = if ($stem -match '^\d{4}-\d{2}-\d{2}-') { $stem } else { "$(Get-Date -Format 'yyyy-MM-dd')-$stem" }
    $base = Join-Path $HubRoot "runs\$Alias\$name"
    $candidate = $base
    $suffix = 2
    while (Test-Path -LiteralPath $candidate) { $candidate = "$base-$suffix"; $suffix++ }
    return $candidate
}

function Get-RepoLockPath([string]$LockDir, [string]$RepoPath) {
    $normalized = [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($RepoPath)).ToUpperInvariant()
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($normalized)))
    return Join-Path $LockDir "$hash.json"
}

function Get-BriefExecutorIdentity([string]$BriefPath, [string]$Provider) {
    $identity = [regex]::Match([IO.File]::ReadAllText($BriefPath), 'Executor:\s+(?<provider>codex|claude)\s+`(?<model>[^`\r\n]+)`;\s*effort\s+`(?<effort>[^`\r\n]+)`\.')
    $matchesProvider = $identity.Success -and $identity.Groups['provider'].Value -eq $Provider
    return [pscustomobject]@{
        Model = if ($matchesProvider) { $identity.Groups['model'].Value } else { $null }
        Effort = if ($matchesProvider) { $identity.Groups['effort'].Value } else { $null }
    }
}

function Get-BriefDevices([string]$BriefPath) {
    $text = [IO.File]::ReadAllText($BriefPath)
    $text = [regex]::Replace($text, '(?ms)^Repo notes:\s*\r?\n.*?(?=^## |\z)', '')
    @(
        foreach ($match in [regex]::Matches($text, '\bemulator-\d+\b')) { $match.Value }
        foreach ($match in [regex]::Matches($text, '(?im)^\s*(?:[-*]\s+)?Device:\s*[`"'']?(?<serial>[A-Za-z0-9][A-Za-z0-9_.:-]*)')) { $match.Groups['serial'].Value }
    ) | Select-Object -Unique
}

function Get-DeviceLockTarget([string]$HubRoot, [string]$Serial) {
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Serial.ToUpperInvariant())))
    return Join-Path $HubRoot ".device-$hash"
}

function Set-RunExecutionState([bool]$Required) {
    if (-not $IsWindows) { return }
    if (-not ('Pipeline.ExecutionState' -as [type])) {
        Add-Type -TypeDefinition @'
namespace Pipeline {
    public static class ExecutionState {
        [System.Runtime.InteropServices.DllImport("kernel32.dll")]
        public static extern uint SetThreadExecutionState(uint flags);
    }
}
'@
    }
    $flags = [uint32]2147483648 # ES_CONTINUOUS; clearing ES_SYSTEM_REQUIRED releases the hold.
    if ($Required) { $flags = $flags -bor 1 }
    if ([Pipeline.ExecutionState]::SetThreadExecutionState($flags) -eq 0) { throw 'SetThreadExecutionState failed' }
}

function Get-RepoLockState([string]$LockDir, [string]$RepoPath) {
    $path = Get-RepoLockPath $LockDir $RepoPath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return [pscustomobject]@{ Status = 'free'; Path = $path; Owner = $null }
    }
    $owner = $null
    try {
        $owner = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json
        $process = Get-Process -Id ([int]$owner.pid) -ErrorAction SilentlyContinue
        if ($null -ne $process -and
            $process.StartTime.ToUniversalTime() -eq ([datetime]$owner.processStartTime).ToUniversalTime()) {
            return [pscustomobject]@{ Status = 'busy'; Path = $path; Owner = $owner }
        }
    }
    catch { }
    return [pscustomobject]@{ Status = 'stale'; Path = $path; Owner = $owner }
}

function Enter-RepoLock([string]$LockDir, [string]$RepoPath, [string]$RunDir) {
    New-Item -ItemType Directory -Force -Path $LockDir | Out-Null
    $normalized = [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($RepoPath))
    $namespace = [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($LockDir)).ToUpperInvariant()
    $mutexKey = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes("$namespace|$($normalized.ToUpperInvariant())")))
    $mutex = [Threading.Mutex]::new($false, "Local\pipeline-repo-$mutexKey")
    $held = $false
    try {
        try { $held = $mutex.WaitOne(0) }
        catch [Threading.AbandonedMutexException] { $held = $true }
        $state = Get-RepoLockState $LockDir $normalized
        if (-not $held -or $state.Status -eq 'busy') {
            if ($held) { $mutex.ReleaseMutex(); $held = $false }
            return [pscustomobject]@{ Acquired = $false; State = $state; Mutex = $null }
        }
        $self = Get-Process -Id $PID
        $owner = [ordered]@{
            pid = $PID
            processStartTime = $self.StartTime.ToUniversalTime().ToString('o')
            runDir = $RunDir
            repoPath = $normalized
            startedAt = [DateTime]::UtcNow.ToString('o')
        }
        [IO.File]::WriteAllText($state.Path, ($owner | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
        return [pscustomobject]@{ Acquired = $true; State = $state; Mutex = $mutex }
    }
    catch {
        if ($held) { $mutex.ReleaseMutex() }
        throw
    }
    finally {
        if (-not $held) { $mutex.Dispose() }
    }
}

function Test-AncestorProcess([int]$OwnerPid) {
    if (-not $IsWindows) { return $false }
    $process = Get-CimInstance Win32_Process -Filter "ProcessId = $PID"
    for ($depth = 0; $depth -lt 16 -and $process -and $process.ParentProcessId; $depth++) {
        if ([int]$process.ParentProcessId -eq $OwnerPid) { return $true }
        $process = Get-CimInstance Win32_Process -Filter "ProcessId = $($process.ParentProcessId)"
    }
    return $false
}

function Exit-RepoLock($Lock) {
    try { Remove-Item -LiteralPath $Lock.State.Path -Force -ErrorAction Stop }
    finally {
        $Lock.Mutex.ReleaseMutex()
        $Lock.Mutex.Dispose()
    }
}

function Format-TomlStringArray([string[]]$Values) {
    foreach ($value in $Values) {
        if ($value.Contains("'")) { throw "writable root contains a single quote: $value" }
    }
    return '[' + (($Values | ForEach-Object { "'$_'" }) -join ',') + ']'
}

function Confirm-GateCommand($Command) {
    if ($Command -is [string]) { return $Command }
    if ($Command -isnot [array] -or $Command.Count -eq 0 -or
        @($Command | Where-Object { $_ -isnot [string] -or [string]::IsNullOrWhiteSpace($_) -or $_.Trim() -ieq 'none' }).Count -gt 0) {
        throw 'expected a command string or a nonempty array of command strings'
    }
    return ,$Command
}

function Test-GateEnabled($Command) {
    return $Command -is [array] -or (-not [string]::IsNullOrWhiteSpace($Command) -and $Command.Trim() -ine 'none')
}

function Get-GateCommand($Entry, $Requested, [bool]$Explicit, [string]$BriefDir) {
    if ($Explicit) { return ,(Confirm-GateCommand $Requested) }
    if ($BriefDir) {
        $gatePath = Join-Path $BriefDir 'brief.gate.json'
        if (Test-Path -LiteralPath $gatePath) {
            try {
                $gate = Get-Content -Raw -LiteralPath $gatePath | ConvertFrom-Json -NoEnumerate
                if ($null -eq $gate -or $gate -isnot [pscustomobject] -or
                    $null -eq $gate.PSObject.Properties['command'] -or
                    $null -eq $gate.PSObject.Properties['owner'] -or $gate.owner -isnot [string] -or $gate.owner -cnotin @('executor', 'launcher')) {
                    throw 'expected command string or array and owner executor|launcher'
                }
                $command = Confirm-GateCommand $gate.command
            }
            catch { throw "Invalid brief.gate.json at '${gatePath}': $($_.Exception.Message)" }
            return ,$command
        }
    }
    if ($null -ne $Entry -and $null -ne $Entry.PSObject.Properties['commands'] -and
        $null -ne $Entry.commands.PSObject.Properties['fullGate']) {
        return ,(Confirm-GateCommand $Entry.commands.fullGate)
    }
    return 'none'
}

function Invoke-TaskUsage([string]$HubRoot, [string]$RunDir, [string]$Phase) {
    try {
        & node (Join-Path $PSScriptRoot 'task-usage.js') --phase $Phase --run-dir $RunDir *> $null
        if ($LASTEXITCODE -ne 0) { Write-Output "warning: task-usage $Phase exited $LASTEXITCODE" }
    }
    catch { Write-Output "warning: task-usage $Phase failed: $($_.Exception.Message)" }
}

# Content fingerprint of the target: relative path plus SHA-256 of every source
# file, so a commit of the same content keeps it. A Git target lists tracked and
# untracked non-ignored files read-only (no index refresh, no optional locks);
# any other target walks every file outside run, log and generated directories.
# Returns $null when the source cannot be read, which never matches.
function Get-SourceFingerprint([string]$RepoPath) {
    try {
        $root = [IO.Path]::GetFullPath($RepoPath)
        $paths = [Collections.Generic.List[string]]::new()
        if (Test-Path -LiteralPath (Join-Path $root '.git')) {
            $info = [Diagnostics.ProcessStartInfo]::new()
            $info.FileName = 'git'
            foreach ($argument in @('--no-optional-locks', '-c', "safe.directory=$root", '-C', $root, 'ls-files', '-z', '-co', '--exclude-standard')) { $info.ArgumentList.Add($argument) }
            $info.UseShellExecute = $false
            $info.CreateNoWindow = $true
            $info.RedirectStandardOutput = $true
            $info.RedirectStandardError = $true
            $info.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
            $process = [Diagnostics.Process]::Start($info)
            $errorTask = $process.StandardError.ReadToEndAsync()
            $listing = $process.StandardOutput.ReadToEnd()
            $process.WaitForExit()
            [void]$errorTask.GetAwaiter().GetResult()
            if ($process.ExitCode -ne 0) { return $null }
            foreach ($relative in $listing.Split([char]0, [StringSplitOptions]::RemoveEmptyEntries)) { $paths.Add($relative) }
        }
        else {
            $excluded = @('runs', 'logs', 'node_modules', 'build', '.dart_tool', '.git')
            $pending = [Collections.Generic.Stack[string]]::new()
            $pending.Push($root)
            while ($pending.Count -gt 0) {
                $directory = $pending.Pop()
                foreach ($file in [IO.Directory]::EnumerateFiles($directory)) { $paths.Add([IO.Path]::GetRelativePath($root, $file).Replace('\', '/')) }
                foreach ($child in [IO.Directory]::EnumerateDirectories($directory)) {
                    if ([IO.Path]::GetFileName($child) -in $excluded) { continue }
                    if ([IO.File]::GetAttributes($child) -band [IO.FileAttributes]::ReparsePoint) { continue }
                    $pending.Push($child)
                }
            }
        }
        $paths.Sort([StringComparer]::Ordinal)
        $builder = [Text.StringBuilder]::new()
        foreach ($relative in $paths) {
            $full = Join-Path $root $relative
            $digest = 'absent'
            if ([IO.File]::Exists($full)) {
                $stream = [IO.File]::Open($full, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
                try { $digest = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stream)) }
                finally { $stream.Dispose() }
            }
            [void]$builder.Append($relative).Append([char]0).Append($digest).Append("`n")
        }
        return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($builder.ToString())))
    }
    catch { return $null }
}

function Get-GateFailurePattern($Entry) {
    if ($null -ne $Entry -and $null -ne $Entry.PSObject.Properties['gateFailurePattern']) { return [string]$Entry.gateFailurePattern }
    return ''
}

# The first 40 failing lines of a gate log. Default, case-sensitive: vitest
# (FAIL, the U+00D7 cross, AssertionError), flutter ([E], Some tests failed) and
# the hub's pwsh tests (FAIL, Write-Error output); a registry gateFailurePattern replaces it.
function Get-GateFailures([string]$Log, [string]$Pattern, [int]$Limit = 40) {
    if (-not $Pattern) { $Pattern = '\bFAIL\b|×|AssertionError|\[E\]|Some tests failed|^Write-Error: ' }
    $regex = [regex]::new($Pattern)
    return @($Log -split '\r\n|\n|\r' | ForEach-Object { ($_ -replace '\x1b\[[0-9;]*[A-Za-z]', '').TrimEnd() } |
        Where-Object { $_ -and $regex.IsMatch($_) } | Select-Object -First $Limit)
}

# The executor may already have run this gate through run-gate.ps1: a green or red,
# untimed gate.json with the same command, cwd and source fingerprint is reused
# (reused: true). Otherwise the launcher runs the gate and keeps an executor
# result it did not reuse as gate.executor.json. A fix loop runs in a new run
# directory while the resumed executor follows the original brief's run-gate
# line, so without a gate.json here the brief's directory is consulted under the
# same rule; a match is copied here with reusedFrom and the original is left as is.
function Get-GateTimeoutMinutes($Entry, [double]$Explicit, [bool]$ExplicitSet) {
    if ($ExplicitSet -or $null -eq $Entry -or $null -eq $Entry.PSObject.Properties['gateTimeoutMinutes']) { return $Explicit }
    return [double]$Entry.gateTimeoutMinutes
}

function Get-GateRetries($Entry, $Defaults) {
    foreach ($source in @($Entry, $Defaults)) {
        if ($null -ne $source -and $null -ne $source.PSObject.Properties['gateRetries']) {
            return [Math]::Max(0, [int]$source.gateRetries)
        }
    }
    return 1
}

function Invoke-LauncherGate($Command, [string]$RepoPath, [string]$RunDir, [double]$TimeoutMinutes, [string]$FailurePattern, [string]$BriefDir, [int]$GateRetries = 1) {
    $jsonPath = Join-Path $RunDir 'gate.json'
    $sourcePath = $jsonPath
    if (-not (Test-Path -LiteralPath $jsonPath -PathType Leaf) -and $BriefDir) {
        $briefGate = Join-Path $BriefDir 'gate.json'
        if ([IO.Path]::GetFullPath($briefGate) -ine [IO.Path]::GetFullPath($jsonPath)) { $sourcePath = $briefGate }
    }
    $prior = $null
    if (Test-Path -LiteralPath $sourcePath -PathType Leaf) {
        try { $prior = Get-Content -Raw -LiteralPath $sourcePath | ConvertFrom-Json -DateKind String } catch { $prior = $null }
    }
    if ($null -ne $prior) {
        $field = { param([string]$Name) $property = $prior.PSObject.Properties[$Name]; if ($null -ne $property) { return ,$property.Value } else { $null } }
        $priorCwd = [string](& $field 'cwd')
        $priorFingerprint = [string](& $field 'fingerprint')
        $reusable = $null -ne (& $field 'exitCode') -and (& $field 'timedOut') -eq $false -and (ConvertTo-Json -InputObject (& $field 'command') -Compress) -ceq (ConvertTo-Json -InputObject $Command -Compress) -and
            $priorCwd -and [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($priorCwd)) -ieq [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($RepoPath)) -and
            $priorFingerprint -and $priorFingerprint -eq (Get-SourceFingerprint $RepoPath)
        if ($reusable) {
            $prior | Add-Member -NotePropertyName reused -NotePropertyValue $true -Force
            if ($sourcePath -ne $jsonPath) { $prior | Add-Member -NotePropertyName reusedFrom -NotePropertyValue ([IO.Path]::GetFullPath($sourcePath)) -Force }
            $prior | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $jsonPath -Encoding utf8
            return $prior
        }
        if ($sourcePath -eq $jsonPath -and (& $field 'owner') -eq 'executor') {
            $executorLog = Join-Path $RunDir 'gate.executor.log'
            if (Test-Path -LiteralPath (Join-Path $RunDir 'gate.log') -PathType Leaf) {
                Move-Item -LiteralPath (Join-Path $RunDir 'gate.log') -Destination $executorLog -Force
                $prior | Add-Member -NotePropertyName log -NotePropertyValue $executorLog -Force
            }
            $prior | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $RunDir 'gate.executor.json') -Encoding utf8
        }
    }
    return Invoke-PostRunGate $Command $RepoPath $RunDir $TimeoutMinutes 'launcher' $FailurePattern $GateRetries
}

# A launcher exit without the executor's report still leaves one: STATUS failed,
# the cause, and progress.md when present. -UpdateMeta marks an existing
# meta.json (or a minimal new one) with reportSynthesized. Returns $true when written.
function Write-MissingReport([string]$RunDir, [string]$Cause, [switch]$UpdateMeta, $Target, [datetime]$AttemptStartedAt = [datetime]::MinValue) {
    $reportPath = Join-Path $RunDir 'report.md'
    if (-not (Test-Path -LiteralPath $RunDir -PathType Container) -or ((Test-Path -LiteralPath $reportPath) -and (Get-Item -LiteralPath $reportPath).LastWriteTimeUtc -ge $AttemptStartedAt)) { return $false }
    $progressPath = Join-Path $RunDir 'progress.md'
    $progress = if (Test-Path -LiteralPath $progressPath -PathType Leaf) { ([string](Get-Content -Raw -LiteralPath $progressPath)).Trim() } else { '' }
    $checkpoint = if ($progress) { 'see progress.md below' } else { 'none recorded' }
    $lines = @('STATUS: failed', "Checkpoint: $checkpoint.", '', "Cause: $Cause", 'The launcher wrote this report because the executor left none (meta.json reportSynthesized).')
    if ($progress) { $lines += @('', '## progress.md', '', $progress) }
    [IO.File]::WriteAllText($reportPath, ($lines -join "`n") + "`n", [Text.UTF8Encoding]::new($false))
    if ($UpdateMeta) {
        $metaPath = Join-Path $RunDir 'meta.json'
        $meta = $null
        if (Test-Path -LiteralPath $metaPath -PathType Leaf) {
            try { $meta = Get-Content -Raw -LiteralPath $metaPath | ConvertFrom-Json -DateKind String } catch { $meta = $null }
        }
        if ($null -eq $meta) { $meta = [pscustomobject]@{ runDir = $RunDir; reportPresent = $false } }
        if ($null -ne $Target) {
            $meta | Add-Member -NotePropertyName repo -NotePropertyValue $Target.Alias -Force
            $meta | Add-Member -NotePropertyName repoPath -NotePropertyValue $Target.Path -Force
            $meta | Add-Member -NotePropertyName repoRoot -NotePropertyValue $Target.Root -Force
            $meta | Add-Member -NotePropertyName github -NotePropertyValue $Target.GitHub -Force
        }
        $meta | Add-Member -NotePropertyName reportSynthesized -NotePropertyValue $true -Force
        $meta | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $metaPath -Encoding utf8
    }
    return $true
}

function Get-GateRetryCommand($Command, [string[]]$Failures) {
    if (@($Command).Count -ne 1) { return $null }
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput([string]@($Command)[0], [ref]$tokens, [ref]$errors)
    if ($errors.Count -or $ast.ParamBlock -or $ast.BeginBlock -or $ast.ProcessBlock -or $ast.EndBlock.Statements.Count -ne 1) { return $null }
    $pipeline = $ast.EndBlock.Statements[0]
    if ($pipeline -isnot [Management.Automation.Language.PipelineAst] -or $pipeline.PipelineElements.Count -ne 1 -or $pipeline.Background) { return $null }
    $call = $pipeline.PipelineElements[0]
    if ($call -isnot [Management.Automation.Language.CommandAst] -or $call.Redirections.Count -or @($call.CommandElements | Where-Object { $_ -isnot [Management.Automation.Language.ConstantExpressionAst] }).Count) { return $null }
    $values = @($call.CommandElements | ForEach-Object { [string]$_.Value })
    $runner = [IO.Path]::GetFileNameWithoutExtension($values[0])
    $index = 1
    if ($runner -in @('npx', 'bunx')) {
        while ($index -lt $values.Count -and $values[$index] -in @('-y', '--yes', '--no-install')) { $index++ }
        if ($index -ge $values.Count) { return $null }
        $runner = $values[$index++]
    }
    elseif ($runner -in @('pnpm', 'yarn', 'npm')) {
        if ($index -lt $values.Count -and $values[$index] -eq 'exec') { $index++ }
        elseif ($runner -eq 'npm') { return $null }
        if ($index -lt $values.Count -and $values[$index] -eq '--') { $index++ }
        if ($index -ge $values.Count) { return $null }
        $runner = $values[$index++]
    }
    if ($runner -in @('flutter', 'dart')) {
        if ($index -ge $values.Count -or $values[$index++] -cne 'test') { return $null }
        $filePattern = '^(?:\d+:\d+(?::\d+)?\s+[^:]*:\s+)?(?:\[[^\]]+\]\s+)?(?:loading\s+)?(?<file>.+?\.dart)(?::\s.*)?\s*\[E\]'
    }
    elseif ($runner -in @('vitest', 'jest')) {
        if (($runner -eq 'vitest' -and $index -lt $values.Count -and $values[$index] -in @('related', 'watch', 'dev', 'bench', 'list', 'typecheck', 'init')) -or ($runner -eq 'jest' -and '--findRelatedTests' -cin $values)) { return $null }
        if ($runner -eq 'vitest' -and $index -lt $values.Count -and $values[$index] -eq 'run') { $index++ }
        $filePattern = '^\s*FAIL\s+(?<file>.+?\.(?:[cm]?[jt]sx?))(?=\s|$)'
    }
    else { return $null }
    $files = @($Failures | ForEach-Object { if ($_ -cmatch $filePattern) { $Matches.file } } | Select-Object -Unique)
    if (-not $files.Count) { return $null }
    $parts = @($call.CommandElements | Select-Object -First $index | ForEach-Object { $_.Extent.Text })
    $valueOptions = @('--concurrency', '-j', '--reporter', '-r', '--timeout', '--test-timeout', '--testTimeout', '--config', '-c', '--project', '--pool', '--maxWorkers', '--minWorkers', '--mode', '--environment', '--name', '--plain-name', '--tags', '--exclude-tags', '--testNamePattern', '-t', '--testPathIgnorePatterns', '--rootDir', '--flavor', '--device-id', '-d', '--dart-define', '--dart-define-from-file', '--coverage-path', '--coverage-package', '--total-shards', '--shard-index', '--test-randomize-ordering-seed', '--file-reporter', '--platform', '--compiler', '--preset', '--shard', '--retry', '--repeat')
    $switchOptions = @('--run', '--runInBand', '--runTestsByPath', '--no-pub', '--coverage', '--no-coverage', '--update-goldens', '--chain-stack-traces', '--no-chain-stack-traces', '--passWithNoTests', '--ci', '--silent', '--verbose')
    for (; $index -lt $values.Count; $index++) {
        if ($values[$index] -eq '--') { $parts += '--'; break }
        if ($values[$index].StartsWith('-')) {
            $parts += $call.CommandElements[$index].Extent.Text
            if ($values[$index] -cin $valueOptions) {
                $index++
                if ($index -ge $values.Count) { return $null }
                $parts += $call.CommandElements[$index].Extent.Text
            }
            elseif ($values[$index] -notmatch '=' -and $values[$index] -cnotin $switchOptions -and $index + 1 -lt $values.Count -and -not $values[$index + 1].StartsWith('-')) {
                # An unknown split option may consume the next token; dropping it would change the base command.
                return $null
            }
        }
    }
    foreach ($file in $files) {
        if ($file.StartsWith('-')) { $file = './' + $file }
        $parts += "'" + $file.Replace("'", "''") + "'"
    }
    return $parts -join ' '
}

function Invoke-PostRunGate($Command, [string]$RepoPath, [string]$RunDir, [double]$TimeoutMinutes, [string]$Owner = 'launcher', [string]$FailurePattern = '', [int]$GateRetries = 1) {
    $logPath = Join-Path $RunDir 'gate.log'
    $jsonPath = Join-Path $RunDir 'gate.json'
    $fingerprint = Get-SourceFingerprint $RepoPath
    $attempts = @()
    $attemptCommand = $Command
    for ($attempt = 1; $attempt -le ([Math]::Max(0, $GateRetries) + 1); $attempt++) {
        $started = [DateTime]::UtcNow
        $exitCode = 0
        $timedOut = $false
        $output = ''
        $commandResults = @()
        foreach ($item in @($attemptCommand)) {
            $commandStarted = [DateTime]::UtcNow
            $commandOutput = ''
            $commandExit = $null
            try {
                $info = [Diagnostics.ProcessStartInfo]::new()
                $info.FileName = 'pwsh'
                # The child writes UTF-8 and is read as UTF-8, so vitest's cross survives into the log and failures.
                $strictCommand = '[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false); $OutputEncoding = [Text.UTF8Encoding]::new($false); $ErrorActionPreference = "Stop"; $PSNativeCommandUseErrorActionPreference = $true; ' + $item
                foreach ($argument in @('-NoProfile', '-Command', $strictCommand)) { $info.ArgumentList.Add($argument) }
                $info.WorkingDirectory = $RepoPath
                $info.UseShellExecute = $false
                $info.CreateNoWindow = $true
                $info.RedirectStandardOutput = $true
                $info.RedirectStandardError = $true
                $info.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
                $info.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
                $process = [Diagnostics.Process]::new()
                $process.StartInfo = $info
                [void]$process.Start()
                $stdoutTask = $process.StandardOutput.ReadToEndAsync()
                $stderrTask = $process.StandardError.ReadToEndAsync()
                $timeoutMs = [int][Math]::Min([int]::MaxValue, [Math]::Max(0, [Math]::Ceiling($TimeoutMinutes * 60000 - ([DateTime]::UtcNow - $started).TotalMilliseconds)))
                $timedOut = -not $process.WaitForExit($timeoutMs)
                if ($timedOut) { $process.Kill($true); [void]$process.WaitForExit(5000) }
                $commandOutput = $stdoutTask.GetAwaiter().GetResult() + $stderrTask.GetAwaiter().GetResult()
                if ($process.HasExited) { $commandExit = $process.ExitCode }
            }
            catch { $commandOutput += "gate launch failed: $($_.Exception.Message)" }
            $commandGreen = $commandExit -eq 0 -and -not $timedOut
            $commandResults += [ordered]@{
                command = $item
                startedAt = $commandStarted.ToString('o')
                durationSeconds = [Math]::Round(([DateTime]::UtcNow - $commandStarted).TotalSeconds, 3)
                exitCode = $commandExit
                timedOut = $timedOut
                failures = @(if (-not $commandGreen) { Get-GateFailures $commandOutput $FailurePattern })
            }
            $output += $commandOutput
            if (-not $commandGreen -and $exitCode -eq 0) { $exitCode = $commandExit }
            if ($timedOut -or $null -eq $commandExit) { break }
        }
        [IO.File]::WriteAllText($logPath, $output)
        $lines = @($output -split '\r?\n' | Where-Object { $_ -ne '' })
        $tail = (@($lines | Select-Object -Last 40) -join "`n")
        $green = $exitCode -eq 0 -and -not $timedOut
        $result = [ordered]@{
            command = $Command
            cwd = $RepoPath
            owner = $Owner
            fingerprint = $fingerprint
            reused = $false
            startedAt = $started.ToString('o')
            durationSeconds = [Math]::Round(([DateTime]::UtcNow - $started).TotalSeconds, 3)
            exitCode = $exitCode
            timedOut = $timedOut
            log = $logPath
            tail = $tail
            failures = @(if (-not $green) { Get-GateFailures $output $FailurePattern })
        }
        if ($Command -is [array]) { $result.commands = @($commandResults) }
        $attempts += [ordered]@{
            command = $attemptCommand
            exitCode = $result.exitCode
            timedOut = $result.timedOut
            durationSeconds = $result.durationSeconds
            failures = $result.failures
            log = $logPath
        }
        if ($Command -is [array]) { $attempts[-1].commands = @($commandResults) }
        if ($green -or $timedOut -or $null -eq $exitCode -or $attempt -gt $GateRetries) { break }
        $attemptCommand = Get-GateRetryCommand $Command @(Get-GateFailures $output $FailurePattern ([int]::MaxValue))
        if ($null -eq $attemptCommand) { break }
        $attemptLog = Join-Path $RunDir "gate.attempt$attempt.log"
        Move-Item -LiteralPath $logPath -Destination $attemptLog -Force
        $attempts[-1].log = $attemptLog
    }
    $result.flaky = $green -and $attempts.Count -gt 1
    $result.attempts = @($attempts)
    $result.totalDurationSeconds = [Math]::Round(($attempts | ForEach-Object { $_.durationSeconds } | Measure-Object -Sum).Sum, 3)
    $result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $jsonPath -Encoding utf8
    return $result
}

# Reads the live plan windows from codeburn. Returns the refusal sentence, which
# starts with 'quota gate:', when the provider is above the cap (exactly at the
# cap still leaves the reserve and is allowed), and otherwise a status line the
# caller prints: 'skipped: <reason>' when codeburn cannot answer, or
# '<provider> <highest usedPct>% (cap <cap>%)'. Every window codeburn reports
# for the provider (5-hour and weekly alike) is compared and the highest usedPct
# wins, so a low reading on one window never hides a high reading on the other.
# usedPct is kept as read, not rounded, so a boundary value is not misjudged.
# A missing reading is returned to the caller as a 'skipped: <reason>' status; the
# caller applies its own provider policy (Claude fails closed, Codex treats it as advisory).
# $Model narrows which windows count. Codeburn reports only label/usedPct/resetsAt
# (no model field); a scoped window encodes the scope in its label as
# "Weekly · <Scope>" (installed main.js decodeClaudeUsage/toWindows: labels seen
# are '5-hour', 'Weekly', 'Weekly · Opus', 'Weekly · Sonnet', 'Weekly · Fable';
# 'Weekly · Haiku' follows the same scope convention).
# A label with no '·' is a common window and always counts. A label whose scope
# matches $Model's own scope ('Opus', 'Sonnet', or 'Haiku' for Claude 5.5 models)
# counts. A label whose scope is a different known scope ('Fable', or the other
# Claude models) is excluded, so Fable's usage never blocks Claude models. An
# unrecognised scope is kept conservatively. Leaving $Model empty (the default,
# and every Codex call) keeps every window, unchanged from before this scoping existed.
function Test-QuotaGate([string]$Provider, [int]$CapPercent, [int]$TimeoutSeconds, [string]$Model, [string]$CacheDir, [int]$TtlSeconds = 600, [switch]$CacheOnly) {
    if (-not $CacheOnly -and -not (Get-Command codeburn.cmd -ErrorAction SilentlyContinue) -and -not (Get-Command codeburn -ErrorAction SilentlyContinue)) { return 'skipped: codeburn is not on PATH' }
    if (-not $CacheDir) { $CacheDir = Join-Path (Get-PipelineHome) 'logs\quota' }
    $cachePath = Join-Path $CacheDir 'last-good.json'
    $data = $null
    $fetchedAt = [datetime]::MinValue
    $source = 'fresh'
    $readCache = {
        if (-not (Test-Path -LiteralPath $cachePath -PathType Leaf)) { return $null }
        try {
            $saved = Get-Content -Raw -LiteralPath $cachePath -Encoding utf8 | ConvertFrom-Json -DateKind String
            $when = [datetime]::Parse([string]$saved.fetchedAtUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
            if ($when -gt [datetime]::UtcNow.AddSeconds(5)) { return $null }
            $quota = $saved.quota
            if ($null -eq $quota -or $null -eq $quota.PSObject.Properties['providers']) { return $null }
            $matching = @($quota.providers) | Where-Object { $null -ne $_.PSObject.Properties['id'] -and [string]$_.id -ieq $Provider } | Select-Object -First 1
            if ($null -eq $matching -or $matching.available -ne $true -or $null -eq $matching.windows) { return $null }
            $validWindow = $false
            foreach ($window in @($matching.windows)) {
                $reset = [datetimeoffset]::MinValue
                if ($null -ne $window.PSObject.Properties['resetsAt'] -and [datetimeoffset]::TryParse([string]$window.resetsAt, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$reset) -and $reset -le [datetimeoffset]::UtcNow) { return $null }
                $number = 0.0
                if ($null -ne $window.PSObject.Properties['usedPct'] -and [double]::TryParse([string]$window.usedPct, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$number) -and [double]::IsFinite($number)) { $validWindow = $true }
                elseif ($null -ne $window.PSObject.Properties['usedPct']) { return $null }
            }
            if (-not $validWindow) { return $null }
            return [pscustomobject]@{ Data = $quota; FetchedAt = $when }
        }
        catch { return $null }
    }
    $cached = & $readCache
    if ($null -ne $cached -and ([datetime]::UtcNow - $cached.FetchedAt).TotalSeconds -lt $TtlSeconds) {
        $data = $cached.Data
        $fetchedAt = $cached.FetchedAt
        $source = 'cached'
    }
    else {
        if ($CacheOnly) { return 'skipped: no fresh cached quota reading' }
        try { [IO.Directory]::CreateDirectory($CacheDir) | Out-Null } catch { return "skipped: quota cache directory unavailable: $($_.Exception.Message)" }
        $lockPath = Join-Path $CacheDir 'refresh.lock'
        $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSeconds + 15)
        $lock = $null
        while ($null -eq $lock -and [datetime]::UtcNow -lt $deadline) {
            try { $lock = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
            catch [IO.IOException] { Start-Sleep -Milliseconds 250 }
            catch { return "skipped: quota refresh lock unavailable: $($_.Exception.Message)" }
        }
        if ($null -eq $lock) { return "skipped: quota refresh lock timed out after $($TimeoutSeconds + 15)s" }
        try {
            $cached = & $readCache
            if ($null -ne $cached -and ([datetime]::UtcNow - $cached.FetchedAt).TotalSeconds -lt $TtlSeconds) {
                $data = $cached.Data
                $fetchedAt = $cached.FetchedAt
                $source = 'cached'
            }
            else {
                $reading = Invoke-QuotaReading $TimeoutSeconds
                if ($reading -is [string]) { return $reading }
                $data = $reading
                try { $checked = Format-QuotaGate $data $Provider $CapPercent $Model 'fresh, age 0s' }
                catch { return 'skipped: codeburn quota printed invalid windows' }
                if ($checked -like 'skipped:*') { return $checked }
                $fetchedAt = [datetime]::UtcNow
                $tempPath = Join-Path $CacheDir ('.quota-' + [guid]::NewGuid().ToString('N') + '.json')
                try {
                    $json = @{ fetchedAtUtc = $fetchedAt.ToString('o'); quota = $data } | ConvertTo-Json -Depth 30 -Compress
                    [IO.File]::WriteAllText($tempPath, $json, [Text.Encoding]::UTF8)
                    [IO.File]::Move($tempPath, $cachePath, $true)
                }
                catch { if (Test-Path -LiteralPath $tempPath) { Remove-Item -LiteralPath $tempPath -ErrorAction SilentlyContinue } }
            }
        }
        finally { $lock.Dispose() }
    }
    $ageSeconds = [int][math]::Max(0, [math]::Floor(([datetime]::UtcNow - $fetchedAt).TotalSeconds))
    $freshness = "$source, age ${ageSeconds}s"
    return (Format-QuotaGate $data $Provider $CapPercent $Model $freshness)
}

function Invoke-QuotaReading([int]$TimeoutSeconds) {
    # npm installs codeburn.cmd and codeburn.ps1 side by side, and a bare
    # `Get-Command codeburn` in pwsh returns the script, which Process.Start
    # cannot launch: ask for the executable shim first.
    $command = Get-Command codeburn.cmd -TotalCount 1 -ErrorAction SilentlyContinue
    if ($null -eq $command) { $command = Get-Command codeburn -TotalCount 1 -ErrorAction SilentlyContinue }
    if ($null -eq $command) { return 'skipped: codeburn is not on PATH' }
    $arguments = @('quota', '--format', 'json', '--no-color')
    $info = [Diagnostics.ProcessStartInfo]::new()
    # codeburn is an npm shim: a .cmd runs only through the command interpreter.
    if ($command.Source -match '\.(cmd|bat)$') {
        $info.FileName = $env:ComSpec
        $info.Arguments = '/d /s /c ""' + $command.Source + '" ' + ($arguments -join ' ') + '"'
    }
    elseif ($command.Source -match '\.ps1$') {
        $info.FileName = 'pwsh'
        foreach ($argument in (@('-NoProfile', '-File', $command.Source) + $arguments)) { $info.ArgumentList.Add($argument) }
    }
    else {
        $info.FileName = $command.Source
        foreach ($argument in $arguments) { $info.ArgumentList.Add($argument) }
    }
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    # Node's fetch ignores HTTPS_PROXY unless asked: behind the proxy codeburn
    # would wait for the network until the gate times out.
    $info.Environment['NODE_USE_ENV_PROXY'] = '1'
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    # Read the JSON as UTF-8: through cmd.exe the console codepage decodes the
    # '·' of 'Weekly · Fable' as two box-drawing characters, the scope test
    # below never matches, and a scoped window blocks a model it does not own.
    $info.StandardOutputEncoding = [Text.Encoding]::UTF8
    $info.StandardErrorEncoding = [Text.Encoding]::UTF8
    $info.Environment['NODE_USE_ENV_PROXY'] = '1'
    $info.Environment['NO_COLOR'] = '1'
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    try { [void]$process.Start() } catch { return "skipped: codeburn did not start: $($_.Exception.Message)" }
    $outputTask = $process.StandardOutput.ReadToEndAsync()
    [void]$process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        try { $process.Kill($true); [void]$process.WaitForExit(5000) } catch { }
        return "skipped: codeburn quota timed out after ${TimeoutSeconds}s"
    }
    if ($process.ExitCode -ne 0) { return "skipped: codeburn quota exited $($process.ExitCode)" }
    $data = $null
    try { $data = $outputTask.GetAwaiter().GetResult() | ConvertFrom-Json } catch { $data = $null }
    if ($null -eq $data -or $null -eq $data.PSObject.Properties['providers']) { return 'skipped: codeburn quota printed no provider list' }
    return $data
}

function Format-QuotaGate($data, [string]$Provider, [int]$CapPercent, [string]$Model, [string]$Freshness) {
    $entry = @($data.providers) | Where-Object { $null -ne $_.PSObject.Properties['id'] -and [string]$_.id -ieq $Provider } | Select-Object -First 1
    if ($null -eq $entry -or $null -eq $entry.PSObject.Properties['available'] -or $entry.available -ne $true -or $null -eq $entry.PSObject.Properties['windows']) {
        return "skipped: codeburn reports no available quota for $Provider"
    }
    $knownScopeLabels = [ordered]@{ Opus = @('claude-opus-5-5'); Sonnet = @('claude-sonnet-5-5'); Haiku = @('claude-haiku-5-5'); Fable = @('fable') }
    $ownScopeEntry = if ($Model) { $knownScopeLabels.GetEnumerator() | Where-Object { $_.Value -icontains $Model } | Select-Object -First 1 } else { $null }
    $ownScopeLabel = if ($null -ne $ownScopeEntry) { $ownScopeEntry.Key } else { $null }
    $peak = @($entry.windows) | Where-Object { $null -ne $_.PSObject.Properties['usedPct'] } | Where-Object {
        if (-not $Model) { return $true }
        $label = if ($null -ne $_.PSObject.Properties['label']) { [string]$_.label } else { '' }
        $separator = $label.IndexOf([char]0x00B7)
        if ($separator -lt 0) { return $true }
        $scope = $label.Substring($separator + 1).Trim()
        if ($ownScopeLabel -and $scope -ieq $ownScopeLabel) { return $true }
        return $scope -notin $knownScopeLabels.Keys
    } | Sort-Object { [double]$_.usedPct } -Descending | Select-Object -First 1
    if ($null -eq $peak) { return "skipped: codeburn reports no quota window for $Provider" }
    $usedPct = [double]$peak.usedPct
    if ($usedPct -le $CapPercent) { return "$Provider $usedPct% (cap $CapPercent%) ($Freshness)" }
    $label = if ($null -ne $peak.PSObject.Properties['label']) { [string]$peak.label } else { 'window' }
    $resetsValue = if ($null -ne $peak.PSObject.Properties['resetsAt']) { $peak.resetsAt } else { $null }
    $resets = 'unknown'
    if ($resetsValue -is [datetime]) { $resets = ([datetime]$resetsValue).ToLocalTime().ToString('yyyy-MM-dd HH:mm') }
    elseif ($resetsValue) {
        $parsed = [datetimeoffset]::MinValue
        $resets = if ([datetimeoffset]::TryParse([string]$resetsValue, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed)) {
            $parsed.ToLocalTime().ToString('yyyy-MM-dd HH:mm')
        }
        else { [string]$resetsValue }
    }
    return "quota gate: $Provider $label at $usedPct% (cap $CapPercent%), resets $resets ($Freshness)"
}

function Test-FixLoopGate([int]$FixLoop, [int]$MaxFixLoops, [bool]$AllowExtra) {
    if ($FixLoop -le $MaxFixLoops -or $AllowExtra) { return $null }
    return "fix loop $FixLoop exceeds the cap of $MaxFixLoops; write a fresh fix brief for a new executor or pass -AllowExtraFixLoop"
}
