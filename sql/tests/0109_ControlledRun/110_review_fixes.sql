-- =============================================
-- File:        0109_ControlledRun/110_review_fixes.sql
-- Author:      Blue Ridge Automation
-- Description: Final-review fixes: the open/add race is all-or-nothing; a removed member is not re-added by sync; one window per part and place; cancel syncs before it counts.
-- =============================================
EXEC test.BeginTestFile @FileName = N'0109_ControlledRun/110_review_fixes.sql';
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
VALUES (N'TEST-CR-X',    @Item, 1, 1, 10, @Line, @App, @Term, 0, DATEADD(HOUR, -2, SYSUTCDATETIME())),
       (N'TEST-CR-Y',    @Item, 1, 1, 10, @Line, @App, @Term, 0, DATEADD(HOUR, -2, SYSUTCDATETIME())),
       (N'TEST-CR-SEED', @Item, 1, 1, 10, @Line, @App, @Term, 0, DATEADD(HOUR, -2, SYSUTCDATETIME())),
       (N'TEST-CR-A',    @Item, 1, 1, 10, @Line, @App, @Term, 0, DATEADD(HOUR, -2, SYSUTCDATETIME()));
DECLARE @LotX BIGINT = (SELECT Id FROM @Ids WHERE Name = N'TEST-CR-X');
DECLARE @LotY BIGINT = (SELECT Id FROM @Ids WHERE Name = N'TEST-CR-Y');
DECLARE @LotSeed BIGINT = (SELECT Id FROM @Ids WHERE Name = N'TEST-CR-SEED');
DECLARE @LotA BIGINT = (SELECT Id FROM @Ids WHERE Name = N'TEST-CR-A');

DECLARE @o TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
DECLARE @s TABLE (Status BIT, Message NVARCHAR(500));
DECLARE @j NVARCHAR(MAX);

-- =====================================================================================
-- 1. THE RACE. A competitor takes LOT X between this call's pre-transaction check and
--    its write. Simulated honestly with a trigger that fires INSIDE the opener's
--    transaction, right after its header row is inserted -- i.e. after every validation
--    has passed. (A trigger cannot see T-SQL variables, so the ids travel in a table.)
-- =====================================================================================
SET @j = (SELECT @LotSeed AS lotId FOR JSON PATH);
INSERT INTO @o EXEC Quality.ControlledRun_Open @Reason = N'the competitor', @MembersJson = @j, @AppUserId = @App;
DECLARE @Rival BIGINT = (SELECT NewId FROM @o);
DELETE FROM @o;

