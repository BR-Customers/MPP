-- =============================================
-- File:         0026_PlantFloor_Downtime_Shift/060_ShiftEndSummary_reads.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-06-16
-- Description:  Arc 2 Phase 8 shift-end summary reads (FDS-09-015):
--                 * Oee.DowntimeEvent_GetOpenByLocation  (open downtime at cell)
--                 * Oee.Lot_GetInProcessByLocation       (in-process LOTs at cell)
--               Asserts each read returns the seeded row; ET conversion is applied
--               (StartedAtEt wall-clock is behind UTC). INSERT-EXEC into temp
--               tables matching the SELECT shape (project test convention).
--               Fixture: a Received LOT at an eligible Cell + an open downtime.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0026_PlantFloor_Downtime_Shift/060_ShiftEndSummary_reads.sql';
GO

IF OBJECT_ID(N'tempdb..#SumFix') IS NOT NULL DROP TABLE #SumFix;
CREATE TABLE #SumFix (Tag NVARCHAR(20) PRIMARY KEY, Val BIGINT);
GO

DECLARE @OriginRcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
DECLARE @ItemId BIGINT, @CellId BIGINT;
SELECT TOP 1 @ItemId = eil.ItemId, @CellId = eil.LocationId
FROM Parts.v_EffectiveItemLocation eil
WHERE NOT EXISTS (SELECT 1 FROM Tools.ToolAssignment ta WHERE ta.CellLocationId = eil.LocationId AND ta.ReleasedAt IS NULL)
ORDER BY eil.LocationId;

DECLARE @cr TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO @cr EXEC Lots.Lot_Create
    @ItemId = @ItemId, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @CellId,
    @PieceCount = 50, @AppUserId = 1;
DECLARE @LotId BIGINT = (SELECT NewId FROM @cr);

DECLARE @Src BIGINT = (SELECT Id FROM Oee.DowntimeSourceCode WHERE Code = N'Operator');
DECLARE @ds TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @ds EXEC Oee.DowntimeEvent_Start @LocationId = @CellId, @DowntimeSourceCodeId = @Src, @AppUserId = 1;
DECLARE @EvtId BIGINT = (SELECT NewId FROM @ds);

INSERT INTO #SumFix (Tag, Val) VALUES (N'CELL', @CellId), (N'LOT', @LotId), (N'EVT', @EvtId);
GO

-- =============================================
-- Test 1: open-downtime read returns the open event + ET conversion applied
-- =============================================
DECLARE @Cell BIGINT = (SELECT Val FROM #SumFix WHERE Tag = N'CELL');
DECLARE @dt TABLE (DowntimeEventId BIGINT, LocationId BIGINT, LocationCode NVARCHAR(50),
    DowntimeReasonCodeId BIGINT, ReasonCode NVARCHAR(20), DowntimeSourceCodeId BIGINT,
    SourceCode NVARCHAR(20), StartedAtEt DATETIMEOFFSET, AppUserId BIGINT, ShotCount INT);
INSERT INTO @dt EXEC Oee.DowntimeEvent_GetOpenByLocation @LocationId = @Cell;
DECLARE @dtCnt INT = (SELECT COUNT(*) FROM @dt);
EXEC test.Assert_RowCount @TestName = N'[Summary] open-downtime read returns the open event',
    @ExpectedCount = 1, @ActualCount = @dtCnt;

DECLARE @etWall DATETIME2(3) = (SELECT CONVERT(DATETIME2(3), StartedAtEt) FROM @dt);
DECLARE @utc DATETIME2(3) = (SELECT StartedAt FROM Oee.DowntimeEvent WHERE Id = (SELECT DowntimeEventId FROM @dt));
DECLARE @etCond BIT = CASE WHEN @etWall < @utc THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[Summary] StartedAtEt wall-clock is behind UTC (ET applied)', @Condition = @etCond;
GO

-- =============================================
-- Test 2: in-process read returns the LOT at the cell
-- =============================================
DECLARE @Cell BIGINT = (SELECT Val FROM #SumFix WHERE Tag = N'CELL');
DECLARE @LotId BIGINT = (SELECT Val FROM #SumFix WHERE Tag = N'LOT');
DECLARE @ip TABLE (LotId BIGINT, LotName NVARCHAR(50), ItemCode NVARCHAR(50),
    InProcessPieceCount DECIMAL(18,3), LotStatus NVARCHAR(20), ArrivedAtEt DATETIMEOFFSET);
INSERT INTO @ip EXEC Oee.Lot_GetInProcessByLocation @LocationId = @Cell;
DECLARE @ipCnt INT = (SELECT COUNT(*) FROM @ip WHERE LotId = @LotId);
EXEC test.Assert_RowCount @TestName = N'[Summary] in-process read returns the LOT at the cell',
    @ExpectedCount = 1, @ActualCount = @ipCnt;
GO

-- ---- cleanup (FK-safe) ----
DECLARE @Cell BIGINT = (SELECT Val FROM #SumFix WHERE Tag = N'CELL');
DECLARE @LotId BIGINT = (SELECT Val FROM #SumFix WHERE Tag = N'LOT');
DELETE ol FROM Audit.OperationLog ol
    INNER JOIN Oee.DowntimeEvent de ON de.Id = ol.EntityId
    WHERE de.LocationId = @Cell
      AND ol.LogEntityTypeId = (SELECT Id FROM Audit.LogEntityType WHERE Code = N'DowntimeEvent');
DELETE FROM Oee.DowntimeEvent WHERE LocationId = @Cell;
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId = @LotId OR DescendantLotId = @LotId;
DELETE FROM Lots.LotGenealogy WHERE ParentLotId = @LotId OR ChildLotId = @LotId;
DELETE FROM Lots.LotAttributeChange WHERE LotId = @LotId;
DELETE FROM Lots.LotEventLog WHERE LotId = @LotId;
DELETE FROM Lots.LotMovement WHERE LotId = @LotId;
DELETE FROM Lots.LotStatusHistory WHERE LotId = @LotId;
DELETE FROM Lots.Lot WHERE Id = @LotId;
IF OBJECT_ID(N'tempdb..#SumFix') IS NOT NULL DROP TABLE #SumFix;
GO
