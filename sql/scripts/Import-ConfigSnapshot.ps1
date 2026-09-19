# =============================================================================
# Import-ConfigSnapshot.ps1 -- REPLACE a local database's plant configuration
# with a snapshot taken by Export-ProdConfig.ps1, keeping the snapshot's Ids.
#
#   Purpose: make Dev carry prod's real configuration (locations, parts, routes,
#   BOMs, dies + cavities + mounts, defect / downtime codes, shifts, label
#   templates, code tables) for training material and realistic testing.
#
# Usage (from the repo root):
#   .\sql\scripts\Import-ConfigSnapshot.ps1 -SnapshotDir sql\scratch\_prod_config_20260918_1748
#       DRY RUN (default): every statement runs inside a transaction, the result
#       is verified, then ROLLED BACK. Nothing changes. Read the report.
#   .\sql\scripts\Import-ConfigSnapshot.ps1 -SnapshotDir ... -Commit
#       Takes a verified COPY_ONLY backup of the target first, then does the same
#       work and COMMITS if every check passes.
#
# WHAT HAPPENS TO THE TARGET, in one transaction:
#   REPLACED  every table in the snapshot except $KeepTables: all rows deleted,
#             the snapshot's rows inserted with their original Ids.
#   KEPT      Location.AppUser (Dev's users + PINs), dbo.SchemaVersion,
#             Lots.AimPoolConfig (Dev's AIM stays pointed nowhere, posting off),
#             Location.SessionPolicy, Lots.IdentifierSequence (Dev's counters).
#   WIPED     every transactional / log table in $WipeTables (LOTs, genealogy,
#             containers, events, downtime, shifts, audit logs): their rows point
#             at Dev's old config Ids and would be dangling or, worse, point at
#             the wrong thing. Lots.AimShipperIdPool keeps its UNCONSUMED rows
#             (Dev's fake AIM pool) and loses only the consumed ones.
#
#   User attribution: every AppUser column in a replaced table (CreatedByUserId,
#   UpdatedByUserId, ...) carries a PROD user Id. It is remapped to the Dev user
#   with the same AD account, else the same PIN, else SYS (AppUser 1).
#
#   Foreign keys: kept code tables point INTO replaced tables (Tools.ToolType ->
#   LocationTypeDefinition, PlcDeviceType -> ClosureMethodCode), so there is no
#   safe delete order. Every FK in the database is disabled inside the
#   transaction and re-enabled WITH CHECK before commit, which re-validates every
#   row: one dangling reference anywhere fails the load and rolls it all back.
#   The script refuses to start unless every FK is enabled and trusted now, so it
#   restores exactly the state it found.
#
#   Identity seeds of replaced tables are reset to MAX(Id), so new rows made in
#   Dev continue after prod's Ids.
#
# This is a bulk replace, NOT a proc-driven change: no Audit.ConfigLog rows are
# written, and procs cannot insert rows with chosen Ids. That is deliberate for a
# Dev refresh. Never point this at a plant database -- it refuses to.
#
# Gates (refuse to start): target not a local server or named like *Prod*;
# target's migration level differs from the snapshot's; any snapshot table's
# column list differs from the target's; a target table that is in no list
# (unclassified); a binary column in a replaced table; any FK disabled or
# untrusted.
#
# Afterwards: run .\scan.ps1 so the gateway drops cached query results, and
# reload open Perspective sessions.
# =============================================================================
param(
    [Parameter(Mandatory = $true)]
    [string]$SnapshotDir,
    [string]$ServerInstance = "localhost",
    [string]$DatabaseName   = "MPP_MES_Dev",
    [switch]$Commit
)

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

# ---- Classification ---------------------------------------------------------
$KeepTables = @(
    'Location.AppUser', 'dbo.SchemaVersion', 'Lots.AimPoolConfig',
    'Location.SessionPolicy', 'Lots.IdentifierSequence'
)

