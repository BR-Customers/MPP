-- =============================================
-- File: 0049_AimIntegration/040_MarkPosted.sql
-- Desc: MarkPosted stamps PostedAt with audit attribution and rejects re-marking.
-- =============================================
EXEC test.BeginTestFile @FileName = N'0049_AimIntegration/040_MarkPosted.sql';
GO

-- Cleanup (idempotent, run before AND after -- see bottom block for rationale).
-- AimShipperIdPool is part-agnostic (Migration 0049) and global; a blanket clear
-- guarantees this file's own inserted row is the only one in play.
DELETE FROM Lots.AimShipperIdPool;
DELETE FROM Audit.ConfigLog WHERE Description LIKE N'%000900301%';
DELETE sl FROM Lots.ShippingLabel sl INNER JOIN Lots.Container ct ON ct.Id = sl.ContainerId
    INNER JOIN Parts.Item i ON i.Id = ct.ItemId WHERE i.PartNumber = N'AIM-P1-FK';
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
     CustomerPartNumber, Quantity, LotNumber, PostAttempts, LastPostError)
VALUES
    (N'000900301', SYSUTCDATETIME(), SYSUTCDATETIME(), @ContainerId, @UserId,
     N'112006FB A000', 15, N'000900301', 12, N'AIM rejected: echo');
DECLARE @PoolId BIGINT = SCOPE_IDENTITY();

-- A NULL or whitespace-only @Note is rejected -- the note IS the audit
-- justification, so a blank one defeats the point. Run BEFORE the row is
-- marked posted so the rejection is attributable to the blank note, not the
-- already-posted guard.
DECLARE @M TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @M EXEC Lots.AimShipperIdPool_MarkPosted
    @Id = @PoolId, @AppUserId = @UserId, @Note = NULL;
DECLARE @NullNoteStatus NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @M);
EXEC test.Assert_IsEqual
    @TestName = N'[0049] MarkPosted rejects a NULL note',
    @Expected = N'0', @Actual = @NullNoteStatus;

DELETE FROM @M;
INSERT INTO @M EXEC Lots.AimShipperIdPool_MarkPosted
    @Id = @PoolId, @AppUserId = @UserId, @Note = N'   ';
DECLARE @BlankNoteStatus NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @M);
EXEC test.Assert_IsEqual
    @TestName = N'[0049] MarkPosted rejects a whitespace-only note',
    @Expected = N'0', @Actual = @BlankNoteStatus;

DECLARE @NotYetPosted NVARCHAR(10) = (SELECT CASE WHEN PostedAt IS NULL THEN N'1' ELSE N'0' END
    FROM Lots.AimShipperIdPool WHERE Id = @PoolId);
EXEC test.Assert_IsEqual
    @TestName = N'[0049] blank-note rejection leaves the row unposted',
    @Expected = N'1', @Actual = @NotYetPosted;

DELETE FROM @M;
INSERT INTO @M EXEC Lots.AimShipperIdPool_MarkPosted
    @Id = @PoolId, @AppUserId = @UserId,
    @Note = N'Confirmed on AIM Unshipped Labels report';
DECLARE @Ok NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @M);
EXEC test.Assert_IsEqual
    @TestName = N'[0049] MarkPosted succeeds on an owed row',
    @Expected = N'1', @Actual = @Ok;

DECLARE @Posted NVARCHAR(10) = (SELECT CASE WHEN PostedAt IS NOT NULL THEN N'1' ELSE N'0' END
    FROM Lots.AimShipperIdPool WHERE Id = @PoolId);
EXEC test.Assert_IsEqual
    @TestName = N'[0049] MarkPosted stamps PostedAt',
    @Expected = N'1', @Actual = @Posted;

DECLARE @Audited NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10))
    FROM Audit.ConfigLog
    WHERE Description LIKE N'%000900301%' AND Description LIKE N'%Marked Posted%');
EXEC test.Assert_IsEqual
    @TestName = N'[0049] MarkPosted writes an audit row naming the serial',
    @Expected = N'1', @Actual = @Audited;

-- Re-marking an already-posted row is rejected.
DELETE FROM @M;
INSERT INTO @M EXEC Lots.AimShipperIdPool_MarkPosted
    @Id = @PoolId, @AppUserId = @UserId, @Note = N'again';
DECLARE @Rejected NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @M);
EXEC test.Assert_IsEqual
    @TestName = N'[0049] MarkPosted rejects an already-posted row',
    @Expected = N'0', @Actual = @Rejected;
GO

EXEC test.EndTestFile;
GO

-- Cleanup (idempotent; mirrors the top block). Lots.Lot_Create is not called in
-- this file, but the genealogy/movement/status/event deletes are kept for
-- consistency with the sibling 030 fixture pattern and are harmless no-ops here.
DELETE FROM Lots.AimShipperIdPool;
DELETE FROM Audit.ConfigLog WHERE Description LIKE N'%000900301%';
DELETE sl FROM Lots.ShippingLabel sl INNER JOIN Lots.Container ct ON ct.Id = sl.ContainerId
    INNER JOIN Parts.Item i ON i.Id = ct.ItemId WHERE i.PartNumber = N'AIM-P1-FK';
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
