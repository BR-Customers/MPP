-- =============================================
-- File:         0119_ContainerAsLot/050_controlled_run.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-11-04
-- Description:  Container-as-LOT spec 7.3 + D9: super-lot readers on NEW-shape
--               containers. A container LOT is born at its FIRST tray, so a time
--               window reads the container's TRAYS (ClosedAt, ClosedAtTerminalId),
--               not Lot.CreatedAt. Also: a container LOT folds into its container
--               member, container pieces / CRT come from the container LOT, and
--               release clears it.
--               Containers (Item, line of @Term):
--                 MID   tray 1 two hours BEFORE the window opens, tray 2 after -> joins
--                 PRE   both trays before the window                          -> not joined
--                 OTHER trays after the window, on another line's terminal    -> not joined
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0119_ContainerAsLot/050_controlled_run.sql';
GO

DECLARE @App  BIGINT = (SELECT TOP 1 Id FROM Location.AppUser WHERE Initials = N'SYS');
DECLARE @Item BIGINT = (SELECT TOP 1 Id FROM Parts.Item WHERE DeprecatedAt IS NULL ORDER BY Id DESC);
DECLARE @Term BIGINT = (SELECT TOP 1 l.Id FROM Location.Location l
    JOIN Location.LocationTypeDefinition d ON d.Id = l.LocationTypeDefinitionId
    WHERE d.Code = N'Terminal' AND l.DeprecatedAt IS NULL AND l.ParentLocationId IS NOT NULL ORDER BY l.Id);
DECLARE @Line BIGINT = (SELECT ParentLocationId FROM Location.Location WHERE Id = @Term);
DECLARE @TermOther BIGINT = (SELECT TOP 1 l.Id FROM Location.Location l
    JOIN Location.LocationTypeDefinition d ON d.Id = l.LocationTypeDefinitionId
    WHERE d.Code = N'Terminal' AND l.DeprecatedAt IS NULL AND l.ParentLocationId <> @Line ORDER BY l.Id);
DECLARE @Cfg BIGINT = (SELECT TOP 1 Id FROM Parts.ContainerConfig ORDER BY Id);
UPDATE Parts.Item SET CrtEnabled = 0 WHERE Id = @Item;

-- open the super-lot (anchor = a throwaway LOT of the part), window open now
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, CurrentLocationId, CreatedByUserId, CreatedAtTerminalId, CrtActive, CreatedAt)
VALUES (N'T118-050-ANCHOR', @Item, 1, 1, 10, @Line, @App, @Term, 0, DATEADD(HOUR, -5, SYSUTCDATETIME()));
DECLARE @Anchor BIGINT = SCOPE_IDENTITY();
INSERT INTO Lots.LotGenealogyClosure (AncestorLotId, DescendantLotId, Depth) VALUES (@Anchor, @Anchor, 0);
DECLARE @o TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
DECLARE @j NVARCHAR(MAX) = (SELECT @Anchor AS lotId FOR JSON PATH);
INSERT INTO @o EXEC Quality.ControlledRun_Open @Reason = N'0119 050', @AnchorLotId = @Anchor, @SelectionItemId = @Item,
    @SelectionLocationId = @Line, @IncludeDescendants = 0, @AutoJoinEnabled = 1, @MembersJson = @j, @AppUserId = @App;
DECLARE @Run BIGINT = (SELECT NewId FROM @o);
DECLARE @OpenedAt DATETIME2(3) = (SELECT OpenedAt FROM Quality.ControlledRun WHERE Id = @Run);

-- three CRT container LOTs, all MINTED (CreatedAt = first tray) before the window
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, CurrentLocationId, CreatedByUserId, CreatedAtTerminalId, CrtActive, CreatedAt)
VALUES (N'T118-050-MID',   @Item, 1, 1, 8, @Line, @App, @Term,      1, DATEADD(HOUR, -2, @OpenedAt)),
       (N'T118-050-PRE',   @Item, 1, 1, 8, @Line, @App, @Term,      1, DATEADD(HOUR, -3, @OpenedAt)),
       (N'T118-050-OTHER', @Item, 1, 1, 8, @Line, @App, @TermOther, 1, DATEADD(HOUR, -2, @OpenedAt));
