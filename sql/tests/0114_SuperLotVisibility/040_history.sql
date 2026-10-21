-- =============================================
-- File:        0114_SuperLotVisibility/040_history.sql
-- Author:      Blue Ridge Automation
-- Description: Super-lot piece 6, Task 4 -- Lots.Lot_GetAttributeHistory v1.5
--              unions stream 11: the LOT's audit log (Lots.LotEventLog) for
--              event types that do NOT repeat the record streams
--              (Audit.LogEventType.RepeatsLotTimeline = 0). Kind comes from
--              LotTimelineKind, 'Event' when unlabelled. LOTs named TEST-SLH-%.
-- =============================================
EXEC test.BeginTestFile @FileName = N'0114_SuperLotVisibility/040_history.sql';
GO
-- ---- teardown (FK-safe) ----
DECLARE @TdLot TABLE (Id BIGINT PRIMARY KEY);
INSERT INTO @TdLot (Id) SELECT Id FROM Lots.Lot WHERE LotName LIKE N'TEST-SLH-%';
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM @TdLot);
DELETE FROM Audit.LogEventType WHERE Code = N'TestSlhUnflagged';
DELETE FROM Lots.LotMovement WHERE LotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM @TdLot) OR DescendantLotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.Lot WHERE Id IN (SELECT Id FROM @TdLot);
GO

DECLARE @App  BIGINT = (SELECT TOP 1 Id FROM Location.AppUser WHERE Initials = N'SYS');
DECLARE @Item BIGINT = (SELECT TOP 1 Id FROM Parts.Item WHERE DeprecatedAt IS NULL ORDER BY Id);
DECLARE @Term BIGINT = (SELECT TOP 1 l.Id FROM Location.Location l
    JOIN Location.LocationTypeDefinition d ON d.Id = l.LocationTypeDefinitionId
    WHERE d.Code = N'Terminal' AND l.DeprecatedAt IS NULL AND l.ParentLocationId IS NOT NULL ORDER BY l.Id);
DECLARE @Line BIGINT = (SELECT ParentLocationId FROM Location.Location WHERE Id = @Term);
DECLARE @MoveTo BIGINT = (SELECT TOP 1 Id FROM Location.Location WHERE DeprecatedAt IS NULL AND Id <> @Line ORDER BY Id);
DECLARE @n NVARCHAR(600);
DECLARE @s TABLE (Status BIT, Message NVARCHAR(500));
DECLARE @H TABLE (EventAt DATETIME2(3), EventKind NVARCHAR(20), Detail NVARCHAR(500), ByUserId BIGINT, ByUserName NVARCHAR(200));

INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId, CreatedAtTerminalId, CrtActive)
VALUES (N'TEST-SLH-A', @Item, 1, 1, 10, 10, @Line, @App, @Term, 0),
       (N'TEST-SLH-PLAIN', @Item, 1, 1, 10, 10, @Line, @App, @Term, 0);
DECLARE @A BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'TEST-SLH-A');
DECLARE @P BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'TEST-SLH-PLAIN');
SET @n = CASE WHEN @App IS NOT NULL AND @Item IS NOT NULL AND @Line IS NOT NULL AND @MoveTo IS NOT NULL AND @A IS NOT NULL THEN N'ok' ELSE N'missing' END;
EXEC test.Assert_IsEqual @TestName = N'[History] fixture: user, item, line, destination, LOTs', @Expected = N'ok', @Actual = @n;

-- ---- audit rows on LOT A: super-lot, CRT, an unflagged unlabelled type ----
INSERT INTO Audit.LogEventType (Id, Code, Name, Description)
VALUES ((SELECT ISNULL(MAX(Id), 0) + 1000 FROM Audit.LogEventType), N'TestSlhUnflagged', N'Test unflagged', N'throwaway for 040_history');

EXEC Audit.Audit_LogOperation @AppUserId = @App, @TerminalLocationId = @Term, @LocationId = NULL,
    @LogEntityTypeCode = N'Lot', @EntityId = @A, @LogEventTypeCode = N'ControlledRunLotJoined',
    @LogSeverityCode = N'Info', @Description = N'TEST-SLH-A - Super-lot X - Joined (Selected)', @OldValue = NULL, @NewValue = NULL;
EXEC Audit.Audit_LogOperation @AppUserId = @App, @TerminalLocationId = @Term, @LocationId = NULL,
    @LogEntityTypeCode = N'Lot', @EntityId = @A, @LogEventTypeCode = N'CrtActivated',
    @LogSeverityCode = N'Info', @Description = N'TEST-SLH-A - CRT - Activated', @OldValue = NULL, @NewValue = NULL;
EXEC Audit.Audit_LogOperation @AppUserId = @App, @TerminalLocationId = @Term, @LocationId = NULL,
    @LogEntityTypeCode = N'Lot', @EntityId = @A, @LogEventTypeCode = N'TestSlhUnflagged',
    @LogSeverityCode = N'Info', @Description = N'TEST-SLH-A - something new', @OldValue = NULL, @NewValue = NULL;