# Transactional / log tables emptied in the target. Must cover every table that
# references a replaced table and is not itself replaced.
$WipeTables = @(
    'Audit.ConfigLog', 'Audit.FailureLog', 'Audit.InterfaceLog', 'Audit.OperationLog',
    'Lots.AimShipperIdPool', 'Lots.Container', 'Lots.ContainerSerial', 'Lots.ContainerSerialHistory',
    'Lots.ContainerTray', 'Lots.Lot', 'Lots.LotAttributeChange', 'Lots.LotEventLog',
    'Lots.LotGenealogy', 'Lots.LotGenealogyClosure', 'Lots.LotLabel', 'Lots.LotMovement',
    'Lots.LotStatusHistory', 'Lots.PauseEvent', 'Lots.SerializedPart', 'Lots.ShippingLabel',
    'Oee.DowntimeEvent', 'Oee.Shift', 'Oee.ShiftOverride',
    'Quality.HoldEvent', 'Quality.QualityAttachment', 'Quality.QualityResult', 'Quality.QualitySample',
    'Workorder.ConsumptionEvent', 'Workorder.DieCastContribution', 'Workorder.DieCastCounterAnchor',
    'Workorder.ProductionEvent', 'Workorder.ProductionEventValue', 'Workorder.RejectEvent',
    'Workorder.WorkOrder', 'Workorder.WorkOrderOperation'
)
# Wipe filters: only these rows are deleted (default: all rows).
$WipeWhere = @{
    'Lots.AimShipperIdPool' = 'ConsumedByContainerId IS NOT NULL OR ConsumedAt IS NOT NULL'
}
$IgnoredSchemas = @('test')

# ---- Output -----------------------------------------------------------------
$report = New-Object System.Collections.Generic.List[string]
function Say([string]$text, [string]$color = "Gray") {
    Write-Host $text -ForegroundColor $color
    $report.Add($text)
}
function Fail([string]$text) {
    Say ""; Say "  REFUSING: $text" "Red"; Say ""
    exit 2
}

# ---- Target guards ----------------------------------------------------------
$localNames = @('localhost', '.', '(local)', '127.0.0.1', $env:COMPUTERNAME)
$serverHost = ($ServerInstance -split '\\')[0]
if ($localNames -notcontains $serverHost) { Fail "target server '$ServerInstance' is not this machine. This script only loads a LOCAL database." }
if ($DatabaseName -like '*Prod*')         { Fail "target database '$DatabaseName' looks like production." }

$SnapshotDir = (Resolve-Path $SnapshotDir).Path
$manifestPath = Join-Path $SnapshotDir "_manifest.json"
$schemaPath   = Join-Path $SnapshotDir "_schema.json"
if (-not (Test-Path $manifestPath) -or -not (Test-Path $schemaPath)) { Fail "no _manifest.json / _schema.json in $SnapshotDir -- not an Export-ProdConfig snapshot." }
$manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json

# Snapshot tables = the data files present (a file deleted by hand is not loaded).
$snapshotTables = @(Get-ChildItem $SnapshotDir -Filter "*.json" |
    Where-Object { $_.Name -notlike "_*" } |
    ForEach-Object { $_.BaseName } | Sort-Object)

# ---- Connect ----------------------------------------------------------------
$csb = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
$csb["Data Source"]            = $ServerInstance
$csb["Initial Catalog"]        = $DatabaseName
$csb["Integrated Security"]    = $true
$csb["Application Name"]       = "MPP Import-ConfigSnapshot"
$csb["Encrypt"]                = $true
$csb["TrustServerCertificate"] = $true
$conn = New-Object System.Data.SqlClient.SqlConnection $csb.ConnectionString
$conn.Open()
$tx = $null

function Q([string]$sql, [hashtable]$params = @{}) {
    $cmd = $conn.CreateCommand()
    $cmd.CommandText = $sql; $cmd.CommandTimeout = 900
    if ($tx) { $cmd.Transaction = $tx }
    foreach ($k in $params.Keys) {
        $p = $cmd.Parameters.Add("@$k", [System.Data.SqlDbType]::NVarChar, -1); $p.Value = $params[$k]
    }
    $dt = New-Object System.Data.DataTable
    $da = New-Object System.Data.SqlClient.SqlDataAdapter $cmd
    [void]$da.Fill($dt)
    , $dt
}
function X([string]$sql, [hashtable]$params = @{}) {
    $cmd = $conn.CreateCommand()
    $cmd.CommandText = $sql; $cmd.CommandTimeout = 900
    if ($tx) { $cmd.Transaction = $tx }
    foreach ($k in $params.Keys) {
        $p = $cmd.Parameters.Add("@$k", [System.Data.SqlDbType]::NVarChar, -1); $p.Value = $params[$k]
    }
    $cmd.ExecuteNonQuery()
}
function QI([string]$name) { '[' + $name.Replace(']', ']]') + ']' }
function FullName([string]$t) { $s, $n = $t -split '\.', 2; "$(QI $s).$(QI $n)" }

