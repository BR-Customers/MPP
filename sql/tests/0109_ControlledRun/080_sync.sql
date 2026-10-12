-- =============================================
-- File:        0109_ControlledRun/080_sync.sql
-- Author:      Blue Ridge Automation
-- Description: Rolling window: ControlledRun_SyncAutoJoin (+ SyncInternal) and ControlledRun_SetAutoJoin.
-- =============================================
EXEC test.BeginTestFile @FileName = N'0109_ControlledRun/080_sync.sql';
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

INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, CurrentLocationId, CreatedByUserId, CreatedAtTerminalId, CrtActive, CreatedAt)
VALUES (N'TEST-CR-A', @Item, 1, 1, 10, @Line, @App, @Term, 0, DATEADD(HOUR, -2, SYSUTCDATETIME()));
DECLARE @LotA BIGINT = SCOPE_IDENTITY();
INSERT INTO Lots.LotGenealogyClosure (AncestorLotId, DescendantLotId, Depth) VALUES (@LotA, @LotA, 0);

DECLARE @o TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
DECLARE @s TABLE (Status BIT, Message NVARCHAR(500));
DECLARE @j NVARCHAR(MAX) = (SELECT @LotA AS lotId FOR JSON PATH);
INSERT INTO @o EXEC Quality.ControlledRun_Open @Reason = N'sync test', @AnchorLotId = @LotA, @SelectionItemId = @Item,
    @SelectionLocationId = @Line, @IncludeDescendants = 1, @AutoJoinEnabled = 1, @MembersJson = @j, @AppUserId = @App;
DECLARE @Run BIGINT = (SELECT NewId FROM @o);
DECLARE @OpenedAt DATETIME2(3) = (SELECT OpenedAt FROM Quality.ControlledRun WHERE Id = @Run);

-- material that appears AFTER the super-lot opened
DECLARE @Ids TABLE (Name NVARCHAR(50) PRIMARY KEY, Id BIGINT);
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, CurrentLocationId, CreatedByUserId, CreatedAtTerminalId, CrtActive, CreatedAt)
OUTPUT inserted.LotName, inserted.Id INTO @Ids (Name, Id)
VALUES (N'TEST-CR-NEW',      @Item,  1, 1, 10, @Line, @App, @Term,      1, DATEADD(SECOND, 1, @OpenedAt)),
       (N'TEST-CR-NEWCLEAN', @Item,  1, 1, 10, @Line, @App, @Term,      0, DATEADD(SECOND, 1, @OpenedAt)),
       (N'TEST-CR-NEWOTHER', @Item,  1, 1, 10, @Line, @App, @TermOther, 1, DATEADD(SECOND, 1, @OpenedAt)),
       (N'TEST-CR-OLD',      @Item,  1, 1, 10, @Line, @App, @Term,      1, DATEADD(DAY, -1, @OpenedAt)),
       (N'TEST-CR-KID',      @Item2, 1, 1, 10, @Line, @App, @TermOther, 1, DATEADD(SECOND, 1, @OpenedAt)),
       (N'TEST-CR-KIDCLEAN', @Item2, 1, 1, 10, @Line, @App, @TermOther, 0, DATEADD(SECOND, 1, @OpenedAt));
DECLARE @LotNew BIGINT = (SELECT Id FROM @Ids WHERE Name = N'TEST-CR-NEW');
DECLARE @LotKid BIGINT = (SELECT Id FROM @Ids WHERE Name = N'TEST-CR-KID');
INSERT INTO Lots.LotGenealogyClosure (AncestorLotId, DescendantLotId, Depth)
SELECT @LotA, Id, 1 FROM @Ids WHERE Name IN (N'TEST-CR-KID', N'TEST-CR-KIDCLEAN');

