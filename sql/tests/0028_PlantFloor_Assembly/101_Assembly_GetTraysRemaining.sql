-- =============================================
-- File:         0028_PlantFloor_Assembly/101_Assembly_GetTraysRemaining.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-10-06
-- Description:  Workorder.Assembly_GetTraysRemaining -- how many more trays of a
--               finished good the line can close before a purchased part runs out
--               (Assembly OUT low-inventory lock,
--               docs/superpowers/specs/2026-10-06-assembly-out-low-inventory-lock-design.md).
--               Cases:
--                 1) BOM part, no stock: one row per PassThrough child, 0 trays,
--                    short; the Component child is not listed;
--                 2) exactly 3 trays left is short, 4 is not; shortest first;
--                 3) a HELD LOT is not counted;
--                 4) topping the short part up to 4 trays clears it;
--                 5) no-BOM repack part: the part itself, received stock only --
--                    a Manufactured tray LOT of the same part is not counted;
--                 6) no pack-out for the closure method / NULL part -> empty set;
--                 7) migration 0106 seeded the Low Inventory downtime reason.
--               Fixture cell: MA1-COMPBR-AOUT (assembly-out).
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0028_PlantFloor_Assembly/101_Assembly_GetTraysRemaining.sql';
GO

-- ---- cleanup ----
DELETE c FROM Lots.LotGenealogyClosure c INNER JOIN Lots.Lot l ON l.Id = c.AncestorLotId OR l.Id = c.DescendantLotId WHERE l.LotName LIKE N'STG-101%';
DELETE FROM Lots.Lot WHERE LotName LIKE N'STG-101%';
GO

-- ---- fixture ----
--   P6-TRL-FG  FinishedGood, ByCount, 10 parts per tray, published BOM:
--     P6-TRL-PT1  PassThrough  QtyPer 2  -> 20 per tray
--     P6-TRL-PT2  PassThrough  QtyPer 1  -> 10 per tray, BoxQuantity 500
--     P6-TRL-CMP  Component    QtyPer 1  -> not a purchased part, never listed
--   P6-TRL-RPK FinishedGood, ByCount, 24 parts per tray, NO BOM (pass-through repack)
DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
DECLARE @FgType BIGINT = (SELECT Id FROM Parts.ItemType WHERE Code = N'FinishedGood');
DECLARE @PtType BIGINT = (SELECT Id FROM Parts.ItemType WHERE Code = N'PassThrough');
DECLARE @CmpType BIGINT = (SELECT Id FROM Parts.ItemType WHERE Code = N'Component');
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'P6-TRL-FG')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId) VALUES (@FgType, N'P6-TRL-FG', N'101 finished good', 1, @Now, 1);
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'P6-TRL-PT1')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId) VALUES (@PtType, N'P6-TRL-PT1', N'101 dowel pin', 1, @Now, 1);
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'P6-TRL-PT2')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, BoxQuantity, CreatedAt, CreatedByUserId) VALUES (@PtType, N'P6-TRL-PT2', N'101 bolt', 1, 500, @Now, 1);
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'P6-TRL-CMP')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId) VALUES (@CmpType, N'P6-TRL-CMP', N'101 casting', 1, @Now, 1);
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'P6-TRL-RPK')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId) VALUES (@FgType, N'P6-TRL-RPK', N'101 repack part', 1, @Now, 1);

DECLARE @Fg  BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-TRL-FG');
DECLARE @Pt1 BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-TRL-PT1');
DECLARE @Pt2 BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-TRL-PT2');
DECLARE @Cmp BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-TRL-CMP');
DECLARE @Rpk BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-TRL-RPK');

IF NOT EXISTS (SELECT 1 FROM Parts.ContainerConfig WHERE ItemId = @Fg AND DeprecatedAt IS NULL)
    INSERT INTO Parts.ContainerConfig (ItemId, TraysPerContainer, PartsPerTray, IsSerialized, ClosureMethod, CreatedAt) VALUES (@Fg, 4, 10, 0, N'ByCount', @Now);
IF NOT EXISTS (SELECT 1 FROM Parts.ContainerConfig WHERE ItemId = @Rpk AND DeprecatedAt IS NULL)
    INSERT INTO Parts.ContainerConfig (ItemId, TraysPerContainer, PartsPerTray, IsSerialized, ClosureMethod, CreatedAt) VALUES (@Rpk, 4, 24, 0, N'ByCount', @Now);

IF NOT EXISTS (SELECT 1 FROM Parts.Bom WHERE ParentItemId = @Fg)
BEGIN
    INSERT INTO Parts.Bom (ParentItemId, VersionNumber, EffectiveFrom, PublishedAt, CreatedByUserId, CreatedAt) VALUES (@Fg, 1, @Now, @Now, 1, @Now);
    DECLARE @BomId BIGINT = SCOPE_IDENTITY();
    INSERT INTO Parts.BomLine (BomId, ChildItemId, QtyPer, UomId, SortOrder) VALUES
        (@BomId, @Pt1, 2, 1, 1), (@BomId, @Pt2, 1, 1, 2), (@BomId, @Cmp, 1, 1, 3);
