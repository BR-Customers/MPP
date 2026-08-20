# ============================================================
# Update-Prod.ps1  --  forward-only update of an EXISTING database (NON-DESTRUCTIVE)
#
# Deploy-Prod.ps1 builds a NEW database and aborts if the target already exists.
# This is its counterpart: it updates a database that is already live, by applying
# only what is missing.
#
#   1. versioned migrations NOT already recorded in dbo.SchemaVersion, in numeric order
#   2. every repeatable R__*.sql (all are CREATE OR ALTER -- re-applying is the point)
#   3. seeds ONLY if -RunSeeds is passed (off by default -- see below)
#
# It never drops, never truncates, and never deletes. The only writes are the ones
# the migration and repeatable files themselves perform.
#
# WHY SEEDS ARE OFF BY DEFAULT
#   Seeds populate real plant configuration -- locations, items, routes, templates,
#   eligibility. On a FRESH deploy that is exactly right. On a LIVE database the
#   customer has since edited through the Config Tool, re-running them can reinstate
#   values an engineer deliberately changed. Most MPP seeds are written insert-if-missing
#   and would be inert, but "most" is not a guarantee worth taking against production.
#   Pass -RunSeeds only when you know a specific new seed needs to land, and prefer
#   running that one file by hand.
#
# ALWAYS PREVIEW FIRST
#   .\Update-Prod.ps1 -ServerInstance "SQLHOST\INSTANCE" -Preview
#   prints exactly which migrations would apply and touches nothing.
#
# Usage:
#   .\Update-Prod.ps1 -ServerInstance "SQLHOST\INSTANCE" -Preview
#   .\Update-Prod.ps1 -ServerInstance "SQLHOST\INSTANCE"
#   .\Update-Prod.ps1 -ServerInstance "SQLHOST\INSTANCE" -DatabaseName MPP_MES_Prod -RunSeeds
#
# AUTH: trusted (Windows) by default, same as Deploy-Prod. -Username/-Password for SQL auth.
#
# TAKE A BACKUP FIRST. This script asks for confirmation before it writes, but it
# cannot undo a migration. There is no down-migration story in this project.
# ============================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ServerInstance,
    [string]$DatabaseName = "MPP_MES_Prod",
    [string]$Username     = "",
    [string]$Password     = "",
    [switch]$Preview,
    [switch]$RunSeeds,
    [switch]$Force,           # skip the interactive confirmation (for scripted runs)
    [switch]$AllowOutOfOrder  # proceed even if a pending migration predates the applied high-water mark
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ($Username -ne "") {
    if ($Password -ne "") { $AuthArgs = @("-U", $Username, "-P", $Password) }
    else                  { $AuthArgs = @("-U", $Username) }
}
else { $AuthArgs = @("-E") }

$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$SqlRoot    = Split-Path -Parent $ScriptDir            # /sql
$Versioned  = Join-Path $SqlRoot "migrations\versioned"
$Repeatable = Join-Path $SqlRoot "migrations\repeatable"
$Seeds      = Join-Path $SqlRoot "seeds"

function Invoke-SqlFile {
    param([string]$FilePath, [string]$Database = $DatabaseName)
    $fileName = Split-Path -Leaf $FilePath
    Write-Host "  Running: $fileName" -ForegroundColor DarkGray
    $output = & sqlcmd -S $ServerInstance @AuthArgs -d $Database -i $FilePath -b -I -C 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  FAILED: $fileName" -ForegroundColor Red
        $output | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
        throw "sqlcmd failed on $fileName (exit code $LASTEXITCODE)"
    }
}

function Invoke-SqlQuery {
    param([string]$Query, [string]$Database = $DatabaseName)
    $output = & sqlcmd -S $ServerInstance @AuthArgs -d $Database -Q $Query -b -I -C -W -s "|" -h -1 2>&1
    if ($LASTEXITCODE -ne 0) {
        $output | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
        throw "sqlcmd query failed (exit code $LASTEXITCODE)"
    }
    return $output
}

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  PROD UPDATE (forward-only)  ->  $DatabaseName  on  $ServerInstance" -ForegroundColor Cyan
Write-Host "  Auth: $(if ($Username -ne '') { "SQL login '$Username'" } else { 'Windows (trusted)' })" -ForegroundColor Cyan
if ($Preview) { Write-Host "  MODE: PREVIEW -- nothing will be written." -ForegroundColor Yellow }
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

