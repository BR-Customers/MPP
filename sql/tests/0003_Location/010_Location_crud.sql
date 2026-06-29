-- =============================================
-- File:         0003_Location/010_Location_crud.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-04-13
-- Description:
--   Tests for Location CRUD procs (List, Get, Create, Update, Deprecate).
--   Covers: create root and child locations, auto-SortOrder, FK validation,
--   Code uniqueness, get, list with filters, update, deprecate with child
--   check, SortOrder compaction, and audit trail verification.
--
--   Pre-conditions:
--     - Migration 0002 applied (LocationType: 5 rows)
--     - Migration 0003 applied (Icon column on LocationTypeDefinition)
--     - All 5 Location CRUD procs deployed
--     - Bootstrap user Id=1 exists
--     - MPP plant seed (011) applied. This test is self-contained: it creates
--       its own root subtree under distinct codes (MPP, MPP-MADISON, MPP-DC,
--       MPP-CNC, MPP-LINE-A/B/C) and cleans them up at the end. The only
--       seed-coupled assertion (Test 9, ProductionArea count) is derived
--       dynamically so it survives seed regeneration.
-- =============================================

EXEC test.BeginTestFile @FileName = N'0003_Location/010_Location_crud.sql';
GO

-- =============================================
-- Test 1: Create Enterprise root (ParentLocationId=NULL, DefinitionId=1 Organization)
-- =============================================
DECLARE @S BIT, @M NVARCHAR(500);
DECLARE @SStr NVARCHAR(1);
DECLARE @NewId BIGINT;

CREATE TABLE #R1 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R1
EXEC Location.Location_Create
    @LocationTypeDefinitionId = 1,
    @ParentLocationId         = NULL,
    @Name                     = N'Madison Precision Products',
    @Code                     = N'MPP',
    @Description              = N'Enterprise root',
    @AppUserId                = 1;
SELECT @S = Status, @M = Message, @NewId = NewId FROM #R1;
DROP TABLE #R1;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'Create Enterprise root: status is 1',
    @Expected = N'1',
    @Actual   = @SStr;

DECLARE @NewIdNotNull NVARCHAR(1) = CASE WHEN @NewId IS NOT NULL THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'Create Enterprise root: NewId returned',
    @Expected = N'1',
    @Actual   = @NewIdNotNull;

-- Verify SortOrder = 2 (seed pre-populates MPP-ENT at SortOrder=1;
-- this new root-level Enterprise is the 2nd root sibling)
DECLARE @Sort INT;
SELECT @Sort = SortOrder FROM Location.Location WHERE Id = @NewId;
DECLARE @SortStr NVARCHAR(10) = CAST(@Sort AS NVARCHAR(10));
EXEC test.Assert_IsEqual
    @TestName = N'Create Enterprise root: SortOrder is 2 (after seed MPP-ENT)',
    @Expected = N'2',
    @Actual   = @SortStr;
GO

-- =============================================
-- Test 2: Create Site under Enterprise
-- =============================================
DECLARE @S BIT, @M NVARCHAR(500);
DECLARE @SStr NVARCHAR(1);
DECLARE @NewId BIGINT;

-- Get the Enterprise root Id
DECLARE @EnterpriseId BIGINT;
SELECT @EnterpriseId = Id FROM Location.Location WHERE Code = N'MPP';

CREATE TABLE #R2 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R2
EXEC Location.Location_Create
    @LocationTypeDefinitionId = 2,
    @ParentLocationId         = @EnterpriseId,
    @Name                     = N'Madison Plant',
    @Code                     = N'MPP-MADISON',
    @Description              = N'Main manufacturing facility',
    @AppUserId                = 1;
SELECT @S = Status, @M = Message, @NewId = NewId FROM #R2;
DROP TABLE #R2;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'Create Site under Enterprise: status is 1',
    @Expected = N'1',
    @Actual   = @SStr;

-- Verify SortOrder = 1 (first child of Enterprise)
DECLARE @Sort INT;
SELECT @Sort = SortOrder FROM Location.Location WHERE Id = @NewId;
DECLARE @SortStr NVARCHAR(10) = CAST(@Sort AS NVARCHAR(10));
EXEC test.Assert_IsEqual
    @TestName = N'Create Site under Enterprise: SortOrder is 1',
    @Expected = N'1',
    @Actual   = @SortStr;
