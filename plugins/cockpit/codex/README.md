# Codex companion on Windows

Codex keeps its native session display. The companion is a separate Windows Terminal tab for pipeline runs, PR/CI verdicts, runners and quota readings. It contains no model calls, transcript reader, approval decisions or GitHub writes. Claude's existing Mod and notification defaults continue to work.

Requirements: Windows, PowerShell 7, Windows PowerShell, Node 24 with native TypeScript support, and Codex with documented command hooks. `wt.exe` plus a Windows Terminal host (`WT_SESSION`) enables automatic opening. `gh` is optional for live PR/runner reads. Missing Terminal leaves the native CLI available. Tests use fixture homes, synthetic hook events and a local Codex app-server that only lists skills/hooks; no model, authentication changes, GitHub queries or desktop notifications run in tests.

## Install and review

Run these commands from a reviewed checkout after the launcher integration gate passes. Set `PIPELINE_HOME` to the existing user state root before installation if it is not already set. No machine paths belong in this repository.

```powershell
$Repo = (Resolve-Path '.').Path
$CodexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
$ClaudeHome = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $HOME '.claude' }
$AgentsSkills = Join-Path $HOME '.agents/skills'
$PipelineHome = if ($env:PIPELINE_HOME) { $env:PIPELINE_HOME } else { Join-Path $HOME '.pipeline' }
$PipelineSkill = Join-Path $Repo 'plugins/pipeline/skills/pipeline'
$Sync = Join-Path $PipelineSkill 'bin/setup-codex-home.ps1'
$Plan = Join-Path $PipelineHome 'cockpit/skill-plan.json'
New-Item -ItemType Directory -Force -Path (Split-Path $Plan) | Out-Null
$Adopt = (Get-Content -Raw (Join-Path $PipelineSkill 'config/skill-sync-policy.json') | ConvertFrom-Json).adoptable
$Active = @((Join-Path $Repo 'plugins/pipeline'))
& $Sync -SyncSkillsOnly -CodexHome $CodexHome -ClaudeHome $ClaudeHome -AgentsSkills $AgentsSkills -ActivePluginDirectory $Active -AdoptSkill $Adopt -DryRun -PlanPath $Plan
Get-Content -Raw $Plan | ConvertFrom-Json | Select-Object -ExpandProperty entries | Format-Table name,action,provenance,portability,path
```

Review both the printed unsupported/conflict dispositions and plan entries. The 21-name adoption list is explicit authorization for those mirrored copies only; requesting it never adopts other links or folders. Both originals are moved to `CodexHome/skill-sync/backups/<transaction>/{codex,agents}/<name>` before replacement descriptors are exposed. Every observed tree and source is checked again at apply; a changed observation stops apply. Backups and generated projections are outside skill discovery. Do not move these directories into a `skills` root.

```powershell
& $Sync -SyncSkillsOnly -CodexHome $CodexHome -ClaudeHome $ClaudeHome -AgentsSkills $AgentsSkills -ApplyPlan $Plan
& (Join-Path $Repo 'plugins/cockpit/codex/setup.ps1') -CodexHome $CodexHome -ClaudeHome $ClaudeHome -AgentsSkills $AgentsSkills -PipelineHome $PipelineHome -PipelineSkill $PipelineSkill -ProfilePath $PROFILE.CurrentUserAllHosts
```

The installer copies all runtime helpers, shared readers, assets and the sync owner dependencies to `CodexHome/cockpit`. It backs up hooks, the selected profile and its own install record under `cockpit/backups`. It adds an owned profile block only when `ProfilePath` is explicitly supplied. It never edits `config.toml`, top-level `notify`, MCP/auth settings, Terminal settings, model/effort, global instructions or context/compaction overrides. New or edited deployed files and edited owned hook/profile definitions cause conflicts rather than being overwritten.

Open a fresh PowerShell. In Codex, use **`/hooks` to review and trust each exact command definition**. The installer does not create trust or enable a bypass. Native fixtures verify eight supported hooks load without configuration warnings and remain untrusted. Hooks must be enabled by the existing Codex configuration; administrative restrictions still apply.

The managed `codex` function resolves `codex.exe`, avoiding recursion. Only terminal-interactive openings refresh skills and attempt a companion. Headless commands (`exec`, `resume exec`, `features`, `mcp`, `review`, help and the other management commands), pipelines and redirected input/output forward arguments and exit status without a refresh or dashboard; they clear inherited companion scope for the child. Direct `codex.exe` calls remain available. The wrapper honors `-C`/`--cd` for the selector and dashboard account root.

The optional skill selector reads `.claude/harness-scope.json` from the checkout, for example `{"profile":"code"}`. Use `code` or `video` and put the corresponding profile under `<ClaudeHome>/harness-scope/profiles/`. The profile accepts `{"skills":{"deny":["example-*"]}}` or an `allow` list in place of `deny`.

## Skill refresh and portability

