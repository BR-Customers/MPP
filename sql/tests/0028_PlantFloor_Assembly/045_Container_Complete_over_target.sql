-- =============================================
-- File:         0028_PlantFloor_Assembly/045_Container_Complete_over_target.sql
-- Author:       Blue Ridge Automation
-- Description:  Lots.Container_Complete defense-in-depth: a container whose accumulated
--               tray parts EXCEED the config target (TraysPerContainer*PartsPerTray) must
--               NOT complete/ship -- it is a data-integrity error, not a pass. Historically
--               the proc only rejected accum < target, so an over-filled container (e.g.
--               container 24: 5 trays / 20 parts against a 4-tray / 16-part config) sailed
--               through and shipped under a single AIM id. Here we stage an over-target OPEN
--               container by direct tray inserts (bypassing the guarded mint path), seed a
--               healthy AIM pool so over-target is the ONLY possible rejection reason, and
--               assert the completion is refused with the container left Open and unlabelled.
--               Fixture cell: MA1-COMPBR-AOUT (assembly-out).
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0028_PlantFloor_Assembly/045_Container_Complete_over_target.sql';
GO

-- ---- cleanup ----
DELETE sl FROM Lots.ShippingLabel sl INNER JOIN Lots.Container ct ON ct.Id = sl.ContainerId INNER JOIN Parts.Item i ON i.Id = ct.ItemId WHERE i.PartNumber = N'P6-OVT-TEST';
DELETE FROM Lots.AimShipperIdPool WHERE PartNumber = N'P6-OVT-TEST';
DELETE tr FROM Lots.ContainerTray tr INNER JOIN Lots.Container ct ON ct.Id = tr.ContainerId INNER JOIN Parts.Item i ON i.Id = ct.ItemId WHERE i.PartNumber = N'P6-OVT-TEST';
DELETE FROM Lots.Container WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-OVT-TEST');
GO

-- ---- fixture: FG part with a 2-tray x 10-part (=20) ByCount pack-out ----
DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'P6-OVT-TEST')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId) VALUES (3, N'P6-OVT-TEST', N'Over-target completion test part', 1, @Now, 1);
DECLARE @Item BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-OVT-TEST');
IF NOT EXISTS (SELECT 1 FROM Parts.ContainerConfig WHERE ItemId = @Item AND DeprecatedAt IS NULL)
    INSERT INTO Parts.ContainerConfig (ItemId, TraysPerContainer, PartsPerTray, IsSerialized, ClosureMethod, CreatedAt) VALUES (@Item, 2, 10, 0, N'ByCount', @Now);
DECLARE @Config BIGINT = (SELECT TOP 1 Id FROM Parts.ContainerConfig WHERE ItemId = @Item AND DeprecatedAt IS NULL);
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');

-- open a container the normal way
DECLARE @O TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @O EXEC Lots.Container_Open @ItemId = @Item, @ContainerConfigId = @Config, @CellLocationId = @Cell, @AppUserId = 1;
DECLARE @Cid BIGINT = (SELECT NewId FROM @O);

-- stage an OVER-target accumulation: 3 closed trays x 10 = 30 parts against a 20 target
-- (direct inserts bypass the mint path so we can exercise Container_Complete's guard in isolation)
INSERT INTO Lots.ContainerTray (ContainerId, TrayPosition, PartsClosedCount, ClosedAt, ClosedByUserId, ClosureMethod)
VALUES (@Cid, 1, 10, @Now, 1, N'ByCount'),
       (@Cid, 2, 10, @Now, 1, N'ByCount'),
       (@Cid, 3, 10, @Now, 1, N'ByCount');

-- seed a healthy AIM pool so over-target is the ONLY reason completion can fail
DECLARE @TP TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @TP EXEC Lots.AimShipperIdPool_Topup @PartNumber = N'P6-OVT-TEST', @AimShipperId = N'AIM-OVT-1';
GO

-- =============================================
-- Test 1: over-target container completion is REFUSED, container left Open + unlabelled
-- =============================================
DECLARE @Item BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-OVT-TEST');
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');
DECLARE @Cid BIGINT = (SELECT TOP 1 Id FROM Lots.Container WHERE ItemId = @Item ORDER BY Id DESC);

DECLARE @R TABLE (Status BIT, Message NVARCHAR(500), ShippingLabelId BIGINT, AimShipperId NVARCHAR(50));
INSERT INTO @R EXEC Lots.Container_Complete @ContainerId = @Cid, @OperatorConfirmed = 1, @AppUserId = 1, @TerminalLocationId = @Cell;

DECLARE @S BIT = (SELECT Status FROM @R);
DECLARE @SCond BIT = CASE WHEN @S = 0 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[Complete] over-target container refused (Status 0)', @Condition = @SCond;
DECLARE @M NVARCHAR(500) = (SELECT Message FROM @R);
EXEC test.Assert_Contains @TestName = N'[Complete] over-target reject message', @HaystackStr = @M, @NeedleStr = N'over';

-- container stays Open (1) -- not shipped
DECLARE @StatusCode NVARCHAR(10) = (SELECT CAST(ContainerStatusCodeId AS NVARCHAR(10)) FROM Lots.Container WHERE Id = @Cid);
EXEC test.Assert_IsEqual @TestName = N'[Complete] over-target container left Open (1)', @Expected = N'1', @Actual = @StatusCode;
-- no ShippingLabel, AIM pool untouched
DECLARE @Labels NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Lots.ShippingLabel WHERE ContainerId = @Cid);
EXEC test.Assert_IsEqual @TestName = N'[Complete] no ShippingLabel on over-target reject', @Expected = N'0', @Actual = @Labels;
DECLARE @PoolFree NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Lots.AimShipperIdPool WHERE PartNumber = N'P6-OVT-TEST' AND ConsumedAt IS NULL);
EXEC test.Assert_IsEqual @TestName = N'[Complete] AIM id NOT consumed on over-target reject', @Expected = N'1', @Actual = @PoolFree;
GO

-- ---- cleanup ----
DELETE sl FROM Lots.ShippingLabel sl INNER JOIN Lots.Container ct ON ct.Id = sl.ContainerId INNER JOIN Parts.Item i ON i.Id = ct.ItemId WHERE i.PartNumber = N'P6-OVT-TEST';
DELETE FROM Lots.AimShipperIdPool WHERE PartNumber = N'P6-OVT-TEST';
DELETE tr FROM Lots.ContainerTray tr INNER JOIN Lots.Container ct ON ct.Id = tr.ContainerId INNER JOIN Parts.Item i ON i.Id = ct.ItemId WHERE i.PartNumber = N'P6-OVT-TEST';
DELETE FROM Lots.Container WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-OVT-TEST');
GO

EXEC test.EndTestFile;
GO
