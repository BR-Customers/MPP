-- =============================================
-- File:         0028_PlantFloor_Assembly/096_Lot_GetComponentsAtCell.sql
-- Author:       Blue Ridge Automation
-- Description:  Lots.Lot_GetComponentsAtCell -- the "Components at this cell" read
--               for the assembly screens. Covers the ROUTELESS leg (leg 2): a
--               routeless component shows iff it is BomDerived-eligible at the cell
--               (= a BOM child of a finished good Direct-eligible here), and a
--               routeless part that is NOT a component here is excluded. Also asserts
--               the routeless rows carry NULL NextOperationTypeCode. (Leg 1, the
--               routeful/route-driven rule, is the verbatim Lot_GetWipQueueByLocation
--               logic already covered by suite 0024.)  Fixture cell: MA1-COMPBR-AOUT.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0028_PlantFloor_Assembly/096_Lot_GetComponentsAtCell.sql';
GO

-- ---- cleanup ----
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');
DELETE FROM Lots.Lot WHERE LotName LIKE N'STG-096%';
DELETE bl FROM Parts.BomLine bl INNER JOIN Parts.Bom b ON b.Id = bl.BomId
    INNER JOIN Parts.Item i ON i.Id = b.ParentItemId WHERE i.PartNumber = N'P6-GCC-FG';
DELETE b FROM Parts.Bom b INNER JOIN Parts.Item i ON i.Id = b.ParentItemId WHERE i.PartNumber = N'P6-GCC-FG';
DELETE il FROM Parts.ItemLocation il INNER JOIN Parts.Item i ON i.Id = il.ItemId
    WHERE i.PartNumber IN (N'P6-GCC-FG', N'P6-GCC-COMP', N'P6-GCC-NOISE');
GO

-- ---- fixture ----
DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');

IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'P6-GCC-FG')    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId) VALUES (4, N'P6-GCC-FG',    N'GCC finished good', 1, @Now, 1);
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'P6-GCC-COMP')  INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId) VALUES (2, N'P6-GCC-COMP',  N'GCC routeless component (in FG BOM)', 1, @Now, 1);
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'P6-GCC-NOISE') INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId) VALUES (2, N'P6-GCC-NOISE', N'GCC routeless non-component', 1, @Now, 1);

DECLARE @FG    BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-GCC-FG');
DECLARE @Comp  BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-GCC-COMP');
DECLARE @Noise BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-GCC-NOISE');

-- FG published BOM: FG <- COMP x2  (makes COMP BomDerived-eligible wherever FG is Direct-eligible)
IF NOT EXISTS (SELECT 1 FROM Parts.Bom WHERE ParentItemId = @FG AND PublishedAt IS NOT NULL AND DeprecatedAt IS NULL)
BEGIN
    INSERT INTO Parts.Bom (ParentItemId, VersionNumber, EffectiveFrom, PublishedAt, CreatedByUserId, CreatedAt) VALUES (@FG, 1, @Now, @Now, 1, @Now);
    DECLARE @BomId BIGINT = SCOPE_IDENTITY();
    INSERT INTO Parts.BomLine (BomId, ChildItemId, QtyPer, UomId, SortOrder) VALUES (@BomId, @Comp, 2, 1, 1);
END

-- FG Direct-eligible at the cell -> COMP is BomDerived-eligible there. NOISE is neither.
IF NOT EXISTS (SELECT 1 FROM Parts.ItemLocation WHERE ItemId = @FG AND LocationId = @Cell AND DeprecatedAt IS NULL)
    INSERT INTO Parts.ItemLocation (ItemId, LocationId, IsConsumptionPoint, CreatedAt) VALUES (@FG, @Cell, 0, @Now);

-- On-hand routeless LOTs at the cell: COMP (a real component) + NOISE (not a component here).
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId, CreatedAt)
VALUES (N'STG-096-COMP',  @Comp,  2, 1, 100, 100, @Cell, 1, @Now);
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId, CreatedAt)
VALUES (N'STG-096-NOISE', @Noise, 2, 1,  50,  50, @Cell, 1, @Now);
GO

-- =============================================
-- Test: routeless component shows (BomDerived-eligible), noise excluded, next-step NULL
-- =============================================
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');

DECLARE @Res TABLE (
    Id BIGINT, LotName NVARCHAR(50), ItemId BIGINT, ItemPartNumber NVARCHAR(50),
    ItemDescription NVARCHAR(500), PieceCount INT, LotStatusId BIGINT, LotStatusCode NVARCHAR(20),
    LastMovementAt DATETIME2(3), NextOperationTypeCode NVARCHAR(30), NextSequenceNumber INT);
INSERT INTO @Res EXEC Lots.Lot_GetComponentsAtCell @CellLocationId = @Cell, @IncludeDescendants = 1;