$mode = if ($Commit) { "COMMIT" } else { "DRY RUN (rolled back)" }
Say ""
Say "  Config snapshot import  ->  $DatabaseName on $ServerInstance   [$mode]" "Cyan"
Say "  Snapshot: $SnapshotDir" "DarkGray"
Say "  Source  : $($manifest.database) on $($manifest.sourceServer), captured $($manifest.capturedAtUtc) UTC" "DarkGray"
Say ""

try {
    # ---- Gates --------------------------------------------------------------
    $targetMig = (Q "SELECT MAX(MigrationId) AS M FROM dbo.SchemaVersion").Rows[0].M
    $snapMig   = $manifest.latestMigration.MigrationId
    if ("$targetMig" -ne "$snapMig") { Fail "migration level differs: target '$targetMig', snapshot '$snapMig'. Bring them level first." }
    Say "  Migration level: $targetMig (matches snapshot)"

    $badFk = (Q "SELECT COUNT(*) AS N FROM sys.foreign_keys WHERE is_disabled = 1 OR is_not_trusted = 1").Rows[0].N
    if ($badFk -gt 0) { Fail "$badFk foreign key(s) are already disabled or untrusted. This script re-enables every FK WITH CHECK and would change that state." }

    $targetTables = @((Q @"
SELECT s.name + '.' + t.name AS T FROM sys.tables t JOIN sys.schemas s ON s.schema_id = t.schema_id
WHERE t.is_ms_shipped = 0 ORDER BY 1
"@).Rows | ForEach-Object { $_.T })

    $replace = @($snapshotTables | Where-Object { $KeepTables -notcontains $_ })
    $missing = @($snapshotTables | Where-Object { $targetTables -notcontains $_ })
    if ($missing.Count) { Fail "snapshot tables missing from target: $($missing -join ', ')" }
    $unclassified = @($targetTables | Where-Object {
        $IgnoredSchemas -notcontains ($_ -split '\.')[0] -and
        $snapshotTables -notcontains $_ -and $KeepTables -notcontains $_ -and $WipeTables -notcontains $_ })
    if ($unclassified.Count) { Fail "target tables in no list (replace / keep / wipe): $($unclassified -join ', '). Classify them in this script." }
    $wipe = @($WipeTables | Where-Object { $targetTables -contains $_ })

    # Column lists: the snapshot's must equal the target's, in order.
    $snapSchema = Get-Content $schemaPath -Raw | ConvertFrom-Json
    $tcols = Q @"
SELECT s.name + '.' + t.name AS T, c.column_id AS Ord, c.name AS Col, TYPE_NAME(c.user_type_id) AS Ty,
       c.max_length AS Len, c.precision AS Prec, c.scale AS Scale, c.is_identity AS IsId, c.is_computed AS IsComp
FROM sys.columns c JOIN sys.tables t ON t.object_id = c.object_id JOIN sys.schemas s ON s.schema_id = t.schema_id
WHERE t.is_ms_shipped = 0 ORDER BY 1, 2
"@
    $colsByTable = @{}
    foreach ($r in $tcols.Rows) {
        if (-not $colsByTable.ContainsKey($r.T)) { $colsByTable[$r.T] = New-Object System.Collections.Generic.List[object] }
        $colsByTable[$r.T].Add($r)
    }
    foreach ($t in $replace) {
        $snapCols = @($snapSchema.tables.$t | ForEach-Object { $_.name }) -join ','
        $tgtCols  = @($colsByTable[$t] | ForEach-Object { $_.Col }) -join ','
        if ($snapCols -ne $tgtCols) { Fail "column list of $t differs.`n    snapshot: $snapCols`n    target  : $tgtCols" }
        $bin = @($colsByTable[$t] | Where-Object { @('varbinary', 'binary', 'image', 'timestamp', 'rowversion') -contains $_.Ty })
        if ($bin.Count) { Fail "$t has a binary column ($($bin[0].Col)); this loader does not decode base64." }
    }
    Say "  Gates passed: $($replace.Count) tables to replace, $($wipe.Count) to wipe, $($KeepTables.Count) kept."

    # AppUser FK columns per table (remapped on insert).
    $userFk = @{}
    foreach ($r in (Q @"
SELECT OBJECT_SCHEMA_NAME(fk.parent_object_id) + '.' + OBJECT_NAME(fk.parent_object_id) AS T, pc.name AS Col
FROM sys.foreign_keys fk
JOIN sys.foreign_key_columns fkc ON fkc.constraint_object_id = fk.object_id
JOIN sys.columns pc ON pc.object_id = fkc.parent_object_id AND pc.column_id = fkc.parent_column_id
WHERE fk.referenced_object_id = OBJECT_ID(N'Location.AppUser')
"@).Rows) {
        if (-not $userFk.ContainsKey($r.T)) { $userFk[$r.T] = @() }
        $userFk[$r.T] += $r.Col
    }

    # ---- Backup (commit only, before anything changes) ----------------------
    if ($Commit) {
        $bakDir  = (Q "SELECT CAST(SERVERPROPERTY('InstanceDefaultBackupPath') AS NVARCHAR(4000)) AS P").Rows[0].P
        $bakFile = Join-Path $bakDir ("{0}_pre-config-import_{1}.bak" -f $DatabaseName, (Get-Date -Format "yyyyMMdd_HHmmss"))
        Say ""
        Say "  Backing up $DatabaseName (COPY_ONLY) -> $bakFile" "Cyan"
        [void](X "BACKUP DATABASE $(QI $DatabaseName) TO DISK = @p WITH COPY_ONLY, CHECKSUM, INIT" @{ p = $bakFile })
        [void](X "RESTORE VERIFYONLY FROM DISK = @p WITH CHECKSUM" @{ p = $bakFile })
        Say "  Backup verified." "Green"
    }

    # ---- The load -----------------------------------------------------------
    [void](X "SET XACT_ABORT ON; SET ARITHABORT ON; SET QUOTED_IDENTIFIER ON; SET ANSI_NULLS ON;")
    $tx = $conn.BeginTransaction("ConfigImport")
    $sw = [Diagnostics.Stopwatch]::StartNew()

    # User map: prod AppUser Id -> Dev AppUser Id (AD account, else PIN, else SYS).
    $prodUsersJson = [IO.File]::ReadAllText((Join-Path $SnapshotDir "Location.AppUser.json"))
    # Created in its own parameterless batch: a #table made inside a parameterized
    # (sp_executesql) call is dropped when that call returns.
    [void](X "CREATE TABLE #UserMap (ProdId BIGINT PRIMARY KEY, DevId BIGINT NOT NULL, MatchedBy NVARCHAR(10) NOT NULL);")
    [void](X @"
INSERT INTO #UserMap (ProdId, DevId, MatchedBy)
SELECT p.Id,
       COALESCE(ad.Id, pin.Id, 1),
       CASE WHEN ad.Id IS NOT NULL THEN N'AdAccount' WHEN pin.Id IS NOT NULL THEN N'Pin' ELSE N'SYS' END
FROM OPENJSON(@j) WITH (Id BIGINT '$.Id', AdAccount NVARCHAR(200) '$.AdAccount', Pin NVARCHAR(5) '$.Pin') p
OUTER APPLY (SELECT TOP (1) u.Id FROM Location.AppUser u
             WHERE p.AdAccount IS NOT NULL AND LTRIM(RTRIM(p.AdAccount)) <> N''
               AND u.AdAccount = p.AdAccount ORDER BY u.DeprecatedAt, u.Id) ad
OUTER APPLY (SELECT TOP (1) u.Id FROM Location.AppUser u
             WHERE p.Pin IS NOT NULL AND u.Pin = p.Pin ORDER BY u.DeprecatedAt, u.Id) pin;
"@ @{ j = $prodUsersJson })
    $um = (Q "SELECT MatchedBy, COUNT(*) AS N FROM #UserMap GROUP BY MatchedBy ORDER BY MatchedBy").Rows
    Say ""
    Say ("  Prod users mapped to Dev users: " + (($um | ForEach-Object { "$($_.MatchedBy) $($_.N)" }) -join ', '))

    # Disable every FK (re-enabled WITH CHECK below).
    $allFks = (Q @"
SELECT QUOTENAME(OBJECT_SCHEMA_NAME(parent_object_id)) + '.' + QUOTENAME(OBJECT_NAME(parent_object_id)) AS T, QUOTENAME(name) AS F
FROM sys.foreign_keys
"@).Rows
    foreach ($fk in $allFks) { [void](X "ALTER TABLE $($fk.T) NOCHECK CONSTRAINT $($fk.F);") }
    Say "  $($allFks.Count) foreign keys disabled for the load."

    # Wipe.
    Say ""
    Say "  Wiped (transactional):" "Cyan"
    foreach ($t in $wipe) {
        $where = if ($WipeWhere.ContainsKey($t)) { " WHERE $($WipeWhere[$t])" } else { "" }
        $n = X "DELETE FROM $(FullName $t)$where;"
        if ($n -gt 0) { Say ("    {0,-42} {1,7} rows deleted{2}" -f $t, $n, $(if ($where) { "  ($($WipeWhere[$t]))" } else { "" })) }
    }

    # Replace.
    Say ""
    Say "  Replaced (config):" "Cyan"
    $expected = @{}
    foreach ($t in $replace) {
        $cols     = @($colsByTable[$t] | Where-Object { -not $_.IsComp })
        $hasId    = @($cols | Where-Object { $_.IsId }).Count -gt 0
        $uCols    = if ($userFk.ContainsKey($t)) { $userFk[$t] } else { @() }
        $json     = [IO.File]::ReadAllText((Join-Path $SnapshotDir "$t.json"))

        $withList = ($cols | ForEach-Object {
            $col = $_
            $ty = if (@('nvarchar', 'nchar') -contains $col.Ty) { if ($col.Len -eq -1) { "$($col.Ty)(max)" } else { "$($col.Ty)($([int]($col.Len / 2)))" } }
                  elseif (@('varchar', 'char') -contains $col.Ty) { if ($col.Len -eq -1) { "$($col.Ty)(max)" } else { "$($col.Ty)($($col.Len))" } }
                  elseif (@('decimal', 'numeric') -contains $col.Ty) { "$($col.Ty)($($col.Prec),$($col.Scale))" }
                  elseif (@('datetime2', 'time', 'datetimeoffset') -contains $col.Ty) { "$($col.Ty)($($col.Scale))" }
                  else { $col.Ty }
            "$(QI $col.Col) $ty '$." + $col.Col.Replace("'", "''") + "'"
        }) -join ", "
        $insList = ($cols | ForEach-Object { QI $_.Col }) -join ", "
        $selList = ($cols | ForEach-Object {
            $c = QI $_.Col
            if ($uCols -contains $_.Col) { "CASE WHEN j.$c IS NULL THEN NULL ELSE ISNULL((SELECT m.DevId FROM #UserMap m WHERE m.ProdId = j.$c), 1) END" }
            else { "j.$c" }
        }) -join ", "

        $fn = FullName $t
        $sql = "DELETE FROM $fn;`n"
        if ($hasId) { $sql += "SET IDENTITY_INSERT $fn ON;`n" }
        $sql += "INSERT INTO $fn ($insList)`nSELECT $selList FROM OPENJSON(@j) WITH ($withList) j;`n"
        if ($hasId) {
            $sql += "SET IDENTITY_INSERT $fn OFF;`n"
            $sql += "DECLARE @mx BIGINT = (SELECT MAX(Id) FROM $fn); IF @mx IS NOT NULL DBCC CHECKIDENT ('$($fn.Replace("'", "''"))', RESEED, @mx) WITH NO_INFOMSGS;`n"
        }
        [void](X $sql @{ j = $json })

        $n = (Q "SELECT COUNT_BIG(*) AS N FROM $fn").Rows[0].N
        $expected[$t] = $n
        $snapRows = @($manifest.tables | Where-Object { $_.table -eq $t } | ForEach-Object { $_.rows })
        $ok = ($snapRows.Count -eq 1 -and [long]$snapRows[0] -eq [long]$n)
        Say ("    {0,-42} {1,7} rows{2}{3}" -f $t, $n, $(if ($uCols.Count) { "  (users remapped: $($uCols -join ', '))" } else { "" }), $(if ($ok) { "" } else { "   <-- snapshot says $snapRows" })) $(if ($ok) { "Gray" } else { "Red" })
        if (-not $ok) { throw "row count mismatch on $t" }
    }

    # Re-enable every FK WITH CHECK: validates every row in the database.
    Say ""
    Say "  Re-enabling and re-validating $($allFks.Count) foreign keys..." "Cyan"
    foreach ($fk in $allFks) {
        try { [void](X "ALTER TABLE $($fk.T) WITH CHECK CHECK CONSTRAINT $($fk.F);") }
        catch { throw "FK $($fk.T).$($fk.F) failed re-validation: $($_.Exception.InnerException.Message)$($_.Exception.Message)" }
    }
    $badFk = (Q "SELECT COUNT(*) AS N FROM sys.foreign_keys WHERE is_disabled = 1 OR is_not_trusted = 1").Rows[0].N
    if ($badFk -gt 0) { throw "$badFk foreign key(s) not trusted after re-enable." }
    Say "  All foreign keys enabled and trusted." "Green"

    # ---- Sanity reads --------------------------------------------------------
    Say ""
    Say "  Spot checks:" "Cyan"
    $checks = Q @"
SELECT N'Active locations'   AS K, COUNT(*) AS V FROM Location.Location WHERE DeprecatedAt IS NULL
UNION ALL SELECT N'Active parts',          COUNT(*) FROM Parts.Item WHERE DeprecatedAt IS NULL
UNION ALL SELECT N'Active dies',           COUNT(*) FROM Tools.Tool WHERE DeprecatedAt IS NULL
UNION ALL SELECT N'Die cavities',          COUNT(*) FROM Tools.ToolCavity
UNION ALL SELECT N'Dies mounted on a press', COUNT(*) FROM Tools.ToolAssignment WHERE ReleasedAt IS NULL
UNION ALL SELECT N'Published routes',      COUNT(*) FROM Parts.RouteTemplate WHERE PublishedAt IS NOT NULL AND DeprecatedAt IS NULL
UNION ALL SELECT N'Open LOTs',             COUNT(*) FROM Lots.Lot
UNION ALL SELECT N'Dev users kept',        COUNT(*) FROM Location.AppUser
UNION ALL SELECT N'AIM pool (unconsumed)', COUNT(*) FROM Lots.AimShipperIdPool
"@
    foreach ($r in $checks.Rows) { Say ("    {0,-28} {1,6}" -f $r.K, $r.V) }

    $loop = Q @"
SELECT l.Code, la.AttributeValue FROM Location.LocationAttribute la
JOIN Location.LocationAttributeDefinition d ON d.Id = la.LocationAttributeDefinitionId AND d.AttributeName = N'IpAddress'
JOIN Location.Location l ON l.Id = la.LocationId AND l.DeprecatedAt IS NULL
WHERE Location.ufn_NormalizeIpAddress(la.AttributeValue) = N'127.0.0.1'
"@
    if ($loop.Rows.Count -eq 0) {
        Say "    No terminal claims loopback: a browser on this machine opens as the Fallback Terminal."
        Say "    To demo as a terminal run sql\scratch\register_loopback_terminal.sql (default DC1-T1)." "DarkGray"
    } else {
        foreach ($r in $loop.Rows) { Say "    Loopback terminal: $($r.Code) ($($r.AttributeValue))" }
    }

    $sw.Stop()
    if ($Commit) {
        $tx.Commit(); $tx = $null
        Say ""
        Say ("  COMMITTED in {0:N1} s. Now run .\scan.ps1 and reload open sessions." -f $sw.Elapsed.TotalSeconds) "Green"
    } else {
        $tx.Rollback(); $tx = $null
        Say ""
        Say ("  DRY RUN complete in {0:N1} s -- everything above ran and was ROLLED BACK. Nothing changed." -f $sw.Elapsed.TotalSeconds) "Yellow"
        Say "  Re-run with -Commit to apply." "Yellow"
    }
}
catch {
    if ($tx) { try { $tx.Rollback() } catch { } ; $tx = $null }
    Say ""
    Say "  FAILED -- rolled back, nothing changed: $($_.Exception.Message)" "Red"
    $failed = $true
}
finally {
    if ($conn.State -ne 'Closed') { $conn.Close() }
    $log = Join-Path $SnapshotDir ("_import_{0}_{1}_{2}.txt" -f $DatabaseName, $(if ($Commit) { "commit" } else { "dryrun" }), (Get-Date -Format "yyyyMMdd_HHmmss"))
    [IO.File]::WriteAllLines($log, $report)
    Write-Host "  Report: $log" -ForegroundColor DarkGray
    Write-Host ""
}
if ($failed) { exit 1 }
