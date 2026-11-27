#requires -Version 7.0
<#
Offline regression fixtures for scripts/watch-pr.ps1.

`gh` is replaced by a scripted function: no network, no live API, no extra
dependencies. Each case asserts the watcher's exit code and the exact ordered
state transitions it emitted. The closing native `pwsh -File` cases check
command-line parsing and the output a native caller receives; neither reaches
an API.
#>
[CmdletBinding()]
param(
    [string]$LogPath
)

$ErrorActionPreference = 'Stop'
$watcher = Join-Path $PSScriptRoot 'watch-pr.ps1'
if (-not (Test-Path -LiteralPath $watcher)) {
    throw "watch-pr.ps1 not found next to $PSCommandPath"
}

$repo = 'fixture-team/sample-app'
$headSha = '0f3b8c1d6a4e2b9f7c5d8a1e3b6f4c2d9a7e5b18'
$otherSha = 'ffeeddccbbaa99887766554433221100ffeeddcc'

function global:gh {
    $argv = @($args | ForEach-Object { [string]$_ })
    $global:FakeGhCalls.Add($argv -join ' ') | Out-Null

    $queue = $null
    if ($argv[0] -eq 'pr') {
        $queue = $global:FakeGh.Pr
    }
    elseif ($argv[0] -eq 'run') {
        $queue = $global:FakeGh.Runs[$argv[2]]
    }

    if ($null -eq $queue -or $queue.Count -eq 0) {
        $global:LASTEXITCODE = 1
        return "fake gh: no scripted response for '$($argv -join ' ')'"
    }

    $entry = $queue[0]
    if ($queue.Count -gt 1) {
        $queue.RemoveAt(0)
    }

    $global:LASTEXITCODE = [int]$entry.ExitCode
    if ($null -ne $entry.Output) {
        return $entry.Output
    }
}

function New-Entry {
    param(
        [string]$Output,
        [int]$ExitCode = 0
    )

    return @{ Output = $Output; ExitCode = $ExitCode }
}

function New-PrJson {
    param(
        [string]$HeadSha,
        [object[]]$Checks = @()
    )

    return [pscustomobject]@{
        headRefOid = $HeadSha
        statusCheckRollup = $Checks
    } | ConvertTo-Json -Depth 6
}

function New-Check {
    param(
        [string]$Name,
        [string]$Conclusion
    )

    return [pscustomobject]@{ name = $Name; status = 'COMPLETED'; conclusion = $Conclusion }
}

function New-RunJson {
    param(
        [long]$Id,
        [string]$HeadSha,
        [string]$Status,
        [string]$Conclusion = '',
        [string]$Name = 'ci',
        [long]$DatabaseId = 0,
        [string]$Url
    )

    if ($DatabaseId -eq 0) { $DatabaseId = $Id }
    if (-not $Url) { $Url = "https://github.com/$repo/actions/runs/$DatabaseId" }

    return [pscustomobject]@{
        databaseId = $DatabaseId
        headSha = $HeadSha
        workflowName = $Name
        status = $Status
        conclusion = $Conclusion
        url = $Url
    } | ConvertTo-Json -Depth 4
}

function New-Queue {
    param([object[]]$Entries)

    $list = [System.Collections.ArrayList]::new()
    foreach ($entry in @($Entries)) {
        $list.Add($entry) | Out-Null
    }
    return ,$list
}

$greenChecks = @((New-Check -Name 'test' -Conclusion 'SUCCESS'), (New-Check -Name 'analyze' -Conclusion 'SUCCESS'))
$redChecks = @((New-Check -Name 'test' -Conclusion 'FAILURE'), (New-Check -Name 'analyze' -Conclusion 'SUCCESS'))

