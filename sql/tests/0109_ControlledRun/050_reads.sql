-- =============================================
-- File:        0109_ControlledRun/050_reads.sql
-- Author:      Blue Ridge Automation
-- Description: Super-lot read procs: List, Get, GetByNumber, ListMembers, GetOpenByMember.
-- =============================================
EXEC test.BeginTestFile @FileName = N'0109_ControlledRun/050_reads.sql';
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
VALUES (N'TEST-CR-A',   @Item, 1, 1, 10, @Line, @App, @Term, 0),
       (N'TEST-CR-B',   @Item, 1, 1, 20, @Line, @App, @Term, 0),
       (N'TEST-CR-X',   @Item, 1, 1, 10, @Line, @App, @Term, 0),
       (N'TEST-CR-Y',   @Item, 1, 1, 10, @Line, @App, @Term, 0),
       (N'TEST-CR-FGD', @Item, 1, 4,  6, @Line, @App, @Term, 0);
DECLARE @LotA BIGINT = (SELECT Id FROM @Ids WHERE Name = N'TEST-CR-A');
DECLARE @LotB BIGINT = (SELECT Id FROM @Ids WHERE Name = N'TEST-CR-B');
DECLARE @LotX BIGINT = (SELECT Id FROM @Ids WHERE Name = N'TEST-CR-X');
DECLARE @LotY BIGINT = (SELECT Id FROM @Ids WHERE Name = N'TEST-CR-Y');
DECLARE @LotFgD BIGINT = (SELECT Id FROM @Ids WHERE Name = N'TEST-CR-FGD');
INSERT INTO Lots.Container (ItemId, ContainerConfigId, CurrentLocationId, ContainerStatusCodeId, CreatedByUserId) VALUES (@Item, @Cfg, @Line, 2, @App);
DECLARE @Con BIGINT = SCOPE_IDENTITY();
INSERT INTO Lots.ContainerTray (ContainerId, TrayPosition, FinishedGoodLotId) VALUES (@Con, 1, @LotFgD);

DECLARE @o TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
DECLARE @j NVARCHAR(MAX) = (SELECT * FROM (VALUES (@LotA, NULL), (@LotB, NULL), (NULL, @Con)) v(lotId, containerId) FOR JSON PATH);
DECLARE @FromEt DATETIME2(3) = N'2026-07-01T08:00:00';
INSERT INTO @o EXEC Quality.ControlledRun_Open @Reason = N'reads test', @AnchorLotId = @LotA, @SelectionItemId = @Item,
    @SelectionLocationId = @Line, @SelectionFromAtEastern = @FromEt, @IncludeDescendants = 1, @MembersJson = @j, @AppUserId = @App;
DECLARE @Run BIGINT = (SELECT NewId FROM @o);
UPDATE Lots.Lot SET CrtActive = 0 WHERE Id = @LotB;      -- B is "cleared"

DELETE FROM @o;
SET @j = (SELECT @LotX AS lotId FOR JSON PATH);
INSERT INTO @o EXEC Quality.ControlledRun_Open @Reason = N'hand picked one', @MembersJson = @j, @AppUserId = @App;
DECLARE @Run2 BIGINT = (SELECT NewId FROM @o);

DECLARE @L TABLE (Seq INT IDENTITY(1,1), Id BIGINT, RunNumber NVARCHAR(15), StatusCode NVARCHAR(20), Reason NVARCHAR(500), PartNumber NVARCHAR(100),
    LocationName NVARCHAR(200), OpenedAt DATETIME2(3), ClosedAt DATETIME2(3), MemberCount INT, ClearedCount INT, WindowOpen BIT);
DECLARE @G TABLE (Id BIGINT, RunNumber NVARCHAR(15), StatusCode NVARCHAR(20), Reason NVARCHAR(500), AnchorLotId BIGINT, AnchorLotName NVARCHAR(50),
    SelectionItemId BIGINT, PartNumber NVARCHAR(100), SelectionLocationId BIGINT, LocationName NVARCHAR(200), SelectionFromAt DATETIME2(3),
    SelectionToAt DATETIME2(3), IncludeDescendants BIT, AutoJoinEnabled BIT, AutoJoinEndedAt DATETIME2(3), OpenedByInitials NVARCHAR(20),
    OpenedAt DATETIME2(3), ClosedByInitials NVARCHAR(20), ClosedAt DATETIME2(3), CloseRemarks NVARCHAR(500), MemberCount INT, ClearedCount INT,
    PieceCount INT, CriteriaText NVARCHAR(400), CanClose BIT, CloseBlockedReason NVARCHAR(200));