END
GO

-- =============================================
-- Test 1: BOM part, no stock.
-- =============================================
DECLARE @Fg BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-TRL-FG');
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');
DECLARE @R TABLE (ItemId BIGINT, PartNumber NVARCHAR(50), Description NVARCHAR(500), BoxQuantity INT, PiecesPerTray INT, Available INT, TraysLeft INT, IsShort BIT, ThresholdTrays INT);
INSERT INTO @R EXEC Workorder.Assembly_GetTraysRemaining @CellLocationId = @Cell, @FinishedGoodItemId = @Fg, @ClosureMethod = N'ByCount';

DECLARE @Parts NVARCHAR(200) = (SELECT STRING_AGG(PartNumber, N',') WITHIN GROUP (ORDER BY PartNumber) FROM @R);
EXEC test.Assert_IsEqual @TestName = N'[TraysLeft] only the purchased BOM children are listed', @Expected = N'P6-TRL-PT1,P6-TRL-PT2', @Actual = @Parts;
DECLARE @Shape NVARCHAR(200) = (SELECT STRING_AGG(PartNumber + N':' + CAST(PiecesPerTray AS NVARCHAR(10)) + N'/' + CAST(Available AS NVARCHAR(10)) + N'/' + CAST(TraysLeft AS NVARCHAR(10)) + N'/' + CAST(IsShort AS NVARCHAR(1)), N' ') WITHIN GROUP (ORDER BY PartNumber) FROM @R);
EXEC test.Assert_IsEqual @TestName = N'[TraysLeft] no stock: pieces per tray from QtyPer x PartsPerTray, 0 trays, short', @Expected = N'P6-TRL-PT1:20/0/0/1 P6-TRL-PT2:10/0/0/1', @Actual = @Shape;
DECLARE @Box NVARCHAR(40) = (SELECT ISNULL(CAST(MAX(CASE WHEN PartNumber = N'P6-TRL-PT1' THEN BoxQuantity END) AS NVARCHAR(10)), N'null') + N'/' + CAST(MAX(CASE WHEN PartNumber = N'P6-TRL-PT2' THEN BoxQuantity END) AS NVARCHAR(10)) + N'/' + CAST(MIN(ThresholdTrays) AS NVARCHAR(10)) FROM @R);
EXEC test.Assert_IsEqual @TestName = N'[TraysLeft] box quantity and the 3-tray threshold are returned', @Expected = N'null/500/3', @Actual = @Box;
GO

-- =============================================
-- Test 2 + 3: PT1 80 = 4 trays (ok). PT2 30 = 3 trays (short), plus a HELD 100 that
--             must not count. Shortest first.
-- =============================================
DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
DECLARE @Fg  BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-TRL-FG');
DECLARE @Pt1 BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-TRL-PT1');
DECLARE @Pt2 BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-TRL-PT2');
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId, CreatedAt) VALUES
    (N'STG-101A', @Pt1, 2, 1, 80, 80, @Cell, 1, @Now),
    (N'STG-101B', @Pt2, 2, 1, 30, 30, @Cell, 1, @Now),
    (N'STG-101H', @Pt2, 2, 2, 100, 100, @Cell, 1, @Now);   -- LotStatusId 2 = Hold (BlocksProduction)

DECLARE @R TABLE (ItemId BIGINT, PartNumber NVARCHAR(50), Description NVARCHAR(500), BoxQuantity INT, PiecesPerTray INT, Available INT, TraysLeft INT, IsShort BIT, ThresholdTrays INT, Seq INT IDENTITY(1,1));
INSERT INTO @R (ItemId, PartNumber, Description, BoxQuantity, PiecesPerTray, Available, TraysLeft, IsShort, ThresholdTrays)
    EXEC Workorder.Assembly_GetTraysRemaining @CellLocationId = @Cell, @FinishedGoodItemId = @Fg, @ClosureMethod = N'ByCount';
DECLARE @Shape NVARCHAR(200) = (SELECT STRING_AGG(PartNumber + N':' + CAST(Available AS NVARCHAR(10)) + N'/' + CAST(TraysLeft AS NVARCHAR(10)) + N'/' + CAST(IsShort AS NVARCHAR(1)), N' ') WITHIN GROUP (ORDER BY Seq) FROM @R);
EXEC test.Assert_IsEqual @TestName = N'[TraysLeft] 3 trays is short, 4 is not, held stock ignored, shortest first', @Expected = N'P6-TRL-PT2:30/3/1 P6-TRL-PT1:80/4/0', @Actual = @Shape;
GO