$cases = @(
    @{
        Name = 'green-checks-with-active-workflow-stays-pending'
        Pr = @(New-Entry -Output (New-PrJson -HeadSha $headSha -Checks $greenChecks))
        Runs = @{ '101' = @(New-Entry -Output (New-RunJson -Id 101 -HeadSha $headSha -Status 'in_progress')) }
        Params = @{ PR = 136; ExpectedHeadSha = $headSha; RunId = @(101) }
        ExpectedExit = 124
        ExpectedStates = @('PENDING', 'TIMEOUT')
    },
    @{
        Name = 'multiple-runs-one-pending-stays-pending'
        Pr = @(New-Entry -Output (New-PrJson -HeadSha $headSha -Checks $greenChecks))
        Runs = @{
            '101' = @(New-Entry -Output (New-RunJson -Id 101 -HeadSha $headSha -Status 'completed' -Conclusion 'success'))
            '102' = @(New-Entry -Output (New-RunJson -Id 102 -HeadSha $headSha -Status 'queued' -Name 'aab'))
        }
        Params = @{ PR = 136; ExpectedHeadSha = $headSha; RunId = @(101, 102) }
        ExpectedExit = 124
        ExpectedStates = @('PENDING', 'TIMEOUT')
    },
    @{
        Name = 'pr-head-mismatch-fails'
        Pr = @(New-Entry -Output (New-PrJson -HeadSha $otherSha -Checks $greenChecks))
        Runs = @{ '101' = @(New-Entry -Output (New-RunJson -Id 101 -HeadSha $headSha -Status 'completed' -Conclusion 'success')) }
        Params = @{ PR = 136; ExpectedHeadSha = $headSha; RunId = @(101) }
        ExpectedExit = 1
        ExpectedStates = @('HEAD_MISMATCH')
    },
    @{
        Name = 'workflow-head-mismatch-fails'
        Pr = @(New-Entry -Output (New-PrJson -HeadSha $headSha -Checks $greenChecks))
        Runs = @{ '101' = @(New-Entry -Output (New-RunJson -Id 101 -HeadSha $otherSha -Status 'completed' -Conclusion 'success')) }
        Params = @{ PR = 136; ExpectedHeadSha = $headSha; RunId = @(101) }
        ExpectedExit = 1
        ExpectedStates = @('RUN_HEAD_MISMATCH')
    },
    @{
        Name = 'wrong-run-identity-fails'
        Pr = @(New-Entry -Output (New-PrJson -HeadSha $headSha -Checks $greenChecks))
        Runs = @{
            '101' = @(New-Entry -Output (New-RunJson -Id 101 -DatabaseId 999 -HeadSha $headSha -Status 'completed' -Conclusion 'success' -Url 'https://github.com/other/repo/actions/runs/999'))
        }
        Params = @{ PR = 136; ExpectedHeadSha = $headSha; RunId = @(101) }
        ExpectedExit = 1
        ExpectedStates = @('RUN_IDENTITY_MISMATCH')
    },
    @{
        Name = 'failed-run-despite-green-checks-fails'
        Pr = @(New-Entry -Output (New-PrJson -HeadSha $headSha -Checks $greenChecks))
        Runs = @{ '101' = @(New-Entry -Output (New-RunJson -Id 101 -HeadSha $headSha -Status 'completed' -Conclusion 'failure')) }
        Params = @{ PR = 136; ExpectedHeadSha = $headSha; RunId = @(101) }
        ExpectedExit = 1
        ExpectedStates = @('FAILURE')
    },
    @{
        Name = 'cancelled-run-despite-green-checks-fails'
        Pr = @(New-Entry -Output (New-PrJson -HeadSha $headSha -Checks $greenChecks))
        Runs = @{ '101' = @(New-Entry -Output (New-RunJson -Id 101 -HeadSha $headSha -Status 'completed' -Conclusion 'cancelled')) }
        Params = @{ PR = 136; ExpectedHeadSha = $headSha; RunId = @(101) }
        ExpectedExit = 1
        ExpectedStates = @('FAILURE')
    },
    @{
        Name = 'failed-pr-check-fails'
        Pr = @(New-Entry -Output (New-PrJson -HeadSha $headSha -Checks $redChecks))
        Runs = @{ '101' = @(New-Entry -Output (New-RunJson -Id 101 -HeadSha $headSha -Status 'completed' -Conclusion 'success')) }
        Params = @{ PR = 136; ExpectedHeadSha = $headSha; RunId = @(101) }
        ExpectedExit = 1
        ExpectedStates = @('FAILURE')
    },
    @{
        Name = 'query-error-fails'
        Pr = @(New-Entry -Output 'gh: HTTP 502 Bad Gateway' -ExitCode 1)
        Runs = @{ '101' = @(New-Entry -Output (New-RunJson -Id 101 -HeadSha $headSha -Status 'completed' -Conclusion 'success')) }
        Params = @{ PR = 136; ExpectedHeadSha = $headSha; RunId = @(101) }
        ExpectedExit = 1
        ExpectedStates = @('QUERY_ERROR')
    },
    @{
        Name = 'run-query-error-fails'
        Pr = @(New-Entry -Output (New-PrJson -HeadSha $headSha -Checks $greenChecks))
        Runs = @{ '101' = @(New-Entry -Output 'gh: could not find any workflow run' -ExitCode 1) }
        Params = @{ PR = 136; ExpectedHeadSha = $headSha; RunId = @(101) }
        ExpectedExit = 1
        ExpectedStates = @('QUERY_ERROR')
    },
    @{
        Name = 'invalid-json-fails'
        Pr = @(New-Entry -Output '{ "headRefOid": ')
        Runs = @{ '101' = @(New-Entry -Output (New-RunJson -Id 101 -HeadSha $headSha -Status 'completed' -Conclusion 'success')) }
        Params = @{ PR = 136; ExpectedHeadSha = $headSha; RunId = @(101) }
        ExpectedExit = 1
        ExpectedStates = @('INVALID_JSON')
    },
    @{
        Name = 'empty-checks-on-supplied-pr-stays-pending'
        Pr = @(New-Entry -Output (New-PrJson -HeadSha $headSha -Checks @()))
        Runs = @{ '101' = @(New-Entry -Output (New-RunJson -Id 101 -HeadSha $headSha -Status 'completed' -Conclusion 'success')) }
        Params = @{ PR = 136; ExpectedHeadSha = $headSha; RunId = @(101) }
        ExpectedExit = 124
        ExpectedStates = @('PENDING', 'TIMEOUT')
    },
    @{
        Name = 'complete-successful-runs-succeed'
        Pr = @(New-Entry -Output (New-PrJson -HeadSha $headSha -Checks $greenChecks))
        Runs = @{
            '101' = @(New-Entry -Output (New-RunJson -Id 101 -HeadSha $headSha -Status 'completed' -Conclusion 'success'))
            '102' = @(New-Entry -Output (New-RunJson -Id 102 -HeadSha $headSha -Status 'completed' -Conclusion 'success' -Name 'aab'))
        }
        Params = @{ PR = 136; ExpectedHeadSha = $headSha; RunId = @(101, 102) }
        ExpectedExit = 0
        ExpectedStates = @('SUCCESS')
        RequiredCalls = @(
            "pr view 136 --repo $repo --json headRefOid,statusCheckRollup",
            "run view 101 --repo $repo --json databaseId,headSha,workflowName,status,conclusion,url",
            "run view 102 --repo $repo --json databaseId,headSha,workflowName,status,conclusion,url"
        )
    },
    @{
        Name = 'run-only-cd-succeeds-without-pr'
        Pr = @()
        Runs = @{ '201' = @(New-Entry -Output (New-RunJson -Id 201 -HeadSha $headSha -Status 'completed' -Conclusion 'success' -Name 'cd')) }
        Params = @{ ExpectedHeadSha = $headSha; RunId = @(201) }
        ExpectedExit = 0
        ExpectedStates = @('SUCCESS')
        ForbiddenCalls = @('pr view')
    },
    @{
        Name = 'run-only-cd-pending-times-out'
        Pr = @()
        Runs = @{ '201' = @(New-Entry -Output (New-RunJson -Id 201 -HeadSha $headSha -Status 'in_progress' -Name 'cd')) }
        Params = @{ ExpectedHeadSha = $headSha; RunId = @(201) }
        ExpectedExit = 124
        ExpectedStates = @('PENDING', 'TIMEOUT')
        ForbiddenCalls = @('pr view')
    },
    @{
        Name = 'unchanged-state-emits-one-line-per-transition'
        Pr = @(
            (New-Entry -Output (New-PrJson -HeadSha $headSha -Checks $greenChecks)),
            (New-Entry -Output (New-PrJson -HeadSha $headSha -Checks $greenChecks))
        )
        Runs = @{
            '101' = @(
                (New-Entry -Output (New-RunJson -Id 101 -HeadSha $headSha -Status 'in_progress')),
                (New-Entry -Output (New-RunJson -Id 101 -HeadSha $headSha -Status 'in_progress'))
            )
        }
        Params = @{ PR = 136; ExpectedHeadSha = $headSha; RunId = @(101) }
        ExpectedExit = 124
        ExpectedStates = @('PENDING', 'TIMEOUT')
        MinimumGhCalls = 4
    },
    @{
        Name = 'missing-run-id-is-rejected'
        Pr = @()
        Runs = @{}
        Params = @{ PR = 136; ExpectedHeadSha = $headSha }
        ExpectedExit = 2
        ExpectedStates = @('MISSING_GATE_IDENTITY')
        MaximumGhCalls = 0
    },
    @{
        Name = 'short-head-sha-is-rejected'
        Pr = @()
        Runs = @{}
        Params = @{ PR = 136; ExpectedHeadSha = '0f3b8c1'; RunId = @(101) }
        ExpectedExit = 2
        ExpectedStates = @('MISSING_GATE_IDENTITY')
        MaximumGhCalls = 0
    },
    @{
        Name = 'negative-run-id-member-is-rejected'
        Pr = @()
        Runs = @{}
        Params = @{ ExpectedHeadSha = $headSha; RunId = @(101, -1) }
        ExpectedExit = 2
        ExpectedStates = @('MISSING_GATE_IDENTITY')
        MaximumGhCalls = 0
    },
    @{
        Name = 'zero-run-id-member-is-rejected'
        Pr = @()
        Runs = @{}
        Params = @{ ExpectedHeadSha = $headSha; RunId = '101,0' }
        ExpectedExit = 2
        ExpectedStates = @('MISSING_GATE_IDENTITY')
        MaximumGhCalls = 0
    },
    @{
        Name = 'malformed-run-id-member-is-rejected'
        Pr = @()
        Runs = @{}
        Params = @{ ExpectedHeadSha = $headSha; RunId = '101,abc' }
        ExpectedExit = 2
        ExpectedStates = @('MISSING_GATE_IDENTITY')
        MaximumGhCalls = 0
    },
    @{
        Name = 'overflowing-run-id-member-is-rejected'
        Pr = @()
        Runs = @{}
        Params = @{ ExpectedHeadSha = $headSha; RunId = '99999999999999999999' }
        ExpectedExit = 2
        ExpectedStates = @('MISSING_GATE_IDENTITY')
        MaximumGhCalls = 0
    },
    @{
        Name = 'empty-run-id-member-is-rejected'
        Pr = @()
        Runs = @{}
        Params = @{ ExpectedHeadSha = $headSha; RunId = '101,,102' }
        ExpectedExit = 2
        ExpectedStates = @('MISSING_GATE_IDENTITY')
        MaximumGhCalls = 0
    },
    @{
        Name = 'comma-string-run-ids-select-both-runs'
        Pr = @()
        Runs = @{
            '101' = @(New-Entry -Output (New-RunJson -Id 101 -HeadSha $headSha -Status 'completed' -Conclusion 'success'))
            '102' = @(New-Entry -Output (New-RunJson -Id 102 -HeadSha $headSha -Status 'completed' -Conclusion 'success' -Name 'aab'))
        }
        Params = @{ ExpectedHeadSha = $headSha; RunId = '101,102' }
        ExpectedExit = 0
        ExpectedStates = @('SUCCESS')
        RequiredCalls = @(
            "run view 101 --repo $repo --json databaseId,headSha,workflowName,status,conclusion,url",
            "run view 102 --repo $repo --json databaseId,headSha,workflowName,status,conclusion,url"
        )
        MaximumGhCalls = 2
    },
    @{
        Name = 'duplicate-run-ids-are-queried-once'
        Pr = @()
        Runs = @{ '101' = @(New-Entry -Output (New-RunJson -Id 101 -HeadSha $headSha -Status 'completed' -Conclusion 'success')) }
        Params = @{ ExpectedHeadSha = $headSha; RunId = '101,101' }
        ExpectedExit = 0
        ExpectedStates = @('SUCCESS')
        MaximumGhCalls = 1
    },
    @{
        Name = 'run-url-id-prefix-mismatch-fails'
        Pr = @()
        Runs = @{
            '101' = @(New-Entry -Output (New-RunJson -Id 101 -HeadSha $headSha -Status 'completed' -Conclusion 'success' -Url "https://github.com/$repo/actions/runs/1019"))
        }
        Params = @{ ExpectedHeadSha = $headSha; RunId = @(101) }
        ExpectedExit = 1
        ExpectedStates = @('RUN_IDENTITY_MISMATCH')
    },
    @{
        Name = 'run-url-wrong-repository-fails'
        Pr = @()
        Runs = @{
            '101' = @(New-Entry -Output (New-RunJson -Id 101 -HeadSha $headSha -Status 'completed' -Conclusion 'success' -Url 'https://github.com/other/repo/actions/runs/101'))
        }
        Params = @{ ExpectedHeadSha = $headSha; RunId = @(101) }
        ExpectedExit = 1
        ExpectedStates = @('RUN_IDENTITY_MISMATCH')
    },
    @{
        Name = 'run-url-untrusted-host-fails'
        Pr = @()
        Runs = @{
            '101' = @(New-Entry -Output (New-RunJson -Id 101 -HeadSha $headSha -Status 'completed' -Conclusion 'success' -Url "https://github.com.evil.test/$repo/actions/runs/101"))
        }
        Params = @{ ExpectedHeadSha = $headSha; RunId = @(101) }
        ExpectedExit = 1
        ExpectedStates = @('RUN_IDENTITY_MISMATCH')
    },
    @{
        Name = 'run-url-repository-case-difference-succeeds'
        Pr = @()
        Runs = @{
            '101' = @(New-Entry -Output (New-RunJson -Id 101 -HeadSha $headSha -Status 'completed' -Conclusion 'success' -Url 'https://github.com/FIXTURE-TEAM/SAMPLE-APP/actions/runs/101'))
        }
        Params = @{ ExpectedHeadSha = $headSha; RunId = @(101) }
        ExpectedExit = 0
        ExpectedStates = @('SUCCESS')
    }
)

