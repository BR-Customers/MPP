-- =============================================
-- File:        0109_ControlledRun/040_open.sql
-- Author:      Blue Ridge Automation
-- Description: Quality.ControlledRun_Open (+ ControlledRun_ApplyMembersInternal) -- bundled create, tag on join, all-or-nothing.
-- =============================================
EXEC test.BeginTestFile @FileName = N'0109_ControlledRun/040_open.sql';
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
       (N'TEST-CR-B',     @Item, 1, 1, 10, @Line, @App, @Term, 1),
       (N'TEST-CR-C',     @Item, 1, 1, 10, @Line, @App, @Term, 0),
       (N'TEST-CR-D',     @Item, 1, 1, 10, @Line, @App, @Term, 0),
       (N'TEST-CR-SCRAP', @Item, 1, 3,  0, @Line, @App, @Term, 0),
       (N'TEST-CR-FGO',   @Item, 1, 1,  6, @Line, @App, @Term, 0),
       (N'TEST-CR-FGD',   @Item, 1, 4,  6, @Line, @App, @Term, 0);
DECLARE @LotA BIGINT = (SELECT Id FROM @Ids WHERE Name = N'TEST-CR-A');
DECLARE @LotB BIGINT = (SELECT Id FROM @Ids WHERE Name = N'TEST-CR-B');
DECLARE @LotC BIGINT = (SELECT Id FROM @Ids WHERE Name = N'TEST-CR-C');
DECLARE @LotD BIGINT = (SELECT Id FROM @Ids WHERE Name = N'TEST-CR-D');
DECLARE @LotScrap BIGINT = (SELECT Id FROM @Ids WHERE Name = N'TEST-CR-SCRAP');
DECLARE @LotFgO BIGINT = (SELECT Id FROM @Ids WHERE Name = N'TEST-CR-FGO');
DECLARE @LotFgD BIGINT = (SELECT Id FROM @Ids WHERE Name = N'TEST-CR-FGD');

INSERT INTO Lots.Container (ItemId, ContainerConfigId, CurrentLocationId, ContainerStatusCodeId, CreatedByUserId) VALUES (@Item, @Cfg, @Line, 1 /*Open*/, @App);
DECLARE @ConOpen BIGINT = SCOPE_IDENTITY();
INSERT INTO Lots.ContainerTray (ContainerId, TrayPosition, FinishedGoodLotId) VALUES (@ConOpen, 1, @LotFgO);
INSERT INTO Lots.Container (ItemId, ContainerConfigId, CurrentLocationId, ContainerStatusCodeId, CreatedByUserId) VALUES (@Item, @Cfg, @Line, 2 /*Complete*/, @App);
DECLARE @ConDone BIGINT = SCOPE_IDENTITY();
INSERT INTO Lots.ContainerTray (ContainerId, TrayPosition, FinishedGoodLotId) VALUES (@ConDone, 1, @LotFgD);

DECLARE @o TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
DECLARE @j NVARCHAR(MAX) = (SELECT * FROM (VALUES (@LotA, NULL), (@LotB, NULL), (NULL, @ConOpen), (NULL, @ConDone)) v(lotId, containerId) FOR JSON PATH);
DECLARE @FromEt DATETIME2(3) = N'2026-07-01T08:00:00';   -- EDT: 12:00 UTC
DECLARE @FailBefore INT = (SELECT COUNT(*) FROM Audit.FailureLog WHERE ProcedureName = N'Quality.ControlledRun_Open');

-- ===== 1. the happy path =====
INSERT INTO @o EXEC Quality.ControlledRun_Open @Reason = N'  porosity at bore  ', @AnchorLotId = @LotA, @SelectionItemId = @Item,
    @SelectionLocationId = @Line, @SelectionFromAtEastern = @FromEt, @IncludeDescendants = 1, @MembersJson = @j,
    @AppUserId = @App, @TerminalLocationId = @Term;
DECLARE @Run BIGINT = (SELECT NewId FROM @o);
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) FROM @o);
EXEC test.Assert_IsEqual @TestName = N'[Open] Status 1', @Expected = N'1', @Actual = @n;
SET @n = (SELECT RunNumber + N'|' + Reason FROM Quality.ControlledRun WHERE Id = @Run);
EXEC test.Assert_IsEqual @TestName = N'[Open] first run number is CR000001, reason trimmed', @Expected = N'CR000001|porosity at bore', @Actual = @n;
SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Quality.ControlledRunMember WHERE ControlledRunId = @Run AND EndedAt IS NULL);
EXEC test.Assert_IsEqual @TestName = N'[Open] four open members', @Expected = N'4', @Actual = @n;
SET @n = (SELECT CAST(CrtActive AS NVARCHAR(1)) FROM Lots.Lot WHERE Id = @LotA);
EXEC test.Assert_IsEqual @TestName = N'[Open] joining tags a clean LOT (D5)', @Expected = N'1', @Actual = @n;
SET @n = (SELECT CAST(a.CrtSetByRun AS NVARCHAR(1)) + N'|' + CAST(b.CrtSetByRun AS NVARCHAR(1))
          FROM Quality.ControlledRunMember a, Quality.ControlledRunMember b WHERE a.LotId = @LotA AND b.LotId = @LotB);
