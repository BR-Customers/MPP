-- =============================================
-- File:         0119_ContainerAsLot/090_review_fixes.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-11-04
-- Description:  Whole-branch review findings (container-as-LOT), each pinned:
--                 I1a  a repack move may not make a genealogy loop (receiver LOT already an
--                      ancestor of the donor LOT -> refused)
--                 I1b  Lot_GetShippedContainers reads the CLOSURE (authoritative trace):
--                      a source that only reached the donor AFTER it gave pieces away is
--                      not reported in the receiver
--                 I2   the FIFO stock-pick index is filtered to LOTs with stock left
--                 M1   CRT re-resolve reads THIS tray's draws only
--                 M3   shipped-containers quantity of a mixed container = its new trays
--                 M4   FG KPI counts minted trays only (not repack moves), by minted count
--                 M5   appending to a Closed container LOT leaves InventoryAvailable alone
--                 M7   die rank: the first tray WITH draws or a LOT, skipping a move tray
--                 M11  Complete leaves a held container LOT open; AIM LOT of a mixed
--                      container = first tray LOT; Ship refuses a mixed container whose
--                      OLD tray LOT is held
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0119_ContainerAsLot/090_review_fixes.sql';
GO

-- ---- shared fixture ----
DECLARE @Now  DATETIME2(3) = SYSUTCDATETIME();
DECLARE @Loc  BIGINT = (SELECT TOP 1 Id FROM Location.Location ORDER BY Id);
INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId)
VALUES ((SELECT Id FROM Parts.ItemType WHERE Code = N'FinishedGood'), N'P118-RV', N'0119 review part', 1, @Now, 1);
DECLARE @Item BIGINT = SCOPE_IDENTITY();
INSERT INTO test.ContainerConfigInsert (ItemId, TraysPerContainer, PartsPerTray, IsSerialized, ClosureMethod, CreatedAt)
VALUES (@Item, 4, 4, 0, N'ByCount', @Now);
GO

-- =============================================
-- I1a + I1b: move loop refusal; closure-based shipped containers
-- =============================================
DECLARE @Item BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P118-RV');
DECLARE @Cfg  BIGINT = (SELECT Id FROM Parts.ContainerConfig WHERE ItemId = @Item);
DECLARE @Loc  BIGINT = (SELECT TOP 1 Id FROM Location.Location ORDER BY Id);
DECLARE @Closed BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Closed');
DECLARE @RF BIGINT = (SELECT Id FROM Lots.ContainerStatusCode WHERE Code = N'ReworkFilling');
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, CurrentLocationId, CreatedByUserId)
VALUES (N'T118-090-A', @Item, 1, @Closed, 8, @Loc, 1), (N'T118-090-B', @Item, 1, @Closed, 4, @Loc, 1),
       (N'T118-090-X', @Item, 1, @Closed, 0, @Loc, 1);
DECLARE @LA BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'T118-090-A');
DECLARE @LB BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'T118-090-B');
DECLARE @LX BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'T118-090-X');
INSERT INTO Lots.LotGenealogyClosure (AncestorLotId, DescendantLotId, Depth) VALUES (@LA, @LA, 0), (@LB, @LB, 0), (@LX, @LX, 0);
INSERT INTO Lots.Container (ItemId, ContainerConfigId, CurrentLocationId, ContainerStatusCodeId, CreatedByUserId, LotId)
VALUES (@Item, @Cfg, @Loc, @RF, 1, @LA), (@Item, @Cfg, @Loc, @RF, 1, @LB);
DECLARE @CA BIGINT = (SELECT Id FROM Lots.Container WHERE LotId = @LA);
DECLARE @CB BIGINT = (SELECT Id FROM Lots.Container WHERE LotId = @LB);
INSERT INTO Lots.ContainerTray (ContainerId, TrayPosition, PartsClosedCount, ClosedAt, ClosureMethod)
VALUES (@CA, 1, 4, SYSUTCDATETIME(), N'ByCount'), (@CA, 2, 4, SYSUTCDATETIME(), N'ByCount'), (@CB, 1, 4, SYSUTCDATETIME(), N'ByCount');
DECLARE @TA1 BIGINT = (SELECT Id FROM Lots.ContainerTray WHERE ContainerId = @CA AND TrayPosition = 1);
DECLARE @TB1 BIGINT = (SELECT Id FROM Lots.ContainerTray WHERE ContainerId = @CB AND TrayPosition = 1);
DECLARE @o TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
DECLARE @c BIT;

