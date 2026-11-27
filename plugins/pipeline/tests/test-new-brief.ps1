$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\skills\pipeline')).Path
$script = Join-Path $root 'bin\new-brief.ps1'
$template = Join-Path $root 'templates\brief.md'
$failures = [Collections.Generic.List[string]]::new()
$assertions = 0

function Assert-True([bool]$Condition, [string]$Message) {
    $script:assertions++
    if (-not $Condition) { $failures.Add($Message) }
}

function Invoke-NewBrief {
    param([string[]]$Arguments)
    $env:PIPELINE_HOME = $root
    $output = (& pwsh -NoProfile -File $script @Arguments 2>&1 | Out-String)
    return [pscustomobject]@{ Output = $output; ExitCode = $LASTEXITCODE }
}

# Outside the hub, so a delete that loses the Windows race leaves nothing behind here.
$work = Join-Path ([IO.Path]::GetTempPath()) ('.test-new-brief-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $work | Out-Null
$sourceRoot = $root
$root = Join-Path $work 'skill'
Copy-Item -LiteralPath $sourceRoot -Destination $root -Recurse
. (Join-Path $PSScriptRoot 'TestSupport.ps1')
$testRegistry = Initialize-TestRegistry $root
$sampleRepo = $testRegistry.executors.'sample-app'.repo
$logRepo = $testRegistry.executors.'sample-log'.repo
$script = Join-Path $root 'bin\new-brief.ps1'


function Remove-WorkDir([string]$Path) {
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path -LiteralPath $Path)) { return }
        Start-Sleep -Milliseconds 200
    }
}
$logTopic = 'zz-test-new-brief-' + [guid]::NewGuid()
$logDir = Join-Path $root "logs\pipeline\$logTopic"
$previousOutputEncoding = [Console]::OutputEncoding
$previousInputEncoding = [Console]::InputEncoding

