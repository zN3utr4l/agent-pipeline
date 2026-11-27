Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$raw = [Console]::In.ReadToEnd()
try { $hookInput = $raw | ConvertFrom-Json } catch { exit 0 }
if ($null -eq $hookInput -or $null -eq $hookInput.PSObject.Properties['tool_name']) { exit 0 }
if ($hookInput.tool_name -notin @('Bash', 'PowerShell')) { exit 0 }
if ($null -eq $hookInput.PSObject.Properties['tool_input'] -or $null -eq $hookInput.tool_input.PSObject.Properties['command']) { exit 0 }
$command = [string]$hookInput.tool_input.command
$background = $hookInput.tool_input.PSObject.Properties['run_in_background']
if ($null -ne $background -and $background.Value -is [bool] -and $background.Value) {
    [Console]::Error.WriteLine('Blocked by the pipeline executor guard: run the command in the foreground and wait for it to finish.')
    exit 2
}
$patterns = @(
    '(?<![\w-])git(?:\.exe)?["'']?(?:\s+(?:-C|-c|--git-dir|--work-tree|--namespace)\s+\S+|\s+-\S+)*\s+(push|merge|rebase|checkout|switch|reset|clean|filter-branch|update-ref)\b',
    '(?<![\w-])git(?:\.exe)?["'']?(?:\s+(?:-C|-c|--git-dir|--work-tree|--namespace)\s+\S+|\s+-\S+)*\s+stash\s+(drop|clear)\b',
    '(?<![\w-])git(?:\.exe)?["'']?(?:\s+(?:-C|-c|--git-dir|--work-tree|--namespace)\s+\S+|\s+-\S+)*\s+branch\b.*(\s-[dD]\b|--delete)',
    '(?<![\w-])git(?:\.exe)?["'']?(?:\s+(?:-C|-c|--git-dir|--work-tree|--namespace)\s+\S+|\s+-\S+)*\s+tag\b.*\s-d\b',
    '(?<![\w-])git(?:\.exe)?["'']?(?:\s+(?:-C|-c|--git-dir|--work-tree|--namespace)\s+\S+|\s+-\S+)*\s+remote\s+(add|remove|set-url)\b',
    '(?<![\w-])git(?:\.exe)?["'']?(?:\s+(?:-C|-c|--git-dir|--work-tree|--namespace)\s+\S+|\s+-\S+)*\s+commit\b.*--amend',
    '--no-verify',
    '(?<![\w-])gh(?:\.exe)?["'']?\s+(pr|release|repo|issue)\s+(create|merge|edit|comment|close|delete|ready|review)\b',
    '(?<![\w-])gh(?:\.exe)?["'']?\s+api\b.*(\s-X|--method)\s*(POST|PUT|PATCH|DELETE)\b'
)
foreach ($pattern in $patterns) {
    $match = [regex]::Match($command, $pattern, 'IgnoreCase')
    if ($match.Success) {
        [Console]::Error.WriteLine("Blocked by the pipeline executor guard: $($match.Value.Trim()). Report it as a blocker; the planning session owns git history and GitHub.")
        exit 2
    }
}
exit 0
