-- =============================================
-- File: 0020_PlantFloor_Foundation/031_Terminal_GetClosureContext.sql
-- Desc: Terminal_GetClosureContext derives the capability set from bound PLC
--       devices (ScaleStation -> ByWeight), always includes ByCount, and omits
--       methods with no capable device.
-- =============================================
EXEC test.BeginTestFile @FileName = N'0020_PlantFloor_Foundation/031_Terminal_GetClosureContext.sql';
GO

-- throwaway terminal (LTD 7) with a ScaleStation device
DELETE FROM Location.TerminalPlcDevice WHERE DeviceCode = N'TEST-SCALE-DEV';
DELETE FROM Location.Location WHERE Code = N'TEST-CLOSURE-TERM';
GO
DECLARE @Parent BIGINT = (SELECT TOP 1 Id FROM Location.Location WHERE LocationTypeDefinitionId <> 7 AND DeprecatedAt IS NULL ORDER BY Id);
INSERT INTO Location.Location (Code, Name, LocationTypeDefinitionId, ParentLocationId, CreatedAt)
VALUES (N'TEST-CLOSURE-TERM', N'Closure test terminal', 7, @Parent, SYSUTCDATETIME());
DECLARE @Term BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-CLOSURE-TERM');
DECLARE @ScaleType BIGINT = (SELECT Id FROM Location.PlcDeviceType WHERE Code = N'ScaleStation');
INSERT INTO Location.TerminalPlcDevice (TerminalLocationId, PlcDeviceTypeId, DeviceCode, UdtInstancePath)
VALUES (@Term, @ScaleType, N'TEST-SCALE-DEV', N'PlcDevices/TEST_Scale');
GO

DECLARE @Term BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-CLOSURE-TERM');
CREATE TABLE #Ctx (CurrentClosureMethod NVARCHAR(20), VisionAppUrl NVARCHAR(400), ClosureCapabilities NVARCHAR(100));
INSERT INTO #Ctx EXEC Location.Terminal_GetClosureContext @TerminalLocationId = @Term;

DECLARE @Caps NVARCHAR(100) = (SELECT ClosureCapabilities FROM #Ctx);
DECLARE @HasWeight NVARCHAR(1) = CASE WHEN @Caps LIKE N'%ByWeight%' THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[CtxCap] scale terminal caps has ByWeight', @Expected = N'1', @Actual = @HasWeight;

DECLARE @HasCount NVARCHAR(1) = CASE WHEN @Caps LIKE N'%ByCount%' THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[CtxCap] caps always include ByCount', @Expected = N'1', @Actual = @HasCount;

DECLARE @HasVision NVARCHAR(1) = CASE WHEN @Caps LIKE N'%ByVision%' THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[CtxCap] no vision device -> no ByVision', @Expected = N'0', @Actual = @HasVision;

DROP TABLE #Ctx;
GO

DELETE FROM Location.TerminalPlcDevice WHERE DeviceCode = N'TEST-SCALE-DEV';
DELETE FROM Location.Location WHERE Code = N'TEST-CLOSURE-TERM';
GO
EXEC test.EndTestFile;
GO
