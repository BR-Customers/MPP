-- =============================================
-- Test file: 0008_Parts_Item/020_Item_Deprecate_cascade.sql
-- Subject:   Parts.Item_Deprecate v3.0 — cascade-deprecate owned config
--            dependents; block ONLY on a live (non-terminal) LOT.
--
-- Behaviour under test (Jacques 2026-07-07 refined rule):
--   * Cascade: RouteTemplate, Bom(parent), ItemLocation, ContainerConfig are
--     soft-deleted when the Item is deprecated; each gets its own audit row and
--     the Item's audit NewValue carries the cascade counts.
--   * Hard stop: a LOT whose status is NOT Closed/Scrap blocks deprecation.
--   * Terminal (Closed/Scrap) LOTs do NOT block.
--   * The Item used as a BomLine CHILD in ANOTHER part's BOM does NOT block and
--     that foreign BOM is left untouched.
--
-- Fixture note: LOTs are inserted directly (minimal columns) to bypass
-- Lot_Create's eligibility check + genealogy-closure writes, keeping teardown a
-- simple DELETE. All fixtures use the TEST-DEPCAS- prefix.
-- EXEC params are pre-computed into @variables (no inline CAST/JSON_VALUE in EXEC).
-- =============================================

EXEC test.BeginTestFile @FileName = N'0008_Parts_Item/020_Item_Deprecate_cascade.sql';
GO

-- =============================================
-- Test 1: Cascade happy path — all four owned dependents deprecate.
-- =============================================
DECLARE @App   BIGINT = 1;
DECLARE @LocId BIGINT = (SELECT TOP 1 Id FROM Location.Location WHERE DeprecatedAt IS NULL ORDER BY Id);
DECLARE @ItemId BIGINT, @S BIT, @M NVARCHAR(500);

CREATE TABLE #ci (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #ci EXEC Parts.Item_Create
    @PartNumber = N'TEST-DEPCAS-A', @ItemTypeId = 3, @Description = N'Cascade parent',
    @UomId = 1, @AppUserId = @App;
SELECT @ItemId = NewId FROM #ci; DROP TABLE #ci;

CREATE TABLE #cr (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #cr EXEC Parts.RouteTemplate_Create @ItemId = @ItemId, @Name = N'DEPCAS route', @AppUserId = @App;
DROP TABLE #cr;

CREATE TABLE #cb (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #cb EXEC Parts.Bom_Create @ParentItemId = @ItemId, @AppUserId = @App;
DROP TABLE #cb;

CREATE TABLE #ce (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #ce EXEC Parts.ItemLocation_Add @ItemId = @ItemId, @LocationId = @LocId, @AppUserId = @App;
DROP TABLE #ce;

CREATE TABLE #cc (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #cc EXEC Parts.ContainerConfig_Create
    @ItemId = @ItemId, @TraysPerContainer = 4, @PartsPerTray = 10, @AppUserId = @App;
DROP TABLE #cc;

CREATE TABLE #dep (Status BIT, Message NVARCHAR(500));
INSERT INTO #dep EXEC Parts.Item_Deprecate @Id = @ItemId, @AppUserId = @App;
SELECT @S = Status, @M = Message FROM #dep; DROP TABLE #dep;

DECLARE @s1 NVARCHAR(1) = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName = N'[Cascade] Status is 1', @Expected = N'1', @Actual = @s1;

DECLARE @itemDep NVARCHAR(1) =
    (SELECT CASE WHEN DeprecatedAt IS NOT NULL THEN N'1' ELSE N'0' END FROM Parts.Item WHERE Id = @ItemId);
EXEC test.Assert_IsEqual @TestName = N'[Cascade] Item DeprecatedAt set', @Expected = N'1', @Actual = @itemDep;

DECLARE @rActive NVARCHAR(10) =
    (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Parts.RouteTemplate WHERE ItemId = @ItemId AND DeprecatedAt IS NULL);
EXEC test.Assert_IsEqual @TestName = N'[Cascade] no active RouteTemplate remains', @Expected = N'0', @Actual = @rActive;

DECLARE @bActive NVARCHAR(10) =
    (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Parts.Bom WHERE ParentItemId = @ItemId AND DeprecatedAt IS NULL);
EXEC test.Assert_IsEqual @TestName = N'[Cascade] no active Bom remains', @Expected = N'0', @Actual = @bActive;

DECLARE @eActive NVARCHAR(10) =
    (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Parts.ItemLocation WHERE ItemId = @ItemId AND DeprecatedAt IS NULL);
EXEC test.Assert_IsEqual @TestName = N'[Cascade] no active ItemLocation remains', @Expected = N'0', @Actual = @eActive;