-- 1. the routeless component (in the FG's BOM) IS returned
DECLARE @CompCnt NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @Res WHERE LotName = N'STG-096-COMP');
EXEC test.Assert_IsEqual @TestName = N'[ComponentsAtCell] routeless BomDerived component shows', @Expected = N'1', @Actual = @CompCnt;

-- 2. its next-step is NULL (came via the routeless leg, not a route)
DECLARE @CompNext NVARCHAR(20) = ISNULL((SELECT NextOperationTypeCode FROM @Res WHERE LotName = N'STG-096-COMP'), N'<null>');
EXEC test.Assert_IsEqual @TestName = N'[ComponentsAtCell] routeless component has NULL NextOperationTypeCode', @Expected = N'<null>', @Actual = @CompNext;

-- 3. the routeless non-component (not eligible / not in any FG BOM here) is EXCLUDED
DECLARE @NoiseCnt NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @Res WHERE LotName = N'STG-096-NOISE');
EXEC test.Assert_IsEqual @TestName = N'[ComponentsAtCell] routeless non-component excluded', @Expected = N'0', @Actual = @NoiseCnt;
GO

-- ---- cleanup ----
DELETE FROM Lots.Lot WHERE LotName LIKE N'STG-096%';
DELETE bl FROM Parts.BomLine bl INNER JOIN Parts.Bom b ON b.Id = bl.BomId
    INNER JOIN Parts.Item i ON i.Id = b.ParentItemId WHERE i.PartNumber = N'P6-GCC-FG';
DELETE b FROM Parts.Bom b INNER JOIN Parts.Item i ON i.Id = b.ParentItemId WHERE i.PartNumber = N'P6-GCC-FG';
DELETE il FROM Parts.ItemLocation il INNER JOIN Parts.Item i ON i.Id = il.ItemId
    WHERE i.PartNumber IN (N'P6-GCC-FG', N'P6-GCC-COMP', N'P6-GCC-NOISE');
GO

-- =============================================
-- v1.2 (2026-11-13, SP review): LOT scoping + status + last-movement behaviour that the
-- heap-scan rewrite must preserve. Uses ROUTEFUL LOTs (leg 1), which need no
-- eligibility fixture. Pins: only Closed is excluded (Open is INCLUDED, unlike
-- Lot_GetWipQueueByLocation); @IncludeDescendants 0 = exact, 1 = cell + descendants,
-- NULL = nothing; LastMovementAt is the latest movement, converted to Eastern.
-- =============================================

-- ---- cleanup ----
DELETE m FROM Lots.LotMovement m INNER JOIN Lots.Lot l ON l.Id = m.LotId WHERE l.LotName LIKE N'STG-096-V2%';
DELETE FROM Lots.Lot WHERE LotName LIKE N'STG-096-V2%';
GO

-- ---- fixture ----
DECLARE @Now    DATETIME2(3) = SYSUTCDATETIME();
DECLARE @Cell   BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');
DECLARE @Parent BIGINT = (SELECT ParentLocationId FROM Location.Location WHERE Id = @Cell);
-- an Item with a published route that has a ConsumeMint step (always pending while open)
DECLARE @RItem  BIGINT = (
    SELECT TOP 1 rt.ItemId
    FROM Parts.RouteTemplate rt
    INNER JOIN Parts.RouteStep rs         ON rs.RouteTemplateId = rt.Id
    INNER JOIN Parts.OperationTemplate ot ON ot.Id = rs.OperationTemplateId
    INNER JOIN Parts.OperationType oty    ON oty.Id = ot.OperationTypeId
    INNER JOIN Parts.OperationRoleKind rk ON rk.Id = oty.OperationRoleKindId
    WHERE rt.PublishedAt IS NOT NULL AND rt.DeprecatedAt IS NULL AND rk.Code = N'ConsumeMint'
    ORDER BY rt.ItemId);

-- A: Good at the cell (latest movement 2026-01-15 15:00 UTC = 10:00 ET; an earlier one proves MAX)
-- B: Closed at the cell      -> excluded
-- C: Open (status 5) at the cell -> INCLUDED (only Closed is excluded here)
-- D: Good at the cell's PARENT -> only seen when the parent is the queried scope
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId, CreatedAt)
VALUES (N'STG-096-V2-A', @RItem, 1, 1, 10, 10, @Cell,   1, @Now),
       (N'STG-096-V2-B', @RItem, 1, 4, 10,  0, @Cell,   1, @Now),
       (N'STG-096-V2-C', @RItem, 1, 5, 10, 10, @Cell,   1, @Now),
       (N'STG-096-V2-D', @RItem, 1, 1, 10, 10, @Parent, 1, @Now);

