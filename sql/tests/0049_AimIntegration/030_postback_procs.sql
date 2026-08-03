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
                  Quantity INT, LotNumber NVARCHAR(50), PostedAt DATETIME2(3), PostAttempts INT);
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

DELETE FROM @L;
INSERT INTO @L EXEC Lots.AimShipperIdPool_ListUnposted @Top = 50;
DECLARE @GoneFromList NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @L WHERE Id = @PoolId);
EXEC test.Assert_IsEqual
    @TestName = N'[0049] posted row leaves the unposted list',
    @Expected = N'0', @Actual = @GoneFromList;
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
GO