GO

-- =============================================
-- Test 3: Create two Areas under Site — verify SortOrder auto-increments
-- =============================================
DECLARE @S BIT, @M NVARCHAR(500);
DECLARE @SStr NVARCHAR(1);
DECLARE @NewId1 BIGINT, @NewId2 BIGINT;

DECLARE @SiteId BIGINT;
SELECT @SiteId = Id FROM Location.Location WHERE Code = N'MPP-MADISON';

-- Create first Area
CREATE TABLE #R3a (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R3a
EXEC Location.Location_Create
    @LocationTypeDefinitionId = 3,
    @ParentLocationId         = @SiteId,
    @Name                     = N'Die Cast Area',
    @Code                     = N'MPP-DC',
    @AppUserId                = 1;
SELECT @S = Status, @M = Message, @NewId1 = NewId FROM #R3a;
DROP TABLE #R3a;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'Create Area 1: status is 1',
    @Expected = N'1',
    @Actual   = @SStr;

DECLARE @Sort1 INT;
SELECT @Sort1 = SortOrder FROM Location.Location WHERE Id = @NewId1;
DECLARE @Sort1Str NVARCHAR(10) = CAST(@Sort1 AS NVARCHAR(10));
EXEC test.Assert_IsEqual
    @TestName = N'Create Area 1: SortOrder is 1',
    @Expected = N'1',
    @Actual   = @Sort1Str;

-- Create second Area
CREATE TABLE #R3b (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R3b
EXEC Location.Location_Create
    @LocationTypeDefinitionId = 3,
    @ParentLocationId         = @SiteId,
    @Name                     = N'CNC Area',
    @Code                     = N'MPP-CNC',
    @AppUserId                = 1;
SELECT @S = Status, @M = Message, @NewId2 = NewId FROM #R3b;
DROP TABLE #R3b;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'Create Area 2: status is 1',
    @Expected = N'1',
    @Actual   = @SStr;

DECLARE @Sort2 INT;
SELECT @Sort2 = SortOrder FROM Location.Location WHERE Id = @NewId2;
DECLARE @Sort2Str NVARCHAR(10) = CAST(@Sort2 AS NVARCHAR(10));
EXEC test.Assert_IsEqual
    @TestName = N'Create Area 2: SortOrder is 2',
    @Expected = N'2',
    @Actual   = @Sort2Str;
GO

-- =============================================
-- Test 4: Create with invalid LocationTypeDefinitionId — rejected
-- =============================================
DECLARE @S BIT, @M NVARCHAR(500);
DECLARE @SStr NVARCHAR(1);
DECLARE @NewId BIGINT;

CREATE TABLE #R4 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R4
EXEC Location.Location_Create
    @LocationTypeDefinitionId = 99999,
    @ParentLocationId         = NULL,
    @Name                     = N'Bad Location',
    @Code                     = N'BAD-LOC',
    @AppUserId                = 1;
SELECT @S = Status, @M = Message, @NewId = NewId FROM #R4;
DROP TABLE #R4;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'Create invalid DefinitionId: status is 0',
    @Expected = N'0',
    @Actual   = @SStr;

EXEC test.Assert_IsEqual
    @TestName = N'Create invalid DefinitionId: message says invalid',
    @Expected = N'Invalid or deprecated LocationTypeDefinitionId.',
    @Actual   = @M;
GO

-- =============================================
-- Test 5: Create with duplicate Code — rejected
-- =============================================
DECLARE @S BIT, @M NVARCHAR(500);
DECLARE @SStr NVARCHAR(1);
DECLARE @NewId BIGINT;

CREATE TABLE #R5 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R5
EXEC Location.Location_Create
    @LocationTypeDefinitionId = 1,
    @ParentLocationId         = NULL,
    @Name                     = N'Duplicate Enterprise',
    @Code                     = N'MPP',
    @AppUserId                = 1;
