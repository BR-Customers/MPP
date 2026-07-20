-- =============================================
-- File:         0028_PlantFloor_Assembly/092_Assembly_CompleteTray.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-07-06
-- Description:  Workorder.Assembly_CompleteTray (Spec 2 Task A2). Tray completion
--               MINTS a finished-good LOT (tray = LOT), consumes BOM x PieceCount
--               FIFO from component stock at the cell INTO that LOT, attaches the
--               tray to the cell's open Container (auto-open), and reports
--               @ContainerFull WITHOUT completing the container (delegation to
--               Lots.Container_Complete). Covers: mint + FIFO consume (oldest LOT
--               drained, next partially) + genealogy (Consumption edges/closure) +
--               tray<->LOT link + container-full flag on the 2nd tray + container
--               left Open (delegation) + insufficient-stock rollback.
--               Fixture cell: MA1-COMPBR-AOUT (assembly-out).
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0028_PlantFloor_Assembly/092_Assembly_CompleteTray.sql';
GO

-- ---- cleanup (FK-safe: consumption -> genealogy/closure/movement/history -> trays -> container -> LOTs) ----
DECLARE @OutC BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-CT-OUT');
DECLARE @ShortC BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-CT-SHORT');
DELETE ce FROM Workorder.ConsumptionEvent ce
    WHERE ce.ProducedItemId IN (@OutC, @ShortC)
       OR ce.ConsumedItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber IN (N'P6-CT-A', N'P6-CT-B', N'P6-CT-SC'));
DELETE g FROM Lots.LotGenealogy g INNER JOIN Lots.Lot l ON l.Id = g.ChildLotId OR l.Id = g.ParentLotId
    WHERE l.ItemId IN (@OutC, @ShortC) OR l.LotName LIKE N'STG-092%';
DELETE c FROM Lots.LotGenealogyClosure c INNER JOIN Lots.Lot l ON l.Id = c.AncestorLotId OR l.Id = c.DescendantLotId
    WHERE l.ItemId IN (@OutC, @ShortC) OR l.LotName LIKE N'STG-092%';
DELETE m FROM Lots.LotMovement m INNER JOIN Lots.Lot l ON l.Id = m.LotId
    WHERE l.ItemId IN (@OutC, @ShortC) OR l.LotName LIKE N'STG-092%';
DELETE h FROM Lots.LotStatusHistory h INNER JOIN Lots.Lot l ON l.Id = h.LotId
    WHERE l.ItemId IN (@OutC, @ShortC) OR l.LotName LIKE N'STG-092%';
DELETE tr FROM Lots.ContainerTray tr INNER JOIN Lots.Container ct ON ct.Id = tr.ContainerId WHERE ct.ItemId IN (@OutC, @ShortC);
DELETE FROM Lots.Container WHERE ItemId IN (@OutC, @ShortC);
DELETE le FROM Lots.LotEventLog le INNER JOIN Lots.Lot l ON l.Id = le.LotId WHERE l.ItemId IN (@OutC, @ShortC) OR l.LotName LIKE N'STG-092%';
DELETE FROM Lots.Lot WHERE ItemId IN (@OutC, @ShortC) OR LotName LIKE N'STG-092%';
GO

-- ---- fixture ----
DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'P6-CT-OUT') INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId) VALUES (3, N'P6-CT-OUT', N'A2 finished good', 1, @Now, 1);
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'P6-CT-A')   INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId) VALUES (3, N'P6-CT-A', N'A2 component A', 1, @Now, 1);
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'P6-CT-B')   INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId) VALUES (3, N'P6-CT-B', N'A2 component B', 1, @Now, 1);
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'P6-CT-SHORT') INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId) VALUES (3, N'P6-CT-SHORT', N'A2 short-stock finished good', 1, @Now, 1);
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'P6-CT-SC')  INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId) VALUES (3, N'P6-CT-SC', N'A2 short component', 1, @Now, 1);
DECLARE @Out BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-CT-OUT');
DECLARE @A BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-CT-A');
DECLARE @B BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-CT-B');
DECLARE @Short BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-CT-SHORT');
DECLARE @SC BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-CT-SC');
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');

-- container config: 2 trays x 24 parts
IF NOT EXISTS (SELECT 1 FROM Parts.ContainerConfig WHERE ItemId = @Out AND DeprecatedAt IS NULL)
    INSERT INTO Parts.ContainerConfig (ItemId, TraysPerContainer, PartsPerTray, IsSerialized, ClosureMethod, CreatedAt) VALUES (@Out, 2, 24, 0, N'ByCount', @Now);
