-- =============================================
-- File:         0117_Oee_Dashboard/020_classification.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-10-29
-- Description:  The OEE dashboard's classification functions (spec
--               docs/superpowers/specs/2026-10-27-oee-dashboard-design.md
--               sec 6.2, 6.4, 6.5):
--                 Oee.ufn_OeeUnits          every OEE location: unit or station,
--                                           its top unit, family, ProductionArea
--                 Oee.ufn_AreaFamily        where a location lands: family +
--                                           placement (top unit, or the shop)
--                 Oee.ufn_RejectChargeFamily  ChargeToParty -> family
--                 Oee.ufn_OeeBand           green / amber / red
--               Families: diecast | trim | ma. M&A is the catch-all for any
--               other OEE unit type (inspection + offsite lines sit under M&A,
--               Jacques 2026-10-29).
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0117_Oee_Dashboard/020_classification.sql';
GO

EXEC test.OeeDashFixture_Build;
DELETE FROM Quality.DefectCode WHERE Code LIKE N'ZZ-DSH-%';
INSERT INTO Quality.DefectCode (Code, Description, OperationCategoryId, IsExcused, CreatedAt, ChargeToPartyId)
SELECT v.Code, N'DSH test defect', NULL, 0, SYSUTCDATETIME(), p.Id
FROM (VALUES (N'ZZ-DSH-D-DC', N'DieCast'), (N'ZZ-DSH-D-DM', N'DieMaintenance'),
             (N'ZZ-DSH-D-TS', N'TrimShop'), (N'ZZ-DSH-D-MS', N'MachineShop'),
             (N'ZZ-DSH-D-NM', N'MppNonSpecific'), (N'ZZ-DSH-D-NS', N'SupplierNonSpecific')) v (Code, Party)
INNER JOIN Quality.ChargeToParty p ON p.Code = v.Party;
GO

-- =============================================
-- Test 1: area family of a location
-- =============================================
DECLARE @v NVARCHAR(20);

-- Every real, seeded die-cast press resolves to diecast.
DECLARE @bad INT = (SELECT COUNT(*) FROM Location.Location l
    INNER JOIN Location.LocationTypeDefinition d ON d.Id = l.LocationTypeDefinitionId
    OUTER APPLY Oee.ufn_AreaFamily(l.Id) f
    WHERE d.Code = N'DieCastMachine' AND l.IsOeeEnabled = 1 AND l.DeprecatedAt IS NULL
      AND ISNULL(f.AreaFamily, N'') <> N'diecast');
EXEC test.Assert_RowCount @TestName = N'[Family] each seeded DieCastMachine -> diecast', @ExpectedCount = 0, @ActualCount = @bad;

SET @v = (SELECT AreaFamily FROM Oee.ufn_AreaFamily((SELECT Id FROM Location.Location WHERE Code = N'ZZ-DSH-TR-P1')));
EXEC test.Assert_IsEqual @TestName = N'[Family] TrimPress -> trim', @Expected = N'trim', @Actual = @v;

SET @v = (SELECT AreaFamily FROM Oee.ufn_AreaFamily((SELECT Id FROM Location.Location WHERE Code = N'ZZ-DSH-TR')));
EXEC test.Assert_IsEqual @TestName = N'[Family] Trim Shop area (presses beneath) -> trim', @Expected = N'trim', @Actual = @v;

SET @v = (SELECT AreaFamily FROM Oee.ufn_AreaFamily((SELECT Id FROM Location.Location WHERE Code = N'ZZ-DSH-MA-P')));
EXEC test.Assert_IsEqual @TestName = N'[Family] ProductionLine -> ma', @Expected = N'ma', @Actual = @v;

SET @v = (SELECT AreaFamily FROM Oee.ufn_AreaFamily((SELECT Id FROM Location.Location WHERE Code = N'ZZ-DSH-MA-L-A')));
EXEC test.Assert_IsEqual @TestName = N'[Family] station under a line -> ma', @Expected = N'ma', @Actual = @v;

SET @v = (SELECT AreaFamily FROM Oee.ufn_AreaFamily((SELECT Id FROM Location.Location WHERE Code = N'ZZ-DSH-IN-L')));
EXEC test.Assert_IsEqual @TestName = N'[Family] InspectionLine -> ma', @Expected = N'ma', @Actual = @v;

SET @v = (SELECT AreaFamily FROM Oee.ufn_AreaFamily((SELECT Id FROM Location.Location WHERE Code = N'ZZ-DSH-DC-M1-T1')));
EXEC test.Assert_IsEqual @TestName = N'[Family] terminal under a press -> diecast', @Expected = N'diecast', @Actual = @v;

SET @v = ISNULL((SELECT AreaFamily FROM Oee.ufn_AreaFamily((SELECT Id FROM Location.Location WHERE Code = N'ZZ-DSH-SUP-T1'))), N'<NULL>');
EXEC test.Assert_IsEqual @TestName = N'[Family] location with no OEE unit above or below -> NULL', @Expected = N'<NULL>', @Actual = @v;
GO

