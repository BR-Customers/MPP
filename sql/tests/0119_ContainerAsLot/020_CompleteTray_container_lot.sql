-- =============================================
-- File:         0119_ContainerAsLot/020_CompleteTray_container_lot.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-11-04
-- Description:  Workorder.Assembly_CompleteTray v2.0 (container-as-LOT spec 7.1,
--               D1-D5, D10, D11): the first tray mints the container's LOT, later
--               trays append to it; trays carry no LOT but are stamped with shift,
--               terminal and a fixed minted count; one genealogy edge per
--               (source LOT, container LOT); held / Closed container LOTs still
--               receive trays; CRT re-resolved per tray; an old-shape open
--               container becomes mixed.
--               Fixture cell/terminal MA1-COMPBR-AOUT. FG P118-OUT = 3 trays x 4.
--               BOM: A x1. Stock: A1 = 6 (older), A2 = 20.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0119_ContainerAsLot/020_CompleteTray_container_lot.sql';
GO

-- ---- fixture ----
DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId)
VALUES (3, N'P118-OUT', N'0119 finished good', 1, @Now, 1),
       (3, N'P118-A',   N'0119 component A', 1, @Now, 1);
DECLARE @Out BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P118-OUT');
DECLARE @A   BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P118-A');
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');
INSERT INTO Parts.ContainerConfig (ItemId, TraysPerContainer, PartsPerTray, IsSerialized, ClosureMethod, CreatedAt)
VALUES (@Out, 3, 4, 0, N'ByCount', @Now);
INSERT INTO Parts.Bom (ParentItemId, VersionNumber, EffectiveFrom, PublishedAt, CreatedByUserId, CreatedAt) VALUES (@Out, 1, @Now, @Now, 1, @Now);
INSERT INTO Parts.BomLine (BomId, ChildItemId, QtyPer, UomId, SortOrder) VALUES (SCOPE_IDENTITY(), @A, 1, 1, 1);
INSERT INTO Parts.ItemLocation (ItemId, LocationId, IsConsumptionPoint, CreatedAt) VALUES (@Out, @Cell, 0, @Now);
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId, CreatedAt)
VALUES (N'STG-118A1', @A, 1, 1, 6, 6, @Cell, 1, @Now),
       (N'STG-118A2', @A, 1, 1, 20, 20, @Cell, 1, DATEADD(SECOND, 5, @Now));
INSERT INTO Lots.LotGenealogyClosure (AncestorLotId, DescendantLotId, Depth)
SELECT Id, Id, 0 FROM Lots.Lot WHERE LotName LIKE N'STG-118%';

-- shift covering now (the 092 pattern)
DECLARE @NowLocal   DATETIME2(0) = CAST(SYSUTCDATETIME() AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(0));
DECLARE @StartLocal DATETIME2(0) = DATEADD(MINUTE, -1, DATEADD(SECOND, -DATEPART(SECOND, @NowLocal), @NowLocal));
DECLARE @EndLocal   DATETIME2(0) = DATEADD(HOUR, 2, @StartLocal);
INSERT INTO Oee.ShiftSchedule (Name, StartTime, EndTime, DaysOfWeekBitmask, EffectiveFrom, CreatedByUserId)
VALUES (N'CT118-SHIFT-SCHED', CAST(@StartLocal AS TIME(0)), CAST(@EndLocal AS TIME(0)), 127, DATEADD(DAY, -2, CAST(@StartLocal AS DATE)), 1);
INSERT INTO Oee.Shift (ShiftScheduleId, ActualStart, ActualEnd, Remarks)
VALUES ((SELECT Id FROM Oee.ShiftSchedule WHERE Name = N'CT118-SHIFT-SCHED'), @StartLocal, @EndLocal, N'CT118-SHIFT');
GO

