<#
.SYNOPSIS
    Times the hot screen / report reads against a year-scale bench database so the
    slowest ones can be found and fixed. Companion to bench_lot_volume_seed.sql.

.DESCRIPTION
    Each read runs -Runs times through SqlClient (rows drained, as the gateway reads a
    named query); the first is reported Cold (after DBCC DROPCLEANBUFFERS), the
    median of the rest Warm. Logical reads come from SET STATISTICS IO, summed over
    every table. Read-only. Refuses any database not named MPP_MES_Bench*.

.EXAMPLE
    .\sql\scratch\Probe-ReadSweep.ps1 -Database MPP_MES_Bench_After -Label sweep1 -OutDir <dir>
#>
param(
    [string]$ServerInstance = 'localhost',
    [Parameter(Mandatory = $true)][string]$Database,
    [Parameter(Mandatory = $true)][string]$Label,
    [string]$OutDir = '.',
    [int]$Runs = 3,
    [string]$Only = '',
    [ValidateSet('1','2','all')][string]$Set = '1'
)
$ErrorActionPreference = 'Stop'
if ($Database -notlike 'MPP_MES_Bench*') { throw 'Probe-ReadSweep runs only against MPP_MES_Bench* databases.' }

$cs = "Server=$ServerInstance;Database=$Database;Integrated Security=True;TrustServerCertificate=True;Application Name=Probe-ReadSweep"
$cn = New-Object System.Data.SqlClient.SqlConnection $cs
$script:reads = 0
$cn.add_InfoMessage({ param($s, $e)
    foreach ($m in [regex]::Matches($e.Message, 'logical reads (\d+)')) { $script:reads += [int64]$m.Groups[1].Value } })
$cn.FireInfoMessageEventOnUserErrors = $false
$cn.Open()

function Scalar([string]$sql) {
    $cmd = $cn.CreateCommand(); $cmd.CommandText = $sql; $cmd.CommandTimeout = 1200
    return $cmd.ExecuteScalar()
}
function Exec([string]$sql) { $cmd = $cn.CreateCommand(); $cmd.CommandText = $sql; $cmd.CommandTimeout = 1200; [void]$cmd.ExecuteNonQuery() }

function Probe([string]$name, [string]$sql) {
    if ($Only -and $name -notlike "*$Only*") { return }
    $ms = @(); $rows = 0; $rd0 = 0
    for ($i = 0; $i -lt $Runs; $i++) {
        if ($i -eq 0) { Exec 'DBCC DROPCLEANBUFFERS WITH NO_INFOMSGS;' }
        Exec 'SET STATISTICS IO ON;'
        $script:reads = 0
        $cmd = $cn.CreateCommand(); $cmd.CommandText = $sql; $cmd.CommandTimeout = 1200
        $sw = [Diagnostics.Stopwatch]::StartNew()
        try {
            $r = $cmd.ExecuteReader(); $n = 0
            do { while ($r.Read()) { $n++ } } while ($r.NextResult())
            $r.Close()
        } catch { $n = -1; "  ERROR $name : $($_.Exception.Message)" | Write-Host }
        $sw.Stop(); Exec 'SET STATISTICS IO OFF;'
        $ms += $sw.Elapsed.TotalMilliseconds; $rows = $n; if ($i -eq $Runs - 1) { $rd0 = $script:reads }
    }
    $rest = @($ms[1..($ms.Count - 1)] | Sort-Object)
    [pscustomobject]@{ Check = $name; Rows = $rows; ColdMs = [int]$ms[0]; WarmMs = [int]$rest[[int][Math]::Floor(($rest.Count - 1) / 2)]; Reads = $rd0 }
}

