-- =============================================
-- File:         0003_Location/060_Location_ListByTier.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-05-19
-- Description:
--   Tests for Location.Location_ListByTier.
--   Covers: returns matching rows, filters out deprecated, returns 0 for unknown tier.
--
--   Pre-conditions:
--     - Migration 0002 applied (LocationType seed has Tier 1..5 incl Area)
--     - Location.Location has at least one Area-tier row from seed_locations.sql
-- =============================================

EXEC test.BeginTestFile @FileName = N'0003_Location/060_Location_ListByTier.sql';
GO

-- =============================================
-- Setup: insert one Area-tier Location for deterministic assertions.
--   Location.Location has no LocationTypeId column; tier is resolved via
--   LocationTypeDefinition.LocationTypeId. Uses ProductionArea definition (Id=3)
--   which belongs to the Area tier (LocationType.Id=3).
--   Parent: first active Site-tier location from seed.
-- =============================================
DECLARE @ProductionAreaDefId BIGINT = (
    SELECT Id FROM Location.LocationTypeDefinition WHERE Code = N'ProductionArea'
);

DECLARE @ParentId BIGINT = (
    SELECT TOP 1 l.Id
    FROM Location.Location l
    INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
    INNER JOIN Location.LocationType lt ON lt.Id = ltd.LocationTypeId
    WHERE lt.Code = N'Site'
      AND l.DeprecatedAt IS NULL
);

INSERT INTO Location.Location (Code, Name, LocationTypeDefinitionId, ParentLocationId, SortOrder)
VALUES (N'TEST110-DC-AREA', N'Test110 Die Cast Area', @ProductionAreaDefId, @ParentId, 99);

INSERT INTO Location.Location (Code, Name, LocationTypeDefinitionId, ParentLocationId, SortOrder, DeprecatedAt)
VALUES (N'TEST110-DEPR-AREA', N'Test110 Deprecated Area', @ProductionAreaDefId, @ParentId, 100, SYSUTCDATETIME());
GO

-- =============================================
-- Test 1: ListByTier('Area') returns the Test110 active area
-- =============================================
CREATE TABLE #ByTier1 (
    Id                       BIGINT,
    Code                     NVARCHAR(50),
    Name                     NVARCHAR(200),
    LocationTypeDefinitionId BIGINT,
    ParentLocationId         BIGINT,
    SortOrder                INT,
    DeprecatedAt             DATETIME2(3)
);

INSERT INTO #ByTier1
EXEC Location.Location_ListByTier @TierCode = N'Area';

-- Assert 1a: active test row is returned
DECLARE @Cnt1a INT = (SELECT COUNT(*) FROM #ByTier1 WHERE Code = N'TEST110-DC-AREA');
EXEC test.Assert_RowCount
    @TestName      = N'ListByTier(Area): active Test110 row returned',
    @ExpectedCount = 1,
    @ActualCount   = @Cnt1a;

-- Assert 1b: deprecated row is excluded
DECLARE @Cnt1b INT = (SELECT COUNT(*) FROM #ByTier1 WHERE Code = N'TEST110-DEPR-AREA');
EXEC test.Assert_RowCount
    @TestName      = N'ListByTier(Area): deprecated row excluded',
    @ExpectedCount = 0,
    @ActualCount   = @Cnt1b;

DROP TABLE #ByTier1;
GO

-- =============================================
-- Test 2: Unknown tier code returns 0 rows (no error)
-- =============================================
CREATE TABLE #ByTier2 (
    Id                       BIGINT,
    Code                     NVARCHAR(50),
    Name                     NVARCHAR(200),
    LocationTypeDefinitionId BIGINT,
    ParentLocationId         BIGINT,
    SortOrder                INT,
    DeprecatedAt             DATETIME2(3)
);

INSERT INTO #ByTier2
EXEC Location.Location_ListByTier @TierCode = N'BogusTier';

DECLARE @Cnt2 INT = (SELECT COUNT(*) FROM #ByTier2);
EXEC test.Assert_RowCount
    @TestName      = N'ListByTier(BogusTier): 0 rows returned',
    @ExpectedCount = 0,
    @ActualCount   = @Cnt2;

DROP TABLE #ByTier2;
GO

-- =============================================
-- Cleanup: remove test fixture rows
-- =============================================
DELETE FROM Location.Location
WHERE Code IN (N'TEST110-DC-AREA', N'TEST110-DEPR-AREA');
GO

-- =============================================
-- Final summary
-- =============================================
EXEC test.PrintSummary;
GO
