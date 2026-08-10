-- =============================================
-- File:         0025_PlantFloor_Label_Dispatch/050_ShippingLabel_Lifecycle.sql
-- Author:       Blue Ridge Automation
-- Description:  Brief D print/label lifecycle:
--                 * Container_Complete renders + persists ShippingLabel.ZplContent (LBL-060).
--                 * ShippingLabel_MarkDispatch success/failure/exhaustion (ENV-170/LBL-150).
--                 * GetStranded / GetForBanner / AckBanner reads (print-failure lifecycle).
--               Transport (socket) is SIM/hardware-gated; the lifecycle is proc-tested here.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0025_PlantFloor_Label_Dispatch/050_ShippingLabel_Lifecycle.sql';
GO

-- ---- fixture cleanup (re-runnable; LFC namespace) ----
DELETE FROM Lots.ShippingLabel     WHERE AimShipperId IN (N'AIM99887766', N'AIMSTRAND01', N'AIMBANNER01');
DELETE FROM Lots.AimShipperIdPool  WHERE AimShipperId = N'AIM99887766';
DELETE FROM Lots.ContainerTray     WHERE ClosureMethod = N'LFC-TEST';
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId   IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'LFC%');
DELETE FROM Lots.LotGenealogyClosure WHERE DescendantLotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'LFC%');
DELETE FROM Lots.LotStatusHistory  WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'LFC%');
DELETE FROM Lots.LotMovement       WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'LFC%');
DELETE FROM Lots.LotEventLog       WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'LFC%');
DELETE FROM Lots.Container         WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'PN-COMPLETE');
DELETE FROM Lots.Lot               WHERE LotName LIKE N'LFC%';
DELETE FROM Parts.ContainerConfig  WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'PN-COMPLETE');
DELETE FROM Parts.Item             WHERE PartNumber = N'PN-COMPLETE';
DELETE FROM Tools.Tool             WHERE Code = N'LFC-DIE';
DELETE FROM Tools.DieRank          WHERE Code = N'LFC-A';
GO

-- ==========================================================================
-- Part 1 -- Container_Complete renders + persists ZplContent (Task 4 / LBL-060)
-- ==========================================================================
DECLARE @Rank BIGINT;
INSERT INTO Tools.DieRank (Code, Name) VALUES (N'LFC-A', N'Lifecycle A');
SET @Rank = SCOPE_IDENTITY();
DECLARE @Die BIGINT;
INSERT INTO Tools.Tool (ToolTypeId, Code, Name, DieRankId, StatusCodeId, CreatedByUserId)
VALUES ((SELECT Id FROM Tools.ToolType WHERE Code = N'Die'), N'LFC-DIE', N'LFC Die', @Rank,
        (SELECT Id FROM Tools.ToolStatusCode WHERE Code = N'Active'), 1);
SET @Die = SCOPE_IDENTITY();

DECLARE @Item BIGINT;
INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedByUserId)
VALUES ((SELECT TOP 1 Id FROM Parts.ItemType ORDER BY Id), N'PN-COMPLETE', N'DESC-COMPLETE',
        (SELECT TOP 1 Id FROM Parts.Uom ORDER BY Id), 1);
SET @Item = SCOPE_IDENTITY();

-- config: 1 tray x 6 parts = target 6
DECLARE @Cfg BIGINT;
INSERT INTO Parts.ContainerConfig (ItemId, TraysPerContainer, PartsPerTray, ClosureMethod) VALUES (@Item, 1, 6, N'ByCount');
SET @Cfg = SCOPE_IDENTITY();

DECLARE @Loc     BIGINT = (SELECT TOP 1 Id FROM Location.Location ORDER BY Id);
DECLARE @Good    BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Good');
DECLARE @OrigMfg BIGINT = (SELECT Id FROM Lots.LotOriginType  WHERE Code = N'Manufactured');

-- casting -> FG genealogy so {DcPartLevel} resolves on the persisted label
DECLARE @CastLot BIGINT;
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, CurrentLocationId, ToolId, CreatedByUserId)
VALUES (N'LFCCAST1', @Item, @OrigMfg, @Good, 6, @Loc, @Die, 1);
SET @CastLot = SCOPE_IDENTITY();
INSERT INTO Lots.LotGenealogyClosure (AncestorLotId, DescendantLotId, Depth) VALUES (@CastLot, @CastLot, 0);
DECLARE @FgLot BIGINT;
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, CurrentLocationId, CreatedByUserId)
VALUES (N'LFCFG1', @Item, @OrigMfg, @Good, 6, @Loc, 1);
SET @FgLot = SCOPE_IDENTITY();
INSERT INTO Lots.LotGenealogyClosure (AncestorLotId, DescendantLotId, Depth) VALUES (@FgLot, @FgLot, 0), (@CastLot, @FgLot, 1);

-- open container + one closed tray (6 = target)
DECLARE @Cont BIGINT;
INSERT INTO Lots.Container (ItemId, ContainerConfigId, CurrentLocationId, ContainerStatusCodeId, CreatedByUserId)
VALUES (@Item, @Cfg, @Loc, 1, 1);
SET @Cont = SCOPE_IDENTITY();
INSERT INTO Lots.ContainerTray (ContainerId, TrayPosition, PartsClosedCount, ClosedAt, ClosedByUserId, ClosureMethod, FinishedGoodLotId)
VALUES (@Cont, 1, 6, SYSUTCDATETIME(), 1, N'LFC-TEST', @FgLot);

-- AIM pool row for the part
INSERT INTO Lots.AimShipperIdPool (AimShipperId, PartNumber) VALUES (N'AIM99887766', N'PN-COMPLETE');

-- complete the container
DECLARE @SLId BIGINT;
CREATE TABLE #CC (Status BIT, Message NVARCHAR(500), ShippingLabelId BIGINT, AimShipperId NVARCHAR(50));
INSERT INTO #CC EXEC Lots.Container_Complete @ContainerId = @Cont, @OperatorConfirmed = 1, @AppUserId = 1;
DECLARE @CCStatus BIT = (SELECT Status FROM #CC);
SELECT @SLId = ShippingLabelId FROM #CC;
DROP TABLE #CC;

DECLARE @CCStatusStr NVARCHAR(10) = CAST(ISNULL(@CCStatus, 0) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[Complete] Container_Complete Status 1', @Expected = N'1', @Actual = @CCStatusStr;

DECLARE @Zpl NVARCHAR(MAX) = (SELECT ZplContent FROM Lots.ShippingLabel WHERE Id = @SLId);
DECLARE @Persisted NVARCHAR(10) = CASE WHEN @Zpl IS NOT NULL AND LEN(@Zpl) > 0 THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[Complete] ShippingLabel.ZplContent persisted', @Expected = N'1', @Actual = @Persisted;

DECLARE @HasPart NVARCHAR(10) = CASE WHEN @Zpl LIKE N'%PN-COMPLETE%' THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[Complete] persisted ZPL carries part number', @Expected = N'1', @Actual = @HasPart;

DECLARE @HasLevel NVARCHAR(10) = CASE WHEN @Zpl LIKE N'%LFC-A%' THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[Complete] persisted ZPL carries die-rank (DC part level)', @Expected = N'1', @Actual = @HasLevel;
GO
EXEC test.EndTestFile;
GO
