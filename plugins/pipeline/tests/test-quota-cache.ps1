$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\skills\pipeline\bin\RunCommon.ps1')
$work = Join-Path $PSScriptRoot '..\..\..\.pipeline-logs\fixtures\quota-cache'
New-Item -ItemType Directory -Force -Path $work | Out-Null
$assertions = 0
function Assert-True([bool]$Condition, [string]$Message) {
    $script:assertions++
    if (-not $Condition) { throw $Message }
}
function codeburn.cmd { }
$script:refreshes = 0
function Invoke-QuotaReading([int]$TimeoutSeconds) {
    $script:refreshes++
    return [pscustomobject]@{ providers = @([pscustomobject]@{ id = 'claude'; available = $true; windows = @([pscustomobject]@{ label = 'Weekly'; usedPct = 0; resetsAt = [datetimeoffset]::UtcNow.AddDays(7).ToString('o') }) }) }
}
foreach ($reset in @([datetimeoffset]::UtcNow.AddSeconds(-1).ToString('o'), [datetimeoffset]::UtcNow.AddMinutes(-1).ToOffset([timespan]::FromHours(2)).ToString('o'), [datetimeoffset]::UtcNow.AddDays(1).ToString('o'), 'unknown', $null)) {
    $before = $script:refreshes
    $parsed = [datetimeoffset]::MinValue
    $expired = [datetimeoffset]::TryParse($reset, [ref]$parsed) -and $parsed -le [datetimeoffset]::UtcNow
    @{ fetchedAtUtc = [datetime]::UtcNow.AddSeconds(-105).ToString('o'); quota = @{ providers = @(@{ id = 'claude'; available = $true; windows = @(@{ label = 'Weekly'; usedPct = 95; resetsAt = $reset }) }) } } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $work 'last-good.json') -Encoding utf8
    $cachedOnly = Test-QuotaGate 'claude' 85 1 'claude-opus-5-5' $work 600 -CacheOnly
    Assert-True (($cachedOnly -like 'skipped:*') -eq $expired) 'cache-only must reject elapsed reset windows only'
    Assert-True ($script:refreshes -eq $before) 'cache-only must not refresh'
    $result = Test-QuotaGate 'claude' 85 1 'claude-opus-5-5' $work 600
    if ($expired) {
        Assert-True ($result -like 'claude 0%*fresh*' -and $script:refreshes -eq $before + 1) "elapsed reset must refresh and pass: $result"
    } else {
        Assert-True ($result -like 'quota gate: claude Weekly at 95%*cached*' -and $script:refreshes -eq $before) "usable cache must retain its cap: $result"
    }
}
Write-Output "quota cache tests: PASS ($assertions assertions)"
