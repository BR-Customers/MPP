-- =============================================
-- File:         0029_PlantFloor_Hold_Sort_Shipping_Aim/100_FinishedGoodClose_HeldTrayReclose.sql
-- Description:  FAT #21 -- a held FG tray LOT is SKIPPED by the completion close and
--               stays open; releasing its hold (container already Complete) closes it
--               Good->Closed (two status-history rows: Hold->Good restore, Good->Closed).
--               A container-level hold release is unaffected (no FG close).
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0029_PlantFloor_Hold_Sort_Shipping_Aim/100_FinishedGoodClose_HeldTrayReclose.sql';
GO

-- ---- teardown (FK-safe order) ----
DELETE FROM Quality.HoldEvent WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P21-FGR-FG'));
DELETE FROM Quality.HoldEvent WHERE ContainerId IN (SELECT c.Id FROM Lots.Container c INNER JOIN Parts.Item i ON i.Id = c.ItemId WHERE i.PartNumber = N'P21-FGR-FG');
DELETE sl FROM Lots.ShippingLabel sl INNER JOIN Lots.Container c ON c.Id = sl.ContainerId INNER JOIN Parts.Item i ON i.Id = c.ItemId WHERE i.PartNumber = N'P21-FGR-FG';
-- Migration 0052 made the AIM pool per-company-code and dropped PartNumber.
-- Clear it wholesale, the convention eight sibling test files already follow.
DELETE FROM Lots.AimShipperIdPool;
DELETE FROM Workorder.ConsumptionEvent WHERE ProducedItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P21-FGR-FG') OR ConsumedItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P21-FGR-CHILD');
DELETE FROM Lots.LotGenealogyClosure WHERE DescendantLotId IN (SELECT Id FROM Lots.Lot WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P21-FGR-FG')) OR AncestorLotId IN (SELECT Id FROM Lots.Lot WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P21-FGR-FG'));
DELETE FROM Lots.LotGenealogy WHERE ChildLotId IN (SELECT Id FROM Lots.Lot WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P21-FGR-FG')) OR ParentLotId IN (SELECT Id FROM Lots.Lot WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P21-FGR-CHILD'));
DELETE tr FROM Lots.ContainerTray tr INNER JOIN Lots.Container c ON c.Id = tr.ContainerId INNER JOIN Parts.Item i ON i.Id = c.ItemId WHERE i.PartNumber = N'P21-FGR-FG';
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber IN (N'P21-FGR-FG', N'P21-FGR-CHILD')) OR LotName = N'STG-100');
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber IN (N'P21-FGR-FG', N'P21-FGR-CHILD')) OR LotName = N'STG-100');
DELETE FROM Lots.LotMovement WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber IN (N'P21-FGR-FG', N'P21-FGR-CHILD')) OR LotName = N'STG-100');
DELETE FROM Lots.Container WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P21-FGR-FG');
DELETE FROM Lots.Lot WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber IN (N'P21-FGR-FG', N'P21-FGR-CHILD')) OR LotName = N'STG-100';
GO

DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'P21-FGR-FG')    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId) VALUES (3, N'P21-FGR-FG', N'FAT21 reclose FG', 1, @Now, 1);
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'P21-FGR-CHILD') INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId) VALUES (3, N'P21-FGR-CHILD', N'FAT21 reclose component', 1, @Now, 1);
DECLARE @Fg BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P21-FGR-FG');
DECLARE @Child BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P21-FGR-CHILD');
IF NOT EXISTS (SELECT 1 FROM Parts.Bom WHERE ParentItemId = @Fg AND PublishedAt IS NOT NULL AND DeprecatedAt IS NULL)
BEGIN
    INSERT INTO Parts.Bom (ParentItemId, VersionNumber, EffectiveFrom, PublishedAt, CreatedByUserId, CreatedAt) VALUES (@Fg, 1, @Now, @Now, 1, @Now);
    INSERT INTO Parts.BomLine (BomId, ChildItemId, QtyPer, UomId, SortOrder) VALUES (SCOPE_IDENTITY(), @Child, 1, 1, 1);
END
IF NOT EXISTS (SELECT 1 FROM Parts.ContainerConfig WHERE ItemId = @Fg AND DeprecatedAt IS NULL)
    INSERT INTO Parts.ContainerConfig (ItemId, TraysPerContainer, PartsPerTray, IsSerialized, ClosureMethod, CreatedAt) VALUES (@Fg, 2, 1, 0, N'ByCount', @Now);