INSERT INTO Lots.LotMovement (LotId, FromLocationId, ToLocationId, MovedByUserId, TerminalLocationId, MovedAt)
SELECT l.Id, NULL, @Cell, 1, NULL, '2026-01-15 09:00:00.000' FROM Lots.Lot l WHERE l.LotName = N'STG-096-V2-A'
UNION ALL
SELECT l.Id, NULL, @Cell, 1, NULL, '2026-01-15 15:00:00.000' FROM Lots.Lot l WHERE l.LotName = N'STG-096-V2-A';
GO

DECLARE @Cell   BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');
DECLARE @Parent BIGINT = (SELECT ParentLocationId FROM Location.Location WHERE Id = @Cell);

DECLARE @Res TABLE (
    Id BIGINT, LotName NVARCHAR(50), ItemId BIGINT, ItemPartNumber NVARCHAR(50),
    ItemDescription NVARCHAR(500), PieceCount INT, LotStatusId BIGINT, LotStatusCode NVARCHAR(20),
    LastMovementAt DATETIME2(3), NextOperationTypeCode NVARCHAR(30), NextSequenceNumber INT);
DECLARE @N NVARCHAR(10);

-- cell, exact (@IncludeDescendants = 0)
INSERT INTO @Res EXEC Lots.Lot_GetComponentsAtCell @CellLocationId = @Cell, @IncludeDescendants = 0;
SET @N = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @Res WHERE LotName = N'STG-096-V2-A');
EXEC test.Assert_IsEqual @TestName = N'[ComponentsAtCell v1.2] routeful Good LOT at the cell is returned', @Expected = N'1', @Actual = @N;
SET @N = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @Res WHERE LotName = N'STG-096-V2-B');
EXEC test.Assert_IsEqual @TestName = N'[ComponentsAtCell v1.2] Closed LOT is excluded', @Expected = N'0', @Actual = @N;
SET @N = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @Res WHERE LotName = N'STG-096-V2-C');
EXEC test.Assert_IsEqual @TestName = N'[ComponentsAtCell v1.2] Open-status LOT is INCLUDED (only Closed is excluded here)', @Expected = N'1', @Actual = @N;
SET @N = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @Res WHERE LotName = N'STG-096-V2-D');
EXEC test.Assert_IsEqual @TestName = N'[ComponentsAtCell v1.2] exact scope excludes a LOT at the parent location', @Expected = N'0', @Actual = @N;
SET @N = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @Res WHERE LotName = N'STG-096-V2-A' AND NextOperationTypeCode IS NOT NULL AND NextSequenceNumber IS NOT NULL);
EXEC test.Assert_IsEqual @TestName = N'[ComponentsAtCell v1.2] routeful LOT carries its next pending route step', @Expected = N'1', @Actual = @N;
DECLARE @Lma NVARCHAR(30) = ISNULL((SELECT CONVERT(NVARCHAR(30), LastMovementAt, 121) FROM @Res WHERE LotName = N'STG-096-V2-A'), N'<null>');
EXEC test.Assert_IsEqual @TestName = N'[ComponentsAtCell v1.2] LastMovementAt is the LATEST movement, converted UTC to Eastern', @Expected = N'2026-01-15 10:00:00.000', @Actual = @Lma;

-- parent, with descendants: parent's own LOT + the cell's LOTs (Closed still excluded)
DELETE FROM @Res;
INSERT INTO @Res EXEC Lots.Lot_GetComponentsAtCell @CellLocationId = @Parent, @IncludeDescendants = 1;
SET @N = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @Res WHERE LotName LIKE N'STG-096-V2%');
EXEC test.Assert_IsEqual @TestName = N'[ComponentsAtCell v1.2] parent + descendants returns A, C and D (not Closed B)', @Expected = N'3', @Actual = @N;

-- parent, exact: only the parent's own LOT
DELETE FROM @Res;
INSERT INTO @Res EXEC Lots.Lot_GetComponentsAtCell @CellLocationId = @Parent, @IncludeDescendants = 0;
SET @N = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @Res WHERE LotName LIKE N'STG-096-V2%');
EXEC test.Assert_IsEqual @TestName = N'[ComponentsAtCell v1.2] parent exact returns only the parent''s own LOT', @Expected = N'1', @Actual = @N;

-- NULL @IncludeDescendants matches neither arm: nothing comes back
DELETE FROM @Res;
INSERT INTO @Res EXEC Lots.Lot_GetComponentsAtCell @CellLocationId = @Cell, @IncludeDescendants = NULL;
SET @N = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @Res WHERE LotName LIKE N'STG-096-V2%');
EXEC test.Assert_IsEqual @TestName = N'[ComponentsAtCell v1.2] NULL @IncludeDescendants returns nothing', @Expected = N'0', @Actual = @N;
GO

-- ---- cleanup ----
DELETE m FROM Lots.LotMovement m INNER JOIN Lots.Lot l ON l.Id = m.LotId WHERE l.LotName LIKE N'STG-096-V2%';
DELETE FROM Lots.Lot WHERE LotName LIKE N'STG-096-V2%';
GO

EXEC test.EndTestFile;
GO
