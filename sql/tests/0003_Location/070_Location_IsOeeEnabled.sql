-- =============================================
-- File:         0003_Location/070_Location_IsOeeEnabled.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-09-17
-- Description:  The Config Tool write path for Location.IsOeeEnabled:
--               Location_SaveAll carries it, the type guard
--               (Location.ufn_CanBeOeeEnabled) refuses a device / store /
--               hierarchy tier, Location_Get returns it, and
--               LocationTypeDefinition_GetOeeEligibility answers the
--               checkbox-enabled question for the editor.
--               Fixture codes use the ZZ-LOCF prefix (NOT ZZ-OEE, which the
--               shared OEE fixture teardown sweeps).
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0003_Location/070_Location_IsOeeEnabled.sql';
GO

-- ---- fixture: a parent Area, resolved dynamically ----
IF OBJECT_ID(N'tempdb..#LocF') IS NOT NULL DROP TABLE #LocF;
CREATE TABLE #LocF (Tag NVARCHAR(20) PRIMARY KEY, Val BIGINT);

DECLARE @Area BIGINT = (SELECT TOP 1 l.Id FROM Location.Location l
    INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
    WHERE ltd.Code = N'ProductionArea' AND l.DeprecatedAt IS NULL ORDER BY l.Id);
DECLARE @Site BIGINT = (SELECT TOP 1 l.Id FROM Location.Location l
    INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
    INNER JOIN Location.LocationType lt            ON lt.Id  = ltd.LocationTypeId
    WHERE lt.Code = N'Site' AND l.DeprecatedAt IS NULL ORDER BY l.Id);
INSERT INTO #LocF (Tag, Val) VALUES (N'AREA', @Area), (N'SITE', @Site);
EXEC test.Assert_IsNotNull @TestName = N'[OeeSave] fixture: a ProductionArea exists', @Value = @Area;
GO

-- =============================================
-- Test 1: create a press with the flag ON.
-- =============================================
DECLARE @Area BIGINT = (SELECT Val FROM #LocF WHERE Tag = N'AREA');
DECLARE @PressDef BIGINT = (SELECT Id FROM Location.LocationTypeDefinition WHERE Code = N'DieCastMachine');
DECLARE @r1 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @r1 EXEC Location.Location_SaveAll
    @Id = NULL, @ParentLocationId = @Area, @LocationTypeDefinitionId = @PressDef,
    @Name = N'OEE Flag Press', @Code = N'ZZ-LOCF-M1', @AppUserId = 1, @IsOeeEnabled = 1;

DECLARE @s1 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @r1);
EXEC test.Assert_IsEqual @TestName = N'[OeeSave] create with the flag on succeeds',
     @Expected = N'1', @Actual = @s1;
DECLARE @f1 NVARCHAR(10) = (SELECT CAST(IsOeeEnabled AS NVARCHAR(10)) FROM Location.Location WHERE Code = N'ZZ-LOCF-M1');
EXEC test.Assert_IsEqual @TestName = N'[OeeSave] the created row is flagged',
     @Expected = N'1', @Actual = @f1;
GO