IF OBJECT_ID(N'test.CrRace', N'U') IS NOT NULL DROP TABLE test.CrRace;
CREATE TABLE test.CrRace (RivalRunId BIGINT NOT NULL, LotId BIGINT NOT NULL, AppUserId BIGINT NOT NULL, Armed BIT NOT NULL);
INSERT INTO test.CrRace (RivalRunId, LotId, AppUserId, Armed) VALUES (@Rival, @LotX, @App, 1);
EXEC(N'CREATE OR ALTER TRIGGER Quality.trg_test_CrRace ON Quality.ControlledRun AFTER INSERT AS
BEGIN
    SET NOCOUNT ON;
    INSERT INTO Quality.ControlledRunMember (ControlledRunId, LotId, ControlledRunJoinMethodId, CrtSetByRun, AddedByUserId)
    SELECT c.RivalRunId, c.LotId, 2, 0, c.AppUserId FROM test.CrRace c WHERE c.Armed = 1;
END');

DECLARE @RunsBefore INT = (SELECT COUNT(*) FROM Quality.ControlledRun);
DECLARE @SeqBefore BIGINT = (SELECT LastValue FROM Lots.IdentifierSequence WHERE Code = N'ControlledRun');
SET @j = (SELECT * FROM (VALUES (@LotX), (@LotY)) v(lotId) FOR JSON PATH);
BEGIN TRY
    -- Captured via INSERT-EXEC, so the proc's CATCH ROLLBACK surfaces here as an error
    -- (Msg 3915) instead of a status row. What matters is what is LEFT BEHIND.
    INSERT INTO @o EXEC Quality.ControlledRun_Open @Reason = N'the loser', @MembersJson = @j, @AppUserId = @App;
END TRY
BEGIN CATCH
END CATCH
EXEC(N'DROP TRIGGER Quality.trg_test_CrRace');
DROP TABLE test.CrRace;

SET @n = CAST((SELECT COUNT(*) FROM Quality.ControlledRun) - @RunsBefore AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[Race] the loser leaves NO super-lot behind (was: a short super-lot reported as a success)', @Expected = N'0', @Actual = @n;
SET @n = (SELECT CAST(SUM(CAST(CrtActive AS INT)) AS NVARCHAR(5)) FROM Lots.Lot WHERE Id IN (@LotX, @LotY));
EXEC test.Assert_IsEqual @TestName = N'[Race] ... and tags nothing, not even the unit nobody contested', @Expected = N'0', @Actual = @n;
SET @n = CAST((SELECT LastValue FROM Lots.IdentifierSequence WHERE Code = N'ControlledRun') - @SeqBefore AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[Race] ... and burns no run number', @Expected = N'0', @Actual = @n;
SET @n = CAST((SELECT COUNT(*) FROM Quality.ControlledRunMember WHERE LotId IN (@LotX, @LotY)) AS NVARCHAR(5));
EXEC test.Assert_IsEqual @TestName = N'[Race] ... and no membership rows', @Expected = N'0', @Actual = @n;

-- =====================================================================================
-- 2. A member Quality REMOVED must not come back on the next sync.
-- =====================================================================================
DELETE FROM @o;
SET @j = (SELECT @LotA AS lotId FOR JSON PATH);
INSERT INTO @o EXEC Quality.ControlledRun_Open @Reason = N'window', @SelectionItemId = @Item, @SelectionLocationId = @Line,
    @AutoJoinEnabled = 1, @MembersJson = @j, @AppUserId = @App;
DECLARE @Run BIGINT = (SELECT NewId FROM @o);
DECLARE @OpenedAt DATETIME2(3) = (SELECT OpenedAt FROM Quality.ControlledRun WHERE Id = @Run);
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, CurrentLocationId, CreatedByUserId, CreatedAtTerminalId, CrtActive, CreatedAt)
VALUES (N'TEST-CR-NEW', @Item, 1, 1, 10, @Line, @App, @Term, 1, DATEADD(SECOND, 1, @OpenedAt));
DECLARE @LotNew BIGINT = SCOPE_IDENTITY();
INSERT INTO @s EXEC Quality.ControlledRun_SyncAutoJoin @Id = @Run, @AppUserId = @App;
DECLARE @MemNew BIGINT = (SELECT Id FROM Quality.ControlledRunMember WHERE LotId = @LotNew AND EndedAt IS NULL);
DELETE FROM @s;
INSERT INTO @s EXEC Quality.ControlledRun_RemoveMember @MemberId = @MemNew, @Remarks = N'scanned in error', @AppUserId = @App;
DELETE FROM @s;
INSERT INTO @s EXEC Quality.ControlledRun_SyncAutoJoin @Id = @Run, @AppUserId = @App;
SET @n = (SELECT Message + N'|' + CAST((SELECT COUNT(*) FROM Quality.ControlledRunMember WHERE LotId = @LotNew AND EndedAt IS NULL) AS NVARCHAR(5)) FROM @s);
EXEC test.Assert_IsEqual @TestName = N'[Sync] a member that was REMOVED is not re-added by the next sync', @Expected = N'0 added.|0', @Actual = @n;

DELETE FROM @s;
SET @j = (SELECT @LotNew AS lotId FOR JSON PATH);
INSERT INTO @s EXEC Quality.ControlledRun_AddMembers @Id = @Run, @MembersJson = @j, @AppUserId = @App;
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) FROM @s);
EXEC test.Assert_IsEqual @TestName = N'[Sync] ... but a deliberate scan-in can still bring it back', @Expected = N'1', @Actual = @n;

-- =====================================================================================
-- 3. Only ONE open window may cover a part at a place.
-- =====================================================================================
DELETE FROM @o;
INSERT INTO @o EXEC Quality.ControlledRun_Open @Reason = N'second window, same line', @SelectionItemId = @Item,
    @SelectionLocationId = @Line, @AutoJoinEnabled = 1, @AppUserId = @App;
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) + N'|' + Message FROM @o);
DECLARE @ExpC NVARCHAR(500) = N'0|Super-lot ' + (SELECT RunNumber FROM Quality.ControlledRun WHERE Id = @Run)
    + N' is already adding new production of this part here. End its window first.';
EXEC test.Assert_IsEqual @TestName = N'[Window] a second window on the same part and line is refused, naming the first', @Expected = @ExpC, @Actual = @n;

DELETE FROM @o;
INSERT INTO @o EXEC Quality.ControlledRun_Open @Reason = N'second window, no line', @SelectionItemId = @Item, @AutoJoinEnabled = 1, @AppUserId = @App;
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) FROM @o);
EXEC test.Assert_IsEqual @TestName = N'[Window] ... also when the second names no line (it would cover the first)', @Expected = N'0', @Actual = @n;

DELETE FROM @o;
INSERT INTO @o EXEC Quality.ControlledRun_Open @Reason = N'second window, the terminal under the line', @SelectionItemId = @Item,
    @SelectionLocationId = @Term, @AutoJoinEnabled = 1, @AppUserId = @App;
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) FROM @o);
EXEC test.Assert_IsEqual @TestName = N'[Window] ... and when it names a location under the first', @Expected = N'0', @Actual = @n;

DELETE FROM @o;
INSERT INTO @o EXEC Quality.ControlledRun_Open @Reason = N'other part, same line', @SelectionItemId = @Item2,
    @SelectionLocationId = @Line, @AutoJoinEnabled = 1, @AppUserId = @App;
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) FROM @o);
EXEC test.Assert_IsEqual @TestName = N'[Window] a window on ANOTHER part at the same line is fine', @Expected = N'1', @Actual = @n;

