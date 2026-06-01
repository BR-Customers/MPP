-- =============================================
-- File:         0010_Parts_Bom/060_Bom_ListByParentItem_v3.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-05-26
-- Description:
--   Tests the v3.0 upgrade of Parts.Bom_ListByParentItem:
--     - LineCount column populated
--     - Status column ("Draft" | "Published" | "Deprecated")
--     - @IncludeDeprecated semantics
--     - Draft-first ordering
-- =============================================

EXEC test.BeginTestFile @FileName = N'0010_Parts_Bom/060_Bom_ListByParentItem_v3.sql';
GO

-- Setup: parent + child + Bom v1 (Published) + Bom v2 (Draft)
DECLARE @S BIT, @M NVARCHAR(500), @NewId BIGINT;

CREATE TABLE #Rl1 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rl1 EXEC Parts.Item_Create
    @PartNumber = N'TEST-LB-PARENT-001', @ItemTypeId = 4,
    @Description = N'List parent', @UomId = 1, @AppUserId = 1;
DROP TABLE #Rl1;

CREATE TABLE #Rl2 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rl2 EXEC Parts.Item_Create
    @PartNumber = N'TEST-LB-CHILD-001', @ItemTypeId = 2,
    @Description = N'List child', @UomId = 1, @AppUserId = 1;
DROP TABLE #Rl2;

DECLARE @PId BIGINT, @C1 BIGINT;
SELECT @PId = Id FROM Parts.Item WHERE PartNumber = N'TEST-LB-PARENT-001';
SELECT @C1  = Id FROM Parts.Item WHERE PartNumber = N'TEST-LB-CHILD-001';

CREATE TABLE #Rl3 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rl3 EXEC Parts.Bom_Create
    @ParentItemId = @PId, @AppUserId = 1;
DROP TABLE #Rl3;

DECLARE @V1Id BIGINT;
SELECT @V1Id = Id FROM Parts.Bom WHERE ParentItemId = @PId AND VersionNumber = 1;

CREATE TABLE #Rl4 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rl4 EXEC Parts.BomLine_Add
    @BomId = @V1Id, @ChildItemId = @C1,
    @QtyPer = 1.0, @UomId = 1, @AppUserId = 1;
DROP TABLE #Rl4;

CREATE TABLE #Rl5 (Status BIT, Message NVARCHAR(500));
INSERT INTO #Rl5 EXEC Parts.Bom_Publish
    @Id = @V1Id, @AppUserId = 1;
DROP TABLE #Rl5;

-- Create v2 draft (clones v1)
CREATE TABLE #Rl6 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rl6 EXEC Parts.Bom_CreateNewVersion
    @ParentBomId = @V1Id, @AppUserId = 1;
DROP TABLE #Rl6;
GO

-- =============================================
-- Test 1: ListByParentItem returns rows with LineCount + Status
-- =============================================
DECLARE @PId BIGINT;
SELECT @PId = Id FROM Parts.Item WHERE PartNumber = N'TEST-LB-PARENT-001';

CREATE TABLE #LBList (
    Id BIGINT, ParentItemId BIGINT, VersionNumber INT,
    EffectiveFrom DATETIME2(3), PublishedAt DATETIME2(3), DeprecatedAt DATETIME2(3),
    CreatedByUserId BIGINT, CreatedByDisplayName NVARCHAR(200),
    CreatedAt DATETIME2(3), LineCount INT, [Status] NVARCHAR(20)
);
INSERT INTO #LBList EXEC Parts.Bom_ListByParentItem
    @ParentItemId = @PId, @IncludeDeprecated = 0;

