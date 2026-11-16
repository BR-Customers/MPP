-- =============================================
-- File:         02_audit_readers/075_FailureLog_List_page.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-11-16
-- Description:
--   Pins the result contract of Audit.FailureLog_List that the v3.2
--   rewrite (stored-procedure review: filter + count + TOP over the key,
--   wide columns fetched for the page only) must keep:
--     - TOP 1000 cap, newest first, strictly descending AttemptedAt
--     - TotalCount = the full filtered count on every row (not the page size)
--     - AttemptedAt returned in Eastern time
--     - @EndDate is an inclusive day
--     - entity-type / user / procedure / location / LOT-name / reason
--       filters, alone and combined, with TotalCount following the filter
--     - an unknown @LogEntityTypeCode returns no rows
--     - display names (user, entity type, event type, location, LOT) resolved
--   Written to pass on v3.1 and v3.2 alike.
--
--   Seeds its own rows on 2001-03-15 (UTC) so no other test's rows share
--   the window, and removes them at the end.
-- =============================================
EXEC test.BeginTestFile @FileName = N'02_audit_readers/075_FailureLog_List_page.sql';
GO

DELETE FROM Audit.FailureLog WHERE ProcedureName LIKE N'Test075.%';
DELETE FROM Lots.Lot WHERE LotName = N'FL075-LOT';
GO

DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, CurrentLocationId, CreatedByUserId)
VALUES (N'FL075-LOT', (SELECT TOP 1 Id FROM Parts.Item WHERE DeprecatedAt IS NULL ORDER BY Id),
        (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received'), 1, 5, @Cell, 1);
DECLARE @Lot BIGINT = SCOPE_IDENTITY();
DECLARE @EntUser BIGINT = (SELECT Id FROM Audit.LogEntityType WHERE Code = N'AppUser');
DECLARE @EntLoc  BIGINT = (SELECT Id FROM Audit.LogEntityType WHERE Code = N'Location');
DECLARE @EvCreated BIGINT = (SELECT Id FROM Audit.LogEventType WHERE Code = N'Created');

-- 1,005 rows one second apart from 2001-03-15 10:00:00 UTC (n = 1 oldest).
--   entity type: Location when n % 3 = 0 (335 rows), else AppUser (670)
--   procedure:   Test075.P2 when n % 5 = 0 (201 rows), else Test075.P1
--   location:    @Cell when n % 4 = 0 (251 rows)
--   LOT:         @Lot when n % 100 = 0 (10 rows; 3 Location-typed: n = 300, 600, 900)
WITH N AS (SELECT TOP (1005) ROW_NUMBER() OVER (ORDER BY (SELECT 1)) AS n FROM sys.all_objects a CROSS JOIN sys.all_objects b)
INSERT INTO Audit.FailureLog (AttemptedAt, AppUserId, LogEntityTypeId, EntityId, LogEventTypeId,
                              FailureReason, ProcedureName, AttemptedParameters, LocationId, LotId)
SELECT DATEADD(SECOND, n, CAST('2001-03-15T10:00:00' AS DATETIME2(3))),
       1,
       CASE WHEN n % 3 = 0 THEN @EntLoc ELSE @EntUser END,
       n, @EvCreated,
       N'Test 075 row ' + CAST(n AS NVARCHAR(10)),
       CASE WHEN n % 5 = 0 THEN N'Test075.P2' ELSE N'Test075.P1' END,
       N'{"n":' + CAST(n AS NVARCHAR(10)) + N'}',
       CASE WHEN n % 4 = 0 THEN @Cell END,
       CASE WHEN n % 100 = 0 THEN @Lot END
FROM N;
GO

CREATE TABLE #L (
    Id BIGINT, AttemptedAt DATETIME2(3), AppUserId BIGINT, UserDisplayName NVARCHAR(200),
    LogEntityTypeCode NVARCHAR(50), LogEntityTypeName NVARCHAR(100), EntityId BIGINT,
    LogEventTypeId BIGINT, LogEventTypeCode NVARCHAR(50), FailureReason NVARCHAR(500),
    ProcedureName NVARCHAR(200), AttemptedParameters NVARCHAR(MAX), TotalCount INT,
    LocationId BIGINT, LocationName NVARCHAR(200), LotId BIGINT, LotName NVARCHAR(50),
    RowNo INT IDENTITY(1,1));
GO

-- Capture helper: every case below truncates #L and refills it in arrival order.
CREATE OR ALTER PROCEDURE #Fill
    @StartDate DATETIME2(3), @EndDate DATETIME2(3),
    @LogEntityTypeCode NVARCHAR(50) = NULL, @AppUserId BIGINT = NULL,
    @ProcedureName NVARCHAR(200) = NULL, @FailureReasonLike NVARCHAR(500) = NULL,
    @LocationId BIGINT = NULL, @LotNameLike NVARCHAR(50) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    TRUNCATE TABLE #L;
    INSERT INTO #L (Id, AttemptedAt, AppUserId, UserDisplayName, LogEntityTypeCode, LogEntityTypeName, EntityId,
                    LogEventTypeId, LogEventTypeCode, FailureReason, ProcedureName, AttemptedParameters, TotalCount,
                    LocationId, LocationName, LotId, LotName)
    EXEC Audit.FailureLog_List
        @StartDate = @StartDate, @EndDate = @EndDate,
        @LogEntityTypeCode = @LogEntityTypeCode, @AppUserId = @AppUserId,
        @ProcedureName = @ProcedureName, @FailureReasonLike = @FailureReasonLike,
        @LocationId = @LocationId, @LotNameLike = @LotNameLike;