INSERT INTO @o EXEC Lots.ContainerRework_MovePieces @FromContainerTrayId = @TA1, @ToContainerId = @CB, @Quantity = 2, @AppUserId = 1;
SET @c = CASE WHEN (SELECT Status FROM @o) = 1 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[I1a] A -> B move succeeds', @Condition = @c;
DELETE FROM @o;
INSERT INTO @o EXEC Lots.ContainerRework_MovePieces @FromContainerTrayId = @TB1, @ToContainerId = @CA, @Quantity = 1, @AppUserId = 1;
SET @c = CASE WHEN (SELECT Status FROM @o) = 0 AND (SELECT Message FROM @o) LIKE N'%T118-090-B%T118-090-A%'
               AND NOT EXISTS (SELECT 1 FROM Lots.LotGenealogy WHERE ParentLotId = @LB AND ChildLotId = @LA) THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[I1a] B -> A refused (would make A both parent and child of B), names both LOTs', @Condition = @c;

-- I1b: X becomes an ancestor of A only AFTER A gave pieces to B (a later top-up of A)
INSERT INTO Lots.LotGenealogy (ParentLotId, ChildLotId, RelationshipTypeId, PieceCount, EventUserId) VALUES (@LX, @LA, 3, 1, 1);
INSERT INTO Lots.LotGenealogyClosure (AncestorLotId, DescendantLotId, Depth) VALUES (@LX, @LA, 1);
UPDATE Lots.Container SET ContainerStatusCodeId = (SELECT Id FROM Lots.ContainerStatusCode WHERE Code = N'Shipped') WHERE Id IN (@CA, @CB);
DECLARE @S TABLE (FinishedGoodLotId BIGINT, FinishedGoodLotName NVARCHAR(50), FinishedGoodPartNumber NVARCHAR(50), ContainerId BIGINT,
                  AimShipperId NVARCHAR(50), Quantity INT, ContainerStatusName NVARCHAR(50), CurrentLocationName NVARCHAR(200), CompletedAt DATETIME2(3));
INSERT INTO @S EXEC Lots.Lot_GetShippedContainers @LotId = @LX;
SET @c = CASE WHEN EXISTS (SELECT 1 FROM @S WHERE ContainerId = @CA) AND NOT EXISTS (SELECT 1 FROM @S WHERE ContainerId = @CB) THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[I1b] shipped containers follow the closure: X reached A, not B (B''s pieces left A before X arrived)', @Condition = @c;
GO

-- =============================================
-- I2: the stock-pick index is filtered to LOTs with stock
-- =============================================
DECLARE @c BIT = CASE WHEN EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'Lots.Lot')
                                   AND name = N'IX_Lot_LocationItemCreated' AND has_filter = 1
                                   AND filter_definition LIKE N'%InventoryAvailable%>%0%') THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[I2] IX_Lot_LocationItemCreated is filtered to InventoryAvailable > 0', @Condition = @c;
GO

