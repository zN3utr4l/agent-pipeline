[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$Repo,

    [ValidateRange(1, [int]::MaxValue)]
    [int]$PR,

    [string]$ExpectedHeadSha,

    [string[]]$RunId,

    [ValidateRange(1, [int]::MaxValue)]
    [int]$IntervalSeconds = 60,

    [Parameter(Mandatory)]
    [ValidateScript({ $_ -gt 0 })]
    [double]$TimeoutMinutes,

    [string]$LogPath,

    [Parameter(DontShow)]
    [scriptblock]$GetElapsed = { $timer.Elapsed }
)

$successStates = @('SUCCESS', 'NEUTRAL', 'SKIPPED')
$failureStates = @(
    'ACTION_REQUIRED',
    'CANCELLED',
    'ERROR',
    'FAILURE',
    'STALE',
    'STARTUP_FAILURE',
    'TIMED_OUT'
)
$lastSignature = $null
$terminal = $null
$hasPr = $PSBoundParameters.ContainsKey('PR')
$timer = [System.Diagnostics.Stopwatch]::StartNew()
$timeout = [TimeSpan]::FromMinutes($TimeoutMinutes)

function Write-StateChange {
    param(
        [Parameter(Mandatory)]
        [string]$Signature,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Event
    )

    if ($script:lastSignature -eq $Signature) {
        return
    }

    $script:lastSignature = $Signature
    $line = $Event | ConvertTo-Json -Compress -Depth 5
    Write-Output $line
    if ($LogPath) {
        Add-Content -LiteralPath $LogPath -Value $line -Encoding utf8
    }
}

# A diagnostic raised inside a helper whose output the caller captures
# (`$payload = ...`) would be swallowed, so record it and unwind to the
# top-level handler, which emits it on the normal output stream and exits 1.
function Stop-Watch {
    param(
        [Parameter(Mandatory)]
        [string]$Signature,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Event
    )

    $script:terminal = @{
        Signature = $Signature
        Event = $Event
    }
    throw 'watch-pr terminal state'
}

function Get-Detail {
    param($Value)

    $text = (@($Value) -join [Environment]::NewLine)
    if ($text.Length -gt 500) {
        return $text.Substring(0, 500) + '...[truncated]'
    }
    return $text
}

$expectedSha = if ($ExpectedHeadSha) { $ExpectedHeadSha.Trim().ToLowerInvariant() } else { '' }

$identityErrors = @()
if ($expectedSha -notmatch '^[0-9a-f]{40}$') {
    $identityErrors += 'ExpectedHeadSha must be the full 40-character SHA of the reviewed head.'
}

$runIds = @()
foreach ($token in @($RunId | Where-Object { $null -ne $_ })) {
    foreach ($member in ([string]$token).Split(',')) {
        $text = $member.Trim()
        if ($text -notmatch '^[0-9]+$') {
            $identityErrors += "RunId member '$text' is not a positive decimal workflow run id."
            continue
        }

        $parsed = [long]0
        $isLong = [long]::TryParse(
            $text,
            [System.Globalization.NumberStyles]::None,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [ref]$parsed
        )
        if (-not $isLong) {
            $identityErrors += "RunId member '$text' is outside the supported workflow run id range."
            continue
        }
        if ($parsed -le 0) {
            $identityErrors += "RunId member '$text' must be greater than zero."
            continue
        }

        if ($runIds -notcontains $parsed) {
            $runIds += $parsed
        }
    }
}
if ($runIds.Count -eq 0) {
    $identityErrors += 'RunId must list at least one workflow run id selected for this gate.'
}
if ($identityErrors.Count -gt 0) {
    Write-StateChange -Signature 'MISSING_GATE_IDENTITY' -Event ([ordered]@{
        repo = $Repo
        state = 'MISSING_GATE_IDENTITY'
        detail = ($identityErrors -join ' ')
    })
    exit 2
}

function New-Event {
    param(
        [Parameter(Mandatory)]
        [string]$State,

        [System.Collections.IDictionary]$Extra
    )

    $event = [ordered]@{ repo = $Repo }
    if ($script:hasPr) {
        $event['pr'] = $PR
    }
    $event['expectedHeadSha'] = $script:expectedSha
    $event['runIds'] = $script:runIds
    $event['state'] = $State
    if ($Extra) {
        foreach ($key in $Extra.Keys) {
            $event[$key] = $Extra[$key]
        }
    }
    return $event
}

function Invoke-GhJson {
    param(
        [Parameter(Mandatory)]
        [string[]]$GhArgs,

        [Parameter(Mandatory)]
        [string]$Scope
    )

    $raw = & gh @GhArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        $detail = Get-Detail $raw
        Stop-Watch -Signature "QUERY_ERROR|$Scope|$detail" -Event (
            New-Event -State 'QUERY_ERROR' -Extra ([ordered]@{ scope = $Scope; detail = $detail })
        )
    }

    try {
        return ($raw -join [Environment]::NewLine) | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        $detail = Get-Detail $_.Exception.Message
        Stop-Watch -Signature "INVALID_JSON|$Scope|$detail" -Event (
            New-Event -State 'INVALID_JSON' -Extra ([ordered]@{ scope = $Scope; detail = $detail })
        )
    }
}

