$ErrorActionPreference='Stop'
$checks=0
function Check($Value,$Label) { $script:checks++; if(-not $Value){throw $Label} }
$names=@('CC_NOTIFY_RING','CC_NOTIFY_TOAST','CC_NOTIFY_KIND','CC_NOTIFY_TITLE','CC_NOTIFY_TEXT','CC_NOTIFY_FOLDER','CC_NOTIFY_SOUND','CC_NOTIFY_AUMID','CC_NOTIFY_GROUP','CC_NOTIFY_APP','CC_NOTIFY_CACHE','CC_NOTIFY_OWNER_PID','CC_NOTIFY_OWNER_START')
$previous=@{}; foreach($name in $names){$previous[$name]=[Environment]::GetEnvironmentVariable($name);[Environment]::SetEnvironmentVariable($name,$null)}
try {
    . (Join-Path $PSScriptRoot '../scripts/notify.ps1')
    Check ($Aumid -eq 'ClaudeCode.TurnNotify' -and $Group -eq 'claude-code' -and $AppName -eq 'Claude Code') 'Claude defaults changed'
    $env:CC_NOTIFY_KIND='permission';$env:CC_NOTIFY_TITLE='Approval <&"';$env:CC_NOTIFY_TEXT='Text <&';$env:CC_NOTIFY_FOLDER='Folder & <';$env:CC_NOTIFY_SOUND='0'
    [xml]$xml=Get-ToastXml 'Session <&'
    Check ($xml.toast.visual.binding.text[0].'#text' -eq 'Approval <&"') 'title XML escaping failed'
    Check ($xml.SelectSingleNode('/toast/visual/binding/text[2]').InnerText -eq 'Text <&') 'body XML escaping failed'
    Check ($xml.toast.audio.silent -eq 'true') 'mute ignored'
    Check ($xml.toast.duration -eq 'long') 'approval duration changed'
    $env:CC_NOTIFY_SOUND='1';[xml]$xml=Get-ToastXml ''
    Check ($xml.toast.audio.src -match 'Notification.Reminder') 'approval sound missing'
    $env:CC_NOTIFY_KIND='done';[xml]$xml=Get-ToastXml ''
    Check ($xml.toast.audio.src -match 'Notification.Default') 'completion sound missing'
    $Assets='C:\Fixture & Space\assets';[xml]$xml=Get-ToastXml ''
    Check ($xml.toast.visual.binding.image.src -match 'Fixture.*&') 'asset URI XML escaping failed'
    $env:CC_NOTIFY_OWNER_PID=[string]$PID;$env:CC_NOTIFY_OWNER_START=(Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o')
    Check ((Get-NotifySession) -eq $PID) 'exact owner rejected'
    $env:CC_NOTIFY_OWNER_START='2000-01-01T00:00:00Z'
    Check ((Get-NotifySession) -eq 0) 'reused PID accepted'
    $env:CC_NOTIFY_AUMID='Codex.Cockpit';$env:CC_NOTIFY_GROUP='codex-cockpit';$env:CC_NOTIFY_APP='Codex';$env:CC_NOTIFY_CACHE=Join-Path ([IO.Path]::GetTempPath()) 'fixture-not-created'
    . (Join-Path $PSScriptRoot '../scripts/notify.ps1')
    Check ($Aumid -eq 'Codex.Cockpit' -and $Group -eq 'codex-cockpit' -and $AppName -eq 'Codex') 'Codex identity ignored'
    Write-Output "notification bridge: PASS ($checks checks; no desktop actions)"
} finally { foreach($name in $names){[Environment]::SetEnvironmentVariable($name,$previous[$name])} }