DECLARE @kActive NVARCHAR(10) =
    (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Parts.ContainerConfig WHERE ItemId = @ItemId AND DeprecatedAt IS NULL);
EXEC test.Assert_IsEqual @TestName = N'[Cascade] no active ContainerConfig remains', @Expected = N'0', @Actual = @kActive;

-- Item audit NewValue carries the cascade counts.
DECLARE @NewVal NVARCHAR(MAX) = (
    SELECT TOP 1 cl.NewValue FROM Audit.ConfigLog cl
    INNER JOIN Audit.LogEntityType let ON let.Id = cl.LogEntityTypeId
    WHERE let.Code = N'Item' AND cl.EntityId = @ItemId AND cl.Description LIKE N'%Deprecated%'
    ORDER BY cl.Id DESC);
DECLARE @rCount NVARCHAR(10) = JSON_VALUE(@NewVal, '$.RoutesDeprecated');
EXEC test.Assert_IsEqual @TestName = N'[Cascade] audit NewValue RoutesDeprecated = 1', @Expected = N'1', @Actual = @rCount;
DECLARE @kCount NVARCHAR(10) = JSON_VALUE(@NewVal, '$.ContainerConfigsDeprecated');
EXEC test.Assert_IsEqual @TestName = N'[Cascade] audit NewValue ContainerConfigsDeprecated = 1', @Expected = N'1', @Actual = @kCount;

-- Per-dependent cascade audit row written in the Route's own history.
DECLARE @routeAudit NVARCHAR(10) = (
    SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Audit.ConfigLog cl
    INNER JOIN Audit.LogEntityType let ON let.Id = cl.LogEntityTypeId
    WHERE let.Code = N'Route'
      AND cl.EntityId IN (SELECT Id FROM Parts.RouteTemplate WHERE ItemId = @ItemId)
      AND cl.Description LIKE N'%Cascade-deprecated%');
EXEC test.Assert_IsEqual @TestName = N'[Cascade] per-Route cascade audit row written', @Expected = N'1', @Actual = @routeAudit;
GO

-- =============================================
-- Test 2: A live (Good) LOT blocks deprecation.
-- =============================================
DECLARE @App   BIGINT = 1;
DECLARE @LocId BIGINT = (SELECT TOP 1 Id FROM Location.Location WHERE DeprecatedAt IS NULL ORDER BY Id);
DECLARE @ItemId BIGINT, @S BIT, @M NVARCHAR(500);

CREATE TABLE #ci2 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #ci2 EXEC Parts.Item_Create
    @PartNumber = N'TEST-DEPCAS-B', @ItemTypeId = 3, @Description = N'Has live lot',
    @UomId = 1, @AppUserId = @App;
SELECT @ItemId = NewId FROM #ci2; DROP TABLE #ci2;

INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, CurrentLocationId, CreatedByUserId)
VALUES (N'TEST-DEPCAS-LOT-B', @ItemId, 1, 1 /*Good*/, 10, @LocId, @App);

CREATE TABLE #dep2 (Status BIT, Message NVARCHAR(500));
INSERT INTO #dep2 EXEC Parts.Item_Deprecate @Id = @ItemId, @AppUserId = @App;
SELECT @S = Status, @M = Message FROM #dep2; DROP TABLE #dep2;

DECLARE @s2 NVARCHAR(1) = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName = N'[ActiveLotBlocks] Status is 0', @Expected = N'0', @Actual = @s2;

DECLARE @msgMatch NVARCHAR(1) = CASE WHEN @M LIKE N'%active LOTs%' THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[ActiveLotBlocks] Message mentions active LOTs', @Expected = N'1', @Actual = @msgMatch;

DECLARE @stillActive NVARCHAR(1) =
    (SELECT CASE WHEN DeprecatedAt IS NULL THEN N'1' ELSE N'0' END FROM Parts.Item WHERE Id = @ItemId);
EXEC test.Assert_IsEqual @TestName = N'[ActiveLotBlocks] Item stays active', @Expected = N'1', @Actual = @stillActive;
GO

-- =============================================
-- Test 3: A terminal (Closed) LOT does NOT block deprecation.
-- =============================================
DECLARE @App   BIGINT = 1;
DECLARE @LocId BIGINT = (SELECT TOP 1 Id FROM Location.Location WHERE DeprecatedAt IS NULL ORDER BY Id);
DECLARE @ItemId BIGINT, @S BIT, @M NVARCHAR(500);