DELETE FROM @o;
INSERT INTO @o EXEC Quality.ControlledRun_Open @Reason = N'same part, no window', @SelectionItemId = @Item, @SelectionLocationId = @Line,
    @MembersJson = N'[]', @AutoJoinEnabled = 0, @AppUserId = @App;
SET @n = (SELECT Message FROM @o);
EXEC test.Assert_IsEqual @TestName = N'[Window] the rule only concerns windows (a no-window open fails for its own reason)', @Expected = N'A super-lot needs at least one member.', @Actual = @n;

-- resume is held to the same rule
DELETE FROM @o;
SET @j = (SELECT @LotY AS lotId FOR JSON PATH);
INSERT INTO @o EXEC Quality.ControlledRun_Open @Reason = N'no window yet', @SelectionItemId = @Item, @SelectionLocationId = @Line, @MembersJson = @j, @AppUserId = @App;
DECLARE @Run3 BIGINT = (SELECT NewId FROM @o);
DELETE FROM @s;
INSERT INTO @s EXEC Quality.ControlledRun_SetAutoJoin @Id = @Run3, @Enabled = 1, @AppUserId = @App;
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) FROM @s);
EXEC test.Assert_IsEqual @TestName = N'[Window] switching a window ON is refused while another covers the part', @Expected = N'0', @Actual = @n;
DELETE FROM @s;
INSERT INTO @s EXEC Quality.ControlledRun_SetAutoJoin @Id = @Run, @Enabled = 0, @AppUserId = @App;
DELETE FROM @s;
INSERT INTO @s EXEC Quality.ControlledRun_SetAutoJoin @Id = @Run, @Enabled = 1, @AppUserId = @App;
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) FROM @s);
EXEC test.Assert_IsEqual @TestName = N'[Window] a super-lot does not conflict with itself on resume', @Expected = N'1', @Actual = @n;

-- =====================================================================================
-- 4. Sync skips a LOT that is already in ANOTHER open super-lot (spec section 11).
-- =====================================================================================
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, CurrentLocationId, CreatedByUserId, CreatedAtTerminalId, CrtActive, CreatedAt)
VALUES (N'TEST-CR-TAKEN', @Item, 1, 1, 10, @Line, @App, @Term, 1, DATEADD(SECOND, 2, @OpenedAt));
DECLARE @LotTaken BIGINT = SCOPE_IDENTITY();
DELETE FROM @s;
SET @j = (SELECT @LotTaken AS lotId FOR JSON PATH);
INSERT INTO @s EXEC Quality.ControlledRun_AddMembers @Id = @Run3, @MembersJson = @j, @AppUserId = @App;
DELETE FROM @s;
INSERT INTO @s EXEC Quality.ControlledRun_SyncAutoJoin @Id = @Run, @AppUserId = @App;
SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(5)) + N'|' + CAST(MAX(ControlledRunId) - @Run3 AS NVARCHAR(5)) FROM Quality.ControlledRunMember WHERE LotId = @LotTaken AND EndedAt IS NULL);
EXEC test.Assert_IsEqual @TestName = N'[Sync] a LOT already in another open super-lot stays there', @Expected = N'1|0', @Actual = @n;

-- =====================================================================================
-- 5. Cancel runs a final sync, so its "still tagged" count includes unlisted material.
-- =====================================================================================
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, CurrentLocationId, CreatedByUserId, CreatedAtTerminalId, CrtActive, CreatedAt)
VALUES (N'TEST-CR-UNLISTED', @Item, 1, 1, 10, @Line, @App, @Term, 1, DATEADD(SECOND, 3, @OpenedAt));
DECLARE @LotUnlisted BIGINT = SCOPE_IDENTITY();
DECLARE @Listed INT = (SELECT COUNT(*) FROM Quality.ufn_ControlledRunMemberState(@Run) WHERE EndedAt IS NULL AND CrtActive = 1);
DELETE FROM @s;
INSERT INTO @s EXEC Quality.ControlledRun_Cancel @Id = @Run, @Remarks = N'opened in error', @AppUserId = @App;
SET @n = (SELECT Message FROM @s);
DECLARE @ExpK NVARCHAR(500) = N'Super-lot ' + (SELECT RunNumber FROM Quality.ControlledRun WHERE Id = @Run) + N' cancelled. '
    + CAST(@Listed + 1 AS NVARCHAR(10)) + N' members are still CRT-tagged and must be cleared individually.';
EXEC test.Assert_IsEqual @TestName = N'[Cancel] the still-tagged count includes material the window tagged but no sync had listed', @Expected = @ExpK, @Actual = @n;
SET @n = (SELECT er.Code FROM Quality.ControlledRunMember m JOIN Quality.ControlledRunMemberEndReason er ON er.Id = m.ControlledRunMemberEndReasonId WHERE m.LotId = @LotUnlisted);
EXEC test.Assert_IsEqual @TestName = N'[Cancel] ... and that material is on the cancelled super-lot record, not stranded', @Expected = N'RunCancelled', @Actual = @n;

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
