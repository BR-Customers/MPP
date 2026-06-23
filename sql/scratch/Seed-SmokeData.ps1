# =============================================================================
# Seed-SmokeData.ps1
# Builds a complete, known-good DEV test environment in MPP_MES_Dev:
#   1. Rebuilds the database from scratch (migrations + base seed) via
#      Reset-DevDatabase.ps1  -- guarded so the gateway pool releases.
#   2. Layers ALL scenario smoke data (Phases 2-8) in dependency order.
#
# Use this for first-time setup or a full reset to a clean test state.
# For a quick refresh of just the machining/assembly/ship/sort/AIM data
# (no full rebuild), run sql\scratch\smoke_seed_phase5_7.sql on its own --
# it self-cleans.
#
#   Run:  .\sql\scratch\Seed-SmokeData.ps1
#
# NOTE: this always rebuilds first. The scenario seeds clean up by deleting their
# own rows, which FK-conflicts on a dirty DB -- they only compose cleanly from a
# fresh reset, run once in order. For a quick arc-only refresh WITHOUT a rebuild,
# run sql\scratch\smoke_seed_phase5_7.sql directly (it self-cleans in isolation).
# =============================================================================
$root  = Split-Path -Parent $MyInvocation.MyCommand.Path
# Reliable scenario seeds (verified against the current schema). phase2 (lot-lifecycle)
# and phase4 (trim/receiving) are LEGACY seeds that error on the current schema and are
# excluded pending repair -- see TESTING_GUIDE.md "Known gaps".
$seeds = @("phase3_diecast", "phase5_7", "phase8")

Write-Host "Rebuilding MPP_MES_Dev (guarded reset)..." -ForegroundColor Cyan
sqlcmd -S localhost -d master -E -C -b -Q "ALTER LOGIN ignition DISABLE;" | Out-Null
try {
    & (Join-Path $root "..\scripts\Reset-DevDatabase.ps1")
    if ($LASTEXITCODE -ne 0) { Write-Host "  Reset FAILED (exit $LASTEXITCODE). Aborting." -ForegroundColor Red; return }
} finally {
    sqlcmd -S localhost -d master -E -C -b -Q "ALTER LOGIN ignition ENABLE;" | Out-Null
}
Write-Host "  reset OK" -ForegroundColor Green

Write-Host "Seeding scenario smoke data..." -ForegroundColor Cyan
foreach ($s in $seeds) {
    $f = Join-Path $root "smoke_seed_$s.sql"
    if (-not (Test-Path $f)) { Write-Host ("  {0,-16} MISSING" -f $s) -ForegroundColor Yellow; continue }
    Write-Host ("  {0,-16} " -f $s) -NoNewline
    $out = sqlcmd -S localhost -d MPP_MES_Dev -E -C -I -b -i $f 2>&1
    if ($LASTEXITCODE -ne 0 -or ($out -match "Msg \d+")) {
        Write-Host "ERROR" -ForegroundColor Red
        ($out | Select-String "Msg \d+|error" | Select-Object -First 3) | ForEach-Object { Write-Host "    $_" }
    } else { Write-Host "OK" -ForegroundColor Green }
}
Write-Host ""
Write-Host "================ WHAT TO SMOKE (live IDs) ================" -ForegroundColor Cyan
$guide = @"
SET NOCOUNT ON;
SELECT Seq AS [#], Screen, [Pick / Enter] AS Input, [Use this] FROM (VALUES
 (1,'Machining IN','DEV NAV: Mach IN  (cell MA1-5GOF-MIN)', (SELECT STRING_AGG(LotName, ', ') WITHIN GROUP (ORDER BY Id) FROM Lots.Lot WHERE LotName LIKE 'SMK-MIN-%')+' (-3 is on Hold)'),
 (2,'Machining OUT','DEV NAV: Mach OUT (cell MA1-5GOF-MOUT)', (SELECT TOP 1 LotName FROM Lots.Lot WHERE LotName='SMK-MOUT-1')+'  -- split two qtys summing to 48'),
 (3,'Assembly Serialized','DEV NAV: Asm Ser (cell MA1-5GOF-ASER)', 'open 5G0 container '+CAST((SELECT MAX(Id) FROM Lots.Container WHERE CurrentLocationId=80 AND ContainerStatusCodeId=1) AS VARCHAR)),
 (4,'Assembly Non-Serialized','DEV NAV: Asm NonSer (cell MA1-COMPBR-AOUT)', 'open 5G0-C container '+CAST((SELECT MAX(Id) FROM Lots.Container WHERE CurrentLocationId=47 AND ContainerStatusCodeId=1) AS VARCHAR)),
 (5,'Shipping Dock','ShippingLabel Id ->', (SELECT CAST(MAX(sl.Id) AS VARCHAR) FROM Lots.ShippingLabel sl JOIN Lots.Container c ON c.Id=sl.ContainerId JOIN Parts.Item i ON i.Id=c.ItemId WHERE i.PartNumber='6MA-HSG' AND sl.IsVoid=0)),
 (6,'Sort Cage','ContainerSerial Id ->', (SELECT CAST(cs.Id AS VARCHAR) FROM Lots.ContainerSerial cs JOIN Lots.SerializedPart sp ON sp.Id=cs.SerializedPartId WHERE sp.SerialNumber='SMK-SER-1')),
 (7,'Sort Cage','New Container Id (dest) ->', (SELECT CAST(MAX(c.Id) AS VARCHAR) FROM Lots.Container c JOIN Parts.Item i ON i.Id=c.ItemId WHERE i.PartNumber='5G0' AND c.ContainerStatusCodeId=1 AND c.CurrentLocationId=73)),
 (8,'Hold Mgmt - place','LOT name or Container Id ->','SMK-MIN-1  (or container '+CAST((SELECT MAX(Id) FROM Lots.Container WHERE CurrentLocationId=80 AND ContainerStatusCodeId=1) AS VARCHAR)+')'),
 (9,'Hold Mgmt - release','Hold Event Id ->', (SELECT CAST(he.Id AS VARCHAR) FROM Quality.HoldEvent he JOIN Lots.Lot l ON l.Id=he.LotId WHERE l.LotName='SMK-MIN-3' AND he.ReleasedAt IS NULL)),
 (10,'AIM Config / Tile','(no input)','thresholds 50/30/20/10; ~100 IDs/part')
) g(Seq,Screen,[Pick / Enter],[Use this]) ORDER BY Seq;
"@
sqlcmd -S localhost -d MPP_MES_Dev -E -C -W -Q $guide
Write-Host "Operator: actions auto-attribute to a dev user, or use the Initials popup with 'JD'." -ForegroundColor Cyan
Write-Host ""
Write-Host "*** RESTART THE IGNITION GATEWAY NOW ***" -ForegroundColor Yellow
Write-Host "This rebuilt the database, so the running gateway's DB connection is now stale" -ForegroundColor Yellow
Write-Host "(screens will show 'no data' until you restart). A project scan is NOT enough." -ForegroundColor Yellow