DECLARE @Count INT = (SELECT COUNT(*) FROM #LBList);
EXEC test.Assert_RowCount
    @TestName = N'[ListV3] 2 active rows (v1 published + v2 draft)',
    @ExpectedCount = 2, @ActualCount = @Count;

-- LineCount: v1 has 1, v2 (clone) has 1
DECLARE @LcV1 INT = (SELECT LineCount FROM #LBList WHERE VersionNumber = 1);
DECLARE @LcV1Str NVARCHAR(5) = CAST(@LcV1 AS NVARCHAR(5));
EXEC test.Assert_IsEqual
    @TestName = N'[ListV3] v1 LineCount = 1',
    @Expected = N'1', @Actual = @LcV1Str;

DECLARE @LcV2 INT = (SELECT LineCount FROM #LBList WHERE VersionNumber = 2);
DECLARE @LcV2Str NVARCHAR(5) = CAST(@LcV2 AS NVARCHAR(5));
EXEC test.Assert_IsEqual
    @TestName = N'[ListV3] v2 LineCount = 1 (cloned)',
    @Expected = N'1', @Actual = @LcV2Str;

-- Status column
DECLARE @StatusV1 NVARCHAR(20) = (SELECT [Status] FROM #LBList WHERE VersionNumber = 1);
EXEC test.Assert_IsEqual
    @TestName = N'[ListV3] v1 Status = Published',
    @Expected = N'Published', @Actual = @StatusV1;

DECLARE @StatusV2 NVARCHAR(20) = (SELECT [Status] FROM #LBList WHERE VersionNumber = 2);
EXEC test.Assert_IsEqual
    @TestName = N'[ListV3] v2 Status = Draft',
    @Expected = N'Draft', @Actual = @StatusV2;

DROP TABLE #LBList;
GO

-- =============================================
-- Test 2: @IncludeDeprecated semantics
--   Deprecate v1, list with default (0) -> only v2 returned.
--   List with 1 -> both v1 + v2 returned.
-- =============================================
DECLARE @PId BIGINT, @V1Id BIGINT;
SELECT @PId  = Id FROM Parts.Item WHERE PartNumber = N'TEST-LB-PARENT-001';
SELECT @V1Id = Id FROM Parts.Bom  WHERE ParentItemId = @PId AND VersionNumber = 1;

CREATE TABLE #Rl7 (Status BIT, Message NVARCHAR(500));
INSERT INTO #Rl7 EXEC Parts.Bom_Deprecate @Id = @V1Id, @AppUserId = 1;
DROP TABLE #Rl7;

-- Default (IncludeDeprecated = 0)
CREATE TABLE #LBExc (
    Id BIGINT, ParentItemId BIGINT, VersionNumber INT,
    EffectiveFrom DATETIME2(3), PublishedAt DATETIME2(3), DeprecatedAt DATETIME2(3),
    CreatedByUserId BIGINT, CreatedByDisplayName NVARCHAR(200),
    CreatedAt DATETIME2(3), LineCount INT, [Status] NVARCHAR(20)
);
INSERT INTO #LBExc EXEC Parts.Bom_ListByParentItem
    @ParentItemId = @PId, @IncludeDeprecated = 0;
DECLARE @ExcCount INT = (SELECT COUNT(*) FROM #LBExc);
EXEC test.Assert_RowCount
    @TestName = N'[ListIncDep0] 1 row (v2 only, v1 deprecated)',
    @ExpectedCount = 1, @ActualCount = @ExcCount;
DROP TABLE #LBExc;

-- IncludeDeprecated = 1
CREATE TABLE #LBInc (
    Id BIGINT, ParentItemId BIGINT, VersionNumber INT,
    EffectiveFrom DATETIME2(3), PublishedAt DATETIME2(3), DeprecatedAt DATETIME2(3),
    CreatedByUserId BIGINT, CreatedByDisplayName NVARCHAR(200),
    CreatedAt DATETIME2(3), LineCount INT, [Status] NVARCHAR(20)
);
INSERT INTO #LBInc EXEC Parts.Bom_ListByParentItem
    @ParentItemId = @PId, @IncludeDeprecated = 1;
DECLARE @IncCount INT = (SELECT COUNT(*) FROM #LBInc);
EXEC test.Assert_RowCount
    @TestName = N'[ListIncDep1] 2 rows (v1 deprecated + v2 draft)',
    @ExpectedCount = 2, @ActualCount = @IncCount;

DECLARE @V1Status NVARCHAR(20) = (SELECT [Status] FROM #LBInc WHERE VersionNumber = 1);
EXEC test.Assert_IsEqual
    @TestName = N'[ListIncDep1] v1 Status = Deprecated',
    @Expected = N'Deprecated', @Actual = @V1Status;
DROP TABLE #LBInc;
GO

-- =============================================
-- Test 3: Backward-compat @ActiveOnly alias
-- =============================================
DECLARE @PId BIGINT;
SELECT @PId = Id FROM Parts.Item WHERE PartNumber = N'TEST-LB-PARENT-001';

CREATE TABLE #LBLegacy (
    Id BIGINT, ParentItemId BIGINT, VersionNumber INT,
    EffectiveFrom DATETIME2(3), PublishedAt DATETIME2(3), DeprecatedAt DATETIME2(3),
    CreatedByUserId BIGINT, CreatedByDisplayName NVARCHAR(200),
    CreatedAt DATETIME2(3), LineCount INT, [Status] NVARCHAR(20)
);
-- Legacy call shape: @ActiveOnly only
INSERT INTO #LBLegacy EXEC Parts.Bom_ListByParentItem
    @ParentItemId = @PId, @ActiveOnly = 0;
DECLARE @LegacyCount INT = (SELECT COUNT(*) FROM #LBLegacy);
DROP TABLE #LBLegacy;
EXEC test.Assert_RowCount
    @TestName = N'[ListLegacy] @ActiveOnly=0 includes deprecated',
    @ExpectedCount = 2, @ActualCount = @LegacyCount;
GO

-- Cleanup
DELETE bl FROM Parts.BomLine bl
INNER JOIN Parts.Bom b  ON b.Id = bl.BomId
INNER JOIN Parts.Item p ON p.Id = b.ParentItemId
WHERE p.PartNumber = N'TEST-LB-PARENT-001';

DELETE b FROM Parts.Bom b
INNER JOIN Parts.Item p ON p.Id = b.ParentItemId
WHERE p.PartNumber = N'TEST-LB-PARENT-001';

DELETE FROM Parts.Item WHERE PartNumber LIKE N'TEST-LB-%';
GO

EXEC test.PrintSummary;
GO
