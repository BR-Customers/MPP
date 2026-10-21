-- =============================================
-- File:        0109_ControlledRun/030_preview.sql
-- Author:      Blue Ridge Automation
-- Description: Quality.ControlledRun_PreviewSelection -- candidates by part / line / time / genealogy; read-only.
-- =============================================
EXEC test.BeginTestFile @FileName = N'0109_ControlledRun/030_preview.sql';
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

DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
DECLARE @Ids TABLE (Name NVARCHAR(50) PRIMARY KEY, Id BIGINT);
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, CurrentLocationId, CreatedByUserId, CreatedAtTerminalId, CreatedAt)
OUTPUT inserted.LotName, inserted.Id INTO @Ids (Name, Id)
VALUES (N'TEST-CR-ANCHOR',    @Item,  1, 1, 10, @Line, @App, @Term,      DATEADD(HOUR, -3, @Now)),
       (N'TEST-CR-IN',        @Item,  1, 1, 10, @Line, @App, @Term,      DATEADD(HOUR, -2, @Now)),
       (N'TEST-CR-EARLY',     @Item,  1, 1, 10, @Line, @App, @Term,      DATEADD(HOUR, -5, @Now)),
       (N'TEST-CR-OTHERLINE', @Item,  1, 1, 10, @Line, @App, @TermOther, DATEADD(HOUR, -2, @Now)),
       (N'TEST-CR-OTHERPART', @Item2, 1, 1, 10, @Line, @App, @Term,      DATEADD(HOUR, -2, @Now)),
       (N'TEST-CR-NOTERM',    @Item,  1, 1, 10, @Line, @App, NULL,       DATEADD(HOUR, -2, @Now)),
       (N'TEST-CR-CHILD',     @Item2, 1, 1, 10, @Line, @App, @TermOther, DATEADD(HOUR, -1, @Now)),
       (N'TEST-CR-GRAND',     @Item2, 1, 4,  6, @Line, @App, @TermOther, DATEADD(MINUTE, -30, @Now));
DECLARE @LotAnchor BIGINT = (SELECT Id FROM @Ids WHERE Name = N'TEST-CR-ANCHOR');
DECLARE @LotChild  BIGINT = (SELECT Id FROM @Ids WHERE Name = N'TEST-CR-CHILD');
DECLARE @LotGrand  BIGINT = (SELECT Id FROM @Ids WHERE Name = N'TEST-CR-GRAND');
DECLARE @LotIn     BIGINT = (SELECT Id FROM @Ids WHERE Name = N'TEST-CR-IN');

INSERT INTO Lots.Container (ItemId, ContainerConfigId, CurrentLocationId, ContainerStatusCodeId, CreatedByUserId, OpenedAt)
VALUES (@Item2, @Cfg, @Line, 2 /*Complete*/, @App, DATEADD(MINUTE, -30, @Now));
DECLARE @Con BIGINT = SCOPE_IDENTITY();
INSERT INTO Lots.ContainerTray (ContainerId, TrayPosition, FinishedGoodLotId) VALUES (@Con, 1, @LotGrand);

INSERT INTO Lots.LotGenealogyClosure (AncestorLotId, DescendantLotId, Depth) VALUES
    (@LotAnchor, @LotAnchor, 0), (@LotChild, @LotChild, 0), (@LotGrand, @LotGrand, 0),
    (@LotAnchor, @LotChild, 1), (@LotChild, @LotGrand, 1), (@LotAnchor, @LotGrand, 2);

DECLARE @p TABLE (Seq INT IDENTITY(1,1), Kind NVARCHAR(10), LotId BIGINT, ContainerId BIGINT, DisplayName NVARCHAR(60), PartNumber NVARCHAR(100),
    CurrentLocationName NVARCHAR(200), StatusCode NVARCHAR(20), PieceCount INT, ProducedAt DATETIME2(3), CrtActive BIT,
    FoundBy NVARCHAR(40), Eligible BIT, IneligibleReason NVARCHAR(100));
DECLARE @MembersBefore INT = (SELECT COUNT(*) FROM Quality.ControlledRunMember);

-- ===== A: part + line, window from the anchor, no genealogy =====
INSERT INTO @p (Kind, LotId, ContainerId, DisplayName, PartNumber, CurrentLocationName, StatusCode, PieceCount, ProducedAt, CrtActive, FoundBy, Eligible, IneligibleReason)
EXEC Quality.ControlledRun_PreviewSelection @AnchorLotId = @LotAnchor, @ItemId = @Item, @LocationId = @Line;

SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @p);
EXEC test.Assert_IsEqual @TestName = N'[Preview A] part + line + window from anchor -> anchor and IN only', @Expected = N'2', @Actual = @n;
SET @n = (SELECT FoundBy FROM @p WHERE DisplayName = N'TEST-CR-IN');
EXEC test.Assert_IsEqual @TestName = N'[Preview A] IN found by line + time', @Expected = N'Line + time', @Actual = @n;
SET @n = (SELECT FoundBy FROM @p WHERE DisplayName = N'TEST-CR-ANCHOR');
EXEC test.Assert_IsEqual @TestName = N'[Preview A] anchor found as suspect LOT', @Expected = N'Suspect LOT', @Actual = @n;
SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @p WHERE DisplayName IN (N'TEST-CR-EARLY', N'TEST-CR-OTHERLINE', N'TEST-CR-OTHERPART'));
EXEC test.Assert_IsEqual @TestName = N'[Preview A] excludes before-window, other line, other part', @Expected = N'0', @Actual = @n;
SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @p WHERE DisplayName = N'TEST-CR-NOTERM');
EXEC test.Assert_IsEqual @TestName = N'[Preview A] a LOT with no CreatedAtTerminalId is NOT matched by the line filter (pinned)', @Expected = N'0', @Actual = @n;
DECLARE @Exp NVARCHAR(30) = (SELECT CONVERT(NVARCHAR(30), CAST(CreatedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)), 121) FROM Lots.Lot WHERE Id = @LotAnchor);
SET @n = (SELECT CONVERT(NVARCHAR(30), ProducedAt, 121) FROM @p WHERE DisplayName = N'TEST-CR-ANCHOR');
EXEC test.Assert_IsEqual @TestName = N'[Preview A] ProducedAt is Eastern', @Expected = @Exp, @Actual = @n;
SET @n = (SELECT TOP 1 DisplayName FROM @p ORDER BY Seq);
EXEC test.Assert_IsEqual @TestName = N'[Preview A] oldest first', @Expected = N'TEST-CR-ANCHOR', @Actual = @n;

-- ===== B: genealogy only =====
DELETE FROM @p;
INSERT INTO @p (Kind, LotId, ContainerId, DisplayName, PartNumber, CurrentLocationName, StatusCode, PieceCount, ProducedAt, CrtActive, FoundBy, Eligible, IneligibleReason)
EXEC Quality.ControlledRun_PreviewSelection @AnchorLotId = @LotAnchor, @IncludeDescendants = 1;
SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @p);
EXEC test.Assert_IsEqual @TestName = N'[Preview B] genealogy -> anchor + child + the container of the grandchild', @Expected = N'3', @Actual = @n;
SET @n = (SELECT Kind + N'|' + FoundBy + N'|' + CAST(Eligible AS NVARCHAR(1)) FROM @p WHERE ContainerId = @Con);
EXEC test.Assert_IsEqual @TestName = N'[Preview B] depth-2 tray LOT appears as its container, eligible', @Expected = N'Container|Made from suspect LOT|1', @Actual = @n;
SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @p WHERE LotId = @LotGrand);
EXEC test.Assert_IsEqual @TestName = N'[Preview B] the tray LOT itself never appears as a LOT', @Expected = N'0', @Actual = @n;

-- ===== C: a part alone is "everything" -> nothing =====
DELETE FROM @p;
INSERT INTO @p (Kind, LotId, ContainerId, DisplayName, PartNumber, CurrentLocationName, StatusCode, PieceCount, ProducedAt, CrtActive, FoundBy, Eligible, IneligibleReason)
EXEC Quality.ControlledRun_PreviewSelection @ItemId = @Item;
SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @p);
EXEC test.Assert_IsEqual @TestName = N'[Preview C] part with no start and no anchor -> no rows', @Expected = N'0', @Actual = @n;

-- ===== D: explicit Eastern from-time, no line =====
DELETE FROM @p;
DECLARE @FromEt DATETIME2(3) = CAST(DATEADD(HOUR, -6, @Now) AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3));
INSERT INTO @p (Kind, LotId, ContainerId, DisplayName, PartNumber, CurrentLocationName, StatusCode, PieceCount, ProducedAt, CrtActive, FoundBy, Eligible, IneligibleReason)
EXEC Quality.ControlledRun_PreviewSelection @ItemId = @Item, @FromAtEastern = @FromEt;
SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @p WHERE DisplayName IN (N'TEST-CR-EARLY', N'TEST-CR-OTHERLINE', N'TEST-CR-NOTERM', N'TEST-CR-ANCHOR', N'TEST-CR-IN'));
EXEC test.Assert_IsEqual @TestName = N'[Preview D] Eastern from-time, no line -> all five of the part, incl. the no-terminal LOT', @Expected = N'5', @Actual = @n;
SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @p WHERE DisplayName = N'TEST-CR-OTHERPART');
EXEC test.Assert_IsEqual @TestName = N'[Preview D] still excludes the other part', @Expected = N'0', @Actual = @n;

-- ===== read-only =====
SET @n = CAST((SELECT COUNT(*) FROM Quality.ControlledRunMember) - @MembersBefore AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[Preview] writes no members', @Expected = N'0', @Actual = @n;
SET @n = (SELECT CAST(CrtActive AS NVARCHAR(1)) FROM Lots.Lot WHERE Id = @LotIn);
EXEC test.Assert_IsEqual @TestName = N'[Preview] tags nothing', @Expected = N'0', @Actual = @n;
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
