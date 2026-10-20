-- =============================================
-- File:         0113_ScaleStation/020_EligibleParts.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-10-19
-- Description:
--   Workorder.ufn_ScaleStationEligibleParts / ScaleStation_ListEligibleParts:
--   which finished goods a By Weight scale station may run (spec §5.1):
--     - eligible at the line (v_EffectiveItemLocation), By Weight pack-out;
--     - at least ONE cast line (Component / SubAssembly) covered;
--     - at least 60% of the other BOM lines covered;
--     - covered = good stock at the line >= QtyPer * PartsPerTray.
--   ReadyRank 1 = the highest share of BOM lines covered.
--
--   Fixture (own line + terminal so no seeded data interferes):
--     TST-SS-LINE / TST-SS-AOUT
--     FG-A: C1, C2 (Component) + P1..P5 (PassThrough), 10 per tray
--     FG-B: C1 + P1, 10 per tray
--     FG-N: as FG-B but ByCount only  -> never eligible
--     FG-X: as FG-B, ByWeight, NOT set up at the line -> never eligible
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0113_ScaleStation/020_EligibleParts.sql';
GO

-- ---- reset the fixture's operational data (shared with 030/040) ----
-- The fixture's locations and parts are built once and kept: once 040 has
-- run, audit rows point at the terminal, so it can never be deleted again.
-- Only stock, boxes and the override are cleared between runs.
DECLARE @Term BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TST-SS-AOUT');
DECLARE @Line BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TST-SS-LINE');
DELETE FROM Audit.InterfaceLog WHERE LocationId = @Term;          -- 050's press rows (FK to the LOTs)
DELETE sl FROM Lots.ShippingLabel sl JOIN Lots.Container c ON c.Id = sl.ContainerId WHERE c.CurrentLocationId = @Line;
DELETE tr FROM Lots.ContainerTray tr JOIN Lots.Container c ON c.Id = tr.ContainerId WHERE c.CurrentLocationId = @Line;
DELETE FROM Lots.Container WHERE CurrentLocationId = @Line;
DELETE cl FROM Lots.LotGenealogyClosure cl JOIN Lots.Lot l ON l.Id = cl.AncestorLotId OR l.Id = cl.DescendantLotId WHERE l.CurrentLocationId = @Line;
DELETE FROM Lots.Lot WHERE CurrentLocationId = @Line;
DELETE FROM Location.LocationAttribute WHERE LocationId = @Term;
GO

-- ---- fixture build: every piece created only if missing ----
DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
DECLARE @Area BIGINT = (SELECT TOP 1 Id FROM Location.Location WHERE LocationTypeDefinitionId = 3 AND DeprecatedAt IS NULL ORDER BY Id);
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'TST-SS-LINE')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, SortOrder, CreatedAt)
    VALUES (5, @Area, N'Scale station test line', N'TST-SS-LINE', 999, @Now);
DECLARE @Line BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TST-SS-LINE');
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'TST-SS-AOUT')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, SortOrder, CreatedAt)
    VALUES (7, @Line, N'Scale station test terminal', N'TST-SS-AOUT', 1, @Now);

DECLARE @Fg BIGINT = (SELECT Id FROM Parts.ItemType WHERE Code = N'FinishedGood');
DECLARE @Comp BIGINT = (SELECT Id FROM Parts.ItemType WHERE Code = N'Component');
DECLARE @Pass BIGINT = (SELECT Id FROM Parts.ItemType WHERE Code = N'PassThrough');
INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId)
SELECT v.TypeId, v.PartNumber, v.Description, 1, @Now, 1
FROM (VALUES (@Fg, N'TST-SS-FG-A', N'Scale test FG A'),
             (@Fg, N'TST-SS-FG-B', N'Scale test FG B'),
             (@Fg, N'TST-SS-FG-N', N'Scale test FG no ByWeight'),
             (@Fg, N'TST-SS-FG-X', N'Scale test FG not at line'),
             (@Comp, N'TST-SS-C1', N'cast 1'), (@Comp, N'TST-SS-C2', N'cast 2'),
             (@Pass, N'TST-SS-P1', N'bought 1'), (@Pass, N'TST-SS-P2', N'bought 2'),
             (@Pass, N'TST-SS-P3', N'bought 3'), (@Pass, N'TST-SS-P4', N'bought 4'),
             (@Pass, N'TST-SS-P5', N'bought 5')) v (TypeId, PartNumber, Description)
