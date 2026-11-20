<#
.SYNOPSIS
    LOT-volume benchmark for the container-as-LOT change: row counts / reserved MB per
    table, MESL numbers used, and cold/warm timings of the LOT reads that scale with
    the LOT count. Companion to sql/scratch/bench_lot_volume_seed.sql.

.DESCRIPTION
    Spec docs/superpowers/specs/2026-11-04-container-as-lot-and-lot-volume-design.md sec 10.
    READ-ONLY except the Assembly_CompleteTray probe, which runs inside
    BEGIN TRAN ... ROLLBACK. Refuses any database whose name does not start with
    MPP_MES_Bench. Each call drains every row through SqlClient (as the gateway reads
    a named query); -Runs calls per check, first reported Cold, median of the rest Warm.
    Writes <Label>.json beside the script's -OutDir.

.EXAMPLE
    .\sql\scratch\Measure-LotVolume.ps1 -Database MPP_MES_Bench -Label A-before -OutDir <dir>
#>
param(
    [string]$ServerInstance = 'localhost',
    [Parameter(Mandatory = $true)][string]$Database,
    [Parameter(Mandatory = $true)][string]$Label,
    [string]$OutDir = '.',
    [int]$Runs = 4
)
$ErrorActionPreference = 'Stop'
if ($Database -notlike 'MPP_MES_Bench*') { throw "Measure-LotVolume runs only against MPP_MES_Bench* databases." }

$cs = "Server=$ServerInstance;Database=$Database;Integrated Security=True;TrustServerCertificate=True;Application Name=Measure-LotVolume"
$cn = New-Object System.Data.SqlClient.SqlConnection $cs
$cn.Open()

function Scalar([string]$sql) {
    $cmd = $cn.CreateCommand(); $cmd.CommandText = $sql; $cmd.CommandTimeout = 1200
    return $cmd.ExecuteScalar()
}
function Rows([string]$sql) {
    $cmd = $cn.CreateCommand(); $cmd.CommandText = $sql; $cmd.CommandTimeout = 1200
    $da = New-Object System.Data.SqlClient.SqlDataAdapter $cmd
    $t = New-Object System.Data.DataTable; [void]$da.Fill($t); return ,$t
}
function Time-Call([string]$name, [string]$sql) {
    $ms = @(); $rows = 0
    for ($i = 0; $i -lt $Runs; $i++) {
        if ($i -eq 0) { $c0 = $cn.CreateCommand(); $c0.CommandText = 'DBCC DROPCLEANBUFFERS WITH NO_INFOMSGS;'; [void]$c0.ExecuteNonQuery() }
        $cmd = $cn.CreateCommand(); $cmd.CommandText = $sql; $cmd.CommandTimeout = 1200
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $rd = $cmd.ExecuteReader(); $n = 0
        do { while ($rd.Read()) { $n++ } } while ($rd.NextResult())
        $rd.Close(); $sw.Stop()
        $ms += $sw.Elapsed.TotalMilliseconds; $rows = $n
    }
    $rest = @($ms[1..($ms.Count - 1)] | Sort-Object)
    $warm = $rest[[int][Math]::Floor(($rest.Count - 1) / 2)]
    [pscustomobject]@{ Check = $name; Rows = $rows; ColdMs = [int]$ms[0]; WarmMs = [int]$warm }
}

# ---- sizes ----
$tables = 'Lots.Lot','Lots.LotStatusHistory','Lots.LotMovement','Lots.LotGenealogy','Lots.LotGenealogyClosure',
          'Workorder.ConsumptionEvent','Lots.ContainerTray','Lots.Container','Lots.LotEventLog'
$sizes = foreach ($t in $tables) {
    $r = Rows @"
SELECT SUM(CASE WHEN p.index_id IN (0,1) THEN p.row_count ELSE 0 END) AS RowCnt,
       CAST(SUM(p.reserved_page_count) * 8 / 1024.0 AS DECIMAL(12,1)) AS ReservedMb
FROM sys.dm_db_partition_stats p WHERE p.object_id = OBJECT_ID(N'$t')
"@
    [pscustomobject]@{ Table = $t; Rows = [int64]$r.Rows[0].RowCnt; ReservedMb = [decimal]$r.Rows[0].ReservedMb }
}
$fgMinted = [int64](Scalar "SELECT COUNT(*) FROM Lots.Lot WHERE LotName LIKE N'BENCHF%'")
$seqLast  = [int64](Scalar "SELECT LastValue FROM Lots.IdentifierSequence WHERE Code = N'Lot'")
$seqEnd   = [int64](Scalar "SELECT EndingValue FROM Lots.IdentifierSequence WHERE Code = N'Lot'")
$yearsLeft = if ($fgMinted -gt 0) { [Math]::Round(($seqEnd - $seqLast) / $fgMinted, 1) } else { $null }

