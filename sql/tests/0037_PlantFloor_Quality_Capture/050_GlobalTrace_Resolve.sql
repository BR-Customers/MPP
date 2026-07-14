-- =============================================
-- File:         0037_PlantFloor_Quality_Capture/050_GlobalTrace_Resolve.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-07-10
-- Description:  Lots.GlobalTrace_Resolve (Arc 2 Phase 9, FDS-12-001/012/013):
--                 - exact LotName match (rank 1, ahead of prefix hits)
--                 - serial number -> producing LOT
--                 - container id -> DISTINCT source LOTs (tray FG LOT UNION
--                   serial producing LOT)
--                 - AIM shipper id -> its container's source LOTs
--                 - prefix -> multiple rows (disambiguation list)
--                 - garbage / blank -> 0 rows
--               Fixture: LOTs P9T-TRC-A / P9T-TRC-A2 / P9T-TRC-B, serial
--               P9SER-0001 (-> A), container with tray FG LOT B + serial from A,
--               shipping label P9AIM-XYZ on that container.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0037_PlantFloor_Quality_Capture/050_GlobalTrace_Resolve.sql';
GO

-- ---- fixture cleanup (re-runnable; children before parents) ----
DELETE sl FROM Lots.ShippingLabel sl WHERE sl.AimShipperId = N'P9AIM-XYZ';
DELETE cs FROM Lots.ContainerSerial cs INNER JOIN Lots.SerializedPart sp ON sp.Id = cs.SerializedPartId WHERE sp.SerialNumber LIKE N'P9SER-%';
DELETE ct FROM Lots.ContainerTray ct INNER JOIN Lots.Container c ON c.Id = ct.ContainerId INNER JOIN Parts.Item i ON i.Id = c.ItemId WHERE i.PartNumber = N'P9-QC-TEST';
DELETE c  FROM Lots.Container c INNER JOIN Parts.Item i ON i.Id = c.ItemId WHERE i.PartNumber = N'P9-QC-TEST';
DELETE sp FROM Lots.SerializedPart sp WHERE sp.SerialNumber LIKE N'P9SER-%';
DELETE eg FROM Lots.LotEventLog eg INNER JOIN Lots.Lot l ON l.Id = eg.LotId INNER JOIN Parts.Item i ON i.Id = l.ItemId WHERE i.PartNumber = N'P9-QC-TEST';
DELETE m FROM Lots.LotMovement m INNER JOIN Lots.Lot l ON l.Id = m.LotId INNER JOIN Parts.Item i ON i.Id = l.ItemId WHERE i.PartNumber = N'P9-QC-TEST';
DELETE h FROM Lots.LotStatusHistory h INNER JOIN Lots.Lot l ON l.Id = h.LotId INNER JOIN Parts.Item i ON i.Id = l.ItemId WHERE i.PartNumber = N'P9-QC-TEST';
DELETE c FROM Lots.LotGenealogyClosure c INNER JOIN Lots.Lot l ON l.Id = c.AncestorLotId OR l.Id = c.DescendantLotId INNER JOIN Parts.Item i ON i.Id = l.ItemId WHERE i.PartNumber = N'P9-QC-TEST';
DELETE FROM Lots.Lot WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P9-QC-TEST');
GO

-- ---- fixture build ----
DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'P9-QC-TEST')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId)
    VALUES (2, N'P9-QC-TEST', N'Phase 9 quality-capture test part', 1, @Now, 1);
DECLARE @Item BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P9-QC-TEST');

DECLARE @LocM05 BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'DC1-M05');
IF NOT EXISTS (SELECT 1 FROM Parts.ItemLocation WHERE ItemId = @Item AND LocationId = @LocM05 AND DeprecatedAt IS NULL)
    INSERT INTO Parts.ItemLocation (ItemId, LocationId, IsConsumptionPoint, CreatedAt) VALUES (@Item, @LocM05, 0, @Now);
IF NOT EXISTS (SELECT 1 FROM Parts.ContainerConfig WHERE ItemId = @Item AND DeprecatedAt IS NULL)
    INSERT INTO Parts.ContainerConfig (ItemId, TraysPerContainer, PartsPerTray, IsSerialized, ClosureMethod, CreatedAt)
    VALUES (@Item, 4, 25, 1, N'ByVision', @Now);
DECLARE @Config BIGINT = (SELECT TOP 1 Id FROM Parts.ContainerConfig WHERE ItemId = @Item AND DeprecatedAt IS NULL);

