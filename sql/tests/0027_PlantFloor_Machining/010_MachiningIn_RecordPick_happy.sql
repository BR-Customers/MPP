-- =============================================
-- File:         0027_PlantFloor_Machining/010_MachiningIn_RecordPick_happy.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-06-19
-- Rewritten:    2026-07-06 - "unworked arrivals" model. Machining IN no longer
--               consumes/renames via BOM; a pick just records a MachiningIn
--               checkpoint on the SAME LOT and stops.
-- Description:  Happy path for Workorder.MachiningIn_RecordPick:
--                 - Status=1; NewId (ProductionEventId) returned
--                 - one MachiningIn ProductionEvent written for the SAME LOT,
--                   stamped to the machining-in terminal
--                 - the LOT is UNCHANGED: same Item, same PieceCount, still Good
--                   (NOT closed), still at the line
--                 - NO new LOT, NO ConsumptionEvent
--                 - after the pick the LOT has HasLineEvent=1 at the line, so it
--                   leaves the unworked-arrivals queue
--                 - MachiningInPicked audit in Lots.LotEventLog for the LOT
--               Fixture: test item P5-CAST-TEST eligible at the LINE MA1-COMPBR;
--               a whole LOT checked into that line. Terminal = MA1-COMPBR-MIN.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0027_PlantFloor_Machining/010_MachiningIn_RecordPick_happy.sql';
GO

-- ---- fixture builder (idempotent): one item eligible at the LINE ----
DECLARE @Now  DATETIME2(3) = SYSUTCDATETIME();
DECLARE @Line BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR');

IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'P5-CAST-TEST')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, DefaultSubLotQty, MaxLotSize, UomId, CreatedAt, CreatedByUserId)
    VALUES (2, N'P5-CAST-TEST', N'Phase5 test cast/trim part', 48, NULL, 1, @Now, 1);
DECLARE @SrcItem BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P5-CAST-TEST');

IF NOT EXISTS (SELECT 1 FROM Parts.ItemLocation WHERE ItemId = @SrcItem AND LocationId = @Line AND DeprecatedAt IS NULL)
    INSERT INTO Parts.ItemLocation (ItemId, LocationId, IsConsumptionPoint, CreatedAt)
    VALUES (@SrcItem, @Line, 0, @Now);
GO

-- ---- fixture LOT cleanup (re-runnable) ----
DELETE pe FROM Workorder.ProductionEvent pe
    INNER JOIN Lots.Lot l ON l.Id = pe.LotId
    WHERE l.ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P5-CAST-TEST');
DELETE c FROM Lots.LotGenealogyClosure c
    INNER JOIN Lots.Lot l ON l.Id = c.AncestorLotId OR l.Id = c.DescendantLotId
    WHERE l.ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P5-CAST-TEST');
DELETE m FROM Lots.LotMovement m
    INNER JOIN Lots.Lot l ON l.Id = m.LotId
    WHERE l.ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P5-CAST-TEST');
DELETE h FROM Lots.LotStatusHistory h
    INNER JOIN Lots.Lot l ON l.Id = h.LotId
    WHERE l.ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P5-CAST-TEST');
DELETE eg FROM Lots.LotEventLog eg INNER JOIN Lots.Lot l ON l.Id = eg.LotId
    WHERE l.ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P5-CAST-TEST');
DELETE FROM Lots.Lot WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P5-CAST-TEST');
GO

-- ====================================================================
-- Test: record pick (no consume, keep identity)
-- ====================================================================
DECLARE @Line BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR');
DECLARE @Term BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-MIN');
DECLARE @SrcItem BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P5-CAST-TEST');
DECLARE @OriginRcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');

-- a whole LOT checked into the line
DECLARE @Lot BIGINT;
CREATE TABLE #C (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #C EXEC Lots.Lot_Create
    @ItemId = @SrcItem, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @Line,
    @PieceCount = 40, @AppUserId = 1, @LotName = N'P5T-PICK-010';
SELECT @Lot = NewId FROM #C; DROP TABLE #C;

DECLARE @LotStr NVARCHAR(20) = CAST(@Lot AS NVARCHAR(20));
EXEC test.Assert_IsNotNull @TestName = N'[MachIn] fixture LOT created at the line', @Value = @LotStr;

