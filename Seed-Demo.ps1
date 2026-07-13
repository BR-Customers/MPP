# =============================================================================
# Seed-Demo.ps1
# Re-seeds the continuous demo threads into an existing MPP_MES_Dev WITHOUT a
# full database rebuild. seed_demo.sql is idempotent -- it wipes its own
# transactional footprint (LOTs, containers, events, holds, downtime, ...) in
# FK-safe order, then rebuilds the golden thread via the production procs.
#
# Config (Parts.*, Location.*, Tools.*, code tables) is left intact -- this only
# touches transactional data. For a from-scratch rebuild use Reset-DevDatabase.ps1
# (which runs seed_demo.sql by default; pass -SkipDemoSeed to skip it).
#
#   Run:  .\Seed-Demo.ps1
#         .\Seed-Demo.ps1 -ServerInstance ".\SQL2022" -DatabaseName "MPP_MES_Dev"
#
# NOTE: after seeding, the running Ignition gateway's cached data is stale -- run
# .\scan.ps1 (a full gateway restart is NOT required; no schema changed).
# =============================================================================
[CmdletBinding()]
param(
    [string]$ServerInstance = "localhost",
    [string]$DatabaseName   = "MPP_MES_Dev"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$DemoFile  = Join-Path $ScriptDir "sql\scratch\seed_demo.sql"

if (-not (Test-Path $DemoFile)) {
    Write-Host "  ERROR: seed_demo.sql not found at: $DemoFile" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "Seeding demo threads into $DatabaseName on $ServerInstance ..." -ForegroundColor Cyan

# -b: abort on error; -I: QUOTED_IDENTIFIER ON (Lots.* filtered indexes need it); -C: trust cert.
$output = & sqlcmd -S $ServerInstance -d $DatabaseName -E -b -I -C -i $DemoFile 2>&1
if ($LASTEXITCODE -ne 0) {
    $output | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    Write-Host "  Seed-Demo FAILED (exit $LASTEXITCODE)." -ForegroundColor Red
    exit 1
}
$output | ForEach-Object { Write-Host "  $_" }

Write-Host ""
Write-Host "  Demo threads seeded. Run .\scan.ps1 so the gateway picks up the new data." -ForegroundColor Green
Write-Host ""
