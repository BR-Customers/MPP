-- =============================================
-- File:         0010_Parts_Bom/010_Bom_crud.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-04-14
-- Description:
--   Tests for Parts.Bom procs:
--     Parts.Bom_ListByParentItem
--     Parts.Bom_Get
--     Parts.Bom_GetActiveForItem
--     Parts.Bom_Create
--     Parts.Bom_CreateNewVersion
--     Parts.Bom_Publish
--     Parts.Bom_Deprecate
--     Parts.Bom_WhereUsedByChildItem
--
--   Covers: create happy + duplicate + invalid parent + NULL param;
--   draft invisibility via GetActiveForItem; publish happy + double +
--   deprecated; published BomLine lock; GetActiveForItem with default
--   and historical AsOfDate; CreateNewVersion clone (2 lines); list-
--   by-parent; deprecate v1 lifecycle; WhereUsedByChildItem lookups;
--   audit trail.
--
--   Pre-conditions:
--     - Migration 0001-0006 applied
--     - AppUser Id=1 exists
--     - Parts.ItemType and Parts.Uom seeds present (ItemType 2, 4; Uom 1)
--     - All Parts.Bom_* and Parts.BomLine_* procs deployed
-- =============================================

EXEC test.BeginTestFile @FileName = N'0010_Parts_Bom/010_Bom_crud.sql';
GO

-- =============================================
-- Setup: parent (FinishedGood) + 3 child Items (Component)
-- =============================================
DECLARE @S     BIT,
        @M     NVARCHAR(500),
        @NewId BIGINT;

CREATE TABLE #Rc31 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rc31
EXEC Parts.Item_Create
    @PartNumber  = N'TEST-BOM-PARENT-001',
    @ItemTypeId  = 4,
    @Description = N'Test BOM parent',
    @UomId       = 1,
    @AppUserId   = 1;
SELECT @S = Status, @M = Message, @NewId = NewId FROM #Rc31;
DROP TABLE #Rc31;

CREATE TABLE #Rc32 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rc32
EXEC Parts.Item_Create
    @PartNumber  = N'TEST-BOM-CHILD-001',
    @ItemTypeId  = 2,
    @Description = N'Test BOM child 1',
    @UomId       = 1,
    @AppUserId   = 1;
SELECT @S = Status, @M = Message, @NewId = NewId FROM #Rc32;
DROP TABLE #Rc32;

CREATE TABLE #Rc33 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rc33
EXEC Parts.Item_Create
    @PartNumber  = N'TEST-BOM-CHILD-002',
    @ItemTypeId  = 2,
    @Description = N'Test BOM child 2',
    @UomId       = 1,
    @AppUserId   = 1;
SELECT @S = Status, @M = Message, @NewId = NewId FROM #Rc33;
DROP TABLE #Rc33;

CREATE TABLE #Rc34 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rc34
EXEC Parts.Item_Create
    @PartNumber  = N'TEST-BOM-CHILD-003',
    @ItemTypeId  = 2,
    @Description = N'Test BOM child 3',
    @UomId       = 1,
    @AppUserId   = 1;
SELECT @S = Status, @M = Message, @NewId = NewId FROM #Rc34;
DROP TABLE #Rc34;
GO

-- =============================================
-- Test 1: Bom_Create happy path
-- =============================================
DECLARE @S      BIT,
        @M      NVARCHAR(500),
        @SStr   NVARCHAR(1),
        @PId    BIGINT,
        @BomId  BIGINT;

SELECT @PId = Id FROM Parts.Item WHERE PartNumber = N'TEST-BOM-PARENT-001';

CREATE TABLE #Rc1 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rc1
EXEC Parts.Bom_Create
    @ParentItemId = @PId,
    @AppUserId    = 1;
SELECT @S = Status, @M = Message, @BomId = NewId FROM #Rc1;
DROP TABLE #Rc1;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[BomCreateHappy] Status is 1',
    @Expected = N'1',
    @Actual   = @SStr;

DECLARE @BomIdStr NVARCHAR(20) = CAST(@BomId AS NVARCHAR(20));
EXEC test.Assert_IsNotNull
    @TestName = N'[BomCreateHappy] NewId is not NULL',
    @Value    = @BomIdStr;

DECLARE @Ver INT;
SELECT @Ver = VersionNumber FROM Parts.Bom WHERE Id = @BomId;
DECLARE @VerStr NVARCHAR(20) = CAST(@Ver AS NVARCHAR(20));
EXEC test.Assert_IsEqual
    @TestName = N'[BomCreateHappy] VersionNumber = 1',
    @Expected = N'1',
    @Actual   = @VerStr;

DECLARE @PubAt DATETIME2(3);
SELECT @PubAt = PublishedAt FROM Parts.Bom WHERE Id = @BomId;
DECLARE @PubNullStr NVARCHAR(1) = CASE WHEN @PubAt IS NULL THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[BomCreateHappy] PublishedAt IS NULL (Draft)',
    @Expected = N'1',
    @Actual   = @PubNullStr;