-- =============================================
-- Test 2: create with the parameter omitted -> unflagged.
-- =============================================
DECLARE @Area BIGINT = (SELECT Val FROM #LocF WHERE Tag = N'AREA');
DECLARE @PressDef BIGINT = (SELECT Id FROM Location.LocationTypeDefinition WHERE Code = N'DieCastMachine');
DECLARE @r2 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @r2 EXEC Location.Location_SaveAll
    @Id = NULL, @ParentLocationId = @Area, @LocationTypeDefinitionId = @PressDef,
    @Name = N'OEE Flag Press 2', @Code = N'ZZ-LOCF-M2', @AppUserId = 1;
DECLARE @f2 NVARCHAR(10) = (SELECT CAST(IsOeeEnabled AS NVARCHAR(10)) FROM Location.Location WHERE Code = N'ZZ-LOCF-M2');
EXEC test.Assert_IsEqual @TestName = N'[OeeSave] create without the parameter leaves it unflagged',
     @Expected = N'0', @Actual = @f2;
GO

-- =============================================
-- Test 3: the type guard -- a Terminal cannot be flagged. The guard must fire
-- BEFORE the required-attribute check, or this rejection would be masked by
-- Terminal's required HasBarcodeScanner attribute.
-- =============================================
DECLARE @Area BIGINT = (SELECT Val FROM #LocF WHERE Tag = N'AREA');
DECLARE @TermDef BIGINT = (SELECT Id FROM Location.LocationTypeDefinition WHERE Code = N'Terminal');
DECLARE @r3 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @r3 EXEC Location.Location_SaveAll
    @Id = NULL, @ParentLocationId = @Area, @LocationTypeDefinitionId = @TermDef,
    @Name = N'OEE Flag Terminal', @Code = N'ZZ-LOCF-T1', @AppUserId = 1, @IsOeeEnabled = 1;
DECLARE @s3 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @r3);
DECLARE @m3 NVARCHAR(500) = (SELECT Message FROM @r3);
EXEC test.Assert_IsEqual @TestName = N'[OeeSave] a Terminal cannot be OEE-enabled',
     @Expected = N'0', @Actual = @s3;
EXEC test.Assert_Contains @TestName = N'[OeeSave] the rejection names the OEE flag',
     @HaystackStr = @m3, @NeedleStr = N'OEE';
GO

-- =============================================
-- Test 4: an Area cannot be flagged either (wrong tier).
-- =============================================
DECLARE @Site BIGINT = (SELECT Val FROM #LocF WHERE Tag = N'SITE');
DECLARE @AreaDef BIGINT = (SELECT Id FROM Location.LocationTypeDefinition WHERE Code = N'ProductionArea');
DECLARE @r4 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @r4 EXEC Location.Location_SaveAll
    @Id = NULL, @ParentLocationId = @Site, @LocationTypeDefinitionId = @AreaDef,
    @Name = N'OEE Flag Area', @Code = N'ZZ-LOCF-A1', @AppUserId = 1, @IsOeeEnabled = 1;
DECLARE @s4 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @r4);
EXEC test.Assert_IsEqual @TestName = N'[OeeSave] an Area cannot be OEE-enabled',
     @Expected = N'0', @Actual = @s4;
GO

-- =============================================
-- Test 5: update turns the flag off; omitting the parameter leaves it alone.
-- =============================================
DECLARE @Area BIGINT = (SELECT Val FROM #LocF WHERE Tag = N'AREA');
DECLARE @PressDef BIGINT = (SELECT Id FROM Location.LocationTypeDefinition WHERE Code = N'DieCastMachine');
DECLARE @M1 BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-LOCF-M1');

DECLARE @r5 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @r5 EXEC Location.Location_SaveAll
    @Id = @M1, @ParentLocationId = @Area, @LocationTypeDefinitionId = @PressDef,
    @Name = N'OEE Flag Press', @Code = N'ZZ-LOCF-M1', @AppUserId = 1, @IsOeeEnabled = 0;
DECLARE @f5 NVARCHAR(10) = (SELECT CAST(IsOeeEnabled AS NVARCHAR(10)) FROM Location.Location WHERE Id = @M1);
EXEC test.Assert_IsEqual @TestName = N'[OeeSave] update can turn the flag off',
     @Expected = N'0', @Actual = @f5;

UPDATE Location.Location SET IsOeeEnabled = 1 WHERE Id = @M1;
DECLARE @r5b TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @r5b EXEC Location.Location_SaveAll
    @Id = @M1, @ParentLocationId = @Area, @LocationTypeDefinitionId = @PressDef,
    @Name = N'OEE Flag Press Renamed', @Code = N'ZZ-LOCF-M1', @AppUserId = 1;
DECLARE @f5b NVARCHAR(10) = (SELECT CAST(IsOeeEnabled AS NVARCHAR(10)) FROM Location.Location WHERE Id = @M1);
EXEC test.Assert_IsEqual @TestName = N'[OeeSave] update without the parameter preserves the flag',
     @Expected = N'1', @Actual = @f5b;
GO

-- =============================================
-- Test 6: Location_Get returns the flag (last column).
-- =============================================
DECLARE @M1 BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-LOCF-M1');
DECLARE @g TABLE (Id BIGINT, LocationTypeDefinitionId BIGINT, ParentLocationId BIGINT,
    Name NVARCHAR(200), Code NVARCHAR(50), Description NVARCHAR(500), SortOrder INT,
    CreatedAt DATETIME2(3), DeprecatedAt DATETIME2(3),
    LocationTypeDefinitionName NVARCHAR(100), LocationTypeDefinitionIcon NVARCHAR(100),
    LocationTypeName NVARCHAR(100), IsOeeEnabled BIT);
INSERT INTO @g EXEC Location.Location_Get @Id = @M1;
DECLARE @g1 NVARCHAR(10) = (SELECT CAST(IsOeeEnabled AS NVARCHAR(10)) FROM @g);
EXEC test.Assert_IsEqual @TestName = N'[OeeSave] Location_Get returns IsOeeEnabled',
     @Expected = N'1', @Actual = @g1;
GO

-- =============================================
-- Test 7: the eligibility read proc that drives the editor checkbox.
-- =============================================
DECLARE @e TABLE (LocationTypeDefinitionId BIGINT, CanBeOeeEnabled BIT);
DECLARE @PressDef BIGINT = (SELECT Id FROM Location.LocationTypeDefinition WHERE Code = N'DieCastMachine');
DECLARE @LineDef  BIGINT = (SELECT Id FROM Location.LocationTypeDefinition WHERE Code = N'ProductionLine');
DECLARE @TermDef  BIGINT = (SELECT Id FROM Location.LocationTypeDefinition WHERE Code = N'Terminal');
DECLARE @AreaDef  BIGINT = (SELECT Id FROM Location.LocationTypeDefinition WHERE Code = N'ProductionArea');

DELETE FROM @e; INSERT INTO @e EXEC Location.LocationTypeDefinition_GetOeeEligibility @LocationTypeDefinitionId = @PressDef;
DECLARE @e1 NVARCHAR(10) = (SELECT CAST(CanBeOeeEnabled AS NVARCHAR(10)) FROM @e);
EXEC test.Assert_IsEqual @TestName = N'[OeeElig] a die cast machine is eligible', @Expected = N'1', @Actual = @e1;

DELETE FROM @e; INSERT INTO @e EXEC Location.LocationTypeDefinition_GetOeeEligibility @LocationTypeDefinitionId = @LineDef;
DECLARE @e2 NVARCHAR(10) = (SELECT CAST(CanBeOeeEnabled AS NVARCHAR(10)) FROM @e);
EXEC test.Assert_IsEqual @TestName = N'[OeeElig] a production line is eligible', @Expected = N'1', @Actual = @e2;

DELETE FROM @e; INSERT INTO @e EXEC Location.LocationTypeDefinition_GetOeeEligibility @LocationTypeDefinitionId = @TermDef;
DECLARE @e3 NVARCHAR(10) = (SELECT CAST(CanBeOeeEnabled AS NVARCHAR(10)) FROM @e);
EXEC test.Assert_IsEqual @TestName = N'[OeeElig] a terminal is not eligible', @Expected = N'0', @Actual = @e3;

DELETE FROM @e; INSERT INTO @e EXEC Location.LocationTypeDefinition_GetOeeEligibility @LocationTypeDefinitionId = @AreaDef;
DECLARE @e4 NVARCHAR(10) = (SELECT CAST(CanBeOeeEnabled AS NVARCHAR(10)) FROM @e);
EXEC test.Assert_IsEqual @TestName = N'[OeeElig] an area is not eligible', @Expected = N'0', @Actual = @e4;

DELETE FROM @e; INSERT INTO @e EXEC Location.LocationTypeDefinition_GetOeeEligibility @LocationTypeDefinitionId = -1;
DECLARE @e5 INT = (SELECT COUNT(*) FROM @e);
EXEC test.Assert_RowCount @TestName = N'[OeeElig] unknown definition -> empty result set',
     @ExpectedCount = 0, @ActualCount = @e5;
GO

-- ---- cleanup ----
DELETE la FROM Location.LocationAttribute la
INNER JOIN Location.Location l ON l.Id = la.LocationId WHERE l.Code LIKE N'ZZ-LOCF%';
DELETE FROM Location.Location WHERE Code LIKE N'ZZ-LOCF%';
IF OBJECT_ID(N'tempdb..#LocF') IS NOT NULL DROP TABLE #LocF;
GO

EXEC test.PrintSummary;
EXEC test.EndTestFile;
GO