-- =============================================
-- M3: mixed container quantity in shipped containers = its new (LOT-less) trays only
-- =============================================
DECLARE @Item BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P118-RV');
DECLARE @Cfg  BIGINT = (SELECT Id FROM Parts.ContainerConfig WHERE ItemId = @Item);
DECLARE @Loc  BIGINT = (SELECT TOP 1 Id FROM Location.Location ORDER BY Id);
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, CurrentLocationId, CreatedByUserId)
VALUES (N'T118-090-SRC', @Item, 1, 4, 0, @Loc, 1), (N'T118-090-MOLD', @Item, 1, 4, 4, @Loc, 1), (N'T118-090-MNEW', @Item, 1, 4, 4, @Loc, 1);
DECLARE @Src BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'T118-090-SRC');
DECLARE @MOld BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'T118-090-MOLD');
DECLARE @MNew BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'T118-090-MNEW');
INSERT INTO Lots.LotGenealogyClosure (AncestorLotId, DescendantLotId, Depth)
VALUES (@Src, @Src, 0), (@MOld, @MOld, 0), (@MNew, @MNew, 0), (@Src, @MOld, 1), (@Src, @MNew, 1);
INSERT INTO Lots.LotGenealogy (ParentLotId, ChildLotId, RelationshipTypeId, PieceCount, EventUserId) VALUES (@Src, @MOld, 3, 4, 1), (@Src, @MNew, 3, 4, 1);
INSERT INTO Lots.Container (ItemId, ContainerConfigId, CurrentLocationId, ContainerStatusCodeId, CreatedByUserId, LotId)
VALUES (@Item, @Cfg, @Loc, (SELECT Id FROM Lots.ContainerStatusCode WHERE Code = N'Shipped'), 1, @MNew);
DECLARE @CM BIGINT = SCOPE_IDENTITY();
INSERT INTO Lots.ContainerTray (ContainerId, TrayPosition, PartsClosedCount, ClosedAt, FinishedGoodLotId)
VALUES (@CM, 1, 4, SYSUTCDATETIME(), @MOld), (@CM, 2, 4, SYSUTCDATETIME(), NULL);
DECLARE @S TABLE (FinishedGoodLotId BIGINT, FinishedGoodLotName NVARCHAR(50), FinishedGoodPartNumber NVARCHAR(50), ContainerId BIGINT,
                  AimShipperId NVARCHAR(50), Quantity INT, ContainerStatusName NVARCHAR(50), CurrentLocationName NVARCHAR(200), CompletedAt DATETIME2(3));
INSERT INTO @S EXEC Lots.Lot_GetShippedContainers @LotId = @Src;
DECLARE @c BIT = CASE WHEN (SELECT SUM(Quantity) FROM @S WHERE ContainerId = @CM) = 8
                       AND (SELECT Quantity FROM @S WHERE FinishedGoodLotId = @MNew) = 4 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[M3] mixed container: old tray LOT 4 + container LOT 4 (its own trays), not 4 + 8', @Condition = @c;
GO

-- =============================================
-- M4: FG KPI counts minted trays only, by minted count
-- =============================================
DECLARE @Item BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P118-RV');
DECLARE @CM BIGINT = (SELECT Id FROM Lots.Container WHERE LotId = (SELECT Id FROM Lots.Lot WHERE LotName = N'T118-090-MNEW'));
UPDATE Lots.ContainerTray SET MintedPieceCount = 4, ClosedAt = '2020-04-01T10:00:00' WHERE ContainerId = @CM AND TrayPosition = 2;
UPDATE Lots.ContainerTray SET ClosedAt = '2019-01-01' WHERE ContainerId = @CM AND TrayPosition = 1;
INSERT INTO Lots.ContainerTray (ContainerId, TrayPosition, PartsClosedCount, ClosedAt, FinishedGoodLotId, MintedPieceCount)
VALUES (@CM, 3, 3, '2020-04-01T11:00:00', NULL, NULL);   -- a repack-move tray
UPDATE Lots.ContainerTray SET PartsClosedCount = 2 WHERE ContainerId = @CM AND TrayPosition = 2;  -- scrapped since
DECLARE @K TABLE (ItemId BIGINT, PartNumber NVARCHAR(50), Description NVARCHAR(500), LotCount INT, PartCount INT);
INSERT INTO @K EXEC Workorder.FinishedGoods_GetProducedSummary @ShiftStartUtc = '2020-04-01T00:00:00', @ShiftEndUtc = '2020-04-02T00:00:00';
DECLARE @c BIT = CASE WHEN (SELECT PartCount FROM @K WHERE ItemId = @Item) = 4 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[M4] KPI = minted tray pieces (4): not the move tray (3), not the scrapped-down count (2)', @Condition = @c;
GO