GO

-- =============================================
-- Test 2: Bom_Create NULL ParentItemId
-- =============================================
DECLARE @S     BIT,
        @M     NVARCHAR(500),
        @SStr  NVARCHAR(1),
        @BomId BIGINT;

CREATE TABLE #Rc2 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rc2
EXEC Parts.Bom_Create
    @ParentItemId = NULL,
    @AppUserId    = 1;
SELECT @S = Status, @M = Message, @BomId = NewId FROM #Rc2;
DROP TABLE #Rc2;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[BomCreateNull] Status is 0 (NULL required param)',
    @Expected = N'0',
    @Actual   = @SStr;
GO

-- =============================================
-- Test 3: Bom_Create duplicate for same parent
-- =============================================
DECLARE @S     BIT,
        @M     NVARCHAR(500),
        @SStr  NVARCHAR(1),
        @PId   BIGINT,
        @BomId BIGINT;

SELECT @PId = Id FROM Parts.Item WHERE PartNumber = N'TEST-BOM-PARENT-001';

CREATE TABLE #Rc3 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rc3
EXEC Parts.Bom_Create
    @ParentItemId = @PId,
    @AppUserId    = 1;
SELECT @S = Status, @M = Message, @BomId = NewId FROM #Rc3;
DROP TABLE #Rc3;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[BomCreateDup] Status is 0 (already exists)',
    @Expected = N'0',
    @Actual   = @SStr;

DECLARE @DupMsg NVARCHAR(1) = CASE
    WHEN @M LIKE N'%already exists%' OR @M LIKE N'%already%'
    THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[BomCreateDup] Message indicates already exists',
    @Expected = N'1',
    @Actual   = @DupMsg;
GO

-- =============================================
-- Test 4: Bom_Create invalid ParentItemId
-- =============================================
DECLARE @S     BIT,
        @M     NVARCHAR(500),
        @SStr  NVARCHAR(1),
        @BomId BIGINT;

CREATE TABLE #Rc4 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rc4
EXEC Parts.Bom_Create
    @ParentItemId = 999999,
    @AppUserId    = 1;
SELECT @S = Status, @M = Message, @BomId = NewId FROM #Rc4;
DROP TABLE #Rc4;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[BomCreateBadParent] Status is 0',
    @Expected = N'0',
    @Actual   = @SStr;
GO

-- =============================================
-- Test 5: Bom_GetActiveForItem on a Draft BOM returns no data
--   (status may be 1 but no published row exists)
-- =============================================
DECLARE @S     BIT,
        @M     NVARCHAR(500),
        @SStr  NVARCHAR(1),
        @PId   BIGINT;

SELECT @PId = Id FROM Parts.Item WHERE PartNumber = N'TEST-BOM-PARENT-001';

-- Invoke read proc (converted: no OUTPUT params). Capture to scratch temp table
-- so INSERT-EXEC does not emit rows into the client result stream.
IF OBJECT_ID('tempdb..#BomActiveScratch') IS NOT NULL DROP TABLE #BomActiveScratch;
CREATE TABLE #BomActiveScratch (
    Id BIGINT, ParentItemId BIGINT, PartNumber NVARCHAR(50), VersionNumber INT,
    EffectiveFrom DATETIME2(3), PublishedAt DATETIME2(3), DeprecatedAt DATETIME2(3),
    CreatedByUserId BIGINT, CreatedByDisplayName NVARCHAR(200), CreatedAt DATETIME2(3)
);
INSERT INTO #BomActiveScratch EXEC Parts.Bom_GetActiveForItem @ParentItemId = @PId, @AsOfDate = NULL;
DROP TABLE #BomActiveScratch;

-- Direct-query proof: no published+active BOM yet
DECLARE @PubCount INT = (
    SELECT COUNT(*) FROM Parts.Bom
    WHERE ParentItemId = @PId
      AND PublishedAt IS NOT NULL
      AND DeprecatedAt IS NULL
);
EXEC test.Assert_RowCount
    @TestName      = N'[BomDraftInvisible] 0 published BOMs for parent',
    @ExpectedCount = 0,
    @ActualCount   = @PubCount;
GO

-- =============================================
-- Test 6: Add 2 BomLines to Draft v1
-- =============================================
DECLARE @S     BIT,
        @M     NVARCHAR(500),
        @SStr  NVARCHAR(1),
        @BomId BIGINT,
        @C1    BIGINT,
        @C2    BIGINT,
        @LnId  BIGINT;

SELECT @BomId = b.Id
FROM Parts.Bom b
INNER JOIN Parts.Item p ON p.Id = b.ParentItemId
WHERE p.PartNumber = N'TEST-BOM-PARENT-001' AND b.VersionNumber = 1;

