-- =============================================
-- File:         0009_Parts_Process/030_ItemLocation_crud.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-04-14
-- Description:
--   Tests for Parts.ItemLocation eligibility junction procs:
--     Parts.ItemLocation_ListByItem
--     Parts.ItemLocation_ListByLocation
--     Parts.ItemLocation_Add
--     Parts.ItemLocation_Remove
--
--   Covers: add happy path, idempotent re-add (same pair), invalid
--   ItemId/LocationId, list by item and location, remove happy +
--   remove-twice rejection, reactivation of a deprecated pairing
--   (Add returns the SAME Id), and ConfigLog audit trail.
--
--   Pre-conditions:
--     - Migration 0001-0006 applied
--     - AppUser Id=1 exists
--     - MPP plant seed (011): at least two active DieCastMachine cells
--       (DefId 8). Cells are resolved dynamically per batch (@Cell1 / @Cell2)
--       rather than by hardcoded seed Id/Code.
--     - ItemLocation procs deployed
-- =============================================

EXEC test.BeginTestFile @FileName = N'0009_Parts_Process/030_ItemLocation_crud.sql';
GO

-- =============================================
-- Setup: create a test Item
-- =============================================
DECLARE @S     BIT,
        @M     NVARCHAR(500),
        @NewId BIGINT;

CREATE TABLE #Rc22 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rc22
EXEC Parts.Item_Create
    @ItemTypeId  = 4,
    @PartNumber  = N'TEST-IL-ITEM-001',
    @Description = N'Eligibility test item',
    @UomId       = 1,
    @AppUserId   = 1;
SELECT @S = Status, @M = Message, @NewId = NewId FROM #Rc22;
DROP TABLE #Rc22;
GO

-- =============================================
-- Test 1: ItemLocation_Add happy path
-- =============================================
DECLARE @Cell1 BIGINT = (SELECT TOP 1 Id FROM Location.Location
    WHERE LocationTypeDefinitionId = 8 AND DeprecatedAt IS NULL ORDER BY SortOrder, Id);
DECLARE @S      BIT,
        @M      NVARCHAR(500),
        @SStr   NVARCHAR(1),
        @ItemId BIGINT,
        @IlId   BIGINT;

SELECT @ItemId = Id FROM Parts.Item WHERE PartNumber = N'TEST-IL-ITEM-001';

CREATE TABLE #Rc23 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rc23
EXEC Parts.ItemLocation_Add
    @ItemId     = @ItemId,
    @LocationId = @Cell1,                  -- DC-401
    @AppUserId  = 1;
SELECT @S = Status, @M = Message, @IlId = NewId FROM #Rc23;
DROP TABLE #Rc23;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[AddHappy] Status is 1',
    @Expected = N'1',
    @Actual   = @SStr;

DECLARE @IlIdStr NVARCHAR(20) = CAST(@IlId AS NVARCHAR(20));
EXEC test.Assert_IsNotNull
    @TestName = N'[AddHappy] NewId is not NULL',
    @Value    = @IlIdStr;

-- Exactly one active row for (Item, DC-401)
DECLARE @RowCount INT = (
    SELECT COUNT(*) FROM Parts.ItemLocation
    WHERE ItemId = @ItemId AND LocationId = @Cell1 AND DeprecatedAt IS NULL
);
EXEC test.Assert_RowCount
    @TestName      = N'[AddHappy] One active (Item, DC-401) row',
    @ExpectedCount = 1,
    @ActualCount   = @RowCount;
GO

-- =============================================
-- Test 2: ItemLocation_Add same pair again - idempotent
--   Should return Status=1 and the SAME NewId as before (already active).
-- =============================================
DECLARE @Cell1 BIGINT = (SELECT TOP 1 Id FROM Location.Location
    WHERE LocationTypeDefinitionId = 8 AND DeprecatedAt IS NULL ORDER BY SortOrder, Id);
DECLARE @S      BIT,
        @M      NVARCHAR(500),
        @SStr   NVARCHAR(1),
        @ItemId BIGINT,
        @PriorId BIGINT,
        @NewId  BIGINT;

