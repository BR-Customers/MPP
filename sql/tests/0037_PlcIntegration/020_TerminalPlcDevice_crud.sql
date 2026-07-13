-- =============================================
-- File: 0037_PlcIntegration/020_TerminalPlcDevice_crud.sql
-- Tests TerminalPlcDevice_Save (insert/update), _GetByTerminal, _Deprecate.
-- Self-contained: creates a throwaway Terminal location, cleans up at the end.
-- NOTE: assertion @Actual values are precomputed into @variables -- an inline
--   CAST()/CASE/subquery in an EXEC parameter is a T-SQL syntax error.
-- =============================================
EXEC test.BeginTestFile @FileName = N'0037_PlcIntegration/020_TerminalPlcDevice_crud.sql';
GO

-- Fixture: a throwaway Terminal (LocationTypeDefinitionId 7) under the plant root.
DECLARE @rootId BIGINT = (SELECT TOP 1 Id FROM Location.Location WHERE DeprecatedAt IS NULL ORDER BY Id);
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'TEST-TPD-TERM')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code)
    VALUES (7, @rootId, N'Test TPD Terminal', N'TEST-TPD-TERM');
GO

-- Test 1: Insert a device mapping
DECLARE @S BIT, @M NVARCHAR(500), @NewId BIGINT;
DECLARE @termId BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-TPD-TERM');
DECLARE @typeId BIGINT = (SELECT Id FROM Location.PlcDeviceType WHERE Code = N'SerializedMipStation');
CREATE TABLE #R1 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R1 EXEC Location.TerminalPlcDevice_Save
    @Id=NULL, @TerminalLocationId=@termId, @PlcDeviceTypeId=@typeId,
    @DeviceCode=N'5G0_A1', @UdtInstancePath=N'[MPP]PlcDevices/5G0_A1', @AppUserId=1;
SELECT @S=Status, @M=Message, @NewId=NewId FROM #R1; DROP TABLE #R1;

DECLARE @SStr NVARCHAR(1) = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName=N'Save insert: status 1', @Expected=N'1', @Actual=@SStr;
DECLARE @HasId NVARCHAR(1) = CASE WHEN @NewId IS NOT NULL THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName=N'Save insert: NewId returned', @Expected=N'1', @Actual=@HasId;
DECLARE @Sort NVARCHAR(10) = CAST((SELECT SortOrder FROM Location.TerminalPlcDevice WHERE Id=@NewId) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName=N'Save insert: SortOrder auto = 1', @Expected=N'1', @Actual=@Sort;
GO

-- Test 2: Duplicate DeviceCode on same terminal is rejected
DECLARE @S BIT, @M NVARCHAR(500);
DECLARE @termId BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-TPD-TERM');
DECLARE @typeId BIGINT = (SELECT Id FROM Location.PlcDeviceType WHERE Code = N'SerializedMipStation');
CREATE TABLE #R2 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R2 EXEC Location.TerminalPlcDevice_Save
    @Id=NULL, @TerminalLocationId=@termId, @PlcDeviceTypeId=@typeId,
    @DeviceCode=N'5G0_A1', @UdtInstancePath=N'[MPP]PlcDevices/5G0_A1', @AppUserId=1;
SELECT @S=Status, @M=Message FROM #R2; DROP TABLE #R2;
DECLARE @SStr NVARCHAR(1) = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName=N'Save dup DeviceCode: status 0', @Expected=N'0', @Actual=@SStr;
EXEC test.Assert_Contains @TestName=N'Save dup DeviceCode: message mentions exists',
    @HaystackStr=@M, @NeedleStr=N'already';
GO

-- Test 3: Update existing row (repoint instance path via @Id)
DECLARE @S BIT, @M NVARCHAR(500);
DECLARE @termId BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-TPD-TERM');
DECLARE @typeId BIGINT = (SELECT Id FROM Location.PlcDeviceType WHERE Code = N'SerializedMipStation');
DECLARE @rowId BIGINT = (SELECT Id FROM Location.TerminalPlcDevice WHERE DeviceCode=N'5G0_A1' AND TerminalLocationId=@termId);
CREATE TABLE #R3 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R3 EXEC Location.TerminalPlcDevice_Save
    @Id=@rowId, @TerminalLocationId=@termId, @PlcDeviceTypeId=@typeId,
    @DeviceCode=N'5G0_A1', @UdtInstancePath=N'[MPP]PlcDevices/5G0_A1_v2', @AppUserId=1;
SELECT @S=Status, @M=Message FROM #R3; DROP TABLE #R3;
DECLARE @SStr NVARCHAR(1) = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName=N'Save update: status 1', @Expected=N'1', @Actual=@SStr;
DECLARE @Path NVARCHAR(400) = (SELECT UdtInstancePath FROM Location.TerminalPlcDevice WHERE Id=@rowId);
EXEC test.Assert_IsEqual @TestName=N'Save update: UdtInstancePath repointed',
    @Expected=N'[MPP]PlcDevices/5G0_A1_v2', @Actual=@Path;
GO

-- Test 4: GetByTerminal returns the active row joined to type
DECLARE @termId BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-TPD-TERM');
CREATE TABLE #G (Id BIGINT, TerminalLocationId BIGINT, PlcDeviceTypeId BIGINT,
    DeviceTypeCode NVARCHAR(50), DeviceTypeName NVARCHAR(100), DeviceCode NVARCHAR(100),
    UdtInstancePath NVARCHAR(400), SortOrder INT);
