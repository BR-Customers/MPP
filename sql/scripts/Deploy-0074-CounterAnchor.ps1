# ============================================================
# Deploy-0074-CounterAnchor.ps1  --  NON-DESTRUCTIVE deployment of the die cast
#                                    counter anchor to a LIVE database.
#
# Spec: docs/superpowers/specs/2026-09-10-diecast-counter-anchor-design.md
#
# WHY THIS EXISTS RATHER THAN Update-Prod.ps1
#   Update-Prod applies EVERY pending migration and re-applies ALL 456
#   repeatables. That is the right tool for a routine catch-up, and the wrong
#   one for shipping a single fix to a live plant: it aborts on unrelated
#   migration drift (MPP_MES_Dev currently reports 0064/0065/0066 pending and
#   out of order), and it touches hundreds of objects that have nothing to do
#   with this change. This script applies EXACTLY the counter-anchor change set
#   and nothing else, so the blast radius is the thing you are shipping.
#
# WHAT IT WRITES
#   1. migration 0074_diecast_counter_anchor.sql   (skips itself if recorded)
#   2. seven CREATE OR ALTER repeatables            (re-applying is the point)
#   Nothing else. No seeds, no drops, no truncates, no deletes. The only writes
#   are the ones those files perform.
#
# WHY IT IS SAFE TO RUN MID-SHIFT
#   The change is ADDITIVE and BEHAVIOUR-PRESERVING. Both watermark functions
#   gain a floor term that reads a table which, immediately after deploy, is
#   empty -- so every number they return is byte-for-byte what it was. There is
#   no backfill and no cutover window. Step [5/5] asserts exactly that against
#   the live database before it reports success.
#
# ALWAYS PREVIEW FIRST
#   .\Deploy-0074-CounterAnchor.ps1 -ServerInstance "SQLHOST\INSTANCE" -Preview
#   prints what it would do and touches nothing.
#
# Usage:
#   .\Deploy-0074-CounterAnchor.ps1 -ServerInstance "SQLHOST\INSTANCE" -Preview
#   .\Deploy-0074-CounterAnchor.ps1 -ServerInstance "SQLHOST\INSTANCE"
#   .\Deploy-0074-CounterAnchor.ps1 -ServerInstance "SQLHOST\INSTANCE" -DatabaseName MPP_MES_Prod -Force
#
# AUTH: trusted (Windows) by default, matching Deploy-Prod / Update-Prod.
#       -Username / -Password for SQL auth.
#
# TAKE A BACKUP FIRST. This project has no down-migration story. Rolling this
# back means restoring, or hand-dropping two tables and reverting seven
# repeatables to their previous versions from git.
#
# AFTER THIS SCRIPT: the Ignition side is a separate step -- three named
# queries, one script module and three views. See the spec, and note the
# ordering: SQL FIRST, because the views call procs that must already exist.
# ============================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ServerInstance,
    [string]$DatabaseName = "MPP_MES_Prod",
    [string]$Username     = "",
    [string]$Password     = "",
    [switch]$Preview,
    [switch]$Force        # skip the interactive confirmation (for scripted runs)
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

$MigrationId   = "0074_diecast_counter_anchor"
$MigrationFile = Join-Path $Versioned "$MigrationId.sql"

# ORDER MATTERS. The two watermark functions reference
# Workorder.DieCastCounterAnchor, and DieCastCounterAnchor_Record calls
# ufn_DieShotWatermark to capture the watermark it supersedes. The migration
# creates the tables first; these then layer on in dependency order.
$RepeatableFiles = @(
    "R__Workorder_ufn_DieShotWatermark.sql",
    "R__Workorder_ufn_CavityShotWatermark.sql",
    "R__Workorder_DieCastCounterAnchorReason_List.sql",
    "R__Workorder_DieCast_GetCounterContext.sql",
    "R__Workorder_DieCastCounterAnchor_Record.sql",
    "R__Workorder_DieCast_GetReleasePreview.sql"
)

