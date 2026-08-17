# ============================================================
# Deploy-Prod.ps1  --  fresh-server production deploy (NON-DESTRUCTIVE)
#
# Creates a NEW database and applies, in order:
#   versioned migrations (0001..NNNN)  ->  repeatable procs (R__*)  ->  seeds (real config)
# Does NOT drop anything. Aborts if the target database already exists.
# Loads NO demo data (demo lives in sql/scratch, which this script never touches).
#
# AUTH: defaults to a trusted (Windows) connection (-E) -- works on a server set to
#       "Windows Authentication mode only". Pass -Username/-Password to use SQL auth
#       instead (only works once the server is in Mixed Mode).
#
# Usage (from the machine that can reach the customer server):
#   .\Deploy-Prod.ps1 -ServerInstance "SQLHOST\INSTANCE"
#   .\Deploy-Prod.ps1 -ServerInstance "SQLHOST\INSTANCE" -MapIgnitionUser   # after the 'ignition' LOGIN exists
#
# The Ignition runtime login is provisioned SEPARATELY (needs Mixed Mode):
#   CREATE LOGIN [ignition] WITH PASSWORD = '<strong>', CHECK_POLICY = ON;
# then re-run with -MapIgnitionUser (or map it by hand). This script never stores a password.
# ============================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ServerInstance,
    [string]$DatabaseName = "MPP_MES_Prod",
    [string]$Username     = "",
    [string]$Password     = "",
    [switch]$MapIgnitionUser
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Auth args: SQL auth if a username was supplied, else explicit trusted (Windows) auth.
if ($Username -ne "") { $AuthArgs = @("-U", $Username, "-P", $Password) }
else                  { $AuthArgs = @("-E") }

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

function Invoke-Sql {
    param([string]$Query, [string]$Database = "master")
    $output = & sqlcmd -S $ServerInstance @AuthArgs -d $Database -Q $Query -b -I -C 2>&1
    if ($LASTEXITCODE -ne 0) {
        $output | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
        throw "sqlcmd failed (exit code $LASTEXITCODE)"
    }
    return $output
}

function Invoke-SqlQuery {
    param([string]$Query, [string]$Database = $DatabaseName)
    $output = & sqlcmd -S $ServerInstance @AuthArgs -d $Database -Q $Query -b -I -C -W -s "|" -h -1 2>&1
    if ($LASTEXITCODE -ne 0) { throw "sqlcmd query failed (exit code $LASTEXITCODE)" }
    return $output
}

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  PROD DEPLOY  ->  $DatabaseName  on  $ServerInstance" -ForegroundColor Cyan
Write-Host "  Auth: $(if ($Username -ne '') { "SQL login '$Username'" } else { 'Windows (trusted)' })" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

# ---- STEP 0: connectivity + who am I ----
Write-Host "[0/6] Verifying connection..." -ForegroundColor Cyan
$who = Invoke-SqlQuery -Database "master" -Query "SET NOCOUNT ON; SELECT CONCAT(SUSER_SNAME(), ' | sysadmin=', CONVERT(NVARCHAR(2), IS_SRVROLEMEMBER('sysadmin')), ' | WinAuthOnly=', CONVERT(NVARCHAR(10), SERVERPROPERTY('IsIntegratedSecurityOnly')));"
Write-Host "  Connected as: $($who | Where-Object { $_ -match '\S' } | Select-Object -First 1)" -ForegroundColor Green

# ---- SAFETY: refuse to touch an existing database ----
$exists = Invoke-SqlQuery -Database "master" -Query "SET NOCOUNT ON; SELECT CASE WHEN DB_ID(N'$DatabaseName') IS NULL THEN 'NO' ELSE 'YES' END;"
$dbExists = ($exists | Where-Object { $_ -match 'YES|NO' } | Select-Object -First 1)
if ($dbExists -match 'YES') {
    Write-Host ""
    Write-Host "ABORT: database '$DatabaseName' already exists on $ServerInstance." -ForegroundColor Red
    Write-Host "  This script is non-destructive and will not modify an existing database." -ForegroundColor Yellow
    Write-Host "  If this is a failed prior attempt, drop it first (manually) and re-run." -ForegroundColor Yellow
    throw "Deploy-Prod: target database already exists; refusing to proceed."
}

# ---- STEP 1: create the database ----
Write-Host "[1/6] Creating database '$DatabaseName'..." -ForegroundColor Cyan
Invoke-Sql -Query "CREATE DATABASE [$DatabaseName];"
Write-Host "  Created." -ForegroundColor Green