function Get-PrChecks {
    $payload = Invoke-GhJson -Scope 'pr' -GhArgs @(
        'pr', 'view', [string]$PR,
        '--repo', $Repo,
        '--json', 'headRefOid,statusCheckRollup'
    )

    $headSha = ([string]$payload.headRefOid).Trim().ToLowerInvariant()
    if ($headSha -ne $script:expectedSha) {
        Stop-Watch -Signature "HEAD_MISMATCH|$headSha" -Event (
            New-Event -State 'HEAD_MISMATCH' -Extra ([ordered]@{ scope = 'pr'; actualHeadSha = $headSha })
        )
    }

    return @($payload.statusCheckRollup | ForEach-Object {
        $name = if ($_.name) {
            $_.name
        }
        elseif ($_.context) {
            $_.context
        }
        elseif ($_.workflowName) {
            $_.workflowName
        }
        else {
            $_.__typename
        }

        $state = if ($_.conclusion) {
            $_.conclusion
        }
        elseif ($_.state) {
            $_.state
        }
        elseif ($_.status) {
            $_.status
        }
        else {
            'UNKNOWN'
        }

        [ordered]@{
            name = [string]$name
            state = ([string]$state).ToUpperInvariant()
        }
    } | Sort-Object name, state)
}

function Get-RunStates {
    $results = @()
    foreach ($id in $script:runIds) {
        $payload = Invoke-GhJson -Scope "run:$id" -GhArgs @(
            'run', 'view', [string]$id,
            '--repo', $Repo,
            '--json', 'databaseId,headSha,workflowName,status,conclusion,url'
        )

        $url = [string]$payload.url
        $uri = $null
        $pathPattern = '(?i)^/' + [regex]::Escape($Repo) + '/actions/runs/' + $id +
            '(/attempts/[0-9]+)?/?$'
        $urlMatches = [System.Uri]::TryCreate($url, [System.UriKind]::Absolute, [ref]$uri) -and
            $uri.Scheme -eq 'https' -and
            $uri.Host -eq 'github.com' -and
            $uri.AbsolutePath -match $pathPattern
        $identityMatches = ([long]$payload.databaseId -eq $id) -and $urlMatches
        if (-not $identityMatches) {
            Stop-Watch -Signature "RUN_IDENTITY_MISMATCH|$id|$($payload.databaseId)|$url" -Event (
                New-Event -State 'RUN_IDENTITY_MISMATCH' -Extra ([ordered]@{
                    scope = "run:$id"
                    actualRunId = $payload.databaseId
                    url = $url
                })
            )
        }

        $runHeadSha = ([string]$payload.headSha).Trim().ToLowerInvariant()
        if ($runHeadSha -ne $script:expectedSha) {
            Stop-Watch -Signature "RUN_HEAD_MISMATCH|$id|$runHeadSha" -Event (
                New-Event -State 'RUN_HEAD_MISMATCH' -Extra ([ordered]@{
                    scope = "run:$id"
                    actualHeadSha = $runHeadSha
                })
            )
        }

        $status = ([string]$payload.status).ToUpperInvariant()
        $conclusion = ([string]$payload.conclusion).ToUpperInvariant()
        $state = if ($status -ne 'COMPLETED') {
            'PENDING'
        }
        elseif ($conclusion -eq 'SUCCESS') {
            'SUCCESS'
        }
        else {
            'FAILURE'
        }

        $results += [ordered]@{
            runId = $id
            name = [string]$payload.workflowName
            status = $status
            conclusion = $conclusion
            state = $state
        }
    }
    return @($results)
}

try {
    while ($true) {
        $elapsed = & $GetElapsed
        if ($elapsed -ge $timeout) {
            Write-StateChange -Signature 'TIMEOUT' -Event (
                New-Event -State 'TIMEOUT' -Extra ([ordered]@{
                    elapsedSeconds = [math]::Round($elapsed.TotalSeconds, 1)
                    note = 'observation window ended; no run was cancelled'
                })
            )
            exit 124
        }

        $checks = @(if ($hasPr) { Get-PrChecks } else { @() })
        $runs = @(Get-RunStates)

        $checkStates = @($checks | ForEach-Object { $_.state })
        $runStates = @($runs | ForEach-Object { $_.state })

        $terminalFailure = @($checkStates | Where-Object { $_ -in $failureStates }).Count -gt 0 -or
            @($runStates | Where-Object { $_ -eq 'FAILURE' }).Count -gt 0
        $checksSucceeded = (-not $hasPr) -or ($checks.Count -gt 0 -and
            @($checkStates | Where-Object { $_ -notin $successStates }).Count -eq 0)
        $runsSucceeded = $runs.Count -gt 0 -and
            @($runStates | Where-Object { $_ -ne 'SUCCESS' }).Count -eq 0
        $terminalSuccess = $checksSucceeded -and $runsSucceeded

        $aggregate = if ($terminalFailure) {
            'FAILURE'
        }
        elseif ($terminalSuccess) {
            'SUCCESS'
        }
        else {
            'PENDING'
        }

        $signature = "$aggregate|checks:" + (($checks | ForEach-Object {
            "$($_.name)=$($_.state)"
        }) -join ';') + '|runs:' + (($runs | ForEach-Object {
            "$($_.runId)=$($_.status)/$($_.conclusion)"
        }) -join ';')

        $extra = [ordered]@{}
        if ($hasPr) {
            $extra['checks'] = $checks
        }
        $extra['runs'] = $runs
        Write-StateChange -Signature $signature -Event (New-Event -State $aggregate -Extra $extra)

        if ($terminalFailure) {
            exit 1
        }
        if ($terminalSuccess) {
            exit 0
        }

        $remainingMilliseconds = [math]::Max(
            1,
            [math]::Floor(($timeout - (& $GetElapsed)).TotalMilliseconds)
        )
        $sleepMilliseconds = [math]::Min($IntervalSeconds * 1000, $remainingMilliseconds)
        Start-Sleep -Milliseconds $sleepMilliseconds
    }
}
catch {
    if (-not $terminal) {
        throw
    }
    Write-StateChange -Signature $terminal.Signature -Event $terminal.Event
    exit 1
}