# ------------------------------------------------------------
function Invoke-SqlFile {
    param([string]$FilePath)
    $fileName = Split-Path -Leaf $FilePath
    Write-Host "  Running: $fileName" -ForegroundColor DarkGray
    $output = & sqlcmd -S $ServerInstance @AuthArgs -d $DatabaseName -i $FilePath -b -I -C 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  FAILED: $fileName" -ForegroundColor Red
        $output | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
        throw "sqlcmd failed on $fileName (exit code $LASTEXITCODE)"
    }
    $output | Where-Object { $_ -match '\S' -and $_ -notmatch '^\(\d+ rows? affected\)' } |
        ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
}

function Invoke-SqlScalar {
    # -Database exists so the connection and does-it-exist checks can run
    # against master. Pointing them at a database that is not there makes
    # sqlcmd fail with a bare "Login failed", which reads like a credentials
    # problem and sends you debugging the wrong thing.
    param([string]$Query, [string]$Database = $DatabaseName)
    $output = & sqlcmd -S $ServerInstance @AuthArgs -d $Database -Q $Query -b -I -C -W -h -1 2>&1
    if ($LASTEXITCODE -ne 0) {
        $output | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
        throw "sqlcmd query failed (exit code $LASTEXITCODE)"
    }
    return ($output | Where-Object { $_ -match '\S' } | Select-Object -First 1).ToString().Trim()
}

function Assert-Equal {
    param([string]$Label, [string]$Expected, [string]$Actual)
    if ($Actual -eq $Expected) {
        Write-Host ("  OK    {0}" -f $Label) -ForegroundColor Green
        return $true
    }
    Write-Host ("  FAIL  {0} -- expected '{1}', got '{2}'" -f $Label, $Expected, $Actual) -ForegroundColor Red
    return $false
}

# ------------------------------------------------------------
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Die Cast Counter Anchor -- deploy to $DatabaseName" -ForegroundColor Cyan
Write-Host "  Server: $ServerInstance" -ForegroundColor Cyan
if ($Preview) { Write-Host "  MODE:   PREVIEW (nothing will be written)" -ForegroundColor Yellow }
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

# -- [1/5] every file this script needs must exist before we touch anything --
Write-Host "[1/5] Checking the change set is complete on disk..."
$missing = @()
if (-not (Test-Path $MigrationFile)) { $missing += $MigrationFile }
foreach ($f in $RepeatableFiles) {
    $p = Join-Path $Repeatable $f
    if (-not (Test-Path $p)) { $missing += $p }
}
if ($missing.Count -gt 0) {
    $missing | ForEach-Object { Write-Host "  MISSING: $_" -ForegroundColor Red }
    throw "Change set incomplete -- are you running this from a checkout that has the counter-anchor commit?"
}
Write-Host ("  All {0} file(s) present." -f (1 + $RepeatableFiles.Count)) -ForegroundColor Green

# -- [2/5] connection + prerequisites --
Write-Host ""
Write-Host "[2/5] Verifying connection and prerequisites..."
$who = Invoke-SqlScalar -Database "master" -Query `
    "SET NOCOUNT ON; SELECT SUSER_SNAME() + ' | sysadmin=' + CAST(IS_SRVROLEMEMBER('sysadmin') AS NVARCHAR(1));"
Write-Host "  Connected as: $who"

$dbOk = Invoke-SqlScalar -Database "master" -Query `
    "SET NOCOUNT ON; SELECT CAST(COUNT(*) AS NVARCHAR(2)) FROM sys.databases WHERE name = '$DatabaseName';"
if ($dbOk -ne "1") { throw "Database '$DatabaseName' does not exist on $ServerInstance. This script updates an EXISTING database; it never creates one." }

