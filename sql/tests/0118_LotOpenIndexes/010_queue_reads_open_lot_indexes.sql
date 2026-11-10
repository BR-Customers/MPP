-- =============================================
-- File:         0118_LotOpenIndexes/010_queue_reads_open_lot_indexes.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-11-10
-- Description:  Migration 0118 + Lot_GetWipQueueByLocation v3.3 +
--               Lot_GetTrimStorageQueueForLine v2.1 (prod incident 2026-11-10).
--               The rewrites seek IX_Lot_NotClosed_Location / _Item, whose filter is
--               the literal LotStatusId <> 4. This file pins what the existing queue
--               tests (0024/060, 0024/065) do not:
--                 * both indexes exist with that filter, and Closed IS Id 4;
--                 * the status set is unchanged -- a Scrap LOT (Id 3, outside the
--                   older IX_Lot_Active filter) is still listed, Closed and Open are not;
--                 * the descendant branch of the WIP read still finds a LOT below
--                   the requested location.
--               Fixture: casting 5G0-c at line MA1-5GOF, pre-advanced so its next
--               pending step is MachiningIn (same as 0024/060).
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0118_LotOpenIndexes/010_queue_reads_open_lot_indexes.sql';
GO

-- ---- indexes + the literal they depend on ----
DECLARE @f1 NVARCHAR(200) = (SELECT filter_definition FROM sys.indexes
    WHERE object_id = OBJECT_ID(N'Lots.Lot') AND name = N'IX_Lot_NotClosed_Location');
EXEC test.Assert_IsEqual N'[0118] IX_Lot_NotClosed_Location filters out Closed', N'([LotStatusId]<>(4))', @f1;
DECLARE @f2 NVARCHAR(200) = (SELECT filter_definition FROM sys.indexes
    WHERE object_id = OBJECT_ID(N'Lots.Lot') AND name = N'IX_Lot_NotClosed_Item');
EXEC test.Assert_IsEqual N'[0118] IX_Lot_NotClosed_Item filters out Closed', N'([LotStatusId]<>(4))', @f2;
DECLARE @closed NVARCHAR(20) = (SELECT Code FROM Lots.LotStatusCode WHERE Id = 4);
EXEC test.Assert_IsEqual N'[0118] LotStatusCode Id 4 is Closed (the indexes'' literal)', N'Closed', @closed;
GO

-- ---- fixture ----
DELETE pe FROM Workorder.ProductionEvent pe INNER JOIN Lots.Lot l ON l.Id = pe.LotId WHERE l.LotName = N'OI-0118';
DELETE m  FROM Lots.LotMovement m          INNER JOIN Lots.Lot l ON l.Id = m.LotId  WHERE l.LotName = N'OI-0118';
DELETE c  FROM Lots.LotGenealogyClosure c  INNER JOIN Lots.Lot l ON l.Id = c.AncestorLotId OR l.Id = c.DescendantLotId WHERE l.LotName = N'OI-0118';
DELETE FROM Lots.Lot WHERE LotName = N'OI-0118';

DECLARE @Item   BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'5G0-c');
DECLARE @Line   BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-5GOF');
DECLARE @Origin BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');
IF NOT EXISTS (SELECT 1 FROM Parts.ItemLocation WHERE ItemId = @Item AND LocationId = @Line AND DeprecatedAt IS NULL)
    INSERT INTO Parts.ItemLocation (ItemId, LocationId, IsConsumptionPoint, CreatedAt) VALUES (@Item, @Line, 0, SYSUTCDATETIME());

INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId, CreatedAt)
VALUES (N'OI-0118', @Item, @Origin, (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Scrap'), 10, 10, @Line, 1, SYSUTCDATETIME());
DECLARE @Lot BIGINT = SCOPE_IDENTITY();
INSERT INTO Lots.LotGenealogyClosure (AncestorLotId, DescendantLotId, Depth) VALUES (@Lot, @Lot, 0);
INSERT INTO Lots.LotMovement (LotId, FromLocationId, ToLocationId, MovedByUserId, MovedAt) VALUES (@Lot, NULL, @Line, 1, SYSUTCDATETIME());
INSERT INTO Workorder.ProductionEvent (LotId, OperationTemplateId, EventAt, ShotCount, AppUserId)
SELECT @Lot, rs.OperationTemplateId, SYSUTCDATETIME(), 10, 1
FROM Parts.RouteTemplate rt JOIN Parts.RouteStep rs ON rs.RouteTemplateId = rt.Id
JOIN Parts.OperationTemplate ot ON ot.Id = rs.OperationTemplateId JOIN Parts.OperationType oty ON oty.Id = ot.OperationTypeId
WHERE rt.ItemId = @Item AND rt.PublishedAt IS NOT NULL AND rt.DeprecatedAt IS NULL AND oty.Code IN (N'DieCast', N'TrimIn', N'TrimOut');
GO

-- ---- status set unchanged ----
DECLARE @Lot    BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'OI-0118');
DECLARE @Line   BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-5GOF');
DECLARE @Parent BIGINT = (SELECT ParentLocationId FROM Location.Location WHERE Id = @Line);
DECLARE @Q TABLE (Id BIGINT, LotName NVARCHAR(50), ItemId BIGINT, ItemPartNumber NVARCHAR(50), ItemDescription NVARCHAR(500),
    PieceCount INT, LotStatusId BIGINT, LotStatusCode NVARCHAR(20), LastMovementAt DATETIME2(3), NextOperationTypeCode NVARCHAR(20), NextSequenceNumber INT);
DECLARE @n NVARCHAR(10);

-- Scrap: listed by all three reads (as before v3.3 / v2.1)
DELETE FROM @Q; INSERT INTO @Q EXEC Lots.Lot_GetWipQueueByLocation @LocationId = @Line, @OperationTypeCode = N'MachiningIn';
SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @Q WHERE Id = @Lot);
EXEC test.Assert_IsEqual N'[0118] WIP exact: Scrap LOT still listed', N'1', @n;

