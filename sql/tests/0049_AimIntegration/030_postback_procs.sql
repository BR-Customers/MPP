-- =============================================
-- File: 0049_AimIntegration/030_postback_procs.sql
-- Desc: GetForPost / RecordPostResult / ListUnposted round-trip.
-- =============================================
EXEC test.BeginTestFile @FileName = N'0049_AimIntegration/030_postback_procs.sql';
GO

-- Cleanup (idempotent, run before AND after -- see bottom block for rationale).
DELETE sl FROM Lots.ShippingLabel sl INNER JOIN Lots.Container ct ON ct.Id = sl.ContainerId
    INNER JOIN Parts.Item i ON i.Id = ct.ItemId WHERE i.PartNumber = N'AIM-P1-FK';
-- AimShipperIdPool is part-agnostic (Migration 0049) and global; a blanket clear
-- guarantees this file's own inserted row is the only one in play.
DELETE FROM Lots.AimShipperIdPool;
DELETE tr FROM Lots.ContainerTray tr INNER JOIN Lots.Container ct ON ct.Id = tr.ContainerId
    INNER JOIN Parts.Item i ON i.Id = ct.ItemId WHERE i.PartNumber = N'AIM-P1-FK';
DELETE c FROM Lots.LotGenealogyClosure c INNER JOIN Lots.Lot l ON l.Id = c.AncestorLotId OR l.Id = c.DescendantLotId
    WHERE l.LotName = N'AIM-P1-FK-LOT';
DELETE m FROM Lots.LotMovement m INNER JOIN Lots.Lot l ON l.Id = m.LotId WHERE l.LotName = N'AIM-P1-FK-LOT';
DELETE h FROM Lots.LotStatusHistory h INNER JOIN Lots.Lot l ON l.Id = h.LotId WHERE l.LotName = N'AIM-P1-FK-LOT';
DELETE le FROM Lots.LotEventLog le INNER JOIN Lots.Lot l ON l.Id = le.LotId WHERE l.LotName = N'AIM-P1-FK-LOT';
DELETE FROM Lots.Lot WHERE LotName = N'AIM-P1-FK-LOT';
DELETE FROM Lots.Container WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'AIM-P1-FK');
-- Self-heal fixture (config-gap test block, PART = 'AIM-P1-HEAL').
DELETE FROM Lots.Container WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'AIM-P1-HEAL');
GO

-- Run-Tests resets with -SkipDemoSeed: Lots.Container is EMPTY. Open our own
-- (FIXTURE BLOCK, PART = 'AIM-P1-FK'); this task only needs a valid container FK.
DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
DECLARE @UserId BIGINT = 1;
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'AIM-P1-FK')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId)
    VALUES (3, N'AIM-P1-FK', N'AIM plan-1 FK fixture part', 1, @Now, 1);
DECLARE @FkItem BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'AIM-P1-FK');
IF NOT EXISTS (SELECT 1 FROM Parts.ContainerConfig WHERE ItemId = @FkItem AND DeprecatedAt IS NULL)
    INSERT INTO Parts.ContainerConfig (ItemId, TraysPerContainer, PartsPerTray, IsSerialized, ClosureMethod, CreatedAt)
    VALUES (@FkItem, 1, 15, 0, N'ByCount', @Now);
DECLARE @FkConfig BIGINT = (SELECT TOP 1 Id FROM Parts.ContainerConfig WHERE ItemId = @FkItem AND DeprecatedAt IS NULL);
DECLARE @FkCell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');
DECLARE @O TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @O EXEC Lots.Container_Open
    @ItemId = @FkItem, @ContainerConfigId = @FkConfig, @CellLocationId = @FkCell, @AppUserId = @UserId;
DECLARE @ContainerId BIGINT = (SELECT NewId FROM @O);

INSERT INTO Lots.AimShipperIdPool
    (AimShipperId, FetchedAt, ConsumedAt, ConsumedByContainerId, ConsumedByUserId,
     CustomerPartNumber, Quantity, LotNumber)
VALUES
    (N'000900201', SYSUTCDATETIME(), SYSUTCDATETIME(), @ContainerId, @UserId,
     N'112006FB A000', 15, N'000900201');
DECLARE @PoolId BIGINT = SCOPE_IDENTITY();

-- GetForPost returns the payload.
DECLARE @G TABLE (Id BIGINT, AimShipperId NVARCHAR(50), CustomerPartNumber NVARCHAR(50),
                  Quantity INT, LotNumber NVARCHAR(50), PostedAt DATETIME2(3), PostAttempts INT,
                  ContainerId BIGINT, ItemPartNumber NVARCHAR(50));
