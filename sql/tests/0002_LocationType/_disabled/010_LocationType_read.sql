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
-- Test 4: LocationTypeDefinition_List (no filter) — returns 15 rows
-- =============================================
DECLARE @Count INT;
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
    @TestName      = N'LocationTypeDefinition_List (all): 15 rows returned by proc',
    @ExpectedCount = 15,
    @ActualCount   = @Count;
GO

-- =============================================
-- Test 5: LocationTypeDefinition_List(@LocationTypeId=5) — 9 Cell defs
-- =============================================
DECLARE @Count INT;
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
    @TestName      = N'LocationTypeDefinition_List(Cell): 9 Cell-tier definitions',
    @ExpectedCount = 9,
    @ActualCount   = @Count;
GO

-- =============================================
-- Test 6: LocationTypeDefinition_List(@IncludeDeprecated=0 / 1)
--   Deprecate one row, confirm proc filters, then restore.
-- =============================================
UPDATE Location.LocationTypeDefinition
SET DeprecatedAt = SYSUTCDATETIME()
WHERE Id = 15;
GO

DECLARE @Count INT;
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
    @TestName      = N'LocationTypeDefinition_List(excl deprecated): 14 after deprecating Scale',
    @ExpectedCount = 14,
    @ActualCount   = @Count;
GO

DECLARE @Count INT;
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
    @TestName      = N'LocationTypeDefinition_List(incl deprecated): 15 with deprecated included',
    @ExpectedCount = 15,
    @ActualCount   = @Count;
GO

-- Restore seed state
UPDATE Location.LocationTypeDefinition
SET DeprecatedAt = NULL
WHERE Id = 15;
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
