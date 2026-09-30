SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0101_PrinterUsbBridge/030_read_procs_resolve_endpoint.sql';
GO
-- Fixture: a dedicated Terminal with a known IpAddress, and two printers under
-- it -- one UsbBridge (no stored endpoint), one Networked (stored endpoint).
DELETE la FROM Location.LocationAttribute la
    INNER JOIN Location.Location l ON l.Id = la.LocationId
    WHERE l.Code IN (N'TEST-UB-PRN', N'TEST-NW-PRN', N'TEST-UB-TERM');
DELETE FROM Location.Location WHERE Code IN (N'TEST-UB-PRN', N'TEST-NW-PRN');
DELETE FROM Location.Location WHERE Code = N'TEST-UB-TERM';
GO
DECLARE @Zone BIGINT = (SELECT TOP 1 ParentLocationId FROM Location.Location
                        WHERE LocationTypeDefinitionId = 7 AND ParentLocationId IS NOT NULL
                          AND DeprecatedAt IS NULL ORDER BY Id);
INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
VALUES (7, @Zone, N'Test UB Terminal', N'TEST-UB-TERM', N'test', 960);
DECLARE @Term BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-UB-TERM');
DECLARE @IpDef BIGINT = (SELECT Id FROM Location.LocationAttributeDefinition
                         WHERE LocationTypeDefinitionId = 7 AND AttributeName = N'IpAddress' AND DeprecatedAt IS NULL);
INSERT INTO Location.LocationAttribute (LocationId, LocationAttributeDefinitionId, AttributeValue)
VALUES (@Term, @IpDef, N'172.17.20.5');

DECLARE @EpDef BIGINT = (SELECT Id FROM Location.LocationAttributeDefinition
                         WHERE LocationTypeDefinitionId = 16 AND AttributeName = N'Endpoint' AND DeprecatedAt IS NULL);
DECLARE @CkDef BIGINT = (SELECT Id FROM Location.LocationAttributeDefinition
                         WHERE LocationTypeDefinitionId = 16 AND AttributeName = N'ConnectionKind' AND DeprecatedAt IS NULL);

INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
VALUES (16, @Term, N'Test UB Printer', N'TEST-UB-PRN', N'test', 1);
DECLARE @Ub BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-UB-PRN');
INSERT INTO Location.LocationAttribute (LocationId, LocationAttributeDefinitionId, AttributeValue)
VALUES (@Ub, @CkDef, N'UsbBridge');

INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
VALUES (16, @Term, N'Test NW Printer', N'TEST-NW-PRN', N'test', 2);
DECLARE @Nw BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-NW-PRN');
INSERT INTO Location.LocationAttribute (LocationId, LocationAttributeDefinitionId, AttributeValue)
VALUES (@Nw, @CkDef, N'Networked'), (@Nw, @EpDef, N'172.17.20.228:9100');
GO
-- Printer_GetById: the UsbBridge printer derives; the Networked one does not.
CREATE TABLE #P (LocationId BIGINT, Code NVARCHAR(50), Name NVARCHAR(200),
                 Endpoint NVARCHAR(255), Model NVARCHAR(255), ConnectionKind NVARCHAR(255),
                 StoredEndpoint NVARCHAR(255), TerminalIpAddress NVARCHAR(255),
                 EndpointSource NVARCHAR(30));
DECLARE @Ub BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-UB-PRN');
INSERT INTO #P EXEC Location.Printer_GetById @PrinterLocationId = @Ub;
DECLARE @Ep NVARCHAR(255), @Src NVARCHAR(30), @Stored NVARCHAR(255), @Tip NVARCHAR(255);
SELECT @Ep = Endpoint, @Src = EndpointSource, @Stored = StoredEndpoint, @Tip = TerminalIpAddress FROM #P;
DROP TABLE #P;
EXEC test.Assert_IsEqual @TestName = N'[PrinterById] UsbBridge endpoint derives from the terminal IP',
     @Expected = N'172.17.20.5:9100', @Actual = @Ep;
EXEC test.Assert_IsEqual @TestName = N'[PrinterById] and says where it came from',
     @Expected = N'derived-terminal-ip', @Actual = @Src;
EXEC test.Assert_IsNull @TestName = N'[PrinterById] UsbBridge stores no endpoint', @Value  = @Stored;
EXEC test.Assert_IsEqual @TestName = N'[PrinterById] the terminal IP is reported for diagnosis',
     @Expected = N'172.17.20.5', @Actual = @Tip;
GO
CREATE TABLE #P2 (LocationId BIGINT, Code NVARCHAR(50), Name NVARCHAR(200),
                  Endpoint NVARCHAR(255), Model NVARCHAR(255), ConnectionKind NVARCHAR(255),
                  StoredEndpoint NVARCHAR(255), TerminalIpAddress NVARCHAR(255),
                  EndpointSource NVARCHAR(30));
DECLARE @Nw BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-NW-PRN');
INSERT INTO #P2 EXEC Location.Printer_GetById @PrinterLocationId = @Nw;
DECLARE @Ep2 NVARCHAR(255), @Src2 NVARCHAR(30);
SELECT @Ep2 = Endpoint, @Src2 = EndpointSource FROM #P2;
DROP TABLE #P2;
-- THE REGRESSION GUARD for the three live Networked printers.
EXEC test.Assert_IsEqual @TestName = N'[PrinterById] a Networked printer keeps its stored endpoint',
     @Expected = N'172.17.20.228:9100', @Actual = @Ep2;