DECLARE @M TABLE (MemberId BIGINT, Kind NVARCHAR(10), LotId BIGINT, ContainerId BIGINT, DisplayName NVARCHAR(60), PartNumber NVARCHAR(100),
    CurrentLocationName NVARCHAR(200), PieceCount INT, CrtActive BIT, JoinMethodName NVARCHAR(100), AddedAt DATETIME2(3), EndedAt DATETIME2(3), EndReasonName NVARCHAR(100),
    WasCompleteAtJoin BIT);
DECLARE @B TABLE (Id BIGINT, RunNumber NVARCHAR(15));

-- ===== List =====
INSERT INTO @L (Id, RunNumber, StatusCode, Reason, PartNumber, LocationName, OpenedAt, ClosedAt, MemberCount, ClearedCount, WindowOpen)
EXEC Quality.ControlledRun_List;
SET @n = (SELECT CAST(MemberCount AS NVARCHAR(5)) + N'|' + CAST(ClearedCount AS NVARCHAR(5)) + N'|' + CAST(WindowOpen AS NVARCHAR(1)) FROM @L WHERE Id = @Run);
EXEC test.Assert_IsEqual @TestName = N'[List] default = open runs; 3 members, 1 cleared (B; the completed container is tagged since piece 2)', @Expected = N'3|1|0', @Actual = @n;
SET @n = (SELECT TOP 1 RunNumber FROM @L ORDER BY Seq);
EXEC test.Assert_IsEqual @TestName = N'[List] open runs oldest first', @Expected = N'CR000001', @Actual = @n;
DELETE FROM @L;
INSERT INTO @L (Id, RunNumber, StatusCode, Reason, PartNumber, LocationName, OpenedAt, ClosedAt, MemberCount, ClearedCount, WindowOpen)
EXEC Quality.ControlledRun_List @StatusCode = N'Closed';
SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(5)) FROM @L);
EXEC test.Assert_IsEqual @TestName = N'[List] Closed filter -> none', @Expected = N'0', @Actual = @n;
DELETE FROM @L;
INSERT INTO @L (Id, RunNumber, StatusCode, Reason, PartNumber, LocationName, OpenedAt, ClosedAt, MemberCount, ClearedCount, WindowOpen)
EXEC Quality.ControlledRun_List @StatusCode = N'All', @Text = N'hand picked';
SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(5)) + N'|' + MAX(RunNumber) FROM @L);
EXEC test.Assert_IsEqual @TestName = N'[List] text matches the reason', @Expected = N'1|CR000002', @Actual = @n;
DELETE FROM @L;
INSERT INTO @L (Id, RunNumber, StatusCode, Reason, PartNumber, LocationName, OpenedAt, ClosedAt, MemberCount, ClearedCount, WindowOpen)
EXEC Quality.ControlledRun_List @StatusCode = N'All', @Text = N'zzz-no-such';
SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(5)) FROM @L);
EXEC test.Assert_IsEqual @TestName = N'[List] text with no match -> none', @Expected = N'0', @Actual = @n;