-- FG item eligible at the cell -- Assembly_CompleteTray mirrors Lot_Create's eligibility cascade
-- and rejects "Finished-good Item is not eligible at this cell." without a Parts.ItemLocation row
-- (same setup the sibling test sql/tests/0028_PlantFloor_Assembly/092_Assembly_CompleteTray.sql uses).
IF NOT EXISTS (SELECT 1 FROM Parts.ItemLocation WHERE ItemId = @Fg AND LocationId = @Cell AND DeprecatedAt IS NULL)
    INSERT INTO Parts.ItemLocation (ItemId, LocationId, IsConsumptionPoint, CreatedAt) VALUES (@Fg, @Cell, 0, @Now);
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, CurrentLocationId, TotalInProcess, InventoryAvailable, CreatedByUserId)
    VALUES (N'STG-100', @Child, 1, 1, 100000, @Cell, 0, 100000, 1);
DECLARE @TP TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @TP EXEC Lots.AimShipperIdPool_Topup @AimShipperId = N'AIM-FGR-1';

DECLARE @AT TABLE (Status BIT, Message NVARCHAR(500), FinishedGoodLotId BIGINT, ContainerId BIGINT, ContainerTrayId BIGINT, ContainerFull BIT, TraysPerContainer INT);
INSERT INTO @AT EXEC Workorder.Assembly_CompleteTray @FinishedGoodItemId = @Fg, @PieceCount = 1, @CellLocationId = @Cell, @ClosureMethod = N'ByCount', @AppUserId = 1, @TerminalLocationId = @Cell;
DECLARE @Fg1 BIGINT = (SELECT FinishedGoodLotId FROM @AT); DECLARE @Con BIGINT = (SELECT ContainerId FROM @AT); DELETE FROM @AT;
INSERT INTO @AT EXEC Workorder.Assembly_CompleteTray @FinishedGoodItemId = @Fg, @PieceCount = 1, @CellLocationId = @Cell, @ClosureMethod = N'ByCount', @AppUserId = 1, @TerminalLocationId = @Cell;
DECLARE @Fg2 BIGINT = (SELECT FinishedGoodLotId FROM @AT); DELETE FROM @AT;

-- Hold FG LOT 1 (a LOT hold) before completion.
DECLARE @HoldType BIGINT = (SELECT TOP 1 Id FROM Quality.HoldTypeCode ORDER BY Id);
DECLARE @HP TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @HP EXEC Quality.Hold_Place @LotId = @Fg1, @HoldTypeCodeId = @HoldType, @Reason = N'reclose test', @AppUserId = 2, @TerminalLocationId = @Cell;
DECLARE @He BIGINT = (SELECT NewId FROM @HP); DELETE FROM @HP;

-- Complete the (full) container.
DECLARE @CMP TABLE (Status BIT, Message NVARCHAR(500), ShippingLabelId BIGINT, AimShipperId NVARCHAR(50));
INSERT INTO @CMP EXEC Lots.Container_Complete @ContainerId = @Con, @OperatorConfirmed = 1, @AppUserId = 1, @TerminalLocationId = @Cell; DELETE FROM @CMP;

-- Assert: FG LOT 2 closed; FG LOT 1 skipped (still Hold = 2).
DECLARE @S2 NVARCHAR(10) = (SELECT CAST(LotStatusId AS NVARCHAR(10)) FROM Lots.Lot WHERE Id = @Fg2);
EXEC test.Assert_IsEqual @TestName = N'[FGReclose] non-held FG LOT closed on complete (4)', @Expected = N'4', @Actual = @S2;
DECLARE @S1 NVARCHAR(10) = (SELECT CAST(LotStatusId AS NVARCHAR(10)) FROM Lots.Lot WHERE Id = @Fg1);
EXEC test.Assert_IsEqual @TestName = N'[FGReclose] held FG LOT skipped, stays Hold (2)', @Expected = N'2', @Actual = @S1;

-- Release the hold -> restores to Good, then re-closes because container is Complete.
DECLARE @RL TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @RL EXEC Quality.Hold_Release @HoldEventId = @He, @ReleaseRemarks = N'released', @AppUserId = 2, @TerminalLocationId = @Cell;
DECLARE @RlStatus NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @RL); DELETE FROM @RL;
EXEC test.Assert_IsEqual @TestName = N'[FGReclose] hold release succeeds (Status 1)', @Expected = N'1', @Actual = @RlStatus;

-- Assert: FG LOT 1 is now Closed (4).
DECLARE @S1b NVARCHAR(10) = (SELECT CAST(LotStatusId AS NVARCHAR(10)) FROM Lots.Lot WHERE Id = @Fg1);
EXEC test.Assert_IsEqual @TestName = N'[FGReclose] released FG LOT re-closed (4)', @Expected = N'4', @Actual = @S1b;

