-- =============================================
-- File:         0029_PlantFloor_Hold_Sort_Shipping_Aim/025_Hold_AssociatedContainers.sql
-- Description:  FAT-QH-170 - Quality.Hold_ListAssociatedContainers returns the
--               DISTINCT containers associated with a LOT via BOTH paths:
--                 A) Lots.ContainerTray.FinishedGoodLotId  (FG-lot-is-a-tray)
--                 B) Lots.SerializedPart.ProducingLotId -> Lots.ContainerSerial
--               A LOT linked to one container by BOTH paths returns it ONCE.
--               Advisory read only (no mutation / audit).
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0029_PlantFloor_Hold_Sort_Shipping_Aim/025_Hold_AssociatedContainers.sql';
GO

-- ---- cleanup (FK-safe: ContainerSerial -> SerializedPart -> ContainerTray -> Container; then LOTs) ----
DELETE cs FROM Lots.ContainerSerial cs INNER JOIN Lots.Container c ON c.Id = cs.ContainerId INNER JOIN Parts.Item i ON i.Id = c.ItemId WHERE i.PartNumber = N'F-QH170-TEST';
DELETE sp FROM Lots.SerializedPart sp INNER JOIN Parts.Item i ON i.Id = sp.ItemId WHERE i.PartNumber = N'F-QH170-TEST';
DELETE ct FROM Lots.ContainerTray ct INNER JOIN Lots.Container c ON c.Id = ct.ContainerId INNER JOIN Parts.Item i ON i.Id = c.ItemId WHERE i.PartNumber = N'F-QH170-TEST';
DELETE FROM Lots.Container WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'F-QH170-TEST');
DELETE eg FROM Lots.LotEventLog eg INNER JOIN Lots.Lot l ON l.Id = eg.LotId INNER JOIN Parts.Item i ON i.Id = l.ItemId WHERE i.PartNumber = N'F-QH170-TEST';
DELETE m FROM Lots.LotMovement m INNER JOIN Lots.Lot l ON l.Id = m.LotId INNER JOIN Parts.Item i ON i.Id = l.ItemId WHERE i.PartNumber = N'F-QH170-TEST';
DELETE h FROM Lots.LotStatusHistory h INNER JOIN Lots.Lot l ON l.Id = h.LotId INNER JOIN Parts.Item i ON i.Id = l.ItemId WHERE i.PartNumber = N'F-QH170-TEST';
DELETE c FROM Lots.LotGenealogyClosure c INNER JOIN Lots.Lot l ON l.Id = c.AncestorLotId OR l.Id = c.DescendantLotId INNER JOIN Parts.Item i ON i.Id = l.ItemId WHERE i.PartNumber = N'F-QH170-TEST';
DELETE FROM Lots.Lot WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'F-QH170-TEST');
GO

DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'F-QH170-TEST')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId) VALUES (3, N'F-QH170-TEST', N'Container-advisory test part', 1, @Now, 1);
DECLARE @Item BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'F-QH170-TEST');
IF NOT EXISTS (SELECT 1 FROM Parts.ContainerConfig WHERE ItemId = @Item AND DeprecatedAt IS NULL)
    INSERT INTO Parts.ContainerConfig (ItemId, TraysPerContainer, PartsPerTray, IsSerialized, ClosureMethod, CreatedAt) VALUES (@Item, 4, 25, 1, N'ByVision', @Now);
DECLARE @Config BIGINT = (SELECT TOP 1 Id FROM Parts.ContainerConfig WHERE ItemId = @Item AND DeprecatedAt IS NULL);
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');
IF NOT EXISTS (SELECT 1 FROM Parts.ItemLocation WHERE ItemId = @Item AND LocationId = @Cell AND DeprecatedAt IS NULL)
    INSERT INTO Parts.ItemLocation (ItemId, LocationId, IsConsumptionPoint, CreatedAt) VALUES (@Item, @Cell, 0, @Now);
DECLARE @OriginMfg BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');