EXEC test.Assert_IsEqual @TestName = N'[Open] CrtSetByRun = 1 for the LOT it tagged, 0 for one already tagged', @Expected = N'1|0', @Actual = @n;
SET @n = (SELECT CAST(CrtActive AS NVARCHAR(1)) FROM Lots.Lot WHERE Id = @LotFgO);
EXEC test.Assert_IsEqual @TestName = N'[Open] an open container: its tray LOT is tagged', @Expected = N'1', @Actual = @n;
SET @n = (SELECT CAST(l.CrtActive AS NVARCHAR(1)) + N'|' + CAST(m.CrtSetByRun AS NVARCHAR(1))
          FROM Lots.Lot l, Quality.ControlledRunMember m WHERE l.Id = @LotFgD AND m.ContainerId = @ConDone);
EXEC test.Assert_IsEqual @TestName = N'[Open] a completed container is a member but its Closed tray is NOT tagged in this piece', @Expected = N'0|0', @Actual = @n;
SET @n = (SELECT CAST(SUM(CASE WHEN lel.LotId = @LotA THEN 1 ELSE 0 END) AS NVARCHAR(5)) + N'|'
               + CAST(SUM(CASE WHEN lel.LotId = @LotFgO THEN 1 ELSE 0 END) AS NVARCHAR(5)) + N'|'
               + CAST(SUM(CASE WHEN lel.LotId = @LotB THEN 1 ELSE 0 END) AS NVARCHAR(5))
          FROM Lots.LotEventLog lel JOIN Audit.LogEventType t ON t.Id = lel.LogEventTypeId
          WHERE t.Code = N'CrtActivated' AND lel.LotId IN (@LotA, @LotB, @LotFgO));
EXEC test.Assert_IsEqual @TestName = N'[Open] one CrtActivated row per LOT tagged, none for the already-tagged', @Expected = N'1|1|0', @Actual = @n;
SET @n = (SELECT TOP 1 LEFT(ol.Description, 8) FROM Audit.OperationLog ol JOIN Audit.LogEventType t ON t.Id = ol.LogEventTypeId
          WHERE t.Code = N'ControlledRunOpened' AND ol.EntityId = @Run);
EXEC test.Assert_IsEqual @TestName = N'[Open] one ControlledRunOpened audit row, subject is the run number', @Expected = N'CR000001', @Actual = @n;
SET @n = (SELECT CAST(COUNT(DISTINCT jm.Code) AS NVARCHAR(5)) + N'|' + MAX(jm.Code) FROM Quality.ControlledRunMember m
          JOIN Quality.ControlledRunJoinMethod jm ON jm.Id = m.ControlledRunJoinMethodId WHERE m.ControlledRunId = @Run);
EXEC test.Assert_IsEqual @TestName = N'[Open] join method Selected', @Expected = N'1|Selected', @Actual = @n;
SET @n = (SELECT CONVERT(NVARCHAR(19), SelectionFromAt, 126) FROM Quality.ControlledRun WHERE Id = @Run);
EXEC test.Assert_IsEqual @TestName = N'[Open] Eastern from-time stored as UTC', @Expected = N'2026-07-01T12:00:00', @Actual = @n;

-- ===== 2. already in a run: refused, nothing burned =====
DELETE FROM @o;
SET @j = (SELECT @LotA AS lotId FOR JSON PATH);
INSERT INTO @o EXEC Quality.ControlledRun_Open @Reason = N'again', @MembersJson = @j, @AppUserId = @App;
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) + N'|' + CASE WHEN Message LIKE N'%TEST-CR-A (Already in CR000001)%' THEN N'named' ELSE Message END FROM @o);
EXEC test.Assert_IsEqual @TestName = N'[Open] a member already in an open super-lot is refused and named', @Expected = N'0|named', @Actual = @n;
SET @n = (SELECT CAST((SELECT COUNT(*) FROM Quality.ControlledRun) AS NVARCHAR(5)) + N'|' + CAST((SELECT LastValue FROM Lots.IdentifierSequence WHERE Code = N'ControlledRun') AS NVARCHAR(10)));
EXEC test.Assert_IsEqual @TestName = N'[Open] a refused open creates no run and burns no number', @Expected = N'1|1', @Actual = @n;

