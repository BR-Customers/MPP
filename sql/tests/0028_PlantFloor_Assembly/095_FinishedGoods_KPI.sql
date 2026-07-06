-- =============================================
-- File:         0028_PlantFloor_Assembly/095_FinishedGoods_KPI.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-07-06
-- Description:  Workorder.FinishedGoods_GetProducedSummary (Spec 2 Task K1). A
--               DERIVED finished-goods KPI: finished-good LOTs are exactly the LOTs
--               referenced by Lots.ContainerTray.FinishedGoodLotId (minted by
--               Assembly_CompleteTray). Two trays are minted at MA1-COMPBR-AOUT
--               (2 FG LOTs x 24 pcs of P6-KPI-OUT), then the KPI is asserted:
--                 - cell + window spanning the mints -> LotCount 2, PartCount 48;
--                 - a DIFFERENT cell -> no row for the FG part;
--                 - a window ENDING before the mints -> no row for the FG part.
--               Fixture mirrors 092 (ContainerConfig + published BOM + eligibility
--               + staged component stock with genealogy-closure self-rows).
--               Fixture cell: MA1-COMPBR-AOUT.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0028_PlantFloor_Assembly/095_FinishedGoods_KPI.sql';
GO

-- ---- cleanup (FK-safe: consumption -> genealogy/closure/movement/history -> trays -> container -> event log -> LOTs) ----
DECLARE @OutC BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-KPI-OUT');
DELETE ce FROM Workorder.ConsumptionEvent ce
    WHERE ce.ProducedItemId = @OutC
       OR ce.ConsumedItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-KPI-A');
DELETE g FROM Lots.LotGenealogy g INNER JOIN Lots.Lot l ON l.Id = g.ChildLotId OR l.Id = g.ParentLotId
    WHERE l.ItemId = @OutC OR l.LotName LIKE N'KPI-STG%';
DELETE c FROM Lots.LotGenealogyClosure c INNER JOIN Lots.Lot l ON l.Id = c.AncestorLotId OR l.Id = c.DescendantLotId
    WHERE l.ItemId = @OutC OR l.LotName LIKE N'KPI-STG%';
DELETE m FROM Lots.LotMovement m INNER JOIN Lots.Lot l ON l.Id = m.LotId
    WHERE l.ItemId = @OutC OR l.LotName LIKE N'KPI-STG%';
DELETE h FROM Lots.LotStatusHistory h INNER JOIN Lots.Lot l ON l.Id = h.LotId
    WHERE l.ItemId = @OutC OR l.LotName LIKE N'KPI-STG%';
DELETE tr FROM Lots.ContainerTray tr INNER JOIN Lots.Container ct ON ct.Id = tr.ContainerId WHERE ct.ItemId = @OutC;
DELETE FROM Lots.Container WHERE ItemId = @OutC;
DELETE le FROM Lots.LotEventLog le INNER JOIN Lots.Lot l ON l.Id = le.LotId WHERE l.ItemId = @OutC OR l.LotName LIKE N'KPI-STG%';
DELETE FROM Lots.Lot WHERE ItemId = @OutC OR LotName LIKE N'KPI-STG%';
GO

-- ---- fixture ----
DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'P6-KPI-OUT') INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId) VALUES (3, N'P6-KPI-OUT', N'K1 finished good', 1, @Now, 1);
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'P6-KPI-A')   INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId) VALUES (3, N'P6-KPI-A', N'K1 component A', 1, @Now, 1);
DECLARE @Out BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-KPI-OUT');
DECLARE @A BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-KPI-A');
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');

-- container config: 4 trays x 24 parts (two mints stay in one Open container)
IF NOT EXISTS (SELECT 1 FROM Parts.ContainerConfig WHERE ItemId = @Out AND DeprecatedAt IS NULL)
    INSERT INTO Parts.ContainerConfig (ItemId, TraysPerContainer, PartsPerTray, IsSerialized, ClosureMethod, CreatedAt) VALUES (@Out, 4, 24, 0, N'ByCount', @Now);

