-- =============================================
-- File:         0119_ContainerAsLot/060_repack.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-11-04
-- Description:  Container-as-LOT spec 7.4, D6, D12: container repack on NEW-shape
--               containers. Scrap takes pieces off the container LOT and the tray;
--               a move takes them off the donor's LOT and adds them to the receiver's
--               LOT, with ONE genealogy edge per (donor LOT, receiver LOT) that a
--               repeat move adds to; an emptied receiver with no LOT mints one;
--               ListTrays shows the container LOT and "moved from".
--               Fixture (non-serialized part, own config 4 trays x 4):
--                 A  donor,    ReworkProcessing, LOT A (8 pcs, trays 1-2 of 4)
--                 B  receiver, ReworkFilling,    LOT B (4 pcs, tray 1 of 4)
--                 E  receiver, ReworkFilling,    no LOT, no trays (emptied)
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0119_ContainerAsLot/060_repack.sql';
GO

DECLARE @Now  DATETIME2(3) = SYSUTCDATETIME();
DECLARE @App  BIGINT = (SELECT TOP 1 Id FROM Location.AppUser WHERE Initials = N'SYS');
DECLARE @Loc  BIGINT = (SELECT TOP 1 Id FROM Location.Location ORDER BY Id);
INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId)
VALUES (3, N'P118-RP', N'0119 repack part', 1, @Now, 1);
DECLARE @Item BIGINT = SCOPE_IDENTITY();
INSERT INTO Parts.ContainerConfig (ItemId, TraysPerContainer, PartsPerTray, IsSerialized, ClosureMethod, CreatedAt)
VALUES (@Item, 4, 4, 0, N'ByCount', @Now);
DECLARE @Cfg BIGINT = SCOPE_IDENTITY();
DECLARE @Closed BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Closed');
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, CurrentLocationId, CreatedByUserId)
VALUES (N'T118-060-A', @Item, 1, @Closed, 8, @Loc, @App), (N'T118-060-B', @Item, 1, @Closed, 4, @Loc, @App);
DECLARE @LA BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'T118-060-A');
DECLARE @LB BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'T118-060-B');
INSERT INTO Lots.LotGenealogyClosure (AncestorLotId, DescendantLotId, Depth) VALUES (@LA, @LA, 0), (@LB, @LB, 0);
INSERT INTO Lots.Container (ItemId, ContainerConfigId, CurrentLocationId, ContainerStatusCodeId, CreatedByUserId, LotId)
VALUES (@Item, @Cfg, @Loc, (SELECT Id FROM Lots.ContainerStatusCode WHERE Code = N'ReworkProcessing'), @App, @LA),
       (@Item, @Cfg, @Loc, (SELECT Id FROM Lots.ContainerStatusCode WHERE Code = N'ReworkFilling'),    @App, @LB),
       (@Item, @Cfg, @Loc, (SELECT Id FROM Lots.ContainerStatusCode WHERE Code = N'ReworkFilling'),    @App, NULL);
DECLARE @CA BIGINT = (SELECT Id FROM Lots.Container WHERE LotId = @LA);
DECLARE @CB BIGINT = (SELECT Id FROM Lots.Container WHERE LotId = @LB);
DECLARE @CE BIGINT = (SELECT Id FROM Lots.Container WHERE ItemId = @Item AND LotId IS NULL);
INSERT INTO Lots.ContainerTray (ContainerId, TrayPosition, PartsClosedCount, ClosedAt, ClosureMethod, MintedPieceCount)
VALUES (@CA, 1, 4, @Now, N'ByCount', 4), (@CA, 2, 4, @Now, N'ByCount', 4), (@CB, 1, 4, @Now, N'ByCount', 4);
GO

DECLARE @App  BIGINT = (SELECT TOP 1 Id FROM Location.AppUser WHERE Initials = N'SYS');
DECLARE @Item BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P118-RP');
DECLARE @LA BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'T118-060-A');
DECLARE @LB BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'T118-060-B');
DECLARE @CA BIGINT = (SELECT Id FROM Lots.Container WHERE LotId = @LA);
DECLARE @CB BIGINT = (SELECT Id FROM Lots.Container WHERE LotId = @LB);
DECLARE @CE BIGINT = (SELECT Id FROM Lots.Container WHERE ItemId = @Item AND LotId IS NULL);
DECLARE @TA1 BIGINT = (SELECT Id FROM Lots.ContainerTray WHERE ContainerId = @CA AND TrayPosition = 1);
DECLARE @TA2 BIGINT = (SELECT Id FROM Lots.ContainerTray WHERE ContainerId = @CA AND TrayPosition = 2);
DECLARE @Def BIGINT = (SELECT TOP 1 Id FROM Quality.DefectCode ORDER BY Id);
DECLARE @o TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
DECLARE @c BIT;