INSERT INTO @G EXEC Lots.AimShipperIdPool_GetForPost @AimShipperId = N'000900201';
DECLARE @GotPart NVARCHAR(50) = (SELECT CustomerPartNumber FROM @G);
EXEC test.Assert_IsEqual
    @TestName = N'[0049] GetForPost returns the customer part',
    @Expected = N'112006FB A000', @Actual = @GotPart;

-- Unknown serial returns an empty rowset, not an error.
DELETE FROM @G;
INSERT INTO @G EXEC Lots.AimShipperIdPool_GetForPost @AimShipperId = N'999999999';
DECLARE @NoRows NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @G);
EXEC test.Assert_IsEqual
    @TestName = N'[0049] GetForPost returns empty for an unknown serial',
    @Expected = N'0', @Actual = @NoRows;

-- ListUnposted sees it.
DECLARE @L TABLE (Id BIGINT, AimShipperId NVARCHAR(50), ContainerId BIGINT,
                  CustomerPartNumber NVARCHAR(50), Quantity INT, LotNumber NVARCHAR(50),
                  PostAttempts INT, LastPostError NVARCHAR(500),
                  ConsumedAtEt DATETIME2(3), LastPostAttemptAtEt DATETIME2(3), AgeMinutes INT);
INSERT INTO @L EXEC Lots.AimShipperIdPool_ListUnposted @Top = 50;
DECLARE @Listed NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @L WHERE Id = @PoolId);
EXEC test.Assert_IsEqual
    @TestName = N'[0049] ListUnposted includes an owed row',
    @Expected = N'1', @Actual = @Listed;

-- Failure path: attempts increment, error recorded, still owed.
DECLARE @RR TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @RR EXEC Lots.AimShipperIdPool_RecordPostResult
    @Id = @PoolId, @Success = 0, @Error = N'AIM rejected: echo';
DECLARE @Attempts NVARCHAR(10) = (SELECT CAST(PostAttempts AS NVARCHAR(10))
    FROM Lots.AimShipperIdPool WHERE Id = @PoolId);
EXEC test.Assert_IsEqual
    @TestName = N'[0049] failed post increments PostAttempts',
    @Expected = N'1', @Actual = @Attempts;

DECLARE @Err NVARCHAR(500) = (SELECT LastPostError FROM Lots.AimShipperIdPool WHERE Id = @PoolId);
EXEC test.Assert_IsEqual
    @TestName = N'[0049] failed post records the error',
    @Expected = N'AIM rejected: echo', @Actual = @Err;

DECLARE @StillOwed NVARCHAR(10) = (SELECT CASE WHEN PostedAt IS NULL THEN N'1' ELSE N'0' END
    FROM Lots.AimShipperIdPool WHERE Id = @PoolId);
EXEC test.Assert_IsEqual
    @TestName = N'[0049] failed post leaves the row owed',
    @Expected = N'1', @Actual = @StillOwed;

-- Success path: PostedAt stamped, row leaves the unposted list.
DELETE FROM @RR;
INSERT INTO @RR EXEC Lots.AimShipperIdPool_RecordPostResult
    @Id = @PoolId, @Success = 1, @Error = NULL;
DECLARE @Posted NVARCHAR(10) = (SELECT CASE WHEN PostedAt IS NOT NULL THEN N'1' ELSE N'0' END
    FROM Lots.AimShipperIdPool WHERE Id = @PoolId);
EXEC test.Assert_IsEqual
    @TestName = N'[0049] successful post stamps PostedAt',
    @Expected = N'1', @Actual = @Posted;

-- Success path totals attempts across both calls (this row's earlier failed
-- attempt + this successful one) -- pins PostAttempts as a count of attempts
-- made, not a failure-only counter.
DECLARE @AttemptsAfterSuccess NVARCHAR(10) = (SELECT CAST(PostAttempts AS NVARCHAR(10))
    FROM Lots.AimShipperIdPool WHERE Id = @PoolId);
EXEC test.Assert_IsEqual
    @TestName = N'[0049] successful post brings PostAttempts to 2',
    @Expected = N'2', @Actual = @AttemptsAfterSuccess;

DECLARE @ErrAfterSuccess NVARCHAR(500) = (SELECT LastPostError FROM Lots.AimShipperIdPool WHERE Id = @PoolId);
EXEC test.Assert_IsNull
    @TestName = N'[0049] successful post clears LastPostError',
    @Value = @ErrAfterSuccess;

