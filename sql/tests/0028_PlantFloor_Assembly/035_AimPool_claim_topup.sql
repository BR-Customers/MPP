-- =============================================
-- File:         0028_PlantFloor_Assembly/035_AimPool_claim_topup.sql
-- Description:  Lots.AimShipperIdPool_Topup + _Claim (Arc 2 Phase 6 / UJ-04). Migration
--               0049: the pool is part-agnostic (AIM's nextserial.csv takes no part
--               parameter) -- FIFO by FetchedAt across the whole pool; OI-33 empty-pool
--               hard-fail is global. (@ContainerId was always a required parameter of
--               _Claim; only @PartNumber was dropped by the genericization. A container
--               is opened as a fixture.)
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0028_PlantFloor_Assembly/035_AimPool_claim_topup.sql';
GO

-- pre-cleanup: guarantee a clean global pool before seeding (claim is now global FIFO,
-- so leftover rows from an earlier file would be claimed ahead of this file's own ids).
DELETE FROM Lots.AimShipperIdPool;
GO

-- Topup with no part dimension.
DECLARE @T TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @T EXEC Lots.AimShipperIdPool_Topup
    @AimShipperId = N'000900001', @FetchedInterfaceLogId = NULL;
DECLARE @TopupOk NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @T);
EXEC test.Assert_IsEqual
    @TestName = N'[AimPool] topup accepts an ID with no part number',
    @Expected = N'1', @Actual = @TopupOk;

INSERT INTO @T EXEC Lots.AimShipperIdPool_Topup
    @AimShipperId = N'000900002', @FetchedInterfaceLogId = NULL;

-- Depth is a single global number.
DECLARE @D TABLE (Depth INT, OldestAvailableAt DATETIME2(3));
INSERT INTO @D EXEC Lots.AimShipperIdPool_GetDepth;
DECLARE @DepthRows NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @D);
EXEC test.Assert_IsEqual
    @TestName = N'[AimPool] GetDepth returns exactly one row',
    @Expected = N'1', @Actual = @DepthRows;

DECLARE @DepthAtLeast NVARCHAR(10) =
    (SELECT CASE WHEN Depth >= 2 THEN N'1' ELSE N'0' END FROM @D);
EXEC test.Assert_IsEqual
    @TestName = N'[AimPool] depth counts both seeded IDs',
    @Expected = N'1', @Actual = @DepthAtLeast;

-- Claim takes no part number and returns the FIFO-oldest available ID.
-- -SkipDemoSeed leaves Lots.Container empty, so open one (FIXTURE BLOCK, PART = 'AIM-P1-T2').
DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
DECLARE @UserId BIGINT = 1;
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'AIM-P1-T2')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId)
    VALUES (3, N'AIM-P1-T2', N'AIM plan-1 claim fixture part', 1, @Now, 1);
DECLARE @T2Item BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'AIM-P1-T2');
IF NOT EXISTS (SELECT 1 FROM Parts.ContainerConfig WHERE ItemId = @T2Item AND DeprecatedAt IS NULL)
    INSERT INTO Parts.ContainerConfig (ItemId, TraysPerContainer, PartsPerTray, IsSerialized, ClosureMethod, CreatedAt)
    VALUES (@T2Item, 1, 15, 0, N'ByCount', @Now);
DECLARE @T2Config BIGINT = (SELECT TOP 1 Id FROM Parts.ContainerConfig WHERE ItemId = @T2Item AND DeprecatedAt IS NULL);
DECLARE @T2Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');
DECLARE @O2 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @O2 EXEC Lots.Container_Open
    @ItemId = @T2Item, @ContainerConfigId = @T2Config, @CellLocationId = @T2Cell, @AppUserId = @UserId;
DECLARE @ContainerId BIGINT = (SELECT NewId FROM @O2);
DECLARE @C TABLE (Status BIT, Message NVARCHAR(500), AimShipperId NVARCHAR(50));
INSERT INTO @C EXEC Lots.AimShipperIdPool_Claim
    @ContainerId = @ContainerId, @AppUserId = @UserId;
DECLARE @ClaimOk NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @C);
EXEC test.Assert_IsEqual
    @TestName = N'[AimPool] claim succeeds with no part number',
    @Expected = N'1', @Actual = @ClaimOk;

DECLARE @Claimed NVARCHAR(50) = (SELECT AimShipperId FROM @C);
EXEC test.Assert_IsNotNull
    @TestName = N'[AimPool] claim returns an AimShipperId',
    @Value = @Claimed;

DECLARE @Consumed NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10))
    FROM Lots.AimShipperIdPool
    WHERE AimShipperId = @Claimed AND ConsumedAt IS NOT NULL
      AND ConsumedByContainerId = @ContainerId);
EXEC test.Assert_IsEqual
    @TestName = N'[AimPool] claimed row is marked consumed and bound to the container',
    @Expected = N'1', @Actual = @Consumed;
GO

-- post-cleanup: leave the pool empty for the next file's global-FIFO expectations
-- (Container_Complete/Container_Ship fixtures assert specific "FIFO first" ids).
DELETE FROM Lots.AimShipperIdPool;
DELETE FROM Lots.Container WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'AIM-P1-T2');
GO

EXEC test.EndTestFile;
GO