# ---- STEP 0: connectivity ----
Write-Host "[0/5] Verifying connection..." -ForegroundColor Cyan
$who = Invoke-SqlQuery -Database "master" -Query "SET NOCOUNT ON; SELECT CONCAT(SUSER_SNAME(), ' | sysadmin=', CONVERT(NVARCHAR(2), IS_SRVROLEMEMBER('sysadmin')));"
Write-Host "  Connected as: $($who | Where-Object { $_ -match '\S' } | Select-Object -First 1)" -ForegroundColor Green

# ---- SAFETY: the database MUST already exist (inverse of Deploy-Prod) ----
$exists = Invoke-SqlQuery -Database "master" -Query "SET NOCOUNT ON; SELECT CASE WHEN DB_ID(N'$DatabaseName') IS NULL THEN 'NO' ELSE 'YES' END;"
if (($exists | Where-Object { $_ -match 'YES|NO' } | Select-Object -First 1) -notmatch 'YES') {
    Write-Host ""
    Write-Host "ABORT: database '$DatabaseName' does not exist on $ServerInstance." -ForegroundColor Red
    Write-Host "  This script UPDATES an existing database. For a first install use Deploy-Prod.ps1." -ForegroundColor Yellow
    throw "Update-Prod: target database does not exist."
}

# ---- SAFETY: SchemaVersion must be present, or we cannot tell what is applied ----
$hasSv = Invoke-SqlQuery -Query "SET NOCOUNT ON; SELECT CASE WHEN OBJECT_ID(N'dbo.SchemaVersion') IS NULL THEN 'NO' ELSE 'YES' END;"
if (($hasSv | Where-Object { $_ -match 'YES|NO' } | Select-Object -First 1) -notmatch 'YES') {
    Write-Host ""
    Write-Host "ABORT: '$DatabaseName' has no dbo.SchemaVersion table." -ForegroundColor Red
    Write-Host "  Without it there is no way to know which migrations are already applied," -ForegroundColor Yellow
    Write-Host "  and re-running them blind against live data is not safe." -ForegroundColor Yellow
    throw "Update-Prod: dbo.SchemaVersion missing."
}

# ---- STEP 1: work out what is missing ----
Write-Host "[1/5] Comparing repo migrations against dbo.SchemaVersion..." -ForegroundColor Cyan

$applied = @{}
$rows = Invoke-SqlQuery -Query "SET NOCOUNT ON; SELECT MigrationId FROM dbo.SchemaVersion;"
foreach ($r in $rows) {
    $id = "$r".Trim()
    if ($id -ne "" -and $id -notmatch '^\(') { $applied[$id] = $true }
}

$allFiles = @(Get-ChildItem -Path $Versioned -Filter "*.sql" | Sort-Object Name)
if ($allFiles.Count -eq 0) { throw "No versioned migrations found in $Versioned" }

$pending = @()
foreach ($f in $allFiles) {
    $id = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
    if (-not $applied.ContainsKey($id)) { $pending += $f }
}

Write-Host "  Repo has $($allFiles.Count) migration(s); database reports $($applied.Count) applied." -ForegroundColor Gray

# Drift check: the database knows about migrations this checkout does not have.
# Usually means prod was updated from a different branch, or this checkout is stale.
$repoIds = @{}
foreach ($f in $allFiles) { $repoIds[[System.IO.Path]::GetFileNameWithoutExtension($f.Name)] = $true }
$orphans = @($applied.Keys | Where-Object { -not $repoIds.ContainsKey($_) } | Sort-Object)
if ($orphans.Count -gt 0) {
    Write-Host ""
    Write-Host "  WARNING: $($orphans.Count) migration(s) recorded in the database have no file in this checkout:" -ForegroundColor Yellow
    $orphans | ForEach-Object { Write-Host "    $_" -ForegroundColor Yellow }
    Write-Host "  The database may be ahead of this branch. Confirm you are deploying the right code." -ForegroundColor Yellow
}

