-- =============================================
-- File:         0027_PlantFloor_Machining/010_MachiningIn_RecordPick_happy.sql
-- Author:       Blue Ridge Automation
-- Rewritten:    2026-07-23 - Trim-Storage model (v2). Machining IN now CLAIMS a LOT
--               out of Trim Storage onto the line: the pick moves the LOT
--               Trim Storage -> line, then records the MachiningIn checkpoint. Uses the
--               routed seed casting 5G0-c (route DieCast->TrimIn->TrimOut->MachiningIn
--               [Advance]->MachiningOut[ConsumeMint]); the pre-machining steps are
--               pre-stamped so the LOT's next pending step is MachiningIn. LOT staged at
--               TRIM1-STORE; line = MA1-5GOF; terminal = MA1-5GOF-MIN.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0027_PlantFloor_Machining/010_MachiningIn_RecordPick_happy.sql';
GO

-- ---- fixture: 5G0-c eligible at the line; a whole LOT staged in Trim Storage ----
DECLARE @U     BIGINT = 1;
DECLARE @Item  BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'5G0-c');
DECLARE @Line  BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-5GOF');
DECLARE @Store BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TRIM1-STORE');
DECLARE @Origin BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');

IF NOT EXISTS (SELECT 1 FROM Parts.ItemLocation WHERE ItemId = @Item AND LocationId = @Line AND DeprecatedAt IS NULL)
    INSERT INTO Parts.ItemLocation (ItemId, LocationId, IsConsumptionPoint, CreatedAt) VALUES (@Item, @Line, 0, SYSUTCDATETIME());

DELETE pe FROM Workorder.ProductionEvent pe INNER JOIN Lots.Lot l ON l.Id = pe.LotId WHERE l.LotName = N'P5T-PICK-010';
DELETE m FROM Lots.LotMovement m INNER JOIN Lots.Lot l ON l.Id = m.LotId WHERE l.LotName = N'P5T-PICK-010';
DELETE h FROM Lots.LotStatusHistory h INNER JOIN Lots.Lot l ON l.Id = h.LotId WHERE l.LotName = N'P5T-PICK-010';
DELETE eg FROM Lots.LotEventLog eg INNER JOIN Lots.Lot l ON l.Id = eg.LotId WHERE l.LotName = N'P5T-PICK-010';
DELETE c FROM Lots.LotGenealogyClosure c INNER JOIN Lots.Lot l ON l.Id = c.AncestorLotId OR l.Id = c.DescendantLotId WHERE l.LotName = N'P5T-PICK-010';
DELETE FROM Lots.Lot WHERE LotName = N'P5T-PICK-010';
GO

-- ====================================================================
-- Test: claim from Trim Storage onto the line + record MachiningIn checkpoint
-- ====================================================================
DECLARE @Item  BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'5G0-c');
DECLARE @Line  BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-5GOF');
DECLARE @Store BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TRIM1-STORE');
DECLARE @Term  BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-5GOF-MIN');
DECLARE @Origin BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');

-- a whole LOT staged directly in Trim Storage (deterministic; avoids Lot_Create eligibility)
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId, CreatedAt)
VALUES (N'P5T-PICK-010', @Item, @Origin, (SELECT Id FROM Lots.LotStatusCode WHERE Code=N'Good'), 40, 40, @Store, 1, SYSUTCDATETIME());
DECLARE @Lot BIGINT = SCOPE_IDENTITY();
INSERT INTO Lots.LotGenealogyClosure (AncestorLotId, DescendantLotId, Depth) VALUES (@Lot, @Lot, 0);
INSERT INTO Lots.LotMovement (LotId, FromLocationId, ToLocationId, MovedByUserId, MovedAt) VALUES (@Lot, NULL, @Store, 1, SYSUTCDATETIME());

-- pre-advance past DieCast/TrimIn/TrimOut so the next pending step is MachiningIn
INSERT INTO Workorder.ProductionEvent (LotId, OperationTemplateId, EventAt, ShotCount, AppUserId)
SELECT @Lot, rs.OperationTemplateId, SYSUTCDATETIME(), 40, 1
FROM Parts.RouteTemplate rt JOIN Parts.RouteStep rs ON rs.RouteTemplateId = rt.Id
JOIN Parts.OperationTemplate ot ON ot.Id = rs.OperationTemplateId
JOIN Parts.OperationType oty ON oty.Id = ot.OperationTypeId
WHERE rt.ItemId = @Item AND rt.PublishedAt IS NOT NULL AND rt.DeprecatedAt IS NULL
  AND oty.Code IN (N'DieCast', N'TrimIn', N'TrimOut');