SELECT @S = Status, @M = Message, @NewId = NewId FROM #R5;
DROP TABLE #R5;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'Create duplicate Code: status is 0',
    @Expected = N'0',
    @Actual   = @SStr;

EXEC test.Assert_IsEqual
    @TestName = N'Create duplicate Code: message says already exists',
    @Expected = N'A location with this Code already exists.',
    @Actual   = @M;
GO

-- =============================================
-- Test 6: Create with invalid ParentLocationId — rejected
-- =============================================
DECLARE @S BIT, @M NVARCHAR(500);
DECLARE @SStr NVARCHAR(1);
DECLARE @NewId BIGINT;

CREATE TABLE #R6 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R6
EXEC Location.Location_Create
    @LocationTypeDefinitionId = 2,
    @ParentLocationId         = 99999,
    @Name                     = N'Orphan Site',
    @Code                     = N'ORPHAN',
    @AppUserId                = 1;
SELECT @S = Status, @M = Message, @NewId = NewId FROM #R6;
DROP TABLE #R6;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'Create invalid ParentId: status is 0',
    @Expected = N'0',
    @Actual   = @SStr;

EXEC test.Assert_IsEqual
    @TestName = N'Create invalid ParentId: message says invalid',
    @Expected = N'Invalid or deprecated ParentLocationId.',
    @Actual   = @M;
GO

-- =============================================
-- Test 7: Get by known Id — verify fields match what was created
-- =============================================
DECLARE @EnterpriseId BIGINT;
SELECT @EnterpriseId = Id FROM Location.Location WHERE Code = N'MPP';

DECLARE @Count INT;
DECLARE @Name NVARCHAR(200), @GotCode NVARCHAR(50), @DefName NVARCHAR(200), @TypeName NVARCHAR(200);
CREATE TABLE #R (
    Id BIGINT, LocationTypeDefinitionId BIGINT, ParentLocationId BIGINT,
    Name NVARCHAR(200), Code NVARCHAR(50), Description NVARCHAR(500),
    SortOrder INT, CreatedAt DATETIME2(3), DeprecatedAt DATETIME2(3),
    LocationTypeDefinitionName NVARCHAR(200), LocationTypeDefinitionIcon NVARCHAR(100),
    LocationTypeName NVARCHAR(200)
);
INSERT INTO #R EXEC Location.Location_Get @Id = @EnterpriseId;
SELECT @Count = COUNT(*),
       @Name = MAX(Name), @GotCode = MAX(Code),
       @DefName = MAX(LocationTypeDefinitionName), @TypeName = MAX(LocationTypeName)
FROM #R;
DROP TABLE #R;

EXEC test.Assert_RowCount
    @TestName      = N'Get Enterprise: 1 row returned',
    @ExpectedCount = 1,
    @ActualCount   = @Count;

EXEC test.Assert_IsEqual
    @TestName = N'Get Enterprise: Name is correct',
    @Expected = N'Madison Precision Products',
    @Actual   = @Name;

EXEC test.Assert_IsEqual
    @TestName = N'Get Enterprise: Code is correct',
    @Expected = N'MPP',
    @Actual   = @GotCode;

EXEC test.Assert_IsEqual
    @TestName = N'Get Enterprise: DefinitionName is Organization',
    @Expected = N'Organization',
    @Actual   = @DefName;

EXEC test.Assert_IsEqual
    @TestName = N'Get Enterprise: TypeName is Enterprise',
    @Expected = N'Enterprise',
    @Actual   = @TypeName;
GO

-- =============================================
-- Test 8: List children of Site (filter by ParentLocationId) — verify returns Areas
-- =============================================
DECLARE @SiteId BIGINT;
SELECT @SiteId = Id FROM Location.Location WHERE Code = N'MPP-MADISON';

DECLARE @ChildCount INT;
CREATE TABLE #R (
    Id BIGINT, LocationTypeDefinitionId BIGINT, ParentLocationId BIGINT,
    Name NVARCHAR(200), Code NVARCHAR(50), Description NVARCHAR(500),
    SortOrder INT, CreatedAt DATETIME2(3), DeprecatedAt DATETIME2(3),
    LocationTypeDefinitionName NVARCHAR(200), LocationTypeName NVARCHAR(200),
    Icon NVARCHAR(100)
);
INSERT INTO #R EXEC Location.Location_List @ParentLocationId = @SiteId, @FilterByParent = 1;
SELECT @ChildCount = COUNT(*) FROM #R;
DROP TABLE #R;

