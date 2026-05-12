# scan.ps1 -- tell the Ignition Gateway to re-scan project resources from disk.
# Use after Claude / a script writes new files into ignition/projects/<proj>/ and
# you want Designer to pick them up without a gateway restart.
#
# Token must live at $tokenFile (gitignored / outside the repo by convention).

$tokenFile  = "C:\Users\JacquesPotgieter\Documents\git-sync-api-key.txt"
$gatewayUrl = "http://localhost:8088"

if (-not (Test-Path $tokenFile)) {
    Write-Host "Token file not found at $tokenFile -- aborting." -ForegroundColor Red
    exit 1
}

$token = (Get-Content $tokenFile -Raw).Trim()
$url   = "$gatewayUrl/data/api/v1/scan/projects"

# Trigger a scan. Content-Type header is REQUIRED on POST (omitting it yields 403
# in 8.3.5-rc1) even though the body is empty.
$body = curl.exe -s -X POST $url `
    -H "X-Ignition-API-Token: $token" `
    -H "Content-Type: application/json" `
    -d "{}"

Write-Host $body

# Poll once briefly so the caller knows scan finished, not just started.
Start-Sleep -Milliseconds 600
$state = curl.exe -s -X GET $url -H "X-Ignition-API-Token: $token"
Write-Host ""
Write-Host "Post-scan state:"
Write-Host $state