-- =============================================
-- Trays 1 and 2: mint, then append
-- =============================================
DECLARE @Out  BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P118-OUT');
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');
DECLARE @SeqBefore BIGINT = (SELECT LastValue FROM Lots.IdentifierSequence WHERE Code = N'Lot');
DECLARE @R TABLE (N INT IDENTITY(1,1), Status BIT, Message NVARCHAR(500), FinishedGoodLotId BIGINT, ContainerId BIGINT, ContainerTrayId BIGINT, ContainerFull BIT, TraysPerContainer INT);
INSERT INTO @R (Status, Message, FinishedGoodLotId, ContainerId, ContainerTrayId, ContainerFull, TraysPerContainer)
EXEC Workorder.Assembly_CompleteTray @FinishedGoodItemId = @Out, @PieceCount = 4, @CellLocationId = @Cell, @ClosureMethod = N'ByCount', @AppUserId = 1, @TerminalLocationId = @Cell;
INSERT INTO @R (Status, Message, FinishedGoodLotId, ContainerId, ContainerTrayId, ContainerFull, TraysPerContainer)
EXEC Workorder.Assembly_CompleteTray @FinishedGoodItemId = @Out, @PieceCount = 4, @CellLocationId = @Cell, @ClosureMethod = N'ByCount', @AppUserId = 1, @TerminalLocationId = @Cell;

DECLARE @c BIT;
DECLARE @Lot BIGINT = (SELECT FinishedGoodLotId FROM @R WHERE N = 1);
DECLARE @Cid BIGINT = (SELECT ContainerId FROM @R WHERE N = 1);
DECLARE @Shift BIGINT = (SELECT Id FROM Oee.Shift WHERE Remarks = N'CT118-SHIFT');

SET @c = CASE WHEN (SELECT COUNT(*) FROM @R WHERE Status = 1) = 2 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[D1] both trays Status 1', @Condition = @c;
SET @c = CASE WHEN (SELECT LotId FROM Lots.Container WHERE Id = @Cid) = @Lot THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[D1] first tray mints; Container.LotId = the LOT returned', @Condition = @c;
SET @c = CASE WHEN (SELECT FinishedGoodLotId FROM @R WHERE N = 2) = @Lot AND (SELECT ContainerId FROM @R WHERE N = 2) = @Cid THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[D1] second tray appends to the same LOT and container', @Condition = @c;
SET @c = CASE WHEN EXISTS (SELECT 1 FROM Lots.Lot WHERE Id = @Lot AND PieceCount = 8 AND InventoryAvailable = 8) THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[D1] LOT PieceCount = 8, InventoryAvailable = 8 after two trays', @Condition = @c;
SET @c = CASE WHEN (SELECT LastValue FROM Lots.IdentifierSequence WHERE Code = N'Lot') = @SeqBefore + 1 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[D1] Lot sequence advanced once for two trays', @Condition = @c;
SET @c = CASE WHEN (SELECT COUNT(*) FROM Lots.LotStatusHistory WHERE LotId = @Lot) = 1
               AND (SELECT COUNT(*) FROM Lots.LotMovement WHERE LotId = @Lot) = 1 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[D1] one status-history row and one movement for the container LOT', @Condition = @c;
SET @c = CASE WHEN (SELECT COUNT(*) FROM Lots.LotEventLog le JOIN Audit.LogEventType et ON et.Id = le.LogEventTypeId
                     WHERE le.LotId = @Lot AND et.Code = N'LotCreated') = 1 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[D1] LotCreated audit written once (on mint only)', @Condition = @c;

SET @c = CASE WHEN (SELECT COUNT(*) FROM Lots.ContainerTray WHERE ContainerId = @Cid AND FinishedGoodLotId IS NULL
                     AND MintedPieceCount = 4 AND PartsClosedCount = 4 AND ShiftId = @Shift AND ClosedAtTerminalId = @Cell) = 2
         THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[D2/D5/D11] trays: no LOT, MintedPieceCount 4, ShiftId + ClosedAtTerminalId stamped', @Condition = @c;
SET @c = CASE WHEN EXISTS (SELECT 1 FROM Lots.Lot WHERE Id = @Lot AND ShiftId IS NULL AND MintedPieceCount IS NULL) THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[D5] container LOT carries no ShiftId / MintedPieceCount', @Condition = @c;