Write-Host ""
if ($pending.Count -eq 0) {
    Write-Host "  No pending migrations -- schema is already current." -ForegroundColor Green
} else {
    Write-Host "  $($pending.Count) migration(s) PENDING:" -ForegroundColor Yellow
    $pending | ForEach-Object { Write-Host "    $($_.Name)" -ForegroundColor Yellow }
}
Write-Host ""

# ---- SAFETY: out-of-order pending migrations ----
# A pending migration numbered BELOW the highest already-applied one is not routine
# catch-up -- the database has already moved past that point, and a later migration may
# have deliberately superseded it. Observed for real on MPP_MES_Dev: 0019 (adds
# Location.CoupledDownstreamCellLocationId) had no SchemaVersion row while 0036 (which
# DROPS that column) had already run. Applying "all pending in numeric order" would have
# silently reinstated retired schema.
#
# So these halt the run. They almost always mean one of:
#   * a migration's file name does not match the MigrationId it INSERTs (so it never
#     records, and looks pending forever),
#   * a migration was renumbered after this database was built,
#   * the database was built from a different branch.
# Each needs a human decision -- usually "record it as applied without running it".
function Get-MigrationNumber { param([string]$id) if ($id -match '^(\d+)') { return [int]$Matches[1] } return -1 }

$maxApplied = 0
foreach ($id in $applied.Keys) {
    $n = Get-MigrationNumber $id
    if ($n -gt $maxApplied) { $maxApplied = $n }
}
$outOfOrder = @($pending | Where-Object { (Get-MigrationNumber $_.Name) -le $maxApplied })

if ($outOfOrder.Count -gt 0) {
    Write-Host "  OUT-OF-ORDER: $($outOfOrder.Count) pending migration(s) numbered at or below the" -ForegroundColor Red
    Write-Host "  highest already-applied migration ($maxApplied):" -ForegroundColor Red
    $outOfOrder | ForEach-Object { Write-Host "    $($_.Name)" -ForegroundColor Red }
    Write-Host ""
    Write-Host "  The database has already moved past these. A later migration may have" -ForegroundColor Yellow
    Write-Host "  superseded them -- running them now can reinstate retired schema." -ForegroundColor Yellow
    Write-Host "  Resolve each one before updating. To record one as applied WITHOUT running it:" -ForegroundColor Yellow
    Write-Host "    INSERT INTO dbo.SchemaVersion (MigrationId, Description)" -ForegroundColor Gray
    Write-Host "    VALUES (N'<file name without .sql>', N'Backfilled: superseded / already reflected.');" -ForegroundColor Gray
    Write-Host "  Or pass -AllowOutOfOrder if you have verified each one is genuinely safe to run." -ForegroundColor Yellow
    Write-Host ""
    if (-not $AllowOutOfOrder) {
        if ($Preview) {
            Write-Host "PREVIEW: an actual run would ABORT here." -ForegroundColor Red
        } else {
            throw "Update-Prod: out-of-order pending migrations; refusing to proceed."
        }
    } else {
        Write-Host "  -AllowOutOfOrder set -- proceeding anyway." -ForegroundColor Yellow
    }
}

$repeatables = @(Get-ChildItem -Path $Repeatable -Filter "R__*.sql" | Sort-Object Name)
Write-Host "  $($repeatables.Count) repeatable(s) will be re-applied (CREATE OR ALTER)." -ForegroundColor Gray
if ($RunSeeds) {
    $seedFiles = @(Get-ChildItem -Path $Seeds -Filter "*.sql" | Sort-Object Name)
    Write-Host "  $($seedFiles.Count) seed script(s) will run (-RunSeeds)." -ForegroundColor Yellow
} else {
    Write-Host "  Seeds SKIPPED (pass -RunSeeds to include them)." -ForegroundColor Gray
}

