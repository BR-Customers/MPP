# ============================================================
# Run-Tests.ps1
# Runs all MPP MES T-SQL test suites against the dev database.
#
# Usage:
#   .\Run-Tests.ps1                          # reset + run all
#   .\Run-Tests.ps1 -Filter "AppUser"        # only files matching AppUser
#   .\Run-Tests.ps1 -ServerInstance ".\SQL2022"
#   .\Run-Tests.ps1 -DatabaseName "MPP_MES_Dev" -Filter ""
#
# Prerequisites:
#   - sqlcmd.exe (ships with SSMS or SQL Server)
#   - Reset-DevDatabase.ps1 must be present in ../scripts/
# ============================================================

[CmdletBinding()]
param(
    # SAFETY: defaults to the THROWAWAY test DB. Run-Tests resets (DROPs) its target,
    # so it must NEVER default to MPP_MES_Dev (hand-built dev data, no backups).
    # Reset-DevDatabase additionally refuses to drop a *_Dev DB without -Force.
    [string]$ServerInstance = "localhost",
    [string]$DatabaseName   = "MPP_MES_Test",
    [string]$Filter         = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# -- Resolve paths relative to this script
$TestsDir    = Split-Path -Parent $MyInvocation.MyCommand.Path
$SqlRoot     = Split-Path -Parent $TestsDir
$ScriptsDir  = Join-Path $SqlRoot "scripts"
$HelpersDir  = Join-Path $TestsDir "helpers"
$ResetScript = Join-Path $ScriptsDir "Reset-DevDatabase.ps1"

# -- Noise-line filter: suppress sqlcmd informational output
$NoisePattern = '^\s*$|^\(\d+ rows? affected\)|^Changed database context|^Msg \d+, Level 0'

function Invoke-SqlFile {
    param(
        [string]$FilePath,
        [string]$Database = $DatabaseName
    )
    $output = & sqlcmd.exe -S $ServerInstance -d $Database -i $FilePath -b -I -C 2>&1
    if ($LASTEXITCODE -ne 0) {
        $output | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
        throw "sqlcmd failed on $(Split-Path -Leaf $FilePath) (exit $LASTEXITCODE)"
    }
    $output | Where-Object { $_ -notmatch $NoisePattern } | ForEach-Object {
        Write-Host "  $_"
    }
}

function Invoke-SqlQuery {
    param([string]$Query)
    $output = & sqlcmd.exe -S $ServerInstance -d $DatabaseName -Q $Query -b -I -C -W -s "|" -h -1 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "sqlcmd query failed (exit $LASTEXITCODE)"
    }
    return $output
}

# ============================================================
# STEP 1: Reset the database
# ============================================================
Write-Host ""
Write-Host "====================================================" -ForegroundColor Cyan
Write-Host "  MPP MES Test Runner" -ForegroundColor Cyan
Write-Host "  Server: $ServerInstance   DB: $DatabaseName" -ForegroundColor Cyan
Write-Host "====================================================" -ForegroundColor Cyan
Write-Host ""

Write-Host "[1/4] Resetting database..." -ForegroundColor Cyan
if (-not (Test-Path $ResetScript)) {
    Write-Host "  ERROR: Reset script not found at: $ResetScript" -ForegroundColor Red
    exit 1
}
try {
    & $ResetScript -ServerInstance $ServerInstance -DatabaseName $DatabaseName -SkipDemoSeed
} catch {
    Write-Host "  Database reset FAILED: $_" -ForegroundColor Red
    exit 1
}
Write-Host "  Database reset complete." -ForegroundColor Green
Write-Host ""

# ============================================================
# STEP 2: Deploy test framework helpers
# ============================================================
Write-Host "[2/4] Deploying test framework helpers..." -ForegroundColor Cyan
if (-not (Test-Path $HelpersDir)) {
    Write-Host "  ERROR: helpers/ directory not found at: $HelpersDir" -ForegroundColor Red
    exit 1
}
$helperFiles = @(Get-ChildItem -Path $HelpersDir -Filter "*.sql" | Sort-Object Name)
if ($helperFiles.Count -eq 0) {
    Write-Host "  WARNING: No helper .sql files found in $HelpersDir" -ForegroundColor Yellow
} else {
    foreach ($f in $helperFiles) {
        Write-Host "  Deploying: $($f.Name)" -ForegroundColor DarkGray
        Invoke-SqlFile -FilePath $f.FullName
    }
    Write-Host "  $($helperFiles.Count) helper(s) deployed." -ForegroundColor Green
}

# Clear any results from prior runs now that the permanent tables exist
Invoke-SqlQuery -Query "TRUNCATE TABLE test.TestResults; DELETE FROM test.CurrentTestFile;" | Out-Null
Write-Host ""

# ============================================================
# STEP 3: Discover and run test files
# ============================================================
Write-Host "[3/4] Discovering test files..." -ForegroundColor Cyan