The existing pipeline sync owner discovers enabled user plugins at their current `installed_plugins.json` install paths, explicitly configured active plugin directories, local skills and nested synced buckets. It never updates sources or uses a stale marketplace checkout instead of the installed revision. Active directory choices and explicitly verified MCP names are retained in the ownership ledger for later refreshes.

Plans print **provenance** independently from **portability**. Portable whole directories are linked, including supporting files. Runtime Markdown commands receive absolute installed resource paths only after the referenced file is found: `${CLAUDE_SKILL_DIR}`, `<SKILL_DIR>`, `<MEDIA_DIR>`, bundled `scripts/` paths and installed sibling `skills/<name>/` paths are supported. Bare script names and fixture-relative `../scripts/` paths resolve only to existing bundled scripts. Missing runtime resources remain unsupported. Frontmatter requirements and actual Claude runtime/tool dependencies are checked separately from generic prose, support-script usage comments and development evaluation sections. Explicitly illustrative missing commands stay documented as unavailable; optional MCP paths receive a conditional prerequisite note and are never attested as available.

Adapted skills receive a brief portability preamble and a whole supporting-tree projection outside discovery. Sibling resource links preserve ordinary module-relative imports without rewriting source logic. Source and sibling observations select the projection revision; refresh and apply recheck both, and rollback also checks the surrounding sibling layout for concurrent edits. Regenerate plans produced by the earlier adapter before applying them. Fixtures execute PowerShell and JavaScript support files from an unrelated cwd, including local and sibling module imports. Linked supporting trees, discovery cycles, required unverified MCP servers and unresolved runtime paths remain unsupported. Classification does not establish external executable, platform, provider, service or credential health; inspect those prerequisites before use. Opaque command construction still requires review.

Unknown links, real directories and duplicate descriptors are conflicts. They are preserved, including existing same-target links whose ownership was never recorded. The 21 mirrored video names can be selected for initial adoption with backups; unsupported sources are reported and not newly offered. `.system`, official/newer native equivalents (including Sentry), deliberate exclusions and unrelated skills remain protected. Existing links are not silently claimed as owned. Refresh retires only owned descriptors whose source disappears or becomes unsupported. Source contents are never removed. Edited projections or links remain conflicts. Rollback restores originals only if owned after-state, target content and backup still match; concurrent edits stay in place and are reported.

```powershell
$DeployedSync = Join-Path $CodexHome 'cockpit/pipeline/bin/setup-codex-home.ps1'
& $DeployedSync -SyncSkillsOnly -CodexHome $CodexHome -ClaudeHome $ClaudeHome -AgentsSkills $AgentsSkills -DryRun
# After reviewing dispositions, refresh only owned entries:
& $DeployedSync -SyncSkillsOnly -CodexHome $CodexHome -ClaudeHome $ClaudeHome -AgentsSkills $AgentsSkills
```

If you need an MCP server for a skill, use the native selective external-agent import flow for the reviewed MCP server configuration. Do not import sessions, memory, global instructions or the entire configuration. Keep credentials in user configuration. Check `/mcp` and exercise a safe read tool for each imported server; configuration presence alone does not establish health. After verifying Codex compatibility, explicitly attest the relevant names when planning a refresh, for example `-VerifiedMcpServer @('example-docs')`. This is a reviewer attestation, not an automatic health check. The adapter does not run server-specific indexing or startup updates.

## Dashboard and hooks

```powershell
# Deterministic read-only snapshot; also the fallback without Windows Terminal:
node (Join-Path $CodexHome 'cockpit/deploy/codex/dashboard.mjs') --once --offline --pipeline-home $PipelineHome --width 100
```

`--once` always implies offline. It reads bounded run metadata/report/progress/gate/task-usage artifacts, recorded lock identities and the existing quota cache; it starts no external process or network poll. Offline owner liveness remains unknown. Missing/malformed data is unknown, old gates/reports are excluded, live-mode dead or mismatched lock owners are unknown/abandoned, and historical data carries age. Run outcomes reuse Claude's pure outcome reader, including missing report, timeout, gate failure/retry, quota refusal and preflight distinctions. Stop alone means a stopped turn, not pipeline success. The dashboard does not read launcher transcripts or logs.

Live rendering refreshes about every three seconds. PRs poll at most every five minutes, runners at most every minute, without overlap. Account selection uses the longest path-prefix boundary in the user registry. Account-specific token failure preserves the last reading and never switches account. Runner repositories honor `cockpitRunnerRoot` and deduplicate slugs. Credentials stay transient; stderr, token responses, PR titles and command bodies are not persisted. Live readings do not overwrite the Codeburn quota cache. Quota is stale at 600 seconds, on reset or when unavailable. No Codeburn refresh is started by the companion.

