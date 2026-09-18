-- =============================================
-- File:         0090_Oee_EnabledLocations/020_resolution.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-09-17
-- Description:  Oee.ufn_OeeAncestors, Oee.ufn_ResolveDowntimeScope and
--               Oee.ufn_ResolveOeeEquipment once the flag is the rule.
--               Uses test.OeeFixture_Build (see helpers/0090_fixture_oee_locations.sql).
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0090_Oee_EnabledLocations/020_resolution.sql';
GO

EXEC test.OeeFixture_Build;
GO

-- =============================================
-- Test 1: ufn_OeeAncestors returns flagged ancestors only, nearest first.
-- =============================================
DECLARE @A   BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-OEE-L-A');
DECLARE @L   BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-OEE-L');
DECLARE @T1  BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-OEE-L-T1');

DECLARE @ancA NVARCHAR(50) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Oee.ufn_OeeAncestors(@A));
EXEC test.Assert_IsEqual @TestName = N'[OeeAnc] a station has exactly one flagged ancestor (its line)',
     @Expected = N'1', @Actual = @ancA;

DECLARE @ancACode NVARCHAR(50) = (SELECT TOP 1 l.Code FROM Oee.ufn_OeeAncestors(@A) a
                                  INNER JOIN Location.Location l ON l.Id = a.AncestorLocationId
                                  ORDER BY a.Distance);
EXEC test.Assert_IsEqual @TestName = N'[OeeAnc] that ancestor is the line',
     @Expected = N'ZZ-OEE-L', @Actual = @ancACode;

DECLARE @ancL NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Oee.ufn_OeeAncestors(@L));
EXEC test.Assert_IsEqual @TestName = N'[OeeAnc] the line itself has no flagged ancestor (the Area is not flagged)',
     @Expected = N'0', @Actual = @ancL;

DECLARE @ancT NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Oee.ufn_OeeAncestors(@T1));
EXEC test.Assert_IsEqual @TestName = N'[OeeAnc] a terminal on the line sees the line as its flagged ancestor',
     @Expected = N'1', @Actual = @ancT;
GO

-- =============================================
-- Test 2: ResolveDowntimeScope -- self when flagged, else nearest flagged
-- ancestor, else itself.
-- =============================================
DECLARE @L    BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-OEE-L');
DECLARE @A    BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-OEE-L-A');
DECLARE @T1   BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-OEE-L-T1');
DECLARE @M1   BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-OEE-DC-M1');
DECLARE @M1T  BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-OEE-DC-M1-T1');
DECLARE @ET   BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-OEE-E-T1');

DECLARE @rT1 NVARCHAR(50) = (SELECT Code FROM Location.Location WHERE Id = Oee.ufn_ResolveDowntimeScope(@T1));
EXEC test.Assert_IsEqual @TestName = N'[DtScope] a terminal on a split line resolves to the line',
     @Expected = N'ZZ-OEE-L', @Actual = @rT1;

DECLARE @rA NVARCHAR(50) = (SELECT Code FROM Location.Location WHERE Id = Oee.ufn_ResolveDowntimeScope(@A));
EXEC test.Assert_IsEqual @TestName = N'[DtScope] a FLAGGED station resolves to ITSELF, not up to the line',
     @Expected = N'ZZ-OEE-L-A', @Actual = @rA;

DECLARE @rL NVARCHAR(50) = (SELECT Code FROM Location.Location WHERE Id = Oee.ufn_ResolveDowntimeScope(@L));
EXEC test.Assert_IsEqual @TestName = N'[DtScope] the line resolves to itself',
     @Expected = N'ZZ-OEE-L', @Actual = @rL;

DECLARE @rM1T NVARCHAR(50) = (SELECT Code FROM Location.Location WHERE Id = Oee.ufn_ResolveDowntimeScope(@M1T));
EXEC test.Assert_IsEqual @TestName = N'[DtScope] a dedicated press terminal resolves to its press',
     @Expected = N'ZZ-OEE-DC-M1', @Actual = @rM1T;

DECLARE @rET NVARCHAR(50) = (SELECT Code FROM Location.Location WHERE Id = Oee.ufn_ResolveDowntimeScope(@ET));
EXEC test.Assert_IsEqual @TestName = N'[DtScope] a terminal with no flagged ancestor falls back to itself',
     @Expected = N'ZZ-OEE-E-T1', @Actual = @rET;

DECLARE @rNull BIGINT = Oee.ufn_ResolveDowntimeScope(NULL);
EXEC test.Assert_IsNull @TestName = N'[DtScope] NULL in -> NULL out', @Value = @rNull;
GO

