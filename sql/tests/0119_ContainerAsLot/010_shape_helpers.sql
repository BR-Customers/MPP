-- =============================================
-- File:         0119_ContainerAsLot/010_shape_helpers.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-11-04
-- Description:  Lots.ufn_ContainerLots / Lots.ufn_LotContainers (spec sec 6):
--               both shapes and a mixed container.
--                 OLD   2 trays, each with its own FG LOT (FinishedGoodLotId)
--                 NEW   Container.LotId set, 2 trays with NULL FinishedGoodLotId
--                 MIXED 1 tray LOT + a container LOT (second tray appended)
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0119_ContainerAsLot/010_shape_helpers.sql';
GO

DECLARE @ItemId BIGINT = (SELECT TOP 1 ItemId FROM Parts.ContainerConfig WHERE DeprecatedAt IS NULL ORDER BY Id);
DECLARE @CfgId  BIGINT = (SELECT TOP 1 Id FROM Parts.ContainerConfig WHERE ItemId = @ItemId AND DeprecatedAt IS NULL ORDER BY Id);
DECLARE @LocId  BIGINT = (SELECT TOP 1 Id FROM Location.Location ORDER BY Id);
DECLARE @Good   BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Good');
DECLARE @Mfg    BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');

INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, CurrentLocationId, CreatedByUserId)
VALUES (N'T0119-010-OLD1', @ItemId, @Mfg, @Good, 4, @LocId, 1),
       (N'T0119-010-OLD2', @ItemId, @Mfg, @Good, 4, @LocId, 1),
       (N'T0119-010-NEW',  @ItemId, @Mfg, @Good, 8, @LocId, 1),
       (N'T0119-010-MXT',  @ItemId, @Mfg, @Good, 4, @LocId, 1),
       (N'T0119-010-MXC',  @ItemId, @Mfg, @Good, 4, @LocId, 1);
DECLARE @Old1 BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'T0119-010-OLD1');
DECLARE @Old2 BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'T0119-010-OLD2');
DECLARE @New  BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'T0119-010-NEW');
DECLARE @MxT  BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'T0119-010-MXT');
DECLARE @MxC  BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'T0119-010-MXC');

INSERT INTO Lots.Container (ItemId, ContainerConfigId, CurrentLocationId, CreatedByUserId, LotId) VALUES (@ItemId, @CfgId, @LocId, 1, NULL);
DECLARE @COld BIGINT = SCOPE_IDENTITY();
INSERT INTO Lots.Container (ItemId, ContainerConfigId, CurrentLocationId, CreatedByUserId, LotId) VALUES (@ItemId, @CfgId, @LocId, 1, @New);
DECLARE @CNew BIGINT = SCOPE_IDENTITY();
INSERT INTO Lots.Container (ItemId, ContainerConfigId, CurrentLocationId, CreatedByUserId, LotId) VALUES (@ItemId, @CfgId, @LocId, 1, @MxC);
DECLARE @CMx BIGINT = SCOPE_IDENTITY();

INSERT INTO Lots.ContainerTray (ContainerId, TrayPosition, PartsClosedCount, ClosedAt, FinishedGoodLotId)
VALUES (@COld, 1, 4, SYSUTCDATETIME(), @Old1), (@COld, 2, 4, SYSUTCDATETIME(), @Old2),
       (@CNew, 1, 4, SYSUTCDATETIME(), NULL),  (@CNew, 2, 4, SYSUTCDATETIME(), NULL),
       (@CMx,  1, 4, SYSUTCDATETIME(), @MxT),  (@CMx,  2, 4, SYSUTCDATETIME(), NULL);
DECLARE @OldTray2 BIGINT = (SELECT Id FROM Lots.ContainerTray WHERE ContainerId = @COld AND TrayPosition = 2);

DECLARE @c BIT;

-- ufn_ContainerLots row counts
SET @c = CASE WHEN (SELECT COUNT(*) FROM Lots.ufn_ContainerLots(@COld)) = 2 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[ContainerLots] old container -> its 2 tray LOTs', @Condition = @c;
SET @c = CASE WHEN (SELECT COUNT(*) FROM Lots.ufn_ContainerLots(@CNew)) = 1
               AND (SELECT LotId FROM Lots.ufn_ContainerLots(@CNew)) = @New THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[ContainerLots] new container -> its 1 container LOT', @Condition = @c;
SET @c = CASE WHEN (SELECT COUNT(*) FROM Lots.ufn_ContainerLots(@CMx)) = 2 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[ContainerLots] mixed container -> tray LOT + container LOT', @Condition = @c;

-- Representative LOT: TOP 1 ORDER BY SortKey
SET @c = CASE WHEN (SELECT TOP 1 LotId FROM Lots.ufn_ContainerLots(@COld) ORDER BY SortKey) = @Old1 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[ContainerLots] representative of old = first tray LOT', @Condition = @c;
SET @c = CASE WHEN (SELECT TOP 1 LotId FROM Lots.ufn_ContainerLots(@CMx) ORDER BY SortKey) = @MxT THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[ContainerLots] representative of mixed = first tray LOT', @Condition = @c;
SET @c = CASE WHEN (SELECT TOP 1 LotId FROM Lots.ufn_ContainerLots(@CNew) ORDER BY SortKey) = @New THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[ContainerLots] representative of new = container LOT', @Condition = @c;
SET @c = CASE WHEN (SELECT Shape FROM Lots.ufn_ContainerLots(@CNew)) = N'Container'
               AND NOT EXISTS (SELECT 1 FROM Lots.ufn_ContainerLots(@COld) WHERE Shape <> N'Tray') THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[ContainerLots] Shape labels Tray / Container', @Condition = @c;

-- ufn_LotContainers
SET @c = CASE WHEN (SELECT COUNT(*) FROM Lots.ufn_LotContainers(@Old2)) = 1
               AND (SELECT ContainerId FROM Lots.ufn_LotContainers(@Old2)) = @COld
               AND (SELECT ContainerTrayId FROM Lots.ufn_LotContainers(@Old2)) = @OldTray2 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[LotContainers] old tray LOT -> its container + tray', @Condition = @c;
SET @c = CASE WHEN (SELECT COUNT(*) FROM Lots.ufn_LotContainers(@New)) = 1
               AND (SELECT ContainerId FROM Lots.ufn_LotContainers(@New)) = @CNew
               AND (SELECT ContainerTrayId FROM Lots.ufn_LotContainers(@New)) IS NULL THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[LotContainers] container LOT -> its container, tray NULL', @Condition = @c;
SET @c = CASE WHEN NOT EXISTS (SELECT 1 FROM Lots.ufn_LotContainers(-1)) THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[LotContainers] unknown LOT -> no rows', @Condition = @c;

DELETE FROM Lots.ContainerTray WHERE ContainerId IN (@COld, @CNew, @CMx);
DELETE FROM Lots.Container WHERE Id IN (@COld, @CNew, @CMx);
DELETE FROM Lots.Lot WHERE Id IN (@Old1, @Old2, @New, @MxT, @MxC);
GO

EXEC test.PrintSummary;
EXEC test.EndTestFile;
GO