-- =============================================
-- M7: die rank skips a first tray that has no draws and no LOT (a move tray)
-- =============================================
DECLARE @Item BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P118-RV');
DECLARE @Cfg  BIGINT = (SELECT Id FROM Parts.ContainerConfig WHERE ItemId = @Item);
DECLARE @Loc  BIGINT = (SELECT TOP 1 Id FROM Location.Location ORDER BY Id);
INSERT INTO Tools.DieRank (Code, Name) VALUES (N'T118-RV', N'0119 review rank');
INSERT INTO Tools.Tool (ToolTypeId, Code, Name, DieRankId, StatusCodeId, CreatedByUserId)
VALUES ((SELECT Id FROM Tools.ToolType WHERE Code = N'Die'), N'T118-RV-DIE', N'0119 review die', SCOPE_IDENTITY(),
        (SELECT Id FROM Tools.ToolStatusCode WHERE Code = N'Active'), 1);
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, CurrentLocationId, CreatedByUserId, ToolId)
VALUES (N'T118-090-CAST', @Item, 1, 4, 0, @Loc, 1, (SELECT Id FROM Tools.Tool WHERE Code = N'T118-RV-DIE')),
       (N'T118-090-DLOT', @Item, 1, 1, 8, @Loc, 1, NULL);
DECLARE @Cast BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'T118-090-CAST');
DECLARE @DLot BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'T118-090-DLOT');
INSERT INTO Lots.LotGenealogyClosure (AncestorLotId, DescendantLotId, Depth) VALUES (@Cast, @Cast, 0), (@DLot, @DLot, 0), (@Cast, @DLot, 1);
INSERT INTO Lots.Container (ItemId, ContainerConfigId, CurrentLocationId, CreatedByUserId, LotId) VALUES (@Item, @Cfg, @Loc, 1, @DLot);
DECLARE @CD BIGINT = SCOPE_IDENTITY();
INSERT INTO Lots.ContainerTray (ContainerId, TrayPosition, PartsClosedCount, ClosedAt) VALUES (@CD, 1, 2, SYSUTCDATETIME()), (@CD, 2, 4, SYSUTCDATETIME());
INSERT INTO Workorder.ConsumptionEvent (SourceLotId, ProducedLotId, ProducedContainerId, ConsumedItemId, ProducedItemId, PieceCount, LocationId, AppUserId, TrayId)
VALUES (@Cast, @DLot, @CD, @Item, @Item, 4, @Loc, 1, (SELECT Id FROM Lots.ContainerTray WHERE ContainerId = @CD AND TrayPosition = 2));
DECLARE @c BIT = CASE WHEN Tools.ufn_ContainerOriginDieRankCode(@CD) = N'T118-RV' THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[M7] die rank skips a first tray with no draws (a move tray) to the first tray with draws', @Condition = @c;
GO