# ---- STEP 2: SchemaVersion tracking table ----
Write-Host "[2/6] Creating SchemaVersion table..." -ForegroundColor Cyan
Invoke-Sql -Database $DatabaseName -Query @"
CREATE TABLE dbo.SchemaVersion (
    Id           INT IDENTITY(1,1) PRIMARY KEY,
    MigrationId  NVARCHAR(200) NOT NULL,
    AppliedAt    DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    Description  NVARCHAR(MAX) NULL,
    CONSTRAINT UQ_SchemaVersion_MigrationId UNIQUE (MigrationId)
);
"@
Write-Host "  Created." -ForegroundColor Green

# ---- STEP 3: versioned migrations, in numeric order ----
Write-Host "[3/6] Running versioned migrations..." -ForegroundColor Cyan
$migrations = @(Get-ChildItem -Path $Versioned -Filter "*.sql" | Sort-Object Name)
if ($migrations.Count -eq 0) { throw "No versioned migrations found in $Versioned" }
foreach ($file in $migrations) { Invoke-SqlFile -FilePath $file.FullName }
Write-Host "  $($migrations.Count) migration(s) applied." -ForegroundColor Green

# ---- STEP 4: repeatable procedures ----
Write-Host "[4/6] Running repeatable scripts..." -ForegroundColor Cyan
$repeatables = @(Get-ChildItem -Path $Repeatable -Filter "R__*.sql" | Sort-Object Name)
foreach ($file in $repeatables) { Invoke-SqlFile -FilePath $file.FullName }
Write-Host "  $($repeatables.Count) repeatable(s) applied." -ForegroundColor Green

# ---- STEP 5: real config/plant seeds (NO demo) ----
Write-Host "[5/6] Running seed scripts (config + real plant, no demo)..." -ForegroundColor Cyan
$seeds = @(Get-ChildItem -Path $Seeds -Filter "*.sql" | Sort-Object Name)
foreach ($file in $seeds) { Invoke-SqlFile -FilePath $file.FullName }
Write-Host "  $($seeds.Count) seed script(s) loaded." -ForegroundColor Green

# ---- STEP 6: optionally map the Ignition runtime login (login must already exist) ----
Write-Host "[6/6] Ignition runtime user..." -ForegroundColor Cyan
if ($MapIgnitionUser) {
    $hasLogin = Invoke-SqlQuery -Database "master" -Query "SET NOCOUNT ON; SELECT CASE WHEN EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'ignition') THEN 'YES' ELSE 'NO' END;"
    if (($hasLogin | Where-Object { $_ -match 'YES|NO' } | Select-Object -First 1) -match 'YES') {
        Invoke-Sql -Database $DatabaseName -Query @"
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'ignition')
    CREATE USER [ignition] FOR LOGIN [ignition];
ALTER ROLE db_owner ADD MEMBER [ignition];
"@
        Write-Host "  Mapped 'ignition' login to db_owner on $DatabaseName." -ForegroundColor Green
    } else {
        Write-Host "  SKIPPED: no server login named 'ignition' exists yet." -ForegroundColor Yellow
        Write-Host "    Enable Mixed Mode, then:  CREATE LOGIN [ignition] WITH PASSWORD='<strong>', CHECK_POLICY=ON;" -ForegroundColor Yellow
        Write-Host "    then re-run:  .\Deploy-Prod.ps1 -ServerInstance '$ServerInstance' -DatabaseName '$DatabaseName' -MapIgnitionUser" -ForegroundColor Yellow
    }
} else {
    Write-Host "  Skipped (no -MapIgnitionUser). Provision the 'ignition' login + user before Ignition connects." -ForegroundColor DarkYellow
}

# ---- Verification summary ----
Write-Host ""
Write-Host "=== Deploy verification ===" -ForegroundColor Cyan
$summary = Invoke-SqlQuery -Query @"
SET NOCOUNT ON;
SELECT CONCAT('SchemaVersion rows (migrations applied): ', COUNT(*)) FROM dbo.SchemaVersion;
SELECT CONCAT('Locations total: ', COUNT(*)) FROM Location.Location;
SELECT CONCAT('  incl Offsite (OFFSITE/OS-*): ', COUNT(*)) FROM Location.Location WHERE Code = 'OFFSITE' OR Code LIKE 'OS-%';
SELECT CONCAT('Parts.Item: ', COUNT(*)) FROM Parts.Item;
SELECT CONCAT('ItemLocation eligibility rows: ', COUNT(*)) FROM Parts.ItemLocation;
"@
$summary | Where-Object { $_ -match '\S' } | ForEach-Object { Write-Host "  $_" -ForegroundColor Green }

Write-Host ""
Write-Host "DEPLOY COMPLETE: $DatabaseName on $ServerInstance" -ForegroundColor Green
Write-Host ""