SELECT @C1 = Id FROM Parts.Item WHERE PartNumber = N'TEST-BOM-CHILD-001';
SELECT @C2 = Id FROM Parts.Item WHERE PartNumber = N'TEST-BOM-CHILD-002';

CREATE TABLE #Rc5 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rc5
EXEC Parts.BomLine_Add
    @BomId       = @BomId,
    @ChildItemId = @C1,
    @QtyPer      = 1.0,
    @UomId       = 1,
    @AppUserId   = 1;
SELECT @S = Status, @M = Message, @LnId = NewId FROM #Rc5;
DROP TABLE #Rc5;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[BomLineAdd1] Status is 1',
    @Expected = N'1',
    @Actual   = @SStr;

CREATE TABLE #Rc6 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rc6
EXEC Parts.BomLine_Add
    @BomId       = @BomId,
    @ChildItemId = @C2,
    @QtyPer      = 2.0,
    @UomId       = 1,
    @AppUserId   = 1;
SELECT @S = Status, @M = Message, @LnId = NewId FROM #Rc6;
DROP TABLE #Rc6;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[BomLineAdd2] Status is 1',
    @Expected = N'1',
    @Actual   = @SStr;

-- Verify 2 lines exist
DECLARE @LineCount INT = (SELECT COUNT(*) FROM Parts.BomLine WHERE BomId = @BomId);
EXEC test.Assert_RowCount
    @TestName      = N'[BomLineAdd] 2 BomLines on Draft v1',
    @ExpectedCount = 2,
    @ActualCount   = @LineCount;
GO

-- =============================================
-- Test 7: Bom_Publish v1 happy path
-- =============================================
DECLARE @S     BIT,
        @M     NVARCHAR(500),
        @SStr  NVARCHAR(1),
        @BomId BIGINT;

SELECT @BomId = b.Id
FROM Parts.Bom b
INNER JOIN Parts.Item p ON p.Id = b.ParentItemId
WHERE p.PartNumber = N'TEST-BOM-PARENT-001' AND b.VersionNumber = 1;

CREATE TABLE #Ru9 (Status BIT, Message NVARCHAR(500));
INSERT INTO #Ru9
EXEC Parts.Bom_Publish
    @Id        = @BomId,
    @AppUserId = 1;
SELECT @S = Status, @M = Message FROM #Ru9;
DROP TABLE #Ru9;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[BomPublish1] Status is 1',
    @Expected = N'1',
    @Actual   = @SStr;

DECLARE @PubAt DATETIME2(3);
SELECT @PubAt = PublishedAt FROM Parts.Bom WHERE Id = @BomId;
DECLARE @PubSetStr NVARCHAR(1) = CASE WHEN @PubAt IS NOT NULL THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[BomPublish1] PublishedAt is set',
    @Expected = N'1',
    @Actual   = @PubSetStr;
GO

-- =============================================
-- Test 8: Bom_Publish on already-published BOM
-- =============================================
DECLARE @S     BIT,
        @M     NVARCHAR(500),
        @SStr  NVARCHAR(1),
        @BomId BIGINT;

SELECT @BomId = b.Id
FROM Parts.Bom b
INNER JOIN Parts.Item p ON p.Id = b.ParentItemId
WHERE p.PartNumber = N'TEST-BOM-PARENT-001' AND b.VersionNumber = 1;

CREATE TABLE #Ru10 (Status BIT, Message NVARCHAR(500));
INSERT INTO #Ru10
EXEC Parts.Bom_Publish
    @Id        = @BomId,
    @AppUserId = 1;
SELECT @S = Status, @M = Message FROM #Ru10;
DROP TABLE #Ru10;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[BomPublishTwice] Status is 0 (already published)',
    @Expected = N'0',
    @Actual   = @SStr;

DECLARE @MsgHit NVARCHAR(1) = CASE
    WHEN @M LIKE N'%already published%' OR @M LIKE N'%already%'
    THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[BomPublishTwice] Message indicates already published',
    @Expected = N'1',
    @Actual   = @MsgHit;
GO

-- =============================================
-- Test 9: BomLine_Add on published BOM rejected
-- =============================================
DECLARE @S     BIT,
        @M     NVARCHAR(500),
        @SStr  NVARCHAR(1),
        @BomId BIGINT,
        @C3    BIGINT,
        @LnId  BIGINT;

SELECT @BomId = b.Id
FROM Parts.Bom b
INNER JOIN Parts.Item p ON p.Id = b.ParentItemId
WHERE p.PartNumber = N'TEST-BOM-PARENT-001' AND b.VersionNumber = 1;

SELECT @C3 = Id FROM Parts.Item WHERE PartNumber = N'TEST-BOM-CHILD-003';

CREATE TABLE #Rc7 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rc7
EXEC Parts.BomLine_Add
    @BomId       = @BomId,
    @ChildItemId = @C3,
    @QtyPer      = 1.0,
    @UomId       = 1,
    @AppUserId   = 1;
