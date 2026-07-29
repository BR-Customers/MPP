-- =============================================
-- File:         0024_PlantFloor_Movement_Trim/065_Lot_GetTrimStorageQueueForLine.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-07-23
-- Description:  Tests for Lots.Lot_GetTrimStorageQueueForLine (Trim-Storage model). A LOT
--               sitting in Trim Storage whose next-pending route step is MachiningIn shows
--               up at a line ONLY when its Item is eligible there; a part eligible at two
--               lines appears in BOTH lines' reads (the two-line case); claiming it onto one
--               line (move off Trim Storage) removes it from both. Fixture: routed casting
--               5G0-c staged in TRIM1-STORE, made eligible at MA1-5GOF AND MA1-5GOR (two
--               lines), NOT at MA1-6MD.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0024_PlantFloor_Movement_Trim/065_Lot_GetTrimStorageQueueForLine.sql';
GO

DECLARE @Item BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'5G0-c');
DECLARE @LineA BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-5GOF');
DECLARE @LineB BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-5GOR');
-- eligible at both lines (the two-line part)
IF NOT EXISTS (SELECT 1 FROM Parts.ItemLocation WHERE ItemId=@Item AND LocationId=@LineA AND DeprecatedAt IS NULL) INSERT INTO Parts.ItemLocation (ItemId, LocationId, IsConsumptionPoint, CreatedAt) VALUES (@Item, @LineA, 0, SYSUTCDATETIME());
IF NOT EXISTS (SELECT 1 FROM Parts.ItemLocation WHERE ItemId=@Item AND LocationId=@LineB AND DeprecatedAt IS NULL) INSERT INTO Parts.ItemLocation (ItemId, LocationId, IsConsumptionPoint, CreatedAt) VALUES (@Item, @LineB, 0, SYSUTCDATETIME());
DELETE pe FROM Workorder.ProductionEvent pe INNER JOIN Lots.Lot l ON l.Id=pe.LotId WHERE l.LotName=N'TS-065';
DELETE m FROM Lots.LotMovement m INNER JOIN Lots.Lot l ON l.Id=m.LotId WHERE l.LotName=N'TS-065';
DELETE h FROM Lots.LotStatusHistory h INNER JOIN Lots.Lot l ON l.Id=h.LotId WHERE l.LotName=N'TS-065';
DELETE c FROM Lots.LotGenealogyClosure c INNER JOIN Lots.Lot l ON l.Id=c.AncestorLotId OR l.Id=c.DescendantLotId WHERE l.LotName=N'TS-065';
DELETE FROM Lots.Lot WHERE LotName=N'TS-065';
GO

DECLARE @Item  BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'5G0-c');
DECLARE @LineA BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-5GOF');
DECLARE @LineB BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-5GOR');
DECLARE @LineC BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-6MD');   -- 5G0-c NOT eligible here
DECLARE @TermA BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-5GOF-MIN');
DECLARE @Store BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TRIM1-STORE');
DECLARE @Origin BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');

INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId, CreatedAt)
VALUES (N'TS-065', @Item, @Origin, (SELECT Id FROM Lots.LotStatusCode WHERE Code=N'Good'), 30, 30, @Store, 1, SYSUTCDATETIME());
DECLARE @Lot BIGINT = SCOPE_IDENTITY();
INSERT INTO Lots.LotGenealogyClosure (AncestorLotId, DescendantLotId, Depth) VALUES (@Lot, @Lot, 0);
INSERT INTO Lots.LotMovement (LotId, FromLocationId, ToLocationId, MovedByUserId, MovedAt) VALUES (@Lot, NULL, @Store, 1, SYSUTCDATETIME());
-- pre-advance to MachiningIn-pending
INSERT INTO Workorder.ProductionEvent (LotId, OperationTemplateId, EventAt, ShotCount, AppUserId)
SELECT @Lot, rs.OperationTemplateId, SYSUTCDATETIME(), 30, 1
FROM Parts.RouteTemplate rt JOIN Parts.RouteStep rs ON rs.RouteTemplateId=rt.Id
JOIN Parts.OperationTemplate ot ON ot.Id=rs.OperationTemplateId JOIN Parts.OperationType oty ON oty.Id=ot.OperationTypeId
WHERE rt.ItemId=@Item AND rt.PublishedAt IS NOT NULL AND rt.DeprecatedAt IS NULL AND oty.Code IN (N'DieCast',N'TrimIn',N'TrimOut');