# This timeout must convert to zero TimeSpan ticks: only then is the observation
# window provably over before the first poll, so the child process cannot reach
# gh however fast the host is. The runner validates the conversion.
$nativeTimeoutMinutes = '0.000000000001'

$nativeCases = @(
    @{
        Name = 'native-file-comma-string-keeps-both-run-ids'
        Arguments = @(
            '-Repo', $repo,
            '-ExpectedHeadSha', $headSha,
            '-RunId', '101,102',
            '-TimeoutMinutes', $nativeTimeoutMinutes
        )
        RequiresZeroTimeout = $true
        ExpectedExit = 124
        ExpectedStates = @('TIMEOUT')
        ExpectedRunIds = @(101, 102)
    },
    @{
        Name = 'native-file-invalid-run-id-emits-clean-json'
        Arguments = @(
            '-Repo', $repo,
            '-ExpectedHeadSha', $headSha,
            '-RunId', '101,abc',
            '-TimeoutMinutes', '5'
        )
        ExpectedExit = 2
        ExpectedStates = @('MISSING_GATE_IDENTITY')
        ExpectedRunIds = @()
    }
)

$details = [System.Collections.Generic.List[string]]::new()
$failures = 0

$fixtureClock = @{ Elapsed = [TimeSpan]::Zero }
$getFixtureElapsed = { $fixtureClock.Elapsed }.GetNewClosure()
function Start-Sleep {
    param([ValidateRange(1, [int]::MaxValue)][int]$Milliseconds)

    $fixtureClock.Elapsed += [TimeSpan]::FromMilliseconds($Milliseconds)
}