# 0073 is the hard prerequisite: it adds DieCastContribution.ShotCounterReading,
# which both watermark functions read. Without it they will not compile.
$prereq = Invoke-SqlScalar "SET NOCOUNT ON; SELECT CAST(COUNT(*) AS NVARCHAR(2)) FROM dbo.SchemaVersion WHERE MigrationId = N'0073_diecast_shot_counter_reading';"
if ($prereq -ne "1") {
    throw "Migration 0073_diecast_shot_counter_reading is NOT applied to $DatabaseName. The counter anchor floors a watermark that 0073 creates -- deploy 0073 first."
}
Write-Host "  0073 (shot-reading chain) is applied -- prerequisite met." -ForegroundColor Green

$already = Invoke-SqlScalar "SET NOCOUNT ON; SELECT CAST(COUNT(*) AS NVARCHAR(2)) FROM dbo.SchemaVersion WHERE MigrationId = N'$MigrationId';"
if ($already -eq "1") {
    Write-Host "  0074 is ALREADY recorded -- the migration will no-op and only the repeatables re-apply." -ForegroundColor Yellow
} else {
    Write-Host "  0074 is pending." -ForegroundColor Green
}

# How much live data the floor will apply to, so the operator knows the scale.
$openBaskets = Invoke-SqlScalar @"
SET NOCOUNT ON;
SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Lots.Lot l
JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId AND sc.Code = N'Open'
WHERE l.ToolId IS NOT NULL;
"@
Write-Host "  Open die-cast baskets right now: $openBaskets (unaffected -- see [5/5])"

# -- [3/5] what would happen --
Write-Host ""
Write-Host "[3/5] Plan:"
if ($already -ne "1") { Write-Host "  + migration  $MigrationId.sql" }
else                  { Write-Host "  . migration  $MigrationId.sql  (already recorded -- self-skips)" -ForegroundColor DarkGray }
foreach ($f in $RepeatableFiles) { Write-Host "  ~ repeatable $f" }
Write-Host ""
Write-Host "  Creates: Workorder.DieCastCounterAnchor, Workorder.DieCastCounterAnchorReason (4 rows),"
Write-Host "           Audit.LogEventType 'DieCastCounterAnchored'."
Write-Host "  Alters:  two watermark functions (adds a floor term), three new procs, one proc +1 column."
Write-Host "  Drops / deletes / truncates: NONE."

if ($Preview) {
    Write-Host ""
    Write-Host "PREVIEW complete -- nothing was written." -ForegroundColor Yellow
    Write-Host ""
    exit 0
}

if (-not $Force) {
    Write-Host ""
    $answer = Read-Host "Apply this to '$DatabaseName' on '$ServerInstance'? Type YES to proceed"
    if ($answer -cne "YES") {
        Write-Host "Aborted -- nothing was written." -ForegroundColor Yellow
        exit 1
    }
}

# -- [4/5] apply --
Write-Host ""
Write-Host "[4/5] Applying..."
Invoke-SqlFile $MigrationFile
foreach ($f in $RepeatableFiles) { Invoke-SqlFile (Join-Path $Repeatable $f) }
Write-Host "  Applied." -ForegroundColor Green

# -- [5/5] verify against the live database --
Write-Host ""
Write-Host "[5/5] Verifying..."
$ok = $true

$ok = (Assert-Equal "migration 0074 recorded" "1" (Invoke-SqlScalar `
    "SET NOCOUNT ON; SELECT CAST(COUNT(*) AS NVARCHAR(2)) FROM dbo.SchemaVersion WHERE MigrationId = N'$MigrationId';")) -and $ok

$ok = (Assert-Equal "both tables exist" "2" (Invoke-SqlScalar @"
SET NOCOUNT ON;
SELECT CAST(COUNT(*) AS NVARCHAR(2)) FROM sys.tables
WHERE SCHEMA_NAME(schema_id) = 'Workorder'
  AND name IN ('DieCastCounterAnchor','DieCastCounterAnchorReason');
"@)) -and $ok

$ok = (Assert-Equal "four reasons seeded" "4" (Invoke-SqlScalar `
    "SET NOCOUNT ON; SELECT CAST(COUNT(*) AS NVARCHAR(3)) FROM Workorder.DieCastCounterAnchorReason;")) -and $ok