-- =============================================
-- Test 2: placement -- the unit (or shop) a location's scrap lands on
-- =============================================
DECLARE @e NVARCHAR(20), @a NVARCHAR(20);

SET @e = (SELECT CAST(Id AS NVARCHAR(20)) FROM Location.Location WHERE Code = N'ZZ-DSH-MA-L');
SET @a = (SELECT CAST(PlacementLocationId AS NVARCHAR(20)) FROM Oee.ufn_AreaFamily((SELECT Id FROM Location.Location WHERE Code = N'ZZ-DSH-MA-L-T1')));
EXEC test.Assert_IsEqual @TestName = N'[Place] line terminal -> the line', @Expected = @e, @Actual = @a;

SET @a = (SELECT CAST(PlacementLocationId AS NVARCHAR(20)) FROM Oee.ufn_AreaFamily((SELECT Id FROM Location.Location WHERE Code = N'ZZ-DSH-MA-L-MI')));
EXEC test.Assert_IsEqual @TestName = N'[Place] station -> its top unit, the line', @Expected = @e, @Actual = @a;

SET @e = (SELECT CAST(Id AS NVARCHAR(20)) FROM Location.Location WHERE Code = N'ZZ-DSH-TR');
SET @a = (SELECT CAST(PlacementLocationId AS NVARCHAR(20)) FROM Oee.ufn_AreaFamily((SELECT Id FROM Location.Location WHERE Code = N'ZZ-DSH-TR')));
EXEC test.Assert_IsEqual @TestName = N'[Place] trim shop -> the shop itself', @Expected = @e, @Actual = @a;

SET @a = (SELECT CAST(ProductionAreaId AS NVARCHAR(20)) FROM Oee.ufn_AreaFamily((SELECT Id FROM Location.Location WHERE Code = N'ZZ-DSH-TR-P2')));
EXEC test.Assert_IsEqual @TestName = N'[Place] trim press ProductionArea = its shop', @Expected = @e, @Actual = @a;

-- A shop terminal is under no press: it lands on its ProductionArea (the shop),
-- flagged as an area placement. That is where trim good and scrap are booked.
SET @a = (SELECT CAST(PlacementLocationId AS NVARCHAR(20)) FROM Oee.ufn_AreaFamily((SELECT Id FROM Location.Location WHERE Code = N'ZZ-DSH-TR-T1')));
EXEC test.Assert_IsEqual @TestName = N'[Place] trim shop terminal -> the shop', @Expected = @e, @Actual = @a;
SET @a = (SELECT CAST(PlacementIsArea AS NVARCHAR(20)) FROM Oee.ufn_AreaFamily((SELECT Id FROM Location.Location WHERE Code = N'ZZ-DSH-TR-T1')));
EXEC test.Assert_IsEqual @TestName = N'[Place] shop placement is flagged PlacementIsArea', @Expected = N'1', @Actual = @a;
SET @a = (SELECT AreaFamily FROM Oee.ufn_AreaFamily((SELECT Id FROM Location.Location WHERE Code = N'ZZ-DSH-TR-T1')));
EXEC test.Assert_IsEqual @TestName = N'[Place] trim shop terminal -> trim', @Expected = N'trim', @Actual = @a;
SET @a = (SELECT CAST(PlacementIsArea AS NVARCHAR(20)) FROM Oee.ufn_AreaFamily((SELECT Id FROM Location.Location WHERE Code = N'ZZ-DSH-MA-L-T1')));
EXEC test.Assert_IsEqual @TestName = N'[Place] unit placement is not PlacementIsArea', @Expected = N'0', @Actual = @a;
GO