# ---- probes (picked from the seeded data) ----
$lotName   = Scalar "SELECT TOP 1 LotName FROM Lots.Lot WHERE LotName LIKE N'BENCHF%' ORDER BY Id DESC"
$oldLot    = Scalar "SELECT TOP 1 LotName FROM Lots.Lot WHERE LotName LIKE N'BENCHF%' ORDER BY Id"
$lotId     = Scalar "SELECT Id FROM Lots.Lot WHERE LotName = N'$lotName'"
$ctrId     = Scalar "SELECT TOP 1 Id FROM Lots.Container WHERE ItemId = (SELECT ItemId FROM Lots.Lot WHERE Id = $lotId) ORDER BY Id DESC"
$partNo    = Scalar "SELECT i.PartNumber FROM Parts.Item i JOIN Lots.Lot l ON l.ItemId = i.Id WHERE l.Id = $lotId"
$hasNewSearch = [int](Scalar "SELECT COUNT(*) FROM sys.parameters WHERE object_id = OBJECT_ID(N'Lots.Lot_Search') AND name = N'@IncludeOlder'")

$checks = @(
    Time-Call 'Lot_Search exact (newest LOT)'   "EXEC Lots.Lot_Search @Query = N'$lotName'"
    Time-Call 'Lot_Search exact (year-old LOT)' "EXEC Lots.Lot_Search @Query = N'$oldLot'"
    Time-Call 'Lot_Search prefix BENCHF12'      "EXEC Lots.Lot_Search @Query = N'BENCHF12'"
    Time-Call 'Lot_Search part number'          "EXEC Lots.Lot_Search @Query = N'$partNo'"
    Time-Call 'Lot_Search vendor-ish miss'      "EXEC Lots.Lot_Search @Query = N'ZZNOMATCH'"
    Time-Call 'Lot_Search empty'                "EXEC Lots.Lot_Search @Query = NULL"
    Time-Call 'Lot_SearchAdvanced part'         "EXEC Lots.Lot_SearchAdvanced @Query = N'$partNo'"
    Time-Call 'GlobalTrace_Resolve container'   "EXEC Lots.GlobalTrace_Resolve @SearchText = N'$ctrId'"
    Time-Call 'Hold_ListAssociatedContainers'   "EXEC Quality.Hold_ListAssociatedContainers @LotId = $lotId"
    Time-Call 'Lot_GetLinkedContainer'          "EXEC Lots.Lot_GetLinkedContainer @LotId = $lotId"
    Time-Call 'Container_GetTraceDetail'        "EXEC Lots.Container_GetTraceDetail @ContainerId = $ctrId"
)

