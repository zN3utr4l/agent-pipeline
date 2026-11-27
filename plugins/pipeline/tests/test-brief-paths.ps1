$ErrorActionPreference = 'Stop'
$skillRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\skills\pipeline')).Path
$failures = [Collections.Generic.List[string]]::new()
$assertions = 0
$hint = ' (a file created after launch belongs in the run directory or the repository)'
function Assert-True([bool]$Condition, [string]$Message) {
    $script:assertions++
    if (-not $Condition) { $failures.Add($Message) }
}

$work = Join-Path ([IO.Path]::GetTempPath()) ('.test-brief-paths-' + [guid]::NewGuid())
$hubRoot = Join-Path $work 'hub'
$repo = Join-Path $work 'target repo'
$run = Join-Path $hubRoot 'runs\target\recorded'
$brief = Join-Path $work 'brief.md'
$session = [guid]::NewGuid().ToString()
$originalPath = $env:PATH
$originalHome = $env:PIPELINE_HOME
$originalCodexHome = $env:CODEX_HOME
try {
    New-Item -ItemType Directory -Force -Path $repo, $run, (Join-Path $work 'bin'), (Join-Path $work 'codex-home') | Out-Null
    Set-Content -LiteralPath (Join-Path $work 'bin\codex.cmd') -Value "@echo off`nexit /b 52" -Encoding ascii
    $env:PATH = (Join-Path $work 'bin') + ';' + $originalPath
    $env:PIPELINE_HOME = $hubRoot
    $env:CODEX_HOME = Join-Path $work 'codex-home'
    @{ sessionId = $session; model = 'gpt-6.2-sol'; reasoningEffort = 'high' } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $run 'meta.json')
    @{ num_turns = 1; usage = @{ cache_read_input_tokens = 1000 } } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $run 'result.json')
    $existing = Join-Path $work 'external inputs\map.md'
    New-Item -ItemType Directory -Force -Path (Split-Path $existing) | Out-Null
    Set-Content -LiteralPath $existing -Value '# Migration map'
    $missing = @((Join-Path $work 'removed worktree\map.md'), (Join-Path $work 'removed\map-two.md'), (Join-Path $work 'removed inputs\map-three.md'))
    $siblings = @("$repo-gone\map.md", "$hubRoot-gone\map.md", "$repo\..\escaped\map.md")
    $listMissing = @((Join-Path $work 'list-missing-one.md'), (Join-Path $work 'list-missing-two.md'))
    $citationForms = [ordered]@{
        placeholder = '`C:\Example\Checkouts\<repo>`'
        globs = '`D:\x\lib\*.dart` `D:\x\Replay*.cs` `D:\x\screens-{1,2,3}.log` `D:\x\file?.cs` `D:\x\file[12].cs`'
        elisions = '`D:\...\claude-run.ps1` `D:\…\claude-run.ps1` `C:/…`'
        regex = '`[A-Za-z]:[\\/]`'
        'Docker mount' = '`-v ' + $hubRoot + ':/src:ro`'
        'quoted lists' = '"' + $work + ',' + $hubRoot + '" and "' + $work + ';' + $hubRoot + '"'
        'network paths' = '`\\server` `\\unreachable.invalid\share\map.md` \\unreachable.invalid\share\other.md'
        'quoted command' = '`git -C ' + $work + ' show v1`'
        'path-led command' = '`' + (Join-Path $work 'bin\codex.cmd') + ' --flag value`'
        'spaced path-led command' = '`' + $existing + ' --flag value`'
        'shell-quoted commands' = '`"' + $existing + '" --check` `& ''' + $existing + ''' --check` `pwsh -File "' + $existing + '" -Repo x`'
        apostrophes = "l'input ``" + $existing + "`` e l'altro"
    }
    foreach ($provider in @('codex', 'claude')) {
        foreach ($resume in @($false, $true)) {
            $arguments = @('-Repo', $repo, '-Brief', $brief, '-RunDir', $run, '-GateCommand', 'none', '-SkipQuotaCheck', '-DryRun')
            if ($resume) { $arguments += @('-Resume', $session, '-FixLoop', '1') }
            # Claude's recorded identity differs from Codex's, but both use this run.
            $model = if ($provider -eq 'codex') { 'gpt-6.2-sol' } else { 'claude-opus-5-5' }
            @{ sessionId = $session; model = $model; reasoningEffort = 'high'; effort = 'high' } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $run 'meta.json')
            foreach ($case in @('missing external paths', 'repo and hub outputs', 'existing external path', 'sibling and escaped paths')) {
                $body = switch ($case) {
                    'missing external paths' { 'Read `' + $missing[0] + '` and ' + $missing[1] + ", then '" + $missing[2] + "'." }
                    'repo and hub outputs' { 'Write `' + (Join-Path $repo 'outputs\future.md') + '` and "' + (Join-Path $hubRoot 'runs\future\report.md').Replace('\', '/') + '".' }
                    'existing external path' { 'Read "' + $existing + '" and `' + $existing + ':12`.' }
                    'sibling and escaped paths' { ($siblings | ForEach-Object { '`' + $_ + '`' }) -join ', ' }
                }
                Set-Content -LiteralPath $brief -Value ("# Brief`n" + $body)
                $output = (& pwsh -NoProfile -File (Join-Path $skillRoot "bin\$provider-run.ps1") @arguments 2>&1 | Out-String)
                $code = $LASTEXITCODE
                $name = "$provider $(if ($resume) { 'resume' } else { 'fresh' }): $case"
                if ($case -in @('missing external paths', 'sibling and escaped paths')) {
                    Assert-True ($code -eq 3 -and $output.Contains("$provider-run: refused |") -and $output -notmatch '(?m)^command:') "$name must refuse before launch (exit $code): $output"
                    Assert-True ($output.Trim().EndsWith($hint)) "$name must explain where files created after launch belong: $output"
                    $expected = if ($case -eq 'missing external paths') { $missing } else { $siblings }
                    foreach ($path in $expected) { Assert-True ($output.Contains($path)) "$name must list $path" }
                }
                else {
                    Assert-True ($code -eq 0 -and $output -match '(?m)^command:') "$name must be allowed (exit $code): $output"
                }
            }
            if (-not $resume) {
                foreach ($form in $citationForms.Keys) {
                    foreach ($adjacentMissing in @($false, $true)) {
                        $body = $citationForms[$form]
                        if ($adjacentMissing) { $body += ' and `' + $missing[0] + '`' }
                        Set-Content -LiteralPath $brief -Value ("# Brief`n" + $body)
                        $output = (& pwsh -NoProfile -File (Join-Path $skillRoot "bin\$provider-run.ps1") @arguments 2>&1 | Out-String)
                        $code = $LASTEXITCODE
                        $name = "$provider fresh: $form$(if ($adjacentMissing) { ' with missing neighbor' })"
                        if ($adjacentMissing) {
                            Assert-True ($code -eq 3 -and $output.Contains($missing[0]) -and $output -notmatch '(?m)^command:') "$name must refuse the missing neighbor (exit $code): $output"
                            Assert-True ($output.Trim().EndsWith('missing external brief paths: ' + $missing[0] + $hint)) "$name must list only the missing neighbor and the hint: $output"
                        }
                        else {
                            Assert-True ($code -eq 0 -and $output -match '(?m)^command:') "$name must be allowed (exit $code): $output"
                        }
                    }
                }
                Set-Content -LiteralPath $brief -Value ("# Brief`nRead " + '"' + $work + ',' + $listMissing[0] + '" and "' + $hubRoot + ';' + $listMissing[1] + '".')
                $output = (& pwsh -NoProfile -File (Join-Path $skillRoot "bin\$provider-run.ps1") @arguments 2>&1 | Out-String)
                Assert-True ($LASTEXITCODE -eq 3 -and $output.Trim().EndsWith('missing external brief paths: ' + ($listMissing -join '; ') + $hint)) "$provider fresh: quoted lists must check each missing element and show the hint: $output"
                $missingTool = (Join-Path $work 'external inputs (x86)\Missing\tool.exe') + ' --check'
                Set-Content -LiteralPath $brief -Value ("# Brief`nRun ``" + $missingTool + "``.")
                $output = (& pwsh -NoProfile -File (Join-Path $skillRoot "bin\$provider-run.ps1") @arguments 2>&1 | Out-String)
                Assert-True ($LASTEXITCODE -eq 3 -and $output.Contains($missingTool)) "$provider fresh: a path-led command needs its executable, not an existing parent directory: $output"
                $commandArguments = @(
                    ('`' + (Join-Path $work 'bin\codex.cmd') + ' --config ' + $missing[1] + '`'),
                    ('`' + $existing + ' --config ' + $missing[1] + '`'),
                    ('`' + (Join-Path $repo 'tool.ps1') + ' --config ' + $missing[1] + '`')
                )
                foreach ($command in $commandArguments) {
                    Set-Content -LiteralPath $brief -Value ("# Brief`nRun " + $command + '.')
                    $output = (& pwsh -NoProfile -File (Join-Path $skillRoot "bin\$provider-run.ps1") @arguments 2>&1 | Out-String)
                    Assert-True ($LASTEXITCODE -eq 3 -and $output.Trim().EndsWith('missing external brief paths: ' + $missing[1] + $hint)) "$provider fresh: path-led command arguments must be checked and show the hint: $command $output"
                }
            }
        }
    }
}
finally {
    $env:PATH = $originalPath
    $env:PIPELINE_HOME = $originalHome
    $env:CODEX_HOME = $originalCodexHome
    if ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($work)) -ne [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetTempPath())) { throw 'unsafe fixture cleanup path' }
    Remove-Item -LiteralPath $work -Recurse -Force
}
if ($failures.Count) {
    $failures | ForEach-Object { Write-Error $_ -ErrorAction Continue }
    exit 1
}
Write-Output "brief-path tests: PASS ($assertions assertions)"
