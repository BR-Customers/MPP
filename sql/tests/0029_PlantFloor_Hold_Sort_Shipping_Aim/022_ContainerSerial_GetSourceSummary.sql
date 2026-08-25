-- =============================================
-- File:         0029_PlantFloor_Hold_Sort_Shipping_Aim/022_ContainerSerial_GetSourceSummary.sql
-- Description:  Lots.ContainerSerial_GetSourceSummary - the READ backing the Sort
--               Cage screen's "Source Container" KPI panel. Verifies the summary
--               resolves the container, the part, the serial and the counts; that
--               the AIM Shipper ID comes through the pool claim; and that an
--               unknown id returns an EMPTY result set rather than a row of NULLs
--               (READ-proc convention, FDS-11-011).
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0029_PlantFloor_Hold_Sort_Shipping_Aim/022_ContainerSerial_GetSourceSummary.sql';
GO

-- ---- clean any prior fixture (FK-safe order) ----
DELETE FROM Lots.AimShipperIdPool WHERE AimShipperId = N'999900022';
DELETE csh FROM Lots.ContainerSerialHistory csh INNER JOIN Lots.ContainerSerial cs ON cs.Id = csh.ContainerSerialId INNER JOIN Lots.SerializedPart sp ON sp.Id = cs.SerializedPartId INNER JOIN Parts.Item i ON i.Id = sp.ItemId WHERE i.PartNumber = N'P7-SUMMARY-TEST';
DELETE cs FROM Lots.ContainerSerial cs INNER JOIN Lots.SerializedPart sp ON sp.Id = cs.SerializedPartId INNER JOIN Parts.Item i ON i.Id = sp.ItemId WHERE i.PartNumber = N'P7-SUMMARY-TEST';
DELETE sp FROM Lots.SerializedPart sp INNER JOIN Parts.Item i ON i.Id = sp.ItemId WHERE i.PartNumber = N'P7-SUMMARY-TEST';
DELETE FROM Lots.ContainerTray WHERE ContainerId IN (SELECT Id FROM Lots.Container WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P7-SUMMARY-TEST'));
DELETE FROM Lots.Container WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P7-SUMMARY-TEST');
DELETE eg FROM Lots.LotEventLog eg INNER JOIN Lots.Lot l ON l.Id = eg.LotId INNER JOIN Parts.Item i ON i.Id = l.ItemId WHERE i.PartNumber = N'P7-SUMMARY-TEST';
DELETE m FROM Lots.LotMovement m INNER JOIN Lots.Lot l ON l.Id = m.LotId INNER JOIN Parts.Item i ON i.Id = l.ItemId WHERE i.PartNumber = N'P7-SUMMARY-TEST';
DELETE h FROM Lots.LotStatusHistory h INNER JOIN Lots.Lot l ON l.Id = h.LotId INNER JOIN Parts.Item i ON i.Id = l.ItemId WHERE i.PartNumber = N'P7-SUMMARY-TEST';
DELETE c FROM Lots.LotGenealogyClosure c INNER JOIN Lots.Lot l ON l.Id = c.AncestorLotId OR l.Id = c.DescendantLotId INNER JOIN Parts.Item i ON i.Id = l.ItemId WHERE i.PartNumber = N'P7-SUMMARY-TEST';
DELETE FROM Lots.Lot WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P7-SUMMARY-TEST');
GO

-- ---- fixture: one container holding two serials, with an AIM shipper claimed ----
DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'P7-SUMMARY-TEST')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId)
    VALUES (3, N'P7-SUMMARY-TEST', N'Phase7 sort-cage summary test part', 1, @Now, 1);
DECLARE @Item BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P7-SUMMARY-TEST');

IF NOT EXISTS (SELECT 1 FROM Parts.ContainerConfig WHERE ItemId = @Item AND DeprecatedAt IS NULL)
    INSERT INTO Parts.ContainerConfig (ItemId, TraysPerContainer, PartsPerTray, IsSerialized, ClosureMethod, CreatedAt)
    VALUES (@Item, 4, 25, 1, N'ByVision', @Now);
DECLARE @Config BIGINT = (SELECT TOP 1 Id FROM Parts.ContainerConfig WHERE ItemId = @Item AND DeprecatedAt IS NULL);

DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');
IF NOT EXISTS (SELECT 1 FROM Parts.ItemLocation WHERE ItemId = @Item AND LocationId = @Cell AND DeprecatedAt IS NULL)
    INSERT INTO Parts.ItemLocation (ItemId, LocationId, IsConsumptionPoint, CreatedAt) VALUES (@Item, @Cell, 0, @Now);