-- published BOM: OUT <- A x1
IF NOT EXISTS (SELECT 1 FROM Parts.Bom WHERE ParentItemId = @Out AND PublishedAt IS NOT NULL AND DeprecatedAt IS NULL)
BEGIN
    INSERT INTO Parts.Bom (ParentItemId, VersionNumber, EffectiveFrom, PublishedAt, CreatedByUserId, CreatedAt) VALUES (@Out, 1, @Now, @Now, 1, @Now);
    DECLARE @BomId BIGINT = SCOPE_IDENTITY();
    INSERT INTO Parts.BomLine (BomId, ChildItemId, QtyPer, UomId, SortOrder) VALUES (@BomId, @A, 1, 1, 1);
END

-- FG item eligible at the cell
IF NOT EXISTS (SELECT 1 FROM Parts.ItemLocation WHERE ItemId = @Out AND LocationId = @Cell AND DeprecatedAt IS NULL)
    INSERT INTO Parts.ItemLocation (ItemId, LocationId, IsConsumptionPoint, CreatedAt) VALUES (@Out, @Cell, 0, @Now);

-- staged component stock at the cell (plenty for 2 trays x 24 = 48)
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId, CreatedAt) VALUES (N'KPI-STGA', @A, 1, 1, 200, 200, @Cell, 1, @Now);
INSERT INTO Lots.LotGenealogyClosure (AncestorLotId, DescendantLotId, Depth)
SELECT Id, Id, 0 FROM Lots.Lot WHERE LotName LIKE N'KPI-STG%'
  AND NOT EXISTS (SELECT 1 FROM Lots.LotGenealogyClosure c WHERE c.AncestorLotId = Lots.Lot.Id AND c.DescendantLotId = Lots.Lot.Id);
GO

-- =============================================
-- Mint two FG LOTs, then assert the KPI
-- =============================================
DECLARE @Out BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-KPI-OUT');
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');

DECLARE @M1 TABLE (Status BIT, Message NVARCHAR(500), FinishedGoodLotId BIGINT, ContainerId BIGINT, ContainerTrayId BIGINT, ContainerFull BIT);
INSERT INTO @M1 EXEC Workorder.Assembly_CompleteTray @FinishedGoodItemId = @Out, @PieceCount = 24, @CellLocationId = @Cell, @AppUserId = 1;
DECLARE @M2 TABLE (Status BIT, Message NVARCHAR(500), FinishedGoodLotId BIGINT, ContainerId BIGINT, ContainerTrayId BIGINT, ContainerFull BIT);
INSERT INTO @M2 EXEC Workorder.Assembly_CompleteTray @FinishedGoodItemId = @Out, @PieceCount = 24, @CellLocationId = @Cell, @AppUserId = 1;

-- both mints succeeded
DECLARE @S1 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @M1);
DECLARE @S2 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @M2);
EXEC test.Assert_IsEqual @TestName = N'[FgKpi] mint 1 succeeded', @Expected = N'1', @Actual = @S1;
EXEC test.Assert_IsEqual @TestName = N'[FgKpi] mint 2 succeeded', @Expected = N'1', @Actual = @S2;

