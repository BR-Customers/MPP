-- =============================================
-- File:         0029_PlantFloor_Hold_Sort_Shipping_Aim/015_Hold_ListOpen.sql
-- Description:  Quality.Hold_ListOpen (Arc 2 Phase 7) -- the Hold Management open-holds
--               panels. Lists every open hold (LOT + container) with its Hold Event Id,
--               target, type, reason; a released hold drops out of the list.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0029_PlantFloor_Hold_Sort_Shipping_Aim/015_Hold_ListOpen.sql';
GO

DELETE FROM Quality.HoldEvent WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName = N'HLIST-1')
   OR ContainerId IN (SELECT c.Id FROM Lots.Container c INNER JOIN Parts.Item i ON i.Id = c.ItemId WHERE i.PartNumber = N'P7-HLIST-TEST');
DELETE FROM Lots.Container WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P7-HLIST-TEST');
DELETE FROM Lots.LotEventLog       WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName = N'HLIST-1');
DELETE FROM Lots.LotStatusHistory  WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName = N'HLIST-1');
DELETE FROM Lots.Lot WHERE LotName = N'HLIST-1';
GO

DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'P7-HLIST-TEST') INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId) VALUES (3, N'P7-HLIST-TEST', N'Hold list test part', 1, @Now, 1);
DECLARE @Item BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P7-HLIST-TEST');
IF NOT EXISTS (SELECT 1 FROM Parts.ContainerConfig WHERE ItemId = @Item AND DeprecatedAt IS NULL)
    INSERT INTO Parts.ContainerConfig (ItemId, TraysPerContainer, PartsPerTray, IsSerialized, ClosureMethod, CreatedAt) VALUES (@Item, 1, 1, 0, N'ByCount', @Now);
DECLARE @Config BIGINT = (SELECT TOP 1 Id FROM Parts.ContainerConfig WHERE ItemId = @Item AND DeprecatedAt IS NULL);
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');

INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, CurrentLocationId, CreatedByUserId) VALUES (N'HLIST-1', @Item, 1, 1, 10, @Cell, 1);
DECLARE @Lot BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'HLIST-1');
DECLARE @O TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @O EXEC Lots.Container_Open @ItemId = @Item, @ContainerConfigId = @Config, @CellLocationId = @Cell, @AppUserId = 2;
DECLARE @Con BIGINT = (SELECT NewId FROM @O);

-- place a LOT hold + a CONTAINER hold
DECLARE @P TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @P EXEC Quality.Hold_Place @LotId = @Lot, @HoldTypeCodeId = 1, @Reason = N'list test lot', @AppUserId = 2;
DECLARE @HeLot BIGINT = (SELECT NewId FROM @P);
DELETE FROM @P;
INSERT INTO @P EXEC Quality.Hold_Place @ContainerId = @Con, @HoldTypeCodeId = 2, @Reason = N'list test container', @AppUserId = 2;
DECLARE @HeCon BIGINT = (SELECT NewId FROM @P);

-- list open holds
CREATE TABLE #o (HoldEventId BIGINT, LotId BIGINT, LotName NVARCHAR(50), ContainerId BIGINT, ContainerItemPartNumber NVARCHAR(50), HoldTypeCodeId BIGINT, HoldTypeCode NVARCHAR(50), Reason NVARCHAR(MAX), PlacedByInitials NVARCHAR(50), PlacedAt DATETIME2(3));
INSERT INTO #o EXEC Quality.Hold_ListOpen;
DECLARE @LotRow NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #o WHERE HoldEventId = @HeLot AND LotId = @Lot AND LotName = N'HLIST-1' AND ContainerId IS NULL);
EXEC test.Assert_IsEqual @TestName = N'[HoldList] open LOT hold listed (with LotName, no container)', @Expected = N'1', @Actual = @LotRow;
DECLARE @ConRow NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #o WHERE HoldEventId = @HeCon AND ContainerId = @Con AND LotId IS NULL);
EXEC test.Assert_IsEqual @TestName = N'[HoldList] open container hold listed (with ContainerId, no lot)', @Expected = N'1', @Actual = @ConRow;
DECLARE @TypeOk NVARCHAR(50) = (SELECT HoldTypeCode FROM #o WHERE HoldEventId = @HeLot);
EXEC test.Assert_IsEqual @TestName = N'[HoldList] hold type resolved (QualityHold)', @Expected = N'QualityHold', @Actual = @TypeOk;

-- release the LOT hold -> drops out; container hold remains
DECLARE @R TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @R EXEC Quality.Hold_Release @HoldEventId = @HeLot, @AppUserId = 2;
DELETE FROM #o;
INSERT INTO #o EXEC Quality.Hold_ListOpen;
DECLARE @Gone NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #o WHERE HoldEventId = @HeLot);
EXEC test.Assert_IsEqual N'[HoldList] released LOT hold no longer listed', N'0', @Gone;
DECLARE @Still NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #o WHERE HoldEventId = @HeCon);
EXEC test.Assert_IsEqual N'[HoldList] container hold still listed', N'1', @Still;
DROP TABLE #o;
GO

DELETE FROM Quality.HoldEvent WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName = N'HLIST-1')
   OR ContainerId IN (SELECT c.Id FROM Lots.Container c INNER JOIN Parts.Item i ON i.Id = c.ItemId WHERE i.PartNumber = N'P7-HLIST-TEST');
DELETE FROM Lots.Container WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P7-HLIST-TEST');
DELETE FROM Lots.LotEventLog       WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName = N'HLIST-1');
DELETE FROM Lots.LotStatusHistory  WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName = N'HLIST-1');
DELETE FROM Lots.Lot WHERE LotName = N'HLIST-1';
GO

EXEC test.EndTestFile;
GO