-- ===== 3. all-or-nothing =====
DELETE FROM @o;
SET @j = (SELECT * FROM (VALUES (@LotC), (@LotScrap)) v(lotId) FOR JSON PATH);
INSERT INTO @o EXEC Quality.ControlledRun_Open @Reason = N'mixed', @MembersJson = @j, @AppUserId = @App;
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) + N'|' + CASE WHEN Message LIKE N'%TEST-CR-SCRAP (Scrapped)%' THEN N'named' ELSE Message END FROM @o);
EXEC test.Assert_IsEqual @TestName = N'[Open] one ineligible member refuses the whole call', @Expected = N'0|named', @Actual = @n;
SET @n = (SELECT CAST(l.CrtActive AS NVARCHAR(1)) + N'|' + CAST((SELECT COUNT(*) FROM Quality.ControlledRunMember WHERE LotId = @LotC) AS NVARCHAR(5)) FROM Lots.Lot l WHERE l.Id = @LotC);
EXEC test.Assert_IsEqual @TestName = N'[Open] ... and the eligible one was neither added nor tagged', @Expected = N'0|0', @Actual = @n;

-- ===== 4. parameter rejections =====
DELETE FROM @o;
SET @j = (SELECT @LotC AS lotId FOR JSON PATH);
INSERT INTO @o EXEC Quality.ControlledRun_Open @Reason = N'   ', @MembersJson = @j, @AppUserId = @App;
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) FROM @o);
EXEC test.Assert_IsEqual @TestName = N'[Open] blank reason refused', @Expected = N'0', @Actual = @n;

DELETE FROM @o;
INSERT INTO @o EXEC Quality.ControlledRun_Open @Reason = N'empty', @MembersJson = NULL, @AppUserId = @App;
SET @n = (SELECT Message FROM @o);
EXEC test.Assert_IsEqual @TestName = N'[Open] no members and no window -> refused', @Expected = N'A super-lot needs at least one member.', @Actual = @n;

DELETE FROM @o;
INSERT INTO @o EXEC Quality.ControlledRun_Open @Reason = N'future only', @MembersJson = NULL, @AutoJoinEnabled = 1, @SelectionItemId = @Item2, @AppUserId = @App;
SET @n = (SELECT CAST(o.Status AS NVARCHAR(1)) + N'|' + CAST((SELECT COUNT(*) FROM Quality.ControlledRunMember WHERE ControlledRunId = o.NewId) AS NVARCHAR(5)) FROM @o o);
EXEC test.Assert_IsEqual @TestName = N'[Open] no members but keep-adding on -> an empty super-lot is legal', @Expected = N'1|0', @Actual = @n;

DELETE FROM @o;
INSERT INTO @o EXEC Quality.ControlledRun_Open @Reason = N'window, no part', @MembersJson = @j, @AutoJoinEnabled = 1, @AppUserId = @App;
SET @n = (SELECT Message FROM @o);
EXEC test.Assert_IsEqual @TestName = N'[Open] keep-adding without a part refused', @Expected = N'Keep adding new production needs a part.', @Actual = @n;

DELETE FROM @o;
INSERT INTO @o EXEC Quality.ControlledRun_Open @Reason = N'bad anchor', @AnchorLotId = 999999999, @MembersJson = @j, @AppUserId = @App;
SET @n = (SELECT Message FROM @o);
EXEC test.Assert_IsEqual @TestName = N'[Open] unknown suspect LOT refused', @Expected = N'Suspect LOT not found.', @Actual = @n;

SET @n = CAST((SELECT COUNT(*) FROM Audit.FailureLog WHERE ProcedureName = N'Quality.ControlledRun_Open') - @FailBefore AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[Open] every rejection wrote an Audit.FailureLog row (6)', @Expected = N'6', @Actual = @n;

-- ===== 5. the loser of a race gets a clean refusal =====
INSERT INTO Quality.ControlledRunMember (ControlledRunId, LotId, ControlledRunJoinMethodId, CrtSetByRun, AddedByUserId) VALUES (@Run, @LotD, 1, 0, @App);
DELETE FROM @o;
SET @j = (SELECT @LotD AS lotId FOR JSON PATH);
INSERT INTO @o EXEC Quality.ControlledRun_Open @Reason = N'race loser', @MembersJson = @j, @AppUserId = @App;
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) + N'|' + CASE WHEN Message LIKE N'Cannot open: TEST-CR-D (Already in %' THEN N'clean' ELSE Message END FROM @o);
EXEC test.Assert_IsEqual @TestName = N'[Open] a unit taken by another super-lot -> clean Status 0 naming it, not a raw error', @Expected = N'0|clean', @Actual = @n;
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