-- =============================================
-- M1, M5, M11 on a real line (Assembly_CompleteTray + Container_Complete + Ship)
-- =============================================
DECLARE @Now  DATETIME2(3) = SYSUTCDATETIME();
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');
INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId)
VALUES (3, N'P118-RVL', N'0119 review line FG', 1, @Now, 1), (3, N'P118-RVC', N'0119 review component', 1, @Now, 1);
DECLARE @Out BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P118-RVL');
DECLARE @CmpItem BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P118-RVC');
INSERT INTO test.ContainerConfigInsert (ItemId, TraysPerContainer, PartsPerTray, IsSerialized, ClosureMethod, CreatedAt) VALUES (@Out, 3, 2, 0, N'ByCount', @Now);
INSERT INTO Parts.Bom (ParentItemId, VersionNumber, EffectiveFrom, PublishedAt, CreatedByUserId, CreatedAt) VALUES (@Out, 1, @Now, @Now, 1, @Now);
INSERT INTO Parts.BomLine (BomId, ChildItemId, QtyPer, UomId, SortOrder) VALUES (SCOPE_IDENTITY(), @CmpItem, 1, 1, 1);
INSERT INTO Parts.ItemLocation (ItemId, LocationId, IsConsumptionPoint, CreatedAt) VALUES (@Out, @Cell, 0, @Now);
-- CRT stock first (oldest), then clean stock: tray 1 draws the CRT LOT, tray 2 the clean one
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId, CreatedAt, CrtActive)
VALUES (N'STG-118RV-CRT', @CmpItem, 1, 1, 2, 2, @Cell, 1, DATEADD(MINUTE, -10, @Now), 1),
       (N'STG-118RV-OK',  @CmpItem, 1, 1, 20, 20, @Cell, 1, @Now, 0);
INSERT INTO Lots.LotGenealogyClosure (AncestorLotId, DescendantLotId, Depth) SELECT Id, Id, 0 FROM Lots.Lot WHERE LotName LIKE N'STG-118RV-%';
DECLARE @R TABLE (N INT IDENTITY(1,1), Status BIT, Message NVARCHAR(500), FinishedGoodLotId BIGINT, ContainerId BIGINT, ContainerTrayId BIGINT, ContainerFull BIT, TraysPerContainer INT);
INSERT INTO @R (Status, Message, FinishedGoodLotId, ContainerId, ContainerTrayId, ContainerFull, TraysPerContainer)
EXEC Workorder.Assembly_CompleteTray @FinishedGoodItemId = @Out, @PieceCount = 2, @CellLocationId = @Cell, @ClosureMethod = N'ByCount', @AppUserId = 1, @TerminalLocationId = @Cell;
DECLARE @Lot BIGINT = (SELECT FinishedGoodLotId FROM @R WHERE N = 1);
DECLARE @Cid BIGINT = (SELECT ContainerId FROM @R WHERE N = 1);
-- Quality validates the container LOT (CRT cleared); the next tray draws only clean stock
UPDATE Lots.Lot SET CrtActive = 0 WHERE Id = @Lot;
INSERT INTO @R (Status, Message, FinishedGoodLotId, ContainerId, ContainerTrayId, ContainerFull, TraysPerContainer)
EXEC Workorder.Assembly_CompleteTray @FinishedGoodItemId = @Out, @PieceCount = 2, @CellLocationId = @Cell, @ClosureMethod = N'ByCount', @AppUserId = 1, @TerminalLocationId = @Cell;
DECLARE @c BIT = CASE WHEN (SELECT FinishedGoodLotId FROM @R WHERE N = 2) = @Lot AND (SELECT CrtActive FROM Lots.Lot WHERE Id = @Lot) = 0 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[M1] a tray drawing only clean stock does not re-tag a validated container LOT', @Condition = @c;

-- M5: container LOT Closed (a resumed rework container): append raises PieceCount only
UPDATE Lots.Lot SET LotStatusId = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Closed'), InventoryAvailable = 0 WHERE Id = @Lot;
INSERT INTO @R (Status, Message, FinishedGoodLotId, ContainerId, ContainerTrayId, ContainerFull, TraysPerContainer)
EXEC Workorder.Assembly_CompleteTray @FinishedGoodItemId = @Out, @PieceCount = 2, @CellLocationId = @Cell, @ClosureMethod = N'ByCount', @AppUserId = 1, @TerminalLocationId = @Cell;
SET @c = CASE WHEN EXISTS (SELECT 1 FROM Lots.Lot WHERE Id = @Lot AND PieceCount = 6 AND InventoryAvailable = 0) THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[M5] appending to a Closed container LOT raises PieceCount, leaves InventoryAvailable 0', @Condition = @c;