-- window that spans the two mints (derived from the minted LOTs' actual CreatedAt)
DECLARE @WinStart DATETIME2(3) = (SELECT DATEADD(MINUTE, -1, MIN(CreatedAt)) FROM Lots.Lot WHERE ItemId = @Out);
DECLARE @WinEnd   DATETIME2(3) = (SELECT DATEADD(MINUTE,  1, MAX(CreatedAt)) FROM Lots.Lot WHERE ItemId = @Out);
DECLARE @WinBefore DATETIME2(3) = (SELECT MIN(CreatedAt) FROM Lots.Lot WHERE ItemId = @Out);  -- CreatedAt < this excludes all

-- ---- KPI 1: cell + spanning window -> LotCount 2, PartCount 48 ----
CREATE TABLE #k1 (ItemId BIGINT, PartNumber NVARCHAR(50), Description NVARCHAR(500), LotCount INT, PartCount INT);
INSERT INTO #k1 EXEC Workorder.FinishedGoods_GetProducedSummary @CellLocationId = @Cell, @ShiftStartUtc = @WinStart, @ShiftEndUtc = @WinEnd;

DECLARE @Lc NVARCHAR(10) = (SELECT CAST(LotCount AS NVARCHAR(10)) FROM #k1 WHERE PartNumber = N'P6-KPI-OUT');
EXEC test.Assert_IsEqual @TestName = N'[FgKpi] LotCount 2 for the FG part', @Expected = N'2', @Actual = @Lc;
DECLARE @Pc NVARCHAR(10) = (SELECT CAST(PartCount AS NVARCHAR(10)) FROM #k1 WHERE PartNumber = N'P6-KPI-OUT');
EXEC test.Assert_IsEqual @TestName = N'[FgKpi] PartCount 48 for the FG part', @Expected = N'48', @Actual = @Pc;
DROP TABLE #k1;

-- ---- KPI 2: a different cell -> no row for the FG part ----
DECLARE @OtherCell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-MIN');
CREATE TABLE #k2 (ItemId BIGINT, PartNumber NVARCHAR(50), Description NVARCHAR(500), LotCount INT, PartCount INT);
INSERT INTO #k2 EXEC Workorder.FinishedGoods_GetProducedSummary @CellLocationId = @OtherCell, @ShiftStartUtc = @WinStart, @ShiftEndUtc = @WinEnd;
DECLARE @OtherRows NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #k2 WHERE PartNumber = N'P6-KPI-OUT');
EXEC test.Assert_IsEqual @TestName = N'[FgKpi] different cell returns no FG-part row', @Expected = N'0', @Actual = @OtherRows;
DROP TABLE #k2;

-- ---- KPI 3: window ending before the mints -> no row for the FG part ----
CREATE TABLE #k3 (ItemId BIGINT, PartNumber NVARCHAR(50), Description NVARCHAR(500), LotCount INT, PartCount INT);
INSERT INTO #k3 EXEC Workorder.FinishedGoods_GetProducedSummary @CellLocationId = @Cell, @ShiftStartUtc = @WinStart, @ShiftEndUtc = @WinBefore;
DECLARE @BeforeRows NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #k3 WHERE PartNumber = N'P6-KPI-OUT');
EXEC test.Assert_IsEqual @TestName = N'[FgKpi] window before mints returns no FG-part row', @Expected = N'0', @Actual = @BeforeRows;
DROP TABLE #k3;
GO

-- ---- cleanup ----
DECLARE @OutC BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-KPI-OUT');
DELETE ce FROM Workorder.ConsumptionEvent ce
    WHERE ce.ProducedItemId = @OutC
       OR ce.ConsumedItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-KPI-A');
DELETE g FROM Lots.LotGenealogy g INNER JOIN Lots.Lot l ON l.Id = g.ChildLotId OR l.Id = g.ParentLotId
    WHERE l.ItemId = @OutC OR l.LotName LIKE N'KPI-STG%';
DELETE c FROM Lots.LotGenealogyClosure c INNER JOIN Lots.Lot l ON l.Id = c.AncestorLotId OR l.Id = c.DescendantLotId
    WHERE l.ItemId = @OutC OR l.LotName LIKE N'KPI-STG%';
DELETE m FROM Lots.LotMovement m INNER JOIN Lots.Lot l ON l.Id = m.LotId
    WHERE l.ItemId = @OutC OR l.LotName LIKE N'KPI-STG%';
DELETE h FROM Lots.LotStatusHistory h INNER JOIN Lots.Lot l ON l.Id = h.LotId
    WHERE l.ItemId = @OutC OR l.LotName LIKE N'KPI-STG%';
DELETE tr FROM Lots.ContainerTray tr INNER JOIN Lots.Container ct ON ct.Id = tr.ContainerId WHERE ct.ItemId = @OutC;
DELETE FROM Lots.Container WHERE ItemId = @OutC;
DELETE le FROM Lots.LotEventLog le INNER JOIN Lots.Lot l ON l.Id = le.LotId WHERE l.ItemId = @OutC OR l.LotName LIKE N'KPI-STG%';
DELETE FROM Lots.Lot WHERE ItemId = @OutC OR LotName LIKE N'KPI-STG%';
GO

EXEC test.EndTestFile;
GO