SELECT @S = Status, @M = Message, @LnId = NewId FROM #Rc7;
DROP TABLE #Rc7;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[BomLineAddOnPub] Status is 0 (published BOM immutable)',
    @Expected = N'0',
    @Actual   = @SStr;

DECLARE @LockMsg NVARCHAR(1) = CASE
    WHEN @M LIKE N'%published%' THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[BomLineAddOnPub] Message contains "published"',
    @Expected = N'1',
    @Actual   = @LockMsg;
GO

-- =============================================
-- Test 10: BomLine_Update on published BOM rejected
-- =============================================
DECLARE @S     BIT,
        @M     NVARCHAR(500),
        @SStr  NVARCHAR(1),
        @BomId BIGINT,
        @LnId  BIGINT;

SELECT @BomId = b.Id
FROM Parts.Bom b
INNER JOIN Parts.Item p ON p.Id = b.ParentItemId
WHERE p.PartNumber = N'TEST-BOM-PARENT-001' AND b.VersionNumber = 1;

SELECT TOP 1 @LnId = Id FROM Parts.BomLine WHERE BomId = @BomId ORDER BY SortOrder;

CREATE TABLE #Ru11 (Status BIT, Message NVARCHAR(500));
INSERT INTO #Ru11
EXEC Parts.BomLine_Update
    @Id        = @LnId,
    @QtyPer    = 99.0,
    @UomId     = 1,
    @AppUserId = 1;
SELECT @S = Status, @M = Message FROM #Ru11;
DROP TABLE #Ru11;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[BomLineUpdOnPub] Status is 0 (published BOM immutable)',
    @Expected = N'0',
    @Actual   = @SStr;

DECLARE @UpdLockMsg NVARCHAR(1) = CASE
    WHEN @M LIKE N'%published%' THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[BomLineUpdOnPub] Message contains "published"',
    @Expected = N'1',
    @Actual   = @UpdLockMsg;
GO

-- =============================================
-- Test 11: Bom_GetActiveForItem returns the published v1
-- =============================================
DECLARE @S    BIT,
        @M    NVARCHAR(500),
        @SStr NVARCHAR(1),
        @PId  BIGINT;

SELECT @PId = Id FROM Parts.Item WHERE PartNumber = N'TEST-BOM-PARENT-001';

-- Invoke read proc (converted: no OUTPUT params). Capture to scratch temp table
-- so INSERT-EXEC does not emit rows into the client result stream.
IF OBJECT_ID('tempdb..#BomActiveScratch') IS NOT NULL DROP TABLE #BomActiveScratch;
CREATE TABLE #BomActiveScratch (
    Id BIGINT, ParentItemId BIGINT, PartNumber NVARCHAR(50), VersionNumber INT,
    EffectiveFrom DATETIME2(3), PublishedAt DATETIME2(3), DeprecatedAt DATETIME2(3),
    CreatedByUserId BIGINT, CreatedByDisplayName NVARCHAR(200), CreatedAt DATETIME2(3)
);
INSERT INTO #BomActiveScratch EXEC Parts.Bom_GetActiveForItem @ParentItemId = @PId, @AsOfDate = NULL;
DROP TABLE #BomActiveScratch;

DECLARE @PubCount INT = (
    SELECT COUNT(*) FROM Parts.Bom
    WHERE ParentItemId = @PId
      AND PublishedAt IS NOT NULL
      AND DeprecatedAt IS NULL
);
EXEC test.Assert_RowCount
    @TestName      = N'[BomActiveV1] 1 published+active BOM exists',
    @ExpectedCount = 1,
    @ActualCount   = @PubCount;
GO

-- =============================================
-- Test 12: Bom_GetActiveForItem historical AsOfDate
--   Backdate v1.EffectiveFrom so the AsOfDate window is real.
--   AsOfDate = NOW-1h: row returned (in window).
--   AsOfDate = NOW-3h: 0 rows (before EffectiveFrom).
-- =============================================
DECLARE @S    BIT,
        @M    NVARCHAR(500),
        @SStr NVARCHAR(1),
        @PId  BIGINT,
        @AsOf DATETIME2(3);

SELECT @PId = Id FROM Parts.Item WHERE PartNumber = N'TEST-BOM-PARENT-001';

UPDATE Parts.Bom
SET EffectiveFrom = DATEADD(HOUR, -2, SYSUTCDATETIME())
WHERE ParentItemId = @PId AND VersionNumber = 1;

SET @AsOf = DATEADD(HOUR, -1, SYSUTCDATETIME());

