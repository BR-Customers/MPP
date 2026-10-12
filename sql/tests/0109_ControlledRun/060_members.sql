-- =============================================
-- File:        0109_ControlledRun/060_members.sql
-- Author:      Blue Ridge Automation
-- Description: ControlledRun_AddMembers / _RemoveMember -- fold on add, reason on remove, D6 remove never clears the tag.
-- =============================================
EXEC test.BeginTestFile @FileName = N'0109_ControlledRun/060_members.sql';
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

DECLARE @Ids TABLE (Name NVARCHAR(50) PRIMARY KEY, Id BIGINT);
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, CurrentLocationId, CreatedByUserId, CreatedAtTerminalId, CrtActive)
OUTPUT inserted.LotName, inserted.Id INTO @Ids (Name, Id)
VALUES (N'TEST-CR-A',     @Item, 1, 1, 10, @Line, @App, @Term, 0),
       (N'TEST-CR-NEW',   @Item, 1, 1, 10, @Line, @App, @Term, 0),
       (N'TEST-CR-Z',     @Item, 1, 1, 10, @Line, @App, @Term, 0),
       (N'TEST-CR-SCRAP', @Item, 1, 3,  0, @Line, @App, @Term, 0),
       (N'TEST-CR-FG1',   @Item, 1, 1,  6, @Line, @App, @Term, 0),
       (N'TEST-CR-FG2',   @Item, 1, 1,  6, @Line, @App, @Term, 0);
DECLARE @LotA BIGINT = (SELECT Id FROM @Ids WHERE Name = N'TEST-CR-A');
DECLARE @LotNew BIGINT = (SELECT Id FROM @Ids WHERE Name = N'TEST-CR-NEW');
DECLARE @LotZ BIGINT = (SELECT Id FROM @Ids WHERE Name = N'TEST-CR-Z');
DECLARE @LotScrap BIGINT = (SELECT Id FROM @Ids WHERE Name = N'TEST-CR-SCRAP');
DECLARE @LotFg1 BIGINT = (SELECT Id FROM @Ids WHERE Name = N'TEST-CR-FG1');
DECLARE @LotFg2 BIGINT = (SELECT Id FROM @Ids WHERE Name = N'TEST-CR-FG2');
INSERT INTO Lots.Container (ItemId, ContainerConfigId, CurrentLocationId, ContainerStatusCodeId, CreatedByUserId) VALUES (@Item, @Cfg, @Line, 1 /*Open*/, @App);
DECLARE @Con BIGINT = SCOPE_IDENTITY();
INSERT INTO Lots.ContainerTray (ContainerId, TrayPosition, FinishedGoodLotId) VALUES (@Con, 1, @LotFg1), (@Con, 2, @LotFg2);

DECLARE @o TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
DECLARE @s TABLE (Status BIT, Message NVARCHAR(500));
DECLARE @j NVARCHAR(MAX) = (SELECT @LotA AS lotId FOR JSON PATH);
INSERT INTO @o EXEC Quality.ControlledRun_Open @Reason = N'members test', @MembersJson = @j, @AppUserId = @App;
DECLARE @Run BIGINT = (SELECT NewId FROM @o);

-- ===== Add =====
SET @j = (SELECT @LotNew AS lotId FOR JSON PATH);
INSERT INTO @s EXEC Quality.ControlledRun_AddMembers @Id = @Run, @MembersJson = @j, @AppUserId = @App, @TerminalLocationId = @Term;
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) + N'|' + Message FROM @s);
EXEC test.Assert_IsEqual @TestName = N'[Add] a Good LOT joins', @Expected = N'1|1 added to super-lot CR000001.', @Actual = @n;
SET @n = (SELECT jm.Code + N'|' + CAST(l.CrtActive AS NVARCHAR(1)) + N'|' + CAST(m.CrtSetByRun AS NVARCHAR(1))
          FROM Quality.ControlledRunMember m JOIN Quality.ControlledRunJoinMethod jm ON jm.Id = m.ControlledRunJoinMethodId
          JOIN Lots.Lot l ON l.Id = m.LotId WHERE m.LotId = @LotNew);
