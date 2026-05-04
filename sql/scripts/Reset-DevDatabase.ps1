# ============================================================
# Reset-DevDatabase.ps1
# WARNING: Destroys and rebuilds the dev database from scratch.
# FOR DEV USE ONLY. Never run against staging or production.
#
# Usage:
#   .\Reset-DevDatabase.ps1                          # localhost, Windows auth
#   .\Reset-DevDatabase.ps1 -ServerInstance ".\SQL2022"
#   .\Reset-DevDatabase.ps1 -ServerInstance "server" -DatabaseName "MPP_MES_QA"
#
# Prerequisites:
#   - sqlcmd.exe (ships with SSMS or SQL Server)
#   - SQL Server running in Mixed Mode auth (SQL + Windows).
#     If not enabled, toggle via SSMS: Server Properties > Security.
#
# -------------------------- !! PROD !! ----------------------
# This script creates a SQL login named 'ignition' with password
# 'ignition' and grants it db_owner. THAT IS DEV-ONLY.
#
# For prod:
#   - Do NOT run this script. Prod DBs are not dropped/recreated.
#   - Provision the Ignition SQL login manually with a strong
#     managed password.
#   - Grant the minimum required permissions only:
#       EXECUTE on the application schemas (Location, Parts, ...),
#       SELECT/INSERT/UPDATE on tables the Named Queries hit
#       directly, no db_owner.
#   - Store the password in the Ignition Gateway datasource config,
#     not in any repo file.
# ============================================================

[CmdletBinding()]
param(
    [string]$ServerInstance = "localhost",
    [string]$DatabaseName  = "MPP_MES_Dev",
    [string]$Username      = "",
    [string]$Password      = ""
)

# Build SQL auth args if credentials were supplied
$AuthArgs = @()
if ($Username -ne "") {
    $AuthArgs = @("-U", $Username, "-P", $Password)
}

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── Resolve paths relative to this script ─────────────────────
$ScriptDir    = Split-Path -Parent $MyInvocation.MyCommand.Path
$SqlRoot      = Split-Path -Parent $ScriptDir   # /sql
$Versioned    = Join-Path $SqlRoot "migrations\versioned"
$Repeatable   = Join-Path $SqlRoot "migrations\repeatable"
$Seeds        = Join-Path $SqlRoot "seeds"

# ── Helper: run a .sql file via sqlcmd.exe ────────────────────
function Invoke-SqlFile {
    param(
        [string]$FilePath,
        [string]$Database = $DatabaseName
    )
    $fileName = Split-Path -Leaf $FilePath
    Write-Host "  Running: $fileName" -ForegroundColor DarkGray

    $output = & sqlcmd -S $ServerInstance @AuthArgs -d $Database -i $FilePath -b -I -C 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  FAILED: $fileName" -ForegroundColor Red
        $output | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
        throw "sqlcmd failed on $fileName (exit code $LASTEXITCODE)"
    }
}

# ── Helper: run inline SQL via sqlcmd.exe ─────────────────────
function Invoke-Sql {
    param(
        [string]$Query,
        [string]$Database = "master"
    )
    $output = & sqlcmd -S $ServerInstance @AuthArgs -d $Database -Q $Query -b -I -C 2>&1
    if ($LASTEXITCODE -ne 0) {
        $output | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
        throw "sqlcmd failed (exit code $LASTEXITCODE)"
    }
    return $output
}

# ── Helper: run inline SQL and return parsed table ────────────
function Invoke-SqlQuery {
    param(
        [string]$Query,
        [string]$Database = $DatabaseName
    )
    # -h -1 suppresses headers, -W trims whitespace
    $output = & sqlcmd -S $ServerInstance @AuthArgs -d $Database -Q $Query -b -I -C -W -s "|" 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "sqlcmd query failed (exit code $LASTEXITCODE)"
    }
    return $output
}

# ============================================================
# STEP 1: Drop and recreate the database
# ============================================================
Write-Host ""
Write-Host "========================================" -ForegroundColor Yellow
Write-Host "  Resetting $DatabaseName on $ServerInstance" -ForegroundColor Yellow
Write-Host "========================================" -ForegroundColor Yellow
Write-Host ""

Write-Host "[1/6] Dropping and recreating database..." -ForegroundColor Cyan
Invoke-Sql -Query @"
IF DB_ID(N'$DatabaseName') IS NOT NULL
BEGIN
    ALTER DATABASE [$DatabaseName] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE [$DatabaseName];
END
CREATE DATABASE [$DatabaseName];
"@

# ============================================================
# STEP 2: Create/map the 'ignition' dev login
# ------------------------------------------------------------
# DEV ONLY. Creates a SQL login 'ignition' with password 'ignition'
# (password policy disabled) and grants db_owner inside the new DB.
# DROP DATABASE destroys database-level users, so this mapping
# must be re-created on every reset.
#
# DO NOT REPLICATE THIS IN PROD. See the PROD notice at the top
# of this file for the correct prod provisioning posture.
# ============================================================
Write-Host "[2/6] Creating/mapping dev 'ignition' login..." -ForegroundColor Cyan

