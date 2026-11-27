#requires -Version 7.0
<#
Offline regression for new-brief.ps1: a gh issue body with non-ASCII text must reach
brief.md byte-exact as UTF-8. `gh` is a fake .cmd that emits UTF-8 bytes, as the real one does.
#>
$ErrorActionPreference = 'Stop'
$newBrief = Join-Path $PSScriptRoot '..\bin\new-brief.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) ('nb-utf8-' + [guid]::NewGuid().ToString('N'))
$utf8 = [Text.UTF8Encoding]::new($false)
New-Item -ItemType Directory -Force -Path "$root\bin", "$root\home\config", "$root\run", "$root\repo\.git\objects", "$root\repo\.git\refs\heads" | Out-Null
try {
    # Hand-built repository skeleton: HEAD plus an origin remote, no git command needed.
    [IO.File]::WriteAllText("$root\repo\.git\HEAD", "ref: refs/heads/main`n", $utf8)
    [IO.File]::WriteAllText("$root\repo\.git\config", "[core]`n`trepositoryformatversion = 0`n[remote `"origin`"]`n`turl = https://github.com/fixture/sample.git`n", $utf8)
    $json = [ordered]@{ number = 57; title = 'Requests no longer time out'; body = '- [ ] café — ready'; url = 'https://github.com/fixture/sample/issues/57' } | ConvertTo-Json -Compress
    [IO.File]::WriteAllText("$root\issue.json", $json, $utf8)
    Set-Content -LiteralPath "$root\bin\gh.cmd" -Encoding ascii -Value @(
        '@echo off', 'if "%1"=="auth" (echo tok& exit /b 0)', "type `"$root\issue.json`"")
    $oldPath = $env:PATH; $oldHome = $env:PIPELINE_HOME
    $env:PATH = "$root\bin;$oldPath"; $env:PIPELINE_HOME = "$root\home"
    try {
        $out = & pwsh -NoProfile -File $newBrief -Repo "$root\repo" -Topic t -Risk LOW -Issue 57 -RunDir "$root\run" 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) { throw "new-brief failed: $out" }
    }
    finally { $env:PATH = $oldPath; $env:PIPELINE_HOME = $oldHome }
    $brief = [IO.File]::ReadAllText("$root\run\brief.md", $utf8)
    $expected = '- café — ready'
    if (-not $brief.Contains($expected)) { throw "brief.md lacks the UTF-8 acceptance line '$expected'" }
    Write-Output 'PASS new-brief UTF-8 issue body'
}
finally { Remove-Item -Recurse -Force -LiteralPath $root -ErrorAction SilentlyContinue }
