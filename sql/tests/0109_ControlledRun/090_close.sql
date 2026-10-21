-- =============================================
-- File:        0109_ControlledRun/090_close.sql
-- Author:      Blue Ridge Automation
-- Description: ControlledRun_Close / _Cancel -- close only when every member is cleared and the window has ended.
-- =============================================
EXEC test.BeginTestFile @FileName = N'0109_ControlledRun/090_close.sql';
GO

-- ---- teardown (FK-safe): everything this suite creates (LOT names start TEST-CR-) ----
DECLARE @TdCon TABLE (Id BIGINT);
INSERT INTO @TdCon (Id)
SELECT DISTINCT ContainerId FROM Lots.ContainerTray
WHERE FinishedGoodLotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'TEST-CR-%');
DELETE FROM Quality.ControlledRunLabel;
DELETE FROM Quality.ControlledRunMember;
DELETE FROM Quality.ControlledRun;
DELETE FROM Lots.ContainerTray WHERE ContainerId IN (SELECT Id FROM @TdCon);
DELETE FROM Lots.Container WHERE Id IN (SELECT Id FROM @TdCon);
DELETE FROM Lots.LotGenealogyClosure
WHERE AncestorLotId   IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'TEST-CR-%')
   OR DescendantLotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'TEST-CR-%');
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'TEST-CR-%');
DELETE FROM Lots.Lot WHERE LotName LIKE N'TEST-CR-%';
UPDATE Lots.IdentifierSequence SET LastValue = 0 WHERE Code = N'ControlledRun';
GO

DECLARE @App  BIGINT = (SELECT TOP 1 Id FROM Location.AppUser WHERE Initials = N'SYS');
DECLARE @Item BIGINT = (SELECT TOP 1 Id FROM Parts.Item WHERE DeprecatedAt IS NULL ORDER BY Id);
DECLARE @Item2 BIGINT = (SELECT TOP 1 Id FROM Parts.Item WHERE DeprecatedAt IS NULL AND Id <> @Item ORDER BY Id);
DECLARE @Term BIGINT = (SELECT TOP 1 l.Id FROM Location.Location l
    JOIN Location.LocationTypeDefinition d ON d.Id = l.LocationTypeDefinitionId
    WHERE d.Code = N'Terminal' AND l.DeprecatedAt IS NULL AND l.ParentLocationId IS NOT NULL ORDER BY l.Id);
DECLARE @Line BIGINT = (SELECT ParentLocationId FROM Location.Location WHERE Id = @Term);
DECLARE @TermOther BIGINT = (SELECT TOP 1 l.Id FROM Location.Location l
    JOIN Location.LocationTypeDefinition d ON d.Id = l.LocationTypeDefinitionId
    WHERE d.Code = N'Terminal' AND l.DeprecatedAt IS NULL AND l.ParentLocationId <> @Line ORDER BY l.Id);
DECLARE @Cfg BIGINT = ISNULL((SELECT TOP 1 Id FROM Parts.ContainerConfig WHERE ItemId = @Item), (SELECT TOP 1 Id FROM Parts.ContainerConfig));
DECLARE @n NVARCHAR(500);

DECLARE @OldCrt1 BIT = (SELECT CrtEnabled FROM Parts.Item WHERE Id = @Item);
UPDATE Parts.Item SET CrtEnabled = 0 WHERE Id = @Item;

DECLARE @Ids TABLE (Name NVARCHAR(50) PRIMARY KEY, Id BIGINT);
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, CurrentLocationId, CreatedByUserId, CreatedAtTerminalId, CrtActive, CreatedAt)
OUTPUT inserted.LotName, inserted.Id INTO @Ids (Name, Id)
VALUES (N'TEST-CR-A', @Item, 1, 1, 10, @Line, @App, @Term, 0, DATEADD(HOUR, -2, SYSUTCDATETIME())),
       (N'TEST-CR-B', @Item, 1, 1, 10, @Line, @App, @Term, 0, DATEADD(HOUR, -2, SYSUTCDATETIME())),
       (N'TEST-CR-C', @Item, 1, 1, 10, @Line, @App, @Term, 1, DATEADD(HOUR, -2, SYSUTCDATETIME())),
       (N'TEST-CR-K', @Item, 1, 1, 10, @Line, @App, @Term, 0, DATEADD(HOUR, -2, SYSUTCDATETIME())),
       (N'TEST-CR-L', @Item, 1, 1, 10, @Line, @App, @Term, 0, DATEADD(HOUR, -2, SYSUTCDATETIME()));