try {
    $utf8Encoding = [Text.UTF8Encoding]::new($false)
    [Console]::OutputEncoding = $utf8Encoding
    [Console]::InputEncoding = $utf8Encoding
    Assert-True (Test-Path -LiteralPath $script) 'missing bin\new-brief.ps1'
    $templateText = Get-Content -Raw -LiteralPath $template
    $wordCount = (($templateText -split '\s+') | Where-Object { $_ }).Count
    Assert-True ($templateText -notmatch 'Probe once|{{probe}}') 'template still requires probe'
    Assert-True ($wordCount -le 350) "brief template exceeds 350 words: $wordCount"

    foreach ($route in @(
        @('codex','LOW','gpt-6.1-terra','medium'), @('codex','MEDIUM','gpt-6.2-sol','medium'), @('codex','HIGH','gpt-6.2-sol','high'),
        @('claude','LOW','claude-haiku-5-5','medium'), @('claude','MEDIUM','claude-sonnet-5-5','medium'), @('claude','HIGH','claude-opus-5-5','high'))) {
        $routed = Invoke-NewBrief @('-Repo', 'pipeline-tools', '-Topic', 'model-policy', '-Executor', $route[0], '-Risk', $route[1], '-DryRun')
        $expected = 'Executor: ' + $route[0] + ' `' + $route[2] + '`; effort `' + $route[3] + '`.'
        Assert-True ($routed.ExitCode -eq 0 -and $routed.Output.Contains($expected)) "wrong brief route: $($route -join '/')"
        Assert-True ($routed.Output -match '(?s)\r?\n## Code economy\r?\n.*\r?\n## Return\r?\n') "Code economy section missing: $($route -join '/')"
        if ($route[0] -eq 'codex') {
            Assert-True ($routed.Output -match '(?s)## Return.*Leave changes uncommitted; the reviewer commits\.' -and $routed.Output -notmatch 'Commit only when assigned') "Codex commit wording: $($route -join '/')"
            $defaultRoute = Invoke-NewBrief @('-Repo','pipeline-tools','-Topic','model-policy','-Risk',$route[1],'-DryRun')
            Assert-True ($defaultRoute.ExitCode -eq 0 -and $defaultRoute.Output.Contains($expected)) "wrong default brief route: $($route -join '/')"
        }
        else {
            Assert-True ($routed.Output -match '(?s)## Return.*Commit only when assigned\.' -and $routed.Output -notmatch 'Leave changes uncommitted') "Claude commit wording: $($route -join '/')"
        }
    }
    foreach ($override in @(@('codex','gpt-6.1-terra'),@('codex','gpt-6.2-sol'),@('claude','claude-haiku-5-5'),@('claude','claude-sonnet-5-5'),@('claude','claude-opus-5-5'))) {
        $chosen = Invoke-NewBrief @('-Repo','pipeline-tools','-Topic','model-policy','-Risk','HIGH','-Executor',$override[0],'-Model',$override[1],'-DryRun')
        Assert-True ($chosen.ExitCode -eq 0 -and $chosen.Output.Contains('Executor: ' + $override[0] + ' `' + $override[1] + '`; effort `high`.')) 'explicit allowed model not rendered'
    }
    foreach ($risk in @('LOW', 'MEDIUM', 'HIGH')) {
        $astraDir = Join-Path $work "astra-$risk"
        $astra = Invoke-NewBrief @('-Repo','pipeline-tools','-Topic','model-policy','-Executor','codex','-Risk',$risk,'-Model','gpt-6.2-astra','-RunDir',$astraDir)
        $astraBrief = Join-Path $astraDir 'brief.md'
        Assert-True ($astra.ExitCode -eq 0 -and (Test-Path -LiteralPath $astraBrief) -and (Get-Content -Raw -LiteralPath $astraBrief).Contains('Executor: codex `gpt-6.2-astra`; effort `high`.')) "Astra brief missing model or default high effort at $risk"
    }
    $astraXhigh = Invoke-NewBrief @('-Repo','pipeline-tools','-Topic','model-policy','-Executor','codex','-Risk','LOW','-Model','gpt-6.2-astra','-Effort','xhigh','-DryRun')
    Assert-True ($astraXhigh.ExitCode -eq 0 -and $astraXhigh.Output.Contains('Executor: codex `gpt-6.2-astra`; effort `xhigh`.')) 'Astra brief ignored explicit xhigh effort'
    $astraMedium = Invoke-NewBrief @('-Repo','pipeline-tools','-Topic','model-policy','-Executor','codex','-Model','gpt-6.2-astra','-Effort','medium','-DryRun')
    Assert-True ($astraMedium.ExitCode -ne 0 -and $astraMedium.Output -match 'gpt-6\.2-astra requires high or xhigh effort') 'Astra brief must refuse medium effort with a reason'
    $invalidModels = @(@('codex','gpt-6-luna'),@('codex','gpt-6-astra'),@('codex','gpt-6-sol'),@('codex','gpt-6.2-nova'),@('codex','claude-opus-5-5'),@('claude','claude-opus-5'),@('claude','claude-sonnet-5'),@('claude','gpt-6.2-sol'))
    foreach ($invalid in $invalidModels) {
        $bad = Invoke-NewBrief @('-Repo','pipeline-tools','-Topic','model-policy','-Executor',$invalid[0],'-Model',$invalid[1],'-DryRun')
        Assert-True ($bad.ExitCode -ne 0) "invalid brief model accepted: $($invalid -join '/')"
    }
    foreach ($executor in @('codex', 'claude')) {
        $rejectedEffort = Invoke-NewBrief @('-Repo','pipeline-tools','-Topic','effort-policy','-Executor',$executor,'-Effort','low','-DryRun')
        Assert-True ($rejectedEffort.ExitCode -ne 0 -and $rejectedEffort.Output -match 'ValidateSet' -and $rejectedEffort.Output -match 'medium,high,xhigh') "$executor low effort must fail parameter validation with the allowed set"
    }
    $effortPath = $env:PATH
    $effortGit = Split-Path (Get-Command git).Source -Parent
    try {
        $env:PATH = "$PSHOME;$env:SystemRoot\System32;$effortGit"
        foreach ($route in @(@('LOW','claude-haiku-5-5','medium'),@('MEDIUM','claude-sonnet-5-5','medium'),@('HIGH','claude-opus-5-5','high'))) {
            foreach ($model in @('gpt-6.1-terra','gpt-6.2-sol','gpt-6.2-astra')) {
                $fallback = Invoke-NewBrief @('-Repo','pipeline-tools','-Topic','model-policy','-Executor','codex','-Risk',$route[0],'-Model',$model,'-DryRun')
                Assert-True ($fallback.ExitCode -eq 0 -and $fallback.Output.Contains('Executor: claude `' + $route[1] + '`; effort `' + $route[2] + '`.')) "wrong no-Codex fallback: $model/$($route[0])"
            }
        }
        $retiredFallback = Invoke-NewBrief @('-Repo','pipeline-tools','-Topic','model-policy','-Executor','codex','-Model',$invalidModels[0][1],'-DryRun')
        Assert-True ($retiredFallback.ExitCode -ne 0 -and $retiredFallback.Output -match 'Unsupported Codex executor model') 'no-Codex fallback accepted retired model'
    }
    finally { $env:PATH = $effortPath }
    $sampleApp = Invoke-NewBrief @('-Repo', 'sample-app', '-Topic', 'probe', '-DryRun')
    Assert-True ($sampleApp.ExitCode -eq 0) 'sample-app brief dry run failed'
    Assert-True ($sampleApp.Output -notmatch 'test-executor-capabilities|Probe once|scope and fingerprint') 'rendered brief still requires probe or fingerprint'
    Assert-True ($sampleApp.Output.Contains('Report each command with exit, count, and log. Do not rerun matching green evidence.')) 'brief evidence rule missing'
    Assert-True ($sampleApp.Output -match '(?m)^Depends on: none\.\r?$') 'default dependency must be none'
    Assert-True ($sampleApp.Output -match '(?m)^Long steps: none\.\r?$') 'default long steps must be none'
    Assert-True (-not $sampleApp.Output.Contains('Repo notes:')) 'absent notes rendered a heading'
    Assert-True ($sampleApp.Output -match 'next step\.\r?\n\r?\n## Verify') 'absent notes added extra blank lines'
    # Ponytail rules from the first paragraph through "Never cut:", as one section right before Return.
    $economy = [regex]::Match($sampleApp.Output, '(?ms)^## Code economy\r?$.*?(?=^## )')
    Assert-True ($economy.Success -and $sampleApp.Output.Substring($economy.Index + $economy.Length).StartsWith('## Return')) 'Code economy must be the section right before Return'
    Assert-True ($economy.Value -match "(?s)^## Code economy\r?\n\r?\nPonytail v5\.3\.3 \(``7801d06``\)[^\r\n]*Report what you skipped or did not check in the report's Risks line\.\r?\n\r?\nYou are a lazy senior developer\..*### The smallest complete change.*\r?\nNever cut: [^\r\n]*anything the user asked for\.\r?\n\r?\n$") "Code economy pin, adapter or ruleset wrong: $($economy.Value)"
    $vendorRules = ((Get-Content -LiteralPath (Join-Path $root 'vendor\ponytail\AGENTS.md'))[2..29] -replace '^## ', '### ') -join "`n"
    Assert-True ($economy.Value.Replace("`r`n", "`n").EndsWith($vendorRules + "`n`n")) 'Code economy lost or changed vendored rules'
    Assert-True ([regex]::Matches($sampleApp.Output, '(?m)^## Code economy\r?$').Count -eq 1 -and [regex]::Matches($sampleApp.Output, '(?m)^You are a lazy senior developer\.').Count -eq 1) 'Code economy rules rendered more than once'
    Assert-True ($sampleApp.Output -notmatch 'lazy senior dev mode|ponytail repo itself') 'ponytail H1 or closing parenthetical rendered'
    $sampleWeb = Invoke-NewBrief @('-Repo', 'sample-web', '-Topic', 'deadline-notes', '-DryRun')
    Assert-True ($sampleWeb.ExitCode -eq 0 -and $sampleWeb.Output.Contains('npm run test:ci -- --maxWorkers=6')) 'SampleWeb bounded concurrency gate not rendered'
    Assert-True ($sampleWeb.Output.Contains('node --test scripts/*.test.mjs') -and $sampleWeb.Output.Contains('.github/') -and $sampleWeb.Output.Contains('Ops tooling tests') -and $sampleWeb.Output.Contains('not part of `test:ci`')) 'SampleWeb ops tooling note not rendered'
    Assert-True ($sampleWeb.Output.Contains('packages/crawler') -and $sampleWeb.Output.Contains('5 s')) 'SampleWeb PDF timeout explanation missing'
    $dependent = Invoke-NewBrief @('-Repo', 'sample-app', '-Topic', 'dependent', '-DependsOn', 'lot-a', '-DryRun')
    Assert-True ($dependent.ExitCode -eq 0 -and $dependent.Output -match '(?m)^Depends on: lot-a\.\r?$') '-DependsOn did not render'
    foreach ($text in @(
            $sampleRepo,
            'flutter test <target>',
            'flutter analyze',
            '\build\pipeline\probe',
            'ci-sample-app.yml',
            'none — bounded design approved in chat',
            'effort `medium`',
            'templates\report.md'
        )) {
        Assert-True ($sampleApp.Output.Contains($text)) "sample-app brief missing $text"
    }
    Assert-True ($sampleApp.Output -match 'branch `[^`\s]+`') 'Git repository branch was missing'
    Assert-True (-not $sampleApp.Output.Contains('{{')) 'unexpanded placeholder in the sample-app brief'
    Assert-True ($sampleApp.Output.Contains('Issue: none.')) 'issue must render none without -Issue'
    Assert-True ($sampleApp.Output.Contains('Gate owner: executor; after the last edit run') -and $sampleApp.Output.Contains('run-gate.ps1') -and $sampleApp.Output.Contains('matching green `gate.json`')) 'executor-owned gate text missing for sample-app'
    $hubDate = Get-Date -Format 'yyyy-MM-dd'
    $hubBrief = Invoke-NewBrief @('-Repo', 'sample-log', '-Topic', 'gate-owner', '-DryRun')
    $hubCommand = "Gate owner: executor; after the last edit run ``pwsh -NoProfile -File '$root\bin\run-gate.ps1' -Repo '$logRepo' -RunDir '$root\runs\sample-log\$hubDate-gate-owner'`` once and fix red in context; the launcher reuses a matching green ``gate.json``."
    Assert-True ($hubBrief.ExitCode -eq 0 -and $hubBrief.Output.Contains($hubCommand)) "executor-owned gate command missing: $($hubBrief.Output)"
    Assert-True (-not $hubBrief.Output.Contains('run only targeted tests')) 'executor-owned brief keeps the launcher text'
    $opsBrief = Invoke-NewBrief @('-Repo', 'pipeline-tools', '-Topic', 'gate-owner', '-DryRun')
    Assert-True ($opsBrief.ExitCode -eq 0 -and $opsBrief.Output.Contains('Gate owner: executor; after the last edit run') -and $opsBrief.Output.Contains('bin\run-gate.ps1') -and $opsBrief.Output.Contains('Full gate: `pwsh -NoProfile -File tests\run-all.ps1`')) 'pipeline-tools parallel gate is not executor-owned'
    $pumpRunDir = Join-Path $work 'run-sample-log'
    $pumpBrief = Invoke-NewBrief @('-Repo', 'sample-log', '-Topic', 'gate-owner', '-RunDir', $pumpRunDir, '-DryRun')
    Assert-True ($pumpBrief.Output.Contains("run-gate.ps1' -Repo '$logRepo' -RunDir '$pumpRunDir'``")) 'executor gate command does not name the target path and -RunDir'

    $arrayRegistryPath = Join-Path $root 'config\executors.json'
    $arrayRegistryText = [IO.File]::ReadAllText($arrayRegistryPath)
    $arrayRegistry = $arrayRegistryText | ConvertFrom-Json
    $arrayRegistry.executors.'sample-log'.commands.fullGate = @('npm run test:run', 'node --test test/example.js')
    $arrayRegistry | ConvertTo-Json -Depth 32 | Set-Content $arrayRegistryPath
    $arrayBrief = Invoke-NewBrief @('-Repo', 'sample-log', '-Topic', 'array-gate', '-DryRun')
    Assert-True ($arrayBrief.ExitCode -eq 0 -and $arrayBrief.Output.Contains('Full gate: `npm run test:run` and `node --test test/example.js`, 2 commands from the repository root (run-gate runs each)')) 'array fullGate rendered as a joined command'
    [IO.File]::WriteAllText($arrayRegistryPath, $arrayRegistryText)

    $registry = Get-Content -Raw -LiteralPath (Join-Path $root 'config\executors.json') | ConvertFrom-Json
    Assert-True ($registry.executors.'sample-app'.gateOwner -eq 'executor' -and $registry.executors.'pipeline-tools'.gateOwner -eq 'executor') 'short registry gates must be executor-owned'
    foreach ($entry in $registry.executors.PSObject.Properties) {
        $expectedGithub = switch ($entry.Name) { 'sample-log' { 'fixture-team/SampleLog' } 'sample-app' { 'fixture-team/SampleApp' } 'sample-web' { 'fixture-team/SampleWeb' } default { $null } }
        if ($expectedGithub) {
            Assert-True ($entry.Value.github -eq $expectedGithub -and $null -eq $entry.Value.PSObject.Properties['tracker']) "generic GitHub mapping missing for $($entry.Name)"
        }
        else {
            Assert-True ($null -eq $entry.Value.PSObject.Properties['tracker']) "unexpected tracker override: $($entry.Name)"
        }
    }
    . (Join-Path $root 'bin\RunCommon.ps1')
    $team = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot '..\skills\pipeline\config\executors.json') | ConvertFrom-Json
    foreach ($entry in $team.executors.PSObject.Properties) {
        $actual = $registry.executors.PSObject.Properties[$entry.Name].Value
        $resolved = Resolve-ExecutorTarget $root $entry.Name
        Assert-True ($resolved.Path -eq $actual.repo -and $actual.repo.StartsWith($work)) "team alias path mismatch: $($entry.Name)"
        Assert-True (($actual.commands | ConvertTo-Json -Depth 12 -Compress) -ceq ($entry.Value.commands | ConvertTo-Json -Depth 12 -Compress)) "team commands changed: $($entry.Name)"
        if ($entry.Value.PSObject.Properties['briefNotes']) {
            Assert-True (($actual.briefNotes | ConvertTo-Json -Compress) -ceq ($entry.Value.briefNotes | ConvertTo-Json -Compress)) "team notes changed: $($entry.Name)"
        }
    }
    $api = $team.executors.'acme-api'
    Assert-True ($api.gateRetries -eq 0 -and $api.heavyGate -eq $true) 'acme-api heavy gate policy differs'
    Assert-True ($api.commands.fullGate -is [array] -and $api.commands.fullGate.Count -eq 2 -and @($api.commands.fullGate | Where-Object { $_ -notmatch 'Category=Integration' }).Count -eq 0) 'acme-api gate array differs'
    Assert-True ($api.gateTimeoutMinutes -eq 30 -and @($api.briefNotes | Where-Object { $_.StartsWith('Before the report, run the whole unit suite') }).Count -eq 1) 'acme-api gate timeout or unit-suite note missing'
    foreach ($entry in $registry.executors.PSObject.Properties) {
        Assert-True (($entry.Value.commands | ConvertTo-Json -Compress) -notmatch '/p:') "Git Bash unsafe command: $($entry.Name)"
    }
    $issueJson = Join-Path $work 'issue.json'
    [pscustomobject]@{ number=234; title='Fixture'; url='https://github.com/fixture-team/SampleApp/issues/234'; body="Intro`n- [ ] First acceptance`n- [x] Already completed`n  - [ ] Indented acceptance`n- [X] Also completed" } | ConvertTo-Json | Set-Content -LiteralPath $issueJson -Encoding utf8
    $issue = Invoke-NewBrief @('-Repo', 'sample-app', '-Topic', 'issue', '-Issue', '234', '-IssueJson', $issueJson, '-DryRun')
    Assert-True ($issue.ExitCode -eq 0) "offline issue brief failed: $($issue.Output.Trim())"
    Assert-True ($issue.Output.Contains('Issue: https://github.com/fixture-team/SampleApp/issues/234.')) 'issue URL not rendered'
    Assert-True ($issue.Output -match '(?m)^- First acceptance\r?$' -and $issue.Output -match '(?m)^- Indented acceptance\r?$') 'unchecked acceptance not rendered as Done-when bullets'
    Assert-True ($issue.Output -notmatch 'Already completed|Also completed') 'checked acceptance included'
    Assert-True ($issue.Output -notmatch '<fill: observable acceptance') 'default Done-when hint kept with acceptance lines'
    Assert-True ($issue.Output -match '<fill: reviewer check') 'reviewer acceptance hint was removed'
    $noAcceptanceJson = Join-Path $work 'no-acceptance.json'
    [pscustomobject]@{ number=234; url='https://github.com/fixture-team/SampleApp/issues/234'; body='- [x] Complete' } | ConvertTo-Json | Set-Content -LiteralPath $noAcceptanceJson -Encoding utf8
    $noAcceptance = Invoke-NewBrief @('-Repo', 'sample-app', '-Topic', 'no-acceptance', '-Issue', '234', '-IssueJson', $noAcceptanceJson, '-DryRun')
    Assert-True ($noAcceptance.ExitCode -eq 0 -and $noAcceptance.Output.Contains('<fill: observable acceptance')) 'empty checklist should keep template hint'
    $noTracker = Invoke-NewBrief @('-Repo', 'pipeline-tools', '-Topic', 'no-tracker', '-Issue', '234', '-IssueJson', $issueJson, '-DryRun')
    Assert-True ($noTracker.ExitCode -ne 0 -and $noTracker.Output -match 'no GitHub identity: no origin remote') 'missing GitHub identity reason not reported'
    $mismatch = Invoke-NewBrief @('-Repo', 'sample-app', '-Topic', 'mismatch', '-Issue', '235', '-IssueJson', $issueJson, '-DryRun')
    Assert-True ($mismatch.ExitCode -ne 0 -and $mismatch.Output -match 'number') 'mismatched fixture issue accepted'
    $orphan = Invoke-NewBrief @('-Repo', 'sample-app', '-Topic', 'orphan', '-IssueJson', $issueJson, '-DryRun')
    Assert-True ($orphan.ExitCode -ne 0 -and $orphan.Output -match 'IssueJson.*Issue') '-IssueJson accepted without -Issue'
    $badIssueJson = Join-Path $work 'bad-issue.json'
    Set-Content -LiteralPath $badIssueJson -Value '{bad' -Encoding utf8
    $badIssue = Invoke-NewBrief @('-Repo', 'sample-app', '-Topic', 'bad-issue', '-Issue', '234', '-IssueJson', $badIssueJson, '-DryRun')
    Assert-True ($badIssue.ExitCode -ne 0) 'malformed issue fixture accepted'
    $ghDir = Join-Path $work 'gh-stub'
    New-Item -ItemType Directory -Path $ghDir | Out-Null
    $ghCalls = Join-Path $work 'gh-called.txt'
    Set-Content -LiteralPath (Join-Path $ghDir 'gh.cmd') -Value "@echo off`r`necho called>> `"$ghCalls`"`r`nexit /b 99" -Encoding ascii
    $oldPath = $env:PATH
    try {
        $env:PATH = "$ghDir;$oldPath"
        $offlineDry = Invoke-NewBrief @('-Repo', 'sample-app', '-Topic', 'offline-dry', '-Issue', '234', '-IssueJson', $issueJson, '-DryRun')
        Assert-True ($offlineDry.ExitCode -eq 0) 'offline dry run failed'
        $liveDry = Invoke-NewBrief @('-Repo', 'sample-app', '-Topic', 'live-dry', '-Issue', '234', '-DryRun')
        Assert-True ($liveDry.ExitCode -eq 0 -and $liveDry.Output.Contains('https://github.com/fixture-team/SampleApp/issues/234')) 'dry run without fixture should render canonical URL'
        Assert-True ($liveDry.Output.Contains('<fill: observable acceptance')) 'dry run without fixture should retain acceptance hint'
        Assert-True (-not (Test-Path -LiteralPath $ghCalls)) '-DryRun called gh'
    }
    finally { $env:PATH = $oldPath }

    $fixtureHub = Join-Path $work 'fixture-hub'
    foreach ($relative in @('bin\new-brief.ps1','bin\RunCommon.ps1','templates\brief.md','templates\report.md','vendor\ponytail\AGENTS.md','vendor\ponytail\LICENSE','vendor\ponytail\SOURCE.md')) {
        $destination = Join-Path $fixtureHub $relative
        New-Item -ItemType Directory -Force -Path (Split-Path $destination -Parent) | Out-Null
        Copy-Item -LiteralPath (Join-Path $root $relative) -Destination $destination
    }
    $fixtureRepo = Join-Path $work 'tracker-repo'
    New-Item -ItemType Directory -Path $fixtureRepo | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $fixtureHub 'config') | Out-Null
    $registry.executors.'sample-app'.repo = $fixtureRepo
    $registry.executors.'sample-app'.logDir = 'logs'
    $registry.defaults | Add-Member -NotePropertyName githubAccounts -NotePropertyValue ([pscustomobject]@{ $work = 'fixture-reader' }) -Force
    $registry | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $fixtureHub 'config\executors.json') -Encoding utf8
    $fakeToken = 'fixture-owner-token'
    $stubText = @"
@echo off
if "%~1"=="auth" goto auth
if "%~1"=="issue" goto issue
exit /b 95
:auth
if not "%~2"=="token" exit /b 98
if not "%~3"=="--user" exit /b 98
if not "%~4"=="fixture-reader" exit /b 98
echo auth-owner-ok>> "$ghCalls"
if "%STUB_FAILURE%"=="auth" goto auth-failed
echo $fakeToken
exit /b 0
:auth-failed
echo $fakeToken 1>&2
exit /b 97
:issue
if "%GH_TOKEN%"=="$fakeToken" (echo issue-token-ok>> "$ghCalls") else (echo issue-token-missing>> "$ghCalls")
if "%STUB_FAILURE%"=="issue" goto issue-failed
type "$issueJson"
exit /b 0
:issue-failed
echo $fakeToken 1>&2
exit /b 96
"@
    Set-Content -LiteralPath (Join-Path $ghDir 'gh.cmd') -Value $stubText -Encoding ascii
    $tokenWrapper = Join-Path $work 'token-wrapper.ps1'
    @'
param([string]$ScriptPath, [string]$RunDir, [string]$PreviousMode, [string]$Failure)
$previousToken = if ($PreviousMode -eq 'present') { 'fixture-prior-token' } else { $null }
[Environment]::SetEnvironmentVariable('GH_TOKEN', $previousToken, 'Process')
$previousToken = [Environment]::GetEnvironmentVariable('GH_TOKEN', 'Process')
$env:STUB_FAILURE = $Failure
$resultCode = 0
$env:PIPELINE_HOME = Split-Path (Split-Path $ScriptPath)
try { & $ScriptPath -Repo sample-app -Topic live-fixture -Issue 234 -RunDir $RunDir }
catch { Write-Output "ERROR: $($_.Exception.Message)"; $resultCode = 1 }
finally {
    $restored = [Environment]::GetEnvironmentVariable('GH_TOKEN', 'Process') -ceq $previousToken
    Write-Output "TOKEN_RESTORED=$restored"
}
exit $resultCode
'@ | Set-Content -LiteralPath $tokenWrapper -Encoding utf8
    try {
        $env:PATH = "$ghDir;$oldPath"
        foreach ($case in @(@('present','none'), @('absent','none'), @('present','auth'), @('present','issue'))) {
            Set-Content -LiteralPath $ghCalls -Value '' -Encoding ascii
            $liveRun = Join-Path $work ("live-$($case[0])-$($case[1])")
            $liveOutput = (& pwsh -NoProfile -File $tokenWrapper -ScriptPath (Join-Path $fixtureHub 'bin\new-brief.ps1') -RunDir $liveRun -PreviousMode $case[0] -Failure $case[1] 2>&1 | Out-String)
            $liveExit = $LASTEXITCODE
            $calls = @(Get-Content -LiteralPath $ghCalls | Where-Object { $_ } | ForEach-Object { $_.Trim() })
            Assert-True ($liveOutput.Contains('TOKEN_RESTORED=True')) "GH_TOKEN not restored for $($case -join '/')"
            Assert-True (-not $liveOutput.Contains($fakeToken)) 'owner token leaked in output'
            if ($case[1] -eq 'auth') {
                Assert-True ($liveExit -ne 0 -and $liveOutput -match 'token.*fixture-reader|fixture-reader.*token') 'mapped-account token failure must be clear'
                Assert-True (($calls -join ',') -eq 'auth-owner-ok') 'issue view called after token lookup failed'
            }
            else {
                Assert-True (($calls -join ',') -eq 'auth-owner-ok,issue-token-ok') 'owner token not scoped to issue view'
                if ($case[1] -eq 'issue') {
                    Assert-True ($liveExit -ne 0 -and $liveOutput -match 'gh issue view failed') ("issue view failure not reported (exit $liveExit): " + $liveOutput.Replace($fakeToken, '[redacted]').Trim())
                }
                else {
                    Assert-True ($liveExit -eq 0) 'stub live issue brief failed'
                    $savedBriefPath = Join-Path $liveRun 'brief.md'
                    Assert-True (Test-Path -LiteralPath $savedBriefPath) 'stub live brief was not written'
                    if (Test-Path -LiteralPath $savedBriefPath) {
                        $savedBrief = Get-Content -Raw -LiteralPath $savedBriefPath
                        Assert-True ($savedBrief.Contains('https://github.com/fixture-team/SampleApp/issues/234') -and $savedBrief.Contains('- First acceptance')) 'live issue content missing'
                        Assert-True (-not $savedBrief.Contains($fakeToken)) 'owner token persisted in brief'
                    }
                }
            }
        }
    }
    finally { $env:PATH = $oldPath }

    $highRisk = Invoke-NewBrief @('-Repo', 'sample-app', '-Topic', 'high-risk', '-Risk', 'HIGH', '-DryRun')
    Assert-True ($highRisk.ExitCode -eq 0 -and $highRisk.Output.Contains('effort `high`')) 'HIGH brief did not default to high effort'
    $highExplicit = Invoke-NewBrief @('-Repo', 'sample-app', '-Topic', 'high-explicit', '-Risk', 'HIGH', '-Effort', 'medium', '-DryRun')
    Assert-True ($highExplicit.ExitCode -eq 0 -and $highExplicit.Output.Contains('effort `medium`')) 'explicit effort did not override the HIGH default'

    $fakeRepo = Join-Path $work 'fake-repo'
    $workflowDir = Join-Path $fakeRepo '.github\workflows'
    New-Item -ItemType Directory -Path $workflowDir -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $workflowDir 'ci.yml') -Value 'name: ci' -Encoding utf8
    Set-Content -LiteralPath (Join-Path $fakeRepo 'CLAUDE.md') -Value '# Rules' -Encoding utf8
    $fake = Invoke-NewBrief @('-Repo', $fakeRepo, '-Topic', 't', '-Plan', 'D:\p.md', '-Tasks', '1-2', '-Risk', 'LOW', '-Effort', 'medium', '-Executor', 'claude', '-DryRun')
    Assert-True ($fake.ExitCode -eq 0) "fixture repository brief dry run failed: $($fake.Output.Trim())"
    foreach ($text in @('not a git repository — do not run git', 'D:\p.md', 'tasks 1-2', '<fill: command>', 'ci.yml', 'effort `medium`', 'Executor: claude', 'LOW', 'CLAUDE.md / AGENTS.md in the repository root')) {
        Assert-True ($fake.Output.Contains($text)) "fake repository brief missing $text"
    }
    Set-Content -LiteralPath (Join-Path $fakeRepo 'CLAUDE.md') -Value ((1..201 | ForEach-Object { 'A rule.' }) -join "`n") -Encoding utf8
    $oversized = Invoke-NewBrief @('-Repo', $fakeRepo, '-Topic', 'oversized', '-DryRun')
    Assert-True ($oversized.ExitCode -eq 0 -and $oversized.Output -match 'warning: CLAUDE.md .*201 lines.*bytes') 'oversized fixture CLAUDE.md warning missing'

    $emptyRepo = Join-Path $work 'empty-repo'
    New-Item -ItemType Directory -Path $emptyRepo | Out-Null
    $empty = Invoke-NewBrief @('-Repo', $emptyRepo, '-Topic', 'empty', '-DryRun')
    Assert-True ($empty.ExitCode -eq 0) 'dry run for an empty repository failed'
    Assert-True ($empty.Output.Contains('Remote CI: missing')) 'missing CI was not reported'
    Assert-True ($empty.Output.Contains('none in the repository root')) 'missing instructions were not reported'

    $sidecarRun = Join-Path $work 'sidecar-render'
    $sidecarPath = Join-Path $sidecarRun 'brief.gate.json'
    $sidecar = Invoke-NewBrief @('-Repo', $emptyRepo, '-Topic', 'sidecar', '-RunDir', $sidecarRun, '-GateCommand', 'Write-Output gate')
    Assert-True ($sidecar.ExitCode -eq 0 -and (Test-Path -LiteralPath $sidecarPath)) 'gate command did not write sidecar'
    if (Test-Path -LiteralPath $sidecarPath) {
        $data = Get-Content -Raw -LiteralPath $sidecarPath | ConvertFrom-Json
        Assert-True ($data.command -eq 'Write-Output gate' -and $data.owner -eq 'launcher') 'command-only sidecar did not use rendered owner'
        $bytes = [IO.File]::ReadAllBytes($sidecarPath)
        Assert-True (-not ($bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191)) 'sidecar has UTF-8 BOM'
    }
    $ownerOnly = Invoke-NewBrief @('-Repo', 'sample-app', '-Topic', $logTopic, '-RunDir', $sidecarRun, '-GateOwner', 'Launcher', '-Force')
    Assert-True ($ownerOnly.ExitCode -eq 0 -and (Test-Path -LiteralPath $sidecarPath)) 'owner-only render did not write sidecar'
    if (Test-Path -LiteralPath $sidecarPath) {
        $data = Get-Content -Raw -LiteralPath $sidecarPath | ConvertFrom-Json
        Assert-True ($data.command -eq 'flutter test --concurrency=3' -and $data.owner -eq 'launcher') 'owner-only sidecar did not use rendered gate'
    }
    $executor = Invoke-NewBrief @('-Repo', $emptyRepo, '-Topic', 'sidecar', '-RunDir', $sidecarRun, '-GateCommand', 'Write-Output executor-gate', '-GateOwner', 'Executor', '-Force')
    if (Test-Path -LiteralPath $sidecarPath) {
        $data = Get-Content -Raw -LiteralPath $sidecarPath | ConvertFrom-Json
        Assert-True ($executor.ExitCode -eq 0 -and $data.command -eq 'Write-Output executor-gate' -and $data.owner -eq 'executor') 'executor sidecar values missing'
    }
    $refused = Invoke-NewBrief @('-Repo', $emptyRepo, '-Topic', 'sidecar', '-RunDir', $sidecarRun)
    Assert-True ($refused.ExitCode -ne 0 -and (Test-Path -LiteralPath $sidecarPath)) 'refused overwrite removed sidecar'
    $cleared = Invoke-NewBrief @('-Repo', $emptyRepo, '-Topic', 'sidecar', '-RunDir', $sidecarRun, '-Force')
    Assert-True ($cleared.ExitCode -eq 0 -and -not (Test-Path -LiteralPath $sidecarPath)) 'force render without gate flags retained stale sidecar'

    $gitRepo = Join-Path $work 'unregistered-git'
    New-Item -ItemType Directory -Path $gitRepo | Out-Null
    & git -C $gitRepo init -b fixture-branch *> $null
    Assert-True ($LASTEXITCODE -eq 0) 'fixture git init failed'
    $emptyGit = Invoke-NewBrief @('-Repo', $gitRepo, '-Topic', 'empty-git', '-DryRun')
    Assert-True ($emptyGit.ExitCode -eq 0 -and $emptyGit.Output.Contains('branch `fixture-branch`')) 'unregistered empty Git branch not read'
    # Executor ownership requires an executable full gate, including for unregistered targets.
    foreach ($target in @($emptyRepo, $gitRepo)) {
        $missingGate = Invoke-NewBrief @('-Repo', $target, '-Topic', 'missing-gate', '-GateOwner', 'executor', '-DryRun')
        Assert-True ($missingGate.ExitCode -ne 0 -and $missingGate.Output -match '-GateCommand' -and $missingGate.Output -match 'commands.fullGate') 'executor owner without a full gate was not clearly refused'
    }
    foreach ($command in @('none', ' ')) {
        $disabledGate = Invoke-NewBrief @('-Repo', $gitRepo, '-Topic', 'disabled-gate', '-GateOwner', 'executor', '-GateCommand', $command, '-DryRun')
        Assert-True ($disabledGate.ExitCode -ne 0 -and $disabledGate.Output -match '-GateCommand' -and $disabledGate.Output -match 'commands.fullGate') 'executor owner with a disabled full gate was not clearly refused'
    }
    $disabledRegistryGate = Invoke-NewBrief @('-Repo', 'sample-log', '-Topic', 'disabled-registry-gate', '-GateCommand', 'none', '-DryRun')
    Assert-True ($disabledRegistryGate.ExitCode -ne 0 -and $disabledRegistryGate.Output -match '-GateCommand') 'registry executor owner accepted explicit none gate'
    $explicitExecutorGate = Invoke-NewBrief @('-Repo', $gitRepo, '-Topic', 'explicit-executor-gate', '-GateOwner', 'executor', '-GateCommand', 'Write-Output gate', '-DryRun')
    Assert-True ($explicitExecutorGate.ExitCode -eq 0 -and $explicitExecutorGate.Output.Contains("-GateCommand 'Write-Output gate'")) 'executor owner refused a real explicit gate command'
    Set-Content -LiteralPath (Join-Path $gitRepo 'README.md') -Value 'fixture'
    & git -C $gitRepo -c user.name=Fixture -c user.email=fixture@example.invalid add README.md *> $null
    & git -C $gitRepo -c user.name=Fixture -c user.email=fixture@example.invalid commit -m fixture *> $null
    Assert-True ($LASTEXITCODE -eq 0) 'fixture git commit failed'
    $unregistered = Invoke-NewBrief @('-Repo', $gitRepo, '-Topic', 'probe', '-DryRun')
    Assert-True ($unregistered.ExitCode -eq 0) "unregistered Git repo refused: $($unregistered.Output)"
    foreach ($text in @('unregistered-git', 'branch `fixture-branch`', 'Full gate: `none`', 'Targeted: `none`', 'build\pipeline\probe', 'Gate owner: launcher; run only targeted tests and analysis')) {
        Assert-True ($unregistered.Output.Contains($text)) "unregistered Git brief misses $text"
    }

    . (Join-Path $root 'bin\RunCommon.ps1')
    Copy-Item -LiteralPath (Join-Path $root 'config\projects.json') -Destination (Join-Path $fixtureHub 'config\projects.json')
    $worktree = Join-Path $work '.worktrees\unregistered-win-lag'
    & git -C $gitRepo worktree add -b fixture-worktree $worktree *> $null
    Assert-True ($LASTEXITCODE -eq 0) 'fixture worktree add failed'
    & git -C $gitRepo remote add origin git@github.com:fixture-team/acme-api.git *> $null
    $identity = Resolve-ExecutorTarget $fixtureHub $worktree
    Assert-True ($identity.Alias -eq 'unregistered-git' -and $identity.Path -eq $worktree -and $identity.Root -eq $gitRepo -and $identity.GitHub -eq 'fixture-team/acme-api' -and $null -eq $identity.Entry) 'unregistered worktree identity did not use main checkout'
    $registry.executors | Add-Member -NotePropertyName registered-services -NotePropertyValue ([pscustomobject]@{ repo = $gitRepo; github = 'registry-team/services'; commands = $registry.executors.'sample-app'.commands; logDir = 'logs'; briefNotes = @('Fixture note with `$literal and {{placeholder}}.', 'Second inherited note.') })
    $registry | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $fixtureHub 'config\executors.json')
    $registered = Resolve-ExecutorTarget $fixtureHub $worktree
    Assert-True ($registered.Alias -eq 'registered-services' -and $registered.Path -eq $worktree -and $registered.Root -eq $gitRepo -and $registered.GitHub -eq 'registry-team/services' -and $null -ne $registered.Entry) 'registered worktree did not inherit registry identity'
    $env:PIPELINE_HOME = $fixtureHub
    $notesOutput = (& pwsh -NoProfile -File (Join-Path $fixtureHub 'bin\new-brief.ps1') -Repo $worktree -Topic inherited -DryRun 2>&1 | Out-String)
    Assert-True ($LASTEXITCODE -eq 0) 'registered worktree brief failed'
    Assert-True ($notesOutput -match 'next step\.\r?\n\r?\nRepo notes:') 'notes need exactly one blank line after Known state'
    Assert-True ($notesOutput -match '(?s)Repo notes:\r?\n- Fixture note with `\$literal and \{\{placeholder\}\}\.\r?\n- Second inherited note\.\r?\n\r?\n## Verify') 'worktree notes not preserved at end of Known state'
    Assert-True ($notesOutput.Contains('Targeted: `flutter test <target>`') -and $notesOutput.Contains('Full gate: `flutter test --concurrency=3`')) 'worktree did not inherit registry commands'
    $registry.executors.PSObject.Properties.Remove('registered-services')
    $registry.defaults.githubAccounts | Add-Member -NotePropertyName $gitRepo -NotePropertyValue 'nested-reader'
    $registry | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $fixtureHub 'config\executors.json')
    Assert-True ((Get-GitHubAccount $fixtureHub $identity.Root) -eq 'nested-reader') 'longest main-checkout account prefix did not win'
    Assert-True ((Get-GitHubAccount $fixtureHub ($gitRepo + '-sibling')) -eq 'fixture-reader') 'account prefix crossed a directory boundary'
    $actualAccounts = (Get-ExecutorRegistry $root).Defaults.githubAccounts
    Assert-True ($actualAccounts.PSObject.Properties[$root].Value -eq 'fixture-reader') 'root-folder GitHub accounts missing'
    [pscustomobject]@{ number=234; url='https://github.com/fixture-team/acme-api/issues/234'; body='- [ ] Generic acceptance' } | ConvertTo-Json | Set-Content -LiteralPath $issueJson
    $genericIssue = Invoke-NewBrief @('-Repo', $worktree, '-Topic', 'generic-issue', '-Issue', '234', '-IssueJson', $issueJson, '-DryRun')
    Assert-True ($genericIssue.ExitCode -eq 0 -and $genericIssue.Output.Contains('- Generic acceptance')) 'GitHub-origin worktree issue rejected'
    foreach ($remote in @('https://github.com/fixture-team/acme-api.git', 'ssh://git@github.com/fixture-team/acme-api.git')) {
        & git -C $gitRepo remote set-url origin $remote *> $null
        Assert-True ((Resolve-ExecutorTarget $root $worktree).GitHub -eq 'fixture-team/acme-api') "GitHub origin not recognized: $remote"
    }
    $registry.executors | Add-Member -NotePropertyName opted-out -NotePropertyValue ([pscustomobject]@{ repo=$gitRepo; tracker='none'; commands=$registry.executors.'sample-app'.commands; logDir='logs' })
    $registry | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $fixtureHub 'config\executors.json')
    $optOutOutput = (& pwsh -NoProfile -File (Join-Path $fixtureHub 'bin\new-brief.ps1') -Repo $worktree -Topic opt-out -Issue 234 -IssueJson $issueJson -DryRun 2>&1 | Out-String)
    Assert-True ($LASTEXITCODE -ne 0 -and $optOutOutput -match 'tracker.*none') 'tracker none did not opt out'
    & git -C $gitRepo remote set-url origin https://dev.azure.com/team/project/_git/services *> $null
    $azureIssue = Invoke-NewBrief @('-Repo', $worktree, '-Topic', 'azure', '-Issue', '234', '-IssueJson', $issueJson, '-DryRun')
    Assert-True ($azureIssue.ExitCode -ne 0 -and $azureIssue.Output -match 'origin.*github.com') 'Azure DevOps identity reason missing'
    Assert-True ($null -eq (Resolve-ExecutorTarget $root $worktree).GitHub) 'Azure DevOps produced a GitHub identity'
    & git -C $gitRepo remote remove origin *> $null
    $localIssue = Invoke-NewBrief @('-Repo', $worktree, '-Topic', 'local', '-Issue', '234', '-IssueJson', $issueJson, '-DryRun')
    Assert-True ($localIssue.ExitCode -ne 0 -and $localIssue.Output -match 'no origin remote') 'local Git identity reason missing'
    $plainIdentity = Resolve-ExecutorTarget $root $emptyRepo
    Assert-True ($plainIdentity.Root -eq $emptyRepo -and $plainIdentity.Path -eq $emptyRepo -and $plainIdentity.Alias -eq 'empty-repo' -and $null -eq $plainIdentity.GitHub) 'non-Git identity changed'
    $locks = Join-Path $work 'identity-locks'
    $lock = Enter-RepoLock $locks $worktree 'fixture-run'
    try {
        Assert-True ((Get-RepoLockState $locks $identity.Path).Status -eq 'busy' -and (Get-RepoLockState $locks $gitRepo).Status -eq 'free') 'alias change weakened same-path lock or locked the main checkout'
    } finally { Exit-RepoLock $lock }
    $newRun = New-RunDirPath $fixtureHub $identity.Alias (Join-Path $work '2026-10-06-identity.md')
    Assert-True ($newRun -eq (Join-Path $fixtureHub 'runs\unregistered-git\2026-10-06-identity')) 'run naming did not use repository alias'
    $legacyRun = Join-Path $fixtureHub 'runs\unregistered-win-lag\legacy-run'
    Assert-True ((New-RunDirPath $fixtureHub $identity.Alias (Join-Path $legacyRun 'brief.md')) -eq $legacyRun) 'existing worktree brief run directory changed'

    $runDir = Join-Path $work 'run'
    $write = Invoke-NewBrief @('-Repo', $emptyRepo, '-Topic', 'write', '-RunDir', $runDir)
    $briefPath = Join-Path $runDir 'brief.md'
    Assert-True ($write.ExitCode -eq 0 -and $write.Output -match 'brief:') 'failed to write brief'
    Assert-True (Test-Path -LiteralPath $briefPath) 'brief.md was not written'
    $again = Invoke-NewBrief @('-Repo', $emptyRepo, '-Topic', 'write', '-RunDir', $runDir)
    Assert-True ($again.ExitCode -ne 0 -and $again.Output -match 'brief exists:') 'existing brief overwritten without -Force'
    $force = Invoke-NewBrief @('-Repo', $emptyRepo, '-Topic', 'write', '-RunDir', $runDir, '-Force')
    Assert-True ($force.ExitCode -eq 0) '-Force did not allow an overwrite'
    # The size warning counts only our text: the vendored Code economy section is left out.
    $briefText = Get-Content -Raw -LiteralPath $briefPath
    $economyLength = [regex]::Match($briefText, '(?ms)^## Code economy\r?$.*?(?=^## )').Length
    foreach ($ownTarget in @(5900, 6100)) {
        $padded = $briefText.Replace('## Code economy', ('x' * ($ownTarget - ($briefText.Length - $economyLength))) + "`n`n## Code economy")
        $paddedPath = Join-Path $work "padded-$ownTarget.md"
        [IO.File]::WriteAllText($paddedPath, $padded, $utf8Encoding)
        $sizeOutput = (& pwsh -NoProfile -File (Join-Path $root 'bin\claude-run.ps1') -Repo $emptyRepo -Brief $paddedPath -RunDir (Join-Path $work "size-$ownTarget") -LockDir (Join-Path $work 'locks') -SkipQuotaCheck -DryRun 2>&1 | Out-String)
        $sizeExit = $LASTEXITCODE
        if ($ownTarget -lt 6000) {
            Assert-True ($sizeExit -eq 0 -and $padded.Length -gt 6000 -and $sizeOutput -notmatch 'brief warning:') "Code economy counted in the brief size warning (exit $sizeExit)"
        }
        else {
            Assert-True ($sizeExit -eq 0 -and $sizeOutput -match "(?m)^brief warning: $($padded.Length - $economyLength) characters, above 6000") "brief size warning does not measure our text only (exit $sizeExit)"
        }
    }
    Assert-True ((Get-Content -Raw -LiteralPath $script).Contains('unfilled placeholder')) 'unknown placeholder check was missing'

    # The brief names a log directory the executor is told to write into, and a
    # brief that forbids any other command leaves it unable to create one itself.
    $logWrite = Invoke-NewBrief @('-Repo', 'pipeline-tools', '-Topic', $logTopic, '-RunDir', (Join-Path $work 'run-log'))
    Assert-True ($logWrite.ExitCode -eq 0) "failed to write brief with a log directory: $($logWrite.Output.Trim())"
    Assert-True (Test-Path -LiteralPath $logDir -PathType Container) 'brief log directory was not created'

    foreach ($name in @('AGENTS.md', 'LICENSE', 'SOURCE.md')) {
        $vendorFile = Join-Path $fixtureHub "vendor\ponytail\$name"
        Move-Item -LiteralPath $vendorFile -Destination "$vendorFile.off"
        $missingVendor = (& pwsh -NoProfile -File (Join-Path $fixtureHub 'bin\new-brief.ps1') -Repo $emptyRepo -Topic missing-vendor -DryRun 2>&1 | Out-String)
        Assert-True ($LASTEXITCODE -ne 0 -and $missingVendor -match "(?s)missing vendored ponytail file:.*ponytail\\$([regex]::Escape($name))") "missing vendored $name not refused clearly: $missingVendor"
        Move-Item -LiteralPath "$vendorFile.off" -Destination $vendorFile
    }}
catch {
    $failures.Add($_.Exception.Message)
}
finally {
    [Console]::OutputEncoding = $previousOutputEncoding
    [Console]::InputEncoding = $previousInputEncoding
    Remove-WorkDir $work
    Remove-Item -LiteralPath $logDir -Recurse -Force -ErrorAction SilentlyContinue
}

Assert-True (-not (Test-Path -LiteralPath $work)) "working directory was not removed: $work"

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Error $_ -ErrorAction Continue }
    exit 1
}

Write-Output "new-brief tests: PASS ($assertions assertions)"
