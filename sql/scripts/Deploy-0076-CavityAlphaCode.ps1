# ============================================================
# Deploy-0076-CavityAlphaCode.ps1 -- deployment of the per-part alphabetic
#                                    cavity code to a LIVE database.
#
# Spec: docs/superpowers/specs/2026-09-10-cavity-alpha-code-design.md
# Plan: docs/superpowers/plans/2026-09-10-cavity-alpha-code.md
#
# ============================================================
# READ THIS BEFORE RUNNING. THIS ONE IS NOT LIKE 0074.
# ============================================================
#   Deploy-0074-CounterAnchor could truthfully say "safe to run mid-shift"
#   because it was additive and behaviour-preserving. THIS IS NEITHER.
#
#   0076 DROPS TWO COLUMNS:
#       Tools.ToolCavity.CavityNumber   (the die-wide INT ordinal)
#       Lots.Lot.CavityNumber           (the D2 free-text manual-cavity note)
#
#   There is NO down-migration and the ordinal cannot be recovered from the
#   letter once cavities are added or deprecated. ROLLBACK IS RESTORE FROM
#   BACKUP. Take one, verify it, and know where it is before you start.
#
#   It also RETIRES the D2 fallback: after this, Lots.Lot_Create REJECTS a
#   die-cast-origin LOT that has no @ToolCavityId. There is no free-text
#   escape hatch any more.
#
# WHAT IT WRITES
#   1. migration 0076_toolcavity_alpha_code.sql   (skips itself if recorded)
#   2. 18 CREATE OR ALTER repeatables              (re-applying is the point)
#   No seeds. No deletes. No truncates. The only DROPs are the two columns
#   above, inside the migration, after its own guards pass.
#
# THE MIGRATION GUARDS ITSELF -- and one guard WILL fire on a mis-configured
# database, by design:
#   * a (Tool, Item) group larger than 26 aborts (there is no 27th letter)
#   * a FAMILY die (2+ distinct parts) that still has an UNMAPPED cavity
#     aborts, because that row falls into the NULL group alone and silently
#     shifts its peers' letters. Observed on prod 2026-09-10: DMO124 cavity 7
#     was Scrapped before migration 0072 and could not be mapped through the
#     UI, which would have mis-lettered cavities 8 and 9 of 12241-6MA.
#   An abort leaves the database untouched. Fix the mapping, re-run.
#
# ORDER OF OPERATIONS
#   SQL FIRST, then the Ignition resources. The renamed views and named
#   queries read columns this migration creates. Build the import archives
#   with:
#       .\tools\Build-ChangeExport.ps1 -Since 8c8a8f8c -Label cavity-alpha-code
#   and import Core FIRST (MPP and MPP_Config declare parent Core).
#
#   A gateway still serving the OLD views against the NEW schema shows blank
#   cavity fields on every die-cast screen. Keep the gap short.
#
# ALWAYS PREVIEW FIRST
#   .\Deploy-0076-CavityAlphaCode.ps1 -ServerInstance "SQLHOST" -Preview
#   runs every read-only pre-flight check and touches nothing.
#
# Usage:
#   .\Deploy-0076-CavityAlphaCode.ps1 -ServerInstance "SQLHOST" -Preview
#   .\Deploy-0076-CavityAlphaCode.ps1 -ServerInstance "SQLHOST" -Username Ignition -Password ***
#   .\Deploy-0076-CavityAlphaCode.ps1 -ServerInstance "SQLHOST" -Username Ignition
#       (prompts for the password, masked -- it does NOT hand sqlcmd a bare -U)
#   .\Deploy-0076-CavityAlphaCode.ps1 -ServerInstance "SQLHOST" -DatabaseName MPP_MES_Prod -Force
#
# AUTH: trusted (Windows) by default, matching Deploy-Prod / Update-Prod.
#       -Username / -Password for SQL auth.
# ============================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ServerInstance,
    [string]$DatabaseName = "MPP_MES_Prod",
    [string]$Username     = "",
    [string]$Password     = "",
    [switch]$Preview,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$SqlRoot    = Split-Path -Parent $ScriptDir
$Versioned  = Join-Path $SqlRoot "migrations\versioned"
$Repeatable = Join-Path $SqlRoot "migrations\repeatable"