-- Assert: the release produced BOTH history rows (Hold->Good and Good->Closed).
DECLARE @HRestore NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Lots.LotStatusHistory WHERE LotId = @Fg1 AND OldStatusId = 2 AND NewStatusId = 1);
EXEC test.Assert_IsEqual @TestName = N'[FGReclose] Hold->Good restore history row present', @Expected = N'1', @Actual = @HRestore;
DECLARE @HClose NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Lots.LotStatusHistory WHERE LotId = @Fg1 AND OldStatusId = 1 AND NewStatusId = 4);
EXEC test.Assert_IsEqual @TestName = N'[FGReclose] Good->Closed re-close history row present', @Expected = N'1', @Actual = @HClose;
GO

-- ---- Container-hold release is unaffected (no FG close, no error) ----
-- Reuse the completed container @Con: place a container-level hold, then release it.
DECLARE @Con2 BIGINT = (SELECT c.Id FROM Lots.Container c INNER JOIN Parts.Item i ON i.Id = c.ItemId WHERE i.PartNumber = N'P21-FGR-FG');
DECLARE @HoldType2 BIGINT = (SELECT TOP 1 Id FROM Quality.HoldTypeCode ORDER BY Id);
DECLARE @HPC TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @HPC EXEC Quality.Hold_Place @ContainerId = @Con2, @HoldTypeCodeId = @HoldType2, @Reason = N'container hold', @AppUserId = 2, @TerminalLocationId = @Con2;
DECLARE @HeC BIGINT = (SELECT NewId FROM @HPC); DELETE FROM @HPC;
DECLARE @RLC TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @RLC EXEC Quality.Hold_Release @HoldEventId = @HeC, @ReleaseRemarks = N'released container', @AppUserId = 2;
DECLARE @RlcStatus NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @RLC); DELETE FROM @RLC;
EXEC test.Assert_IsEqual @TestName = N'[FGReclose] container-hold release unaffected (Status 1)', @Expected = N'1', @Actual = @RlcStatus;
GO

-- ---- teardown (FK-safe order) ----
DELETE FROM Quality.HoldEvent WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P21-FGR-FG'));
DELETE FROM Quality.HoldEvent WHERE ContainerId IN (SELECT c.Id FROM Lots.Container c INNER JOIN Parts.Item i ON i.Id = c.ItemId WHERE i.PartNumber = N'P21-FGR-FG');
DELETE sl FROM Lots.ShippingLabel sl INNER JOIN Lots.Container c ON c.Id = sl.ContainerId INNER JOIN Parts.Item i ON i.Id = c.ItemId WHERE i.PartNumber = N'P21-FGR-FG';
-- Migration 0052 made the AIM pool per-company-code and dropped PartNumber.
-- Clear it wholesale, the convention eight sibling test files already follow.
DELETE FROM Lots.AimShipperIdPool;
DELETE FROM Workorder.ConsumptionEvent WHERE ProducedItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P21-FGR-FG') OR ConsumedItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P21-FGR-CHILD');
DELETE FROM Lots.LotGenealogyClosure WHERE DescendantLotId IN (SELECT Id FROM Lots.Lot WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P21-FGR-FG')) OR AncestorLotId IN (SELECT Id FROM Lots.Lot WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P21-FGR-FG'));
DELETE FROM Lots.LotGenealogy WHERE ChildLotId IN (SELECT Id FROM Lots.Lot WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P21-FGR-FG')) OR ParentLotId IN (SELECT Id FROM Lots.Lot WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P21-FGR-CHILD'));
DELETE tr FROM Lots.ContainerTray tr INNER JOIN Lots.Container c ON c.Id = tr.ContainerId INNER JOIN Parts.Item i ON i.Id = c.ItemId WHERE i.PartNumber = N'P21-FGR-FG';
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber IN (N'P21-FGR-FG', N'P21-FGR-CHILD')) OR LotName = N'STG-100');
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber IN (N'P21-FGR-FG', N'P21-FGR-CHILD')) OR LotName = N'STG-100');
DELETE FROM Lots.LotMovement WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber IN (N'P21-FGR-FG', N'P21-FGR-CHILD')) OR LotName = N'STG-100');
DELETE FROM Lots.Container WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P21-FGR-FG');
DELETE FROM Lots.Lot WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber IN (N'P21-FGR-FG', N'P21-FGR-CHILD')) OR LotName = N'STG-100';
GO

EXEC test.EndTestFile;
GO