-- =============================================
-- Test 4: one more box of the short part -> 40 = 4 trays -> nothing short.
-- =============================================
DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
DECLARE @Fg  BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-TRL-FG');
DECLARE @Pt2 BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-TRL-PT2');
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId, CreatedAt)
VALUES (N'STG-101C', @Pt2, 2, 1, 10, 10, @Cell, 1, @Now);
DECLARE @R TABLE (ItemId BIGINT, PartNumber NVARCHAR(50), Description NVARCHAR(500), BoxQuantity INT, PiecesPerTray INT, Available INT, TraysLeft INT, IsShort BIT, ThresholdTrays INT);
INSERT INTO @R EXEC Workorder.Assembly_GetTraysRemaining @CellLocationId = @Cell, @FinishedGoodItemId = @Fg, @ClosureMethod = N'ByCount';
DECLARE @Short NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @R WHERE IsShort = 1);
EXEC test.Assert_IsEqual @TestName = N'[TraysLeft] topped up to 4 trays -> nothing short', @Expected = N'0', @Actual = @Short;
GO

-- =============================================
-- Test 5: repack part. Received 48 + ReceivedOffsite 24 = 72 = 3 trays (short).
--         A Manufactured LOT of the same part (a tray this station already
--         packed) is NOT stock.
-- =============================================
DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
DECLARE @Rpk BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-TRL-RPK');
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId, CreatedAt) VALUES
    (N'STG-101R1', @Rpk, 2, 1, 48, 48, @Cell, 1, @Now),
    (N'STG-101R2', @Rpk, 3, 1, 24, 24, @Cell, 1, @Now),
    (N'STG-101RM', @Rpk, 1, 1, 24, 24, @Cell, 1, @Now);   -- Manufactured: a packed tray
DECLARE @R TABLE (ItemId BIGINT, PartNumber NVARCHAR(50), Description NVARCHAR(500), BoxQuantity INT, PiecesPerTray INT, Available INT, TraysLeft INT, IsShort BIT, ThresholdTrays INT);
INSERT INTO @R EXEC Workorder.Assembly_GetTraysRemaining @CellLocationId = @Cell, @FinishedGoodItemId = @Rpk, @ClosureMethod = N'ByCount';
DECLARE @Shape NVARCHAR(200) = (SELECT STRING_AGG(PartNumber + N':' + CAST(PiecesPerTray AS NVARCHAR(10)) + N'/' + CAST(Available AS NVARCHAR(10)) + N'/' + CAST(TraysLeft AS NVARCHAR(10)) + N'/' + CAST(IsShort AS NVARCHAR(1)), N' ') FROM @R);
EXEC test.Assert_IsEqual @TestName = N'[TraysLeft] repack: the part itself, received stock only', @Expected = N'P6-TRL-RPK:24/72/3/1', @Actual = @Shape;
GO

-- =============================================
-- Test 6: nothing to calculate -> empty set.
-- =============================================
DECLARE @Fg BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-TRL-FG');
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');
DECLARE @R TABLE (ItemId BIGINT, PartNumber NVARCHAR(50), Description NVARCHAR(500), BoxQuantity INT, PiecesPerTray INT, Available INT, TraysLeft INT, IsShort BIT, ThresholdTrays INT);
INSERT INTO @R EXEC Workorder.Assembly_GetTraysRemaining @CellLocationId = @Cell, @FinishedGoodItemId = @Fg, @ClosureMethod = N'ByWeight';
INSERT INTO @R EXEC Workorder.Assembly_GetTraysRemaining @CellLocationId = @Cell, @FinishedGoodItemId = NULL, @ClosureMethod = N'ByCount';
INSERT INTO @R EXEC Workorder.Assembly_GetTraysRemaining @CellLocationId = NULL, @FinishedGoodItemId = @Fg, @ClosureMethod = N'ByCount';
DECLARE @N NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @R);
EXEC test.Assert_IsEqual @TestName = N'[TraysLeft] no pack-out for the method / NULL part / NULL cell -> empty set', @Expected = N'0', @Actual = @N;
GO

-- =============================================
-- Test 7: migration 0106 -- the Low Inventory downtime reason.
-- =============================================
DECLARE @Reason NVARCHAR(200) = (
    SELECT rc.Description + N'/' + oc.Code + N'/' + src.Code + N'/' + CAST(rc.IsExcused AS NVARCHAR(1))
    FROM Oee.DowntimeReasonCode rc
    INNER JOIN Parts.OperationCategory oc ON oc.Id = rc.OperationCategoryId
    INNER JOIN Oee.DowntimeSourceCode src ON src.Id = rc.DowntimeSourceCodeId
    WHERE rc.Code = N'MA-LOWINV' AND rc.DeprecatedAt IS NULL);
EXEC test.Assert_IsEqual @TestName = N'[TraysLeft] Low Inventory downtime reason is seeded', @Expected = N'Low Inventory/MachiningAssembly/System/0', @Actual = @Reason;
GO

-- ---- cleanup ----
DELETE c FROM Lots.LotGenealogyClosure c INNER JOIN Lots.Lot l ON l.Id = c.AncestorLotId OR l.Id = c.DescendantLotId WHERE l.LotName LIKE N'STG-101%';
DELETE FROM Lots.Lot WHERE LotName LIKE N'STG-101%';
GO
