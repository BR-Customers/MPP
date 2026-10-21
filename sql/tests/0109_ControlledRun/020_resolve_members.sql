-- =============================================
-- File:        0109_ControlledRun/020_resolve_members.sql
-- Author:      Blue Ridge Automation
-- Description: Quality.ufn_ControlledRunResolveMembers -- fold tray LOTs to their container (D3), describe, judge eligible.
-- =============================================
EXEC test.BeginTestFile @FileName = N'0109_ControlledRun/020_resolve_members.sql';
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

-- ---- fixture: one of every kind of candidate ----
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, CurrentLocationId, CreatedByUserId, CreatedAtTerminalId)
VALUES (N'TEST-CR-A', @Item, 1, 1 /*Good*/, 10, @Line, @App, @Term);
DECLARE @LotA BIGINT = SCOPE_IDENTITY();
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, CurrentLocationId, CreatedByUserId, CreatedAtTerminalId)
VALUES (N'TEST-CR-SCRAP', @Item, 1, 3 /*Scrap*/, 0, @Line, @App, @Term);
DECLARE @LotScrap BIGINT = SCOPE_IDENTITY();
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, CurrentLocationId, CreatedByUserId, CreatedAtTerminalId)
VALUES (N'TEST-CR-CLOSED', @Item, 1, 4 /*Closed*/, 0, @Line, @App, @Term);
DECLARE @LotClosed BIGINT = SCOPE_IDENTITY();
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, CurrentLocationId, CreatedByUserId, CreatedAtTerminalId)
VALUES (N'TEST-CR-FG1', @Item, 1, 4, 6, @Line, @App, @Term);
DECLARE @LotFg1 BIGINT = SCOPE_IDENTITY();
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, CurrentLocationId, CreatedByUserId, CreatedAtTerminalId)
VALUES (N'TEST-CR-FG2', @Item, 1, 4, 6, @Line, @App, @Term);
DECLARE @LotFg2 BIGINT = SCOPE_IDENTITY();
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, CurrentLocationId, CreatedByUserId, CreatedAtTerminalId)
VALUES (N'TEST-CR-FGS', @Item, 1, 4, 6, @Line, @App, @Term);
DECLARE @LotFgS BIGINT = SCOPE_IDENTITY();

INSERT INTO Lots.Container (ItemId, ContainerConfigId, CurrentLocationId, ContainerStatusCodeId, CreatedByUserId)
VALUES (@Item, @Cfg, @Line, 2 /*Complete*/, @App);
DECLARE @Con BIGINT = SCOPE_IDENTITY();
INSERT INTO Lots.ContainerTray (ContainerId, TrayPosition, FinishedGoodLotId) VALUES (@Con, 1, @LotFg1), (@Con, 2, @LotFg2);
INSERT INTO Lots.Container (ItemId, ContainerConfigId, CurrentLocationId, ContainerStatusCodeId, CreatedByUserId)
VALUES (@Item, @Cfg, @Line, 3 /*Shipped*/, @App);
DECLARE @ConShipped BIGINT = SCOPE_IDENTITY();
INSERT INTO Lots.ContainerTray (ContainerId, TrayPosition, FinishedGoodLotId) VALUES (@ConShipped, 1, @LotFgS);

DECLARE @j NVARCHAR(MAX) = (SELECT * FROM (VALUES (@LotA, NULL), (@LotScrap, NULL), (@LotClosed, NULL),
        (@LotFg1, NULL), (@LotFg2, NULL), (@LotFgS, NULL), (CAST(999999999 AS BIGINT), NULL), (NULL, @Con)) v(lotId, containerId)
    FOR JSON PATH);
DECLARE @r TABLE (LotId BIGINT, ContainerId BIGINT, Kind NVARCHAR(10), DisplayName NVARCHAR(60), ItemId BIGINT,
    CurrentLocationId BIGINT, StatusCode NVARCHAR(20), PieceCount INT, ProducedAt DATETIME2(3), CrtActive BIT, IneligibleReason NVARCHAR(100));
INSERT INTO @r SELECT * FROM Quality.ufn_ControlledRunResolveMembers(@j);


SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @r);
EXEC test.Assert_IsEqual @TestName = N'[Resolve] 8 inputs fold to 6 units (two trays + the container itself = one container)', @Expected = N'6', @Actual = @n;
SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @r WHERE ContainerId = @Con);
EXEC test.Assert_IsEqual @TestName = N'[Resolve] tray LOTs fold to their container exactly once', @Expected = N'1', @Actual = @n;
SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @r WHERE LotId IN (@LotFg1, @LotFg2, @LotFgS));
EXEC test.Assert_IsEqual @TestName = N'[Resolve] a tray LOT is never returned as a LOT', @Expected = N'0', @Actual = @n;
SET @n = (SELECT ISNULL(IneligibleReason, N'(eligible)') FROM @r WHERE LotId = @LotA);
EXEC test.Assert_IsEqual @TestName = N'[Resolve] Good LOT eligible', @Expected = N'(eligible)', @Actual = @n;
SET @n = (SELECT ISNULL(IneligibleReason, N'(eligible)') FROM @r WHERE ContainerId = @Con);
EXEC test.Assert_IsEqual @TestName = N'[Resolve] completed unshipped container eligible (spec 9.2)', @Expected = N'(eligible)', @Actual = @n;
SET @n = (SELECT IneligibleReason FROM @r WHERE LotId = @LotScrap);
EXEC test.Assert_IsEqual @TestName = N'[Resolve] scrapped', @Expected = N'Scrapped', @Actual = @n;
SET @n = (SELECT IneligibleReason FROM @r WHERE LotId = @LotClosed);
EXEC test.Assert_IsEqual @TestName = N'[Resolve] closed non-tray LOT', @Expected = N'Closed', @Actual = @n;
SET @n = (SELECT IneligibleReason FROM @r WHERE ContainerId = @ConShipped);
EXEC test.Assert_IsEqual @TestName = N'[Resolve] shipped container', @Expected = N'Already shipped', @Actual = @n;
SET @n = (SELECT IneligibleReason FROM @r WHERE LotId = 999999999);
EXEC test.Assert_IsEqual @TestName = N'[Resolve] unknown LOT', @Expected = N'LOT not found', @Actual = @n;

-- already in an open run
INSERT INTO Quality.ControlledRun (RunNumber, ControlledRunStatusId, Reason, OpenedByUserId) VALUES (N'CR000900', 1, N'resolve test', @App);
DECLARE @Run BIGINT = SCOPE_IDENTITY();
INSERT INTO Quality.ControlledRunMember (ControlledRunId, LotId, ControlledRunJoinMethodId, CrtSetByRun, AddedByUserId) VALUES (@Run, @LotA, 1, 0, @App);
SET @n = (SELECT IneligibleReason FROM Quality.ufn_ControlledRunResolveMembers((SELECT @LotA AS lotId FOR JSON PATH)));
EXEC test.Assert_IsEqual @TestName = N'[Resolve] already in an open super-lot names it', @Expected = N'Already in CR000900', @Actual = @n;

SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Quality.ufn_ControlledRunResolveMembers(NULL));
EXEC test.Assert_IsEqual @TestName = N'[Resolve] NULL json -> no rows, no error', @Expected = N'0', @Actual = @n;
SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Quality.ufn_ControlledRunResolveMembers(N'[{"lotId":"abc"},{}]'));
EXEC test.Assert_IsEqual @TestName = N'[Resolve] junk entries are ignored, not errors', @Expected = N'0', @Actual = @n;
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