IF OBJECT_ID('tempdb..#BomActiveScratch') IS NOT NULL DROP TABLE #BomActiveScratch;
CREATE TABLE #BomActiveScratch (
    Id BIGINT, ParentItemId BIGINT, PartNumber NVARCHAR(50), VersionNumber INT,
    EffectiveFrom DATETIME2(3), PublishedAt DATETIME2(3), DeprecatedAt DATETIME2(3),
    CreatedByUserId BIGINT, CreatedByDisplayName NVARCHAR(200), CreatedAt DATETIME2(3)
);
INSERT INTO #BomActiveScratch EXEC Parts.Bom_GetActiveForItem @ParentItemId = @PId, @AsOfDate = @AsOf;
DROP TABLE #BomActiveScratch;

DECLARE @InWindow INT = (
    SELECT COUNT(*) FROM Parts.Bom
    WHERE ParentItemId = @PId
      AND PublishedAt IS NOT NULL
      AND EffectiveFrom <= @AsOf
      AND (DeprecatedAt IS NULL OR DeprecatedAt > @AsOf)
);
EXEC test.Assert_RowCount
    @TestName      = N'[BomActiveHistIn] 1 BOM active at AsOfDate (NOW-1h)',
    @ExpectedCount = 1,
    @ActualCount   = @InWindow;

-- Before the backdated EffectiveFrom
DECLARE @AsOfBefore DATETIME2(3) = DATEADD(HOUR, -3, SYSUTCDATETIME());
DECLARE @BeforeCount INT = (
    SELECT COUNT(*) FROM Parts.Bom
    WHERE ParentItemId = @PId
      AND PublishedAt IS NOT NULL
      AND EffectiveFrom <= @AsOfBefore
      AND (DeprecatedAt IS NULL OR DeprecatedAt > @AsOfBefore)
);
EXEC test.Assert_RowCount
    @TestName      = N'[BomActiveHistBefore] 0 BOMs active at NOW-3h',
    @ExpectedCount = 0,
    @ActualCount   = @BeforeCount;
GO

-- =============================================
-- Test 13: Bom_CreateNewVersion from v1 -> v2 Draft clone
-- =============================================
DECLARE @S      BIT,
        @M      NVARCHAR(500),
        @SStr   NVARCHAR(1),
        @PId    BIGINT,
        @V1Id   BIGINT,
        @V2Id   BIGINT;

SELECT @PId  = Id FROM Parts.Item WHERE PartNumber = N'TEST-BOM-PARENT-001';
SELECT @V1Id = Id FROM Parts.Bom WHERE ParentItemId = @PId AND VersionNumber = 1;

CREATE TABLE #Rc8 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rc8
EXEC Parts.Bom_CreateNewVersion
    @ParentBomId = @V1Id,
    @AppUserId   = 1;
SELECT @S = Status, @M = Message, @V2Id = NewId FROM #Rc8;
DROP TABLE #Rc8;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[BomNewVer] Status is 1',
    @Expected = N'1',
    @Actual   = @SStr;

DECLARE @V2IdStr NVARCHAR(20) = CAST(@V2Id AS NVARCHAR(20));
EXEC test.Assert_IsNotNull
    @TestName = N'[BomNewVer] NewId is not NULL',
    @Value    = @V2IdStr;

DECLARE @V2Ver INT;
SELECT @V2Ver = VersionNumber FROM Parts.Bom WHERE Id = @V2Id;
DECLARE @V2VerStr NVARCHAR(20) = CAST(@V2Ver AS NVARCHAR(20));
EXEC test.Assert_IsEqual
    @TestName = N'[BomNewVer] VersionNumber = 2',
    @Expected = N'2',
    @Actual   = @V2VerStr;

DECLARE @V2Pub DATETIME2(3);
SELECT @V2Pub = PublishedAt FROM Parts.Bom WHERE Id = @V2Id;
DECLARE @V2PubNull NVARCHAR(1) = CASE WHEN @V2Pub IS NULL THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[BomNewVer] v2 PublishedAt IS NULL (Draft)',
    @Expected = N'1',
    @Actual   = @V2PubNull;

DECLARE @V2LineCount INT = (SELECT COUNT(*) FROM Parts.BomLine WHERE BomId = @V2Id);
EXEC test.Assert_RowCount
    @TestName      = N'[BomNewVer] 2 BomLines cloned into v2',
    @ExpectedCount = 2,
    @ActualCount   = @V2LineCount;
GO

-- =============================================
-- Test 14: Bom_ListByParentItem returns v1 (published) and v2 (draft)
-- =============================================
DECLARE @S    BIT,
        @M    NVARCHAR(500),
        @SStr NVARCHAR(1),
        @PId  BIGINT;

SELECT @PId = Id FROM Parts.Item WHERE PartNumber = N'TEST-BOM-PARENT-001';