CREATE TABLE #ci3 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #ci3 EXEC Parts.Item_Create
    @PartNumber = N'TEST-DEPCAS-C', @ItemTypeId = 3, @Description = N'Only closed lot',
    @UomId = 1, @AppUserId = @App;
SELECT @ItemId = NewId FROM #ci3; DROP TABLE #ci3;

INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, CurrentLocationId, CreatedByUserId)
VALUES (N'TEST-DEPCAS-LOT-C', @ItemId, 1, 4 /*Closed*/, 10, @LocId, @App);

CREATE TABLE #dep3 (Status BIT, Message NVARCHAR(500));
INSERT INTO #dep3 EXEC Parts.Item_Deprecate @Id = @ItemId, @AppUserId = @App;
SELECT @S = Status, @M = Message FROM #dep3; DROP TABLE #dep3;

DECLARE @s3 NVARCHAR(1) = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName = N'[ClosedLotAllows] Status is 1', @Expected = N'1', @Actual = @s3;
GO

-- =============================================
-- Test 4: The part used as a BomLine CHILD in ANOTHER part's BOM does NOT block,
--         and that foreign parent BOM is left untouched.
-- =============================================
DECLARE @App BIGINT = 1;
DECLARE @ChildId BIGINT, @ParentId BIGINT, @BomId BIGINT, @S BIT, @M NVARCHAR(500);

CREATE TABLE #cch (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #cch EXEC Parts.Item_Create
    @PartNumber = N'TEST-DEPCAS-CHILD', @ItemTypeId = 2, @Description = N'Component child',
    @UomId = 1, @AppUserId = @App;
SELECT @ChildId = NewId FROM #cch; DROP TABLE #cch;

CREATE TABLE #cpa (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #cpa EXEC Parts.Item_Create
    @PartNumber = N'TEST-DEPCAS-PARENT', @ItemTypeId = 4, @Description = N'FG parent',
    @UomId = 1, @AppUserId = @App;
SELECT @ParentId = NewId FROM #cpa; DROP TABLE #cpa;

CREATE TABLE #cbm (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #cbm EXEC Parts.Bom_Create @ParentItemId = @ParentId, @AppUserId = @App;
SELECT @BomId = NewId FROM #cbm; DROP TABLE #cbm;

INSERT INTO Parts.BomLine (BomId, ChildItemId, QtyPer, UomId, SortOrder)
VALUES (@BomId, @ChildId, 1, 1, 0);

CREATE TABLE #dep4 (Status BIT, Message NVARCHAR(500));
INSERT INTO #dep4 EXEC Parts.Item_Deprecate @Id = @ChildId, @AppUserId = @App;
SELECT @S = Status, @M = Message FROM #dep4; DROP TABLE #dep4;

DECLARE @s4 NVARCHAR(1) = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName = N'[ForeignBomChild] child deprecates (Status 1)', @Expected = N'1', @Actual = @s4;

DECLARE @bomActive NVARCHAR(1) =
    (SELECT CASE WHEN DeprecatedAt IS NULL THEN N'1' ELSE N'0' END FROM Parts.Bom WHERE Id = @BomId);
EXEC test.Assert_IsEqual @TestName = N'[ForeignBomChild] foreign parent BOM untouched', @Expected = N'1', @Actual = @bomActive;
GO

-- =============================================
-- Cleanup (FK order: lots -> bom lines -> boms/routes/eligibility/configs -> items)
-- =============================================
DELETE FROM Lots.Lot WHERE LotName LIKE N'TEST-DEPCAS-%';
DELETE FROM Parts.BomLine
    WHERE BomId IN (SELECT Id FROM Parts.Bom WHERE ParentItemId IN
                    (SELECT Id FROM Parts.Item WHERE PartNumber LIKE N'TEST-DEPCAS-%'))
       OR ChildItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber LIKE N'TEST-DEPCAS-%');
DELETE FROM Parts.Bom             WHERE ParentItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber LIKE N'TEST-DEPCAS-%');
DELETE FROM Parts.RouteTemplate   WHERE ItemId       IN (SELECT Id FROM Parts.Item WHERE PartNumber LIKE N'TEST-DEPCAS-%');
DELETE FROM Parts.ItemLocation    WHERE ItemId       IN (SELECT Id FROM Parts.Item WHERE PartNumber LIKE N'TEST-DEPCAS-%');
DELETE FROM Parts.ContainerConfig WHERE ItemId       IN (SELECT Id FROM Parts.Item WHERE PartNumber LIKE N'TEST-DEPCAS-%');
DELETE FROM Parts.Item            WHERE PartNumber LIKE N'TEST-DEPCAS-%';
GO

EXEC test.PrintSummary;
GO
