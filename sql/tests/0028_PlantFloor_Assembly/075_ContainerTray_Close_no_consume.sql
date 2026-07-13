-- =============================================
-- File:         0028_PlantFloor_Assembly/075_ContainerTray_Close_no_consume.sql
-- Author:       Blue Ridge Automation
-- Description:  Regression guard for Spec 2 Task A3: Lots.ContainerTray_Close is now a
--               thin tray-insert / accumulation helper and NO LONGER consumes BOM
--               components (consumption moved to Workorder.Assembly_CompleteTray, which
--               mints the finished-good LOT). Closing a tray must: return Status 1 +
--               accumulate PartsClosedCount, write ZERO ConsumptionEvents, and leave the
--               component stock LOTs untouched -- even when a published BOM + component
--               stock exist at the cell. Prevents a double-consume regression.
--               Fixture cell: MA1-COMPBR-AOUT.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0028_PlantFloor_Assembly/075_ContainerTray_Close_no_consume.sql';
GO

-- ---- cleanup ----
DELETE FROM Workorder.ConsumptionEvent WHERE ProducedItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-ASMB-OUT')
    OR ConsumedItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber IN (N'P6-CHILD-A', N'P6-CHILD-B'));
DELETE tr FROM Lots.ContainerTray tr INNER JOIN Lots.Container ct ON ct.Id = tr.ContainerId INNER JOIN Parts.Item i ON i.Id = ct.ItemId WHERE i.PartNumber = N'P6-ASMB-OUT';
DELETE FROM Lots.Container WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-ASMB-OUT');
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName IN (N'STG-075A', N'STG-075B'));
DELETE FROM Lots.Lot WHERE LotName IN (N'STG-075A', N'STG-075B');
GO

DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'P6-ASMB-OUT') INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId) VALUES (4, N'P6-ASMB-OUT', N'P6 assembly output (no-consume test)', 1, @Now, 1);
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'P6-CHILD-A') INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId) VALUES (3, N'P6-CHILD-A', N'P6 component A', 1, @Now, 1);
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'P6-CHILD-B') INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId) VALUES (3, N'P6-CHILD-B', N'P6 component B', 1, @Now, 1);
DECLARE @Out BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-ASMB-OUT');
DECLARE @A BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-CHILD-A');
DECLARE @B BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-CHILD-B');

IF NOT EXISTS (SELECT 1 FROM Parts.ContainerConfig WHERE ItemId = @Out AND DeprecatedAt IS NULL)
    INSERT INTO Parts.ContainerConfig (ItemId, TraysPerContainer, PartsPerTray, IsSerialized, ClosureMethod, CreatedAt) VALUES (@Out, 2, 24, 0, N'ByCount', @Now);
DECLARE @Config BIGINT = (SELECT TOP 1 Id FROM Parts.ContainerConfig WHERE ItemId = @Out AND DeprecatedAt IS NULL);

-- published BOM exists (proves ContainerTray_Close still does NOT consume despite it)
IF NOT EXISTS (SELECT 1 FROM Parts.Bom WHERE ParentItemId = @Out AND PublishedAt IS NOT NULL AND DeprecatedAt IS NULL)
BEGIN
    INSERT INTO Parts.Bom (ParentItemId, VersionNumber, EffectiveFrom, PublishedAt, CreatedByUserId, CreatedAt) VALUES (@Out, 1, @Now, @Now, 1, @Now);
    DECLARE @BomId BIGINT = SCOPE_IDENTITY();
    INSERT INTO Parts.BomLine (BomId, ChildItemId, QtyPer, UomId, SortOrder) VALUES (@BomId, @A, 1, 1, 1), (@BomId, @B, 2, 1, 2);
END

DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId) VALUES (N'STG-075A', @A, 1, 1, 48, 48, @Cell, 1);
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId) VALUES (N'STG-075B', @B, 1, 1, 96, 96, @Cell, 1);

DECLARE @O TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @O EXEC Lots.Container_Open @ItemId = @Out, @ContainerConfigId = @Config, @CellLocationId = @Cell, @AppUserId = 1;
DECLARE @Cid BIGINT = (SELECT NewId FROM @O);

-- close tray 1 (24 parts)
DECLARE @TC TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, ContainerAccumulatedParts INT);
INSERT INTO @TC EXEC Lots.ContainerTray_Close @ContainerId = @Cid, @TrayPosition = 1, @PartsCount = 24, @AppUserId = 1;
DECLARE @S NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @TC);
EXEC test.Assert_IsEqual @TestName = N'[NoConsume] tray close Status 1', @Expected = N'1', @Actual = @S;
DECLARE @AccumStr NVARCHAR(10) = (SELECT CAST(ContainerAccumulatedParts AS NVARCHAR(10)) FROM @TC);
EXEC test.Assert_IsEqual @TestName = N'[NoConsume] accumulated parts 24', @Expected = N'24', @Actual = @AccumStr;

-- ZERO ConsumptionEvents written by ContainerTray_Close
DECLARE @CeCount NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Workorder.ConsumptionEvent WHERE ProducedContainerId = @Cid);
EXEC test.Assert_IsEqual @TestName = N'[NoConsume] no ConsumptionEvents written by tray close', @Expected = N'0', @Actual = @CeCount;

-- component LOTs untouched
DECLARE @ARem NVARCHAR(10) = (SELECT CAST(PieceCount AS NVARCHAR(10)) FROM Lots.Lot WHERE LotName = N'STG-075A');
EXEC test.Assert_IsEqual @TestName = N'[NoConsume] component A LOT untouched (48)', @Expected = N'48', @Actual = @ARem;
DECLARE @BRem NVARCHAR(10) = (SELECT CAST(PieceCount AS NVARCHAR(10)) FROM Lots.Lot WHERE LotName = N'STG-075B');
EXEC test.Assert_IsEqual @TestName = N'[NoConsume] component B LOT untouched (96)', @Expected = N'96', @Actual = @BRem;
GO

-- ---- cleanup ----
DELETE FROM Workorder.ConsumptionEvent WHERE ProducedItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-ASMB-OUT')
    OR ConsumedItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber IN (N'P6-CHILD-A', N'P6-CHILD-B'));
DELETE tr FROM Lots.ContainerTray tr INNER JOIN Lots.Container ct ON ct.Id = tr.ContainerId INNER JOIN Parts.Item i ON i.Id = ct.ItemId WHERE i.PartNumber = N'P6-ASMB-OUT';
DELETE FROM Lots.Container WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-ASMB-OUT');
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName IN (N'STG-075A', N'STG-075B'));
DELETE FROM Lots.Lot WHERE LotName IN (N'STG-075A', N'STG-075B');
GO

EXEC test.EndTestFile;
GO
