$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../skills/pipeline/bin/RunCommon.ps1')
$work = Join-Path ([IO.Path]::GetTempPath()) ('test-brief-devices-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $work | Out-Null
$brief = Join-Path $work 'brief.md'
$assertions = 0
try {
    foreach ($newline in @("`n", "`r`n")) {
        foreach ($case in @(
            @{ Text = 'Device: emulator-5556'; Expected = 'emulator-5556' },
            @{ Text = "## Known state`nUse emulator-5556 twice: emulator-5556."; Expected = 'emulator-5556' },
            @{ Text = "## Known state`nNone.`n`nRepo notes:`n- adb -s emulator-5554 emu geo fix 9 45.`n`n## Verify`nNone."; Expected = '' },
            @{ Text = "Device: emulator-5556`nRepo notes:`n- Device: R58M123ABC`n- emulator-5554"; Expected = 'emulator-5556' },
            @{ Text = "## Known state`nUse emulator-5556.`n`nRepo notes:`n- emulator-5554`n`n## Verify`nDevice: R58M123ABC"; Expected = 'emulator-5556,R58M123ABC' }
        )) {
            Set-Content -LiteralPath $brief -Value ($case.Text.Replace("`n", $newline))
            $actual = @(Get-BriefDevices $brief) -join ','
            $assertions++
            if ($actual -cne $case.Expected) { throw "Expected '$($case.Expected)', got '$actual'" }
        }
    }
    Write-Output "brief device tests: PASS ($assertions assertions)"
}
finally { Remove-Item -LiteralPath $work -Recurse -Force }