-- ===== Get / GetByNumber =====
INSERT INTO @G EXEC Quality.ControlledRun_Get @Id = @Run;
SET @n = (SELECT StatusCode + N'|' + OpenedByInitials + N'|' + AnchorLotName + N'|' + CAST(MemberCount AS NVARCHAR(5)) + N'|' + CAST(ClearedCount AS NVARCHAR(5)) + N'|' + CAST(PieceCount AS NVARCHAR(10)) FROM @G);
EXEC test.Assert_IsEqual @TestName = N'[Get] header, who opened it, totals (10 + 20 + 6 pieces)', @Expected = N'Open|SYS|TEST-CR-A|3|1|36', @Actual = @n;
SET @n = (SELECT CONVERT(NVARCHAR(19), SelectionFromAt, 126) FROM @G);
EXEC test.Assert_IsEqual @TestName = N'[Get] SelectionFromAt comes back Eastern', @Expected = N'2026-07-01T08:00:00', @Actual = @n;
SET @n = (SELECT CASE WHEN CriteriaText LIKE (SELECT PartNumber FROM Parts.Item WHERE Id = @Item) + N' made on % since %, plus everything made from TEST-CR-A' THEN N'ok' ELSE CriteriaText END FROM @G);
EXEC test.Assert_IsEqual @TestName = N'[Get] CriteriaText reads as a sentence', @Expected = N'ok', @Actual = @n;
DELETE FROM @G;
INSERT INTO @G EXEC Quality.ControlledRun_Get @Id = @Run2;
SET @n = (SELECT CriteriaText FROM @G);
EXEC test.Assert_IsEqual @TestName = N'[Get] a run with no criteria is Hand-picked', @Expected = N'Hand-picked', @Actual = @n;
DELETE FROM @G;
INSERT INTO @G EXEC Quality.ControlledRun_Get @Id = 999999999;
SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(5)) FROM @G);
EXEC test.Assert_IsEqual @TestName = N'[Get] unknown id -> empty set', @Expected = N'0', @Actual = @n;
INSERT INTO @G EXEC Quality.ControlledRun_GetByNumber @RunNumber = N'CR000001';
SET @n = (SELECT CASE WHEN Id = @Run THEN N'same' ELSE N'different' END FROM @G);
EXEC test.Assert_IsEqual @TestName = N'[GetByNumber] resolves the run', @Expected = N'same', @Actual = @n;

-- ===== ListMembers =====
INSERT INTO @M EXEC Quality.ControlledRun_ListMembers @Id = @Run;
SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(5)) FROM @M);
EXEC test.Assert_IsEqual @TestName = N'[ListMembers] three members', @Expected = N'3', @Actual = @n;
SET @n = (SELECT Kind + N'|' + JoinMethodName + N'|' + CAST(PieceCount AS NVARCHAR(5)) + N'|' + CAST(CrtActive AS NVARCHAR(1)) FROM @M WHERE ContainerId = @Con);
EXEC test.Assert_IsEqual @TestName = N'[ListMembers] container row: kind, join method, tray pieces, tag state', @Expected = N'Container|Selected|6|1', @Actual = @n;
DECLARE @ExpEt NVARCHAR(30) = (SELECT CONVERT(NVARCHAR(30), CAST(AddedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)), 121)
                               FROM Quality.ControlledRunMember WHERE ControlledRunId = @Run AND LotId = @LotA);
SET @n = (SELECT CONVERT(NVARCHAR(30), AddedAt, 121) FROM @M WHERE LotId = @LotA);
EXEC test.Assert_IsEqual @TestName = N'[ListMembers] AddedAt is Eastern', @Expected = @ExpEt, @Actual = @n;

-- ===== GetOpenByMember =====
INSERT INTO @B EXEC Quality.ControlledRun_GetOpenByMember @LotId = @LotA;
SET @n = (SELECT RunNumber FROM @B);
EXEC test.Assert_IsEqual @TestName = N'[GetOpenByMember] a member LOT', @Expected = N'CR000001', @Actual = @n;
DELETE FROM @B;
INSERT INTO @B EXEC Quality.ControlledRun_GetOpenByMember @LotId = @LotFgD;
SET @n = (SELECT RunNumber FROM @B);
EXEC test.Assert_IsEqual @TestName = N'[GetOpenByMember] a tray LOT resolves through its container', @Expected = N'CR000001', @Actual = @n;
DELETE FROM @B;
INSERT INTO @B EXEC Quality.ControlledRun_GetOpenByMember @LotId = @LotY;
SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(5)) FROM @B);
EXEC test.Assert_IsEqual @TestName = N'[GetOpenByMember] a LOT in no super-lot -> empty set', @Expected = N'0', @Actual = @n;
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