-- D3: consumption per tray, produced = container LOT. Tray 1 drew A1 x4; tray 2 drew A1 x2 + A2 x2.
SET @c = CASE WHEN (SELECT COUNT(*) FROM Workorder.ConsumptionEvent WHERE ProducedLotId = @Lot) = 3
               AND (SELECT COUNT(DISTINCT TrayId) FROM Workorder.ConsumptionEvent WHERE ProducedLotId = @Lot) = 2
               AND NOT EXISTS (SELECT 1 FROM Workorder.ConsumptionEvent WHERE ProducedLotId = @Lot AND ProducedContainerId <> @Cid) THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[D3] ConsumptionEvent per tray draw: ProducedLotId = container LOT, TrayId per tray', @Condition = @c;

-- D4: one edge per (source, container LOT); A1 drawn by both trays -> one edge of 6.
DECLARE @A1 BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'STG-118A1');
DECLARE @A2 BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'STG-118A2');
SET @c = CASE WHEN (SELECT COUNT(*) FROM Lots.LotGenealogy WHERE ChildLotId = @Lot) = 2
               AND (SELECT PieceCount FROM Lots.LotGenealogy WHERE ChildLotId = @Lot AND ParentLotId = @A1) = 6
               AND (SELECT PieceCount FROM Lots.LotGenealogy WHERE ChildLotId = @Lot AND ParentLotId = @A2) = 2 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[D4] one edge per source LOT; A1 edge PieceCount = 4 + 2', @Condition = @c;
SET @c = CASE WHEN NOT EXISTS (SELECT AncestorLotId FROM Lots.LotGenealogyClosure WHERE DescendantLotId = @Lot
                               GROUP BY AncestorLotId HAVING COUNT(*) > 1)
               AND (SELECT COUNT(*) FROM Lots.LotGenealogyClosure WHERE DescendantLotId = @Lot) = 3 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[D4] closure: self + A1 + A2, no duplicate ancestors', @Condition = @c;
GO

-- =============================================
-- D10: LOT on Hold -> third tray still appends; LOT stays Hold
-- =============================================
DECLARE @Out  BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P118-OUT');
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');
DECLARE @Cid  BIGINT = (SELECT Id FROM Lots.Container WHERE ItemId = @Out);
DECLARE @Lot  BIGINT = (SELECT LotId FROM Lots.Container WHERE Id = @Cid);
UPDATE Lots.Lot SET LotStatusId = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Hold') WHERE Id = @Lot;
DECLARE @R TABLE (Status BIT, Message NVARCHAR(500), FinishedGoodLotId BIGINT, ContainerId BIGINT, ContainerTrayId BIGINT, ContainerFull BIT, TraysPerContainer INT);
INSERT INTO @R EXEC Workorder.Assembly_CompleteTray @FinishedGoodItemId = @Out, @PieceCount = 4, @CellLocationId = @Cell, @ClosureMethod = N'ByCount', @AppUserId = 1, @TerminalLocationId = @Cell;
DECLARE @c BIT = CASE WHEN (SELECT Status FROM @R) = 1 AND (SELECT FinishedGoodLotId FROM @R) = @Lot
                       AND EXISTS (SELECT 1 FROM Lots.Lot l JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
                                   WHERE l.Id = @Lot AND sc.Code = N'Hold' AND l.PieceCount = 12 AND l.InventoryAvailable = 12)
                       AND (SELECT ContainerFull FROM @R) = 1 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[D10] tray appends to a held container LOT (12 pcs, still Hold, container full)', @Condition = @c;
GO

