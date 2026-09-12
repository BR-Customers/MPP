-- =============================================
-- File:         0070_Cutover_EntryRoute/050_Session_context_reads.sql
-- Description:  The two session-context reads behind the cutover scan header:
--               which route sequence an OperationType ROLE sits at (the value
--               passed as Lot_Create @EntryRouteSequence), and where a line's
--               scanned stock is deposited.
--
--               Both are domain questions and are therefore answered in SQL --
--               the scan screen asks, it does not compute.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0070_Cutover_EntryRoute/050_Session_context_reads.sql';
GO

DECLARE @Item BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'5G0-c');
DECLARE @Line BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-5GOF');
DECLARE @Whse BIGINT = (SELECT TOP 1 Id FROM Location.Location WHERE Code = N'WHSE' AND DeprecatedAt IS NULL ORDER BY Id);

CREATE TABLE #S (SequenceNumber INT);
CREATE TABLE #D (DestinationLocationId BIGINT, DestinationCode NVARCHAR(50), DestinationName NVARCHAR(100));

-- (1) The MachiningIn role resolves to a sequence.
INSERT INTO #S EXEC Parts.RouteStep_GetSequenceForItemRole @ItemId = @Item, @OperationTypeCode = N'MachiningIn';
DECLARE @e1 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #S);
EXEC test.Assert_IsEqual @TestName = N'[Session] MachiningIn role resolves to one row',
    @Expected = N'1', @Actual = @e1;

-- (2) The resolved value is usable as an EntryRouteSequence -- it names a real
--     step on the item's active route, which is exactly what Lot_Create checks.
DECLARE @Seq INT = (SELECT SequenceNumber FROM #S);
DECLARE @e2 NVARCHAR(10) = (SELECT CASE WHEN EXISTS (
    SELECT 1 FROM Parts.RouteTemplate rt
    JOIN Parts.RouteStep rs ON rs.RouteTemplateId = rt.Id
    WHERE rt.ItemId = @Item AND rt.PublishedAt IS NOT NULL AND rt.DeprecatedAt IS NULL
      AND rs.SequenceNumber = @Seq) THEN N'1' ELSE N'0' END);
EXEC test.Assert_IsEqual @TestName = N'[Session] resolved sequence names a real route step',
    @Expected = N'1', @Actual = @e2;

-- (3) Resolution is by ROLE, and different roles give different sequences.
DELETE FROM #S;
INSERT INTO #S EXEC Parts.RouteStep_GetSequenceForItemRole @ItemId = @Item, @OperationTypeCode = N'TrimIn';
DECLARE @TrimSeq INT = (SELECT SequenceNumber FROM #S);
DECLARE @e3 NVARCHAR(10) = CASE WHEN @TrimSeq < @Seq THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[Session] TrimIn resolves earlier than MachiningIn',
    @Expected = N'1', @Actual = @e3;

-- (4) A role the route does not carry returns an EMPTY SET, not a NULL row.
--     The scan screen branches on "no entry step for this role" and must not be
--     handed a row of NULLs.
DELETE FROM #S;
INSERT INTO #S EXEC Parts.RouteStep_GetSequenceForItemRole @ItemId = @Item, @OperationTypeCode = N'NoSuchRole';
DECLARE @e4 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #S);
EXEC test.Assert_IsEqual @TestName = N'[Session] unknown role returns an empty set',
    @Expected = N'0', @Actual = @e4;

-- (5) Stock destination: NULL DefaultStockLocationId resolves to the line itself
--     (today's behaviour -- M&A inventory is line-resident).
UPDATE Location.Location SET DefaultStockLocationId = NULL WHERE Id = @Line;
INSERT INTO #D EXEC Location.Location_GetStockDestination @LineLocationId = @Line;
DECLARE @e5 NVARCHAR(20) = (SELECT CAST(DestinationLocationId AS NVARCHAR(20)) FROM #D);
DECLARE @e5exp NVARCHAR(20) = CAST(@Line AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[Session] NULL destination resolves to the line itself',
    @Expected = @e5exp, @Actual = @e5;

-- (6) A configured destination wins, and its Code/Name come back for display.
UPDATE Location.Location SET DefaultStockLocationId = @Whse WHERE Id = @Line;
DELETE FROM #D; INSERT INTO #D EXEC Location.Location_GetStockDestination @LineLocationId = @Line;
DECLARE @e6 NVARCHAR(20) = (SELECT CAST(DestinationLocationId AS NVARCHAR(20)) FROM #D);
DECLARE @e6exp NVARCHAR(20) = CAST(@Whse AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[Session] configured destination wins',
    @Expected = @e6exp, @Actual = @e6;

DECLARE @e7 NVARCHAR(50) = (SELECT DestinationCode FROM #D);
EXEC test.Assert_IsEqual @TestName = N'[Session] destination Code returned for the header',
    @Expected = N'WHSE', @Actual = @e7;

DECLARE @e8 NVARCHAR(100) = (SELECT DestinationName FROM #D);
EXEC test.Assert_IsNotNull @TestName = N'[Session] destination Name returned for the header',
    @Value = @e8;

-- (7) An unknown line returns an empty set.
DELETE FROM #D; INSERT INTO #D EXEC Location.Location_GetStockDestination @LineLocationId = -1;
DECLARE @e9 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #D);
EXEC test.Assert_IsEqual @TestName = N'[Session] unknown line returns an empty set',
    @Expected = N'0', @Actual = @e9;

-- Restore the shared fixture row.
UPDATE Location.Location SET DefaultStockLocationId = NULL WHERE Id = @Line;
DROP TABLE #S; DROP TABLE #D;
GO