DELETE FROM @L;
INSERT INTO @L EXEC Lots.AimShipperIdPool_ListUnposted @Top = 50;
DECLARE @GoneFromList NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @L WHERE Id = @PoolId);
EXEC test.Assert_IsEqual
    @TestName = N'[0049] posted row leaves the unposted list',
    @Expected = N'0', @Actual = @GoneFromList;

-- RecordPostResult with a NULL Id returns Status = 0 (required-parameter guard).
DELETE FROM @RR;
INSERT INTO @RR EXEC Lots.AimShipperIdPool_RecordPostResult
    @Id = NULL, @Success = 1, @Error = NULL;
DECLARE @NullIdStatus NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @RR);
EXEC test.Assert_IsEqual
    @TestName = N'[0049] RecordPostResult with a NULL Id returns Status = 0',
    @Expected = N'0', @Actual = @NullIdStatus;

-- RecordPostResult with a non-existent Id returns Status = 0 (not-found guard).
DELETE FROM @RR;
INSERT INTO @RR EXEC Lots.AimShipperIdPool_RecordPostResult
    @Id = 99999999, @Success = 1, @Error = NULL;
DECLARE @MissingIdStatus NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @RR);
EXEC test.Assert_IsEqual
    @TestName = N'[0049] RecordPostResult with a non-existent Id returns Status = 0',
    @Expected = N'0', @Actual = @MissingIdStatus;

-- GetForPost with a NULL AimShipperId returns an empty rowset, not an error.
DELETE FROM @G;
INSERT INTO @G EXEC Lots.AimShipperIdPool_GetForPost @AimShipperId = NULL;
DECLARE @NullSerialRows NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @G);
EXEC test.Assert_IsEqual
    @TestName = N'[0049] GetForPost returns empty for a NULL serial',
    @Expected = N'0', @Actual = @NullSerialRows;

-- ---- Config-gap self-heal (a row snapshotted with a NULL CustomerPartNumber
-- must rejoin to the DERIVED value -- Parts.ufn_AimCustomerPartNumber over the
-- live Item.PartNumber, Migration 0051 -- on every read, not stay NULL forever). ----
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'AIM-P1-HEAL')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId)
    VALUES (3, N'AIM-P1-HEAL', N'AIM self-heal fixture part', 1, SYSUTCDATETIME(), 1);
DECLARE @HealItem BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'AIM-P1-HEAL');
IF NOT EXISTS (SELECT 1 FROM Parts.ContainerConfig WHERE ItemId = @HealItem AND DeprecatedAt IS NULL)
    INSERT INTO Parts.ContainerConfig (ItemId, TraysPerContainer, PartsPerTray, IsSerialized, ClosureMethod, CreatedAt)
    VALUES (@HealItem, 1, 15, 0, N'ByCount', SYSUTCDATETIME());
DECLARE @HealConfig BIGINT = (SELECT TOP 1 Id FROM Parts.ContainerConfig WHERE ItemId = @HealItem AND DeprecatedAt IS NULL);
DECLARE @OH TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @OH EXEC Lots.Container_Open
    @ItemId = @HealItem, @ContainerConfigId = @HealConfig, @CellLocationId = @FkCell, @AppUserId = @UserId;
DECLARE @HealContainerId BIGINT = (SELECT NewId FROM @OH);

-- Row A: snapshot NULL -> GetForPost must return the DERIVED value
-- (Parts.ufn_AimCustomerPartNumber(N'AIM-P1-HEAL') = N'AIMP1HEAL').
INSERT INTO Lots.AimShipperIdPool
    (AimShipperId, FetchedAt, ConsumedAt, ConsumedByContainerId, ConsumedByUserId,
     CustomerPartNumber, Quantity, LotNumber)
VALUES
    (N'000900401', SYSUTCDATETIME(), SYSUTCDATETIME(), @HealContainerId, @UserId,
     NULL, 15, N'000900401');
DELETE FROM @G;
INSERT INTO @G EXEC Lots.AimShipperIdPool_GetForPost @AimShipperId = N'000900401';
DECLARE @HealedPart NVARCHAR(50) = (SELECT CustomerPartNumber FROM @G);
EXEC test.Assert_IsEqual
    @TestName = N'[0051] GetForPost self-heals a NULL snapshot to the derived value',
    @Expected = N'AIMP1HEAL', @Actual = @HealedPart;

-- Row B: snapshot IS set, and differs from the item's derived value -> GetForPost
-- must return the FROZEN snapshot, not the derived live value (precedence check).
INSERT INTO Lots.AimShipperIdPool
    (AimShipperId, FetchedAt, ConsumedAt, ConsumedByContainerId, ConsumedByUserId,
     CustomerPartNumber, Quantity, LotNumber)