foreach ($case in $cases) {
    $global:FakeGhCalls = [System.Collections.ArrayList]::new()
    $runQueues = @{}
    foreach ($key in $case.Runs.Keys) {
        $runQueues[$key] = New-Queue -Entries $case.Runs[$key]
    }
    $global:FakeGh = @{ Pr = (New-Queue -Entries $case.Pr); Runs = $runQueues }

    $fixtureClock.Elapsed = [TimeSpan]::Zero
    $params = @{ Repo = $repo; IntervalSeconds = 1; TimeoutMinutes = 0.02; GetElapsed = $getFixtureElapsed }
    foreach ($key in $case.Params.Keys) {
        $params[$key] = $case.Params[$key]
    }

    $output = & $watcher @params 2>&1
    $exitCode = $LASTEXITCODE

    $states = @(foreach ($line in @($output)) {
        $text = [string]$line
        if (-not $text.Trim()) { continue }
        try {
            ([string](($text | ConvertFrom-Json -ErrorAction Stop).state))
        }
        catch {
            "UNPARSED:$text"
        }
    })

    $problems = @()
    if ($exitCode -ne $case.ExpectedExit) {
        $problems += "exit $exitCode, expected $($case.ExpectedExit)"
    }
    $expectedStates = @($case.ExpectedStates) -join ','
    $actualStates = $states -join ','
    if ($actualStates -ne $expectedStates) {
        $problems += "states [$actualStates], expected [$expectedStates]"
    }
    foreach ($required in @($case.RequiredCalls)) {
        if ($required -and -not @($global:FakeGhCalls | Where-Object { $_ -eq $required }).Count) {
            $problems += "missing gh call '$required'"
        }
    }
    foreach ($forbidden in @($case.ForbiddenCalls)) {
        if ($forbidden -and @($global:FakeGhCalls | Where-Object { $_ -like "*$forbidden*" }).Count) {
            $problems += "unexpected gh call matching '$forbidden'"
        }
    }
    if ($case.ContainsKey('MinimumGhCalls') -and $global:FakeGhCalls.Count -lt $case.MinimumGhCalls) {
        $problems += "gh calls $($global:FakeGhCalls.Count), expected at least $($case.MinimumGhCalls)"
    }
    if ($case.ContainsKey('MaximumGhCalls') -and $global:FakeGhCalls.Count -gt $case.MaximumGhCalls) {
        $problems += "gh calls $($global:FakeGhCalls.Count), expected at most $($case.MaximumGhCalls)"
    }

    if ($problems.Count -eq 0) {
        Write-Output "PASS $($case.Name)"
        $details.Add("PASS $($case.Name) | exit $exitCode | states [$actualStates]")
    }
    else {
        $failures++
        Write-Output "FAIL $($case.Name): $($problems -join '; ')"
        $details.Add("FAIL $($case.Name) | $($problems -join '; ') | output: $(@($output) -join ' / ')")
    }
}