SELECT @ItemId = Id FROM Parts.Item WHERE PartNumber = N'TEST-IL-ITEM-001';
SELECT @PriorId = Id FROM Parts.ItemLocation
WHERE ItemId = @ItemId AND LocationId = @Cell1 AND DeprecatedAt IS NULL;

CREATE TABLE #Rc24 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rc24
EXEC Parts.ItemLocation_Add
    @ItemId     = @ItemId,
    @LocationId = @Cell1,
    @AppUserId  = 1;
SELECT @S = Status, @M = Message, @NewId = NewId FROM #Rc24;
DROP TABLE #Rc24;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[AddSamePair] Status is 1',
    @Expected = N'1',
    @Actual   = @SStr;

-- NewId should match the prior Id (idempotent)
DECLARE @PriorIdStr NVARCHAR(20) = CAST(@PriorId AS NVARCHAR(20));
DECLARE @NewIdStr   NVARCHAR(20) = CAST(@NewId   AS NVARCHAR(20));
EXEC test.Assert_IsEqual
    @TestName = N'[AddSamePair] NewId matches prior Id (idempotent)',
    @Expected = @PriorIdStr,
    @Actual   = @NewIdStr;

-- Still exactly one row total
DECLARE @TotalRows INT = (
    SELECT COUNT(*) FROM Parts.ItemLocation
    WHERE ItemId = @ItemId AND LocationId = @Cell1
);
EXEC test.Assert_RowCount
    @TestName      = N'[AddSamePair] Still exactly 1 (Item, DC-401) row total',
    @ExpectedCount = 1,
    @ActualCount   = @TotalRows;
GO

-- =============================================
-- Test 3: ItemLocation_Add invalid ItemId
-- =============================================
DECLARE @Cell1 BIGINT = (SELECT TOP 1 Id FROM Location.Location
    WHERE LocationTypeDefinitionId = 8 AND DeprecatedAt IS NULL ORDER BY SortOrder, Id);
DECLARE @S     BIT,
        @M     NVARCHAR(500),
        @SStr  NVARCHAR(1),
        @NewId BIGINT;

CREATE TABLE #Rc25 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rc25
EXEC Parts.ItemLocation_Add
    @ItemId     = 999999,
    @LocationId = @Cell1,
    @AppUserId  = 1;
SELECT @S = Status, @M = Message, @NewId = NewId FROM #Rc25;
DROP TABLE #Rc25;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[AddBadItem] Status is 0',
    @Expected = N'0',
    @Actual   = @SStr;

DECLARE @NewIdStr NVARCHAR(20) = CAST(@NewId AS NVARCHAR(20));
EXEC test.Assert_IsNull
    @TestName = N'[AddBadItem] NewId is NULL',
    @Value    = @NewIdStr;
GO

-- =============================================
-- Test 4: ItemLocation_Add invalid LocationId
-- =============================================
DECLARE @S      BIT,
        @M      NVARCHAR(500),
        @SStr   NVARCHAR(1),
        @ItemId BIGINT,
        @NewId  BIGINT;

SELECT @ItemId = Id FROM Parts.Item WHERE PartNumber = N'TEST-IL-ITEM-001';

CREATE TABLE #Rc26 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rc26
EXEC Parts.ItemLocation_Add
    @ItemId     = @ItemId,
    @LocationId = 999999,
    @AppUserId  = 1;
SELECT @S = Status, @M = Message, @NewId = NewId FROM #Rc26;
DROP TABLE #Rc26;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[AddBadLoc] Status is 0',
    @Expected = N'0',
    @Actual   = @SStr;
GO

-- =============================================
-- Test 5: ItemLocation_ListByItem - 1 row (DC-401 only so far)
-- =============================================
DECLARE @S      BIT,
        @M      NVARCHAR(500),
        @SStr   NVARCHAR(1),
        @ItemId BIGINT;

SELECT @ItemId = Id FROM Parts.Item WHERE PartNumber = N'TEST-IL-ITEM-001';