# ---- probe arguments, picked from the seeded data ----
$line    = Scalar "SELECT Id FROM Location.Location WHERE Code = N'MA2-6MACH'"
$aout    = Scalar "SELECT Id FROM Location.Location WHERE Code = N'MA2-6MACH-AOUT1'"
$term    = Scalar "SELECT TOP 1 c.StationLocationId FROM Lots.Container c WHERE c.CurrentLocationId = $line AND c.StationLocationId IS NOT NULL ORDER BY c.Id DESC"
if (-not $term) { $term = $aout }
$fgLot   = Scalar "SELECT TOP 1 Id FROM Lots.Lot WHERE LotName LIKE N'BENCHF%' ORDER BY Id DESC"
$fgItem  = Scalar "SELECT ItemId FROM Lots.Lot WHERE Id = $fgLot"
$srcLot  = Scalar "SELECT TOP 1 g.ParentLotId FROM Lots.LotGenealogy g WHERE g.ChildLotId = $fgLot ORDER BY g.ParentLotId"
$castLot = Scalar "SELECT TOP 1 c.AncestorLotId FROM Lots.LotGenealogyClosure c WHERE c.DescendantLotId = $srcLot AND c.Depth = 1"
$ctr     = Scalar "SELECT TOP 1 Id FROM Lots.Container WHERE ItemId = $fgItem ORDER BY Id DESC"
$to      = (Get-Date).ToString('yyyy-MM-dd'); $from7 = (Get-Date).AddDays(-7).ToString('yyyy-MM-dd'); $from30 = (Get-Date).AddDays(-30).ToString('yyyy-MM-dd')
"[$Label] $Database line=$line aout=$aout term=$term fgLot=$fgLot srcLot=$srcLot castLot=$castLot ctr=$ctr"