# Server-level: create the login once (survives DROP DATABASE).
Invoke-Sql -Query @"
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'ignition')
BEGIN
    CREATE LOGIN [ignition]
        WITH PASSWORD       = N'ignition',
             CHECK_POLICY   = OFF,
             CHECK_EXPIRATION = OFF;
END
"@

# Database-level: map the login and grant owner (wiped by DROP DATABASE).
# Sysadmin logins are auto-mapped to dbo — skip CREATE USER if already mapped.
Invoke-Sql -Database $DatabaseName -Query @"
IF NOT EXISTS (
    SELECT 1 FROM sys.database_principals dp
    JOIN sys.server_principals sp ON dp.sid = sp.sid
    WHERE sp.name = N'ignition'
)
BEGIN
    CREATE USER [ignition] FOR LOGIN [ignition];
    ALTER ROLE db_owner ADD MEMBER [ignition];
END
"@

# ============================================================
# STEP 3: Create SchemaVersion table
# ============================================================
Write-Host "[3/6] Creating SchemaVersion table..." -ForegroundColor Cyan
Invoke-Sql -Database $DatabaseName -Query @"
CREATE TABLE dbo.SchemaVersion (
    Id          INT IDENTITY(1,1)   NOT NULL PRIMARY KEY,
    MigrationId NVARCHAR(200)       NOT NULL,
    AppliedBy   NVARCHAR(100)       NOT NULL DEFAULT SYSTEM_USER,
    AppliedAt   DATETIME2(3)        NOT NULL DEFAULT GETUTCDATE(),
    Description NVARCHAR(500)       NULL,
    CONSTRAINT UQ_SchemaVersion_MigrationId UNIQUE (MigrationId)
);
"@

# ============================================================
# STEP 4: Run versioned migrations in numeric order
# ============================================================
Write-Host "[4/6] Running versioned migrations..." -ForegroundColor Cyan
$migrations = @(Get-ChildItem -Path $Versioned -Filter "*.sql" | Sort-Object Name)
if ($migrations.Count -eq 0) {
    Write-Host "  (no migrations found)" -ForegroundColor DarkYellow
} else {
    foreach ($file in $migrations) {
        Invoke-SqlFile -FilePath $file.FullName
    }
    Write-Host "  $($migrations.Count) migration(s) applied." -ForegroundColor Green
}

# ============================================================
# STEP 5: Run repeatable scripts (auto-discovered)
# ============================================================
Write-Host "[5/6] Running repeatable scripts..." -ForegroundColor Cyan
$repeatables = @(Get-ChildItem -Path $Repeatable -Filter "R__*.sql" | Sort-Object Name)
if ($repeatables.Count -eq 0) {
    Write-Host "  (no repeatables found)" -ForegroundColor DarkYellow
} else {
    foreach ($file in $repeatables) {
        Invoke-SqlFile -FilePath $file.FullName
    }
    Write-Host "  $($repeatables.Count) repeatable(s) deployed." -ForegroundColor Green
}

# ============================================================
# STEP 6: Run seed scripts (auto-discovered)
# ============================================================
Write-Host "[6/6] Running seed scripts..." -ForegroundColor Cyan
if (Test-Path $Seeds) {
    $seeds = @(Get-ChildItem -Path $Seeds -Filter "*.sql" | Sort-Object Name)
    if ($seeds.Count -eq 0) {
        Write-Host "  (no seed scripts found)" -ForegroundColor DarkYellow
    } else {
        foreach ($file in $seeds) {
            Invoke-SqlFile -FilePath $file.FullName
        }
        Write-Host "  $($seeds.Count) seed script(s) loaded." -ForegroundColor Green
    }
} else {
    Write-Host "  (seeds directory not found - skipping)" -ForegroundColor DarkYellow
}

# ============================================================
# VERIFY
# ============================================================
Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "  $DatabaseName rebuild complete." -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""

# Show applied migrations
Write-Host "Applied migrations:" -ForegroundColor Cyan
$migrationResult = Invoke-SqlQuery -Query "SELECT MigrationId, AppliedAt, Description FROM dbo.SchemaVersion ORDER BY AppliedAt;"
$migrationResult | ForEach-Object { Write-Host ('  ' + $_) }
Write-Host ""

# Show deployed procs
$procResult = & sqlcmd -S $ServerInstance @AuthArgs -d $DatabaseName -Q "SELECT COUNT(*) FROM sys.procedures WHERE schema_id != SCHEMA_ID('dbo');" -h -1 -W -b -C 2>&1
Write-Host "Stored procedures deployed: $($procResult[0].Trim())" -ForegroundColor Green

# Show table count
$tableResult = & sqlcmd -S $ServerInstance @AuthArgs -d $DatabaseName -Q "SELECT COUNT(*) FROM sys.tables;" -h -1 -W -b -C 2>&1
Write-Host "Tables created: $($tableResult[0].Trim())" -ForegroundColor Green
Write-Host ""
