$ErrorActionPreference = 'Stop'
$source = (Resolve-Path (Join-Path $PSScriptRoot '..\skills\pipeline')).Path
$work = Join-Path ([IO.Path]::GetTempPath()) ('pipeline-tools-' + [guid]::NewGuid())
$skill = Join-Path $work 'skill'
$oldPath = $env:PATH
$assertions = 0
function Assert-True([bool]$Condition, [string]$Message) {
    $script:assertions++
    if (-not $Condition) { throw $Message }
}
try {
    New-Item -ItemType Directory -Force -Path $work | Out-Null
    Copy-Item -LiteralPath $source -Destination $skill -Recurse
    . (Join-Path $PSScriptRoot 'TestSupport.ps1')
    $registry = Initialize-TestRegistry $skill
    $bin = Join-Path $work 'bin'
    New-Item -ItemType Directory -Force -Path $bin | Out-Null
    @'
@echo off
if "%~1"=="auth" (
  echo {"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty"}
  exit /b 0
)
echo {"type":"result","is_error":false,"result":"STATUS: ready_for_review","session_id":"fixture-claude","num_turns":1,"usage":{"cache_read_input_tokens":1000},"permission_denials":[]}
exit /b 0
'@ | Set-Content (Join-Path $bin 'claude.cmd') -Encoding ascii
    $gitBin = Split-Path (Get-Command git -TotalCount 1).Source -Parent
    $env:PATH = "$bin;$env:SystemRoot\System32;$PSHOME;$gitBin"
    . (Join-Path $skill 'bin\RunCommon.ps1')
    Assert-True (-not (Get-Command codex -ErrorAction SilentlyContinue) -and -not (Get-Command codeburn -ErrorAction SilentlyContinue)) 'fixture must omit optional tools'
    $quotaDir = Join-Path $skill 'logs\quota'
    New-Item -ItemType Directory -Force -Path $quotaDir | Out-Null
    @{ fetchedAtUtc = [datetime]::UtcNow.ToString('o'); quota = @{ providers = @(@{ id = 'claude'; available = $true; windows = @(@{ usedPct = 99 }) }) } } | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $quotaDir 'last-good.json')
    Assert-True ((Test-QuotaGate 'claude' 85 1 '' $quotaDir) -eq 'skipped: codeburn is not on PATH') 'absent codeburn must skip even an old quota cache'
    $brief = Join-Path $work 'brief.md'
    Set-Content $brief '# Fixture brief'
    $run = Join-Path $work 'run'
    $output = & pwsh -NoProfile -File (Join-Path $skill 'bin\codex-run.ps1') -Repo sample-app -Brief $brief -RunDir $run -ReasoningEffort high -GateCommand none 2>&1 | Out-String
    $code = $LASTEXITCODE
    Assert-True ($code -eq 0 -and $output.Contains('Codex is not on PATH') -and $output.Contains('codeburn is not on PATH')) "fallback failed: $output"
    $meta = Get-Content -Raw (Join-Path $run 'meta.json') | ConvertFrom-Json
    Assert-True ($meta.model -eq 'claude-opus-5-5' -and $meta.effort -eq 'high' -and $meta.repoPath -eq $registry.executors.'sample-app'.repo -and $meta.auth.verified) 'fallback lost identity or guards'
    Assert-True ((Get-Content -Raw (Join-Path $run 'report.md')).Contains('ready_for_review')) 'fallback report missing'
    $dry = & pwsh -NoProfile -File (Join-Path $skill 'bin\codex-run.ps1') -Repo sample-app -Brief $brief -GateCommand none -DryRun 2>&1 | Out-String
    Assert-True ($LASTEXITCODE -eq 0 -and $dry.Contains('--model claude-sonnet-5-5') -and $dry.Contains('--agent pipeline:implementer') -and $dry.Contains('--plugin-dir')) 'dry fallback must select the namespaced plugin agent'
    Set-Content $brief 'Executor: codex `gpt-6.2-sol`; effort `high`.'
    $briefFallback = & pwsh -NoProfile -File (Join-Path $skill 'bin\codex-run.ps1') -Repo sample-app -Brief $brief -GateCommand none -DryRun 2>&1 | Out-String
    Assert-True ($LASTEXITCODE -eq 0 -and $briefFallback.Contains('--model claude-opus-5-5') -and $briefFallback.Contains('--effort high')) 'provider fallback lost the brief effort'
    Set-Content $brief '# Fixture brief'
    $resume = & pwsh -NoProfile -File (Join-Path $skill 'bin\codex-run.ps1') -Repo sample-app -Brief $brief -Resume fixture-codex -FixLoop 1 -DryRun 2>&1 | Out-String
    Assert-True ($LASTEXITCODE -eq 3 -and $resume.Contains('cannot resume through Claude')) 'Codex resume must not change provider'
    $fix = & pwsh -NoProfile -File (Join-Path $skill 'bin\codex-run.ps1') -Repo sample-app -Brief $brief -FixLoop 1 -DryRun 2>&1 | Out-String
    Assert-True ($LASTEXITCODE -ne 0 -and $fix.Contains('FixLoop')) 'fallback must preserve fix-loop validation'
    $newBrief = & pwsh -NoProfile -File (Join-Path $skill 'bin\new-brief.ps1') -Repo sample-app -Topic fallback -Risk HIGH -Model gpt-6.2-sol -DryRun 2>&1 | Out-String
    Assert-True ($LASTEXITCODE -eq 0 -and $newBrief.Contains('Executor: claude `claude-opus-5-5`')) 'brief must follow the available provider'
    $claude = & pwsh -NoProfile -File (Join-Path $skill 'bin\claude-run.ps1') -Repo sample-app -Brief $brief -RunDir (Join-Path $work 'claude-run') -GateCommand none 2>&1 | Out-String
    Assert-True ($LASTEXITCODE -eq 0 -and $claude.Contains('codeburn is not on PATH')) 'Claude must warn and run without codeburn'
    $setup = & pwsh -NoProfile -File (Join-Path $skill 'bin\setup-codex-home.ps1') -CodexHome (Join-Path $work 'fresh-codex') -ClaudeHome (Join-Path $work 'fresh-claude') 2>&1 | Out-String
    Assert-True ($LASTEXITCODE -eq 0 -and $setup.Contains('Python unavailable')) 'Codex setup must work without Python'
    $registry.defaults.PSObject.Properties.Remove('githubAccounts')
    $registry | ConvertTo-Json -Depth 12 | Set-Content (Join-Path $skill 'config\executors.json')
    $ghLog = Join-Path $work 'gh.log'
    @"
@echo off
echo %*>>"$ghLog"
echo {"number":234,"url":"https://github.com/fixture-team/SampleApp/issues/234","body":"- [ ] Fixture acceptance"}
exit /b 0
"@ | Set-Content (Join-Path $bin 'gh.cmd') -Encoding ascii
    $issue = & pwsh -NoProfile -File (Join-Path $skill 'bin\new-brief.ps1') -Repo sample-app -Topic optional-account -Issue 234 -RunDir (Join-Path $work 'issue-run') 2>&1 | Out-String
    Assert-True ($LASTEXITCODE -eq 0 -and (Get-Content -Raw (Join-Path $work 'issue-run\brief.md')).Contains('- Fixture acceptance')) "issue with optional account failed: $issue"
    Assert-True (@(Get-Content $ghLog).Count -eq 1 -and (Get-Content -Raw $ghLog).StartsWith('issue view')) 'unset account must use current auth without token selection'
    Write-Output "tool fallback tests: PASS ($assertions assertions)"
}
finally {
    $env:PATH = $oldPath
    if ([IO.Path]::GetFullPath($work).StartsWith([IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
}
