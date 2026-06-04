# scan.ps1 -- tell the Ignition Gateway to re-scan project resources from disk.
# Use after Claude / git pull / a script writes new files into
# ignition/projects/<proj>/ and you want Designer to pick them up without a
# gateway restart.
#
# Token must live at $tokenFile (gitignored / outside the repo by convention).
# $tokenFile auto-resolves to <your-user-home>\Documents\git-sync-api-key.txt
# so the same checked-in script works for every developer without churning the
# path. Override with $env:IGNITION_API_TOKEN_FILE if you keep the token
# somewhere else.
#
# One-time setup (per developer):
#   1. Open http://localhost:8088 in a browser, sign in as the gateway admin.
#   2. Config tab -> Security -> API Keys -> Create new API Key.
#      Grant it the permission scope that covers
#      `POST /data/api/v1/scan/projects` (in 8.3 this is under the
#      Gateway Web API permissions; exact label varies by patch version).
#   3. Click Create, copy the generated token -- it is shown ONLY on creation.
#      Lose it and you'll need to revoke + create a new one.
#   4. Save it to %USERPROFILE%\Documents\git-sync-api-key.txt
#      (e.g. C:\Users\HunterKraft\Documents\git-sync-api-key.txt).
#      File contents: the token, nothing else (no quotes, no trailing newline).

$tokenFile  = if ($env:IGNITION_API_TOKEN_FILE) {
                  $env:IGNITION_API_TOKEN_FILE
              } else {
                  Join-Path $env:USERPROFILE "Documents\git-sync-api-key.txt"
              }
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