-- ===== sync =====
INSERT INTO @s EXEC Quality.ControlledRun_SyncAutoJoin @Id = @Run, @AppUserId = @App;
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) + N'|' + Message FROM @s);
EXEC test.Assert_IsEqual @TestName = N'[Sync] picks up the tagged new mint and the tagged descendant', @Expected = N'1|2 added.', @Actual = @n;
SET @n = (SELECT jm.Code FROM Quality.ControlledRunMember m JOIN Quality.ControlledRunJoinMethod jm ON jm.Id = m.ControlledRunJoinMethodId WHERE m.LotId = @LotNew);
EXEC test.Assert_IsEqual @TestName = N'[Sync] new production joins as AutoJoined', @Expected = N'AutoJoined', @Actual = @n;
SET @n = (SELECT jm.Code FROM Quality.ControlledRunMember m JOIN Quality.ControlledRunJoinMethod jm ON jm.Id = m.ControlledRunJoinMethodId WHERE m.LotId = @LotKid);
EXEC test.Assert_IsEqual @TestName = N'[Sync] a CRT descendant of a member joins as Descendant', @Expected = N'Descendant', @Actual = @n;
SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(5)) FROM Quality.ControlledRunMember m JOIN Lots.Lot l ON l.Id = m.LotId
          WHERE l.LotName IN (N'TEST-CR-NEWCLEAN', N'TEST-CR-NEWOTHER', N'TEST-CR-OLD', N'TEST-CR-KIDCLEAN'));
EXEC test.Assert_IsEqual @TestName = N'[Sync] NOT joined: untagged mint, other line, minted before the open, untagged descendant', @Expected = N'0', @Actual = @n;

DELETE FROM @s;
INSERT INTO @s EXEC Quality.ControlledRun_SyncAutoJoin @Id = @Run, @AppUserId = @App;
SET @n = (SELECT Message + N'|' + CAST((SELECT COUNT(*) FROM Quality.ControlledRunMember WHERE ControlledRunId = @Run) AS NVARCHAR(5)) FROM @s);
EXEC test.Assert_IsEqual @TestName = N'[Sync] idempotent', @Expected = N'0 added.|3', @Actual = @n;

DELETE FROM @s;
INSERT INTO @s EXEC Quality.ControlledRun_SyncAutoJoin @Id = NULL, @AppUserId = @App;
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) FROM @s);
EXEC test.Assert_IsEqual @TestName = N'[Sync] @Id NULL sweeps every open super-lot', @Expected = N'1', @Actual = @n;

DELETE FROM @s;
INSERT INTO @s EXEC Quality.ControlledRun_SyncAutoJoin @Id = 999999999, @AppUserId = @App;
SET @n = (SELECT Message FROM @s);
EXEC test.Assert_IsEqual @TestName = N'[Sync] unknown super-lot', @Expected = N'Super-lot not found.', @Actual = @n;

-- ===== end the window: a final sync runs first =====
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, CurrentLocationId, CreatedByUserId, CreatedAtTerminalId, CrtActive, CreatedAt)
VALUES (N'TEST-CR-LASTMIN', @Item, 1, 1, 10, @Line, @App, @Term, 1, DATEADD(SECOND, 2, @OpenedAt));
DECLARE @LotLast BIGINT = SCOPE_IDENTITY();
DELETE FROM @s;
INSERT INTO @s EXEC Quality.ControlledRun_SetAutoJoin @Id = @Run, @Enabled = 0, @AppUserId = @App, @TerminalLocationId = @Term;
SET @n = (SELECT CAST(s.Status AS NVARCHAR(1)) + N'|' + CAST(r.AutoJoinEnabled AS NVARCHAR(1)) + N'|' + CASE WHEN r.AutoJoinEndedAt IS NOT NULL AND r.AutoJoinEndedByUserId = @App THEN N'stamped' ELSE N'not stamped' END
          FROM @s s, Quality.ControlledRun r WHERE r.Id = @Run);
EXEC test.Assert_IsEqual @TestName = N'[Window] End: flag off, ended-at and ended-by stamped', @Expected = N'1|0|stamped', @Actual = @n;
SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(5)) FROM Quality.ControlledRunMember WHERE LotId = @LotLast AND EndedAt IS NULL);
EXEC test.Assert_IsEqual @TestName = N'[Window] End runs a final sync: a last-minute mint is not left out', @Expected = N'1', @Actual = @n;
SET @n = (SELECT TOP 1 CASE WHEN ol.Description LIKE N'CR000001 % Window % Ended' THEN N'ok' ELSE ol.Description END
          FROM Audit.OperationLog ol JOIN Audit.LogEventType t ON t.Id = ol.LogEventTypeId
          WHERE t.Code = N'ControlledRunWindowChanged' AND ol.EntityId = @Run ORDER BY ol.Id DESC);