Hook input uses documented `session_id`, `cwd`, `model`, event/status and numeric request usage fields only. The adapter ignores prompts, tool inputs, error text, assistant messages and transcript paths. Every command returns neutral `{}` on stdout, including Stop and malformed input. Events: `SessionStart`, `UserPromptSubmit`, `PermissionRequest`, `PostToolUse`, `PostModelRequest`, `Stop`, `Interrupt`, `SessionEnd`. It never returns permission decisions or tool output replacements.

The hook queues state; the companion serializes Windows delivery. Approval waits deduplicate for 20 seconds and clear on new input/resolved tool use. Superseded generations cannot deliver late notifications. Stopped turns show a green ring, with a toast after two minutes; model failures show red, interruption clears the ring and replaces any wait toast, and session end clears owned signals. Completion text says stopped rather than asserting success. Set `CODEX_COCKPIT_MUTE=1` to mute companion sounds. Each scope has a separate session directory, notification tag and companion ownership record. PID plus process start time prevents attaching to a recycled PID. Closing Codex closes its scope; the companion aborts pending reads and clears its signals. Closing the companion stops its polling and delivery while Codex continues. A later startup clears stale owned notifications; it never removes pipeline runs or locks.

The native statusline remains the source for session context/input/output/5h/week. The dashboard may show timestamped **last-request** token usage when hooks provide it; it does not infer total context, cache TTL, a thread ID, exact context breakdown or model entitlement. No app-server observer is enabled because current-session mapping has not been proven. Existing context settings remain in force. API model maxima do not establish the local runtime limit.

## Active Mod parity

| Source | Codex behavior | Remaining boundary |
| --- | --- | --- |
| cockpit | Native statusline + companion; shared run/account/PR readers; Windows assets/sender | No embedded Claude UI, cache warm-up or transcript-derived counters; pipeline runs are displayed globally, without guessed session attribution |
| pipeline | Existing Codex launcher/skill/setup owner; no provider or launcher policy edits | Executor selection and final gate remain reviewer/orchestrator responsibilities |
| External skills and MCP servers | Configured active-directory discovery and explicit MCP compatibility attestation | Selective MCP import/health check and indexing setup remain reviewer work; no automatic startup update |
| gh-guard | Dashboard makes read-only calls with registry account boundaries | No native tool-blocking guard or auth switching is installed |
| Skill scope selector | Current `code`/`video` selector translates skill patterns to proven native exact `SKILL.md` paths, including linked skills | No selector leaves discovery unchanged; unreadable/unknown selector passes through. Existing native skills configuration wins; attachment/tool/instruction interception and all Claude scope categories are unsupported |
| Read discipline | Existing instruction-based read economy | No structured shell Read mapping; no shell-text rejection |
| Tool output | Existing native output limits and pipeline logs | No PostToolUse result replacement or rejected code-mode promises |
| Context view | Native context display and timestamped request usage | No exact per-file/tool breakdown or cache TTL |
| deep-research / LSP | Explicit capability gaps | Source presence is not proof of a native workflow/tool |

## Verification and rollback

Run the integration gate from the repository root.

```powershell
pwsh -NoProfile -File plugins/cockpit/tests/test-codex-parity.ps1 -LogDirectory '<run logs>/integration'
```

It runs all focused suites, existing setup callers, Claude Cockpit tests/path fixtures and root/affected-plugin validation. A missing command, failure or skipped-test report fails the gate. Reviewer live smoke: trust hooks, launch `codex` in Windows Terminal, verify one approval/new-input/stopped/error/interrupt lifecycle, then exit and verify companion cleanup. Verify headless `codex features list` retains its exit and opens no tab. Exercise safe MCP reads and read-only PR/runner/quota views separately; fixture success does not establish live service health. Desktop auto-open and exact thread/rate-limit observer attachment remain unproven.

Close wrapper-launched sessions first so their companions clear notifications. Roll skills back **before** uninstall removes the deployed sync helper:

```powershell
& $DeployedSync -SyncSkillsOnly -CodexHome $CodexHome -ClaudeHome $ClaudeHome -AgentsSkills $AgentsSkills -Rollback -DryRun
& $DeployedSync -SyncSkillsOnly -CodexHome $CodexHome -ClaudeHome $ClaudeHome -AgentsSkills $AgentsSkills -Rollback
& (Join-Path $CodexHome 'cockpit/deploy/codex/setup.ps1') -CodexHome $CodexHome -ProfilePath $PROFILE.CurrentUserAllHosts -Uninstall
```

Rollback conflicts require review; do not restore a whole backup over concurrent user changes. Uninstall removes exact owned hook groups, the exact profile block and unchanged deployed files, preserving unrelated content and edited files. Backups, skill projections/state and the Windows notification identity/cache remain outside discovery for recovery; no auth/config/source directories are deleted. Start a fresh PowerShell after uninstall (or use `codex.exe`) and verify the original native notify/statusline remain. Windows may retain the separate `Codex.Cockpit` notification identity/history until cleared in Windows notification settings.