DECLARE @LotA BIGINT = (SELECT Id FROM @Ids WHERE Name = N'TEST-CR-A');
DECLARE @LotB BIGINT = (SELECT Id FROM @Ids WHERE Name = N'TEST-CR-B');
DECLARE @LotC BIGINT = (SELECT Id FROM @Ids WHERE Name = N'TEST-CR-C');
DECLARE @LotK BIGINT = (SELECT Id FROM @Ids WHERE Name = N'TEST-CR-K');
DECLARE @LotL BIGINT = (SELECT Id FROM @Ids WHERE Name = N'TEST-CR-L');

DECLARE @o TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
DECLARE @s TABLE (Status BIT, Message NVARCHAR(500));
DECLARE @j NVARCHAR(MAX) = (SELECT * FROM (VALUES (@LotA), (@LotB), (@LotC)) v(lotId) FOR JSON PATH);
INSERT INTO @o EXEC Quality.ControlledRun_Open @Reason = N'close test', @SelectionItemId = @Item, @SelectionLocationId = @Line,
    @AutoJoinEnabled = 1, @MembersJson = @j, @AppUserId = @App;
DECLARE @Run BIGINT = (SELECT NewId FROM @o);
UPDATE Lots.Lot SET CrtActive = 0 WHERE Id = @LotC;          -- C already cleared; A and B outstanding

-- ===== refused while the window is open =====
INSERT INTO @s EXEC Quality.ControlledRun_Close @Id = @Run, @AppUserId = @App;
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) + N'|' + Message FROM @s);
EXEC test.Assert_IsEqual @TestName = N'[Close] refused while the window is open', @Expected = N'0|End the window before closing.', @Actual = @n;

-- a tagged LOT minted in the window that no sync has listed yet; then the window is shut by a raw update (no final sync)
DECLARE @OpenedAt DATETIME2(3) = (SELECT OpenedAt FROM Quality.ControlledRun WHERE Id = @Run);
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, CurrentLocationId, CreatedByUserId, CreatedAtTerminalId, CrtActive, CreatedAt)
VALUES (N'TEST-CR-UNSYNCED', @Item, 1, 1, 10, @Line, @App, @Term, 1, DATEADD(SECOND, 1, @OpenedAt));
DECLARE @LotU BIGINT = SCOPE_IDENTITY();
UPDATE Quality.ControlledRun SET AutoJoinEnabled = 0, AutoJoinEndedAt = DATEADD(SECOND, 5, @OpenedAt), AutoJoinEndedByUserId = @App WHERE Id = @Run;

-- ===== refused while members are tagged; the final sync finds the unlisted one =====
DELETE FROM @s;
INSERT INTO @s EXEC Quality.ControlledRun_Close @Id = @Run, @AppUserId = @App;
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) + N'|' + Message FROM @s);
EXEC test.Assert_IsEqual @TestName = N'[Close] refused with members outstanding -- and the final sync counted the unlisted LOT (A, B, UNSYNCED of 4)', @Expected = N'0|3 of 4 members are still CRT-tagged.', @Actual = @n;
SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(5)) FROM Quality.ControlledRunMember WHERE LotId = @LotU AND EndedAt IS NULL);
EXEC test.Assert_IsEqual @TestName = N'[Close] the final sync made the unlisted LOT a member', @Expected = N'1', @Actual = @n;
SET @n = (SELECT sc.Code FROM Quality.ControlledRun r JOIN Quality.ControlledRunStatusCode sc ON sc.Id = r.ControlledRunStatusId WHERE r.Id = @Run);
EXEC test.Assert_IsEqual @TestName = N'[Close] a refused close leaves it Open', @Expected = N'Open', @Actual = @n;

-- ===== release through the REAL per-LOT path, then close =====
DECLARE @c TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @c EXEC Lots.Lot_ClearCrt @LotId = @LotA, @AppUserId = @App;
INSERT INTO @c EXEC Lots.Lot_ClearCrt @LotId = @LotB, @AppUserId = @App;
INSERT INTO @c EXEC Lots.Lot_ClearCrt @LotId = @LotU, @AppUserId = @App;
SET @n = (SELECT CAST(SUM(CAST(Status AS INT)) AS NVARCHAR(5)) FROM @c);
EXEC test.Assert_IsEqual @TestName = N'[Close] fixture: three members cleared with Lots.Lot_ClearCrt', @Expected = N'3', @Actual = @n;

