-- =============================================
-- File:         0029_PlantFloor_Hold_Sort_Shipping_Aim/090_FinishedGoodClose_OnComplete.sql
-- Description:  FAT #21 -- Lots.Container_Complete closes every linked finished-good LOT
--               (tray = LOT) that is Good, and only those. Uses Assembly_CompleteTray to
--               mint real FG-LOT-linked trays (2-tray container). Also proves a
--               NULL-FinishedGoodLotId tray (ContainerTray_Close flow) does not break
--               completion, and that closed FG LOTs drop from Lot_GetLineInventoryByPart
--               while staying genealogy-queryable.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0029_PlantFloor_Hold_Sort_Shipping_Aim/090_FinishedGoodClose_OnComplete.sql';
GO

-- ---- teardown (FK-safe order) ----
DELETE FROM Quality.HoldEvent WHERE ContainerId IN (SELECT c.Id FROM Lots.Container c INNER JOIN Parts.Item i ON i.Id = c.ItemId WHERE i.PartNumber IN (N'P21-FGC-FG', N'P21-FGC-NUL'));
DELETE sl FROM Lots.ShippingLabel sl INNER JOIN Lots.Container c ON c.Id = sl.ContainerId INNER JOIN Parts.Item i ON i.Id = c.ItemId WHERE i.PartNumber IN (N'P21-FGC-FG', N'P21-FGC-NUL');
DELETE FROM Lots.AimShipperIdPool WHERE AimShipperId IN (N'AIM-FGC-1', N'AIM-NUL-1');
DELETE FROM Workorder.ConsumptionEvent WHERE ProducedItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber IN (N'P21-FGC-FG', N'P21-FGC-NUL')) OR ConsumedItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P21-FGC-CHILD');
DELETE FROM Lots.LotGenealogyClosure WHERE DescendantLotId IN (SELECT Id FROM Lots.Lot WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber IN (N'P21-FGC-FG', N'P21-FGC-NUL'))) OR AncestorLotId IN (SELECT Id FROM Lots.Lot WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber IN (N'P21-FGC-FG', N'P21-FGC-NUL')));
DELETE FROM Lots.LotGenealogy WHERE ChildLotId IN (SELECT Id FROM Lots.Lot WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber IN (N'P21-FGC-FG', N'P21-FGC-NUL'))) OR ParentLotId IN (SELECT Id FROM Lots.Lot WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P21-FGC-CHILD'));
DELETE tr FROM Lots.ContainerTray tr INNER JOIN Lots.Container c ON c.Id = tr.ContainerId INNER JOIN Parts.Item i ON i.Id = c.ItemId WHERE i.PartNumber IN (N'P21-FGC-FG', N'P21-FGC-NUL');
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber IN (N'P21-FGC-FG', N'P21-FGC-NUL', N'P21-FGC-CHILD')) OR LotName IN (N'STG-090', N'STG-090B'));
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber IN (N'P21-FGC-FG', N'P21-FGC-NUL', N'P21-FGC-CHILD')) OR LotName IN (N'STG-090', N'STG-090B'));
DELETE FROM Lots.LotMovement WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber IN (N'P21-FGC-FG', N'P21-FGC-NUL', N'P21-FGC-CHILD')) OR LotName IN (N'STG-090', N'STG-090B'));
DELETE FROM Lots.Container WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber IN (N'P21-FGC-FG', N'P21-FGC-NUL'));
DELETE FROM Lots.Lot WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber IN (N'P21-FGC-FG', N'P21-FGC-NUL', N'P21-FGC-CHILD')) OR LotName IN (N'STG-090', N'STG-090B');
GO

DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');

-- FG parent part + component child + published 1-line BOM.
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'P21-FGC-FG')    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId) VALUES (3, N'P21-FGC-FG', N'FAT21 FG part', 1, @Now, 1);
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'P21-FGC-CHILD') INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId) VALUES (3, N'P21-FGC-CHILD', N'FAT21 component', 1, @Now, 1);
DECLARE @Fg BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P21-FGC-FG');
DECLARE @Child BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P21-FGC-CHILD');
IF NOT EXISTS (SELECT 1 FROM Parts.Bom WHERE ParentItemId = @Fg AND PublishedAt IS NOT NULL AND DeprecatedAt IS NULL)
BEGIN
    INSERT INTO Parts.Bom (ParentItemId, VersionNumber, EffectiveFrom, PublishedAt, CreatedByUserId, CreatedAt) VALUES (@Fg, 1, @Now, @Now, 1, @Now);
    INSERT INTO Parts.BomLine (BomId, ChildItemId, QtyPer, UomId, SortOrder) VALUES (SCOPE_IDENTITY(), @Child, 1, 1, 1);
