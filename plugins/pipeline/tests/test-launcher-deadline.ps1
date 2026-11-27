$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\skills\pipeline\bin\RunCommon.ps1')
$assertions = 0
foreach ($case in @(@(30, 10), @(110, 16.5), @(0.5, 10))) {
    $launch = [datetimeoffset]::Parse('2026-10-08T23:50:00+02:00')
    $times = Get-ExecutorDeadline $case[0] $launch
    $deadline = [datetimeoffset]::Parse($times.DeadlineLocal)
    $reportBy = [datetimeoffset]::Parse($times.ReportByLocal)
    if (($deadline - $launch).TotalMinutes -ne $case[0]) { throw 'deadline does not match launch plus timeout' }
    $assertions++
    if (($deadline - $reportBy).TotalMinutes -ne $case[1]) { throw 'report reserve does not match max(10, 15%)' }
    $assertions++
    if (-not $times.Header.Contains($deadline.ToString('HH:mm')) -or -not $times.Header.Contains($reportBy.ToString('HH:mm'))) { throw 'header differs from metadata times' }
    $assertions++
}
Write-Output "launcher-deadline tests: PASS ($assertions assertions)"