EXEC test.Assert_RowCount
    @TestName      = N'List children of Site: 2 Areas returned by proc',
    @ExpectedCount = 2,
    @ActualCount   = @ChildCount;

-- Verify ordering: first child should have SortOrder 1
DECLARE @FirstSort INT;
SELECT TOP 1 @FirstSort = SortOrder
FROM Location.Location
WHERE ParentLocationId = @SiteId AND DeprecatedAt IS NULL
ORDER BY SortOrder ASC;

DECLARE @FirstSortStr NVARCHAR(10) = CAST(@FirstSort AS NVARCHAR(10));
EXEC test.Assert_IsEqual
    @TestName = N'List children of Site: first SortOrder is 1',
    @Expected = N'1',
    @Actual   = @FirstSortStr;
GO

-- =============================================
-- Test 9: List with LocationTypeDefinitionId filter — verify filtering works
-- =============================================
DECLARE @DefCount INT, @Expected INT;
-- Derived: all active ProductionArea (DefId 3) rows = seeded plant areas plus
-- the 2 areas created above (MPP-DC, MPP-CNC). Comparing the proc result to an
-- independent direct count validates the LocationTypeDefinitionId filter
-- without hardcoding the seed's area count.
SELECT @Expected = COUNT(*) FROM Location.Location
WHERE LocationTypeDefinitionId = 3 AND DeprecatedAt IS NULL;
CREATE TABLE #R (
    Id BIGINT, LocationTypeDefinitionId BIGINT, ParentLocationId BIGINT,
    Name NVARCHAR(200), Code NVARCHAR(50), Description NVARCHAR(500),
    SortOrder INT, CreatedAt DATETIME2(3), DeprecatedAt DATETIME2(3),
    LocationTypeDefinitionName NVARCHAR(200), LocationTypeName NVARCHAR(200),
    Icon NVARCHAR(100)
);
INSERT INTO #R EXEC Location.Location_List @LocationTypeDefinitionId = 3;
SELECT @DefCount = COUNT(*) FROM #R;
DROP TABLE #R;

EXEC test.Assert_RowCount
    @TestName      = N'List by DefinitionId 3: proc returns all active ProductionAreas (seeded + 2 test)',
    @ExpectedCount = @Expected,
    @ActualCount   = @DefCount;
GO

-- =============================================
-- Test 10: Update Name of a location — verify changed
-- =============================================
DECLARE @S BIT, @M NVARCHAR(500);
DECLARE @SStr NVARCHAR(1);

DECLARE @TargetId BIGINT;
SELECT @TargetId = Id FROM Location.Location WHERE Code = N'MPP-DC';

CREATE TABLE #R10 (Status BIT, Message NVARCHAR(500));
INSERT INTO #R10
EXEC Location.Location_Update
    @Id          = @TargetId,
    @Name        = N'Die Cast Production Area',
    @Code        = N'MPP-DC',
    @Description = N'Updated description',
    @AppUserId   = 1;
SELECT @S = Status, @M = Message FROM #R10;
DROP TABLE #R10;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'Update Name: status is 1',
    @Expected = N'1',
    @Actual   = @SStr;

-- Verify name changed
DECLARE @NewName NVARCHAR(200);
SELECT @NewName = Name FROM Location.Location WHERE Id = @TargetId;

EXEC test.Assert_IsEqual
    @TestName = N'Update Name: Name changed',
    @Expected = N'Die Cast Production Area',
    @Actual   = @NewName;
GO

-- =============================================
-- Test 11: Update with duplicate Code — rejected
-- =============================================
DECLARE @S BIT, @M NVARCHAR(500);
DECLARE @SStr NVARCHAR(1);

DECLARE @TargetId BIGINT;
SELECT @TargetId = Id FROM Location.Location WHERE Code = N'MPP-DC';