$MigrationId   = "0076_toolcavity_alpha_code"
$MigrationFile = Join-Path $Versioned "$MigrationId.sql"

# Every repeatable the cavity rename touched. Order does not matter -- these
# are CREATE OR ALTER and have no interdependencies at deploy time -- but the
# extended-properties script runs LAST so it documents the final shape.
$RepeatableFiles = @(
    "R__Tools_ToolCavity_Create.sql",
    "R__Tools_ToolCavity_SaveAll.sql",
    "R__Tools_ToolCavity_ListByTool.sql",
    "R__Tools_ToolCavity_ListActiveByTool.sql",
    "R__Tools_Tool_Duplicate.sql",
    "R__Lots_Lot_Create.sql",
    "R__Lots_Lot_Get.sql",
    "R__Lots_Lot_GetLatestForToolCavity.sql",
    "R__Lots_Lot_GetOpenByTool.sql",
    "R__Lots_Lot_GetShiftCavityTally.sql",
    "R__Lots_Lot_GetTerminalRecentCreations.sql",
    "R__Lots_Lot_SearchAdvanced.sql",
    "R__Lots_DieCastLot_Open.sql",
    "R__Workorder_Assembly_CompleteTray.sql",
    "R__Workorder_MachiningOut_Mint.sql",
    "R__Workorder_DieCast_GetReleasePreview.sql",
    "R__Workorder_DieCast_GetShiftOutputBreakdown.sql",
    "R__Descriptions_ExtendedProperties.sql"
)