IF NOT EXISTS (SELECT 1 FROM Parts.ContainerConfig WHERE ItemId = @Short AND DeprecatedAt IS NULL)
    INSERT INTO Parts.ContainerConfig (ItemId, TraysPerContainer, PartsPerTray, IsSerialized, ClosureMethod, CreatedAt) VALUES (@Short, 1, 24, 0, N'ByCount', @Now);

-- published BOM: OUT <- A x1 + B x2 ;  SHORT <- SC x1
IF NOT EXISTS (SELECT 1 FROM Parts.Bom WHERE ParentItemId = @Out AND PublishedAt IS NOT NULL AND DeprecatedAt IS NULL)
BEGIN
    INSERT INTO Parts.Bom (ParentItemId, VersionNumber, EffectiveFrom, PublishedAt, CreatedByUserId, CreatedAt) VALUES (@Out, 1, @Now, @Now, 1, @Now);
    DECLARE @BomId BIGINT = SCOPE_IDENTITY();
    INSERT INTO Parts.BomLine (BomId, ChildItemId, QtyPer, UomId, SortOrder) VALUES (@BomId, @A, 1, 1, 1), (@BomId, @B, 2, 1, 2);
END
IF NOT EXISTS (SELECT 1 FROM Parts.Bom WHERE ParentItemId = @Short AND PublishedAt IS NOT NULL AND DeprecatedAt IS NULL)
BEGIN
    INSERT INTO Parts.Bom (ParentItemId, VersionNumber, EffectiveFrom, PublishedAt, CreatedByUserId, CreatedAt) VALUES (@Short, 1, @Now, @Now, 1, @Now);
    DECLARE @BomIdS BIGINT = SCOPE_IDENTITY();
    INSERT INTO Parts.BomLine (BomId, ChildItemId, QtyPer, UomId, SortOrder) VALUES (@BomIdS, @SC, 1, 1, 1);
END

-- FG items eligible at the cell (A2 mirrors Lot_Create eligibility)
IF NOT EXISTS (SELECT 1 FROM Parts.ItemLocation WHERE ItemId = @Out AND LocationId = @Cell AND DeprecatedAt IS NULL)
    INSERT INTO Parts.ItemLocation (ItemId, LocationId, IsConsumptionPoint, CreatedAt) VALUES (@Out, @Cell, 0, @Now);
IF NOT EXISTS (SELECT 1 FROM Parts.ItemLocation WHERE ItemId = @Short AND LocationId = @Cell AND DeprecatedAt IS NULL)
    INSERT INTO Parts.ItemLocation (ItemId, LocationId, IsConsumptionPoint, CreatedAt) VALUES (@Short, @Cell, 0, @Now);

-- staged component stock at the cell (BOTH PieceCount + InventoryAvailable set, as real LOTs are).
-- A as TWO LOTs to prove FIFO: A1=10 (older) drains fully, A2=40 (newer) partially. B single 96.
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId, CreatedAt) VALUES (N'STG-092A1', @A, 1, 1, 10, 10, @Cell, 1, @Now);
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId, CreatedAt) VALUES (N'STG-092A2', @A, 1, 1, 40, 40, @Cell, 1, DATEADD(SECOND, 5, @Now));
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId, CreatedAt) VALUES (N'STG-092B', @B, 1, 1, 96, 96, @Cell, 1, @Now);
-- SHORT component: only 5 available (< 24 needed) -> insufficient
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId, CreatedAt) VALUES (N'STG-092SC', @SC, 1, 1, 5, 5, @Cell, 1, @Now);

-- staged LOTs need genealogy closure self-rows (real LOTs get these from Lot_Create;
-- the consumption closure propagation reads them to link source ancestors -> FG LOT).
INSERT INTO Lots.LotGenealogyClosure (AncestorLotId, DescendantLotId, Depth)
SELECT Id, Id, 0 FROM Lots.Lot WHERE LotName LIKE N'STG-092%'
  AND NOT EXISTS (SELECT 1 FROM Lots.LotGenealogyClosure c WHERE c.AncestorLotId = Lots.Lot.Id AND c.DescendantLotId = Lots.Lot.Id);
GO

-- =============================================
-- Test 1: happy path - tray 1 mints FG LOT, consumes BOM FIFO, container not full
-- =============================================
DECLARE @Out BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-CT-OUT');
DECLARE @A BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-CT-A');
DECLARE @B BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-CT-B');
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');

