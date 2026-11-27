[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$RepoPath,

    [string]$FlutterSdkPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-FullPathSafely([string]$Path) {
    try {
        return [pscustomobject]@{ Path = [IO.Path]::GetFullPath($Path); Reason = $null }
    }
    catch {
        return [pscustomobject]@{ Path = $Path; Reason = $_.Exception.Message }
    }
}

function Invoke-CreateNewProbe([string]$Directory) {
    if (-not (Test-Path -LiteralPath $Directory -PathType Container -ErrorAction SilentlyContinue)) {
        return [pscustomobject]@{ Writable = $false; Reason = "directory does not exist: $Directory" }
    }

    $probePath = Join-Path $Directory ('.codex-capability-' + [guid]::NewGuid().ToString('N') + '.tmp')
    $stream = $null
    $writable = $false
    $reason = $null
    try {
        $stream = [IO.File]::Open($probePath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $stream.WriteByte(1)
        $stream.Dispose()
        $stream = $null
        [IO.File]::Delete($probePath)
        $writable = $true
    }
    catch {
        $reason = $_.Exception.Message
    }
    finally {
        if ($null -ne $stream) { $stream.Dispose() }
        if (Test-Path -LiteralPath $probePath -PathType Leaf -ErrorAction SilentlyContinue) {
            try { [IO.File]::Delete($probePath) }
            catch {
                $writable = $false
                $reason = "probe cleanup failed: $($_.Exception.Message)"
            }
        }
    }
    return [pscustomobject]@{ Writable = $writable; Reason = $reason }
}

$reasons = [ordered]@{}
$repoResult = Get-FullPathSafely $RepoPath
$resolvedRepoPath = $repoResult.Path
$repoExists = $false
$repositoryWritable = $false
$gitMetadataPresent = $false
$gitMetadataPath = $null
$gitMetadataWritable = $false
$gitCommonMetadataPresent = $false
$gitCommonMetadataPath = $null
$gitCommonMetadataWritable = $false
$requiresCommonMetadata = $false

if ($repoResult.Reason) {
    $reasons.repository = $repoResult.Reason
}
elseif (-not (Test-Path -LiteralPath $resolvedRepoPath -PathType Container -ErrorAction SilentlyContinue)) {
    $reasons.repository = "repository directory does not exist: $resolvedRepoPath"
}
else {
    $repoExists = $true
    $repoProbe = Invoke-CreateNewProbe $resolvedRepoPath
    $repositoryWritable = $repoProbe.Writable
    if ($repoProbe.Reason) { $reasons.repository = $repoProbe.Reason }

    $dotGit = Join-Path $resolvedRepoPath '.git'
    if (Test-Path -LiteralPath $dotGit -PathType Container -ErrorAction SilentlyContinue) {
        $gitMetadataPresent = $true
        $gitMetadataPath = (Get-FullPathSafely $dotGit).Path
    }
    elseif (Test-Path -LiteralPath $dotGit -PathType Leaf -ErrorAction SilentlyContinue) {
        $gitMetadataPresent = $true
        $requiresCommonMetadata = $true
        try {
            $pointer = ([IO.File]::ReadLines($dotGit) | Select-Object -First 1)
            if ($pointer -notmatch '^gitdir:\s*(.+)\s*$') { throw 'invalid .git worktree pointer' }
            $pointerPath = $Matches[1]
            if (-not [IO.Path]::IsPathRooted($pointerPath)) { $pointerPath = Join-Path $resolvedRepoPath $pointerPath }
            $gitMetadataPath = (Get-FullPathSafely $pointerPath).Path
        }
        catch {
            $reasons.gitMetadata = $_.Exception.Message
        }
    }

    if ($gitMetadataPresent -and $gitMetadataPath) {
        $gitProbe = Invoke-CreateNewProbe $gitMetadataPath
        $gitMetadataWritable = $gitProbe.Writable
        if ($gitProbe.Reason) { $reasons.gitMetadata = $gitProbe.Reason }

        if ($requiresCommonMetadata) {
            try {
                $commonPointerPath = Join-Path $gitMetadataPath 'commondir'
                if (-not (Test-Path -LiteralPath $commonPointerPath -PathType Leaf -ErrorAction SilentlyContinue)) {
                    throw "Git commondir pointer does not exist: $commonPointerPath"
                }
                $commonPointer = ([IO.File]::ReadLines($commonPointerPath) | Select-Object -First 1)
                if ([string]::IsNullOrWhiteSpace($commonPointer)) { throw 'invalid empty Git commondir pointer' }
                if (-not [IO.Path]::IsPathRooted($commonPointer)) {
                    $commonPointer = Join-Path $gitMetadataPath $commonPointer
                }
                $commonPathResult = Get-FullPathSafely $commonPointer
                if ($commonPathResult.Reason) { throw $commonPathResult.Reason }
                $gitCommonMetadataPath = $commonPathResult.Path
                $gitCommonMetadataPresent = Test-Path -LiteralPath $gitCommonMetadataPath -PathType Container -ErrorAction SilentlyContinue
                $commonProbe = Invoke-CreateNewProbe $gitCommonMetadataPath
                $gitCommonMetadataWritable = $commonProbe.Writable
                if ($commonProbe.Reason) { $reasons.gitCommonMetadata = $commonProbe.Reason }
            }
            catch {
                $reasons.gitCommonMetadata = $_.Exception.Message
            }
            $gitMetadataWritable = $gitMetadataWritable -and $gitCommonMetadataWritable
        }
    }
}

$flutterRequested = -not [string]::IsNullOrWhiteSpace($FlutterSdkPath)
$flutterBinWritable = $false
$flutterCacheWritable = $false
if ($flutterRequested) {
    $flutterResult = Get-FullPathSafely $FlutterSdkPath
    if ($flutterResult.Reason) {
        $reasons.flutterBin = $flutterResult.Reason
        $reasons.flutterCache = $flutterResult.Reason
    }
    else {
        $flutterBinProbe = Invoke-CreateNewProbe (Join-Path $flutterResult.Path 'bin')
        $flutterCacheProbe = Invoke-CreateNewProbe (Join-Path $flutterResult.Path 'bin\cache')
        $flutterBinWritable = $flutterBinProbe.Writable
        $flutterCacheWritable = $flutterCacheProbe.Writable
        if ($flutterBinProbe.Reason) { $reasons.flutterBin = $flutterBinProbe.Reason }
        if ($flutterCacheProbe.Reason) { $reasons.flutterCache = $flutterCacheProbe.Reason }
    }
}

[ordered]@{
    repoPath             = $resolvedRepoPath
    repoPathExists       = $repoExists
    repositoryWritable   = $repositoryWritable
    gitMetadataPresent   = $gitMetadataPresent
    gitMetadataPath      = $gitMetadataPath
    gitMetadataWritable  = $gitMetadataWritable
    gitCommonMetadataPresent  = $gitCommonMetadataPresent
    gitCommonMetadataPath     = $gitCommonMetadataPath
    gitCommonMetadataWritable = $gitCommonMetadataWritable
    flutterRequested     = $flutterRequested
    flutterBinWritable   = $flutterBinWritable
    flutterCacheWritable = $flutterCacheWritable
    reasons              = $reasons
} | ConvertTo-Json -Depth 3 -Compress
