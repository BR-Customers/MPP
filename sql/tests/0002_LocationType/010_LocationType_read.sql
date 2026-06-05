-- =============================================
-- File:         0002_LocationType/010_LocationType_read.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-04-13
-- Rewritten:    2026-04-14 (Ignition JDBC refactor)
-- Description:
--   Tests for LocationType and LocationTypeDefinition read procs.
--   Covers: list, get by Id, filtered list, deprecated filter.
-- =============================================

EXEC test.BeginTestFile @FileName = N'0002_LocationType/010_LocationType_read.sql';
GO

-- =============================================
-- Test 1: LocationType_List — returns all 5 rows
-- =============================================
DECLARE @Count INT;
CREATE TABLE #R (Id BIGINT, Code NVARCHAR(50), Name NVARCHAR(100), HierarchyLevel INT, Description NVARCHAR(500));
INSERT INTO #R EXEC Location.LocationType_List;
SELECT @Count = COUNT(*) FROM #R;
DROP TABLE #R;
EXEC test.Assert_RowCount
    @TestName      = N'LocationType_List: 5 rows returned by proc',
    @ExpectedCount = 5,
    @ActualCount   = @Count;
GO

-- =============================================
-- Test 2: LocationType_Get(1) — returns Enterprise
-- =============================================
DECLARE @Count INT;
DECLARE @Code NVARCHAR(50);
CREATE TABLE #R (Id BIGINT, Code NVARCHAR(50), Name NVARCHAR(100), HierarchyLevel INT, Description NVARCHAR(500));
INSERT INTO #R EXEC Location.LocationType_Get @Id = 1;
SELECT @Count = COUNT(*), @Code = MAX(Code) FROM #R;
DROP TABLE #R;

EXEC test.Assert_RowCount
    @TestName      = N'LocationType_Get(1): 1 row returned',
    @ExpectedCount = 1,
    @ActualCount   = @Count;

EXEC test.Assert_IsEqual
    @TestName = N'LocationType_Get(1): Code is Enterprise',
    @Expected = N'Enterprise',
    @Actual   = @Code;
GO

-- =============================================
-- Test 3: LocationType_Get(999) — empty result
-- =============================================
DECLARE @Count INT;
CREATE TABLE #R (Id BIGINT, Code NVARCHAR(50), Name NVARCHAR(100), HierarchyLevel INT, Description NVARCHAR(500));
INSERT INTO #R EXEC Location.LocationType_Get @Id = 999;
SELECT @Count = COUNT(*) FROM #R;
DROP TABLE #R;
EXEC test.Assert_RowCount
    @TestName      = N'LocationType_Get(999): 0 rows (missing Id)',
    @ExpectedCount = 0,
    @ActualCount   = @Count;
GO

-- =============================================
-- Test 4: LocationTypeDefinition_List (no filter) — returns all non-deprecated
--   Expected count derived dynamically so the test survives new kinds being
--   seeded (e.g. the Printer kind added by 011_seed_locations_mpp_plant.sql).
-- =============================================
DECLARE @Count INT, @Expected INT;
SELECT @Expected = COUNT(*) FROM Location.LocationTypeDefinition WHERE DeprecatedAt IS NULL;
CREATE TABLE #R (
    Id BIGINT,
    LocationTypeId BIGINT,
    LocationTypeName NVARCHAR(100),
    Code NVARCHAR(50),
    Name NVARCHAR(100),
    Description NVARCHAR(500),
    Icon NVARCHAR(100),
    CreatedAt DATETIME2(3),
    DeprecatedAt DATETIME2(3)
);
INSERT INTO #R EXEC Location.LocationTypeDefinition_List;
SELECT @Count = COUNT(*) FROM #R;
DROP TABLE #R;
EXEC test.Assert_RowCount
    @TestName      = N'LocationTypeDefinition_List (all): proc count matches active def count',
    @ExpectedCount = @Expected,
    @ActualCount   = @Count;
GO

-- =============================================
-- Test 5: LocationTypeDefinition_List(@LocationTypeId=5) — Cell-tier defs
--   Expected count derived dynamically (Cell-tier kinds grow over time, e.g.
--   the seeded Printer kind is LocationTypeId=5).
-- =============================================
DECLARE @Count INT, @Expected INT;
SELECT @Expected = COUNT(*) FROM Location.LocationTypeDefinition
WHERE LocationTypeId = 5 AND DeprecatedAt IS NULL;
CREATE TABLE #R (
    Id BIGINT,
    LocationTypeId BIGINT,
    LocationTypeName NVARCHAR(100),
    Code NVARCHAR(50),
    Name NVARCHAR(100),
    Description NVARCHAR(500),
    Icon NVARCHAR(100),
    CreatedAt DATETIME2(3),
    DeprecatedAt DATETIME2(3)
);
INSERT INTO #R EXEC Location.LocationTypeDefinition_List @LocationTypeId = 5;
SELECT @Count = COUNT(*) FROM #R;
DROP TABLE #R;
EXEC test.Assert_RowCount
    @TestName      = N'LocationTypeDefinition_List(Cell): proc count matches active Cell-tier def count',
    @ExpectedCount = @Expected,
    @ActualCount   = @Count;