-- LOTs: A (FG-tray path), B (serialized-part path), Z (no containers), D (both paths -> one container)
DECLARE @CLA TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO @CLA EXEC Lots.Lot_Create @ItemId = @Item, @LotOriginTypeId = @OriginMfg, @CurrentLocationId = @Cell, @PieceCount = 4, @AppUserId = 1, @LotName = N'QH170-LOT-A';
DECLARE @LotA BIGINT = (SELECT NewId FROM @CLA);
DECLARE @CLB TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO @CLB EXEC Lots.Lot_Create @ItemId = @Item, @LotOriginTypeId = @OriginMfg, @CurrentLocationId = @Cell, @PieceCount = 4, @AppUserId = 1, @LotName = N'QH170-LOT-B';
DECLARE @LotB BIGINT = (SELECT NewId FROM @CLB);
DECLARE @CLZ TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO @CLZ EXEC Lots.Lot_Create @ItemId = @Item, @LotOriginTypeId = @OriginMfg, @CurrentLocationId = @Cell, @PieceCount = 4, @AppUserId = 1, @LotName = N'QH170-LOT-Z';
DECLARE @LotZ BIGINT = (SELECT NewId FROM @CLZ);
DECLARE @CLD TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO @CLD EXEC Lots.Lot_Create @ItemId = @Item, @LotOriginTypeId = @OriginMfg, @CurrentLocationId = @Cell, @PieceCount = 4, @AppUserId = 1, @LotName = N'QH170-LOT-D';
DECLARE @LotD BIGINT = (SELECT NewId FROM @CLD);

-- Container C1 - holds LOT A as a finished-good tray (Path A)
INSERT INTO Lots.Container (ItemId, ContainerConfigId, CurrentLocationId, ContainerStatusCodeId, CreatedByUserId) VALUES (@Item, @Config, @Cell, 1, 1);
DECLARE @C1 BIGINT = SCOPE_IDENTITY();
INSERT INTO Lots.ContainerTray (ContainerId, TrayPosition, FinishedGoodLotId) VALUES (@C1, 1, @LotA);

-- Container C2 - holds a serialized part produced by LOT B (Path B)
INSERT INTO Lots.Container (ItemId, ContainerConfigId, CurrentLocationId, ContainerStatusCodeId, CreatedByUserId) VALUES (@Item, @Config, @Cell, 1, 1);
DECLARE @C2 BIGINT = SCOPE_IDENTITY();
INSERT INTO Lots.SerializedPart (SerialNumber, ItemId, ProducingLotId, EtchedByUserId) VALUES (N'QH170-SER-B1', @Item, @LotB, 1);
DECLARE @SpB BIGINT = SCOPE_IDENTITY();
INSERT INTO Lots.ContainerSerial (ContainerId, SerializedPartId) VALUES (@C2, @SpB);

-- Container C3 - LOT D linked BOTH ways to the SAME container (distinctness case)
INSERT INTO Lots.Container (ItemId, ContainerConfigId, CurrentLocationId, ContainerStatusCodeId, CreatedByUserId) VALUES (@Item, @Config, @Cell, 1, 1);
DECLARE @C3 BIGINT = SCOPE_IDENTITY();
INSERT INTO Lots.ContainerTray (ContainerId, TrayPosition, FinishedGoodLotId) VALUES (@C3, 1, @LotD);
INSERT INTO Lots.SerializedPart (SerialNumber, ItemId, ProducingLotId, EtchedByUserId) VALUES (N'QH170-SER-D1', @Item, @LotD, 1);
DECLARE @SpD BIGINT = SCOPE_IDENTITY();
INSERT INTO Lots.ContainerSerial (ContainerId, SerializedPartId) VALUES (@C3, @SpD);

-- ---- Path A: FG-tray LOT A -> container C1, kind FinishedGoodTray ----
DECLARE @A TABLE (ContainerId BIGINT, ItemPartNumber NVARCHAR(50), ItemDescription NVARCHAR(200), CurrentLocationName NVARCHAR(200), ContainerStatusCode NVARCHAR(50), AssociationKind NVARCHAR(30));
INSERT INTO @A EXEC Quality.Hold_ListAssociatedContainers @LotId = @LotA;
DECLARE @AC NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @A);
DECLARE @ACid NVARCHAR(20) = (SELECT CAST(ContainerId AS NVARCHAR(20)) FROM @A);
DECLARE @AKind NVARCHAR(30) = (SELECT AssociationKind FROM @A);
DECLARE @C1s NVARCHAR(20) = CAST(@C1 AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[QH170] LOT A -> 1 associated container', @Expected = N'1', @Actual = @AC;
EXEC test.Assert_IsEqual @TestName = N'[QH170] LOT A container is C1', @Expected = @C1s, @Actual = @ACid;
EXEC test.Assert_IsEqual @TestName = N'[QH170] LOT A kind = FinishedGoodTray', @Expected = N'FinishedGoodTray', @Actual = @AKind;

-- ---- Path B: producing LOT B -> container C2, kind SerializedPart ----
DECLARE @B TABLE (ContainerId BIGINT, ItemPartNumber NVARCHAR(50), ItemDescription NVARCHAR(200), CurrentLocationName NVARCHAR(200), ContainerStatusCode NVARCHAR(50), AssociationKind NVARCHAR(30));
INSERT INTO @B EXEC Quality.Hold_ListAssociatedContainers @LotId = @LotB;
DECLARE @BC NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @B);
DECLARE @BCid NVARCHAR(20) = (SELECT CAST(ContainerId AS NVARCHAR(20)) FROM @B);
DECLARE @BKind NVARCHAR(30) = (SELECT AssociationKind FROM @B);
DECLARE @C2s NVARCHAR(20) = CAST(@C2 AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[QH170] LOT B -> 1 associated container', @Expected = N'1', @Actual = @BC;
EXEC test.Assert_IsEqual @TestName = N'[QH170] LOT B container is C2', @Expected = @C2s, @Actual = @BCid;
EXEC test.Assert_IsEqual @TestName = N'[QH170] LOT B kind = SerializedPart', @Expected = N'SerializedPart', @Actual = @BKind;

-- ---- No containers: LOT Z -> empty ----
DECLARE @Z TABLE (ContainerId BIGINT, ItemPartNumber NVARCHAR(50), ItemDescription NVARCHAR(200), CurrentLocationName NVARCHAR(200), ContainerStatusCode NVARCHAR(50), AssociationKind NVARCHAR(30));
INSERT INTO @Z EXEC Quality.Hold_ListAssociatedContainers @LotId = @LotZ;
DECLARE @ZC NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @Z);
EXEC test.Assert_IsEqual @TestName = N'[QH170] LOT Z (no containers) -> empty', @Expected = N'0', @Actual = @ZC;

