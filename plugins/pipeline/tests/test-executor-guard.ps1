$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\skills\pipeline')).Path
$script = Join-Path $root 'hooks\guard-executor-git.ps1'
$failures = [Collections.Generic.List[string]]::new()
$assertions = 0
$work = Join-Path ([IO.Path]::GetTempPath()) ('.test-executor-guard-' + [guid]::NewGuid())
$stderrPath = Join-Path $work 'stderr.log'
New-Item -ItemType Directory -Path $work | Out-Null

function Assert-True([bool]$Condition, [string]$Message) {
    $script:assertions++
    if (-not $Condition) { $failures.Add($Message) }
}

function Invoke-Guard([string]$Json) {
    $null = $Json | & pwsh -NoProfile -File $script 2> $stderrPath
    $exitCode = $LASTEXITCODE
    $stderr = if (Test-Path -LiteralPath $stderrPath) { Get-Content -Raw -LiteralPath $stderrPath } else { '' }
    return [pscustomobject]@{ ExitCode = $exitCode; Stderr = $stderr }
}

try {
    Assert-True (Test-Path -LiteralPath $script) 'missing hooks\guard-executor-git.ps1'

    $blocked = @(
        @{ tool = 'Bash'; command = 'git push origin main' },
        @{ tool = 'Bash'; command = 'git push --force-with-lease' },
        @{ tool = 'Bash'; command = 'cd D:\x && git rebase main' },
        @{ tool = 'Bash'; command = 'git checkout main' },
        @{ tool = 'Bash'; command = 'git switch -c feature' },
        @{ tool = 'Bash'; command = 'git reset --hard HEAD~1' },
        @{ tool = 'Bash'; command = 'git clean -fd' },
        @{ tool = 'Bash'; command = 'git commit --amend -m "x"' },
        @{ tool = 'Bash'; command = 'git commit -m x --no-verify' },
        @{ tool = 'Bash'; command = 'git branch -D old' },
        @{ tool = 'Bash'; command = 'git tag -d old' },
        @{ tool = 'Bash'; command = 'git stash drop' },
        @{ tool = 'Bash'; command = 'gh pr create --fill' },
        @{ tool = 'Bash'; command = 'git -C D:\x push' },
        @{ tool = 'Bash'; command = 'git -c user.name=x merge feat' },
        @{ tool = 'Bash'; command = 'git.exe push' },
        @{ tool = 'Bash'; command = '& "C:\Program Files\Git\bin\git.exe" push' },
        @{ tool = 'Bash'; command = 'git --work-tree D:\x --git-dir D:\x\.git push' },
        @{ tool = 'Bash'; command = 'gh.exe pr create --fill' },
        @{ tool = 'Bash'; command = 'gh pr merge 5 --squash' },
        @{ tool = 'Bash'; command = 'gh api repos/o/r/pulls -X POST -f title=x' },
        @{ tool = 'PowerShell'; command = 'git push origin main' }
    )
    foreach ($case in $blocked) {
        $json = @{ tool_name = $case.tool; tool_input = @{ command = $case.command } } | ConvertTo-Json -Compress
        $result = Invoke-Guard $json
        Assert-True ($result.ExitCode -eq 2) "command was not blocked: $($case.command)"
        Assert-True ($result.Stderr -match 'Blocked by the pipeline executor guard') "reason for blocking was missing: $($case.command)"
    }

    foreach ($tool in @('Bash', 'PowerShell')) {
        $json = @{ tool_name = $tool; tool_input = @{ command = 'npm test'; run_in_background = $true } } | ConvertTo-Json -Compress
        $result = Invoke-Guard $json
        Assert-True ($result.ExitCode -eq 2) "background $tool call not blocked"
        Assert-True ($result.Stderr -match 'foreground and wait') "background $tool refusal lacks foreground guidance"
    }

    $allowed = @(
        @{ tool = 'Bash'; command = 'git status --short' },
        @{ tool = 'Bash'; command = 'git add -A && git commit -m "feat: x"' },
        @{ tool = 'Bash'; command = 'git diff --check' },
        @{ tool = 'Bash'; command = 'git log origin/main..HEAD --oneline' },
        @{ tool = 'Bash'; command = 'git stash list' },
        @{ tool = 'Bash'; command = 'git branch --show-current' },
        @{ tool = 'Bash'; command = 'git log --grep push' },
        @{ tool = 'Bash'; command = 'github push' },
        @{ tool = 'Bash'; command = 'git fetch origin && git log origin/main..HEAD' },
        @{ tool = 'Bash'; command = 'gh pr view 5 --json state' },
        @{ tool = 'Bash'; command = 'gh run list --limit 3' },
        @{ tool = 'Bash'; command = 'flutter test test/a_test.dart' },
        @{ tool = 'Bash'; command = 'npm run test:run -- src/a.test.ts' },
        @{ tool = 'Read'; command = 'git push origin main' }
    )
    foreach ($case in $allowed) {
        $json = @{ tool_name = $case.tool; tool_input = @{ command = $case.command } } | ConvertTo-Json -Compress
        $result = Invoke-Guard $json
        Assert-True ($result.ExitCode -eq 0) "allowed command was blocked: $($case.command)"
        Assert-True ([string]::IsNullOrWhiteSpace($result.Stderr)) "unexpected stderr for allowed command: $($case.command)"
    }
    foreach ($background in @($false, $null, 'true')) {
        $json = @{ tool_name = 'Bash'; tool_input = @{ command = 'npm test'; run_in_background = $background } } | ConvertTo-Json -Compress
        $result = Invoke-Guard $json
        Assert-True ($result.ExitCode -eq 0) 'foreground Bash call unexpectedly blocked'
    }

    foreach ($json in @('not json', (@{ tool_name = 'Bash' } | ConvertTo-Json -Compress))) {
        $result = Invoke-Guard $json
        Assert-True ($result.ExitCode -eq 0) 'incomplete or non-JSON input was blocked'
        Assert-True ([string]::IsNullOrWhiteSpace($result.Stderr)) 'incomplete or non-JSON input produced stderr'
    }
}
catch {
    $failures.Add($_.Exception.Message)
}
finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Error $_ -ErrorAction Continue }
    exit 1
}

Write-Output "executor guard tests: PASS ($assertions assertions)"