GO

-- =============================================
-- Test 6: LocationTypeDefinition_List(@IncludeDeprecated=0 / 1)
--   Deprecate one stable kind (Scale, by Code), confirm the proc's filter,
--   then restore. Expected counts derived dynamically against current state.
-- =============================================
UPDATE Location.LocationTypeDefinition
SET DeprecatedAt = SYSUTCDATETIME()
WHERE Code = N'Scale';
GO

DECLARE @Count INT, @Expected INT;
-- After deprecating Scale, the default (excl-deprecated) proc must return
-- exactly the active rows.
SELECT @Expected = COUNT(*) FROM Location.LocationTypeDefinition WHERE DeprecatedAt IS NULL;
CREATE TABLE #R (
    Id BIGINT,
    LocationTypeId BIGINT,
    LocationTypeName NVARCHAR(100),
    Code NVARCHAR(50),
    Name NVARCHAR(100),
    Description NVARCHAR(500),
    Icon NVARCHAR(100),
    CreatedAt DATETIME2(3),
    DeprecatedAt DATETIME2(3)
);
INSERT INTO #R EXEC Location.LocationTypeDefinition_List @IncludeDeprecated = 0;
SELECT @Count = COUNT(*) FROM #R;
DROP TABLE #R;
EXEC test.Assert_RowCount
    @TestName      = N'LocationTypeDefinition_List(excl deprecated): excludes the deprecated Scale kind',
    @ExpectedCount = @Expected,
    @ActualCount   = @Count;
GO

DECLARE @Count INT, @Expected INT;
-- IncludeDeprecated=1 must return every row regardless of DeprecatedAt.
SELECT @Expected = COUNT(*) FROM Location.LocationTypeDefinition;
CREATE TABLE #R (
    Id BIGINT,
    LocationTypeId BIGINT,
    LocationTypeName NVARCHAR(100),
    Code NVARCHAR(50),
    Name NVARCHAR(100),
    Description NVARCHAR(500),
    Icon NVARCHAR(100),
    CreatedAt DATETIME2(3),
    DeprecatedAt DATETIME2(3)
);
INSERT INTO #R EXEC Location.LocationTypeDefinition_List @IncludeDeprecated = 1;
SELECT @Count = COUNT(*) FROM #R;
DROP TABLE #R;
EXEC test.Assert_RowCount
    @TestName      = N'LocationTypeDefinition_List(incl deprecated): returns all rows incl deprecated Scale',
    @ExpectedCount = @Expected,
    @ActualCount   = @Count;
GO

-- Restore seed state
UPDATE Location.LocationTypeDefinition
SET DeprecatedAt = NULL
WHERE Code = N'Scale';
GO

-- =============================================
-- Test 7: LocationTypeDefinition_Get(8) — returns DieCastMachine
-- =============================================
DECLARE @Count INT;
DECLARE @Code NVARCHAR(50);
CREATE TABLE #R (
    Id BIGINT,
    LocationTypeId BIGINT,
    LocationTypeName NVARCHAR(100),
    Code NVARCHAR(50),
    Name NVARCHAR(100),
    Description NVARCHAR(500),
    Icon NVARCHAR(100),
    CreatedAt DATETIME2(3),
    DeprecatedAt DATETIME2(3)
);
INSERT INTO #R EXEC Location.LocationTypeDefinition_Get @Id = 8;
SELECT @Count = COUNT(*), @Code = MAX(Code) FROM #R;
DROP TABLE #R;

EXEC test.Assert_RowCount
    @TestName      = N'LocationTypeDefinition_Get(8): 1 row returned',
    @ExpectedCount = 1,
    @ActualCount   = @Count;

EXEC test.Assert_IsEqual
    @TestName = N'LocationTypeDefinition_Get(8): Code is DieCastMachine',
    @Expected = N'DieCastMachine',
    @Actual   = @Code;
GO

-- =============================================
-- Final summary
-- =============================================
EXEC test.PrintSummary;
GO