# ------------------------------------------------------------
# sqlcmd helpers
# ------------------------------------------------------------
# Built ONCE at script scope, matching Deploy-0074. A function returning this
# array does not splat reliably -- PowerShell unrolls the return value and
# sqlcmd sees a bare ' ' it cannot parse.
#
# PROMPT FOR A MISSING PASSWORD OURSELVES. Handing sqlcmd a -U with no -P makes
# IT prompt -- and every helper below captures output with `& sqlcmd ... 2>&1`,
# which swallows that prompt. The script then hangs on stdin the operator
# cannot see. PROJECT_STATUS records the same trap in Update-Prod.ps1; it is
# fixed here rather than inherited.
#
# -AsSecureString because the last prod deploy echoed this password in clear
# text and it still has not been rotated.
if ($Username -ne "") {
    if ($Password -eq "") {
        $secure   = Read-Host "  SQL password for '$Username'" -AsSecureString
        $bstr     = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try     { $Password = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
        if ($Password -eq "") { throw "No password entered for SQL login '$Username'." }
    }
    $AuthArgs = @("-U", $Username, "-P", $Password)
}
else { $AuthArgs = @("-E") }

function Invoke-SqlFile {
    param([string]$FilePath)
    $out = & sqlcmd -S $ServerInstance @AuthArgs -d $DatabaseName -i $FilePath -b -I -C 2>&1
    if ($LASTEXITCODE -ne 0) {
        $out | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
        throw "sqlcmd failed on $(Split-Path -Leaf $FilePath) (exit $LASTEXITCODE)"
    }
    $out | Where-Object { $_ -notmatch '^\s*$|^\(\d+ rows? affected\)|^Changed database context' } |
        ForEach-Object { Write-Host "    $_" }
}

function Invoke-SqlScalar {
    param([string]$Query)
    $out = & sqlcmd -S $ServerInstance @AuthArgs -d $DatabaseName -Q $Query -b -I -C -W -h -1 2>&1
    if ($LASTEXITCODE -ne 0) { throw "sqlcmd query failed: $out" }
    # Skip informational "Warning: ..." lines -- sqlcmd interleaves them with
    # results, and a warning must never be mistaken for the value.
    return ($out | Where-Object { $_ -notmatch '^\s*$' -and $_ -notmatch '^Warning:' } |
            Select-Object -First 1).ToString().Trim()
}

function Invoke-SqlTable {
    param([string]$Query)
    $out = & sqlcmd -S $ServerInstance @AuthArgs -d $DatabaseName -Q $Query -b -I -C -W -s "|" 2>&1
    if ($LASTEXITCODE -ne 0) { throw "sqlcmd query failed: $out" }
    return $out
}

Write-Host ""
Write-Host "====================================================" -ForegroundColor Cyan
Write-Host "  Cavity alpha code -- 0076" -ForegroundColor Cyan
Write-Host "  Server: $ServerInstance   DB: $DatabaseName" -ForegroundColor Cyan
if ($Preview) { Write-Host "  MODE:   PREVIEW (nothing will be written)" -ForegroundColor Yellow }
Write-Host "====================================================" -ForegroundColor Cyan
Write-Host ""

# ------------------------------------------------------------
# [1/6] Files present
# ------------------------------------------------------------
Write-Host "[1/6] Checking the change set is on disk..." -ForegroundColor Cyan
$missing = @()
if (-not (Test-Path $MigrationFile)) { $missing += $MigrationFile }
foreach ($f in $RepeatableFiles) {
    $p = Join-Path $Repeatable $f
    if (-not (Test-Path $p)) { $missing += $p }
}
if ($missing.Count -gt 0) {
    $missing | ForEach-Object { Write-Host "  MISSING: $_" -ForegroundColor Red }
    throw "Change set incomplete -- $($missing.Count) file(s) missing."
}
Write-Host ("  All {0} file(s) present." -f (1 + $RepeatableFiles.Count)) -ForegroundColor Green

# ------------------------------------------------------------
# [2/6] Prerequisite: 0072 must be applied
# ------------------------------------------------------------
Write-Host "[2/6] Checking prerequisites..." -ForegroundColor Cyan
$prereq = Invoke-SqlScalar "SET NOCOUNT ON; SELECT CAST(COUNT(*) AS NVARCHAR(2)) FROM dbo.SchemaVersion WHERE MigrationId = N'0072_toolcavity_itemid';"
if ($prereq -ne "1") {
    throw "Migration 0072_toolcavity_itemid is NOT applied to $DatabaseName. 0076 letters cavities PER PART, which requires the Tools.ToolCavity.ItemId map that 0072 creates. Deploy 0072 first."
}
Write-Host "  0072 (ToolCavity.ItemId) applied." -ForegroundColor Green

$already = Invoke-SqlScalar "SET NOCOUNT ON; SELECT CAST(COUNT(*) AS NVARCHAR(2)) FROM dbo.SchemaVersion WHERE MigrationId = N'$MigrationId';"
if ($already -eq "1") {
    Write-Host "  0076 is ALREADY recorded -- the migration file is skipped; repeatables still re-apply." -ForegroundColor DarkYellow
}

# ------------------------------------------------------------
# [3/6] THE GATE -- the same checks the migration will run, but read-only
#       and reported, so a failure is understood BEFORE anything is written.
# ------------------------------------------------------------
Write-Host "[3/6] Pre-flight (read-only)..." -ForegroundColor Cyan

$cav = Invoke-SqlScalar "SET NOCOUNT ON; SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Tools.ToolCavity WHERE DeprecatedAt IS NULL;"
Write-Host "  Active cavities: $cav"

$over26 = Invoke-SqlScalar @"
SET NOCOUNT ON;
SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM (
  SELECT ToolId FROM Tools.ToolCavity
  GROUP BY ToolId, ISNULL(ItemId,-1) HAVING COUNT(*) > 26) x;
"@
if ($over26 -ne "0") { throw "$over26 (Tool, Item) group(s) carry more than 26 cavities. There is no 27th letter -- the ItemId map is wrong. The migration would abort; fix the mapping first." }
Write-Host "  No (Tool, Item) group exceeds 26." -ForegroundColor Green

# The one that actually bites.
#
# GATE ON A NUMBER, NOT ON PARSED TEXT. An earlier version counted the rows
# sqlcmd printed -- and COUNT(DISTINCT ItemId) makes SQL Server emit
# "Warning: Null value is eliminated by an aggregate" whenever ANY cavity has
# a NULL ItemId, which every single-part die legitimately does. The warning
# line was counted as an offending die, so the gate false-fired on every
# database with a single-part die: MPP_MES_Dev, and prod. The decision is now
# a scalar; the table is printed only to name the offenders once we know
# there are some. ANSI_WARNINGS OFF keeps the warning out of both.
$familyGateSql = @"
SET NOCOUNT ON; SET ANSI_WARNINGS OFF;
SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM (
  SELECT tc.ToolId
  FROM Tools.ToolCavity tc
  WHERE tc.DeprecatedAt IS NULL
  GROUP BY tc.ToolId
  HAVING COUNT(DISTINCT tc.ItemId) >= 2
     AND SUM(CASE WHEN tc.ItemId IS NULL THEN 1 ELSE 0 END) > 0) x;
"@
$offenderCount = Invoke-SqlScalar $familyGateSql
if ($offenderCount -ne "0") {
    Write-Host ""
    Write-Host "  $offenderCount FAMILY DIE(S) WITH AN UNMAPPED CAVITY:" -ForegroundColor Red
    Invoke-SqlTable @"
SET NOCOUNT ON; SET ANSI_WARNINGS OFF;
SELECT t.Code AS Tool,
       COUNT(DISTINCT tc.ItemId) AS Parts,
       SUM(CASE WHEN tc.ItemId IS NULL THEN 1 ELSE 0 END) AS Unmapped
FROM Tools.ToolCavity tc
INNER JOIN Tools.Tool t ON t.Id = tc.ToolId
WHERE tc.DeprecatedAt IS NULL
GROUP BY t.Code
HAVING COUNT(DISTINCT tc.ItemId) >= 2
   AND SUM(CASE WHEN tc.ItemId IS NULL THEN 1 ELSE 0 END) > 0;
"@ | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
    Write-Host ""
    throw "An unmapped cavity on a family die falls into the NULL group alone and mis-letters its peers. Map every cavity to its part in the Tool Cavities editor, then re-run. (The migration itself aborts on this too -- this check just tells you sooner, and by name.)"
}
Write-Host "  Every family die is fully mapped." -ForegroundColor Green

# D6: dropping Lots.Lot.CavityNumber must not destroy data or strand a LOT.
$colExists = Invoke-SqlScalar "SET NOCOUNT ON; SELECT CAST(COUNT(*) AS NVARCHAR(2)) FROM sys.columns WHERE object_id = OBJECT_ID(N'Lots.Lot') AND name = N'CavityNumber';"
if ($colExists -eq "1") {
    $populated = Invoke-SqlScalar "SET NOCOUNT ON; SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Lots.Lot WHERE NULLIF(LTRIM(RTRIM(CavityNumber)), N'') IS NOT NULL;"
    if ($populated -ne "0") { throw "Lots.Lot.CavityNumber holds $populated non-empty value(s). The migration refuses to drop a populated column. Rename it to CavityNote instead (see the spec, section 6.3) and keep the D2 fallback." }
    Write-Host "  Lots.Lot.CavityNumber is empty -- safe to drop." -ForegroundColor Green
}
$stranded = Invoke-SqlScalar "SET NOCOUNT ON; SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Lots.Lot WHERE ToolId IS NOT NULL AND ToolCavityId IS NULL;"
if ($stranded -ne "0") {
    Write-Host "  WARNING: $stranded die-cast LOT(s) have a ToolId but no ToolCavityId." -ForegroundColor Yellow
    Write-Host "           They keep working, but after this deploy no NEW LOT can be" -ForegroundColor Yellow
    Write-Host "           created that way -- the D2 free-text fallback is retired." -ForegroundColor Yellow
}

# Show what the letters WILL be, so a human can eyeball them before the drop.
Write-Host ""
Write-Host "  Derived codes (letter is assigned per part, in ordinal order):" -ForegroundColor Cyan
if ($colExists -eq "1") {
    Invoke-SqlTable @"
SET NOCOUNT ON;
SELECT TOP 40 t.Code AS Tool, ISNULL(i.PartNumber,'(unmapped)') AS Part,
       tc.CavityNumber AS Ord, ISNULL(tc.Description,'') AS Descr,
       CHAR(96 + ROW_NUMBER() OVER (PARTITION BY tc.ToolId, ISNULL(tc.ItemId,-1)
                                    ORDER BY tc.CavityNumber, tc.Id)) AS Code
FROM Tools.ToolCavity tc
INNER JOIN Tools.Tool t ON t.Id = tc.ToolId
LEFT  JOIN Parts.Item i ON i.Id = tc.ItemId
WHERE tc.DeprecatedAt IS NULL
ORDER BY t.Code, i.PartNumber, tc.CavityNumber;
"@ | ForEach-Object { Write-Host "    $_" }
    Write-Host "    (first 40 rows; the migration prints an ADVISORY for any code that" -ForegroundColor DarkGray
    Write-Host "     disagrees with the letter already at the end of Description)" -ForegroundColor DarkGray
} else {
    Write-Host "    CavityNumber is already gone -- 0076 has run here." -ForegroundColor DarkGray
}

# ------------------------------------------------------------
# [4/6] Plan
# ------------------------------------------------------------
Write-Host ""
Write-Host "[4/6] Plan:" -ForegroundColor Cyan
if ($already -ne "1") { Write-Host "  + migration  $MigrationId.sql   (ADDS CavityCode, DROPS 2 columns)" -ForegroundColor Yellow }
else                  { Write-Host "  . migration  $MigrationId.sql   (already recorded -- self-skips)" -ForegroundColor DarkGray }
foreach ($f in $RepeatableFiles) { Write-Host "  ~ repeatable $f" }

if ($Preview) {
    Write-Host ""
    Write-Host "  PREVIEW -- nothing written. Re-run without -Preview to apply." -ForegroundColor Yellow
    Write-Host ""
    return
}

# ------------------------------------------------------------
# [5/6] Confirm, then apply
# ------------------------------------------------------------
if (-not $Force) {
    Write-Host ""
    Write-Host "  This DROPS Tools.ToolCavity.CavityNumber and Lots.Lot.CavityNumber." -ForegroundColor Red
    Write-Host "  There is no down-migration. Rollback is RESTORE FROM BACKUP." -ForegroundColor Red
    Write-Host ""
    $answer = Read-Host "  Type the database name ($DatabaseName) to proceed"
    if ($answer -ne $DatabaseName) { Write-Host "  Aborted." -ForegroundColor Yellow; return }
}

Write-Host ""
Write-Host "[5/6] Applying..." -ForegroundColor Cyan
# Only when pending. The migration's top-of-file RETURN exits its FIRST batch
# only; re-run after it is recorded, the later batches still execute and name
# the dropped CavityNumber column (Msg 207). It does not self-skip.
if ($already -ne "1") { Invoke-SqlFile $MigrationFile }
foreach ($f in $RepeatableFiles) {
    Write-Host "  ~ $f"
    Invoke-SqlFile (Join-Path $Repeatable $f)
}

# ------------------------------------------------------------
# [6/6] Verify against the live database
# ------------------------------------------------------------
Write-Host ""
Write-Host "[6/6] Verifying..." -ForegroundColor Cyan

function Assert-Equal {
    param([string]$Label, [string]$Expected, [string]$Actual)
    if ($Actual -eq $Expected) { Write-Host "  PASS  $Label" -ForegroundColor Green }
    else { Write-Host "  FAIL  $Label -- expected '$Expected', got '$Actual'" -ForegroundColor Red; $script:failed++ }
}
$failed = 0

Assert-Equal "0076 recorded in SchemaVersion" "1" (Invoke-SqlScalar "SET NOCOUNT ON; SELECT CAST(COUNT(*) AS NVARCHAR(2)) FROM dbo.SchemaVersion WHERE MigrationId = N'$MigrationId';")
Assert-Equal "Tools.ToolCavity.CavityCode exists" "1" (Invoke-SqlScalar "SET NOCOUNT ON; SELECT CAST(COUNT(*) AS NVARCHAR(2)) FROM sys.columns WHERE object_id = OBJECT_ID(N'Tools.ToolCavity') AND name = N'CavityCode';")
Assert-Equal "CavityCode is NOT NULL" "0" (Invoke-SqlScalar "SET NOCOUNT ON; SELECT CAST(is_nullable AS NVARCHAR(2)) FROM sys.columns WHERE object_id = OBJECT_ID(N'Tools.ToolCavity') AND name = N'CavityCode';")
Assert-Equal "Tools.ToolCavity.CavityNumber dropped" "0" (Invoke-SqlScalar "SET NOCOUNT ON; SELECT CAST(COUNT(*) AS NVARCHAR(2)) FROM sys.columns WHERE object_id = OBJECT_ID(N'Tools.ToolCavity') AND name = N'CavityNumber';")
Assert-Equal "Lots.Lot.CavityNumber dropped" "0" (Invoke-SqlScalar "SET NOCOUNT ON; SELECT CAST(COUNT(*) AS NVARCHAR(2)) FROM sys.columns WHERE object_id = OBJECT_ID(N'Lots.Lot') AND name = N'CavityNumber';")
Assert-Equal "UQ_ToolCavity_ActiveToolItemCode created" "1" (Invoke-SqlScalar "SET NOCOUNT ON; SELECT CAST(COUNT(*) AS NVARCHAR(2)) FROM sys.indexes WHERE object_id = OBJECT_ID(N'Tools.ToolCavity') AND name = N'UQ_ToolCavity_ActiveToolItemCode';")
Assert-Equal "old die-wide unique index gone" "0" (Invoke-SqlScalar "SET NOCOUNT ON; SELECT CAST(COUNT(*) AS NVARCHAR(2)) FROM sys.indexes WHERE object_id = OBJECT_ID(N'Tools.ToolCavity') AND name = N'UQ_ToolCavity_ActiveToolCavity';")
Assert-Equal "every cavity carries a code" "0" (Invoke-SqlScalar "SET NOCOUNT ON; SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Tools.ToolCavity WHERE CavityCode IS NULL OR CavityCode = N'';")
Assert-Equal "every (Tool, Item) group starts at 'a'" "0" (Invoke-SqlScalar @"
SET NOCOUNT ON;
SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM (
  SELECT ToolId FROM Tools.ToolCavity WHERE DeprecatedAt IS NULL
  GROUP BY ToolId, ISNULL(ItemId,-1) HAVING MIN(CavityCode) <> N'a') x;
"@)
Assert-Equal "all 18 procs compiled" "18" (Invoke-SqlScalar @"
SET NOCOUNT ON;
SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM sys.objects
WHERE name IN ('ToolCavity_Create','ToolCavity_SaveAll','ToolCavity_ListByTool',
               'ToolCavity_ListActiveByTool','Tool_Duplicate','Lot_Create','Lot_Get',
               'Lot_GetLatestForToolCavity','Lot_GetOpenByTool','Lot_GetShiftCavityTally',
               'Lot_GetTerminalRecentCreations','Lot_SearchAdvanced','DieCastLot_Open',
               'Assembly_CompleteTray','MachiningOut_Mint','DieCast_GetReleasePreview',
               'DieCast_GetShiftOutputBreakdown','ufn_CavityShotWatermark');
"@)

Write-Host ""
Write-Host "  Final cavity configuration:" -ForegroundColor Cyan
Invoke-SqlTable @"
SET NOCOUNT ON;
SELECT TOP 40 t.Code AS Tool, ISNULL(i.PartNumber,'(unmapped)') AS Part,
       tc.CavityCode AS Code, ISNULL(tc.Description,'') AS Descr
FROM Tools.ToolCavity tc
INNER JOIN Tools.Tool t ON t.Id = tc.ToolId
LEFT  JOIN Parts.Item i ON i.Id = tc.ItemId
WHERE tc.DeprecatedAt IS NULL
ORDER BY t.Code, i.PartNumber, tc.CavityCode;
"@ | ForEach-Object { Write-Host "    $_" }

Write-Host ""
if ($failed -gt 0) {
    Write-Host "  $failed verification(s) FAILED. Investigate before releasing the plant." -ForegroundColor Red
    exit 1
}
Write-Host "====================================================" -ForegroundColor Green
Write-Host "  0076 deployed and verified on $DatabaseName" -ForegroundColor Green
Write-Host "====================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  NEXT -- the Ignition side is a SEPARATE step and the plant needs it:" -ForegroundColor Yellow
Write-Host "    .\tools\Build-ChangeExport.ps1 -Since 8c8a8f8c -Label cavity-alpha-code" -ForegroundColor Yellow
Write-Host "    then import in the Designer, CORE FIRST." -ForegroundColor Yellow
Write-Host ""
Write-Host "  Until those land, the die-cast screens read a column that no longer" -ForegroundColor Yellow
Write-Host "  exists under its old name. Keep the gap short." -ForegroundColor Yellow
Write-Host ""