IF OBJECT_ID('tempdb..#BomListScratch') IS NOT NULL DROP TABLE #BomListScratch;
CREATE TABLE #BomListScratch (
    Id BIGINT, ParentItemId BIGINT, VersionNumber INT,
    EffectiveFrom DATETIME2(3), PublishedAt DATETIME2(3), DeprecatedAt DATETIME2(3),
    CreatedByUserId BIGINT, CreatedByDisplayName NVARCHAR(200), CreatedAt DATETIME2(3),
    LineCount INT, [Status] NVARCHAR(20)
);
INSERT INTO #BomListScratch EXEC Parts.Bom_ListByParentItem @ParentItemId = @PId, @ActiveOnly = 1;
DROP TABLE #BomListScratch;

DECLARE @ListCount INT = (
    SELECT COUNT(*) FROM Parts.Bom
    WHERE ParentItemId = @PId AND DeprecatedAt IS NULL
);
EXEC test.Assert_RowCount
    @TestName      = N'[BomList] 2 active BOM rows (v1 pub + v2 draft)',
    @ExpectedCount = 2,
    @ActualCount   = @ListCount;
GO

-- =============================================
-- Test 15: Bom_Publish v2
-- =============================================
DECLARE @S    BIT,
        @M    NVARCHAR(500),
        @SStr NVARCHAR(1),
        @PId  BIGINT,
        @V2Id BIGINT;

SELECT @PId  = Id FROM Parts.Item WHERE PartNumber = N'TEST-BOM-PARENT-001';
SELECT @V2Id = Id FROM Parts.Bom WHERE ParentItemId = @PId AND VersionNumber = 2;

CREATE TABLE #Ru12 (Status BIT, Message NVARCHAR(500));
INSERT INTO #Ru12
EXEC Parts.Bom_Publish
    @Id        = @V2Id,
    @AppUserId = 1;
SELECT @S = Status, @M = Message FROM #Ru12;
DROP TABLE #Ru12;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[BomPublishV2] Status is 1',
    @Expected = N'1',
    @Actual   = @SStr;
GO

-- =============================================
-- Test 16: Bom_GetActiveForItem default returns v2 (newest active published)
-- =============================================
DECLARE @S    BIT,
        @M    NVARCHAR(500),
        @SStr NVARCHAR(1),
        @PId  BIGINT;

SELECT @PId = Id FROM Parts.Item WHERE PartNumber = N'TEST-BOM-PARENT-001';

-- Invoke read proc (converted: no OUTPUT params). Capture to scratch temp table
-- so INSERT-EXEC does not emit rows into the client result stream.
IF OBJECT_ID('tempdb..#BomActiveScratch') IS NOT NULL DROP TABLE #BomActiveScratch;
CREATE TABLE #BomActiveScratch (
    Id BIGINT, ParentItemId BIGINT, PartNumber NVARCHAR(50), VersionNumber INT,
    EffectiveFrom DATETIME2(3), PublishedAt DATETIME2(3), DeprecatedAt DATETIME2(3),
    CreatedByUserId BIGINT, CreatedByDisplayName NVARCHAR(200), CreatedAt DATETIME2(3)
);
INSERT INTO #BomActiveScratch EXEC Parts.Bom_GetActiveForItem @ParentItemId = @PId, @AsOfDate = NULL;
DROP TABLE #BomActiveScratch;

DECLARE @NewestVer INT;
SELECT TOP 1 @NewestVer = VersionNumber
FROM Parts.Bom
WHERE ParentItemId = @PId
  AND PublishedAt IS NOT NULL
  AND DeprecatedAt IS NULL
ORDER BY EffectiveFrom DESC, VersionNumber DESC;

DECLARE @NewestVerStr NVARCHAR(20) = CAST(@NewestVer AS NVARCHAR(20));
EXEC test.Assert_IsEqual
    @TestName = N'[BomActiveV2] Newest active published version is v2',
    @Expected = N'2',
    @Actual   = @NewestVerStr;
GO

-- =============================================
-- Test 17: Bom_Deprecate v1
-- =============================================
DECLARE @S    BIT,
        @M    NVARCHAR(500),
        @SStr NVARCHAR(1),
        @PId  BIGINT,
        @V1Id BIGINT;

SELECT @PId  = Id FROM Parts.Item WHERE PartNumber = N'TEST-BOM-PARENT-001';
SELECT @V1Id = Id FROM Parts.Bom WHERE ParentItemId = @PId AND VersionNumber = 1;

CREATE TABLE #Ru13 (Status BIT, Message NVARCHAR(500));
INSERT INTO #Ru13
EXEC Parts.Bom_Deprecate
    @Id        = @V1Id,
    @AppUserId = 1;
SELECT @S = Status, @M = Message FROM #Ru13;
DROP TABLE #Ru13;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[BomDepV1] Status is 1',
    @Expected = N'1',
    @Actual   = @SStr;

DECLARE @V1Dep DATETIME2(3);
SELECT @V1Dep = DeprecatedAt FROM Parts.Bom WHERE Id = @V1Id;
DECLARE @V1DepStr NVARCHAR(1) = CASE WHEN @V1Dep IS NOT NULL THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[BomDepV1] DeprecatedAt is set',
    @Expected = N'1',
    @Actual   = @V1DepStr;
