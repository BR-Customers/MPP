-- =============================================
-- File:         0013_Tools_Types/010_Types_read.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-04-23
-- Description:
--   Read-only tests for the Tools schema seed-only code tables.
--   Verifies the migration 0010 seeds land exactly as specified.
-- =============================================

EXEC test.BeginTestFile @FileName = N'0013_Tools_Types/010_Types_read.sql';
GO

-- =============================================
-- Test 1: ToolStatusCode_List returns 4 seed rows
-- =============================================
CREATE TABLE #TS (Id BIGINT, Code NVARCHAR(30), Name NVARCHAR(100), Description NVARCHAR(500));
INSERT INTO #TS EXEC Tools.ToolStatusCode_List;

DECLARE @Count INT = (SELECT COUNT(*) FROM #TS);
EXEC test.Assert_RowCount
    @TestName      = N'[ToolStatusCode_List] 4 rows',
    @ExpectedCount = 4,
    @ActualCount   = @Count;

DECLARE @HasActive INT = (SELECT COUNT(*) FROM #TS WHERE Code = N'Active');
DECLARE @HasActiveStr NVARCHAR(5) = CAST(@HasActive AS NVARCHAR(5));
EXEC test.Assert_IsEqual
    @TestName = N'[ToolStatusCode_List] Contains Active',
    @Expected = N'1',
    @Actual   = @HasActiveStr;

DECLARE @HasScrapped INT = (SELECT COUNT(*) FROM #TS WHERE Code = N'Scrapped');
DECLARE @HasScrappedStr NVARCHAR(5) = CAST(@HasScrapped AS NVARCHAR(5));
EXEC test.Assert_IsEqual
    @TestName = N'[ToolStatusCode_List] Contains Scrapped',
    @Expected = N'1',
    @Actual   = @HasScrappedStr;

DROP TABLE #TS;
GO

-- =============================================
-- Test 2: ToolCavityStatusCode_List returns 3 seed rows
-- =============================================
CREATE TABLE #TCS (Id BIGINT, Code NVARCHAR(30), Name NVARCHAR(100), Description NVARCHAR(500));
INSERT INTO #TCS EXEC Tools.ToolCavityStatusCode_List;

DECLARE @Count INT = (SELECT COUNT(*) FROM #TCS);
EXEC test.Assert_RowCount
    @TestName      = N'[ToolCavityStatusCode_List] 3 rows',
    @ExpectedCount = 3,
    @ActualCount   = @Count;

DECLARE @HasClosed INT = (SELECT COUNT(*) FROM #TCS WHERE Code = N'Closed');
DECLARE @HasClosedStr NVARCHAR(5) = CAST(@HasClosed AS NVARCHAR(5));
EXEC test.Assert_IsEqual
    @TestName = N'[ToolCavityStatusCode_List] Contains Closed',
    @Expected = N'1',
    @Actual   = @HasClosedStr;

DROP TABLE #TCS;
GO

-- =============================================
-- Test 3: ToolType_List returns 6 seed rows; Die has HasCavities=1
-- =============================================
CREATE TABLE #TT (
    Id BIGINT, Code NVARCHAR(50), Name NVARCHAR(100),
    Description NVARCHAR(500), Icon NVARCHAR(100),
    HasCavities BIT, CompatibleLocationTypeDefinitionId BIGINT, SortOrder INT,
    CreatedAt DATETIME2(3), DeprecatedAt DATETIME2(3)
);
INSERT INTO #TT EXEC Tools.ToolType_List @IncludeDeprecated = 0;

DECLARE @Count INT = (SELECT COUNT(*) FROM #TT);
EXEC test.Assert_RowCount
    @TestName      = N'[ToolType_List] 6 active rows',
    @ExpectedCount = 6,
    @ActualCount   = @Count;

DECLARE @DieHasCavities BIT =
    (SELECT HasCavities FROM #TT WHERE Code = N'Die');
DECLARE @DieHasCavitiesStr NVARCHAR(1) = CAST(@DieHasCavities AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[ToolType_List] Die HasCavities = 1',
    @Expected = N'1',
    @Actual   = @DieHasCavitiesStr;

DECLARE @CutterHasCavities BIT =
    (SELECT HasCavities FROM #TT WHERE Code = N'Cutter');
DECLARE @CutterHasCavitiesStr NVARCHAR(1) = CAST(@CutterHasCavities AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[ToolType_List] Cutter HasCavities = 0',
    @Expected = N'0',
    @Actual   = @CutterHasCavitiesStr;

DROP TABLE #TT;
GO

-- =============================================
-- Test 4: ToolType_Get by Id — happy + not-found
-- =============================================
CREATE TABLE #TG (
    Id BIGINT, Code NVARCHAR(50), Name NVARCHAR(100),
    Description NVARCHAR(500), Icon NVARCHAR(100),
    HasCavities BIT, CompatibleLocationTypeDefinitionId BIGINT, SortOrder INT,
    CreatedAt DATETIME2(3), DeprecatedAt DATETIME2(3)
);
INSERT INTO #TG EXEC Tools.ToolType_Get @Id = 1;
DECLARE @GotCode NVARCHAR(50) = (SELECT TOP 1 Code FROM #TG);
EXEC test.Assert_IsEqual
    @TestName = N'[ToolType_Get] Id=1 returns Die',
    @Expected = N'Die',
    @Actual   = @GotCode;
DROP TABLE #TG;

CREATE TABLE #TG2 (
    Id BIGINT, Code NVARCHAR(50), Name NVARCHAR(100),
    Description NVARCHAR(500), Icon NVARCHAR(100),
    HasCavities BIT, CompatibleLocationTypeDefinitionId BIGINT, SortOrder INT,
    CreatedAt DATETIME2(3), DeprecatedAt DATETIME2(3)
);
INSERT INTO #TG2 EXEC Tools.ToolType_Get @Id = 999999;
DECLARE @NFCount INT = (SELECT COUNT(*) FROM #TG2);
EXEC test.Assert_RowCount
    @TestName      = N'[ToolType_Get] not-found returns 0 rows',
    @ExpectedCount = 0,
    @ActualCount   = @NFCount;
DROP TABLE #TG2;
GO

EXEC test.PrintSummary;
GO
