-- =============================================
-- File:         0009_Parts_Process/050_Location_ListForEligibilityPicker.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-05-27
-- Description:  Tests for Location.Location_ListForEligibilityPicker.
--               Covers: returns rows, sort order is (TierOrdinal ASC,
--               Code ASC), DisplayLabel matches "Code — Name (TierName)"
--               shape.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0009_Parts_Process/050_Location_ListForEligibilityPicker.sql';
GO

-- =============================================
-- Test 1: Returns at least one row
-- =============================================
IF OBJECT_ID('tempdb..#P1') IS NOT NULL DROP TABLE #P1;
CREATE TABLE #P1 (
    Id BIGINT, Code NVARCHAR(50), Name NVARCHAR(200),
    TierName NVARCHAR(100), TierOrdinal INT, DisplayLabel NVARCHAR(400)
);
INSERT INTO #P1 EXEC Location.Location_ListForEligibilityPicker;

DECLARE @Cnt INT = (SELECT COUNT(*) FROM #P1);
DECLARE @CntStr NVARCHAR(20) = CASE WHEN @Cnt > 0 THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[PickerNonEmpty] Returns at least one row',
    @Expected = N'1',
    @Actual   = @CntStr;
DROP TABLE #P1;
GO

-- =============================================
-- Test 2: Sort order is (TierOrdinal ASC, Code ASC) — first row's TierOrdinal <= last row's
-- =============================================
IF OBJECT_ID('tempdb..#P2') IS NOT NULL DROP TABLE #P2;
CREATE TABLE #P2 (
    RowNum INT IDENTITY(1,1) PRIMARY KEY,
    Id BIGINT, Code NVARCHAR(50), Name NVARCHAR(200),
    TierName NVARCHAR(100), TierOrdinal INT, DisplayLabel NVARCHAR(400)
);
INSERT INTO #P2 (Id, Code, Name, TierName, TierOrdinal, DisplayLabel)
EXEC Location.Location_ListForEligibilityPicker;

DECLARE @FirstTier INT = (SELECT TOP 1 TierOrdinal FROM #P2 ORDER BY RowNum ASC);
DECLARE @LastTier  INT = (SELECT TOP 1 TierOrdinal FROM #P2 ORDER BY RowNum DESC);
DECLARE @SortOk NVARCHAR(1) = CASE WHEN @FirstTier <= @LastTier THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[PickerSort] First row TierOrdinal <= last row TierOrdinal',
    @Expected = N'1',
    @Actual   = @SortOk;
DROP TABLE #P2;
GO

-- =============================================
-- Test 3: DisplayLabel contains the em-dash separator pattern
-- =============================================
IF OBJECT_ID('tempdb..#P3') IS NOT NULL DROP TABLE #P3;
CREATE TABLE #P3 (
    Id BIGINT, Code NVARCHAR(50), Name NVARCHAR(200),
    TierName NVARCHAR(100), TierOrdinal INT, DisplayLabel NVARCHAR(400)
);
INSERT INTO #P3 EXEC Location.Location_ListForEligibilityPicker;

DECLARE @Sep NVARCHAR(5) = NCHAR(8212);
DECLARE @AnyMatch NVARCHAR(1) =
    CASE WHEN EXISTS (SELECT 1 FROM #P3 WHERE DisplayLabel LIKE N'% ' + @Sep + N' % (%)') THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[PickerLabel] DisplayLabel matches "code — name (tier)" shape',
    @Expected = N'1',
    @Actual   = @AnyMatch;
DROP TABLE #P3;
GO

-- =============================================
-- Test 4 (v1.1, Jacques 2026-07-06): only Area + WorkCenter tiers offered
-- =============================================
IF OBJECT_ID('tempdb..#P4') IS NOT NULL DROP TABLE #P4;
CREATE TABLE #P4 (
    Id BIGINT, Code NVARCHAR(50), Name NVARCHAR(200),
    TierName NVARCHAR(100), TierOrdinal INT, DisplayLabel NVARCHAR(400)
);
INSERT INTO #P4 EXEC Location.Location_ListForEligibilityPicker;

DECLARE @BadTier INT = (SELECT COUNT(*) FROM #P4 WHERE TierOrdinal NOT IN (2, 3));
DECLARE @BadTierStr NVARCHAR(10) = CAST(@BadTier AS NVARCHAR(10));
EXEC test.Assert_IsEqual
    @TestName = N'[PickerTiers] only Area (2) + WorkCenter (3) tiers offered',
    @Expected = N'0',
    @Actual   = @BadTierStr;

-- terminals + printers (Cell tier) are structurally excluded
DECLARE @HasCell INT = (SELECT COUNT(*) FROM #P4 p
    INNER JOIN Location.Location l ON l.Id = p.Id
    INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
    INNER JOIN Location.LocationType lt ON lt.Id = ltd.LocationTypeId
    WHERE lt.HierarchyLevel = 4);
DECLARE @HasCellStr NVARCHAR(10) = CAST(@HasCell AS NVARCHAR(10));
EXEC test.Assert_IsEqual
    @TestName = N'[PickerTiers] no Cell-tier rows (terminals/printers excluded)',
    @Expected = N'0',
    @Actual   = @HasCellStr;
DROP TABLE #P4;
GO

EXEC test.EndTestFile;
GO