EXEC test.Assert_IsEqual @TestName = N'[Add] join method Manual, tag set by the run', @Expected = N'Manual|1|1', @Actual = @n;
SET @n = (SELECT TOP 1 CASE WHEN ol.Description LIKE N'CR000001 % Members % + TEST-CR-NEW' THEN N'ok' ELSE ol.Description END
          FROM Audit.OperationLog ol JOIN Audit.LogEventType t ON t.Id = ol.LogEventTypeId
          WHERE t.Code = N'ControlledRunMemberAdded' AND ol.EntityId = @Run ORDER BY ol.Id DESC);
EXEC test.Assert_IsEqual @TestName = N'[Add] audit line: <run> . Members . + <name>', @Expected = N'ok', @Actual = @n;

DELETE FROM @s;
SET @j = (SELECT * FROM (VALUES (@LotFg1), (@LotFg2)) v(lotId) FOR JSON PATH);
INSERT INTO @s EXEC Quality.ControlledRun_AddMembers @Id = @Run, @MembersJson = @j, @AppUserId = @App;
SET @n = (SELECT CAST((SELECT Status FROM @s) AS NVARCHAR(1)) + N'|'
               + CAST((SELECT COUNT(*) FROM Quality.ControlledRunMember WHERE ControlledRunId = @Run AND ContainerId = @Con) AS NVARCHAR(5)) + N'|'
               + CAST((SELECT COUNT(*) FROM Quality.ControlledRunMember WHERE LotId IN (@LotFg1, @LotFg2)) AS NVARCHAR(5)));
EXEC test.Assert_IsEqual @TestName = N'[Add] two tray LOTs of one container add the CONTAINER once, never the LOTs', @Expected = N'1|1|0', @Actual = @n;

DELETE FROM @s;
SET @j = (SELECT @LotNew AS lotId FOR JSON PATH);
INSERT INTO @s EXEC Quality.ControlledRun_AddMembers @Id = @Run, @MembersJson = @j, @AppUserId = @App;
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) + N'|' + Message FROM @s);
EXEC test.Assert_IsEqual @TestName = N'[Add] already a member -> refused and named', @Expected = N'0|Cannot add: TEST-CR-NEW (Already in CR000001)', @Actual = @n;

DELETE FROM @s;
SET @j = (SELECT * FROM (VALUES (@LotZ), (@LotScrap)) v(lotId) FOR JSON PATH);
INSERT INTO @s EXEC Quality.ControlledRun_AddMembers @Id = @Run, @MembersJson = @j, @AppUserId = @App;
SET @n = (SELECT CAST((SELECT Status FROM @s) AS NVARCHAR(1)) + N'|' + CAST((SELECT COUNT(*) FROM Quality.ControlledRunMember WHERE LotId = @LotZ) AS NVARCHAR(5)));
EXEC test.Assert_IsEqual @TestName = N'[Add] one scrapped unit refuses the call; the good one is not added', @Expected = N'0|0', @Actual = @n;

DELETE FROM @s;
INSERT INTO @s EXEC Quality.ControlledRun_AddMembers @Id = @Run, @MembersJson = N'[]', @AppUserId = @App;
SET @n = (SELECT Message FROM @s);
EXEC test.Assert_IsEqual @TestName = N'[Add] empty list', @Expected = N'Nothing to add.', @Actual = @n;

-- ===== Remove =====
DECLARE @MemNew BIGINT = (SELECT Id FROM Quality.ControlledRunMember WHERE LotId = @LotNew AND EndedAt IS NULL);
DELETE FROM @s;
INSERT INTO @s EXEC Quality.ControlledRun_RemoveMember @MemberId = @MemNew, @Remarks = N'  ', @AppUserId = @App;
SET @n = (SELECT Message FROM @s);
EXEC test.Assert_IsEqual @TestName = N'[Remove] a reason is required', @Expected = N'A reason is required to remove a member.', @Actual = @n;

