-- =============================================
-- File:         0027_PlantFloor_Machining/101_Lot_GetLineInventoryByPart_scope.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-11-13
-- Description:  Lots.Lot_GetLineInventoryByPart v1.4 (stored-procedure review). Behaviour the
--               per-LOT-seek rewrite must preserve, complementing 100_ (ordering, Closed,
--               zero stock, arrival fallback):
--                 * only LOTs AT the location (a LOT at another location is not returned);
--                 * only Closed is excluded (an Open-status LOT with stock IS returned);
--                 * @ExcludeFinishedGoods = 1 drops FinishedGood items, 0 keeps them;
--                 * ArrivedAt = the LATEST movement INTO the location (a later movement to
--                   another location is ignored), converted UTC to Eastern;
--                 * NULL @LocationId returns nothing.
--               Fixture cell: MA1-COMPBR-MIN; other location: WHSE.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0027_PlantFloor_Machining/101_Lot_GetLineInventoryByPart_scope.sql';
GO

-- ---- cleanup ----
DELETE m FROM Lots.LotMovement m INNER JOIN Lots.Lot l ON l.Id = m.LotId WHERE l.LotName LIKE N'I1S-%';
DELETE FROM Lots.Lot WHERE LotName LIKE N'I1S-%';
GO

-- ---- fixture ----
DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
DECLARE @Cell  BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-MIN');
DECLARE @Other BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'WHSE');
DECLARE @PtType BIGINT = (SELECT Id FROM Parts.ItemType WHERE Code = N'PassThrough');
DECLARE @FgType BIGINT = (SELECT Id FROM Parts.ItemType WHERE Code = N'FinishedGood');
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'P-I1S-A')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId) VALUES (@PtType, N'P-I1S-A', N'I1S A purchased part', 1, @Now, 1);
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'P-I1S-FG')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId) VALUES (@FgType, N'P-I1S-FG', N'I1S B finished good', 1, @Now, 1);
DECLARE @A  BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P-I1S-A');
DECLARE @Fg BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P-I1S-FG');
DECLARE @ClosedSt BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Closed');
DECLARE @OpenSt   BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Open');

-- A:  Good at the cell, 5 on hand; movements INTO the cell 14:00 and 15:30 UTC (latest wins -> 10:30 ET)
--     and a LATER movement into another location at 18:00 (must be ignored)
-- B:  Open-status at the cell, 7 on hand, no movement -> ArrivedAt falls back to CreatedAt (now) -> sorts after A
-- C:  Closed at the cell with stock -> excluded
-- D:  Good but at ANOTHER location -> excluded
-- FG: finished good at the cell, 3 on hand
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId, CreatedAt) VALUES
    (N'I1S-A',  @A,  2, 1,         5,  5,  @Cell,  1, @Now),
    (N'I1S-B',  @A,  2, @OpenSt,   7,  7,  @Cell,  1, @Now),
    (N'I1S-C',  @A,  2, @ClosedSt, 9,  9,  @Cell,  1, @Now),
    (N'I1S-D',  @A,  2, 1,         11, 11, @Other, 1, @Now),
    (N'I1S-FG', @Fg, 1, 1,         3,  3,  @Cell,  1, @Now);

INSERT INTO Lots.LotMovement (LotId, FromLocationId, ToLocationId, MovedByUserId, TerminalLocationId, MovedAt)
SELECT l.Id, NULL, @Cell,  1, NULL, '2026-01-15 14:00:00.000' FROM Lots.Lot l WHERE l.LotName = N'I1S-A'
UNION ALL SELECT l.Id, NULL, @Cell,  1, NULL, '2026-01-15 15:30:00.000' FROM Lots.Lot l WHERE l.LotName = N'I1S-A'
UNION ALL SELECT l.Id, @Cell, @Other, 1, NULL, '2026-01-15 18:00:00.000' FROM Lots.Lot l WHERE l.LotName = N'I1S-A';
GO

DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-MIN');
DECLARE @R TABLE (RowNo INT IDENTITY(1,1), ItemId BIGINT, PartNumber NVARCHAR(50), Description NVARCHAR(500), LotId BIGINT, LotName NVARCHAR(50),
                  InventoryAvailable INT, ArrivedAt DATETIME2(3), LotStatusCode NVARCHAR(20));
DECLARE @S NVARCHAR(200);

-- everything on hand at the cell: A (earlier arrival), B (Open status, arrives now), then the finished good
INSERT INTO @R (ItemId, PartNumber, Description, LotId, LotName, InventoryAvailable, ArrivedAt, LotStatusCode)
EXEC Lots.Lot_GetLineInventoryByPart @LocationId = @Cell, @ExcludeFinishedGoods = 0;
SET @S = ISNULL((SELECT STRING_AGG(LotName, N',') WITHIN GROUP (ORDER BY RowNo) FROM @R WHERE LotName LIKE N'I1S-%'), N'<none>');
EXEC test.Assert_IsEqual @TestName = N'[LineInvByPart v1.4] at-location, not-Closed LOTs only (Open included; Closed and other-location excluded), grouped by part then arrival',
    @Expected = N'I1S-A,I1S-B,I1S-FG', @Actual = @S;
SET @S = ISNULL((SELECT CONVERT(NVARCHAR(30), ArrivedAt, 121) FROM @R WHERE LotName = N'I1S-A'), N'<null>');
EXEC test.Assert_IsEqual @TestName = N'[LineInvByPart v1.4] ArrivedAt = latest movement INTO the location (later movement elsewhere ignored), Eastern',
    @Expected = N'2026-01-15 10:30:00.000', @Actual = @S;

-- finished goods excluded on request
DELETE FROM @R;
INSERT INTO @R (ItemId, PartNumber, Description, LotId, LotName, InventoryAvailable, ArrivedAt, LotStatusCode)
EXEC Lots.Lot_GetLineInventoryByPart @LocationId = @Cell, @ExcludeFinishedGoods = 1;
SET @S = ISNULL((SELECT STRING_AGG(LotName, N',') WITHIN GROUP (ORDER BY RowNo) FROM @R WHERE LotName LIKE N'I1S-%'), N'<none>');
EXEC test.Assert_IsEqual @TestName = N'[LineInvByPart v1.4] @ExcludeFinishedGoods = 1 drops the FinishedGood LOT', @Expected = N'I1S-A,I1S-B', @Actual = @S;

-- NULL location: nothing
DELETE FROM @R;
INSERT INTO @R (ItemId, PartNumber, Description, LotId, LotName, InventoryAvailable, ArrivedAt, LotStatusCode)
EXEC Lots.Lot_GetLineInventoryByPart @LocationId = NULL;
SET @S = CAST((SELECT COUNT(*) FROM @R) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[LineInvByPart v1.4] NULL @LocationId returns nothing', @Expected = N'0', @Actual = @S;
GO

-- ---- cleanup ----
DELETE m FROM Lots.LotMovement m INNER JOIN Lots.Lot l ON l.Id = m.LotId WHERE l.LotName LIKE N'I1S-%';
DELETE FROM Lots.Lot WHERE LotName LIKE N'I1S-%';
GO

EXEC test.EndTestFile;
GO