DECLARE @R1 TABLE (Status BIT, Message NVARCHAR(500), FinishedGoodLotId BIGINT, ContainerId BIGINT, ContainerTrayId BIGINT, ContainerFull BIT);
INSERT INTO @R1 EXEC Workorder.Assembly_CompleteTray @FinishedGoodItemId = @Out, @PieceCount = 24, @CellLocationId = @Cell, @ClosureMethod = N'ByCount', @AppUserId = 1;

DECLARE @S1 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @R1);
EXEC test.Assert_IsEqual @TestName = N'[CompleteTray] tray-1 Status 1', @Expected = N'1', @Actual = @S1;

DECLARE @Fg1 BIGINT = (SELECT FinishedGoodLotId FROM @R1);
DECLARE @Cid BIGINT = (SELECT ContainerId FROM @R1);
DECLARE @Tid BIGINT = (SELECT ContainerTrayId FROM @R1);
DECLARE @OutStr NVARCHAR(20) = CAST(@Out AS NVARCHAR(20));
DECLARE @Fg1Str NVARCHAR(20) = CAST(@Fg1 AS NVARCHAR(20));

-- FG LOT: right item, 24 pcs, Manufactured origin, Good status
DECLARE @FgItem NVARCHAR(20) = (SELECT CAST(ItemId AS NVARCHAR(20)) FROM Lots.Lot WHERE Id = @Fg1);
EXEC test.Assert_IsEqual @TestName = N'[CompleteTray] FG LOT carries the finished-good Item', @Expected = @OutStr, @Actual = @FgItem;
DECLARE @FgPc NVARCHAR(10) = (SELECT CAST(PieceCount AS NVARCHAR(10)) FROM Lots.Lot WHERE Id = @Fg1);
EXEC test.Assert_IsEqual @TestName = N'[CompleteTray] FG LOT PieceCount 24', @Expected = N'24', @Actual = @FgPc;
DECLARE @FgOrigin NVARCHAR(20) = (SELECT ot.Code FROM Lots.Lot l INNER JOIN Lots.LotOriginType ot ON ot.Id = l.LotOriginTypeId WHERE l.Id = @Fg1);
EXEC test.Assert_IsEqual @TestName = N'[CompleteTray] FG LOT origin Manufactured', @Expected = N'Manufactured', @Actual = @FgOrigin;
DECLARE @FgStatus NVARCHAR(20) = (SELECT sc.Code FROM Lots.Lot l INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId WHERE l.Id = @Fg1);
EXEC test.Assert_IsEqual @TestName = N'[CompleteTray] FG LOT status Good', @Expected = N'Good', @Actual = @FgStatus;

-- tray links to the FG LOT 1:1
DECLARE @TrayFg NVARCHAR(20) = (SELECT CAST(FinishedGoodLotId AS NVARCHAR(20)) FROM Lots.ContainerTray WHERE Id = @Tid);
EXEC test.Assert_IsEqual @TestName = N'[CompleteTray] tray.FinishedGoodLotId = minted FG LOT', @Expected = @Fg1Str, @Actual = @TrayFg;

-- consumption targets the FG LOT (ProducedLotId), A=24 (x1), B=48 (x2)
DECLARE @AConsumed NVARCHAR(10) = (SELECT CAST(ISNULL(SUM(PieceCount),0) AS NVARCHAR(10)) FROM Workorder.ConsumptionEvent WHERE ProducedLotId = @Fg1 AND ConsumedItemId = @A);
EXEC test.Assert_IsEqual @TestName = N'[CompleteTray] component A consumed 24 into FG LOT', @Expected = N'24', @Actual = @AConsumed;
DECLARE @BConsumed NVARCHAR(10) = (SELECT CAST(ISNULL(SUM(PieceCount),0) AS NVARCHAR(10)) FROM Workorder.ConsumptionEvent WHERE ProducedLotId = @Fg1 AND ConsumedItemId = @B);
EXEC test.Assert_IsEqual @TestName = N'[CompleteTray] component B consumed 48 into FG LOT', @Expected = N'48', @Actual = @BConsumed;