END;
GO

DECLARE @Day DATETIME2(3) = '2001-03-15';
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');
DECLARE @CellName NVARCHAR(200) = (SELECT Name FROM Location.Location WHERE Id = @Cell);
DECLARE @s NVARCHAR(400), @c BIT;

-- ---- Test 1: TOP 1000 cap, TotalCount, order, newest page, ET, names ----
EXEC #Fill @StartDate = @Day, @EndDate = @Day;
SET @s = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #L);
EXEC test.Assert_IsEqual @TestName = N'[075] List caps the page at 1000 rows', @Expected = N'1000', @Actual = @s;
SET @s = (SELECT CAST(MIN(TotalCount) AS NVARCHAR(10)) + N'/' + CAST(MAX(TotalCount) AS NVARCHAR(10)) FROM #L);
EXEC test.Assert_IsEqual @TestName = N'[075] TotalCount is the full count (1005) on every row', @Expected = N'1005/1005', @Actual = @s;
SET @c = CASE WHEN EXISTS (SELECT 1 FROM #L a JOIN #L b ON b.RowNo = a.RowNo + 1 WHERE b.AttemptedAt >= a.AttemptedAt) THEN 0 ELSE 1 END;
EXEC test.Assert_IsTrue @TestName = N'[075] rows are strictly newest first', @Condition = @c;
SET @s = (SELECT CAST(MIN(EntityId) AS NVARCHAR(10)) + N'..' + CAST(MAX(EntityId) AS NVARCHAR(10)) FROM #L);
EXEC test.Assert_IsEqual @TestName = N'[075] the page is the newest 1000 (n 6..1005)', @Expected = N'6..1005', @Actual = @s;
-- n = 1005 -> 10:16:45 UTC on 2001-03-15 (EST, UTC-5) -> 05:16:45 Eastern.
SET @s = (SELECT CONVERT(NVARCHAR(30), AttemptedAt, 126) FROM #L WHERE RowNo = 1);
EXEC test.Assert_IsEqual @TestName = N'[075] AttemptedAt is returned in Eastern time', @Expected = N'2001-03-15T05:16:45', @Actual = @s;
SET @s = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #L
          WHERE UserDisplayName IS NULL OR LogEntityTypeName IS NULL OR LogEventTypeCode IS NULL OR LogEventTypeCode <> N'Created');
EXEC test.Assert_IsEqual @TestName = N'[075] user, entity-type and event-type names resolved', @Expected = N'0', @Actual = @s;

-- ---- Test 2: @EndDate is an inclusive day; the day before is empty ----
EXEC #Fill @StartDate = '2001-03-14', @EndDate = '2001-03-14';
SET @s = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #L);
EXEC test.Assert_IsEqual @TestName = N'[075] a window ending the day before returns no rows', @Expected = N'0', @Actual = @s;

-- ---- Test 3: entity-type filter, TotalCount follows it ----
EXEC #Fill @StartDate = @Day, @EndDate = @Day, @LogEntityTypeCode = N'Location';
SET @s = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) + N'/' + CAST(MAX(TotalCount) AS NVARCHAR(10))
                 + N'/' + CAST(SUM(CASE WHEN LogEntityTypeCode <> N'Location' THEN 1 ELSE 0 END) AS NVARCHAR(10)) FROM #L);
EXEC test.Assert_IsEqual @TestName = N'[075] entity-type filter: 335 rows, TotalCount 335, no other type', @Expected = N'335/335/0', @Actual = @s;

-- ---- Test 4: unknown entity-type code -> no rows ----
EXEC #Fill @StartDate = @Day, @EndDate = @Day, @LogEntityTypeCode = N'NoSuchType075';
SET @s = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #L);
EXEC test.Assert_IsEqual @TestName = N'[075] unknown entity-type code returns no rows', @Expected = N'0', @Actual = @s;

-- ---- Test 5: procedure + user filters ----
EXEC #Fill @StartDate = @Day, @EndDate = @Day, @ProcedureName = N'Test075.P2', @AppUserId = 1;
SET @s = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) + N'/' + CAST(MAX(TotalCount) AS NVARCHAR(10)) FROM #L);
EXEC test.Assert_IsEqual @TestName = N'[075] procedure + user filter: 201 rows, TotalCount 201', @Expected = N'201/201', @Actual = @s;
EXEC #Fill @StartDate = @Day, @EndDate = @Day, @AppUserId = -75;
SET @s = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #L);
EXEC test.Assert_IsEqual @TestName = N'[075] user filter with no rows returns none', @Expected = N'0', @Actual = @s;

-- ---- Test 6: location filter + LocationName ----
EXEC #Fill @StartDate = @Day, @EndDate = @Day, @LocationId = @Cell;
SET @s = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) + N'/' + CAST(MAX(TotalCount) AS NVARCHAR(10))
                 + N'/' + CAST(SUM(CASE WHEN LocationName = @CellName THEN 1 ELSE 0 END) AS NVARCHAR(10)) FROM #L);