-- =============================================
-- Test 3: charge family
-- =============================================
DECLARE @v NVARCHAR(20);
SET @v = (SELECT ChargeFamily FROM Oee.ufn_RejectChargeFamily((SELECT Id FROM Quality.DefectCode WHERE Code = N'ZZ-DSH-D-DC'), N'ma'));
EXEC test.Assert_IsEqual @TestName = N'[Charge] DieCast found on a line -> diecast', @Expected = N'diecast', @Actual = @v;
SET @v = (SELECT ChargeFamily FROM Oee.ufn_RejectChargeFamily((SELECT Id FROM Quality.DefectCode WHERE Code = N'ZZ-DSH-D-DM'), N'diecast'));
EXEC test.Assert_IsEqual @TestName = N'[Charge] DieMaintenance -> diecast', @Expected = N'diecast', @Actual = @v;
SET @v = (SELECT ChargeFamily FROM Oee.ufn_RejectChargeFamily((SELECT Id FROM Quality.DefectCode WHERE Code = N'ZZ-DSH-D-TS'), N'ma'));
EXEC test.Assert_IsEqual @TestName = N'[Charge] TrimShop -> trim', @Expected = N'trim', @Actual = @v;
SET @v = (SELECT ChargeFamily FROM Oee.ufn_RejectChargeFamily((SELECT Id FROM Quality.DefectCode WHERE Code = N'ZZ-DSH-D-MS'), N'diecast'));
EXEC test.Assert_IsEqual @TestName = N'[Charge] MachineShop -> ma', @Expected = N'ma', @Actual = @v;
SET @v = (SELECT ChargeFamily FROM Oee.ufn_RejectChargeFamily((SELECT Id FROM Quality.DefectCode WHERE Code = N'ZZ-DSH-D-NM'), N'trim'));
EXEC test.Assert_IsEqual @TestName = N'[Charge] MppNonSpecific found at trim -> trim', @Expected = N'trim', @Actual = @v;
SET @v = ISNULL((SELECT ChargeFamily FROM Oee.ufn_RejectChargeFamily((SELECT Id FROM Quality.DefectCode WHERE Code = N'ZZ-DSH-D-NS'), NULL)), N'<NULL>');
EXEC test.Assert_IsEqual @TestName = N'[Charge] SupplierNonSpecific with no found family -> NULL', @Expected = N'<NULL>', @Actual = @v;
GO

-- =============================================
-- Test 4: colour band
-- =============================================
DECLARE @v NVARCHAR(10);
SET @v = (SELECT Band FROM Oee.ufn_OeeBand(0.8500)); EXEC test.Assert_IsEqual @TestName = N'[Band] 0.8500 green', @Expected = N'green', @Actual = @v;
SET @v = (SELECT Band FROM Oee.ufn_OeeBand(0.8499)); EXEC test.Assert_IsEqual @TestName = N'[Band] 0.8499 amber', @Expected = N'amber', @Actual = @v;
SET @v = (SELECT Band FROM Oee.ufn_OeeBand(0.7000)); EXEC test.Assert_IsEqual @TestName = N'[Band] 0.7000 amber', @Expected = N'amber', @Actual = @v;
SET @v = (SELECT Band FROM Oee.ufn_OeeBand(0.6999)); EXEC test.Assert_IsEqual @TestName = N'[Band] 0.6999 red', @Expected = N'red', @Actual = @v;
SET @v = ISNULL((SELECT Band FROM Oee.ufn_OeeBand(NULL)), N'<NULL>'); EXEC test.Assert_IsEqual @TestName = N'[Band] NULL -> NULL', @Expected = N'<NULL>', @Actual = @v;
GO

-- =============================================
-- Test 5: units vs stations
-- =============================================
DECLARE @e NVARCHAR(20), @a NVARCHAR(20);
SET @a = (SELECT CAST(IsStation AS NVARCHAR(20)) FROM Oee.ufn_OeeUnits() WHERE Code = N'ZZ-DSH-MA-L');
EXEC test.Assert_IsEqual @TestName = N'[Units] a line with stations is a unit (IsStation 0)', @Expected = N'0', @Actual = @a;
SET @a = (SELECT CAST(IsStation AS NVARCHAR(20)) FROM Oee.ufn_OeeUnits() WHERE Code = N'ZZ-DSH-MA-L-A');
EXEC test.Assert_IsEqual @TestName = N'[Units] its station is IsStation 1', @Expected = N'1', @Actual = @a;
SET @e = (SELECT CAST(Id AS NVARCHAR(20)) FROM Location.Location WHERE Code = N'ZZ-DSH-MA-L');
SET @a = (SELECT CAST(ParentUnitLocationId AS NVARCHAR(20)) FROM Oee.ufn_OeeUnits() WHERE Code = N'ZZ-DSH-MA-L-A');
EXEC test.Assert_IsEqual @TestName = N'[Units] station ParentUnitLocationId = the line', @Expected = @e, @Actual = @a;
SET @a = (SELECT AreaFamily FROM Oee.ufn_OeeUnits() WHERE Code = N'ZZ-DSH-MA-L-MI');
EXEC test.Assert_IsEqual @TestName = N'[Units] station takes its line''s family (ma)', @Expected = N'ma', @Actual = @a;
SET @e = (SELECT CAST(Id AS NVARCHAR(20)) FROM Location.Location WHERE Code = N'ZZ-DSH-DC');
SET @a = (SELECT CAST(ProductionAreaId AS NVARCHAR(20)) FROM Oee.ufn_OeeUnits() WHERE Code = N'ZZ-DSH-DC-M2');
EXEC test.Assert_IsEqual @TestName = N'[Units] press ProductionAreaId = its shop', @Expected = @e, @Actual = @a;
GO

-- ---- cleanup ----
DELETE FROM Quality.DefectCode WHERE Code LIKE N'ZZ-DSH-%';
EXEC test.OeeDashFixture_Teardown;
GO

EXEC test.PrintSummary;
EXEC test.EndTestFile;
GO
