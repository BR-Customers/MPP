-- =============================================
-- File:         0027_PlantFloor_Machining/090_Rework_LOT_in_queue.sql
-- Author:       Blue Ridge Automation
-- Rewritten:    2026-07-23 - Trim-Storage model (v2). A rework casting re-staged in Trim
--               Storage is picked with no special handling: MachiningIn_RecordPick claims
--               it onto the line (Trim Storage -> line) and records the MachiningIn event,
--               keeping the LOT's identity (no consume / rename / close).
--               Fixture: routed casting 5G0-c eligible at MA1-5GOF; staged in TRIM1-STORE.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0027_PlantFloor_Machining/090_Rework_LOT_in_queue.sql';
GO

DECLARE @Item BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'5G0-c');
DECLARE @Line BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-5GOF');
IF NOT EXISTS (SELECT 1 FROM Parts.ItemLocation WHERE ItemId = @Item AND LocationId = @Line AND DeprecatedAt IS NULL)
    INSERT INTO Parts.ItemLocation (ItemId, LocationId, IsConsumptionPoint, CreatedAt) VALUES (@Item, @Line, 0, SYSUTCDATETIME());
DELETE pe FROM Workorder.ProductionEvent pe INNER JOIN Lots.Lot l ON l.Id = pe.LotId WHERE l.LotName = N'P5T-REWORK-090';
DELETE m FROM Lots.LotMovement m INNER JOIN Lots.Lot l ON l.Id = m.LotId WHERE l.LotName = N'P5T-REWORK-090';
DELETE h FROM Lots.LotStatusHistory h INNER JOIN Lots.Lot l ON l.Id = h.LotId WHERE l.LotName = N'P5T-REWORK-090';
DELETE eg FROM Lots.LotEventLog eg INNER JOIN Lots.Lot l ON l.Id = eg.LotId WHERE l.LotName = N'P5T-REWORK-090';
DELETE c FROM Lots.LotGenealogyClosure c INNER JOIN Lots.Lot l ON l.Id = c.AncestorLotId OR l.Id = c.DescendantLotId WHERE l.LotName = N'P5T-REWORK-090';
DELETE FROM Lots.Lot WHERE LotName = N'P5T-REWORK-090';
GO

DECLARE @Item  BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'5G0-c');
DECLARE @Line  BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-5GOF');
DECLARE @Term  BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-5GOF-MIN');
DECLARE @Store BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TRIM1-STORE');
DECLARE @Origin BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');

-- a "rework" LOT staged directly in Trim Storage (deterministic; avoids Lot_Create eligibility)
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId, CreatedAt)
VALUES (N'P5T-REWORK-090', @Item, @Origin, (SELECT Id FROM Lots.LotStatusCode WHERE Code=N'Good'), 18, 18, @Store, 1, SYSUTCDATETIME());
DECLARE @Rework BIGINT = SCOPE_IDENTITY();
INSERT INTO Lots.LotGenealogyClosure (AncestorLotId, DescendantLotId, Depth) VALUES (@Rework, @Rework, 0);
INSERT INTO Lots.LotMovement (LotId, FromLocationId, ToLocationId, MovedByUserId, MovedAt) VALUES (@Rework, NULL, @Store, 1, SYSUTCDATETIME());

-- pre-advance past DieCast/TrimIn/TrimOut so next pending is MachiningIn
INSERT INTO Workorder.ProductionEvent (LotId, OperationTemplateId, EventAt, ShotCount, AppUserId)
SELECT @Rework, rs.OperationTemplateId, SYSUTCDATETIME(), 18, 1
FROM Parts.RouteTemplate rt JOIN Parts.RouteStep rs ON rs.RouteTemplateId = rt.Id
JOIN Parts.OperationTemplate ot ON ot.Id = rs.OperationTemplateId
JOIN Parts.OperationType oty ON oty.Id = ot.OperationTypeId
WHERE rt.ItemId = @Item AND rt.PublishedAt IS NOT NULL AND rt.DeprecatedAt IS NULL
  AND oty.Code IN (N'DieCast', N'TrimIn', N'TrimOut');

DECLARE @S BIT;
CREATE TABLE #R (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R EXEC Workorder.MachiningIn_RecordPick @LotId = @Rework, @LineLocationId = @Line, @AppUserId = 1, @TerminalLocationId = @Term;
SELECT @S = Status FROM #R; DROP TABLE #R;
DECLARE @SStr NVARCHAR(10) = CAST(@S AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[Rework] MachiningIn pick succeeds for rework LOT', @Expected = N'1', @Actual = @SStr;

-- keeps identity + stays open
DECLARE @ReworkItem NVARCHAR(20) = (SELECT CAST(ItemId AS NVARCHAR(20)) FROM Lots.Lot WHERE Id = @Rework);
DECLARE @ItemStr NVARCHAR(20) = CAST(@Item AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[Rework] rework LOT keeps its Item (no rename)', @Expected = @ItemStr, @Actual = @ReworkItem;
DECLARE @ReworkStatus NVARCHAR(20) = (SELECT sc.Code FROM Lots.Lot l INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId WHERE l.Id = @Rework);
EXEC test.Assert_IsEqual @TestName = N'[Rework] rework LOT stays open after pick', @Expected = N'Good', @Actual = @ReworkStatus;

-- MachiningIn event stamped on the same LOT
DECLARE @PeCnt NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Workorder.ProductionEvent pe
    INNER JOIN Parts.OperationTemplate ot ON ot.Id = pe.OperationTemplateId
    INNER JOIN Parts.OperationType oty ON oty.Id = ot.OperationTypeId
    WHERE pe.LotId = @Rework AND oty.Code = N'MachiningIn' AND pe.TerminalLocationId = @Term);
EXEC test.Assert_IsEqual @TestName = N'[Rework] MachiningIn event stamped on the rework LOT', @Expected = N'1', @Actual = @PeCnt;
GO

-- ---- cleanup ----
DELETE pe FROM Workorder.ProductionEvent pe INNER JOIN Lots.Lot l ON l.Id = pe.LotId WHERE l.LotName = N'P5T-REWORK-090';
DELETE m FROM Lots.LotMovement m INNER JOIN Lots.Lot l ON l.Id = m.LotId WHERE l.LotName = N'P5T-REWORK-090';
DELETE h FROM Lots.LotStatusHistory h INNER JOIN Lots.Lot l ON l.Id = h.LotId WHERE l.LotName = N'P5T-REWORK-090';
DELETE eg FROM Lots.LotEventLog eg INNER JOIN Lots.Lot l ON l.Id = eg.LotId WHERE l.LotName = N'P5T-REWORK-090';
DELETE c FROM Lots.LotGenealogyClosure c INNER JOIN Lots.Lot l ON l.Id = c.AncestorLotId OR l.Id = c.DescendantLotId WHERE l.LotName = N'P5T-REWORK-090';
DELETE FROM Lots.Lot WHERE LotName = N'P5T-REWORK-090';
GO

EXEC test.EndTestFile;
GO