END
-- 2-tray container config (target = 2 parts => two FG LOTs).
IF NOT EXISTS (SELECT 1 FROM Parts.ContainerConfig WHERE ItemId = @Fg AND DeprecatedAt IS NULL)
    INSERT INTO Parts.ContainerConfig (ItemId, TraysPerContainer, PartsPerTray, IsSerialized, ClosureMethod, CreatedAt) VALUES (@Fg, 2, 1, 0, N'ByCount', @Now);
-- FG item eligible at the cell (Assembly_CompleteTray mirrors Lot_Create eligibility; see sibling
-- test 0028_PlantFloor_Assembly/092_Assembly_CompleteTray.sql -- not in the brief's listing, added
-- here because Assembly_CompleteTray otherwise rejects with "Finished-good Item is not eligible at this cell.").
IF NOT EXISTS (SELECT 1 FROM Parts.ItemLocation WHERE ItemId = @Fg AND LocationId = @Cell AND DeprecatedAt IS NULL)
    INSERT INTO Parts.ItemLocation (ItemId, LocationId, IsConsumptionPoint, CreatedAt) VALUES (@Fg, @Cell, 0, @Now);
-- staged component stock at the cell (plenty).
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, CurrentLocationId, TotalInProcess, InventoryAvailable, CreatedByUserId)
    VALUES (N'STG-090', @Child, 1, 1, 100000, @Cell, 0, 100000, 1);
-- AIM pool for the FG part (Container_Complete claims one).
DECLARE @TP TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @TP EXEC Lots.AimShipperIdPool_Topup @AimShipperId = N'AIM-FGC-1';

-- ---- Act: mint two FG-LOT-linked trays into one container ----
DECLARE @AT TABLE (Status BIT, Message NVARCHAR(500), FinishedGoodLotId BIGINT, ContainerId BIGINT, ContainerTrayId BIGINT, ContainerFull BIT);
INSERT INTO @AT EXEC Workorder.Assembly_CompleteTray @FinishedGoodItemId = @Fg, @PieceCount = 1, @CellLocationId = @Cell, @ClosureMethod = N'ByCount', @AppUserId = 1, @TerminalLocationId = @Cell;
DECLARE @Fg1 BIGINT = (SELECT FinishedGoodLotId FROM @AT); DECLARE @Con BIGINT = (SELECT ContainerId FROM @AT); DELETE FROM @AT;
INSERT INTO @AT EXEC Workorder.Assembly_CompleteTray @FinishedGoodItemId = @Fg, @PieceCount = 1, @CellLocationId = @Cell, @ClosureMethod = N'ByCount', @AppUserId = 1, @TerminalLocationId = @Cell;
DECLARE @Fg2 BIGINT = (SELECT FinishedGoodLotId FROM @AT); DECLARE @Full BIT = (SELECT ContainerFull FROM @AT); DELETE FROM @AT;

-- Sanity: both FG LOTs are Good and appear in line inventory BEFORE completion.
DECLARE @InvBefore TABLE (ItemId BIGINT, PartNumber NVARCHAR(50), Description NVARCHAR(500), LotId BIGINT, LotName NVARCHAR(50), InventoryAvailable INT, ArrivedAt DATETIME2(3));
INSERT INTO @InvBefore EXEC Lots.Lot_GetLineInventoryByPart @LocationId = @Cell;
DECLARE @InvB NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @InvBefore WHERE LotId IN (@Fg1, @Fg2));
EXEC test.Assert_IsEqual @TestName = N'[FGClose] both FG LOTs on-hand before complete', @Expected = N'2', @Actual = @InvB;

-- ---- Act: complete the (full) container ----
DECLARE @CMP TABLE (Status BIT, Message NVARCHAR(500), ShippingLabelId BIGINT, AimShipperId NVARCHAR(50));
INSERT INTO @CMP EXEC Lots.Container_Complete @ContainerId = @Con, @OperatorConfirmed = 1, @AppUserId = 1, @TerminalLocationId = @Cell;
DECLARE @CmpStatus NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @CMP); DELETE FROM @CMP;
EXEC test.Assert_IsEqual @TestName = N'[FGClose] container completed (Status 1)', @Expected = N'1', @Actual = @CmpStatus;

-- Assert: both FG LOTs are now Closed (4).
DECLARE @S1 NVARCHAR(10) = (SELECT CAST(LotStatusId AS NVARCHAR(10)) FROM Lots.Lot WHERE Id = @Fg1);
EXEC test.Assert_IsEqual @TestName = N'[FGClose] FG LOT 1 -> Closed (4)', @Expected = N'4', @Actual = @S1;
DECLARE @S2 NVARCHAR(10) = (SELECT CAST(LotStatusId AS NVARCHAR(10)) FROM Lots.Lot WHERE Id = @Fg2);
EXEC test.Assert_IsEqual @TestName = N'[FGClose] FG LOT 2 -> Closed (4)', @Expected = N'4', @Actual = @S2;

