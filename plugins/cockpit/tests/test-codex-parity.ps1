[CmdletBinding()]
param([string]$LogDirectory = (Join-Path ([IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))) ('.pipeline-logs/codex-parity/' + [guid]::NewGuid().ToString('N'))))
$ErrorActionPreference='Stop'
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
[IO.Directory]::CreateDirectory($LogDirectory) | Out-Null
$steps=0
function Gate([string]$Name,[string]$Exe,[string[]]$Arguments) {
    $log=Join-Path $LogDirectory "$Name.log"
    & $Exe @Arguments *> $log
    $result=$LASTEXITCODE
    $tail=Get-Content -LiteralPath $log -Tail 12 | Out-String
    $content=Get-Content -Raw -LiteralPath $log
    if($result -ne 0){throw "$Name exit=$result log=$log`n$tail"}
    if($content -match '(?im)^# skipped [1-9]|\b[1-9][0-9]* (?:skip|skipped|todo)\b'){throw "$Name reported skipped tests: $log"}
    $counts=@([regex]::Matches($content,'(?im)^# (?:tests|pass|fail|skipped) \d+|\d+ pass|PASS \(\d+ (?:checks|assertions)|\d+ checks passed') | ForEach-Object Value) -join '; '
    Write-Output "$Name exit=0 $counts log=$log"
    $script:steps++
}
Push-Location $repo
try {
    Gate 'skill-sync' 'pwsh' @('-NoProfile','-File','plugins/cockpit/tests/skill-sync.test.ps1')
    Gate 'codex-runtime' 'node' @('--test','--test-reporter=tap','plugins/cockpit/tests/codex-hook.test.mjs','plugins/cockpit/tests/codex-dashboard.test.mjs','plugins/cockpit/tests/codex-native-skills.test.mjs')
    Gate 'codex-setup' 'pwsh' @('-NoProfile','-File','plugins/cockpit/tests/codex-setup.test.ps1')
    Gate 'notification-bridge' 'pwsh' @('-NoProfile','-File','plugins/cockpit/tests/notify.test.ps1')
    Gate 'agent-setup' 'pwsh' @('-NoProfile','-File','plugins/pipeline/tests/test-agent-setup.ps1')
    Gate 'cockpit-paths' 'pwsh' @('-NoProfile','-File','plugins/cockpit/tests/pipeline-paths.test.ps1')
    Gate 'claude-cockpit' 'claude' @('plugin','test','./plugins/cockpit')
    Gate 'marketplace' 'claude' @('plugin','validate','.')
    Gate 'cockpit-validation' 'claude' @('plugin','validate','./plugins/cockpit')
    Gate 'pipeline-validation' 'claude' @('plugin','validate','./plugins/pipeline')
    Write-Output "Codex parity gate: PASS ($steps steps; no skipped-test success). Logs: $LogDirectory"
} finally { Pop-Location }
