[CmdletBinding()]
param([string]$GateLogPath)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if (-not $GateLogPath -and $IsWindows) {
    # A launcher owns gate.log; keep suite logs beside it without changing launcher code.
    $ancestor = Get-CimInstance Win32_Process -Filter "ProcessId = $PID"
    for ($depth = 0; $depth -lt 5 -and $ancestor.ParentProcessId; $depth++) {
        $ancestor = Get-CimInstance Win32_Process -Filter "ProcessId = $($ancestor.ParentProcessId)"
        if (-not $ancestor) { break }
        if ($ancestor.CommandLine -notmatch '(?:codex-run|claude-run|run-gate)\.ps1') { continue }
        $tokens = @([regex]::Matches($ancestor.CommandLine, '"[^"]*"|''[^'']*''|\S+') | ForEach-Object { $_.Value.Trim('"').Trim("'") })
        foreach ($option in @('-RunDir', '-Brief')) {
            $index = [Array]::IndexOf($tokens, $option)
            if ($index -lt 0 -or $index + 1 -ge $tokens.Count) { continue }
            $directory = $tokens[$index + 1]
            if ($option -eq '-Brief') { $directory = Split-Path $directory -Parent }
            $GateLogPath = Join-Path $directory 'gate.log'
            break
        }
        if ($GateLogPath) { break }
    }
}
if (-not $GateLogPath) {
    $GateLogPath = Join-Path ([IO.Path]::GetTempPath()) ('pipeline-run-all\' + [guid]::NewGuid() + '\gate.log')
}
$GateLogPath = [IO.Path]::GetFullPath($GateLogPath)
$logDir = Split-Path $GateLogPath -Parent
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$suites = @('test-pipeline-skill.ps1', 'test-codex-run.ps1', 'test-claude-run.ps1', 'test-brief-paths.ps1', 'test-brief-devices.ps1', 'test-executor-guard.ps1', 'test-new-brief.ps1', 'test-launcher-deadline.ps1', 'test-launcher-jobs.ps1', 'test-usage.ps1', 'test-context-audit.ps1', 'test-run-gate.ps1', 'test-retro-scan.js', 'test-agent-setup.ps1', 'test-executor-capabilities.ps1', 'test-run-logged.js', 'test-task-usage.js', 'test-portability.ps1', 'test-tool-fallbacks.ps1', 'test-quota-cache.ps1', '..\skills\pipeline\scripts\test-watch-pr.ps1')
$running = [Collections.Generic.List[object]]::new()
$summary = [Collections.Generic.List[string]]::new()
$wall = [Diagnostics.Stopwatch]::StartNew()
$failed = $false
try {
    foreach ($suite in $suites) {
        $info = [Diagnostics.ProcessStartInfo]::new()
        $info.FileName = if ($suite.EndsWith('.js')) { 'node' } else { 'pwsh' }
        if ($info.FileName -eq 'pwsh') {
            foreach ($argument in @('-NoProfile', '-File')) { $info.ArgumentList.Add($argument) }
        }
        $info.ArgumentList.Add((Join-Path $PSScriptRoot $suite))
        $info.WorkingDirectory = $root
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        $info.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
        $info.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
        $process = [Diagnostics.Process]::new()
        $process.StartInfo = $info
        $timer = [Diagnostics.Stopwatch]::StartNew()
        [void]$process.Start()
        $running.Add([pscustomobject]@{ Suite = $suite; Process = $process; Timer = $timer; Out = $process.StandardOutput.ReadToEndAsync(); Err = $process.StandardError.ReadToEndAsync() })
    }
    while ($running.Count) {
        foreach ($item in @($running.ToArray())) {
            if (-not $item.Process.HasExited) { continue }
            $item.Timer.Stop()
            $output = $item.Out.GetAwaiter().GetResult() + $item.Err.GetAwaiter().GetResult()
            $log = Join-Path $logDir ([IO.Path]::GetFileNameWithoutExtension($item.Suite) + '.log')
            [IO.File]::WriteAllText($log, $output, [Text.UTF8Encoding]::new($false))
            $match = [regex]::Match($output, 'PASS \((\d+) assertions\)')
            if (-not $match.Success -and $item.Suite.EndsWith('.js')) { $match = [regex]::Match($output, '(?m)^(?:#|ℹ) pass (\d+)\s*$') }
            if (-not $match.Success -and $item.Suite.EndsWith('test-watch-pr.ps1')) { $match = [regex]::Match($output, 'cases (\d+), passed \d+, failed 0') }
            $count = if ($match.Success) { [int]$match.Groups[1].Value } else { 0 }
            $code = $item.Process.ExitCode
            if ($code -ne 0 -or -not $match.Success) { $failed = $true }
            $line = '{0}: exit {1}, {2} assertions, {3:N2}s; log: {4}' -f $item.Suite, $code, $count, $item.Timer.Elapsed.TotalSeconds, $log
            $summary.Add($line)
            Write-Output $line
            $item.Process.Dispose()
            [void]$running.Remove($item)
        }
        if ($running.Count) { Start-Sleep -Milliseconds 100 }
    }
}
finally {
    foreach ($item in $running) {
        if (-not $item.Process.HasExited) { $item.Process.Kill($true); $item.Process.WaitForExit() }
        $item.Process.Dispose()
    }
    $wall.Stop()
    $line = 'run-all: {0} suites, {1:N2}s wall; gate log: {2}' -f $suites.Count, $wall.Elapsed.TotalSeconds, $GateLogPath
    $summary.Add($line)
    [IO.File]::WriteAllLines($GateLogPath, $summary, [Text.UTF8Encoding]::new($false))
    Write-Output $line
}
if ($failed) { exit 1 }
exit 0
