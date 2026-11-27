$ErrorActionPreference = 'Stop'
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$setup = Join-Path $repo 'plugins/pipeline/skills/pipeline/bin/setup-codex-home.ps1'
$work = Join-Path ([IO.Path]::GetTempPath()) ('codex-sync-' + [guid]::NewGuid())
$checks = 0
function Check($Value, $Label) { $script:checks++; if (-not $Value) { throw $Label } }
function Put($Path, $Text) { [IO.Directory]::CreateDirectory((Split-Path $Path)) | Out-Null; [IO.File]::WriteAllText($Path, $Text) }
function Sync([string[]]$Extra = @()) {
    $out = & pwsh -NoProfile -File $setup -SyncSkillsOnly -CodexHome "$work/codex" -ClaudeHome "$work/claude" -AgentsSkills "$work/agents/skills" @Extra 2>&1 | Out-String
    if ($LASTEXITCODE) { throw $out }; return $out
}
try {
    Put "$work/claude/settings.json" '{"enabledPlugins":{"demo@test":true}}'
    Put "$work/cache-v2/skills/current/SKILL.md" '# Current'
    Put "$work/claude/plugins/marketplaces/test/plugins/demo/skills/old/SKILL.md" '# Stale checkout'
    Put "$work/claude/plugins/installed_plugins.json" (@{plugins=@{'demo@test'=@(@{scope='user';installPath="$work/cache-v2"})}} | ConvertTo-Json -Depth 8)
    Put "$work/claude/skills/synced/bucket/deep/nested/SKILL.md" '# Nested'
    Put "$work/claude/skills/adapted/SKILL.md" 'Run: pwsh -NoProfile -File "${CLAUDE_SKILL_DIR}/scripts/local.ps1"'
    Put "$work/claude/skills/adapted/scripts/local.ps1" "Write-Output 'support-v1'"
    Put "$work/claude/skills/unsafe/SKILL.md" 'Run python scripts/relative.py using mcp__unknown__execute'
    Put "$work/claude/skills/relative-file/SKILL.md" 'Run pwsh -NoProfile -File utility.ps1'
    Put "$work/claude/skills/needs-mcp/SKILL.md" 'Use server MCP `fixture-server` for search.'
    Put "$work/claude/skills/context-notes/SKILL.md" @'
---
name: context-notes
description: Minimal runtime documentation fixture.
---
System tools: install Node and ffmpeg.
Runtime enum: claude_code / codex / other. An Agent tool may dispatch work.
Use native audio or media-use; the standalone harness is optional.
```bash
# Usage note only: node absent.mjs; this example mentions the required Claude runtime.
```
'@
    Put "$work/claude/skills/context-notes/scripts/unused.mjs" "// Usage: node absent.mjs`nexport const unused = true;"
    Put "$work/claude/skills/context-notes/references/eval.md" @'
# Validation guide
## Per-fixture flow
```bash
# Lint a development fixture
node ../../fixture-only.mjs
```
'@
    Put "$work/claude/skills/context-notes/references/harness.md" 'This is an optional temporary workaround for standalone demos. Use HeyGen MCP `search_audio_sounds` tool only for this optional audio path.'
    Put "$work/claude/skills/resource-workflow/SKILL.md" @'
Run node <SKILL_DIR>/scripts/support.mjs
Run bash scripts/prepare.sh
Run bash prepare.sh
Run ../../scripts/prepare.sh
Resolve <MEDIA_DIR> as the installed media-use skill directory.
Run node <MEDIA_DIR>/scripts/helper.mjs
Run python skills/resource-sibling/scripts/helper.py
'@
    Put "$work/claude/skills/resource-workflow/references/planning.md" 'Run node scripts/support.mjs before accepting the plan.'
    Put "$work/claude/skills/resource-workflow/scripts/support.mjs" @'
// Usage: node support.mjs
import { local } from './lib/local.mjs';
import { sibling } from '../../resource-sibling/scripts/value.mjs';
console.log(local + ':' + sibling);
'@
    Put "$work/claude/skills/resource-workflow/scripts/lib/local.mjs" "export const local = 'module';"
    Put "$work/claude/skills/resource-workflow/scripts/prepare.sh" "#!/bin/sh`nexit 0"
    Put "$work/claude/skills/resource-sibling/SKILL.md" '# Supporting sibling'
    Put "$work/claude/skills/resource-sibling/scripts/value.mjs" "export const sibling = 'sibling-v1';"
    Put "$work/claude/skills/resource-sibling/scripts/helper.py" "print('fixture')"
    Put "$work/claude/skills/media-use/SKILL.md" 'Run node <MEDIA_DIR>/scripts/helper.mjs'
    Put "$work/claude/skills/media-use/scripts/helper.mjs" "console.log('media');"
    Put "$work/claude/skills/missing-resource/SKILL.md" 'Run node <SKILL_DIR>/scripts/not-installed.mjs'
    Put "$work/claude/skills/missing-sibling/SKILL.md" 'Run node skills/not-installed/scripts/helper.mjs'
    Put "$work/claude/skills/hard-runtime/SKILL.md" 'You must use the Bash tool supplied by Claude Code.'
    Put "$work/claude/skills/hard-mcp-tool/SKILL.md" 'You must invoke HeyGen MCP `search_audio_sounds` tool.'
    Put "$work/claude/skills/not-optional/SKILL.md" 'You must invoke HeyGen MCP `search_audio_sounds` tool; this is not optional.'
    Put "$work/claude/skills/hard-frontmatter/SKILL.md" "---`nname: hard-frontmatter`ntools: Bash`n---`nRequired tool metadata."
    Put "$work/claude/skills/illustrative/SKILL.md" '> Illustrative: `node <SKILL_DIR>/missing.mjs` — or use the installed media CLI after verifying it.'
    Put "$work/claude/skills/sentry-instrument/SKILL.md" '# Old Sentry'
    Put "$work/active/skills/example-reference/SKILL.md" '# Portable knowledge'
    Put "$work/claude/skills/hyperframes/SKILL.md" '# Authoritative video v2'
    Put "$work/codex/skills/hyperframes/SKILL.md" '# Drifted copy'
    Put "$work/agents/skills/hyperframes/SKILL.md" '# Drifted copy'
    Put "$work/codex/skills/user/SKILL.md" '# User'
    Put "$work/codex/skills/.system/skill-creator/SKILL.md" '# Native'
    New-Item -ItemType SymbolicLink -Path "$work/codex/skills/unknown" -Target "$work/active" | Out-Null
    Put "$work/claude/skills/unknown/SKILL.md" '# Conflicting'
    Put "$work/claude/skills/equal-link/SKILL.md" '# Already linked without ownership'
    New-Item -ItemType SymbolicLink -Path "$work/codex/skills/equal-link" -Target "$work/claude/skills/equal-link" | Out-Null
    New-Item -ItemType SymbolicLink -Path "$work/claude/skills/cycle" -Target "$work/claude/skills" | Out-Null
    $plan = Sync @('-DryRun','-PlanPath',"$work/plan.json",'-ActivePluginDirectory',"$work/active",'-AdoptSkill','hyperframes')
    Check (-not (Test-Path "$work/codex/skills/current")) 'dry run wrote links'
    Check ($plan -match 'unsupported' -and $plan -match 'provenance' -and $plan -match 'conflict') 'plan lacks portability/provenance/conflicts'
    Put "$work/claude/skills/resource-sibling/scripts/value.mjs" "export const sibling = 'sibling-v2';"
    $out = & pwsh -NoProfile -File $setup -SyncSkillsOnly -ApplyPlan "$work/plan.json" -CodexHome "$work/codex" -ClaudeHome "$work/claude" -AgentsSkills "$work/agents/skills" 2>&1 | Out-String
    Check ($LASTEXITCODE -ne 0 -and $out -match 'Before-state changed' -and -not (Test-Path "$work/codex/skills/current")) 'apply accepted a changed sibling resource'
    Put "$work/claude/skills/resource-sibling/scripts/value.mjs" "export const sibling = 'sibling-v1';"
    $legacyPlan=Get-Content -Raw "$work/plan.json" | ConvertFrom-Json -AsHashtable
    $legacyPlan.Remove('adapterVersion')
    Put "$work/legacy-plan.json" ($legacyPlan | ConvertTo-Json -Depth 12)
    $out = & pwsh -NoProfile -File $setup -SyncSkillsOnly -ApplyPlan "$work/legacy-plan.json" -CodexHome "$work/codex" -ClaudeHome "$work/claude" -AgentsSkills "$work/agents/skills" 2>&1 | Out-String
    Check ($LASTEXITCODE -ne 0 -and $out -match 'regenerate and review') 'old portability plan accepted without reclassification'
    Put "$work/agents/skills/hyperframes/edit.txt" 'concurrent'
    $out = & pwsh -NoProfile -File $setup -SyncSkillsOnly -ApplyPlan "$work/plan.json" -CodexHome "$work/codex" -ClaudeHome "$work/claude" -AgentsSkills "$work/agents/skills" 2>&1 | Out-String
    Check ($LASTEXITCODE -ne 0 -and (Test-Path "$work/agents/skills/hyperframes/edit.txt")) 'apply accepted changed adoption observation'
    Sync @('-DryRun','-PlanPath',"$work/plan.json",'-ActivePluginDirectory',"$work/active",'-AdoptSkill','hyperframes') | Out-Null
    Sync @('-ApplyPlan',"$work/plan.json") | Out-Null
    Check (Test-Path "$work/codex/skills/current/SKILL.md") 'current installed revision missing'
    Check (-not (Test-Path "$work/codex/skills/old")) 'stale checkout selected'
    Check (Test-Path "$work/codex/skills/nested/SKILL.md") 'nested synced skill missing'
    Check (Test-Path "$work/codex/skills/example-reference/SKILL.md") 'active directory omitted'
    Check (-not (Test-Path "$work/codex/skills/unsafe")) 'unsupported skill exposed'
    Check (-not (Test-Path "$work/codex/skills/relative-file")) 'cwd-relative script outside scripts/bin exposed'
    Check (-not (Test-Path "$work/codex/skills/needs-mcp")) 'unverified MCP assumed usable'
    Check (Test-Path "$work/codex/skills/context-notes/SKILL.md") 'prose, usage comments, evaluation examples or optional MCP tools rejected a portable workflow'
    Check (-not (Test-Path "$work/codex/skills/missing-resource")) 'missing placeholder resource accepted'
    Check (-not (Test-Path "$work/codex/skills/missing-sibling")) 'missing sibling resource accepted'
    Check (-not (Test-Path "$work/codex/skills/hard-runtime")) 'required Claude-only tool accepted'
    Check (-not (Test-Path "$work/codex/skills/hard-mcp-tool")) 'required unavailable MCP tool accepted'
    Check (-not (Test-Path "$work/codex/skills/not-optional")) 'explicitly mandatory MCP tool mistaken for an optional capability'
    Check (-not (Test-Path "$work/codex/skills/hard-frontmatter")) 'actual tool frontmatter accepted'
    Check ((Get-Content -Raw "$work/codex/skills/illustrative/SKILL.md") -match 'missing resource.*do not execute') 'missing illustrative resource was attested or lost its boundary'
    Check (Test-Path "$work/codex/skills/resource-workflow/SKILL.md") 'verified runtime resources were not projected'
    $resourceDescriptor = Get-Content -Raw "$work/codex/skills/resource-workflow/SKILL.md"
    $modulePath = [regex]::Match($resourceDescriptor, 'node "([^"]+/scripts/support.mjs)"').Groups[1].Value
    Push-Location ([IO.Path]::GetTempPath())
    try {
        $result = & node $modulePath
        Check ($LASTEXITCODE -eq 0 -and $result -eq 'module:sibling-v1') 'projected module/sibling imports failed from unrelated cwd'
    } finally { Pop-Location }
    Check ((Get-Content -Raw "$work/codex/skills/resource-workflow/references/planning.md") -match 'node "[^"]+/scripts/support.mjs"') 'nested runtime reference was not rooted'
    Check ($resourceDescriptor -match 'bash "[^"]+/scripts/prepare.sh"' -and $resourceDescriptor -notmatch '\.\./\.\./scripts/prepare.sh|bash prepare.sh') 'verified bare and fixture-relative resource paths were not rooted'
    Check ((Get-Content -Raw "$work/codex/skills/media-use/SKILL.md") -notmatch '<MEDIA_DIR>') 'self-referenced installed media root was not resolved'
    Check ((Get-Content -Raw "$work/codex/skills/resource-workflow/scripts/support.mjs") -match '// Usage: node support.mjs') 'script usage comment was rewritten'
    Check ((Get-Content -Raw "$work/codex/skills/context-notes/SKILL.md") -match 'optional|conditional') 'optional unavailable capability boundary was not stated'
    Check (-not (Test-Path "$work/codex/skills/sentry-instrument")) 'native Sentry shadowed'
    Check ((Get-Item "$work/codex/skills/unknown").ResolveLinkTarget($true).FullName -eq [IO.Path]::GetFullPath("$work/active")) 'unknown link replaced'
    $owned = Get-Content -Raw "$work/codex/skill-sync/owned.json" | ConvertFrom-Json
    Check (@($owned.entries | Where-Object { $_.path -like '*equal-link' }).Count -eq 0) 'same-target unknown link was silently claimed'
    Check (-not (Test-Path "$work/agents/skills/hyperframes")) 'duplicate descriptor remains'
    Check (@(Get-ChildItem "$work/codex/skill-sync/backups" -Recurse -Filter SKILL.md).Count -eq 2) 'both adoption backups missing'
    Push-Location ([IO.Path]::GetTempPath())
    try {
        $descriptor = Get-Content -Raw "$work/codex/skills/adapted/SKILL.md"
        $scriptPath = [regex]::Match($descriptor, '-File "([^"]+)"').Groups[1].Value
        $result = & pwsh -NoProfile -File $scriptPath
        Check ($LASTEXITCODE -eq 0 -and $result -eq 'support-v1') 'adapted support failed from unrelated cwd'
    } finally { Pop-Location }
    $before = (Get-Item "$work/codex/skills/adapted").Target
    $resourceBefore = (Get-Item "$work/codex/skills/resource-workflow").Target
    Sync @('-ActivePluginDirectory',"$work/active") | Out-Null
    Check ((Get-Item "$work/codex/skills/adapted").Target -eq $before) 'unchanged projection was rewritten'
    Check ((Get-Item "$work/codex/skills/resource-workflow").Target -eq $resourceBefore) 'unchanged sibling projection was rewritten'
    Put "$work/claude/skills/resource-sibling/scripts/value.mjs" "export const sibling = 'sibling-v2';"
    Sync | Out-Null
    $resourceAfter=(Get-Item "$work/codex/skills/resource-workflow").Target
    Push-Location ([IO.Path]::GetTempPath())
    try {
        $result = & node (Join-Path $resourceAfter 'scripts/support.mjs')
        Check ($LASTEXITCODE -eq 0 -and $result -eq 'module:sibling-v2' -and $resourceBefore -ne $resourceAfter) 'changed sibling failed to refresh projection/imports'
    } finally { Pop-Location }
    Put "$work/claude/skills/adapted/scripts/local.ps1" "Write-Output 'support-v2'"
    Sync @('-ActivePluginDirectory',"$work/active") | Out-Null
    Check ((Get-Content -Raw "$work/codex/skills/adapted/scripts/local.ps1") -match 'support-v2') 'projection not refreshed'
    Put (Join-Path $before 'scripts/local.ps1') "Write-Output 'edited old projection'"
    Put "$work/claude/skills/adapted/scripts/local.ps1" "Write-Output 'support-v1'"
    $refresh = Sync
    Check ($refresh -match 'edited projection' -and (Get-Content -Raw "$work/codex/skills/adapted/scripts/local.ps1") -match 'support-v2') 'refresh exposed an edited older projection'
    Put "$work/claude/skills/adapted/scripts/local.ps1" "Write-Output 'support-v2'"
    Put "$work/cache-v3/skills/current/SKILL.md" '# Current v3'
    Put "$work/claude/plugins/installed_plugins.json" (@{plugins=@{'demo@test'=@(@{scope='user';installPath="$work/cache-v3"})}} | ConvertTo-Json -Depth 8)
    Sync @('-VerifiedMcpServer','fixture-server') | Out-Null
    Check ((Get-Content -Raw "$work/codex/skills/current/SKILL.md") -match 'Current v3') 'installed revision not refreshed'
    Check (Test-Path "$work/codex/skills/needs-mcp/SKILL.md") 'explicitly verified MCP skill not exposed'
    Sync | Out-Null
    Check (Test-Path "$work/codex/skills/needs-mcp/SKILL.md") 'verified MCP support not retained on refresh'
    Put "$work/claude/settings.json" '{"enabledPlugins":{"demo@test":false}}'
    Sync | Out-Null
    Check (-not (Test-Path "$work/codex/skills/current")) 'disabled plugin retained owned descriptor'
    Check (Test-Path "$work/cache-v3/skills/current/SKILL.md") 'retirement deleted source'
    Put "$work/codex/skills/adapted/scripts/local.ps1" "Write-Output 'user edit'"
    Put "$work/claude/skills/adapted/scripts/local.ps1" "Write-Output 'source-v3'"
    $refresh = Sync
    Check ($refresh -match 'edited projection' -and (Get-Content -Raw "$work/codex/skills/adapted/scripts/local.ps1") -match 'user edit') 'refresh lost concurrent projection edit'
    $resourceLayout=Split-Path $resourceAfter
    Put (Join-Path $resourceLayout 'user.txt') 'concurrent layout edit'
    $refresh=Sync
    Check ($refresh -match 'edited projection' -and (Test-Path (Join-Path $resourceLayout 'user.txt'))) 'refresh overwrote a concurrent sibling-layout edit'
    Put "$work/codex/skills/hyperframes/concurrent.md" 'source edit through link'
    Sync @('-Rollback') | Out-Null
    Check ((Test-Path "$work/codex/skills/resource-workflow") -and (Test-Path (Join-Path $resourceLayout 'user.txt'))) 'rollback overwrote a concurrent sibling-layout edit'
    Check ((Get-Content -Raw "$work/codex/skills/hyperframes/concurrent.md") -eq 'source edit through link') 'rollback lost concurrent edit'
    Check (Test-Path "$work/codex/skills/user/SKILL.md") 'unrelated directory lost'
    Check (Test-Path "$work/codex/skills/.system/skill-creator/SKILL.md") 'system skill lost'
    $bulk = "$work/bulk"
    $policy = Get-Content -Raw (Join-Path $repo 'plugins/pipeline/skills/pipeline/config/skill-sync-policy.json') | ConvertFrom-Json
    $index = 0
    foreach ($name in $policy.adoptable) {
        $index++
        $old = if ($index -le 16) { '# Old mirrored drift' } else { '# Current' }
        Put "$bulk/claude/skills/$name/SKILL.md" '# Current'
        Put "$bulk/codex/skills/$name/SKILL.md" $old
        Put "$bulk/agents/skills/$name/SKILL.md" $old
    }
    & $setup -SyncSkillsOnly -CodexHome "$bulk/codex" -ClaudeHome "$bulk/claude" -AgentsSkills "$bulk/agents/skills" -AdoptSkill $policy.adoptable | Out-Null
    Check (@(Get-ChildItem "$bulk/codex/skill-sync/backups" -Recurse -Filter SKILL.md).Count -eq 42) '21-pair backups incomplete'
    Check (@(Get-ChildItem "$bulk/codex/skills" -Directory | Where-Object LinkType).Count -eq 21) 'canonical 21 adoption links missing'
    Check (@(Get-ChildItem "$bulk/agents/skills" -Directory).Count -eq 0) 'adoption left duplicate descriptors'
    & $setup -SyncSkillsOnly -CodexHome "$bulk/codex" -ClaudeHome "$bulk/claude" -AgentsSkills "$bulk/agents/skills" -Rollback | Out-Null
    Put "$bulk/claude/settings.json" '{"enabledPlugins":{"missing@test":true}}'
    Put "$bulk/claude/plugins/installed_plugins.json" '{"plugins":{}}'
    & $setup -SyncSkillsOnly -CodexHome "$bulk/codex" -ClaudeHome "$bulk/claude" -AgentsSkills "$bulk/agents/skills" -DryRun | Out-Null
    Check ($?) 'missing current plugin record failed discovery'
    Check (@(Get-ChildItem "$bulk/agents/skills" -Directory).Count -eq 21) 'rollback did not restore 21 Agents originals'
    Check (@(Get-ChildItem "$bulk/codex/skills" -Directory | Where-Object { -not $_.LinkType }).Count -eq 21) 'rollback did not restore 21 Codex originals'
    Check (@(Get-ChildItem "$bulk/codex/skills" -Filter SKILL.md -Recurse | Where-Object { (Get-Content -Raw $_.FullName) -eq '# Old mirrored drift' }).Count -eq 16) 'rollback lost original 16 drifts'
    & $setup -SyncSkillsOnly -CodexHome "$bulk/codex" -ClaudeHome "$bulk/claude" -AgentsSkills "$bulk/agents/skills" -Rollback | Out-Null
    Write-Output "skill sync: PASS ($checks checks)"
} finally {
    if ([IO.Path]::GetFullPath($work).StartsWith([IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $work -Recurse -Force }
}