-- FIFO: oldest A LOT (STG-092A1, 10) drained to 0 + Closed; next (STG-092A2) partial 40 -> 26
DECLARE @A1Pc NVARCHAR(10) = (SELECT CAST(PieceCount AS NVARCHAR(10)) FROM Lots.Lot WHERE LotName = N'STG-092A1');
EXEC test.Assert_IsEqual @TestName = N'[CompleteTray] FIFO oldest A LOT drained to 0', @Expected = N'0', @Actual = @A1Pc;
DECLARE @A1Status NVARCHAR(20) = (SELECT sc.Code FROM Lots.Lot l INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId WHERE l.LotName = N'STG-092A1');
EXEC test.Assert_IsEqual @TestName = N'[CompleteTray] drained A LOT Closed', @Expected = N'Closed', @Actual = @A1Status;
DECLARE @A2Pc NVARCHAR(10) = (SELECT CAST(PieceCount AS NVARCHAR(10)) FROM Lots.Lot WHERE LotName = N'STG-092A2');
EXEC test.Assert_IsEqual @TestName = N'[CompleteTray] next A LOT partially consumed 40 -> 26', @Expected = N'26', @Actual = @A2Pc;

-- genealogy: 3 Consumption edges (A1, A2, B) -> FG LOT (RelationshipTypeId=3)
DECLARE @Edges NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Lots.LotGenealogy WHERE ChildLotId = @Fg1 AND RelationshipTypeId = 3);
EXEC test.Assert_IsEqual @TestName = N'[CompleteTray] three Consumption genealogy edges -> FG LOT', @Expected = N'3', @Actual = @Edges;
-- closure includes component ancestors -> FG LOT (self-row + 3 sources = 4 rows terminating at FG LOT)
DECLARE @ClosAnc NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Lots.LotGenealogyClosure WHERE DescendantLotId = @Fg1);
EXEC test.Assert_IsEqual @TestName = N'[CompleteTray] closure has FG-LOT self-row + 3 component ancestors', @Expected = N'4', @Actual = @ClosAnc;

-- container not full after 1 of 2 trays; container still Open
DECLARE @Full1 NVARCHAR(10) = (SELECT CAST(ContainerFull AS NVARCHAR(10)) FROM @R1);
EXEC test.Assert_IsEqual @TestName = N'[CompleteTray] container NOT full after tray 1', @Expected = N'0', @Actual = @Full1;
DECLARE @CStat1 NVARCHAR(10) = (SELECT CAST(ContainerStatusCodeId AS NVARCHAR(10)) FROM Lots.Container WHERE Id = @Cid);
EXEC test.Assert_IsEqual @TestName = N'[CompleteTray] container still Open (1) after tray 1', @Expected = N'1', @Actual = @CStat1;
GO

-- =============================================
-- Test 2: tray 2 fills the container -> ContainerFull=1, but container left Open (delegation)
-- =============================================
DECLARE @Out BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-CT-OUT');
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');

DECLARE @R2 TABLE (Status BIT, Message NVARCHAR(500), FinishedGoodLotId BIGINT, ContainerId BIGINT, ContainerTrayId BIGINT, ContainerFull BIT);
INSERT INTO @R2 EXEC Workorder.Assembly_CompleteTray @FinishedGoodItemId = @Out, @PieceCount = 24, @CellLocationId = @Cell, @ClosureMethod = N'ByCount', @AppUserId = 1;

DECLARE @S2 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @R2);
EXEC test.Assert_IsEqual @TestName = N'[CompleteTray] tray-2 Status 1', @Expected = N'1', @Actual = @S2;
DECLARE @Full2 NVARCHAR(10) = (SELECT CAST(ContainerFull AS NVARCHAR(10)) FROM @R2);
EXEC test.Assert_IsEqual @TestName = N'[CompleteTray] container FULL after tray 2', @Expected = N'1', @Actual = @Full2;

-- same container reused (both trays); a second distinct FG LOT minted
DECLARE @Cid2 BIGINT = (SELECT ContainerId FROM @R2);
DECLARE @Fg2 BIGINT = (SELECT FinishedGoodLotId FROM @R2);
DECLARE @TrayCount NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Lots.ContainerTray WHERE ContainerId = @Cid2);
EXEC test.Assert_IsEqual @TestName = N'[CompleteTray] two trays on the container', @Expected = N'2', @Actual = @TrayCount;
DECLARE @DistinctFg NVARCHAR(10) = (SELECT CAST(COUNT(DISTINCT FinishedGoodLotId) AS NVARCHAR(10)) FROM Lots.ContainerTray WHERE ContainerId = @Cid2);
EXEC test.Assert_IsEqual @TestName = N'[CompleteTray] two distinct FG LOTs (one per tray)', @Expected = N'2', @Actual = @DistinctFg;