INSERT INTO #G EXEC Location.TerminalPlcDevice_GetByTerminal @TerminalLocationId=@termId;
DECLARE @rc NVARCHAR(10) = CAST((SELECT COUNT(*) FROM #G) AS NVARCHAR(10));
DECLARE @tc NVARCHAR(50) = (SELECT TOP 1 DeviceTypeCode FROM #G);
DROP TABLE #G;
EXEC test.Assert_IsEqual @TestName=N'GetByTerminal: 1 active row', @Expected=N'1', @Actual=@rc;
EXEC test.Assert_IsEqual @TestName=N'GetByTerminal: type code resolved',
    @Expected=N'SerializedMipStation', @Actual=@tc;
GO

-- Test 5: Deprecate the row; GetByTerminal no longer returns it
DECLARE @S BIT, @M NVARCHAR(500);
DECLARE @termId BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-TPD-TERM');
DECLARE @rowId BIGINT = (SELECT Id FROM Location.TerminalPlcDevice WHERE TerminalLocationId=@termId AND DeviceCode=N'5G0_A1');
CREATE TABLE #R5 (Status BIT, Message NVARCHAR(500));
INSERT INTO #R5 EXEC Location.TerminalPlcDevice_Deprecate @Id=@rowId, @AppUserId=1;
SELECT @S=Status, @M=Message FROM #R5; DROP TABLE #R5;
DECLARE @SStr NVARCHAR(1) = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName=N'Deprecate: status 1', @Expected=N'1', @Actual=@SStr;
DECLARE @DepSet NVARCHAR(1) = CASE WHEN (SELECT DeprecatedAt FROM Location.TerminalPlcDevice WHERE Id=@rowId) IS NOT NULL THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName=N'Deprecate: DeprecatedAt set', @Expected=N'1', @Actual=@DepSet;

CREATE TABLE #G5 (Id BIGINT, TerminalLocationId BIGINT, PlcDeviceTypeId BIGINT,
    DeviceTypeCode NVARCHAR(50), DeviceTypeName NVARCHAR(100), DeviceCode NVARCHAR(100),
    UdtInstancePath NVARCHAR(400), SortOrder INT);
INSERT INTO #G5 EXEC Location.TerminalPlcDevice_GetByTerminal @TerminalLocationId=@termId;
DECLARE @rc5 NVARCHAR(10) = CAST((SELECT COUNT(*) FROM #G5) AS NVARCHAR(10)); DROP TABLE #G5;
EXEC test.Assert_IsEqual @TestName=N'Deprecate: GetByTerminal now 0 rows', @Expected=N'0', @Actual=@rc5;
GO

-- Cleanup
DELETE FROM Location.TerminalPlcDevice WHERE TerminalLocationId IN
    (SELECT Id FROM Location.Location WHERE Code = N'TEST-TPD-TERM');
DELETE FROM Location.Location WHERE Code = N'TEST-TPD-TERM';
GO

EXEC test.PrintSummary;
GO
