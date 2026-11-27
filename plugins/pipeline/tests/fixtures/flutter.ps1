param([Parameter(ValueFromRemainingArguments = $true)][string[]]$RunnerArguments)
$ErrorActionPreference = 'Stop'
Add-Content -LiteralPath $env:FAKE_GATE_COUNTER -Value ($RunnerArguments -join '|')
if (@(Get-Content -LiteralPath $env:FAKE_GATE_COUNTER).Count -eq 1) {
    Write-Output '00:04 +4 -1: test/b_test.dart: breaks [E]'
    Write-Output '00:04 +4 -1: test/b_test.dart: also breaks [E]'
    exit 1
}
if (($RunnerArguments -join '|') -ne 'test|--concurrency=3|test/b_test.dart') {
    Write-Output 'FAIL retry did not select only the failing file'
    exit 9
}
Write-Output 'All tests passed!'