-- Assert: each FG LOT got a Good->Closed history row + LotStatusChanged audit.
DECLARE @H1 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Lots.LotStatusHistory WHERE LotId = @Fg1 AND OldStatusId = 1 AND NewStatusId = 4);
EXEC test.Assert_IsEqual @TestName = N'[FGClose] FG LOT 1 Good->Closed history row', @Expected = N'1', @Actual = @H1;
-- NOTE: 'Lot'-entity audit events with non-NULL EntityId route to Lots.LotEventLog
-- (B7 routing in Audit.Audit_LogOperation), NOT Audit.OperationLog. Assert there.
DECLARE @A1 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Lots.LotEventLog el INNER JOIN Audit.LogEventType et ON et.Id = el.LogEventTypeId WHERE et.Code = N'LotStatusChanged' AND el.LotId = @Fg1);
EXEC test.Assert_IsEqual @TestName = N'[FGClose] FG LOT 1 LotStatusChanged audit present', @Expected = N'1', @Actual = @A1;

-- Assert: closed FG LOTs are excluded from line inventory.
DECLARE @InvAfter TABLE (ItemId BIGINT, PartNumber NVARCHAR(50), Description NVARCHAR(500), LotId BIGINT, LotName NVARCHAR(50), InventoryAvailable INT, ArrivedAt DATETIME2(3));
INSERT INTO @InvAfter EXEC Lots.Lot_GetLineInventoryByPart @LocationId = @Cell;
DECLARE @InvA NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @InvAfter WHERE LotId IN (@Fg1, @Fg2));
EXEC test.Assert_IsEqual @TestName = N'[FGClose] closed FG LOTs gone from line inventory', @Expected = N'0', @Actual = @InvA;

-- Assert: FG LOT provenance still queryable after close -- the consumption edges into
-- the FG LOT (written by Assembly_CompleteTray) survive the status change to Closed.
DECLARE @Gen NVARCHAR(10) = (SELECT CASE WHEN COUNT(*) >= 1 THEN N'1' ELSE N'0' END FROM Workorder.ConsumptionEvent WHERE ProducedLotId = @Fg1);
EXEC test.Assert_IsEqual @TestName = N'[FGClose] FG LOT 1 consumption genealogy queryable after close', @Expected = N'1', @Actual = @Gen;
GO

-- ---- NULL-FinishedGoodLotId tray must not break completion (ContainerTray_Close flow) ----
DECLARE @Now2 DATETIME2(3) = SYSUTCDATETIME();
DECLARE @Cell2 BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'P21-FGC-NUL') INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId) VALUES (3, N'P21-FGC-NUL', N'FAT21 null-tray part', 1, @Now2, 1);
DECLARE @Nul BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P21-FGC-NUL');
IF NOT EXISTS (SELECT 1 FROM Parts.ContainerConfig WHERE ItemId = @Nul AND DeprecatedAt IS NULL) INSERT INTO Parts.ContainerConfig (ItemId, TraysPerContainer, PartsPerTray, IsSerialized, ClosureMethod, CreatedAt) VALUES (@Nul, 1, 1, 0, N'ByCount', @Now2);
-- ContainerTray_Close needs a published BOM + staged component (reuse P21-FGC-CHILD stock at cell).
DECLARE @NChild BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P21-FGC-CHILD');
IF NOT EXISTS (SELECT 1 FROM Parts.Bom WHERE ParentItemId = @Nul AND PublishedAt IS NOT NULL AND DeprecatedAt IS NULL)
BEGIN
    INSERT INTO Parts.Bom (ParentItemId, VersionNumber, EffectiveFrom, PublishedAt, CreatedByUserId, CreatedAt) VALUES (@Nul, 1, @Now2, @Now2, 1, @Now2);
    INSERT INTO Parts.BomLine (BomId, ChildItemId, QtyPer, UomId, SortOrder) VALUES (SCOPE_IDENTITY(), @NChild, 1, 1, 1);
END
-- NOTE: LotName is globally unique (UQ_Lot_LotName) -- 'STG-090' is already used by the FG
-- section's staged component LOT above, so this second staged LOT uses a distinct name.
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, CurrentLocationId, TotalInProcess, InventoryAvailable, CreatedByUserId) VALUES (N'STG-090B', @NChild, 1, 1, 100000, @Cell2, 0, 100000, 1);
DECLARE @TP2 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @TP2 EXEC Lots.AimShipperIdPool_Topup @AimShipperId = N'AIM-NUL-1';