DELETE FROM @s;
INSERT INTO @s EXEC Quality.ControlledRun_Close @Id = @Run, @Remarks = N'  all inspected  ', @AppUserId = @App, @TerminalLocationId = @Term;
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) + N'|' + Message FROM @s);
EXEC test.Assert_IsEqual @TestName = N'[Close] closes once every member is cleared', @Expected = N'1|Super-lot CR000001 closed.', @Actual = @n;
SET @n = (SELECT sc.Code + N'|' + r.CloseRemarks + N'|' + CASE WHEN r.ClosedAt IS NOT NULL AND r.ClosedByUserId = @App THEN N'stamped' ELSE N'no' END
          FROM Quality.ControlledRun r JOIN Quality.ControlledRunStatusCode sc ON sc.Id = r.ControlledRunStatusId WHERE r.Id = @Run);
EXEC test.Assert_IsEqual @TestName = N'[Close] status, trimmed remarks, who and when', @Expected = N'Closed|all inspected|stamped', @Actual = @n;
SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(5)) + N'|' + CAST(SUM(CASE WHEN m.EndedAt IS NOT NULL AND er.Code = N'RunClosed' THEN 1 ELSE 0 END) AS NVARCHAR(5))
          FROM Quality.ControlledRunMember m LEFT JOIN Quality.ControlledRunMemberEndReason er ON er.Id = m.ControlledRunMemberEndReasonId WHERE m.ControlledRunId = @Run);
EXEC test.Assert_IsEqual @TestName = N'[Close] every membership ended as RunClosed', @Expected = N'4|4', @Actual = @n;
SET @n = (SELECT TOP 1 CASE WHEN ol.Description LIKE N'CR000001 % Closed: all inspected' THEN N'ok' ELSE ol.Description END
          FROM Audit.OperationLog ol JOIN Audit.LogEventType t ON t.Id = ol.LogEventTypeId
          WHERE t.Code = N'ControlledRunClosed' AND ol.EntityId = @Run);
EXEC test.Assert_IsEqual @TestName = N'[Close] audit line', @Expected = N'ok', @Actual = @n;

DECLARE @G TABLE (Id BIGINT, RunNumber NVARCHAR(15), StatusCode NVARCHAR(20), Reason NVARCHAR(500), AnchorLotId BIGINT, AnchorLotName NVARCHAR(50),
    SelectionItemId BIGINT, PartNumber NVARCHAR(100), SelectionLocationId BIGINT, LocationName NVARCHAR(200), SelectionFromAt DATETIME2(3),
    SelectionToAt DATETIME2(3), IncludeDescendants BIT, AutoJoinEnabled BIT, AutoJoinEndedAt DATETIME2(3), OpenedByInitials NVARCHAR(20),
    OpenedAt DATETIME2(3), ClosedByInitials NVARCHAR(20), ClosedAt DATETIME2(3), CloseRemarks NVARCHAR(500), MemberCount INT, ClearedCount INT,
    PieceCount INT, CriteriaText NVARCHAR(400), CanClose BIT, CloseBlockedReason NVARCHAR(200));
INSERT INTO @G EXEC Quality.ControlledRun_Get @Id = @Run;
SET @n = (SELECT StatusCode + N'|' + CAST(MemberCount AS NVARCHAR(5)) + N'|' + CAST(ClearedCount AS NVARCHAR(5)) + N'|' + ClosedByInitials FROM @G);
EXEC test.Assert_IsEqual @TestName = N'[Close] a closed super-lot still reports what it held', @Expected = N'Closed|4|4|SYS', @Actual = @n;

DELETE FROM @s;
INSERT INTO @s EXEC Quality.ControlledRun_Close @Id = @Run, @AppUserId = @App;
SET @n = (SELECT Message FROM @s);
EXEC test.Assert_IsEqual @TestName = N'[Close] closing twice', @Expected = N'Super-lot CR000001 is not open.', @Actual = @n;

-- D4: a unit from a closed super-lot is free to join another
DELETE FROM @o;
SET @j = (SELECT * FROM (VALUES (@LotA), (@LotK), (@LotL)) v(lotId) FOR JSON PATH);
INSERT INTO @o EXEC Quality.ControlledRun_Open @Reason = N'second look', @SelectionItemId = @Item, @AutoJoinEnabled = 1, @MembersJson = @j, @AppUserId = @App;
DECLARE @Run2 BIGINT = (SELECT NewId FROM @o);
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) + N'|' + CAST((SELECT COUNT(*) FROM Quality.ControlledRunMember WHERE LotId = @LotA) AS NVARCHAR(5)) FROM @o);
EXEC test.Assert_IsEqual @TestName = N'[Close] a LOT from a closed super-lot can join a new one (2 membership rows)', @Expected = N'1|2', @Actual = @n;