DECLARE @OriginMfg BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');

DECLARE @O TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @O EXEC Lots.Container_Open @ItemId = @Item, @ContainerConfigId = @Config, @CellLocationId = @Cell, @AppUserId = 1;
DECLARE @Con BIGINT = (SELECT NewId FROM @O);

DECLARE @CL TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO @CL EXEC Lots.Lot_Create @ItemId = @Item, @LotOriginTypeId = @OriginMfg,
    @CurrentLocationId = @Cell, @PieceCount = 5, @AppUserId = 1, @LotName = N'P7T-SUM-LOT';
DECLARE @Lot BIGINT = (SELECT NewId FROM @CL);

DECLARE @M TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, SerialNumber NVARCHAR(50));
INSERT INTO @M EXEC Lots.SerializedPart_Mint @ItemId = @Item, @ProducingLotId = @Lot, @AppUserId = 1;
DECLARE @Sp1 BIGINT = (SELECT NewId FROM @M); DELETE FROM @M;
INSERT INTO @M EXEC Lots.SerializedPart_Mint @ItemId = @Item, @ProducingLotId = @Lot, @AppUserId = 1;
DECLARE @Sp2 BIGINT = (SELECT NewId FROM @M);

DECLARE @A TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @A EXEC Lots.ContainerSerial_Add @ContainerId = @Con, @SerializedPartId = @Sp1, @AppUserId = 1;
DECLARE @Cs1 BIGINT = (SELECT NewId FROM @A); DELETE FROM @A;
INSERT INTO @A EXEC Lots.ContainerSerial_Add @ContainerId = @Con, @SerializedPartId = @Sp2, @AppUserId = 1;

-- the AIM shipper is linked by the POOL CLAIM, not by a shipping label
INSERT INTO Lots.AimShipperIdPool (AimShipperId, FetchedAt, ConsumedAt, ConsumedByContainerId, ConsumedByUserId)
VALUES (N'999900022', @Now, @Now, @Con, 1);

IF OBJECT_ID(N'tempdb..#SumFix') IS NOT NULL DROP TABLE #SumFix;
CREATE TABLE #SumFix (Tag NVARCHAR(20) PRIMARY KEY, Val BIGINT);
INSERT INTO #SumFix VALUES (N'Cs1', @Cs1), (N'Con', @Con), (N'Item', @Item);
GO

-- =============================================
-- Test 1: the summary resolves container, part, serial and counts
-- =============================================
IF OBJECT_ID(N'tempdb..#sum') IS NOT NULL DROP TABLE #sum;
CREATE TABLE #sum (
    ContainerSerialId BIGINT, ContainerId BIGINT, ContainerTrayId BIGINT, TrayPosition INT,
    SerialNumber NVARCHAR(50), ItemId BIGINT, PartNumber NVARCHAR(50), ItemDescription NVARCHAR(500),
    AimShipperId NVARCHAR(50), SerialCount INT, TrayCount INT, ContainerStatusCode NVARCHAR(50),
    CurrentLocationId BIGINT, CurrentLocationName NVARCHAR(200),
    OpenedAt DATETIME2(3), CompletedAt DATETIME2(3));

