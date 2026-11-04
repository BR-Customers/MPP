<#
.SYNOPSIS
    Times the OEE dashboard reads, the per-shift compute and a few LOT reads that
    the extra seeded LOT volume could slow down, against MPP_MES_Dev.

.DESCRIPTION
    Companion to seed_oee_history.sql: run it before and after a seed to see what
    the volume costs. Each call goes through SqlClient and drains every row, the
    way the gateway reads a named query. Each runs -Runs times; the first is
    reported as Cold, the median of the rest as Warm.

    READ-ONLY except the last check, Oee.ShiftSummary_RefreshChanged (what the
    OeeSummaryRefresh timer runs every 15 min) -- it rewrites derived summary
    rows only. Skip it with -SkipRefresh.

    The anchor is the last closed shift that has seeded M&A trays (falls back to
    the last closed shift); "busy" is the closed shift with the most minted LOTs.

.EXAMPLE
    .\sql\scratch\Measure-OeeDevVolume.ps1 -Label baseline
#>
param(
    [string]$ServerInstance = 'localhost',
    [string]$Database       = 'MPP_MES_Dev',
    [int]$Runs              = 3,
    [string]$Label          = 'run',
    [switch]$SkipRefresh
)
$ErrorActionPreference = 'Stop'

$cs = "Server=$ServerInstance;Database=$Database;Integrated Security=True;TrustServerCertificate=True;Application Name=Measure-OeeDevVolume"
$cn = New-Object System.Data.SqlClient.SqlConnection $cs
$cn.Open()

function Scalar([string]$sql) {
    $cmd = $cn.CreateCommand(); $cmd.CommandText = $sql; $cmd.CommandTimeout = 600
    return $cmd.ExecuteScalar()
}

function Time-Call([string]$name, [string]$sql, [int]$runs = $Runs) {
    $ms = @(); $rows = 0
    for ($i = 0; $i -lt $runs; $i++) {
        $cmd = $cn.CreateCommand(); $cmd.CommandText = $sql; $cmd.CommandTimeout = 600
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $rd = $cmd.ExecuteReader(); $n = 0
        do { while ($rd.Read()) { $n++ } } while ($rd.NextResult())
        $rd.Close(); $sw.Stop()
        $ms += $sw.Elapsed.TotalMilliseconds; $rows = $n
    }
    $warm = if ($ms.Count -gt 1) { ($ms[1..($ms.Count - 1)] | Sort-Object)[[int][Math]::Floor(($ms.Count - 1) / 2)] } else { $ms[0] }
    [pscustomobject]@{ Check = $name; Rows = $rows; ColdMs = [int]$ms[0]; WarmMs = [int]$warm }
}

$anchor = Scalar @"
SELECT COALESCE(
  (SELECT TOP 1 l.ShiftId FROM Lots.Lot l JOIN Oee.Shift s ON s.Id = l.ShiftId
    WHERE l.LotName LIKE N'OEESEED-%' AND l.ShiftId IS NOT NULL AND s.ActualEnd IS NOT NULL
    ORDER BY s.ActualStart DESC),
  (SELECT TOP 1 Id FROM Oee.Shift WHERE ActualEnd IS NOT NULL ORDER BY ActualStart DESC))
"@
$busy = Scalar @"
SELECT COALESCE(
  (SELECT TOP 1 l.ShiftId FROM Lots.Lot l JOIN Oee.Shift s ON s.Id = l.ShiftId
    WHERE s.ActualEnd IS NOT NULL GROUP BY l.ShiftId ORDER BY COUNT(*) DESC, l.ShiftId DESC), $anchor)
"@
$counts = Scalar @"
SELECT CONCAT('Lots=', (SELECT COUNT(*) FROM Lots.Lot),
  ' (seeded ', (SELECT COUNT(*) FROM Lots.Lot WHERE LotName LIKE N'OEESEED-%'), ')',
  '  FG minted in busy shift=', (SELECT COUNT(*) FROM Lots.Lot WHERE ShiftId = $busy),
  '  DowntimeEvent=', (SELECT COUNT(*) FROM Oee.DowntimeEvent),
  '  RejectEvent=', (SELECT COUNT(*) FROM Workorder.RejectEvent),
  '  ShiftSummary=', (SELECT COUNT(*) FROM Oee.ShiftSummary))
"@
$line = Scalar "SELECT Id FROM Location.Location WHERE Code = N'MA2-6MACH'"
$aout = Scalar "SELECT Id FROM Location.Location WHERE Code = N'MA2-6MACH-AOUT1'"
$press = Scalar "SELECT Id FROM Location.Location WHERE Code = N'DC1-M04'"

Write-Host "[$Label] $Database  anchor shift $anchor  busy shift $busy"
Write-Host "[$Label] $counts"