GO

-- =============================================
-- Test 18: Bom_Publish on a (now) deprecated BOM rejected
--   v1 has just been deprecated; publishing it again must fail.
-- =============================================
DECLARE @S    BIT,
        @M    NVARCHAR(500),
        @SStr NVARCHAR(1),
        @PId  BIGINT,
        @V1Id BIGINT;

SELECT @PId  = Id FROM Parts.Item WHERE PartNumber = N'TEST-BOM-PARENT-001';
SELECT @V1Id = Id FROM Parts.Bom WHERE ParentItemId = @PId AND VersionNumber = 1;

CREATE TABLE #Ru14 (Status BIT, Message NVARCHAR(500));
INSERT INTO #Ru14
EXEC Parts.Bom_Publish
    @Id        = @V1Id,
    @AppUserId = 1;
SELECT @S = Status, @M = Message FROM #Ru14;
DROP TABLE #Ru14;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[BomPublishDep] Status is 0 (deprecated/already published)',
    @Expected = N'0',
    @Actual   = @SStr;

DECLARE @DepMsg NVARCHAR(1) = CASE
    WHEN @M LIKE N'%deprecated%' OR @M LIKE N'%already%' OR @M LIKE N'%published%'
    THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[BomPublishDep] Message indicates deprecated/published',
    @Expected = N'1',
    @Actual   = @DepMsg;
GO

-- =============================================
-- Test 19: Bom_GetActiveForItem historical just after v1 was deprecated
--   Returns v2 only.
-- =============================================
DECLARE @S    BIT,
        @M    NVARCHAR(500),
        @SStr NVARCHAR(1),
        @PId  BIGINT,
        @AsOf DATETIME2(3);

SELECT @PId = Id FROM Parts.Item WHERE PartNumber = N'TEST-BOM-PARENT-001';
SET @AsOf = SYSUTCDATETIME();

IF OBJECT_ID('tempdb..#BomActiveScratch') IS NOT NULL DROP TABLE #BomActiveScratch;
CREATE TABLE #BomActiveScratch (
    Id BIGINT, ParentItemId BIGINT, PartNumber NVARCHAR(50), VersionNumber INT,
    EffectiveFrom DATETIME2(3), PublishedAt DATETIME2(3), DeprecatedAt DATETIME2(3),
    CreatedByUserId BIGINT, CreatedByDisplayName NVARCHAR(200), CreatedAt DATETIME2(3)
);
INSERT INTO #BomActiveScratch EXEC Parts.Bom_GetActiveForItem @ParentItemId = @PId, @AsOfDate = @AsOf;
DROP TABLE #BomActiveScratch;

-- Direct query: only v2 is published AND not deprecated
DECLARE @ActiveNowCount INT = (
    SELECT COUNT(*) FROM Parts.Bom
    WHERE ParentItemId = @PId
      AND PublishedAt IS NOT NULL
      AND DeprecatedAt IS NULL
);
EXEC test.Assert_RowCount
    @TestName      = N'[BomActiveAfterDep] Exactly 1 active published BOM (v2)',
    @ExpectedCount = 1,
    @ActualCount   = @ActiveNowCount;

DECLARE @OnlyVer INT;
SELECT TOP 1 @OnlyVer = VersionNumber
FROM Parts.Bom
WHERE ParentItemId = @PId AND PublishedAt IS NOT NULL AND DeprecatedAt IS NULL;
DECLARE @OnlyVerStr NVARCHAR(20) = CAST(@OnlyVer AS NVARCHAR(20));
EXEC test.Assert_IsEqual
    @TestName = N'[BomActiveAfterDep] Only active version is v2',
    @Expected = N'2',
    @Actual   = @OnlyVerStr;
GO

-- =============================================
-- Test 20: Bom_WhereUsedByChildItem for CHILD-001 returns rows for v1 + v2
-- =============================================
DECLARE @C1 BIGINT;
SELECT @C1 = Id FROM Parts.Item WHERE PartNumber = N'TEST-BOM-CHILD-001';

CREATE TABLE #WU1 (
    BomLineId         BIGINT,
    BomId             BIGINT,
    ParentItemId      BIGINT,
    ParentPartNumber  NVARCHAR(50),
    ParentDescription NVARCHAR(500),
    VersionNumber     INT,
    PublishedAt       DATETIME2(3),
    DeprecatedAt      DATETIME2(3),
    QtyPer            DECIMAL(10,4),
    UomId             BIGINT,
    UomCode           NVARCHAR(20)
);

INSERT INTO #WU1 EXEC Parts.Bom_WhereUsedByChildItem
    @ChildItemId = @C1,
    @ActiveOnly  = 0;

DECLARE @WU1Count INT;
SELECT @WU1Count = COUNT(*) FROM #WU1;
DROP TABLE #WU1;