EXEC test.Assert_IsEqual @TestName = N'[PrinterById] and reports it as stored',
     @Expected = N'stored', @Actual = @Src2;
GO
-- Terminal_GetPrinter: TOP 1 by SortOrder, so it lands on the UsbBridge printer.
CREATE TABLE #T (LocationId BIGINT, Code NVARCHAR(50), Name NVARCHAR(200),
                 Endpoint NVARCHAR(255), Model NVARCHAR(255), ConnectionKind NVARCHAR(255),
                 StoredEndpoint NVARCHAR(255), TerminalIpAddress NVARCHAR(255),
                 EndpointSource NVARCHAR(30));
DECLARE @Term BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-UB-TERM');
INSERT INTO #T EXEC Location.Terminal_GetPrinter @TerminalLocationId = @Term;
DECLARE @Ep3 NVARCHAR(255), @Ck3 NVARCHAR(255);
SELECT @Ep3 = Endpoint, @Ck3 = ConnectionKind FROM #T;
DROP TABLE #T;
EXEC test.Assert_IsEqual @TestName = N'[TerminalGetPrinter] resolves the derived endpoint',
     @Expected = N'172.17.20.5:9100', @Actual = @Ep3;
EXEC test.Assert_IsEqual @TestName = N'[TerminalGetPrinter] now projects ConnectionKind',
     @Expected = N'UsbBridge', @Actual = @Ck3;
GO
-- PrinterFgAssignment_ListForStation: both printers, each resolved its own way.
CREATE TABLE #L (PrinterLocationId BIGINT, PrinterCode NVARCHAR(50), PrinterName NVARCHAR(200),
                 Endpoint NVARCHAR(255), ConnectionKind NVARCHAR(255), AssignedItemId BIGINT,
                 PartNumber NVARCHAR(50), Description NVARCHAR(500), SortOrder INT,
                 StoredEndpoint NVARCHAR(255), TerminalIpAddress NVARCHAR(255),
                 EndpointSource NVARCHAR(30));
DECLARE @Term2 BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-UB-TERM');
INSERT INTO #L EXEC Location.PrinterFgAssignment_ListForStation @StationTerminalLocationId = @Term2;
DECLARE @UbEp NVARCHAR(255) = (SELECT Endpoint FROM #L WHERE PrinterCode = N'TEST-UB-PRN');
DECLARE @NwEp NVARCHAR(255) = (SELECT Endpoint FROM #L WHERE PrinterCode = N'TEST-NW-PRN');
DECLARE @Cnt  INT = (SELECT COUNT(*) FROM #L);
DROP TABLE #L;
EXEC test.Assert_RowCount @TestName = N'[FgList] both printers returned', @ExpectedCount = 2, @ActualCount = @Cnt;
EXEC test.Assert_IsEqual @TestName = N'[FgList] the UsbBridge card gets a derived endpoint',
     @Expected = N'172.17.20.5:9100', @Actual = @UbEp;
EXEC test.Assert_IsEqual @TestName = N'[FgList] the Networked card is unchanged',
     @Expected = N'172.17.20.228:9100', @Actual = @NwEp;
GO
-- A terminal with NO IpAddress: the UsbBridge printer resolves to NULL and says
-- so, rather than composing ':9100'. This is what makes the resolve stage log
-- EndpointUnresolved instead of a socket error naming a nonsense host.
DELETE la FROM Location.LocationAttribute la
    INNER JOIN Location.Location l ON l.Id = la.LocationId
    INNER JOIN Location.LocationAttributeDefinition lad ON lad.Id = la.LocationAttributeDefinitionId
    WHERE l.Code = N'TEST-UB-TERM' AND lad.AttributeName = N'IpAddress';
GO
CREATE TABLE #P3 (LocationId BIGINT, Code NVARCHAR(50), Name NVARCHAR(200),
                  Endpoint NVARCHAR(255), Model NVARCHAR(255), ConnectionKind NVARCHAR(255),
                  StoredEndpoint NVARCHAR(255), TerminalIpAddress NVARCHAR(255),
                  EndpointSource NVARCHAR(30));
DECLARE @Ub2 BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-UB-PRN');
INSERT INTO #P3 EXEC Location.Printer_GetById @PrinterLocationId = @Ub2;
DECLARE @Ep4 NVARCHAR(255), @Src4 NVARCHAR(30);
SELECT @Ep4 = Endpoint, @Src4 = EndpointSource FROM #P3;
DROP TABLE #P3;
EXEC test.Assert_IsNull @TestName = N'[PrinterById] no terminal IP -> no endpoint', @Value  = @Ep4;
EXEC test.Assert_IsEqual @TestName = N'[PrinterById] and it is reported unresolved',
     @Expected = N'unresolved', @Actual = @Src4;
GO
-- Teardown. LocationAttribute BEFORE Location; printers BEFORE their terminal.
DELETE la FROM Location.LocationAttribute la
    INNER JOIN Location.Location l ON l.Id = la.LocationId
    WHERE l.Code IN (N'TEST-UB-PRN', N'TEST-NW-PRN', N'TEST-UB-TERM');
DELETE FROM Location.Location WHERE Code IN (N'TEST-UB-PRN', N'TEST-NW-PRN');
DELETE FROM Location.Location WHERE Code = N'TEST-UB-TERM';
GO
EXEC test.EndTestFile;
GO
