-- =============================================
-- File:         0028_PlantFloor_Assembly/075_ContainerTray_Close_consumes_bom.sql
-- Description:  Lots.ContainerTray_Close per-tray BOM consumption (Arc 2 Phase 6 /
--               FDS-06-013, FDS-06-014). On each tray close the proc writes one
--               Workorder.ConsumptionEvent per BOM component (ProducedContainerId +
--               TrayId, ProducedItemId = container item), decrementing the source
--               component LOTs by PartsPerTray x QtyPer. No output LOT.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0028_PlantFloor_Assembly/075_ContainerTray_Close_consumes_bom.sql';
GO

-- ---- cleanup (FK-safe: consumption -> trays -> container; status history -> child LOTs) ----
DELETE FROM Workorder.ConsumptionEvent WHERE ProducedItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-ASMB-OUT')
    OR ConsumedItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber IN (N'P6-CHILD-A', N'P6-CHILD-B'));
DELETE tr FROM Lots.ContainerTray tr INNER JOIN Lots.Container ct ON ct.Id = tr.ContainerId INNER JOIN Parts.Item i ON i.Id = ct.ItemId WHERE i.PartNumber = N'P6-ASMB-OUT';
DELETE FROM Lots.Container WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-ASMB-OUT');
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName IN (N'STG-075A', N'STG-075B'));
DELETE FROM Lots.Lot WHERE LotName IN (N'STG-075A', N'STG-075B');
GO

DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'P6-ASMB-OUT') INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId) VALUES (3, N'P6-ASMB-OUT', N'P6 assembly output (consumption test)', 1, @Now, 1);
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'P6-CHILD-A') INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId) VALUES (3, N'P6-CHILD-A', N'P6 component A', 1, @Now, 1);
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'P6-CHILD-B') INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId) VALUES (3, N'P6-CHILD-B', N'P6 component B', 1, @Now, 1);
DECLARE @Out BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-ASMB-OUT');
DECLARE @A BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-CHILD-A');
DECLARE @B BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-CHILD-B');

IF NOT EXISTS (SELECT 1 FROM Parts.ContainerConfig WHERE ItemId = @Out AND DeprecatedAt IS NULL)
    INSERT INTO Parts.ContainerConfig (ItemId, TraysPerContainer, PartsPerTray, IsSerialized, ClosureMethod, CreatedAt) VALUES (@Out, 2, 24, 0, N'ByCount', @Now);
DECLARE @Config BIGINT = (SELECT TOP 1 Id FROM Parts.ContainerConfig WHERE ItemId = @Out AND DeprecatedAt IS NULL);

-- published BOM: P6-ASMB-OUT <- P6-CHILD-A x1 + P6-CHILD-B x2
IF NOT EXISTS (SELECT 1 FROM Parts.Bom WHERE ParentItemId = @Out AND PublishedAt IS NOT NULL AND DeprecatedAt IS NULL)
BEGIN
    INSERT INTO Parts.Bom (ParentItemId, VersionNumber, EffectiveFrom, PublishedAt, CreatedByUserId, CreatedAt) VALUES (@Out, 1, @Now, @Now, 1, @Now);
    DECLARE @BomId BIGINT = SCOPE_IDENTITY();
    INSERT INTO Parts.BomLine (BomId, ChildItemId, QtyPer, UomId, SortOrder) VALUES (@BomId, @A, 1, 1, 1), (@BomId, @B, 2, 1, 2);
END

DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');
-- staged component LOTs at the cell: A=48 (>= 24x1), B=96 (>= 24x2)
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, CurrentLocationId, CreatedByUserId) VALUES (N'STG-075A', @A, 1, 1, 48, @Cell, 1);
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, CurrentLocationId, CreatedByUserId) VALUES (N'STG-075B', @B, 1, 1, 96, @Cell, 1);

DECLARE @O TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @O EXEC Lots.Container_Open @ItemId = @Out, @ContainerConfigId = @Config, @CellLocationId = @Cell, @AppUserId = 1;
DECLARE @Cid BIGINT = (SELECT NewId FROM @O);

-- close tray 1 (24 parts)
DECLARE @TC TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, ContainerAccumulatedParts INT);
INSERT INTO @TC EXEC Lots.ContainerTray_Close @ContainerId = @Cid, @TrayPosition = 1, @PartsCount = 24, @AppUserId = 1;
DECLARE @S NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @TC);
DECLARE @Tid BIGINT = (SELECT NewId FROM @TC);
EXEC test.Assert_IsEqual @TestName = N'[Consume] tray close Status 1', @Expected = N'1', @Actual = @S;

DECLARE @CeA NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Workorder.ConsumptionEvent WHERE ProducedContainerId = @Cid AND ConsumedItemId = @A AND TrayId = @Tid);
EXEC test.Assert_IsEqual @TestName = N'[Consume] one ConsumptionEvent for component A on this tray', @Expected = N'1', @Actual = @CeA;
DECLARE @CeAQty NVARCHAR(10) = (SELECT CAST(ISNULL(SUM(PieceCount), 0) AS NVARCHAR(10)) FROM Workorder.ConsumptionEvent WHERE ProducedContainerId = @Cid AND ConsumedItemId = @A AND TrayId = @Tid);
EXEC test.Assert_IsEqual @TestName = N'[Consume] component A consumed 24 (24 x QtyPer 1)', @Expected = N'24', @Actual = @CeAQty;
DECLARE @CeBQty NVARCHAR(10) = (SELECT CAST(ISNULL(SUM(PieceCount), 0) AS NVARCHAR(10)) FROM Workorder.ConsumptionEvent WHERE ProducedContainerId = @Cid AND ConsumedItemId = @B AND TrayId = @Tid);
EXEC test.Assert_IsEqual @TestName = N'[Consume] component B consumed 48 (24 x QtyPer 2)', @Expected = N'48', @Actual = @CeBQty;
DECLARE @ProdC NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Workorder.ConsumptionEvent WHERE ProducedContainerId = @Cid AND ProducedItemId = @Out AND ProducedLotId IS NULL);
EXEC test.Assert_IsEqual @TestName = N'[Consume] produced side is the container (ProducedItemId set, ProducedLotId NULL)', @Expected = N'2', @Actual = @ProdC;

DECLARE @ARem NVARCHAR(10) = (SELECT CAST(PieceCount AS NVARCHAR(10)) FROM Lots.Lot WHERE LotName = N'STG-075A');
EXEC test.Assert_IsEqual @TestName = N'[Consume] component A LOT decremented 48 -> 24', @Expected = N'24', @Actual = @ARem;
DECLARE @BRem NVARCHAR(10) = (SELECT CAST(PieceCount AS NVARCHAR(10)) FROM Lots.Lot WHERE LotName = N'STG-075B');
EXEC test.Assert_IsEqual @TestName = N'[Consume] component B LOT decremented 96 -> 48', @Expected = N'48', @Actual = @BRem;
GO

DELETE FROM Workorder.ConsumptionEvent WHERE ProducedItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-ASMB-OUT')
    OR ConsumedItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber IN (N'P6-CHILD-A', N'P6-CHILD-B'));
DELETE tr FROM Lots.ContainerTray tr INNER JOIN Lots.Container ct ON ct.Id = tr.ContainerId INNER JOIN Parts.Item i ON i.Id = ct.ItemId WHERE i.PartNumber = N'P6-ASMB-OUT';
DELETE FROM Lots.Container WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-ASMB-OUT');
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName IN (N'STG-075A', N'STG-075B'));
DELETE FROM Lots.Lot WHERE LotName IN (N'STG-075A', N'STG-075B');
GO

EXEC test.EndTestFile;
GO