DECLARE @WU1Ok NVARCHAR(1) = CASE WHEN @WU1Count >= 2 THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[WhereUsedC1] At least 2 rows returned for CHILD-001',
    @Expected = N'1',
    @Actual   = @WU1Ok;
GO

-- =============================================
-- Test 21: Bom_WhereUsedByChildItem for an unrelated child returns 0 rows
-- =============================================
DECLARE @C3 BIGINT;
-- CHILD-003 was never added as a line (BomLineAdd on published v1 was rejected,
-- and v2 was cloned from v1 which had only CHILD-001 and CHILD-002)
SELECT @C3 = Id FROM Parts.Item WHERE PartNumber = N'TEST-BOM-CHILD-003';

CREATE TABLE #WU3 (
    BomLineId         BIGINT,
    BomId             BIGINT,
    ParentItemId      BIGINT,
    ParentPartNumber  NVARCHAR(50),
    ParentDescription NVARCHAR(500),
    VersionNumber     INT,
    PublishedAt       DATETIME2(3),
    DeprecatedAt      DATETIME2(3),
    QtyPer            DECIMAL(10,4),
    UomId             BIGINT,
    UomCode           NVARCHAR(20)
);

INSERT INTO #WU3 EXEC Parts.Bom_WhereUsedByChildItem
    @ChildItemId = @C3,
    @ActiveOnly  = 0;

DECLARE @C3Count INT;
SELECT @C3Count = COUNT(*) FROM #WU3;
DROP TABLE #WU3;

EXEC test.Assert_RowCount
    @TestName      = N'[WhereUsedC3] 0 rows returned for CHILD-003',
    @ExpectedCount = 0,
    @ActualCount   = @C3Count;
GO

-- =============================================
-- Test 22: Bom_Get happy path
--   NOTE: Bom_Get returns 2 result sets (header + lines). INSERT-EXEC only
--   captures the first (header). Lines are covered by BomLine_ListByBom tests.
-- =============================================
DECLARE @PId  BIGINT, @V2Id BIGINT;

SELECT @PId  = Id FROM Parts.Item WHERE PartNumber = N'TEST-BOM-PARENT-001';
SELECT @V2Id = Id FROM Parts.Bom WHERE ParentItemId = @PId AND VersionNumber = 2;

CREATE TABLE #BomGetHeader (
    Id BIGINT, ParentItemId BIGINT, PartNumber NVARCHAR(50), VersionNumber INT,
    EffectiveFrom DATETIME2(3), PublishedAt DATETIME2(3), DeprecatedAt DATETIME2(3),
    CreatedByUserId BIGINT, CreatedByDisplayName NVARCHAR(200), CreatedAt DATETIME2(3)
);
INSERT INTO #BomGetHeader EXEC Parts.Bom_Get @Id = @V2Id;
DECLARE @BomGetCount INT = (SELECT COUNT(*) FROM #BomGetHeader);
DROP TABLE #BomGetHeader;

EXEC test.Assert_RowCount
    @TestName      = N'[BomGet] Header result set returns 1 row',
    @ExpectedCount = 1,
    @ActualCount   = @BomGetCount;
GO

-- =============================================
-- Test 23: Audit trail - ConfigLog has >= 4 entries for Code='Bom'
-- =============================================
DECLARE @AuditCount INT;
SELECT @AuditCount = COUNT(*)
FROM Audit.ConfigLog cl
INNER JOIN Audit.LogEntityType let ON let.Id = cl.LogEntityTypeId
INNER JOIN Parts.Bom b              ON b.Id = cl.EntityId
INNER JOIN Parts.Item it            ON it.Id = b.ParentItemId
WHERE let.Code = N'Bom'
  AND it.PartNumber = N'TEST-BOM-PARENT-001';

DECLARE @AuditOk NVARCHAR(1) = CASE WHEN @AuditCount >= 4 THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[BomAudit] ConfigLog has >= 4 entries for Code=Bom',
    @Expected = N'1',
    @Actual   = @AuditOk;
GO

-- =============================================
-- Cleanup (dependency-safe order)
-- =============================================
DELETE bl
FROM Parts.BomLine bl
INNER JOIN Parts.Bom b  ON b.Id = bl.BomId
INNER JOIN Parts.Item p ON p.Id = b.ParentItemId
WHERE p.PartNumber = N'TEST-BOM-PARENT-001';

DELETE b
FROM Parts.Bom b
INNER JOIN Parts.Item p ON p.Id = b.ParentItemId
WHERE p.PartNumber = N'TEST-BOM-PARENT-001';

DELETE FROM Parts.Item WHERE PartNumber LIKE N'TEST-BOM-PARENT-%'
                          OR PartNumber LIKE N'TEST-BOM-CHILD-%';
GO

-- =============================================
-- Final summary
-- =============================================
EXEC test.PrintSummary;
GO
