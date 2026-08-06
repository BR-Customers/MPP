SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0029_AssemblyPrinterCards/040_PrinterFgAssignment_SaveAll.sql';
GO
-- fixtures: station terminal + 2 child printers; a valid AppUser + 2 FGs
DELETE pfa FROM Location.PrinterFgAssignment pfa INNER JOIN Location.Location l ON l.Id = pfa.PrinterLocationId WHERE l.Code IN (N'TEST-SA-P1', N'TEST-SA-P2');
DELETE FROM Location.Location WHERE Code IN (N'TEST-SA-P1', N'TEST-SA-P2', N'TEST-SA-TERM');
DECLARE @AnyParent BIGINT = (SELECT TOP 1 ParentLocationId FROM Location.Location WHERE LocationTypeDefinitionId = 7 AND ParentLocationId IS NOT NULL ORDER BY Id);
INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, SortOrder) VALUES (7, @AnyParent, N'Test SA Term', N'TEST-SA-TERM', 970);
DECLARE @T BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-SA-TERM');
INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, SortOrder) VALUES (16, @T, N'P1', N'TEST-SA-P1', 1),(16, @T, N'P2', N'TEST-SA-P2', 2);
GO
DECLARE @T BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-SA-TERM');
DECLARE @P1 BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-SA-P1');
DECLARE @P2 BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-SA-P2');
DECLARE @U BIGINT = (SELECT TOP 1 Id FROM Location.AppUser ORDER BY Id);
DECLARE @Fg1 BIGINT = (SELECT TOP 1 i.Id FROM Parts.Item i JOIN Parts.ItemType it ON it.Id = i.ItemTypeId AND it.Code = N'FinishedGood' WHERE i.DeprecatedAt IS NULL ORDER BY i.Id);
DECLARE @Fg2 BIGINT = (SELECT TOP 1 i.Id FROM Parts.Item i JOIN Parts.ItemType it ON it.Id = i.ItemTypeId AND it.Code = N'FinishedGood' WHERE i.DeprecatedAt IS NULL AND i.Id <> @Fg1 ORDER BY i.Id);

-- Test 1: assign FG1->P1, FG2->P2
DECLARE @Json NVARCHAR(MAX) = N'[{"PrinterLocationId":' + CAST(@P1 AS NVARCHAR(20)) + N',"ItemId":' + CAST(@Fg1 AS NVARCHAR(20)) + N',"SortOrder":1},{"PrinterLocationId":' + CAST(@P2 AS NVARCHAR(20)) + N',"ItemId":' + CAST(@Fg2 AS NVARCHAR(20)) + N',"SortOrder":2}]';
DECLARE @St BIT, @Msg NVARCHAR(500);
CREATE TABLE #R (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R EXEC Location.PrinterFgAssignment_SaveAll @StationTerminalLocationId=@T, @AppUserId=@U, @AssignmentsJson=@Json;
SELECT @St = Status FROM #R; DELETE FROM #R;
DECLARE @StStr1 NVARCHAR(1) = CAST(@St AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName=N'[SaveAll] assign two -> Status 1', @Expected=N'1', @Actual=@StStr1;
DECLARE @Rows INT = (SELECT COUNT(*) FROM Location.PrinterFgAssignment WHERE PrinterLocationId IN (@P1,@P2));
EXEC test.Assert_RowCount @TestName=N'[SaveAll] two rows persisted', @ExpectedCount=2, @ActualCount=@Rows;

-- Test 2: swap (FG2->P1, FG1->P2) is still Status 1 and count stays 2
SET @Json = N'[{"PrinterLocationId":' + CAST(@P1 AS NVARCHAR(20)) + N',"ItemId":' + CAST(@Fg2 AS NVARCHAR(20)) + N',"SortOrder":1},{"PrinterLocationId":' + CAST(@P2 AS NVARCHAR(20)) + N',"ItemId":' + CAST(@Fg1 AS NVARCHAR(20)) + N',"SortOrder":2}]';
INSERT INTO #R EXEC Location.PrinterFgAssignment_SaveAll @StationTerminalLocationId=@T, @AppUserId=@U, @AssignmentsJson=@Json;
SELECT @St = Status FROM #R; DELETE FROM #R;
DECLARE @P1Item BIGINT = (SELECT ItemId FROM Location.PrinterFgAssignment WHERE PrinterLocationId=@P1);
DECLARE @Fg2Str NVARCHAR(20) = CAST(@Fg2 AS NVARCHAR(20));
DECLARE @P1ItemStr NVARCHAR(20) = CAST(@P1Item AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName=N'[SaveAll] swap -> P1 now has FG2', @Expected=@Fg2Str, @Actual=@P1ItemStr;

-- Test 3: duplicate ItemId on two printers -> Status 0 (rejected)
SET @Json = N'[{"PrinterLocationId":' + CAST(@P1 AS NVARCHAR(20)) + N',"ItemId":' + CAST(@Fg1 AS NVARCHAR(20)) + N',"SortOrder":1},{"PrinterLocationId":' + CAST(@P2 AS NVARCHAR(20)) + N',"ItemId":' + CAST(@Fg1 AS NVARCHAR(20)) + N',"SortOrder":2}]';
INSERT INTO #R EXEC Location.PrinterFgAssignment_SaveAll @StationTerminalLocationId=@T, @AppUserId=@U, @AssignmentsJson=@Json;
SELECT @St = Status FROM #R; DELETE FROM #R;
DECLARE @StStr3 NVARCHAR(1) = CAST(@St AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName=N'[SaveAll] duplicate FG -> Status 0', @Expected=N'0', @Actual=@StStr3;

-- Test 4: unassign P2 (null ItemId) -> only P1 row remains
SET @Json = N'[{"PrinterLocationId":' + CAST(@P1 AS NVARCHAR(20)) + N',"ItemId":' + CAST(@Fg2 AS NVARCHAR(20)) + N',"SortOrder":1},{"PrinterLocationId":' + CAST(@P2 AS NVARCHAR(20)) + N',"ItemId":null,"SortOrder":2}]';
INSERT INTO #R EXEC Location.PrinterFgAssignment_SaveAll @StationTerminalLocationId=@T, @AppUserId=@U, @AssignmentsJson=@Json;
DELETE FROM #R;
DECLARE @Rows2 INT = (SELECT COUNT(*) FROM Location.PrinterFgAssignment WHERE PrinterLocationId IN (@P1,@P2));
EXEC test.Assert_RowCount @TestName=N'[SaveAll] unassign one -> one row', @ExpectedCount=1, @ActualCount=@Rows2;
DROP TABLE #R;
GO
DELETE pfa FROM Location.PrinterFgAssignment pfa INNER JOIN Location.Location l ON l.Id = pfa.PrinterLocationId WHERE l.Code IN (N'TEST-SA-P1', N'TEST-SA-P2');
DELETE FROM Location.Location WHERE Code IN (N'TEST-SA-P1', N'TEST-SA-P2', N'TEST-SA-TERM');
GO
EXEC test.EndTestFile;
GO