DELETE FROM @Q; INSERT INTO @Q EXEC Lots.Lot_GetWipQueueByLocation @LocationId = @Parent, @OperationTypeCode = N'MachiningIn', @IncludeDescendants = 1;
SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @Q WHERE Id = @Lot);
EXEC test.Assert_IsEqual N'[0118] WIP descendants: LOT below the parent is listed', N'1', @n;

DELETE FROM @Q; INSERT INTO @Q EXEC Lots.Lot_GetWipQueueByLocation @LocationId = @Parent, @OperationTypeCode = N'MachiningIn', @IncludeDescendants = 0;
SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @Q WHERE Id = @Lot);
EXEC test.Assert_IsEqual N'[0118] WIP exact at the parent: LOT below it NOT listed', N'0', @n;

DELETE FROM @Q; INSERT INTO @Q EXEC Lots.Lot_GetTrimStorageQueueForLine @LineLocationId = @Line;
SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @Q WHERE Id = @Lot);
EXEC test.Assert_IsEqual N'[0118] Machining IN: Scrap LOT still listed', N'1', @n;

-- Open: excluded by both
UPDATE Lots.Lot SET LotStatusId = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Open') WHERE Id = @Lot;
DELETE FROM @Q; INSERT INTO @Q EXEC Lots.Lot_GetWipQueueByLocation @LocationId = @Line, @OperationTypeCode = N'MachiningIn';
SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @Q WHERE Id = @Lot);
EXEC test.Assert_IsEqual N'[0118] WIP: Open LOT not listed', N'0', @n;
DELETE FROM @Q; INSERT INTO @Q EXEC Lots.Lot_GetTrimStorageQueueForLine @LineLocationId = @Line;
SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @Q WHERE Id = @Lot);
EXEC test.Assert_IsEqual N'[0118] Machining IN: Open LOT not listed', N'0', @n;

-- Closed: excluded by both
UPDATE Lots.Lot SET LotStatusId = 4 WHERE Id = @Lot;
DELETE FROM @Q; INSERT INTO @Q EXEC Lots.Lot_GetWipQueueByLocation @LocationId = @Line, @OperationTypeCode = N'MachiningIn';
SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @Q WHERE Id = @Lot);
EXEC test.Assert_IsEqual N'[0118] WIP: Closed LOT not listed', N'0', @n;
DELETE FROM @Q; INSERT INTO @Q EXEC Lots.Lot_GetTrimStorageQueueForLine @LineLocationId = @Line;
SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @Q WHERE Id = @Lot);
EXEC test.Assert_IsEqual N'[0118] Machining IN: Closed LOT not listed', N'0', @n;

-- NULL location: still an empty result set of the same shape, not an error
DELETE FROM @Q; INSERT INTO @Q EXEC Lots.Lot_GetWipQueueByLocation @LocationId = NULL, @IncludeDescendants = 1;
SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @Q);
EXEC test.Assert_IsEqual N'[0118] WIP: NULL location returns no rows', N'0', @n;
GO

-- ---- cleanup ----
DELETE pe FROM Workorder.ProductionEvent pe INNER JOIN Lots.Lot l ON l.Id = pe.LotId WHERE l.LotName = N'OI-0118';
DELETE m  FROM Lots.LotMovement m          INNER JOIN Lots.Lot l ON l.Id = m.LotId  WHERE l.LotName = N'OI-0118';
DELETE c  FROM Lots.LotGenealogyClosure c  INNER JOIN Lots.Lot l ON l.Id = c.AncestorLotId OR l.Id = c.DescendantLotId WHERE l.LotName = N'OI-0118';
DELETE FROM Lots.Lot WHERE LotName = N'OI-0118';
GO

EXEC test.EndTestFile;
GO