VALUES
    (N'000900402', SYSUTCDATETIME(), SYSUTCDATETIME(), @HealContainerId, @UserId,
     N'FROZEN-SNAPSHOT-999', 15, N'000900402');
DELETE FROM @G;
INSERT INTO @G EXEC Lots.AimShipperIdPool_GetForPost @AimShipperId = N'000900402';
DECLARE @FrozenPart NVARCHAR(50) = (SELECT CustomerPartNumber FROM @G);
EXEC test.Assert_IsEqual
    @TestName = N'[0049] GetForPost keeps a set snapshot over a differing live item value',
    @Expected = N'FROZEN-SNAPSHOT-999', @Actual = @FrozenPart;

-- GetForPost also surfaces ContainerId + ItemPartNumber for the config-gap modal.
DECLARE @HealedContainerId BIGINT = (SELECT ContainerId FROM @G);
DECLARE @HealContainerIdStr NVARCHAR(20) = CAST(@HealContainerId AS NVARCHAR(20));
DECLARE @HealedContainerIdStr NVARCHAR(20) = CAST(@HealedContainerId AS NVARCHAR(20));
EXEC test.Assert_IsEqual
    @TestName = N'[0049] GetForPost returns the consuming ContainerId',
    @Expected = @HealContainerIdStr, @Actual = @HealedContainerIdStr;

DECLARE @HealedItemPart NVARCHAR(50) = (SELECT ItemPartNumber FROM @G);
EXEC test.Assert_IsEqual
    @TestName = N'[0049] GetForPost returns the item PartNumber',
    @Expected = N'AIM-P1-HEAL', @Actual = @HealedItemPart;

-- ListUnposted applies the same self-heal for the supervisor screen.
DELETE FROM @L;
INSERT INTO @L EXEC Lots.AimShipperIdPool_ListUnposted @Top = 50;
DECLARE @ListedHealedPart NVARCHAR(50) = (SELECT CustomerPartNumber FROM @L WHERE AimShipperId = N'000900401');
EXEC test.Assert_IsEqual
    @TestName = N'[0051] ListUnposted self-heals a NULL snapshot to the derived value',
    @Expected = N'AIMP1HEAL', @Actual = @ListedHealedPart;
GO

EXEC test.EndTestFile;
GO

-- Cleanup (idempotent; mirrors the top block). Lots.Lot_Create is not called in
-- this file, but the genealogy/movement/status/event deletes are kept for
-- consistency with the sibling 020 fixture pattern and are harmless no-ops here
-- (non-cascading FKs on LotGenealogyClosure/LotMovement/LotStatusHistory/
-- LotEventLog/ShippingLabel bite the moment any future edit of this file mints
-- a LOT under 'AIM-P1-FK-LOT').
DELETE sl FROM Lots.ShippingLabel sl INNER JOIN Lots.Container ct ON ct.Id = sl.ContainerId
    INNER JOIN Parts.Item i ON i.Id = ct.ItemId WHERE i.PartNumber = N'AIM-P1-FK';
DELETE FROM Lots.AimShipperIdPool;
DELETE tr FROM Lots.ContainerTray tr INNER JOIN Lots.Container ct ON ct.Id = tr.ContainerId
    INNER JOIN Parts.Item i ON i.Id = ct.ItemId WHERE i.PartNumber = N'AIM-P1-FK';
DELETE c FROM Lots.LotGenealogyClosure c INNER JOIN Lots.Lot l ON l.Id = c.AncestorLotId OR l.Id = c.DescendantLotId
    WHERE l.LotName = N'AIM-P1-FK-LOT';
DELETE m FROM Lots.LotMovement m INNER JOIN Lots.Lot l ON l.Id = m.LotId WHERE l.LotName = N'AIM-P1-FK-LOT';
DELETE h FROM Lots.LotStatusHistory h INNER JOIN Lots.Lot l ON l.Id = h.LotId WHERE l.LotName = N'AIM-P1-FK-LOT';
DELETE le FROM Lots.LotEventLog le INNER JOIN Lots.Lot l ON l.Id = le.LotId WHERE l.LotName = N'AIM-P1-FK-LOT';
DELETE FROM Lots.Lot WHERE LotName = N'AIM-P1-FK-LOT';
DELETE FROM Lots.Container WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'AIM-P1-FK');
DELETE FROM Lots.Container WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'AIM-P1-HEAL');
GO