DECLARE @Cs1 BIGINT = (SELECT Val FROM #SumFix WHERE Tag = N'Cs1');
DECLARE @Con BIGINT = (SELECT Val FROM #SumFix WHERE Tag = N'Con');
INSERT INTO #sum EXEC Lots.ContainerSerial_GetSourceSummary @ContainerSerialId = @Cs1;

DECLARE @n INT = (SELECT COUNT(*) FROM #sum);
EXEC test.Assert_RowCount @TestName = N'[SourceSummary] exactly one row for a known serial',
    @ExpectedCount = 1, @ActualCount = @n;

DECLARE @conStr NVARCHAR(20) = (SELECT CAST(ContainerId AS NVARCHAR(20)) FROM #sum);
DECLARE @conExp NVARCHAR(20) = CAST(@Con AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[SourceSummary] resolves the owning container',
    @Expected = @conExp, @Actual = @conStr;

DECLARE @part NVARCHAR(50) = (SELECT PartNumber FROM #sum);
EXEC test.Assert_IsEqual @TestName = N'[SourceSummary] resolves the part number',
    @Expected = N'P7-SUMMARY-TEST', @Actual = @part;

DECLARE @serial NVARCHAR(50) = (SELECT SerialNumber FROM #sum);
EXEC test.Assert_IsNotNull @TestName = N'[SourceSummary] resolves the scanned serial number', @Value = @serial;

-- both serials sit in this container, so the count is 2 (not 1 - it counts the
-- CONTAINER's serials, not the scanned row)
DECLARE @sc NVARCHAR(10) = (SELECT CAST(SerialCount AS NVARCHAR(10)) FROM #sum);
EXEC test.Assert_IsEqual @TestName = N'[SourceSummary] SerialCount counts the container, not the scan',
    @Expected = N'2', @Actual = @sc;

DECLARE @aim NVARCHAR(50) = (SELECT AimShipperId FROM #sum);
EXEC test.Assert_IsEqual @TestName = N'[SourceSummary] AIM Shipper ID comes through the pool claim',
    @Expected = N'999900022', @Actual = @aim;

DECLARE @status NVARCHAR(50) = (SELECT ContainerStatusCode FROM #sum);
EXEC test.Assert_IsNotNull @TestName = N'[SourceSummary] container status resolved', @Value = @status;
DROP TABLE #sum;
GO

-- =============================================
-- Test 2: unknown id -> EMPTY result set (no invented 404, no NULL row)
-- =============================================
IF OBJECT_ID(N'tempdb..#none') IS NOT NULL DROP TABLE #none;
CREATE TABLE #none (
    ContainerSerialId BIGINT, ContainerId BIGINT, ContainerTrayId BIGINT, TrayPosition INT,
    SerialNumber NVARCHAR(50), ItemId BIGINT, PartNumber NVARCHAR(50), ItemDescription NVARCHAR(500),
    AimShipperId NVARCHAR(50), SerialCount INT, TrayCount INT, ContainerStatusCode NVARCHAR(50),
    CurrentLocationId BIGINT, CurrentLocationName NVARCHAR(200),
    OpenedAt DATETIME2(3), CompletedAt DATETIME2(3));
INSERT INTO #none EXEC Lots.ContainerSerial_GetSourceSummary @ContainerSerialId = -1;
DECLARE @n0 INT = (SELECT COUNT(*) FROM #none);
DROP TABLE #none;
EXEC test.Assert_RowCount @TestName = N'[SourceSummary] unknown id returns an empty set',
    @ExpectedCount = 0, @ActualCount = @n0;
GO

-- ---- cleanup ----
DELETE FROM Lots.AimShipperIdPool WHERE AimShipperId = N'999900022';
DELETE csh FROM Lots.ContainerSerialHistory csh INNER JOIN Lots.ContainerSerial cs ON cs.Id = csh.ContainerSerialId INNER JOIN Lots.SerializedPart sp ON sp.Id = cs.SerializedPartId INNER JOIN Parts.Item i ON i.Id = sp.ItemId WHERE i.PartNumber = N'P7-SUMMARY-TEST';
DELETE cs FROM Lots.ContainerSerial cs INNER JOIN Lots.SerializedPart sp ON sp.Id = cs.SerializedPartId INNER JOIN Parts.Item i ON i.Id = sp.ItemId WHERE i.PartNumber = N'P7-SUMMARY-TEST';
DELETE sp FROM Lots.SerializedPart sp INNER JOIN Parts.Item i ON i.Id = sp.ItemId WHERE i.PartNumber = N'P7-SUMMARY-TEST';
DELETE FROM Lots.ContainerTray WHERE ContainerId IN (SELECT Id FROM Lots.Container WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P7-SUMMARY-TEST'));
DELETE FROM Lots.Container WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P7-SUMMARY-TEST');
DELETE eg FROM Lots.LotEventLog eg INNER JOIN Lots.Lot l ON l.Id = eg.LotId INNER JOIN Parts.Item i ON i.Id = l.ItemId WHERE i.PartNumber = N'P7-SUMMARY-TEST';
DELETE m FROM Lots.LotMovement m INNER JOIN Lots.Lot l ON l.Id = m.LotId INNER JOIN Parts.Item i ON i.Id = l.ItemId WHERE i.PartNumber = N'P7-SUMMARY-TEST';
DELETE h FROM Lots.LotStatusHistory h INNER JOIN Lots.Lot l ON l.Id = h.LotId INNER JOIN Parts.Item i ON i.Id = l.ItemId WHERE i.PartNumber = N'P7-SUMMARY-TEST';
DELETE c FROM Lots.LotGenealogyClosure c INNER JOIN Lots.Lot l ON l.Id = c.AncestorLotId OR l.Id = c.DescendantLotId INNER JOIN Parts.Item i ON i.Id = l.ItemId WHERE i.PartNumber = N'P7-SUMMARY-TEST';
DELETE FROM Lots.Lot WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P7-SUMMARY-TEST');
IF OBJECT_ID(N'tempdb..#SumFix') IS NOT NULL DROP TABLE #SumFix;
GO
