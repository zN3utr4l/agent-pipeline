Set-StrictMode -Version Latest
function Get-CockpitWorkingDirectory([string[]]$Arguments, [string]$Default) {
    $directory = $Default
    for ($i=0; $i -lt $Arguments.Count; $i++) {
        if ($Arguments[$i] -in '-C','--cd' -and $i+1 -lt $Arguments.Count) { $directory=[IO.Path]::GetFullPath($Arguments[++$i],$Default) }
        elseif ($Arguments[$i].StartsWith('--cd=')) { $directory=[IO.Path]::GetFullPath($Arguments[$i].Substring(5),$Default) }
    }
    return $directory
}
function Test-CockpitInteractive([string[]]$Arguments, [bool]$TerminalInput, [bool]$TerminalOutput) {
    if (-not $TerminalInput -or -not $TerminalOutput) { return $false }
    if (@($Arguments | Where-Object { $_ -in '--help','-h','--version','-V' }).Count) { return $false }
    $commands = @('exec','e','review','login','logout','mcp','plugin','app-server','remote-control','app','completion','update','doctor','sandbox','debug','apply','a','queue','archive','delete','migrate-rollouts','migrate-nfs-db','unarchive','cloud','exec-server','features','help')
    # Ignore values for known root options when finding the command position.
    $takesValue = @('-c','--config','--enable','--disable','--remote','--remote-auth-token-env','-i','--image','-m','--model','--local-provider','-p','--profile','-s','--sandbox','-a','--ask-for-approval','-C','--cd','--add-dir')
    for ($i=0; $i -lt $Arguments.Count; $i++) {
        $value = $Arguments[$i]
        if ($value -in $takesValue) { $i++; continue }
        if ($value.StartsWith('-')) { continue }
        if ($value -in $commands) { return $false }
        if ($value -in 'resume','fork' -and $i+1 -lt $Arguments.Count -and $Arguments[$i+1] -in 'exec','e') { return $false }
        break
    }
    return $true
}

function Get-CockpitSkillSuppression([string]$Cwd, [string]$ClaudeHome, [string[]]$SkillRoots) {
    $selector = Join-Path $Cwd '.claude/harness-scope.json'
    if (-not (Test-Path -LiteralPath $selector)) { return @() }
    try {
        $selection = Get-Content -Raw -LiteralPath $selector | ConvertFrom-Json -AsHashtable
        if ($selection.Keys.Count -ne 1 -or $selection.profile -notin 'code','video') { return @() }
        $profile = Join-Path $ClaudeHome "harness-scope/profiles/$($selection.profile).json"
        if (-not (Test-Path -LiteralPath $profile)) { return @() }
        $rules = Get-Content -Raw -LiteralPath $profile | ConvertFrom-Json -AsHashtable
        if (-not $rules.skills -or $rules.skills.Keys.Count -ne 1 -or @($rules.skills.Keys)[0] -notin 'allow','deny') { return @() }
        $mode = @($rules.skills.Keys)[0]; $patterns = @($rules.skills[$mode])
        if (@($patterns | Where-Object { $_ -isnot [string] }).Count) { return @() }
        $entries = @()
        foreach ($root in $SkillRoots) {
            if (-not (Test-Path -LiteralPath $root)) { continue }
            $pending = [Collections.Generic.Queue[string]]::new(); $pending.Enqueue($root)
            $visited = @{}; $files = @()
            while ($pending.Count -gt 0 -and $visited.Count -lt 2000) {
                $dir = $pending.Dequeue(); $item = Get-Item -LiteralPath $dir -Force
                $canonical = if ($item.LinkType) { $item.ResolveLinkTarget($true).FullName } else { $item.FullName }
                if (-not $canonical -or $visited.ContainsKey($canonical)) { continue }; $visited[$canonical] = $true
                $descriptor = Join-Path $dir 'SKILL.md'
                if (Test-Path -LiteralPath $descriptor -PathType Leaf) { $files += Get-Item -LiteralPath $descriptor; continue }
                foreach ($child in Get-ChildItem -LiteralPath $dir -Directory -Force) { if (-not $child.Name.StartsWith('.')) { $pending.Enqueue($child.FullName) } }
            }
            foreach ($file in $files) {
                if ($file.FullName -match '[\\/]\.system[\\/]') { continue }
                $name = $file.Directory.Name
                $matched = @($patterns | Where-Object { $name -clike $_ }).Count -gt 0
                if (($mode -eq 'deny' -and $matched) -or ($mode -eq 'allow' -and -not $matched)) {
                    # Codex selects SKILL.md by its exact discovered absolute path.
                    $entries += '{path=' + (ConvertTo-Json -InputObject $file.FullName.Replace('\','/') -Compress) + ',enabled=false}'
                }
            }
        }
        if ($entries.Count) { return @('-c', ('skills.config=[' + (($entries | Sort-Object -Unique) -join ',') + ']')) }
    } catch { Write-Warning 'Harness selector could not be translated; current discovery retained.' }
    return @()
}

function New-CockpitTerminalArguments([string]$NodeExe, [string]$Dashboard, [string]$ScopeFile, [string]$PipelineHome) {
    # EncodedCommand keeps Windows Terminal's semicolon parser away from paths.
    $quote = { param($value) "'" + $value.Replace("'", "''") + "'" }
    $command = '& ' + (& $quote $NodeExe) + ' ' + (& $quote $Dashboard) + ' --scope ' + (& $quote $ScopeFile) + ' --pipeline-home ' + (& $quote $PipelineHome)
    return @('-w','0','new-tab','--title','Codex Cockpit','pwsh','-NoProfile','-EncodedCommand',[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command)))
}