-- Try to change Code to an existing Code
CREATE TABLE #R11 (Status BIT, Message NVARCHAR(500));
INSERT INTO #R11
EXEC Location.Location_Update
    @Id          = @TargetId,
    @Name        = N'Die Cast Production Area',
    @Code        = N'MPP-CNC',
    @AppUserId   = 1;
SELECT @S = Status, @M = Message FROM #R11;
DROP TABLE #R11;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'Update duplicate Code: status is 0',
    @Expected = N'0',
    @Actual   = @SStr;

EXEC test.Assert_IsEqual
    @TestName = N'Update duplicate Code: message says already exists',
    @Expected = N'A location with this Code already exists.',
    @Actual   = @M;
GO

-- =============================================
-- Test 12: Deprecate a leaf location (Area with no children) — verify DeprecatedAt set
-- =============================================
DECLARE @S BIT, @M NVARCHAR(500);
DECLARE @SStr NVARCHAR(1);

DECLARE @LeafId BIGINT;
SELECT @LeafId = Id FROM Location.Location WHERE Code = N'MPP-CNC';

CREATE TABLE #R12 (Status BIT, Message NVARCHAR(500));
INSERT INTO #R12
EXEC Location.Location_Deprecate
    @Id        = @LeafId,
    @AppUserId = 1;
SELECT @S = Status, @M = Message FROM #R12;
DROP TABLE #R12;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'Deprecate leaf (CNC Area): status is 1',
    @Expected = N'1',
    @Actual   = @SStr;

-- Verify DeprecatedAt is set
DECLARE @DepAt DATETIME2(3);
SELECT @DepAt = DeprecatedAt FROM Location.Location WHERE Id = @LeafId;

DECLARE @DepAtNotNull NVARCHAR(1) = CASE WHEN @DepAt IS NOT NULL THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'Deprecate leaf: DeprecatedAt is set',
    @Expected = N'1',
    @Actual   = @DepAtNotNull;
GO

-- =============================================
-- Test 13: Deprecate a location with children — rejected
-- =============================================
DECLARE @S BIT, @M NVARCHAR(500);
DECLARE @SStr NVARCHAR(1);

-- Site has child Areas (at least MPP-DC is still active)
DECLARE @SiteId BIGINT;
SELECT @SiteId = Id FROM Location.Location WHERE Code = N'MPP-MADISON';

CREATE TABLE #R13 (Status BIT, Message NVARCHAR(500));
INSERT INTO #R13
EXEC Location.Location_Deprecate
    @Id        = @SiteId,
    @AppUserId = 1;
SELECT @S = Status, @M = Message FROM #R13;
DROP TABLE #R13;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'Deprecate with children: status is 0',
    @Expected = N'0',
    @Actual   = @SStr;

EXEC test.Assert_IsEqual
    @TestName = N'Deprecate with children: message says active children',
    @Expected = N'Cannot deprecate: active child locations exist.',
    @Actual   = @M;
GO

-- =============================================
-- Test 14: Verify SortOrder compaction after deprecate
--   Create 3 siblings, deprecate the middle one, verify remaining renumber to 1,2
-- =============================================
DECLARE @S BIT, @M NVARCHAR(500);
DECLARE @SStr NVARCHAR(1);
DECLARE @NewId1 BIGINT, @NewId2 BIGINT, @NewId3 BIGINT;

DECLARE @SiteId BIGINT;
SELECT @SiteId = Id FROM Location.Location WHERE Code = N'MPP-MADISON';

-- Create 3 WorkCenter siblings under Site
CREATE TABLE #R14a (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R14a
EXEC Location.Location_Create
    @LocationTypeDefinitionId = 5,
    @ParentLocationId         = @SiteId,
    @Name                     = N'Line A',
    @Code                     = N'MPP-LINE-A',
    @AppUserId                = 1;
SELECT @S = Status, @M = Message, @NewId1 = NewId FROM #R14a;
DROP TABLE #R14a;

CREATE TABLE #R14b (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R14b
EXEC Location.Location_Create
    @LocationTypeDefinitionId = 5,
    @ParentLocationId         = @SiteId,
    @Name                     = N'Line B',
    @Code                     = N'MPP-LINE-B',
    @AppUserId                = 1;
