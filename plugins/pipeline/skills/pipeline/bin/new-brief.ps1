[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Repo,

    [Parameter(Mandatory = $true)]
    [string]$Topic,

    [string]$Plan,
    [string]$Spec,
    [string]$Tasks,

    [ValidateRange(1, [int]::MaxValue)]
    [int]$Issue,
    [string]$IssueJson,

    $GateCommand,
    [ValidateSet('executor', 'launcher')]
    [string]$GateOwner,

    [ValidateSet('LOW', 'MEDIUM', 'HIGH')]
    [string]$Risk,

    [ValidateSet('medium', 'high', 'xhigh')]
    [string]$Effort,

    [ValidateSet('codex', 'claude')]
    [string]$Executor = 'codex',

    [string]$Model,

    [string]$DependsOn = 'none',

    [string]$RunDir,
    [switch]$Force,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'RunCommon.ps1')
$SkillRoot = Get-PipelineSkillRoot
$HubRoot = Get-PipelineHome -NoCreate:$DryRun
$repoInfo = Resolve-ExecutorTarget $HubRoot $Repo
$registryEntry = $repoInfo.Entry
$codexModels = @('gpt-6.1-terra', 'gpt-6.2-sol', 'gpt-6.2-astra')
if ($Executor -eq 'codex' -and $Model -eq 'gpt-6.2-astra' -and $Effort -eq 'medium') {
    throw 'gpt-6.2-astra requires high or xhigh effort.'
}
if ($Executor -eq 'codex' -and -not (Get-Command codex -ErrorAction SilentlyContinue)) {
    Write-Warning 'Codex is not on PATH; preparing a Claude executor brief.'
    $Executor = 'claude'
    if ($PSBoundParameters.ContainsKey('Model')) {
        if ($Model -notin $codexModels) { throw "Unsupported Codex executor model '$Model'." }
        $Model = if ($Risk -eq 'HIGH') { 'claude-opus-5-5' } elseif ($Risk -eq 'LOW') { 'claude-haiku-5-5' } else { 'claude-sonnet-5-5' }
    }
}
$templatePath = Join-Path $SkillRoot 'templates\brief.md'
$reportTemplate = Join-Path $SkillRoot 'templates\report.md'

$issueValue = 'none'
$acceptance = @()
if ($IssueJson -and -not $PSBoundParameters.ContainsKey('Issue')) { throw '-IssueJson requires -Issue' }
if ($PSBoundParameters.ContainsKey('Issue')) {
    if ($null -ne $registryEntry -and $null -ne $registryEntry.PSObject.Properties['tracker'] -and $registryEntry.tracker -eq 'none') {
        throw "Repo '$Repo' opts out of GitHub issues with tracker: none."
    }
    if (-not $repoInfo.GitHub) { throw "Repo '$Repo' has no GitHub identity: $($repoInfo.GitHubReason)." }
    $github = [string]$repoInfo.GitHub
    $issueValue = "https://github.com/$github/issues/$Issue"
    $issueData = $null
    if ($IssueJson) {
        $issueData = Get-Content -Raw -LiteralPath $IssueJson | ConvertFrom-Json
    }
    elseif (-not $DryRun) {
        $owner = Get-GitHubAccount $HubRoot $repoInfo.Root
        $previousGhToken = [Environment]::GetEnvironmentVariable('GH_TOKEN', 'Process')
        try {
            if ($owner) {
                try { $ownerToken = (& gh auth token --user $owner 2>$null | Out-String).Trim() }
                catch { throw "could not obtain the GitHub token for '$owner'" }
                if ($LASTEXITCODE -ne 0 -or -not $ownerToken) { throw "could not obtain the GitHub token for '$owner'" }
                [Environment]::SetEnvironmentVariable('GH_TOKEN', $ownerToken, 'Process')
            }
            $issueOutput = Invoke-Utf8Native { (& gh issue view $Issue --repo $github --json number,title,body,url 2>&1 | Out-String) }
            if ($LASTEXITCODE -ne 0) { throw "gh issue view failed for '$github' issue $Issue (exit $LASTEXITCODE)" }
            $issueData = $issueOutput | ConvertFrom-Json
        }
        finally {
            [Environment]::SetEnvironmentVariable('GH_TOKEN', $previousGhToken, 'Process')
            $ownerToken = $null
        }
    }
    if ($IssueJson -or -not $DryRun) {
        if ($null -eq $issueData -or $null -eq $issueData.PSObject.Properties['number'] -or [int]$issueData.number -ne $Issue) { throw 'issue number does not match -Issue' }
        if ($null -eq $issueData.PSObject.Properties['url'] -or [string]$issueData.url -ne $issueValue) { throw 'issue URL does not match the tracker repository and number' }
        if ($null -eq $issueData.PSObject.Properties['body']) { throw 'issue body is missing' }
        $issueValue = [string]$issueData.url
        $acceptance = @([regex]::Matches([string]$issueData.body, '(?m)^[ \t]*-[ \t]+\[ \][ \t]+([^\r\n]+)') | ForEach-Object { '- ' + $_.Groups[1].Value.Trim() })
    }
}

