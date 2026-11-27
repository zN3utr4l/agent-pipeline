# Dot-sourced by setup-codex-home.ps1 and setup-claude-home.ps1.
# $ScriptName must be set by the caller before dot-sourcing; it prefixes every
# step line so a test can tell a no-op run from one that changed something.

function Write-Step([string]$Message) {
    Write-Output "${ScriptName}: $Message"
}

function Get-LinkEntry([string]$Path) {
    # Get-Item works on a symlink even when its target is gone; Test-Path does not.
    try { return Get-Item -LiteralPath $Path -Force -ErrorAction Stop } catch { return $null }
}

function Test-LinkTargetExists($Item) {
    $target = $Item.ResolveLinkTarget($true)
    return ($null -ne $target -and $target.Exists)
}

function Remove-BrokenLinks([string]$Directory, [bool]$DryRun) {
    if (-not (Test-Path -LiteralPath $Directory)) { return }
    $entry = Get-LinkEntry $Directory
    if ($entry.LinkType -in @('SymbolicLink', 'Junction') -and -not (Test-LinkTargetExists $entry)) { return }
    foreach ($item in Get-ChildItem -LiteralPath $Directory -Force) {
        if ($item.LinkType -notin @('SymbolicLink', 'Junction')) { continue }
        if (Test-LinkTargetExists $item) { continue }
        Write-Step "removing broken link $($item.FullName) -> $($item.Target)"
        # FileSystemInfo.Delete removes the link itself, never the target's contents.
        if (-not $DryRun) { $item.Delete() }
    }
}

function Ensure-Link([string]$LinkPath, [string]$Target, [bool]$DryRun) {
    if (-not (Test-Path -LiteralPath $Target)) {
        throw "Link target does not exist: $Target"
    }
    $wanted = [IO.Path]::GetFullPath($Target)
    $existing = Get-LinkEntry $LinkPath
    if ($null -ne $existing) {
        if ($existing.LinkType -in @('SymbolicLink', 'Junction')) {
            $current = [IO.Path]::GetFullPath([string]$existing.Target)
            if ($current -eq $wanted) { return }
            Write-Step "relink $LinkPath -> $wanted (was $current)"
            if (-not $DryRun) { $existing.Delete() }
        }
        elseif ($existing.PSIsContainer) {
            throw "$LinkPath is a real directory; move it away before linking."
        }
        elseif ($existing.Length -gt 0) {
            throw "$LinkPath is a non-empty file; move it away before linking."
        }
        else {
            Write-Step "replacing empty file $LinkPath with a link"
            if (-not $DryRun) { $existing.Delete() }
        }
    }
    else {
        Write-Step "link $LinkPath -> $wanted"
    }
    if ($DryRun) { return }
    $parent = Split-Path -Path $LinkPath -Parent
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    New-Item -ItemType SymbolicLink -Path $LinkPath -Target $wanted | Out-Null
}