SELECT @S = Status, @M = Message, @NewId2 = NewId FROM #R14b;
DROP TABLE #R14b;

CREATE TABLE #R14c (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R14c
EXEC Location.Location_Create
    @LocationTypeDefinitionId = 5,
    @ParentLocationId         = @SiteId,
    @Name                     = N'Line C',
    @Code                     = N'MPP-LINE-C',
    @AppUserId                = 1;
SELECT @S = Status, @M = Message, @NewId3 = NewId FROM #R14c;
DROP TABLE #R14c;

-- Before deprecate: Die Cast Area is SortOrder=1 (only active Area left),
-- Line A=2, Line B=3, Line C=4 (new siblings after CNC was deprecated and compacted)
-- Actually, the existing active sibling MPP-DC was SortOrder=1 before these creates.
-- The 3 new lines got SortOrder 2, 3, 4.
-- Deprecate Line B (the middle of the 3 lines, SortOrder=3)

CREATE TABLE #R14d (Status BIT, Message NVARCHAR(500));
INSERT INTO #R14d
EXEC Location.Location_Deprecate
    @Id        = @NewId2,
    @AppUserId = 1;
SELECT @S = Status, @M = Message FROM #R14d;
DROP TABLE #R14d;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'Deprecate Line B: status is 1',
    @Expected = N'1',
    @Actual   = @SStr;

-- Verify remaining active siblings have compacted SortOrder (1, 2, 3)
-- Active siblings of Site: MPP-DC (was 1), Line A (was 2), Line C (was 4) → should be 1, 2, 3
DECLARE @MaxSort INT, @MinSort INT, @ActiveCount INT;
SELECT @MaxSort = MAX(SortOrder),
       @MinSort = MIN(SortOrder),
       @ActiveCount = COUNT(*)
FROM Location.Location
WHERE ParentLocationId = @SiteId AND DeprecatedAt IS NULL;

DECLARE @MaxSortStr NVARCHAR(10) = CAST(@MaxSort AS NVARCHAR(10));
DECLARE @MinSortStr NVARCHAR(10) = CAST(@MinSort AS NVARCHAR(10));

EXEC test.Assert_IsEqual
    @TestName = N'SortOrder compaction: min is 1',
    @Expected = N'1',
    @Actual   = @MinSortStr;

EXEC test.Assert_IsEqual
    @TestName = N'SortOrder compaction: max equals active count',
    @Expected = N'3',
    @Actual   = @MaxSortStr;

EXEC test.Assert_RowCount
    @TestName      = N'SortOrder compaction: 3 active siblings remain',
    @ExpectedCount = 3,
    @ActualCount   = @ActiveCount;
GO

-- =============================================
-- Test 15: Audit trail — verify ConfigLog entries exist for Location entity
-- =============================================
DECLARE @AuditCount INT;
SELECT @AuditCount = COUNT(*)
FROM Audit.ConfigLog cl
INNER JOIN Audit.LogEntityType let ON let.Id = cl.LogEntityTypeId
WHERE let.Code = N'Location';

-- We should have at least:
--   4 creates (Enterprise, Site, Die Cast Area, CNC Area)
--   + 3 creates (Line A, B, C)
--   + 1 update (Die Cast Area name)
--   + 2 deprecates (CNC Area, Line B)
--   = 10 minimum
DECLARE @HasAudit NVARCHAR(1) = CASE WHEN @AuditCount >= 10 THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'Audit trail: at least 10 ConfigLog entries for Location',
    @Expected = N'1',
    @Actual   = @HasAudit;
GO

-- =============================================
-- Test 16: Audit-readability — Create narrative + resolved-FK JSON
--   The Madison Plant (MPP-MADISON) was created under the MPP enterprise root.
-- =============================================
DECLARE @CreateDesc NVARCHAR(500), @CreateNew NVARCHAR(MAX);
SELECT TOP 1 @CreateDesc = cl.Description, @CreateNew = cl.NewValue
FROM Audit.ConfigLog cl
INNER JOIN Audit.LogEntityType let ON let.Id = cl.LogEntityTypeId
WHERE let.Code = N'Location'
  AND cl.Description LIKE N'Location MPP-MADISON %'
  AND cl.Description LIKE N'% Created%'