-- DELEGATION: A2 did NOT complete the container - still Open (1), no ShippingLabel
DECLARE @CStat2 NVARCHAR(10) = (SELECT CAST(ContainerStatusCodeId AS NVARCHAR(10)) FROM Lots.Container WHERE Id = @Cid2);
EXEC test.Assert_IsEqual @TestName = N'[CompleteTray] container LEFT OPEN when full (delegation)', @Expected = N'1', @Actual = @CStat2;
DECLARE @Labels NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Lots.ShippingLabel WHERE ContainerId = @Cid2);
EXEC test.Assert_IsEqual @TestName = N'[CompleteTray] no ShippingLabel created by the orchestrator', @Expected = N'0', @Actual = @Labels;
GO

-- =============================================
-- Test 3: insufficient component stock -> Status 0, nothing minted (rolled back)
-- =============================================
DECLARE @Short BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-CT-SHORT');
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');

DECLARE @R3 TABLE (Status BIT, Message NVARCHAR(500), FinishedGoodLotId BIGINT, ContainerId BIGINT, ContainerTrayId BIGINT, ContainerFull BIT);
INSERT INTO @R3 EXEC Workorder.Assembly_CompleteTray @FinishedGoodItemId = @Short, @PieceCount = 24, @CellLocationId = @Cell, @ClosureMethod = N'ByCount', @AppUserId = 1;

DECLARE @S3 BIT = (SELECT Status FROM @R3);
DECLARE @M3 NVARCHAR(500) = (SELECT Message FROM @R3);
DECLARE @S3cond BIT = CASE WHEN @S3 = 0 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[CompleteTray] insufficient stock rejected (Status 0)', @Condition = @S3cond;
EXEC test.Assert_Contains @TestName = N'[CompleteTray] insufficient-stock message', @HaystackStr = @M3, @NeedleStr = N'Insufficient component stock';
-- no FG LOT minted (rolled back / never opened a txn)
DECLARE @ShortLots NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Lots.Lot WHERE ItemId = @Short);
EXEC test.Assert_IsEqual @TestName = N'[CompleteTray] no FG LOT minted on insufficient stock', @Expected = N'0', @Actual = @ShortLots;
GO

-- ---- cleanup ----
DECLARE @OutC BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-CT-OUT');
DECLARE @ShortC BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-CT-SHORT');
DELETE ce FROM Workorder.ConsumptionEvent ce
    WHERE ce.ProducedItemId IN (@OutC, @ShortC)
       OR ce.ConsumedItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber IN (N'P6-CT-A', N'P6-CT-B', N'P6-CT-SC'));
DELETE g FROM Lots.LotGenealogy g INNER JOIN Lots.Lot l ON l.Id = g.ChildLotId OR l.Id = g.ParentLotId
    WHERE l.ItemId IN (@OutC, @ShortC) OR l.LotName LIKE N'STG-092%';
DELETE c FROM Lots.LotGenealogyClosure c INNER JOIN Lots.Lot l ON l.Id = c.AncestorLotId OR l.Id = c.DescendantLotId
    WHERE l.ItemId IN (@OutC, @ShortC) OR l.LotName LIKE N'STG-092%';
DELETE m FROM Lots.LotMovement m INNER JOIN Lots.Lot l ON l.Id = m.LotId
    WHERE l.ItemId IN (@OutC, @ShortC) OR l.LotName LIKE N'STG-092%';
DELETE h FROM Lots.LotStatusHistory h INNER JOIN Lots.Lot l ON l.Id = h.LotId
    WHERE l.ItemId IN (@OutC, @ShortC) OR l.LotName LIKE N'STG-092%';
DELETE tr FROM Lots.ContainerTray tr INNER JOIN Lots.Container ct ON ct.Id = tr.ContainerId WHERE ct.ItemId IN (@OutC, @ShortC);
DELETE FROM Lots.Container WHERE ItemId IN (@OutC, @ShortC);
DELETE le FROM Lots.LotEventLog le INNER JOIN Lots.Lot l ON l.Id = le.LotId WHERE l.ItemId IN (@OutC, @ShortC) OR l.LotName LIKE N'STG-092%';
DELETE FROM Lots.Lot WHERE ItemId IN (@OutC, @ShortC) OR LotName LIKE N'STG-092%';
GO

EXEC test.EndTestFile;
GO
