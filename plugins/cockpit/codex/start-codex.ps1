# Leave Codex's options out of PowerShell's parameter binder (-c is otherwise
# ambiguous with CodexHome/CodexExe). Only leading wrapper options are consumed.
$CodexExe = $null
$CodexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
$headless = $false
$offset = 0
while ($offset -lt $args.Count) {
    if ($args[$offset] -eq '-CockpitHeadless') { $headless=$true; $offset++; continue }
    if ($args[$offset] -notin '-CodexExe','-CodexHome') { break }
    if ($offset + 1 -ge $args.Count) { throw 'Missing wrapper option value' }
    if ($args[$offset] -eq '-CodexExe') { $CodexExe=[string]$args[$offset+1] } else { $CodexHome=[string]$args[$offset+1] }
    $offset += 2
}
$CodexArguments = @($args | Select-Object -Skip $offset)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'StartCommon.ps1')
if (-not $CodexExe) { $CodexExe = (Get-Command codex.exe -CommandType Application -TotalCount 1 -ErrorAction Stop).Source }
if ($headless -or $MyInvocation.PipelineLength -gt 1 -or $MyInvocation.ExpectingInput -or -not (Test-CockpitInteractive $CodexArguments (-not [Console]::IsInputRedirected) (-not [Console]::IsOutputRedirected))) {
    $parentScope = $env:CODEX_COCKPIT_SCOPE
    try {
        $env:CODEX_COCKPIT_SCOPE = $null
        if ($MyInvocation.ExpectingInput) { $input | & $CodexExe @CodexArguments } else { & $CodexExe @CodexArguments }
        $headlessExit = $LASTEXITCODE
    } finally { $env:CODEX_COCKPIT_SCOPE = $parentScope }
    exit $headlessExit
}
$stateRoot = Join-Path $CodexHome 'cockpit'
$install = Get-Content -Raw -LiteralPath (Join-Path $stateRoot 'install.json') | ConvertFrom-Json
$pipelineHome_ = if ($env:PIPELINE_HOME) { $env:PIPELINE_HOME } else { $install.pipelineHome }
$sync = Join-Path $stateRoot 'pipeline/bin/setup-codex-home.ps1'
try {
    & pwsh -NoProfile -File $sync -SyncSkillsOnly -CodexHome $CodexHome -ClaudeHome $install.claudeHome -AgentsSkills $install.agentsSkills
    if ($LASTEXITCODE -ne 0) { Write-Warning 'Skill refresh failed; existing discovery retained.' }
} catch { Write-Warning 'Skill refresh unavailable; existing discovery retained.' }
$cwd_ = Get-CockpitWorkingDirectory $CodexArguments (Get-Location).Path
$suppression = @(Get-CockpitSkillSuppression $cwd_ $install.claudeHome @((Join-Path $CodexHome 'skills'),$install.agentsSkills,(Join-Path $CodexHome 'plugins/cache')))
if ($suppression.Count -and (Test-Path -LiteralPath (Join-Path $CodexHome 'config.toml'))) {
    $configText_ = [IO.File]::ReadAllText((Join-Path $CodexHome 'config.toml'))
    if ($configText_ -match '(?m)^\s*(?:\[\[?skills(?:\.|\])|skills\.config\s*=)') {
        Write-Warning 'Existing native skills configuration takes precedence; automatic harness suppression was not applied.'
        $suppression = @()
    }
    $configText_ = $null
}
$scopeFile = $null
$oldScope = $env:CODEX_COCKPIT_SCOPE
$codexExit = 1
try {
    $terminal = Get-Command wt.exe -CommandType Application -TotalCount 1 -ErrorAction SilentlyContinue
    if ($terminal -and $env:WT_SESSION) {
        $id = [guid]::NewGuid().ToString('N')
        $scopeFile = Join-Path $pipelineHome_ "cockpit/codex/scopes/$id.json"
        [IO.Directory]::CreateDirectory((Split-Path $scopeFile)) | Out-Null
        $scope = @{id=$id;home=(Join-Path $pipelineHome_ 'cockpit/codex');cwd=$cwd_;owner=@{pid=$PID;startedAt=(Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o')};closed=$false}
        $scope | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $scopeFile -Encoding utf8
        $env:CODEX_COCKPIT_SCOPE = $scopeFile
        $info = [Diagnostics.ProcessStartInfo]::new($terminal.Source)
        $info.UseShellExecute = $false; $info.CreateNoWindow = $true
        foreach ($arg in New-CockpitTerminalArguments $install.nodeExe (Join-Path $PSScriptRoot 'dashboard.mjs') $scopeFile $pipelineHome_) { $info.ArgumentList.Add($arg) }
        try {
            $terminalProcess = [Diagnostics.Process]::Start($info)
            if (-not $terminalProcess.WaitForExit(5000) -or $terminalProcess.ExitCode -ne 0) { Write-Warning 'Windows Terminal companion did not confirm startup.' }
            $terminalProcess.Dispose()
        } catch { Write-Warning 'Windows Terminal unavailable; continuing with native Codex.' }
    } else { Write-Verbose 'No Windows Terminal host; use dashboard.mjs --once --offline for monitoring.' }
    & $CodexExe @suppression @CodexArguments
    $codexExit = $LASTEXITCODE
} finally {
    $env:CODEX_COCKPIT_SCOPE = $oldScope
    if ($scopeFile) { $scope.closed=$true; $scope | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $scopeFile -Encoding utf8 }
}
exit $codexExit