-- three LOTs
DECLARE @OriginMfg BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');
DECLARE @CL TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO @CL EXEC Lots.Lot_Create @ItemId = @Item, @LotOriginTypeId = @OriginMfg, @CurrentLocationId = @LocM05, @PieceCount = 10, @AppUserId = 1, @LotName = N'P9T-TRC-A';
DECLARE @LotA BIGINT = (SELECT NewId FROM @CL); DELETE FROM @CL;
INSERT INTO @CL EXEC Lots.Lot_Create @ItemId = @Item, @LotOriginTypeId = @OriginMfg, @CurrentLocationId = @LocM05, @PieceCount = 10, @AppUserId = 1, @LotName = N'P9T-TRC-A2';
DELETE FROM @CL;
INSERT INTO @CL EXEC Lots.Lot_Create @ItemId = @Item, @LotOriginTypeId = @OriginMfg, @CurrentLocationId = @LocM05, @PieceCount = 10, @AppUserId = 1, @LotName = N'P9T-TRC-B';
DECLARE @LotB BIGINT = (SELECT NewId FROM @CL);

-- serialized part etched from LOT A
INSERT INTO Lots.SerializedPart (SerialNumber, ItemId, ProducingLotId, EtchedAt, EtchedByUserId)
VALUES (N'P9SER-0001', @Item, @LotA, @Now, 1);
DECLARE @Sp BIGINT = CAST(SCOPE_IDENTITY() AS BIGINT);

-- container: one tray holding finished-good LOT B + one serial produced by LOT A
INSERT INTO Lots.Container (ItemId, ContainerConfigId, CurrentLocationId, ContainerStatusCodeId, OpenedAt, CreatedByUserId)
VALUES (@Item, @Config, @LocM05, 1, @Now, 1);
DECLARE @Con BIGINT = CAST(SCOPE_IDENTITY() AS BIGINT);
INSERT INTO Lots.ContainerTray (ContainerId, TrayPosition, PartsClosedCount, FinishedGoodLotId)
VALUES (@Con, 1, 25, @LotB);
INSERT INTO Lots.ContainerSerial (ContainerId, ContainerTrayId, SerializedPartId, TrayPosition, CreatedAt)
VALUES (@Con, NULL, @Sp, 2, @Now);

-- shipping label with an AIM shipper id on that container
DECLARE @LabelType BIGINT = (SELECT Id FROM Lots.LabelTypeCode WHERE Code = N'Primary');
INSERT INTO Lots.ShippingLabel (ContainerId, AimShipperId, LabelTypeCodeId, Initial, CreatedAt)
VALUES (@Con, N'P9AIM-XYZ', @LabelType, 1, @Now);
GO