WHERE NOT EXISTS (SELECT 1 FROM Parts.Item i WHERE i.PartNumber = v.PartNumber);

-- pack-outs: A/B/X ByWeight 4 x 10, 18.25 +/- 0.5; N ByCount only
INSERT INTO Parts.ContainerConfig (ItemId, TraysPerContainer, PartsPerTray, IsSerialized, ClosureMethod, TargetWeight, ToleranceWeight, CreatedAt)
SELECT i.Id, 4, 10, 0, CASE WHEN i.PartNumber = N'TST-SS-FG-N' THEN N'ByCount' ELSE N'ByWeight' END, 18.25, 0.5, @Now
FROM Parts.Item i
WHERE i.PartNumber IN (N'TST-SS-FG-A', N'TST-SS-FG-B', N'TST-SS-FG-N', N'TST-SS-FG-X')
  AND NOT EXISTS (SELECT 1 FROM Parts.ContainerConfig cc WHERE cc.ItemId = i.Id AND cc.DeprecatedAt IS NULL);

-- set up at the line: A, B, N (not X)
INSERT INTO Parts.ItemLocation (ItemId, LocationId, IsConsumptionPoint, CreatedAt)
SELECT i.Id, @Line, 0, @Now FROM Parts.Item i
WHERE i.PartNumber IN (N'TST-SS-FG-A', N'TST-SS-FG-B', N'TST-SS-FG-N')
  AND NOT EXISTS (SELECT 1 FROM Parts.ItemLocation il WHERE il.ItemId = i.Id AND il.LocationId = @Line AND il.DeprecatedAt IS NULL);

-- published BOMs
INSERT INTO Parts.Bom (ParentItemId, VersionNumber, EffectiveFrom, PublishedAt, CreatedByUserId, CreatedAt)
SELECT i.Id, 1, @Now, @Now, 1, @Now FROM Parts.Item i
WHERE i.PartNumber IN (N'TST-SS-FG-A', N'TST-SS-FG-B', N'TST-SS-FG-N', N'TST-SS-FG-X')
  AND NOT EXISTS (SELECT 1 FROM Parts.Bom b WHERE b.ParentItemId = i.Id);
INSERT INTO Parts.BomLine (BomId, ChildItemId, QtyPer, UomId, SortOrder)
SELECT b.Id, c.Id, 1, 1, ROW_NUMBER() OVER (PARTITION BY b.Id ORDER BY c.PartNumber)
FROM Parts.Bom b JOIN Parts.Item p ON p.Id = b.ParentItemId
JOIN Parts.Item c ON (p.PartNumber = N'TST-SS-FG-A' AND c.PartNumber IN (N'TST-SS-C1', N'TST-SS-C2', N'TST-SS-P1', N'TST-SS-P2', N'TST-SS-P3', N'TST-SS-P4', N'TST-SS-P5'))
                  OR (p.PartNumber <> N'TST-SS-FG-A' AND c.PartNumber IN (N'TST-SS-C1', N'TST-SS-P1'))
WHERE p.PartNumber LIKE N'TST-SS-FG-%'
  AND NOT EXISTS (SELECT 1 FROM Parts.BomLine x WHERE x.BomId = b.Id);
GO

-- Stock helper pattern: #Stock(PartNumber, Qty) -> replace all fixture LOTs at the line.
CREATE TABLE #Stock (PartNumber NVARCHAR(50), Qty INT);
CREATE TABLE #E (ItemId BIGINT, PartNumber NVARCHAR(50), Description NVARCHAR(500), PartsPerTray INT, TraysPerContainer INT,
                 TargetWeight DECIMAL(10,4), ToleranceWeight DECIMAL(10,4), LinesTotal INT, LinesCovered INT,
                 ShareCovered DECIMAL(5,4), CastLinesCovered INT, TraysCovered INT, ReadyRank BIGINT,
                 LowLimit DECIMAL(10,4), HighLimit DECIMAL(10,4));
GO

