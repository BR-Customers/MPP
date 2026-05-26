-- =============================================
-- File:         0010_Parts_Bom/070_Item_ListAvailableForBom.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-05-26
-- Description:
--   Tests Parts.Item_ListAvailableForBom -- excludes parent + deprecated,
--   honors @SearchText filter.
-- =============================================

EXEC test.BeginTestFile @FileName = N'0010_Parts_Bom/070_Item_ListAvailableForBom.sql';
GO

-- Setup: parent + 3 children + 1 deprecated child
DECLARE @S BIT, @M NVARCHAR(500), @NewId BIGINT;

CREATE TABLE #Ra1 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Ra1 EXEC Parts.Item_Create
    @PartNumber = N'TEST-LA-PARENT-001', @ItemTypeId = 4,
    @Description = N'Available parent', @UomId = 1, @AppUserId = 1;
DROP TABLE #Ra1;

CREATE TABLE #Ra2 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Ra2 EXEC Parts.Item_Create
    @PartNumber = N'TEST-LA-ALPHA-001', @ItemTypeId = 2,
    @Description = N'Alpha component', @UomId = 1, @AppUserId = 1;
DROP TABLE #Ra2;

CREATE TABLE #Ra3 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Ra3 EXEC Parts.Item_Create
    @PartNumber = N'TEST-LA-ALPHA-002', @ItemTypeId = 2,
    @Description = N'Beta component', @UomId = 1, @AppUserId = 1;
DROP TABLE #Ra3;

CREATE TABLE #Ra4 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Ra4 EXEC Parts.Item_Create
    @PartNumber = N'TEST-LA-DEPR-001', @ItemTypeId = 2,
    @Description = N'Deprecated component', @UomId = 1, @AppUserId = 1;
DROP TABLE #Ra4;

DECLARE @PId BIGINT, @DepId BIGINT;
SELECT @PId   = Id FROM Parts.Item WHERE PartNumber = N'TEST-LA-PARENT-001';
SELECT @DepId = Id FROM Parts.Item WHERE PartNumber = N'TEST-LA-DEPR-001';

-- Deprecate one child
UPDATE Parts.Item SET DeprecatedAt = SYSUTCDATETIME() WHERE Id = @DepId;
GO

-- =============================================
-- Test 1: no @SearchText returns all active items except parent
-- =============================================
DECLARE @PId BIGINT;
SELECT @PId = Id FROM Parts.Item WHERE PartNumber = N'TEST-LA-PARENT-001';

CREATE TABLE #LA (
    Id BIGINT, PartNumber NVARCHAR(50), Description NVARCHAR(500),
    ItemTypeId BIGINT, ItemTypeName NVARCHAR(50),
    DefaultUomId BIGINT, DefaultUomCode NVARCHAR(20)
);
INSERT INTO #LA EXEC Parts.Item_ListAvailableForBom
    @ParentItemId = @PId, @SearchText = NULL;

DECLARE @Total INT = (SELECT COUNT(*) FROM #LA WHERE PartNumber LIKE N'TEST-LA-%');
DECLARE @TotalStr NVARCHAR(5) = CAST(@Total AS NVARCHAR(5));
EXEC test.Assert_IsEqual
    @TestName = N'[Avail] 2 TEST-LA items returned (excl. parent + deprecated)',
    @Expected = N'2', @Actual = @TotalStr;

-- Parent itself not in result
DECLARE @ParentInResult INT = (SELECT COUNT(*) FROM #LA WHERE Id = @PId);
EXEC test.Assert_RowCount
    @TestName = N'[Avail] Parent Item excluded',
    @ExpectedCount = 0, @ActualCount = @ParentInResult;

-- Deprecated child not in result
DECLARE @DepId BIGINT;
SELECT @DepId = Id FROM Parts.Item WHERE PartNumber = N'TEST-LA-DEPR-001';
DECLARE @DepInResult INT = (SELECT COUNT(*) FROM #LA WHERE Id = @DepId);
EXEC test.Assert_RowCount
    @TestName = N'[Avail] Deprecated Item excluded',
    @ExpectedCount = 0, @ActualCount = @DepInResult;

DROP TABLE #LA;
GO

-- =============================================
-- Test 2: @SearchText prefix-matches PartNumber
-- =============================================
DECLARE @PId BIGINT;
SELECT @PId = Id FROM Parts.Item WHERE PartNumber = N'TEST-LA-PARENT-001';

CREATE TABLE #LASearch (
    Id BIGINT, PartNumber NVARCHAR(50), Description NVARCHAR(500),
    ItemTypeId BIGINT, ItemTypeName NVARCHAR(50),
    DefaultUomId BIGINT, DefaultUomCode NVARCHAR(20)
);
INSERT INTO #LASearch EXEC Parts.Item_ListAvailableForBom
    @ParentItemId = @PId, @SearchText = N'TEST-LA-ALPHA';

DECLARE @MatchCount INT = (SELECT COUNT(*) FROM #LASearch WHERE PartNumber LIKE N'TEST-LA-ALPHA-%');
EXEC test.Assert_RowCount
    @TestName = N'[AvailSearch] 2 TEST-LA-ALPHA items returned',
    @ExpectedCount = 2, @ActualCount = @MatchCount;

DROP TABLE #LASearch;
GO

-- Cleanup
DELETE FROM Parts.Item WHERE PartNumber LIKE N'TEST-LA-%';
GO

EXEC test.PrintSummary;
GO