DELETE FROM @s;
INSERT INTO @s EXEC Quality.ControlledRun_RemoveMember @MemberId = @MemNew, @Remarks = N'scanned in error', @AppUserId = @App, @TerminalLocationId = @Term;
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) + N'|' + CASE WHEN Message LIKE N'TEST-CR-NEW removed from super-lot CR000001.%still CRT-tagged%' THEN N'warned' ELSE Message END FROM @s);
EXEC test.Assert_IsEqual @TestName = N'[Remove] removed, and the message warns it is still tagged', @Expected = N'1|warned', @Actual = @n;
SET @n = (SELECT er.Code + N'|' + m.EndRemarks + N'|' + CASE WHEN m.EndedAt IS NOT NULL THEN N'ended' ELSE N'open' END
          FROM Quality.ControlledRunMember m JOIN Quality.ControlledRunMemberEndReason er ON er.Id = m.ControlledRunMemberEndReasonId WHERE m.Id = @MemNew);
EXEC test.Assert_IsEqual @TestName = N'[Remove] membership ended as Removed with the remarks, not deleted', @Expected = N'Removed|scanned in error|ended', @Actual = @n;
SET @n = (SELECT CAST(CrtActive AS NVARCHAR(1)) FROM Lots.Lot WHERE Id = @LotNew);
EXEC test.Assert_IsEqual @TestName = N'[Remove] D6: the LOT is STILL CRT-tagged', @Expected = N'1', @Actual = @n;
SET @n = (SELECT TOP 1 CASE WHEN ol.Description LIKE N'CR000001 % Members % - TEST-CR-NEW: scanned in error' THEN N'ok' ELSE ol.Description END
          FROM Audit.OperationLog ol JOIN Audit.LogEventType t ON t.Id = ol.LogEventTypeId
          WHERE t.Code = N'ControlledRunMemberRemoved' AND ol.EntityId = @Run ORDER BY ol.Id DESC);
EXEC test.Assert_IsEqual @TestName = N'[Remove] audit line: <run> . Members . - <name>: <reason>', @Expected = N'ok', @Actual = @n;

DELETE FROM @s;
INSERT INTO @s EXEC Quality.ControlledRun_RemoveMember @MemberId = @MemNew, @Remarks = N'again', @AppUserId = @App;
SET @n = (SELECT Message FROM @s);
EXEC test.Assert_IsEqual @TestName = N'[Remove] removing twice', @Expected = N'Member is no longer in the super-lot.', @Actual = @n;

DELETE FROM @s;
SET @j = (SELECT @LotNew AS lotId FOR JSON PATH);
INSERT INTO @s EXEC Quality.ControlledRun_AddMembers @Id = @Run, @MembersJson = @j, @AppUserId = @App;
SET @n = (SELECT CAST((SELECT Status FROM @s) AS NVARCHAR(1)) + N'|' + CAST((SELECT COUNT(*) FROM Quality.ControlledRunMember WHERE LotId = @LotNew) AS NVARCHAR(5))
               + N'|' + CAST((SELECT CrtSetByRun FROM Quality.ControlledRunMember WHERE LotId = @LotNew AND EndedAt IS NULL) AS NVARCHAR(1)));
EXEC test.Assert_IsEqual @TestName = N'[Add] a removed LOT can rejoin (2 rows, 1 open; tag was already set)', @Expected = N'1|2|0', @Actual = @n;

-- ===== not open =====
UPDATE Quality.ControlledRun SET ControlledRunStatusId = 2, ClosedByUserId = @App, ClosedAt = SYSUTCDATETIME() WHERE Id = @Run;
DELETE FROM @s;
SET @j = (SELECT @LotZ AS lotId FOR JSON PATH);
INSERT INTO @s EXEC Quality.ControlledRun_AddMembers @Id = @Run, @MembersJson = @j, @AppUserId = @App;
SET @n = (SELECT Message FROM @s);
EXEC test.Assert_IsEqual @TestName = N'[Add] a closed super-lot takes no members', @Expected = N'Super-lot CR000001 is not open.', @Actual = @n;
DECLARE @MemA BIGINT = (SELECT Id FROM Quality.ControlledRunMember WHERE LotId = @LotA AND EndedAt IS NULL);
DELETE FROM @s;
INSERT INTO @s EXEC Quality.ControlledRun_RemoveMember @MemberId = @MemA, @Remarks = N'late', @AppUserId = @App;
SET @n = (SELECT Message FROM @s);
EXEC test.Assert_IsEqual @TestName = N'[Remove] a closed super-lot loses no members', @Expected = N'Super-lot CR000001 is not open.', @Actual = @n;
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