ORDER BY cl.Id DESC;

EXEC test.Assert_Contains
    @TestName    = N'Create audit: Description matches "Location <Code> ... Created under ..."',
    @HaystackStr = @CreateDesc,
    @NeedleStr   = N'Created under MPP';

EXEC test.Assert_Contains
    @TestName    = N'Create audit: NewValue JSON carries LocationTypeDefinition FK sub-object',
    @HaystackStr = @CreateNew,
    @NeedleStr   = N'"LocationTypeDefinition":{';

EXEC test.Assert_Contains
    @TestName    = N'Create audit: NewValue JSON carries Parent FK sub-object',
    @HaystackStr = @CreateNew,
    @NeedleStr   = N'"Parent":{';
GO

-- =============================================
-- Test 17: Audit-readability — Update narrative + resolved-FK JSON
--   MPP-DC was renamed in Test 10.
-- =============================================
DECLARE @UpdateDesc NVARCHAR(500), @UpdateOld NVARCHAR(MAX);
SELECT TOP 1 @UpdateDesc = cl.Description, @UpdateOld = cl.OldValue
FROM Audit.ConfigLog cl
INNER JOIN Audit.LogEntityType let ON let.Id = cl.LogEntityTypeId
WHERE let.Code = N'Location'
  AND cl.Description LIKE N'Location MPP-DC % Updated %'
ORDER BY cl.Id DESC;

EXEC test.Assert_Contains
    @TestName    = N'Update audit: Description shows a Name field diff arrow',
    @HaystackStr = @UpdateDesc,
    @NeedleStr   = N'Name "';

EXEC test.Assert_Contains
    @TestName    = N'Update audit: OldValue JSON carries LocationTypeDefinition FK sub-object',
    @HaystackStr = @UpdateOld,
    @NeedleStr   = N'"LocationTypeDefinition":{';
GO

-- =============================================
-- Test 18: Audit-readability — Deprecate narrative + resolved-FK JSON
--   MPP-CNC (CNC Area) was deprecated in Test 12.
-- =============================================
DECLARE @DepDesc NVARCHAR(500), @DepOld NVARCHAR(MAX), @DepNew NVARCHAR(MAX);
SELECT TOP 1 @DepDesc = cl.Description, @DepOld = cl.OldValue, @DepNew = cl.NewValue
FROM Audit.ConfigLog cl
INNER JOIN Audit.LogEntityType let ON let.Id = cl.LogEntityTypeId
WHERE let.Code = N'Location'
  AND cl.Description LIKE N'Location MPP-CNC % Deprecated'
ORDER BY cl.Id DESC;

EXEC test.Assert_Contains
    @TestName    = N'Deprecate audit: Description ends with Deprecated',
    @HaystackStr = @DepDesc,
    @NeedleStr   = N'Deprecated';

EXEC test.Assert_Contains
    @TestName    = N'Deprecate audit: OldValue JSON carries LocationTypeDefinition FK sub-object',
    @HaystackStr = @DepOld,
    @NeedleStr   = N'"LocationTypeDefinition":{';

DECLARE @DepNewIsNull NVARCHAR(1) = CASE WHEN @DepNew IS NULL THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'Deprecate audit: NewValue is NULL per convention',
    @Expected = N'1',
    @Actual   = @DepNewIsNull;
GO

-- =============================================
-- Cleanup: remove test data to restore clean state
-- =============================================

-- Delete children first (bottom-up), then parents
-- Lines under Site
DELETE FROM Location.Location WHERE Code IN (N'MPP-LINE-A', N'MPP-LINE-B', N'MPP-LINE-C');
-- Areas under Site
DELETE FROM Location.Location WHERE Code IN (N'MPP-DC', N'MPP-CNC');
-- Site under Enterprise
DELETE FROM Location.Location WHERE Code = N'MPP-MADISON';
-- Enterprise root
DELETE FROM Location.Location WHERE Code = N'MPP';
GO

-- =============================================
-- Final summary
-- =============================================
EXEC test.PrintSummary;
GO
