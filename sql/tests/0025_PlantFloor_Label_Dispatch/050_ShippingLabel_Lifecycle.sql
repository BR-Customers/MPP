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
INSERT INTO Lots.AimShipperIdPool (AimShipperId, FetchedAt) VALUES (N'AIM99887766', SYSUTCDATETIME());

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

-- ==========================================================================
-- Part 2 -- ShippingLabel_Reprint re-renders ZplContent (Task 5 / LBL-060)
-- ==========================================================================
DECLARE @ReprintId BIGINT;
CREATE TABLE #RP (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #RP EXEC Lots.ShippingLabel_Reprint @ShippingLabelId = @SLId, @PrintReasonCode = N'Damaged', @AppUserId = 1;
SELECT @ReprintId = NewId FROM #RP; DROP TABLE #RP;

DECLARE @RZpl NVARCHAR(MAX) = (SELECT ZplContent FROM Lots.ShippingLabel WHERE Id = @ReprintId);
DECLARE @ROk NVARCHAR(10) = CASE WHEN @RZpl IS NOT NULL AND LEN(@RZpl) > 0 AND @RZpl LIKE N'%PN-COMPLETE%' THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[Reprint] re-rendered ZplContent persisted', @Expected = N'1', @Actual = @ROk;

-- ==========================================================================
-- Part 3 -- ShippingLabel_MarkDispatch lifecycle (Task 6 / ENV-170 / LBL-150)
-- ==========================================================================
-- success on the primary label -> PrintedAt set, PrintAttempts bumped
CREATE TABLE #M1 (Status BIT, Message NVARCHAR(500));
INSERT INTO #M1 EXEC Lots.ShippingLabel_MarkDispatch @ShippingLabelId = @SLId, @Success = 1;
DROP TABLE #M1;
DECLARE @Pr NVARCHAR(10) = (SELECT CASE WHEN PrintedAt IS NOT NULL AND PrintAttempts >= 1 THEN N'1' ELSE N'0' END FROM Lots.ShippingLabel WHERE Id = @SLId);
EXEC test.Assert_IsEqual @TestName = N'[Mark] success sets PrintedAt + bumps PrintAttempts', @Expected = N'1', @Actual = @Pr;

-- failure x2 on the reprint row with MaxAttempts 2 -> PrintFailedAt + LastPrintError
CREATE TABLE #M2 (Status BIT, Message NVARCHAR(500));
INSERT INTO #M2 EXEC Lots.ShippingLabel_MarkDispatch @ShippingLabelId = @ReprintId, @Success = 0, @ErrorText = N'conn refused', @MaxAttempts = 2;
INSERT INTO #M2 EXEC Lots.ShippingLabel_MarkDispatch @ShippingLabelId = @ReprintId, @Success = 0, @ErrorText = N'conn refused', @MaxAttempts = 2;
DROP TABLE #M2;
DECLARE @Fail NVARCHAR(10) = (SELECT CASE WHEN PrintFailedAt IS NOT NULL AND LastPrintError = N'conn refused' AND PrintAttempts >= 2 THEN N'1' ELSE N'0' END FROM Lots.ShippingLabel WHERE Id = @ReprintId);
EXEC test.Assert_IsEqual @TestName = N'[Mark] attempts exhausted -> PrintFailedAt + LastPrintError', @Expected = N'1', @Actual = @Fail;

-- bad id -> Status 0
DECLARE @MBad BIT;
CREATE TABLE #M3 (Status BIT, Message NVARCHAR(500));
INSERT INTO #M3 EXEC Lots.ShippingLabel_MarkDispatch @ShippingLabelId = 999999999, @Success = 1;
SELECT @MBad = Status FROM #M3; DROP TABLE #M3;
DECLARE @MBadStr NVARCHAR(10) = CAST(@MBad AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[Mark] bad ShippingLabelId rejected', @Expected = N'0', @Actual = @MBadStr;

-- ==========================================================================
-- Part 4 -- GetStranded / GetForBanner / AckBanner reads (Task 7)
-- ==========================================================================
-- a stranded label: unprinted, unfailed, older than 60s
DECLARE @StrandId BIGINT;
INSERT INTO Lots.ShippingLabel (ContainerId, AimShipperId, LabelTypeCodeId, Initial, PrintedByUserId, ZplContent, CreatedAt)
VALUES (@Cont, N'AIMSTRAND01', (SELECT Id FROM Lots.LabelTypeCode WHERE Code = N'Container'), 1, 1, N'^XA^XZ', DATEADD(MINUTE, -5, SYSUTCDATETIME()));
SET @StrandId = SCOPE_IDENTITY();

CREATE TABLE #S (Id BIGINT, ContainerId BIGINT, AimShipperId NVARCHAR(50), TerminalLocationId BIGINT, ZplContent NVARCHAR(MAX), PrintAttempts INT);
INSERT INTO #S EXEC Lots.ShippingLabel_GetStranded;
DECLARE @StrandHit NVARCHAR(10) = CASE WHEN EXISTS (SELECT 1 FROM #S WHERE Id = @StrandId) THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[Stranded] old unprinted row returned', @Expected = N'1', @Actual = @StrandHit;
-- the primary label was marked printed -> excluded
DECLARE @PrintedMiss NVARCHAR(10) = CASE WHEN EXISTS (SELECT 1 FROM #S WHERE Id = @SLId) THEN N'0' ELSE N'1' END;
EXEC test.Assert_IsEqual @TestName = N'[Stranded] printed row excluded', @Expected = N'1', @Actual = @PrintedMiss;
DROP TABLE #S;

-- the reprint row is failed (PrintFailedAt) + unacked -> banner
CREATE TABLE #B (Id BIGINT, ContainerId BIGINT, TerminalLocationId BIGINT, AimShipperId NVARCHAR(50), LastPrintError NVARCHAR(500));
INSERT INTO #B EXEC Lots.ShippingLabel_GetForBanner;
DECLARE @BannerHit NVARCHAR(10) = CASE WHEN EXISTS (SELECT 1 FROM #B WHERE Id = @ReprintId) THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[Banner] failed-unacked row returned', @Expected = N'1', @Actual = @BannerHit;
DROP TABLE #B;

-- ack it -> no longer in the banner set
CREATE TABLE #A (Status BIT, Message NVARCHAR(500));
INSERT INTO #A EXEC Lots.ShippingLabel_AckBanner @ShippingLabelId = @ReprintId;
DROP TABLE #A;
CREATE TABLE #B2 (Id BIGINT, ContainerId BIGINT, TerminalLocationId BIGINT, AimShipperId NVARCHAR(50), LastPrintError NVARCHAR(500));
INSERT INTO #B2 EXEC Lots.ShippingLabel_GetForBanner;
DECLARE @AckedMiss NVARCHAR(10) = CASE WHEN EXISTS (SELECT 1 FROM #B2 WHERE Id = @ReprintId) THEN N'0' ELSE N'1' END;
EXEC test.Assert_IsEqual @TestName = N'[Banner] acknowledged row cleared', @Expected = N'1', @Actual = @AckedMiss;
DROP TABLE #B2;
GO
EXEC test.EndTestFile;
GO
