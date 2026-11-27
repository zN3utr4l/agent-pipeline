$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\skills\pipeline')).Path
$work = Join-Path ([IO.Path]::GetTempPath()) ('context-audit-' + [guid]::NewGuid())
$assertions = 0
function Assert-True([bool]$Condition, [string]$Message) {
    $script:assertions++
    if (-not $Condition) { throw $Message }
}
try {
    $repos = Join-Path $work 'repos'
    $memory = Join-Path $work 'memory'
    $transcripts = Join-Path $work 'projects'
    New-Item -ItemType Directory -Force -Path $repos,$memory,$transcripts,(Join-Path $repos 'node_modules'),(Join-Path $repos 'boundary'),(Join-Path $memory 'archive'),(Join-Path $transcripts 'project-a') | Out-Null
    Set-Content -LiteralPath (Join-Path $repos 'CLAUDE.md') -Value ((1..201 | ForEach-Object { 'rule' }) -join "`n")
    Set-Content -LiteralPath (Join-Path $repos 'AGENTS.md') -Value ('a' * 17000)
    Set-Content -LiteralPath (Join-Path $repos 'boundary/AGENTS.md') -Value ((1..200 | ForEach-Object { 'short' }) -join "`n")
    Set-Content -LiteralPath (Join-Path $repos 'node_modules/AGENTS.md') -Value ('x' * 20000)
    Set-Content -LiteralPath (Join-Path $memory 'MEMORY.md') -Value ('m' * 8200)
    Set-Content -LiteralPath (Join-Path $memory 'notes.md') -Value ('n' * 21000)
    Set-Content -LiteralPath (Join-Path $memory 'archive/old.md') -Value ('m' * 25000)
    $stamp = (Get-Date).ToUniversalTime().ToString('o')
    foreach ($tokens in @(70000,50000,120000)) {
        $row = @{ type='assistant'; timestamp=$stamp; cwd='C:\fixture\repo'; message=@{ id=[guid]::NewGuid().ToString(); model='claude-test'; usage=@{ input_tokens=$tokens; cache_read_input_tokens=1000; cache_creation_input_tokens=2000 } } } | ConvertTo-Json -Compress -Depth 8
        Set-Content -LiteralPath (Join-Path $transcripts "project-a/session-$tokens.jsonl") -Value $row
    }
    $old = @{ type='assistant'; timestamp=(Get-Date).AddDays(-9).ToUniversalTime().ToString('o'); cwd='C:\fixture\repo'; message=@{ id='old'; model='claude-test'; usage=@{ input_tokens=1 } } } | ConvertTo-Json -Compress -Depth 8
    $later = @{ type='assistant'; timestamp=$stamp; cwd='C:\fixture\repo'; message=@{ id='later'; model='claude-test'; usage=@{ input_tokens=90000 } } } | ConvertTo-Json -Compress -Depth 8
    Set-Content -LiteralPath (Join-Path $transcripts 'project-a/old-session.jsonl') -Value @($old,$later)
    $output = & node (Join-Path $root 'bin/context-audit.js') --roots $repos --memory $memory --transcripts $transcripts --days 7 2>&1 | Out-String
    Assert-True ($LASTEXITCODE -eq 0) "context audit exit: $output"
    Assert-True ($output.Contains('CLAUDE.md') -and $output -match '20[12] lines') 'instruction threshold missing'
    Assert-True ($output.Contains('AGENTS.md') -and $output -match '17\d\d\d bytes') 'instruction byte threshold missing'
    Assert-True (-not $output.Contains('boundary')) 'exactly 200 lines flagged'
    Assert-True (-not $output.Contains('node_modules')) 'excluded instruction directory scanned'
    Assert-True ($output.Contains('MEMORY.md') -and $output.Contains('notes.md') -and -not $output.Contains('old.md')) 'memory threshold or archive exclusion failed'
    Assert-True ($output.Contains('C:\fixture\repo') -and $output.Contains('median 73000') -and $output.Contains('max 123000')) 'first-call context grouping failed'
    Assert-True ($output.Contains('Startup context: 3 sessions')) 'old sessions were counted from later calls'
    Assert-True ($output.Contains('FLAG')) 'high median not flagged'
    Write-Output "context audit tests: PASS ($assertions assertions)"
}
finally { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
