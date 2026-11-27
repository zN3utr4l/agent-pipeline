$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\skills\pipeline')).Path
$script = Join-Path $root 'bin\test-executor-capabilities.ps1'
$failures = [Collections.Generic.List[string]]::new()
$script:assertionCount = 0

function Assert-True([bool]$Condition, [string]$Message) {
    $script:assertionCount++
    if (-not $Condition) { $failures.Add($Message) }
}

function Invoke-CapabilityProbe {
    param([string[]]$Arguments)
    $output = (& pwsh -NoProfile -File $script @Arguments 2>&1 | Out-String)
    return [pscustomobject]@{ Output = $output; ExitCode = $LASTEXITCODE }
}

# Outside the hub, so a delete that loses the Windows race leaves nothing behind here.
$work = Join-Path ([IO.Path]::GetTempPath()) ('.test-executor-capabilities-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $work | Out-Null

function Remove-WorkDir([string]$Path) {
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path -LiteralPath $Path)) { return }
        Start-Sleep -Milliseconds 200
    }
}

try {
    Assert-True (Test-Path -LiteralPath $script -PathType Leaf) 'missing bin\test-executor-capabilities.ps1'
    if (-not (Test-Path -LiteralPath $script -PathType Leaf)) { throw 'capability script missing' }

    # A normal fake repository probes only unique temporary files and cleans them.
    $repo = Join-Path $work 'repo'
    $gitDir = Join-Path $repo '.git'
    New-Item -ItemType Directory -Path $gitDir -Force | Out-Null
    $plain = Invoke-CapabilityProbe @('-RepoPath', $repo)
    $plainJson = $plain.Output | ConvertFrom-Json
    Assert-True ($plain.ExitCode -eq 0) 'fixture repository probe failed'
    Assert-True ($plainJson.repoPathExists -eq $true) 'existing repository was not detected'
    Assert-True ($plainJson.repositoryWritable -eq $true) 'writability of the fixture repository was not detected'
    Assert-True ($plainJson.gitMetadataPresent -eq $true) 'fixture .git directory was not detected'
    Assert-True ($plainJson.gitMetadataWritable -eq $true) 'writability of fixture Git metadata was not detected'
    Assert-True ($plainJson.flutterRequested -eq $false) 'Flutter probed without an explicit parameter'

    # A worktree pointer must resolve its actual metadata directory without Git.
    $worktree = Join-Path $work 'worktree'
    $metadata = Join-Path $work 'worktree-metadata'
    $commonMetadata = Join-Path $work 'common-metadata'
    New-Item -ItemType Directory -Path $worktree, $metadata, $commonMetadata | Out-Null
    Set-Content -LiteralPath (Join-Path $worktree '.git') -Value 'gitdir: ..\worktree-metadata' -Encoding ascii
    Set-Content -LiteralPath (Join-Path $metadata 'commondir') -Value '..\common-metadata' -Encoding ascii
    $pointer = Invoke-CapabilityProbe @('-RepoPath', $worktree)
    $pointerJson = $pointer.Output | ConvertFrom-Json
    Assert-True ($pointer.ExitCode -eq 0) 'worktree pointer probe failed'
    Assert-True ($pointerJson.gitMetadataPresent -eq $true) 'worktree pointer was not detected'
    Assert-True ($pointerJson.gitMetadataWritable -eq $true) 'worktree metadata was not probed'
    Assert-True ($pointerJson.gitMetadataPath -eq (Resolve-Path -LiteralPath $metadata).Path) 'worktree pointer resolved to the wrong path'
    $commonPathProperty = $pointerJson.PSObject.Properties['gitCommonMetadataPath']
    $commonWritableProperty = $pointerJson.PSObject.Properties['gitCommonMetadataWritable']
    Assert-True ($null -ne $commonPathProperty -and $commonPathProperty.Value -eq (Resolve-Path -LiteralPath $commonMetadata).Path) 'valid commondir did not resolve to shared metadata'
    Assert-True ($null -ne $commonWritableProperty -and $commonWritableProperty.Value -eq $true) 'valid shared Git metadata was not probed'

    # A writable per-worktree directory cannot mask a missing shared Git directory.
    $brokenWorktree = Join-Path $work 'broken-worktree'
    $brokenMetadata = Join-Path $work 'broken-metadata'
    New-Item -ItemType Directory -Path $brokenWorktree, $brokenMetadata | Out-Null
    Set-Content -LiteralPath (Join-Path $brokenWorktree '.git') -Value 'gitdir: ..\broken-metadata' -Encoding ascii
    Set-Content -LiteralPath (Join-Path $brokenMetadata 'commondir') -Value '..\missing-common-metadata' -Encoding ascii
    $brokenPointer = Invoke-CapabilityProbe @('-RepoPath', $brokenWorktree)
    $brokenPointerJson = $brokenPointer.Output | ConvertFrom-Json
    Assert-True ($brokenPointer.ExitCode -eq 0) 'missing commondir caused the probe to fail'
    Assert-True ($brokenPointerJson.gitMetadataWritable -eq $false) 'writable worktree metadata masked the missing commondir'
    $commonReasonProperty = $brokenPointerJson.reasons.PSObject.Properties['gitCommonMetadata']
    Assert-True ($null -ne $commonReasonProperty -and $commonReasonProperty.Value -match 'does not exist') 'missing commondir lacked a diagnostic message'

    # Flutter is probed only when its SDK path is supplied.
    $flutter = Join-Path $work 'flutter'
    New-Item -ItemType Directory -Path (Join-Path $flutter 'bin\cache') -Force | Out-Null
    $withFlutter = Invoke-CapabilityProbe @('-RepoPath', $repo, '-FlutterSdkPath', $flutter)
    $flutterJson = $withFlutter.Output | ConvertFrom-Json
    Assert-True ($flutterJson.flutterRequested -eq $true) 'Flutter request was not recorded'
    Assert-True ($flutterJson.flutterBinWritable -eq $true) 'fixture Flutter bin was not writable'
    Assert-True ($flutterJson.flutterCacheWritable -eq $true) 'fixture Flutter cache was not writable'

    # Missing paths are diagnostics, not thrown errors.
    $missing = Invoke-CapabilityProbe @('-RepoPath', (Join-Path $work 'missing-repo'), '-FlutterSdkPath', (Join-Path $work 'missing-flutter'))
    $missingJson = $missing.Output | ConvertFrom-Json
    Assert-True ($missing.ExitCode -eq 0) 'missing directories caused the probe to fail'
    Assert-True ($missingJson.repoPathExists -eq $false) 'missing repository was reported as existing'
    Assert-True ($missingJson.repositoryWritable -eq $false) 'missing repository was reported as writable'
    Assert-True ($missingJson.flutterBinWritable -eq $false -and $missingJson.flutterCacheWritable -eq $false) 'missing Flutter SDK was reported as writable'
    Assert-True ($missingJson.reasons.repository -match 'does not exist') 'missing repository lacked a diagnostic message'

    $leftovers = @(Get-ChildItem -LiteralPath $work -Recurse -Force -File | Where-Object Name -Like '.codex-capability-*')
    Assert-True ($leftovers.Count -eq 0) 'probe left temporary files'
}
catch {
    $failures.Add($_.Exception.Message)
}
finally {
    Remove-WorkDir $work
}

Assert-True (-not (Test-Path -LiteralPath $work)) "working directory was not removed: $work"

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Error $_ -ErrorAction Continue }
    exit 1
}

Write-Output "executor capability tests: PASS ($script:assertionCount assertions)"