INSERT INTO Lots.LotGenealogyClosure (AncestorLotId, DescendantLotId, Depth)
SELECT Id, Id, 0 FROM Lots.Lot WHERE LotName IN (N'T118-050-MID', N'T118-050-PRE', N'T118-050-OTHER');
INSERT INTO Lots.Container (ItemId, ContainerConfigId, CurrentLocationId, CreatedByUserId, LotId, OpenedAt)
SELECT @Item, @Cfg, @Line, @App, Id, CreatedAt FROM Lots.Lot WHERE LotName IN (N'T118-050-MID', N'T118-050-PRE', N'T118-050-OTHER');
DECLARE @CMid   BIGINT = (SELECT c.Id FROM Lots.Container c JOIN Lots.Lot l ON l.Id = c.LotId WHERE l.LotName = N'T118-050-MID');
DECLARE @CPre   BIGINT = (SELECT c.Id FROM Lots.Container c JOIN Lots.Lot l ON l.Id = c.LotId WHERE l.LotName = N'T118-050-PRE');
DECLARE @COther BIGINT = (SELECT c.Id FROM Lots.Container c JOIN Lots.Lot l ON l.Id = c.LotId WHERE l.LotName = N'T118-050-OTHER');
INSERT INTO Lots.ContainerTray (ContainerId, TrayPosition, PartsClosedCount, ClosedAt, ClosedAtTerminalId, MintedPieceCount)
VALUES (@CMid,   1, 4, DATEADD(HOUR,   -2, @OpenedAt), @Term, 4), (@CMid,   2, 4, DATEADD(SECOND, 5, @OpenedAt), @Term, 4),
       (@CPre,   1, 4, DATEADD(HOUR,   -3, @OpenedAt), @Term, 4), (@CPre,   2, 4, DATEADD(HOUR, -1, @OpenedAt), @Term, 4),
       (@COther, 1, 4, DATEADD(SECOND,  5, @OpenedAt), @TermOther, 4), (@COther, 2, 4, DATEADD(SECOND, 6, @OpenedAt), @TermOther, 4);

DECLARE @s TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @s EXEC Quality.ControlledRun_SyncAutoJoin @Id = @Run, @AppUserId = @App;

DECLARE @c BIT;
SET @c = CASE WHEN EXISTS (SELECT 1 FROM Quality.ControlledRunMember WHERE ControlledRunId = @Run AND ContainerId = @CMid AND EndedAt IS NULL) THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[D9] a container with a tray inside the window auto-joins (as its container)', @Condition = @c;
SET @c = CASE WHEN NOT EXISTS (SELECT 1 FROM Quality.ControlledRunMember WHERE ControlledRunId = @Run AND ContainerId = @CPre) THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[D9] a container whose trays all predate the window does not join', @Condition = @c;
SET @c = CASE WHEN NOT EXISTS (SELECT 1 FROM Quality.ControlledRunMember WHERE ControlledRunId = @Run AND ContainerId = @COther) THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[D9] in-window trays on another line''s terminal do not join', @Condition = @c;

-- preview by line + time also reads the trays
DECLARE @FromEt DATETIME2(3) = CAST(@OpenedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3));
DECLARE @P TABLE (Kind NVARCHAR(20), LotId BIGINT, ContainerId BIGINT, DisplayName NVARCHAR(60), PartNumber NVARCHAR(50),
                  CurrentLocationName NVARCHAR(200), StatusCode NVARCHAR(30), PieceCount INT, ProducedAt DATETIME2(3),
                  CrtActive BIT, FoundBy NVARCHAR(50), Eligible BIT, IneligibleReason NVARCHAR(100));
DECLARE @ToEt DATETIME2(3) = DATEADD(HOUR, 1, @FromEt);   -- tray 2 is 5 s after OpenedAt, i.e. after 'now'
INSERT INTO @P EXEC Quality.ControlledRun_PreviewSelection @ItemId = @Item, @LocationId = @Line, @FromAtEastern = @FromEt, @ToAtEastern = @ToEt;
SET @c = CASE WHEN EXISTS (SELECT 1 FROM @P WHERE ContainerId = @CMid AND FoundBy = N'Line + time')
               AND NOT EXISTS (SELECT 1 FROM @P WHERE ContainerId IN (@CPre, @COther)) THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[D9] preview by line + time finds the container by its in-window tray', @Condition = @c;

-- container member state: pieces from the container LOT, CRT from it
DECLARE @MidLot BIGINT = (SELECT LotId FROM Lots.Container WHERE Id = @CMid);
SET @c = CASE WHEN EXISTS (SELECT 1 FROM Quality.ufn_ControlledRunResolveMembers((SELECT @MidLot AS lotId FOR JSON PATH))
                           WHERE ContainerId = @CMid AND Kind = N'Container' AND PieceCount = 8 AND CrtActive = 1) THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[Fold] a container LOT folds into its container member (8 pcs, CRT)', @Condition = @c;
SET @c = CASE WHEN EXISTS (SELECT 1 FROM Quality.ufn_ControlledRunMemberState(@Run) WHERE Kind = N'Container' AND DisplayName LIKE N'%' + CAST(@CMid AS NVARCHAR(20)) AND PieceCount = 8 AND CrtActive = 1) THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[State] container member pieces 8 and CRT from the container LOT', @Condition = @c;
SET @c = CASE WHEN EXISTS (SELECT 1 FROM Quality.ufn_ControlledRunMembershipsForLot(@MidLot) WHERE ControlledRunId = @Run AND ViaContainerId = @CMid) THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[Memberships] the container LOT is in the run via its container', @Condition = @c;
GO

EXEC test.PrintSummary;
EXEC test.EndTestFile;
GO