$branch = 'not a git repository — do not run git'
if (Test-Path -LiteralPath (Join-Path $repoInfo.Path '.git')) {
    $oldGitConfigCount = [Environment]::GetEnvironmentVariable('GIT_CONFIG_COUNT', 'Process')
    $oldGitConfigKey = [Environment]::GetEnvironmentVariable('GIT_CONFIG_KEY_0', 'Process')
    $oldGitConfigValue = [Environment]::GetEnvironmentVariable('GIT_CONFIG_VALUE_0', 'Process')
    try {
        $env:GIT_CONFIG_COUNT = '1'
        $env:GIT_CONFIG_KEY_0 = 'safe.directory'
        $env:GIT_CONFIG_VALUE_0 = $repoInfo.Path
        $branch = (Invoke-Utf8Native { & git -C $repoInfo.Path rev-parse --abbrev-ref HEAD 2>&1 | Out-String }).Trim()
        if ($LASTEXITCODE -ne 0 -or -not $branch) {
            $branch = (Invoke-Utf8Native { & git -C $repoInfo.Path symbolic-ref --short HEAD 2>&1 | Out-String }).Trim()
        }
        if ($LASTEXITCODE -ne 0 -or -not $branch) { throw "could not read branch for $($repoInfo.Path)" }
    }
    finally {
        [Environment]::SetEnvironmentVariable('GIT_CONFIG_COUNT', $oldGitConfigCount, 'Process')
        [Environment]::SetEnvironmentVariable('GIT_CONFIG_KEY_0', $oldGitConfigKey, 'Process')
        [Environment]::SetEnvironmentVariable('GIT_CONFIG_VALUE_0', $oldGitConfigValue, 'Process')
    }
}

$instructions = if ((Test-Path -LiteralPath (Join-Path $repoInfo.Path 'CLAUDE.md') -PathType Leaf) -or (Test-Path -LiteralPath (Join-Path $repoInfo.Path 'AGENTS.md') -PathType Leaf)) {
    'CLAUDE.md / AGENTS.md in the repository root'
}
else {
    'none in the repository root'
}

$instructionWarnings = @()
foreach ($name in @('CLAUDE.md', 'AGENTS.md')) {
    $instructionPath = Join-Path $repoInfo.Path $name
    if (Test-Path -LiteralPath $instructionPath -PathType Leaf) {
        $bytes = (Get-Item -LiteralPath $instructionPath).Length
        $lines = @(Get-Content -LiteralPath $instructionPath).Count
        if ($lines -gt 200 -or $bytes -gt 16384) {
            $instructionWarnings += "warning: $name $lines lines, $bytes bytes (over 200 lines or 16 KB)"
        }
    }
}
$workflowDir = Join-Path $repoInfo.Path '.github\workflows'
$workflowNames = @(if (Test-Path -LiteralPath $workflowDir -PathType Container) {
        Get-ChildItem -LiteralPath $workflowDir -Filter '*.yml' -File | Sort-Object Name | Select-Object -ExpandProperty Name
    })
$remoteCi = if ($workflowNames.Count -gt 0) { $workflowNames -join ', ' } else { 'missing' }

$isUnregisteredGit = $null -eq $registryEntry -and (Test-Path -LiteralPath (Join-Path $repoInfo.Path '.git'))
$emptyCommand = if ($isUnregisteredGit) { 'none' } else { '<fill: command>' }
$targetedTest = $emptyCommand
$analyze = $emptyCommand
$regenerate = $emptyCommand
$fullGate = $emptyCommand
$e2e = $emptyCommand
$logDir = if ($isUnregisteredGit) { Join-Path $repoInfo.Path "build\pipeline\$Topic" } else { Join-Path $repoInfo.Path "<fill: gitignored dir>\$Topic" }
if ($null -ne $registryEntry) {
    $targetedTest = [string]$registryEntry.commands.targetedTest
    $analyze = [string]$registryEntry.commands.analyze
    $regenerate = [string]$registryEntry.commands.regenerate
    $fullGate = Get-GateCommand $registryEntry $null $false
    $e2e = [string]$registryEntry.commands.e2e
    $logDir = Join-Path $repoInfo.Path "$($registryEntry.logDir)\$Topic"
}
if ($PSBoundParameters.ContainsKey('GateCommand')) { $fullGate = Get-GateCommand $registryEntry $GateCommand $true }

