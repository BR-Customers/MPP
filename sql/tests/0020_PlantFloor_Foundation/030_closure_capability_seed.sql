-- =============================================
-- File: 0020_PlantFloor_Foundation/030_closure_capability_seed.sql
-- Desc: PlcDeviceType->ClosureMethod map, terminal closure attribute defs,
--       and the Changeover hold type are seeded by migration 0041.
-- =============================================
EXEC test.BeginTestFile @FileName = N'0020_PlantFloor_Foundation/030_closure_capability_seed.sql';
GO

-- device-type -> method map
DECLARE @W NVARCHAR(20) = (SELECT ClosureMethodCode FROM Location.PlcDeviceType WHERE Code = N'ScaleStation');
EXEC test.Assert_IsEqual @TestName = N'[Cap] ScaleStation -> ByWeight', @Expected = N'ByWeight', @Actual = @W;

DECLARE @V NVARCHAR(20) = (SELECT ClosureMethodCode FROM Location.PlcDeviceType WHERE Code = N'TrayInspectionStation');
EXEC test.Assert_IsEqual @TestName = N'[Cap] TrayInspectionStation -> ByVision', @Expected = N'ByVision', @Actual = @V;

DECLARE @M NVARCHAR(10) = (SELECT CASE WHEN ClosureMethodCode IS NULL THEN N'NULL' ELSE N'SET' END FROM Location.PlcDeviceType WHERE Code = N'SerializedMipStation');
EXEC test.Assert_IsEqual @TestName = N'[Cap] SerializedMipStation -> NULL', @Expected = N'NULL', @Actual = @M;

-- terminal attribute definitions
DECLARE @A NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Location.LocationAttributeDefinition
    WHERE LocationTypeDefinitionId = 7 AND AttributeName IN (N'CurrentClosureMethod', N'VisionAppUrl') AND DeprecatedAt IS NULL);
EXEC test.Assert_IsEqual @TestName = N'[Cap] two terminal closure attrs defined', @Expected = N'2', @Actual = @A;

-- Changeover hold type
DECLARE @H NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Quality.HoldTypeCode WHERE Code = N'Changeover');
EXEC test.Assert_IsEqual @TestName = N'[Cap] Changeover HoldTypeCode seeded', @Expected = N'1', @Actual = @H;

-- ClosureModeChanged audit event
DECLARE @E NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Audit.LogEventType WHERE Code = N'ClosureModeChanged');
EXEC test.Assert_IsEqual @TestName = N'[Cap] ClosureModeChanged LogEventType seeded', @Expected = N'1', @Actual = @E;
GO

EXEC test.EndTestFile;
GO