-- M11: a held container LOT survives Container_Complete open
UPDATE Lots.Lot SET LotStatusId = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Hold') WHERE Id = @Lot;
DECLARE @TP TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @TP EXEC Lots.AimShipperIdPool_Topup @AimShipperId = N'T118-090-AIM1';
DECLARE @CMP TABLE (Status BIT, Message NVARCHAR(500), ShippingLabelId BIGINT, AimShipperId NVARCHAR(50));
INSERT INTO @CMP EXEC Lots.Container_Complete @ContainerId = @Cid, @OperatorConfirmed = 1, @AppUserId = 1, @TerminalLocationId = @Cell;
SET @c = CASE WHEN (SELECT Status FROM @CMP) = 1
               AND EXISTS (SELECT 1 FROM Lots.Lot l JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId WHERE l.Id = @Lot AND sc.Code = N'Hold')
         THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[M11] Container_Complete leaves a held container LOT open (Hold)', @Condition = @c;
GO

-- M11: mixed container -- AIM LOT number = first tray LOT; Ship refused when the OLD tray LOT is held
DECLARE @Out  BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P118-RVL');
DECLARE @Cfg  BIGINT = (SELECT Id FROM Parts.ContainerConfig WHERE ItemId = @Out);
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, CurrentLocationId, CreatedByUserId)
VALUES (N'T118-090-XOLD', @Out, 1, 1, 2, @Cell, 1), (N'T118-090-XNEW', @Out, 1, 1, 4, @Cell, 1);
DECLARE @XOld BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'T118-090-XOLD');
DECLARE @XNew BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'T118-090-XNEW');
INSERT INTO Lots.Container (ItemId, ContainerConfigId, CurrentLocationId, CreatedByUserId, LotId, StationLocationId)
VALUES (@Out, @Cfg, @Cell, 1, @XNew, NULL);
DECLARE @CX BIGINT = SCOPE_IDENTITY();
INSERT INTO Lots.ContainerTray (ContainerId, TrayPosition, PartsClosedCount, ClosedAt, FinishedGoodLotId)
VALUES (@CX, 1, 2, SYSUTCDATETIME(), @XOld), (@CX, 2, 2, SYSUTCDATETIME(), NULL), (@CX, 3, 2, SYSUTCDATETIME(), NULL);
DECLARE @TP TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @TP EXEC Lots.AimShipperIdPool_Topup @AimShipperId = N'T118-090-AIM2';
DECLARE @CMP TABLE (Status BIT, Message NVARCHAR(500), ShippingLabelId BIGINT, AimShipperId NVARCHAR(50));
INSERT INTO @CMP EXEC Lots.Container_Complete @ContainerId = @CX, @OperatorConfirmed = 1, @AppUserId = 1, @TerminalLocationId = @Cell;
DECLARE @c BIT = CASE WHEN (SELECT Status FROM @CMP) = 1
                       AND (SELECT LotNumber FROM Lots.AimShipperIdPool WHERE ConsumedByContainerId = @CX AND VoidedAt IS NULL) = N'T118-090-XOLD'
                 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[M11] mixed container: AIM LotNumber = the first tray''s LOT', @Condition = @c;
DECLARE @HP TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @HP EXEC Quality.Hold_Place @LotId = @XOld, @HoldTypeCodeId = 1, @Reason = N'0119 090 old tray hold', @AppUserId = 1;
DECLARE @Sl BIGINT = (SELECT ShippingLabelId FROM @CMP);
DECLARE @SH TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @SH EXEC Lots.Container_Ship @ShippingLabelId = @Sl, @AppUserId = 1;
SET @c = CASE WHEN (SELECT Status FROM @SH) = 0 AND (SELECT Message FROM @SH) LIKE N'%T118-090-XOLD%on hold%' THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[M11] mixed container: Ship refused while the OLD tray LOT is held, naming it', @Condition = @c;
GO

EXEC test.PrintSummary;
EXEC test.EndTestFile;
GO