$checks = @(
    @('Site  Shift  GetUnitSummary',           "EXEC Oee.Dashboard_GetUnitSummary @Zoom=N'Shift', @AnchorShiftId=$anchor, @AreaFamily=NULL, @ReadLive=0"),
    @('Site  Shift  GetUnitSummary ReadLive',  "EXEC Oee.Dashboard_GetUnitSummary @Zoom=N'Shift', @AnchorShiftId=$anchor, @AreaFamily=NULL, @ReadLive=1"),
    @('Site  Day    GetUnitSummary',           "EXEC Oee.Dashboard_GetUnitSummary @Zoom=N'Day',   @AnchorShiftId=$anchor, @AreaFamily=NULL, @ReadLive=0"),
    @('Site  Week   GetUnitSummary',           "EXEC Oee.Dashboard_GetUnitSummary @Zoom=N'Week',  @AnchorShiftId=$anchor, @AreaFamily=NULL, @ReadLive=0"),
    @('Area  Week   GetUnitSummary ma',        "EXEC Oee.Dashboard_GetUnitSummary @Zoom=N'Week',  @AnchorShiftId=$anchor, @AreaFamily=N'ma', @ReadLive=0"),
    @('Area  ma     GetTrend',                 "EXEC Oee.Dashboard_GetTrend @AnchorShiftId=$anchor, @AreaFamily=N'ma', @LocationId=NULL"),
    @('Area  Week   GetDowntimeByReason ma',   "EXEC Oee.Dashboard_GetDowntimeByReason @Zoom=N'Week', @AnchorShiftId=$anchor, @AreaFamily=N'ma', @LocationId=NULL"),
    @('Area  Week   GetScrap ma by Line',      "EXEC Oee.Dashboard_GetScrap @Zoom=N'Week', @AnchorShiftId=$anchor, @AreaFamily=N'ma', @LocationId=NULL, @GroupBy=N'Line'"),
    @('Area  Week   GetScrap ma by Part',      "EXEC Oee.Dashboard_GetScrap @Zoom=N'Week', @AnchorShiftId=$anchor, @AreaFamily=N'ma', @LocationId=NULL, @GroupBy=N'Part'"),
    @('Unit  Week   GetBreakdown line',        "EXEC Oee.Dashboard_GetBreakdown @Zoom=N'Week', @AnchorShiftId=$anchor, @LocationId=$line"),
    @('Unit  Week   GetScrap line',            "EXEC Oee.Dashboard_GetScrap @Zoom=N'Week', @AnchorShiftId=$anchor, @AreaFamily=NULL, @LocationId=$line, @GroupBy=N'Defect'"),
    @('Unit  Shift  GetDowntimeEntries line',  "EXEC Oee.Dashboard_GetDowntimeEntries @AnchorShiftId=$anchor, @LocationId=$line"),
    @('Compute busy ufn_ShiftGood',            "SELECT * FROM Oee.ufn_ShiftGood($busy)"),
    @('Compute busy ufn_ShiftSummaryRows',     "SELECT * FROM Oee.ufn_ShiftSummaryRows($busy)"),
    @('LOT  WIP queue AssemblyOut (6MACH)',    "EXEC Lots.Lot_GetWipQueueByLocation @LocationId=$aout, @OperationTypeCode=N'AssemblyOut', @IncludeDescendants=0"),
    @('LOT  WIP queue DieCast (DC1-M04)',      "EXEC Lots.Lot_GetWipQueueByLocation @LocationId=$press, @OperationTypeCode=N'DieCast', @IncludeDescendants=0"),
    @('LOT  Lot_List at line',                 "EXEC Lots.Lot_List @ItemId=NULL, @CurrentLocationId=$line, @LotStatusId=NULL, @LimitRows=200"),
    @('LOT  Lot_Search ''6MA''',               "EXEC Lots.Lot_Search @Query=N'6MA', @LotStatusId=NULL, @LotOriginTypeId=NULL, @LimitRows=200"),
    @('LOT  Lot_SearchAdvanced by shift',      "EXEC Lots.Lot_SearchAdvanced @Query=NULL, @ItemId=NULL, @CreatedFromEt=NULL, @CreatedToEt=NULL, @ToolId=NULL, @ToolCavityId=NULL, @LocationId=NULL, @MachineLocationId=NULL, @ShiftId=$busy, @LotStatusId=NULL, @LotOriginTypeId=NULL, @LimitRows=200, @ExcludeFinishedGoods=0")
)

$results = foreach ($c in $checks) {
    try { Time-Call $c[0] $c[1] }
    catch { [pscustomobject]@{ Check = $c[0]; Rows = -1; ColdMs = -1; WarmMs = -1; Error = $_.Exception.InnerException.Message } }
}
if (-not $SkipRefresh) {
    $results += Time-Call 'Timer ShiftSummary_RefreshChanged' "EXEC Oee.ShiftSummary_RefreshChanged @AppUserId=1, @MaxShifts=NULL" 1
}
$cn.Close()
$results | Format-Table -AutoSize | Out-String -Width 200
