-- =============================================
-- File:         0029_PlantFloor_Hold_Sort_Shipping_Aim/016_Hold_GetOpen_initials.sql
-- Description:  Quality.Hold_GetOpenByLot / Hold_GetOpenByContainer expose
--               PlacedByInitials (display parity with Hold_ListOpen). The HoldPanel
--               bound-summary reads it. Asserts the column resolves to the placing
--               AppUser's initials for both a LOT hold and a Container hold.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0029_PlantFloor_Hold_Sort_Shipping_Aim/016_Hold_GetOpen_initials.sql';
GO

DELETE FROM Quality.HoldEvent WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName = N'HINIT-1')
   OR ContainerId IN (SELECT c.Id FROM Lots.Container c INNER JOIN Parts.Item i ON i.Id = c.ItemId WHERE i.PartNumber = N'P7-HINIT-TEST');
DELETE FROM Lots.Container WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P7-HINIT-TEST');
DELETE FROM Lots.LotEventLog       WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName = N'HINIT-1');
DELETE FROM Lots.LotStatusHistory  WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName = N'HINIT-1');
DELETE FROM Lots.Lot WHERE LotName = N'HINIT-1';
GO

DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'P7-HINIT-TEST') INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId) VALUES (3, N'P7-HINIT-TEST', N'Hold initials test part', 1, @Now, 1);
DECLARE @Item BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P7-HINIT-TEST');
IF NOT EXISTS (SELECT 1 FROM Parts.ContainerConfig WHERE ItemId = @Item AND DeprecatedAt IS NULL)
    INSERT INTO Parts.ContainerConfig (ItemId, TraysPerContainer, PartsPerTray, IsSerialized, ClosureMethod, CreatedAt) VALUES (@Item, 1, 1, 0, N'ByCount', @Now);
DECLARE @Config BIGINT = (SELECT TOP 1 Id FROM Parts.ContainerConfig WHERE ItemId = @Item AND DeprecatedAt IS NULL);
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');

INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, CurrentLocationId, CreatedByUserId) VALUES (N'HINIT-1', @Item, 1, 1, 5, @Cell, 1);
DECLARE @Lot BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'HINIT-1');
DECLARE @O TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @O EXEC Lots.Container_Open @ItemId = @Item, @ContainerConfigId = @Config, @CellLocationId = @Cell, @AppUserId = 2;
DECLARE @Con BIGINT = (SELECT NewId FROM @O);

DECLARE @ExpInit NVARCHAR(50) = (SELECT Initials FROM Location.AppUser WHERE Id = 2);

-- place a LOT hold + a CONTAINER hold (placed by user 2)
DECLARE @P TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @P EXEC Quality.Hold_Place @LotId = @Lot, @HoldTypeCodeId = 1, @Reason = N'init test lot', @AppUserId = 2;
DECLARE @HeLot BIGINT = (SELECT NewId FROM @P);
DELETE FROM @P;
INSERT INTO @P EXEC Quality.Hold_Place @ContainerId = @Con, @HoldTypeCodeId = 2, @Reason = N'init test container', @AppUserId = 2;
DECLARE @HeCon BIGINT = (SELECT NewId FROM @P);

-- read the LOT hold -> PlacedByInitials must resolve
CREATE TABLE #gl (Id BIGINT, LotId BIGINT, ContainerId BIGINT, HoldTypeCodeId BIGINT, HoldTypeCode NVARCHAR(50), Reason NVARCHAR(MAX), PlacedByUserId BIGINT, PlacedByInitials NVARCHAR(50), PlacedAt DATETIME2(3));
INSERT INTO #gl EXEC Quality.Hold_GetOpenByLot @LotId = @Lot;
DECLARE @GotLot NVARCHAR(50) = (SELECT PlacedByInitials FROM #gl WHERE Id = @HeLot);
EXEC test.Assert_IsEqual @TestName = N'[HoldGetOpen] Hold_GetOpenByLot exposes PlacedByInitials', @Expected = @ExpInit, @Actual = @GotLot;
DROP TABLE #gl;

-- read the CONTAINER hold -> PlacedByInitials must resolve
CREATE TABLE #gc (Id BIGINT, LotId BIGINT, ContainerId BIGINT, HoldTypeCodeId BIGINT, HoldTypeCode NVARCHAR(50), Reason NVARCHAR(MAX), PlacedByUserId BIGINT, PlacedByInitials NVARCHAR(50), PlacedAt DATETIME2(3));
INSERT INTO #gc EXEC Quality.Hold_GetOpenByContainer @ContainerId = @Con;
DECLARE @GotCon NVARCHAR(50) = (SELECT PlacedByInitials FROM #gc WHERE Id = @HeCon);
EXEC test.Assert_IsEqual @TestName = N'[HoldGetOpen] Hold_GetOpenByContainer exposes PlacedByInitials', @Expected = @ExpInit, @Actual = @GotCon;
DROP TABLE #gc;
GO

DELETE FROM Quality.HoldEvent WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName = N'HINIT-1')
   OR ContainerId IN (SELECT c.Id FROM Lots.Container c INNER JOIN Parts.Item i ON i.Id = c.ItemId WHERE i.PartNumber = N'P7-HINIT-TEST');
DELETE FROM Lots.Container WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P7-HINIT-TEST');
DELETE FROM Lots.LotEventLog       WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName = N'HINIT-1');
DELETE FROM Lots.LotStatusHistory  WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName = N'HINIT-1');
DELETE FROM Lots.Lot WHERE LotName = N'HINIT-1';
GO

EXEC test.EndTestFile;
GO