-- =============================================
-- Test 1: exact LotName resolves first (prefix sibling ranks after)
-- =============================================
CREATE TABLE #R (Ord INT IDENTITY(1,1), MatchType NVARCHAR(20), MatchedEntityId BIGINT, LotId BIGINT, LotName NVARCHAR(50), ItemPartNumber NVARCHAR(50), Detail NVARCHAR(200));
INSERT INTO #R EXEC Lots.GlobalTrace_Resolve @SearchText = N'P9T-TRC-A';
DECLARE @C INT = (SELECT COUNT(*) FROM #R);
EXEC test.Assert_RowCount @TestName = N'[Trace] exact name: exact + prefix sibling = 2 rows', @ExpectedCount = 2, @ActualCount = @C;
DECLARE @N1 NVARCHAR(50) = (SELECT LotName FROM #R WHERE Ord = 1);
EXEC test.Assert_IsEqual @TestName = N'[Trace] exact match ranked FIRST', @Expected = N'P9T-TRC-A', @Actual = @N1;
DECLARE @T1 NVARCHAR(20) = (SELECT MatchType FROM #R WHERE Ord = 1);
EXEC test.Assert_IsEqual @TestName = N'[Trace] exact match MatchType = Lot', @Expected = N'Lot', @Actual = @T1;
DECLARE @N2 NVARCHAR(50) = (SELECT LotName FROM #R WHERE Ord = 2);
EXEC test.Assert_IsEqual @TestName = N'[Trace] prefix sibling ranked second', @Expected = N'P9T-TRC-A2', @Actual = @N2;
DECLARE @PN NVARCHAR(50) = (SELECT ItemPartNumber FROM #R WHERE Ord = 1);
EXEC test.Assert_IsEqual @TestName = N'[Trace] ItemPartNumber joined', @Expected = N'P9-QC-TEST', @Actual = @PN;
DROP TABLE #R;
GO

-- =============================================
-- Test 2: serial number -> producing LOT
-- =============================================
CREATE TABLE #R (MatchType NVARCHAR(20), MatchedEntityId BIGINT, LotId BIGINT, LotName NVARCHAR(50), ItemPartNumber NVARCHAR(50), Detail NVARCHAR(200));
INSERT INTO #R EXEC Lots.GlobalTrace_Resolve @SearchText = N'P9SER-0001';
DECLARE @C INT = (SELECT COUNT(*) FROM #R);
EXEC test.Assert_RowCount @TestName = N'[Trace] serial resolves to 1 row', @ExpectedCount = 1, @ActualCount = @C;
DECLARE @T NVARCHAR(20) = (SELECT MatchType FROM #R);
EXEC test.Assert_IsEqual @TestName = N'[Trace] serial MatchType = Serial', @Expected = N'Serial', @Actual = @T;
DECLARE @N NVARCHAR(50) = (SELECT LotName FROM #R);
EXEC test.Assert_IsEqual @TestName = N'[Trace] serial maps to its PRODUCING LOT (A)', @Expected = N'P9T-TRC-A', @Actual = @N;
DROP TABLE #R;
GO

-- =============================================
-- Test 3: container id -> DISTINCT source LOTs (tray FG UNION serial producer)
-- =============================================
DECLARE @Con BIGINT = (SELECT TOP 1 c.Id FROM Lots.Container c INNER JOIN Parts.Item i ON i.Id = c.ItemId WHERE i.PartNumber = N'P9-QC-TEST' ORDER BY c.Id DESC);
DECLARE @ConStr NVARCHAR(100) = CAST(@Con AS NVARCHAR(100));
CREATE TABLE #R (MatchType NVARCHAR(20), MatchedEntityId BIGINT, LotId BIGINT, LotName NVARCHAR(50), ItemPartNumber NVARCHAR(50), Detail NVARCHAR(200));
INSERT INTO #R EXEC Lots.GlobalTrace_Resolve @SearchText = @ConStr;
DECLARE @C INT = (SELECT COUNT(*) FROM #R WHERE MatchType = N'Container');
EXEC test.Assert_RowCount @TestName = N'[Trace] container expands to 2 source LOTs', @ExpectedCount = 2, @ActualCount = @C;
DECLARE @HasA INT = (SELECT COUNT(*) FROM #R WHERE MatchType = N'Container' AND LotName = N'P9T-TRC-A');
EXEC test.Assert_RowCount @TestName = N'[Trace] container includes serial-producing LOT A', @ExpectedCount = 1, @ActualCount = @HasA;
DECLARE @HasB INT = (SELECT COUNT(*) FROM #R WHERE MatchType = N'Container' AND LotName = N'P9T-TRC-B');
EXEC test.Assert_RowCount @TestName = N'[Trace] container includes tray FG LOT B', @ExpectedCount = 1, @ActualCount = @HasB;
DECLARE @Ent NVARCHAR(20) = (SELECT TOP 1 CAST(MatchedEntityId AS NVARCHAR(20)) FROM #R WHERE MatchType = N'Container');
EXEC test.Assert_IsEqual @TestName = N'[Trace] MatchedEntityId = the container id', @Expected = @ConStr, @Actual = @Ent;
DROP TABLE #R;
GO

-- =============================================
-- Test 4: AIM shipper id -> its container's source LOTs
-- =============================================
CREATE TABLE #R (MatchType NVARCHAR(20), MatchedEntityId BIGINT, LotId BIGINT, LotName NVARCHAR(50), ItemPartNumber NVARCHAR(50), Detail NVARCHAR(200));
INSERT INTO #R EXEC Lots.GlobalTrace_Resolve @SearchText = N'P9AIM-XYZ';
DECLARE @C INT = (SELECT COUNT(*) FROM #R WHERE MatchType = N'Shipper');
EXEC test.Assert_RowCount @TestName = N'[Trace] shipper id expands to 2 source LOTs', @ExpectedCount = 2, @ActualCount = @C;
DECLARE @HasA INT = (SELECT COUNT(*) FROM #R WHERE MatchType = N'Shipper' AND LotName = N'P9T-TRC-A');
EXEC test.Assert_RowCount @TestName = N'[Trace] shipper includes LOT A', @ExpectedCount = 1, @ActualCount = @HasA;
DECLARE @D NVARCHAR(200) = (SELECT TOP 1 Detail FROM #R WHERE MatchType = N'Shipper');
EXEC test.Assert_Contains @TestName = N'[Trace] shipper Detail names the shipper id', @HaystackStr = @D, @NeedleStr = N'P9AIM-XYZ';
DROP TABLE #R;
GO

-- =============================================
-- Test 5: prefix -> disambiguation list (multiple rows)
-- =============================================
CREATE TABLE #R (MatchType NVARCHAR(20), MatchedEntityId BIGINT, LotId BIGINT, LotName NVARCHAR(50), ItemPartNumber NVARCHAR(50), Detail NVARCHAR(200));
INSERT INTO #R EXEC Lots.GlobalTrace_Resolve @SearchText = N'P9T-TRC';
DECLARE @C INT = (SELECT COUNT(*) FROM #R);
EXEC test.Assert_RowCount @TestName = N'[Trace] prefix returns all 3 LOTs (disambiguation)', @ExpectedCount = 3, @ActualCount = @C;
DECLARE @AllLot INT = (SELECT COUNT(*) FROM #R WHERE MatchType = N'Lot');
EXEC test.Assert_RowCount @TestName = N'[Trace] prefix rows are all MatchType Lot', @ExpectedCount = 3, @ActualCount = @AllLot;
DROP TABLE #R;
GO

-- =============================================
-- Test 6: garbage and blank input -> 0 rows
-- =============================================
CREATE TABLE #R (MatchType NVARCHAR(20), MatchedEntityId BIGINT, LotId BIGINT, LotName NVARCHAR(50), ItemPartNumber NVARCHAR(50), Detail NVARCHAR(200));
INSERT INTO #R EXEC Lots.GlobalTrace_Resolve @SearchText = N'ZZZ-NO-MATCH-999';
DECLARE @C1 INT = (SELECT COUNT(*) FROM #R);
EXEC test.Assert_RowCount @TestName = N'[Trace] garbage input -> 0 rows', @ExpectedCount = 0, @ActualCount = @C1;

DELETE FROM #R;
INSERT INTO #R EXEC Lots.GlobalTrace_Resolve @SearchText = N'   ';
DECLARE @C2 INT = (SELECT COUNT(*) FROM #R);
EXEC test.Assert_RowCount @TestName = N'[Trace] blank input -> 0 rows', @ExpectedCount = 0, @ActualCount = @C2;
DROP TABLE #R;
GO

-- ---- cleanup ----
DELETE sl FROM Lots.ShippingLabel sl WHERE sl.AimShipperId = N'P9AIM-XYZ';
DELETE cs FROM Lots.ContainerSerial cs INNER JOIN Lots.SerializedPart sp ON sp.Id = cs.SerializedPartId WHERE sp.SerialNumber LIKE N'P9SER-%';
DELETE ct FROM Lots.ContainerTray ct INNER JOIN Lots.Container c ON c.Id = ct.ContainerId INNER JOIN Parts.Item i ON i.Id = c.ItemId WHERE i.PartNumber = N'P9-QC-TEST';
DELETE c  FROM Lots.Container c INNER JOIN Parts.Item i ON i.Id = c.ItemId WHERE i.PartNumber = N'P9-QC-TEST';
DELETE sp FROM Lots.SerializedPart sp WHERE sp.SerialNumber LIKE N'P9SER-%';
DELETE eg FROM Lots.LotEventLog eg INNER JOIN Lots.Lot l ON l.Id = eg.LotId INNER JOIN Parts.Item i ON i.Id = l.ItemId WHERE i.PartNumber = N'P9-QC-TEST';
DELETE m FROM Lots.LotMovement m INNER JOIN Lots.Lot l ON l.Id = m.LotId INNER JOIN Parts.Item i ON i.Id = l.ItemId WHERE i.PartNumber = N'P9-QC-TEST';
DELETE h FROM Lots.LotStatusHistory h INNER JOIN Lots.Lot l ON l.Id = h.LotId INNER JOIN Parts.Item i ON i.Id = l.ItemId WHERE i.PartNumber = N'P9-QC-TEST';
DELETE c FROM Lots.LotGenealogyClosure c INNER JOIN Lots.Lot l ON l.Id = c.AncestorLotId OR l.Id = c.DescendantLotId INNER JOIN Parts.Item i ON i.Id = l.ItemId WHERE i.PartNumber = N'P9-QC-TEST';
DELETE FROM Lots.Lot WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P9-QC-TEST');
GO

EXEC test.EndTestFile;
GO
