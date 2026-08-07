SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0029_AssemblyPrinterCards/020_Printer_GetById.sql';
GO
-- fixture: a printer with an Endpoint under an arbitrary terminal
DELETE la FROM Location.LocationAttribute la INNER JOIN Location.Location l ON l.Id = la.LocationId WHERE l.Code = N'TEST-PRN-1';
DELETE FROM Location.Location WHERE Code = N'TEST-PRN-1';
DECLARE @Parent BIGINT = (SELECT TOP 1 Id FROM Location.Location WHERE LocationTypeDefinitionId = 7 AND DeprecatedAt IS NULL ORDER BY Id);
INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
VALUES (16, @Parent, N'Test Printer 1', N'TEST-PRN-1', N'test', 950);
DECLARE @Pid BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-PRN-1');
DECLARE @EpDef BIGINT = (SELECT Id FROM Location.LocationAttributeDefinition WHERE LocationTypeDefinitionId = 16 AND AttributeName = N'Endpoint' AND DeprecatedAt IS NULL);
INSERT INTO Location.LocationAttribute (LocationId, LocationAttributeDefinitionId, AttributeValue) VALUES (@Pid, @EpDef, N'10.20.30.40:9100');
GO
DECLARE @Ep NVARCHAR(200), @Code NVARCHAR(50), @Rows INT, @TestPid BIGINT;
CREATE TABLE #P (LocationId BIGINT, Code NVARCHAR(50), Name NVARCHAR(200), Endpoint NVARCHAR(200), Model NVARCHAR(200), ConnectionKind NVARCHAR(50));
SELECT @TestPid = Id FROM Location.Location WHERE Code = N'TEST-PRN-1';
INSERT INTO #P EXEC Location.Printer_GetById @PrinterLocationId = @TestPid;
SELECT @Ep = Endpoint, @Code = Code, @Rows = COUNT(*) OVER() FROM #P;
DROP TABLE #P;
EXEC test.Assert_IsEqual @TestName = N'[PrinterById] endpoint resolves', @Expected = N'10.20.30.40:9100', @Actual = @Ep;
EXEC test.Assert_IsEqual @TestName = N'[PrinterById] code resolves', @Expected = N'TEST-PRN-1', @Actual = @Code;
GO
DECLARE @Rows2 INT;
CREATE TABLE #U (LocationId BIGINT, Code NVARCHAR(50), Name NVARCHAR(200), Endpoint NVARCHAR(200), Model NVARCHAR(200), ConnectionKind NVARCHAR(50));
INSERT INTO #U EXEC Location.Printer_GetById @PrinterLocationId = -999;
SELECT @Rows2 = COUNT(*) FROM #U;
DROP TABLE #U;
EXEC test.Assert_RowCount @TestName = N'[PrinterById] unknown id -> empty set', @ExpectedCount = 0, @ActualCount = @Rows2;
GO
DELETE la FROM Location.LocationAttribute la INNER JOIN Location.Location l ON l.Id = la.LocationId WHERE l.Code = N'TEST-PRN-1';
DELETE FROM Location.Location WHERE Code = N'TEST-PRN-1';
GO
EXEC test.EndTestFile;
GO
