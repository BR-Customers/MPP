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

-- Test 5 (Validation 1): PrinterLocationId that is NOT a child printer of the
-- station (some other location entirely) -> Status 0 (rejected).
DECLARE @NotAChildPrinter BIGINT = (SELECT TOP 1 Id FROM Location.Location WHERE Id NOT IN (@P1, @P2) AND DeprecatedAt IS NULL ORDER BY Id);
SET @Json = N'[{"PrinterLocationId":' + CAST(@NotAChildPrinter AS NVARCHAR(20)) + N',"ItemId":' + CAST(@Fg1 AS NVARCHAR(20)) + N',"SortOrder":1}]';
INSERT INTO #R EXEC Location.PrinterFgAssignment_SaveAll @StationTerminalLocationId=@T, @AppUserId=@U, @AssignmentsJson=@Json;
SELECT @St = Status FROM #R; DELETE FROM #R;
DECLARE @StStr5 NVARCHAR(1) = CAST(@St AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName=N'[SaveAll] printer not a child of station -> Status 0', @Expected=N'0', @Actual=@StStr5;

-- Test 6 (Validation 2): valid child printer, but ItemId that is NOT an active
-- FinishedGood (a non-existent Id) -> Status 0 (rejected).
DECLARE @BogusItemId BIGINT = -999;
SET @Json = N'[{"PrinterLocationId":' + CAST(@P1 AS NVARCHAR(20)) + N',"ItemId":' + CAST(@BogusItemId AS NVARCHAR(20)) + N',"SortOrder":1}]';
INSERT INTO #R EXEC Location.PrinterFgAssignment_SaveAll @StationTerminalLocationId=@T, @AppUserId=@U, @AssignmentsJson=@Json;
SELECT @St = Status FROM #R; DELETE FROM #R;
DECLARE @StStr6 NVARCHAR(1) = CAST(@St AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName=N'[SaveAll] item not an active finished good -> Status 0', @Expected=N'0', @Actual=@StStr6;

-- Test 7 (audit): a successful save writes RESOLVED-NAME JSON to Audit.ConfigLog
-- (regression guard for the resolved-name audit fix -- bare-ID JSON must not return).
DECLARE @Fg1Part NVARCHAR(50) = (SELECT PartNumber FROM Parts.Item WHERE Id = @Fg1);
SET @Json = N'[{"PrinterLocationId":' + CAST(@P1 AS NVARCHAR(20)) + N',"ItemId":' + CAST(@Fg1 AS NVARCHAR(20)) + N',"SortOrder":1}]';
INSERT INTO #R EXEC Location.PrinterFgAssignment_SaveAll @StationTerminalLocationId=@T, @AppUserId=@U, @AssignmentsJson=@Json; DELETE FROM #R;
DECLARE @NewVal NVARCHAR(MAX);
SELECT TOP 1 @NewVal = cl.NewValue FROM Audit.ConfigLog cl
    JOIN Audit.LogEntityType et ON et.Id = cl.LogEntityTypeId
    WHERE et.Code = N'PrinterFgAssignment' AND cl.EntityId = @T
    ORDER BY cl.Id DESC;
EXEC test.Assert_Contains @TestName=N'[SaveAll] audit NewValue carries resolved PartNumber (not bare IDs)', @HaystackStr=@NewVal, @NeedleStr=@Fg1Part;

-- Test 8 (ordering): ListForStation returns rows in SortOrder; a reorder changes
-- ONLY order, not the FG<->printer binding.
SET @Json = N'[{"PrinterLocationId":' + CAST(@P1 AS NVARCHAR(20)) + N',"ItemId":' + CAST(@Fg1 AS NVARCHAR(20)) + N',"SortOrder":1},{"PrinterLocationId":' + CAST(@P2 AS NVARCHAR(20)) + N',"ItemId":' + CAST(@Fg2 AS NVARCHAR(20)) + N',"SortOrder":2}]';
INSERT INTO #R EXEC Location.PrinterFgAssignment_SaveAll @StationTerminalLocationId=@T, @AppUserId=@U, @AssignmentsJson=@Json; DELETE FROM #R;
CREATE TABLE #L (PrinterLocationId BIGINT, PrinterCode NVARCHAR(50), PrinterName NVARCHAR(200), Endpoint NVARCHAR(200), ConnectionKind NVARCHAR(50), AssignedItemId BIGINT, PartNumber NVARCHAR(50), Description NVARCHAR(500), SortOrder INT);
INSERT INTO #L EXEC Location.PrinterFgAssignment_ListForStation @StationTerminalLocationId=@T;
DECLARE @First BIGINT;
SELECT TOP 1 @First = PrinterLocationId FROM #L ORDER BY SortOrder, PrinterLocationId;
DELETE FROM #L;
DECLARE @P1Str  NVARCHAR(20) = CAST(@P1  AS NVARCHAR(20));
DECLARE @P2Str  NVARCHAR(20) = CAST(@P2  AS NVARCHAR(20));
DECLARE @Fg1Str NVARCHAR(20) = CAST(@Fg1 AS NVARCHAR(20));
DECLARE @FirstStr NVARCHAR(20) = CAST(@First AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName=N'[SaveAll] ListForStation orders by SortOrder (P1 first)', @Expected=@P1Str, @Actual=@FirstStr;
SET @Json = N'[{"PrinterLocationId":' + @P1Str + N',"ItemId":' + @Fg1Str + N',"SortOrder":2},{"PrinterLocationId":' + @P2Str + N',"ItemId":' + CAST(@Fg2 AS NVARCHAR(20)) + N',"SortOrder":1}]';
INSERT INTO #R EXEC Location.PrinterFgAssignment_SaveAll @StationTerminalLocationId=@T, @AppUserId=@U, @AssignmentsJson=@Json; DELETE FROM #R;
INSERT INTO #L EXEC Location.PrinterFgAssignment_ListForStation @StationTerminalLocationId=@T;
DECLARE @First2 BIGINT;
SELECT TOP 1 @First2 = PrinterLocationId FROM #L ORDER BY SortOrder, PrinterLocationId;
DECLARE @P1Fg BIGINT = (SELECT AssignedItemId FROM #L WHERE PrinterLocationId=@P1);
DROP TABLE #L;
DECLARE @First2Str NVARCHAR(20) = CAST(@First2 AS NVARCHAR(20));
DECLARE @P1FgStr   NVARCHAR(20) = CAST(@P1Fg   AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName=N'[SaveAll] reorder puts P2 first', @Expected=@P2Str, @Actual=@First2Str;
EXEC test.Assert_IsEqual @TestName=N'[SaveAll] reorder keeps P1->FG1 binding', @Expected=@Fg1Str, @Actual=@P1FgStr;

-- Test 9 (malformed): non-numeric PrinterLocationId -> TRY_CAST NULL -> Status 0 (no throw).
SET @Json = N'[{"PrinterLocationId":"not-a-number","ItemId":' + CAST(@Fg1 AS NVARCHAR(20)) + N',"SortOrder":1}]';
INSERT INTO #R EXEC Location.PrinterFgAssignment_SaveAll @StationTerminalLocationId=@T, @AppUserId=@U, @AssignmentsJson=@Json;
SELECT @St = Status FROM #R; DELETE FROM #R;
DECLARE @StStr9 NVARCHAR(1) = CAST(@St AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName=N'[SaveAll] malformed PrinterLocationId -> Status 0 (no throw)', @Expected=N'0', @Actual=@StStr9;

DROP TABLE #R;
GO
DELETE pfa FROM Location.PrinterFgAssignment pfa INNER JOIN Location.Location l ON l.Id = pfa.PrinterLocationId WHERE l.Code IN (N'TEST-SA-P1', N'TEST-SA-P2');
DELETE FROM Location.Location WHERE Code IN (N'TEST-SA-P1', N'TEST-SA-P2', N'TEST-SA-TERM');
GO
EXEC test.EndTestFile;
GO