-- scrap 2 from tray A1
INSERT INTO @o EXEC Lots.ContainerRework_Scrap @ContainerTrayId = @TA1, @DefectCodeId = @Def, @Quantity = 2, @AppUserId = @App;
SET @c = CASE WHEN (SELECT Status FROM @o) = 1
               AND (SELECT PieceCount FROM Lots.Lot WHERE Id = @LA) = 6
               AND (SELECT PartsClosedCount FROM Lots.ContainerTray WHERE Id = @TA1) = 2
               AND (SELECT MintedPieceCount FROM Lots.ContainerTray WHERE Id = @TA1) = 4
               AND EXISTS (SELECT 1 FROM Workorder.RejectEvent WHERE Id = (SELECT NewId FROM @o) AND LotId = @LA AND Quantity = 2)
         THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[Scrap] container LOT and tray -2; RejectEvent on the container LOT; minted count unchanged', @Condition = @c;

-- move 3 from tray A2 to B, then 3 more from A2+A1 (2 then 1) -- one edge A->B
DELETE FROM @o;
INSERT INTO @o EXEC Lots.ContainerRework_MovePieces @FromContainerTrayId = @TA2, @ToContainerId = @CB, @Quantity = 3, @AppUserId = @App;
SET @c = CASE WHEN (SELECT Status FROM @o) = 1
               AND (SELECT PieceCount FROM Lots.Lot WHERE Id = @LA) = 3
               AND (SELECT PieceCount FROM Lots.Lot WHERE Id = @LB) = 7
               AND (SELECT LotId FROM Lots.Container WHERE Id = @CB) = @LB
               AND (SELECT PieceCount FROM Lots.LotGenealogy WHERE ParentLotId = @LA AND ChildLotId = @LB AND RelationshipTypeId = 3) = 3
         THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[Move] A -3, B +3 (B keeps its LOT), one edge A->B of 3', @Condition = @c;
DECLARE @NewTray BIGINT = (SELECT NewId FROM @o);
SET @c = CASE WHEN EXISTS (SELECT 1 FROM Lots.ContainerTray WHERE Id = @NewTray AND ContainerId = @CB AND FinishedGoodLotId IS NULL
                           AND ShiftId IS NULL AND MintedPieceCount IS NULL AND PartsClosedCount = 3)
               AND EXISTS (SELECT 1 FROM Workorder.ConsumptionEvent WHERE TrayId = @NewTray AND SourceLotId = @LA AND ProducedLotId = @LB AND PieceCount = 3)
         THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[Move] receiving tray: no LOT, no OEE stamp; ConsumptionEvent A->B on that tray', @Condition = @c;

DELETE FROM @o;
INSERT INTO @o EXEC Lots.ContainerRework_MovePieces @FromContainerTrayId = @TA1, @ToContainerId = @CB, @Quantity = 2, @AppUserId = @App;
SET @c = CASE WHEN (SELECT Status FROM @o) = 1
               AND (SELECT COUNT(*) FROM Lots.LotGenealogy WHERE ParentLotId = @LA AND ChildLotId = @LB) = 1
               AND (SELECT PieceCount FROM Lots.LotGenealogy WHERE ParentLotId = @LA AND ChildLotId = @LB) = 5
               AND (SELECT COUNT(*) FROM Lots.LotGenealogyClosure WHERE AncestorLotId = @LA AND DescendantLotId = @LB) = 1
         THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[Move] a second move adds to the same edge (5); closure not duplicated', @Condition = @c;

-- move the last piece of A into the emptied container E: E mints a LOT
DELETE FROM @o;
INSERT INTO @o EXEC Lots.ContainerRework_MovePieces @FromContainerTrayId = @TA2, @ToContainerId = @CE, @Quantity = 1, @AppUserId = @App;
DECLARE @LE BIGINT = (SELECT LotId FROM Lots.Container WHERE Id = @CE);
SET @c = CASE WHEN (SELECT Status FROM @o) = 1 AND @LE IS NOT NULL
               AND (SELECT PieceCount FROM Lots.Lot WHERE Id = @LE) = 1
               AND EXISTS (SELECT 1 FROM Lots.LotGenealogy WHERE ParentLotId = @LA AND ChildLotId = @LE AND PieceCount = 1)
         THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[Move] a receiver with no LOT mints one and links it to the donor', @Condition = @c;

-- ListTrays on B: the moved-in tray names the container LOT and "moved from" A
DECLARE @T TABLE (ContainerTrayId BIGINT, TrayPosition INT, Pieces INT, LotId BIGINT, LotName NVARCHAR(50), CrtActive BIT, MovedFromLotName NVARCHAR(50));
INSERT INTO @T EXEC Lots.ContainerRework_ListTrays @ContainerId = @CB;
SET @c = CASE WHEN EXISTS (SELECT 1 FROM @T WHERE ContainerTrayId = @NewTray AND LotId = @LB AND MovedFromLotName = N'T118-060-A')
               AND NOT EXISTS (SELECT 1 FROM @T WHERE LotId IS NULL) THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[ListTrays] trays show the container LOT; moved-in tray names the donor LOT', @Condition = @c;
GO

EXEC test.PrintSummary;
EXEC test.EndTestFile;
GO