-- ===== Cancel =====
DELETE FROM @s;
INSERT INTO @s EXEC Quality.ControlledRun_Cancel @Id = @Run2, @Remarks = NULL, @AppUserId = @App;
SET @n = (SELECT Message FROM @s);
EXEC test.Assert_IsEqual @TestName = N'[Cancel] a reason is required', @Expected = N'A reason is required to cancel a super-lot.', @Actual = @n;

DELETE FROM @s;
INSERT INTO @s EXEC Quality.ControlledRun_Cancel @Id = @Run2, @Remarks = N'opened against the wrong part', @AppUserId = @App;
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) + N'|' + Message FROM @s);
EXEC test.Assert_IsEqual @TestName = N'[Cancel] cancelled, and the message counts what is still tagged',
    @Expected = N'1|Super-lot CR000002 cancelled. 3 members are still CRT-tagged and must be cleared individually.', @Actual = @n;
SET @n = (SELECT sc.Code + N'|' + CAST(r.AutoJoinEnabled AS NVARCHAR(1)) + N'|' + CASE WHEN r.AutoJoinEndedAt IS NOT NULL THEN N'ended' ELSE N'no' END
          FROM Quality.ControlledRun r JOIN Quality.ControlledRunStatusCode sc ON sc.Id = r.ControlledRunStatusId WHERE r.Id = @Run2);
EXEC test.Assert_IsEqual @TestName = N'[Cancel] status Cancelled and the window forced off', @Expected = N'Cancelled|0|ended', @Actual = @n;
SET @n = (SELECT CAST(SUM(CASE WHEN er.Code = N'RunCancelled' THEN 1 ELSE 0 END) AS NVARCHAR(5)) + N'|'
               + CAST((SELECT SUM(CAST(CrtActive AS INT)) FROM Lots.Lot WHERE Id IN (@LotA, @LotK, @LotL)) AS NVARCHAR(5))
          FROM Quality.ControlledRunMember m JOIN Quality.ControlledRunMemberEndReason er ON er.Id = m.ControlledRunMemberEndReasonId WHERE m.ControlledRunId = @Run2);
EXEC test.Assert_IsEqual @TestName = N'[Cancel] memberships ended as RunCancelled; all three LOTs STILL tagged', @Expected = N'3|3', @Actual = @n;
DECLARE @b BIT;
SELECT @b = CrtActive FROM Lots.ufn_CrtForMint(@Item, @Term, NULL);
SET @n = CAST(@b AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName = N'[Cancel] the mint resolver stops tagging the part', @Expected = N'0', @Actual = @n;
SET @n = (SELECT TOP 1 CASE WHEN ol.Description LIKE N'CR000002 % Cancelled: opened against the wrong part' THEN N'ok' ELSE ol.Description END
          FROM Audit.OperationLog ol JOIN Audit.LogEventType t ON t.Id = ol.LogEventTypeId
          WHERE t.Code = N'ControlledRunCancelled' AND ol.EntityId = @Run2);
EXEC test.Assert_IsEqual @TestName = N'[Cancel] audit line', @Expected = N'ok', @Actual = @n;

DELETE FROM @s;
INSERT INTO @s EXEC Quality.ControlledRun_Cancel @Id = @Run, @Remarks = N'too late', @AppUserId = @App;
SET @n = (SELECT Message FROM @s);
EXEC test.Assert_IsEqual @TestName = N'[Cancel] a closed super-lot cannot be cancelled', @Expected = N'Super-lot CR000001 is not open.', @Actual = @n;

UPDATE Parts.Item SET CrtEnabled = @OldCrt1 WHERE Id = @Item;
GO

-- ---- teardown (FK-safe): everything this suite creates (LOT names start TEST-CR-) ----
DECLARE @TdCon TABLE (Id BIGINT);
INSERT INTO @TdCon (Id)
SELECT DISTINCT ContainerId FROM Lots.ContainerTray
WHERE FinishedGoodLotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'TEST-CR-%');
DELETE FROM Quality.ControlledRunLabel;
DELETE FROM Quality.ControlledRunMember;
DELETE FROM Quality.ControlledRun;
DELETE FROM Lots.ContainerTray WHERE ContainerId IN (SELECT Id FROM @TdCon);
DELETE FROM Lots.Container WHERE Id IN (SELECT Id FROM @TdCon);
DELETE FROM Lots.LotGenealogyClosure
WHERE AncestorLotId   IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'TEST-CR-%')
   OR DescendantLotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'TEST-CR-%');
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'TEST-CR-%');
DELETE FROM Lots.Lot WHERE LotName LIKE N'TEST-CR-%';
UPDATE Lots.IdentifierSequence SET LastValue = 0 WHERE Code = N'ControlledRun';
GO

EXEC test.EndTestFile;
GO