# Codex reconciliation is intentionally separate from the legacy Claude link helpers.
function Get-SkillObservation([string]$Path) {
    $item = Get-LinkEntry $Path
    if ($null -eq $item) { return 'absent' }
    if ($item.LinkType) { return 'link:' + [string]$item.Target }
    if (-not $item.PSIsContainer) { return 'file:' + (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
    $rows = [Collections.Generic.List[string]]::new()
    foreach ($file in Get-ChildItem -LiteralPath $Path -Recurse -Force | Sort-Object FullName) {
        if ($file.LinkType) { $rows.Add($file.FullName.Substring($Path.Length) + ':link:' + $file.Target) }
        elseif (-not $file.PSIsContainer) { $rows.Add($file.FullName.Substring($Path.Length) + ':' + (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash) }
        else { $rows.Add($file.FullName.Substring($Path.Length) + ':directory') }
    }
    return 'tree:' + [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes(($rows -join "`n"))))
}

function Get-SkillSources([string]$ClaudeHome, [string[]]$ActivePluginDirectory) {
    $roots = [Collections.Generic.List[object]]::new()
    $settingsFile = Join-Path $ClaudeHome 'settings.json'
    $installedFile = Join-Path $ClaudeHome 'plugins/installed_plugins.json'
    if ((Test-Path $settingsFile) -and (Test-Path $installedFile)) {
        $settings = Get-Content -Raw -LiteralPath $settingsFile | ConvertFrom-Json -AsHashtable
        $installed = Get-Content -Raw -LiteralPath $installedFile | ConvertFrom-Json -AsHashtable
        $enabled = if ($settings.ContainsKey('enabledPlugins') -and $settings.enabledPlugins -is [Collections.IDictionary]) { $settings.enabledPlugins } else { @{} }
        foreach ($key in @($enabled.Keys | Sort-Object)) {
            if ($enabled[$key] -ne $true) { continue }
            $records = @(if ($installed.ContainsKey('plugins')) { $installed.plugins[$key] | Where-Object { $_ -and $_.scope -eq 'user' } })
            if ($records.Count -gt 1) { throw "Ambiguous current plugin installation: $key" }
            if ($records.Count -eq 1) { $roots.Add(@{Path=(Join-Path $records[0].installPath 'skills'); Provenance="enabled-plugin:$key"}) }
        }
    }
    foreach ($dir in $ActivePluginDirectory) { $roots.Add(@{Path=(Join-Path ([IO.Path]::GetFullPath($dir)) 'skills'); Provenance='active-directory'}) }
    $roots.Add(@{Path=(Join-Path $ClaudeHome 'skills'); Provenance='local-or-synced'})
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root.Path -PathType Container)) { continue }
        $pending = [Collections.Generic.Queue[string]]::new(); $pending.Enqueue($root.Path)
        $visited = @{}
        while ($pending.Count) {
            $directory = $pending.Dequeue()
            $item = Get-LinkEntry $directory
            try { $resolved = if ($item.LinkType) { $item.ResolveLinkTarget($true).FullName } else { $item.FullName } } catch { continue }
            if (-not $resolved -or $visited.ContainsKey($resolved)) { continue }
            $visited[$resolved] = $true
            if (Test-Path -LiteralPath (Join-Path $resolved 'SKILL.md') -PathType Leaf) {
                [pscustomobject]@{Name=$item.Name; Path=$resolved; Provenance=$root.Provenance}
                continue
            }
            foreach ($child in Get-ChildItem -LiteralPath $resolved -Directory -Force | Sort-Object Name) {
                if ($child.Name.StartsWith('.')) { continue }
                # Container links cannot be trusted to form an acyclic discovery tree.
                if ($child.LinkType -and -not (Test-Path -LiteralPath (Join-Path $child.FullName 'SKILL.md'))) { continue }
                $pending.Enqueue($child.FullName)
            }
        }
    }
}

