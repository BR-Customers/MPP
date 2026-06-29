-- =============================================
-- File:         0028_PlantFloor_Assembly/076_Assembly_ScanIn.sql
-- Description:  Workorder.Assembly_ScanIn (Arc 2 Phase 6 / FDS-06-008 uncoupled path).
--               Moves a component LOT into an Assembly Cell's queue (LotMovement, no
--               rename). A LOT whose Item is a BOM component of an assembly produced at
--               the cell scans in (Status 1); a non-component LOT rejects (Status 0,
--               not moved). Uses MA1-5GOR-ASER as the assembly cell, MA1-5GOF-MOUT as the
--               source location.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0028_PlantFloor_Assembly/076_Assembly_ScanIn.sql';
GO

DELETE FROM Lots.LotMovement WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName IN (N'SCAN-076A', N'SCAN-076B', N'SCAN-076C'));
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName IN (N'SCAN-076A', N'SCAN-076B', N'SCAN-076C'));
DELETE FROM Lots.Lot WHERE LotName IN (N'SCAN-076A', N'SCAN-076B', N'SCAN-076C');
GO

DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'P6-SCAN-OUT') INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId) VALUES (3, N'P6-SCAN-OUT', N'Phase6 scan-in test assembly', 1, @Now, 1);
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'P6-SCAN-CHILD') INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId) VALUES (3, N'P6-SCAN-CHILD', N'Phase6 scan-in test component', 1, @Now, 1);
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'P6-SCAN-OTHER') INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId) VALUES (3, N'P6-SCAN-OTHER', N'Phase6 scan-in non-component', 1, @Now, 1);
DECLARE @Out BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-SCAN-OUT');
DECLARE @Child BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-SCAN-CHILD');
DECLARE @Other BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-SCAN-OTHER');

-- published BOM: P6-SCAN-OUT <- P6-SCAN-CHILD x1
IF NOT EXISTS (SELECT 1 FROM Parts.Bom WHERE ParentItemId = @Out AND PublishedAt IS NOT NULL AND DeprecatedAt IS NULL)
BEGIN
    INSERT INTO Parts.Bom (ParentItemId, VersionNumber, EffectiveFrom, PublishedAt, CreatedByUserId, CreatedAt) VALUES (@Out, 1, @Now, @Now, 1, @Now);
    INSERT INTO Parts.BomLine (BomId, ChildItemId, QtyPer, UomId, SortOrder) VALUES (SCOPE_IDENTITY(), @Child, 1, 1, 1);
END

DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-5GOR-ASER');     -- the assembly cell
DECLARE @SrcCell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-5GOF-MOUT');  -- where the LOTs start
-- P6-SCAN-OUT is produced at the assembly cell (IsConsumptionPoint = 0)
IF NOT EXISTS (SELECT 1 FROM Parts.ItemLocation WHERE ItemId = @Out AND LocationId = @Cell AND DeprecatedAt IS NULL)
    INSERT INTO Parts.ItemLocation (ItemId, LocationId, CreatedAt, IsConsumptionPoint) VALUES (@Out, @Cell, @Now, 0);

INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, CurrentLocationId, CreatedByUserId) VALUES (N'SCAN-076A', @Child, 1, 1, 48, @SrcCell, 1);
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, CurrentLocationId, CreatedByUserId) VALUES (N'SCAN-076B', @Other, 1, 1, 48, @SrcCell, 1);
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, CurrentLocationId, CreatedByUserId) VALUES (N'SCAN-076C', @Child, 1, 1, 24, @SrcCell, 1);
DECLARE @ChildLot BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'SCAN-076A');
DECLARE @OtherLot BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'SCAN-076B');

-- scan the component LOT into the assembly cell
DECLARE @R TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @R EXEC Workorder.Assembly_ScanIn @LotId = @ChildLot, @CellLocationId = @Cell, @AppUserId = 1;
DECLARE @S1 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @R);
EXEC test.Assert_IsEqual @TestName = N'[ScanIn] component LOT scans in (Status 1)', @Expected = N'1', @Actual = @S1;
DECLARE @AtCell NVARCHAR(10) = (SELECT CASE WHEN CurrentLocationId = @Cell THEN N'1' ELSE N'0' END FROM Lots.Lot WHERE Id = @ChildLot);
EXEC test.Assert_IsEqual @TestName = N'[ScanIn] LOT CurrentLocationId is now the assembly cell', @Expected = N'1', @Actual = @AtCell;
DECLARE @MoveOk NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Lots.LotMovement WHERE LotId = @ChildLot AND ToLocationId = @Cell);
EXEC test.Assert_IsEqual @TestName = N'[ScanIn] LotMovement into the cell recorded', @Expected = N'1', @Actual = @MoveOk;
DECLARE @ItemKept NVARCHAR(10) = (SELECT CASE WHEN ItemId = @Child THEN N'1' ELSE N'0' END FROM Lots.Lot WHERE Id = @ChildLot);
EXEC test.Assert_IsEqual @TestName = N'[ScanIn] no rename — ItemId unchanged', @Expected = N'1', @Actual = @ItemKept;

-- scan a non-component LOT -> reject
DELETE FROM @R;
INSERT INTO @R EXEC Workorder.Assembly_ScanIn @LotId = @OtherLot, @CellLocationId = @Cell, @AppUserId = 1;
DECLARE @S2 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @R);
EXEC test.Assert_IsEqual @TestName = N'[ScanIn] non-component LOT rejects (Status 0)', @Expected = N'0', @Actual = @S2;
DECLARE @NotMoved NVARCHAR(10) = (SELECT CASE WHEN CurrentLocationId = @SrcCell THEN N'1' ELSE N'0' END FROM Lots.Lot WHERE Id = @OtherLot);
EXEC test.Assert_IsEqual @TestName = N'[ScanIn] rejected LOT not moved', @Expected = N'1', @Actual = @NotMoved;

-- scan a component LOT by its LTT (LotName) instead of id -> resolves + moves in
DECLARE @R3 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @R3 EXEC Workorder.Assembly_ScanIn @LotName = N'SCAN-076C', @CellLocationId = @Cell, @AppUserId = 1;
DECLARE @S3 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @R3);
EXEC test.Assert_IsEqual @TestName = N'[ScanIn] scan by LotName (LTT) resolves + moves in (Status 1)', @Expected = N'1', @Actual = @S3;
DECLARE @CAtCell NVARCHAR(10) = (SELECT CASE WHEN CurrentLocationId = @Cell THEN N'1' ELSE N'0' END FROM Lots.Lot WHERE LotName = N'SCAN-076C');
EXEC test.Assert_IsEqual @TestName = N'[ScanIn] LotName-scanned LOT now at the cell', @Expected = N'1', @Actual = @CAtCell;
GO

DELETE FROM Lots.LotMovement WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName IN (N'SCAN-076A', N'SCAN-076B', N'SCAN-076C'));
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName IN (N'SCAN-076A', N'SCAN-076B', N'SCAN-076C'));
DELETE FROM Lots.Lot WHERE LotName IN (N'SCAN-076A', N'SCAN-076B', N'SCAN-076C');
GO

EXEC test.EndTestFile;
GO