-- =============================================
-- 7.4: container LOT Closed + container Open (a resumed rework container) -> tray appends
-- =============================================
DECLARE @Out  BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P118-OUT');
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');
DECLARE @Cid  BIGINT = (SELECT Id FROM Lots.Container WHERE ItemId = @Out);
DECLARE @Lot  BIGINT = (SELECT LotId FROM Lots.Container WHERE Id = @Cid);
-- simulate a repack: one tray scrapped out (container no longer full), LOT Closed
UPDATE Lots.ContainerTray SET PartsClosedCount = 0 WHERE ContainerId = @Cid AND TrayPosition = 3;
UPDATE Lots.Lot SET LotStatusId = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Closed'), PieceCount = 8, InventoryAvailable = 8 WHERE Id = @Lot;
DECLARE @R TABLE (Status BIT, Message NVARCHAR(500), FinishedGoodLotId BIGINT, ContainerId BIGINT, ContainerTrayId BIGINT, ContainerFull BIT, TraysPerContainer INT);
INSERT INTO @R EXEC Workorder.Assembly_CompleteTray @FinishedGoodItemId = @Out, @PieceCount = 4, @CellLocationId = @Cell, @ClosureMethod = N'ByCount', @AppUserId = 1, @TerminalLocationId = @Cell;
DECLARE @c BIT = CASE WHEN (SELECT Status FROM @R) = 1 AND (SELECT FinishedGoodLotId FROM @R) = @Lot
                       AND EXISTS (SELECT 1 FROM Lots.Lot WHERE Id = @Lot AND PieceCount = 12) THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[7.4] tray appends to a Closed container LOT while the container is Open', @Condition = @c;
GO

-- =============================================
-- CRT: a fresh container; tray 2 consumes a CRT input -> container LOT tagged
-- =============================================
DECLARE @Out  BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P118-OUT');
DECLARE @A    BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P118-A');
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');
UPDATE Lots.Container SET ContainerStatusCodeId = (SELECT Id FROM Lots.ContainerStatusCode WHERE Code = N'Complete') WHERE ItemId = @Out;
-- remaining A2 stock = 20 - 2 - 4 - 4 = 10. Add a newer CRT LOT; drain order is A2 then CRT.
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId, CreatedAt, CrtActive)
VALUES (N'STG-118CRT', @A, 1, 1, 10, 10, @Cell, 1, DATEADD(MINUTE, 5, SYSUTCDATETIME()), 1);
INSERT INTO Lots.LotGenealogyClosure (AncestorLotId, DescendantLotId, Depth) SELECT Id, Id, 0 FROM Lots.Lot WHERE LotName = N'STG-118CRT';
UPDATE Lots.Lot SET PieceCount = 4, InventoryAvailable = 4 WHERE LotName = N'STG-118A2';
DECLARE @R TABLE (N INT IDENTITY(1,1), Status BIT, Message NVARCHAR(500), FinishedGoodLotId BIGINT, ContainerId BIGINT, ContainerTrayId BIGINT, ContainerFull BIT, TraysPerContainer INT);
INSERT INTO @R (Status, Message, FinishedGoodLotId, ContainerId, ContainerTrayId, ContainerFull, TraysPerContainer)
EXEC Workorder.Assembly_CompleteTray @FinishedGoodItemId = @Out, @PieceCount = 4, @CellLocationId = @Cell, @ClosureMethod = N'ByCount', @AppUserId = 1, @TerminalLocationId = @Cell;
DECLARE @Lot BIGINT = (SELECT FinishedGoodLotId FROM @R WHERE N = 1);
DECLARE @c BIT = CASE WHEN (SELECT CrtActive FROM Lots.Lot WHERE Id = @Lot) = 0 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[CRT] new container LOT clean after a clean tray', @Condition = @c;
INSERT INTO @R (Status, Message, FinishedGoodLotId, ContainerId, ContainerTrayId, ContainerFull, TraysPerContainer)
EXEC Workorder.Assembly_CompleteTray @FinishedGoodItemId = @Out, @PieceCount = 4, @CellLocationId = @Cell, @ClosureMethod = N'ByCount', @AppUserId = 1, @TerminalLocationId = @Cell;
SET @c = CASE WHEN (SELECT FinishedGoodLotId FROM @R WHERE N = 2) = @Lot AND (SELECT CrtActive FROM Lots.Lot WHERE Id = @Lot) = 1 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[CRT] tray 2 consumes a CRT input -> container LOT CrtActive 1', @Condition = @c;
GO

