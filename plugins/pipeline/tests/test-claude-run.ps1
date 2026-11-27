$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\skills\pipeline')).Path
$script = Join-Path $root 'bin\claude-run.ps1'
$failures = [Collections.Generic.List[string]]::new()
$assertions = 0

function Assert-True([bool]$Condition, [string]$Message) {
    $script:assertions++
    if (-not $Condition) { $failures.Add($Message) }
}

function Invoke-ClaudeRun {
    param([string[]]$Arguments)
    if ('-DryRun' -notin $Arguments -and '-GateCommand' -notin $Arguments -and -not (Test-Path -LiteralPath (Join-Path (Split-Path $Arguments[3]) 'brief.gate.json'))) { $Arguments += @('-GateCommand', 'none') }
    $Arguments += @('-LockDir', (Join-Path $work 'locks'))
    if ('-DryRun' -notin $Arguments) { Remove-Item -LiteralPath (Join-Path $work 'locks\quota\last-good.json') -ErrorAction SilentlyContinue }
    $output = (& pwsh -NoProfile -File $script @Arguments 2>&1 | Out-String)
    return [pscustomobject]@{ Output = $output; ExitCode = $LASTEXITCODE }
}

$work = Join-Path ([IO.Path]::GetTempPath()) ('.test-claude-run-' + [guid]::NewGuid())
$sourceRoot = $root
$root = Join-Path $work 'hub with spaces'
$script = Join-Path $root 'bin\claude-run.ps1'
$fixture = Join-Path $root ('runs\sample-app\zz-test-claude-run-' + [guid]::NewGuid())
$originalPath = $env:PATH
New-Item -ItemType Directory -Path $work, $fixture -Force | Out-Null

try {
    foreach ($directory in @('bin', 'config', 'agents', 'hooks')) {
        New-Item -ItemType Directory -Force -Path (Join-Path $root $directory) | Out-Null
    }
    Get-ChildItem -LiteralPath (Join-Path $sourceRoot 'bin') -File | Where-Object Extension -in @('.ps1', '.js', '.cmd') | Copy-Item -Destination (Join-Path $root 'bin')
    # The lifecycle seam is checked below; CLI fixtures need no repeated Windows interop compilation.
    Add-Content (Join-Path $root 'bin\RunCommon.ps1') 'function Set-RunExecutionState([bool]$Required) { }'
    $usageFixture = Join-Path $root 'bin\task-usage.js'
    $usageText = [IO.File]::ReadAllText($usageFixture).Replace('function codeburnCandidates() {', 'function codeburnCandidates() { return [];')
    [IO.File]::WriteAllText($usageFixture, $usageText, [Text.UTF8Encoding]::new($false))
    . (Join-Path $PSScriptRoot 'TestSupport.ps1')
    $testRegistry = Initialize-TestRegistry $root
    $sampleRepo = $testRegistry.executors.'sample-app'.repo
    foreach ($relative in @('agents\implementer.md', 'hooks\guard-executor-git.ps1')) {
        Copy-Item -LiteralPath (Join-Path $sourceRoot $relative) -Destination (Join-Path $root $relative)
    }
    Assert-True (Test-Path -LiteralPath $script) 'missing bin\claude-run.ps1'
    $brief = Join-Path $work 'brief.md'
    Set-Content -LiteralPath $brief -Value '# Brief' -Encoding utf8
    $fixtureBrief = Join-Path $fixture 'brief.md'
    Copy-Item -LiteralPath $brief -Destination $fixtureBrief

    $fakeBin = Join-Path $work 'bin'
    New-Item -ItemType Directory -Path $fakeBin | Out-Null
    $fake = @'
@echo off
if "%~1"=="auth" (
  if "%FAKE_CLAUDE_AUTH%"=="bad" ( echo {"loggedIn":true,"authMethod":"console","apiProvider":"firstParty"} & exit /b 0 )
  echo {"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty"}
  exit /b 0
)
if not "%FAKE_CLAUDE_SETTINGS_FILE%"=="" node "%~dp0capture-settings.js" %*
echo args: %* 1>&2
if "%FAKE_CLAUDE_FIXTURE%"=="resume" ( node "%~dp0resume-result.js" %* & exit /b )
if "%FAKE_CLAUDE_MODE%"=="noreport" ( echo {"type":"result","is_error":false,"num_turns":1,"session_id":"aaaaaaaa-0000-0000-0000-000000000001","usage":{"cache_read_input_tokens":1000,"output_tokens":10},"permission_denials":[]} & exit /b 0 )
if "%FAKE_CLAUDE_MODE%"=="newreport" ( echo {"type":"result","is_error":false,"result":"# Updated report","num_turns":4,"session_id":"aaaaaaaa-0000-0000-0000-000000000001","usage":{"cache_read_input_tokens":400000},"permission_denials":[]} & exit /b 0 )
echo {"type":"result","is_error":false,"result":"# Report\n\n**Outcome:** done","num_turns":4,"session_id":"aaaaaaaa-0000-0000-0000-000000000001","total_cost_usd":0.5,"usage":{"cache_read_input_tokens":400000,"output_tokens":100},"permission_denials":[],"modelUsage":{"claude-opus-5-5":{}}}
exit /b 0
'@
    Set-Content -LiteralPath (Join-Path $fakeBin 'claude.cmd') -Value $fake -Encoding ascii
    Set-Content -LiteralPath (Join-Path $fakeBin 'resume-result.js') -Encoding ascii -Value @'
const fs = require('node:fs');
const { execFileSync } = require('node:child_process');
const args = process.argv.slice(2);
const git = (...args) => execFileSync('git', args, { stdio: 'pipe' });
switch (process.env.FAKE_CLAUDE_PROGRESS) {
  case 'edit': fs.appendFileSync('source.txt', 'progress\n'); break;
  case 'untracked': fs.writeFileSync('untracked.txt', 'progress\n'); break;
  case 'commit': git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '--allow-empty', '-m', 'progress'); break;
  case 'mode': git('update-index', '--chmod=+x', 'source.txt'); break;
}
const result = process.env.FAKE_CLAUDE_REPLY || '# Report\n\n**Outcome:** done';
fs.writeFileSync(require('node:path').join(args[args.indexOf('--add-dir') + 1], 'report.md'), result);
console.log(JSON.stringify({ type: 'result', is_error: false, result,
  num_turns: 4, usage: { cache_read_input_tokens: 400000 }, permission_denials: [],
  session_id: args[args.indexOf(args.includes('--resume') ? '--resume' : '--session-id') + 1] }));
'@
    Set-Content -LiteralPath (Join-Path $fakeBin 'capture-settings.js') -Encoding ascii -Value "const args = process.argv.slice(2); require('node:fs').writeFileSync(process.env.FAKE_CLAUDE_SETTINGS_FILE, args[args.indexOf('--settings') + 1]);"
    $fakeCodeburn = @'