-- ==== Test 1: cast line uncovered -> FG-A not eligible ====
DELETE FROM #Stock; INSERT INTO #Stock VALUES (N'TST-SS-P1',100),(N'TST-SS-P2',100),(N'TST-SS-P3',100),(N'TST-SS-P4',100),(N'TST-SS-P5',100);
DECLARE @Line BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TST-SS-LINE');
DECLARE @Term BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TST-SS-AOUT');
DECLARE @Good BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Good');
DECLARE @Rcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
DELETE FROM Lots.Lot WHERE CurrentLocationId = @Line;
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId)
SELECT N'TSS-' + RIGHT(s.PartNumber, 2) + N'-' + LEFT(CAST(NEWID() AS NVARCHAR(36)), 8), i.Id, @Rcv, @Good, s.Qty, s.Qty, @Line, 1
FROM #Stock s JOIN Parts.Item i ON i.PartNumber = s.PartNumber;
DELETE FROM #E; INSERT INTO #E EXEC Workorder.ScaleStation_ListEligibleParts @TerminalLocationId = @Term;
DECLARE @N NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #E WHERE PartNumber = N'TST-SS-FG-A');
EXEC test.Assert_IsEqual @TestName = N'[Elig] cast line uncovered -> not eligible', @Expected = N'0', @Actual = @N;
GO

-- ==== Test 2: one of two cast lines + 3 of 5 others (60%) -> eligible ====
DELETE FROM #Stock; INSERT INTO #Stock VALUES (N'TST-SS-C2',10),(N'TST-SS-P1',10),(N'TST-SS-P2',10),(N'TST-SS-P3',10);
DECLARE @Line BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TST-SS-LINE');
DECLARE @Term BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TST-SS-AOUT');
DECLARE @Good BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Good');
DECLARE @Rcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
DELETE FROM Lots.Lot WHERE CurrentLocationId = @Line;
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId)
SELECT N'TSS-' + RIGHT(s.PartNumber, 2) + N'-' + LEFT(CAST(NEWID() AS NVARCHAR(36)), 8), i.Id, @Rcv, @Good, s.Qty, s.Qty, @Line, 1
FROM #Stock s JOIN Parts.Item i ON i.PartNumber = s.PartNumber;
DELETE FROM #E; INSERT INTO #E EXEC Workorder.ScaleStation_ListEligibleParts @TerminalLocationId = @Term;
DECLARE @S NVARCHAR(60) = (SELECT CONCAT(LinesCovered, N'/', LinesTotal, N' cast', CastLinesCovered, N' trays', TraysCovered)
                           FROM #E WHERE PartNumber = N'TST-SS-FG-A');
EXEC test.Assert_IsEqual @TestName = N'[Elig] one of two cast lines covered + 60% others -> eligible',
    @Expected = N'4/7 cast1 trays0', @Actual = @S;
DECLARE @W NVARCHAR(40) = (SELECT CONCAT(LowLimit, N'-', HighLimit) FROM #E WHERE PartNumber = N'TST-SS-FG-A');
EXEC test.Assert_IsEqual @TestName = N'[Elig] list carries the window', @Expected = N'17.7500-18.7500', @Actual = @W;
GO

-- ==== Test 3: 2 of 5 others (40%) -> not eligible ====
DELETE FROM #Stock; INSERT INTO #Stock VALUES (N'TST-SS-C2',10),(N'TST-SS-P1',10),(N'TST-SS-P2',10);
DECLARE @Line BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TST-SS-LINE');
DECLARE @Term BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TST-SS-AOUT');
DECLARE @Good BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Good');
DECLARE @Rcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
DELETE FROM Lots.Lot WHERE CurrentLocationId = @Line;
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId)
SELECT N'TSS-' + RIGHT(s.PartNumber, 2) + N'-' + LEFT(CAST(NEWID() AS NVARCHAR(36)), 8), i.Id, @Rcv, @Good, s.Qty, s.Qty, @Line, 1
FROM #Stock s JOIN Parts.Item i ON i.PartNumber = s.PartNumber;
DELETE FROM #E; INSERT INTO #E EXEC Workorder.ScaleStation_ListEligibleParts @TerminalLocationId = @Term;
DECLARE @N NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #E WHERE PartNumber = N'TST-SS-FG-A');
EXEC test.Assert_IsEqual @TestName = N'[Elig] 40% of other lines -> not eligible', @Expected = N'0', @Actual = @N;
GO

-- ==== Test 4: cast stock one short of a tray -> uncovered ====
DELETE FROM #Stock; INSERT INTO #Stock VALUES (N'TST-SS-C2',9),(N'TST-SS-P1',10),(N'TST-SS-P2',10),(N'TST-SS-P3',10),(N'TST-SS-P4',10),(N'TST-SS-P5',10);
DECLARE @Line BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TST-SS-LINE');
DECLARE @Term BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TST-SS-AOUT');
DECLARE @Good BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Good');
DECLARE @Rcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
DELETE FROM Lots.Lot WHERE CurrentLocationId = @Line;
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId)
SELECT N'TSS-' + RIGHT(s.PartNumber, 2) + N'-' + LEFT(CAST(NEWID() AS NVARCHAR(36)), 8), i.Id, @Rcv, @Good, s.Qty, s.Qty, @Line, 1
FROM #Stock s JOIN Parts.Item i ON i.PartNumber = s.PartNumber;
DELETE FROM #E; INSERT INTO #E EXEC Workorder.ScaleStation_ListEligibleParts @TerminalLocationId = @Term;
DECLARE @N NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #E WHERE PartNumber = N'TST-SS-FG-A');
EXEC test.Assert_IsEqual @TestName = N'[Elig] covered needs QtyPer*PartsPerTray', @Expected = N'0', @Actual = @N;
GO