EXEC test.Assert_IsEqual @TestName = N'[Window] audit line: <run> . Window . Ended', @Expected = N'ok', @Actual = @n;

-- minted AFTER the window ended: tagged for another reason, must NOT join
DECLARE @EndedAt DATETIME2(3) = (SELECT AutoJoinEndedAt FROM Quality.ControlledRun WHERE Id = @Run);
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, CurrentLocationId, CreatedByUserId, CreatedAtTerminalId, CrtActive, CreatedAt)
VALUES (N'TEST-CR-LATE', @Item, 1, 1, 10, @Line, @App, @Term, 1, DATEADD(SECOND, 1, @EndedAt));
DECLARE @LotLate BIGINT = SCOPE_IDENTITY();
DELETE FROM @s;
INSERT INTO @s EXEC Quality.ControlledRun_SyncAutoJoin @Id = @Run, @AppUserId = @App;
SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(5)) FROM Quality.ControlledRunMember WHERE LotId = @LotLate);
EXEC test.Assert_IsEqual @TestName = N'[Window] a LOT minted after the window ended does not join', @Expected = N'0', @Actual = @n;
DECLARE @b BIT;
SELECT @b = CrtActive FROM Lots.ufn_CrtForMint(@Item, @Term, NULL);
SET @n = CAST(@b AS NVARCHAR(1));
EXEC test.Assert_IsEqual @TestName = N'[Window] ... and the mint resolver no longer tags the part', @Expected = N'0', @Actual = @n;

DELETE FROM @s;
INSERT INTO @s EXEC Quality.ControlledRun_SetAutoJoin @Id = @Run, @Enabled = 0, @AppUserId = @App;
SET @n = (SELECT Message FROM @s);
EXEC test.Assert_IsEqual @TestName = N'[Window] ending twice', @Expected = N'Automatic adding is already off.', @Actual = @n;

DELETE FROM @s;
INSERT INTO @s EXEC Quality.ControlledRun_SetAutoJoin @Id = @Run, @Enabled = 1, @AppUserId = @App;
SET @n = (SELECT CAST(s.Status AS NVARCHAR(1)) + N'|' + CAST(r.AutoJoinEnabled AS NVARCHAR(1)) + N'|' + CASE WHEN r.AutoJoinEndedAt IS NULL THEN N'cleared' ELSE N'kept' END
          FROM @s s, Quality.ControlledRun r WHERE r.Id = @Run);
EXEC test.Assert_IsEqual @TestName = N'[Window] Resume: flag on, ended-at cleared', @Expected = N'1|1|cleared', @Actual = @n;

-- ===== guards =====
DELETE FROM @o;
SET @j = (SELECT Id AS lotId FROM @Ids WHERE Name = N'TEST-CR-NEWCLEAN' FOR JSON PATH);
INSERT INTO @o EXEC Quality.ControlledRun_Open @Reason = N'no part', @MembersJson = @j, @AppUserId = @App;
DECLARE @Run2 BIGINT = (SELECT NewId FROM @o);
DELETE FROM @s;
INSERT INTO @s EXEC Quality.ControlledRun_SetAutoJoin @Id = @Run2, @Enabled = 1, @AppUserId = @App;
SET @n = (SELECT Message FROM @s);
EXEC test.Assert_IsEqual @TestName = N'[Window] cannot keep adding without a part', @Expected = N'Keep adding new production needs a part.', @Actual = @n;

UPDATE Quality.ControlledRun SET AutoJoinEnabled = 0, ControlledRunStatusId = 2, ClosedByUserId = @App, ClosedAt = SYSUTCDATETIME() WHERE Id = @Run;
DELETE FROM @s;
INSERT INTO @s EXEC Quality.ControlledRun_SetAutoJoin @Id = @Run, @Enabled = 1, @AppUserId = @App;
SET @n = (SELECT Message FROM @s);
EXEC test.Assert_IsEqual @TestName = N'[Window] a closed super-lot has no window', @Expected = N'Super-lot CR000001 is not open.', @Actual = @n;

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