@echo off
if "%FAKE_CODEBURN_MODE%"=="fail" exit /b 1
if "%FAKE_CODEBURN_PCT%"=="" set FAKE_CODEBURN_PCT=10
if "%FAKE_CODEBURN_PCT_5H%"=="" set FAKE_CODEBURN_PCT_5H=%FAKE_CODEBURN_PCT%
set EXTRA=
REM Real codeburn windows carry only label/usedPct/resetsAt (no model field); a
REM scope is encoded in the label itself as "Weekly \u00b7 <Scope>" (installed
REM main.js decodeClaudeUsage/toWindows). \u00b7 is the literal JSON escape for
REM the middot so this fixture survives the ASCII .cmd encoding unchanged.
if not "%FAKE_CODEBURN_FABLE_PCT%"=="" set EXTRA=%EXTRA%,{"label":"Weekly \u00b7 Fable","usedPct":%FAKE_CODEBURN_FABLE_PCT%,"resetsAt":"2026-09-10T19:59:59.793Z"}
if not "%FAKE_CODEBURN_OPUS_PCT%"=="" set EXTRA=%EXTRA%,{"label":"Weekly \u00b7 Opus","usedPct":%FAKE_CODEBURN_OPUS_PCT%,"resetsAt":"2026-09-10T19:59:59.793Z"}
if not "%FAKE_CODEBURN_SONNET_PCT%"=="" set EXTRA=%EXTRA%,{"label":"Weekly \u00b7 Sonnet","usedPct":%FAKE_CODEBURN_SONNET_PCT%,"resetsAt":"2026-09-10T19:59:59.793Z"}
if not "%FAKE_CODEBURN_HAIKU_PCT%"=="" set EXTRA=%EXTRA%,{"label":"Weekly \u00b7 Haiku","usedPct":%FAKE_CODEBURN_HAIKU_PCT%,"resetsAt":"2026-09-10T19:59:59.793Z"}
if not "%FAKE_CODEBURN_UNKNOWN_PCT%"=="" set EXTRA=%EXTRA%,{"label":"Weekly \u00b7 Beta","usedPct":%FAKE_CODEBURN_UNKNOWN_PCT%,"resetsAt":"2026-09-10T19:59:59.793Z"}
echo {"providers":[{"id":"claude","available":true,"plan":"Max 5x","windows":[{"label":"Weekly","usedPct":%FAKE_CODEBURN_PCT%,"resetsAt":"2026-09-10T19:59:59.793Z"},{"label":"5h","usedPct":%FAKE_CODEBURN_PCT_5H%,"resetsAt":"2026-09-10T19:59:59.793Z"}%EXTRA%]},{"id":"codex","available":true,"windows":[{"label":"Weekly","usedPct":%FAKE_CODEBURN_PCT%,"resetsAt":"2026-09-15T01:32:48.000Z"},{"label":"5h","usedPct":%FAKE_CODEBURN_PCT_5H%,"resetsAt":"2026-09-15T01:32:48.000Z"}]}]}
exit /b 0
'@
    Set-Content -LiteralPath (Join-Path $fakeBin 'codeburn.cmd') -Value $fakeCodeburn -Encoding ascii
    # npm installs a .ps1 shim next to the .cmd one, and pwsh resolves the script
    # first: the gate must still reach the executable shim.
    Set-Content -LiteralPath (Join-Path $fakeBin 'codeburn.ps1') -Value "Write-Output 'not json'`nexit 1" -Encoding ascii
    $env:PATH = "$fakeBin;$env:PATH"

    $dryRunDir = Join-Path $work 'dry-run'
    # Retired explicit/default models and recorded resumes must never launch.
    $policyRegistryPath = Join-Path $root 'config\executors.json'
    $policyRegistryText = [IO.File]::ReadAllText($policyRegistryPath)
    foreach ($retired in @('claude-opus-5', 'claude-sonnet-5', 'unknown-model')) {
        $rejected = Invoke-ClaudeRun @('-Repo', 'sample-app', '-Brief', $brief, '-Model', $retired, '-DryRun')
        Assert-True ($rejected.ExitCode -ne 0 -and $rejected.Output -notmatch '(?m)^command:') "fresh retired model accepted: $retired (exit $($rejected.ExitCode))"
        $policyRegistry = $policyRegistryText | ConvertFrom-Json
        $policyRegistry.defaults.model = $retired
        [IO.File]::WriteAllText($policyRegistryPath, ($policyRegistry | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
        $rejectedDefault = Invoke-ClaudeRun @('-Repo', 'sample-app', '-Brief', $brief, '-DryRun')
        Assert-True ($rejectedDefault.ExitCode -ne 0 -and $rejectedDefault.Output -notmatch '(?m)^command:') "retired registry default accepted: $retired"
        [IO.File]::WriteAllText($policyRegistryPath, $policyRegistryText, [Text.UTF8Encoding]::new($false))
        $policyRun = Join-Path $fixture ('policy-' + $retired)
        New-Item -ItemType Directory -Force -Path $policyRun | Out-Null
        $policyId = [guid]::NewGuid().ToString()
        @{ sessionId = $policyId; model = $retired; reasoningEffort = 'medium'; effort = 'medium' } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $policyRun 'meta.json') -Encoding utf8
        @{ num_turns = 4; usage = @{ cache_read_input_tokens = 400000 } } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $policyRun 'result.json') -Encoding utf8
        foreach ($overrides in @(@(), @('-Model', 'claude-sonnet-5-5', '-Effort', 'medium'))) {
            $rejectedResume = Invoke-ClaudeRun (@('-Repo', 'sample-app', '-Brief', $brief, '-RunDir', $policyRun, '-Resume', $policyId, '-FixLoop', '1', '-DryRun') + $overrides)
            Assert-True ($rejectedResume.ExitCode -eq 3 -and $rejectedResume.Output.Contains($retired) -and $rejectedResume.Output.Contains('fix-<n>.md') -and $rejectedResume.Output -match 'fresh executor.*same run directory' -and $rejectedResume.Output -notmatch '(?m)^command:') "retired resume not clearly refused: $retired (exit $($rejectedResume.ExitCode))"
        }
    }

    $dry = Invoke-ClaudeRun @('-Repo', 'sample-app', '-Brief', $brief, '-RunDir', $dryRunDir, '-DryRun')
    $sidecarRun = Join-Path $work 'sidecar-run'
    $sidecarBrief = Join-Path $sidecarRun 'brief.md'
    $sidecarRepo = Join-Path $root 'sidecar-repo'
    New-Item -ItemType Directory -Path $sidecarRepo | Out-Null
    foreach ($relative in @('templates\brief.md','templates\report.md','vendor\ponytail\AGENTS.md','vendor\ponytail\LICENSE','vendor\ponytail\SOURCE.md')) {
        $destination = Join-Path $root $relative
        New-Item -ItemType Directory -Force -Path (Split-Path $destination) | Out-Null
        Copy-Item -LiteralPath (Join-Path $sourceRoot $relative) -Destination $destination
    }
    $renderOutput = (& pwsh -NoProfile -File (Join-Path $root 'bin\new-brief.ps1') -Repo $sidecarRepo -Topic sidecar -RunDir $sidecarRun -GateCommand 'Write-Output sidecar-gate' 2>&1 | Out-String)
    Assert-True ($LASTEXITCODE -eq 0) "sidecar brief render failed: $renderOutput"
    $sidecarDry = Invoke-ClaudeRun @('-Repo', $sidecarRepo, '-Brief', $sidecarBrief, '-SkipQuotaCheck', '-DryRun')
    Assert-True ($sidecarDry.ExitCode -eq 0 -and $sidecarDry.Output.Contains('gate command: Write-Output sidecar-gate')) "rendered brief gate was lost: $($sidecarDry.Output)"
    Assert-True ($sidecarDry.Output.Contains('gate source: brief.gate.json')) 'sidecar gate source missing'
    $registryDry = Invoke-ClaudeRun @('-Repo', 'sample-app', '-Brief', $sidecarBrief, '-SkipQuotaCheck', '-DryRun')
    Assert-True ($registryDry.ExitCode -eq 0 -and $registryDry.Output.Contains('gate command: Write-Output sidecar-gate')) 'registry gate overrode sidecar'
    foreach ($command in @('Write-Output explicit-gate', 'none')) {
        $overrideDry = Invoke-ClaudeRun @('-Repo', $sidecarRepo, '-Brief', $sidecarBrief, '-GateCommand', $command, '-SkipQuotaCheck', '-DryRun')
        Assert-True ($overrideDry.ExitCode -eq 0 -and $overrideDry.Output.Contains("gate command: $command") -and -not $overrideDry.Output.Contains('gate source: brief.gate.json')) 'explicit gate did not override sidecar'
    }
    Copy-Item -LiteralPath $sidecarBrief -Destination (Join-Path $sidecarRun 'fix-1.md')
    $fixDry = Invoke-ClaudeRun @('-Repo', $sidecarRepo, '-Brief', (Join-Path $sidecarRun 'fix-1.md'), '-SkipQuotaCheck', '-DryRun')
    Assert-True ($fixDry.ExitCode -eq 0 -and $fixDry.Output.Contains('gate command: Write-Output sidecar-gate')) 'fix brief lost sidecar gate'
    foreach ($invalid in @('{', '{}', 'null', '[]', '{"command":7,"owner":"launcher"}', '{"command":"none","owner":"other"}', '{"command":"none","owner":["executor"]}', '{"command":"none"}')) {
        Set-Content -LiteralPath (Join-Path $sidecarRun 'brief.gate.json') -Value $invalid -Encoding utf8
        $invalidDry = Invoke-ClaudeRun @('-Repo', $sidecarRepo, '-Brief', $sidecarBrief, '-SkipQuotaCheck', '-DryRun')
        Assert-True ($invalidDry.ExitCode -eq 3 -and $invalidDry.Output.Contains('brief.gate.json')) "malformed sidecar was not refused: $invalid"
    }
    $explicitDry = Invoke-ClaudeRun @('-Repo', $sidecarRepo, '-Brief', $sidecarBrief, '-GateCommand', 'none', '-SkipQuotaCheck', '-DryRun')
    Assert-True ($explicitDry.ExitCode -eq 0) 'explicit gate did not bypass malformed lower-priority sidecar'
    Remove-Item -LiteralPath (Join-Path $sidecarRun 'brief.gate.json')
    $noneDry = Invoke-ClaudeRun @('-Repo', $sidecarRepo, '-Brief', $sidecarBrief, '-SkipQuotaCheck', '-DryRun')
    Assert-True ($noneDry.ExitCode -eq 0 -and $noneDry.Output.Contains('gate command: none')) 'unregistered target without sidecar did not use none'

    $budget = Invoke-ClaudeRun @('-Repo', 'sample-app', '-Brief', $brief, '-TimeoutMinutes', '95', '-GateTimeoutMinutes', '20', '-GateCommand', 'Write-Output gate', '-SkipQuotaCheck', '-DryRun')
    Assert-True ($budget.ExitCode -eq 0 -and ($budget.Output -notmatch '115-minute background budget')) 'background budget case 95/Write-Output gate/20 failed or blocked launch'
    $budget = Invoke-ClaudeRun @('-Repo', 'sample-app', '-Brief', $brief, '-TimeoutMinutes', '96', '-GateTimeoutMinutes', '20', '-GateCommand', 'Write-Output gate', '-SkipQuotaCheck', '-DryRun')
    Assert-True ($budget.ExitCode -eq 0 -and ($budget.Output.Contains('warning: executor 96 + gate 20 minutes exceeds the 115-minute background budget'))) 'background budget case 96/Write-Output gate/20 failed or blocked launch'
    $budget = Invoke-ClaudeRun @('-Repo', 'sample-app', '-Brief', $brief, '-TimeoutMinutes', '116', '-GateTimeoutMinutes', '20', '-GateCommand', 'none', '-SkipQuotaCheck', '-DryRun')
    Assert-True ($budget.ExitCode -eq 0 -and ($budget.Output.Contains('warning: executor 116 + gate 0 minutes exceeds the 115-minute background budget'))) 'background budget case 116/none/20 failed or blocked launch'
    $budget = Invoke-ClaudeRun @('-Repo', 'sample-app', '-Brief', $brief, '-TimeoutMinutes', '100', '-GateTimeoutMinutes', '50', '-GateCommand', 'none', '-SkipQuotaCheck', '-DryRun')
    Assert-True ($budget.ExitCode -eq 0 -and ($budget.Output -notmatch '115-minute background budget')) 'background budget case 100/none/50 failed or blocked launch'
    $budget = Invoke-ClaudeRun @('-Repo', 'sample-app', '-Brief', $brief, '-TimeoutMinutes', '100', '-GateTimeoutMinutes', '50', '-GateCommand', ' ', '-SkipQuotaCheck', '-DryRun')
    Assert-True ($budget.ExitCode -eq 0 -and ($budget.Output -notmatch '115-minute background budget')) 'background budget case 100/ /50 failed or blocked launch'
    $budget = Invoke-ClaudeRun @('-Repo', 'sample-app', '-Brief', $brief, '-TimeoutMinutes', '100', '-GateTimeoutMinutes', '16', '-GateCommand', 'Write-Output gate', '-SkipQuotaCheck', '-DryRun')
    Assert-True ($budget.ExitCode -eq 0 -and ($budget.Output.Contains('warning: executor 100 + gate 16 minutes exceeds the 115-minute background budget'))) 'background budget case 100/Write-Output gate/16 failed or blocked launch'
    Assert-True ($dry.ExitCode -eq 0) 'Opus dry run failed'
    Assert-True ($dry.Output.Contains('--add-dir') -and $dry.Output.Contains($dryRunDir)) 'Claude run dir not added for writes'
    Assert-True ($dry.Output.Contains('gate command: flutter test --concurrency=3')) 'registry fullGate not selected by default'
    foreach ($text in @('--autocompact 400000', '--max-budget-usd 30', '--effort high', '--agent pipeline:implementer', '--model claude-opus-5-5', '--session-id', '--allowedTools Read,Edit,Write,Glob,Grep,Bash,PowerShell', 'gate: allowed')) {
        Assert-True ($dry.Output.Contains($text)) "dry run missing $text"
    }
    Assert-True (-not (Test-Path -LiteralPath $dryRunDir)) 'dry run created a run directory'

    $dryFixture = Invoke-ClaudeRun @('-Repo', 'sample-app', '-Brief', $fixtureBrief, '-DryRun')
    Assert-True ($dryFixture.ExitCode -eq 0) 'Opus dry run using a brief in the run directory failed'
    Assert-True ($dryFixture.Output -match "(?m)^run dir: $([regex]::Escape($fixture))\s*$") 'brief.md in the run directory did not reuse its parent directory'

    $custom = Invoke-ClaudeRun @('-Repo', 'sample-app', '-Brief', $brief, '-RunDir', (Join-Path $work 'custom'), '-Effort', 'medium', '-AutoCompactTokens', '120000', '-MaxBudgetUsd', '12', '-DryRun')
    Assert-True ($custom.ExitCode -eq 0) 'dry run with custom limits failed'
    Assert-True ($custom.Output.Contains('--effort medium')) 'custom effort was ignored'
    Assert-True ($custom.Output.Contains('--autocompact 120000')) 'custom autocompact setting was ignored'
    Assert-True ($custom.Output.Contains('--max-budget-usd 12')) 'custom budget was ignored'
    $sonnet = Invoke-ClaudeRun @('-Repo', 'sample-app', '-Brief', $brief, '-RunDir', (Join-Path $work 'sonnet'), '-Model', 'claude-sonnet-5-5', '-DryRun')
    Assert-True ($sonnet.ExitCode -eq 0 -and $sonnet.Output.Contains('--model claude-sonnet-5-5')) '-Model claude-sonnet-5-5 was ignored'
    $opus55 = Invoke-ClaudeRun @('-Repo', 'sample-app', '-Brief', $brief, '-RunDir', (Join-Path $work 'opus55'), '-Model', 'claude-opus-5-5', '-DryRun')
    Assert-True ($opus55.ExitCode -eq 0 -and $opus55.Output.Contains('--model claude-opus-5-5')) '-Model claude-opus-5-5 was ignored'
    $sonnet55 = Invoke-ClaudeRun @('-Repo', 'sample-app', '-Brief', $brief, '-RunDir', (Join-Path $work 'sonnet55'), '-Model', 'claude-sonnet-5-5', '-DryRun')
    Assert-True ($sonnet55.ExitCode -eq 0 -and $sonnet55.Output.Contains('--model claude-sonnet-5-5')) '-Model claude-sonnet-5-5 was ignored'
    $haiku = Invoke-ClaudeRun @('-Repo', 'sample-app', '-Brief', $brief, '-RunDir', (Join-Path $work 'haiku'), '-Model', 'claude-haiku-5-5', '-Effort', 'medium', '-DryRun')
    Assert-True ($haiku.ExitCode -eq 0 -and $haiku.Output.Contains('--model claude-haiku-5-5') -and $haiku.Output.Contains('--effort medium')) 'Haiku medium dry run missing model or effort'

    # --- Brief size: the brief is replayed on every executor turn, so a long one is flagged before launch.
    Assert-True (-not $dry.Output.Contains('brief warning:')) 'a short brief was flagged as long'
    $longBrief = Join-Path $work 'long-brief.md'
    Set-Content -LiteralPath $longBrief -Value ('# Brief' + [Environment]::NewLine + ('x' * 6500)) -Encoding utf8
    $long = Invoke-ClaudeRun @('-Repo', 'sample-app', '-Brief', $longBrief, '-RunDir', (Join-Path $work 'long'), '-DryRun')
    Assert-True ($long.ExitCode -eq 0 -and $long.Output -match '(?m)^brief warning: 65\d\d characters, above 6000') 'dry run did not flag a brief longer than briefWarnChars'

    $idA = 'aaaaaaaa-1111-1111-1111-111111111111'
    $idB = 'bbbbbbbb-2222-2222-2222-222222222222'
    $runA = Join-Path $fixture 'a'
    $runB = Join-Path $fixture 'b'
    New-Item -ItemType Directory -Path $runA, $runB | Out-Null
    @{ sessionId = $idA; model = 'claude-opus-5-5'; effort = 'high' } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $runA 'meta.json') -Encoding utf8
    @{ num_turns = 10; usage = @{ cache_read_input_tokens = 3000000 } } | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath (Join-Path $runA 'result.json') -Encoding utf8
    @{ sessionId = $idB; model = 'claude-opus-5-5'; effort = 'high' } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $runB 'meta.json') -Encoding utf8
    @{ num_turns = 10; usage = @{ cache_read_input_tokens = 1000000 } } | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath (Join-Path $runB 'result.json') -Encoding utf8

    $idC = 'cccccccc-4444-4444-4444-444444444444'
    $runC = Join-Path $fixture 'c'
    New-Item -ItemType Directory -Path $runC | Out-Null
    @{ sessionId = $idC; model = 'claude-sonnet-5-5'; effort = 'medium' } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $runC 'meta.json') -Encoding utf8
    @{ num_turns = 10; usage = @{ cache_read_input_tokens = 1000000 } } | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath (Join-Path $runC 'result.json') -Encoding utf8
    $idSonnet55 = 'eeeeeeee-6666-6666-6666-666666666666'
    $runSonnet55 = Join-Path $fixture 'sonnet55'
    New-Item -ItemType Directory -Path $runSonnet55 | Out-Null
    @{ sessionId = $idSonnet55; model = 'claude-sonnet-5-5'; effort = 'medium' } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $runSonnet55 'meta.json') -Encoding utf8
    @{ num_turns = 10; usage = @{ cache_read_input_tokens = 1000000 } } | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath (Join-Path $runSonnet55 'result.json') -Encoding utf8
    $idHaiku = 'ffffffff-7777-7777-7777-777777777777'
    $runHaiku = Join-Path $fixture 'haiku'
    New-Item -ItemType Directory -Path $runHaiku | Out-Null
    @{ sessionId = $idHaiku; model = 'claude-haiku-5-5'; effort = 'medium' } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $runHaiku 'meta.json') -Encoding utf8
    @{ num_turns = 10; usage = @{ cache_read_input_tokens = 1000000 } } | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath (Join-Path $runHaiku 'result.json') -Encoding utf8

    $idLegacy = 'dddddddd-5555-5555-5555-555555555555'
    $runLegacy = Join-Path $fixture 'legacy'
    New-Item -ItemType Directory -Path $runLegacy | Out-Null
    @{ sessionId = $idLegacy } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $runLegacy 'meta.json') -Encoding utf8
    @{ num_turns = 10; usage = @{ cache_read_input_tokens = 1000000 } } | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath (Join-Path $runLegacy 'result.json') -Encoding utf8

    # --- Resume inheritance: an omitted option inherits the recorded model/effort from the resumed session's meta.json.
    $fixBrief = Join-Path $runC 'fix-1.md'
    Copy-Item -LiteralPath $brief -Destination $fixBrief
    $fixNaming = Invoke-ClaudeRun @('-Repo', 'sample-app', '-Brief', $fixBrief, '-Resume', $idC, '-FixLoop', '1', '-DryRun')
    Assert-True ($fixNaming.ExitCode -eq 0 -and $fixNaming.Output.Contains("run dir: $($runC)-fix1")) 'resume fix brief lost its existing run directory name'
    $explicitFix = Invoke-ClaudeRun @('-Repo', 'sample-app', '-Brief', $fixBrief, '-Resume', $idC, '-FixLoop', '1', '-RunDir', (Join-Path $work 'explicit-fix'), '-DryRun')
    Assert-True ($explicitFix.ExitCode -eq 0 -and $explicitFix.Output.Contains('run dir: ' + (Join-Path $work 'explicit-fix'))) 'explicit resume run directory lost precedence'
    $inheritSonnet = Invoke-ClaudeRun @('-Repo', 'sample-app', '-Brief', $brief, '-Resume', $idC, '-FixLoop', '1', '-DryRun')
    Assert-True ($inheritSonnet.ExitCode -eq 0 -and $inheritSonnet.Output.Contains('--model claude-sonnet-5-5') -and $inheritSonnet.Output.Contains('--effort medium')) 'resume without -Model/-Effort did not inherit recorded Sonnet/medium'
    $inheritSonnet55 = Invoke-ClaudeRun @('-Repo', 'sample-app', '-Brief', $brief, '-Resume', $idSonnet55, '-FixLoop', '1', '-DryRun')
    Assert-True ($inheritSonnet55.ExitCode -eq 0 -and $inheritSonnet55.Output.Contains('--model claude-sonnet-5-5') -and $inheritSonnet55.Output.Contains('--effort medium')) 'resume without -Model/-Effort did not inherit recorded Sonnet 5.5/medium'
    $inheritHaiku = Invoke-ClaudeRun @('-Repo', 'sample-app', '-Brief', $brief, '-Resume', $idHaiku, '-FixLoop', '1', '-DryRun')
    Assert-True ($inheritHaiku.ExitCode -eq 0 -and $inheritHaiku.Output.Contains('--model claude-haiku-5-5') -and $inheritHaiku.Output.Contains('--effort medium')) 'resume did not inherit Haiku/medium'

    # --- Explicit matching value on resume is accepted.
    $matchSonnet = Invoke-ClaudeRun @('-Repo', 'sample-app', '-Brief', $brief, '-Resume', $idC, '-FixLoop', '1', '-Model', 'claude-sonnet-5-5', '-Effort', 'medium', '-DryRun')
    Assert-True ($matchSonnet.ExitCode -eq 0 -and $matchSonnet.Output.Contains('--model claude-sonnet-5-5') -and $matchSonnet.Output.Contains('--effort medium')) 'resume with matching explicit -Model/-Effort was refused'

    # --- Explicit mismatching value on resume is refused: a fresh session is required.
    $mismatchModel = Invoke-ClaudeRun @('-Repo', 'sample-app', '-Brief', $brief, '-Resume', $idC, '-FixLoop', '1', '-Model', 'claude-opus-5-5', '-DryRun')
    Assert-True ($mismatchModel.ExitCode -eq 3 -and $mismatchModel.Output -match 'does not match recorded model claude-sonnet-5-5') 'resume accepted an explicit -Model that differed from the recorded model'
    $mismatchEffort = Invoke-ClaudeRun @('-Repo', 'sample-app', '-Brief', $brief, '-Resume', $idC, '-FixLoop', '1', '-Effort', 'high', '-DryRun')
    Assert-True ($mismatchEffort.ExitCode -eq 3 -and $mismatchEffort.Output -match 'does not match recorded effort medium') 'resume accepted an explicit -Effort that differed from the recorded effort'

    # --- Legacy meta.json with no recorded model/effort: an omitted option is refused, no guessing; an explicit value is accepted.
    $legacyOmitted = Invoke-ClaudeRun @('-Repo', 'sample-app', '-Brief', $brief, '-Resume', $idLegacy, '-FixLoop', '1', '-DryRun')
    Assert-True ($legacyOmitted.ExitCode -eq 3 -and $legacyOmitted.Output -match 'recorded model missing or unsupported') 'resume from legacy metadata without an explicit -Model was accepted'
    $legacyExplicit = Invoke-ClaudeRun @('-Repo', 'sample-app', '-Brief', $brief, '-Resume', $idLegacy, '-FixLoop', '1', '-Model', 'claude-sonnet-5-5', '-Effort', 'xhigh', '-DryRun')
    Assert-True ($legacyExplicit.ExitCode -eq 0 -and $legacyExplicit.Output.Contains('--model claude-sonnet-5-5') -and $legacyExplicit.Output.Contains('--effort xhigh')) 'resume from legacy metadata with explicit -Model/-Effort was refused'

    $noLoop = Invoke-ClaudeRun @('-Repo', 'sample-app', '-Brief', $brief, '-Resume', $idB, '-DryRun')
    Assert-True ($noLoop.ExitCode -ne 0 -and $noLoop.Output -match '-FixLoop is required with -Resume') 'resume accepted without -FixLoop'
    $large = Invoke-ClaudeRun @('-Repo', 'sample-app', '-Brief', $brief, '-Resume', $idA, '-FixLoop', '1', '-DryRun')
    Assert-True ($large.ExitCode -eq 3) 'resume over the limit did not exit 3'
    Assert-True ($large.Output -match 'resume refused: transcript averages 300000 tokens per turn') 'resume refusal omitted the average context size'
    $small = Invoke-ClaudeRun @('-Repo', 'sample-app', '-Brief', $brief, '-Resume', $idB, '-FixLoop', '1', '-DryRun')
    Assert-True ($small.ExitCode -eq 0) 'resume below the limit was refused'
    Assert-True ($small.Output -match 'gate: allowed') 'allowed gate was not printed'
    Assert-True ($small.Output.Contains("--resume $idB")) 'resume ID was not passed to Claude'
    $loop3 = Invoke-ClaudeRun @('-Repo', 'sample-app', '-Brief', $brief, '-Resume', $idB, '-FixLoop', '3', '-DryRun')
    Assert-True ($loop3.ExitCode -eq 3 -and $loop3.Output -match 'fix loop 3 exceeds the cap of 2') 'third fix loop was accepted'
    $loop3ok = Invoke-ClaudeRun @('-Repo', 'sample-app', '-Brief', $brief, '-Resume', $idB, '-FixLoop', '3', '-AllowExtraFixLoop', '-DryRun')
    Assert-True ($loop3ok.ExitCode -eq 0) 'claude-run ignored -AllowExtraFixLoop'
    $unknown = Invoke-ClaudeRun @('-Repo', 'sample-app', '-Brief', $brief, '-Resume', 'cccccccc-3333-3333-3333-333333333333', '-FixLoop', '1', '-DryRun')
    Assert-True ($unknown.ExitCode -eq 3 -and $unknown.Output -match 'no recorded run for session') 'unknown session was accepted'

    Remove-Item Env:FAKE_CLAUDE_MODE -ErrorAction SilentlyContinue
    Remove-Item Env:FAKE_CLAUDE_AUTH -ErrorAction SilentlyContinue

    # --- Quota gate: a provider above the cap costs nothing and refuses with exit 4.
    $env:FAKE_CODEBURN_PCT = '96'
    $runQuota = Join-Path $work 'run-quota'
    $quotaRefused = Invoke-ClaudeRun @('-Repo', 'sample-app', '-Brief', $brief, '-RunDir', $runQuota)
    Assert-True ($quotaRefused.ExitCode -eq 4) 'quota above the cap did not exit 4'
    Assert-True ($quotaRefused.Output -match 'claude-run: refused \| quota gate: claude .*\b96%') 'quota refusal omitted the provider and percentage'
    Assert-True (-not (Test-Path -LiteralPath $runQuota)) 'run directory created after a quota refusal'
    $gateText = (& pwsh -NoProfile -Command ". '$root\bin\RunCommon.ps1'; Test-QuotaGate 'claude' 95 30 '' '$work\direct-quota' 0" 2>&1 | Out-String).Trim()
    Assert-True ($gateText.StartsWith('quota gate: claude Weekly at 96%')) "Test-QuotaGate missed usage above the cap: $gateText"
    $quotaSkipped = Invoke-ClaudeRun @('-Repo', 'sample-app', '-Brief', $brief, '-RunDir', (Join-Path $work 'run-quota-skip'), '-SkipQuotaCheck')
    Assert-True ($quotaSkipped.ExitCode -eq 0) "-SkipQuotaCheck did not bypass the quota check: $($quotaSkipped.Output)"
    # --- No reading, no launch: a blind launch can burn the window, so the gate fails closed unless -SkipQuotaCheck.
    $env:FAKE_CODEBURN_MODE = 'fail'
    $runQuotaFail = Join-Path $work 'run-quota-fail'
    $quotaBroken = Invoke-ClaudeRun @('-Repo', 'sample-app', '-Brief', $brief, '-RunDir', $runQuotaFail)
    Assert-True ($quotaBroken.ExitCode -eq 4) 'unavailable codeburn did not stop launch (gate failed open)'
    Assert-True ($quotaBroken.Output -match 'claude-run: refused \| quota gate: claude gave no reading \(skipped: codeburn quota exited 1\)') 'unavailable codeburn did not trigger a missing-reading refusal'
    Assert-True (-not (Test-Path -LiteralPath $runQuotaFail)) 'run directory created after a missing-reading refusal'
    $brokenSkipped = Invoke-ClaudeRun @('-Repo', 'sample-app', '-Brief', $brief, '-RunDir', (Join-Path $work 'run-quota-fail-skip'), '-SkipQuotaCheck')
    Assert-True ($brokenSkipped.ExitCode -eq 0) '-SkipQuotaCheck did not bypass the gate with a missing reading'
    Remove-Item Env:FAKE_CODEBURN_MODE -ErrorAction SilentlyContinue

    # --- Uniform 85% consumption cap (15% reserve): fresh and resume share one boundary; exactly 85% used is still allowed.
    $env:FAKE_CODEBURN_PCT = '64'
    $freshAt64 = Invoke-ClaudeRun @('-Repo', 'sample-app', '-Brief', $brief, '-RunDir', (Join-Path $work 'run-fresh-64'))
    Assert-True ($freshAt64.ExitCode -eq 0 -and $freshAt64.Output -match '(?m)^quota gate: claude 64% \(cap 85%\)') 'fresh run at 64% was refused below the shared 85% cap'
    $resumeAt64 = Invoke-ClaudeRun @('-Repo', 'sample-app', '-Brief', $brief, '-RunDir', (Join-Path $work 'run-resume-64'), '-Resume', $idB, '-FixLoop', '1')
    Assert-True ($resumeAt64.ExitCode -eq 0 -and $resumeAt64.Output -match '(?m)^quota gate: claude 64% \(cap 85%\)') 'resume at 64% was refused below the shared 85% cap'
    $env:FAKE_CODEBURN_PCT = '84'
    $freshAt84 = Invoke-ClaudeRun @('-Repo', 'sample-app', '-Brief', $brief, '-RunDir', (Join-Path $work 'run-fresh-84'))
    Assert-True ($freshAt84.ExitCode -eq 0 -and $freshAt84.Output -match '(?m)^quota gate: claude 84% \(cap 85%\)') 'fresh run at 84% was refused below the 85% cap'
    $env:FAKE_CODEBURN_PCT = '85'
    $freshAt85 = Invoke-ClaudeRun @('-Repo', 'sample-app', '-Brief', $brief, '-RunDir', (Join-Path $work 'run-fresh-85'))
    Assert-True ($freshAt85.ExitCode -eq 0 -and $freshAt85.Output -match '(?m)^quota gate: claude 85% \(cap 85%\)') 'run was refused at exactly the 85% cap, which should preserve the 15% reserve'
    $env:FAKE_CODEBURN_PCT = '85.1'
    $freshAt851 = Invoke-ClaudeRun @('-Repo', 'sample-app', '-Brief', $brief, '-RunDir', (Join-Path $work 'run-fresh-85-1'))
    Assert-True ($freshAt851.ExitCode -eq 4 -and $freshAt851.Output -match 'quota gate: claude .*85\.1% \(cap 85%\)') 'fresh run at 85.1% was accepted because decimal precision was lost'
    $env:FAKE_CODEBURN_PCT = '86'
    $freshAt86 = Invoke-ClaudeRun @('-Repo', 'sample-app', '-Brief', $brief, '-RunDir', (Join-Path $work 'run-fresh-86'))
    Assert-True ($freshAt86.ExitCode -eq 4) 'fresh run at 86% was accepted'
    $resumeAt86 = Invoke-ClaudeRun @('-Repo', 'sample-app', '-Brief', $brief, '-RunDir', (Join-Path $work 'run-resume-86'), '-Resume', $idB, '-FixLoop', '1')
    Assert-True ($resumeAt86.ExitCode -eq 4) 'resume at 86% was accepted above the shared 85% cap'

    # --- Both windows: a low weekly reading must not hide a high 5-hour reading, or vice versa.
    $env:FAKE_CODEBURN_PCT = '40'

    . (Join-Path $root 'bin\RunCommon.ps1')
    $lockDir = Join-Path $work 'locks'
    New-Item -ItemType Directory -Path $lockDir -Force | Out-Null
    $repoA = Join-Path $work 'repo-a'
    $repoB = Join-Path $work 'repo-b'
    New-Item -ItemType Directory -Path $repoA, $repoB | Out-Null
    $lockPath = Get-RepoLockPath $lockDir $repoA
    $owner = Get-Process -Id $PID
    $held = @{ pid = $PID; processStartTime = $owner.StartTime.ToUniversalTime().ToString('o'); runDir = 'held-run'; repoPath = $repoA; startedAt = [DateTime]::UtcNow.ToString('o') }
    $held | ConvertTo-Json | Set-Content -LiteralPath $lockPath -Encoding utf8
    $dryBusy = Invoke-ClaudeRun @('-Repo', $repoA, '-Brief', $brief, '-DryRun')
    Assert-True ($dryBusy.ExitCode -eq 0 -and $dryBusy.Output -match 'lock: busy' -and (Test-Path -LiteralPath $lockPath)) 'DryRun must show a live lock without taking it'
    $busyDir = Join-Path $work 'busy'
    $busy = Invoke-ClaudeRun @('-Repo', $repoA, '-Brief', $brief, '-RunDir', $busyDir, '-SkipQuotaCheck')
    Assert-True ($busy.ExitCode -eq 3 -and $busy.Output.Contains("repo busy: $repoA (run held-run, pid $PID)")) 'live repository lock did not refuse with exit 3 and owner'
    Assert-True (-not (Test-Path -LiteralPath $busyDir)) 'busy launch created a run directory'
    $other = Invoke-ClaudeRun @('-Repo', $repoB, '-Brief', $brief, '-RunDir', (Join-Path $work 'other'), '-SkipQuotaCheck')
    Assert-True ($other.ExitCode -eq 0 -and (Test-Path -LiteralPath $lockPath)) 'different repository path was blocked or disturbed the held lock'
    $held.processStartTime = [DateTime]::UtcNow.AddDays(-1).ToString('o')
    $held | ConvertTo-Json | Set-Content -LiteralPath $lockPath -Encoding utf8
    $stale = Invoke-ClaudeRun @('-Repo', $repoA, '-Brief', $brief, '-RunDir', (Join-Path $work 'stale'), '-SkipQuotaCheck')
    Assert-True ($stale.ExitCode -eq 0 -and $stale.Output -match 'warning: stale repo lock' -and -not (Test-Path -LiteralPath $lockPath)) 'stale lock was not reclaimed and released'
    $dryFree = Invoke-ClaudeRun @('-Repo', $repoA, '-Brief', $brief, '-DryRun')
    Assert-True ($dryFree.ExitCode -eq 0 -and $dryFree.Output -match 'lock: free' -and -not (Test-Path -LiteralPath $lockPath)) 'DryRun acquired a free lock'

    Test-RetroLauncher 'claude' { param($Arguments) Invoke-ClaudeRun $Arguments }

    $registryPath = Join-Path $root 'config\executors.json'
    $heavyRegistry = Get-Content -Raw $registryPath | ConvertFrom-Json
    $heavyRegistry.executors | Add-Member -NotePropertyName fixture-heavy -NotePropertyValue ([pscustomobject]@{repo=$repoA;heavyGate=$true;gateRetries=0;writableRoots=@();commands=[pscustomobject]@{fullGate='none'}})
    $heavyRegistry | ConvertTo-Json -Depth 10 | Set-Content $registryPath
    $heavyPath = Get-RepoLockPath $lockDir (Join-Path $root '.heavy-gate')
    $held.processStartTime = $owner.StartTime.ToUniversalTime().ToString('o')
    $held.repoPath = $repoB
    $held | ConvertTo-Json | Set-Content $heavyPath
    $heavyDry = Invoke-ClaudeRun @('-Repo', 'fixture-heavy', '-Brief', $brief, '-DryRun')
    Assert-True ($heavyDry.ExitCode -eq 0 -and $heavyDry.Output.Contains('heavy gate lock: busy') -and (Test-Path $heavyPath)) 'heavy dry run acquired or hid the lock'
    $heavyRun = Join-Path $work 'heavy-busy'
    $heavyBusy = Invoke-ClaudeRun @('-Repo', 'fixture-heavy', '-Brief', $brief, '-RunDir', $heavyRun, '-SkipQuotaCheck', '-GateCommand', 'none')
    Assert-True ($heavyBusy.ExitCode -eq 3 -and $heavyBusy.Output.Contains('heavy gate busy:') -and $heavyBusy.Output.Contains('held-run') -and -not (Test-Path $heavyRun)) 'heavy launch did not refuse a different repository owner'
    Assert-True (-not (Test-Path (Get-RepoLockPath $lockDir $repoA))) 'heavy refusal leaked repository lock'
    $nonHeavy = Invoke-ClaudeRun @('-Repo', $repoB, '-Brief', $brief, '-RunDir', (Join-Path $work 'non-heavy'), '-SkipQuotaCheck', '-GateCommand', 'none')
    Assert-True ($nonHeavy.ExitCode -eq 0 -and (Test-Path $heavyPath)) 'non-heavy launch disturbed the heavy lock'
    $held.processStartTime = [DateTime]::UtcNow.AddDays(-1).ToString('o')
    $held | ConvertTo-Json | Set-Content $heavyPath
    $heavyStale = Invoke-ClaudeRun @('-Repo', 'fixture-heavy', '-Brief', $brief, '-RunDir', (Join-Path $work 'heavy-stale'), '-SkipQuotaCheck', '-GateCommand', 'none')
    Assert-True ($heavyStale.ExitCode -eq 0 -and $heavyStale.Output.Contains('stale heavy gate lock taken over') -and -not (Test-Path $heavyPath)) 'stale heavy lock was not reclaimed and released'
    $heavyGateRun = Join-Path $work 'heavy-array-gate'
    New-Item -ItemType Directory -Path $heavyGateRun | Out-Null
    $heavyBrief = Join-Path $heavyGateRun 'brief.md'
    Copy-Item $brief $heavyBrief
    $heavyMarker = Join-Path $work 'heavy-second.txt'
    $heavyCommands = @("if (-not (Test-Path -LiteralPath '$heavyPath')) { exit 98 }; Write-Output 'FAIL first heavy'; exit 7", "Add-Content -LiteralPath '$heavyMarker' -Value ran; Write-Output 'FAIL second heavy'; exit 9")
    @{command=$heavyCommands;owner='launcher'} | ConvertTo-Json | Set-Content (Join-Path $heavyGateRun 'brief.gate.json')
    $heavyArray = Invoke-ClaudeRun @('-Repo', 'fixture-heavy', '-Brief', $heavyBrief, '-RunDir', $heavyGateRun, '-SkipQuotaCheck')
    $heavyGateJson = Get-Content -Raw (Join-Path $heavyGateRun 'gate.json') | ConvertFrom-Json
    Assert-True ($heavyArray.ExitCode -eq 5 -and (Test-Path $heavyMarker) -and $heavyGateJson.commands[0].exitCode -eq 7 -and $heavyGateJson.commands[1].exitCode -eq 9) 'launcher did not hold heavy lock through both array commands'
    Assert-True ($heavyGateJson.attempts.Count -eq 1 -and -not (Test-Path $heavyPath) -and -not (Test-Path (Get-RepoLockPath $lockDir $repoA))) 'zero retries ignored or heavy gate failure leaked locks'
    $env:FAKE_CODEBURN_PCT_5H = '90'
    $high5h = Invoke-ClaudeRun @('-Repo', 'sample-app', '-Brief', $brief, '-RunDir', (Join-Path $work 'run-high-5h'))
    Assert-True ($high5h.ExitCode -eq 4 -and $high5h.Output -match 'quota gate: claude .*90%') 'high 5-hour usage with low weekly usage did not block launch'
    $env:FAKE_CODEBURN_PCT = '90'
    $env:FAKE_CODEBURN_PCT_5H = '40'
    $highWeekly = Invoke-ClaudeRun @('-Repo', 'sample-app', '-Brief', $brief, '-RunDir', (Join-Path $work 'run-high-weekly'))
    Assert-True ($highWeekly.ExitCode -eq 4 -and $highWeekly.Output -match 'quota gate: claude .*90%') 'high weekly usage with low 5-hour usage did not block launch'
    Remove-Item Env:FAKE_CODEBURN_PCT_5H -ErrorAction SilentlyContinue
    $env:FAKE_CODEBURN_PCT = '40'

    $commonPath = Join-Path $root 'bin\RunCommon.ps1'
    $commonText = [IO.File]::ReadAllText($commonPath)
    $lockSignature = 'function Enter-RepoLock([string]$LockDir, [string]$RepoPath, [string]$RunDir) {'
    [IO.File]::WriteAllText($commonPath, $commonText.Replace($lockSignature, $lockSignature + "`n    if ([IO.Path]::GetFileName(`$RepoPath) -eq '.heavy-gate') { throw 'injected pre-attempt crash' }"))
    try {
        foreach ($existing in @($false, $true)) {
            $earlyRun = Join-Path $work "early-crash-$existing"
            New-Item -ItemType Directory -Path $earlyRun | Out-Null
            $earlyReport = Join-Path $earlyRun 'report.md'
            if ($existing) { Set-Content -LiteralPath $earlyReport -Value 'Previous report' }
            $early = Invoke-ClaudeRun @('-Repo', 'fixture-heavy', '-Brief', $brief, '-RunDir', $earlyRun, '-SkipQuotaCheck', '-GateCommand', 'none')
            Assert-True ($early.ExitCode -eq 1 -and $early.Output.Contains('injected pre-attempt crash') -and $early.Output -notmatch 'attemptStartedAt|has not been set') "pre-attempt crash lost original error: $existing"
            $expectedReport = if ($existing) { '^Previous report\s*$' } else { '(?s)^STATUS: failed.*Cause: crash: launcher error: injected pre-attempt crash' }
            Assert-True ((Test-Path -LiteralPath $earlyReport) -and (Get-Content -Raw -LiteralPath $earlyReport) -match $expectedReport) "pre-attempt crash lost or overwrote report: $existing"
        }
    }
    finally { [IO.File]::WriteAllText($commonPath, $commonText) }

    # --- Model-scoped quota: Fable's usage, and the other Claude model's own window, never block this launch.
    $env:FAKE_CODEBURN_PCT = '56'
    $env:FAKE_CODEBURN_FABLE_PCT = '95'
    $fableIgnoredOpus = Invoke-ClaudeRun @('-Repo', 'sample-app', '-Brief', $brief, '-RunDir', (Join-Path $work 'run-fable-opus'), '-Model', 'claude-opus-5-5')
    Assert-True ($fableIgnoredOpus.ExitCode -eq 0 -and $fableIgnoredOpus.Output -match '(?m)^quota gate: claude .*56%') 'the Fable window at 95% blocked an Opus launch'
    $fableIgnoredSonnet = Invoke-ClaudeRun @('-Repo', 'sample-app', '-Brief', $brief, '-RunDir', (Join-Path $work 'run-fable-sonnet'), '-Model', 'claude-sonnet-5-5')
    Assert-True ($fableIgnoredSonnet.ExitCode -eq 0 -and $fableIgnoredSonnet.Output -match '(?m)^quota gate: claude .*56%') 'the Fable window at 95% blocked a Sonnet launch'
    Remove-Item Env:FAKE_CODEBURN_FABLE_PCT -ErrorAction SilentlyContinue

    # --- The launched model's own scoped window blocks; the other Claude model's scoped window is ignored.
    $env:FAKE_CODEBURN_OPUS_PCT = '86'
    $ownScopedBlocks = Invoke-ClaudeRun @('-Repo', 'sample-app', '-Brief', $brief, '-RunDir', (Join-Path $work 'run-own-scoped-86'), '-Model', 'claude-opus-5-5')
    Assert-True ($ownScopedBlocks.ExitCode -eq 4 -and $ownScopedBlocks.Output -match 'quota gate: claude .*86%') 'the selected Opus model window at 86% did not block an Opus launch'
    $ownScopedBlocks55 = Invoke-ClaudeRun @('-Repo', 'sample-app', '-Brief', $brief, '-RunDir', (Join-Path $work 'run-own-scoped-86-55'), '-Model', 'claude-opus-5-5')
    Assert-True ($ownScopedBlocks55.ExitCode -eq 4 -and $ownScopedBlocks55.Output -match 'quota gate: claude .*86%') 'the Opus window at 86% did not block an Opus 5.5 launch'
    $otherScopedIgnored = Invoke-ClaudeRun @('-Repo', 'sample-app', '-Brief', $brief, '-RunDir', (Join-Path $work 'run-other-scoped-86'), '-Model', 'claude-sonnet-5-5')
    Assert-True ($otherScopedIgnored.ExitCode -eq 0 -and $otherScopedIgnored.Output -match '(?m)^quota gate: claude .*56%') 'the Opus window at 86% blocked a Sonnet launch'
    $otherScopedIgnored55 = Invoke-ClaudeRun @('-Repo', 'sample-app', '-Brief', $brief, '-RunDir', (Join-Path $work 'run-other-scoped-86-sonnet55'), '-Model', 'claude-sonnet-5-5')
    Assert-True ($otherScopedIgnored55.ExitCode -eq 0 -and $otherScopedIgnored55.Output -match '(?m)^quota gate: claude .*56%') 'the Opus window at 86% blocked a Sonnet 5.5 launch'
    Remove-Item Env:FAKE_CODEBURN_OPUS_PCT -ErrorAction SilentlyContinue

    # --- Boundary on the launched model's own scoped window: exactly 85% still allowed, 85.1% blocked.
    $env:FAKE_CODEBURN_OPUS_PCT = '85'
    $ownBoundaryAllowed = Invoke-ClaudeRun @('-Repo', 'sample-app', '-Brief', $brief, '-RunDir', (Join-Path $work 'run-own-boundary-85'), '-Model', 'claude-opus-5-5')
    Assert-True ($ownBoundaryAllowed.ExitCode -eq 0 -and $ownBoundaryAllowed.Output -match '(?m)^quota gate: claude .*85%') 'the selected model window blocked launch at exactly the 85% cap, which should preserve the 15% reserve'
    $env:FAKE_CODEBURN_OPUS_PCT = '85.1'
    $ownBoundaryBlocked = Invoke-ClaudeRun @('-Repo', 'sample-app', '-Brief', $brief, '-RunDir', (Join-Path $work 'run-own-boundary-85-1'), '-Model', 'claude-opus-5-5')
    Assert-True ($ownBoundaryBlocked.ExitCode -eq 4 -and $ownBoundaryBlocked.Output -match 'quota gate: claude .*85\.1%') 'the selected model window at 85.1% did not block launch'
    Remove-Item Env:FAKE_CODEBURN_OPUS_PCT -ErrorAction SilentlyContinue

    # --- Inherited-Sonnet quota: a resume that inherits Sonnet (no -Model) is scoped by Sonnet's own window,
    # and Opus's and Fable's scoped windows never block it.
    $env:FAKE_CODEBURN_PCT = '40'
    $env:FAKE_CODEBURN_OPUS_PCT = '95'
    $env:FAKE_CODEBURN_FABLE_PCT = '95'
    $env:FAKE_CODEBURN_SONNET_PCT = '56'
    $sonnet55IgnoresOthers = Invoke-ClaudeRun @('-Repo', 'sample-app', '-Brief', $brief, '-RunDir', (Join-Path $work 'run-sonnet55-scoped-ok'), '-Model', 'claude-sonnet-5-5')
    Assert-True ($sonnet55IgnoresOthers.ExitCode -eq 0 -and $sonnet55IgnoresOthers.Output -match '(?m)^quota gate: claude .*56%') 'Sonnet 5.5 was blocked by the Opus/Fable windows'
    $inheritedSonnetIgnoresOthers = Invoke-ClaudeRun @('-Repo', 'sample-app', '-Brief', $brief, '-RunDir', (Join-Path $work 'run-inherited-sonnet-ok'), '-Resume', $idC, '-FixLoop', '1')
    Assert-True ($inheritedSonnetIgnoresOthers.ExitCode -eq 0 -and $inheritedSonnetIgnoresOthers.Output -match '(?m)^quota gate: claude .*56%') 'resume with inherited Sonnet was blocked by the Opus/Fable windows'
    $env:FAKE_CODEBURN_SONNET_PCT = '86'
    $sonnet55Blocks = Invoke-ClaudeRun @('-Repo', 'sample-app', '-Brief', $brief, '-RunDir', (Join-Path $work 'run-sonnet55-scoped-blocked'), '-Model', 'claude-sonnet-5-5')
    Assert-True ($sonnet55Blocks.ExitCode -eq 4 -and $sonnet55Blocks.Output -match 'quota gate: claude .*86%') 'the Sonnet window at 86% did not block a Sonnet 5.5 launch'
    $inheritedSonnetBlocks = Invoke-ClaudeRun @('-Repo', 'sample-app', '-Brief', $brief, '-RunDir', (Join-Path $work 'run-inherited-sonnet-blocked'), '-Resume', $idC, '-FixLoop', '1')
    Assert-True ($inheritedSonnetBlocks.ExitCode -eq 4 -and $inheritedSonnetBlocks.Output -match 'quota gate: claude .*86%') 'the inherited Sonnet window at 86% did not block a resume'
    Remove-Item Env:FAKE_CODEBURN_OPUS_PCT, Env:FAKE_CODEBURN_FABLE_PCT, Env:FAKE_CODEBURN_SONNET_PCT -ErrorAction SilentlyContinue

    $env:FAKE_CODEBURN_HAIKU_PCT = '86'
    foreach ($model in @('claude-opus-5-5','claude-sonnet-5-5')) {
        $ignoresHaiku = Invoke-ClaudeRun @('-Repo', 'sample-app', '-Brief', $brief, '-RunDir', (Join-Path $work "run-ignore-haiku-$model"), '-Model', $model)
        Assert-True ($ignoresHaiku.ExitCode -eq 0 -and $ignoresHaiku.Output -match '(?m)^quota gate: claude .*40%') "$model blocked by Haiku window"
    }
    $haikuBlocked = Invoke-ClaudeRun @('-Repo', 'sample-app', '-Brief', $brief, '-RunDir', (Join-Path $work 'run-haiku-blocked'), '-Model', 'claude-haiku-5-5')
    Assert-True ($haikuBlocked.ExitCode -eq 4 -and $haikuBlocked.Output -match 'quota gate: claude .*86%') 'Haiku own window did not block at 86%'
    $env:FAKE_CODEBURN_HAIKU_PCT = '85'
    $env:FAKE_CODEBURN_OPUS_PCT = '95'
    $env:FAKE_CODEBURN_SONNET_PCT = '95'
    $env:FAKE_CODEBURN_FABLE_PCT = '95'
    $haikuAllowed = Invoke-ClaudeRun @('-Repo', 'sample-app', '-Brief', $brief, '-RunDir', (Join-Path $work 'run-haiku-allowed'), '-Resume', $idHaiku, '-FixLoop', '1')
    Assert-True ($haikuAllowed.ExitCode -eq 0 -and $haikuAllowed.Output -match '(?m)^quota gate: claude .*85%') 'inherited Haiku blocked at cap or by other model windows'
    Remove-Item Env:FAKE_CODEBURN_OPUS_PCT, Env:FAKE_CODEBURN_FABLE_PCT, Env:FAKE_CODEBURN_SONNET_PCT, Env:FAKE_CODEBURN_HAIKU_PCT -ErrorAction SilentlyContinue

    # --- Common (untagged) windows still block regardless of the selected model.
    $env:FAKE_CODEBURN_PCT = '86'
    $commonWeeklyBlocksScoped = Invoke-ClaudeRun @('-Repo', 'sample-app', '-Brief', $brief, '-RunDir', (Join-Path $work 'run-common-weekly-86'), '-Model', 'claude-opus-5-5')
    Assert-True ($commonWeeklyBlocksScoped.ExitCode -eq 4 -and $commonWeeklyBlocksScoped.Output -match 'quota gate: claude .*86%') 'the shared weekly window at 86% did not block launch with a selected model'
    $commonWeeklyBlocksHaiku = Invoke-ClaudeRun @('-Repo', 'sample-app', '-Brief', $brief, '-RunDir', (Join-Path $work 'run-haiku-common-weekly-86'), '-Model', 'claude-haiku-5-5')
    Assert-True ($commonWeeklyBlocksHaiku.ExitCode -eq 4 -and $commonWeeklyBlocksHaiku.Output -match 'quota gate: claude .*86%') 'common weekly window did not block Haiku'
    $env:FAKE_CODEBURN_PCT = '40'
    $env:FAKE_CODEBURN_PCT_5H = '86'
    $common5hBlocksScoped = Invoke-ClaudeRun @('-Repo', 'sample-app', '-Brief', $brief, '-RunDir', (Join-Path $work 'run-common-5h-86'), '-Model', 'claude-sonnet-5-5')
    Assert-True ($common5hBlocksScoped.ExitCode -eq 4 -and $common5hBlocksScoped.Output -match 'quota gate: claude .*86%') 'the shared 5-hour window at 86% did not block launch with a selected model'
    Remove-Item Env:FAKE_CODEBURN_PCT_5H -ErrorAction SilentlyContinue

    # --- An unrecognised scope is kept conservatively: it still blocks.
    $env:FAKE_CODEBURN_PCT = '40'
    $env:FAKE_CODEBURN_UNKNOWN_PCT = '95'
    $unknownScopeRetained = Invoke-ClaudeRun @('-Repo', 'sample-app', '-Brief', $brief, '-RunDir', (Join-Path $work 'run-unknown-scope-95'), '-Model', 'claude-opus-5-5')
    Assert-True ($unknownScopeRetained.ExitCode -eq 4 -and $unknownScopeRetained.Output -match 'quota gate: claude .*95%') 'the window with unknown scope at 95% did not block launch, so scope was not handled conservatively'
    Remove-Item Env:FAKE_CODEBURN_UNKNOWN_PCT -ErrorAction SilentlyContinue

    # --- Calling Test-QuotaGate without -Model preserves the old behaviour: every window counts, Fable's own included.
    # A distinct 97% (not the 95% used above by any other scoped window) isolates that this reading came from Fable.
    $env:FAKE_CODEBURN_PCT = '40'
    $env:FAKE_CODEBURN_FABLE_PCT = '97'
    $noModelDirect = (& pwsh -NoProfile -Command ". '$root\bin\RunCommon.ps1'; Test-QuotaGate 'claude' 85 30 '' '$work\direct-quota' 0" 2>&1 | Out-String).Trim()
    Assert-True ($noModelDirect -match 'quota gate: claude .*97%') 'Test-QuotaGate without -Model no longer checks the Fable window'
    Remove-Item Env:FAKE_CODEBURN_FABLE_PCT -ErrorAction SilentlyContinue
    $env:FAKE_CODEBURN_PCT = '40'

    $runOk = Join-Path $work 'run-ok'
    $env:FAKE_CLAUDE_SETTINGS_FILE = Join-Path $work 'captured-settings.json'
    $ok = Invoke-ClaudeRun @('-Repo', 'sample-app', '-Brief', $brief, '-RunDir', $runOk)
    Remove-Item Env:FAKE_CLAUDE_SETTINGS_FILE
    Assert-True ($ok.ExitCode -eq 0) "successful fixture Claude run did not exit 0: $($ok.Output.Trim())"
    Assert-True ((Test-Path -LiteralPath (Join-Path $runOk 'task-usage-start.json')) -and (Test-Path -LiteralPath (Join-Path $runOk 'task-usage.json'))) 'automatic task usage artifacts missing'
    Assert-True ($ok.Output -match '(?m)^quota gate: claude .*40%') 'successful run omitted usage below the cap'
    Assert-True ((Get-Content -Raw -LiteralPath (Join-Path $runOk 'report.md')).StartsWith('# Report')) 'result did not produce report.md'
    $metaOk = Get-Content -Raw -LiteralPath (Join-Path $runOk 'meta.json') | ConvertFrom-Json -DateKind String
    Assert-True ($metaOk.lineEndingOnly -is [array] -and $metaOk.lineEndingOnly.Count -eq 0) 'successful Claude run must record an empty lineEndingOnly array'
    $deadline = [datetimeoffset]::Parse($metaOk.deadlineLocal)
    $reportBy = [datetimeoffset]::Parse($metaOk.reportByLocal)
    Assert-True ($metaOk.deadlineLocal -match '[+-]\d{2}:\d{2}$' -and $metaOk.reportByLocal -match '[+-]\d{2}:\d{2}$') 'deadline metadata must include local offsets'
    Assert-True ([Math]::Abs(($deadline - $reportBy).TotalMinutes - 10) -lt 0.001) 'default report reserve must be ten minutes'
    $deadlinePrompt = Get-Content -Raw -LiteralPath (Join-Path $runOk 'executor-prompt.md')
    Assert-True ($deadlinePrompt.Contains('Launcher will stop the executor at ' + $deadline.ToString('HH:mm')) -and $deadlinePrompt.Contains('Stop working and write the final report by ' + $reportBy.ToString('HH:mm'))) 'deadline header differs from metadata'
    Assert-True ($deadlinePrompt.Contains('even if incomplete, listing what is missing')) 'report instruction missing incomplete work requirement'

    Assert-True ($metaOk.repoRoot -eq $sampleRepo -and $metaOk.github -eq 'fixture-team/SampleApp') 'registered repository identity missing in Claude metadata'
    Assert-True ($metaOk.reportPresent -eq $true) 'reportPresent was false for a successful run'
    Assert-True ($metaOk.exitCode -eq 0 -and $metaOk.wrapperExitCode -eq 0) 'incorrect exit codes in metadata'
    Assert-True ($null -eq $metaOk.fixLoop) 'fixLoop was not null for a fresh run'
    Assert-True ($metaOk.autoCompactTokens -eq 400000) 'incorrect autoCompactTokens in metadata'
    Assert-True ($metaOk.maxBudgetUsd -eq 30) 'incorrect maxBudgetUsd in metadata'
    Assert-True ($metaOk.model -eq 'claude-opus-5-5') 'default model missing from metadata'
    Assert-True ($metaOk.numTurns -eq 4 -and $metaOk.contextPerTurn -eq 100000 -and $metaOk.totalCostUsd -eq 0.5) 'turns, context per turn, or cost missing from metadata'
    Assert-True ($metaOk.briefChars -gt 0) 'brief length missing from metadata'
    Assert-True ($ok.Output -match 'turns 4 \| contextPerTurn 100000') 'final line omitted turns and context per turn'
    Assert-True ($metaOk.auth.verified -eq $true) 'authentication was not verified in metadata'
    Assert-True (-not (Test-Path -LiteralPath (Get-RepoLockPath $lockDir $sampleRepo))) 'lock retained after success'
    Assert-True ($metaOk.sessionId -eq 'aaaaaaaa-0000-0000-0000-000000000001') 'session ID from the result was not recorded'
    Assert-True (Test-Path -LiteralPath (Join-Path $runOk 'auth-decision.json')) 'missing auth-decision.json'
    Assert-True ((Get-Content -Raw -LiteralPath (Join-Path $runOk 'claude.stderr.log')) -match 'args: .*--print --agent pipeline:implementer') 'Claude arguments were not saved in the stderr log'
    $launchSettings = Get-Content -Raw -LiteralPath (Join-Path $work 'captured-settings.json') | ConvertFrom-Json
    Assert-True ($launchSettings.fallbackModel.Count -eq 0 -and $launchSettings.switchModelsOnFlag -eq $false) 'launch settings lost model safeguards'
    $guardHook = $launchSettings.hooks.PreToolUse[0]
    Assert-True ($guardHook.matcher -eq 'Bash|PowerShell' -and $guardHook.hooks[0].type -eq 'command' -and $guardHook.hooks[0].command -eq ('pwsh -NoProfile -File "' + (Join-Path $root 'hooks\guard-executor-git.ps1') + '"')) 'launched settings must carry the executor Git guard with a quoted absolute path'

    # A fresh fix brief, then an outside brief, launched into the same run directory keep the first brief.
    $runFix = Join-Path $runOk 'fix-1.md'
    Set-Content -LiteralPath $runFix -Value '# Fix 1' -Encoding utf8
    $freshFix = Invoke-ClaudeRun @('-Repo', 'sample-app', '-Brief', $runFix, '-RunDir', $runOk)
    $outsideBrief = Join-Path $work 'lot-two.md'
    Set-Content -LiteralPath $outsideBrief -Value '# Lot two' -Encoding utf8
    $outside = Invoke-ClaudeRun @('-Repo', 'sample-app', '-Brief', $outsideBrief, '-RunDir', $runOk)
    Assert-True ($freshFix.ExitCode -eq 0 -and $outside.ExitCode -eq 0) "later briefs into the same run directory failed: $($freshFix.Output.Trim()) $($outside.Output.Trim())"
    Assert-True ((Get-Content -Raw -LiteralPath (Join-Path $runOk 'brief.md')).Trim() -eq '# Brief') 'a later brief overwrote the run directory brief.md'
    Assert-True ((Get-Content -Raw -LiteralPath (Join-Path $runOk 'lot-two.md')).Trim() -eq '# Lot two') 'an outside brief was not kept under its own name'
    Assert-True ((Get-Content -Raw -LiteralPath (Join-Path $runOk 'meta.json') | ConvertFrom-Json).brief -eq $outsideBrief) 'meta.json does not name the latest brief'

    $gateSuccessDir = Join-Path $work 'gate-success'
    $gateSuccess = Invoke-ClaudeRun @('-Repo','sample-app','-Brief',$brief,'-RunDir',$gateSuccessDir,'-GateCommand','Write-Output gate-ok')
    $gateSuccessJson = Get-Content -Raw -LiteralPath (Join-Path $gateSuccessDir 'gate.json') | ConvertFrom-Json
    Assert-True ($gateSuccess.ExitCode -eq 0 -and $gateSuccess.Output -match 'gate: exit 0') 'successful post-run gate failed'
    Assert-True ($gateSuccessJson.exitCode -eq 0 -and $gateSuccessJson.cwd -eq $sampleRepo -and $gateSuccessJson.tail -match 'gate-ok') 'gate.json missing success evidence'
    Assert-True ($gateSuccessJson.owner -eq 'launcher' -and $gateSuccessJson.reused -eq $false -and $gateSuccessJson.fingerprint -match '^[0-9A-F]{64}$' -and @($gateSuccessJson.failures).Count -eq 0) 'launcher gate.json misses owner, reused, fingerprint or failures'
    Assert-True ((Get-Content -Raw -LiteralPath (Join-Path $gateSuccessDir 'meta.json') | ConvertFrom-Json).reportSynthesized -eq $false) 'report synthesized although the executor wrote one'
    $flakyDir = Join-Path $work 'gate-flaky'
    New-Item -ItemType Directory -Path $flakyDir | Out-Null
    $flakyCounter = Join-Path $work 'flaky.count'
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixtures\flutter.ps1') -Destination $fakeBin
    $env:FAKE_GATE_COUNTER = $flakyCounter
    $flakyCommand = 'flutter test --concurrency=3'
    $flakyRun = Invoke-ClaudeRun @('-Repo','sample-app','-Brief',$brief,'-RunDir',$flakyDir,'-GateCommand',$flakyCommand)
    $flakyGate = Get-Content -Raw -LiteralPath (Join-Path $flakyDir 'gate.json') | ConvertFrom-Json
    Assert-True ($flakyRun.ExitCode -eq 0 -and $flakyGate.flaky -eq $true -and @($flakyGate.attempts).Count -eq 2) 'flaky green became wrapper failure'
    Assert-True ($flakyRun.Output.Contains('gate: exit 0 (flaky: green on retry 1; 2 failures first)')) 'flaky gate summary missing'

    $gateFailureDir = Join-Path $work 'gate-failure'
    $gateFailure = Invoke-ClaudeRun @('-Repo','sample-app','-Brief',$brief,'-RunDir',$gateFailureDir,'-GateCommand','exit 7')
    Assert-True ($gateFailure.ExitCode -eq 5 -and $gateFailure.Output -match 'gate: exit 7') 'failed gate did not exit 5'
    Assert-True ($gateFailure.Output -match '(?m)^claude-run: exit 5 \(executor 0\) \|') 'summary must report wrapper failure and executor success'
    Assert-True (-not (Test-Path -LiteralPath (Get-RepoLockPath $lockDir $sampleRepo))) 'lock retained after gate failure'
    $gateNoneDir = Join-Path $work 'gate-none'
    $gateNone = Invoke-ClaudeRun @('-Repo','sample-app','-Brief',$brief,'-RunDir',$gateNoneDir,'-GateCommand','none')
    Assert-True ($gateNone.ExitCode -eq 0 -and -not (Test-Path -LiteralPath (Join-Path $gateNoneDir 'gate.json'))) 'GateCommand none did not skip'

    # --- Matching green/red executor gates are reused; changed, timed-out or absent gates run.
    $gateRepo = Join-Path $work 'gate-repo'
    New-Item -ItemType Directory -Path $gateRepo | Out-Null
    Set-Content -LiteralPath (Join-Path $gateRepo 'source.txt') -Value 'v1' -Encoding utf8
    foreach ($case in @('reuse', 'changed', 'red', 'timeout', 'absent')) {
        $caseDir = Join-Path $work "executor-gate-$case"
        $counter = Join-Path $work "executor-gate-$case.count"
        $exitFirst = if ($case -eq 'red') { 3 } else { 0 }
        $caseCommand = "Add-Content -LiteralPath '$counter' -Value run; if (@(Get-Content -LiteralPath '$counter').Count -le 2) { exit $exitFirst }"
        New-Item -ItemType Directory -Path $caseDir | Out-Null
        if ($case -ne 'absent') { & pwsh -NoProfile -File (Join-Path $root 'bin\run-gate.ps1') -Repo $gateRepo -RunDir $caseDir -GateCommand $caseCommand *> $null }
        if ($case -eq 'changed') { Set-Content -LiteralPath (Join-Path $gateRepo 'source.txt') -Value 'v2' -Encoding utf8 }
        if ($case -eq 'timeout') {
            $priorPath = Join-Path $caseDir 'gate.json'
            $prior = Get-Content -Raw -LiteralPath $priorPath | ConvertFrom-Json
            $prior.timedOut = $true
            $prior | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $priorPath
        }
        $caseRun = Invoke-ClaudeRun @('-Repo', $gateRepo, '-Brief', $brief, '-RunDir', $caseDir, '-GateCommand', $caseCommand)
        $caseGate = Get-Content -Raw -LiteralPath (Join-Path $caseDir 'gate.json') | ConvertFrom-Json
        $caseMeta = Get-Content -Raw -LiteralPath (Join-Path $caseDir 'meta.json') | ConvertFrom-Json
        $caseRuns = @(Get-Content -LiteralPath $counter).Count
        $kept = Join-Path $caseDir 'gate.executor.json'
        $expectedExit = if ($case -eq 'red') { 5 } else { 0 }
        Assert-True ($caseRun.ExitCode -eq $expectedExit) "executor gate case $case exit $($caseRun.ExitCode), expected $expectedExit"
        if ($case -in @('reuse', 'red')) {
            Assert-True ($caseRuns -eq 1 -and $caseRun.Output -match "gate: exit $exitFirst \(reused\)") 'matching executor gate was run again'
            Assert-True ($caseGate.exitCode -eq $exitFirst -and $caseMeta.gate.exitCode -eq $exitFirst -and $caseMeta.wrapperExitCode -eq $expectedExit) 'reused gate changed its outcome'
            Assert-True ($caseGate.owner -eq 'executor' -and $caseGate.reused -eq $true -and $caseMeta.gate.reused -eq $true) 'reused gate not recorded in gate.json and meta.gate'
            Assert-True (-not (Test-Path -LiteralPath $kept)) 'reused executor gate also kept as gate.executor.json'
        }
        else {
            $expectedRuns = if ($case -eq 'absent') { 1 } else { 2 }
            Assert-True ($caseRuns -eq $expectedRuns -and $caseGate.owner -eq 'launcher' -and $caseGate.reused -eq $false -and $caseMeta.gate.reused -eq $false) "executor gate case $case not rerun by the launcher"
            Assert-True ((Test-Path -LiteralPath $kept) -eq ($case -ne 'absent')) "executor gate case $case kept the wrong gate.executor.json"
        }
    }
    $keptTimeout = Get-Content -Raw -LiteralPath (Join-Path $work 'executor-gate-timeout\gate.executor.json') | ConvertFrom-Json
    Assert-True ($keptTimeout.owner -eq 'executor' -and $keptTimeout.timedOut -eq $true -and (Test-Path -LiteralPath $keptTimeout.log)) 'timed-out executor gate not kept with its log'
    $origRun = Join-Path $work 'brief-gate-run'
    $briefCounter = Join-Path $work 'brief-gate.count'
    $briefCommand = "Add-Content -LiteralPath '$briefCounter' -Value run"
    New-Item -ItemType Directory -Path $origRun | Out-Null
    Copy-Item -LiteralPath $brief -Destination (Join-Path $origRun 'brief.md')
    & pwsh -NoProfile -File (Join-Path $root 'bin\run-gate.ps1') -Repo $gateRepo -RunDir $origRun -GateCommand $briefCommand *> $null
    [ordered]@{ command = $briefCommand; owner = 'executor' } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $origRun 'brief.gate.json') -Encoding utf8
    $fixRun = Join-Path $work 'brief-gate-run-fix1'
    $briefReuse = Invoke-ClaudeRun @('-Repo', $gateRepo, '-Brief', (Join-Path $origRun 'brief.md'), '-RunDir', $fixRun)
    $fixGate = Get-Content -Raw -LiteralPath (Join-Path $fixRun 'gate.json') | ConvertFrom-Json
    Assert-True ($briefReuse.ExitCode -eq 0 -and $briefReuse.Output -match 'gate: exit 0 \(reused\)' -and @(Get-Content -LiteralPath $briefCounter).Count -eq 1) 'fix-loop launcher did not reuse the gate in the brief directory'
    Assert-True ($fixGate.reused -eq $true -and $fixGate.reusedFrom -eq (Join-Path $origRun 'gate.json')) 'brief-directory gate copied without reused or reusedFrom'
    Set-Content -LiteralPath (Join-Path $fakeBin 'node.cmd') -Value "@echo off`r`nexit /b 9" -Encoding ascii
    $accounting = Invoke-ClaudeRun @('-Repo','sample-app','-Brief',$brief,'-RunDir',(Join-Path $work 'accounting-failure'),'-GateCommand','none')
    Assert-True ($accounting.ExitCode -eq 0 -and $accounting.Output -match 'warning: task-usage') 'task-usage failure changed exit or was silent'
    Remove-Item -LiteralPath (Join-Path $fakeBin 'node.cmd') -Force

    $env:FAKE_CLAUDE_MODE = 'noreport'
    $runNoReport = Join-Path $work 'run-noreport'
    New-Item -ItemType Directory -Path $runNoReport | Out-Null
    Set-Content -LiteralPath (Join-Path $runNoReport 'progress.md') -Value 'Task 1 done; stopped in task 2' -Encoding utf8
    Set-Content -LiteralPath (Join-Path $runNoReport 'report.md') -Value 'STATUS: ready_for_review'
    $noReport = Invoke-ClaudeRun @('-Repo', 'sample-app', '-Brief', $brief, '-RunDir', $runNoReport)
    $metaNoReport = Get-Content -Raw -LiteralPath (Join-Path $runNoReport 'meta.json') | ConvertFrom-Json
    Assert-True ($noReport.ExitCode -eq 1 -and $metaNoReport.reportPresent -eq $false) 'result without a report did not exit 1'
    Assert-True ($metaNoReport.reportSynthesized -eq $true -and (Get-Content -Raw -LiteralPath (Join-Path $runNoReport 'report.md')) -match '(?s)^STATUS: failed.*Cause: executor error.*Task 1 done; stopped in task 2') 'executor exit without report left no report with cause and progress'
    Assert-True ($null -eq $metaNoReport.gate) 'stale Claude report ran success gate'
    Assert-True (-not (Test-Path -LiteralPath (Get-RepoLockPath $lockDir $sampleRepo))) 'lock retained after executor failure'

    Remove-Item Env:FAKE_CLAUDE_MODE -ErrorAction SilentlyContinue
    $env:FAKE_CLAUDE_MODE = 'ok'
    foreach ($loop in @(1, 2)) {
        if ($loop -eq 2) { $env:FAKE_CLAUDE_MODE = 'newreport' }
        $historyResume = Invoke-ClaudeRun @('-Repo', 'sample-app', '-Brief', $brief, '-RunDir', $runNoReport, '-Resume', $metaNoReport.sessionId, '-FixLoop', "$loop", '-GateCommand', 'none')
        $historyMeta = Get-Content -Raw -LiteralPath (Join-Path $runNoReport 'meta.json') | ConvertFrom-Json
        Assert-True ($historyResume.ExitCode -eq 0 -and $historyMeta.wrapperExitCode -eq 0 -and $historyMeta.fixLoop -eq $loop) 'claude latest resume outcome changed'
        Assert-True (@($historyMeta.attempts).Count -eq $loop) 'claude earlier attempts lost on same-directory resume'
        if ($historyMeta.attempts) {
            $first = $historyMeta.attempts[0]
            foreach ($field in @('startedAt', 'endedAt', 'exitCode', 'wrapperExitCode', 'timedOut', 'fixLoop', 'sessionId', 'model')) {
                Assert-True ($first.$field -eq $metaNoReport.$field) "claude archived $field changed"
            }
            Assert-True ($first.reasoningEffort -eq $metaNoReport.effort) 'claude archived reasoning effort missing'
            Assert-True ($null -eq $first.PSObject.Properties['attempts']) 'claude nested attempt history'
        }
    }
    $env:FAKE_CLAUDE_MODE = 'ok'

    $noopRepo = Join-Path $work 'resume-noop-repo'
    New-Item -ItemType Directory -Path $noopRepo | Out-Null
    & git -C $noopRepo init -b main *> $null
    Set-Content -LiteralPath (Join-Path $noopRepo 'source.txt') -Value fixture
    & git -C $noopRepo add source.txt *> $null
    & git -C $noopRepo -c user.name=Fixture -c user.email=fixture@example.invalid commit -m fixture *> $null
    Assert-True ($LASTEXITCODE -eq 0) 'resume no-op fixture commit failed'
    $env:FAKE_CLAUDE_FIXTURE = 'resume'
    foreach ($case in @('same-directory', 'different-directory', 'commit', 'mode', 'edit', 'untracked', 'reply', 'latest', 'inside', 'missing-baseline', 'unreadable-baseline', 'unreadable-source')) {
        $caseRoot = Join-Path $root "runs\resume-noop-repo\$case"
        $firstDir = Join-Path $caseRoot 'A'
        if ($case -eq 'inside') { $firstDir = Join-Path $noopRepo 'run' }
        $counter = Join-Path $work "noop-$case.count"
        $gateCommand = "Add-Content -LiteralPath '$counter' -Value gate"
        $firstRun = Invoke-ClaudeRun @('-Repo', $noopRepo, '-Brief', $brief, '-RunDir', $firstDir, '-GateCommand', $gateCommand)
        $firstMeta = Get-Content -Raw -LiteralPath (Join-Path $firstDir 'meta.json') | ConvertFrom-Json
        Assert-True ($firstRun.ExitCode -eq 0 -and $firstMeta.reportSynthesized -eq $false) "$case fresh fixture failed: $($firstRun.Output.Trim())"
        $reply = (Get-Content -Raw -LiteralPath (Join-Path $firstDir 'result.json') | ConvertFrom-Json).result
        $resumeDir = if ($case -eq 'different-directory' -or $case -eq 'latest') { Join-Path $caseRoot 'B' } else { $firstDir }
        if ($case -in @('edit', 'untracked', 'commit', 'mode')) { $env:FAKE_CLAUDE_PROGRESS = $case }
        if ($case -in @('reply', 'latest')) { $env:FAKE_CLAUDE_REPLY = '# Updated report' }
        if ($case -eq 'same-directory') { $env:FAKE_CLAUDE_REPLY = $reply + " `r`n" }
        if ($case -eq 'missing-baseline') {
            $baseline = Get-Content -Raw -LiteralPath (Join-Path $firstDir 'result.json') | ConvertFrom-Json
            $baseline.PSObject.Properties.Remove('result')
            $baseline | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $firstDir 'result.json')
        }
        if ($case -eq 'unreadable-baseline') {
            $brokenDir = Join-Path $caseRoot 'broken'
            New-Item -ItemType Directory -Path $brokenDir | Out-Null
            $brokenMeta = $firstMeta | ConvertTo-Json -Depth 10 | ConvertFrom-Json
            $brokenMeta.endedAt = [datetime]::UtcNow.AddMinutes(1).ToString('o')
            $brokenMeta | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $brokenDir 'meta.json')
            Set-Content -LiteralPath (Join-Path $brokenDir 'result.json') -Value 'unreadable'
        }
        $sourceLock = if ($case -eq 'unreadable-source') { [IO.File]::Open((Join-Path $noopRepo 'source.txt'), [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None) } else { $null }
        try {
            $resumed = Invoke-ClaudeRun @('-Repo', $noopRepo, '-Brief', (Join-Path $firstDir 'brief.md'), '-RunDir', $resumeDir, '-Resume', $firstMeta.sessionId, '-FixLoop', '1', '-GateCommand', $gateCommand)
        }
        finally { if ($null -ne $sourceLock) { $sourceLock.Dispose() } }
        $resumedMeta = Get-Content -Raw -LiteralPath (Join-Path $resumeDir 'meta.json') | ConvertFrom-Json
        if ($case -in @('same-directory', 'different-directory')) {
            Assert-True ($resumed.ExitCode -eq 1 -and $resumedMeta.wrapperExitCode -eq 1 -and $resumedMeta.exitCode -eq 0) "$case repeated resume did not fail: $($resumed.Output.Trim())"
            Assert-True ($resumedMeta.reportSynthesized -eq $true -and $resumedMeta.resumeNoop -eq $true -and $null -eq $resumedMeta.gate) "$case no-op metadata or gate wrong"
            Assert-True ((Get-Content -Raw -LiteralPath (Join-Path $resumeDir 'report.md')) -match '(?s)^STATUS: failed.*resume repeated the previous report without changes') "$case no-op failure report missing"
            Assert-True ((Get-Content -Raw -LiteralPath (Join-Path $resumeDir 'report.previous.md')) -ceq (Get-Content -Raw -LiteralPath (Join-Path $resumeDir 'result.json') | ConvertFrom-Json).result) "$case raw executor report not preserved"
            Assert-True (@(Get-Content -LiteralPath $counter).Count -eq 1 -and $resumed.Output -notmatch 'gate: exit') "$case no-op ran or reused a gate"
            $again = Invoke-ClaudeRun @('-Repo', $noopRepo, '-Brief', (Join-Path $resumeDir 'brief.md'), '-RunDir', $resumeDir, '-Resume', $firstMeta.sessionId, '-FixLoop', '2', '-GateCommand', $gateCommand)
            Assert-True ($again.ExitCode -eq 1 -and @(Get-Content -LiteralPath $counter).Count -eq 1) "$case second consecutive no-op escaped detection"
        }
        else {
            Assert-True ($resumed.ExitCode -eq 0 -and $resumedMeta.reportSynthesized -eq $false -and $null -ne $resumedMeta.gate) "$case progress or skipped detection changed behavior: $($resumed.Output.Trim())"
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $resumeDir 'report.previous.md'))) "$case progress preserved a no-op report"
            if ($case -in @('missing-baseline', 'unreadable-baseline', 'unreadable-source')) {
                Assert-True (@([regex]::Matches($resumed.Output, '(?m)^warning: resume no-op detection skipped:')).Count -eq 1) "$case did not warn once"
            }
        }
        Remove-Item Env:FAKE_CLAUDE_PROGRESS, Env:FAKE_CLAUDE_REPLY -ErrorAction SilentlyContinue
        if ($case -eq 'latest') {
            $env:FAKE_CLAUDE_REPLY = '# Updated report'
            $unfinishedDir = Join-Path $caseRoot 'unfinished'
            New-Item -ItemType Directory -Path $unfinishedDir | Out-Null
            $resumedMeta.endedAt = $null
            $resumedMeta | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $unfinishedDir 'meta.json')
            Copy-Item -LiteralPath (Join-Path $firstDir 'result.json') -Destination $unfinishedDir
            $thirdDir = Join-Path $caseRoot 'C'
            $third = Invoke-ClaudeRun @('-Repo', $noopRepo, '-Brief', (Join-Path $firstDir 'brief.md'), '-RunDir', $thirdDir, '-Resume', $firstMeta.sessionId, '-FixLoop', '2', '-GateCommand', $gateCommand)
            $thirdMeta = Get-Content -Raw -LiteralPath (Join-Path $thirdDir 'meta.json') | ConvertFrom-Json
            Assert-True ($third.ExitCode -eq 1 -and $thirdMeta.resumeNoop -eq $true -and $null -eq $thirdMeta.gate) 'A -> B -> C compared with A instead of the latest completed reply B'
            Remove-Item Env:FAKE_CLAUDE_REPLY
        }
    }
    Remove-Item Env:FAKE_CLAUDE_FIXTURE

    $env:FAKE_CLAUDE_AUTH = 'bad'
    $runBadAuth = Join-Path $work 'run-bad-auth'
    $badAuth = Invoke-ClaudeRun @('-Repo', 'sample-app', '-Brief', $brief, '-RunDir', $runBadAuth)
    Assert-True ($badAuth.ExitCode -eq 2) 'non-subscription authentication did not exit 2'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $runBadAuth 'result.json'))) 'Claude launched without verified authentication'
    $authDecision = Get-Content -Raw -LiteralPath (Join-Path $runBadAuth 'auth-decision.json') | ConvertFrom-Json
    Assert-True ($authDecision.verified -eq $false) 'auth-decision did not record the refusal'
    $metaBadAuth = Get-Content -Raw -LiteralPath (Join-Path $runBadAuth 'meta.json') | ConvertFrom-Json
    Assert-True ($metaBadAuth.repoRoot -eq $sampleRepo -and $metaBadAuth.github -eq 'fixture-team/SampleApp') 'auth-refusal repository identity missing'
    Assert-True ($metaBadAuth.reportSynthesized -eq $true -and $metaBadAuth.wrapperExitCode -eq 2 -and (Get-Content -Raw -LiteralPath (Join-Path $runBadAuth 'report.md')) -match '(?s)^STATUS: failed.*Cause: auth') 'auth exit left no synthesized report'

    # --- A launcher crash after the run directory exists still leaves a report; the exit stays the crash exit.
    Remove-Item Env:FAKE_CLAUDE_AUTH -ErrorAction SilentlyContinue
    $gitBin = Split-Path (Get-Command git -TotalCount 1).Source -Parent
    $env:PATH = "$env:SystemRoot\System32;$PSHOME;$gitBin"
    $runCrash = Join-Path $work 'run-crash'
    $crash = Invoke-ClaudeRun @('-Repo', 'sample-app', '-Brief', $brief, '-RunDir', $runCrash, '-SkipQuotaCheck')
    $env:PATH = "$fakeBin;$originalPath"
    Assert-True ($crash.ExitCode -eq 1) "launcher crash exit changed: $($crash.ExitCode)"
    Assert-True ((Test-Path -LiteralPath (Join-Path $runCrash 'report.md')) -and (Get-Content -Raw -LiteralPath (Join-Path $runCrash 'report.md')) -match '(?s)^STATUS: failed.*Cause: crash: launcher error') 'launcher crash left no synthesized report'
    Assert-True ((Test-Path -LiteralPath (Join-Path $runCrash 'meta.json')) -and (Get-Content -Raw -LiteralPath (Join-Path $runCrash 'meta.json') | ConvertFrom-Json).reportSynthesized -eq $true) 'launcher crash did not mark meta.json'
    $crashMeta = Get-Content -Raw -LiteralPath (Join-Path $runCrash 'meta.json') | ConvertFrom-Json
    Assert-True ($crashMeta.repoRoot -eq $sampleRepo -and $crashMeta.github -eq 'fixture-team/SampleApp') 'Claude crash metadata lost repository identity'
    Assert-True (-not (Test-Path -LiteralPath (Get-RepoLockPath $lockDir $sampleRepo))) 'lock retained after launcher crash'

    Remove-Item Env:FAKE_CLAUDE_AUTH -ErrorAction SilentlyContinue
    $runResume = Join-Path $work 'run-resume'
    $resume = Invoke-ClaudeRun @('-Repo', 'sample-app', '-Brief', $brief, '-RunDir', $runResume, '-Resume', $idB, '-FixLoop', '2')
    $metaResume = Get-Content -Raw -LiteralPath (Join-Path $runResume 'meta.json') | ConvertFrom-Json
    Assert-True ($resume.ExitCode -eq 0) 'fixture resume failed'
    Assert-True ($metaResume.fixLoop -eq 2) 'fixLoop was not recorded for the resume'
    Assert-True ($metaResume.resumedFrom -eq $idB) 'resumedFrom was not recorded'
    Assert-True ($metaResume.resumeGuard.contextPerTurn -eq 100000) 'incorrect contextPerTurn for the resume'
    $identityRun = Join-Path $work 'identity-run'
    $identityResult = Invoke-ClaudeRun @('-Repo', $repoA, '-Brief', $brief, '-RunDir', $identityRun, '-SkipQuotaCheck')
    $identityMeta = Get-Content -Raw -LiteralPath (Join-Path $identityRun 'meta.json') | ConvertFrom-Json
    Assert-True ($identityResult.ExitCode -eq 0 -and $identityMeta.repoRoot -eq $repoA -and $null -eq $identityMeta.github -and $null -ne $identityMeta.PSObject.Properties['github']) 'non-Git Claude metadata identity missing or not null'
    $nonGitResume = Invoke-ClaudeRun @('-Repo', $repoA, '-Brief', $brief, '-RunDir', $identityRun, '-Resume', $identityMeta.sessionId, '-FixLoop', '1', '-SkipQuotaCheck')
    Assert-True ($nonGitResume.ExitCode -eq 0 -and $nonGitResume.Output -notmatch 'resume no-op detection skipped' -and -not (Test-Path -LiteralPath (Join-Path $identityRun 'report.previous.md'))) 'non-Git repeated resume changed behavior'
    $mainRepo = Join-Path $work 'Acme-Api'
    New-Item -ItemType Directory -Path $mainRepo | Out-Null
    & git -C $mainRepo init -b main *> $null
    & git -C $mainRepo config core.autocrlf false
    [IO.File]::WriteAllText((Join-Path $mainRepo 'source.txt'), "fixture`n")
    & git -C $mainRepo add source.txt *> $null
    & git -C $mainRepo -c user.name=Fixture -c user.email=fixture@example.invalid commit -m fixture *> $null
    Assert-True ($LASTEXITCODE -eq 0) 'Claude identity fixture commit failed'
    $worktreeRepo = Join-Path $work '.worktrees\services-win-lag'
    & git -C $mainRepo worktree add -b win-lag $worktreeRepo *> $null
    Assert-True ($LASTEXITCODE -eq 0) 'Claude identity fixture worktree failed'
    & git -C $mainRepo remote add origin https://github.com/fixture-team/acme-api.git *> $null
    $worktreeRun = Join-Path $work 'worktree-run'
    [IO.File]::WriteAllText((Join-Path $worktreeRepo 'source.txt'), "fixture`r`n")
    $worktreeResult = Invoke-ClaudeRun @('-Repo', $worktreeRepo, '-Brief', $brief, '-RunDir', $worktreeRun, '-SkipQuotaCheck')
    $worktreeMeta = Get-Content -Raw -LiteralPath (Join-Path $worktreeRun 'meta.json') | ConvertFrom-Json
    Assert-True ($worktreeMeta.lineEndingOnly -is [array] -and $worktreeMeta.lineEndingOnly.Count -eq 1 -and $worktreeMeta.lineEndingOnly[0] -eq 'source.txt' -and $worktreeResult.Output.Contains("git checkout -- 'source.txt'")) 'Claude worktree run must report its line-ending-only file and restoration command'
    Assert-True ($worktreeResult.ExitCode -eq 0 -and $worktreeMeta.repo -eq 'acme-api' -and $worktreeMeta.repoPath -eq $worktreeRepo -and $worktreeMeta.repoRoot -eq $mainRepo -and $worktreeMeta.github -eq 'fixture-team/acme-api') 'Claude worktree metadata did not preserve target and main-checkout identity'
    $worktreeDry = Invoke-ClaudeRun @('-Repo', $worktreeRepo, '-Brief', $brief, '-DryRun')
    Assert-True ($worktreeDry.ExitCode -eq 0 -and $worktreeDry.Output.Contains('runs\acme-api\')) 'Claude worktree run naming kept the worktree leaf'

    # Resume lookup survives the worktree alias migration and prefers explicit locations.
    $legacySession = 'aaaaaaaa-7777-7777-7777-777777777777'
    $legacyAliasRun = Join-Path $root 'runs\services-win-lag\legacy-run'
    New-Item -ItemType Directory -Path $legacyAliasRun -Force | Out-Null
    @{ sessionId = $legacySession; model = 'claude-sonnet-5-5'; effort = 'xhigh' } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $legacyAliasRun 'meta.json')
    @{ num_turns = 4; usage = @{ cache_read_input_tokens = 400000 } } | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath (Join-Path $legacyAliasRun 'result.json')
    $legacyAliasResume = Invoke-ClaudeRun @('-Repo', $worktreeRepo, '-Brief', $brief, '-Resume', $legacySession, '-FixLoop', '1', '-DryRun')
    Assert-True ($legacyAliasResume.ExitCode -eq 0 -and $legacyAliasResume.Output.Contains('--model claude-sonnet-5-5') -and $legacyAliasResume.Output.Contains('--effort xhigh')) 'Claude legacy worktree alias resume lost recorded model/effort'
    $canonicalRun = Join-Path $root 'runs\acme-api\canonical-run'
    New-Item -ItemType Directory -Path $canonicalRun -Force | Out-Null
    @{ sessionId = $legacySession; model = 'claude-opus-5-5'; effort = 'medium' } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $canonicalRun 'meta.json')
    Copy-Item -LiteralPath (Join-Path $legacyAliasRun 'result.json') -Destination $canonicalRun
    $canonicalResume = Invoke-ClaudeRun @('-Repo', $worktreeRepo, '-Brief', $brief, '-Resume', $legacySession, '-FixLoop', '1', '-DryRun')
    Assert-True ($canonicalResume.ExitCode -eq 0 -and $canonicalResume.Output.Contains('--model claude-opus-5-5') -and $canonicalResume.Output.Contains('--effort medium')) 'Claude canonical alias did not precede legacy alias'
    @{ sessionId = $legacySession; model = 'claude-sonnet-5-5'; effort = 'high' } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path (Split-Path $brief) 'meta.json')
    Copy-Item -LiteralPath (Join-Path $legacyAliasRun 'result.json') -Destination (Split-Path $brief)
    $briefResume = Invoke-ClaudeRun @('-Repo', $worktreeRepo, '-Brief', $brief, '-Resume', $legacySession, '-FixLoop', '1', '-DryRun')
    Assert-True ($briefResume.ExitCode -eq 0 -and $briefResume.Output.Contains('--model claude-sonnet-5-5') -and $briefResume.Output.Contains('--effort high')) 'Claude brief directory did not precede alias directories'
    $suppliedRun = Join-Path $work 'supplied-resume'
    New-Item -ItemType Directory -Path $suppliedRun | Out-Null
    @{ sessionId = $legacySession; model = 'claude-opus-5-5'; effort = 'xhigh' } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $suppliedRun 'meta.json')
    Copy-Item -LiteralPath (Join-Path $legacyAliasRun 'result.json') -Destination $suppliedRun
    $suppliedResume = Invoke-ClaudeRun @('-Repo', $worktreeRepo, '-Brief', $brief, '-RunDir', $suppliedRun, '-Resume', $legacySession, '-FixLoop', '1', '-DryRun')
    Assert-True ($suppliedResume.ExitCode -eq 0 -and $suppliedResume.Output.Contains('--model claude-opus-5-5') -and $suppliedResume.Output.Contains('--effort xhigh')) 'Claude supplied run directory did not precede brief directory'
    $unknownWorktreeResume = Invoke-ClaudeRun @('-Repo', $worktreeRepo, '-Brief', $brief, '-Resume', 'ffffffff-9999-9999-9999-999999999999', '-FixLoop', '1', '-DryRun')
    Assert-True ($unknownWorktreeResume.ExitCode -eq 3 -and $unknownWorktreeResume.Output -match 'no recorded run for session') 'Claude unknown worktree session was not refused with exit 3'
}
catch {
    $failures.Add($_.Exception.Message)
}
finally {
    Remove-Item Env:FAKE_GATE_COUNTER -ErrorAction SilentlyContinue
    Remove-Item Env:FAKE_CLAUDE_FIXTURE, Env:FAKE_CLAUDE_PROGRESS, Env:FAKE_CLAUDE_REPLY -ErrorAction SilentlyContinue
    $env:PATH = $originalPath
    Remove-Item Env:FAKE_CLAUDE_MODE -ErrorAction SilentlyContinue
    Remove-Item Env:FAKE_CLAUDE_AUTH -ErrorAction SilentlyContinue
    Remove-Item Env:FAKE_CLAUDE_SETTINGS_FILE -ErrorAction SilentlyContinue
    Remove-Item Env:FAKE_CODEBURN_MODE -ErrorAction SilentlyContinue
    Remove-Item Env:FAKE_CODEBURN_PCT -ErrorAction SilentlyContinue
    Remove-Item Env:FAKE_CODEBURN_PCT_5H, Env:FAKE_CODEBURN_FABLE_PCT, Env:FAKE_CODEBURN_OPUS_PCT, Env:FAKE_CODEBURN_SONNET_PCT, Env:FAKE_CODEBURN_HAIKU_PCT, Env:FAKE_CODEBURN_UNKNOWN_PCT -ErrorAction SilentlyContinue
    if ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($work)) -ne [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetTempPath())) { throw 'unsafe fixture cleanup path' }
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Error $_ -ErrorAction Continue }
    exit 1
}

Write-Output "claude-run tests: PASS ($assertions assertions)"
