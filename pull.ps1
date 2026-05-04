$git = "C:\Program Files\Git\cmd\git.exe"
$repo = "C:\MPP"
$log = "C:\MPP\pull.log"
$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

Add-Content $log ("[$timestamp] Starting sync...")

# Ensure correct branch
& $git -C $repo checkout hunter/explore 2>&1 | Out-Null

# Capture commit hash before fetch
$hashBefore = & $git -C $repo rev-parse HEAD 2>&1

# Fetch and reset to remote
$fetch = & $git -C $repo fetch origin hunter/explore 2>&1
Add-Content $log ("Fetch: " + $fetch)

$reset = & $git -C $repo reset --hard origin/hunter/explore 2>&1
Add-Content $log ("Reset: " + $reset)

# Capture commit hash after fetch
$hashAfter = & $git -C $repo rev-parse HEAD 2>&1

# Trigger Ignition scan only if something changed
if ($hashBefore -ne $hashAfter) {
    Add-Content $log "Changes detected - triggering Ignition file system scan..."
    $token = (Get-Content "C:\Users\admin\Documents\git-sync-api-key.txt" -Raw).Trim()
    $result = curl.exe -s -o NUL -w "%{http_code}" -X POST "http://localhost:8088/data/api/v1/scan/projects" -H "X-Ignition-API-Token: $token"
    Add-Content $log ("Scan response: " + $result)
} else {
    Add-Content $log "No changes - skipping scan."
}

Add-Content $log ("[$timestamp] Sync complete.")
