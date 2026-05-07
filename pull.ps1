# pull.ps1 — sync the deploy machine's working copy to origin/hunter/explore
# and trigger an Ignition Gateway project scan only when something actually changed.
#
# Behavior:
#   1. Switch to the target branch (logs result; aborts on failure).
#   2. Capture HEAD before the fetch.
#   3. Fetch + reset --hard origin/<branch> (forces exact match with remote).
#   4. git clean -fd to remove orphaned untracked files, preserving pull.log.
#   5. Capture HEAD after; only POST the scan endpoint if HEAD moved.
#   6. Log start + end timestamps separately and the total elapsed seconds.

$git        = "C:\Program Files\Git\cmd\git.exe"
$repo       = "C:\MPP"
$log        = "C:\MPP\pull.log"
$tokenFile  = "C:\Users\admin\Documents\git-sync-api-key.txt"
$gatewayUrl = "http://localhost:8088"
$branch     = "hunter/explore"

function Write-Log {
    param([string]$msg)
    Add-Content -Path $log -Value $msg
}

function Stop-Sync {
    param([string]$msg)
    Write-Log $msg
    Write-Log "Aborting sync."
    exit 1
}

# --- Start ----------------------------------------------------------------
$startTime  = Get-Date
$startStamp = $startTime.ToString("yyyy-MM-dd HH:mm:ss")
Write-Log "[$startStamp] Starting sync..."

# --- Ensure correct branch ------------------------------------------------
$checkoutOut = & $git -C $repo checkout $branch 2>&1
if ($LASTEXITCODE -ne 0) {
    Stop-Sync "Checkout FAILED (exit $LASTEXITCODE): $checkoutOut"
}
Write-Log "Checkout: $checkoutOut"

# --- Capture HEAD before --------------------------------------------------
$headBefore = (& $git -C $repo rev-parse HEAD 2>&1) | Out-String
$headBefore = $headBefore.Trim()
if ($LASTEXITCODE -ne 0) {
    Stop-Sync "Could not read HEAD before fetch (exit $LASTEXITCODE): $headBefore"
}

# --- Fetch ----------------------------------------------------------------
$fetchOut = & $git -C $repo fetch origin $branch 2>&1
if ($LASTEXITCODE -ne 0) {
    Stop-Sync "Fetch FAILED (exit $LASTEXITCODE): $fetchOut"
}
Write-Log "Fetch: $fetchOut"

# --- Reset working tree to remote -----------------------------------------
$resetOut = & $git -C $repo reset --hard "origin/$branch" 2>&1
if ($LASTEXITCODE -ne 0) {
    Stop-Sync "Reset FAILED (exit $LASTEXITCODE): $resetOut"
}
Write-Log "Reset: $resetOut"

# --- Clean orphaned untracked files (excluding the log itself) ------------
$cleanOut = & $git -C $repo clean -fd -e pull.log 2>&1
if ($LASTEXITCODE -ne 0) {
    # Non-fatal — the reset already happened; scan should still run.
    Write-Log "Clean WARNING (exit $LASTEXITCODE): $cleanOut"
} else {
    Write-Log "Clean: $cleanOut"
}

# --- Capture HEAD after ---------------------------------------------------
$headAfter = (& $git -C $repo rev-parse HEAD 2>&1) | Out-String
$headAfter = $headAfter.Trim()
if ($LASTEXITCODE -ne 0) {
    Stop-Sync "Could not read HEAD after reset (exit $LASTEXITCODE): $headAfter"
}

# --- Conditionally trigger Ignition scan ----------------------------------
if ($headBefore -eq $headAfter) {
    Write-Log "No changes (HEAD still at $headBefore) -- skipping Ignition scan."
} else {
    Write-Log "Changes detected ($headBefore -> $headAfter) -- triggering Ignition file system scan..."

    if (-not (Test-Path $tokenFile)) {
        Write-Log "Token file not found at $tokenFile -- skipping scan."
    } else {
        $token      = (Get-Content $tokenFile -Raw).Trim()
        $scanResult = curl.exe -s -o NUL -w "%{http_code}" -X POST "$gatewayUrl/data/api/v1/scan/projects" -H "X-Ignition-API-Token: $token"
        Write-Log "Scan response: $scanResult"
    }
}

# --- End ------------------------------------------------------------------
$endTime  = Get-Date
$endStamp = $endTime.ToString("yyyy-MM-dd HH:mm:ss")
$elapsed  = [math]::Round(($endTime - $startTime).TotalSeconds, 2)
Write-Log "[$endStamp] Sync complete (elapsed: ${elapsed}s)."