$planValue = if ($Plan) { $Plan } else { 'none — bounded design approved in chat' }
$specValue = if ($Spec) { $Spec } else { 'none — bounded design approved in chat' }
$tasksValue = if ($Tasks) { $Tasks } elseif ($Plan) { 'all' } else { '<fill: tasks or all>' }
$riskValue = if ($Risk) { $Risk } else { '<fill: LOW|MEDIUM|HIGH and reason>' }
$effortValue = if ($PSBoundParameters.ContainsKey('Effort')) { $Effort } elseif ($Risk -eq 'HIGH' -or $Model -eq 'gpt-6.2-astra') { 'high' } else { 'medium' }
$allowedModels = if ($Executor -eq 'codex') { $codexModels } else { @('claude-haiku-5-5', 'claude-sonnet-5-5', 'claude-opus-5-5') }
if ($PSBoundParameters.ContainsKey('Model')) {
    if ($Model -notin $allowedModels) { throw "Unsupported $Executor executor model '$Model'. Allowed: $($allowedModels -join ', ')." }
}
elseif ($Executor -eq 'codex') {
    $Model = if ($Risk -eq 'LOW') { 'gpt-6.1-terra' } else { 'gpt-6.2-sol' }
}
else {
    $Model = if ($Risk -eq 'HIGH') { 'claude-opus-5-5' } elseif ($Risk -eq 'LOW') { 'claude-haiku-5-5' } else { 'claude-sonnet-5-5' }
}
$date = Get-Date -Format 'yyyy-MM-dd'
if (-not $RunDir) { $RunDir = Join-Path $HubRoot "runs\$($repoInfo.Alias)\$date-$Topic" }
$RunDir = [IO.Path]::GetFullPath($RunDir)
$selectedOwner = if ($GateOwner) { $GateOwner } elseif ($null -ne $registryEntry -and $null -ne $registryEntry.PSObject.Properties['gateOwner']) { [string]$registryEntry.gateOwner } else { 'launcher' }
$gateOwnerText = 'launcher; run only targeted tests and analysis'
if ($selectedOwner -eq 'executor') {
    $executorGate = Get-GateCommand $registryEntry $GateCommand $PSBoundParameters.ContainsKey('GateCommand')
    if (-not (Test-GateEnabled $executorGate)) {
        throw "executor gate owner requires a full gate for '$($repoInfo.Alias)': pass -GateCommand or set registry commands.fullGate"
    }
    $gateLine = "pwsh -NoProfile -File '$((Join-Path $PSScriptRoot 'run-gate.ps1').Replace("'", "''"))' -Repo '$($repoInfo.Path.Replace("'", "''"))' -RunDir '$($RunDir.Replace("'", "''"))'"
    if ($fullGate -is [string] -and $PSBoundParameters.ContainsKey('GateCommand') -and $fullGate -cne (Get-GateCommand $registryEntry '' $false)) {
        $gateLine += " -GateCommand '$($fullGate.Replace("'", "''"))'"
    }
    $gateOwnerText = "executor; after the last edit run ``$gateLine`` once and fix red in context; the launcher reuses a matching green ``gate.json``"
}

$repoNotes = ''
if ($null -ne $registryEntry -and $null -ne $registryEntry.PSObject.Properties['briefNotes'] -and @($registryEntry.briefNotes).Count -gt 0) {
    $repoNotes = [Environment]::NewLine + 'Repo notes:' + [Environment]::NewLine + ((@($registryEntry.briefNotes) | ForEach-Object { "- $_" }) -join [Environment]::NewLine) + [Environment]::NewLine
}