CREATE TABLE #IlByItem1 (
    Id BIGINT, ItemId BIGINT, LocationId BIGINT,
    LocationName NVARCHAR(200), LocationCode NVARCHAR(50),
    DefinitionName NVARCHAR(200),
    TierOrdinal INT,
    MinQuantity INT, MaxQuantity INT, DefaultQuantity INT,
    IsConsumptionPoint BIT,
    CreatedAt DATETIME2(3), DeprecatedAt DATETIME2(3)
);
INSERT INTO #IlByItem1 EXEC Parts.ItemLocation_ListByItem @ItemId = @ItemId;
DECLARE @ActiveCount INT = (SELECT COUNT(*) FROM #IlByItem1);
DECLARE @LocName NVARCHAR(200) = (SELECT TOP 1 LocationName FROM #IlByItem1);
DROP TABLE #IlByItem1;

EXEC test.Assert_RowCount
    @TestName      = N'[ListByItem1] 1 row returned by proc',
    @ExpectedCount = 1,
    @ActualCount   = @ActiveCount;

EXEC test.Assert_IsNotNull
    @TestName = N'[ListByItem1] LocationName populated in proc result',
    @Value    = @LocName;
GO

-- =============================================
-- Test 6: ItemLocation_Add second pair (same Item, second cell)
-- =============================================
DECLARE @Cell2 BIGINT = (SELECT Id FROM Location.Location
    WHERE LocationTypeDefinitionId = 8 AND DeprecatedAt IS NULL
    ORDER BY SortOrder, Id OFFSET 1 ROWS FETCH NEXT 1 ROWS ONLY);
DECLARE @S      BIT,
        @M      NVARCHAR(500),
        @SStr   NVARCHAR(1),
        @ItemId BIGINT,
        @IlId   BIGINT;

SELECT @ItemId = Id FROM Parts.Item WHERE PartNumber = N'TEST-IL-ITEM-001';

CREATE TABLE #Rc27 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rc27
EXEC Parts.ItemLocation_Add
    @ItemId     = @ItemId,
    @LocationId = @Cell2,             -- second cell (dynamic)
    @AppUserId  = 1;
SELECT @S = Status, @M = Message, @IlId = NewId FROM #Rc27;
DROP TABLE #Rc27;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[AddSecond] Status is 1',
    @Expected = N'1',
    @Actual   = @SStr;
GO

-- =============================================
-- Test 7: ItemLocation_ListByItem - now returns 2 rows
-- =============================================
DECLARE @S      BIT,
        @M      NVARCHAR(500),
        @SStr   NVARCHAR(1),
        @ItemId BIGINT;

SELECT @ItemId = Id FROM Parts.Item WHERE PartNumber = N'TEST-IL-ITEM-001';

CREATE TABLE #IlByItem2 (
    Id BIGINT, ItemId BIGINT, LocationId BIGINT,
    LocationName NVARCHAR(200), LocationCode NVARCHAR(50),
    DefinitionName NVARCHAR(200),
    TierOrdinal INT,
    MinQuantity INT, MaxQuantity INT, DefaultQuantity INT,
    IsConsumptionPoint BIT,
    CreatedAt DATETIME2(3), DeprecatedAt DATETIME2(3)
);
INSERT INTO #IlByItem2 EXEC Parts.ItemLocation_ListByItem @ItemId = @ItemId;
DECLARE @ActiveCount INT = (SELECT COUNT(*) FROM #IlByItem2);
DROP TABLE #IlByItem2;

EXEC test.Assert_RowCount
    @TestName      = N'[ListByItem2] 2 rows returned by proc',
    @ExpectedCount = 2,
    @ActualCount   = @ActiveCount;
GO

-- =============================================
-- Test 8: ItemLocation_ListByLocation for the first cell returns 1 row
-- =============================================
DECLARE @Cell1 BIGINT = (SELECT TOP 1 Id FROM Location.Location
    WHERE LocationTypeDefinitionId = 8 AND DeprecatedAt IS NULL ORDER BY SortOrder, Id);
DECLARE @S     BIT,
        @M     NVARCHAR(500),
        @SStr  NVARCHAR(1),
        @ItemId BIGINT;

SELECT @ItemId = Id FROM Parts.Item WHERE PartNumber = N'TEST-IL-ITEM-001';

CREATE TABLE #IlByLoc (
    Id BIGINT, ItemId BIGINT, LocationId BIGINT,
    PartNumber NVARCHAR(50), Description NVARCHAR(500),
    ItemTypeName NVARCHAR(200),
    MinQuantity INT, MaxQuantity INT, DefaultQuantity INT,
    IsConsumptionPoint BIT,
    CreatedAt DATETIME2(3), DeprecatedAt DATETIME2(3)
);
INSERT INTO #IlByLoc EXEC Parts.ItemLocation_ListByLocation @LocationId = @Cell1;
DECLARE @TestItemAtLoc INT = (
    SELECT COUNT(*) FROM #IlByLoc WHERE PartNumber = N'TEST-IL-ITEM-001'
);
DROP TABLE #IlByLoc;

EXEC test.Assert_RowCount
    @TestName      = N'[ListByLoc] Test item present at DC-401 (via proc)',
    @ExpectedCount = 1,
    @ActualCount   = @TestItemAtLoc;
GO

-- =============================================
-- Test 9: ItemLocation_Remove happy path (first cell pair)
-- =============================================
DECLARE @Cell1 BIGINT = (SELECT TOP 1 Id FROM Location.Location
    WHERE LocationTypeDefinitionId = 8 AND DeprecatedAt IS NULL ORDER BY SortOrder, Id);
DECLARE @S      BIT,
        @M      NVARCHAR(500),
        @SStr   NVARCHAR(1),
        @ItemId BIGINT;

SELECT @ItemId = Id FROM Parts.Item WHERE PartNumber = N'TEST-IL-ITEM-001';

CREATE TABLE #Ru29 (Status BIT, Message NVARCHAR(500));
INSERT INTO #Ru29
EXEC Parts.ItemLocation_Remove
    @ItemId     = @ItemId,
    @LocationId = @Cell1,
    @AppUserId  = 1;
SELECT @S = Status, @M = Message FROM #Ru29;
DROP TABLE #Ru29;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[RemoveHappy] Status is 1',
    @Expected = N'1',
    @Actual   = @SStr;

-- Row is now deprecated (soft-delete)
DECLARE @DepCount INT = (
    SELECT COUNT(*) FROM Parts.ItemLocation
    WHERE ItemId = @ItemId AND LocationId = @Cell1 AND DeprecatedAt IS NOT NULL
);
EXEC test.Assert_RowCount
    @TestName      = N'[RemoveHappy] Row deprecated',
    @ExpectedCount = 1,
    @ActualCount   = @DepCount;

-- No active row for (Item, DC-401) remains
DECLARE @ActiveAfter INT = (
    SELECT COUNT(*) FROM Parts.ItemLocation
    WHERE ItemId = @ItemId AND LocationId = @Cell1 AND DeprecatedAt IS NULL
);
EXEC test.Assert_RowCount
    @TestName      = N'[RemoveHappy] No active row remains',
    @ExpectedCount = 0,
    @ActualCount   = @ActiveAfter;
GO

-- =============================================
-- Test 10: ItemLocation_Remove same pair again rejected
-- =============================================
DECLARE @Cell1 BIGINT = (SELECT TOP 1 Id FROM Location.Location
    WHERE LocationTypeDefinitionId = 8 AND DeprecatedAt IS NULL ORDER BY SortOrder, Id);
DECLARE @S      BIT,
        @M      NVARCHAR(500),
        @SStr   NVARCHAR(1),
        @ItemId BIGINT;

SELECT @ItemId = Id FROM Parts.Item WHERE PartNumber = N'TEST-IL-ITEM-001';

CREATE TABLE #Ru30 (Status BIT, Message NVARCHAR(500));
INSERT INTO #Ru30
EXEC Parts.ItemLocation_Remove
    @ItemId     = @ItemId,
    @LocationId = @Cell1,
    @AppUserId  = 1;
SELECT @S = Status, @M = Message FROM #Ru30;
DROP TABLE #Ru30;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[RemoveTwice] Status is 0 (no active row)',
    @Expected = N'0',
    @Actual   = @SStr;
GO

-- =============================================
-- Test 11: ItemLocation_Add for previously-deprecated pair - reactivation
--   Same Id must be returned, and exactly 1 row (ItemId, LocationId)
--   should exist with DeprecatedAt IS NULL.
-- =============================================
DECLARE @Cell1 BIGINT = (SELECT TOP 1 Id FROM Location.Location
    WHERE LocationTypeDefinitionId = 8 AND DeprecatedAt IS NULL ORDER BY SortOrder, Id);
DECLARE @S       BIT,
        @M       NVARCHAR(500),
        @SStr    NVARCHAR(1),
        @ItemId  BIGINT,
        @PriorId BIGINT,
        @NewId   BIGINT;

SELECT @ItemId = Id FROM Parts.Item WHERE PartNumber = N'TEST-IL-ITEM-001';

-- Capture the deprecated row's Id
SELECT @PriorId = Id FROM Parts.ItemLocation
WHERE ItemId = @ItemId AND LocationId = @Cell1;

CREATE TABLE #Rc28 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rc28
EXEC Parts.ItemLocation_Add
    @ItemId     = @ItemId,
    @LocationId = @Cell1,
    @AppUserId  = 1;
SELECT @S = Status, @M = Message, @NewId = NewId FROM #Rc28;
DROP TABLE #Rc28;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[Reactivate] Status is 1',
    @Expected = N'1',
    @Actual   = @SStr;

-- Same Id returned
DECLARE @PriorIdStr NVARCHAR(20) = CAST(@PriorId AS NVARCHAR(20));
DECLARE @NewIdStr   NVARCHAR(20) = CAST(@NewId   AS NVARCHAR(20));
EXEC test.Assert_IsEqual
    @TestName = N'[Reactivate] Same Id returned (no new insert)',
    @Expected = @PriorIdStr,
    @Actual   = @NewIdStr;

-- Exactly 1 row for (Item, DC-401) and it's active
DECLARE @TotalCount INT = (
    SELECT COUNT(*) FROM Parts.ItemLocation
    WHERE ItemId = @ItemId AND LocationId = @Cell1
);
EXEC test.Assert_RowCount
    @TestName      = N'[Reactivate] Exactly 1 row for (Item, DC-401)',
    @ExpectedCount = 1,
    @ActualCount   = @TotalCount;

DECLARE @ActiveCount INT = (
    SELECT COUNT(*) FROM Parts.ItemLocation
    WHERE ItemId = @ItemId AND LocationId = @Cell1 AND DeprecatedAt IS NULL
);
EXEC test.Assert_RowCount
    @TestName      = N'[Reactivate] That row is active',
    @ExpectedCount = 1,
    @ActualCount   = @ActiveCount;
GO

-- =============================================
-- Test 12: Audit trail - ConfigLog has >= 3 ItemLocation entries
-- =============================================
DECLARE @AuditCount INT;
SELECT @AuditCount = COUNT(*)
FROM Audit.ConfigLog cl
INNER JOIN Audit.LogEntityType let ON let.Id = cl.LogEntityTypeId
WHERE let.Code = N'ItemLocation';

DECLARE @AuditCond BIT = CASE WHEN @AuditCount >= 3 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue
    @TestName  = N'[Audit] ConfigLog has >= 3 ItemLocation entries',
    @Condition = @AuditCond;
GO

-- =============================================
-- Cleanup
-- =============================================
DELETE il
FROM Parts.ItemLocation il
INNER JOIN Parts.Item i ON i.Id = il.ItemId
WHERE i.PartNumber LIKE N'TEST-IL-ITEM-%';

DELETE FROM Parts.Item WHERE PartNumber LIKE N'TEST-IL-ITEM-%';
GO

-- =============================================
-- Final summary
-- =============================================
EXEC test.PrintSummary;
GO