function Resolve-SkillResource([string]$Token, [string]$Source, [string]$Document, [hashtable]$Sources) {
    $tokenPath = $Token.Trim([char[]]'"''').Replace('\','/')
    $root = $Source; $relative = $tokenPath; $sibling = $null
    if ($tokenPath -match '^(?:<SKILL_DIR>|\$\{CLAUDE_SKILL_DIR\})/(.+)$') { $relative = $Matches[1] }
    elseif ($tokenPath -match '^<MEDIA_DIR>/(.+)$') { $sibling='media-use'; $relative=$Matches[1] }
    elseif ($tokenPath -match '^skills/([^/]+)/(.+)$') { $sibling=$Matches[1]; $relative=$Matches[2] }
    elseif ($tokenPath -match '^(?:\.\./)+([^/]+)/(.+)$' -and $Sources.ContainsKey($Matches[1])) { $sibling=$Matches[1]; $relative=$Matches[2] }
    elseif ([IO.Path]::IsPathRooted($tokenPath) -or $tokenPath.StartsWith('$')) { return @{external=$true} }
    if ($sibling) {
        if (-not $Sources.ContainsKey($sibling)) { return $null }
        $root = $Sources[$sibling]
        if ($root -eq $Source) { $sibling=$null }
    }
    if (-not $sibling -and $relative -match '^(?:\.\./)+(scripts/[^<>]+)$') { $relative=$Matches[1] }
    $candidate = [IO.Path]::GetFullPath((Join-Path $root $relative))
    if (-not $sibling -and $relative -notmatch '/' -and -not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        $candidate = Join-Path $root "scripts/$relative"
    }
    if (-not $sibling -and -not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        $candidate = [IO.Path]::GetFullPath((Join-Path (Split-Path $Document) $relative))
    }
    if (-not $candidate.StartsWith($root + [IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $candidate -PathType Leaf)) { return $null }
    return @{external=$false;path=$candidate;relative=[IO.Path]::GetRelativePath($root,$candidate);sibling=$sibling}
}

function Get-SkillPortability([string]$Source, [string[]]$VerifiedMcpServer = @(), [hashtable]$Sources = @{}) {
    if (@(Get-ChildItem -LiteralPath $Source -Recurse -Force | Where-Object LinkType).Count) { return @{status='unsupported:linked supporting tree'} }
    $edits = @(); $siblings = @{}; $notes = @(); $rootTokens = $false
    $commandPattern = '(?<command>\b(?:python\d*|node|bash|sh|pwsh|powershell)\s+(?:(?:-[\w=-]+)\s+)*)(?<resource>"[^"\r\n]+\.(?:mjs|cjs|js|py|ps1|sh)"|''[^''\r\n]+\.(?:mjs|cjs|js|py|ps1|sh)''|(?:\$\{CLAUDE_SKILL_DIR\}|<SKILL_DIR>|<MEDIA_DIR>)[/\\][^\s\x60"''<>;|()]+\.(?:mjs|cjs|js|py|ps1|sh)|[^\s\x60"''<>;|()]+\.(?:mjs|cjs|js|py|ps1|sh))'
    foreach ($file in Get-ChildItem -LiteralPath $Source -File -Recurse -Force | Sort-Object FullName) {
        if ($file.Extension -notin '.md','.ps1','.py','.js','.mjs','.cjs','.sh') { continue }
        if ($file.Length -gt 2MB) { return @{status="unsupported:oversized resource $($file.Name)"} }
        $relative = [IO.Path]::GetRelativePath($Source,$file.FullName).Replace('\','/')
        $text = [IO.File]::ReadAllText($file.FullName)
        $rootTokens = $rootTokens -or $text.Contains('${CLAUDE_SKILL_DIR}') -or $text.Contains('<SKILL_DIR>') -or $text.Contains('<MEDIA_DIR>')
        $developmentFile = $relative -match '(?:^|/)(?:tests?|test-corpus|fixtures)(?:/|$)|\.test\.[^.]+$'
        $optionalFile = $text.Substring(0,[Math]::Min(1600,$text.Length)) -match '(?im)^.*(?:temporary workaround.*standalone|optional.*standalone|^#.*optional)'
        $sections = @(); $frontmatter = $false; $fence = $null
        $lines = $text -split '\r?\n'
        for ($index=0; $index -lt $lines.Count; $index++) {
            $line = $lines[$index]; $where = "${relative}:$($index+1)"
            if ($file.Extension -eq '.md') {
                if ($index -eq 0 -and $line -eq '---') { $frontmatter=$true; continue }
                if ($frontmatter) {
                    if ($line -eq '---') { $frontmatter=$false }
                    elseif ($line -match '^\s*(?:allowed-tools|tools)\s*:') { return @{status="unsupported:${where}: required tool frontmatter $($line.Trim())"} }
                    continue
                }
                if ($line -match '^\s*(?:\x60{3,}|~{3,})(\w*)') {
                    $fence = if ($null -eq $fence) { $Matches[1] } else { $null }
                    continue
                }
                if ($null -eq $fence -and $line -match '^(#{1,6})\s+(.+)') {
                    $depth=$Matches[1].Length; $heading=$Matches[2]
                    $sections=@($sections | Where-Object depth -LT $depth)
                    $sections+=@{depth=$depth;development=($heading -match '\b(?:development|developer|maintainer|per-fixture|test.corpus)\b|how to grade your own');optional=($heading -match '\b(?:optional|fallback|alternative)\b')}
                }
                if ($developmentFile -or @($sections | Where-Object development).Count) { continue }
                if ($null -ne $fence -and $line -match '^\s*(?:#|//|/\*|\*)') { continue }
                $optional = $optionalFile -or @($sections | Where-Object optional).Count -gt 0 -or ($line -match '\boptional\b' -and $line -notmatch '\bnot\s+optional\b|\bmandatory\b')
                $withoutRoot = $line.Replace('${CLAUDE_SKILL_DIR}','')
                $runtime = $withoutRoot -cmatch '\bCLAUDE_[A-Z_]+|mcp__|\$\.process|\$\.session|~[/\\]\.claude'
                $runtime = $runtime -or $line -match '(?i)\b(?:must|required?|only|invoke|call|use)\b.{0,60}\b(?:Bash|Read|Grep|Task)\s+tool\b|\b(?:requires? Claude|Claude(?: Code)?[- ]only|Claude (?:Code )?runtime)\b'
                if ($runtime -and -not $optional) { return @{status="unsupported:${where}: required Claude runtime/tool instruction $($line.Trim().Substring(0,[Math]::Min(140,$line.Trim().Length)))"} }
                foreach ($match in [regex]::Matches($line,'(?i)\b(?:MCP\s+server|server\s+MCP)\s+[\x60"'']([a-z0-9_-]+)[\x60"'']')) {
                    if ($match.Groups[1].Value -notin $VerifiedMcpServer -and -not $optional) { return @{status="unsupported:${where}: unverified MCP server $($match.Groups[1].Value)"} }
                }
                $tool = [regex]::Match($line,'(?i)\bMCP\s+[\x60"'']([a-z0-9_-]+)[\x60"'']\s+tool\b')
                if ($tool.Success -and -not $optional) { return @{status="unsupported:${where}: required MCP tool $($tool.Groups[1].Value) has no verified native adapter"} }
                if ($optional -and ($runtime -or $tool.Success -or $line -match '\bMCP\b')) { $notes += "Conditional capability in ${where}: verify its selected provider/tool before use; it is not attested by skill sync." }
                if ($null -ne $fence -and $fence -notin '','bash','sh','shell','console','powershell','ps1') { continue }
                $directPattern='(?<![\w/])(?<command>)(?<resource>(?:\.\.?/)+(?:scripts|bin)/[^\s\x60"''<>;|()]+\.sh)'
                $commands=@([regex]::Matches($line,$commandPattern))
                $commands+=@([regex]::Matches($line,$directPattern) | Where-Object { $direct=$_; -not @($commands | Where-Object { $direct.Index -ge $_.Index -and $direct.Index -lt ($_.Index+$_.Length) }).Count })
                foreach ($match in $commands) {
                    $token=$match.Groups['resource'].Value
                    $resource=Resolve-SkillResource $token $Source $file.FullName $Sources
                    if (-not $resource -and $line -match '^\s*>\s*Illustrative:') {
                        $notes+="Illustrative command in ${where} references missing resource ${token}; do not execute it. Follow the documented alternative only after verifying its prerequisites."
                        continue
                    }
                    if (-not $resource) { return @{status="unsupported:${where}: executable resource not found: $token"} }
                    if ($resource.external) { continue }
                    if ($resource.sibling) { $siblings[$resource.sibling]=$Sources[$resource.sibling] }
                    $edits+=@{file=$relative;line=$index;before=$match.Value;command=$match.Groups['command'].Value;relative=$resource.relative;sibling=$resource.sibling}
                }
            }
            else {
                if ($developmentFile -or $line -match '^\s*(?://|#|\*|/\*)') { continue }
                if ($line -match '(?:import|require).+["'']claude-code["'']|(?:process\.env[.\[]|os\.environ).+CLAUDE_[A-Z_]+') { return @{status="unsupported:${where}: executable requires Claude runtime"} }
            }
            # Keep the original sibling layout for code imports and documented resources.
            foreach ($name in $(if($line -match '\.\./|["'']\.\.["'']|skills/'){$Sources.Keys}else{@()})) {
                if ($Sources[$name] -eq $Source) { continue }
                $escaped=[regex]::Escape($name)
                $siblingPattern='(?:\.\./)+{0}(?:/|["''])|["'']\.\.["'']\s*,[^;\r\n]*["'']{0}["'']' -f $escaped
                if ($line -match $siblingPattern -or $line -match "skills/$escaped/") { $siblings[$name]=$Sources[$name] }
            }
        }
        if ($text.Contains('<MEDIA_DIR>')) {
            if (-not $Sources.ContainsKey('media-use')) { return @{status="unsupported:${relative}: installed media-use directory is missing for <MEDIA_DIR>"} }
            if ($Sources['media-use'] -ne $Source) { $siblings['media-use']=$Sources['media-use'] }
        }
    }
    $dependencies=@(foreach($name in @($siblings.Keys | Sort-Object)){@{name=$name;source=$siblings[$name];before=(Get-SkillObservation $siblings[$name])}})
    return @{status=$(if($rootTokens -or $edits.Count -or $dependencies.Count -or $notes.Count){'adapted:verified-resource-context'}else{'portable:directory'});edits=@($edits);siblings=$dependencies;mediaRoot=$Sources['media-use'];notes=@($notes | Sort-Object -Unique)}
}

function Get-SkillOwnedObservation($Entry) {
    $path = if ($Entry.ContainsKey('observationPath') -and $Entry.observationPath) { $Entry.observationPath } else { $Entry.target }
    return Get-SkillObservation $path
}

function Test-SkillSourceObservation($Entry) {
    if ((Get-SkillObservation $Entry.source) -ne $Entry.sourceBefore) { return $false }
    if ($Entry.ContainsKey('adaptation')) {
        foreach ($dependency in $Entry.adaptation.siblings) { if ((Get-SkillObservation $dependency.source) -ne $dependency.before) { return $false } }
    }
    return $true
}

function Invoke-CodexSkillSync {
    param([string]$CodexHome, [string]$ClaudeHome, [string]$AgentsSkills, [string[]]$ActivePluginDirectory,
        [string[]]$AdoptSkill, [bool]$DryRun, [string]$PlanPath, [string]$ApplyPlan, [switch]$Rollback,
        [string[]]$VerifiedMcpServer = @())
    $stateRoot = Join-Path $CodexHome 'skill-sync'
    if ($AgentsSkills -eq (Join-Path $CodexHome 'skills')) { throw 'Codex and Agents discovery roots must be distinct.' }
    $ledgerPath = Join-Path $stateRoot 'owned.json'
    $ledger = if (Test-Path $ledgerPath) { Get-Content -Raw -LiteralPath $ledgerPath | ConvertFrom-Json -AsHashtable } else { @{version=1; entries=@(); activePluginDirectory=@();verifiedMcpServer=@()} }
    if (-not $ledger.ContainsKey('projectionHashes')) { $ledger.projectionHashes = @{} }
    if (-not $VerifiedMcpServer -and $ledger.ContainsKey('verifiedMcpServer')) { $VerifiedMcpServer = @($ledger.verifiedMcpServer) }
    foreach ($root in @((Join-Path $CodexHome 'skills'), $AgentsSkills, $stateRoot)) {
        $item = Get-LinkEntry $root
        if ($item -and $item.LinkType) { throw "Unknown root link preserved: $root" }
    }
    if ($Rollback) {
        if (-not (Test-Path -LiteralPath $ledgerPath)) { Write-Step 'rollback: no owned skills'; return }
        $remaining = @()
        foreach ($entry in @($ledger.entries)) {
            $name = Split-Path -Path $entry.path -Leaf
            if ($entry.path -notin @((Join-Path $CodexHome "skills/$name"),(Join-Path $AgentsSkills $name))) { throw 'Invalid owned skill path; rollback stopped.' }
            if ((Get-SkillObservation $entry.path) -ne $entry.after -or ($entry.target -and (Get-SkillOwnedObservation $entry) -ne $entry.targetAfter)) {
                Write-Step "rollback conflict: $($entry.path) (concurrent edit preserved)"; $remaining += $entry; continue
            }
            if ($entry.backup -and (Get-SkillObservation $entry.backup) -ne $entry.before) { Write-Step "rollback conflict: backup $($entry.backup) (concurrent edit preserved)"; $remaining += $entry; continue }
            if (-not $DryRun) {
                $item = Get-LinkEntry $entry.path
                if ($item) { $item.Delete() }
                if ($entry.backup) {
                    Move-Item -LiteralPath $entry.backup -Destination $entry.path
                }
            }
            Write-Step "rollback $($entry.path)"
        }
        if (-not $DryRun) { $ledger.entries = @($remaining); $ledger | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $ledgerPath -Encoding utf8 }
        return
    }
    $policy = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot '../config/skill-sync-policy.json') | ConvertFrom-Json
    foreach ($name in $AdoptSkill) { if ($name -notin $policy.adoptable) { throw "Not authorized for adoption: $name" } }
    if ($ApplyPlan) {
        $plan = Get-Content -Raw -LiteralPath $ApplyPlan | ConvertFrom-Json -AsHashtable
        if (-not $plan.ContainsKey('adapterVersion') -or $plan.adapterVersion -ne 2) { throw 'Skill adapter changed; regenerate and review the skill plan.' }
        if ($plan.codexHome -ne $CodexHome -or $plan.agentsSkills -ne $AgentsSkills) { throw 'Plan roots do not match invocation' }
        foreach ($entry in $plan.entries) {
            $validPaths = @((Join-Path $CodexHome "skills/$($entry.name)"), (Join-Path $AgentsSkills $entry.name))
            if ($entry.name -notmatch '^[a-zA-Z0-9][a-zA-Z0-9._-]*$' -or $entry.path -notin $validPaths) { throw 'Invalid skill plan path' }
            if ($entry.action -in 'adopt','consolidate' -and $entry.name -notin $policy.adoptable) { throw 'Plan requests unauthorized adoption' }
            if ($entry.action -ne 'retire' -and ($entry.name -in $policy.native -or $entry.name -in $policy.excluded)) { throw 'Plan conflicts with protected native/excluded skill policy' }
            if ((Get-SkillObservation $entry.path) -ne $entry.before -or -not (Test-SkillSourceObservation $entry)) { throw "Before-state changed: $($entry.path)" }
        }
    }
    else {
        if (-not $ActivePluginDirectory) { $ActivePluginDirectory = @($ledger.activePluginDirectory) }
        $entries = @(); $seen = @{}; $eligible = @{}
        $discovered = @(Get-SkillSources $ClaudeHome $ActivePluginDirectory)
        $sources = @{}
        foreach ($skill in $discovered) { if (-not $sources.ContainsKey($skill.Name)) { $sources[$skill.Name]=$skill.Path } }
        foreach ($skill in $discovered) {
            if ($seen.ContainsKey($skill.Name)) { Write-Step "duplicate source: $($skill.Name) ($($skill.Provenance)); first source retained"; continue }
            $seen[$skill.Name] = $true
            $adaptation = $null
            $portability = if ($skill.Name -in $policy.native) { 'native-equivalent:preserved' } elseif ($skill.Name -in $policy.excluded) { 'unsupported:deliberate-exclusion' } else { $adaptation=Get-SkillPortability $skill.Path $VerifiedMcpServer $sources; $adaptation.status }
            if ($skill.Name -notmatch '^[a-zA-Z0-9][a-zA-Z0-9._-]*$') { $portability = 'unsupported:invalid-directory-name' }
            $resourceRoots=@($skill.Path)
            if ($adaptation -and $adaptation.ContainsKey('siblings')) { $resourceRoots+=@($adaptation.siblings | ForEach-Object source) }
            foreach ($targetRoot in @((Join-Path $CodexHome 'skills'), $AgentsSkills, $stateRoot)) {
                foreach ($sourceRoot in $resourceRoots) {
                    if ($sourceRoot -eq $targetRoot -or $sourceRoot.StartsWith($targetRoot + [IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or $targetRoot.StartsWith($sourceRoot + [IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { $portability = 'unsupported:discovery-cycle' }
                }
            }
            Write-Step "$($skill.Name): provenance=$($skill.Provenance) portability=$portability source=$($skill.Path)"
            if ($portability -notmatch '^(portable|adapted):') { continue }
            $eligible[$skill.Name] = $true
            $sourceBefore = Get-SkillObservation $skill.Path
            $path = Join-Path $CodexHome "skills/$($skill.Name)"
            $other = Join-Path $AgentsSkills $skill.Name
            $own = @($ledger.entries | Where-Object path -EQ $path) | Select-Object -First 1
            $before = Get-SkillObservation $path
            $action = 'link'
            if ($own -and $own.portability.StartsWith('adapted:') -and $own.target -and (Get-SkillOwnedObservation $own) -ne $own.targetAfter) { Write-Step "conflict: edited projection $($own.target)"; continue }
            if ($before -ne 'absent' -and (-not $own -or $own.after -ne $before)) {
                if ($skill.Name -in $AdoptSkill -and $before.StartsWith('tree:')) { $action = 'adopt' }
                else { Write-Step "conflict: $path (unowned entry preserved)"; continue }
            }
            if ((Get-SkillObservation $other) -ne 'absent') {
                if ($skill.Name -in $AdoptSkill -and (Get-SkillObservation $other).StartsWith('tree:')) {
                    $entries += @{name=$skill.Name;path=$other;source=$skill.Path;sourceBefore=$sourceBefore;before=(Get-SkillObservation $other);action='consolidate';portability=$portability;provenance=$skill.Provenance;adaptation=$adaptation}
                } else { Write-Step "conflict: duplicate descriptor $other (preserved)"; continue }
            }
            $entries += @{name=$skill.Name;path=$path;source=$skill.Path;sourceBefore=$sourceBefore;before=$before;action=$action;portability=$portability;provenance=$skill.Provenance;adaptation=$adaptation}
        }
        foreach ($old in @($ledger.entries)) {
            $name = Split-Path -Path $old.path -Leaf
            if ($old.after -eq 'absent' -or $eligible.ContainsKey($name) -or (Get-SkillObservation $old.path) -ne $old.after) { continue }
            if ($old.portability.StartsWith('adapted:') -and (Get-SkillOwnedObservation $old) -ne $old.targetAfter) { Write-Step "conflict: edited projection $($old.target)"; continue }
            $entries += @{name=$name;path=$old.path;source=$old.source;sourceBefore=(Get-SkillObservation $old.source);before=$old.after;action='retire';portability=$old.portability;provenance=$old.provenance}
        }
        $plan = @{version=1;adapterVersion=2;codexHome=$CodexHome;agentsSkills=$AgentsSkills;entries=@($entries);activePluginDirectory=@($ActivePluginDirectory);verifiedMcpServer=@($VerifiedMcpServer)}
        if ($PlanPath) { $plan | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $PlanPath -Encoding utf8 }
    }
    if ($DryRun) { return }
    [IO.Directory]::CreateDirectory($stateRoot) | Out-Null
    $transaction = [guid]::NewGuid().ToString('N')
    # Preserve every selected original before exposing any replacement descriptor.
    # Record each move immediately so an interrupted adoption can be rolled back.
    foreach ($entry in @($plan.entries | Where-Object action -In 'adopt','consolidate')) {
        if ((Get-SkillObservation $entry.path) -ne $entry.before -or -not (Test-SkillSourceObservation $entry)) { throw "Before-state changed: $($entry.path)" }
        $rootLabel = if ($entry.path -eq (Join-Path $CodexHome "skills/$($entry.name)")) { 'codex' } else { 'agents' }
        $backup = Join-Path $stateRoot "backups/$transaction/$rootLabel/$($entry.name)"
        [IO.Directory]::CreateDirectory((Split-Path $backup)) | Out-Null
        Move-Item -LiteralPath $entry.path -Destination $backup
        $record = @{path=$entry.path;before=$entry.before;after='absent';backup=$backup;target=$null;targetAfter=$null;source=$entry.source;provenance=$entry.provenance;portability=$entry.portability}
        $ledger.entries = @(@($ledger.entries | Where-Object path -NE $entry.path) + @($record))
        $ledger | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $ledgerPath -Encoding utf8
        $entry.before = 'absent'
    }
    foreach ($entry in $plan.entries) {
        # Validate again immediately before each mutation, including during a refresh.
        if ((Get-SkillObservation $entry.path) -ne $entry.before -or -not (Test-SkillSourceObservation $entry)) { throw "Before-state changed: $($entry.path)" }
        $old = @($ledger.entries | Where-Object path -EQ $entry.path) | Select-Object -First 1
        $backup = if ($old) { $old.backup } else { $null }
        $originalBefore = if ($old) { $old.before } else { $entry.before }
        $target = $null
        $observationPath = $null
        if ($entry.action -notin 'consolidate','retire') {
            $target = $entry.source
            if ($entry.portability.StartsWith('adapted:')) {
                $revisionInput=[ordered]@{adapter=2;source=$entry.sourceBefore;siblings=@(foreach($dependency in $entry.adaptation.siblings){[ordered]@{name=$dependency.name;source=$dependency.source;before=$dependency.before}})} | ConvertTo-Json -Depth 8 -Compress
                $revision=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($revisionInput)))
                $observationPath = Join-Path $stateRoot "projections/$($entry.name)/$revision"
                $target = Join-Path $observationPath $entry.name
                if (Test-Path -LiteralPath $observationPath) {
                    $expected = if ($ledger.projectionHashes.ContainsKey($observationPath)) { $ledger.projectionHashes[$observationPath] } else { $null }
                    if (-not $expected -or (Get-SkillObservation $observationPath) -ne $expected) { Write-Step "conflict: edited projection $target"; continue }
                }
                if (-not (Test-Path -LiteralPath $target)) {
                    [IO.Directory]::CreateDirectory((Split-Path $target)) | Out-Null
                    Copy-Item -LiteralPath $entry.source -Destination $target -Recurse
                    foreach ($dependency in $entry.adaptation.siblings) {
                        New-Item -ItemType SymbolicLink -Path (Join-Path $observationPath $dependency.name) -Target $dependency.source | Out-Null
                    }
                    foreach ($group in $entry.adaptation.edits | Group-Object file) {
                        $document=Join-Path $target $group.Name
                        $lines=[IO.File]::ReadAllLines($document)
                        foreach($edit in $group.Group) {
                            $root=if($edit.sibling){($entry.adaptation.siblings | Where-Object name -EQ $edit.sibling).source}else{$target}
                            $absolute=(Join-Path $root $edit.relative).Replace('\','/')
                            $lines[$edit.line]=$lines[$edit.line].Replace($edit.before,($edit.command + '"' + $absolute + '"'))
                        }
                        [IO.File]::WriteAllLines($document,$lines)
                    }
                    foreach ($file in Get-ChildItem -LiteralPath $target -File -Recurse | Where-Object Extension -In '.md','.ps1','.py','.js','.mjs','.cjs','.sh','.json','.yaml','.yml') {
                        $text = [IO.File]::ReadAllText($file.FullName)
                        if ($text.Contains('${CLAUDE_SKILL_DIR}')) { [IO.File]::WriteAllText($file.FullName, $text.Replace('${CLAUDE_SKILL_DIR}', $target.Replace('\','/'))) }
                        if ($file.Extension -eq '.md') {
                            $text=[IO.File]::ReadAllText($file.FullName).Replace('<SKILL_DIR>',$target.Replace('\','/'))
                            $media=@($entry.adaptation.siblings | Where-Object name -EQ 'media-use')
                            if ($media.Count) { $text=$text.Replace('<MEDIA_DIR>',$media[0].source.Replace('\','/')) }
                            elseif ($entry.source -eq $entry.adaptation.mediaRoot) { $text=$text.Replace('<MEDIA_DIR>',$target.Replace('\','/')) }
                            [IO.File]::WriteAllText($file.FullName,$text)
                        }
                    }
                    $descriptor=Join-Path $target 'SKILL.md'
                    $text=[IO.File]::ReadAllText($descriptor)
                    $front=[regex]::Match($text,'(?s)\A---\r?\n.*?\r?\n---(?:\r?\n|$)')
                    $preamble="`n## Codex portability`n`nInstalled skill root: $($target.Replace('\','/')). Existing bundled resource paths resolve from this root, never from the project cwd. Keep project operands in the project cwd; quote installed paths. Supporting modules and sibling resources retain their original layout. External tools, platform constraints and provider sign-in remain prerequisites; no provider or creative choice is changed.`n"
                    foreach($note in $entry.adaptation.notes){$preamble+="- $note`n"}
                    [IO.File]::WriteAllText($descriptor,$text.Insert($front.Length,$preamble+"`n"))
                    if (-not (Test-SkillSourceObservation $entry)) { throw "Source changed while projecting: $($entry.source)" }
                }
                $ledger.projectionHashes[$observationPath] = Get-SkillObservation $observationPath
            }
        }
        $wanted = if ($target) { 'link:' + $target } else { 'absent' }
        if ($entry.before -ne $wanted) {
            $item = Get-LinkEntry $entry.path
            if ($item) { $item.Delete() }
            if ($target) { [IO.Directory]::CreateDirectory((Split-Path $entry.path)) | Out-Null; New-Item -ItemType SymbolicLink -Path $entry.path -Target $target | Out-Null }
            Write-Step "sync $($entry.path) -> $target"
        }
        $record = @{path=$entry.path;before=$originalBefore;after=$wanted;backup=$backup;target=$target;observationPath=$observationPath;targetAfter=$(if ($target) { Get-SkillObservation $(if($observationPath){$observationPath}else{$target}) } else { $null });source=$entry.source;provenance=$entry.provenance;portability=$entry.portability}
        $ledger.entries = @(@($ledger.entries | Where-Object path -NE $entry.path) + @($record))
        $ledger.activePluginDirectory = @($plan.activePluginDirectory)
        $ledger.verifiedMcpServer = @($plan.verifiedMcpServer)
        $ledger | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $ledgerPath -Encoding utf8
    }
    $ledger.activePluginDirectory = @($plan.activePluginDirectory)
    $ledger.verifiedMcpServer = @($plan.verifiedMcpServer)
    $ledger | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $ledgerPath -Encoding utf8
}
