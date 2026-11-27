$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\skills\pipeline')).Path
$script = Join-Path $root 'bin\usage.js'
$failures = [Collections.Generic.List[string]]::new()
$assertions = 0

function Assert-True([bool]$Condition, [string]$Message) {
    $script:assertions++
    if (-not $Condition) { $failures.Add($Message) }
}

function Invoke-Usage([string[]]$Arguments) {
    $output = (& node $script @Arguments 2>&1 | Out-String)
    return [pscustomobject]@{ Output = $output; ExitCode = $LASTEXITCODE }
}

$work = Join-Path ([IO.Path]::GetTempPath()) ('.test-usage-' + [guid]::NewGuid())
$project = Join-Path $work 'projects\p1'
$subagents = Join-Path $project 'subagents'
New-Item -ItemType Directory -Path $subagents -Force | Out-Null

try {
    Assert-True (Test-Path -LiteralPath $script) 'missing bin\usage.js'
    $now = [DateTime]::UtcNow.ToString('o')
    $old = [DateTime]::UtcNow.AddDays(-30).ToString('o')
    $recent = [DateTime]::UtcNow.AddHours(-3).ToString('o')
    $lines = @(
        @{ uuid = 'u0'; sessionId = 'parent-1'; timestamp = $recent; rawContent = 'DO-NOT-PRINT-THIS'; message = @{ id = 'm0'; model = 'claude-opus-5'; usage = @{ input_tokens = 10; cache_read_input_tokens = 20000; cache_creation_input_tokens = 0; output_tokens = 20 } } },
        @{ uuid = 'u1'; sessionId = 'parent-1'; timestamp = $now; message = @{ id = 'm1'; model = 'claude-fable-5-1'; usage = @{ input_tokens = 10; cache_read_input_tokens = 250000; cache_creation_input_tokens = 0; output_tokens = 100 } } },
        @{ uuid = 'u1-stream'; sessionId = 'parent-1'; timestamp = $now; message = @{ id = 'm1'; model = 'claude-fable-5-1'; usage = @{ input_tokens = 10; cache_read_input_tokens = 250000; cache_creation_input_tokens = 0; output_tokens = 200 } } },
        @{ uuid = 'u2'; sessionId = 'parent-1'; timestamp = $now; message = @{ id = 'm2'; model = 'claude-opus-5'; usage = @{ input_tokens = 10; cache_read_input_tokens = 50000; cache_creation_input_tokens = 0; output_tokens = 50 } } },
        @{ uuid = 's0'; sessionId = 'parent-1'; timestamp = $now; message = @{ id = 's0'; model = '<synthetic>'; usage = @{ input_tokens = 0; cache_read_input_tokens = 0; cache_creation_input_tokens = 0; output_tokens = 0 } } },
        @{ uuid = 'u3'; timestamp = $old; message = @{ id = 'm3'; model = 'claude-fable-5-1'; usage = @{ input_tokens = 10; cache_read_input_tokens = 900000; cache_creation_input_tokens = 0; output_tokens = 50 } } }
    ) | ForEach-Object { $_ | ConvertTo-Json -Depth 5 -Compress }
    Set-Content -LiteralPath (Join-Path $project 's1.jsonl') -Value $lines -Encoding utf8
    $subagentLines = @(
        @{ uuid = 'a1'; sessionId = 'parent-1'; timestamp = $now; message = @{ id = 'm1'; model = 'claude-haiku-5'; usage = @{ input_tokens = 5; cache_read_input_tokens = 10000; cache_creation_input_tokens = 0; output_tokens = 10 } } }
    ) | ForEach-Object { $_ | ConvertTo-Json -Depth 5 -Compress }
    Set-Content -LiteralPath (Join-Path $subagents 'agent-a.jsonl') -Value $subagentLines -Encoding utf8

    $jsonRun = Invoke-Usage @('--root', (Join-Path $work 'projects'), '--days', '7', '--json')
    Assert-True ($jsonRun.ExitCode -eq 0) "usage report failed in JSON mode: $($jsonRun.Output)"
    $data = $jsonRun.Output | ConvertFrom-Json
    Assert-True ($data.summary.sessions -eq 2) 'main transcript and subagent were not counted as separate sessions'
    Assert-True (@($data.totals).Count -eq 3) 'totals omit one or more of the three models'
    $fable = @($data.totals) | Where-Object model -eq 'claude-fable-5-1'
    $opus = @($data.totals) | Where-Object model -eq 'claude-opus-5'
    Assert-True ($fable.calls -eq 1) 'duplicate Fable stream record was not removed'
    Assert-True ($fable.cacheReadM -eq 0.3) 'Fable cache reads did not round to 0.3M'
    Assert-True ($opus.calls -eq 2) 'incorrect Opus call count'
    Assert-True (@($data.totals | Where-Object model -eq '<synthetic>').Count -eq 0) 'synthetic record counted as a model or provider'
    Assert-True (@($data.sessions)[0].maxCtxK -eq 250) 'incorrect peak session context'
    Assert-True ($data.summary.over200k -eq 1) 'session above 200k was not counted'
    $mainSession = @($data.sessions) | Where-Object identity -eq 'p1/s1.jsonl'
    $subagentSession = @($data.sessions) | Where-Object identity -eq 'p1/subagents/agent-a.jsonl'
    Assert-True ($mainSession.model -eq 'mixed' -and @($mainSession.models).Count -eq 2) 'multi-model session was not marked mixed'
    Assert-True ($mainSession.calls -eq 3) 'synthetic record counted as a session call'
    Assert-True ($data.metadata.coverage.syntheticRecords -eq 1 -and $data.metadata.coverage.includedCalls -eq 4) 'coverage did not separate synthetic records from provider calls'
    Assert-True ($subagentSession.model -eq 'claude-haiku-5' -and $subagentSession.sessionId -eq 'parent-1') 'incorrect subagent identity or model'
    Assert-True (-not $jsonRun.Output.Contains('DO-NOT-PRINT-THIS')) 'usage report printed raw transcript content'

    # Explicit ISO bounds are deterministic, date-only values are UTC, and end is exclusive.
    $boundedRoot = Join-Path $work 'bounded-projects'
    $boundedProject = Join-Path $boundedRoot 'p1'
    New-Item -ItemType Directory -Path $boundedProject -Force | Out-Null
    $boundedLines = @(
        @{ uuid = 'b0'; timestamp = '2026-09-13T00:00:00.000Z'; message = @{ id = 'b0'; model = 'claude-opus-5'; usage = @{ input_tokens = 1; output_tokens = 1 } } },
        @{ uuid = 'b1'; timestamp = '2026-09-14T23:59:59.999Z'; message = @{ id = 'b1'; model = 'claude-opus-5'; usage = @{ input_tokens = 1; output_tokens = 1 } } },
        @{ uuid = 'b2'; timestamp = '2026-09-15T00:00:00.000Z'; message = @{ id = 'b2'; model = 'claude-opus-5'; usage = @{ input_tokens = 1; output_tokens = 1 } } }
    ) | ForEach-Object { $_ | ConvertTo-Json -Depth 5 -Compress }
    Set-Content -LiteralPath (Join-Path $boundedProject 'bounded.jsonl') -Value $boundedLines -Encoding utf8
    $boundedRun = Invoke-Usage @('--root', $boundedRoot, '--since', '2026-09-13', '--until', '2026-09-15', '--json')
    Assert-True ($boundedRun.ExitCode -eq 0) "usage report failed with date bounds: $($boundedRun.Output)"
    $bounded = $boundedRun.Output | ConvertFrom-Json
    $boundedOpus = @($bounded.totals) | Where-Object model -eq 'claude-opus-5'
    Assert-True ($boundedOpus.calls -eq 2) 'bounds did not include the start or exclude the end'
    $boundedSince = ([datetimeoffset]$bounded.metadata.bounds.since).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    $boundedUntil = ([datetimeoffset]$bounded.metadata.bounds.until).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    Assert-True ($boundedSince -eq '2026-09-13T00:00:00.000Z' -and $boundedUntil -eq '2026-09-15T00:00:00.000Z') 'date-only bounds were not normalized to UTC in metadata'
    Assert-True ($bounded.metadata.bounds.endExclusive -eq $true) 'metadata did not mark the end exclusive'
    Assert-True ($bounded.metadata.coverage.transcriptFiles -eq 1) 'coverage omitted the analyzed transcripts'
    Assert-True ($bounded.metadata.note -match 'not subscription percentages') 'metadata did not distinguish metrics from subscription quota'

    foreach ($validBound in @('2024-02-29T12:00:00Z', '2026-01-01T00:30:00+14:00')) {
        $valid = Invoke-Usage @('--root', $boundedRoot, '--since', '2024-01-01T00:00:00Z', '--until', $validBound, '--json')
        Assert-True ($valid.ExitCode -eq 0) "valid ISO timestamp was refused: $validBound"
    }

    foreach ($invalidArgs in @(
            @('--root', (Join-Path $work 'missing'), '--days', '1', '--json'),
            @('--root', (Join-Path $work 'projects'), '--since', 'not-a-date', '--json'),
            @('--root', (Join-Path $work 'projects'), '--since', '2026-02-30T00:00:00Z', '--until', '2026-03-05T00:00:00Z', '--json'),
            @('--root', (Join-Path $work 'projects'), '--since', '2025-02-29T00:00:00+01:00', '--until', '2026-03-05T00:00:00Z', '--json'),
            @('--root', (Join-Path $work 'projects'), '--since', '2026-09-15', '--until', '2026-09-15', '--json'),
            @('--root', (Join-Path $work 'projects'), '--since', '2026-09-13', '--hours', '5', '--json')
        )) {
        $invalid = Invoke-Usage $invalidArgs
        Assert-True ($invalid.ExitCode -ne 0) "invalid usage argument accepted: $($invalidArgs -join ' ')"
    }
    # --hours N is the rolling quota-window lens: only calls inside the last N hours count.
    $hoursRun = Invoke-Usage @('--root', (Join-Path $work 'projects'), '--hours', '1', '--json')
    Assert-True ($hoursRun.ExitCode -eq 0) "usage report failed with --hours: $($hoursRun.Output)"
    $hoursData = $hoursRun.Output | ConvertFrom-Json
    $opusHour = @($hoursData.totals) | Where-Object model -eq 'claude-opus-5'
    Assert-True ($opusHour.calls -eq 1) '--hours 1 counted the Opus call from three hours ago'
    Assert-True ((@($hoursData.totals) | Where-Object model -eq 'claude-fable-5-1').calls -eq 1) '--hours 1 missed the recent Fable call'

    $textRun = Invoke-Usage @('--root', (Join-Path $work 'projects'), '--days', '7')
    Assert-True ($textRun.ExitCode -eq 0) 'usage report failed in text mode'
    Assert-True ($textRun.Output.Contains('TOTAL BY MODEL')) 'missing TOTAL BY MODEL table'

    # The Claude Code shell sets FORCE_COLOR: the text tables must stay plain
    # ASCII, because ANSI codes and box drawing are unreadable in this console.
    $previousForceColor = $env:FORCE_COLOR
    try {
        $env:FORCE_COLOR = '1'
        $colorRun = Invoke-Usage @('--root', (Join-Path $work 'projects'), '--days', '7')
    }
    finally {
        if ($null -eq $previousForceColor) { Remove-Item Env:FORCE_COLOR -ErrorAction SilentlyContinue }
        else { $env:FORCE_COLOR = $previousForceColor }
    }
    Assert-True ($colorRun.ExitCode -eq 0) 'usage report failed in text mode with FORCE_COLOR'
    Assert-True (-not $colorRun.Output.Contains([char]0x1b + '[')) 'text output contained ANSI sequences'
    Assert-True (-not $colorRun.Output.Contains([char]0x250c)) 'text output contained box-drawing characters'
    Assert-True ($colorRun.Output -match '(?m)^\s*model\s+.*\bcalls\b') 'table header omitted model and calls'
    Assert-True ($colorRun.Output.Contains('SUMMARY:')) 'SUMMARY line was missing'
}
catch {
    $failures.Add($_.Exception.Message)
}
finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Error $_ -ErrorAction Continue }
    exit 1
}

Write-Output "usage tests: PASS ($assertions assertions)"
