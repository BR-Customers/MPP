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
Write-Host "Test environment ready. The phase5_7 'WHAT TO SMOKE' guide (IDs) printed above." -ForegroundColor Cyan