# Test files live in numbered subdirectories: e.g. 0001_AppUser/
$testDirs = @(
    Get-ChildItem -Path $TestsDir -Directory |
    Where-Object { $_.Name -match '^\d+_' } |
    Sort-Object Name
)

$testFiles = @()
foreach ($dir in $testDirs) {
    $files = @(Get-ChildItem -Path $dir.FullName -Filter "*.sql" | Sort-Object Name)
    foreach ($f in $files) {
        if ($Filter -eq "" -or $f.Name -match [regex]::Escape($Filter) -or $dir.Name -match [regex]::Escape($Filter)) {
            $testFiles += $f
        }
    }
}

if ($testFiles.Count -eq 0) {
    if ($Filter -ne "") {
        Write-Host "  No test files found matching filter: '$Filter'" -ForegroundColor Yellow
    } else {
        Write-Host "  No test files found. Add numbered directories (e.g. 0001_AppUser/) with .sql test files." -ForegroundColor Yellow
    }
    Write-Host ""
    Write-Host "[4/4] Summary: 0 tests run." -ForegroundColor Cyan
    exit 0
}

Write-Host "  Found $($testFiles.Count) test file(s)." -ForegroundColor Green
Write-Host ""

$anyFailed = $false
foreach ($f in $testFiles) {
    Write-Host "  Running: $($f.Name)" -ForegroundColor DarkGray
    try {
        Invoke-SqlFile -FilePath $f.FullName
    } catch {
        Write-Host "  ERROR running $($f.Name): $_" -ForegroundColor Red
        $anyFailed = $true
    }
}
Write-Host ""

# ============================================================
# STEP 4: Query test.TestResults for final summary
# ============================================================
Write-Host "[4/4] Final summary..." -ForegroundColor Cyan

$tableCheck = Invoke-SqlQuery -Query "SELECT CASE WHEN OBJECT_ID('test.TestResults') IS NOT NULL THEN 1 ELSE 0 END;"
$tableExists = ($tableCheck | Where-Object { $_ -match '^\s*[01]\s*$' } | Select-Object -First 1)
if ($tableExists) { $tableExists = $tableExists.Trim() } else { $tableExists = "0" }

if ($tableExists -ne "1") {
    Write-Host "  test.TestResults not found -- no assertions were recorded." -ForegroundColor Yellow
    Write-Host ""
    if ($anyFailed) { exit 1 } else { exit 0 }
}

$summaryQuery = "SELECT COUNT(*) AS Total, ISNULL(SUM(CASE WHEN Passed = 1 THEN 1 ELSE 0 END), 0) AS Passed, ISNULL(SUM(CASE WHEN Passed = 0 THEN 1 ELSE 0 END), 0) AS Failed FROM test.TestResults;"
$summaryResult = Invoke-SqlQuery -Query $summaryQuery

$dataRow = $summaryResult | Where-Object { $_ -match '^\s*\d+' } | Select-Object -First 1
if ($dataRow) {
    $parts  = $dataRow.Trim() -split '\|'
    $total  = $parts[0].Trim()
    $passed = $parts[1].Trim()
    $failed = $parts[2].Trim()
} else {
    $total  = "0"
    $passed = "0"
    $failed = "0"
}

Write-Host ""
Write-Host "  +---------------------------------------+" -ForegroundColor Cyan
Write-Host ("  |  Total:  {0,-29}|" -f $total)  -ForegroundColor Cyan
if ([int]$passed -gt 0) {
    Write-Host ("  |  Passed: {0,-29}|" -f $passed) -ForegroundColor Green
} else {
    Write-Host ("  |  Passed: {0,-29}|" -f $passed) -ForegroundColor Cyan
}
if ([int]$failed -gt 0) {
    Write-Host ("  |  Failed: {0,-29}|" -f $failed) -ForegroundColor Red
} else {
    Write-Host ("  |  Failed: {0,-29}|" -f $failed) -ForegroundColor Cyan
}
Write-Host "  +---------------------------------------+" -ForegroundColor Cyan
Write-Host ""

if ([int]$failed -gt 0) {
    Write-Host "  Failing tests:" -ForegroundColor Red
    $failQuery = "SELECT TestFile, TestName, Detail FROM test.TestResults WHERE Passed = 0 ORDER BY Id;"
    $failRows = Invoke-SqlQuery -Query $failQuery
    $failRows | Where-Object { $_ -notmatch $NoisePattern -and $_.Trim() -ne "" } | ForEach-Object {
        Write-Host "    FAIL: $_" -ForegroundColor Red
    }
    Write-Host ""
}

if ([int]$failed -gt 0 -or $anyFailed) {
    Write-Host "  Test run FAILED." -ForegroundColor Red
    exit 1
} else {
    Write-Host "  Test run PASSED." -ForegroundColor Green
    exit 0
}