if ($Preview) {
    Write-Host ""
    Write-Host "PREVIEW complete -- nothing was written." -ForegroundColor Cyan
    Write-Host ""
    return
}

# ---- confirmation ----
if (-not $Force) {
    Write-Host ""
    Write-Host "  Target: $DatabaseName on $ServerInstance" -ForegroundColor White
    Write-Host "  Have you taken a backup? There is no down-migration path." -ForegroundColor Yellow
    $answer = Read-Host "  Type the database name to proceed"
    if ($answer -ne $DatabaseName) {
        Write-Host "  Aborted -- name did not match." -ForegroundColor Red
        return
    }
}

# ---- STEP 2: pending versioned migrations ----
Write-Host ""
Write-Host "[2/5] Applying pending migrations..." -ForegroundColor Cyan
if ($pending.Count -eq 0) {
    Write-Host "  Nothing to do." -ForegroundColor Gray
} else {
    foreach ($f in $pending) { Invoke-SqlFile -FilePath $f.FullName }
    Write-Host "  $($pending.Count) migration(s) applied." -ForegroundColor Green
}

# ---- STEP 3: repeatables ----
Write-Host "[3/5] Re-applying repeatable scripts..." -ForegroundColor Cyan
foreach ($f in $repeatables) { Invoke-SqlFile -FilePath $f.FullName }
Write-Host "  $($repeatables.Count) repeatable(s) applied." -ForegroundColor Green

# ---- STEP 4: seeds (opt-in only) ----
Write-Host "[4/5] Seeds..." -ForegroundColor Cyan
if ($RunSeeds) {
    foreach ($f in @(Get-ChildItem -Path $Seeds -Filter "*.sql" | Sort-Object Name)) { Invoke-SqlFile -FilePath $f.FullName }
    Write-Host "  Seed scripts loaded." -ForegroundColor Green
} else {
    Write-Host "  Skipped (default)." -ForegroundColor Gray
}

# ---- STEP 5: verify ----
Write-Host "[5/5] Verifying..." -ForegroundColor Cyan
$after = Invoke-SqlQuery -Query "SET NOCOUNT ON; SELECT CONCAT((SELECT COUNT(*) FROM dbo.SchemaVersion), ' migrations | ', (SELECT COUNT(*) FROM sys.procedures WHERE schema_id <> SCHEMA_ID('dbo')), ' procs | ', (SELECT COUNT(*) FROM sys.tables), ' tables');"
Write-Host "  $($after | Where-Object { $_ -match '\S' } | Select-Object -First 1)" -ForegroundColor Green

$stillPending = 0
$rows2 = Invoke-SqlQuery -Query "SET NOCOUNT ON; SELECT MigrationId FROM dbo.SchemaVersion;"
$applied2 = @{}
foreach ($r in $rows2) { $id = "$r".Trim(); if ($id -ne "" -and $id -notmatch '^\(') { $applied2[$id] = $true } }
foreach ($f in $allFiles) {
    if (-not $applied2.ContainsKey([System.IO.Path]::GetFileNameWithoutExtension($f.Name))) { $stillPending++ }
}
if ($stillPending -gt 0) {
    Write-Host "  WARNING: $stillPending migration(s) still not recorded in SchemaVersion." -ForegroundColor Yellow
    Write-Host "  A migration whose file name does not match the MigrationId it INSERTs will look" -ForegroundColor Yellow
    Write-Host "  pending forever and re-run on every update. Check the mismatched file." -ForegroundColor Yellow
} else {
    Write-Host "  All repo migrations are recorded." -ForegroundColor Green
}

Write-Host ""
Write-Host "PROD UPDATE COMPLETE  ->  $DatabaseName" -ForegroundColor Cyan
Write-Host "  Reminder: run scan.ps1 against the gateway so Ignition picks up any changed resources." -ForegroundColor Gray
Write-Host ""