# ---- two tray completions at year-end volume, rolled back (busiest line: most trays) ----
#   call 1 opens a new box (mint), call 2 adds to it (append in the container shape,
#   a second mint in the tray shape). Times are measured inside SQL around each EXEC.
$probeSql = @"
SET NOCOUNT ON; SET XACT_ABORT ON;
DECLARE @Item BIGINT, @Cell BIGINT, @Term BIGINT, @Method NVARCHAR(20), @Pcs INT;
SELECT TOP 1 @Item = c.ItemId, @Cell = c.CurrentLocationId, @Term = c.StationLocationId, @Method = cc.ClosureMethod, @Pcs = cc.PartsPerTray
FROM Lots.Container c JOIN Parts.ContainerConfig cc ON cc.Id = c.ContainerConfigId
WHERE c.Id = (SELECT TOP 1 ContainerId FROM Lots.ContainerTray GROUP BY ContainerId ORDER BY COUNT(*) DESC, ContainerId DESC);
BEGIN TRAN;
UPDATE Lots.Container SET ContainerStatusCodeId = (SELECT Id FROM Lots.ContainerStatusCode WHERE Code = N'Shipped')
WHERE ItemId = @Item AND CurrentLocationId = @Cell AND ContainerStatusCodeId = (SELECT Id FROM Lots.ContainerStatusCode WHERE Code = N'Open');
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId)
SELECT CONCAT(N'PROBE-', bl.ChildItemId), bl.ChildItemId, 1, (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Good'),
       CAST(CEILING(bl.QtyPer) * @Pcs * 2 AS INT), CAST(CEILING(bl.QtyPer) * @Pcs * 2 AS INT), @Cell, 1
FROM Parts.BomLine bl
WHERE bl.BomId = (SELECT TOP 1 Id FROM Parts.Bom WHERE ParentItemId = @Item AND PublishedAt IS NOT NULL AND DeprecatedAt IS NULL ORDER BY VersionNumber DESC);
INSERT INTO Lots.LotGenealogyClosure (AncestorLotId, DescendantLotId, Depth) SELECT Id, Id, 0 FROM Lots.Lot WHERE LotName LIKE N'PROBE-%';
DECLARE @R TABLE (Status BIT, Message NVARCHAR(500), FinishedGoodLotId BIGINT, ContainerId BIGINT, ContainerTrayId BIGINT, ContainerFull BIT, TraysPerContainer INT);
DECLARE @t0 DATETIME2(7) = SYSDATETIME();
INSERT INTO @R EXEC Workorder.Assembly_CompleteTray @FinishedGoodItemId = @Item, @PieceCount = @Pcs, @CellLocationId = @Cell, @ClosureMethod = @Method, @AppUserId = 1, @TerminalLocationId = @Term;
DECLARE @t1 DATETIME2(7) = SYSDATETIME();
INSERT INTO @R EXEC Workorder.Assembly_CompleteTray @FinishedGoodItemId = @Item, @PieceCount = @Pcs, @CellLocationId = @Cell, @ClosureMethod = @Method, @AppUserId = 1, @TerminalLocationId = @Term;
DECLARE @t2 DATETIME2(7) = SYSDATETIME();
DECLARE @ok INT = (SELECT COUNT(*) FROM @R WHERE Status = 1), @msg NVARCHAR(500) = (SELECT TOP 1 Message FROM @R WHERE Status = 0);
ROLLBACK;
SELECT DATEDIFF(MICROSECOND, @t0, @t1) / 1000.0 AS FirstMs, DATEDIFF(MICROSECOND, @t1, @t2) / 1000.0 AS SecondMs, @ok AS Ok, @msg AS Msg;
"@
$probeRows = @()
for ($i = 0; $i -lt $Runs; $i++) { $probeRows += (Rows $probeSql).Rows[0] }
$firsts  = @($probeRows | ForEach-Object { [double]$_.FirstMs }  | Sort-Object)
$seconds = @($probeRows | ForEach-Object { [double]$_.SecondMs } | Sort-Object)
$checks += [pscustomobject]@{ Check = 'Assembly_CompleteTray 1st tray (new box)'; Rows = [int]$probeRows[-1].Ok; ColdMs = [int]$probeRows[0].FirstMs;  WarmMs = [int]$firsts[[int][Math]::Floor($firsts.Count / 2)] }
$checks += [pscustomobject]@{ Check = 'Assembly_CompleteTray 2nd tray';           Rows = [int]$probeRows[-1].Ok; ColdMs = [int]$probeRows[0].SecondMs; WarmMs = [int]$seconds[[int][Math]::Floor($seconds.Count / 2)] }
if ($probeRows[-1].Ok -ne 2) { "WARNING: CompleteTray probe Ok=$($probeRows[-1].Ok) msg=$($probeRows[-1].Msg)" }

$result = [pscustomobject]@{
    Label = $Label; Database = $Database; MeasuredAt = (Get-Date).ToString('s')
    FgLotsMinted = $fgMinted; LotSeqLast = $seqLast; LotSeqEnd = $seqEnd; YearsLeftAtThisRate = $yearsLeft
    NewSearchProc = [bool]$hasNewSearch
    Sizes = $sizes; Timings = $checks
}
$cn.Close()
$path = Join-Path $OutDir "$Label.json"
$result | ConvertTo-Json -Depth 5 | Out-File -Encoding utf8 $path
"== $Label ($Database) FG LOTs minted: $fgMinted  seq $seqLast / $seqEnd  years left at this rate: $yearsLeft"
$sizes | Format-Table -AutoSize | Out-String
$checks | Format-Table -AutoSize | Out-String
"saved $path"
