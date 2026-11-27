$ErrorActionPreference = 'Stop'
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$source = Join-Path $repo 'plugins/cockpit/codex'
$work = Join-Path ([IO.Path]::GetTempPath()) ('cockpit-setup-' + [guid]::NewGuid())
$checks = 0
$originalScope = $env:CODEX_COCKPIT_SCOPE
function Check($Value, $Label) { $script:checks++; if (-not $Value) { throw $Label } }
function Put($Path, $Text) { [IO.Directory]::CreateDirectory((Split-Path $Path)) | Out-Null; [IO.File]::WriteAllText($Path, $Text) }
function Setup([string]$Script = "$source/setup.ps1", [string[]]$Extra = @()) {
    $out = & pwsh -NoProfile -File $Script -CodexHome "$work/Codex Home" -PipelineHome "$work/state" -ClaudeHome "$work/claude" -AgentsSkills "$work/agents/skills" -ProfilePath "$work/profile.ps1" @Extra 2>&1 | Out-String
    if ($LASTEXITCODE) { throw $out }; return $out
}
try {
    Put "$work/Codex Home/config.toml" "model = 'gpt-6-astra'`nmodel_reasoning_effort = 'xhigh'`nnotify = ['codex-computer-use.exe', 'turn-ended']`n[mcp_servers.demo]`ncommand = 'untouched'"
    Put "$work/Codex Home/hooks.json" '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"existing-notify"}]}]}}'
    Put "$work/profile.ps1" '# Unrelated profile'
    Put "$work/claude/skills/demo/SKILL.md" '# Demo'
    $config = Get-Content -Raw "$work/Codex Home/config.toml"
    Setup | Out-Null
    $installed = "$work/Codex Home/cockpit/deploy/codex"
    Check (Test-Path "$installed/dashboard.mjs") 'dashboard not deployed'
    Check (Test-Path "$work/Codex Home/cockpit/deploy/core/readings.ts") 'shared runtime dependency missing'
    Check (Test-Path "$work/Codex Home/cockpit/pipeline/bin/AgentLinks.ps1") 'sync dependency not deployed'
    & pwsh -NoProfile -File "$work/Codex Home/cockpit/pipeline/bin/setup-codex-home.ps1" -SyncSkillsOnly -CodexHome "$work/Codex Home" -ClaudeHome "$work/claude" -AgentsSkills "$work/agents/skills" *> "$work/deployed-sync.log"
    Check ($LASTEXITCODE -eq 0 -and (Test-Path "$work/Codex Home/skills/demo/SKILL.md")) 'deployed sync helper failed'
    Check ((Get-Content -Raw "$work/Codex Home/config.toml") -ceq $config) 'config/notify/model changed'
    $first = Get-Content -Raw "$work/Codex Home/hooks.json"
    Setup "$installed/setup.ps1" | Out-Null
    Check ((Get-Content -Raw "$work/Codex Home/hooks.json") -ceq $first) 'repeated install duplicated hooks'
    Check (@([regex]::Matches((Get-Content -Raw "$work/profile.ps1"), '# BEGIN Codex Cockpit')).Count -eq 1) 'profile block duplicated'
    Check ((Get-Content -Raw "$work/Codex Home/hooks.json") -match 'existing-notify') 'unrelated hook removed'
    $editedHooks = Get-Content -Raw "$work/Codex Home/hooks.json" | ConvertFrom-Json -AsHashtable
    $editedHooks.hooks.Stop[1].hooks[0].command += ' user-edit'
    $editedHooks | ConvertTo-Json -Depth 20 | Set-Content "$work/Codex Home/hooks.json"
    $out = & pwsh -NoProfile -File "$source/setup.ps1" -CodexHome "$work/Codex Home" -ProfilePath "$work/profile.ps1" -Uninstall 2>&1 | Out-String
    Check ($LASTEXITCODE -ne 0 -and (Get-Content -Raw "$work/Codex Home/hooks.json") -match 'user-edit') 'uninstall discarded edited hook'
    [IO.File]::WriteAllText("$work/Codex Home/hooks.json",$first)
    $env:COCKPIT_ARGS_FILE = "$work/arguments.json"
    Put "$work/fake-codex.ps1" 'ConvertTo-Json -InputObject @($args) -Compress | Set-Content -LiteralPath $env:COCKPIT_ARGS_FILE; exit 23'
    foreach ($arguments in @(@('exec','a b','quote"x'), @('resume','exec','id'), @('features','list'), @('mcp','list'), @('--help'), @('-c','model="fixture"','exec','a; b'), @('--cd','C:\Space Path','exec','--json'))) {
        & pwsh -NoProfile -File "$installed/start-codex.ps1" -CodexExe "$work/fake-codex.ps1" @arguments *> "$work/start.log"
        Check ($LASTEXITCODE -eq 23) "headless exit lost: $arguments"
        $actual = @(Get-Content -Raw $env:COCKPIT_ARGS_FILE | ConvertFrom-Json)
        Check (($actual | ConvertTo-Json -Compress) -ceq ($arguments | ConvertTo-Json -Compress)) "arguments changed: expected $($arguments | ConvertTo-Json -Compress); actual $($actual | ConvertTo-Json -Compress)"
    }
    & pwsh -NoProfile -File "$installed/start-codex.ps1" -CodexExe "$work/fake-codex.ps1" 'interactive prompt' *> "$work/start.log"
    Check ($LASTEXITCODE -eq 23) 'non-TTY exit lost'
    Check (-not (Test-Path "$work/state/cockpit/codex/scopes")) 'headless spawned dashboard'
    Put "$work/fake-scope.ps1" '[IO.File]::WriteAllText($env:COCKPIT_ARGS_FILE,[string]$env:CODEX_COCKPIT_SCOPE); exit 23'
    $env:CODEX_COCKPIT_SCOPE = 'fixture-parent-scope'
    & pwsh -NoProfile -File "$installed/start-codex.ps1" -CodexExe "$work/fake-scope.ps1" exec *> "$work/start.log"
    Check ($LASTEXITCODE -eq 23 -and [IO.File]::ReadAllText($env:COCKPIT_ARGS_FILE) -eq '') 'headless launch inherited interactive notification scope'
    Check ($env:CODEX_COCKPIT_SCOPE -eq 'fixture-parent-scope') 'headless launch changed caller scope'
    $env:CODEX_COCKPIT_SCOPE = $originalScope
    . "$source/StartCommon.ps1"
    Check (Test-CockpitInteractive @() $true $true) 'interactive launch not recognized'
    Check (-not (Test-CockpitInteractive @('resume','exec','id') $true $true)) 'resume exec classified interactive'
    Check (-not (Test-CockpitInteractive @('-c','model="fixture"','features','list') $true $true)) 'root options hid headless command'
    Check (-not (Test-CockpitInteractive @() $false $true)) 'redirected input classified interactive'
    Check (-not (Test-CockpitInteractive @() $true $false)) 'redirected output classified interactive'
    Check ((Get-CockpitWorkingDirectory @('-C','child path') $work) -eq [IO.Path]::GetFullPath("$work/child path")) 'effective cwd ignored --cd'
    $terminalArgs = New-CockpitTerminalArguments 'C:\Node Path\node.exe' "C:\O'Brien;folder\dashboard.mjs" "C:\Scope Path\session.json" 'C:\State;Path'
    $decoded = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($terminalArgs[-1]))
    Check ($decoded -match "O''Brien;folder" -and $terminalArgs.Count -eq 9) 'Terminal argument escaping failed'
    Put "$work/cwd/.keep" ''
    Put "$work/claude/harness-scope/profiles/code.json" '{"skills":{"deny":["video*"]}}'
    Put "$work/suppression-source/SKILL.md" '# Video'
    [IO.Directory]::CreateDirectory("$work/Codex Home/skills") | Out-Null
    New-Item -ItemType SymbolicLink -Path "$work/Codex Home/skills/video-one" -Target "$work/suppression-source" | Out-Null
    Check (@(Get-CockpitSkillSuppression "$work/cwd" "$work/claude" @("$work/Codex Home/skills")).Count -eq 0) 'absent selector changed discovery'
    Put "$work/cwd/.claude/harness-scope.json" '{"profile":"code"}'
    $suppression = @(Get-CockpitSkillSuppression "$work/cwd" "$work/claude" @("$work/Codex Home/skills"))
    Check ($suppression.Count -eq 2 -and $suppression[1] -match 'video-one/SKILL.md' -and $suppression[1] -match 'enabled=false') 'linked skill suppression missing'
    Put "$work/pipeline-driver.ps1" "param([string]`$Wrapper,[string]`$Exe) 'input fixture' | & `$Wrapper -CodexExe `$Exe -CockpitHeadless exec; exit `$LASTEXITCODE"
    & pwsh -NoProfile -File "$work/pipeline-driver.ps1" -Wrapper "$installed/start-codex.ps1" -Exe "$work/fake-codex.ps1" *> "$work/start.log"
    Check ($LASTEXITCODE -eq 23) 'pipeline exit lost'
    Put "$work/profile.ps1" ((Get-Content -Raw "$work/profile.ps1") + "`n# Concurrent addition")
    Setup "$installed/setup.ps1" @('-Uninstall') | Out-Null
    Check ((Get-Content -Raw "$work/profile.ps1") -match 'Concurrent addition' -and (Get-Content -Raw "$work/profile.ps1") -notmatch 'BEGIN Codex Cockpit') 'uninstall lost unrelated profile edits'
    Check ((Get-Content -Raw "$work/Codex Home/hooks.json") -match 'existing-notify' -and (Get-Content -Raw "$work/Codex Home/hooks.json") -notmatch 'hook.mjs') 'owned hooks not removed cleanly'
    Check ((Get-Content -Raw "$work/Codex Home/config.toml") -ceq $config) 'uninstall changed config'
    Check (Test-Path "$work/claude/skills/demo/SKILL.md") 'source skill changed'
    Setup "$source/setup.ps1" @('-Uninstall') | Out-Null
    Setup | Out-Null
    Check (Test-Path "$installed/start-codex.ps1") 'reinstall after uninstall failed'
    Put "$installed/dashboard.mjs" 'concurrent deployed edit'
    $out = & pwsh -NoProfile -File "$source/setup.ps1" -CodexHome "$work/Codex Home" -PipelineHome "$work/state" -ProfilePath "$work/profile.ps1" 2>&1 | Out-String
    Check ($LASTEXITCODE -ne 0 -and $out -match 'Deployed file edited') 'reinstall overwrote concurrent deployed edit'
    Setup "$source/setup.ps1" @('-Uninstall') | Out-Null
    Check ((Get-Content -Raw "$installed/dashboard.mjs") -ceq 'concurrent deployed edit') 'uninstall deleted concurrent deployed edit'
    Write-Output "Codex setup: PASS ($checks checks)"
} finally {
    $env:CODEX_COCKPIT_SCOPE = $originalScope
    Remove-Item Env:COCKPIT_ARGS_FILE -ErrorAction SilentlyContinue
    if ([IO.Path]::GetFullPath($work).StartsWith([IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $work -Recurse -Force }
}
