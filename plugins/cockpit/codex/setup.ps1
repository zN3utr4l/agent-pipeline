[CmdletBinding()]
param(
    [string]$CodexHome = $(if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }),
    [string]$ClaudeHome = $(if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $HOME '.claude' }),
    [string]$AgentsSkills = (Join-Path $HOME '.agents/skills'),
    [string]$PipelineHome = $(if ($env:PIPELINE_HOME) { $env:PIPELINE_HOME } else { Join-Path $HOME '.pipeline' }),
    [string]$ProfilePath,
    [string]$PipelineSkill,
    [string]$NodeExe = (Get-Command node.exe -CommandType Application -ErrorAction Stop).Source,
    [switch]$Uninstall
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$CodexHome = [IO.Path]::GetFullPath($CodexHome)
$state = Join-Path $CodexHome 'cockpit'
$manifestPath = Join-Path $state 'install.json'
$manifest = if (Test-Path $manifestPath) { Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json -AsHashtable } else { $null }
$hooksPath = Join-Path $CodexHome 'hooks.json'
$originalHooks = if (Test-Path -LiteralPath $hooksPath) { [IO.File]::ReadAllText($hooksPath) } else { $null }
$hooks = if (Test-Path $hooksPath) { Get-Content -Raw -LiteralPath $hooksPath | ConvertFrom-Json -AsHashtable } else { @{hooks=@{}} }
if (-not $hooks.ContainsKey('hooks')) { $hooks.hooks = @{} }
$beforeHooks = $hooks | ConvertTo-Json -Depth 30
$profileText = if ($ProfilePath -and (Test-Path $ProfilePath)) { [IO.File]::ReadAllText($ProfilePath) } else { '' }
$beforeProfile = $profileText
$conflicts = @()
if ($manifest) {
    foreach ($event in $manifest.groups.Keys) {
        $owned = $manifest.groups[$event] | ConvertTo-Json -Depth 12 -Compress
        $found = $false
        $hooks.hooks[$event] = @($hooks.hooks[$event] | Where-Object {
            if (($_ | ConvertTo-Json -Depth 12 -Compress) -ceq $owned) { $found=$true; $false } else { $true }
        })
        if (-not $found -and @($hooks.hooks[$event] | Where-Object { ($_ | ConvertTo-Json -Depth 12 -Compress) -match 'cockpit.+hook\.mjs' }).Count) { $conflicts += "edited hook $event" }
    }
    if ($manifest.profilePath) {
        if ($ProfilePath -and [IO.Path]::GetFullPath($ProfilePath) -ne $manifest.profilePath) { throw 'Use the installed ProfilePath before changing profile destinations.' }
        $ProfilePath = $manifest.profilePath
        $profileText = if (Test-Path $ProfilePath) { [IO.File]::ReadAllText($ProfilePath) } else { '' }
        $beforeProfile = $profileText
        if ($profileText.Contains($manifest.block)) { $profileText = $profileText.Replace($manifest.block,'') }
        elseif ($profileText.Contains('# BEGIN Codex Cockpit')) { $conflicts += 'edited profile block' }
    }
}
if ($conflicts.Count) { throw ('Owned configuration changed; preserved: ' + ($conflicts -join ', ')) }
if ($Uninstall -and -not $manifest) { Write-Output 'Codex Cockpit is not installed.'; return }
if ($manifest -and -not $Uninstall) {
    foreach ($file in $manifest.files.Keys) {
        if ((Test-Path -LiteralPath $file) -and (Get-FileHash -LiteralPath $file).Hash -ne $manifest.files[$file]) { throw "Deployed file edited; preserved: $file" }
    }
}
$backup = Join-Path $state ('backups/' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($backup) | Out-Null
foreach ($entry in @(@{path=$hooksPath;name='hooks.json'},@{path=$ProfilePath;name='profile.ps1'},@{path=$manifestPath;name='install.json'})) {
    if ($entry.path -and (Test-Path -LiteralPath $entry.path)) { Copy-Item -LiteralPath $entry.path -Destination (Join-Path $backup $entry.name) }
}
if (-not $Uninstall) {
    $deploy = Join-Path $state 'deploy'
    $source = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
    if ($source -ne $deploy) {
        if (-not $manifest -and (Test-Path -LiteralPath $deploy) -and @(Get-ChildItem -LiteralPath $deploy -Recurse -Force -File).Count) { throw "Unowned deployment exists: $deploy" }
        foreach ($dir in @('codex','core','scripts','assets')) {
            [IO.Directory]::CreateDirectory((Join-Path $deploy $dir)) | Out-Null
            Copy-Item -Path (Join-Path $source "$dir/*") -Destination (Join-Path $deploy $dir) -Recurse -Force
        }
    }
    $pipelineDeploy = Join-Path $state 'pipeline'
    if (-not $PipelineSkill) {
        $candidate = Join-Path $source '../pipeline/skills/pipeline'
        $PipelineSkill = if (Test-Path -LiteralPath $candidate) { [IO.Path]::GetFullPath($candidate) } else { $pipelineDeploy }
    }
    if ([IO.Path]::GetFullPath($PipelineSkill) -ne $pipelineDeploy) {
        if (-not $manifest -and (Test-Path -LiteralPath $pipelineDeploy) -and @(Get-ChildItem -LiteralPath $pipelineDeploy -Recurse -Force -File).Count) { throw "Unowned sync deployment exists: $pipelineDeploy" }
        [IO.Directory]::CreateDirectory((Join-Path $pipelineDeploy 'bin')) | Out-Null
        [IO.Directory]::CreateDirectory((Join-Path $pipelineDeploy 'config')) | Out-Null
        foreach ($name in @('setup-codex-home.ps1','AgentLinks.ps1')) { Copy-Item -LiteralPath (Join-Path $PipelineSkill "bin/$name") -Destination (Join-Path $pipelineDeploy "bin/$name") -Force }
        Copy-Item -LiteralPath (Join-Path $PipelineSkill 'config/skill-sync-policy.json') -Destination (Join-Path $pipelineDeploy 'config/skill-sync-policy.json') -Force
    }
    foreach ($required in @('bin/setup-codex-home.ps1','bin/AgentLinks.ps1','config/skill-sync-policy.json')) { if (-not (Test-Path (Join-Path $pipelineDeploy $required))) { throw "Missing deployed sync dependency: $required" } }
    $groups = @{}
    foreach ($event in @('SessionStart','SessionEnd','UserPromptSubmit','PermissionRequest','PostToolUse','PostModelRequest','Stop','Interrupt')) {
        $command = '"' + $NodeExe.Replace('\','/') + '" "' + (Join-Path $deploy 'codex/hook.mjs').Replace('\','/') + '" ' + $event
        $group = [ordered]@{hooks=@([ordered]@{type='command';command=$command;timeout=3})}
        $groups[$event] = $group
        $hooks.hooks[$event] = @(@($hooks.hooks[$event]) + @($group) | Where-Object { $null -ne $_ })
    }
    $block = ''
    if ($ProfilePath) {
        $quoted = (Join-Path $deploy 'codex/start-codex.ps1').Replace("'", "''")
        $quotedHome = $CodexHome.Replace("'", "''")
        $invoke = "& '$quoted' -CodexHome '$quotedHome'"
        $block = "`n# BEGIN Codex Cockpit`nfunction global:codex { if (`$MyInvocation.ExpectingInput) { `$input | $invoke -CockpitHeadless @args } elseif (`$MyInvocation.PipelineLength -gt 1) { $invoke -CockpitHeadless @args } else { $invoke @args } }`n# END Codex Cockpit`n"
        $profileText += $block
    }
    $files = @{}
    foreach ($dir in @($deploy,$pipelineDeploy)) { foreach ($file in Get-ChildItem -LiteralPath $dir -File -Recurse) { $files[$file.FullName] = (Get-FileHash -LiteralPath $file.FullName).Hash } }
    $manifest = @{version=1;groups=$groups;block=$block;profilePath=$(if($ProfilePath){[IO.Path]::GetFullPath($ProfilePath)}else{''});files=$files;pipelineHome=[IO.Path]::GetFullPath($PipelineHome);claudeHome=[IO.Path]::GetFullPath($ClaudeHome);agentsSkills=[IO.Path]::GetFullPath($AgentsSkills);nodeExe=$NodeExe}
}
$afterHooks = $hooks | ConvertTo-Json -Depth 30
if ($(if(Test-Path -LiteralPath $hooksPath){[IO.File]::ReadAllText($hooksPath)}else{$null}) -cne $originalHooks) { throw 'hooks.json changed during install; concurrent edit preserved.' }
if ($ProfilePath -and $(if(Test-Path -LiteralPath $ProfilePath){[IO.File]::ReadAllText($ProfilePath)}else{''}) -cne $beforeProfile) { throw 'Profile changed during install; concurrent edit preserved.' }
if ($afterHooks -cne $beforeHooks) { [IO.File]::WriteAllText($hooksPath, $afterHooks) }
if ($ProfilePath -and $profileText -cne $beforeProfile) { [IO.Directory]::CreateDirectory((Split-Path ([IO.Path]::GetFullPath($ProfilePath)))) | Out-Null; [IO.File]::WriteAllText($ProfilePath, $profileText) }
if ($Uninstall) {
    foreach ($file in $manifest.files.Keys) {
        if ((Test-Path -LiteralPath $file) -and (Get-FileHash -LiteralPath $file).Hash -eq $manifest.files[$file]) { [IO.File]::Delete($file) }
    }
    [IO.File]::Delete($manifestPath)
    Write-Output 'Codex Cockpit hooks and profile block removed; backups and edited files retained. Skill rollback is separate.'
} else {
    $manifest | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $manifestPath -Encoding utf8
    Write-Output 'Codex Cockpit installed. Review and trust the exact command hooks with /hooks in Codex. config.toml and notify were preserved.'
}