$ponytailDir = Join-Path $SkillRoot 'vendor\ponytail'
foreach ($name in @('AGENTS.md', 'LICENSE', 'SOURCE.md')) {
    if (-not (Test-Path -LiteralPath (Join-Path $ponytailDir $name) -PathType Leaf)) { throw "missing vendored ponytail file: $(Join-Path $ponytailDir $name)" }
}
$ponytailSource = Get-Content -Raw -LiteralPath (Join-Path $ponytailDir 'SOURCE.md')
$ponytailTag = [regex]::Match($ponytailSource, '(?m)^- Tag: (\S+)').Groups[1].Value
$ponytailCommit = [regex]::Match($ponytailSource, '(?m)^- Commit: ([0-9a-f]{7})').Groups[1].Value
# From the first paragraph through "Never cut:"; the H1 and the closing note stay out.
$ponytailRules = [regex]::Match((Get-Content -Raw -LiteralPath (Join-Path $ponytailDir 'AGENTS.md')), '(?ms)^(?!#)\S.*?^Never cut:[^\r\n]*').Value
if (-not $ponytailTag -or -not $ponytailCommit -or -not $ponytailRules) { throw "vendored ponytail pin or ruleset unreadable in $ponytailDir" }
# Its headings drop one level so Code economy stays a single brief section.
$codeEconomy = "Ponytail $ponytailTag (``$ponytailCommit``) rules, vendored in the hub. Report what you skipped or did not check in the report's Risks line." + [Environment]::NewLine + [Environment]::NewLine + ((($ponytailRules -split '\r?\n') -replace '^## ', '### ') -join [Environment]::NewLine)

$values = @{
    codeEconomy = $codeEconomy
    repoNotes = $repoNotes
    repo = $repoInfo.Path
    alias = $repoInfo.Alias
    branch = $branch
    plan = $planValue
    tasks = $tasksValue
    spec = $specValue
    issue = $issueValue
    instructions = $instructions
    risk = $riskValue
    effort = $effortValue
    executor = "$Executor ``$Model``"
    dependsOn = $DependsOn
    remoteCi = $remoteCi
    targetedTest = $targetedTest
    analyze = $analyze
    regenerate = $regenerate
    fullGate = if ($fullGate -is [array]) { (($fullGate | ForEach-Object { "``$_``" }) -join ' and ') + ", $($fullGate.Count) commands from the repository root (run-gate runs each)" } else { "``$fullGate``" }
    e2e = $e2e
    longSteps = 'none'
    logDir = $logDir
    gateOwner = $gateOwnerText
    reportTemplate = $reportTemplate
    commitPolicy = if ($Executor -eq 'codex') { 'Leave changes uncommitted; the reviewer commits.' } else { 'Commit only when assigned.' }
    topic = $Topic
    date = $date
}
$template = Get-Content -Raw -LiteralPath $templatePath
$rendered = [regex]::Replace($template, '\{\{(\w+)\}\}', {
        param($match)
        $name = $match.Groups[1].Value
        if ($values.Contains($name)) { return [string]$values[$name] }
        throw "unfilled placeholder: $($match.Value)"
    })
if ($acceptance.Count -gt 0) {
    $acceptanceText = $acceptance -join [Environment]::NewLine
    $rendered = [regex]::Replace($rendered, '(?m)^- <fill: observable acceptance[^\r\n]*', [Text.RegularExpressions.MatchEvaluator]{ param($match) $acceptanceText })
}

if ($DryRun) {
    $instructionWarnings | ForEach-Object { Write-Output $_ }
    Write-Output $rendered
    exit 0
}

$briefPath = Join-Path $RunDir 'brief.md'
if ((Test-Path -LiteralPath $briefPath -PathType Leaf) -and -not $Force) {
    throw "brief exists: $briefPath; pass -Force to overwrite"
}
New-Item -ItemType Directory -Force -Path $RunDir | Out-Null
# The executor is told to write its logs here and a brief may forbid any other
# command, so the directory has to exist before the run starts. An unfilled
# marker is not a path: whoever fills it also creates it.
if (-not $logDir.Contains('<fill:') -and (Test-Path -LiteralPath $repoInfo.Path -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
}
[IO.File]::WriteAllText($briefPath, $rendered, [Text.UTF8Encoding]::new($false))
$gatePath = Join-Path $RunDir 'brief.gate.json'
if ($PSBoundParameters.ContainsKey('GateCommand') -or $PSBoundParameters.ContainsKey('GateOwner')) {
    $gateJson = [ordered]@{ command = $fullGate; owner = $selectedOwner.ToLowerInvariant() } | ConvertTo-Json
    [IO.File]::WriteAllText($gatePath, $gateJson, [Text.UTF8Encoding]::new($false))
}
elseif (Test-Path -LiteralPath $gatePath -PathType Leaf) {
    Remove-Item -LiteralPath $gatePath
}
$instructionWarnings | ForEach-Object { Write-Output $_ }
Write-Output "brief: $briefPath"