-- ---- Distinctness: LOT D linked via BOTH paths to C3 -> returned ONCE (kind FinishedGoodTray wins) ----
DECLARE @D TABLE (ContainerId BIGINT, ItemPartNumber NVARCHAR(50), ItemDescription NVARCHAR(200), CurrentLocationName NVARCHAR(200), ContainerStatusCode NVARCHAR(50), AssociationKind NVARCHAR(30));
INSERT INTO @D EXEC Quality.Hold_ListAssociatedContainers @LotId = @LotD;
DECLARE @DC NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @D);
DECLARE @DCid NVARCHAR(20) = (SELECT CAST(ContainerId AS NVARCHAR(20)) FROM @D);
DECLARE @DKind NVARCHAR(30) = (SELECT AssociationKind FROM @D);
DECLARE @C3s NVARCHAR(20) = CAST(@C3 AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[QH170] LOT D (both paths, same container) -> 1 distinct row', @Expected = N'1', @Actual = @DC;
EXEC test.Assert_IsEqual @TestName = N'[QH170] LOT D container is C3', @Expected = @C3s, @Actual = @DCid;
EXEC test.Assert_IsEqual @TestName = N'[QH170] LOT D kind = FinishedGoodTray (tray wins)', @Expected = N'FinishedGoodTray', @Actual = @DKind;
GO

-- ---- teardown ----
DELETE cs FROM Lots.ContainerSerial cs INNER JOIN Lots.Container c ON c.Id = cs.ContainerId INNER JOIN Parts.Item i ON i.Id = c.ItemId WHERE i.PartNumber = N'F-QH170-TEST';
DELETE sp FROM Lots.SerializedPart sp INNER JOIN Parts.Item i ON i.Id = sp.ItemId WHERE i.PartNumber = N'F-QH170-TEST';
DELETE ct FROM Lots.ContainerTray ct INNER JOIN Lots.Container c ON c.Id = ct.ContainerId INNER JOIN Parts.Item i ON i.Id = c.ItemId WHERE i.PartNumber = N'F-QH170-TEST';
DELETE FROM Lots.Container WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'F-QH170-TEST');
DELETE eg FROM Lots.LotEventLog eg INNER JOIN Lots.Lot l ON l.Id = eg.LotId INNER JOIN Parts.Item i ON i.Id = l.ItemId WHERE i.PartNumber = N'F-QH170-TEST';
DELETE m FROM Lots.LotMovement m INNER JOIN Lots.Lot l ON l.Id = m.LotId INNER JOIN Parts.Item i ON i.Id = l.ItemId WHERE i.PartNumber = N'F-QH170-TEST';
DELETE h FROM Lots.LotStatusHistory h INNER JOIN Lots.Lot l ON l.Id = h.LotId INNER JOIN Parts.Item i ON i.Id = l.ItemId WHERE i.PartNumber = N'F-QH170-TEST';
DELETE c FROM Lots.LotGenealogyClosure c INNER JOIN Lots.Lot l ON l.Id = c.AncestorLotId OR l.Id = c.DescendantLotId INNER JOIN Parts.Item i ON i.Id = l.ItemId WHERE i.PartNumber = N'F-QH170-TEST';
DELETE FROM Lots.Lot WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'F-QH170-TEST');
GO

EXEC test.EndTestFile;
GO