DECLARE @Q TABLE (Id BIGINT, LotName NVARCHAR(50), ItemId BIGINT, ItemPartNumber NVARCHAR(50), ItemDescription NVARCHAR(500),
    PieceCount INT, LotStatusId BIGINT, LotStatusCode NVARCHAR(20), LastMovementAt DATETIME2(3), NextOperationTypeCode NVARCHAR(20), NextSequenceNumber INT);

-- present at line A
DELETE FROM @Q; INSERT INTO @Q EXEC Lots.Lot_GetTrimStorageQueueForLine @LineLocationId=@LineA;
DECLARE @a NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @Q WHERE Id=@Lot);
EXEC test.Assert_IsEqual @TestName=N'[TSQueue] LOT visible at eligible line A', @Expected=N'1', @Actual=@a;
-- present at line B (two-line part)
DELETE FROM @Q; INSERT INTO @Q EXEC Lots.Lot_GetTrimStorageQueueForLine @LineLocationId=@LineB;
DECLARE @b NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @Q WHERE Id=@Lot);
EXEC test.Assert_IsEqual N'[TSQueue] LOT visible at eligible line B too (two-line part)', N'1', @b;
-- absent at line C (not eligible)
DELETE FROM @Q; INSERT INTO @Q EXEC Lots.Lot_GetTrimStorageQueueForLine @LineLocationId=@LineC;
DECLARE @c NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @Q WHERE Id=@Lot);
EXEC test.Assert_IsEqual N'[TSQueue] LOT NOT visible at ineligible line C', N'0', @c;

-- claim onto line A -> leaves Trim Storage -> gone from BOTH queues
DECLARE @R TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @R EXEC Workorder.MachiningIn_RecordPick @LotId=@Lot, @LineLocationId=@LineA, @AppUserId=1, @TerminalLocationId=@TermA;
DECLARE @claimS NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @R);
EXEC test.Assert_IsEqual N'[TSQueue] claim onto line A succeeds', N'1', @claimS;
DELETE FROM @Q; INSERT INTO @Q EXEC Lots.Lot_GetTrimStorageQueueForLine @LineLocationId=@LineB;
DECLARE @b2 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @Q WHERE Id=@Lot);
EXEC test.Assert_IsEqual N'[TSQueue] after claim, LOT gone from line B queue (no longer in Trim Storage)', N'0', @b2;
GO

-- cleanup
DELETE pe FROM Workorder.ProductionEvent pe INNER JOIN Lots.Lot l ON l.Id=pe.LotId WHERE l.LotName=N'TS-065';
DELETE m FROM Lots.LotMovement m INNER JOIN Lots.Lot l ON l.Id=m.LotId WHERE l.LotName=N'TS-065';
DELETE h FROM Lots.LotStatusHistory h INNER JOIN Lots.Lot l ON l.Id=h.LotId WHERE l.LotName=N'TS-065';
DELETE eg FROM Lots.LotEventLog eg INNER JOIN Lots.Lot l ON l.Id=eg.LotId WHERE l.LotName=N'TS-065';
DELETE c FROM Lots.LotGenealogyClosure c INNER JOIN Lots.Lot l ON l.Id=c.AncestorLotId OR l.Id=c.DescendantLotId WHERE l.LotName=N'TS-065';
DELETE FROM Lots.Lot WHERE LotName=N'TS-065';
GO

EXEC test.EndTestFile;
GO
