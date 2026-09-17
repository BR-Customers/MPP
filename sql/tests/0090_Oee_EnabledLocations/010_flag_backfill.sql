-- =============================================
-- File:         0090_Oee_EnabledLocations/010_flag_backfill.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-09-17
-- Description:  Location.Location.IsOeeEnabled exists, defaults to 0, and the
--               0090 backfill (repeated by seed 034 on a fresh build) flagged
--               exactly the set the pre-change equipment rule returned:
--               active, Cell/WorkCenter tier, not a device or store, and no
--               WorkCenter ancestor above it.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0090_Oee_EnabledLocations/010_flag_backfill.sql';
GO

-- =============================================
-- Test 1: the column exists and the migration is recorded.
-- =============================================
DECLARE @col NVARCHAR(10) = CASE WHEN COL_LENGTH(N'Location.Location', N'IsOeeEnabled') IS NULL
                                 THEN N'missing' ELSE N'present' END;
EXEC test.Assert_IsEqual @TestName = N'[OeeFlag] Location.IsOeeEnabled column exists',
     @Expected = N'present', @Actual = @col;

DECLARE @mig NVARCHAR(10) = CASE WHEN EXISTS (SELECT 1 FROM dbo.SchemaVersion
                                              WHERE MigrationId = N'0090_location_is_oee_enabled')
                                 THEN N'yes' ELSE N'no' END;
EXEC test.Assert_IsEqual @TestName = N'[OeeFlag] migration 0090 recorded in SchemaVersion',
     @Expected = N'yes', @Actual = @mig;
GO

-- =============================================
-- Test 2: the flagged set equals the pre-change rule, computed independently
-- here (nearest-WorkCenter-ancestor walk, device/store exclusions).
-- =============================================
;WITH Tree AS (
    SELECT l.Id, CAST(CASE WHEN lt.Code = N'WorkCenter' THEN l.Id END AS BIGINT) AS NearestWorkCenterId
    FROM Location.Location l
    INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
    INNER JOIN Location.LocationType lt            ON lt.Id  = ltd.LocationTypeId
    WHERE l.ParentLocationId IS NULL
    UNION ALL
    SELECT c.Id, CAST(CASE WHEN lt.Code = N'WorkCenter' THEN c.Id ELSE t.NearestWorkCenterId END AS BIGINT)
    FROM Location.Location c
    INNER JOIN Tree t                              ON c.ParentLocationId = t.Id
    INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = c.LocationTypeDefinitionId
    INNER JOIN Location.LocationType lt            ON lt.Id  = ltd.LocationTypeId
)
SELECT l.Id
INTO #Expected
FROM Location.Location l
INNER JOIN Tree t                              ON t.Id   = l.Id
INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
INNER JOIN Location.LocationType lt            ON lt.Id  = ltd.LocationTypeId
WHERE l.DeprecatedAt IS NULL
  AND lt.Code IN (N'WorkCenter', N'Cell')
  AND ltd.Code NOT IN (N'Terminal', N'Printer', N'InventoryLocation', N'Receiving', N'Scale')
  AND COALESCE(t.NearestWorkCenterId, l.Id) = l.Id
OPTION (MAXRECURSION 20);

DECLARE @missing INT = (SELECT COUNT(*) FROM #Expected e
                        WHERE NOT EXISTS (SELECT 1 FROM Location.Location l
                                          WHERE l.Id = e.Id AND l.IsOeeEnabled = 1));
DECLARE @extra INT = (SELECT COUNT(*) FROM Location.Location l
                      WHERE l.IsOeeEnabled = 1
                        AND NOT EXISTS (SELECT 1 FROM #Expected e WHERE e.Id = l.Id));
DECLARE @missingTxt NVARCHAR(10) = CAST(@missing AS NVARCHAR(10));
DECLARE @extraTxt   NVARCHAR(10) = CAST(@extra AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[OeeFlag] every location the old rule admitted is flagged',
     @Expected = N'0', @Actual = @missingTxt;
EXEC test.Assert_IsEqual @TestName = N'[OeeFlag] nothing outside the old rule is flagged',
     @Expected = N'0', @Actual = @extraTxt;

DECLARE @anyFlagged INT = (SELECT COUNT(*) FROM Location.Location WHERE IsOeeEnabled = 1);
DECLARE @anyTxt NVARCHAR(10) = CASE WHEN @anyFlagged > 0 THEN N'yes' ELSE N'no' END;
EXEC test.Assert_IsEqual @TestName = N'[OeeFlag] the backfill flagged something (seed 034 ran)',
     @Expected = N'yes', @Actual = @anyTxt;
DROP TABLE #Expected;
GO

-- =============================================
-- Test 3: devices, stores, hierarchy tiers and deprecated rows are never flagged.
-- =============================================
DECLARE @badDef INT = (SELECT COUNT(*) FROM Location.Location l
    INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
    WHERE l.IsOeeEnabled = 1
      AND ltd.Code IN (N'Terminal', N'Printer', N'InventoryLocation', N'Scale', N'Receiving'));
DECLARE @badDefTxt NVARCHAR(10) = CAST(@badDef AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[OeeFlag] no terminal / printer / store / scale is flagged',
     @Expected = N'0', @Actual = @badDefTxt;

DECLARE @badTier INT = (SELECT COUNT(*) FROM Location.Location l
    INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
    INNER JOIN Location.LocationType lt            ON lt.Id  = ltd.LocationTypeId
    WHERE l.IsOeeEnabled = 1 AND lt.Code NOT IN (N'WorkCenter', N'Cell'));
DECLARE @badTierTxt NVARCHAR(10) = CAST(@badTier AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[OeeFlag] no Enterprise / Site / Area row is flagged',
     @Expected = N'0', @Actual = @badTierTxt;

DECLARE @badDep INT = (SELECT COUNT(*) FROM Location.Location WHERE IsOeeEnabled = 1 AND DeprecatedAt IS NOT NULL);
DECLARE @badDepTxt NVARCHAR(10) = CAST(@badDep AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[OeeFlag] no deprecated location is flagged',
     @Expected = N'0', @Actual = @badDepTxt;
GO

-- =============================================
-- Test 4: a new location defaults to unflagged.
-- =============================================
DECLARE @Site BIGINT = (SELECT TOP 1 l.Id FROM Location.Location l
    INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
    INNER JOIN Location.LocationType lt            ON lt.Id  = ltd.LocationTypeId
    WHERE lt.Code = N'Site' AND l.DeprecatedAt IS NULL ORDER BY l.Id);
DECLARE @AreaDef BIGINT = (SELECT Id FROM Location.LocationTypeDefinition WHERE Code = N'ProductionArea');
INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
VALUES (@AreaDef, @Site, N'OEE Default Probe', N'ZZ-OEEDFLT', N'010_flag_backfill fixture', 998);
DECLARE @dflt NVARCHAR(10) = (SELECT CAST(IsOeeEnabled AS NVARCHAR(10)) FROM Location.Location WHERE Code = N'ZZ-OEEDFLT');
EXEC test.Assert_IsEqual @TestName = N'[OeeFlag] a newly inserted location defaults to unflagged',
     @Expected = N'0', @Actual = @dflt;
DELETE FROM Location.Location WHERE Code = N'ZZ-OEEDFLT';
GO

EXEC test.PrintSummary;
EXEC test.EndTestFile;
GO