$anchor  = Scalar "SELECT TOP 1 ShiftId FROM Lots.ContainerTray WHERE ShiftId IS NOT NULL ORDER BY ClosedAt DESC"
if (-not $anchor) { $anchor = Scalar "SELECT TOP 1 Id FROM Oee.Shift WHERE ActualEnd IS NOT NULL ORDER BY ActualStart DESC" }
$fromDt  = (Get-Date).AddDays(-30).ToString('yyyy-MM-dd'); $toDt = (Get-Date).ToString('yyyy-MM-dd')
$item1   = Scalar "SELECT TOP 1 ItemId FROM Workorder.RejectEvent ORDER BY Id DESC"
$results = @()
if ($Set -in '2','all') { $results += @(
    Probe 'OEE unit summary Week ReadLive'        "EXEC Oee.Dashboard_GetUnitSummary @Zoom=N'Week', @AnchorShiftId=$anchor, @AreaFamily=NULL, @ReadLive=1"
    Probe 'OEE unit summary Shift ReadLive'       "EXEC Oee.Dashboard_GetUnitSummary @Zoom=N'Shift', @AnchorShiftId=$anchor, @AreaFamily=NULL, @ReadLive=1"
    Probe 'OEE scrap Week ma by Line'             "EXEC Oee.Dashboard_GetScrap @Zoom=N'Week', @AnchorShiftId=$anchor, @AreaFamily=N'ma', @LocationId=NULL, @GroupBy=N'Line'"
    Probe 'OEE downtime by reason Week ma'        "EXEC Oee.Dashboard_GetDowntimeByReason @Zoom=N'Week', @AnchorShiftId=$anchor, @AreaFamily=N'ma', @LocationId=NULL"
    Probe 'OEE downtime entries (line)'           "EXEC Oee.Dashboard_GetDowntimeEntries @AnchorShiftId=$anchor, @LocationId=$line"
    Probe 'OEE trend ma'                          "EXEC Oee.Dashboard_GetTrend @AnchorShiftId=$anchor, @AreaFamily=N'ma', @LocationId=NULL"
    Probe 'OEE ufn_ShiftSummaryRows (anchor)'     "SELECT * FROM Oee.ufn_ShiftSummaryRows($anchor)"
    Probe 'OEE ufn_ShiftScrap (anchor)'           "SELECT * FROM Oee.ufn_ShiftScrap($anchor)"
    Probe 'OEE ufn_ShiftInputFingerprint'         "SELECT * FROM Oee.ufn_ShiftInputFingerprint($anchor)"
    Probe 'Shift availability (line)'             "EXEC Oee.Shift_GetAvailability @ShiftId=$anchor, @LocationId=$line"
    Probe 'Downtime by scope (line, desc)'        "EXEC Oee.DowntimeEvent_GetByScope @ScopeLocationId=$line, @IncludeDescendants=1, @ShiftId=$anchor"
    Probe 'Downtime open summary'                 "EXEC Oee.DowntimeEvent_GetOpenSummary"
    Probe 'Defect codes ranked (term)'            "EXEC Quality.DefectCode_ListRankedForLocation @LocationId=$term, @OperationTypeCode=NULL, @WindowDays=30"
    Probe 'Rejects non-reject scrap (30d)'        "EXEC Quality.Reject_GetNonRejectScrap @FromEt='$fromDt', @ToEt='$toDt'"
    Probe 'Rejects part matrix defects (30d)'     "EXEC Quality.Reject_GetPartMatrixDefects @ItemId=$item1, @FromEt='$fromDt', @ToEt='$toDt'"
    Probe 'Rejects part matrix by party (30d)'    "EXEC Quality.Reject_GetPartMatrixByParty @ItemId=$item1, @FromEt='$fromDt', @ToEt='$toDt'"
    Probe 'Rejects plant summary (30d)'           "EXEC Quality.Reject_GetPlantSummary @FromEt='$fromDt', @ToEt='$toDt'"
    Probe 'Rejects search detail (30d)'           "EXEC Quality.Reject_SearchDetail @FromEt='$fromDt', @ToEt='$toDt', @PartNumberLike=NULL, @DefectCodeId=NULL, @ChargeToPartyId=NULL, @LimitRows=500"
    Probe 'Failure log default'                   "EXEC Audit.FailureLog_List @StartDate=NULL, @EndDate=NULL, @LogEntityTypeCode=NULL, @AppUserId=NULL, @ProcedureName=NULL, @FailureReasonLike=NULL, @LocationId=NULL, @LotNameLike=NULL"
    Probe 'Failure log top reasons'               "EXEC Audit.FailureLog_GetTopReasons @StartDate=NULL, @EndDate=NULL, @LogEntityTypeCode=NULL, @ProcedureName=NULL"
    Probe 'Failure log top procs'                 "EXEC Audit.FailureLog_GetTopProcs @StartDate=NULL, @EndDate=NULL"
    Probe 'Config log default'                    "EXEC Audit.ConfigLog_List @StartDate=NULL, @EndDate=NULL, @LogEntityTypeCode=NULL, @AppUserId=NULL, @LogSeverityCode=NULL, @DescriptionLike=NULL"
    Probe 'LOT lifecycle (FG)'                    "EXEC Lots.Lot_GetLifecycle @LotId=$fgLot"
    Probe 'Scale press log'                       "EXEC Workorder.ScaleStation_GetPressLog @TerminalLocationId=$term, @Top=20"
    Probe 'CRT required inspections (line)'       "EXEC Quality.Crt_GetRequiredInspections @LocationId=$line"
) }
if ($Set -in '1','all') { $results += @(
    Probe 'Genealogy tree FG LOT (both)'          "EXEC Lots.Lot_GetGenealogyTree @LotId=$fgLot, @Direction=N'Both'"
    Probe 'Genealogy edge tree casting (down)'    "EXEC Lots.Lot_GetGenealogyEdgeTree @LotId=$castLot, @Direction=N'Descendants'"
    Probe 'Genealogy tree casting (both)'         "EXEC Lots.Lot_GetGenealogyTree @LotId=$castLot, @Direction=N'Both'"
    Probe 'Shipped containers from casting'       "EXEC Lots.Lot_GetShippedContainers @LotId=$castLot"
    Probe 'Line inventory summary (line)'         "EXEC Lots.Lot_GetLineInventorySummary @LocationId=$line, @TerminalRole=NULL, @LineWide=1"
    Probe 'Line inventory by part (line)'         "EXEC Lots.Lot_GetLineInventoryByPart @LocationId=$line, @ExcludeFinishedGoods=0"
    Probe 'Components at cell (line, desc)'       "EXEC Lots.Lot_GetComponentsAtCell @CellLocationId=$line, @IncludeDescendants=1"
    Probe 'Cell line quantity'                    "EXEC Lots.Lot_GetCellLineQuantity @LocationId=$line, @ItemId=$fgItem"
    Probe 'Trim storage queue for line'           "EXEC Lots.Lot_GetTrimStorageQueueForLine @LineLocationId=$line, @StorageLocationId=NULL"
    Probe 'Open container by cell'                "EXEC Lots.Container_GetOpenByCell @CellLocationId=$line, @StationLocationId=$term, @ClosureMethod=N'ByVision'"
    Probe 'Trays remaining'                       "EXEC Workorder.Assembly_GetTraysRemaining @CellLocationId=$line, @FinishedGoodItemId=$fgItem, @ClosureMethod=N'ByVision'"
    Probe 'Recent shipping labels by cell'        "EXEC Lots.ShippingLabel_ListRecentByCell @CellLocationId=$line, @TopN=20"
    Probe 'Scale recent boxes'                    "EXEC Workorder.ScaleStation_GetRecentBoxes @TerminalLocationId=$term, @Top=20"
    Probe 'Scale shift tally'                     "EXEC Workorder.ScaleStation_GetShiftTally @TerminalLocationId=$term"
    Probe 'FG produced summary (24h, line)'       "DECLARE @s DATETIME2(3) = DATEADD(HOUR,-24,SYSUTCDATETIME()); EXEC Workorder.FinishedGoods_GetProducedSummary @CellLocationId=$line, @ShiftStartUtc=@s, @ShiftEndUtc=NULL"
    Probe 'Shipped containers list (30d)'         "EXEC Lots.Container_ListShipped @FromEt='$from30', @ToEt='$to', @PartNumberLike=NULL"
    Probe 'Pending CRT validation (line)'         "EXEC Lots.Container_ListPendingValidation @LocationId=$line, @ContainerId=NULL"
    Probe 'AIM unposted'                          "EXEC Lots.AimShipperIdPool_ListUnposted @Top=50"
    Probe 'Hold list open'                        "EXEC Quality.Hold_ListOpen @FilterText=NULL, @FilterTypeCodeId=NULL"
    Probe 'Hold associated containers (src)'      "EXEC Quality.Hold_ListAssociatedContainers @LotId=$srcLot"
    Probe 'Controlled runs list'                  "EXEC Quality.ControlledRun_List @StatusCode=NULL, @Text=NULL"
    Probe 'Rejects plant summary (7d)'            "EXEC Quality.Reject_GetPlantSummary @FromEt='$from7', @ToEt='$to'"
    Probe 'Rejects part matrix (30d)'             "EXEC Quality.Reject_GetPartMatrix @FromEt='$from30', @ToEt='$to'"
    Probe 'Rejects search detail (30d)'           "EXEC Quality.Reject_SearchDetail @FromEt='$from30', @ToEt='$to', @PartNumberLike=NULL, @DefectCodeId=NULL, @ChargeToPartyId=NULL, @LimitRows=500"
    Probe 'Failure log default'                   "EXEC Audit.FailureLog_List @StartDate=NULL, @EndDate=NULL, @LogEntityTypeCode=NULL, @AppUserId=NULL, @ProcedureName=NULL, @FailureReasonLike=NULL, @LocationId=NULL, @LotNameLike=NULL"
    Probe 'LOT get by id'                         "EXEC Lots.Lot_Get @LotId=$fgLot, @LotName=NULL"
    Probe 'WIP queue AssemblyOut (term)'          "EXEC Lots.Lot_GetWipQueueByLocation @LocationId=$aout, @OperationTypeCode=N'AssemblyOut', @IncludeDescendants=0"
    Probe 'WIP queue line (desc)'                 "EXEC Lots.Lot_GetWipQueueByLocation @LocationId=$line, @OperationTypeCode=NULL, @IncludeDescendants=1"
    Probe 'Lot_List at line'                      "EXEC Lots.Lot_List @ItemId=NULL, @CurrentLocationId=$line, @LotStatusId=NULL, @LimitRows=200"
) }
$cn.Close()
$results | Sort-Object WarmMs -Descending | Format-Table -AutoSize | Out-String -Width 200
$results | ConvertTo-Json -Depth 3 | Out-File -Encoding utf8 (Join-Path $OutDir "sweep_$Label.json")
