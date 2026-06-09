# Quiet wrapper: runs Run-Tests.ps1 with a filter and prints only test result lines.
param([string]$Filter = "0020_PlantFloor_Foundation")
$out = & "$PSScriptRoot\Run-Tests.ps1" -Filter $Filter 2>&1
$out | Select-String -Pattern "PASS:|FAIL:|Total: |Passed:|Failed:|Msg \d|ERROR running|Could not find|Incorrect syntax|Test run" |
    ForEach-Object { $_.ToString() }