-- =============================================
-- Mixed: an old-shape open container (tray LOT, LotId NULL) -> next tray mints the container LOT
-- =============================================
DECLARE @Out  BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P118-OUT');
DECLARE @A    BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P118-A');
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');
UPDATE Lots.Container SET ContainerStatusCodeId = (SELECT Id FROM Lots.ContainerStatusCode WHERE Code = N'Complete') WHERE ItemId = @Out;
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId)
VALUES (N'T118-OLDTRAY', @Out, 1, 1, 4, 4, @Cell, 1);
DECLARE @OldLot BIGINT = SCOPE_IDENTITY();
INSERT INTO Lots.Container (ItemId, ContainerConfigId, CurrentLocationId, CreatedByUserId, StationLocationId)
VALUES (@Out, (SELECT Id FROM Parts.ContainerConfig WHERE ItemId = @Out), @Cell, 1, @Cell);
DECLARE @OldC BIGINT = SCOPE_IDENTITY();
INSERT INTO Lots.ContainerTray (ContainerId, TrayPosition, PartsClosedCount, ClosedAt, FinishedGoodLotId) VALUES (@OldC, 1, 4, SYSUTCDATETIME(), @OldLot);
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId)
VALUES (N'STG-118A3', @A, 1, 1, 10, 10, @Cell, 1);
INSERT INTO Lots.LotGenealogyClosure (AncestorLotId, DescendantLotId, Depth) SELECT Id, Id, 0 FROM Lots.Lot WHERE LotName = N'STG-118A3';
DECLARE @R TABLE (Status BIT, Message NVARCHAR(500), FinishedGoodLotId BIGINT, ContainerId BIGINT, ContainerTrayId BIGINT, ContainerFull BIT, TraysPerContainer INT);
INSERT INTO @R EXEC Workorder.Assembly_CompleteTray @FinishedGoodItemId = @Out, @PieceCount = 4, @CellLocationId = @Cell, @ClosureMethod = N'ByCount', @AppUserId = 1, @TerminalLocationId = @Cell;
DECLARE @NewLot BIGINT = (SELECT FinishedGoodLotId FROM @R);
DECLARE @c BIT = CASE WHEN (SELECT ContainerId FROM @R) = @OldC
                       AND (SELECT LotId FROM Lots.Container WHERE Id = @OldC) = @NewLot
                       AND @NewLot <> @OldLot
                       AND EXISTS (SELECT 1 FROM Lots.Lot WHERE Id = @OldLot AND PieceCount = 4)
                       AND (SELECT COUNT(*) FROM Lots.ufn_ContainerLots(@OldC)) = 2 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[mixed] old-shape open container gets a container LOT; old tray LOT untouched', @Condition = @c;
GO

-- ---- cleanup ----
DECLARE @Out BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P118-OUT');
DECLARE @A   BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P118-A');
DELETE FROM Workorder.ConsumptionEvent WHERE ProducedItemId = @Out;
DELETE g FROM Lots.LotGenealogy g JOIN Lots.Lot l ON l.Id = g.ChildLotId WHERE l.ItemId = @Out;
DELETE c FROM Lots.LotGenealogyClosure c JOIN Lots.Lot l ON l.Id = c.DescendantLotId WHERE l.ItemId IN (@Out, @A);
DELETE m FROM Lots.LotMovement m JOIN Lots.Lot l ON l.Id = m.LotId WHERE l.ItemId IN (@Out, @A);
DELETE h FROM Lots.LotStatusHistory h JOIN Lots.Lot l ON l.Id = h.LotId WHERE l.ItemId IN (@Out, @A);
DELETE le FROM Lots.LotEventLog le JOIN Lots.Lot l ON l.Id = le.LotId WHERE l.ItemId IN (@Out, @A);
DELETE tr FROM Lots.ContainerTray tr JOIN Lots.Container c ON c.Id = tr.ContainerId WHERE c.ItemId = @Out;
DELETE FROM Lots.Container WHERE ItemId = @Out;
DELETE FROM Lots.Lot WHERE ItemId IN (@Out, @A);
DELETE FROM Oee.Shift WHERE Remarks = N'CT118-SHIFT';
DELETE FROM Oee.ShiftSchedule WHERE Name = N'CT118-SHIFT-SCHED';
GO

EXEC test.PrintSummary;
EXEC test.EndTestFile;
GO
