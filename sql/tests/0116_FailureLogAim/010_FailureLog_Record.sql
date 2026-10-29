-- =============================================
-- File: 0116_FailureLogAim/010_FailureLog_Record.sql
-- Desc: Audit.FailureLog_Record (status-row writer for Ignition) and
--       Audit.Audit_LogFailure v1.1 (@LocationId / @LotId), migration 0116.
-- =============================================
EXEC test.BeginTestFile @FileName = N'0116_FailureLogAim/010_FailureLog_Record.sql';
GO

-- Fixture: one LOT named FL116-LOT at an Assembly OUT cell (direct insert,
-- the 0015 pattern -- only a valid FK target is needed).
DELETE FROM Audit.FailureLog WHERE ProcedureName LIKE N'Test0116.%';
DELETE FROM Lots.Lot WHERE LotName = N'FL116-LOT';
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, CurrentLocationId, CreatedByUserId)
VALUES (N'FL116-LOT',
        (SELECT TOP 1 Id FROM Parts.Item WHERE DeprecatedAt IS NULL ORDER BY Id),
        (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received'),
        (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Good'),
        10,
        (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT'),
        1);
GO

-- ---- Event codes seeded ----
DECLARE @Codes NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Audit.LogEventType
                               WHERE Code IN (N'AimPostFailed', N'AimSerialFetchFailed'));
EXEC test.Assert_IsEqual @TestName = N'[0116] AimPostFailed + AimSerialFetchFailed event types exist',
    @Expected = N'2', @Actual = @Codes;
GO

-- ---- Happy path: location + LOT + JSON metadata stored ----
DECLARE @Loc BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');
DECLARE @Lot BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'FL116-LOT');
DECLARE @R TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @R EXEC Audit.FailureLog_Record
    @AppUserId = 1, @LogEntityTypeCode = N'Container', @EntityId = 42,
    @LogEventTypeCode = N'AimPostFailed', @FailureReason = N'HTTP 403: Not logged in',
    @ProcedureName = N'Test0116.Happy', @AttemptedParameters = N'{"q":"a\"b","httpStatus":403}',
    @LocationId = @Loc, @LotId = @Lot;
DECLARE @S NVARCHAR(1) = (SELECT CAST(Status AS NVARCHAR(1)) FROM @R);
DECLARE @NewId BIGINT = (SELECT NewId FROM @R);
EXEC test.Assert_IsEqual @TestName = N'[0116] FailureLog_Record happy path returns Status 1',
    @Expected = N'1', @Actual = @S;
DECLARE @RowLoc NVARCHAR(20) = (SELECT CAST(LocationId AS NVARCHAR(20)) FROM Audit.FailureLog WHERE Id = @NewId);
DECLARE @ExpLoc NVARCHAR(20) = CAST(@Loc AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[0116] FailureLog_Record stores LocationId',
    @Expected = @ExpLoc, @Actual = @RowLoc;
DECLARE @RowLot NVARCHAR(20) = (SELECT CAST(LotId AS NVARCHAR(20)) FROM Audit.FailureLog WHERE Id = @NewId);
DECLARE @ExpLot NVARCHAR(20) = CAST(@Lot AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[0116] FailureLog_Record stores LotId',
    @Expected = @ExpLot, @Actual = @RowLot;
DECLARE @IsJson NVARCHAR(1) = (SELECT CAST(ISJSON(AttemptedParameters) AS NVARCHAR(1)) FROM Audit.FailureLog WHERE Id = @NewId);
EXEC test.Assert_IsEqual @TestName = N'[0116] FailureLog_Record keeps quoted JSON valid',
    @Expected = N'1', @Actual = @IsJson;
DECLARE @Ev NVARCHAR(50) = (SELECT e.Code FROM Audit.FailureLog f JOIN Audit.LogEventType e ON e.Id = f.LogEventTypeId WHERE f.Id = @NewId);
EXEC test.Assert_IsEqual @TestName = N'[0116] FailureLog_Record resolves the event code',
    @Expected = N'AimPostFailed', @Actual = @Ev;
GO

-- ---- Refusals: no row written ----
DECLARE @Before INT = (SELECT COUNT(*) FROM Audit.FailureLog WHERE ProcedureName = N'Test0116.Refused');
DECLARE @R TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);

INSERT INTO @R EXEC Audit.FailureLog_Record
    @AppUserId = NULL, @LogEntityTypeCode = N'Container', @LogEventTypeCode = N'AimPostFailed',
    @FailureReason = N'x', @ProcedureName = N'Test0116.Refused';
DECLARE @S1 NVARCHAR(1) = (SELECT CAST(Status AS NVARCHAR(1)) FROM @R);
EXEC test.Assert_IsEqual @TestName = N'[0116] missing AppUserId refused',
    @Expected = N'0', @Actual = @S1;

DELETE FROM @R;
INSERT INTO @R EXEC Audit.FailureLog_Record
    @AppUserId = 1, @LogEntityTypeCode = N'Container', @LogEventTypeCode = N'NoSuchEvent116',
    @FailureReason = N'x', @ProcedureName = N'Test0116.Refused';
DECLARE @S2 NVARCHAR(1) = (SELECT CAST(Status AS NVARCHAR(1)) FROM @R);
DECLARE @M2 NVARCHAR(500) = (SELECT Message FROM @R);
EXEC test.Assert_IsEqual @TestName = N'[0116] unknown event code refused',
    @Expected = N'0', @Actual = @S2;
EXEC test.Assert_Contains @TestName = N'[0116] unknown event code message names the code',
    @HaystackStr = @M2, @NeedleStr = N'NoSuchEvent116';

DELETE FROM @R;
INSERT INTO @R EXEC Audit.FailureLog_Record
    @AppUserId = 1, @LogEntityTypeCode = N'NoSuchEntity116', @LogEventTypeCode = N'AimPostFailed',
    @FailureReason = N'x', @ProcedureName = N'Test0116.Refused';
DECLARE @S3 NVARCHAR(1) = (SELECT CAST(Status AS NVARCHAR(1)) FROM @R);
EXEC test.Assert_IsEqual @TestName = N'[0116] unknown entity code refused',
    @Expected = N'0', @Actual = @S3;

DELETE FROM @R;
INSERT INTO @R EXEC Audit.FailureLog_Record
    @AppUserId = 1, @LogEntityTypeCode = N'Container', @LogEventTypeCode = N'AimPostFailed',
    @FailureReason = N'   ', @ProcedureName = N'Test0116.Refused';
DECLARE @S4 NVARCHAR(1) = (SELECT CAST(Status AS NVARCHAR(1)) FROM @R);
EXEC test.Assert_IsEqual @TestName = N'[0116] blank reason refused',
    @Expected = N'0', @Actual = @S4;

DECLARE @After INT = (SELECT COUNT(*) FROM Audit.FailureLog WHERE ProcedureName = N'Test0116.Refused');
DECLARE @Delta NVARCHAR(10) = CAST(@After - @Before AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[0116] refusals write no FailureLog row',
    @Expected = N'0', @Actual = @Delta;
GO

-- ---- Long reason truncated, not refused ----
DECLARE @Long NVARCHAR(MAX) = REPLICATE(CAST(N'x' AS NVARCHAR(MAX)), 900);
DECLARE @R TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @R EXEC Audit.FailureLog_Record
    @AppUserId = 1, @LogEntityTypeCode = N'Container', @LogEventTypeCode = N'AimPostFailed',
    @FailureReason = @Long, @ProcedureName = N'Test0116.Long';
DECLARE @S NVARCHAR(1) = (SELECT CAST(Status AS NVARCHAR(1)) FROM @R);
EXEC test.Assert_IsEqual @TestName = N'[0116] 900-char reason accepted',
    @Expected = N'1', @Actual = @S;
DECLARE @Len INT = (SELECT LEN(FailureReason) FROM Audit.FailureLog WHERE Id = (SELECT NewId FROM @R));
DECLARE @Ok BIT = CASE WHEN @Len <= 500 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[0116] 900-char reason stored at <= 500', @Condition = @Ok;
GO

-- ---- Unknown context ids dropped, row still written ----
DECLARE @R TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @R EXEC Audit.FailureLog_Record
    @AppUserId = 1, @LogEntityTypeCode = N'Container', @LogEventTypeCode = N'AimPostFailed',
    @FailureReason = N'ghost ids', @ProcedureName = N'Test0116.Ghost',
    @LocationId = -116, @LotId = -116;
DECLARE @S NVARCHAR(1) = (SELECT CAST(Status AS NVARCHAR(1)) FROM @R);
EXEC test.Assert_IsEqual @TestName = N'[0116] unknown Location/LOT ids still record the failure',
    @Expected = N'1', @Actual = @S;
DECLARE @L NVARCHAR(20) = (SELECT CAST(LocationId AS NVARCHAR(20)) FROM Audit.FailureLog WHERE Id = (SELECT NewId FROM @R));
EXEC test.Assert_IsNull @TestName = N'[0116] unknown LocationId stored as NULL', @Value = @L;
GO

-- ---- Audit_LogFailure v1.1: stores context, still emits no result set ----
DECLARE @Loc BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');
DECLARE @Lot BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'FL116-LOT');
DECLARE @Capture TABLE (AnyCol SQL_VARIANT);
INSERT INTO @Capture EXEC Audit.Audit_LogFailure
    @AppUserId = 1, @LogEntityTypeCode = N'Container', @EntityId = 7,
    @LogEventTypeCode = N'AimPostFailed', @FailureReason = N'silent writer',
    @ProcedureName = N'Test0116.Silent', @LocationId = @Loc, @LotId = @Lot;
DECLARE @Emitted NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @Capture);
EXEC test.Assert_IsEqual @TestName = N'[0116] Audit_LogFailure still emits no result set',
    @Expected = N'0', @Actual = @Emitted;
DECLARE @SLot NVARCHAR(20) = (SELECT TOP 1 CAST(LotId AS NVARCHAR(20)) FROM Audit.FailureLog
                              WHERE ProcedureName = N'Test0116.Silent' ORDER BY Id DESC);
DECLARE @ExpLot NVARCHAR(20) = CAST(@Lot AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[0116] Audit_LogFailure stores LotId',
    @Expected = @ExpLot, @Actual = @SLot;
GO

-- Cleanup.
DELETE FROM Audit.FailureLog WHERE ProcedureName LIKE N'Test0116.%';
DELETE FROM Lots.Lot WHERE LotName = N'FL116-LOT';
GO
