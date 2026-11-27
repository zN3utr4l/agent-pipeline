[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Repo,

    [Parameter(Mandatory = $true)]
    [string]$RunDir,

    $GateCommand,

    [ValidateRange(0.001, 1440)]
    [double]$TimeoutMinutes = 20
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# The executor's full gate: the registry fullGate through the launcher's own gate
# code, recorded as owner "executor" with a source fingerprint, so the launcher
# reuses a matching untimed green or red gate.json instead of running the suite again.
. (Join-Path $PSScriptRoot 'RunCommon.ps1')
$SkillRoot = Get-PipelineSkillRoot
$HubRoot = Get-PipelineHome
$repoInfo = Resolve-ExecutorTarget $HubRoot $Repo
$command = Get-GateCommand $repoInfo.Entry $GateCommand $PSBoundParameters.ContainsKey('GateCommand') $RunDir
if (-not (Test-GateEnabled $command)) {
    throw "no full gate for '$($repoInfo.Alias)': pass -GateCommand or set commands.fullGate in config\executors.json"
}
$TimeoutMinutes = Get-GateTimeoutMinutes $repoInfo.Entry $TimeoutMinutes $PSBoundParameters.ContainsKey('TimeoutMinutes')
$RunDir = [IO.Path]::GetFullPath($RunDir)
New-Item -ItemType Directory -Force -Path $RunDir | Out-Null
# Heavy suites share the machine lock with the launchers; an executor calling this
# from inside its own run already holds it through its launcher, an ancestor process.
$heavyLock = $null
if ($null -ne $repoInfo.Entry -and $null -ne $repoInfo.Entry.PSObject.Properties['heavyGate'] -and $repoInfo.Entry.heavyGate -eq $true) {
    $lockDir = Join-Path $HubRoot 'runs\.locks'
    $heavyLock = Enter-RepoLock $lockDir (Join-Path $HubRoot '.heavy-gate') $RunDir
    if (-not $heavyLock.Acquired) {
        $owner = $heavyLock.State.Owner
        $heavyLock = $null
        if (-not ($owner -and (Test-AncestorProcess ([int]$owner.pid)))) {
            $busyRun = if ($owner) { $owner.runDir } else { 'unknown' }
            $busyPid = if ($owner) { $owner.pid } else { 'unknown' }
            Write-Output "heavy gate busy: another heavy-gate run holds the machine lock (run $busyRun, pid $busyPid)"
            exit 3
        }
    }
}
try {
    $result = Invoke-PostRunGate $command $repoInfo.Path $RunDir $TimeoutMinutes 'executor' (Get-GateFailurePattern $repoInfo.Entry) (Get-GateRetries $repoInfo.Entry (Get-ExecutorRegistry $HubRoot).Defaults)
}
finally {
    if ($null -ne $heavyLock) { Exit-RepoLock $heavyLock }
}
Write-Output "run-gate: exit $($result.exitCode) | timedOut $($result.timedOut) | $($result.durationSeconds)s | failures $(@($result.failures).Count) | $(Join-Path $RunDir 'gate.json')"
foreach ($line in $result.failures) { Write-Output "  $line" }
if ($result.timedOut) { exit 124 }
if ($null -eq $result.exitCode) { exit 1 }
exit $result.exitCode