-- pick (claim from Trim Storage + record MachiningIn checkpoint)
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
    INNER JOIN Parts.OperationType oty ON oty.Id = ot.OperationTypeId
    WHERE pe.Id = @ProdId AND pe.LotId = @Lot AND oty.Code = N'MachiningIn' AND pe.TerminalLocationId = @Term);
EXEC test.Assert_IsEqual @TestName = N'[MachIn] MachiningIn ProductionEvent on the same LOT, at the terminal', @Expected = N'1', @Actual = @PeCnt;

-- CLAIM: the LOT moved Trim Storage -> line
DECLARE @LocNow NVARCHAR(20) = (SELECT CAST(CurrentLocationId AS NVARCHAR(20)) FROM Lots.Lot WHERE Id = @Lot);
DECLARE @LineStr NVARCHAR(20) = CAST(@Line AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[MachIn] LOT claimed onto the line (moved from Trim Storage)', @Expected = @LineStr, @Actual = @LocNow;
DECLARE @MovCnt NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Lots.LotMovement WHERE LotId = @Lot AND FromLocationId = @Store AND ToLocationId = @Line);
EXEC test.Assert_IsEqual @TestName = N'[MachIn] LotMovement Trim Storage -> line', @Expected = N'1', @Actual = @MovCnt;

-- LOT identity unchanged: same item, still Good, same piece count
DECLARE @ItemNow NVARCHAR(20) = (SELECT CAST(ItemId AS NVARCHAR(20)) FROM Lots.Lot WHERE Id = @Lot);
DECLARE @ItemExp NVARCHAR(20) = CAST(@Item AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[MachIn] LOT item unchanged (no BOM rename)', @Expected = @ItemExp, @Actual = @ItemNow;
DECLARE @StatusNow NVARCHAR(20) = (SELECT sc.Code FROM Lots.Lot l INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId WHERE l.Id = @Lot);
EXEC test.Assert_IsEqual @TestName = N'[MachIn] LOT still Good (not closed)', @Expected = N'Good', @Actual = @StatusNow;
DECLARE @PcNow NVARCHAR(10) = (SELECT CAST(PieceCount AS NVARCHAR(10)) FROM Lots.Lot WHERE Id = @Lot);
EXEC test.Assert_IsEqual @TestName = N'[MachIn] LOT piece count unchanged (40)', @Expected = N'40', @Actual = @PcNow;

-- audit: 'Lot'-entity events route to Lots.LotEventLog (B7)
DECLARE @AudCnt NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Lots.LotEventLog le
    INNER JOIN Audit.LogEventType et ON et.Id = le.LogEventTypeId
    WHERE et.Code = N'MachiningInPicked' AND le.EntityId = @Lot);
EXEC test.Assert_IsEqual @TestName = N'[MachIn] MachiningInPicked audit in LotEventLog', @Expected = N'1', @Actual = @AudCnt;
GO

-- cleanup
DELETE pe FROM Workorder.ProductionEvent pe INNER JOIN Lots.Lot l ON l.Id = pe.LotId WHERE l.LotName = N'P5T-PICK-010';
DELETE m FROM Lots.LotMovement m INNER JOIN Lots.Lot l ON l.Id = m.LotId WHERE l.LotName = N'P5T-PICK-010';
DELETE h FROM Lots.LotStatusHistory h INNER JOIN Lots.Lot l ON l.Id = h.LotId WHERE l.LotName = N'P5T-PICK-010';
DELETE eg FROM Lots.LotEventLog eg INNER JOIN Lots.Lot l ON l.Id = eg.LotId WHERE l.LotName = N'P5T-PICK-010';
DELETE c FROM Lots.LotGenealogyClosure c INNER JOIN Lots.Lot l ON l.Id = c.AncestorLotId OR l.Id = c.DescendantLotId WHERE l.LotName = N'P5T-PICK-010';
DELETE FROM Lots.Lot WHERE LotName = N'P5T-PICK-010';
GO

EXEC test.EndTestFile;
GO