EXEC test.Assert_IsEqual @TestName = N'[075] location filter: 251 rows, TotalCount 251, name resolved', @Expected = N'251/251/251', @Actual = @s;

-- ---- Test 7: LOT-name substring filter, alone and with entity type ----
EXEC #Fill @StartDate = @Day, @EndDate = @Day, @LotNameLike = N'075-L';
SET @s = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) + N'/' + CAST(MAX(TotalCount) AS NVARCHAR(10))
                 + N'/' + CAST(SUM(CASE WHEN LotName = N'FL075-LOT' THEN 1 ELSE 0 END) AS NVARCHAR(10)) FROM #L);
EXEC test.Assert_IsEqual @TestName = N'[075] LOT-name filter: 10 rows, TotalCount 10, LotName resolved', @Expected = N'10/10/10', @Actual = @s;
SET @s = (SELECT STRING_AGG(CAST(EntityId AS NVARCHAR(10)), N',') WITHIN GROUP (ORDER BY RowNo) FROM #L);
EXEC test.Assert_IsEqual @TestName = N'[075] LOT-name filter rows come newest first',
    @Expected = N'1000,900,800,700,600,500,400,300,200,100', @Actual = @s;
EXEC #Fill @StartDate = @Day, @EndDate = @Day, @LotNameLike = N'075-L', @LogEntityTypeCode = N'Location';
SET @s = (SELECT STRING_AGG(CAST(EntityId AS NVARCHAR(10)), N',') WITHIN GROUP (ORDER BY RowNo) + N'/' + CAST(MAX(TotalCount) AS NVARCHAR(10)) FROM #L);
EXEC test.Assert_IsEqual @TestName = N'[075] LOT-name + entity-type filter: rows 900,600,300, TotalCount 3',
    @Expected = N'900,600,300/3', @Actual = @s;
EXEC #Fill @StartDate = @Day, @EndDate = @Day, @LotNameLike = N'no-such-lot-075';
SET @s = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #L);
EXEC test.Assert_IsEqual @TestName = N'[075] LOT-name filter with no match returns no rows', @Expected = N'0', @Actual = @s;

-- ---- Test 8: reason substring filter ----
-- 'Test 075 row 99' matches n = 99 and 990..999: 11 rows.
EXEC #Fill @StartDate = @Day, @EndDate = @Day, @FailureReasonLike = N'row 99';
SET @s = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) + N'/' + CAST(MAX(TotalCount) AS NVARCHAR(10)) FROM #L);
EXEC test.Assert_IsEqual @TestName = N'[075] reason substring filter: 11 rows, TotalCount 11', @Expected = N'11/11', @Actual = @s;
GO

DROP PROCEDURE #Fill;
DROP TABLE #L;
DELETE FROM Audit.FailureLog WHERE ProcedureName LIKE N'Test075.%';
DELETE FROM Lots.Lot WHERE LotName = N'FL075-LOT';
GO

EXEC test.PrintSummary;
GO