INSERT INTO @H EXEC Lots.Lot_GetAttributeHistory @LotId = @A;
SET @n = (SELECT CONCAT(COUNT(*), N'|', MIN(Detail)) FROM @H WHERE EventKind = N'Super-lot');
EXEC test.Assert_IsEqual @TestName = N'[History] super-lot rows appear with kind Super-lot',
    @Expected = N'1|TEST-SLH-A - Super-lot X - Joined (Selected)', @Actual = @n;
SET @n = (SELECT CONCAT(COUNT(*), N'|', MIN(Detail)) FROM @H WHERE EventKind = N'CRT');
EXEC test.Assert_IsEqual @TestName = N'[History] CrtActivated appears with kind CRT',
    @Expected = N'1|TEST-SLH-A - CRT - Activated', @Actual = @n;
SET @n = (SELECT CONCAT(COUNT(*), N'|', MIN(Detail)) FROM @H WHERE EventKind = N'Event');
EXEC test.Assert_IsEqual @TestName = N'[History] unflagged unlabelled code shows as Event',
    @Expected = N'1|TEST-SLH-A - something new', @Actual = @n;

-- ---- times are Eastern ----
DECLARE @Logged DATETIME2(3) = (SELECT TOP 1 l.LoggedAt FROM Lots.LotEventLog l
    JOIN Audit.LogEventType et ON et.Id = l.LogEventTypeId WHERE l.LotId = @A AND et.Code = N'ControlledRunLotJoined');
DECLARE @Exp DATETIME2(3) = CAST(@Logged AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3));
DECLARE @Got DATETIME2(3) = (SELECT EventAt FROM @H WHERE EventKind = N'Super-lot');
SET @n = CASE WHEN @Got = @Exp THEN N'ok' ELSE CONCAT(CONVERT(NVARCHAR(30), @Got, 121), N' vs ', CONVERT(NVARCHAR(30), @Exp, 121)) END;
EXEC test.Assert_IsEqual @TestName = N'[History] times are Eastern', @Expected = N'ok', @Actual = @n;
DELETE FROM @H;

-- ---- a user-less audit row still shows (LEFT join) ----
UPDATE Lots.LotEventLog SET UserId = NULL WHERE LotId = @A AND LogEventTypeId = (SELECT Id FROM Audit.LogEventType WHERE Code = N'TestSlhUnflagged');
INSERT INTO @H EXEC Lots.Lot_GetAttributeHistory @LotId = @A;
SET @n = (SELECT CONCAT(COUNT(*), N'|', COUNT(ByUserId)) FROM @H WHERE EventKind = N'Event');
EXEC test.Assert_IsEqual @TestName = N'[History] audit row with no user still shows', @Expected = N'1|0', @Actual = @n;
DELETE FROM @H;

-- ---- LotMoved is not repeated: the Movement record row is the only row ----
INSERT INTO @s EXEC Lots.Lot_MoveTo @LotId = @P, @ToLocationId = @MoveTo, @AppUserId = @App;
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) FROM @s);
EXEC test.Assert_IsEqual @TestName = N'[History] fixture: LOT moved', @Expected = N'1', @Actual = @n;
DELETE FROM @s;
SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Lots.LotEventLog l JOIN Audit.LogEventType et ON et.Id = l.LogEventTypeId
          WHERE l.LotId = @P AND et.Code = N'LotMoved');
EXEC test.Assert_IsEqual @TestName = N'[History] fixture: the move also wrote a LotMoved audit row', @Expected = N'1', @Actual = @n;
DECLARE @MoveCode NVARCHAR(50) = (SELECT Code FROM Location.Location WHERE Id = @MoveTo);
INSERT INTO @H EXEC Lots.Lot_GetAttributeHistory @LotId = @P;
SET @n = (SELECT CONCAT(SUM(CASE WHEN EventKind = N'Movement' AND Detail LIKE N'%' + @MoveCode + N')%' THEN 1 ELSE 0 END), N'|',
                        SUM(CASE WHEN EventKind = N'Event' THEN 1 ELSE 0 END)) FROM @H);
EXEC test.Assert_IsEqual @TestName = N'[History] LotMoved does not appear twice', @Expected = N'1|0', @Actual = @n;

-- ---- never in a super-lot: no Super-lot / CRT rows ----
SET @n = (SELECT CONCAT(SUM(CASE WHEN EventKind IN (N'Super-lot', N'CRT', N'Vendor return', N'Rework') THEN 1 ELSE 0 END), N'|',
                        SUM(CASE WHEN EventKind = N'Movement' THEN 1 ELSE 0 END)) FROM @H);
EXEC test.Assert_IsEqual @TestName = N'[History] never-in-a-super-lot LOT: no Super-lot rows, record streams unchanged', @Expected = N'0|1', @Actual = @n;
GO

-- ---- teardown ----
DECLARE @TdLot TABLE (Id BIGINT PRIMARY KEY);
INSERT INTO @TdLot (Id) SELECT Id FROM Lots.Lot WHERE LotName LIKE N'TEST-SLH-%';
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM @TdLot);
DELETE FROM Audit.LogEventType WHERE Code = N'TestSlhUnflagged';
DELETE FROM Lots.LotMovement WHERE LotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM @TdLot) OR DescendantLotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.Lot WHERE Id IN (SELECT Id FROM @TdLot);
GO
EXEC test.EndTestFile;
GO
