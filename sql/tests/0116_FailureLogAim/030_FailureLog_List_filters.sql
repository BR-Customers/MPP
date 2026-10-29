-- =============================================
-- File: 0116_FailureLogAim/030_FailureLog_List_filters.sql
-- Desc: FailureLog_List v3.1 (@LocationId / @LotNameLike, trailing name
--       columns) and FailureLog_GetByEntity v2.1 (trailing name columns).
-- =============================================
EXEC test.BeginTestFile @FileName = N'0116_FailureLogAim/030_FailureLog_List_filters.sql';
GO

DELETE FROM Audit.FailureLog WHERE ProcedureName LIKE N'Test0116L.%';
DELETE FROM Lots.Lot WHERE LotName = N'FL116L-LOT';
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, CurrentLocationId, CreatedByUserId)
VALUES (N'FL116L-LOT', (SELECT TOP 1 Id FROM Parts.Item WHERE DeprecatedAt IS NULL ORDER BY Id),
        (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received'), 1, 5, @Cell, 1);
DECLARE @Lot BIGINT = SCOPE_IDENTITY();
-- One row with both, one with neither.
EXEC Audit.Audit_LogFailure @AppUserId = 1, @LogEntityTypeCode = N'Container', @EntityId = 116,
    @LogEventTypeCode = N'AimPostFailed', @FailureReason = N'with context',
    @ProcedureName = N'Test0116L.A', @LocationId = @Cell, @LotId = @Lot;
EXEC Audit.Audit_LogFailure @AppUserId = 1, @LogEntityTypeCode = N'Container', @EntityId = 116,
    @LogEventTypeCode = N'AimPostFailed', @FailureReason = N'no context',
    @ProcedureName = N'Test0116L.B';
GO

CREATE TABLE #L (
    Id BIGINT, AttemptedAt DATETIME2(3), AppUserId BIGINT, UserDisplayName NVARCHAR(200),
    LogEntityTypeCode NVARCHAR(50), LogEntityTypeName NVARCHAR(100), EntityId BIGINT,
    LogEventTypeId BIGINT, LogEventTypeCode NVARCHAR(50), FailureReason NVARCHAR(500),
    ProcedureName NVARCHAR(200), AttemptedParameters NVARCHAR(MAX), TotalCount INT,
    LocationId BIGINT, LocationName NVARCHAR(200), LotId BIGINT, LotName NVARCHAR(50));
DECLARE @Today DATETIME2(3) = CAST(SYSUTCDATETIME() AS DATE);
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');

-- Location filter: only the row with context.
INSERT INTO #L EXEC Audit.FailureLog_List @StartDate = @Today, @EndDate = @Today,
    @ProcedureName = NULL, @LocationId = @Cell;
DECLARE @OnlyA NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #L WHERE ProcedureName LIKE N'Test0116L.%');
EXEC test.Assert_IsEqual @TestName = N'[0116] List @LocationId returns only rows at that location',
    @Expected = N'1', @Actual = @OnlyA;
DECLARE @LocName NVARCHAR(200) = (SELECT TOP 1 LocationName FROM #L WHERE ProcedureName = N'Test0116L.A');
DECLARE @ExpName NVARCHAR(200) = (SELECT Name FROM Location.Location WHERE Id = @Cell);
EXEC test.Assert_IsEqual @TestName = N'[0116] List resolves LocationName',
    @Expected = @ExpName, @Actual = @LocName;

-- LOT substring filter.
TRUNCATE TABLE #L;
INSERT INTO #L EXEC Audit.FailureLog_List @StartDate = @Today, @EndDate = @Today, @LotNameLike = N'116L-L';
DECLARE @ByLot NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #L WHERE ProcedureName LIKE N'Test0116L.%');
EXEC test.Assert_IsEqual @TestName = N'[0116] List @LotNameLike returns only rows with a matching LOT',
    @Expected = N'1', @Actual = @ByLot;
DECLARE @LName NVARCHAR(50) = (SELECT TOP 1 LotName FROM #L WHERE ProcedureName = N'Test0116L.A');
EXEC test.Assert_IsEqual @TestName = N'[0116] List resolves LotName',
    @Expected = N'FL116L-LOT', @Actual = @LName;

-- No new filter: both rows.
TRUNCATE TABLE #L;
INSERT INTO #L EXEC Audit.FailureLog_List @StartDate = @Today, @EndDate = @Today;
DECLARE @Both NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #L WHERE ProcedureName LIKE N'Test0116L.%');
EXEC test.Assert_IsEqual @TestName = N'[0116] List without the new filters returns both rows',
    @Expected = N'2', @Actual = @Both;
DROP TABLE #L;

-- GetByEntity carries the names.
CREATE TABLE #G (
    Id BIGINT, AttemptedAt DATETIME2(3), AppUserId BIGINT, UserDisplayName NVARCHAR(200),
    LogEntityTypeId BIGINT, LogEntityTypeName NVARCHAR(100), EntityId BIGINT,
    LogEventTypeId BIGINT, LogEventTypeName NVARCHAR(100), FailureReason NVARCHAR(500),
    ProcedureName NVARCHAR(200), AttemptedParameters NVARCHAR(MAX),
    LocationId BIGINT, LocationName NVARCHAR(200), LotId BIGINT, LotName NVARCHAR(50));
INSERT INTO #G EXEC Audit.FailureLog_GetByEntity @LogEntityTypeCode = N'Container', @EntityId = 116;
DECLARE @GLot NVARCHAR(50) = (SELECT TOP 1 LotName FROM #G WHERE ProcedureName = N'Test0116L.A');
EXEC test.Assert_IsEqual @TestName = N'[0116] GetByEntity resolves LotName',
    @Expected = N'FL116L-LOT', @Actual = @GLot;
DROP TABLE #G;
GO

DELETE FROM Audit.FailureLog WHERE ProcedureName LIKE N'Test0116L.%';
DELETE FROM Lots.Lot WHERE LotName = N'FL116L-LOT';
GO