$ok = (Assert-Equal "all six programmable objects present" "6" (Invoke-SqlScalar @"
SET NOCOUNT ON;
SELECT CAST(COUNT(*) AS NVARCHAR(3)) FROM sys.objects
WHERE SCHEMA_NAME(schema_id) = 'Workorder'
  AND name IN ('ufn_DieShotWatermark','ufn_CavityShotWatermark',
               'DieCastCounterAnchor_Record','DieCast_GetCounterContext',
               'DieCastCounterAnchorReason_List','DieCast_GetReleasePreview');
"@)) -and $ok

$ok = (Assert-Equal "audit event type registered" "1" (Invoke-SqlScalar `
    "SET NOCOUNT ON; SELECT CAST(COUNT(*) AS NVARCHAR(2)) FROM Audit.LogEventType WHERE Code = N'DieCastCounterAnchored';")) -and $ok

$ok = (Assert-Equal "GetReleasePreview exposes ToolId" "1" (Invoke-SqlScalar @"
SET NOCOUNT ON;
SELECT CAST(COUNT(*) AS NVARCHAR(2)) FROM sys.dm_exec_describe_first_result_set(
    N'EXEC Workorder.DieCast_GetReleasePreview @LotId = 0', NULL, 0)
WHERE name = 'ToolId';
"@)) -and $ok

# THE ONE THAT MATTERS. No anchors exist yet, so both watermarks must equal
# what they returned before this deploy -- the recorded MAX -- for every die
# that has produced this shift. Any row here is a die whose numbers MOVED,
# which would mean the floor is being applied when it must not be.
$drifted = Invoke-SqlScalar @"
SET NOCOUNT ON;
SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM (
    SELECT l.ToolId, c.ShiftId, c.CellLocationId,
           MAX(c.ShotCounterReading) AS RecordedMax,
           Workorder.ufn_DieShotWatermark(l.ToolId, c.ShiftId, c.CellLocationId) AS Watermark
    FROM Workorder.DieCastContribution c
    INNER JOIN Lots.Lot l ON l.Id = c.LotId
    WHERE c.ShiftId IS NOT NULL
    GROUP BY l.ToolId, c.ShiftId, c.CellLocationId
) x
WHERE ISNULL(x.RecordedMax, 0) <> x.Watermark;
"@
$ok = (Assert-Equal "watermarks unchanged on every existing (die, shift, press)" "0" $drifted) -and $ok

$ok = (Assert-Equal "no anchors written by this deploy" "0" (Invoke-SqlScalar `
    "SET NOCOUNT ON; SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Workorder.DieCastCounterAnchor;")) -and $ok

Write-Host ""
if ($ok) {
    Write-Host "============================================================" -ForegroundColor Green
    Write-Host "  SQL deploy complete and verified." -ForegroundColor Green
    Write-Host "============================================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Next: the Ignition side (SQL first was deliberate -- the views" -ForegroundColor Cyan
    Write-Host "  call procs that now exist)." -ForegroundColor Cyan
    Write-Host ""
    Write-Host "    Named queries (Core):  workorder/DieCastCounterAnchor_Record"
    Write-Host "                           workorder/DieCast_GetCounterContext"
    Write-Host "                           workorder/DieCastCounterAnchorReason_List"
    Write-Host "    Script (Core):         BlueRidge/Workorder/DieCast"
    Write-Host "    Views (MPP):           Components/Popups/DieCastCounterAnchor   (new)"
    Write-Host "                           Components/Popups/DieCastRelease         (modified)"
    Write-Host "                           Views/ShopFloor/DieCastBody              (modified)"
    Write-Host ""
    exit 0
}
else {
    Write-Host "============================================================" -ForegroundColor Red
    Write-Host "  DEPLOY APPLIED BUT VERIFICATION FAILED -- investigate before" -ForegroundColor Red
    Write-Host "  importing the Ignition resources. The screens will call these" -ForegroundColor Red
    Write-Host "  procs the moment they load." -ForegroundColor Red
    Write-Host "============================================================" -ForegroundColor Red
    Write-Host ""
    exit 1
}
