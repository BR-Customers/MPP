-- =============================================
-- File:         0027_PlantFloor_Machining/090_Rework_LOT_in_queue.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-06-19
-- Rewritten:    2026-07-06 - "unworked arrivals" model. A rework LOT routed back to
--               a machining line is treated as a fresh unworked arrival and picked
--               with no special handling; the pick records a MachiningIn event and
--               keeps the LOT's identity (no consume / rename / close).
-- Description:  A rework LOT (CurrentLocationId = a machining LINE):
--                 - appears in that line's FIFO queue as an unworked arrival
--                   (HasLineEvent=0)
--                 - MachiningIn_RecordPick succeeds; the LOT stays OPEN, same Item
--                 - after the pick it has HasLineEvent=1 and leaves the queue
--               Fixture: P5-CAST-TEST eligible at the LINE MA1-COMPBR.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0027_PlantFloor_Machining/090_Rework_LOT_in_queue.sql';
GO

-- ---- fixture (idempotent) ----
DECLARE @Now  DATETIME2(3) = SYSUTCDATETIME();
DECLARE @Line BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR');
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'P5-CAST-TEST')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId) VALUES (2, N'P5-CAST-TEST', N'Phase5 test cast/trim part', 1, @Now, 1);
DECLARE @SrcItem BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P5-CAST-TEST');
IF NOT EXISTS (SELECT 1 FROM Parts.ItemLocation WHERE ItemId = @SrcItem AND LocationId = @Line AND DeprecatedAt IS NULL)
    INSERT INTO Parts.ItemLocation (ItemId, LocationId, IsConsumptionPoint, CreatedAt) VALUES (@SrcItem, @Line, 0, @Now);
GO

-- ---- LOT cleanup ----
DELETE pe FROM Workorder.ProductionEvent pe INNER JOIN Lots.Lot l ON l.Id = pe.LotId WHERE l.ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P5-CAST-TEST');
DELETE c FROM Lots.LotGenealogyClosure c INNER JOIN Lots.Lot l ON l.Id = c.AncestorLotId OR l.Id = c.DescendantLotId WHERE l.ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P5-CAST-TEST');
DELETE m FROM Lots.LotMovement m INNER JOIN Lots.Lot l ON l.Id = m.LotId WHERE l.ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P5-CAST-TEST');
DELETE h FROM Lots.LotStatusHistory h INNER JOIN Lots.Lot l ON l.Id = h.LotId WHERE l.ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P5-CAST-TEST');
DELETE eg FROM Lots.LotEventLog eg INNER JOIN Lots.Lot l ON l.Id = eg.LotId WHERE l.ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P5-CAST-TEST');
DELETE FROM Lots.Lot WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P5-CAST-TEST');
GO

-- ====================================================================
DECLARE @Line BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR');
DECLARE @Term BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-MIN');
DECLARE @SrcItem BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P5-CAST-TEST');
DECLARE @OriginRcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');

-- a "rework" LOT: routed back to the machining line
DECLARE @Rework BIGINT;
CREATE TABLE #C (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #C EXEC Lots.Lot_Create @ItemId = @SrcItem, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @Line, @PieceCount = 18, @AppUserId = 1, @LotName = N'P5T-REWORK-090';
SELECT @Rework = NewId FROM #C; DROP TABLE #C;

-- (Queue membership before/after the pick is covered by the dedicated route-driven
--  queue test 0024/060; this file focuses on a rework LOT flowing through pick with
--  no special handling.)

-- flows through MachiningIn pick with no special handling (keeps identity)
DECLARE @S BIT;
CREATE TABLE #R (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R EXEC Workorder.MachiningIn_RecordPick @LotId = @Rework, @LineLocationId = @Line, @AppUserId = 1, @TerminalLocationId = @Term;
SELECT @S = Status FROM #R; DROP TABLE #R;
DECLARE @SStr NVARCHAR(10) = CAST(@S AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[Rework] MachiningIn pick succeeds for rework LOT', @Expected = N'1', @Actual = @SStr;

-- rework LOT keeps its identity + stays open (no consume/close)
DECLARE @ReworkItem NVARCHAR(20) = (SELECT CAST(ItemId AS NVARCHAR(20)) FROM Lots.Lot WHERE Id = @Rework);
DECLARE @SrcItemStr NVARCHAR(20) = CAST(@SrcItem AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[Rework] rework LOT keeps its Item (no rename)', @Expected = @SrcItemStr, @Actual = @ReworkItem;

DECLARE @ReworkStatus NVARCHAR(20) = (SELECT sc.Code FROM Lots.Lot l INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId WHERE l.Id = @Rework);
EXEC test.Assert_IsEqual @TestName = N'[Rework] rework LOT stays open after pick', @Expected = N'Good', @Actual = @ReworkStatus;

-- the MachiningIn ProductionEvent exists on the same LOT (advances it in the route-driven queue)
DECLARE @PeCnt NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Workorder.ProductionEvent pe
    INNER JOIN Parts.OperationTemplate ot ON ot.Id = pe.OperationTemplateId
    WHERE pe.LotId = @Rework AND ot.Code = N'MachiningIn');
EXEC test.Assert_IsEqual @TestName = N'[Rework] MachiningIn event stamped on the rework LOT', @Expected = N'1', @Actual = @PeCnt;
GO

-- ---- cleanup ----
DELETE pe FROM Workorder.ProductionEvent pe INNER JOIN Lots.Lot l ON l.Id = pe.LotId WHERE l.ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P5-CAST-TEST');
DELETE c FROM Lots.LotGenealogyClosure c INNER JOIN Lots.Lot l ON l.Id = c.AncestorLotId OR l.Id = c.DescendantLotId WHERE l.ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P5-CAST-TEST');
DELETE m FROM Lots.LotMovement m INNER JOIN Lots.Lot l ON l.Id = m.LotId WHERE l.ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P5-CAST-TEST');
DELETE h FROM Lots.LotStatusHistory h INNER JOIN Lots.Lot l ON l.Id = h.LotId WHERE l.ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P5-CAST-TEST');
DELETE eg FROM Lots.LotEventLog eg INNER JOIN Lots.Lot l ON l.Id = eg.LotId WHERE l.ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P5-CAST-TEST');
DELETE FROM Lots.Lot WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P5-CAST-TEST');
GO

EXEC test.EndTestFile;
GO