-- =============================================
-- Test 3: ufn_ResolveOeeEquipment is exactly the flagged, active set.
-- =============================================
DECLARE @inSet NVARCHAR(200) = (
    SELECT STUFF((SELECT N',' + e.Code FROM Oee.ufn_ResolveOeeEquipment() e
                  WHERE e.Code LIKE N'ZZ-OEE%'
                  ORDER BY e.Code FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 1, N''));
EXEC test.Assert_IsEqual @TestName = N'[OeeEquip] the fixture contributes exactly its flagged active rows',
     @Expected = N'ZZ-OEE-DC-M1,ZZ-OEE-DC-M2,ZZ-OEE-L,ZZ-OEE-L-A,ZZ-OEE-L-B,ZZ-OEE-L-MI,ZZ-OEE-P',
     @Actual = @inSet;
GO

-- =============================================
-- Test 4: un-flagging removes a row from the equipment set immediately.
-- =============================================
UPDATE Location.Location SET IsOeeEnabled = 0 WHERE Code = N'ZZ-OEE-L-B';
DECLARE @afterUnflag NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Oee.ufn_ResolveOeeEquipment()
                                     WHERE Code = N'ZZ-OEE-L-B');
EXEC test.Assert_IsEqual @TestName = N'[OeeEquip] un-flagged station leaves the equipment set',
     @Expected = N'0', @Actual = @afterUnflag;

DECLARE @B BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-OEE-L-B');
DECLARE @rB NVARCHAR(50) = (SELECT Code FROM Location.Location WHERE Id = Oee.ufn_ResolveDowntimeScope(@B));
EXEC test.Assert_IsEqual @TestName = N'[DtScope] an un-flagged station resolves back up to its line',
     @Expected = N'ZZ-OEE-L', @Actual = @rB;
UPDATE Location.Location SET IsOeeEnabled = 1 WHERE Code = N'ZZ-OEE-L-B';
GO

-- =============================================
-- Test 5: ufn_OeeAncestors walks PAST a deprecated intermediate -- a
-- deprecated, unflagged cell does not stop the walk, it is just skipped
-- from the output (header contract on R__Oee_ufn_OeeAncestors.sql: "a
-- station under a deprecated intermediate still finds its line").
-- =============================================
DECLARE @LineId BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-OEE-L');
DECLARE @AssemblyStationDefId BIGINT = (SELECT Id FROM Location.LocationTypeDefinition WHERE Code = N'AssemblyStation');

INSERT INTO Location.Location
    (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder, IsOeeEnabled, DeprecatedAt)
VALUES
    (@AssemblyStationDefId, @LineId, N'OEE Deprecated Cell', N'ZZ-OEE-L-DEPZ', N'OEE test fixture', 5, 0, SYSUTCDATETIME());

DECLARE @ZId BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-OEE-L-DEPZ');

INSERT INTO Location.Location
    (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder, IsOeeEnabled, DeprecatedAt)
VALUES
    (@AssemblyStationDefId, @ZId, N'OEE Station Under Deprecated Cell', N'ZZ-OEE-L-DEPZ-S', N'OEE test fixture', 1, 0, NULL);

DECLARE @SId BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-OEE-L-DEPZ-S');

DECLARE @ancCount NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Oee.ufn_OeeAncestors(@SId));
EXEC test.Assert_IsEqual @TestName = N'[OeeAnc] a station under a deprecated intermediate has exactly one flagged ancestor',
     @Expected = N'1', @Actual = @ancCount;

DECLARE @ancCode NVARCHAR(50) = (SELECT TOP 1 l.Code FROM Oee.ufn_OeeAncestors(@SId) a
                                 INNER JOIN Location.Location l ON l.Id = a.AncestorLocationId
                                 ORDER BY a.Distance);
EXEC test.Assert_IsEqual @TestName = N'[OeeAnc] that ancestor is the line, found past the deprecated cell',
     @Expected = N'ZZ-OEE-L', @Actual = @ancCode;

DECLARE @ancDistance NVARCHAR(10) = (SELECT CAST(a.Distance AS NVARCHAR(10)) FROM Oee.ufn_OeeAncestors(@SId) a);
EXEC test.Assert_IsEqual @TestName = N'[OeeAnc] the line is Distance 2 (through the skipped deprecated cell)',
     @Expected = N'2', @Actual = @ancDistance;

DECLARE @rS NVARCHAR(50) = (SELECT Code FROM Location.Location WHERE Id = Oee.ufn_ResolveDowntimeScope(@SId));
EXEC test.Assert_IsEqual @TestName = N'[DtScope] a station under a deprecated intermediate resolves to the line',
     @Expected = N'ZZ-OEE-L', @Actual = @rS;
GO

EXEC test.OeeFixture_Teardown;
GO

EXEC test.PrintSummary;
EXEC test.EndTestFile;
GO