Remove-Item -LiteralPath 'Function:\gh' -ErrorAction SilentlyContinue
Remove-Variable -Name FakeGh, FakeGhCalls -Scope Global -ErrorAction SilentlyContinue

# Native `pwsh -File` invocations: one proves the gate identity parsed from the
# command line with an already elapsed observation window, the other proves an
# identity rejection reaches a native caller as clean JSON rather than formatted
# error text. Neither reaches gh.
$pwshPath = Join-Path $PSHOME 'pwsh.exe'
if (-not (Test-Path -LiteralPath $pwshPath)) {
    $pwshPath = 'pwsh'
}

foreach ($case in $nativeCases) {
    if ($case.RequiresZeroTimeout) {
        $ticks = [TimeSpan]::FromMinutes(
            [double]::Parse($nativeTimeoutMinutes, [System.Globalization.CultureInfo]::InvariantCulture)
        ).Ticks
        if ($ticks -ne 0) {
            $failures++
            $problem = "precondition: $nativeTimeoutMinutes minutes is $ticks ticks, not zero, so the case could reach gh"
            Write-Output "FAIL $($case.Name): $problem"
            $details.Add("FAIL $($case.Name) | $problem")
            continue
        }
    }

    $nativeArgs = @($case.Arguments)
    $output = & $pwshPath -NoProfile -NonInteractive -File $watcher @nativeArgs 2>&1
    $exitCode = $LASTEXITCODE

    $events = @(foreach ($line in @($output)) {
        $text = [string]$line
        if (-not $text.Trim()) { continue }
        try {
            $text | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            [pscustomobject]@{ state = "UNPARSED:$text"; runIds = @() }
        }
    })

    $problems = @()
    if ($exitCode -ne $case.ExpectedExit) {
        $problems += "exit $exitCode, expected $($case.ExpectedExit)"
    }
    $actualStates = @($events | ForEach-Object { [string]$_.state }) -join ','
    $expectedStates = @($case.ExpectedStates) -join ','
    if ($actualStates -ne $expectedStates) {
        $problems += "states [$actualStates], expected [$expectedStates]"
    }
    $actualRunIds = @($events | Select-Object -First 1 | ForEach-Object { @($_.runIds) }) -join ','
    $expectedRunIds = @($case.ExpectedRunIds) -join ','
    if ($actualRunIds -ne $expectedRunIds) {
        $problems += "runIds [$actualRunIds], expected [$expectedRunIds]"
    }

    if ($problems.Count -eq 0) {
        Write-Output "PASS $($case.Name)"
        $details.Add("PASS $($case.Name) | exit $exitCode | runIds [$actualRunIds]")
    }
    else {
        $failures++
        Write-Output "FAIL $($case.Name): $($problems -join '; ')"
        $details.Add("FAIL $($case.Name) | $($problems -join '; ') | output: $(@($output) -join ' / ')")
    }
}

$total = $cases.Count + $nativeCases.Count
$summary = "cases $total, passed $($total - $failures), failed $failures"
Write-Output $summary
if ($LogPath) {
    $details.Add($summary)
    Set-Content -LiteralPath $LogPath -Value $details -Encoding utf8
}

exit ([int]($failures -gt 0))
