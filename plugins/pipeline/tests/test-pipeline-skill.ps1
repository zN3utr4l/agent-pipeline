[CmdletBinding()]
param([string]$RulesPath)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\skills\pipeline')).Path
$failures = [Collections.Generic.List[string]]::new()
$script:assertions = 0
function Assert-True([bool]$Condition, [string]$Message) {
    $script:assertions++
    if (-not $Condition) { $failures.Add($Message) }
}
function Words([string]$Text) { return @($Text -split '\s+' | Where-Object { $_ }).Count }
$files = [ordered]@{
    skill = 'SKILL.md'; handoff = 'references/handoff.md'; crossReview = 'references/cross-review.md'
    review = 'references/review-checklist.md'; delivery = 'references/delivery-economy.md'
    brief = 'templates/brief.md'; report = 'templates/report.md'
    retro = 'references/retro.md'; tracker = 'references/tracker.md'
    environment = 'references/environment.md'
    evals = 'evals/evals.json'
    manual = 'templates/manual-opus-handoff.md'
    codexRun = 'bin/codex-run.ps1'; claudeRun = 'bin/claude-run.ps1'; newBrief = 'bin/new-brief.ps1'
    config = 'config/executors.json'; codexAgent = 'agents/codex-AGENTS.md'; claudeAgent = 'agents/implementer.md'
}
$contents = @{}
Assert-True (Test-Path (Join-Path $PSScriptRoot 'test-launcher-jobs.ps1')) 'launcher jobs test missing'
Assert-True ((Get-Content -Raw (Join-Path $PSScriptRoot 'run-all.ps1')).Contains("'test-launcher-jobs.ps1'")) 'launcher jobs test not registered'
foreach ($key in $files.Keys) {
    $path = Join-Path $root $files[$key]
    Assert-True (Test-Path -LiteralPath $path -PathType Leaf) "missing $($files[$key])"
    if (Test-Path -LiteralPath $path -PathType Leaf) { $contents[$key] = Get-Content -Raw -LiteralPath $path }
}
$encodingFiles = @(Get-ChildItem -LiteralPath $root -Filter '*.md' -Recurse -File) + @(Get-Item -LiteralPath (Join-Path $root 'config/executors.json'))
$mojibake = [string][char]0x00E2 + '[' + [char]0x20AC + [char]0x2020 + ']|' + [char]0x00C3 + '|' + [char]0xFFFD + '|' + [char]0x2019
foreach ($file in $encodingFiles) {
    Assert-True (([IO.File]::ReadAllText($file.FullName)) -notmatch $mojibake) "mojibake in $($file.FullName)"
}
Assert-True ($contents.review -match 'flaky green.*not a fix-loop trigger' -and $contents.review -match 'flaky test.*follow-up.*tracker.*enabled') 'flaky review rule missing'
Assert-True ($contents.review -match '## Device surfaces' -and $contents.review -match 'lock screens.*images.*watches.*shade' -and $contents.review -match 'Record live-notification animations.*period.*period' -and $contents.review -match 'in-app notification twin.*identical content' -and $contents.review -match 'Grep every notification sender.*brief.s Files') 'device-surface review rules missing'
Assert-True ($contents.handoff -match 'read-only audit lot.*table and findings.*then fix lots' -and $contents.handoff -match 'UI lot.*at most about ten roles or screens') 'audit/UI lot sizing missing'
Assert-True ($contents.handoff.Contains('Proven device or API facts name their observed effect; otherwise mark them unverified.')) 'device/API proof rule missing'
Assert-True ($contents.delivery -match 'UI across many screens.*last lot.*full e2e once locally before the single push.*Otherwise CI owns verification') 'final UI e2e rule missing'
Assert-True ($contents.retro -match 'executor table.*routing' -and $contents.retro -match 'cheapest model and effort.*fix-loop and deadline rates') 'executor routing rule missing'
Assert-True ($contents.crossReview -match 'codex-run\.ps1 -ReadOnly' -and $contents.crossReview -match 'read-only sandbox.*apps, plugins, and MCP servers disabled' -and $contents.crossReview -match 'no repository lock.*no post-run gate' -and $contents.crossReview -match '-FullAccess.*-FixLoop.*exit 3.*exit 75' -and $contents.crossReview.Contains('review.json') -and $contents.crossReview.Contains('VERDICT: APPROVED|REVISE|BLOCKED') -and $contents.crossReview -match 'Exit 0 is a valid review whatever the verdict; 1 is failed or malformed' -and $contents.crossReview.Contains('-Resume <id> -ReadOnly')) 'read-only interface missing'
Assert-True ($contents.crossReview.Contains('<lot run dir>\review-<n>\brief.md') -and $contents.crossReview.Contains('-RunDir <lot run dir>\review-<n> -ReadOnly -Model <gpt-6.2-sol|gpt-6.2-astra> -ReasoningEffort high -TimeoutMinutes 30') -and $contents.crossReview -match 'Arbitrate every finding.*accepted edits the brief.*rejected records its reason' -and $contents.crossReview -match 'at most two rounds.*Resume <session> -ReadOnly.*material brief changes' -and $contents.crossReview -match 'not approval.*BLOCKED, failed, or malformed never counts as approval' -and $contents.crossReview.Contains('Brief review: skipped (<reason>)') -and $contents.crossReview -match 'LOW and MEDIUM briefs skip it unless the user asks') 'brief review rules missing'
Assert-True ($contents.crossReview -match 'Read the launcher exit first.*0 gives `review\.json` plus `report\.md` starting `VERDICT:`.*1 gives `report\.md` starting `STATUS: failed` and no `review\.json`.*3, 4 or 75 is refused before launch, possibly with no artifacts') 'exit output map missing'
Assert-True ($contents.crossReview.Contains('review-<n+1>\brief.md') -and $contents.crossReview.Contains('-RunDir <lot run dir>\review-<n+1> -Resume <session> -ReadOnly') -and $contents.crossReview -match 'only under `PIPELINE_HOME.*alias.*review folders stay inside the lot run directory') 'round 2 layout missing'
Assert-True ($contents.crossReview -match 'second-opinion.*reproduction, evidence, and failed approaches.*testable alternative explanation.*fresh session, never the failing executor' -and $contents.skill -match '(?m)^\| second-opinion \|.*second failed fix loop.*Fresh session, never the failing executor' -and $contents.skill.Contains('references/cross-review.md')) 'second-opinion route missing'
Assert-True ($contents.handoff -match 'HIGH brief gets the read-only review.*before launch' -and $contents.handoff -match 'codex-run\.ps1" .*-ReadOnly') 'handoff cross-review pointer or -ReadOnly launcher missing'
Assert-True ($contents.handoff -match 'replaces a behaviour, change every brief, plan, and fix-brief passage.*Done when included; an addendum leaves it standing' -and $contents.handoff -match 'replaces code compares old and new output on the same real inputs from the producing program') 'handoff replacement rules missing'
Assert-True ($contents.review -match 'Changed tests must assert the acceptance criteria or a valid regression, not whatever the implementation returns' -and $contents.review -match '`git diff` omits untracked files: open every new file `git status` lists') 'review test/untracked rules missing'
Assert-True ($contents.retro -match 'Before ranking, read `PIPELINE_HOME\\retro-rejected\.md`; never re-propose a listed candidate without new evidence' -and $contents.retro -match 'Append each candidate the user rejects.*retro-rejected\.md.*date, reason, and evidence path') 'retro rejected-candidate ledger missing'
Assert-True ($contents.environment -match 'Never pipe a launcher.*tail.*head' -and $contents.environment -match 'hides its exit code.*redirect.*file.*tail.*exit') 'launcher pipe/exit rule missing'
if ($contents.Count -eq $files.Count) {
    foreach ($pair in @(@('skill',600),@('handoff',950),@('crossReview',350),@('review',550),@('delivery',600),@('brief',350),@('report',350),@('retro',400),@('tracker',350),@('environment',350))) {
        Assert-True ((Words $contents[$pair[0]]) -le $pair[1]) "$($pair[0]) exceeds $($pair[1]) words"
    }
    $folderWords = 0
    Get-ChildItem $root -Filter '*.md' -Recurse | Where-Object { $_.FullName -notmatch '[\\/](vendor|agents)[\\/]' } | ForEach-Object { $folderWords += Words (Get-Content -Raw -LiteralPath $_.FullName) }
    Assert-True ($folderWords -le 4250) "skill folder exceeds 4250 words: $folderWords"
    $description = [regex]::Match($contents.skill, '(?ms)^description:\s*>-\s*\r?\n\s*(.+?)\r?\n---').Groups[1].Value.Trim()
    Assert-True ($description.StartsWith('Use when') -and $description.Length -le 300) 'description must start Use when and fit 300 characters'
    foreach ($route in @('raw','approved-design-spec','approved-plan','review-only','fix-loop-finish','second-opinion','retro')) {
        Assert-True ($contents.skill -match "(?m)^\| $([regex]::Escape($route)) \|") "missing route $route"
    }
    foreach ($name in @('new-brief.ps1','codex-run.ps1','claude-run.ps1','references/handoff.md','references/cross-review.md','references/review-checklist.md','references/delivery-economy.md','references/retro.md','references/tracker.md')) {
        Assert-True ($contents.skill.Contains($name)) "skill misses $name"
    }
    foreach ($name in @('codex-run.ps1','claude-run.ps1','new-brief.ps1')) {
        Assert-True ($contents.handoff.Contains($name)) "handoff misses $name"
    }
    foreach ($key in @('repo','alias','branch','plan','tasks','spec','instructions','risk','effort','executor','remoteCi','targetedTest','analyze','regenerate','fullGate','e2e','logDir','reportTemplate','topic','date')) {
        Assert-True ($contents.brief.Contains("{{$key}}")) "brief placeholder missing: $key"
    }
    Assert-True ($contents.brief -notmatch 'Probe once|{{probe}}|scope and fingerprint') 'brief still requires probe or fingerprints'
    Assert-True ($contents.handoff -notmatch 'capability probe' -and $contents.handoff.Contains('p90 under 10 minutes')) 'handoff probe or p90 rule incorrect'
    Assert-True ($contents.review.Contains("orchestrator's before-copies")) 'non-Git review scope source missing'
    Assert-True ($contents.brief.Contains('{{dependsOn}}')) 'brief dependency placeholder missing'
    Assert-True ($contents.handoff.Contains('brief.gate.json') -and $contents.handoff.Contains('before registry')) 'handoff misses brief sidecar precedence'
    Assert-True ($contents.brief.Contains('Gate owner: {{gateOwner}}.')) 'brief gate-owner placeholder missing'
    Assert-True ($contents.handoff.Contains('run-gate.ps1') -and $contents.handoff.Contains('`reused: true`') -and $contents.handoff.Contains('`gate.executor.json`') -and $contents.handoff.Contains('`reportSynthesized: true`')) 'handoff misses executor gate ownership and reuse'
    Assert-True ($contents.handoff -match '~/\.claude`? goes to a Codex executor.*sensitive files') 'handoff misses the ~/.claude routing line'
    Assert-True ($contents.review -match '(?m)^3\..*`reused: true` with a `fingerprint`.*gate evidence') 'review step 3 does not accept a reused gate'
    Assert-True ($contents.brief.Contains('{{issue}}')) 'brief issue placeholder missing'
    Assert-True ($contents.handoff.Contains('-Issue')) 'handoff issue option missing'
    foreach ($axis in @('Spec','Standards')) {
        Assert-True ($contents.review -match "(?m)^## $axis\r?$") "review axis missing: $axis"
    }
    foreach ($smell in @('mysterious name','duplicated code','speculative generality','shotgun surgery','feature envy','primitive obsession')) {
        Assert-True ($contents.review.Contains($smell)) "smell baseline misses $smell"
    }
    Assert-True ($contents.review.Contains('→ check') -and $contents.review -match 'duplicated information' -and $contents.review -match 'overflow') 'review prevention/UI rules missing'
    Assert-True ($contents.handoff -match 'vertical slices' -and $contents.handoff -match 'expand.*contract' -and $contents.handoff -match 'red.*regression') 'lot/reproduction rules missing'
    Assert-True ($contents.handoff.Contains('allowed files reach every file the behaviour passes through')) 'brief allowed files must cover the behaviour path'
    Assert-True ($contents.handoff -match 'LOW 30.*MEDIUM 60.*HIGH 90' -and $contents.handoff -match 'numeric target') 'retro-baseline planner rules missing'
    foreach ($key in @('handoff', 'review')) {
        Assert-True ($contents[$key] -match 'screenshots.*360 px.*100%.*dark and light where available.*overflow.*130%.*test.*without screenshots') "$key text-scale rule incorrect"
    }
    foreach ($key in @('codexAgent', 'claudeAgent')) {
        Assert-True ($contents[$key] -match 'Change only the files the brief allows, plus the minimal edit.*requested behaviour passes through \(caller, shared helper, owner\).*scope extension; stop and report.*Must not change.*default-protected kind') "$key scope extension rule missing"
    }
    Assert-True ($contents.codexAgent -match 'edit files with `apply_patch`, never through shell string replacement or whole-file rewrites from the shell') 'Codex apply_patch rule missing'
    Assert-True ($contents.report -match 'Changes:.*scope extensions') 'report scope extension field missing'
    Assert-True ($contents.brief -match 'red reproduction' -and $contents.brief -match 'final message.*report.md.*whole report') 'brief reproduction/report contract missing'
    Assert-True ($contents.report -match 'each Done-when item.*met or not met.*evidence') 'report acceptance evidence missing'
    Assert-True ($contents.skill -match 'issue number or URL' -and $contents.skill -match 'fix loop.*red gate.*non-zero exit') 'raw issue/finish retro trigger missing'
    Assert-True ($contents.skill -match '(?m)^\| raw \|.*Classify a spike, bounded task, or architectural task.*issue number or URL') 'raw classification and issue request must coexist'
    Assert-True ($contents.skill -match '(?m)^\| raw \|.*spike, bounded task, or architectural task') 'raw route must retain spike/bounded/architectural task wording'
    Assert-True ([regex]::Matches($contents.review, 'file:line').Count -eq 1 -and [regex]::Matches($contents.review, 'one correction cycle').Count -eq 1) 'finding/correction rule must appear once'
    Assert-True ($contents.review -match '(?m)^6\..*axis.*tracker.md.*where enabled') 'step 6 must own axes and tracked follow-ups'
    Assert-True ($contents.tracker -match 'new-brief.*scopes.*account.*token.*read' -and $contents.tracker -match 'root folder') 'tracker must document root-account token scope'
    Assert-True ($contents.tracker -match 'any GitHub origin' -and $contents.tracker.Contains('tracker: none') -and $contents.tracker -match 'Azure DevOps.*local.*run directory.*PR' -and $contents.tracker -match 'others use.*user names.*parent') 'generic tracker and shared-repository parent rule missing'
    Assert-True ($contents.handoff.Contains('[-GateCommand <cmd>] [-GateOwner <executor|launcher>]') -and $contents.handoff.Contains('-GateOwner executor -GateCommand') -and $contents.handoff.Contains('launcher reads `brief.gate.json`') -and $contents.handoff.Contains('under 10 minutes')) 'generic executor gate handoff missing'
    Assert-True ($contents.retro.Contains('meta.repoRoot') -and $contents.retro.Contains('meta.repoPath') -and $contents.retro.Contains('--roots') -and $contents.retro.Contains('--registry <file>') -and $contents.retro -match 'registry.*alias' -and $contents.retro -match 'longest.*normalized.*prefix' -and $contents.retro -match 'run folder') 'repository retro grouping missing'
    Assert-True ($contents.delivery -match 'before/after' -and $contents.delivery -match 'one-way or two-way door' -and $contents.delivery -match 'blast radius' -and $contents.delivery.Contains('Closes #n')) 'PR merge-danger contract missing'
    Assert-True ($contents.delivery -match 'fix loop.*red gate.*non-zero exit' -and $contents.delivery.Contains('references/retro.md')) 'delivery retro trigger missing'
    foreach ($artifact in @('bin\retro-scan.js','meta.json','report.md','gate.json','*fix*.md','review findings','never transcripts')) {
        Assert-True ($contents.retro.Contains($artifact)) "retro misses $artifact"
    }
    Assert-True ($contents.retro -match 'frequency.*cost' -and $contents.retro -match 'weekly' -and $contents.retro -match 'deterministic check') 'retro prevention/ranking missing'
    foreach ($command in @('gh issue create','gh issue view','sub_issues -F sub_issue_id=<id>','dependencies/blocked_by -F issue_id=<id>','gh label create','Blocked by #n','Closes #n','Executors never call `gh`')) {
        Assert-True ($contents.tracker.Contains($command)) "tracker misses $command"
    }
    Assert-True ($contents.codexAgent -match 'at most two.*parallel rule' -and $contents.codexAgent -notmatch 'one executor at a time') 'shared orchestrator concurrency rule stale'
    $evals = ($contents.evals | ConvertFrom-Json).evals
    Assert-True (@($evals | Where-Object { $_.prompt -match 'retro.*fix loop' }).Count -eq 1) 'fix-loop retro eval missing'
    Assert-True (@($evals | Where-Object { $_.prompt -match 'two-lot.*tracker-enabled' }).Count -eq 1) 'tracker parent/sub-issue eval missing'
    Assert-True ($contents.skill -match 'at most two executors' -and $contents.skill -match 'worktree' -and $contents.skill -match 'Depends on: none') 'parallel-lot discipline missing'
    Assert-True ($contents.handoff.Contains("Follow SKILL.md's parallel rule; a busy path returns exit 3.") -and $contents.skill.Contains('Prefer different providers')) 'handoff must defer to the preferred-provider parallel rule'
    Assert-True ($contents.handoff -notmatch '\r?\n\r?\n$') 'handoff has extra trailing blank lines'
    Assert-True ([regex]::Matches($contents.brief, '<fill:').Count -ge 3) 'brief needs three fill markers'
    foreach ($status in @('ready_for_review','blocked','failed')) { Assert-True ($contents.report.Contains($status)) "report misses $status" }
    foreach ($model in @('gpt-6.1-terra','claude-haiku-5-5','claude-sonnet-5-5','gpt-6.2-sol','gpt-6.2-astra','claude-opus-5-5')) {
        Assert-True ($contents.handoff.Contains($model)) "routing misses $model"
    }
    $retiredNames = '(?<![\w.-])(?:gpt-6-luna|gpt-6-astra|gpt-6-sol|claude-opus-5|claude-sonnet-5)(?![\w.-])'
    Assert-True ($contents.handoff -notmatch $retiredNames) 'handoff offers retired executor models'
    $orchestratorLine = [regex]::Match($contents.skill, '(?m)^.*?for the orchestrator\.').Value
    Assert-True ($orchestratorLine.Contains('claude-opus-5-5') -and $orchestratorLine.Contains('claude-fable-5-2') -and $orchestratorLine.Contains('gpt-6-astra')) 'orchestrator models missing'
    foreach ($text in @($contents.skill.Replace($orchestratorLine, ''), $contents.codexAgent, $contents.claudeAgent, $contents.config, [IO.File]::ReadAllText((Join-Path $root '..\..\README.md')))) {
        Assert-True ($text -notmatch $retiredNames) 'retired executor model outside orchestrator sentence'
    }
    Assert-True ($contents.handoff -match 'Terra.*screenshots.*images.*browser/app.*MEDIUM' -and $contents.handoff -match 'Opus.*HIGH.*failed fix loop') 'task-specific executor guidance missing'
    Assert-True ($contents.manual.Contains('<claude-haiku-5-5|claude-sonnet-5-5|claude-opus-5-5>')) 'manual handoff misses current Claude models'
    foreach ($key in @('skill','handoff','review','delivery','brief','report','manual')) {
        Assert-True ($contents[$key] -notmatch '(?i)Codex `?\.git`? writes belong to the reviewer|Codex `?\.git`? is read-only') "git-write rule duplicated in $key"
    }
    Assert-True ($contents.skill.Contains('Use absolute paths and `git -C`; never `cd`, which reloads instruction files.')) 'absolute-path discipline missing'
    Assert-True ($contents.skill.Contains('PIPELINE_HOME\config\executors.json') -and $contents.skill.Contains('longest root prefix') -and -not $contents.skill.Contains('Get-GitHubAccount')) 'account selection must name the user registry and main-checkout prefix plainly'
    Assert-True ($contents.skill -match 'worktree setup or removal.*shell command misbehaves.*environment.md') 'environment reference trigger missing'
    Assert-True ($contents.skill -match '\| GitHub issues \|.*tracker.md' -and $contents.skill -notmatch 'Opt-in GitHub') 'tracker row remains opt-in'
    Assert-True ($contents.handoff -match '115 minutes.*Claude Code.*Bash.*two hours' -and $contents.handoff.Contains('`run_in_background`') -and $contents.handoff.Contains('`timeout: 7200000`') -and $contents.handoff -match 'Split longer work.*progress.md.*resume') 'background timeout/resume guidance missing'
    foreach ($key in @('claudeAgent','codexAgent')) {
        $rules = if ($key -eq 'codexAgent') { ($contents[$key] -split '## Assembly-line executor')[1] } else { $contents[$key] }
        foreach ($phrase in @('Batch independent reads and searches into one command','read a short file whole once','never rerun a green command on unchanged files','The brief is the process','Do not open the `pipeline` skill or process skills','test-driven-development, systematic-debugging, verification-before-completion, receiving-code-review, brainstorming, writing-plans','Repository convention skills named by the repository','Evidence is the report: command, exit, count and log path','Write no evidence/scope JSON, hashes or before-copies unless the brief asks','`run-gate.ps1` records the gate fingerprint','Run every command in the foreground','tool timeout up to 10 minutes','run_in_background','Monitor','`&`','Start-Job','`start`','nohup','Split longer checks','scripts that stop them','report only after every command has exited','Never call `gh`, `kubectl`, cloud CLIs, or remote databases, read or write')) {
            Assert-True ([regex]::Matches($rules, [regex]::Escape($phrase)).Count -eq 1) "$key executor rule missing or repeated: $phrase"
        }
    }
    foreach ($phrase in @('absolute paths','git -C','never `cd`','-p:','/p:','MSB1008','MSYS_NO_PATHCONV=1','own line','&&','no `jq`','gh --jq','skips the profile','gh account','-PassThru','TaskStop','command-line regex','never `$PID`','npm ci','yarn install --immutable','no node_modules junction','git worktree remove',"[IO.Directory]::Delete('<wt>\node_modules', `$false)",'origin/develop','explicit refspec','CronCreate','NODE_USE_ENV_PROXY=1','reset time has passed','stale','codeburn quota','does not rerun on push','@codex review')) {
        Assert-True ($contents.environment.Contains($phrase)) "environment rule missing: $phrase"
    }
    $config = $contents.config | ConvertFrom-Json
    Assert-True ($config.defaults.codexModel -eq 'gpt-6.2-sol' -and $config.defaults.model -eq 'claude-opus-5-5') 'model defaults changed unexpectedly'
    Assert-True ($config.defaults.maxFixLoops -eq 2 -and $config.defaults.quotaCapPercent -eq 85 -and $config.defaults.quotaCapPercentResume -eq 85 -and $config.defaults.autoCompactTokens -eq 200000 -and $config.defaults.claudeAutoCompactTokens -eq 400000) 'guard defaults changed'
}
$runsHook = Join-Path $PSScriptRoot '../../cockpit/hooks/runs.tsx'
if (Test-Path -LiteralPath $runsHook) {
    # Parameters reviewed against the cockpit guard (refusalOf, variablePathOf, hasFlag in runs.tsx); the rest cannot change what the guard must refuse.
    $guarded = 'Repo','Brief','RunDir','Resume','FixLoop','TimeoutMinutes','FullAccess','ReadOnly','DryRun','Model','ReasoningEffort','Effort','GateCommand','GateTimeoutMinutes','WritableRoot','AutoCompactTokens','AllowExtraFixLoop','SkipQuotaCheck','QuotaCapPercent','LockDir','MaxBudgetUsd','MaxResumeContextTokens'
    foreach ($launcher in 'codex-run.ps1','claude-run.ps1') {
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root "bin/$launcher"), [ref]$null, [ref]$null)
        foreach ($name in $ast.ParamBlock.Parameters.Name.VariablePath.UserPath) {
            if ($name -notin $guarded) { Assert-True $false "$launcher parameter -$name is not classified: review refusalOf in plugins/cockpit/hooks/runs.tsx first, then add it to the guarded list in test-pipeline-skill.ps1" }
        }
    }
}
else { Write-Output 'cockpit guard check skipped: plugins/cockpit absent' }
if ($failures.Count) { $failures | ForEach-Object { Write-Error $_ -ErrorAction Continue }; exit 1 }
Write-Output "pipeline skill tests: PASS ($script:assertions assertions)"
