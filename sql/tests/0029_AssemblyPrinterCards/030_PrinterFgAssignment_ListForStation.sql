SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0029_AssemblyPrinterCards/030_PrinterFgAssignment_ListForStation.sql';
GO
-- fixtures: a terminal with two child printers; one printer assigned to an FG.
DELETE pfa FROM Location.PrinterFgAssignment pfa INNER JOIN Location.Location l ON l.Id = pfa.PrinterLocationId WHERE l.Code IN (N'TEST-LST-P1', N'TEST-LST-P2');
DELETE FROM Location.Location WHERE Code IN (N'TEST-LST-P1', N'TEST-LST-P2', N'TEST-LST-TERM');
DECLARE @AnyParent BIGINT = (SELECT TOP 1 ParentLocationId FROM Location.Location WHERE LocationTypeDefinitionId = 7 AND ParentLocationId IS NOT NULL ORDER BY Id);
INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, SortOrder) VALUES (7, @AnyParent, N'Test Term', N'TEST-LST-TERM', 960);
DECLARE @T BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-LST-TERM');
INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, SortOrder) VALUES
    (16, @T, N'P1', N'TEST-LST-P1', 1),(16, @T, N'P2', N'TEST-LST-P2', 2);
DECLARE @P1 BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-LST-P1');
DECLARE @Fg BIGINT = (SELECT TOP 1 i.Id FROM Parts.Item i JOIN Parts.ItemType it ON it.Id = i.ItemTypeId AND it.Code = N'FinishedGood' WHERE i.DeprecatedAt IS NULL ORDER BY i.Id);
INSERT INTO Location.PrinterFgAssignment (PrinterLocationId, ItemId, SortOrder) VALUES (@P1, @Fg, 1);
GO
DECLARE @Cnt INT, @Assigned INT, @Unassigned INT;
CREATE TABLE #L (PrinterLocationId BIGINT, PrinterCode NVARCHAR(50), PrinterName NVARCHAR(200), Endpoint NVARCHAR(200), ConnectionKind NVARCHAR(50), AssignedItemId BIGINT, PartNumber NVARCHAR(50), Description NVARCHAR(500), SortOrder INT);
-- NOTE: EXEC parameters must be a literal or a @variable (never an inline subquery) --
-- resolve the terminal id into @StationTerm first, then pass the @variable.
DECLARE @StationTerm BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-LST-TERM');
INSERT INTO #L EXEC Location.PrinterFgAssignment_ListForStation @StationTerminalLocationId = @StationTerm;
SELECT @Cnt = COUNT(*), @Assigned = SUM(CASE WHEN AssignedItemId IS NOT NULL THEN 1 ELSE 0 END), @Unassigned = SUM(CASE WHEN AssignedItemId IS NULL THEN 1 ELSE 0 END) FROM #L;
DROP TABLE #L;
EXEC test.Assert_RowCount @TestName = N'[List] one row per child printer (2)', @ExpectedCount = 2, @ActualCount = @Cnt;
EXEC test.Assert_RowCount @TestName = N'[List] one assigned', @ExpectedCount = 1, @ActualCount = @Assigned;
EXEC test.Assert_RowCount @TestName = N'[List] one unassigned', @ExpectedCount = 1, @ActualCount = @Unassigned;
GO
DELETE pfa FROM Location.PrinterFgAssignment pfa INNER JOIN Location.Location l ON l.Id = pfa.PrinterLocationId WHERE l.Code IN (N'TEST-LST-P1', N'TEST-LST-P2');
DELETE FROM Location.Location WHERE Code IN (N'TEST-LST-P1', N'TEST-LST-P2', N'TEST-LST-TERM');
GO
EXEC test.EndTestFile;
GO