-- ==== Test 5: held stock does not count ====
DELETE FROM #Stock; INSERT INTO #Stock VALUES (N'TST-SS-C1',10),(N'TST-SS-P1',10);
DECLARE @Line BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TST-SS-LINE');
DECLARE @Term BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TST-SS-AOUT');
DECLARE @Hold BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Hold');
DECLARE @Rcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
DELETE FROM Lots.Lot WHERE CurrentLocationId = @Line;
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId)
SELECT N'TSS-' + RIGHT(s.PartNumber, 2) + N'-' + LEFT(CAST(NEWID() AS NVARCHAR(36)), 8), i.Id, @Rcv, @Hold, s.Qty, s.Qty, @Line, 1
FROM #Stock s JOIN Parts.Item i ON i.PartNumber = s.PartNumber;
DELETE FROM #E; INSERT INTO #E EXEC Workorder.ScaleStation_ListEligibleParts @TerminalLocationId = @Term;
DECLARE @N NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #E WHERE PartNumber = N'TST-SS-FG-B');
EXEC test.Assert_IsEqual @TestName = N'[Elig] held stock does not count', @Expected = N'0', @Actual = @N;
GO

-- ==== Test 6: ranking + exclusions with FG-A (4/7) and FG-B (2/2) both eligible ====
DELETE FROM #Stock; INSERT INTO #Stock VALUES (N'TST-SS-C1',10),(N'TST-SS-C2',10),(N'TST-SS-P1',10),(N'TST-SS-P2',10),(N'TST-SS-P3',10);
DECLARE @Line BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TST-SS-LINE');
DECLARE @Term BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TST-SS-AOUT');
DECLARE @Good BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Good');
DECLARE @Rcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
DELETE FROM Lots.Lot WHERE CurrentLocationId = @Line;
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId)
SELECT N'TSS-' + RIGHT(s.PartNumber, 2) + N'-' + LEFT(CAST(NEWID() AS NVARCHAR(36)), 8), i.Id, @Rcv, @Good, s.Qty, s.Qty, @Line, 1
FROM #Stock s JOIN Parts.Item i ON i.PartNumber = s.PartNumber;
DELETE FROM #E; INSERT INTO #E EXEC Workorder.ScaleStation_ListEligibleParts @TerminalLocationId = @Term;
DECLARE @Top NVARCHAR(50) = (SELECT PartNumber FROM #E WHERE ReadyRank = 1);
EXEC test.Assert_IsEqual @TestName = N'[Elig] ReadyRank 1 = highest ShareCovered', @Expected = N'TST-SS-FG-B', @Actual = @Top;
DECLARE @Order NVARCHAR(200) = (SELECT STRING_AGG(PartNumber, N',') WITHIN GROUP (ORDER BY ReadyRank) FROM #E WHERE PartNumber LIKE N'TST-SS-%');
EXEC test.Assert_IsEqual @TestName = N'[Elig] no ByWeight pack-out / not at the line are never listed',
    @Expected = N'TST-SS-FG-B,TST-SS-FG-A', @Actual = @Order;
DECLARE @Tr NVARCHAR(10) = (SELECT CAST(TraysCovered AS NVARCHAR(10)) FROM #E WHERE PartNumber = N'TST-SS-FG-B');
EXEC test.Assert_IsEqual @TestName = N'[Elig] TraysCovered = whole trays the scarcest line covers', @Expected = N'1', @Actual = @Tr;
GO

DROP TABLE #E; DROP TABLE #Stock;
GO
EXEC test.EndTestFile;
GO