DECLARE @O TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
DECLARE @TC TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, ContainerAccumulatedParts INT);
-- NOTE: EXEC parameters must be literals or @variables (project convention) -- the brief's
-- inline subquery form fails with "Incorrect syntax near '('"; resolved to a variable first.
DECLARE @NulContainerConfigId BIGINT = (SELECT TOP 1 Id FROM Parts.ContainerConfig WHERE ItemId = @Nul AND DeprecatedAt IS NULL);
INSERT INTO @O EXEC Lots.Container_Open @ItemId = @Nul, @ContainerConfigId = @NulContainerConfigId, @CellLocationId = @Cell2, @AppUserId = 1;
DECLARE @NCon BIGINT = (SELECT NewId FROM @O); DELETE FROM @O;
INSERT INTO @TC EXEC Lots.ContainerTray_Close @ContainerId = @NCon, @TrayPosition = 1, @PartsCount = 1, @ClosureMethod = N'ByCount', @AppUserId = 1; DELETE FROM @TC;
DECLARE @CMP2 TABLE (Status BIT, Message NVARCHAR(500), ShippingLabelId BIGINT, AimShipperId NVARCHAR(50));
INSERT INTO @CMP2 EXEC Lots.Container_Complete @ContainerId = @NCon, @OperatorConfirmed = 1, @AppUserId = 1, @TerminalLocationId = @Cell2;
DECLARE @NStat NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @CMP2); DELETE FROM @CMP2;
EXEC test.Assert_IsEqual @TestName = N'[FGClose] NULL-FG-tray container completes cleanly (Status 1)', @Expected = N'1', @Actual = @NStat;
GO

-- ---- teardown (FK-safe order) ----
DELETE FROM Quality.HoldEvent WHERE ContainerId IN (SELECT c.Id FROM Lots.Container c INNER JOIN Parts.Item i ON i.Id = c.ItemId WHERE i.PartNumber IN (N'P21-FGC-FG', N'P21-FGC-NUL'));
DELETE sl FROM Lots.ShippingLabel sl INNER JOIN Lots.Container c ON c.Id = sl.ContainerId INNER JOIN Parts.Item i ON i.Id = c.ItemId WHERE i.PartNumber IN (N'P21-FGC-FG', N'P21-FGC-NUL');
DELETE FROM Lots.AimShipperIdPool WHERE AimShipperId IN (N'AIM-FGC-1', N'AIM-NUL-1');
DELETE FROM Workorder.ConsumptionEvent WHERE ProducedItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber IN (N'P21-FGC-FG', N'P21-FGC-NUL')) OR ConsumedItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P21-FGC-CHILD');
DELETE FROM Lots.LotGenealogyClosure WHERE DescendantLotId IN (SELECT Id FROM Lots.Lot WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber IN (N'P21-FGC-FG', N'P21-FGC-NUL'))) OR AncestorLotId IN (SELECT Id FROM Lots.Lot WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber IN (N'P21-FGC-FG', N'P21-FGC-NUL')));
DELETE FROM Lots.LotGenealogy WHERE ChildLotId IN (SELECT Id FROM Lots.Lot WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber IN (N'P21-FGC-FG', N'P21-FGC-NUL'))) OR ParentLotId IN (SELECT Id FROM Lots.Lot WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P21-FGC-CHILD'));
DELETE tr FROM Lots.ContainerTray tr INNER JOIN Lots.Container c ON c.Id = tr.ContainerId INNER JOIN Parts.Item i ON i.Id = c.ItemId WHERE i.PartNumber IN (N'P21-FGC-FG', N'P21-FGC-NUL');
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber IN (N'P21-FGC-FG', N'P21-FGC-NUL', N'P21-FGC-CHILD')) OR LotName IN (N'STG-090', N'STG-090B'));
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber IN (N'P21-FGC-FG', N'P21-FGC-NUL', N'P21-FGC-CHILD')) OR LotName IN (N'STG-090', N'STG-090B'));
DELETE FROM Lots.LotMovement WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber IN (N'P21-FGC-FG', N'P21-FGC-NUL', N'P21-FGC-CHILD')) OR LotName IN (N'STG-090', N'STG-090B'));
DELETE FROM Lots.Container WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber IN (N'P21-FGC-FG', N'P21-FGC-NUL'));
DELETE FROM Lots.Lot WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber IN (N'P21-FGC-FG', N'P21-FGC-NUL', N'P21-FGC-CHILD')) OR LotName IN (N'STG-090', N'STG-090B');
GO

EXEC test.EndTestFile;
GO