-- before the pick: unworked arrival at the line (HasLineEvent = 0)
CREATE TABLE #Q0 (Id BIGINT, LotName NVARCHAR(50), ItemId BIGINT, ItemPartNumber NVARCHAR(50), ItemDescription NVARCHAR(500), PieceCount INT, LotStatusId BIGINT, LotStatusCode NVARCHAR(20), LastMovementAt DATETIME2(3), HasRenameBom BIT, HasLineEvent BIT);
INSERT INTO #Q0 EXEC Lots.Lot_GetWipQueueByLocation @LocationId = @Line;
DECLARE @Before NVARCHAR(10) = (SELECT CAST(HasLineEvent AS NVARCHAR(10)) FROM #Q0 WHERE Id = @Lot);
DROP TABLE #Q0;
EXEC test.Assert_IsEqual @TestName = N'[MachIn] LOT is an unworked arrival before pick', @Expected = N'0', @Actual = @Before;

-- pick (record MachiningIn checkpoint)
DECLARE @S BIT, @ProdId BIGINT;
CREATE TABLE #R (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R EXEC Workorder.MachiningIn_RecordPick
    @LotId = @Lot, @LineLocationId = @Line, @AppUserId = 1, @TerminalLocationId = @Term;
SELECT @S = Status, @ProdId = NewId FROM #R; DROP TABLE #R;

DECLARE @SStr NVARCHAR(10) = CAST(@S AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[MachIn] Status is 1', @Expected = N'1', @Actual = @SStr;

DECLARE @ProdStr NVARCHAR(20) = CAST(@ProdId AS NVARCHAR(20));
EXEC test.Assert_IsNotNull @TestName = N'[MachIn] ProductionEventId returned', @Value = @ProdStr;

-- one MachiningIn ProductionEvent for the SAME LOT, stamped to the terminal
DECLARE @PeCnt NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Workorder.ProductionEvent pe
    INNER JOIN Parts.OperationTemplate ot ON ot.Id = pe.OperationTemplateId
    WHERE pe.Id = @ProdId AND pe.LotId = @Lot AND ot.Code = N'MachiningIn' AND pe.TerminalLocationId = @Term);
EXEC test.Assert_IsEqual @TestName = N'[MachIn] MachiningIn ProductionEvent on the same LOT, at the terminal', @Expected = N'1', @Actual = @PeCnt;

-- LOT unchanged: same item, still Good (not closed), same piece count, still at the line
DECLARE @ItemNow NVARCHAR(20) = (SELECT CAST(ItemId AS NVARCHAR(20)) FROM Lots.Lot WHERE Id = @Lot);
DECLARE @ItemExp NVARCHAR(20) = CAST(@SrcItem AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[MachIn] LOT item unchanged (no BOM rename)', @Expected = @ItemExp, @Actual = @ItemNow;

DECLARE @StatusNow NVARCHAR(20) = (SELECT sc.Code FROM Lots.Lot l INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId WHERE l.Id = @Lot);
EXEC test.Assert_IsEqual @TestName = N'[MachIn] LOT still Good (not closed)', @Expected = N'Good', @Actual = @StatusNow;

DECLARE @PcNow NVARCHAR(10) = (SELECT CAST(PieceCount AS NVARCHAR(10)) FROM Lots.Lot WHERE Id = @Lot);
EXEC test.Assert_IsEqual @TestName = N'[MachIn] LOT piece count unchanged (40)', @Expected = N'40', @Actual = @PcNow;

DECLARE @LocNow NVARCHAR(20) = (SELECT CAST(CurrentLocationId AS NVARCHAR(20)) FROM Lots.Lot WHERE Id = @Lot);
DECLARE @LineStr NVARCHAR(20) = CAST(@Line AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[MachIn] LOT still at the line', @Expected = @LineStr, @Actual = @LocNow;

-- no new LOT / no ConsumptionEvent produced by the pick
DECLARE @CeCnt NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Workorder.ConsumptionEvent WHERE SourceLotId = @Lot);
EXEC test.Assert_IsEqual @TestName = N'[MachIn] no ConsumptionEvent from the pick', @Expected = N'0', @Actual = @CeCnt;

-- after the pick: LOT now has a line event, so it leaves the unworked queue
CREATE TABLE #Q1 (Id BIGINT, LotName NVARCHAR(50), ItemId BIGINT, ItemPartNumber NVARCHAR(50), ItemDescription NVARCHAR(500), PieceCount INT, LotStatusId BIGINT, LotStatusCode NVARCHAR(20), LastMovementAt DATETIME2(3), HasRenameBom BIT, HasLineEvent BIT);
INSERT INTO #Q1 EXEC Lots.Lot_GetWipQueueByLocation @LocationId = @Line;
DECLARE @After NVARCHAR(10) = (SELECT CAST(HasLineEvent AS NVARCHAR(10)) FROM #Q1 WHERE Id = @Lot);
DROP TABLE #Q1;
EXEC test.Assert_IsEqual @TestName = N'[MachIn] LOT has a line event after pick (leaves unworked queue)', @Expected = N'1', @Actual = @After;

-- audit: 'Lot'-entity events route to Lots.LotEventLog (B7)
DECLARE @AudCnt NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Lots.LotEventLog le
    INNER JOIN Audit.LogEventType et ON et.Id = le.LogEventTypeId
    WHERE et.Code = N'MachiningInPicked' AND le.EntityId = @Lot);
EXEC test.Assert_IsEqual @TestName = N'[MachIn] MachiningInPicked audit in LotEventLog', @Expected = N'1', @Actual = @AudCnt;
GO

EXEC test.EndTestFile;
GO
