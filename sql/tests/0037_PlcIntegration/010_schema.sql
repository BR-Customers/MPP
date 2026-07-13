-- =============================================
-- File: 0037_PlcIntegration/010_schema.sql
-- Asserts migration 0037 objects exist + PlcDeviceType seed is correct.
-- =============================================
EXEC test.BeginTestFile @FileName = N'0037_PlcIntegration/010_schema.sql';
GO

-- PlcDeviceType table + 4-row seed
DECLARE @cnt INT = (SELECT COUNT(*) FROM Location.PlcDeviceType WHERE DeprecatedAt IS NULL);
DECLARE @cntStr NVARCHAR(10) = CAST(@cnt AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName=N'PlcDeviceType seeded 4 active rows',
    @Expected=N'4', @Actual=@cntStr;

DECLARE @hasTray NVARCHAR(1) = CASE WHEN EXISTS
    (SELECT 1 FROM Location.PlcDeviceType WHERE Code=N'TrayInspectionStation') THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName=N'PlcDeviceType has TrayInspectionStation',
    @Expected=N'1', @Actual=@hasTray;
GO

-- TerminalPlcDevice table + key columns (thin pointer)
DECLARE @colOk NVARCHAR(1) = CASE WHEN
    COL_LENGTH('Location.TerminalPlcDevice','UdtInstancePath') IS NOT NULL
    AND COL_LENGTH('Location.TerminalPlcDevice','DeviceCode') IS NOT NULL
    AND COL_LENGTH('Location.TerminalPlcDevice','PlcDeviceTypeId') IS NOT NULL
    THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName=N'TerminalPlcDevice has expected columns',
    @Expected=N'1', @Actual=@colOk;
GO

-- Item.PlcId column
DECLARE @plcCol NVARCHAR(1) = CASE WHEN
    COL_LENGTH('Parts.Item','PlcId') IS NOT NULL THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName=N'Item has PlcId column',
    @Expected=N'1', @Actual=@plcCol;
GO

-- Audit entity type seeded
DECLARE @auditOk NVARCHAR(1) = CASE WHEN EXISTS
    (SELECT 1 FROM Audit.LogEntityType WHERE Code=N'TerminalPlcDevice') THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName=N'LogEntityType TerminalPlcDevice seeded',
    @Expected=N'1', @Actual=@auditOk;
GO

EXEC test.PrintSummary;
GO
